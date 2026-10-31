use crate::model::{FrameTrace, MetricRow, Snapshot};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

pub fn usec(value: f64) -> String {
    if value <= 0. {
        "0us".into()
    } else if value < 1000. {
        format!("{value:.0}us")
    } else {
        format!("{:.2}ms", value / 1000.)
    }
}

pub fn bytes(value: i64) -> String {
    if value <= 0 {
        return "0B".into();
    }
    let units = ["B", "KB", "MB", "GB"];
    let mut amount = value as f64;
    let mut index = 0;
    while amount >= 1024. && index < 3 {
        amount /= 1024.;
        index += 1;
    }
    if index == 0 {
        format!("{value}B")
    } else {
        format!("{amount:.1}{}", units[index])
    }
}

pub fn status(s: &Snapshot) -> Value {
    json!({"ok":true,"connected":true,"enabled":s.enabled,"metric_count":s.metric_count,"timer_count":s.timer_count,"gauge_count":s.gauge_count,"counter_count":s.counter_count,"sample_count":s.sample_count,"fps":s.runtime.fps,"recent_frame_trace_count":s.traces().len()})
}

pub fn field(row: &MetricRow, key: &str) -> f64 {
    match key {
        "total" => row.total,
        "max" => row.max,
        "avg" => row.avg,
        "p50" => row.p50,
        "p99" => row.p99,
        "latest" => row.latest,
        "value" => row.value,
        _ => row.p95,
    }
}

pub fn top(rows: &[MetricRow], kind: &str, sort: &str, limit: i64) -> Vec<MetricRow> {
    let mut out: Vec<_> = rows
        .iter()
        .filter(|row| kind.is_empty() || row.kind == kind)
        .cloned()
        .collect();
    out.sort_by(|a, b| field(b, sort).total_cmp(&field(a, sort)));
    if limit > 0 {
        out.truncate(limit as usize);
    }
    out
}

pub fn go_value(value: &Value) -> String {
    match value {
        Value::Null => "<nil>".into(),
        Value::String(s) => s.clone(),
        Value::Array(v) => format!("[{}]", v.iter().map(go_value).collect::<Vec<_>>().join(" ")),
        Value::Object(v) => format!(
            "map[{}]",
            v.iter()
                .map(|(k, v)| format!("{k}:{}", go_value(v)))
                .collect::<Vec<_>>()
                .join(" ")
        ),
        other => other.to_string(),
    }
}

pub fn cardinality(rows: &[MetricRow]) -> BTreeMap<String, usize> {
    let mut values: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    for row in rows {
        if let Some(tags) = &row.tags {
            for (key, value) in tags {
                values
                    .entry(key.clone())
                    .or_default()
                    .insert(go_value(value));
            }
        }
    }
    values
        .into_iter()
        .map(|(key, value)| (key, value.len()))
        .collect()
}

pub fn diagnose(s: &Snapshot) -> Value {
    let mut warnings = Vec::new();
    if !s.enabled {
        warnings.push("metrics capture is disabled".into());
    }
    if s.metric_count == 0 {
        warnings.push("no custom metrics have been recorded".into());
    }
    if s.runtime.fps > 0. && s.runtime.fps < 50. {
        warnings.push(format!("fps is low: {:.1}", s.runtime.fps));
    }
    if s.runtime.frame_delta_usec > 16666 {
        warnings.push(format!(
            "frame delta exceeds 60fps budget: {}",
            usec(s.runtime.frame_delta_usec as f64)
        ));
    }
    if s.sample_count > 2000 {
        warnings.push(format!(
            "large retained sample volume: {}; use filtered snapshots or lower max samples",
            s.sample_count
        ));
    }
    if s.traces().len() > 80 {
        warnings.push(format!(
            "many recent frame traces in snapshot: {}; omit traces from live snapshots by default",
            s.traces().len()
        ));
    }
    let tags = cardinality(s.metrics());
    for (tag, count) in &tags {
        if *count > 25 {
            warnings.push(format!("tag {tag:?} has high cardinality: {count} values"));
        }
    }
    if let Some(row) = s
        .metrics()
        .iter()
        .find(|r| r.kind == "timer" && r.count == 0)
    {
        warnings.push(format!("timer has no samples: {}", row.path));
    }
    if let Some(dropped) = s
        .live
        .as_ref()
        .and_then(|v| v.get("dropped_messages"))
        .and_then(Value::as_f64)
        && dropped > 0.
    {
        warnings.push(format!("live transport dropped {dropped:.0} messages"));
    }
    if let Some(trace) = s.traces().iter().find(|t| t.slow) {
        warnings.push(format!(
            "recent slow trace frame={} total={}",
            trace.frame,
            usec(trace.total_usec as f64)
        ));
    }
    json!({"ok":warnings.is_empty(),"warnings":warnings,"status":status(s),"tag_cardinality":tags})
}

