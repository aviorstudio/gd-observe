## Samples Godot runtime performance monitors for live metrics dashboards.
class_name MetricsRuntimeSampler
extends RefCounted

var _last_snapshot: Dictionary[String, Variant] = {}
var _sample_count: int = 0

func sample(delta_seconds: float = 0.0) -> Dictionary[String, Variant]:
	_sample_count += 1
	_last_snapshot = {
		"timestamp_usec": Time.get_ticks_usec(),
		"sample_count": _sample_count,
		"fps": Performance.get_monitor(Performance.TIME_FPS),
		"frame_delta_usec": int(round(maxf(delta_seconds, 0.0) * 1000000.0)),
		"process_time_usec": _seconds_monitor_to_usec(Performance.TIME_PROCESS),
		"physics_process_time_usec": _seconds_monitor_to_usec(Performance.TIME_PHYSICS_PROCESS),
		"navigation_process_time_usec": _seconds_monitor_to_usec(Performance.TIME_NAVIGATION_PROCESS),
		"memory_static_bytes": int(Performance.get_monitor(Performance.MEMORY_STATIC)),
		"memory_static_max_bytes": int(Performance.get_monitor(Performance.MEMORY_STATIC_MAX)),
		"message_buffer_max_bytes": int(Performance.get_monitor(Performance.MEMORY_MESSAGE_BUFFER_MAX)),
		"object_count": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"resource_count": int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		"node_count": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"orphan_node_count": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		"render_objects_in_frame": int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"render_primitives_in_frame": int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		"draw_calls_in_frame": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"video_memory_bytes": int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)),
		"texture_memory_bytes": int(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)),
		"buffer_memory_bytes": int(Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED)),
		"physics_2d_active_objects": int(Performance.get_monitor(Performance.PHYSICS_2D_ACTIVE_OBJECTS)),
		"physics_2d_collision_pairs": int(Performance.get_monitor(Performance.PHYSICS_2D_COLLISION_PAIRS)),
		"physics_2d_island_count": int(Performance.get_monitor(Performance.PHYSICS_2D_ISLAND_COUNT)),
		"audio_output_latency_usec": _seconds_monitor_to_usec(Performance.AUDIO_OUTPUT_LATENCY),
	}
	return _last_snapshot.duplicate(true)

func get_last_snapshot() -> Dictionary[String, Variant]:
	return _last_snapshot.duplicate(true)

func _seconds_monitor_to_usec(monitor: Performance.Monitor) -> int:
	return int(round(maxf(Performance.get_monitor(monitor), 0.0) * 1000000.0))
