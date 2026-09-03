pub fn is_episode_playback_active(episode_id: Option<i64>, paused: bool) -> bool {
    episode_id.is_some() && !paused
}

pub fn should_persist(
    position: f64,
    last_recorded_position: Option<f64>,
    force: bool,
    allow_regress: bool,
    stride_seconds: f64,
) -> bool {
    if !position.is_finite() || position < 0.0 {
        return false;
    }
    if let Some(last) = last_recorded_position.filter(|v| v.is_finite()) {
        if !allow_regress && position + 1.0 < last {
            return false;
        }
        if !force && (position - last).abs() < stride_seconds {
            return false;
        }
    }
    true
}

pub fn should_run_cast_keep_alive(preferred_output_is_mac: bool) -> bool {
    preferred_output_is_mac
}

pub fn is_mac_cast_selectable(available: bool, connected: bool) -> bool {
    available || connected
}

pub fn should_autoplay_mac_source_replacement(was_playing: bool, connected: bool) -> bool {
    was_playing && connected
}

pub fn should_pend_mac_play_after_connect(was_playing: bool, connected: bool, play_requested: bool) -> bool {
    if connected {
        return false;
    }
    was_playing || play_requested
}

pub fn mac_source_replacement_paused(was_playing: bool, pending_play_after_connect: bool) -> bool {
    !(was_playing || pending_play_after_connect)
}

pub fn should_reload_mac_source(source_failed: bool) -> bool {
    source_failed
}

pub fn accepts_episode_tagged_event(loaded_episode_id: Option<i64>, event_episode_id: Option<i64>) -> bool {
    match event_episode_id {
        None => true,
        Some(tagged) => loaded_episode_id == Some(tagged),
    }
}

pub fn is_positive_duration(value: f64) -> bool {
    value.is_finite() && value > 0.0
}
