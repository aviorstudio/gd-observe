use crate::{Result, analysis, config::Config, model::*, transport};
use crossterm::event::{
    DisableMouseCapture, EnableMouseCapture, Event, EventStream, KeyCode, KeyEventKind,
    KeyModifiers, MouseButton, MouseEventKind,
};
use futures_util::StreamExt;
use ratatui::{
    DefaultTerminal, Frame,
    layout::{Constraint, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Paragraph, Row, Sparkline, Table, TableState, Tabs, Wrap},
};
use serde::Serialize;
use serde_json::Value;
use std::{collections::VecDeque, io, time::Duration};
use tokio::{
    sync::mpsc,
    task::JoinHandle,
    time::{interval, sleep},
};

const RETAIN_BYTES: usize = 8 << 20;
const TABS: [&str; 4] = ["Dashboard", "Logs", "Events", "Traces"];

struct Retained<T> {
    entries: VecDeque<(T, usize)>,
    bytes: usize,
    limit: usize,
}
impl<T> Retained<T> {
    fn new(limit: usize) -> Self {
        Self {
            entries: VecDeque::new(),
            bytes: 0,
            limit,
        }
    }
    fn push(&mut self, value: T, size: usize) {
        if size > RETAIN_BYTES {
            return;
        }
        while !self.entries.is_empty()
            && (self.entries.len() >= self.limit || self.bytes + size > RETAIN_BYTES)
        {
            self.bytes -= self.entries.pop_front().expect("nonempty queue").1;
        }
        self.bytes += size;
        self.entries.push_back((value, size));
    }
}

enum Network {
    Connected,
    Data(Vec<u8>),
    Disconnected,
}
struct Worker(JoinHandle<()>);
impl Drop for Worker {
    fn drop(&mut self) {
        self.0.abort();
    }
}

struct TerminalGuard;
impl Drop for TerminalGuard {
    fn drop(&mut self) {
        let _ = crossterm::execute!(io::stdout(), DisableMouseCapture);
        ratatui::restore();
    }
}

struct Dashboard {
    connected: bool,
    tab: usize,
    snapshot: Snapshot,
    metrics: Vec<MetricRow>,
    logs: Retained<LogEntry>,
    events: Retained<EventEntry>,
    traces: Retained<FrameTrace>,
    history: [VecDeque<u64>; 6],
    tables: [TableState; 4],
    list_area: Rect,
    tabs_area: Rect,
    detail_scroll: u16,
}

impl Default for Dashboard {
    fn default() -> Self {
        Self {
            connected: false,
            tab: 0,
            snapshot: Snapshot::default(),
            metrics: Vec::new(),
            logs: Retained::new(1000),
            events: Retained::new(1000),
            traces: Retained::new(300),
            history: std::array::from_fn(|_| VecDeque::new()),
            tables: std::array::from_fn(|_| TableState::default().with_selected(0)),
            list_area: Rect::default(),
            tabs_area: Rect::default(),
            detail_scroll: 0,
        }
    }
}

fn safe(text: impl AsRef<str>) -> String {
    text.as_ref()
        .chars()
        .filter(|c| !c.is_control() && *c != '\u{202e}' && *c != '\u{202d}')
        .collect()
}

fn details(value: &impl Serialize) -> String {
    let text = serde_json::to_string_pretty(value).unwrap_or_default();
    let mut result = String::new();
    for c in text.chars().take(65536) {
        if c == '\n' || (!c.is_control() && c != '\u{202e}' && c != '\u{202d}') {
            result.push(c);
        }
    }
    if text.chars().count() > 65536 {
        result.push_str("\n[Display truncated; use capture for the complete payload]");
    }
    result
}

