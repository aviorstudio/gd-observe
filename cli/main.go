package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/table"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/gorilla/websocket"
)

const (
	defaultAddr  = "ws://127.0.0.1:8765"
	tabDashboard = 0
	tabLogs      = 1
	tabEvents    = 2
	tabTraces    = 3
)

type metricRow struct {
	Path        string         `json:"path"`
	Key         string         `json:"key"`
	Kind        string         `json:"kind"`
	Unit        string         `json:"unit"`
	Tags        map[string]any `json:"tags"`
	Count       int            `json:"count"`
	Total       float64        `json:"total"`
	Min         float64        `json:"min"`
	Max         float64        `json:"max"`
	Avg         float64        `json:"avg"`
	P50         float64        `json:"p50"`
	P95         float64        `json:"p95"`
	P99         float64        `json:"p99"`
	Latest      float64        `json:"latest"`
	Value       float64        `json:"value"`
	LatestDelta float64        `json:"latest_delta"`
}

type snapshot struct {
	Type          string         `json:"type"`
	Version       int            `json:"version"`
	RequestID     string         `json:"request_id"`
	TimestampUsec int64          `json:"timestamp_usec"`
	Enabled       bool           `json:"enabled"`
	MetricCount   int            `json:"metric_count"`
	TimerCount    int            `json:"timer_count"`
	GaugeCount    int            `json:"gauge_count"`
	CounterCount  int            `json:"counter_count"`
	SampleCount   int            `json:"sample_count"`
	Metrics       []metricRow    `json:"metrics"`
	Runtime       runtimeStats   `json:"runtime"`
	RecentTraces  []frameTrace   `json:"recent_frame_traces"`
	Summary       any            `json:"summary"`
	RuntimeDeltas []any          `json:"runtime_deltas"`
	Live          map[string]any `json:"live"`
}

type runtimeStats struct {
	TimestampUsec           int64   `json:"timestamp_usec"`
	SampleCount             int     `json:"sample_count"`
	FPS                     float64 `json:"fps"`
	FrameDeltaUsec          int64   `json:"frame_delta_usec"`
	ProcessTimeUsec         int64   `json:"process_time_usec"`
	PhysicsProcessTimeUsec  int64   `json:"physics_process_time_usec"`
	NavigationProcessUsec   int64   `json:"navigation_process_time_usec"`
	MemoryStaticBytes       int64   `json:"memory_static_bytes"`
	MemoryStaticMaxBytes    int64   `json:"memory_static_max_bytes"`
	MessageBufferMaxBytes   int64   `json:"message_buffer_max_bytes"`
	ObjectCount             int     `json:"object_count"`
	ResourceCount           int     `json:"resource_count"`
	NodeCount               int     `json:"node_count"`
	OrphanNodeCount         int     `json:"orphan_node_count"`
	RenderObjectsInFrame    int     `json:"render_objects_in_frame"`
	RenderPrimitivesInFrame int     `json:"render_primitives_in_frame"`
	DrawCallsInFrame        int     `json:"draw_calls_in_frame"`
	VideoMemoryBytes        int64   `json:"video_memory_bytes"`
	TextureMemoryBytes      int64   `json:"texture_memory_bytes"`
	BufferMemoryBytes       int64   `json:"buffer_memory_bytes"`
	Physics2DActiveObjects  int     `json:"physics_2d_active_objects"`
	Physics2DCollisionPairs int     `json:"physics_2d_collision_pairs"`
	Physics2DIslandCount    int     `json:"physics_2d_island_count"`
	AudioOutputLatencyUsec  int64   `json:"audio_output_latency_usec"`
}

type connectedMsg struct {
	conn *websocket.Conn
}

type reconnectMsg struct{}

type readMsg struct {
	typeName string
	raw      string
	snap     snapshot
	log      logEntry
	event    eventEntry
	trace    frameTrace
	err      error
}

type logEntry struct {
	Type          string         `json:"type"`
	TimestampUsec int64          `json:"timestamp_usec"`
	Level         string         `json:"level"`
	Message       string         `json:"message"`
	Tags          map[string]any `json:"tags"`
	Fields        map[string]any `json:"fields"`
}

type eventEntry struct {
	Type          string         `json:"type"`
	TimestampUsec int64          `json:"timestamp_usec"`
	Name          string         `json:"name"`
	Internal      bool           `json:"internal"`
	Tags          map[string]any `json:"tags"`
	Fields        map[string]any `json:"fields"`
}

type traceSpan struct {
	Path          string         `json:"path"`
	DurationUsec  int64          `json:"duration_usec"`
	TimestampUsec int64          `json:"timestamp_usec"`
	Tags          map[string]any `json:"tags"`
}

type frameTrace struct {
	Type          string      `json:"type"`
	TimestampUsec int64       `json:"timestamp_usec"`
	Frame         int64       `json:"frame"`
	SpanCount     int         `json:"span_count"`
	TotalUsec     int64       `json:"total_usec"`
	Slow          bool        `json:"slow"`
	Spans         []traceSpan `json:"spans"`
}

type waitCriteria struct {
	Kind  string
	Name  string
	Level string
}

type assertCriteria struct {
	Metric       string
	MaxP95Usec   float64
	MinFPS       float64
	MaxFrameUsec float64
}

type model struct {
	addr      string
	conn      *websocket.Conn
	connected bool
	status    string
	activeTab int
	width     int
	height    int

	table table.Model
	page  viewport.Model

	snapshot      snapshot
	rows          []metricRow
	visibleRows   []metricRow
	logs          []logEntry
	events        []eventEntry
	traces        []frameTrace
	selectedLog   int
	selectedEvent int
	selectedTrace int
	history       map[string][]float64
}

var (
	baseStyle         = lipgloss.NewStyle().Padding(0, 1)
	titleStyle        = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("39"))
	statusStyle       = lipgloss.NewStyle().Foreground(lipgloss.Color("245"))
	okStyle           = lipgloss.NewStyle().Foreground(lipgloss.Color("42"))
	warnStyle         = lipgloss.NewStyle().Foreground(lipgloss.Color("214"))
	panelStyle        = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).Padding(0, 1)
	selectedLineStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("229")).Background(lipgloss.Color("57"))
	sectionStyle      = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("111"))
)

func initialModel(addr string) model {
	columns := []table.Column{
		{Title: "Path", Width: 42},
		{Title: "K", Width: 3},
		{Title: "Cnt", Width: 5},
		{Title: "Now", Width: 8},
		{Title: "Avg", Width: 8},
		{Title: "P95", Width: 8},
		{Title: "Bar", Width: 14},
	}
	t := table.New(table.WithColumns(columns), table.WithFocused(true), table.WithHeight(10))
	t.SetStyles(defaultTableStyles())

	return model{
		addr:      addr,
		status:    "connecting",
		activeTab: tabDashboard,
		table:     t,
		page:      viewport.New(80, 24),
		history:   make(map[string][]float64),
	}
}

func defaultTableStyles() table.Styles {
	styles := table.DefaultStyles()
	styles.Header = styles.Header.BorderStyle(lipgloss.NormalBorder()).BorderForeground(lipgloss.Color("240")).BorderBottom(true).Bold(true)
	styles.Selected = styles.Selected.Foreground(lipgloss.Color("229")).Background(lipgloss.Color("57")).Bold(false)
	return styles
}

func (m model) Init() tea.Cmd {
	return connectCmd(m.addr)
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		m.resize()
		return m, nil
	case connectedMsg:
		m.conn = msg.conn
		m.connected = true
		m.status = "connected"
		return m, readCmd(m.conn)
	case reconnectMsg:
		if m.connected {
			return m, nil
		}
		m.status = "connecting"
		return m, connectCmd(m.addr)
	case readMsg:
		if msg.err != nil {
			m.connected = false
			m.status = "disconnected: " + msg.err.Error()
			if m.conn != nil {
				_ = m.conn.Close()
				m.conn = nil
			}
			return m, reconnectLaterCmd()
		}
		if msg.typeName == "snapshot" {
			m.snapshot = msg.snap
			m.rows = msg.snap.Metrics
			m.recordHistory(msg.snap)
			m.refreshRows()
		} else if msg.typeName == "log" {
			m.logs = appendBounded(m.logs, msg.log, 1000)
		} else if msg.typeName == "event" {
			m.events = appendBounded(m.events, msg.event, 1000)
		} else if msg.typeName == "frame_trace" {
			m.traces = appendBounded(m.traces, msg.trace, 300)
		}
		m.syncPageContent()
		return m, readCmd(m.conn)
	case tea.MouseMsg:
		if m.selectTabWithMouse(msg) {
			m.syncPageContent()
			return m, nil
		}
		if m.selectRowWithMouse(msg) {
			m.syncPageContent()
			return m, nil
		}
		if m.scrollPageWithMouse(msg) {
			return m, nil
		}
	case tea.KeyMsg:
		if msg.String() == "ctrl+c" {
			if m.conn != nil {
				_ = m.conn.Close()
			}
			return m, tea.Quit
		}
		return m, nil
	}

	var cmd tea.Cmd
	m.table, cmd = m.table.Update(msg)
	m.syncPageContent()
	return m, cmd
}

