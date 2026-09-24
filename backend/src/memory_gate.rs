//! System memory gate for Mac inference.
//!
//! Defers Whisper spawn, TTS synthesis, and oMLX lock acquire when available
//! unified memory is low or macOS memory pressure is warn/critical. Does not
//! pause HTTP, sync, speaker, RSS, download, refine, or ffmpeg.
//!
//! Notification Center posts one pause banner and one resume banner per kind.
//! Repeats while that kind stays paused or resumed are suppressed, including
//! after a backend restart. Live `osascript` posts require
//! `PODS_MEMORY_GATE_NOTIFY=1` from `manage.py`.
//!
//! No new crates. libc is already pinned for flock(2).

use crate::error::Error;
use serde_json::{json, Value};
#[cfg(all(target_os = "macos", not(test)))]
use std::sync::{Mutex, OnceLock};

pub const MEMORY_BUSY: &str = "memory_busy";

const BUSY_RETRY_MIN_SECS: i64 = 60;
const BUSY_RETRY_SPAN: u64 = 61; // 60..=120 inclusive

const DEFAULT_WHISPER_DEFER: u64 = 8 * 1024 * 1024 * 1024;
const DEFAULT_WHISPER_RESUME: u64 = 10 * 1024 * 1024 * 1024;
const DEFAULT_OMLX_DEFER: u64 = 24 * 1024 * 1024 * 1024;
const DEFAULT_OMLX_RESUME: u64 = 32 * 1024 * 1024 * 1024;
// Kokoro-82M is far smaller than Whisper-large; thresholds scale with footprint.
const DEFAULT_TTS_DEFER: u64 = 4 * 1024 * 1024 * 1024;
const DEFAULT_TTS_RESUME: u64 = 6 * 1024 * 1024 * 1024;