impl Dashboard {
    fn ingest(&mut self, raw: &[u8]) {
        let Ok(value) = serde_json::from_slice::<Value>(raw) else {
            return;
        };
        match value["type"].as_str().unwrap_or("") {
            "snapshot" => {
                if let Ok(snapshot) = serde_json::from_value::<Snapshot>(value) {
                    let r = &snapshot.runtime;
                    for (history, value) in self.history.iter_mut().zip([
                        r.fps,
                        r.frame_delta_usec as f64,
                        r.process_time_usec as f64,
                        r.physics_process_time_usec as f64,
                        r.memory_static_bytes as f64,
                        r.draw_calls_in_frame as f64,
                    ]) {
                        if history.len() == 120 {
                            history.pop_front();
                        }
                        history.push_back(value.max(0.) as u64);
                    }
                    self.metrics = analysis::top(snapshot.metrics(), "", "p95", 0);
                    self.snapshot = snapshot;
                }
            }
            "log" => {
                if let Ok(value) = serde_json::from_value(value) {
                    self.logs.push(value, raw.len());
                }
            }
            "event" => {
                if let Ok(value) = serde_json::from_value(value) {
                    self.events.push(value, raw.len());
                }
            }
            "frame_trace" => {
                if let Ok(value) = serde_json::from_value(value) {
                    self.traces.push(value, raw.len());
                }
            }
            _ => {}
        }
        self.select(0);
    }