func (m model) View() string {
	if m.width == 0 {
		return "connecting..."
	}
	page := m.page
	view := page.View()
	if page.TotalLineCount() > page.Height {
		view = lipgloss.JoinHorizontal(lipgloss.Top, view, renderScrollbar(page.ScrollPercent(), page.Height))
	}
	return baseStyle.Width(m.width).Render(view)
}

func (m model) renderBody() string {
	parts := []string{
		m.renderTabs(),
		m.renderHeader(),
	}
	switch m.activeTab {
	case tabLogs:
		parts = append(parts, m.renderLogsTab())
	case tabEvents:
		parts = append(parts, m.renderEventsTab())
	case tabTraces:
		parts = append(parts, m.renderTracesTab())
	default:
		parts = append(parts,
			m.renderOverview(),
			m.renderCharts(),
			m.renderRuntimeGrid(),
			m.renderHotspotHeader(),
			m.table.View(),
			m.renderSelectedMetric(),
		)
	}
	return strings.Join(parts, "\n")
}

func (m *model) resize() {
	contentWidth := max(48, m.width-4)
	m.page.Width = contentWidth
	m.page.Height = max(1, m.height-2)
	m.table.SetColumns(metricColumns(contentWidth))
	tableHeight := tableHeightFor(m.height, m.layoutMode())
	m.table.SetHeight(tableHeight)
	m.refreshRows()
	m.syncPageContent()
}

func (m *model) refreshRows() {
	rows := orderRowsByP95(m.rows)
	m.visibleRows = rows
	tableRows := make([]table.Row, 0, len(rows))
	for _, row := range rows {
		tableRows = append(tableRows, metricTableRow(row, m.width))
	}
	m.table.SetRows(tableRows)
}

func (m *model) syncPageContent() {
	if m.width == 0 {
		return
	}
	m.page.SetContent(m.renderBody())
}
func (m *model) scrollPageWithMouse(msg tea.MouseMsg) bool {
	m.syncPageContent()
	switch msg.Type {
	case tea.MouseWheelUp:
		m.page.LineUp(3)
		return true
	case tea.MouseWheelDown:
		m.page.LineDown(3)
		return true
	default:
		return false
	}
}

func (m *model) selectTabWithMouse(msg tea.MouseMsg) bool {
	if msg.Type != tea.MouseLeft || msg.Y != 0 {
		return false
	}
	x := msg.X - 1
	if x < 0 {
		return false
	}
	for _, tab := range tabHitboxes() {
		if x >= tab.start && x < tab.end {
			m.activeTab = tab.index
			m.page.GotoTop()
			return true
		}
	}
	return false
}

func (m *model) selectRowWithMouse(msg tea.MouseMsg) bool {
	if msg.Type != tea.MouseLeft {
		return false
	}
	line := msg.Y + m.page.YOffset
	switch m.activeTab {
	case tabLogs:
		index := line - 6
		if index >= 0 && index < len(m.logs) {
			m.selectedLog = index
			return true
		}
	case tabEvents:
		index := line - 6
		if index >= 0 && index < len(m.events) {
			m.selectedEvent = index
			return true
		}
	case tabTraces:
		index := traceIndexAtLine(m.traces, line-6)
		if index >= 0 {
			m.selectedTrace = index
			return true
		}
	}
	return false
}

func traceIndexAtLine(traces []frameTrace, line int) int {
	if line < 0 {
		return -1
	}
	cursor := 0
	for index, trace := range traces {
		blockHeight := 1 + min(len(trace.Spans), 5)
		if line >= cursor && line < cursor+blockHeight {
			return index
		}
		cursor += blockHeight
	}
	return -1
}

type tabHitbox struct {
	index int
	start int
	end   int
}

func tabHitboxes() []tabHitbox {
	labels := []string{" Dashboard ", " Logs ", " Events ", " Traces "}
	hitboxes := make([]tabHitbox, 0, len(labels))
	x := 0
	for index, label := range labels {
		hitboxes = append(hitboxes, tabHitbox{index: index, start: x, end: x + len(label)})
		x += len(label)
	}
	return hitboxes
}

func (m model) renderTabs() string {
	tabs := []string{
		m.renderTab(tabDashboard, "Dashboard"),
		m.renderTab(tabLogs, "Logs"),
		m.renderTab(tabEvents, "Events"),
		m.renderTab(tabTraces, "Traces"),
	}
	return lipgloss.JoinHorizontal(lipgloss.Top, tabs...)
}

func (m model) renderTab(index int, label string) string {
	style := lipgloss.NewStyle().Padding(0, 1).Foreground(lipgloss.Color("245")).Border(lipgloss.NormalBorder(), false, false, true, false).BorderForeground(lipgloss.Color("238"))
	if m.activeTab == index {
		style = style.Bold(true).Foreground(lipgloss.Color("39")).BorderForeground(lipgloss.Color("39"))
	}
	return style.Render(label)
}

func (m model) renderHeader() string {
	state := warnStyle.Render(m.status)
	if m.connected {
		state = okStyle.Render(m.status)
	}
	return titleStyle.Render("gd-metrics") + " " + statusStyle.Render(m.layoutMode()) + " " + statusStyle.Render(m.addr) + " " + state
}

func (m model) renderOverview() string {
	enabled := "disabled"
	if m.snapshot.Enabled {
		enabled = "enabled"
	}
	cards := []string{
		statusCard("capture", enabled, m.snapshot.Enabled),
		statusCard("socket", connectedLabel(m.connected), m.connected),
		valueCard("fps", formatFPS(m.snapshot.Runtime.FPS), healthBar(m.snapshot.Runtime.FPS, 60, 10)),
		valueCard("frame", formatUsec(float64(m.snapshot.Runtime.FrameDeltaUsec)), healthBar(float64(m.snapshot.Runtime.FrameDeltaUsec), 16666, 10)),
		valueCard("metrics", fmt.Sprintf("%d", m.snapshot.MetricCount), splitBar([]int{m.snapshot.TimerCount, m.snapshot.GaugeCount, m.snapshot.CounterCount}, 10)),
		valueCard("samples", fmt.Sprintf("%d", m.snapshot.SampleCount), barFromRatio(float64(m.snapshot.SampleCount%120)/120, 10)),
		valueCard("memory", formatBytes(m.snapshot.Runtime.MemoryStaticBytes), barFromRatio(memoryRatio(m.snapshot.Runtime), 10)),
		valueCard("updated", formatTimestamp(m.snapshot.TimestampUsec), "──────────"),
	}
	return wrapCards(cards, max(44, m.width-4), 20)
}

func (m model) renderCharts() string {
	chartWidth := chartWidthFor(m.width)
	charts := []string{
		chartPanel("FPS", m.history["fps"], chartWidth, formatFPS(lastValue(m.history["fps"])), "60fps target"),
		chartPanel("Frame", m.history["frame"], chartWidth, formatUsec(lastValue(m.history["frame"])), "16.67ms budget"),
		chartPanel("Process", m.history["process"], chartWidth, formatUsec(lastValue(m.history["process"])), "main loop"),
		chartPanel("Physics", m.history["physics"], chartWidth, formatUsec(lastValue(m.history["physics"])), "physics loop"),
		chartPanel("Memory", m.history["memory"], chartWidth, formatBytes(int64(lastValue(m.history["memory"]))), "static heap"),
		chartPanel("Draws", m.history["draws"], chartWidth, fmt.Sprintf("%.0f", lastValue(m.history["draws"])), "per frame"),
	}
	return wrapCards(charts, max(44, m.width-4), chartWidth+8)
}

