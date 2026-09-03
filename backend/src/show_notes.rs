use crate::jobs::ShowNoteRecord;
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Condvar, Mutex};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ShowNotesError {
    Cancelled,
    SourceChanged,
    FeatureDisabled,
    Closed,
}

#[derive(Default)]
struct State {
    inflight: HashMap<i64, Arc<Generation>>,
    cancel_episode: HashSet<i64>,
    cancel_all: bool,
    closed: bool,
}

struct Generation {
    observed: Mutex<bool>,
    finished: Mutex<bool>,
    result: Mutex<Option<Result<Vec<ShowNoteRecord>, ShowNotesError>>>,
    cond: Condvar,
}

impl Generation {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            observed: Mutex::new(false),
            finished: Mutex::new(false),
            result: Mutex::new(None),
            cond: Condvar::new(),
        })
    }
}

#[derive(Default)]
pub struct ShowNotesService {
    state: Mutex<State>,
}

impl ShowNotesService {
    pub fn generate<F>(&self, episode_id: i64, work: F) -> Result<Vec<ShowNoteRecord>, ShowNotesError>
    where
        F: FnOnce() -> Result<Vec<ShowNoteRecord>, ShowNotesError>,
    {
        let generation = {
            let mut state = self.state.lock().unwrap();
            if state.closed {
                return Err(ShowNotesError::Closed);
            }
            if state.cancel_all {
                return Err(ShowNotesError::FeatureDisabled);
            }
            if state.cancel_episode.contains(&episode_id) {
                return Err(ShowNotesError::SourceChanged);
            }
            if let Some(existing) = state.inflight.get(&episode_id).cloned() {
                drop(state);
                let mut finished = existing.finished.lock().unwrap();
                while !*finished {
                    finished = existing.cond.wait(finished).unwrap();
                }
                return existing
                    .result
                    .lock()
                    .unwrap()
                    .clone()
                    .unwrap_or(Err(ShowNotesError::Cancelled));
            }
            let generation = Generation::new();
            state.inflight.insert(episode_id, generation.clone());
            generation
        };
        let result = work();
        {
            let mut state = self.state.lock().unwrap();
            if state.cancel_episode.contains(&episode_id) || state.cancel_all {
                *generation.observed.lock().unwrap() = true;
                generation.cond.notify_all();
            }
            state.inflight.remove(&episode_id);
            let cancelled = state.cancel_all || state.cancel_episode.contains(&episode_id);
            state.cancel_episode.remove(&episode_id);
            let final_result = if state.closed {
                Err(ShowNotesError::Closed)
            } else if result.is_ok() && cancelled {
                Err(ShowNotesError::Cancelled)
            } else {
                result.clone()
            };
            *generation.result.lock().unwrap() = Some(final_result.clone());
            *generation.finished.lock().unwrap() = true;
            generation.cond.notify_all();
            final_result
        }
    }

    pub fn observe_cancel(&self, episode_id: i64) -> bool {
        let state = self.state.lock().unwrap();
        let requested = state.cancel_all || state.cancel_episode.contains(&episode_id);
        if requested {
            if let Some(generation) = state.inflight.get(&episode_id) {
                *generation.observed.lock().unwrap() = true;
                generation.cond.notify_all();
            }
        }
        requested
    }

    pub fn cancel(&self, episode_id: i64) {
        let generation = {
            let mut state = self.state.lock().unwrap();
            state.cancel_episode.insert(episode_id);
            state.inflight.get(&episode_id).cloned()
        };
        if let Some(generation) = generation {
            let mut observed = generation.observed.lock().unwrap();
            while !*observed {
                observed = generation.cond.wait(observed).unwrap();
            }
        }
    }

    pub fn cancel_all(&self) {
        let inflight = {
            let mut state = self.state.lock().unwrap();
            state.cancel_all = true;
            state.inflight.values().cloned().collect::<Vec<_>>()
        };
        for generation in inflight {
            let mut finished = generation.finished.lock().unwrap();
            while !*finished {
                finished = generation.cond.wait(finished).unwrap();
            }
        }
        let mut state = self.state.lock().unwrap();
        state.cancel_all = false;
        state.cancel_episode.clear();
    }

    pub fn close_writes(&self) {
        self.state.lock().unwrap().closed = true;
    }

    pub fn writes_closed(&self) -> bool {
        self.state.lock().unwrap().closed
    }
}
