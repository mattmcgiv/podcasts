use pods_backend::progress;
use pods_backend::range::{plan, StreamAuthorization};
use pods_backend::skip::*;
use std::collections::HashMap;

fn range(id: &str, start: f64, end: f64, disabled: bool) -> AdSkipRange {
    AdSkipRange {
        id: id.into(),
        start_segment_id: "s0".into(),
        end_segment_id: "s1".into(),
        start_time: start,
        end_time: end,
        confidence: 1.0,
        reason: "ad".into(),
        classifier_version: "v".into(),
        prompt_version: "p".into(),
        created_at: 1,
        disabled,
    }
}

#[test]
fn test_pure_skip_policy_uses_original_timeline_and_ignores_disabled_or_ended_ranges() {
    let ranges = vec![range("first", 10.0, 20.0, false), range("disabled", 30.0, 40.0, true)];
    let d = skip_decision(10.0, &ranges).unwrap();
    assert_eq!(d.range_id, "first");
    assert_eq!(skip_decision(19.999, &ranges).unwrap().target_position(), 20.0);
    assert!(skip_decision(20.0, &ranges).is_none());
    assert!(skip_decision(35.0, &ranges).is_none());
    assert!(skip_decision(9.999, &ranges).is_none());
}

#[test]
fn test_skip_session_keeps_one_pending_action_replaces_it_and_disables_undo_range() {
    let mut session = AdRemovalSkipSession::new(vec![range("first", 10.0, 20.0, false), range("second", 30.0, 45.0, false)]);
    let first = session.enter(12.0).unwrap();
    assert_eq!(first.range_id, "first");
    session.did_complete(first);
    assert_eq!(session.pending.as_ref().unwrap().skipped_duration(), 10.0);
    let second = session.enter(31.0).unwrap();
    assert_eq!(second.range_id, "second");
    assert_eq!(session.pending.as_ref().unwrap().range_id, "first");
    session.did_complete(second);
    assert_eq!(session.pending.as_ref().unwrap().range_id, "second");
    session.did_undo("second");
    assert!(session.pending.is_none());
    assert!(session.enter(31.0).is_none());
    assert_eq!(session.enter(12.0).unwrap().range_id, "first");
}

#[test]
fn test_mac_time_update_entering_enabled_range_produces_automatic_skip_decision() {
    let mut session = AdRemovalSkipSession::new(vec![range("opening-ad", 5.88, 129.3, false)]);
    assert!(session.enter_mac_transport_event("timeupdate", 5.87).is_none());
    assert_eq!(session.enter_mac_transport_event("timeupdate", 5.88).unwrap().range_id, "opening-ad");
    assert!(session.enter_mac_transport_event("pause", 6.0).is_none());
}

#[test]
fn test_mac_automatic_skip_suppresses_post_acknowledgement_stale_clock_and_deduplicates_range() {
    let decision = AdRemovalSkipDecision { range_id: "opening-ad".into(), range_start: 5.88, range_end: 129.3 };
    let mut state = AdRemovalMacSkipState::default();
    let _ = state.begin(decision.clone(), 7, 1000).unwrap();
    assert!(matches!(state.observe(6.0, 7), AdRemovalMacSkipClockObservation::Suppress));
    assert!(matches!(state.observe(200.0, 7), AdRemovalMacSkipClockObservation::Suppress));
    assert!(matches!(state.observe(129.3, 7), AdRemovalMacSkipClockObservation::Completed(_)));
    assert!(matches!(state.observe(6.5, 7), AdRemovalMacSkipClockObservation::Suppress));
    assert!(matches!(state.observe(129.5, 7), AdRemovalMacSkipClockObservation::PassThrough));
    assert!(matches!(state.observe(6.5, 7), AdRemovalMacSkipClockObservation::Suppress));
    assert!(state.begin(decision, 7, 1003).is_none());
}

