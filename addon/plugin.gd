@tool
extends EditorPlugin

const AUTOLOAD_NAME := "GdMetrics"
const AUTOLOAD_SCRIPT := "autoload.gd"

var _added_autoload: bool = false

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