    fn len(&self) -> usize {
        match self.tab {
            0 => self.metrics.len(),
            1 => self.logs.entries.len(),
            2 => self.events.entries.len(),
            _ => self.traces.entries.len(),
        }
    }
    fn select(&mut self, delta: isize) {
        let selected = self.tables[self.tab]
            .selected()
            .unwrap_or(0)
            .saturating_add_signed(delta)
            .min(self.len().saturating_sub(1));
        self.tables[self.tab].select(Some(selected));
        self.detail_scroll = 0;
    }
    fn switch(&mut self, tab: usize) {
        self.tab = tab % 4;
        self.detail_scroll = 0;
    }
    fn input(&mut self, event: Event) -> bool {
        match event {
            Event::Key(key) if key.kind != KeyEventKind::Release => match key.code {
                KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                    return false;
                }
                KeyCode::Char('q') => return false,
                KeyCode::Tab | KeyCode::Right => self.switch(self.tab + 1),
                KeyCode::BackTab | KeyCode::Left => self.switch(self.tab + 3),
                KeyCode::Char(c @ '1'..='4') => self.switch(c as usize - '1' as usize),
                KeyCode::Down | KeyCode::Char('j') => self.select(1),
                KeyCode::Up | KeyCode::Char('k') => self.select(-1),
                KeyCode::PageDown => self.select(10),
                KeyCode::PageUp => self.select(-10),
                KeyCode::Home => self.select(isize::MIN),
                KeyCode::End => self.select(isize::MAX),
                _ => {}
            },
            Event::Mouse(mouse) => {
                let point = ratatui::layout::Position::new(mouse.column, mouse.row);
                match mouse.kind {
                    MouseEventKind::Down(MouseButton::Left) if self.tabs_area.contains(point) => {
                        let mut x = self.tabs_area.x + 1;
                        for (index, label) in TABS.iter().enumerate() {
                            let width = label.len() as u16 + 2;
                            if mouse.column >= x && mouse.column < x + width {
                                self.switch(index);
                                break;
                            }
                            x += width + 1;
                        }
                    }
                    MouseEventKind::Down(MouseButton::Left)
                        if self.list_area.contains(point) && mouse.row > self.list_area.y =>
                    {
                        let index = self.tables[self.tab].offset()
                            + usize::from(mouse.row - self.list_area.y - 1);
                        if index < self.len() {
                            self.tables[self.tab].select(Some(index));
                            self.detail_scroll = 0;
                        }
                    }
                    MouseEventKind::ScrollDown if self.list_area.contains(point) => self.select(3),
                    MouseEventKind::ScrollUp if self.list_area.contains(point) => self.select(-3),
                    MouseEventKind::ScrollDown => {
                        self.detail_scroll = self.detail_scroll.saturating_add(3)
                    }
                    MouseEventKind::ScrollUp => {
                        self.detail_scroll = self.detail_scroll.saturating_sub(3)
                    }
                    _ => {}
                }
            }
            _ => {}
        }
        true
    }

    fn render(&mut self, frame: &mut Frame, addr: &str) {
        let areas = Layout::vertical([
            Constraint::Length(2),
            Constraint::Length(3),
            Constraint::Min(0),
            Constraint::Length(1),
        ])
        .split(frame.area());
        let state = if self.connected {
            "connected"
        } else {
            "disconnected · reconnecting"
        };
        frame.render_widget(
            Paragraph::new(vec![
                Line::from(vec![
                    Span::styled(
                        "gdobs  ",
                        Style::default()
                            .fg(Color::Cyan)
                            .add_modifier(Modifier::BOLD),
                    ),
                    Span::raw(state),
                ]),
                Line::from(safe(addr)),
            ]),
            areas[0],
        );
        self.tabs_area = areas[1];
        frame.render_widget(
            Tabs::new(TABS)
                .select(self.tab)
                .highlight_style(
                    Style::default()
                        .fg(Color::Cyan)
                        .add_modifier(Modifier::BOLD),
                )
                .block(Block::default().borders(Borders::ALL)),
            areas[1],
        );
        frame.render_widget(
            Paragraph::new(
                "Click tabs/rows · wheel scroll · Tab/1–4 tabs · ↑↓ select · Ctrl+C quit",
            )
            .style(Style::default().fg(Color::DarkGray)),
            areas[3],
        );
        let body = if self.tab == 0 {
            self.overview(frame, areas[2])
        } else {
            areas[2]
        };
        let parts =
            Layout::vertical([Constraint::Percentage(55), Constraint::Percentage(45)]).split(body);
        let inner = Block::default().borders(Borders::ALL).inner(parts[0]);
        self.list_area = inner;
        let (headers, widths, rows, detail): (
            Vec<&str>,
            Vec<Constraint>,
            Vec<Row<'static>>,
            String,
        ) = match self.tab {
            0 => (
                vec!["Kind", "Metric", "P95", "Max / Value", "Count"],
                vec![
                    Constraint::Length(8),
                    Constraint::Min(8),
                    Constraint::Length(12),
                    Constraint::Length(12),
                    Constraint::Length(8),
                ],
                self.metrics
                    .iter()
                    .map(|row| {
                        Row::new(vec![
                            safe(&row.kind),
                            safe(&row.path),
                            analysis::usec(row.p95),
                            if row.kind == "timer" {
                                analysis::usec(row.max)
                            } else {
                                format!(
                                    "{} {}",
                                    if row.kind == "counter" {
                                        row.value
                                    } else {
                                        row.latest
                                    },
                                    safe(&row.unit)
                                )
                            },
                            row.count.to_string(),
                        ])
                    })
                    .collect(),
                self.metrics
                    .get(self.tables[0].selected().unwrap_or(0))
                    .map(details)
                    .unwrap_or_default(),
            ),
            1 => (
                vec!["Time", "Level", "Message"],
                vec![
                    Constraint::Length(12),
                    Constraint::Length(8),
                    Constraint::Min(8),
                ],
                self.logs
                    .entries
                    .iter()
                    .map(|(row, _)| {
                        Row::new(vec![
                            format!("{:.1}s", row.timestamp_usec as f64 / 1e6),
                            safe(&row.level),
                            safe(&row.message),
                        ])
                    })
                    .collect(),
                self.logs
                    .entries
                    .get(self.tables[1].selected().unwrap_or(0))
                    .map(|(row, _)| details(row))
                    .unwrap_or_default(),
            ),
            2 => (
                vec!["Time", "Event", "Internal"],
                vec![
                    Constraint::Length(12),
                    Constraint::Min(8),
                    Constraint::Length(8),
                ],
                self.events
                    .entries
                    .iter()
                    .map(|(row, _)| {
                        Row::new(vec![
                            format!("{:.1}s", row.timestamp_usec as f64 / 1e6),
                            safe(&row.name),
                            row.internal.to_string(),
                        ])
                    })
                    .collect(),
                self.events
                    .entries
                    .get(self.tables[2].selected().unwrap_or(0))
                    .map(|(row, _)| details(row))
                    .unwrap_or_default(),
            ),
            _ => (
                vec!["Frame", "Time", "Spans", "Slow", "Groups"],
                vec![
                    Constraint::Length(10),
                    Constraint::Length(12),
                    Constraint::Length(8),
                    Constraint::Length(6),
                    Constraint::Min(8),
                ],
                self.traces
                    .entries
                    .iter()
                    .map(|(row, _)| {
                        Row::new(vec![
                            row.frame.to_string(),
                            analysis::usec(row.total_usec as f64),
                            row.span_count.to_string(),
                            row.slow.to_string(),
                            safe(analysis::trace_groups(row)),
                        ])
                    })
                    .collect(),
                self.traces
                    .entries
                    .get(self.tables[3].selected().unwrap_or(0))
                    .map(|(row, _)| details(row))
                    .unwrap_or_default(),
            ),
        };
        frame.render_stateful_widget(
            Table::new(rows, widths)
                .header(Row::new(headers).style(Style::default().fg(Color::Cyan)))
                .row_highlight_style(Style::default().bg(Color::DarkGray))
                .block(Block::default().title(TABS[self.tab]).borders(Borders::ALL)),
            parts[0],
            &mut self.tables[self.tab],
        );
        frame.render_widget(
            Paragraph::new(detail)
                .wrap(Wrap { trim: false })
                .scroll((self.detail_scroll, 0))
                .block(
                    Block::default()
                        .title("Selected · fields and tags")
                        .borders(Borders::ALL),
                ),
            parts[1],
        );
    }

    fn overview(&self, frame: &mut Frame, area: Rect) -> Rect {
        if area.height < 18 {
            return area;
        }
        let parts = Layout::vertical([
            Constraint::Length(2),
            Constraint::Length(4),
            Constraint::Length(if area.height >= 32 { 10 } else { 4 }),
            Constraint::Min(0),
        ])
        .split(area);
        let s = &self.snapshot;
        let r = &s.runtime;
        frame.render_widget(Paragraph::new(format!("Capture {} · {} metrics · {} timers / {} gauges / {} counters · {} samples\nFPS {:.1} · frame {} · process {} · physics {}", if s.enabled { "enabled" } else { "disabled" }, s.metric_count, s.timer_count, s.gauge_count, s.counter_count, s.sample_count, r.fps, analysis::usec(r.frame_delta_usec as f64), analysis::usec(r.process_time_usec as f64), analysis::usec(r.physics_process_time_usec as f64))), parts[0]);
        let charts = Layout::horizontal([Constraint::Ratio(1, 6); 6]).split(parts[1]);
        for (index, label) in [
            "FPS",
            "Frame µs",
            "Process µs",
            "Physics µs",
            "Memory B",
            "Draw calls",
        ]
        .iter()
        .enumerate()
        {
            let values: Vec<_> = self.history[index].iter().copied().collect();
            frame.render_widget(
                Sparkline::default()
                    .block(Block::default().title(*label).borders(Borders::ALL))
                    .data(&values)
                    .style(Style::default().fg(Color::Cyan)),
                charts[index],
            );
        }
        let runtime = vec![
            format!(
                "Static {} / peak {} · video {} · textures {} · buffers {}",
                analysis::bytes(r.memory_static_bytes),
                analysis::bytes(r.memory_static_max_bytes),
                analysis::bytes(r.video_memory_bytes),
                analysis::bytes(r.texture_memory_bytes),
                analysis::bytes(r.buffer_memory_bytes)
            ),
            format!(
                "Nodes {} · orphans {} · objects {} · resources {}",
                r.node_count, r.orphan_node_count, r.object_count, r.resource_count
            ),
            format!(
                "Render objects {} · primitives {} · draws {}",
                r.render_objects_in_frame, r.render_primitives_in_frame, r.draw_calls_in_frame
            ),
            format!(
                "2D active {} · collisions {} · islands {}",
                r.physics_2d_active_objects,
                r.physics_2d_collision_pairs,
                r.physics_2d_island_count
            ),
            format!(
                "Navigation {} · audio latency {} · message buffer {}",
                analysis::usec(r.navigation_process_time_usec as f64),
                analysis::usec(r.audio_output_latency_usec as f64),
                analysis::bytes(r.message_buffer_max_bytes)
            ),
            format!(
                "Runtime samples {} · timestamp {:.1}s · traces {}",
                r.sample_count,
                r.timestamp_usec as f64 / 1e6,
                s.traces().len()
            ),
        ];
        frame.render_widget(
            Paragraph::new(runtime.into_iter().map(Line::from).collect::<Vec<_>>())
                .wrap(Wrap { trim: false })
                .block(Block::default().title("Runtime").borders(Borders::ALL)),
            parts[2],
        );
        parts[3]
    }
}

