use crate::error::AppError;
use crate::{auth, feeds, now, opml, podcastindex, AppState};
use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::routing::{get, post, put};
use axum::{Json, Router};
use serde::{Deserialize, Serialize};

const PAGE: i64 = 50;

const EPISODE_ITEM_SELECT: &str = "SELECT e.id, e.podcast_id, p.title AS podcast_title, p.image_url AS podcast_image, \
     e.title, e.audio_url, e.duration_secs, e.published_at, e.image_url, \
     CAST(COALESCE(s.position_secs, 0) AS REAL) AS position_secs, s.played_at \
     FROM episodes e \
     JOIN podcasts p ON p.id = e.podcast_id \
     LEFT JOIN episode_state s ON s.episode_id = e.id ";

#[derive(Serialize, sqlx::FromRow)]
pub struct EpisodeItem {
    pub id: i64,
    pub podcast_id: i64,
    pub podcast_title: String,
    pub podcast_image: String,
    pub title: String,
    pub audio_url: String,
    pub duration_secs: Option<i64>,
    pub published_at: i64,
    pub image_url: String,
    pub position_secs: f64,
    pub played_at: Option<i64>,
}

#[derive(Serialize, sqlx::FromRow)]
pub struct EpisodeDetail {
    #[sqlx(flatten)]
    #[serde(flatten)]
    pub item: EpisodeItem,
    pub notes_html: String,
    pub archived_at: Option<i64>,
}

#[derive(Serialize, sqlx::FromRow)]
pub struct Show {
    pub id: i64,
    pub feed_url: String,
    pub title: String,
    pub description: String,
    pub image_url: String,
    pub site_url: String,
    pub episode_count: i64,
    pub unplayed_count: i64,
}

#[derive(Serialize)]
pub struct Page<T> {
    pub items: Vec<T>,
    pub next_offset: Option<i64>,
}

#[derive(Deserialize)]
pub struct PageParams {
    #[serde(default)]
    pub offset: i64,
}

fn paginate<T>(mut rows: Vec<T>, offset: i64) -> Page<T> {
    let next_offset = if rows.len() as i64 > PAGE {
        rows.truncate(PAGE as usize);
        Some(offset + PAGE)
    } else {
        None
    };
    Page { items: rows, next_offset }
}

// ---------- auth ----------

#[derive(Deserialize)]
struct LoginBody {
    token: String,
}

async fn login(State(state): State<AppState>, Json(body): Json<LoginBody>) -> Result<StatusCode, AppError> {
    if auth::token_matches(&body.token, &state.cfg.api_token) {
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(AppError::Unauthorized)
    }
}

// ---------- episode lists ----------

async fn recent(
    State(state): State<AppState>,
    Query(p): Query<PageParams>,
) -> Result<Json<Page<EpisodeItem>>, AppError> {
    let sql = format!(
        "{EPISODE_ITEM_SELECT} WHERE s.played_at IS NULL AND s.archived_at IS NULL \
         ORDER BY e.published_at DESC, e.id DESC LIMIT ? OFFSET ?"
    );
    let rows = sqlx::query_as::<_, EpisodeItem>(&sql)
        .bind(PAGE + 1)
        .bind(p.offset)
        .fetch_all(&state.pool)
        .await?;
    Ok(Json(paginate(rows, p.offset)))
}

async fn played(
    State(state): State<AppState>,
    Query(p): Query<PageParams>,
) -> Result<Json<Page<EpisodeItem>>, AppError> {
    let sql = format!(
        "{EPISODE_ITEM_SELECT} WHERE s.played_at IS NOT NULL \
         ORDER BY s.played_at DESC, e.id DESC LIMIT ? OFFSET ?"
    );
    let rows = sqlx::query_as::<_, EpisodeItem>(&sql)
        .bind(PAGE + 1)
        .bind(p.offset)
        .fetch_all(&state.pool)
        .await?;
    Ok(Json(paginate(rows, p.offset)))
}

// ---------- shows ----------

const SHOW_SELECT: &str = "SELECT p.id, p.feed_url, p.title, p.description, p.image_url, p.site_url, \
     (SELECT COUNT(*) FROM episodes e WHERE e.podcast_id = p.id) AS episode_count, \
     (SELECT COUNT(*) FROM episodes e LEFT JOIN episode_state s ON s.episode_id = e.id \
        WHERE e.podcast_id = p.id AND s.played_at IS NULL AND s.archived_at IS NULL) AS unplayed_count \
     FROM podcasts p ";

async fn shows(State(state): State<AppState>) -> Result<Json<Vec<Show>>, AppError> {
    let sql = format!("{SHOW_SELECT} ORDER BY p.title COLLATE NOCASE, p.id");
    Ok(Json(
        sqlx::query_as::<_, Show>(&sql).fetch_all(&state.pool).await?,
    ))
}