func (m model) renderRuntimeGrid() string {
	r := m.snapshot.Runtime
	items := []string{
		kv("runtime_samples", fmt.Sprintf("%d", r.SampleCount)),
		kv("runtime_time", formatTimestamp(r.TimestampUsec)),
		kv("fps", formatFPS(r.FPS)),
		kv("frame_delta", formatUsec(float64(r.FrameDeltaUsec))),
		kv("process", formatUsec(float64(r.ProcessTimeUsec))),
		kv("physics", formatUsec(float64(r.PhysicsProcessTimeUsec))),
		kv("navigation", formatUsec(float64(r.NavigationProcessUsec))),
		kv("memory_static", formatBytes(r.MemoryStaticBytes)),
		kv("memory_static_max", formatBytes(r.MemoryStaticMaxBytes)),
		kv("message_buffer_max", formatBytes(r.MessageBufferMaxBytes)),
		kv("objects", fmt.Sprintf("%d", r.ObjectCount)),
		kv("resources", fmt.Sprintf("%d", r.ResourceCount)),
		kv("nodes", fmt.Sprintf("%d", r.NodeCount)),
		kv("orphan_nodes", fmt.Sprintf("%d", r.OrphanNodeCount)),
		kv("render_objects", fmt.Sprintf("%d", r.RenderObjectsInFrame)),
		kv("primitives", fmt.Sprintf("%d", r.RenderPrimitivesInFrame)),
		kv("draw_calls", fmt.Sprintf("%d", r.DrawCallsInFrame)),
		kv("video_mem", formatBytes(r.VideoMemoryBytes)),
		kv("texture_mem", formatBytes(r.TextureMemoryBytes)),
		kv("buffer_mem", formatBytes(r.BufferMemoryBytes)),
		kv("phys2d_objects", fmt.Sprintf("%d", r.Physics2DActiveObjects)),
		kv("phys2d_pairs", fmt.Sprintf("%d", r.Physics2DCollisionPairs)),
		kv("phys2d_islands", fmt.Sprintf("%d", r.Physics2DIslandCount)),
		kv("audio_latency", formatUsec(float64(r.AudioOutputLatencyUsec))),
	}
	return panelStyle.Width(max(44, m.width-6)).Render(sectionStyle.Render("Runtime") + "\n" + wrapInline(items, max(36, m.width-10)))
}

func (m model) renderHotspotHeader() string {
	counts := fmt.Sprintf("timers=%d gauges=%d counters=%d", m.snapshot.TimerCount, m.snapshot.GaugeCount, m.snapshot.CounterCount)
	return sectionStyle.Render("Hotspots") + " " + statusStyle.Render("sorted=p95 "+counts)
}

func (m model) renderSelectedMetric() string {
	if len(m.visibleRows) == 0 {
		return panelStyle.Width(max(44, m.width-6)).Render(sectionStyle.Render("Selected Metric") + "\n" + statusStyle.Render("no metrics received yet"))
	}
	index := m.table.Cursor()
	if index < 0 || index >= len(m.visibleRows) {
		index = 0
	}
	row := m.visibleRows[index]
	tagText := formatMap(row.Tags)
	fields := []string{
		kv("path", row.Path),
		kv("key", row.Key),
		kv("kind", row.Kind),
		kv("unit", row.Unit),
		kv("tags", tagText),
		kv("count", fmt.Sprintf("%d", row.Count)),
		kv("total", formatMetricValue(row.Total, row.Unit)),
		kv("min", formatMetricValue(row.Min, row.Unit)),
		kv("max", formatMetricValue(row.Max, row.Unit)),
		kv("avg", formatMetricValue(row.Avg, row.Unit)),
		kv("p50", formatMetricValue(row.P50, row.Unit)),
		kv("p95", formatMetricValue(row.P95, row.Unit)),
		kv("p99", formatMetricValue(row.P99, row.Unit)),
		kv("latest", formatMetricValue(row.Latest, row.Unit)),
		kv("value", formatMetricValue(row.Value, row.Unit)),
		kv("delta", formatMetricValue(row.LatestDelta, row.Unit)),
	}
	visuals := okStyle.Render(barForRow(row, max(10, min(36, m.width-18))))
	return panelStyle.Width(max(44, m.width-6)).Render(sectionStyle.Render("Selected Metric") + " " + visuals + "\n" + wrapInline(fields, max(36, m.width-10)))
}

func (m model) renderLogsTab() string {
	lines := []string{sectionStyle.Render("Logs") + " " + statusStyle.Render(fmt.Sprintf("count=%d", len(m.logs)))}
	if len(m.logs) == 0 {
		lines = append(lines, statusStyle.Render("waiting for explicit GdMetrics.log entries"))
		return strings.Join(lines, "\n")
	}
	lines = append(lines, m.renderSelectedLog())
	for index, entry := range m.logs {
		style := statusStyle
		if entry.Level == "error" {
			style = warnStyle
		} else if entry.Level == "warn" {
			style = warnStyle
		} else if entry.Level == "info" {
			style = okStyle
		}
		line := fmt.Sprintf("%s %s %s %s %s", formatTimestamp(entry.TimestampUsec), style.Render(entry.Level), entry.Message, statusStyle.Render(formatMap(entry.Tags)), statusStyle.Render(formatMap(entry.Fields)))
		if index == clampIndex(m.selectedLog, len(m.logs)) {
			line = selectedLineStyle.Render(line)
		}
		lines = append(lines, line)
	}
	return panelStyle.Width(rawPanelWidth(m.width)).Render(strings.Join(lines, "\n"))
}

func (m model) renderEventsTab() string {
	lines := []string{sectionStyle.Render("Events") + " " + statusStyle.Render(fmt.Sprintf("count=%d", len(m.events)))}
	if len(m.events) == 0 {
		lines = append(lines, statusStyle.Render("waiting for explicit GdMetrics.event entries"))
		return strings.Join(lines, "\n")
	}
	lines = append(lines, m.renderSelectedEvent())
	for index, entry := range m.events {
		kind := "domain"
		if entry.Internal {
			kind = "internal"
		}
		line := fmt.Sprintf("%s %s %s %s %s", formatTimestamp(entry.TimestampUsec), okStyle.Render(entry.Name), statusStyle.Render(kind), statusStyle.Render(formatMap(entry.Tags)), statusStyle.Render(formatMap(entry.Fields)))
		if index == clampIndex(m.selectedEvent, len(m.events)) {
			line = selectedLineStyle.Render(line)
		}
		lines = append(lines, line)
	}
	return panelStyle.Width(rawPanelWidth(m.width)).Render(strings.Join(lines, "\n"))
}

func (m model) renderTracesTab() string {
	lines := []string{sectionStyle.Render("Frame Traces") + " " + statusStyle.Render(fmt.Sprintf("count=%d", len(m.traces)))}
	if len(m.traces) == 0 {
		lines = append(lines, statusStyle.Render("waiting for timer-generated frame traces"))
		return strings.Join(lines, "\n")
	}
	lines = append(lines, m.renderSelectedTrace())
	for index, trace := range m.traces {
		label := okStyle.Render("frame")
		if trace.Slow {
			label = warnStyle.Render("slow")
		}
		line := fmt.Sprintf("%s %s=%d total=%s spans=%d", formatTimestamp(trace.TimestampUsec), label, trace.Frame, formatUsec(float64(trace.TotalUsec)), trace.SpanCount)
		if index == clampIndex(m.selectedTrace, len(m.traces)) {
			line = selectedLineStyle.Render(line)
		}
		lines = append(lines, line)
		for _, span := range topTraceSpans(trace.Spans, 5) {
			lines = append(lines, fmt.Sprintf("  %s %s %s", formatUsec(float64(span.DurationUsec)), span.Path, statusStyle.Render(formatMap(span.Tags))))
		}
	}
	return panelStyle.Width(rawPanelWidth(m.width)).Render(strings.Join(lines, "\n"))
}

func (m model) renderSelectedLog() string {
	index := clampIndex(m.selectedLog, len(m.logs))
	entry := m.logs[index]
	fields := []string{
		kv("time", formatTimestamp(entry.TimestampUsec)),
		kv("level", entry.Level),
		kv("message", entry.Message),
		kv("tags", formatMap(entry.Tags)),
		kv("fields", formatMap(entry.Fields)),
	}
	return panelStyle.Width(rawPanelWidth(m.width)).Render(sectionStyle.Render("Selected Log") + "\n" + wrapInline(fields, max(36, m.width-10)))
}

func (m model) renderSelectedEvent() string {
	index := clampIndex(m.selectedEvent, len(m.events))
	entry := m.events[index]
	kind := "domain"
	if entry.Internal {
		kind = "internal"
	}
	fields := []string{
		kv("time", formatTimestamp(entry.TimestampUsec)),
		kv("name", entry.Name),
		kv("kind", kind),
		kv("tags", formatMap(entry.Tags)),
		kv("fields", formatMap(entry.Fields)),
	}
	return panelStyle.Width(rawPanelWidth(m.width)).Render(sectionStyle.Render("Selected Event") + "\n" + wrapInline(fields, max(36, m.width-10)))
}

