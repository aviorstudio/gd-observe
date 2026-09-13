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
	var max_client_buffer_bytes: int
	var allow_non_loopback: bool
	var auth_token: String
	var auth_timeout_msec: int
	var allowed_tag_keys: PackedStringArray
	var allowed_field_keys: PackedStringArray

	func _init(
		p_enabled: bool = false,
		p_host: String = "127.0.0.1",
		p_port: int = 8765,
		p_snapshot_interval_msec: int = 250,
		p_include_raw_samples: bool = false,
		p_include_runtime_stats: bool = true,
		p_include_frame_traces: bool = false,
		p_max_snapshot_bytes: int = 900000,
		p_max_client_buffer_bytes: int = 1048576,
		p_allow_non_loopback: bool = false,
		p_auth_token: String = "",
		p_auth_timeout_msec: int = 5000,
		p_allowed_tag_keys: PackedStringArray = PackedStringArray(),
		p_allowed_field_keys: PackedStringArray = PackedStringArray()
	) -> void:
		enabled = p_enabled
		host = p_host
		port = p_port
		snapshot_interval_msec = p_snapshot_interval_msec
		include_raw_samples = p_include_raw_samples
		include_runtime_stats = p_include_runtime_stats
		include_frame_traces = p_include_frame_traces
		max_snapshot_bytes = p_max_snapshot_bytes
		max_client_buffer_bytes = p_max_client_buffer_bytes
		allow_non_loopback = p_allow_non_loopback
		auth_token = p_auth_token
		auth_timeout_msec = p_auth_timeout_msec
		allowed_tag_keys = p_allowed_tag_keys.duplicate()
		allowed_field_keys = p_allowed_field_keys.duplicate()

var _config: MetricsLiveServerConfig = MetricsLiveServerConfig.new()
var _metrics_module: RefCounted = null
var _runtime_sampler: RefCounted = null
var _server: TCPServer = TCPServer.new()
var _peers: Dictionary[int, Dictionary] = {}
var _next_peer_id: int = 1
var _last_snapshot_msec: int = 0
var _dropped_message_count: int = 0
var _slow_client_disconnect_count: int = 0

func _ready() -> void:
	set_process(false)

func start_server(metrics_module: RefCounted, config: MetricsLiveServerConfig = null, runtime_sampler: RefCounted = null) -> Error:
	stop()
	_metrics_module = metrics_module
	_config = config if config != null else MetricsLiveServerConfig.new()
	_runtime_sampler = runtime_sampler if runtime_sampler != null else MetricsRuntimeSamplerScript.new()
	_dropped_message_count = 0
	_slow_client_disconnect_count = 0
	if not _config.enabled:
		return OK
	if _metrics_module == null:
		return ERR_INVALID_PARAMETER
	if not _is_loopback_host(_config.host) and (not _config.allow_non_loopback or _config.auth_token.is_empty()):
		return ERR_UNAUTHORIZED
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

func get_transport_counters() -> Dictionary[String, int]:
	return {
		"dropped_messages": _dropped_message_count,
		"slow_client_disconnects": _slow_client_disconnect_count,
	}

