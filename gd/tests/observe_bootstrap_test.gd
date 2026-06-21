extends SceneTree

const MetricsAutoload = preload("res://addon/autoload.gd")
const ObserveBootstrap = preload("res://addon/src/observe_bootstrap.gd")
const ObserveConfig = preload("res://addon/src/observe_config.gd")
const ObserveLiveServerConfig = preload("res://addon/src/observe_live_server_config.gd")

func _initialize() -> void:
	call_deferred("_run_tests")

func _run_tests() -> void:
	var failures: Array[String] = []
	_test_bootstrap_configures_autoload(failures)
	_test_bootstrap_warnings(failures)
	_test_env_overrides(failures)

	if failures.is_empty():
		print("PASS gd-observe observe_bootstrap_test")
		quit(0)
		return

	for failure in failures:
		push_error(failure)
	quit(1)

func _test_bootstrap_configures_autoload(failures: Array[String]) -> void:
	var autoload := _add_observe_autoload()
	var bootstrap := ObserveBootstrap.new()
	bootstrap.metrics_config = ObserveConfig.new()
	bootstrap.metrics_config.max_timer_samples = 5
	bootstrap.context_tags = {"game": "test"}
	bootstrap.live_server_mode = ObserveBootstrap.LiveServerMode.DISABLED
	root.add_child(bootstrap)
	var error: Error = bootstrap.bootstrap()
	if error != OK:
		failures.append("ObserveBootstrap: expected bootstrap OK")
	autoload.record_timer("Bootstrap.timer", 100, {})
	var summary: Dictionary = autoload.get_timer_summary("Bootstrap.timer", {"game": "test"})
	if summary.is_empty():
		failures.append("ObserveBootstrap: expected context tags to apply to configured autoload")
	bootstrap.free()
	_remove_observe_autoload(autoload)

func _test_bootstrap_warnings(failures: Array[String]) -> void:
	var bootstrap := ObserveBootstrap.new()
	var warnings: PackedStringArray = bootstrap._get_configuration_warnings()
	if warnings.is_empty():
		failures.append("ObserveBootstrap: expected warning when metrics_config is missing")
	bootstrap.live_server_mode = ObserveBootstrap.LiveServerMode.DEBUG
	warnings = bootstrap._get_configuration_warnings()
	if warnings.size() < 2:
		failures.append("ObserveBootstrap: expected warning when live server config is missing")
	bootstrap.free()

func _test_env_overrides(failures: Array[String]) -> void:
	var path := "user://gd_observe_env_test.json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify({"gdobs_host": "127.0.0.1", "gdobs_port": 4567}))
	file.close()
	var bootstrap := ObserveBootstrap.new()
	bootstrap.env_path = path
	var overrides: Dictionary = bootstrap._load_env_overrides()
	if str(overrides.get("host", "")) != "127.0.0.1" or int(overrides.get("port", 0)) != 4567:
		failures.append("ObserveBootstrap: expected env host/port overrides")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	bootstrap.free()

func _add_observe_autoload() -> MetricsAutoload:
	var existing: Node = root.get_node_or_null("GdObserve")
	if existing != null:
		existing.free()
	var autoload := MetricsAutoload.new()
	autoload.name = "GdObserve"
	root.add_child(autoload)
	return autoload

func _remove_observe_autoload(autoload: MetricsAutoload) -> void:
	if autoload != null and is_instance_valid(autoload):
		autoload.free()
