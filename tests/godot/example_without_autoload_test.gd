extends SceneTree
const Example = preload("res://addon/examples/app_shell/observe_example_main.gd")

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var view := Control.new()
	view.set_script(Example)
	var button := Button.new()
	var panel := Node.new()
	panel.name = "Panel"
	view.add_child(panel)
	var margin := Node.new()
	margin.name = "Margin"
	panel.add_child(margin)
	var content := Node.new()
	content.name = "Content"
	margin.add_child(content)
	button.name = "EventButton"
	content.add_child(button)
	root.add_child(view)
	await process_frame
	if not button.disabled:
		push_error("Example must safely disable observation when its dependency is absent")
		quit(1)
		return
	view._on_event_button_pressed()
	view.free()
	print("PASS gd-observe example_without_autoload_test")
	quit(0)
