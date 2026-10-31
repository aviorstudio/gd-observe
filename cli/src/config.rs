use crate::Result;
use serde_json::{Value, json};
use std::{collections::BTreeMap, fs, path::Path, time::Duration};

pub const DEFAULT_ADDR: &str = "ws://127.0.0.1:8765";
pub const COMMANDS: &[&str] = &[
    "watch", "version", "snapshot", "capture", "stream", "status", "wait", "assert", "diagnose",
    "top", "diff",
];

#[derive(Clone, Debug)]
pub struct Config {
    pub command: String,
    pub addr: String,
    pub timeout: Duration,
    pub duration: Duration,
    pub wait_for: String,
    pub name: String,
    pub level: String,
    pub metric: String,
    pub max_p95: f64,
    pub min_fps: f64,
    pub max_frame: f64,
    pub kind: String,
    pub path: String,
    pub prefix: String,
    pub sort: String,
    pub limit: i64,
    pub raw: bool,
    pub traces: bool,
    pub out: String,
    pub file: String,
    pub budget: String,
    pub positional: Vec<String>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            command: "watch".into(),
            addr: DEFAULT_ADDR.into(),
            timeout: Duration::from_secs(10),
            duration: Duration::ZERO,
            wait_for: "snapshot".into(),
            name: String::new(),
            level: String::new(),
            metric: String::new(),
            max_p95: -1.,
            min_fps: -1.,
            max_frame: -1.,
            kind: String::new(),
            path: String::new(),
            prefix: String::new(),
            sort: "p95".into(),
            limit: 0,
            raw: false,
            traces: false,
            out: "gdobs-capture".into(),
            file: String::new(),
            budget: String::new(),
            positional: Vec::new(),
        }
    }
}

pub const HELP: &str = "gdobs: Godot observability CLI and Ratatui dashboard\n\nUsage: gdobs [watch|snapshot|capture|stream|status|wait|assert|diagnose|top|diff|version] [options]\n\n  --addr, --url URL       WebSocket endpoint (default ws://127.0.0.1:8765)\n  --env FILE             Endpoint settings from .env or .env.json\n  --project DIRECTORY    Discover endpoint settings in a Godot project\n  --timeout DURATION     Machine command timeout (default 10s)\n  --kind KIND            timer, gauge or counter\n  --path PATH            Exact metric path\n  --path-prefix PREFIX   Metric path prefix\n  --sort FIELD           p95, total, max, avg, p50, p99, latest or value\n  --limit COUNT          Maximum returned metrics\n  --raw, --traces        Include raw samples / recent traces\n  --file FILE            Read an offline snapshot (- reads stdin)\n  --budget FILE          Assert a JSON budget\n  --metric PATH          Metric path or key for assertions\n  --max-p95-usec NUMBER  --min-fps NUMBER  --max-frame-usec NUMBER\n  --for TYPE             Wait for snapshot, event, log or trace\n  --name NAME            Event name to wait for\n  --level LEVEL          Log level to wait for\n  --duration DURATION    Optional capture duration\n  --out DIRECTORY       Capture destination (default gdobs-capture)\n\nAuthentication: GDOBS_AUTH_TOKEN in the process environment only.\nDashboard: click tabs and rows; mouse wheel scrolls; Ctrl+C exits.\n";

