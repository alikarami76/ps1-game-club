class_name Transport
extends Node
## One network connection layer for both roles. WebSocket (default, works in browsers) or ENet
## (optional, desktop only, --transport=enet). Packets are raw PackedByteArrays; nothing goes
## through Godot RPCs or SceneMultiplayer.
##
## A debug network simulator (client side, both directions) adds one-way latency, jitter and
## loss: --net-latency=MS --net-jitter=MS --net-loss=PERCENT [--net-loss-mode=hol|drop].
## WebSocket is TCP, so a lost segment never disappears: it stalls everything behind it until it
## is resent (head-of-line blocking, "hol", the default for WebSocket). "drop" discards
## unreliable packets instead (what ENet does).

signal peer_joined(id: int)
signal peer_left(id: int)
signal connected
signal connect_failed
signal disconnected
signal packet(from_id: int, data: PackedByteArray)

enum Kind { WEBSOCKET, ENET }

const CH_STATE := 0
const CH_RELIABLE := 1

var kind := Kind.WEBSOCKET
var peer: MultiplayerPeer
var is_server := false
var _client_state := 0        # 0 idle, 1 connecting, 2 connected
var _known: Dictionary = {}

# statistics (payload + estimated framing, bytes)
var bytes_in := 0
var bytes_out := 0
var packets_in := 0
var packets_out := 0

# simulator
var sim_latency := 0.0
var sim_jitter := 0.0
var sim_loss := 0.0
var sim_hol := true
var _out_q: Array = []        # [due, to, data, reliable]
var _in_q: Array = []         # [due, from, data]
var _last_out_due := 0.0
var _last_in_due := 0.0

static func kind_from_name(n: String) -> Kind:
	return Kind.ENET if n.to_lower() == "enet" else Kind.WEBSOCKET

func _ready() -> void:
	process_priority = -1000
	process_physics_priority = -1000

func configure_sim(latency_ms: float, jitter_ms: float, loss_pct: float, mode := "") -> void:
	sim_latency = maxf(latency_ms, 0.0) / 1000.0
	sim_jitter = maxf(jitter_ms, 0.0) / 1000.0
	sim_loss = clampf(loss_pct / 100.0, 0.0, 1.0)
	sim_hol = (mode == "hol") or (mode == "" and kind == Kind.WEBSOCKET)

func sim_active() -> bool:
	return sim_latency > 0.0 or sim_jitter > 0.0 or sim_loss > 0.0

## tls_server (WebSocket only): accept wss:// with this certificate instead of ws://.
func listen(port: int, k: Kind, bind := "*", tls_server: TLSOptions = null) -> Error:
	close()
	kind = k
	is_server = true
	var err := OK
	if k == Kind.ENET:
		var e := ENetMultiplayerPeer.new()
		err = e.create_server(port, 256, 2)
		peer = e
	else:
		var w := WebSocketMultiplayerPeer.new()
		w.inbound_buffer_size = 1 << 18
		w.outbound_buffer_size = 1 << 18
		w.max_queued_packets = 4096
		err = w.create_server(port, bind, tls_server)
		peer = w
	if err != OK:
		peer = null
		return err
	peer.peer_connected.connect(_on_peer_connected)
	peer.peer_disconnected.connect(_on_peer_disconnected)
	return OK

## host: a host name or address (then scheme picks ws or wss), or a full ws:// / wss:// URL.
## Desktop wss accepts the server's self-signed certificate (TLSOptions.client_unsafe): the LAN
## server makes its own certificate, so there is no authority to check it against. In a browser
## the page connects to wss://<page host:port>/ws, so the page's certificate exception (Advanced
## > Proceed) covers it (Net.web_connect).
func connect_to(host: String, port: int, k: Kind, scheme := "ws") -> Error:
	close()
	kind = k
	is_server = false
	var err := OK
	if k == Kind.ENET:
		var e := ENetMultiplayerPeer.new()
		err = e.create_client(host, port, 2)
		peer = e
	else:
		var w := WebSocketMultiplayerPeer.new()
		w.inbound_buffer_size = 1 << 18
		w.outbound_buffer_size = 1 << 18
		var url := host if host.begins_with("ws://") or host.begins_with("wss://") else "%s://%s:%d" % [scheme, host, port]
		var opts: TLSOptions = null
		if url.begins_with("wss://") and not OS.has_feature("web"):
			opts = TLSOptions.client_unsafe()
		err = w.create_client(url, opts)
		peer = w
	if err != OK:
		peer = null
		return err
	_client_state = 1
	return OK

func close() -> void:
	if peer != null:
		peer.close()
	peer = null
	_client_state = 0
	_known.clear()
	_out_q.clear()
	_in_q.clear()

