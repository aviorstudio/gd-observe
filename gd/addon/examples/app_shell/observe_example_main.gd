extends Control

## Resolve observation through a configurable node path so the shipped example
## also parses in consumers that deliberately do not enable the addon autoload.
@export var observe_path: NodePath = NodePath("/root/GdObserve")
@onready var _button: Button = $Panel/Margin/Content/EventButton
var _observe: Node

func _ready() -> void:
	_observe = get_node_or_null(observe_path)
	_button.pressed.connect(_on_event_button_pressed)
	_button.disabled = _observe == null
	if _observe:
		_observe.call("event", "example.ready", {"screen": "example"}, {})

func _on_event_button_pressed() -> void:
	if not is_instance_valid(_observe):
		return
	var timer: Variant = _observe.call("begin_timer")
	_observe.call("increment_counter", "Example.button_pressed", 1, "count", {"screen": "example"})
	_observe.call("finish_timer", "Example.button_handler", timer, {"screen": "example"})
	_observe.call("event", "example.button_pressed", {"screen": "example"}, {})
