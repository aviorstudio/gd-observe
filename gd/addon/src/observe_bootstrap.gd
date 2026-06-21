@tool
## Scene-authored bootstrapper for configuring GdObserve from resources.
class_name ObserveBootstrap
extends Node

const ObserveConfigScript = preload("observe_config.gd")
const ObserveLiveServerConfigScript = preload("observe_live_server_config.gd")

enum LiveServerMode { DISABLED, DEBUG_NON_WEB, DEBUG, ALWAYS }

@export var observe_path: NodePath = NodePath("/root/GdObserve")
@export var metrics_config: Resource:
	set(value):
		metrics_config = value
		update_configuration_warnings()
@export var live_server_config: Resource:
	set(value):
		live_server_config = value
		update_configuration_warnings()
@export var live_server_mode: LiveServerMode = LiveServerMode.DISABLED:
	set(value):
		live_server_mode = value
		update_configuration_warnings()
@export var context_tags: Dictionary = {}
@export var env_path: String = "res://.env.json"
@export var emit_bootstrap_event: bool = true

func _ready() -> void:
	if Engine.is_editor_hint():
		update_configuration_warnings()
		return
	bootstrap()

func bootstrap() -> Error:
	var observe: Node = _get_observe()
	if observe == null:
		return ERR_DOES_NOT_EXIST
	if observe.has_method("configure_from_resource"):
		observe.call("configure_from_resource", metrics_config)
	elif metrics_config != null and metrics_config.has_method("to_metrics_config") and observe.has_method("configure"):
		observe.call("configure", metrics_config.call("to_metrics_config"))
	if observe.has_method("set_context") and not context_tags.is_empty():
		observe.call("set_context", context_tags)
	if emit_bootstrap_event and observe.has_method("event"):
		observe.call("event", "gd_observe.bootstrap_configured", context_tags, {"live_server_mode": int(live_server_mode)})
	if not _should_start_live_server():
		return OK
	if live_server_config == null:
		return ERR_UNCONFIGURED
	var error: Error = OK
	if observe.has_method("start_live_server_from_resource"):
		error = observe.call("start_live_server_from_resource", live_server_config, _load_env_overrides())
	elif live_server_config.has_method("to_live_server_config") and observe.has_method("start_live_server"):
		error = observe.call("start_live_server", live_server_config.call("to_live_server_config", _load_env_overrides()))
	if error != OK and observe.has_method("log"):
		observe.call("log", "warn", "Unable to start gd-observe live server", context_tags, {"error": error})
	elif error == OK and observe.has_method("log"):
		observe.call("log", "info", "gd-observe bootstrap completed", context_tags, {"live_server_url": observe.call("get_live_server_url") if observe.has_method("get_live_server_url") else ""})
	return error

func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if metrics_config == null:
		warnings.append("Assign an ObserveConfig resource so metrics behavior is visible in the Inspector.")
	elif not metrics_config.has_method("to_metrics_config"):
		warnings.append("metrics_config must be an ObserveConfig resource.")
	if live_server_mode != LiveServerMode.DISABLED:
		if live_server_config == null:
			warnings.append("Assign an ObserveLiveServerConfig resource when the live server mode is enabled.")
		elif not live_server_config.has_method("to_live_server_config"):
			warnings.append("live_server_config must be an ObserveLiveServerConfig resource.")
		elif "host" in live_server_config and str(live_server_config.get("host")) != "127.0.0.1":
			warnings.append("The live server is intended for local debugging; prefer host 127.0.0.1.")
	return warnings

func _should_start_live_server() -> bool:
	match live_server_mode:
		LiveServerMode.DISABLED:
			return false
		LiveServerMode.DEBUG_NON_WEB:
			return OS.is_debug_build() and not OS.has_feature("web")
		LiveServerMode.DEBUG:
			return OS.is_debug_build()
		LiveServerMode.ALWAYS:
			return true
	return false

func _get_observe() -> Node:
	if not is_inside_tree():
		return null
	var observe: Node = get_node_or_null(observe_path)
	if observe == null and get_tree() != null and get_tree().root != null:
		observe = get_tree().root.get_node_or_null("GdObserve")
	return observe

func _load_env_overrides() -> Dictionary:
	var overrides: Dictionary = {}
	var path := env_path.strip_edges()
	if path.is_empty() or not FileAccess.file_exists(path):
		return overrides
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return overrides
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not (parsed is Dictionary):
		return overrides
	var env: Dictionary = parsed
	if env.has("gdobs_host"):
		overrides["host"] = str(env.get("gdobs_host", ""))
	elif env.has("GDOBS_HOST"):
		overrides["host"] = str(env.get("GDOBS_HOST", ""))
	if env.has("gdobs_port"):
		overrides["port"] = int(env.get("gdobs_port", 0))
	elif env.has("GDOBS_PORT"):
		overrides["port"] = int(env.get("GDOBS_PORT", 0))
	return overrides