#[cfg(all(target_os = "macos", not(test)))]
const PRESSURE_NORMAL: i32 = 0x01;
#[cfg(all(target_os = "macos", not(test)))]
const PRESSURE_WARN: i32 = 0x02;
#[cfg(all(target_os = "macos", not(test)))]
const PRESSURE_CRITICAL: i32 = 0x04;
#[cfg(all(target_os = "macos", not(test)))]
const MIG_ARRAY_TOO_LARGE: i32 = -307;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InferenceKind {
    Whisper,
    Omlx,
    Tts,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PressureLevel {
    Normal,
    Warn,
    Critical,
    Unknown,
}

impl PressureLevel {
    fn as_str(self) -> &'static str {
        match self {
            Self::Normal => "normal",
            Self::Warn => "warn",
            Self::Critical => "critical",
            Self::Unknown => "unknown",
        }
    }

    #[cfg(all(target_os = "macos", not(test)))]
    fn from_sysctl(value: i32) -> Self {
        match value {
            PRESSURE_NORMAL => Self::Normal,
            PRESSURE_WARN => Self::Warn,
            PRESSURE_CRITICAL => Self::Critical,
            _ => Self::Unknown,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GateState {
    Open,
    Deferred,
    Disabled,
}

impl GateState {
    fn as_str(self) -> &'static str {
        match self {
            Self::Open => "open",
            Self::Deferred => "deferred",
            Self::Disabled => "disabled",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MemorySnapshot {
    pub available_bytes: u64,
    pub total_bytes: u64,
    pub pressure: PressureLevel,
    pub sampled_at: i64,
    pub sample_failed: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KindDecision {
    pub state: GateState,
    pub last_reason: Option<&'static str>,
    pub defer_below_bytes: u64,
    pub resume_above_bytes: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MemoryReport {
    pub enabled: bool,
    pub snapshot: MemorySnapshot,
    pub whisper: KindDecision,
    pub omlx: KindDecision,
    pub tts: KindDecision,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct GateConfig {
    pub enabled: bool,
    pub whisper_defer_below_bytes: u64,
    pub whisper_resume_above_bytes: u64,
    pub omlx_defer_below_bytes: u64,
    pub omlx_resume_above_bytes: u64,
    pub tts_defer_below_bytes: u64,
    pub tts_resume_above_bytes: u64,
}

impl GateConfig {
    fn defaults() -> Self {
        Self {
            enabled: true,
            whisper_defer_below_bytes: DEFAULT_WHISPER_DEFER,
            whisper_resume_above_bytes: DEFAULT_WHISPER_RESUME,
            omlx_defer_below_bytes: DEFAULT_OMLX_DEFER,
            omlx_resume_above_bytes: DEFAULT_OMLX_RESUME,
            tts_defer_below_bytes: DEFAULT_TTS_DEFER,
            tts_resume_above_bytes: DEFAULT_TTS_RESUME,
        }
    }

    fn pair(self, kind: InferenceKind) -> (u64, u64) {
        match kind {
            InferenceKind::Whisper => (
                self.whisper_defer_below_bytes,
                self.whisper_resume_above_bytes,
            ),
            InferenceKind::Omlx => (self.omlx_defer_below_bytes, self.omlx_resume_above_bytes),
            InferenceKind::Tts => (self.tts_defer_below_bytes, self.tts_resume_above_bytes),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct KindStates {
    whisper: GateState,
    omlx: GateState,
    tts: GateState,
}

impl KindStates {
    const fn open() -> Self {
        Self {
            whisper: GateState::Open,
            omlx: GateState::Open,
            tts: GateState::Open,
        }
    }

    fn get(self, kind: InferenceKind) -> GateState {
        match kind {
            InferenceKind::Whisper => self.whisper,
            InferenceKind::Omlx => self.omlx,
            InferenceKind::Tts => self.tts,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct PostedStates {
    whisper: Option<GateState>,
    omlx: Option<GateState>,
    tts: Option<GateState>,
}

impl PostedStates {
    const fn empty() -> Self {
        Self {
            whisper: None,
            omlx: None,
            tts: None,
        }
    }

    fn get(self, kind: InferenceKind) -> Option<GateState> {
        match kind {
            InferenceKind::Whisper => self.whisper,
            InferenceKind::Omlx => self.omlx,
            InferenceKind::Tts => self.tts,
        }
    }

    fn set(&mut self, kind: InferenceKind, state: GateState) {
        match kind {
            InferenceKind::Whisper => self.whisper = Some(state),
            InferenceKind::Omlx => self.omlx = Some(state),
            InferenceKind::Tts => self.tts = Some(state),
        }
    }
}

fn apply_posted_to_states(states: &mut KindStates, posted: PostedStates) {
    if let Some(state) = posted.whisper {
        if state != GateState::Disabled {
            states.whisper = state;
        }
    }
    if let Some(state) = posted.omlx {
        if state != GateState::Disabled {
            states.omlx = state;
        }
    }
    if let Some(state) = posted.tts {
        if state != GateState::Disabled {
            states.tts = state;
        }
    }
}

#[cfg(all(target_os = "macos", not(test)))]
struct ProductionGate {
    states: KindStates,
    posted: PostedStates,
    persist_loaded: bool,
}

#[cfg(all(target_os = "macos", not(test)))]
static PRODUCTION_STATES: Mutex<ProductionGate> = Mutex::new(ProductionGate {
    states: KindStates::open(),
    posted: PostedStates::empty(),
    persist_loaded: false,
});

pub fn parse_gate_config(
    gate: Option<&str>,
    whisper_defer: Option<&str>,
    whisper_resume: Option<&str>,
    omlx_defer: Option<&str>,
    omlx_resume: Option<&str>,
    tts_defer: Option<&str>,
    tts_resume: Option<&str>,
) -> GateConfig {
    let mut config = GateConfig::defaults();
    if let Some(value) = gate {
        config.enabled = value != "0";
    }
    parse_bytes(whisper_defer, &mut config.whisper_defer_below_bytes);
    parse_bytes(whisper_resume, &mut config.whisper_resume_above_bytes);
    parse_bytes(omlx_defer, &mut config.omlx_defer_below_bytes);
    parse_bytes(omlx_resume, &mut config.omlx_resume_above_bytes);
    parse_bytes(tts_defer, &mut config.tts_defer_below_bytes);
    parse_bytes(tts_resume, &mut config.tts_resume_above_bytes);
    if config.whisper_resume_above_bytes < config.whisper_defer_below_bytes {
        config.whisper_resume_above_bytes = config.whisper_defer_below_bytes;
    }
    if config.omlx_resume_above_bytes < config.omlx_defer_below_bytes {
        config.omlx_resume_above_bytes = config.omlx_defer_below_bytes;
    }
    if config.tts_resume_above_bytes < config.tts_defer_below_bytes {
        config.tts_resume_above_bytes = config.tts_defer_below_bytes;
    }
    config
}

fn parse_bytes(raw: Option<&str>, dest: &mut u64) {
    let Some(text) = raw else {
        return;
    };
    if text.is_empty() {
        eprintln!("memory gate: empty byte override, using default");
        return;
    }
    match text.parse::<u64>() {
        Ok(value) => *dest = value,
        Err(_) => eprintln!("memory gate: invalid byte override, using default"),
    }
}

fn config_from_env() -> GateConfig {
    parse_gate_config(
        std::env::var("PODS_MEMORY_GATE").ok().as_deref(),
        std::env::var("PODS_MEMORY_WHISPER_DEFER_BELOW_BYTES")
            .ok()
            .as_deref(),
        std::env::var("PODS_MEMORY_WHISPER_RESUME_ABOVE_BYTES")
            .ok()
            .as_deref(),
        std::env::var("PODS_MEMORY_OMLX_DEFER_BELOW_BYTES")
            .ok()
            .as_deref(),
        std::env::var("PODS_MEMORY_OMLX_RESUME_ABOVE_BYTES")
            .ok()
            .as_deref(),
        std::env::var("PODS_MEMORY_TTS_DEFER_BELOW_BYTES")
            .ok()
            .as_deref(),
        std::env::var("PODS_MEMORY_TTS_RESUME_ABOVE_BYTES")
            .ok()
            .as_deref(),
    )
}

pub fn available_from_counts(
    free_count: u32,
    speculative_count: u32,
    external_page_count: u32,
    page_size: u64,
) -> u64 {
    let free_pages = free_count.saturating_sub(speculative_count) as u64;
    (free_pages + u64::from(external_page_count)).saturating_mul(page_size)
}

pub fn busy_retry_delay_secs(episode_id: i64) -> i64 {
    BUSY_RETRY_MIN_SECS + (mix_u64(episode_id as u64) % BUSY_RETRY_SPAN) as i64
}

pub fn is_busy_error(error: &Error) -> bool {
    error.to_string() == MEMORY_BUSY
}

pub fn require_inference(kind: InferenceKind) -> Result<(), Error> {
    let report = evaluate();
    let decision = match kind {
        InferenceKind::Whisper => &report.whisper,
        InferenceKind::Omlx => &report.omlx,
        InferenceKind::Tts => &report.tts,
    };
    if decision.state == GateState::Deferred {
        return Err(Error::Upstream(MEMORY_BUSY.into()));
    }
    Ok(())
}

pub fn should_preempt_whisper() -> bool {
    let report = evaluate();
    report.enabled
        && matches!(
            report.snapshot.pressure,
            PressureLevel::Warn | PressureLevel::Critical
        )
}

pub fn status_json() -> Value {
    let report = evaluate();
    json!({
        "enabled": report.enabled,
        "pressure": report.snapshot.pressure.as_str(),
        "available_bytes": report.snapshot.available_bytes,
        "total_bytes": report.snapshot.total_bytes,
        "sampled_at": report.snapshot.sampled_at,
        "whisper": kind_json(&report.whisper),
        "omlx": kind_json(&report.omlx),
        "tts": kind_json(&report.tts),
    })
}

fn kind_json(decision: &KindDecision) -> Value {
    json!({
        "gate": decision.state.as_str(),
        "defer_below_bytes": decision.defer_below_bytes,
        "resume_above_bytes": decision.resume_above_bytes,
        "last_reason": decision.last_reason,
    })
}

pub fn evaluate() -> MemoryReport {
    #[cfg(test)]
    {
        if let Some(report) = evaluate_injected() {
            return report;
        }
        return disabled_report(config_from_env(), empty_snapshot());
    }
    #[cfg(not(test))]
    {
        let config = config_from_env();
        #[cfg(not(target_os = "macos"))]
        {
            return disabled_report(config, empty_snapshot());
        }
        #[cfg(target_os = "macos")]
        {
            let snapshot = sample_live();
            let mut gate = PRODUCTION_STATES.lock().unwrap_or_else(|e| e.into_inner());
            if !gate.persist_loaded {
                let posted = load_posted();
                apply_posted_to_states(&mut gate.states, posted);
                gate.posted = posted;
                gate.persist_loaded = true;
            }
            let gate = &mut *gate;
            apply_with_states(config, snapshot, &mut gate.states, &mut gate.posted)
        }
    }
}

#[cfg(any(test, not(target_os = "macos")))]
fn empty_snapshot() -> MemorySnapshot {
    MemorySnapshot {
        available_bytes: 0,
        total_bytes: 0,
        pressure: PressureLevel::Unknown,
        sampled_at: crate::db::now_unix(),
        sample_failed: false,
    }
}

fn disabled_report(config: GateConfig, snapshot: MemorySnapshot) -> MemoryReport {
    MemoryReport {
        enabled: false,
        snapshot,
        whisper: KindDecision {
            state: GateState::Disabled,
            last_reason: None,
            defer_below_bytes: config.whisper_defer_below_bytes,
            resume_above_bytes: config.whisper_resume_above_bytes,
        },
        omlx: KindDecision {
            state: GateState::Disabled,
            last_reason: None,
            defer_below_bytes: config.omlx_defer_below_bytes,
            resume_above_bytes: config.omlx_resume_above_bytes,
        },
        tts: KindDecision {
            state: GateState::Disabled,
            last_reason: None,
            defer_below_bytes: config.tts_defer_below_bytes,
            resume_above_bytes: config.tts_resume_above_bytes,
        },
    }
}

fn apply_with_states(
    config: GateConfig,
    snapshot: MemorySnapshot,
    states: &mut KindStates,
    posted: &mut PostedStates,
) -> MemoryReport {
    if !config.enabled {
        *states = KindStates {
            whisper: GateState::Disabled,
            omlx: GateState::Disabled,
            tts: GateState::Disabled,
        };
        return disabled_report(config, snapshot);
    }
    let whisper = decide_kind(
        InferenceKind::Whisper,
        config,
        &snapshot,
        states.get(InferenceKind::Whisper),
    );
    let omlx = decide_kind(
        InferenceKind::Omlx,
        config,
        &snapshot,
        states.get(InferenceKind::Omlx),
    );
    let tts = decide_kind(
        InferenceKind::Tts,
        config,
        &snapshot,
        states.get(InferenceKind::Tts),
    );
    announce_transition(
        InferenceKind::Whisper,
        whisper.state,
        &snapshot,
        whisper.last_reason,
        posted,
    );
    announce_transition(
        InferenceKind::Omlx,
        omlx.state,
        &snapshot,
        omlx.last_reason,
        posted,
    );
    announce_transition(
        InferenceKind::Tts,
        tts.state,
        &snapshot,
        tts.last_reason,
        posted,
    );
    states.whisper = whisper.state;
    states.omlx = omlx.state;
    states.tts = tts.state;
    MemoryReport {
        enabled: true,
        snapshot,
        whisper,
        omlx,
        tts,
    }
}

fn decide_kind(
    kind: InferenceKind,
    config: GateConfig,
    snapshot: &MemorySnapshot,
    previous: GateState,
) -> KindDecision {
    let (defer, resume) = config.pair(kind);
    let previous = if previous == GateState::Disabled {
        GateState::Open
    } else {
        previous
    };
    let (state, last_reason) = if snapshot.sample_failed {
        (GateState::Deferred, Some("sample_failed"))
    } else if snapshot.pressure == PressureLevel::Warn {
        (GateState::Deferred, Some("pressure_warn"))
    } else if snapshot.pressure == PressureLevel::Critical {
        (GateState::Deferred, Some("pressure_critical"))
    } else if snapshot.available_bytes < defer {
        (GateState::Deferred, Some("available_below_threshold"))
    } else if previous == GateState::Deferred {
        if snapshot.available_bytes >= resume
            && matches!(
                snapshot.pressure,
                PressureLevel::Normal | PressureLevel::Unknown
            )
        {
            (GateState::Open, None)
        } else {
            (GateState::Deferred, Some("hysteresis"))
        }
    } else {
        (GateState::Open, None)
    };
    KindDecision {
        state,
        last_reason,
        defer_below_bytes: defer,
        resume_above_bytes: resume,
    }
}

fn announce_transition(
    kind: InferenceKind,
    next: GateState,
    snapshot: &MemorySnapshot,
    reason: Option<&str>,
    posted: &mut PostedStates,
) {
    if next == GateState::Disabled {
        return;
    }
    if posted.get(kind) == Some(next) {
        return;
    }
    let label = match kind {
        InferenceKind::Whisper => "whisper",
        InferenceKind::Omlx => "omlx",
        InferenceKind::Tts => "tts",
    };
    let from = posted.get(kind).unwrap_or(GateState::Open);
    if next == GateState::Deferred {
        eprintln!(
            "memory gate {label} deferred: available_bytes={} pressure={} reason={}",
            snapshot.available_bytes,
            snapshot.pressure.as_str(),
            reason.unwrap_or("unknown")
        );
    } else if next == GateState::Open && from == GateState::Deferred {
        eprintln!(
            "memory gate {label} open: available_bytes={} pressure={}",
            snapshot.available_bytes,
            snapshot.pressure.as_str()
        );
    }
    if let Some(body) = notification_copy(kind, from, next, reason) {
        post_notification(&body);
    }
    posted.set(kind, next);
    persist_posted(*posted);
}

fn work_name(kind: InferenceKind) -> &'static str {
    match kind {
        InferenceKind::Whisper => "Transcription",
        InferenceKind::Omlx => "Classification",
        InferenceKind::Tts => "Speech synthesis",
    }
}

fn pause_cause(reason: Option<&str>) -> Option<&'static str> {
    match reason {
        Some("available_below_threshold") => Some("low memory"),
        Some("pressure_warn") => Some("warning-level memory pressure"),
        Some("pressure_critical") => Some("critical memory pressure"),
        Some("sample_failed") => Some("a memory sample failure"),
        _ => None,
    }
}

fn notification_copy(
    kind: InferenceKind,
    previous: GateState,
    next: GateState,
    reason: Option<&str>,
) -> Option<String> {
    if previous == next || previous == GateState::Disabled {
        return None;
    }
    let x = work_name(kind);
    match next {
        GateState::Deferred => {
            let y = pause_cause(reason)?;
            Some(format!("{x} paused due to {y}"))
        }
        GateState::Open => Some(format!("{x} resumed due to available memory")),
        GateState::Disabled => None,
    }
}

#[cfg(all(target_os = "macos", not(test)))]
fn applescript_literal(value: &str) -> String {
    format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
}

fn post_notification(body: &str) {
    #[cfg(test)]
    {
        TEST_NOTIFICATIONS.with(|cell| cell.borrow_mut().push(body.to_string()));
    }
    #[cfg(all(target_os = "macos", not(test)))]
    {
        if std::env::var("PODS_MEMORY_GATE_NOTIFY").ok().as_deref() != Some("1") {
            return;
        }
        let script = format!(
            "display notification {} with title {}",
            applescript_literal(body),
            applescript_literal("Pods")
        );
        let _ = std::process::Command::new("/usr/bin/osascript")
            .arg("-e")
            .arg(script)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
    }
    #[cfg(all(not(test), not(target_os = "macos")))]
    {
        let _ = body;
    }
}

fn format_posted(posted: PostedStates) -> String {
    let mut lines = String::new();
    for kind in [InferenceKind::Whisper, InferenceKind::Omlx, InferenceKind::Tts] {
        let Some(state) = posted.get(kind) else {
            continue;
        };
        if state == GateState::Disabled {
            continue;
        }
        let label = match kind {
            InferenceKind::Whisper => "whisper",
            InferenceKind::Omlx => "omlx",
            InferenceKind::Tts => "tts",
        };
        lines.push_str(label);
        lines.push('=');
        lines.push_str(state.as_str());
        lines.push('\n');
    }
    lines
}

fn parse_posted(text: &str) -> PostedStates {
    let mut posted = PostedStates::empty();
    for line in text.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let state = match value.trim() {
            "open" => GateState::Open,
            "deferred" => GateState::Deferred,
            _ => continue,
        };
        match key.trim() {
            "whisper" => posted.whisper = Some(state),
            "omlx" => posted.omlx = Some(state),
            "tts" => posted.tts = Some(state),
            _ => {}
        }
    }
    posted
}

fn persist_posted(posted: PostedStates) {
    #[cfg(all(target_os = "macos", not(test)))]
    {
        if std::env::var("PODS_MEMORY_GATE_NOTIFY").ok().as_deref() != Some("1") {
            return;
        }
        let Some(path) = notify_state_path() else {
            return;
        };
        let tmp = path.with_extension("tmp");
        if std::fs::write(&tmp, format_posted(posted)).is_ok() {
            let _ = std::fs::rename(&tmp, path);
        }
    }
    #[cfg(not(all(target_os = "macos", not(test))))]
    {
        let _ = posted;
    }
}

#[cfg(all(target_os = "macos", not(test)))]
fn load_posted() -> PostedStates {
    let Some(path) = notify_state_path() else {
        return PostedStates::empty();
    };
    match std::fs::read_to_string(path) {
        Ok(text) => parse_posted(&text),
        Err(_) => PostedStates::empty(),
    }
}

#[cfg(all(target_os = "macos", not(test)))]
fn notify_state_path() -> Option<std::path::PathBuf> {
    let dir = std::env::var_os("PODS_STATE_DIR")?;
    if dir.is_empty() {
        return None;
    }
    Some(std::path::PathBuf::from(dir).join("memory-gate-notify"))
}

fn mix_u64(mut z: u64) -> u64 {
    z = z.wrapping_add(0x9E3779B97F4A7C15);
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
    z ^ (z >> 31)
}

#[cfg(all(target_os = "macos", not(test)))]
fn sample_live() -> MemorySnapshot {
    let page_size = page_size_bytes();
    let total_bytes = sysctl_u64("hw.memsize").unwrap_or(0);
    let pressure = sysctl_i32("kern.memorystatus_vm_pressure_level")
        .map(PressureLevel::from_sysctl)
        .unwrap_or(PressureLevel::Unknown);
    match vm_available_bytes(page_size) {
        Ok(available_bytes) => MemorySnapshot {
            available_bytes,
            total_bytes,
            pressure,
            sampled_at: crate::db::now_unix(),
            sample_failed: false,
        },
        Err((kern_return, count)) => {
            eprintln!("memory gate sample_failed: kern_return={kern_return} count={count}");
            MemorySnapshot {
                available_bytes: 0,
                total_bytes,
                pressure,
                sampled_at: crate::db::now_unix(),
                sample_failed: true,
            }
        }
    }
}

#[cfg(all(target_os = "macos", not(test)))]
fn page_size_bytes() -> u64 {
    static PAGE_SIZE: OnceLock<u64> = OnceLock::new();
    *PAGE_SIZE.get_or_init(|| {
        sysctl_u64("hw.pagesize").unwrap_or_else(|| unsafe { libc::vm_page_size as u64 })
    })
}

#[cfg(all(target_os = "macos", not(test)))]
fn host_port() -> libc::mach_port_t {
    static HOST: OnceLock<libc::mach_port_t> = OnceLock::new();
    *HOST.get_or_init(|| {
        #[allow(deprecated)]
        unsafe {
            libc::mach_host_self()
        }
    })
}

#[cfg(all(target_os = "macos", not(test)))]
fn vm_available_bytes(page_size: u64) -> Result<u64, (libc::kern_return_t, u32)> {
    let host = host_port();
    let mut stats = unsafe { std::mem::zeroed::<libc::vm_statistics64>() };
    let mut count = libc::HOST_VM_INFO64_COUNT;
    let kr = unsafe {
        libc::host_statistics64(
            host,
            libc::HOST_VM_INFO64,
            (&mut stats as *mut libc::vm_statistics64).cast(),
            &mut count,
        )
    };
    if kr == libc::KERN_SUCCESS {
        return Ok(available_from_vm(&stats, count, page_size));
    }
    if kr != MIG_ARRAY_TOO_LARGE && count <= libc::HOST_VM_INFO64_COUNT {
        return Err((kr, count));
    }
    let n = (count as usize).max(libc::HOST_VM_INFO64_COUNT as usize + 32);
    let mut buf = vec![0i32; n];
    let mut retry_count = n as libc::mach_msg_type_number_t;
    let retry_kr = unsafe {
        libc::host_statistics64(
            host,
            libc::HOST_VM_INFO64,
            buf.as_mut_ptr(),
            &mut retry_count,
        )
    };
    if retry_kr != libc::KERN_SUCCESS {
        return Err((retry_kr, retry_count));
    }
    let copy = (retry_count as usize)
        .saturating_mul(std::mem::size_of::<libc::integer_t>())
        .min(std::mem::size_of::<libc::vm_statistics64>());
    unsafe {
        std::ptr::copy_nonoverlapping(
            buf.as_ptr().cast::<u8>(),
            (&mut stats as *mut libc::vm_statistics64).cast::<u8>(),
            copy,
        );
    }
    Ok(available_from_vm(&stats, retry_count, page_size))
}

#[cfg(all(target_os = "macos", not(test)))]
fn available_from_vm(stats: &libc::vm_statistics64, count: u32, page_size: u64) -> u64 {
    let filled = (count as usize).saturating_mul(std::mem::size_of::<libc::integer_t>());
    let external_offset = std::mem::offset_of!(libc::vm_statistics64, external_page_count);
    let external = if filled > external_offset {
        stats.external_page_count
    } else {
        0
    };
    available_from_counts(
        stats.free_count,
        stats.speculative_count,
        external,
        page_size,
    )
}

#[cfg(all(target_os = "macos", not(test)))]
fn sysctl_u64(name: &str) -> Option<u64> {
    let c_name = std::ffi::CString::new(name).ok()?;
    let mut value: u64 = 0;
    let mut len = std::mem::size_of::<u64>();
    let rc = unsafe {
        libc::sysctlbyname(
            c_name.as_ptr(),
            (&mut value as *mut u64).cast(),
            &mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    if rc == 0 {
        Some(value)
    } else {
        None
    }
}

#[cfg(all(target_os = "macos", not(test)))]
fn sysctl_i32(name: &str) -> Option<i32> {
    let c_name = std::ffi::CString::new(name).ok()?;
    let mut value: i32 = 0;
    let mut len = std::mem::size_of::<i32>();
    let rc = unsafe {
        libc::sysctlbyname(
            c_name.as_ptr(),
            (&mut value as *mut i32).cast(),
            &mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    if rc == 0 {
        Some(value)
    } else {
        None
    }
}

#[cfg(test)]
#[derive(Clone)]
struct TestInject {
    snapshot: MemorySnapshot,
    config: GateConfig,
    states: KindStates,
    posted: PostedStates,
}

#[cfg(test)]
std::thread_local! {
    static TEST_INJECT: std::cell::RefCell<Option<TestInject>> =
        const { std::cell::RefCell::new(None) };
    static TEST_NOTIFICATIONS: std::cell::RefCell<Vec<String>> =
        const { std::cell::RefCell::new(Vec::new()) };
}

#[cfg(test)]
pub struct TestMemory {
    pub snapshot: MemorySnapshot,
    pub enabled: bool,
    pub whisper_defer_below_bytes: u64,
    pub whisper_resume_above_bytes: u64,
    pub omlx_defer_below_bytes: u64,
    pub omlx_resume_above_bytes: u64,
    pub tts_defer_below_bytes: u64,
    pub tts_resume_above_bytes: u64,
}

#[cfg(test)]
impl Default for TestMemory {
    fn default() -> Self {
        let config = GateConfig::defaults();
        Self {
            snapshot: MemorySnapshot {
                available_bytes: config.whisper_resume_above_bytes,
                total_bytes: 128 * 1024 * 1024 * 1024,
                pressure: PressureLevel::Normal,
                sampled_at: 0,
                sample_failed: false,
            },
            enabled: true,
            whisper_defer_below_bytes: config.whisper_defer_below_bytes,
            whisper_resume_above_bytes: config.whisper_resume_above_bytes,
            omlx_defer_below_bytes: config.omlx_defer_below_bytes,
            omlx_resume_above_bytes: config.omlx_resume_above_bytes,
            tts_defer_below_bytes: config.tts_defer_below_bytes,
            tts_resume_above_bytes: config.tts_resume_above_bytes,
        }
    }
}

#[cfg(test)]
pub fn with_test_memory<R>(cfg: TestMemory, f: impl FnOnce() -> R) -> R {
    struct Reset;
    impl Drop for Reset {
        fn drop(&mut self) {
            TEST_INJECT.with(|cell| *cell.borrow_mut() = None);
            TEST_NOTIFICATIONS.with(|cell| cell.borrow_mut().clear());
        }
    }
    let _reset = Reset;
    TEST_INJECT.with(|cell| {
        *cell.borrow_mut() = Some(TestInject {
            snapshot: cfg.snapshot,
            config: GateConfig {
                enabled: cfg.enabled,
                whisper_defer_below_bytes: cfg.whisper_defer_below_bytes,
                whisper_resume_above_bytes: cfg.whisper_resume_above_bytes,
                omlx_defer_below_bytes: cfg.omlx_defer_below_bytes,
                omlx_resume_above_bytes: cfg.omlx_resume_above_bytes,
                tts_defer_below_bytes: cfg.tts_defer_below_bytes,
                tts_resume_above_bytes: cfg.tts_resume_above_bytes,
            },
            states: KindStates::open(),
            posted: PostedStates::empty(),
        });
        TEST_NOTIFICATIONS.with(|cell| cell.borrow_mut().clear());
    });
    f()
}

#[cfg(test)]
pub fn set_test_snapshot(snapshot: MemorySnapshot) {
    TEST_INJECT.with(|cell| {
        if let Some(inject) = cell.borrow_mut().as_mut() {
            inject.snapshot = snapshot;
        }
    });
}

#[cfg(test)]
fn set_test_states_open() {
    TEST_INJECT.with(|cell| {
        if let Some(inject) = cell.borrow_mut().as_mut() {
            inject.states = KindStates::open();
        }
    });
}

#[cfg(test)]
fn simulate_test_restart() {
    TEST_INJECT.with(|cell| {
        if let Some(inject) = cell.borrow_mut().as_mut() {
            inject.states = KindStates::open();
            apply_posted_to_states(&mut inject.states, inject.posted);
        }
    });
}

#[cfg(test)]
fn evaluate_injected() -> Option<MemoryReport> {
    TEST_INJECT.with(|cell| {
        let mut inject = cell.borrow_mut();
        let inject = inject.as_mut()?;
        Some(apply_with_states(
            inject.config,
            inject.snapshot.clone(),
            &mut inject.states,
            &mut inject.posted,
        ))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gib(n: u64) -> u64 {
        n * 1024 * 1024 * 1024
    }

    fn snap(available: u64, pressure: PressureLevel, failed: bool) -> MemorySnapshot {
        MemorySnapshot {
            available_bytes: available,
            total_bytes: gib(128),
            pressure,
            sampled_at: 1,
            sample_failed: failed,
        }
    }

    #[test]
    fn available_formula_clamps_speculative_and_omits_compressor() {
        let page = 16384;
        assert_eq!(available_from_counts(10, 2, 4, page), (8 + 4) * page);
        assert_eq!(available_from_counts(2, 10, 4, page), 4 * page);
        assert_eq!(available_from_counts(10, 0, 0, page), 10 * page);
    }

    #[test]
    fn pressure_warn_defers_all_kinds_at_32_gib() {
        with_test_memory(
            TestMemory {
                snapshot: snap(gib(32), PressureLevel::Warn, false),
                ..TestMemory::default()
            },
            || {
                assert!(require_inference(InferenceKind::Whisper).is_err());
                assert!(require_inference(InferenceKind::Omlx).is_err());
                assert!(require_inference(InferenceKind::Tts).is_err());
                let report = evaluate();
                assert_eq!(report.whisper.state, GateState::Deferred);
                assert_eq!(report.omlx.state, GateState::Deferred);
                assert_eq!(report.tts.state, GateState::Deferred);
                assert_eq!(report.whisper.last_reason, Some("pressure_warn"));
                assert!(should_preempt_whisper());
            },
        );
    }

    #[test]
    fn unknown_pressure_and_plenty_of_ram_is_open() {
        with_test_memory(
            TestMemory {
                snapshot: snap(gib(32), PressureLevel::Unknown, false),
                ..TestMemory::default()
            },
            || {
                require_inference(InferenceKind::Whisper).unwrap();
                require_inference(InferenceKind::Omlx).unwrap();
                assert!(!should_preempt_whisper());
            },
        );
    }

    #[test]
    fn hysteresis_uses_set_test_snapshot_inside_one_guard() {
        with_test_memory(
            TestMemory {
                snapshot: snap(gib(7), PressureLevel::Normal, false),
                ..TestMemory::default()
            },
            || {
                assert_eq!(evaluate().whisper.state, GateState::Deferred);
                set_test_snapshot(snap(gib(9), PressureLevel::Normal, false));
                let mid = evaluate();
                assert_eq!(mid.whisper.state, GateState::Deferred);
                assert_eq!(mid.whisper.last_reason, Some("hysteresis"));
                assert_eq!(mid.omlx.state, GateState::Deferred);
                set_test_snapshot(snap(gib(12), PressureLevel::Normal, false));
                let whisper_open = evaluate();
                assert_eq!(whisper_open.whisper.state, GateState::Open);
                assert_eq!(whisper_open.omlx.state, GateState::Deferred);
                set_test_snapshot(snap(gib(32), PressureLevel::Normal, false));
                assert_eq!(evaluate().omlx.state, GateState::Open);
            },
        );
    }

    #[test]
    fn sample_failed_defers_starts_and_does_not_preempt() {
        with_test_memory(
            TestMemory {
                snapshot: snap(gib(32), PressureLevel::Normal, true),
                ..TestMemory::default()
            },
            || {
                assert!(require_inference(InferenceKind::Whisper).is_err());
                assert!(require_inference(InferenceKind::Omlx).is_err());
                assert!(!should_preempt_whisper());
                assert_eq!(evaluate().whisper.last_reason, Some("sample_failed"));
            },
        );
    }

    #[test]
    fn disabled_gate_is_open_and_last_reason_is_null() {
        with_test_memory(
            TestMemory {
                snapshot: snap(gib(7), PressureLevel::Warn, false),
                enabled: false,
                ..TestMemory::default()
            },
            || {
                require_inference(InferenceKind::Whisper).unwrap();
                require_inference(InferenceKind::Omlx).unwrap();
                assert!(!should_preempt_whisper());
                let json = status_json();
                assert_eq!(json["enabled"], false);
                assert_eq!(json["whisper"]["gate"], "disabled");
                assert!(json["whisper"]["last_reason"].is_null());
                assert!(json["omlx"]["last_reason"].is_null());
            },
        );
    }

    #[test]
    fn parse_gate_config_defaults_and_clamps_resume() {
        let parsed = parse_gate_config(None, None, None, None, None, None, None);
        assert!(parsed.enabled);
        assert_eq!(parsed.whisper_defer_below_bytes, DEFAULT_WHISPER_DEFER);
        assert_eq!(parsed.tts_defer_below_bytes, DEFAULT_TTS_DEFER);
        let invalid = parse_gate_config(Some("0"), Some("nope"), Some(""), Some("3"), Some("1"), Some("5"), Some("2"));
        assert!(!invalid.enabled);
        assert_eq!(invalid.whisper_defer_below_bytes, DEFAULT_WHISPER_DEFER);
        assert_eq!(invalid.omlx_defer_below_bytes, 3);
        assert_eq!(invalid.omlx_resume_above_bytes, 3);
        assert_eq!(invalid.tts_defer_below_bytes, 5);
        assert_eq!(invalid.tts_resume_above_bytes, 5);
    }

    #[test]
    fn busy_retry_stays_in_range_and_spreads() {
        let delays: Vec<i64> = (1..201).map(busy_retry_delay_secs).collect();
        assert!(delays.iter().all(|d| (60..=120).contains(d)));
        assert!(
            delays
                .iter()
                .copied()
                .collect::<std::collections::HashSet<_>>()
                .len()
                > 1
        );
        assert_eq!(busy_retry_delay_secs(7), busy_retry_delay_secs(7));
    }

    #[test]
    fn notification_copy_covers_the_pause_resume_matrix() {
        use InferenceKind::{Omlx, Whisper};
        let cases = [
            (
                Whisper,
                GateState::Open,
                GateState::Deferred,
                Some("available_below_threshold"),
                Some("Transcription paused due to low memory"),
            ),
            (
                Whisper,
                GateState::Open,
                GateState::Deferred,
                Some("pressure_warn"),
                Some("Transcription paused due to warning-level memory pressure"),
            ),
            (
                Whisper,
                GateState::Open,
                GateState::Deferred,
                Some("pressure_critical"),
                Some("Transcription paused due to critical memory pressure"),
            ),
            (
                Whisper,
                GateState::Open,
                GateState::Deferred,
                Some("sample_failed"),
                Some("Transcription paused due to a memory sample failure"),
            ),
            (
                Whisper,
                GateState::Deferred,
                GateState::Deferred,
                Some("hysteresis"),
                None,
            ),
            (
                Whisper,
                GateState::Deferred,
                GateState::Open,
                None,
                Some("Transcription resumed due to available memory"),
            ),
            (
                Omlx,
                GateState::Open,
                GateState::Deferred,
                Some("available_below_threshold"),
                Some("Classification paused due to low memory"),
            ),
            (
                Omlx,
                GateState::Open,
                GateState::Deferred,
                Some("pressure_warn"),
                Some("Classification paused due to warning-level memory pressure"),
            ),
            (
                Omlx,
                GateState::Open,
                GateState::Deferred,
                Some("pressure_critical"),
                Some("Classification paused due to critical memory pressure"),
            ),
            (
                Omlx,
                GateState::Open,
                GateState::Deferred,
                Some("sample_failed"),
                Some("Classification paused due to a memory sample failure"),
            ),
            (
                Omlx,
                GateState::Deferred,
                GateState::Open,
                None,
                Some("Classification resumed due to available memory"),
            ),
            (Whisper, GateState::Disabled, GateState::Open, None, None),
        ];
        for (kind, previous, next, reason, expected) in cases {
            assert_eq!(
                notification_copy(kind, previous, next, reason).as_deref(),
                expected,
                "{kind:?} {previous:?} -> {next:?} {reason:?}"
            );
        }
    }

    #[test]
    fn pressure_transition_posts_all_pause_notifications() {
        with_test_memory(
            TestMemory {
                snapshot: snap(gib(32), PressureLevel::Normal, false),
                ..TestMemory::default()
            },
            || {
                evaluate();
                set_test_snapshot(snap(gib(32), PressureLevel::Warn, false));
                evaluate();
                let posted = TEST_NOTIFICATIONS.with(|cell| cell.borrow().clone());
                assert_eq!(
                    posted,
                    [
                        "Transcription paused due to warning-level memory pressure",
                        "Classification paused due to warning-level memory pressure",
                        "Speech synthesis paused due to warning-level memory pressure",
                    ]
                );
            },
        );
    }

    #[test]
    fn pause_and_resume_banners_fire_once_per_kind() {
        with_test_memory(
            TestMemory {
                snapshot: snap(gib(32), PressureLevel::Normal, false),
                ..TestMemory::default()
            },
            || {
                evaluate();
                set_test_snapshot(snap(gib(7), PressureLevel::Normal, false));
                evaluate();
                evaluate();
                status_json();
                set_test_states_open();
                evaluate();
                let paused = TEST_NOTIFICATIONS.with(|cell| cell.borrow().clone());
                assert_eq!(
                    paused,
                    [
                        "Transcription paused due to low memory",
                        "Classification paused due to low memory",
                    ]
                );
                set_test_snapshot(snap(gib(32), PressureLevel::Normal, false));
                evaluate();
                evaluate();
                set_test_states_open();
                evaluate();
                let posted = TEST_NOTIFICATIONS.with(|cell| cell.borrow().clone());
                assert_eq!(
                    posted,
                    [
                        "Transcription paused due to low memory",
                        "Classification paused due to low memory",
                        "Transcription resumed due to available memory",
                        "Classification resumed due to available memory",
                    ]
                );
                set_test_snapshot(snap(gib(7), PressureLevel::Normal, false));
                evaluate();
                let again = TEST_NOTIFICATIONS.with(|cell| cell.borrow().clone());
                assert_eq!(again.len(), 6);
            },
        );
    }

    #[test]
    fn restart_in_hysteresis_band_does_not_resume() {
        with_test_memory(
            TestMemory {
                snapshot: snap(gib(32), PressureLevel::Normal, false),
                ..TestMemory::default()
            },
            || {
                evaluate();
                set_test_snapshot(snap(gib(7), PressureLevel::Normal, false));
                evaluate();
                assert_eq!(
                    TEST_NOTIFICATIONS.with(|cell| cell.borrow().len()),
                    2
                );
                simulate_test_restart();
                set_test_snapshot(snap(gib(9), PressureLevel::Normal, false));
                let mid = evaluate();
                assert_eq!(mid.whisper.state, GateState::Deferred);
                assert_eq!(mid.omlx.state, GateState::Deferred);
                assert_eq!(mid.whisper.last_reason, Some("hysteresis"));
                assert_eq!(
                    TEST_NOTIFICATIONS.with(|cell| cell.borrow().len()),
                    2
                );
                simulate_test_restart();
                set_test_snapshot(snap(gib(28), PressureLevel::Normal, false));
                let high = evaluate();
                assert_eq!(high.whisper.state, GateState::Open);
                assert_eq!(high.omlx.state, GateState::Deferred);
                assert_eq!(high.omlx.last_reason, Some("hysteresis"));
                let posted = TEST_NOTIFICATIONS.with(|cell| cell.borrow().clone());
                assert_eq!(
                    posted,
                    [
                        "Transcription paused due to low memory",
                        "Classification paused due to low memory",
                        "Transcription resumed due to available memory",
                    ]
                );
            },
        );
    }

    #[test]
    fn parse_posted_reads_open_and_deferred_and_ignores_junk() {
        let parsed = parse_posted("whisper=deferred\nomlx=open\ntts=deferred\ngarbage\nwhisper=nope\n");
        assert_eq!(parsed.whisper, Some(GateState::Deferred));
        assert_eq!(parsed.omlx, Some(GateState::Open));
        assert_eq!(parsed.tts, Some(GateState::Deferred));
        let empty = parse_posted("");
        assert_eq!(empty, PostedStates::empty());
        let formatted = format_posted(PostedStates {
            whisper: Some(GateState::Deferred),
            omlx: Some(GateState::Open),
            tts: Some(GateState::Deferred),
        });
        assert_eq!(formatted, "whisper=deferred\nomlx=open\ntts=deferred\n");
        assert_eq!(parse_posted(&formatted).omlx, Some(GateState::Open));
    }

    #[test]
    fn status_json_has_no_secret_shaped_fields() {
        with_test_memory(TestMemory::default(), || {
            let dump = status_json().to_string();
            assert!(!dump.contains("sk-"));
            assert!(!dump.contains("bearer"));
            assert!(!dump.contains("desec_token"));
            assert!(!dump.contains("/Users/"));
        });
    }
}