impl Config {
    pub fn parse(args: &[String]) -> Result<Self> {
        let mut cfg = Self::default();
        let mut args = args.iter().peekable();
        if args.peek().is_some_and(|v| COMMANDS.contains(&v.as_str())) {
            cfg.command = args.next().unwrap().clone();
        }
        let mut endpoint = false;
        let mut env_file = String::new();
        let mut project = String::new();
        while let Some(arg) = args.next() {
            if arg == "--" {
                cfg.positional.extend(args.cloned());
                break;
            }
            if !arg.starts_with('-') {
                cfg.positional.push(arg.clone());
                continue;
            }
            let (key, inline) = arg
                .trim_start_matches('-')
                .split_once('=')
                .map_or((arg.trim_start_matches('-'), None), |(k, v)| (k, Some(v)));
            if matches!(key, "raw" | "traces") {
                let value = match inline.unwrap_or("true").to_ascii_lowercase().as_str() {
                    "true" | "t" | "1" => true,
                    "false" | "f" | "0" => false,
                    _ => return Err(format!("invalid boolean for --{key}").into()),
                };
                if key == "raw" {
                    cfg.raw = value;
                } else {
                    cfg.traces = value;
                }
                continue;
            }
            let value = inline
                .map(str::to_owned)
                .or_else(|| args.next().cloned())
                .ok_or_else(|| format!("--{key} needs a value"))?;
            match key {
                "addr" | "url" => {
                    cfg.addr = value;
                    endpoint = true;
                }
                "env" => env_file = value,
                "project" => project = value,
                "timeout" => cfg.timeout = duration(&value)?,
                "duration" => cfg.duration = duration(&value)?,
                "for" => cfg.wait_for = value,
                "name" => cfg.name = value,
                "level" => cfg.level = value,
                "metric" => cfg.metric = value,
                "max-p95-usec" => cfg.max_p95 = value.parse()?,
                "min-fps" => cfg.min_fps = value.parse()?,
                "max-frame-usec" => cfg.max_frame = value.parse()?,
                "kind" => cfg.kind = value,
                "path" => cfg.path = value,
                "path-prefix" => cfg.prefix = value,
                "sort" => cfg.sort = value,
                "limit" => cfg.limit = value.parse()?,
                "out" => cfg.out = value,
                "file" => cfg.file = value,
                "budget" => cfg.budget = value,
                _ => return Err(format!("unknown option --{key}").into()),
            }
        }
        if !endpoint {
            if !env_file.is_empty() {
                cfg.addr = address_from_file(Path::new(&env_file))?;
            } else if !project.is_empty() {
                cfg.addr = address_from_project(Path::new(&project))?;
            }
        }
        if ![cfg.max_p95, cfg.min_fps, cfg.max_frame]
            .iter()
            .all(|v| v.is_finite())
        {
            return Err("assertion thresholds must be finite".into());
        }
        Ok(cfg)
    }

    pub fn snapshot_options(&self) -> Value {
        let mut options = json!({"include_raw_samples":self.raw,"include_traces":self.traces,"include_runtime":true,"summary_limit":20});
        for (key, value) in [
            ("kind", &self.kind),
            ("path", &self.path),
            ("path_prefix", &self.prefix),
            ("sort", &self.sort),
        ] {
            if !value.is_empty() {
                options[key] = json!(value);
            }
        }
        if self.limit > 0 {
            options["limit"] = json!(self.limit);
        }
        options
    }
}

pub fn duration(value: &str) -> Result<Duration> {
    if value.is_empty() {
        return Err("duration must not be empty".into());
    }
    if value == "0" {
        return Ok(Duration::ZERO);
    }
    let mut rest = value;
    let mut seconds = 0.;
    while !rest.is_empty() {
        let count = rest
            .find(|c: char| !c.is_ascii_digit() && c != '.')
            .ok_or("duration needs a unit")?;
        let amount: f64 = rest[..count].parse()?;
        rest = &rest[count..];
        let (unit, scale) = [
            ("ns", 1e-9),
            ("us", 1e-6),
            ("µs", 1e-6),
            ("μs", 1e-6),
            ("ms", 1e-3),
            ("s", 1.),
            ("m", 60.),
            ("h", 3600.),
        ]
        .into_iter()
        .find(|(unit, _)| rest.starts_with(unit))
        .ok_or("invalid duration unit")?;
        seconds += amount * scale;
        rest = &rest[unit.len()..];
    }
    if !seconds.is_finite() || seconds < 0. || seconds > i64::MAX as f64 / 1e9 {
        return Err("duration must be finite and nonnegative".into());
    }
    Ok(Duration::try_from_secs_f64(seconds)?)
}

