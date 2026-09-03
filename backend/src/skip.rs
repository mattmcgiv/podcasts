use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct AdSkipRange {
    pub id: String,
    pub start_segment_id: String,
    pub end_segment_id: String,
    pub start_time: f64,
    pub end_time: f64,
    pub confidence: f64,
    pub reason: String,
    pub classifier_version: String,
    pub prompt_version: String,
    pub created_at: i64,
    pub disabled: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct AdRemovalSkipDecision {
    pub range_id: String,
    pub range_start: f64,
    pub range_end: f64,
}

impl AdRemovalSkipDecision {
    pub fn target_position(&self) -> f64 {
        self.range_end
    }
    pub fn skipped_duration(&self) -> f64 {
        self.range_end - self.range_start
    }
}

pub fn skip_decision(position: f64, ranges: &[AdSkipRange]) -> Option<AdRemovalSkipDecision> {
    if !position.is_finite() || position < 0.0 {
        return None;
    }
    ranges.iter().find(|r| !r.disabled && position >= r.start_time && position < r.end_time).map(|r| {
        AdRemovalSkipDecision {
            range_id: r.id.clone(),
            range_start: r.start_time,
            range_end: r.end_time,
        }
    })
}

#[derive(Clone, Debug, Default)]
pub struct AdRemovalSkipSession {
    pub ranges: Vec<AdSkipRange>,
    pub pending: Option<AdRemovalSkipDecision>,
}

impl AdRemovalSkipSession {
    pub fn new(ranges: Vec<AdSkipRange>) -> Self {
        Self { ranges, pending: None }
    }

    pub fn enter(&mut self, position: f64) -> Option<AdRemovalSkipDecision> {
        skip_decision(position, &self.ranges)
    }

    pub fn enter_mac_transport_event(&mut self, event_type: &str, position: f64) -> Option<AdRemovalSkipDecision> {
        if event_type != "timeupdate" {
            return None;
        }
        self.enter(position)
    }

    pub fn did_complete(&mut self, decision: AdRemovalSkipDecision) {
        if self.ranges.iter().any(|r| r.id == decision.range_id && !r.disabled) {
            self.pending = Some(decision);
        }
    }

    pub fn did_undo(&mut self, range_id: &str) {
        for range in &mut self.ranges {
            if range.id == range_id {
                range.disabled = true;
            }
        }
        if self.pending.as_ref().map(|p| p.range_id.as_str()) == Some(range_id) {
            self.pending = None;
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct AdRemovalMacSkipAttempt {
    pub token: u64,
    pub lifecycle_token: u64,
    pub decision: AdRemovalSkipDecision,
    pub started_at: i64,
    pub attempted_at: i64,
    pub attempt_number: i32,
}

#[derive(Clone, Debug, PartialEq)]
pub enum AdRemovalMacSkipClockObservation {
    PassThrough,
    Suppress,
    Completed(AdRemovalMacSkipAttempt),
}

#[derive(Clone, Debug, PartialEq)]
pub enum AdRemovalMacSkipRetryTransition {
    Retry(AdRemovalMacSkipAttempt),
    Exhausted(AdRemovalMacSkipAttempt),
    Ignored,
}

#[derive(Clone, Debug, PartialEq)]
pub enum AdRemovalMacSupersedingSeekObservation {
    Suppress,
    Acknowledged,
    Settled,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct AdRemovalMacSupersedingSeekFence {
    pub target_position: f64,
    acknowledged: bool,
}

impl AdRemovalMacSupersedingSeekFence {
    pub fn new(target_position: f64) -> Self {
        Self { target_position, acknowledged: false }
    }

    pub fn observe(&mut self, position: f64) -> AdRemovalMacSupersedingSeekObservation {
        self.observe_with(position, 1.0, 3.0)
    }

    pub fn observe_with(
        &mut self,
        position: f64,
        acknowledgement_tolerance: f64,
        settlement_tolerance: f64,
    ) -> AdRemovalMacSupersedingSeekObservation {
        if !position.is_finite() {
            return AdRemovalMacSupersedingSeekObservation::Suppress;
        }
        let distance = (position - self.target_position).abs();
        if !self.acknowledged {
            if distance > acknowledgement_tolerance.max(0.0) {
                return AdRemovalMacSupersedingSeekObservation::Suppress;
            }
            self.acknowledged = true;
            return AdRemovalMacSupersedingSeekObservation::Acknowledged;
        }
        if distance > settlement_tolerance.max(0.0) {
            return AdRemovalMacSupersedingSeekObservation::Suppress;
        }
        AdRemovalMacSupersedingSeekObservation::Settled
    }
}

#[derive(Clone, Debug, Default)]
pub struct AdRemovalMacSkipState {
    in_flight: Option<AdRemovalMacSkipAttempt>,
    completed_range_ids: std::collections::HashSet<String>,
    terminal_range_ids: std::collections::HashSet<String>,
    stale_clock_floor: Option<f64>,
    next_attempt_token: u64,
}

impl AdRemovalMacSkipState {
    pub fn begin(
        &mut self,
        decision: AdRemovalSkipDecision,
        lifecycle_token: u64,
        now: i64,
    ) -> Option<AdRemovalMacSkipAttempt> {
        if self.in_flight.is_some()
            || self.completed_range_ids.contains(&decision.range_id)
            || self.terminal_range_ids.contains(&decision.range_id)
        {
            return None;
        }
        self.next_attempt_token = self.next_attempt_token.wrapping_add(1);
        let attempt = AdRemovalMacSkipAttempt {
            token: self.next_attempt_token,
            lifecycle_token,
            decision,
            started_at: now,
            attempted_at: now,
            attempt_number: 1,
        };
        self.in_flight = Some(attempt.clone());
        Some(attempt)
    }

    pub fn observe(&mut self, position: f64, lifecycle_token: u64) -> AdRemovalMacSkipClockObservation {
        self.observe_with(position, lifecycle_token, 1.0)
    }

    pub fn observe_with(
        &mut self,
        position: f64,
        lifecycle_token: u64,
        acknowledgement_tolerance: f64,
    ) -> AdRemovalMacSkipClockObservation {
        if !position.is_finite() {
            return if self.in_flight.is_none() {
                AdRemovalMacSkipClockObservation::PassThrough
            } else {
                AdRemovalMacSkipClockObservation::Suppress
            };
        }
        if let Some(attempt) = self.in_flight.clone() {
            if attempt.lifecycle_token == lifecycle_token {
                let overshoot = position - attempt.decision.target_position();
                if overshoot < 0.0 || overshoot > acknowledgement_tolerance.max(0.0) {
                    return AdRemovalMacSkipClockObservation::Suppress;
                }
                self.in_flight = None;
                self.completed_range_ids.insert(attempt.decision.range_id.clone());
                self.stale_clock_floor = Some(self.stale_clock_floor.unwrap_or(0.0).max(attempt.decision.target_position()));
                return AdRemovalMacSkipClockObservation::Completed(attempt);
            }
        }
        if let Some(floor) = self.stale_clock_floor {
            if position < floor {
                return AdRemovalMacSkipClockObservation::Suppress;
            }
        }
        AdRemovalMacSkipClockObservation::PassThrough
    }

    pub fn retry(
        &mut self,
        attempt_token: u64,
        lifecycle_token: u64,
        now: i64,
        maximum_attempts: i32,
    ) -> AdRemovalMacSkipRetryTransition {
        let current = match &self.in_flight {
            Some(current) if current.token == attempt_token && current.lifecycle_token == lifecycle_token => current.clone(),
            _ => return AdRemovalMacSkipRetryTransition::Ignored,
        };
        if current.attempt_number >= maximum_attempts.max(1) {
            self.in_flight = None;
            self.terminal_range_ids.insert(current.decision.range_id.clone());
            return AdRemovalMacSkipRetryTransition::Exhausted(current);
        }
        self.next_attempt_token = self.next_attempt_token.wrapping_add(1);
        let retry = AdRemovalMacSkipAttempt {
            token: self.next_attempt_token,
            lifecycle_token,
            decision: current.decision,
            started_at: current.started_at,
            attempted_at: now,
            attempt_number: current.attempt_number + 1,
        };
        self.in_flight = Some(retry.clone());
        AdRemovalMacSkipRetryTransition::Retry(retry)
    }

    pub fn accepts_delivery(&self, attempt_token: u64, lifecycle_token: u64) -> bool {
        self.in_flight
            .as_ref()
            .is_some_and(|a| a.token == attempt_token && a.lifecycle_token == lifecycle_token)
    }

    pub fn invalidate(&mut self) {
        self.in_flight = None;
        self.completed_range_ids.clear();
        self.terminal_range_ids.clear();
        self.stale_clock_floor = None;
    }
}

pub fn local_source(publisher: &str, downloaded: Option<&str>) -> String {
    downloaded.unwrap_or(publisher).to_string()
}

pub fn mac_source(publisher: &str, downloaded: bool, authenticated_stream: Option<&str>) -> Option<String> {
    if downloaded {
        authenticated_stream.map(str::to_string)
    } else {
        Some(publisher.to_string())
    }
}
