#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
archive="${1:-$root/dist/@aviorstudio_gd-observe.zip}"
godot="${GODOT_BIN:-godot}"
scratch="${LIFECYCLE_TMP:-$(mktemp -d)}"
mkdir -p "$scratch"
if [ -z "${LIFECYCLE_TMP:-}" ]; then
  trap 'rm -rf "$scratch"' EXIT
fi
allowlist="$root/gd/tests/editor-log-allowlist.txt"

checked_editor() {
  label="$1"
  shift
  log="$scratch/${label}.log"
  set +e
  HOME="$scratch/home" timeout --signal=TERM --kill-after=5 30s "$godot" "$@" 2>&1 | tee "$log"
  status="${PIPESTATUS[0]}"
  set -e
  if [ "$status" -ne 0 ]; then
    echo "Editor command $label exited $status" >&2
    exit 1
  fi
  unexpected="$(grep -E '^(ERROR:|SCRIPT ERROR:|FAIL:)' "$log" | grep -Ev -f "$allowlist" || true)"
  if [ -n "$unexpected" ]; then
    echo "Unexpected editor error in $label: $unexpected" >&2
    exit 1
  fi
}

make_fixture() {
  fixture="$1"
  mkdir -p "$fixture/addons/@aviorstudio_gd-observe"
  unzip -oq "$archive" -d "$fixture/addons/@aviorstudio_gd-observe"
  cat > "$fixture/consumer_owned.gd" <<'GD'
extends Node
GD
}

run_editor() {
  fixture="$1"
  expected="$2"
  cat > "$fixture/editor_restart_check.gd" <<GD
@tool
extends SceneTree
func _initialize() -> void:
	call_deferred("_check")
func _check() -> void:
	await process_frame
	var configured := ProjectSettings.has_setting("autoload/GdObserve")
	if configured != $expected:
		push_error("restart autoload state mismatch")
		quit(1)
		return
	print("PASS gd-observe packaged editor restart")
	await create_timer(0.5).timeout
	quit(0)
GD
  checked_editor "restart-$(basename "$fixture")-$expected" --headless --editor --path "$fixture" --script "$fixture/editor_restart_check.gd"
  grep -Fq 'PASS gd-observe packaged editor restart' "$scratch/restart-$(basename "$fixture")-$expected.log"
}

set_plugin_enabled() {
  fixture="$1"
  enabled="$2"
  cat > "$fixture/set_plugin_enabled.gd" <<GD
@tool
extends SceneTree
func _initialize() -> void:
	call_deferred("_apply_plugin_state")
func _apply_plugin_state() -> void:
	var plugin = load("res://addons/@aviorstudio_gd-observe/plugin.gd").new()
	root.add_child(plugin)
	await process_frame
	if $enabled:
		plugin._enable_plugin()
	else:
		plugin._disable_plugin()
	plugin.queue_free()
	await create_timer(0.5).timeout
	print("PASS gd-observe packaged plugin state $enabled")
	quit(0)
GD
  checked_editor "plugin-$(basename "$fixture")-$enabled" --headless --editor --path "$fixture" --script "$fixture/set_plugin_enabled.gd"
  grep -Fq "PASS gd-observe packaged plugin state $enabled" "$scratch/plugin-$(basename "$fixture")-$enabled.log"
}

owned="$scratch/owned"
make_fixture "$owned"
installed_digest="$(cd "$owned/addons/@aviorstudio_gd-observe" && while IFS= read -r path; do sha256sum "$path"; done < "$root/gd/package-manifest.txt" | sha256sum | cut -d' ' -f1)"
echo "Installed tree SHA-256: $installed_digest"
cat > "$owned/project.godot" <<'CFG'
[application]
config/name="gd-observe package lifecycle"

[autoload]
ConsumerOwned="*res://consumer_owned.gd"

[editor_plugins]
enabled=PackedStringArray()

[rendering]
renderer/rendering_method="gl_compatibility"
CFG
set_plugin_enabled "$owned" true
grep -Fq 'GdObserve=' "$owned/project.godot"
grep -Fq 'ConsumerOwned=' "$owned/project.godot"
run_editor "$owned" true
set_plugin_enabled "$owned" false
run_editor "$owned" false
if grep -Fq 'GdObserve=' "$owned/project.godot"; then
  echo "Owned GdObserve autoload survived plugin disable" >&2
  exit 1
fi
grep -Fq 'ConsumerOwned=' "$owned/project.godot"

consumer="$scratch/consumer"
make_fixture "$consumer"
cat > "$consumer/project.godot" <<'CFG'
[application]
config/name="gd-observe consumer ownership"

[autoload]
GdObserve="*res://consumer_owned.gd"

[editor_plugins]
enabled=PackedStringArray()

[rendering]
renderer/rendering_method="gl_compatibility"
CFG
set_plugin_enabled "$consumer" true
set_plugin_enabled "$consumer" false
run_editor "$consumer" true
grep -Fq 'GdObserve="*res://consumer_owned.gd"' "$consumer/project.godot"
echo "PASS packaged editor enable/restart/disable/restart ownership lifecycle"
