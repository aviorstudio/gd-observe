use crate::{Result, model::Snapshot};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::{
    sync::atomic::{AtomicU64, Ordering},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::{
    net::TcpStream,
    time::{Instant, timeout, timeout_at},
};
use tokio_tungstenite::{
    MaybeTlsStream, WebSocketStream, connect_async_with_config,
    tungstenite::{Message, protocol::WebSocketConfig},
};

pub const MAX_MESSAGE: usize = 32 << 20;
pub type Socket = WebSocketStream<MaybeTlsStream<TcpStream>>;

pub async fn connect(addr: &str, budget: Duration) -> Result<Socket> {
    let config = WebSocketConfig::default()
        .max_message_size(Some(MAX_MESSAGE))
        .max_frame_size(Some(MAX_MESSAGE));
    let (mut socket, _) =
        timeout(budget, connect_async_with_config(addr, Some(config), true)).await??;
    // Authentication is exclusively process-local; endpoint files cannot supply it.
    if let Ok(token) = std::env::var("GDOBS_AUTH_TOKEN")
        && !token.is_empty()
    {
        timeout(
            budget,
            socket.send(Message::Text(
                json!({"type":"auth","token":token}).to_string().into(),
            )),
        )
        .await??;
    }
    Ok(socket)
}

pub async fn payload(socket: &mut Socket, deadline: Option<Instant>) -> Result<Vec<u8>> {
    loop {
        let message = if let Some(deadline) = deadline {
            timeout_at(deadline, socket.next()).await?
        } else {
            socket.next().await
        };
        match message.ok_or("connection closed")?? {
            Message::Text(value) => return Ok(value.as_bytes().to_vec()),
            Message::Binary(value) => return Ok(value.to_vec()),
            Message::Close(_) => return Err("connection closed".into()),
            _ => {}
        }
    }
}

pub async fn snapshot(addr: &str, budget: Duration, options: Option<Value>) -> Result<Snapshot> {
    let deadline = Instant::now() + budget;
    let mut socket = connect(addr, budget).await?;
    let request = if let Some(options) = options {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let request = format!(
            "cli-{}-{}",
            SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        );
        timeout_at(
            deadline,
            socket.send(Message::Text(
                json!({"type":"snapshot_request","request_id":request,"options":options})
                    .to_string()
                    .into(),
            )),
        )
        .await??;
        Some(request)
    } else {
        None
    };
    loop {
        let raw = payload(&mut socket, Some(deadline)).await?;
        let Ok(value) = serde_json::from_slice::<Value>(&raw) else {
            continue;
        };
        if value["type"] != "snapshot"
            || request
                .as_ref()
                .is_some_and(|id| value["request_id"].as_str() != Some(id.as_str()))
        {
            continue;
        }
        return Ok(serde_json::from_value(value)?);
    }
}
