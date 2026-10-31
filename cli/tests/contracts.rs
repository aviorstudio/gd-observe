use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::{
    fs,
    path::PathBuf,
    process::{Command, Output},
    sync::atomic::{AtomicUsize, Ordering},
    time::Duration,
};
use tokio::{net::TcpListener, time::timeout};
use tokio_tungstenite::{accept_async, tungstenite::Message};

struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let path = std::env::temp_dir().join(format!(
            "gdobs-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn cli(args: &[&str]) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_gdobs"));
    command.args(args).env_remove("GDOBS_AUTH_TOKEN");
    command
}
async fn output(command: &mut Command) -> Output {
    let child = command
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    timeout(
        Duration::from_secs(5),
        tokio::task::spawn_blocking(move || child.wait_with_output()),
    )
    .await
    .unwrap()
    .unwrap()
    .unwrap()
}

#[tokio::test]
async fn auth_precedes_request_and_broadcasts_cannot_satisfy_filtered_snapshot() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = format!("ws://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut socket = accept_async(stream).await.unwrap();
        let first: Value =
            serde_json::from_slice(&socket.next().await.unwrap().unwrap().into_data()).unwrap();
        assert_eq!(first, json!({"type":"auth","token":"process-only-secret"}));
        let request: Value =
            serde_json::from_slice(&socket.next().await.unwrap().unwrap().into_data()).unwrap();
        assert_eq!(request["type"], "snapshot_request");
        assert_eq!(request["options"]["path_prefix"], "combat");
        assert_eq!(request["options"]["include_raw_samples"], true);
        for response in [
            json!({"type":"hello"}),
            json!({"type":"snapshot","metric_count":999}),
            json!({"type":"snapshot","request_id":"wrong","metric_count":888}),
            json!({"type":"snapshot","request_id":request["request_id"],"metric_count":2,"enabled":true}),
        ] {
            socket
                .send(Message::Text(response.to_string().into()))
                .await
                .unwrap();
        }
    });
    let result = output(
        cli(&[
            "snapshot",
            "--url",
            &addr,
            "--path-prefix",
            "combat",
            "--raw",
            "--timeout",
            "1s",
        ])
        .env("GDOBS_AUTH_TOKEN", "process-only-secret"),
    )
    .await;
    server.await.unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    let value: Value = serde_json::from_slice(&result.stdout).unwrap();
    assert_eq!(value["metric_count"], 2);
    assert!(value["metrics"].is_null());
    assert!(!String::from_utf8_lossy(&result.stdout).contains("process-only-secret"));
    assert!(result.stderr.is_empty());
}

#[tokio::test]
async fn endpoint_files_do_not_supply_auth_and_wait_filters_events() {
    let root = Temp::new();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = format!("ws://{}", listener.local_addr().unwrap());
    fs::write(
        root.0.join(".env.json"),
        json!({"gdobs_url":addr,"GDOBS_AUTH_TOKEN":"must-not-load"}).to_string(),
    )
    .unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut socket = accept_async(stream).await.unwrap();
        assert!(
            timeout(Duration::from_millis(50), socket.next())
                .await
                .is_err(),
            "client sent unexpected authentication"
        );
        for event in [
            json!({"type":"event","name":"wrong"}),
            json!({"type":"log","name":"ready"}),
            json!({"type":"event","name":"ready","fields":{"id":"abc"}}),
        ] {
            socket
                .send(Message::Text(event.to_string().into()))
                .await
                .unwrap();
        }
    });
    let result = output(&mut cli(&[
        "wait",
        "--project",
        root.0.to_str().unwrap(),
        "--for",
        "event",
        "--name",
        "ready",
        "--timeout",
        "1s",
    ]))
    .await;
    server.await.unwrap();
    assert!(result.status.success());
    let value: Value = serde_json::from_slice(&result.stdout).unwrap();
    assert_eq!(value["matched"]["fields"]["id"], "abc");
}