pub fn address_from_project(path: &Path) -> Result<String> {
    for child in [
        ".env.json",
        ".env",
        ".env.example.json",
        ".env.example",
        "godot_client/.env.json",
        "godot_client/.env",
        "godot_client/.env.example.json",
        "godot_client/.env.example",
    ] {
        let candidate = path.join(child);
        if candidate.try_exists()? {
            return address_from_file(&candidate);
        }
    }
    Err(format!("no supported env file found under {}", path.display()).into())
}

pub fn address_from_file(path: &Path) -> Result<String> {
    let raw = fs::read_to_string(path)?;
    let values: BTreeMap<String, Value> = if path.extension().is_some_and(|s| s == "json") {
        serde_json::from_str(&raw)?
    } else {
        raw.lines()
            .filter_map(|line| {
                let line = line.trim();
                if line.starts_with('#') {
                    return None;
                }
                let (key, value) = line.split_once('=')?;
                Some((
                    key.trim().into(),
                    json!(value.trim().trim_matches(['\'', '"'])),
                ))
            })
            .collect()
    };
    let string = |keys: &[&str]| {
        keys.iter()
            .find_map(|key| {
                values
                    .get(*key)
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
            })
            .unwrap_or("")
            .to_owned()
    };
    let url = string(&["metrics_live_server_url", "gdobs_url", "GDOBS_URL"]);
    if !url.is_empty() {
        return Ok(url);
    }
    let mut host = string(&["metrics_live_server_host", "gdobs_host", "GDOBS_HOST"]);
    let port = ["metrics_live_server_port", "gdobs_port", "GDOBS_PORT"]
        .iter()
        .find_map(|key| values.get(*key));
    if host.is_empty() && port.is_none() {
        return Err(
            "env file does not define metrics_live_server_url or metrics_live_server_host/port"
                .into(),
        );
    }
    if host.is_empty() {
        host = "127.0.0.1".into();
    }
    if host.starts_with("ws://") || host.starts_with("wss://") {
        return Ok(host);
    }
    let port = match port {
        Some(Value::String(v)) => v.trim().parse::<i64>()?,
        Some(Value::Number(v)) => v.as_f64().ok_or("invalid port")? as i64,
        None => 8765,
        _ => return Err("invalid endpoint port".into()),
    };
    if !(1..=65535).contains(&port) {
        return Err(format!("metrics live server port out of range: {port}").into());
    }
    Ok(format!("ws://{host}:{port}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flags_preserve_aliases_defaults_and_interspersed_top_arguments() {
        let args = [
            "top",
            "timers",
            "--url=ws://localhost:7777",
            "-limit",
            "3",
            "--raw=false",
            "--traces",
            "--timeout",
            "1m2.5s",
        ]
        .map(str::to_owned);
        let config = Config::parse(&args).unwrap();
        assert_eq!(config.addr, "ws://localhost:7777");
        assert_eq!(config.positional, ["timers"]);
        assert_eq!(config.timeout, Duration::from_millis(62500));
        assert_eq!(config.snapshot_options()["include_raw_samples"], false);
        assert_eq!(config.snapshot_options()["include_traces"], true);
        assert_eq!(config.snapshot_options()["limit"], 3);
        assert!(
            Config::parse(&[
                "--url".into(),
                "ws://localhost:7".into(),
                "--env".into(),
                "missing-file".into()
            ])
            .is_ok()
        );
        for invalid in ["", "NaN", "-1s", "1", "999999999999h"] {
            assert!(duration(invalid).is_err(), "{invalid}");
        }
        assert_eq!(duration("50ms").unwrap(), Duration::from_millis(50));
        assert!(Config::parse(&["--min-fps=NaN".into()]).is_err());
    }
}