func (m model) renderSelectedTrace() string {
	index := clampIndex(m.selectedTrace, len(m.traces))
	trace := m.traces[index]
	fields := []string{
		kv("time", formatTimestamp(trace.TimestampUsec)),
		kv("frame", fmt.Sprintf("%d", trace.Frame)),
		kv("total", formatUsec(float64(trace.TotalUsec))),
		kv("spans", fmt.Sprintf("%d", trace.SpanCount)),
		kv("slow", fmt.Sprintf("%t", trace.Slow)),
		kv("top_paths", traceGroupSummary(trace.Spans, 3)),
	}
	return panelStyle.Width(rawPanelWidth(m.width)).Render(sectionStyle.Render("Selected Trace") + "\n" + wrapInline(fields, max(36, m.width-10)))
}

func rawPanelWidth(width int) int {
	return max(44, width-6)
}

func kv(label string, value string) string {
	return statusStyle.Render(label+"=") + titleStyle.Render(value)
}

func chartPanel(label string, values []float64, width int, latest string, hint string) string {
	return panelStyle.Width(width + 6).Render(sectionStyle.Render(label) + " " + titleStyle.Render(latest) + "\n" + okStyle.Render(sparkline(values, width)) + "\n" + statusStyle.Render(hint))
}

func (m *model) recordHistory(snap snapshot) {
	if m.history == nil {
		m.history = make(map[string][]float64)
	}
	m.history["fps"] = appendHistory(m.history["fps"], snap.Runtime.FPS, 120)
	m.history["frame"] = appendHistory(m.history["frame"], float64(snap.Runtime.FrameDeltaUsec), 120)
	m.history["process"] = appendHistory(m.history["process"], float64(snap.Runtime.ProcessTimeUsec), 120)
	m.history["physics"] = appendHistory(m.history["physics"], float64(snap.Runtime.PhysicsProcessTimeUsec), 120)
	m.history["memory"] = appendHistory(m.history["memory"], float64(snap.Runtime.MemoryStaticBytes), 120)
	m.history["draws"] = appendHistory(m.history["draws"], float64(snap.Runtime.DrawCallsInFrame), 120)
}

func appendHistory(values []float64, value float64, limit int) []float64 {
	values = append(values, value)
	if len(values) > limit {
		return values[len(values)-limit:]
	}
	return values
}

func appendBounded[T any](values []T, value T, limit int) []T {
	values = append(values, value)
	if len(values) > limit {
		return values[len(values)-limit:]
	}
	return values
}

func topTraceSpans(spans []traceSpan, limit int) []traceSpan {
	result := append([]traceSpan(nil), spans...)
	sort.SliceStable(result, func(i, j int) bool {
		return result[i].DurationUsec > result[j].DurationUsec
	})
	if len(result) > limit {
		return result[:limit]
	}
	return result
}

func traceGroupSummary(spans []traceSpan, limit int) string {
	if len(spans) == 0 {
		return "{}"
	}
	totals := map[string]int64{}
	for _, span := range spans {
		totals[span.Path] += span.DurationUsec
	}
	type pair struct {
		path  string
		total int64
	}
	pairs := make([]pair, 0, len(totals))
	for path, total := range totals {
		pairs = append(pairs, pair{path: path, total: total})
	}
	sort.SliceStable(pairs, func(i, j int) bool {
		return pairs[i].total > pairs[j].total
	})
	if len(pairs) > limit {
		pairs = pairs[:limit]
	}
	parts := make([]string, 0, len(pairs))
	for _, item := range pairs {
		parts = append(parts, fmt.Sprintf("%s=%s", item.path, formatUsec(float64(item.total))))
	}
	return "{" + strings.Join(parts, ",") + "}"
}

func (m model) layoutMode() string {
	if m.width < 80 {
		return "narrow"
	}
	if m.width < 124 {
		return "medium"
	}
	return "wide"
}

func fixedLayoutHeight(mode string) int {
	switch mode {
	case "narrow":
		return 30
	case "medium":
		return 26
	default:
		return 24
	}
}

func tableHeightFor(height int, mode string) int {
	if height < 22 {
		return 4
	}
	if height < 34 {
		return 6
	}
	return max(6, height-fixedLayoutHeight(mode))
}

func metricColumns(width int) []table.Column {
	if width < 80 {
		return []table.Column{
			{Title: "Path", Width: max(18, width-31)},
			{Title: "K", Width: 3},
			{Title: "Now", Width: 8},
			{Title: "Bar", Width: 12},
		}
	}
	if width < 124 {
		return []table.Column{
			{Title: "Path", Width: max(24, width-58)},
			{Title: "K", Width: 3},
			{Title: "Cnt", Width: 5},
			{Title: "Now", Width: 8},
			{Title: "Avg", Width: 8},
			{Title: "P95", Width: 8},
			{Title: "Bar", Width: 12},
		}
	}
	return []table.Column{
		{Title: "Path", Width: max(24, width-118)},
		{Title: "K", Width: 3},
		{Title: "Cnt", Width: 5},
		{Title: "Total", Width: 8},
		{Title: "Min", Width: 8},
		{Title: "Max", Width: 8},
		{Title: "Avg", Width: 8},
		{Title: "P50", Width: 8},
		{Title: "P95", Width: 8},
		{Title: "P99", Width: 8},
		{Title: "Latest", Width: 8},
		{Title: "Value", Width: 8},
		{Title: "Delta", Width: 8},
		{Title: "Bar", Width: 12},
	}
}

func metricTableRow(row metricRow, width int) table.Row {
	if width < 80 {
		return table.Row{
			compactPath(row.Path, max(18, width-31)),
			compactKind(row.Kind),
			formatMetricValue(row.Latest, row.Unit),
			barForRow(row, 10),
		}
	}
	if width < 124 {
		return table.Row{
			compactPath(row.Path, max(24, width-58)),
			compactKind(row.Kind),
			fmt.Sprintf("%d", row.Count),
			formatMetricValue(row.Latest, row.Unit),
			formatMetricValue(row.Avg, row.Unit),
			formatMetricValue(row.P95, row.Unit),
			barForRow(row, 10),
		}
	}
	return table.Row{
		compactPath(row.Path, max(24, width-118)),
		compactKind(row.Kind),
		fmt.Sprintf("%d", row.Count),
		formatMetricValue(row.Total, row.Unit),
		formatMetricValue(row.Min, row.Unit),
		formatMetricValue(row.Max, row.Unit),
		formatMetricValue(row.Avg, row.Unit),
		formatMetricValue(row.P50, row.Unit),
		formatMetricValue(row.P95, row.Unit),
		formatMetricValue(row.P99, row.Unit),
		formatMetricValue(row.Latest, row.Unit),
		formatMetricValue(row.Value, row.Unit),
		formatMetricValue(row.LatestDelta, row.Unit),
		barForRow(row, 10),
	}
}

func connectedLabel(connected bool) string {
	if connected {
		return "connected"
	}
	return "offline"
}

func statusCard(label string, value string, good bool) string {
	dot := warnStyle.Render("●")
	if good {
		dot = okStyle.Render("●")
	}
	return panelStyle.Width(18).Render(dot + " " + statusStyle.Render(label) + "\n" + titleStyle.Render(value) + "\n" + statusStyle.Render("──────────"))
}

func valueCard(label string, value string, visual string) string {
	return panelStyle.Width(18).Render(statusStyle.Render(label) + "\n" + titleStyle.Render(value) + "\n" + okStyle.Render(visual))
}

func healthBar(value float64, target float64, width int) string {
	ratio := 0.0
	if target > 0 {
		ratio = value / target
	}
	return barFromRatio(ratio, width)
}

func barFromRatio(ratio float64, width int) string {
	if width <= 0 {
		return ""
	}
	if ratio < 0 {
		ratio = 0
	}
	if ratio > 1 {
		ratio = 1
	}
	filled := int(ratio * float64(width))
	if ratio > 0 && filled == 0 {
		filled = 1
	}
	return strings.Repeat("█", filled) + strings.Repeat("░", width-filled)
}

func splitBar(parts []int, width int) string {
	total := 0
	for _, part := range parts {
		total += part
	}
	if total <= 0 {
		return strings.Repeat("░", width)
	}
	chars := []string{"█", "▓", "▒"}
	out := strings.Builder{}
	used := 0
	for index, part := range parts {
		cells := int((float64(part) / float64(total)) * float64(width))
		if part > 0 && cells == 0 {
			cells = 1
		}
		if used+cells > width {
			cells = width - used
		}
		if cells > 0 {
			out.WriteString(strings.Repeat(chars[index%len(chars)], cells))
			used += cells
		}
	}
	if used < width {
		out.WriteString(strings.Repeat("░", width-used))
	}
	return out.String()
}

func memoryRatio(stats runtimeStats) float64 {
	if stats.MemoryStaticMaxBytes <= 0 {
		return 0
	}
	return float64(stats.MemoryStaticBytes) / float64(stats.MemoryStaticMaxBytes)
}

