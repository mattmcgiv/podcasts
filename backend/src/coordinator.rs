use crate::jobs::{Job, JobStage, JobStore, JobStoreError};
use std::sync::Mutex;

pub struct Coordinator<'a> {
    store: &'a JobStore<'a>,
    busy: Mutex<bool>,
    enabled: Box<dyn Fn() -> bool + Send + Sync + 'a>,
    skip_daily_limit: bool,
}

impl<'a> Coordinator<'a> {
    pub fn new(store: &'a JobStore<'a>) -> Self {
        Self {
            store,
            busy: Mutex::new(false),
            enabled: Box::new(|| true),
            skip_daily_limit: false,
        }
    }

    pub fn with_enabled<F>(store: &'a JobStore<'a>, enabled: F) -> Self
    where
        F: Fn() -> bool + Send + Sync + 'a,
    {
        Self {
            store,
            busy: Mutex::new(false),
            enabled: Box::new(enabled),
            skip_daily_limit: false,
        }
    }

    pub fn skip_daily_limit(mut self, skip: bool) -> Self {
        self.skip_daily_limit = skip;
        self
    }

    pub fn run_next_stage<F>(&self, mut execute: F) -> Result<Option<Job>, JobStoreError>
    where
        F: FnMut(JobStage, &Job) -> Result<(), String>,
    {
        let mut busy = self.busy.lock().unwrap();
        if *busy {
            return Ok(None);
        }
        *busy = true;
        drop(busy);
        let result = self.run_next_stage_locked(&mut execute);
        *self.busy.lock().unwrap() = false;
        result
    }

    fn run_next_stage_locked<F>(&self, execute: &mut F) -> Result<Option<Job>, JobStoreError>
    where
        F: FnMut(JobStage, &Job) -> Result<(), String>,
    {
        if !(self.enabled)() {
            return Ok(None);
        }
        let Some(mut job) = self.store.next_runnable_job()? else {
            return Ok(None);
        };
        let (executing, completion) = match job.stage {
            JobStage::Queued => (JobStage::Downloading, JobStage::Downloaded),
            JobStage::Downloading => (JobStage::Downloading, JobStage::Downloaded),
            JobStage::Downloaded => (JobStage::Transcribing, JobStage::Classifying),
            JobStage::Transcribing => (JobStage::Transcribing, JobStage::Classifying),
            JobStage::Classifying => (JobStage::Classifying, JobStage::Ready),
            _ => return Ok(None),
        };
        if job.stage == JobStage::Queued || job.stage == JobStage::Downloaded {
            job = self.store.transition(&job.id, executing)?;
        }
        if executing == JobStage::Classifying
            && !self.skip_daily_limit
            && !self.store.reserve_daily_classification_slot(job.episode_id, 20)?
        {
            return Ok(Some(self.store.set_blocking_reason(&job.id, Some(crate::jobs::BlockingReason::DailyLimit))?));
        }
        match execute(executing, &job) {
            Ok(()) => {
                let completed = self.store.transition(&job.id, completion)?;
                Ok(Some(completed))
            }
            Err(err) if err == "cancelled" => Err(JobStoreError::CorruptState("cancelled".into())),
            Err(err) if err.starts_with("pause:") => {
                let reason = crate::jobs::BlockingReason::parse(err.trim_start_matches("pause:")).unwrap_or(crate::jobs::BlockingReason::LowPower);
                Ok(Some(self.store.set_blocking_reason(&job.id, Some(reason))?))
            }
            Err(err) => Ok(Some(self.store.record_failure(&job.id, "stage", &err)?)),
        }
    }

    pub fn run_until_idle<F>(&self, mut execute: F) -> Result<u32, JobStoreError>
    where
        F: FnMut(JobStage, &Job) -> Result<(), String>,
    {
        let mut steps = 0u32;
        while let Some(_job) = self.run_next_stage(&mut execute)? {
            steps += 1;
            if steps > 64 {
                break;
            }
        }
        Ok(steps)
    }

    pub fn run_until_idle_with_sleep<F, S>(
        &self,
        mut execute: F,
        mut sleep: S,
        now: &dyn Fn() -> i64,
    ) -> Result<u32, JobStoreError>
    where
        F: FnMut(JobStage, &Job) -> Result<(), String>,
        S: FnMut(i64),
    {
        if !(self.enabled)() {
            return Ok(0);
        }
        let mut steps = 0u32;
        loop {
            match self.run_next_stage(&mut execute)? {
                Some(_) => {
                    steps += 1;
                }
                None => {
                    let job = self.store.next_runnable_job()?;
                    if job.is_some() {
                        continue;
                    }
                    let conn_now = now();
                    let wait = self.next_sleep(conn_now)?;
                    if let Some(seconds) = wait {
                        sleep(seconds);
                        continue;
                    }
                    break;
                }
            }
            if steps > 64 {
                break;
            }
        }
        Ok(steps)
    }

    fn next_sleep(&self, _now: i64) -> Result<Option<i64>, JobStoreError> {
        self.store.job_retry_wait()
    }
}