pub async fn run(config: &Config) -> Result<()> {
    let mut terminal: DefaultTerminal = ratatui::try_init()?;
    let _guard = TerminalGuard;
    crossterm::execute!(io::stdout(), EnableMouseCapture)?;
    let (sender, mut receiver) = mpsc::channel(4);
    let addr = config.addr.clone();
    let timeout = config.timeout;
    let _worker = Worker(tokio::spawn(async move {
        loop {
            if let Ok(mut socket) = transport::connect(&addr, timeout).await {
                if sender.send(Network::Connected).await.is_err() {
                    return;
                }
                while let Ok(raw) = transport::payload(&mut socket, None).await {
                    if sender.send(Network::Data(raw)).await.is_err() {
                        return;
                    }
                }
            }
            if sender.send(Network::Disconnected).await.is_err() {
                return;
            }
            sleep(Duration::from_secs(1)).await;
        }
    }));
    let mut state = Dashboard::default();
    let mut events = EventStream::new();
    let mut redraw = interval(Duration::from_millis(100));
    loop {
        tokio::select! {
            _ = redraw.tick() => terminal.draw(|frame| state.render(frame, &config.addr)).map(|_| ())?,
            event = events.next() => match event { Some(Ok(event)) => { if !state.input(event) { return Ok(()); } }, Some(Err(error)) => return Err(error.into()), None => return Ok(()) },
            message = receiver.recv() => match message { Some(Network::Connected) => state.connected = true, Some(Network::Disconnected) => state.connected = false, Some(Network::Data(raw)) => state.ingest(&raw), None => return Err("connection worker stopped".into()) },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::{Terminal, backend::TestBackend};
    use serde_json::json;

    #[test]
    fn mouse_tabs_rows_resize_and_untrusted_fields() {
        let mut dashboard = Dashboard::default();
        dashboard.ingest(json!({"type":"log","level":"warn","message":"hello\u{001b}[2J","fields":{"request":"abc"}}).to_string().as_bytes());
        let mut terminal = Terminal::new(TestBackend::new(100, 40)).unwrap();
        terminal
            .draw(|frame| dashboard.render(frame, "ws://localhost:8765"))
            .unwrap();
        dashboard.input(Event::Mouse(crossterm::event::MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column: 16,
            row: 3,
            modifiers: KeyModifiers::NONE,
        }));
        assert_eq!(dashboard.tab, 1);
        terminal
            .draw(|frame| dashboard.render(frame, "ws://localhost:8765"))
            .unwrap();
        let text = terminal
            .backend()
            .buffer()
            .content
            .iter()
            .map(ratatui::buffer::Cell::symbol)
            .collect::<String>();
        assert!(text.contains("hello"));
        assert!(text.contains("abc"));
        assert!(!text.contains('\u{001b}'));
        for (width, height) in [(1, 1), (30, 8), (120, 50)] {
            terminal.resize(Rect::new(0, 0, width, height)).unwrap();
            for tab in 0..4 {
                dashboard.switch(tab);
                terminal
                    .draw(|frame| dashboard.render(frame, "local"))
                    .unwrap();
            }
        }
    }

    #[test]
    fn retained_data_and_history_are_bounded() {
        let mut queue = Retained::new(3);
        for index in 0..10 {
            queue.push(index, RETAIN_BYTES / 2);
        }
        assert_eq!(
            queue
                .entries
                .iter()
                .map(|(value, _)| *value)
                .collect::<Vec<_>>(),
            vec![8, 9]
        );
        queue.push(99, RETAIN_BYTES + 1);
        assert_eq!(queue.entries.len(), 2);
        let mut dashboard = Dashboard::default();
        for _ in 0..130 {
            dashboard.ingest(br#"{"type":"snapshot","runtime":{"fps":60}}"#);
        }
        assert_eq!(dashboard.history[0].len(), 120);
        assert!(dashboard.history[0].iter().all(|value| *value == 60));
    }
}
