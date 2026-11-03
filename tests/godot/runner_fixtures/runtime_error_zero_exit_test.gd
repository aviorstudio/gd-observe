extends SceneTree
func _initialize() -> void:
	push_error("deliberate runtime error control")
	print("PASS gd-observe runtime_error_zero_exit_test")
	quit(0)
