@tool
extends EditorPlugin

const AUTOLOAD_NAME := "GdObserve"
const AUTOLOAD_SCRIPT := "autoload.gd"
const ObserveBootstrapScript = preload("src/observe_bootstrap.gd")
const ObserveConfigScript = preload("src/observe_config.gd")
const ObserveLiveServerConfigScript = preload("src/observe_live_server_config.gd")

var _added_autoload: bool = false

func _enter_tree() -> void:
	add_custom_type("ObserveBootstrap", "Node", ObserveBootstrapScript, _editor_icon("Signals", "Node"))
	add_custom_type("ObserveConfig", "Resource", ObserveConfigScript, _editor_icon("Resource", "Resource"))
	add_custom_type("ObserveLiveServerConfig", "Resource", ObserveLiveServerConfigScript, _editor_icon("Network", "Resource"))

func _exit_tree() -> void:
	remove_custom_type("ObserveLiveServerConfig")
	remove_custom_type("ObserveConfig")
	remove_custom_type("ObserveBootstrap")

func _enable_plugin() -> void:
	var key: String = "autoload/" + AUTOLOAD_NAME
	if ProjectSettings.has_setting(key):
		_added_autoload = false
		return
	var base_dir: String = str(get_script().resource_path).get_base_dir()
	add_autoload_singleton(AUTOLOAD_NAME, base_dir.path_join(AUTOLOAD_SCRIPT))
	_added_autoload = true

func _disable_plugin() -> void:
	if _added_autoload:
		remove_autoload_singleton(AUTOLOAD_NAME)
	_added_autoload = false

func _editor_icon(preferred_name: String, fallback_name: String) -> Texture2D:
	var editor_interface: EditorInterface = get_editor_interface()
	if editor_interface == null:
		return null
	var base_control: Control = editor_interface.get_base_control()
	if base_control == null:
		return null
	if base_control.has_theme_icon(preferred_name, "EditorIcons"):
		return base_control.get_theme_icon(preferred_name, "EditorIcons")
	if base_control.has_theme_icon(fallback_name, "EditorIcons"):
		return base_control.get_theme_icon(fallback_name, "EditorIcons")
	return null
