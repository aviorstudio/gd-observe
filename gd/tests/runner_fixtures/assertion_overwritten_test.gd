extends SceneTree
func _initialize() -> void:
	push_error("deliberate assertion failure whose exit is overwritten")
	quit(1)
	quit(0)
