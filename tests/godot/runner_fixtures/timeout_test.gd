extends SceneTree
func _initialize() -> void:
	await create_timer(60.0).timeout
	print("PASS gd-observe timeout_test")
	quit(0)