func chartWidthFor(width int) int {
	if width < 80 {
		return max(18, width-16)
	}
	if width < 124 {
		return max(20, (width-18)/2)
	}
	return max(18, (width-24)/3)
}

func wrapCards(cards []string, maxWidth int, cardWidth int) string {
	if len(cards) == 0 {
		return ""
	}
	rows := []string{}
	current := []string{}
	currentWidth := 0
	for _, card := range cards {
		nextWidth := cardWidth
		if len(current) > 0 {
			nextWidth++
		}
		if len(current) > 0 && currentWidth+nextWidth > maxWidth {
			rows = append(rows, lipgloss.JoinHorizontal(lipgloss.Top, current...))
			current = []string{card}
			currentWidth = cardWidth
			continue
		}
		current = append(current, card)
		currentWidth += nextWidth
	}
	if len(current) > 0 {
		rows = append(rows, lipgloss.JoinHorizontal(lipgloss.Top, current...))
	}
	return strings.Join(rows, "\n")
}

func wrapInline(items []string, width int) string {
	lines := []string{}
	current := ""
	for _, item := range items {
		candidate := item
		if current != "" {
			candidate = current + "  " + item
		}
		if current != "" && lipgloss.Width(candidate) > width {
			lines = append(lines, current)
			current = item
			continue
		}
		current = candidate
	}
	if current != "" {
		lines = append(lines, current)
	}
	return strings.Join(lines, "\n")
}

func renderScrollbar(percent float64, height int) string {
	if height <= 0 {
		return ""
	}
	thumbSize := max(1, height/6)
	maxTop := max(0, height-thumbSize)
	if percent < 0 {
		percent = 0
	}
	if percent > 1 {
		percent = 1
	}
	thumbTop := int(percent * float64(maxTop))
	lines := make([]string, height)
	for i := range lines {
		if i >= thumbTop && i < thumbTop+thumbSize {
			lines[i] = okStyle.Render("█")
		} else {
			lines[i] = statusStyle.Render("│")
		}
	}
	return strings.Join(lines, "\n")
}

func compactKind(kind string) string {
	switch kind {
	case "timer":
		return "tmr"
	case "gauge":
		return "gag"
	case "counter":
		return "cnt"
	default:
		if len(kind) > 3 {
			return kind[:3]
		}
		return kind
	}
}

func compactPath(path string, limit int) string {
	if limit <= 0 || len(path) <= limit {
		return path
	}
	if limit <= 3 {
		return path[:limit]
	}
	return "..." + path[len(path)-limit+3:]
}

func barForRow(row metricRow, width int) string {
	if width <= 0 {
		return ""
	}
	value := metricBarValue(row)
	capValue := metricBarCap(row)
	filled := 0
	if capValue > 0 && value > 0 {
		filled = int((value / capValue) * float64(width))
		if filled < 1 {
			filled = 1
		}
		if filled > width {
			filled = width
		}
	}
	return strings.Repeat("█", filled) + strings.Repeat("░", width-filled)
}

func metricBarValue(row metricRow) float64 {
	switch row.Kind {
	case "counter":
		if row.LatestDelta > 0 {
			return row.LatestDelta
		}
		return row.Value
	case "gauge":
		return row.Latest
	default:
		if row.P95 > 0 {
			return row.P95
		}
		return row.Avg
	}
}

func metricBarCap(row metricRow) float64 {
	switch row.Unit {
	case "usec":
		return 16666
	case "count":
		return maxFloat(10, metricBarValue(row))
	default:
		return maxFloat(100, metricBarValue(row))
	}
}

func sparkline(values []float64, width int) string {
	if width <= 0 {
		return ""
	}
	if len(values) == 0 {
		return strings.Repeat("·", width)
	}
	if len(values) > width {
		values = values[len(values)-width:]
	}
	minValue := values[0]
	maxValue := values[0]
	for _, value := range values[1:] {
		if value < minValue {
			minValue = value
		}
		if value > maxValue {
			maxValue = value
		}
	}
	blocks := []rune("▁▂▃▄▅▆▇█")
	rendered := make([]rune, 0, width)
	rangeValue := maxValue - minValue
	for _, value := range values {
		index := 0
		if rangeValue > 0 {
			index = int(((value - minValue) / rangeValue) * float64(len(blocks)-1))
		}
		rendered = append(rendered, blocks[index])
	}
	for len(rendered) < width {
		rendered = append([]rune{'·'}, rendered...)
	}
	return string(rendered)
}

func lastValue(values []float64) float64 {
	if len(values) == 0 {
		return 0
	}
	return values[len(values)-1]
}

func maxFloat(a, b float64) float64 {
	if a > b {
		return a
	}
	return b
}

func connectCmd(addr string) tea.Cmd {
	return func() tea.Msg {
		conn, _, err := websocket.DefaultDialer.Dial(addr, nil)
		if err != nil {
			return readMsg{err: err}
		}
		return connectedMsg{conn: conn}
	}
}

func reconnectLaterCmd() tea.Cmd {
	return tea.Tick(time.Second, func(time.Time) tea.Msg { return reconnectMsg{} })
}

func readCmd(conn *websocket.Conn) tea.Cmd {
	return func() tea.Msg {
		if conn == nil {
			return readMsg{err: fmt.Errorf("not connected")}
		}
		_, payload, err := conn.ReadMessage()
		if err != nil {
			return readMsg{err: err}
		}
		raw := string(payload)
		var base struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal(payload, &base); err != nil {
			return readMsg{typeName: "invalid", raw: raw}
		}
		if base.Type == "snapshot" {
			var snap snapshot
			if err := json.Unmarshal(payload, &snap); err != nil {
				return readMsg{err: err}
			}
			return readMsg{typeName: base.Type, raw: raw, snap: snap}
		}
		if base.Type == "log" {
			var entry logEntry
			if err := json.Unmarshal(payload, &entry); err != nil {
				return readMsg{err: err}
			}
			return readMsg{typeName: base.Type, raw: raw, log: entry}
		}
		if base.Type == "event" {
			var entry eventEntry
			if err := json.Unmarshal(payload, &entry); err != nil {
				return readMsg{err: err}
			}
			return readMsg{typeName: base.Type, raw: raw, event: entry}
		}
		if base.Type == "frame_trace" {
			var trace frameTrace
			if err := json.Unmarshal(payload, &trace); err != nil {
				return readMsg{err: err}
			}
			return readMsg{typeName: base.Type, raw: raw, trace: trace}
		}
		return readMsg{typeName: base.Type, raw: raw}
	}
}

func orderRowsByP95(rows []metricRow) []metricRow {
	result := append([]metricRow(nil), rows...)
	sort.SliceStable(result, func(i, j int) bool {
		return result[i].P95 > result[j].P95
	})
	return result
}

func formatMetricDisplayValue(row metricRow) string {
	switch row.Kind {
	case "counter":
		return formatMetricValue(row.Value, row.Unit)
	case "gauge":
		return formatMetricValue(row.Latest, row.Unit)
	default:
		return formatMetricValue(row.Max, row.Unit)
	}
}

func formatMetricValue(value float64, unit string) string {
	switch unit {
	case "usec":
		return formatUsec(value)
	case "count":
		return fmt.Sprintf("%.0f", value)
	default:
		if value == float64(int64(value)) {
			return fmt.Sprintf("%.0f", value)
		}
		return fmt.Sprintf("%.2f", value)
	}
}

func formatUsec(usec float64) string {
	if usec <= 0 {
		return "0us"
	}
	if usec < 1000 {
		return fmt.Sprintf("%.0fus", usec)
	}
	return fmt.Sprintf("%.2fms", usec/1000)
}

func formatFPS(fps float64) string {
	if fps <= 0 {
		return "0.0"
	}
	return fmt.Sprintf("%.1f", fps)
}

func formatBytes(bytes int64) string {
	if bytes <= 0 {
		return "0B"
	}
	units := []string{"B", "KB", "MB", "GB"}
	value := float64(bytes)
	unit := 0
	for value >= 1024 && unit < len(units)-1 {
		value /= 1024
		unit++
	}
	if unit == 0 {
		return fmt.Sprintf("%dB", bytes)
	}
	return fmt.Sprintf("%.1f%s", value, units[unit])
}

func formatTimestamp(usec int64) string {
	if usec <= 0 {
		return "never"
	}
	return fmt.Sprintf("%.1fs", float64(usec)/1000000)
}