func _process(delta: float) -> void:
	_accept_pending_connections()
	_poll_peers()
	if _metrics_module != null and _metrics_module.has_method("flush_frame_trace"):
		_metrics_module.flush_frame_trace()
	if _config.snapshot_interval_msec <= 0:
		return
	var now_msec: int = Time.get_ticks_msec()
	var interval_msec: int = maxi(_config.snapshot_interval_msec, 50)
	if now_msec - _last_snapshot_msec >= interval_msec:
		_last_snapshot_msec = now_msec
		if _config.include_runtime_stats and _runtime_sampler != null:
			_runtime_sampler.sample(delta)
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
		var loopback: bool = _is_loopback_host(_config.host)
		_peers[peer_id] = {
			"peer_id": peer_id,
			"peer": peer,
			"opened": false,
			"authenticated": loopback,
			"non_loopback": not loopback,
			"auth_deadline_msec": Time.get_ticks_msec() + maxi(_config.auth_timeout_msec, 1),
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
				if bool(state.get("authenticated", false)):
					_send_hello(peer_id, peer, state)
					_send_snapshot(peer, state, true)
			while peer.get_available_packet_count() > 0:
				_handle_client_packet(peer_id, peer.get_packet().get_string_from_utf8())
			if not bool(state.get("authenticated", false)) and Time.get_ticks_msec() >= int(state.get("auth_deadline_msec", 0)):
				peer.close(1008, "authentication timeout")
		elif ready_state == WebSocketPeer.STATE_CLOSED:
			closed_peers.append(peer_id)
	for peer_id in closed_peers:
		_peers.erase(peer_id)
		client_disconnected.emit(peer_id)

func _broadcast_snapshot() -> void:
	for state in _peers.values():
		var peer: WebSocketPeer = state.get("peer", null)
		if bool(state.get("authenticated", false)) and peer != null and peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
			_send_snapshot(peer, state)

func _send_hello(peer_id: int, peer: WebSocketPeer, state: Dictionary) -> void:
	_send_json(peer, {
		"type": "hello",
		"version": 2,
		"peer_id": peer_id,
		"server": "gd-observe",
		"url": get_url(),
		"read_only": true,
		"supports_filtered_snapshots": true,
		"default_snapshot": _default_snapshot_options(),
	}, state)

func _send_snapshot(peer: WebSocketPeer, state: Dictionary = {}, sample_runtime: bool = false) -> void:
	if _metrics_module == null:
		_send_error(peer, "metrics_unavailable", "Metrics module is not configured", state)
		return
	var options: Dictionary = state.get("snapshot_options", _default_snapshot_options())
	var snapshot: Dictionary[String, Variant] = _metrics_module.export_snapshot_filtered(options)
	snapshot["type"] = "snapshot"
	snapshot["live"] = {
		"dropped_messages": int(state.get("dropped_messages", 0)),
		"total_dropped_messages": _dropped_message_count,
		"slow_client_disconnects": _slow_client_disconnect_count,
		"max_snapshot_bytes": _config.max_snapshot_bytes,
		"max_client_buffer_bytes": _config.max_client_buffer_bytes,
	}
	if state.has("request_id"):
		snapshot["request_id"] = str(state.get("request_id", ""))
	if _config.include_runtime_stats and _runtime_sampler != null:
		var runtime_snapshot: Dictionary = _runtime_sampler.get_last_snapshot()
		if sample_runtime or runtime_snapshot.is_empty():
			runtime_snapshot = _runtime_sampler.sample(0.0)
		snapshot["runtime"] = runtime_snapshot
	_send_json(peer, snapshot, state)

func _send_error(peer: WebSocketPeer, code: String, message: String, state: Dictionary = {}) -> void:
	_send_json(peer, {
		"type": "error",
		"code": code,
		"message": message,
		"timestamp_usec": Time.get_ticks_usec(),
	}, state)

func _send_json(peer: WebSocketPeer, payload: Dictionary, state: Dictionary = {}) -> void:
	if peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	if _is_slow_client(peer.get_current_outbound_buffered_amount()):
		state["dropped_messages"] = int(state.get("dropped_messages", 0)) + 1
		_dropped_message_count += 1
		_slow_client_disconnect_count += 1
		peer.close(1008, "slow client")
		return
	var safe_payload: Dictionary = _sanitize_payload(payload, state)
	var encoded: String = JSON.stringify(safe_payload)
	var encoded_size: int = encoded.to_utf8_buffer().size()
	if _config.max_snapshot_bytes > 0 and encoded_size > _config.max_snapshot_bytes and str(payload.get("type", "")) == "snapshot":
		var compact: Dictionary = safe_payload.duplicate(true)
		compact["metrics"] = []
		compact["recent_frame_traces"] = []
		compact["truncated"] = true
		compact["truncated_reason"] = "snapshot exceeded max_snapshot_bytes"
		compact["original_size_bytes"] = encoded_size
		encoded = JSON.stringify(compact)
	var error: Error = peer.send_text(encoded)
	if error != OK:
		state["dropped_messages"] = int(state.get("dropped_messages", 0)) + 1
		_dropped_message_count += 1
		_record_send_failure(error, str(safe_payload.get("type", "unknown")), encoded.to_utf8_buffer().size())

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
	var state: Dictionary = _peers.get(peer_id, {})
	if not bool(state.get("authenticated", false)):
		if message_type != "auth" or not _constant_time_equal(str(message.get("token", "")), _config.auth_token):
			var unauthorized_peer: WebSocketPeer = state.get("peer", null)
			if unauthorized_peer != null:
				unauthorized_peer.close(1008, "authentication required")
			return
		state["authenticated"] = true
		_peers[peer_id] = state
		var authenticated_peer: WebSocketPeer = state.get("peer", null)
		if authenticated_peer != null:
			_send_hello(peer_id, authenticated_peer, state)
			_send_snapshot(authenticated_peer, state, true)
		return
	if message_type != "snapshot_request":
		return
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
		_send_snapshot(peer, state, true)

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
		if bool(state.get("authenticated", false)) and peer != null and peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
			_send_json(peer, entry, state)

func _is_loopback_host(host: String) -> bool:
	return host.strip_edges().to_lower() in ["127.0.0.1", "::1", "localhost"]

func _is_slow_client(buffered_bytes: int) -> bool:
	var outbound_limit: int = maxi(_config.max_client_buffer_bytes, 0)
	return outbound_limit == 0 or buffered_bytes >= outbound_limit

func _constant_time_equal(provided: String, expected: String) -> bool:
	var provided_digest: PackedByteArray = provided.sha256_buffer()
	var expected_digest: PackedByteArray = expected.sha256_buffer()
	var difference: int = 0
	for index in provided_digest.size():
		difference |= provided_digest[index] ^ expected_digest[index]
	return difference == 0

func _sanitize_payload(payload: Dictionary, state: Dictionary) -> Dictionary:
	if not bool(state.get("non_loopback", false)):
		return payload
	return _sanitize_value(payload)

func _sanitize_value(value: Variant, container_key: String = "") -> Variant:
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value:
			var normalized_key: String = str(key)
			if container_key == "tags" and normalized_key not in _config.allowed_tag_keys:
				continue
			if container_key == "fields" and normalized_key not in _config.allowed_field_keys:
				continue
			result[key] = _sanitize_value(value[key], normalized_key)
		return result
	if value is Array:
		var result: Array = []
		for item in value:
			result.append(_sanitize_value(item, container_key))
		return result
	return value