#[test]
fn test_superseding_backward_mac_seek_fences_old_automatic_clocks_until_settled() {
    let mut fence = AdRemovalMacSupersedingSeekFence::new(5.88);
    assert_eq!(fence.observe(129.3), AdRemovalMacSupersedingSeekObservation::Suppress);
    assert_eq!(fence.observe(5.88), AdRemovalMacSupersedingSeekObservation::Acknowledged);
    assert_eq!(fence.observe(129.55), AdRemovalMacSupersedingSeekObservation::Suppress);
    assert_eq!(fence.observe(6.1), AdRemovalMacSupersedingSeekObservation::Settled);
}

#[test]
fn test_mac_automatic_skip_timeout_retries_without_a_clock_and_rejects_stale_callbacks() {
    let decision = AdRemovalSkipDecision { range_id: "ad".into(), range_start: 1.0, range_end: 10.0 };
    let mut state = AdRemovalMacSkipState::default();
    let attempt = state.begin(decision, 1, 0).unwrap();
    match state.retry(attempt.token, 1, 5, 3) {
        AdRemovalMacSkipRetryTransition::Retry(retry) => {
            assert_eq!(retry.attempt_number, 2);
            assert!(!state.accepts_delivery(attempt.token, 1));
            assert!(state.accepts_delivery(retry.token, 1));
        }
        other => panic!("{other:?}"),
    }
}

fn auth() -> StreamAuthorization {
    StreamAuthorization {
        episode_id: 42,
        file_path: "/tmp/episode.mp3".into(),
        byte_count: 100,
        token: "secret-token".into(),
        playback_session_id: "playback-session".into(),
    }
}

#[test]
fn test_only_authorized_active_episode_can_be_read() {
    let empty = HashMap::new();
    let authorization = auth();
    assert_eq!(plan("GET", "/episode/42?token=wrong", &empty, Some(&authorization)).status_code, 401);
    assert_eq!(plan("GET", "/episode/41?token=secret-token", &empty, Some(&authorization)).status_code, 404);
    assert_eq!(plan("GET", "/episode/42?token=secret-token", &empty, None).status_code, 401);
}

#[test]
fn test_full_get_and_head_expose_length_and_range_support() {
    let empty = HashMap::new();
    let authorization = auth();
    let get = plan("GET", "/episode/42?token=secret-token", &empty, Some(&authorization));
    assert_eq!(get.status_code, 200);
    assert_eq!(get.body_range, Some(0..100));
    assert_eq!(get.headers.get("Accept-Ranges").unwrap(), "bytes");
    let head = plan("HEAD", "/episode/42?token=secret-token", &empty, Some(&authorization));
    assert_eq!(head.status_code, 200);
    assert!(head.body_range.is_none());
}

#[test]
fn test_closed_open_and_suffix_ranges_use_rfc_byte_semantics() {
    let authorization = auth();
    let mut headers = HashMap::new();
    headers.insert("Range".into(), "bytes=10-19".into());
    assert_eq!(plan("GET", "/episode/42?token=secret-token", &headers, Some(&authorization)).body_range, Some(10..20));
    headers.insert("Range".into(), "bytes=90-".into());
    assert_eq!(plan("GET", "/episode/42?token=secret-token", &headers, Some(&authorization)).body_range, Some(90..100));
    headers.insert("Range".into(), "bytes=-10".into());
    assert_eq!(plan("GET", "/episode/42?token=secret-token", &headers, Some(&authorization)).body_range, Some(90..100));
}

#[test]
fn test_invalid_or_multiple_range_is_rejected_without_body() {
    let authorization = auth();
    let mut headers = HashMap::new();
    for value in ["items=0-1", "bytes=100-101", "bytes=20-10", "bytes=0-1,3-4"] {
        headers.insert("Range".into(), value.into());
        let response = plan("GET", "/episode/42?token=secret-token", &headers, Some(&authorization));
        assert_eq!(response.status_code, 416, "{value}");
        assert_eq!(response.headers.get("Content-Range").unwrap(), "bytes */100");
        assert!(response.body_range.is_none());
    }
}