func formatMap(values map[string]any) string {
	if len(values) == 0 {
		return "{}"
	}
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, key := range keys {
		parts = append(parts, fmt.Sprintf("%s=%v", key, values[key]))
	}
	return "{" + strings.Join(parts, ",") + "}"
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func clampIndex(index int, length int) int {
	if length <= 0 {
		return 0
	}
	if index < 0 {
		return 0
	}
	if index >= length {
		return length - 1
	}
	return index
}

func readMessageType(payload []byte) string {
	var base struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal(payload, &base); err != nil {
		return ""
	}
	return base.Type
}

func readSnapshot(addr string, timeout time.Duration) (snapshot, error) {
	return readSnapshotFiltered(addr, timeout, nil)
}

func readSnapshotFiltered(addr string, timeout time.Duration, options map[string]any) (snapshot, error) {
	conn, _, err := websocket.DefaultDialer.Dial(addr, nil)
	if err != nil {
		return snapshot{}, err
	}
	defer conn.Close()
	requestID := ""
	if len(options) > 0 {
		requestID = fmt.Sprintf("cli-%d", time.Now().UnixNano())
		_ = conn.WriteJSON(map[string]any{"type": "snapshot_request", "request_id": requestID, "options": options})
	}
	deadline := time.Now().Add(timeout)
	for {
		if err := conn.SetReadDeadline(deadline); err != nil {
			return snapshot{}, err
		}
		_, payload, err := conn.ReadMessage()
		if err != nil {
			return snapshot{}, err
		}
		if readMessageType(payload) != "snapshot" {
			continue
		}
		var snap snapshot
		if err := json.Unmarshal(payload, &snap); err != nil {
			return snapshot{}, err
		}
		if requestID != "" && snap.RequestID != requestID {
			continue
		}
		return snap, nil
	}
}

func printJSON(value any) error {
	encoded, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	fmt.Println(string(encoded))
	return nil
}

func snapshotOptions(kind, path, pathPrefix, sortBy string, limit int, raw, traces bool) map[string]any {
	options := map[string]any{
		"include_raw_samples": raw,
		"include_traces":      traces,
		"include_runtime":     true,
		"summary_limit":       20,
	}
	if kind != "" {
		options["kind"] = kind
	}
	if path != "" {
		options["path"] = path
	}
	if pathPrefix != "" {
		options["path_prefix"] = pathPrefix
	}
	if sortBy != "" {
		options["sort"] = sortBy
	}
	if limit > 0 {
		options["limit"] = limit
	}
	return options
}

func runSnapshot(addr string, timeout time.Duration, options map[string]any) error {
	snap, err := readSnapshotFiltered(addr, timeout, options)
	if err != nil {
		return err
	}
	return printJSON(snap)
}

func loadSnapshot(path string) (snapshot, error) {
	var input io.Reader
	if path == "" || path == "-" {
		input = os.Stdin
	} else {
		file, err := os.Open(path)
		if err != nil {
			return snapshot{}, err
		}
		defer file.Close()
		input = file
	}
	var snap snapshot
	decoder := json.NewDecoder(input)
	if err := decoder.Decode(&snap); err != nil {
		return snapshot{}, err
	}
	return snap, nil
}

func writeJSONFile(path string, value any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	encoded, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(encoded, '\n'), 0o644)
}

func writeTextFile(path string, value string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(value), 0o644)
}

func runCapture(addr string, timeout time.Duration, duration time.Duration, outDir string, options map[string]any) error {
	if outDir == "" {
		outDir = "gd-metrics-capture"
	}
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return err
	}
	snap, err := readSnapshotFiltered(addr, timeout, options)
	if err != nil {
		return err
	}
	diag := diagnoseSnapshot(snap)
	status := statusFromSnapshot(snap)
	metadata := map[string]any{"url": addr, "captured_at": time.Now().Format(time.RFC3339Nano), "duration": duration.String(), "options": options}
	if err := writeJSONFile(filepath.Join(outDir, "snapshot.json"), snap); err != nil {
		return err
	}
	if err := writeJSONFile(filepath.Join(outDir, "summary.json"), summarizeSnapshot(snap, 25)); err != nil {
		return err
	}
	if err := writeJSONFile(filepath.Join(outDir, "diagnose.json"), diag); err != nil {
		return err
	}
	if err := writeJSONFile(filepath.Join(outDir, "status.json"), status); err != nil {
		return err
	}
	if err := writeJSONFile(filepath.Join(outDir, "metadata.json"), metadata); err != nil {
		return err
	}
	if err := writeTextFile(filepath.Join(outDir, "summary.md"), renderSummaryMarkdown(snap, diag)); err != nil {
		return err
	}
	if duration > 0 {
		if err := captureStream(addr, duration, filepath.Join(outDir, "stream.jsonl")); err != nil {
			return err
		}
	}
	return printJSON(map[string]any{"ok": true, "out": outDir, "status": status, "warnings": diag["warnings"]})
}

func captureStream(addr string, duration time.Duration, outPath string) error {
	conn, _, err := websocket.DefaultDialer.Dial(addr, nil)
	if err != nil {
		return err
	}
	defer conn.Close()
	file, err := os.Create(outPath)
	if err != nil {
		return err
	}
	defer file.Close()
	deadline := time.Now().Add(duration)
	for time.Now().Before(deadline) {
		_ = conn.SetReadDeadline(time.Now().Add(time.Second))
		_, payload, err := conn.ReadMessage()
		if err != nil {
			if websocket.IsCloseError(err) || strings.Contains(err.Error(), "timeout") {
				continue
			}
			continue
		}
		_, _ = file.Write(append(payload, '\n'))
	}
	return nil
}

func runStream(addr string) error {
	conn, _, err := websocket.DefaultDialer.Dial(addr, nil)
	if err != nil {
		return err
	}
	defer conn.Close()
	for {
		_, payload, err := conn.ReadMessage()
		if err != nil {
			return err
		}
		fmt.Println(string(payload))
	}
}

func runStatus(addr string, timeout time.Duration) error {
	snap, err := readSnapshot(addr, timeout)
	if err != nil {
		return err
	}
	return printJSON(statusFromSnapshot(snap))
}

func statusFromSnapshot(snap snapshot) map[string]any {
	return map[string]any{
		"ok":                       true,
		"connected":                true,
		"enabled":                  snap.Enabled,
		"metric_count":             snap.MetricCount,
		"timer_count":              snap.TimerCount,
		"gauge_count":              snap.GaugeCount,
		"counter_count":            snap.CounterCount,
		"sample_count":             snap.SampleCount,
		"fps":                      snap.Runtime.FPS,
		"recent_frame_trace_count": len(snap.RecentTraces),
	}
}

func runWait(addr string, criteria waitCriteria, timeout time.Duration) error {
	conn, _, err := websocket.DefaultDialer.Dial(addr, nil)
	if err != nil {
		return err
	}
	defer conn.Close()
	deadline := time.Now().Add(timeout)
	for {
		if err := conn.SetReadDeadline(deadline); err != nil {
			return err
		}
		_, payload, err := conn.ReadMessage()
		if err != nil {
			_ = printJSON(map[string]any{"ok": false, "timeout": true, "target": criteria})
			return fmt.Errorf("wait timed out")
		}
		messageType := readMessageType(payload)
		if waitMessageMatches(messageType, payload, criteria) {
			var decoded any
			if err := json.Unmarshal(payload, &decoded); err != nil {
				return err
			}
			return printJSON(map[string]any{"ok": true, "matched": decoded})
		}
	}
}

func waitMessageMatches(messageType string, payload []byte, criteria waitCriteria) bool {
	switch criteria.Kind {
	case "snapshot":
		return messageType == "snapshot"
	case "log":
		if messageType != "log" {
			return false
		}
		var entry logEntry
		if json.Unmarshal(payload, &entry) != nil {
			return false
		}
		return criteria.Level == "" || entry.Level == criteria.Level
	case "event":
		if messageType != "event" {
			return false
		}
		var entry eventEntry
		if json.Unmarshal(payload, &entry) != nil {
			return false
		}
		return criteria.Name == "" || entry.Name == criteria.Name
	case "trace", "frame_trace":
		return messageType == "frame_trace"
	default:
		return false
	}
}

func runAssert(addr string, criteria assertCriteria, timeout time.Duration) error {
	snap, err := readSnapshot(addr, timeout)
	if err != nil {
		return err
	}
	failures := []string{}
	if criteria.MinFPS >= 0 && snap.Runtime.FPS < criteria.MinFPS {
		failures = append(failures, fmt.Sprintf("fps %.2f below %.2f", snap.Runtime.FPS, criteria.MinFPS))
	}
	if criteria.MaxFrameUsec >= 0 && float64(snap.Runtime.FrameDeltaUsec) > criteria.MaxFrameUsec {
		failures = append(failures, fmt.Sprintf("frame %s above %s", formatUsec(float64(snap.Runtime.FrameDeltaUsec)), formatUsec(criteria.MaxFrameUsec)))
	}
	if criteria.Metric != "" && criteria.MaxP95Usec >= 0 {
		row, ok := findMetric(snap.Metrics, criteria.Metric)
		if !ok {
			failures = append(failures, "metric not found: "+criteria.Metric)
		} else if row.P95 > criteria.MaxP95Usec {
			failures = append(failures, fmt.Sprintf("metric %s p95 %s above %s", criteria.Metric, formatUsec(row.P95), formatUsec(criteria.MaxP95Usec)))
		}
	}
	result := map[string]any{"ok": len(failures) == 0, "failures": failures, "snapshot": snap}
	if err := printJSON(result); err != nil {
		return err
	}
	if len(failures) > 0 {
		return fmt.Errorf("assertions failed")
	}
	return nil
}

