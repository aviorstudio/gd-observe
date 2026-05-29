## Local WebSocket live exporter for MetricsModule snapshots.
class_name MetricsLiveServer
extends Node

const MetricsModuleScript = preload("metrics_module.gd")
const MetricsRuntimeSamplerScript = preload("metrics_runtime_sampler.gd")

signal client_connected(peer_id: int)
signal client_disconnected(peer_id: int)

class MetricsLiveServerConfig extends RefCounted:
	var enabled: bool
	var host: String
	var port: int
	var snapshot_interval_msec: int
	var include_raw_samples: bool
	var include_runtime_stats: bool
	var include_frame_traces: bool
	var max_snapshot_bytes: int

	func _init(
		p_enabled: bool = true,
		p_host: String = "127.0.0.1",
		p_port: int = 8765,
		p_snapshot_interval_msec: int = 250,
		p_include_raw_samples: bool = false,
		p_include_runtime_stats: bool = true,
		p_include_frame_traces: bool = false,
		p_max_snapshot_bytes: int = 900000
	) -> void:
		enabled = p_enabled
		host = p_host
		port = p_port
		snapshot_interval_msec = p_snapshot_interval_msec
		include_raw_samples = p_include_raw_samples
		include_runtime_stats = p_include_runtime_stats
		include_frame_traces = p_include_frame_traces
		max_snapshot_bytes = p_max_snapshot_bytes

var _config: MetricsLiveServerConfig = MetricsLiveServerConfig.new()
var _metrics_module: RefCounted = null
var _runtime_sampler: RefCounted = null
var _server: TCPServer = TCPServer.new()
var _peers: Dictionary[int, Dictionary] = {}
var _next_peer_id: int = 1
var _last_snapshot_msec: int = 0

func _ready() -> void:
	set_process(false)

func start_server(metrics_module: RefCounted, config: MetricsLiveServerConfig = null, runtime_sampler: RefCounted = null) -> Error:
	stop()
	_metrics_module = metrics_module
	_config = config if config != null else MetricsLiveServerConfig.new()
	_runtime_sampler = runtime_sampler if runtime_sampler != null else MetricsRuntimeSamplerScript.new()
	if not _config.enabled:
		return OK
	if _metrics_module == null:
		return ERR_INVALID_PARAMETER
	var error: Error = _server.listen(_config.port, _config.host)
	if error != OK:
		return error
	_connect_metric_stream()
	_last_snapshot_msec = 0
	set_process(true)
	if _metrics_module.has_method("event"):
		_metrics_module.event("gd_observe.live_server_started", {"host": _config.host}, {"port": get_port()})
	return OK

func stop() -> void:
	set_process(false)
	if _metrics_module != null and _metrics_module.has_method("event") and _server.is_listening():
		_metrics_module.event("gd_observe.live_server_stopped", {"host": _config.host}, {"port": get_port()})
	_disconnect_metric_stream()
	for peer_id: int in _peers.keys():
		var state: Dictionary = _peers[peer_id]
		var peer: WebSocketPeer = state.get("peer", null)
		if peer != null:
			peer.close(1001, "server stopping")
	_peers.clear()
	if _server.is_listening():
		_server.stop()

func is_running() -> bool:
	return _server.is_listening()

func get_port() -> int:
	return _server.get_local_port() if _server.is_listening() else 0

func get_url() -> String:
	return "ws://%s:%d" % [_config.host, get_port()]

func get_client_count() -> int:
	return _peers.size()

func _process(delta: float) -> void:
	_accept_pending_connections()
	_poll_peers()
	if _config.include_runtime_stats and _runtime_sampler != null:
		_runtime_sampler.sample(delta)
	if _metrics_module != null and _metrics_module.has_method("flush_frame_trace"):
		_metrics_module.flush_frame_trace()
	var now_msec: int = Time.get_ticks_msec()
	var interval_msec: int = maxi(_config.snapshot_interval_msec, 50)
	if now_msec - _last_snapshot_msec >= interval_msec:
		_last_snapshot_msec = now_msec
		_broadcast_snapshot()

func _accept_pending_connections() -> void:
	while _server.is_listening() and _server.is_connection_available():
		var stream: StreamPeerTCP = _server.take_connection()
		if stream == null:
			return
		stream.set_no_delay(true)
		var peer := WebSocketPeer.new()
		var error: Error = peer.accept_stream(stream)
		if error != OK:
			peer.close(-1)
			continue
		var peer_id: int = _next_peer_id
		_next_peer_id += 1
		_peers[peer_id] = {
			"peer": peer,
			"opened": false,
			"snapshot_options": _default_snapshot_options(),
			"dropped_messages": 0,
		}

func _poll_peers() -> void:
	var closed_peers: Array[int] = []
	for peer_id: int in _peers.keys():
		var state: Dictionary = _peers[peer_id]
		var peer: WebSocketPeer = state.get("peer", null)
		if peer == null:
			closed_peers.append(peer_id)
			continue
		peer.poll()
		var ready_state: WebSocketPeer.State = peer.get_ready_state()
		if ready_state == WebSocketPeer.STATE_OPEN:
			if not bool(state.get("opened", false)):
				state["opened"] = true
				_peers[peer_id] = state
				client_connected.emit(peer_id)
				_send_hello(peer_id, peer)
				_send_snapshot(peer, state)
			while peer.get_available_packet_count() > 0:
				_handle_client_packet(peer_id, peer.get_packet().get_string_from_utf8())
		elif ready_state == WebSocketPeer.STATE_CLOSED:
			closed_peers.append(peer_id)
	for peer_id in closed_peers:
		_peers.erase(peer_id)
		client_disconnected.emit(peer_id)

