use crate::{Result, analysis, config::Config, model::Snapshot, transport};
use serde::Serialize;
use serde_json::{Value, json};
use std::{
    fs::{self, File},
    io::{self, BufWriter, Read, Write},
    path::Path,
    time::Duration,
};
use tokio::time::{Instant, sleep_until};

pub fn output(value: &impl Serialize) -> Result<()> {
    let mut out = io::stdout().lock();
    serde_json::to_writer_pretty(&mut out, value)?;
    writeln!(out)?;
    Ok(())
}

pub fn load<T: serde::de::DeserializeOwned>(path: &str) -> Result<T> {
    let reader: Box<dyn Read> = if path.is_empty() || path == "-" {
        Box::new(io::stdin())
    } else {
        Box::new(File::open(path)?)
    };
    let mut bytes = Vec::new();
    reader
        .take(transport::MAX_MESSAGE as u64 + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() > transport::MAX_MESSAGE {
        return Err("snapshot exceeds 32 MiB".into());
    }
    let mut stream = serde_json::Deserializer::from_slice(&bytes).into_iter::<T>();
    Ok(stream.next().ok_or("empty JSON input")??)
}

fn write_json(root: &Path, name: &str, value: &impl Serialize) -> Result<()> {
    let mut file = BufWriter::new(File::create(root.join(name))?);
    serde_json::to_writer_pretty(&mut file, value)?;
    writeln!(file)?;
    file.flush()?;
    Ok(())
}

pub fn matches(value: &Value, config: &Config) -> bool {
    let message = value["type"].as_str().unwrap_or("");
    match config.wait_for.as_str() {
        "snapshot" => message == "snapshot",
        "trace" | "frame_trace" => message == "frame_trace",
        "event" => message == "event" && (config.name.is_empty() || value["name"] == config.name),
        "log" => message == "log" && (config.level.is_empty() || value["level"] == config.level),
        _ => false,
    }
}

async fn capture_stream(config: &Config, root: &Path) -> Result<()> {
    let mut socket = transport::connect(&config.addr, config.timeout).await?;
    let mut file = BufWriter::new(File::create(root.join("stream.jsonl"))?);
    let deadline = Instant::now() + config.duration;
    loop {
        match transport::payload(&mut socket, Some(deadline)).await {
            Ok(raw) => {
                file.write_all(&raw)?;
                writeln!(file)?;
            }
            Err(_) => {
                sleep_until(deadline).await;
                break;
            }
        }
    }
    file.flush()?;
    Ok(())
}

fn duration_string(duration: Duration) -> String {
    if duration.is_zero() {
        return "0s".into();
    }
    let seconds = duration.as_secs_f64();
    if seconds < 1. {
        for (unit, scale) in [("ms", 1000.), ("µs", 1e6), ("ns", 1e9)] {
            if seconds * scale >= 1. {
                return format!("{}{unit}", seconds * scale);
            }
        }
    }
    let hours = duration.as_secs() / 3600;
    let minutes = duration.as_secs() % 3600 / 60;
    let rest = seconds - (hours * 3600 + minutes * 60) as f64;
    format!(
        "{}{}{rest}s",
        if hours > 0 {
            format!("{hours}h")
        } else {
            String::new()
        },
        if minutes > 0 || hours > 0 {
            format!("{minutes}m")
        } else {
            String::new()
        }
    )
}

pub async fn run(config: &Config) -> Result<()> {
    match config.command.as_str() {
        "watch" => return crate::ui::run(config).await,
        "version" => println!(
            "gdobs {} ({}, {})",
            env!("GDOBS_VERSION"),
            env!("GDOBS_COMMIT"),
            env!("GDOBS_DATE")
        ),
        "snapshot" => output(
            &transport::snapshot(
                &config.addr,
                config.timeout,
                Some(config.snapshot_options()),
            )
            .await?,
        )?,
        "status" => output(&analysis::status(
            &transport::snapshot(&config.addr, config.timeout, None).await?,
        ))?,
        "diagnose" => output(&analysis::diagnose(
            &transport::snapshot(&config.addr, config.timeout, None).await?,
        ))?,
        "top" => {
            let kind = if !config.kind.is_empty() {
                config.kind.as_str()
            } else {
                config.positional.first().map(String::as_str).unwrap_or("")
            };
            let kind = match kind {
                "timers" => "timer",
                "gauges" => "gauge",
                "counters" => "counter",
                other => other,
            };
            let snapshot: Snapshot = if !config.file.is_empty() {
                load(&config.file)?
            } else {
                let mut options = config.snapshot_options();
                if !kind.is_empty() {
                    options["kind"] = json!(kind);
                }
                transport::snapshot(&config.addr, config.timeout, Some(options)).await?
            };
            output(&analysis::top(
                snapshot.metrics(),
                kind,
                &config.sort,
                config.limit,
            ))?;
        }
        "diff" => {
            if config.positional.len() < 2 {
                return Err("diff requires before and after snapshot paths".into());
            }
            output(&analysis::diff(
                &load(&config.positional[0])?,
                &load(&config.positional[1])?,
            ))?;
        }
        "wait" => {
            let mut socket = transport::connect(&config.addr, config.timeout).await?;
            let deadline = Instant::now() + config.timeout;
            loop {
                let raw = match transport::payload(&mut socket, Some(deadline)).await {
                    Ok(value) => value,
                    Err(_) => {
                        output(
                            &json!({"ok":false,"timeout":true,"target":{"Kind":config.wait_for,"Name":config.name,"Level":config.level}}),
                        )?;
                        return Err("wait timed out".into());
                    }
                };
                if let Ok(value) = serde_json::from_slice::<Value>(&raw)
                    && matches(&value, config)
                {
                    output(&json!({"ok":true,"matched":value}))?;
                    break;
                }
            }
        }
        "assert" => {
            let snapshot: Snapshot = if !config.budget.is_empty() && !config.file.is_empty() {
                load(&config.file)?
            } else {
                transport::snapshot(&config.addr, config.timeout, None).await?
            };
            let failures = if !config.budget.is_empty() {
                analysis::budget(&snapshot, &load(&config.budget)?)
            } else {
                let mut failures = Vec::new();
                if config.min_fps >= 0. && snapshot.runtime.fps < config.min_fps {
                    failures.push(format!(
                        "fps {:.2} below {:.2}",
                        snapshot.runtime.fps, config.min_fps
                    ));
                }
                if config.max_frame >= 0.
                    && snapshot.runtime.frame_delta_usec as f64 > config.max_frame
                {
                    failures.push(format!(
                        "frame {} above {}",
                        analysis::usec(snapshot.runtime.frame_delta_usec as f64),
                        analysis::usec(config.max_frame)
                    ));
                }
                if !config.metric.is_empty() && config.max_p95 >= 0. {
                    match analysis::find_metric(&snapshot, &config.metric) {
                        None => failures.push(format!("metric not found: {}", config.metric)),
                        Some(row) if row.p95 > config.max_p95 => failures.push(format!(
                            "metric {} p95 {} above {}",
                            config.metric,
                            analysis::usec(row.p95),
                            analysis::usec(config.max_p95)
                        )),
                        _ => {}
                    }
                }
                failures
            };
            let success = failures.is_empty();
            if config.budget.is_empty() {
                output(&json!({"ok":success,"failures":failures,"snapshot":snapshot}))?;
            } else {
                output(&json!({"ok":success,"failures":failures}))?;
            }
            if !success {
                return Err(if config.budget.is_empty() {
                    "assertions failed"
                } else {
                    "budget assertions failed"
                }
                .into());
            }
        }
        "capture" => {
            let root = Path::new(if config.out.is_empty() {
                "gdobs-capture"
            } else {
                &config.out
            });
            fs::create_dir_all(root)?;
            let options = config.snapshot_options();
            let snapshot =
                transport::snapshot(&config.addr, config.timeout, Some(options.clone())).await?;
            let diagnose = analysis::diagnose(&snapshot);
            let status = analysis::status(&snapshot);
            write_json(root, "snapshot.json", &snapshot)?;
            write_json(root, "summary.json", &analysis::summary(&snapshot, 25))?;
            write_json(root, "diagnose.json", &diagnose)?;
            write_json(root, "status.json", &status)?;
            write_json(
                root,
                "metadata.json",
                &json!({"url":config.addr,"captured_at":chrono::Local::now().to_rfc3339_opts(chrono::SecondsFormat::AutoSi,true),"duration":duration_string(config.duration),"options":options}),
            )?;
            fs::write(
                root.join("summary.md"),
                analysis::markdown(&snapshot, &diagnose),
            )?;
            if !config.duration.is_zero() {
                capture_stream(config, root).await?;
            }
            output(&json!({"ok":true,"out":root,"status":status,"warnings":diagnose["warnings"]}))?;
        }
        "stream" => {
            let mut socket = transport::connect(&config.addr, config.timeout).await?;
            loop {
                let bytes = transport::payload(&mut socket, None).await?;
                let mut stdout = io::stdout().lock();
                stdout.write_all(&bytes)?;
                writeln!(stdout)?;
                stdout.flush()?;
            }
        }
        other => return Err(format!("unknown command: {other}").into()),
    }
    Ok(())
}