func runBudgetAssert(addr, budgetPath, snapshotPath string, timeout time.Duration) error {
	var snap snapshot
	var err error
	if snapshotPath != "" {
		snap, err = loadSnapshot(snapshotPath)
	} else {
		snap, err = readSnapshot(addr, timeout)
	}
	if err != nil {
		return err
	}
	file, err := os.Open(budgetPath)
	if err != nil {
		return err
	}
	defer file.Close()
	var budget map[string]any
	if err := json.NewDecoder(file).Decode(&budget); err != nil {
		return err
	}
	failures := evaluateBudget(snap, budget)
	result := map[string]any{"ok": len(failures) == 0, "failures": failures}
	if err := printJSON(result); err != nil {
		return err
	}
	if len(failures) > 0 {
		return fmt.Errorf("budget assertions failed")
	}
	return nil
}

func evaluateBudget(snap snapshot, budget map[string]any) []string {
	failures := []string{}
	if timers, ok := budget["timers"].(map[string]any); ok {
		for metricName, rawRules := range timers {
			row, found := findMetric(snap.Metrics, metricName)
			if !found {
				failures = append(failures, "timer not found: "+metricName)
				continue
			}
			rules, _ := rawRules.(map[string]any)
			if maxP95, ok := numberRule(rules, "p95_usec"); ok && row.P95 > maxP95 {
				failures = append(failures, fmt.Sprintf("%s p95 %s above %s", metricName, formatUsec(row.P95), formatUsec(maxP95)))
			}
			if maxValue, ok := numberRule(rules, "max_usec"); ok && row.Max > maxValue {
				failures = append(failures, fmt.Sprintf("%s max %s above %s", metricName, formatUsec(row.Max), formatUsec(maxValue)))
			}
		}
	}
	if runtimeBudget, ok := budget["runtime"].(map[string]any); ok {
		if minFPS, ok := numberRule(runtimeBudget, "min_fps"); ok && snap.Runtime.FPS < minFPS {
			failures = append(failures, fmt.Sprintf("fps %.1f below %.1f", snap.Runtime.FPS, minFPS))
		}
		if maxFrame, ok := numberRule(runtimeBudget, "max_frame_usec"); ok && float64(snap.Runtime.FrameDeltaUsec) > maxFrame {
			failures = append(failures, fmt.Sprintf("frame %s above %s", formatUsec(float64(snap.Runtime.FrameDeltaUsec)), formatUsec(maxFrame)))
		}
		if maxOrphans, ok := numberRule(runtimeBudget, "max_orphan_nodes"); ok && float64(snap.Runtime.OrphanNodeCount) > maxOrphans {
			failures = append(failures, fmt.Sprintf("orphan nodes %d above %.0f", snap.Runtime.OrphanNodeCount, maxOrphans))
		}
	}
	return failures
}

func numberRule(rules map[string]any, key string) (float64, bool) {
	value, ok := rules[key]
	if !ok {
		return 0, false
	}
	switch typed := value.(type) {
	case float64:
		return typed, true
	case int:
		return float64(typed), true
	default:
		return 0, false
	}
}

func runDiagnose(addr string, timeout time.Duration) error {
	snap, err := readSnapshot(addr, timeout)
	if err != nil {
		return err
	}
	return printJSON(diagnoseSnapshot(snap))
}

func diagnoseSnapshot(snap snapshot) map[string]any {
	warnings := []string{}
	if !snap.Enabled {
		warnings = append(warnings, "metrics capture is disabled")
	}
	if snap.MetricCount == 0 {
		warnings = append(warnings, "no custom metrics have been recorded")
	}
	if snap.Runtime.FPS > 0 && snap.Runtime.FPS < 50 {
		warnings = append(warnings, fmt.Sprintf("fps is low: %.1f", snap.Runtime.FPS))
	}
	if snap.Runtime.FrameDeltaUsec > 16666 {
		warnings = append(warnings, "frame delta exceeds 60fps budget: "+formatUsec(float64(snap.Runtime.FrameDeltaUsec)))
	}
	if snap.SampleCount > 2000 {
		warnings = append(warnings, fmt.Sprintf("large retained sample volume: %d; use filtered snapshots or lower max samples", snap.SampleCount))
	}
	if len(snap.RecentTraces) > 80 {
		warnings = append(warnings, fmt.Sprintf("many recent frame traces in snapshot: %d; omit traces from live snapshots by default", len(snap.RecentTraces)))
	}
	for tag, count := range tagCardinality(snap.Metrics) {
		if count > 25 {
			warnings = append(warnings, fmt.Sprintf("tag %q has high cardinality: %d values", tag, count))
		}
	}
	for _, row := range snap.Metrics {
		if row.Kind == "timer" && row.Count == 0 {
			warnings = append(warnings, "timer has no samples: "+row.Path)
			break
		}
	}
	if snap.Live != nil {
		if dropped, ok := snap.Live["dropped_messages"].(float64); ok && dropped > 0 {
			warnings = append(warnings, fmt.Sprintf("live transport dropped %.0f messages", dropped))
		}
	}
	for _, trace := range snap.RecentTraces {
		if trace.Slow {
			warnings = append(warnings, fmt.Sprintf("recent slow trace frame=%d total=%s", trace.Frame, formatUsec(float64(trace.TotalUsec))))
			break
		}
	}
	return map[string]any{"ok": len(warnings) == 0, "warnings": warnings, "status": statusFromSnapshot(snap), "tag_cardinality": tagCardinality(snap.Metrics)}
}

func tagCardinality(rows []metricRow) map[string]int {
	values := map[string]map[string]bool{}
	for _, row := range rows {
		for key, value := range row.Tags {
			if values[key] == nil {
				values[key] = map[string]bool{}
			}
			values[key][fmt.Sprint(value)] = true
		}
	}
	result := map[string]int{}
	for key, valueSet := range values {
		result[key] = len(valueSet)
	}
	return result
}

func summarizeSnapshot(snap snapshot, limit int) map[string]any {
	return map[string]any{
		"status":              statusFromSnapshot(snap),
		"top_timers_by_p95":   topRows(snap.Metrics, "timer", "p95", limit),
		"top_timers_by_total": topRows(snap.Metrics, "timer", "total", limit),
		"top_counters":        topRows(snap.Metrics, "counter", "value", limit),
		"tag_cardinality":     tagCardinality(snap.Metrics),
		"frame_traces":        frameTraceSummary(snap.RecentTraces),
	}
}

func topRows(rows []metricRow, kind, field string, limit int) []metricRow {
	filtered := []metricRow{}
	for _, row := range rows {
		if kind == "" || row.Kind == kind {
			filtered = append(filtered, row)
		}
	}
	sort.SliceStable(filtered, func(i, j int) bool { return metricField(filtered[i], field) > metricField(filtered[j], field) })
	if limit > 0 && len(filtered) > limit {
		return filtered[:limit]
	}
	return filtered
}

func metricField(row metricRow, field string) float64 {
	switch field {
	case "total":
		return row.Total
	case "max":
		return row.Max
	case "avg":
		return row.Avg
	case "p50":
		return row.P50
	case "p99":
		return row.P99
	case "latest":
		return row.Latest
	case "value":
		return row.Value
	default:
		return row.P95
	}
}

func frameTraceSummary(traces []frameTrace) map[string]any {
	maxTotal := int64(0)
	slow := 0
	for _, trace := range traces {
		if trace.TotalUsec > maxTotal {
			maxTotal = trace.TotalUsec
		}
		if trace.Slow {
			slow++
		}
	}
	return map[string]any{"count": len(traces), "slow_count": slow, "max_total_usec": maxTotal}
}

