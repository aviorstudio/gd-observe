package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func TestOrderRowsByP95(t *testing.T) {
	rows := []metricRow{
		{Path: "Board.slow", Kind: "timer", Count: 1, P95: 5000, Avg: 3000},
		{Path: "Hand.fast", Kind: "timer", Count: 10, P95: 1000, Avg: 500},
	}
	got := orderRowsByP95(rows)
	if got[0].Path != "Board.slow" {
		t.Fatalf("expected p95 sort to put Board first, got %#v", got)
	}
}

func TestFormatUsec(t *testing.T) {
	if got := formatUsec(42); got != "42us" {
		t.Fatalf("expected 42us, got %s", got)
	}
	if got := formatUsec(1500); got != "1.50ms" {
		t.Fatalf("expected 1.50ms, got %s", got)
	}
}

func TestFormatBytes(t *testing.T) {
	if got := formatBytes(512); got != "512B" {
		t.Fatalf("expected 512B, got %s", got)
	}
	if got := formatBytes(1536); got != "1.5KB" {
		t.Fatalf("expected 1.5KB, got %s", got)
	}
	if got := formatBytes(2 * 1024 * 1024); got != "2.0MB" {
		t.Fatalf("expected 2.0MB, got %s", got)
	}
}

func TestSelectTabWithMouse(t *testing.T) {
	m := initialModel(defaultAddr)
	m.width = 100
	if !m.selectTabWithMouse(tea.MouseMsg{Type: tea.MouseLeft, X: 13, Y: 0}) {
		t.Fatal("expected logs tab click to be handled")
	}
	if m.activeTab != tabLogs {
		t.Fatalf("expected logs tab, got %d", m.activeTab)
	}
}

func TestWaitMessageMatches(t *testing.T) {
	payload, err := json.Marshal(eventEntry{Type: "event", Name: "match.ready"})
	if err != nil {
		t.Fatal(err)
	}
	if !waitMessageMatches("event", payload, waitCriteria{Kind: "event", Name: "match.ready"}) {
		t.Fatal("expected event wait criteria to match")
	}
	if waitMessageMatches("event", payload, waitCriteria{Kind: "event", Name: "other"}) {
		t.Fatal("expected event wait criteria not to match other name")
	}
}

func TestTraceGroupSummary(t *testing.T) {
	got := traceGroupSummary([]traceSpan{
		{Path: "B", DurationUsec: 5},
		{Path: "A", DurationUsec: 10},
		{Path: "A", DurationUsec: 7},
	}, 1)
	if got != "{A=17us}" {
		t.Fatalf("expected top grouped trace path, got %s", got)
	}
}

func TestTopRowsAndBudget(t *testing.T) {
	snap := snapshot{
		Runtime: runtimeStats{FPS: 59, FrameDeltaUsec: 16000, OrphanNodeCount: 5},
		Metrics: []metricRow{
			{Path: "Slow", Key: "Slow", Kind: "timer", P95: 5000, Max: 6000},
			{Path: "Fast", Key: "Fast", Kind: "timer", P95: 500, Max: 700},
		},
	}
	rows := topRows(snap.Metrics, "timer", "p95", 1)
	if len(rows) != 1 || rows[0].Path != "Slow" {
		t.Fatalf("expected Slow as top p95 row, got %#v", rows)
	}
	failures := evaluateBudget(snap, map[string]any{
		"timers":  map[string]any{"Slow": map[string]any{"p95_usec": float64(4000)}},
		"runtime": map[string]any{"min_fps": float64(60)},
	})
	if len(failures) != 2 {
		t.Fatalf("expected timer and fps failures, got %#v", failures)
	}
}

func TestTagCardinality(t *testing.T) {
	got := tagCardinality([]metricRow{
		{Path: "A", Tags: map[string]any{"route": "play"}},
		{Path: "B", Tags: map[string]any{"route": "match"}},
		{Path: "C", Tags: map[string]any{"route": "match"}},
	})
	if got["route"] != 2 {
		t.Fatalf("expected route cardinality 2, got %#v", got)
	}
}

func TestIsCommandIncludesVersion(t *testing.T) {
	if !isCommand("version") {
		t.Fatal("expected version to be a command")
	}
}

func TestAddrFromJSONEnvFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".env.json")
	if err := os.WriteFile(path, []byte(`{"metrics_live_server_host":"127.0.0.1","metrics_live_server_port":8766}`), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := addrFromEnvFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if got != "ws://127.0.0.1:8766" {
		t.Fatalf("expected env-derived addr, got %s", got)
	}
}

func TestAddrFromDotEnvFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".env")
	if err := os.WriteFile(path, []byte("GDOBS_HOST=localhost\nGDOBS_PORT=8770\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := addrFromEnvFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if got != "ws://localhost:8770" {
		t.Fatalf("expected dotenv-derived addr, got %s", got)
	}
}

func TestAddrFromProjectPrefersGodotClientEnv(t *testing.T) {
	dir := t.TempDir()
	clientDir := filepath.Join(dir, "godot_client")
	if err := os.Mkdir(clientDir, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(clientDir, ".env.json")
	if err := os.WriteFile(path, []byte(`{"metrics_live_server_port":8767}`), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := addrFromProject(dir)
	if err != nil {
		t.Fatal(err)
	}
	if got != "ws://127.0.0.1:8767" {
		t.Fatalf("expected project-derived addr, got %s", got)
	}
}