func _broadcast_snapshot() -> void:
	for state in _peers.values():
		var peer: WebSocketPeer = state.get("peer", null)
		if peer != null and peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
			_send_snapshot(peer, state)

func _send_hello(peer_id: int, peer: WebSocketPeer) -> void:
	_send_json(peer, {
		"type": "hello",
		"version": 2,
		"peer_id": peer_id,
		"server": "gd-observe",
		"url": get_url(),
		"read_only": true,
		"supports_filtered_snapshots": true,
		"default_snapshot": _default_snapshot_options(),
	})

func _send_snapshot(peer: WebSocketPeer, state: Dictionary = {}) -> void:
	if _metrics_module == null:
		_send_error(peer, "metrics_unavailable", "Metrics module is not configured")
		return
	var options: Dictionary = state.get("snapshot_options", _default_snapshot_options())
	var snapshot: Dictionary[String, Variant] = _metrics_module.export_snapshot_filtered(options)
	snapshot["type"] = "snapshot"
	snapshot["live"] = {
		"dropped_messages": int(state.get("dropped_messages", 0)),
		"max_snapshot_bytes": _config.max_snapshot_bytes,
	}
	if state.has("request_id"):
		snapshot["request_id"] = str(state.get("request_id", ""))
	if _config.include_runtime_stats and _runtime_sampler != null:
		var runtime_snapshot: Dictionary = _runtime_sampler.get_last_snapshot()
		if runtime_snapshot.is_empty():
			runtime_snapshot = _runtime_sampler.sample(0.0)
		snapshot["runtime"] = runtime_snapshot
	_send_json(peer, snapshot)

func _send_error(peer: WebSocketPeer, code: String, message: String) -> void:
	_send_json(peer, {
		"type": "error",
		"code": code,
		"message": message,
		"timestamp_usec": Time.get_ticks_usec(),
	})

func _send_json(peer: WebSocketPeer, payload: Dictionary) -> void:
	if peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	var encoded: String = JSON.stringify(payload)
	if _config.max_snapshot_bytes > 0 and encoded.length() > _config.max_snapshot_bytes and str(payload.get("type", "")) == "snapshot":
		var compact: Dictionary = payload.duplicate(true)
		compact["metrics"] = []
		compact["recent_frame_traces"] = []
		compact["truncated"] = true
		compact["truncated_reason"] = "snapshot exceeded max_snapshot_bytes"
		compact["original_size_bytes"] = encoded.length()
		encoded = JSON.stringify(compact)
	var error: Error = peer.send_text(encoded)
	if error != OK:
		_record_send_failure(error, str(payload.get("type", "unknown")), encoded.length())

func _default_snapshot_options() -> Dictionary:
	return {
		"include_raw_samples": _config.include_raw_samples,
		"include_traces": _config.include_frame_traces,
		"include_runtime": _config.include_runtime_stats,
		"summary_limit": 10,
	}

func _handle_client_packet(peer_id: int, payload: String) -> void:
	var parsed: Variant = JSON.parse_string(payload)
	if not parsed is Dictionary:
		return
	var message: Dictionary = parsed
	var message_type: String = str(message.get("type", ""))
	if message_type != "snapshot_request":
		return
	var state: Dictionary = _peers.get(peer_id, {})
	var options: Dictionary = _default_snapshot_options()
	var requested_options: Variant = message.get("options", {})
	if requested_options is Dictionary:
		for key in requested_options:
			options[key] = requested_options[key]
	state["snapshot_options"] = options
	if message.has("request_id"):
		state["request_id"] = str(message.get("request_id", ""))
	_peers[peer_id] = state
	var peer: WebSocketPeer = state.get("peer", null)
	if peer != null and peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_send_snapshot(peer, state)

func _record_send_failure(error: Error, message_type: String, size_bytes: int) -> void:
	if _metrics_module == null or not _metrics_module.has_method("event"):
		return
	_metrics_module.event("gd_observe.live_send_failed", {"type": message_type}, {"error": error, "size_bytes": size_bytes})

func _connect_metric_stream() -> void:
	if _metrics_module == null:
		return
	var log_callable: Callable = Callable(self, "_broadcast_stream_entry")
	var event_callable: Callable = Callable(self, "_broadcast_stream_entry")
	var trace_callable: Callable = Callable(self, "_broadcast_stream_entry")
	if _metrics_module.has_signal("log_recorded") and not _metrics_module.log_recorded.is_connected(log_callable):
		_metrics_module.log_recorded.connect(log_callable)
	if _metrics_module.has_signal("event_recorded") and not _metrics_module.event_recorded.is_connected(event_callable):
		_metrics_module.event_recorded.connect(event_callable)
	if _metrics_module.has_signal("frame_trace_recorded") and not _metrics_module.frame_trace_recorded.is_connected(trace_callable):
		_metrics_module.frame_trace_recorded.connect(trace_callable)

func _disconnect_metric_stream() -> void:
	if _metrics_module == null:
		return
	var callable: Callable = Callable(self, "_broadcast_stream_entry")
	if _metrics_module.has_signal("log_recorded") and _metrics_module.log_recorded.is_connected(callable):
		_metrics_module.log_recorded.disconnect(callable)
	if _metrics_module.has_signal("event_recorded") and _metrics_module.event_recorded.is_connected(callable):
		_metrics_module.event_recorded.disconnect(callable)
	if _metrics_module.has_signal("frame_trace_recorded") and _metrics_module.frame_trace_recorded.is_connected(callable):
		_metrics_module.frame_trace_recorded.disconnect(callable)

func _broadcast_stream_entry(entry: Dictionary) -> void:
	for state in _peers.values():
		var peer: WebSocketPeer = state.get("peer", null)
		if peer != null and peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
			_send_json(peer, entry)