func renderSummaryMarkdown(snap snapshot, diag map[string]any) string {
	summary := summarizeSnapshot(snap, 10)
	var b strings.Builder
	b.WriteString("# gd-metrics Capture Summary\n\n")
	b.WriteString(fmt.Sprintf("- Metrics: %d (%d timers, %d gauges, %d counters)\n", snap.MetricCount, snap.TimerCount, snap.GaugeCount, snap.CounterCount))
	b.WriteString(fmt.Sprintf("- Runtime: fps %.1f, frame %s, process %s\n", snap.Runtime.FPS, formatUsec(float64(snap.Runtime.FrameDeltaUsec)), formatUsec(float64(snap.Runtime.ProcessTimeUsec))))
	b.WriteString(fmt.Sprintf("- Nodes: %d, orphans: %d, memory: %s\n\n", snap.Runtime.NodeCount, snap.Runtime.OrphanNodeCount, formatBytes(snap.Runtime.MemoryStaticBytes)))
	if warnings, ok := diag["warnings"].([]string); ok && len(warnings) > 0 {
		b.WriteString("## Warnings\n")
		for _, warning := range warnings {
			b.WriteString("- " + warning + "\n")
		}
		b.WriteString("\n")
	}
	b.WriteString("## Top Timers By P95\n")
	if rows, ok := summary["top_timers_by_p95"].([]metricRow); ok {
		for _, row := range rows {
			b.WriteString(fmt.Sprintf("- `%s` p95 %s max %s count %d\n", row.Path, formatUsec(row.P95), formatUsec(row.Max), row.Count))
		}
	}
	return b.String()
}

func runTop(addr, inputPath, kind, sortBy string, limit int, timeout time.Duration) error {
	var snap snapshot
	var err error
	if inputPath != "" {
		snap, err = loadSnapshot(inputPath)
	} else {
		snap, err = readSnapshotFiltered(addr, timeout, snapshotOptions(kind, "", "", sortBy, limit, false, false))
	}
	if err != nil {
		return err
	}
	if kind == "timers" {
		kind = "timer"
	}
	if kind == "counters" {
		kind = "counter"
	}
	if kind == "gauges" {
		kind = "gauge"
	}
	return printJSON(topRows(snap.Metrics, kind, sortBy, limit))
}

func runDiff(beforePath, afterPath string) error {
	before, err := loadSnapshot(beforePath)
	if err != nil {
		return err
	}
	after, err := loadSnapshot(afterPath)
	if err != nil {
		return err
	}
	beforeByKey := map[string]metricRow{}
	for _, row := range before.Metrics {
		beforeByKey[row.Key] = row
	}
	changes := []map[string]any{}
	for _, row := range after.Metrics {
		old, ok := beforeByKey[row.Key]
		if !ok {
			changes = append(changes, map[string]any{"path": row.Path, "key": row.Key, "status": "added", "after": row})
			continue
		}
		changes = append(changes, map[string]any{"path": row.Path, "key": row.Key, "status": "changed", "p95_delta": row.P95 - old.P95, "value_delta": row.Value - old.Value, "latest_delta": row.Latest - old.Latest})
	}
	sort.SliceStable(changes, func(i, j int) bool {
		return absFloat(anyFloat(changes[i]["p95_delta"])) > absFloat(anyFloat(changes[j]["p95_delta"]))
	})
	return printJSON(map[string]any{"before": statusFromSnapshot(before), "after": statusFromSnapshot(after), "changes": changes})
}

func anyFloat(value any) float64 {
	if v, ok := value.(float64); ok {
		return v
	}
	return 0
}
func absFloat(value float64) float64 {
	if value < 0 {
		return -value
	}
	return value
}

func findMetric(rows []metricRow, pathOrKey string) (metricRow, bool) {
	for _, row := range rows {
		if row.Path == pathOrKey || row.Key == pathOrKey {
			return row, true
		}
	}
	return metricRow{}, false
}

func main() {
	args := os.Args[1:]
	mode := "watch"
	if len(args) > 0 && isCommand(args[0]) {
		mode = args[0]
		args = args[1:]
	}
	fs := flag.NewFlagSet("gd-metrics", flag.ExitOnError)
	addr := defaultAddr
	timeout := 10 * time.Second
	waitFor := "snapshot"
	waitName := ""
	waitLevel := ""
	assertMetric := ""
	maxP95Usec := -1.0
	minFPS := -1.0
	maxFrameUsec := -1.0
	kind := ""
	path := ""
	pathPrefix := ""
	sortBy := "p95"
	limit := 0
	includeRaw := false
	includeTraces := false
	outDir := "gd-metrics-capture"
	duration := 0 * time.Second
	inputFile := ""
	budgetFile := ""
	fs.StringVar(&addr, "addr", defaultAddr, "gd-metrics WebSocket URL")
	fs.StringVar(&addr, "url", defaultAddr, "gd-metrics WebSocket URL")
	fs.DurationVar(&timeout, "timeout", 10*time.Second, "timeout for machine-readable commands")
	fs.DurationVar(&duration, "duration", 0, "capture/stream duration")
	fs.StringVar(&waitFor, "for", "snapshot", "wait target: snapshot, log, event, trace")
	fs.StringVar(&waitName, "name", "", "event name for wait")
	fs.StringVar(&waitLevel, "level", "", "log level for wait")
	fs.StringVar(&assertMetric, "metric", "", "metric path or key for assert")
	fs.Float64Var(&maxP95Usec, "max-p95-usec", -1, "maximum p95 usec for --metric")
	fs.Float64Var(&minFPS, "min-fps", -1, "minimum runtime FPS")
	fs.Float64Var(&maxFrameUsec, "max-frame-usec", -1, "maximum frame delta usec")
	fs.StringVar(&kind, "kind", "", "metric kind filter: timer, gauge, counter")
	fs.StringVar(&path, "path", "", "exact metric path filter")
	fs.StringVar(&pathPrefix, "path-prefix", "", "metric path prefix filter")
	fs.StringVar(&sortBy, "sort", "p95", "sort field: p95, total, max, avg, latest, value")
	fs.IntVar(&limit, "limit", 0, "maximum metrics returned")
	fs.BoolVar(&includeRaw, "raw", false, "include raw timer samples")
	fs.BoolVar(&includeTraces, "traces", false, "include recent frame traces in snapshots")
	fs.StringVar(&outDir, "out", "gd-metrics-capture", "output directory for capture")
	fs.StringVar(&inputFile, "file", "", "input snapshot JSON file")
	fs.StringVar(&budgetFile, "budget", "", "budget assertion JSON file")
	if err := fs.Parse(args); err != nil {
		log.Fatal(err)
	}
	switch mode {
	case "snapshot":
		options := snapshotOptions(kind, path, pathPrefix, sortBy, limit, includeRaw, includeTraces)
		if err := runSnapshot(addr, timeout, options); err != nil {
			log.Fatal(err)
		}
		return
	case "capture":
		options := snapshotOptions(kind, path, pathPrefix, sortBy, limit, includeRaw, includeTraces)
		if err := runCapture(addr, timeout, duration, outDir, options); err != nil {
			log.Fatal(err)
		}
		return
	case "stream":
		if err := runStream(addr); err != nil {
			log.Fatal(err)
		}
		return
	case "top":
		topKind := kind
		if topKind == "" && fs.NArg() > 0 {
			topKind = fs.Arg(0)
		}
		if err := runTop(addr, inputFile, topKind, sortBy, limit, timeout); err != nil {
			log.Fatal(err)
		}
		return
	case "diff":
		if fs.NArg() < 2 {
			log.Fatal("diff requires before and after snapshot paths")
		}
		if err := runDiff(fs.Arg(0), fs.Arg(1)); err != nil {
			log.Fatal(err)
		}
		return
	case "status":
		if err := runStatus(addr, timeout); err != nil {
			log.Fatal(err)
		}
		return
	case "wait":
		criteria := waitCriteria{Kind: waitFor, Name: waitName, Level: waitLevel}
		if err := runWait(addr, criteria, timeout); err != nil {
			log.Fatal(err)
		}
		return
	case "assert":
		if budgetFile != "" {
			if err := runBudgetAssert(addr, budgetFile, inputFile, timeout); err != nil {
				log.Fatal(err)
			}
			return
		}
		criteria := assertCriteria{Metric: assertMetric, MaxP95Usec: maxP95Usec, MinFPS: minFPS, MaxFrameUsec: maxFrameUsec}
		if err := runAssert(addr, criteria, timeout); err != nil {
			log.Fatal(err)
		}
		return
	case "diagnose":
		if err := runDiagnose(addr, timeout); err != nil {
			log.Fatal(err)
		}
		return
	}
	program := tea.NewProgram(initialModel(addr), tea.WithAltScreen(), tea.WithMouseCellMotion())
	if _, err := program.Run(); err != nil {
		log.Fatal(err)
	}
}

func isCommand(value string) bool {
	switch value {
	case "watch", "snapshot", "capture", "stream", "status", "wait", "assert", "diagnose", "top", "diff":
		return true
	default:
		return false
	}
}