pub fn summary(s: &Snapshot, limit: i64) -> Value {
    json!({"status":status(s),"top_timers_by_p95":top(s.metrics(),"timer","p95",limit),"top_timers_by_total":top(s.metrics(),"timer","total",limit),"top_counters":top(s.metrics(),"counter","value",limit),"tag_cardinality":cardinality(s.metrics()),"frame_traces":{"count":s.traces().len(),"slow_count":s.traces().iter().filter(|t|t.slow).count(),"max_total_usec":s.traces().iter().map(|t|t.total_usec).max().unwrap_or(0)}})
}

pub fn find_metric<'a>(s: &'a Snapshot, name: &str) -> Option<&'a MetricRow> {
    s.metrics()
        .iter()
        .find(|row| row.path == name || row.key == name)
}

pub fn budget(s: &Snapshot, rules: &Value) -> Vec<String> {
    let mut failures = Vec::new();
    if let Some(timers) = rules["timers"].as_object() {
        for (name, rule) in timers {
            let Some(row) = find_metric(s, name) else {
                failures.push(format!("timer not found: {name}"));
                continue;
            };
            if let Some(max) = rule["p95_usec"].as_f64()
                && row.p95 > max
            {
                failures.push(format!("{name} p95 {} above {}", usec(row.p95), usec(max)));
            }
            if let Some(max) = rule["max_usec"].as_f64()
                && row.max > max
            {
                failures.push(format!("{name} max {} above {}", usec(row.max), usec(max)));
            }
        }
    }
    let runtime = &rules["runtime"];
    if let Some(min) = runtime["min_fps"].as_f64()
        && s.runtime.fps < min
    {
        failures.push(format!("fps {:.1} below {min:.1}", s.runtime.fps));
    }
    if let Some(max) = runtime["max_frame_usec"].as_f64()
        && s.runtime.frame_delta_usec as f64 > max
    {
        failures.push(format!(
            "frame {} above {}",
            usec(s.runtime.frame_delta_usec as f64),
            usec(max)
        ));
    }
    if let Some(max) = runtime["max_orphan_nodes"].as_f64()
        && s.runtime.orphan_node_count as f64 > max
    {
        failures.push(format!(
            "orphan nodes {} above {max:.0}",
            s.runtime.orphan_node_count
        ));
    }
    failures
}

pub fn diff(before: &Snapshot, after: &Snapshot) -> Value {
    let by_key: BTreeMap<_, _> = before.metrics().iter().map(|r| (&r.key, r)).collect();
    let mut changes:Vec<_>=after.metrics().iter().map(|row|match by_key.get(&row.key) {
        Some(old)=>json!({"path":row.path,"key":row.key,"status":"changed","p95_delta":row.p95-old.p95,"value_delta":row.value-old.value,"latest_delta":row.latest-old.latest}),
        None=>json!({"path":row.path,"key":row.key,"status":"added","after":row}),
    }).collect();
    changes.sort_by(|a, b| {
        b["p95_delta"]
            .as_f64()
            .unwrap_or(0.)
            .abs()
            .total_cmp(&a["p95_delta"].as_f64().unwrap_or(0.).abs())
    });
    json!({"before":status(before),"after":status(after),"changes":changes})
}

pub fn trace_groups(trace: &FrameTrace) -> String {
    let mut totals: BTreeMap<&str, i64> = BTreeMap::new();
    for span in trace.spans.as_deref().unwrap_or(&[]) {
        let value = totals.entry(&span.path).or_default();
        *value = value.saturating_add(span.duration_usec);
    }
    let mut pairs: Vec<_> = totals.into_iter().collect();
    pairs.sort_by(|a, b| b.1.cmp(&a.1));
    format!(
        "{{{}}}",
        pairs
            .iter()
            .take(5)
            .map(|(path, time)| format!("{path}={}", usec(*time as f64)))
            .collect::<Vec<_>>()
            .join(",")
    )
}

pub fn markdown(s: &Snapshot, diag: &Value) -> String {
    let mut text = format!(
        "# gdobs Capture Summary\n\n- Metrics: {} ({} timers, {} gauges, {} counters)\n- Runtime: fps {:.1}, frame {}, process {}\n- Nodes: {}, orphans: {}, memory: {}\n\n",
        s.metric_count,
        s.timer_count,
        s.gauge_count,
        s.counter_count,
        s.runtime.fps,
        usec(s.runtime.frame_delta_usec as f64),
        usec(s.runtime.process_time_usec as f64),
        s.runtime.node_count,
        s.runtime.orphan_node_count,
        bytes(s.runtime.memory_static_bytes)
    );
    if let Some(warnings) = diag["warnings"].as_array()
        && !warnings.is_empty()
    {
        text.push_str("## Warnings\n");
        for warning in warnings {
            text.push_str(&format!("- {}\n", warning.as_str().unwrap_or("")));
        }
        text.push('\n');
    }
    text.push_str("## Top Timers By P95\n");
    for row in top(s.metrics(), "timer", "p95", 10) {
        text.push_str(&format!(
            "- `{}` p95 {} max {} count {}\n",
            row.path,
            usec(row.p95),
            usec(row.max),
            row.count
        ));
    }
    text
}