func is_open() -> bool:
	return peer != null

func is_connected_to_server() -> bool:
	return _client_state == 2

func _on_peer_connected(id: int) -> void:
	_known[id] = true
	peer_joined.emit(id)

func _on_peer_disconnected(id: int) -> void:
	_known.erase(id)
	peer_left.emit(id)

func disconnect_peer(id: int) -> void:
	if peer != null and is_server:
		peer.disconnect_peer(id)

func _framing(size: int, outgoing: bool) -> int:
	if kind == Kind.WEBSOCKET:
		var h := 2 if size < 126 else 4
		if outgoing != is_server:
			h += 4   # client -> server frames are masked
		return h
	return 10        # rough ENet command + header share

## Send one packet. to = 1 for the server (client side), or a peer id (server side).
func send(to: int, data: PackedByteArray, reliable: bool) -> void:
	if peer == null:
		return
	if not is_server and sim_active():
		var now := _now()
		var due := now + sim_latency + randf() * sim_jitter
		if sim_loss > 0.0 and randf() < sim_loss:
			if not reliable and not sim_hol:
				return
			due += 2.0 * sim_latency + 0.03   # resent after about one round trip
		due = maxf(due, _last_out_due)        # keep order (one stream)
		_last_out_due = due
		_out_q.append([due, to, data, reliable])
		return
	_raw_send(to, data, reliable)

func _raw_send(to: int, data: PackedByteArray, reliable: bool) -> void:
	if peer == null:
		return
	if is_server and not _known.has(to):
		return
	if is_server and kind == Kind.WEBSOCKET:
		var wp := (peer as WebSocketMultiplayerPeer).get_peer(to)
		if wp == null or wp.get_ready_state() != WebSocketPeer.STATE_OPEN:
			return
	if is_server and kind == Kind.ENET:
		# A peer that is disconnecting (or not yet fully connected) has no channels; sending to it
		# logs "Unable to send packet on channel N, max channels: 0".
		var ep := (peer as ENetMultiplayerPeer).get_peer(to)
		if ep == null or not ep.is_active() or ep.get_state() != ENetPacketPeer.STATE_CONNECTED:
			return
	peer.set_target_peer(to)
	if kind == Kind.ENET:
		peer.transfer_mode = MultiplayerPeer.TRANSFER_MODE_RELIABLE if reliable else MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED
		peer.transfer_channel = CH_RELIABLE if reliable else CH_STATE
	else:
		peer.transfer_mode = MultiplayerPeer.TRANSFER_MODE_RELIABLE
	if peer.put_packet(data) == OK:
		bytes_out += data.size() + _framing(data.size(), true)
		packets_out += 1

func _now() -> float:
	return Time.get_ticks_usec() / 1000000.0

func _process(_d: float) -> void:
	poll()

func _physics_process(_d: float) -> void:
	poll()

func poll() -> void:
	if peer == null:
		_pump()
		return
	peer.poll()
	if peer == null:
		return
	if not is_server:
		var st := peer.get_connection_status()
		if _client_state == 1 and st == MultiplayerPeer.CONNECTION_CONNECTED:
			_client_state = 2
			connected.emit()
		elif _client_state == 1 and st == MultiplayerPeer.CONNECTION_DISCONNECTED:
			_client_state = 0
			peer = null
			connect_failed.emit()
			return
		elif _client_state == 2 and st == MultiplayerPeer.CONNECTION_DISCONNECTED:
			_client_state = 0
			peer = null
			disconnected.emit()
			return
	while peer != null and peer.get_available_packet_count() > 0:
		var from := peer.get_packet_peer()
		var data := peer.get_packet()
		bytes_in += data.size() + _framing(data.size(), false)
		packets_in += 1
		if not is_server and sim_active():
			var now := _now()
			var due := now + sim_latency + randf() * sim_jitter
			if sim_loss > 0.0 and randf() < sim_loss:
				var unreliable := data.size() > 0 and (data[0] == Proto.S_SNAP or data[0] == Proto.S_PONG)
				if unreliable and not sim_hol:
					continue
				due += 2.0 * sim_latency + 0.03
			due = maxf(due, _last_in_due)
			_last_in_due = due
			_in_q.append([due, from, data])
		else:
			packet.emit(from, data)
	_pump()

func _pump() -> void:
	if _out_q.is_empty() and _in_q.is_empty():
		return
	var now := _now()
	while not _out_q.is_empty() and _out_q[0][0] <= now:
		var q: Array = _out_q.pop_front()
		_raw_send(q[1], q[2], q[3])
	while not _in_q.is_empty() and _in_q[0][0] <= now:
		var r: Array = _in_q.pop_front()
		packet.emit(r[1], r[2])
