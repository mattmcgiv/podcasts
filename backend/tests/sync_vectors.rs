//! Shared sync vectors: the Mac must map positions exactly as the browser and the iPhone do.
use pods_backend::browser::{original_time, processed_time, Interval};
use serde_json::Value;

const VECTORS: &str = include_str!("../../client/src/offline/sync-vectors.json");

#[test]
fn timeline_mapping_matches_the_shared_vectors() {
    let vectors: Value = serde_json::from_str(VECTORS).unwrap();
    let cases = vectors["timeline"].as_array().unwrap();
    assert!(!cases.is_empty());
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let timeline: Vec<Interval> = serde_json::from_value(case["timeline"].clone()).unwrap();
        for pair in case["to_original"].as_array().unwrap() {
            let (processed, expected) = (pair[0].as_f64().unwrap(), pair[1].as_f64().unwrap());
            assert_eq!(original_time(&timeline, processed), expected, "{name}: processed {processed}");
        }
        for pair in case["to_processed"].as_array().unwrap() {
            let (original, expected) = (pair[0].as_f64().unwrap(), pair[1].as_f64().unwrap());
            assert_eq!(processed_time(&timeline, original), expected, "{name}: original {original}");
        }
    }
}
