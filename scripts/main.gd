extends Node3D
## Greybox 3D street scene + mobile UI, all built in code.
## Performance rules: one directional light, no shadows on low tier,
## shared meshes/materials, no per-frame allocations.

const STALL_COLORS := [
	Color("8d5a2b"), Color("e8c77a"), Color("d99a3b"),
	Color("4fa3c7"), Color("c0502f"), Color("7a9e4a")]

var stall_nodes: Array[MeshInstance3D] = []
var coin_label: Label
var rate_label: Label
var boost_label: Label
var tap_button: Button
var stall_buttons: Array[Button] = []
var _ui_timer := 0.0
var _bounce := 0.0

func _ready() -> void:
	_build_world()
	_build_ui()
	GameState.changed.connect(_refresh)
	_refresh()
	if GameState.offline_gain > 0.0:
		_show_offline_popup()

func _build_world() -> void:
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 14.0
	cam.position = Vector3(10, 10, 10)
	add_child(cam)
	cam.look_at(Vector3(0, 0, 1), Vector3.UP)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 40, 0)
	sun.shadow_enabled = false
	add_child(sun)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color("87c8e8")
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color("ffffff")
	e.ambient_light_energy = 0.6
	env.environment = e
	add_child(env)

	var ground := MeshInstance3D.new()
	var gm := PlaneMesh.new()
	gm.size = Vector2(30, 30)
	ground.mesh = gm
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color("c9b27a")
	ground.material_override = gmat
	add_child(ground)

	var box := BoxMesh.new()
	box.size = Vector3(2.4, 2.0, 2.4)
	for i in GameState.STALLS.size():
		var m := MeshInstance3D.new()
		m.mesh = box
		var mat := StandardMaterial3D.new()
		mat.albedo_color = STALL_COLORS[i]
		m.material_override = mat
		m.position = Vector3(-5.0 + (i % 3) * 5.0, 1.0, -2.5 + int(i / 3) * 5.0)
		m.visible = GameState.levels[i] > 0
		add_child(m)
		stall_nodes.append(m)

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 14)
	layer.add_child(root)

	coin_label = Label.new()
	coin_label.add_theme_font_size_override("font_size", 72)
	coin_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(coin_label)
	rate_label = Label.new()
	rate_label.add_theme_font_size_override("font_size", 40)
	rate_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(rate_label)
	boost_label = Label.new()
	boost_label.add_theme_font_size_override("font_size", 36)
	boost_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(boost_label)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(spacer)

	tap_button = _make_button(root, "", 56)
	tap_button.pressed.connect(func(): GameState.tap(); _bounce = 1.0)

	for i in GameState.STALLS.size():
		var b := _make_button(root, "", 38)
		b.pressed.connect(func(): GameState.buy_stall(i))
		stall_buttons.append(b)

	var ads := HBoxContainer.new()
	ads.add_theme_constant_override("separation", 14)
	root.add_child(ads)
	var boost_btn := _make_button(ads, "Watch ad: 2x income 30 min", 34)
	boost_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	boost_btn.pressed.connect(func(): AdService.show_rewarded("boost"))
	var chest_btn := _make_button(ads, "Watch ad: Free chest", 34)
	chest_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chest_btn.pressed.connect(func(): AdService.show_rewarded("chest"))

func _make_button(parent: Control, text: String, size: int) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 120)
	b.add_theme_font_size_override("font_size", size)
	parent.add_child(b)
	return b

func _show_offline_popup() -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "Welcome back!"
	dlg.dialog_text = "You earned %s while away.\nWatch an ad to double it?" % GameState.format_num(GameState.offline_gain)
	dlg.ok_button_text = "Watch ad (x2)"
	dlg.add_cancel_button("No thanks")
	dlg.confirmed.connect(func(): AdService.show_rewarded("offline"))
	add_child(dlg)
	dlg.popup_centered(Vector2i(900, 420))

func _refresh() -> void:
	coin_label.text = GameState.format_num(GameState.coins) + " coins"
	rate_label.text = GameState.format_num(GameState.income_per_sec()) + " / sec"
	tap_button.text = "COOK!  (+%s)   upgrade: %s" % [
		GameState.format_num(GameState.tap_value()), GameState.format_num(GameState.tap_cost())]
	for i in GameState.STALLS.size():
		var s = GameState.STALLS[i]
		stall_buttons[i].text = "%s  Lv %d  -  %s" % [
			s.name, GameState.levels[i], GameState.format_num(GameState.upgrade_cost(i))]
		stall_nodes[i].visible = GameState.levels[i] > 0

func _process(delta: float) -> void:
	_ui_timer += delta
	if _ui_timer >= 0.1:
		_ui_timer = 0.0
		_refresh()
		var left := GameState.boost_until - int(Time.get_unix_time_from_system())
		boost_label.text = "2x boost: %d:%02d" % [left / 60, left % 60] if left > 0 else ""
	if _bounce > 0.0:
		_bounce = maxf(0.0, _bounce - delta * 4.0)
		for i in stall_nodes.size():
			stall_nodes[i].scale = Vector3.ONE * (1.0 + 0.08 * _bounce)