async fn fetch_show(state: &AppState, id: i64) -> Result<Show, AppError> {
    let sql = format!("{SHOW_SELECT} WHERE p.id = ?");
    sqlx::query_as::<_, Show>(&sql)
        .bind(id)
        .fetch_optional(&state.pool)
        .await?
        .ok_or(AppError::NotFound)
}

#[derive(Deserialize)]
struct SubscribeBody {
    feed_url: String,
}

async fn subscribe(
    State(state): State<AppState>,
    Json(body): Json<SubscribeBody>,
) -> Result<(StatusCode, Json<Show>), AppError> {
    let id = feeds::subscribe(&state, &body.feed_url).await?;
    Ok((StatusCode::CREATED, Json(fetch_show(&state, id).await?)))
}

#[derive(Serialize)]
struct ShowDetail {
    show: Show,
    episodes: Page<EpisodeItem>,
}

async fn show_detail(
    State(state): State<AppState>,
    Path(id): Path<i64>,
    Query(p): Query<PageParams>,
) -> Result<Json<ShowDetail>, AppError> {
    let show = fetch_show(&state, id).await?;
    let sql = format!(
        "{EPISODE_ITEM_SELECT} WHERE e.podcast_id = ? \
         ORDER BY e.published_at DESC, e.id DESC LIMIT ? OFFSET ?"
    );
    let rows = sqlx::query_as::<_, EpisodeItem>(&sql)
        .bind(id)
        .bind(PAGE + 1)
        .bind(p.offset)
        .fetch_all(&state.pool)
        .await?;
    Ok(Json(ShowDetail { show, episodes: paginate(rows, p.offset) }))
}

async fn unsubscribe(State(state): State<AppState>, Path(id): Path<i64>) -> Result<StatusCode, AppError> {
    fetch_show(&state, id).await?;
    sqlx::query("DELETE FROM episodes_fts WHERE rowid IN (SELECT id FROM episodes WHERE podcast_id = ?)")
        .bind(id)
        .execute(&state.pool)
        .await?;
    sqlx::query("DELETE FROM podcasts WHERE id = ?")
        .bind(id)
        .execute(&state.pool)
        .await?;
    Ok(StatusCode::NO_CONTENT)
}

// ---------- episodes ----------

async fn episode_detail(
    State(state): State<AppState>,
    Path(id): Path<i64>,
) -> Result<Json<EpisodeDetail>, AppError> {
    let sql = format!(
        "SELECT e.id, e.podcast_id, p.title AS podcast_title, p.image_url AS podcast_image, \
         e.title, e.audio_url, e.duration_secs, e.published_at, e.image_url, \
         CAST(COALESCE(s.position_secs, 0) AS REAL) AS position_secs, s.played_at, e.notes_html, s.archived_at \
         FROM episodes e JOIN podcasts p ON p.id = e.podcast_id \
         LEFT JOIN episode_state s ON s.episode_id = e.id WHERE e.id = ?"
    );
    sqlx::query_as::<_, EpisodeDetail>(&sql)
        .bind(id)
        .fetch_optional(&state.pool)
        .await?
        .map(Json)
        .ok_or(AppError::NotFound)
}

async fn episode_exists(state: &AppState, id: i64) -> Result<(), AppError> {
    let found: Option<i64> = sqlx::query_scalar("SELECT id FROM episodes WHERE id = ?")
        .bind(id)
        .fetch_optional(&state.pool)
        .await?;
    found.map(|_| ()).ok_or(AppError::NotFound)
}

async fn set_played(State(state): State<AppState>, Path(id): Path<i64>) -> Result<StatusCode, AppError> {
    episode_exists(&state, id).await?;
    let ts = now();
    sqlx::query(
        "INSERT INTO episode_state (episode_id, played_at, updated_at) VALUES (?, ?, ?) \
         ON CONFLICT (episode_id) DO UPDATE SET played_at = excluded.played_at, updated_at = excluded.updated_at",
    )
    .bind(id)
    .bind(ts)
    .bind(ts)
    .execute(&state.pool)
    .await?;
    Ok(StatusCode::NO_CONTENT)
}