#[tokio::test]
async fn waits_have_an_overall_deadline_and_machine_readable_failure() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = format!("ws://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let _socket = accept_async(stream).await.unwrap();
        tokio::time::sleep(Duration::from_millis(500)).await;
    });
    let result = output(&mut cli(&[
        "wait",
        "--addr",
        &addr,
        "--timeout",
        "80ms",
        "--for",
        "log",
        "--level",
        "error",
    ]))
    .await;
    assert!(!result.status.success());
    assert_eq!(
        serde_json::from_slice::<Value>(&result.stdout).unwrap(),
        json!({"ok":false,"timeout":true,"target":{"Kind":"log","Name":"","Level":"error"}})
    );
    server.abort();
}

#[tokio::test]
async fn offline_top_diff_and_budget_keep_the_public_json_contract() {
    let root = Temp::new();
    let before = root.0.join("before.json");
    let after = root.0.join("after.json");
    let budget = root.0.join("budget.json");
    fs::write(&before,json!({"metrics":[{"path":"combat.a","key":"a","kind":"timer","p95":100},{"path":"combat.b","key":"b","kind":"timer","p95":500}]}).to_string()).unwrap();
    fs::write(&after,json!({"metrics":[{"path":"combat.a","key":"a","kind":"timer","p95":900},{"path":"combat.c","key":"c","kind":"gauge","latest":5}],"runtime":{"fps":30}}).to_string()).unwrap();
    fs::write(
        &budget,
        json!({"timers":{"combat.a":{"p95_usec":500}},"runtime":{"min_fps":60}}).to_string(),
    )
    .unwrap();
    let result = output(&mut cli(&[
        "top",
        "timers",
        "--file",
        before.to_str().unwrap(),
        "--limit",
        "1",
    ]))
    .await;
    assert!(result.status.success());
    let value: Value = serde_json::from_slice(&result.stdout).unwrap();
    assert_eq!(value[0]["key"], "b");
    assert_eq!(value.as_array().unwrap().len(), 1);
    let result = output(&mut cli(&[
        "diff",
        before.to_str().unwrap(),
        after.to_str().unwrap(),
    ]))
    .await;
    assert!(result.status.success());
    let value: Value = serde_json::from_slice(&result.stdout).unwrap();
    assert_eq!(value["changes"][0]["p95_delta"], 800.);
    assert_eq!(value["changes"][1]["status"], "added");
    assert_eq!(value["changes"].as_array().unwrap().len(), 2);
    let result = output(&mut cli(&[
        "assert",
        "--budget",
        budget.to_str().unwrap(),
        "--file",
        after.to_str().unwrap(),
    ]))
    .await;
    assert!(!result.status.success());
    let value: Value = serde_json::from_slice(&result.stdout).unwrap();
    assert_eq!(value["ok"], false);
    assert_eq!(value["failures"].as_array().unwrap().len(), 2);
}

#[tokio::test]
async fn capture_produces_all_summary_artifacts() {
    let root = Temp::new();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = format!("ws://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut socket = accept_async(stream).await.unwrap();
        let request: Value =
            serde_json::from_slice(&socket.next().await.unwrap().unwrap().into_data()).unwrap();
        socket.send(Message::Text(json!({"type":"snapshot","request_id":request["request_id"],"enabled":true,"metric_count":1,"metrics":[{"kind":"timer","path":"combat.tick","count":1,"p95":1200}],"runtime":{"fps":60}}).to_string().into())).await.unwrap();
    });
    let result = output(&mut cli(&[
        "capture",
        "--addr",
        &addr,
        "--out",
        root.0.to_str().unwrap(),
        "--timeout",
        "1s",
    ]))
    .await;
    server.await.unwrap();
    assert!(result.status.success());
    for file in [
        "snapshot.json",
        "summary.json",
        "diagnose.json",
        "status.json",
        "metadata.json",
    ] {
        let _: Value = serde_json::from_slice(&fs::read(root.0.join(file)).unwrap()).unwrap();
    }
    assert!(
        fs::read_to_string(root.0.join("summary.md"))
            .unwrap()
            .contains("combat.tick")
    );
}
