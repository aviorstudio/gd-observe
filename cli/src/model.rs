use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct MetricRow {
    pub path: String,
    pub key: String,
    pub kind: String,
    pub unit: String,
    pub tags: Option<BTreeMap<String, Value>>,
    pub count: i64,
    pub total: f64,
    pub min: f64,
    pub max: f64,
    pub avg: f64,
    pub p50: f64,
    pub p95: f64,
    pub p99: f64,
    pub latest: f64,
    pub value: f64,
    pub latest_delta: f64,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Snapshot {
    #[serde(rename = "type")]
    pub message_type: String,
    pub version: i64,
    pub request_id: String,
    pub timestamp_usec: i64,
    pub enabled: bool,
    pub metric_count: i64,
    pub timer_count: i64,
    pub gauge_count: i64,
    pub counter_count: i64,
    pub sample_count: i64,
    pub metrics: Option<Vec<MetricRow>>,
    pub runtime: RuntimeStats,
    pub recent_frame_traces: Option<Vec<FrameTrace>>,
    pub summary: Value,
    pub runtime_deltas: Option<Vec<Value>>,
    pub live: Option<BTreeMap<String, Value>>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct RuntimeStats {
    pub timestamp_usec: i64,
    pub sample_count: i64,
    pub fps: f64,
    pub frame_delta_usec: i64,
    pub process_time_usec: i64,
    pub physics_process_time_usec: i64,
    pub navigation_process_time_usec: i64,
    pub memory_static_bytes: i64,
    pub memory_static_max_bytes: i64,
    pub message_buffer_max_bytes: i64,
    pub object_count: i64,
    pub resource_count: i64,
    pub node_count: i64,
    pub orphan_node_count: i64,
    pub render_objects_in_frame: i64,
    pub render_primitives_in_frame: i64,
    pub draw_calls_in_frame: i64,
    pub video_memory_bytes: i64,
    pub texture_memory_bytes: i64,
    pub buffer_memory_bytes: i64,
    pub physics_2d_active_objects: i64,
    pub physics_2d_collision_pairs: i64,
    pub physics_2d_island_count: i64,
    pub audio_output_latency_usec: i64,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct LogEntry {
    #[serde(rename = "type")]
    pub message_type: String,
    pub timestamp_usec: i64,
    pub level: String,
    pub message: String,
    pub tags: Option<BTreeMap<String, Value>>,
    pub fields: Option<BTreeMap<String, Value>>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct EventEntry {
    #[serde(rename = "type")]
    pub message_type: String,
    pub timestamp_usec: i64,
    pub name: String,
    pub internal: bool,
    pub tags: Option<BTreeMap<String, Value>>,
    pub fields: Option<BTreeMap<String, Value>>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct TraceSpan {
    pub path: String,
    pub duration_usec: i64,
    pub timestamp_usec: i64,
    pub tags: Option<BTreeMap<String, Value>>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct FrameTrace {
    #[serde(rename = "type")]
    pub message_type: String,
    pub timestamp_usec: i64,
    pub frame: i64,
    pub span_count: i64,
    pub total_usec: i64,
    pub slow: bool,
    pub spans: Option<Vec<TraceSpan>>,
}

impl Snapshot {
    pub fn metrics(&self) -> &[MetricRow] {
        self.metrics.as_deref().unwrap_or(&[])
    }
    pub fn traces(&self) -> &[FrameTrace] {
        self.recent_frame_traces.as_deref().unwrap_or(&[])
    }
}
