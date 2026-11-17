extends SceneTree
## Desktop "Start local server" path, headless: the menu launches a server process, connects,
## creates a lobby and sees it in the list. Run: Godot --headless --path game -s tests/net/local_server_test.gd
var t := 0.0
var step := 0
var menu: Node

func _initialize() -> void:
	menu = load("res://scenes/main_menu.tscn").instantiate()
	root.add_child.call_deferred(menu)

func _process(delta: float) -> bool:
	t += delta
	var net = root.get_node("Net")
	if step == 0 and t > 0.5:
		menu.name_edit.text = "LocalTester"
		menu._on_local_server()
		step = 1
	elif step == 1 and net.state == "browser":
		print("[test] connected to the local server as peer %d" % net.my_id)
		net.create_lobby("Garage")
		step = 2
	elif step == 2 and net.state == "lobby":
		print("[test] in lobby '%s', host=%s" % [net.lobby.name, str(net.is_lobby_host())])
		net.leave_lobby()
		step = 3
	elif step == 3 and net.state == "browser" and t > 0:
		step = 4
		t = 0.0
	elif step == 4 and t > 1.0:
		print("[test] lobby list after leaving: %s" % str(net.lobbies))
		print("[test] PASS")
		net.stop_local_server()
		return true
	if t > 25.0 and step < 4:
		print("[test] FAIL at step %d (state %s)" % [step, net.state])
		net.stop_local_server()
		return true
	return false