/// Unmark: clears archived too, so the episode returns to Recent. Position is
/// kept so resume still works.
async fn clear_played(State(state): State<AppState>, Path(id): Path<i64>) -> Result<StatusCode, AppError> {
    episode_exists(&state, id).await?;
    sqlx::query("UPDATE episode_state SET played_at = NULL, archived_at = NULL, updated_at = ? WHERE episode_id = ?")
        .bind(now())
        .bind(id)
        .execute(&state.pool)
        .await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct PositionBody {
    seconds: f64,
}

async fn set_position(
    State(state): State<AppState>,
    Path(id): Path<i64>,
    Json(body): Json<PositionBody>,
) -> Result<StatusCode, AppError> {
    if !body.seconds.is_finite() || body.seconds < 0.0 {
        return Err(AppError::Invalid("seconds must be >= 0".into()));
    }
    episode_exists(&state, id).await?;
    let ts = now();
    sqlx::query(
        "INSERT INTO episode_state (episode_id, position_secs, updated_at) VALUES (?, ?, ?) \
         ON CONFLICT (episode_id) DO UPDATE SET position_secs = excluded.position_secs, updated_at = excluded.updated_at",
    )
    .bind(id)
    .bind(body.seconds)
    .bind(ts)
    .execute(&state.pool)
    .await?;
    Ok(StatusCode::NO_CONTENT)
}

// ---------- next (autoplay) ----------

#[derive(Deserialize)]
struct NextParams {
    after: i64,
    #[serde(default)]
    context: Option<String>,
}

/// The episode autoplay should move to. Recent context walks down the Recent
/// list (next-older unplayed across all shows); show context binges the same
/// show chronologically (next-newer unplayed).
async fn next_episode(
    State(state): State<AppState>,
    Query(p): Query<NextParams>,
) -> Result<Json<Option<EpisodeItem>>, AppError> {
    let cur: Option<(i64, i64)> =
        sqlx::query_as("SELECT published_at, podcast_id FROM episodes WHERE id = ?")
            .bind(p.after)
            .fetch_optional(&state.pool)
            .await?;
    let Some((published_at, podcast_id)) = cur else {
        return Err(AppError::NotFound);
    };
    let context = p.context.as_deref().unwrap_or("recent");
    let sql = match context {
        "show" => format!(
            "{EPISODE_ITEM_SELECT} WHERE s.played_at IS NULL AND s.archived_at IS NULL \
             AND e.podcast_id = ?3 AND (e.published_at > ?1 OR (e.published_at = ?1 AND e.id > ?2)) \
             ORDER BY e.published_at ASC, e.id ASC LIMIT 1"
        ),
        _ => format!(
            "{EPISODE_ITEM_SELECT} WHERE s.played_at IS NULL AND s.archived_at IS NULL \
             AND (e.published_at < ?1 OR (e.published_at = ?1 AND e.id < ?2)) AND ?3 = ?3 \
             ORDER BY e.published_at DESC, e.id DESC LIMIT 1"
        ),
    };
    let next = sqlx::query_as::<_, EpisodeItem>(&sql)
        .bind(published_at)
        .bind(p.after)
        .bind(podcast_id)
        .fetch_optional(&state.pool)
        .await?;
    Ok(Json(next))
}

// ---------- settings ----------

#[derive(Serialize, Deserialize)]
struct Settings {
    speed: f64,
    autoplay: bool,
}

async fn get_settings(State(state): State<AppState>) -> Result<Json<Settings>, AppError> {
    let rows: Vec<(String, String)> = sqlx::query_as("SELECT key, value FROM settings")
        .fetch_all(&state.pool)
        .await?;
    let mut s = Settings { speed: 1.0, autoplay: true };
    for (k, v) in rows {
        match k.as_str() {
            "speed" => s.speed = v.parse().unwrap_or(1.0),
            "autoplay" => s.autoplay = v != "false",
            _ => {}
        }
    }
    Ok(Json(s))
}

async fn put_settings(
    State(state): State<AppState>,
    Json(body): Json<Settings>,
) -> Result<StatusCode, AppError> {
    if !(0.5..=3.0).contains(&body.speed) {
        return Err(AppError::Invalid("speed must be between 0.5 and 3.0".into()));
    }
    for (k, v) in [("speed", body.speed.to_string()), ("autoplay", body.autoplay.to_string())] {
        sqlx::query("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value")
            .bind(k)
            .bind(v)
            .execute(&state.pool)
            .await?;
    }
    Ok(StatusCode::NO_CONTENT)
}

// ---------- refresh ----------

async fn refresh(State(state): State<AppState>) -> Json<serde_json::Value> {
    let (ok, errs) = feeds::refresh_all(&state).await;
    Json(serde_json::json!({ "refreshed": ok, "errors": errs }))
}

// ---------- search ----------

#[derive(Deserialize)]
struct SearchParams {
    q: String,
}

#[derive(Serialize)]
struct SearchResults {
    directory_configured: bool,
    podcasts: Vec<podcastindex::DirectoryPodcast>,
    episodes: Vec<EpisodeItem>,
}

/// Tokenized FTS5 prefix query: `dark kn` -> `"dark" "kn"*`
fn fts_query(q: &str) -> String {
    let tokens: Vec<String> = q
        .split_whitespace()
        .map(|t| format!("\"{}\"", t.replace('"', "\"\"")))
        .collect();
    match tokens.split_last() {
        Some((last, rest)) => {
            let mut parts: Vec<String> = rest.to_vec();
            parts.push(format!("{last}*"));
            parts.join(" ")
        }
        None => String::new(),
    }
}

async fn search(
    State(state): State<AppState>,
    Query(p): Query<SearchParams>,
) -> Result<Json<SearchResults>, AppError> {
    let q = p.q.trim();
    if q.is_empty() {
        return Err(AppError::Invalid("q must not be empty".into()));
    }

    let match_expr = fts_query(q);
    let sql = format!(
        "{EPISODE_ITEM_SELECT} WHERE e.id IN \
         (SELECT rowid FROM episodes_fts WHERE episodes_fts MATCH ? ORDER BY rank LIMIT 30) \
         ORDER BY e.published_at DESC"
    );
    let episodes = sqlx::query_as::<_, EpisodeItem>(&sql)
        .bind(&match_expr)
        .fetch_all(&state.pool)
        .await
        .unwrap_or_default();

    // Directory failures degrade to empty results rather than failing local search.
    let (directory_configured, mut podcasts) = match podcastindex::search(&state, q).await {
        Ok(Some(list)) => (true, list),
        Ok(None) => (false, Vec::new()),
        Err(e) => {
            tracing::warn!(error = %e, "podcast index search failed");
            (true, Vec::new())
        }
    };
    if !podcasts.is_empty() {
        let subscribed: std::collections::HashSet<String> =
            sqlx::query_scalar::<_, String>("SELECT feed_url FROM podcasts")
                .fetch_all(&state.pool)
                .await?
                .into_iter()
                .collect();
        for p in &mut podcasts {
            p.subscribed = subscribed.contains(&p.feed_url);
        }
    }

    Ok(Json(SearchResults { directory_configured, podcasts, episodes }))
}

// ---------- OPML ----------

async fn opml_export(State(state): State<AppState>) -> Result<impl axum::response::IntoResponse, AppError> {
    let items: Vec<(String, String)> =
        sqlx::query_as("SELECT title, feed_url FROM podcasts ORDER BY title COLLATE NOCASE")
            .fetch_all(&state.pool)
            .await?;
    Ok((
        [
            (axum::http::header::CONTENT_TYPE, "text/xml; charset=utf-8"),
            (
                axum::http::header::CONTENT_DISPOSITION,
                "attachment; filename=\"pods.opml\"",
            ),
        ],
        opml::render_opml(&items),
    ))
}

async fn opml_import(State(state): State<AppState>, body: String) -> Result<Json<serde_json::Value>, AppError> {
    let urls = opml::parse_opml(&body);
    if urls.is_empty() {
        return Err(AppError::Invalid("no feeds found in OPML".into()));
    }
    let (mut imported, mut skipped, mut failed) = (0, 0, 0);
    for url in urls {
        match feeds::subscribe(&state, &url).await {
            Ok(_) => imported += 1,
            Err(AppError::Conflict(_)) => skipped += 1,
            Err(e) => {
                tracing::warn!(url, error = %e, "opml import: feed failed");
                failed += 1;
            }
        }
    }
    Ok(Json(serde_json::json!({ "imported": imported, "skipped": skipped, "failed": failed })))
}

// ---------- router ----------

pub fn router(state: AppState) -> Router {
    let protected = Router::new()
        .route("/api/recent", get(recent))
        .route("/api/played", get(played))
        .route("/api/shows", get(shows).post(subscribe))
        .route("/api/shows/{id}", get(show_detail).delete(unsubscribe))
        .route("/api/episodes/{id}", get(episode_detail))
        .route("/api/episodes/{id}/played", post(set_played).delete(clear_played))
        .route("/api/episodes/{id}/position", put(set_position))
        .route("/api/settings", get(get_settings).put(put_settings))
        .route("/api/refresh", post(refresh))
        .route("/api/next", get(next_episode))
        .route("/api/search", get(search))
        .route("/api/opml", get(opml_export).post(opml_import))
        .route_layer(axum::middleware::from_fn_with_state(state.clone(), auth::require_bearer));

    Router::new()
        .route("/api/login", post(login))
        .merge(protected)
        .fallback(crate::assets::static_handler)
        .with_state(state)
}

#[cfg(test)]
mod tests {
    use super::fts_query;

    #[test]
    fn fts_query_quotes_and_prefixes() {
        assert_eq!(fts_query("dark kn"), "\"dark\" \"kn\"*");
        assert_eq!(fts_query("one"), "\"one\"*");
        assert_eq!(fts_query("say \"hi\""), "\"say\" \"\"\"hi\"\"\"*");
        assert_eq!(fts_query("  "), "");
    }
}
