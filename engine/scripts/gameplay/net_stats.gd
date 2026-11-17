class_name NetStats
extends CanvasLayer
## Client network statistics: F3 toggles an overlay; --netstats prints a line every 5 s and a
## summary when the match ends. Bytes are measured by the Transport (payload + framing).

var match_node: Node
var label: Label
var acc := 0.0
var t_total := 0.0
var win_t := 0.0
var last_in := 0
var last_out := 0
var rate_in := 0.0
var rate_out := 0.0
var start_in := -1
var start_out := 0
var printed_final := false
var log_enabled := false

func _ready() -> void:
	layer = 50
	log_enabled = Game.args.has("netstats")
	label = Label.new()
	label.position = Vector2(12, 12)
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 5)
	label.visible = Game.args.has("overlay")
	add_child(label)

func toggle_overlay() -> void:
	label.visible = not label.visible

func _process(delta: float) -> void:
	var tr: Transport = Net.transport
	if tr == null or match_node == null:
		return
	if start_in < 0:
		start_in = tr.bytes_in
		start_out = tr.bytes_out
		last_in = tr.bytes_in
		last_out = tr.bytes_out
	acc += delta
	t_total += delta
	if acc >= 1.0:
		rate_in = (tr.bytes_in - last_in) / acc
		rate_out = (tr.bytes_out - last_out) / acc
		last_in = tr.bytes_in
		last_out = tr.bytes_out
		acc = 0.0
		if label.visible:
			label.text = _overlay_text()
	win_t += delta
	if log_enabled and win_t >= 5.0:
		win_t = 0.0
		print(line("[netstats]"))

func _overlay_text() -> String:
	var m := match_node
	var age: float = (m._now_ticks() - m.last_snap_time) / Proto.TICK_RATE * 1000.0
	return "ping %d ms   jitter %.0f ms   loss %.1f%%\nin %.2f KB/s   out %.2f KB/s\nsnapshot age %d ms   interp delay %.0f ms\nreconcile err %.3f m (avg %.3f, max %.2f)   replays %d\ntransport %s%s" % [
		Net.rtt_ms, m.jitter_ema * 1000.0 / Proto.TICK_RATE, loss_pct(),
		rate_in / 1024.0, rate_out / 1024.0, age, m.interp_delay * 1000.0 / Proto.TICK_RATE,
		m.corr_last, m.corr_sum / maxf(m.corr_count, 1), m.corr_max, m.reconcile_count,
		"websocket" if Net.transport.kind == Transport.Kind.WEBSOCKET else "enet",
		"   (sim %d ms / %d ms / %.0f%%)" % [Net.transport.sim_latency * 1000, Net.transport.sim_jitter * 1000, Net.transport.sim_loss * 100] if Net.transport.sim_active() else ""]

func loss_pct() -> float:
	var m := match_node
	return 100.0 * m.snaps_lost / maxf(m.snaps_lost + m.snaps_recv, 1)

func line(prefix: String) -> String:
	var m := match_node
	var tr: Transport = Net.transport
	var secs := maxf(t_total, 0.001)
	var tin := (tr.bytes_in - start_in) / secs if tr != null else 0.0
	var tout := (tr.bytes_out - start_out) / secs if tr != null else 0.0
	return "%s name=%s slot=%d t=%.0fs in=%.0f B/s out=%.0f B/s snaps=%d (%.1f/s) lost=%d nobase=%d rtt=%d ms jitter=%.1f ms interp=%.0f ms recon_err avg=%.4f m max=%.3f m n=%d >1m=%d replays=%d replay_ticks=%d hist(<5cm,<25cm,<1m,>=1m)=%s" % [
		prefix, Game.player_name, m.my_slot, t_total, tin, tout, m.snaps_recv, m.snaps_recv / secs, m.snaps_lost,
		m.snaps_dropped_nobase, Net.rtt_ms, m.jitter_ema * 1000.0 / Proto.TICK_RATE, m.interp_delay * 1000.0 / Proto.TICK_RATE,
		m.corr_sum / maxf(m.corr_count, 1), m.corr_max, m.corr_count, m.corr_big, m.reconcile_count, m.replay_ticks, str(m.corr_hist).replace(" ", "")]

func _exit_tree() -> void:
	if log_enabled and not printed_final and match_node != null:
		printed_final = true
		print(line("[netstats-final]"))
