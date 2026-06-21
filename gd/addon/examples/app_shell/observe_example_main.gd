extends Control

@onready var _button: Button = $Panel/Margin/Content/EventButton

func _ready() -> void:
	_button.pressed.connect(_on_event_button_pressed)
	if has_node("ObserveBootstrap"):
		GdObserve.event("example.ready", {"screen": "example"}, {})

func _on_event_button_pressed() -> void:
	var timer := GdObserve.begin_timer()
	GdObserve.increment_counter("Example.button_pressed", 1, "count", {"screen": "example"})
	GdObserve.finish_timer("Example.button_handler", timer, {"screen": "example"})
	GdObserve.event("example.button_pressed", {"screen": "example"}, {})
