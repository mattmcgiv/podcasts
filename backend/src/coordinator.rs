use crate::jobs::{Job, JobStage, JobStore, JobStoreError};

pub fn next_stage(stage: JobStage) -> Option<JobStage> {
    match stage {
        JobStage::Queued => Some(JobStage::Downloading),
        JobStage::Downloading => Some(JobStage::Downloaded),
        JobStage::Downloaded => Some(JobStage::Transcribing),
        JobStage::Transcribing => Some(JobStage::Classifying),
        JobStage::Classifying => Some(JobStage::Ready),
        _ => None,
    }
}

pub fn run_until_idle<F>(store: &JobStore<'_>, mut execute: F) -> Result<u32, JobStoreError>
where
    F: FnMut(JobStage, &Job) -> Result<(), String>,
{
    let mut steps = 0u32;
    while let Some(job) = store.next_runnable_job()? {
        let Some(next) = next_stage(job.stage) else {
            break;
        };
        if let Err(err) = execute(job.stage, &job) {
            store.record_failure(&job.id, "stage", &err)?;
            continue;
        }
        store.transition(&job.id, next)?;
        steps += 1;
        if steps > 32 {
            break;
        }
    }
    Ok(steps)
}