#[test]
fn test_unsupported_method_is_rejected() {
    let empty = HashMap::new();
    let post = plan("POST", "/episode/42?token=secret-token", &empty, Some(&auth()));
    assert_eq!(post.status_code, 405);
    assert_eq!(post.headers.get("Allow").unwrap(), "GET, HEAD");
}

#[test]
fn test_range_planner_contracts() {
    let auth = StreamAuthorization {
        episode_id: 42,
        file_path: "/tmp/episode.mp3".into(),
        byte_count: 100,
        token: "secret-token".into(),
        playback_session_id: "playback-session".into(),
    };
    let empty = HashMap::new();
    assert_eq!(plan("GET", "/episode/42?token=wrong", &empty, Some(&auth)).status_code, 401);
    assert_eq!(plan("GET", "/episode/41?token=secret-token", &empty, Some(&auth)).status_code, 404);
    assert_eq!(plan("GET", "/episode/42?token=secret-token", &empty, None).status_code, 401);
    let get = plan("GET", "/episode/42?token=secret-token", &empty, Some(&auth));
    assert_eq!(get.status_code, 200);
    assert_eq!(get.body_range, Some(0..100));
    assert_eq!(get.headers.get("Accept-Ranges").unwrap(), "bytes");
    let head = plan("HEAD", "/episode/42?token=secret-token", &empty, Some(&auth));
    assert_eq!(head.status_code, 200);
    assert!(head.body_range.is_none());
    let mut headers = HashMap::new();
    headers.insert("Range".into(), "bytes=10-19".into());
    let closed = plan("GET", "/episode/42?token=secret-token", &headers, Some(&auth));
    assert_eq!(closed.status_code, 206);
    assert_eq!(closed.body_range, Some(10..20));
    headers.insert("Range".into(), "bytes=90-".into());
    assert_eq!(plan("GET", "/episode/42?token=secret-token", &headers, Some(&auth)).body_range, Some(90..100));
    headers.insert("Range".into(), "bytes=-10".into());
    assert_eq!(plan("GET", "/episode/42?token=secret-token", &headers, Some(&auth)).body_range, Some(90..100));
    for value in ["items=0-1", "bytes=100-101", "bytes=20-10", "bytes=0-1,3-4"] {
        headers.insert("Range".into(), value.into());
        let response = plan("GET", "/episode/42?token=secret-token", &headers, Some(&auth));
        assert_eq!(response.status_code, 416, "{value}");
        assert_eq!(response.headers.get("Content-Range").unwrap(), "bytes */100");
        assert!(response.body_range.is_none());
    }
    let post = plan("POST", "/episode/42?token=secret-token", &empty, Some(&auth));
    assert_eq!(post.status_code, 405);
    assert_eq!(post.headers.get("Allow").unwrap(), "GET, HEAD");
}

#[test]
fn test_playback_progress_policy_rejects_non_finite_and_regressions() {
    assert!(!progress::should_persist(f64::NAN, Some(10.0), false, false, 1.0));
    assert!(!progress::should_persist(-1.0, None, true, true, 1.0));
    assert!(!progress::should_persist(8.0, Some(10.0), false, false, 1.0));
    assert!(progress::should_persist(12.0, Some(10.0), false, false, 1.0));
    assert!(progress::is_positive_duration(1.0));
    assert!(!progress::is_positive_duration(0.0));
    assert!(progress::is_episode_playback_active(Some(1), false));
    assert!(!progress::is_episode_playback_active(Some(1), true));
    assert!(progress::should_run_cast_keep_alive(true));
    assert!(progress::is_mac_cast_selectable(true, false));
    assert!(progress::should_autoplay_mac_source_replacement(true, true));
    assert!(progress::should_pend_mac_play_after_connect(true, false, false));
    assert!(!progress::mac_source_replacement_paused(true, false));
    assert!(progress::should_reload_mac_source(true));
    assert!(progress::accepts_episode_tagged_event(Some(1), None));
    assert!(!progress::accepts_episode_tagged_event(Some(1), Some(2)));
}
