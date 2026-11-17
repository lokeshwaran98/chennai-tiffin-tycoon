extends Node3D
## Low-poly 3D street scene + mobile UI, all built in code.
## Performance rules: one directional light, no shadows, shared meshes and
## materials, pooled customers (no allocation after startup).

const STALL_COLORS := [
	Color("8d5a2b"), Color("e8c77a"), Color("d99a3b"),
	Color("4fa3c7"), Color("c0502f"), Color("7a9e4a")]
const ACCENT_COLORS := [
	Color("f2e6d0"), Color("ffffff"), Color("f0b43c"),
	Color("f7dc9a"), Color("e8b36a"), Color("d9c27a")]
const CUSTOMER_COLORS := [
	Color("2f6fb5"), Color("b53f6a"), Color("3f9e6a"), Color("8a5bb5"), Color("d08a2f")]
const MAX_CUSTOMERS := 12
const WALK_SPEED := 4.0

class Cust:
	var node: MeshInstance3D
	var state: int = -1   # -1 pooled, 0 walking in, 1 eating, 2 leaving
	var target: Vector3 = Vector3.ZERO
	var timer: float = 0.0

var _mats: Dictionary = {}
var stall_nodes: Array = []
var stall_positions: Array = []
var customers: Array = []
var _spawn_timer := 0.0
var _ui_timer := 0.0
var _bounce := 0.0

var coin_label: Label
var rate_label: Label
var status_label: Label
var tap_button: Button
var stall_buttons: Array = []
var prestige_button: Button
var daily_button: Button
var daily_ad_button: Button
var modal_dim: ColorRect
var modal_title: Label
var modal_body: Label
var modal_ok: Button
var modal_cancel: Button
var _modal_cb: Callable

func _ready() -> void:
	randomize()
	_build_world()
	_build_customers()
	_build_ui()
	GameState.changed.connect(_refresh)
	_refresh()
	if GameState.offline_gain > 0.0:
		_show_offline_popup()
	if OS.get_cmdline_user_args().has("--smoke"):
		_run_smoke_actions()
	if OS.get_cmdline_user_args().has("--shot"):
		_take_shot()

# CI-only: render a screenshot (software GL under xvfb) so the look can be reviewed.
func _take_shot() -> void:
	await get_tree().create_timer(9.0).timeout
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := OS.get_environment("SHOT_PATH")
	if path == "":
		path = "user://shot.png"
	img.save_png(path)
	print("SHOT_SAVED ", path, " ", img.get_size())
	get_tree().quit()

# CI-only: exercise buying, ads, daily reward and prestige without a screen.
func _run_smoke_actions() -> void:
	await get_tree().create_timer(6.0).timeout
	for i in GameState.STALLS.size():
		GameState.buy_stall(i)
	GameState.buy_tap()
	GameState.tap()
	GameState.claim_daily(1.0)
	AdService.show_rewarded("boost")
	AdService.show_rewarded("chest")
	await get_tree().create_timer(2.5).timeout
	GameState.double_offline()
	GameState.prestige()
	await get_tree().create_timer(1.0).timeout
	print("SMOKE_DONE coins=", GameState.coins, " prestige=", GameState.prestige_points)

# ------------------------------------------------------------------ world
func _mat(c: Color) -> StandardMaterial3D:
	var key := c.to_html()
	if not _mats.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = c
		m.roughness = 1.0
		_mats[key] = m
	return _mats[key]

func _add_box(parent: Node3D, size: Vector3, pos: Vector3, c: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = _mat(c)
	mi.position = pos
	parent.add_child(mi)
	return mi

func _add_cyl(parent: Node3D, radius: float, height: float, pos: Vector3, c: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = height
	cm.radial_segments = 10
	cm.rings = 1
	mi.mesh = cm
	mi.material_override = _mat(c)
	mi.position = pos
	parent.add_child(mi)
	return mi

func _add_sphere(parent: Node3D, radius: float, pos: Vector3, c: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	sm.radial_segments = 10
	sm.rings = 6
	mi.mesh = sm
	mi.material_override = _mat(c)
	mi.position = pos
	parent.add_child(mi)
	return mi

func _build_world() -> void:
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.keep_aspect = Camera3D.KEEP_WIDTH
	cam.size = 27.0
	cam.v_offset = -6.0
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

	# Ground, road and footpath
	_add_box(self, Vector3(34, 0.2, 34), Vector3(0, -0.1, 0), Color("c9b27a"))
	_add_box(self, Vector3(34, 0.22, 4.0), Vector3(0, -0.09, 9.0), Color("55585c"))
	_add_box(self, Vector3(34, 0.26, 1.2), Vector3(0, -0.07, 6.2), Color("b9b2a0"))
	for x in range(-14, 15, 4):
		_add_box(self, Vector3(1.6, 0.02, 0.2), Vector3(x, 0.03, 9.0), Color("e8e2c8"))

	# Palm trees (trunk + leaf clusters)
	for p in [Vector3(-11, 0, -7), Vector3(11, 0, -7), Vector3(-11, 0, 3), Vector3(12, 0, 3)]:
		var tree := Node3D.new()
		tree.position = p
		add_child(tree)
		_add_cyl(tree, 0.18, 3.0, Vector3(0, 1.5, 0), Color("7a5a35"))
		_add_sphere(tree, 0.9, Vector3(0, 3.2, 0), Color("3f8f3f"))
		_add_sphere(tree, 0.6, Vector3(0.7, 2.9, 0.3), Color("4aa04a"))
		_add_sphere(tree, 0.6, Vector3(-0.6, 2.9, -0.3), Color("4aa04a"))

	# Stalls (hidden until bought)
	for i in GameState.STALLS.size():
		var pos := Vector3(-5.0 + (i % 3) * 5.0, 0.0, -3.0 + int(i / 3) * 5.0)
		stall_positions.append(pos)
		var s := _make_stall(i)
		s.position = pos
		s.visible = GameState.levels[i] > 0
		add_child(s)
		stall_nodes.append(s)

func _make_stall(i: int) -> Node3D:
	var s := Node3D.new()
	var c: Color = STALL_COLORS[i]
	_add_box(s, Vector3(2.6, 1.0, 1.6), Vector3(0, 0.5, 0), c.darkened(0.25))   # counter
	_add_box(s, Vector3(2.7, 0.12, 1.7), Vector3(0, 1.05, 0), Color("e9dfc9"))   # counter top
	for sx in [-1.2, 1.2]:                                                        # poles
		_add_cyl(s, 0.06, 2.2, Vector3(sx, 1.1, -0.7), Color("5a4a3a"))
	_add_box(s, Vector3(3.0, 0.14, 2.1), Vector3(0, 2.25, 0.1), c)                # awning
	_add_box(s, Vector3(3.0, 0.3, 0.1), Vector3(0, 2.0, 1.1), c.lightened(0.25))  # awning fringe
	var acc: Color = ACCENT_COLORS[i]
	_add_cyl(s, 0.38, 0.45, Vector3(-0.6, 1.35, 0), acc)                          # pot / tray
	_add_sphere(s, 0.3, Vector3(0.55, 1.33, 0.1), acc.darkened(0.1))             # food heap
	_add_box(s, Vector3(0.5, 0.5, 0.4), Vector3(0.9, 0.3, -0.3), Color("3a3a3a")) # stove
	return s

# --------------------------------------------------------------- customers
func _build_customers() -> void:
	var cap := CapsuleMesh.new()
	cap.radius = 0.3
	cap.height = 1.2
	cap.radial_segments = 8
	cap.rings = 2
	for i in MAX_CUSTOMERS:
		var c := Cust.new()
		var mi := MeshInstance3D.new()
		mi.mesh = cap
		mi.material_override = _mat(CUSTOMER_COLORS[i % CUSTOMER_COLORS.size()])
		mi.visible = false
		add_child(mi)
		c.node = mi
		customers.append(c)

func _spawn_customer() -> void:
	var active: Array = []
	for i in GameState.STALLS.size():
		if GameState.levels[i] > 0:
			active.append(i)
	if active.is_empty():
		return
	for c in customers:
		if c.state == -1:
			var si: int = active[randi() % active.size()]
			var sp: Vector3 = stall_positions[si]
			c.node.position = Vector3(-13.0, 0.6, 9.0)
			c.target = Vector3(sp.x + randf_range(-0.6, 0.6), 0.6, sp.z + 2.2)
			c.state = 0
			c.node.visible = true
			return

func _update_customers(delta: float) -> void:
	_spawn_timer += delta
	if _spawn_timer >= 0.9:
		_spawn_timer = 0.0
		var busy := 0
		for c in customers:
			if c.state != -1:
				busy += 1
		var desired := mini(MAX_CUSTOMERS, 1 + int(GameState.total_levels() / 4))
		if GameState.total_levels() > 0 and busy < desired:
			_spawn_customer()
	for c in customers:
		if c.state == -1:
			continue
		if c.state == 1:
			c.timer -= delta
			if c.timer <= 0.0:
				c.state = 2
				c.target = Vector3(13.0, 0.6, 9.0)
			continue
		var to: Vector3 = c.target - c.node.position
		var dist := to.length()
		if dist < 0.1:
			if c.state == 0:
				c.state = 1
				c.timer = randf_range(1.5, 3.0)
			else:
				c.state = -1
				c.node.visible = false
		else:
			c.node.position += to / dist * minf(WALK_SPEED * delta, dist)

# ---------------------------------------------------------------------- UI
func _box(c: Color, radius: int = 18) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = c
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	return sb

func _style_button(b: Button, base: Color) -> void:
	b.add_theme_stylebox_override("normal", _box(base))
	b.add_theme_stylebox_override("hover", _box(base.lightened(0.12)))
	b.add_theme_stylebox_override("pressed", _box(base.darkened(0.2)))
	b.add_theme_stylebox_override("disabled", _box(Color("4a4540")))
	b.add_theme_color_override("font_color", Color.WHITE)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	b.add_theme_color_override("font_disabled_color", Color("a8a199"))

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	# Top HUD with a translucent backing so numbers stay readable.
	var hud := PanelContainer.new()
	hud.set_anchors_preset(Control.PRESET_TOP_WIDE)
	hud.add_theme_stylebox_override("panel", _box(Color(0, 0, 0, 0.45), 0))
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(hud)
	var hud_box := VBoxContainer.new()
	hud_box.add_theme_constant_override("separation", 2)
	hud_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(hud_box)
	coin_label = _make_label(hud_box, 76)
	rate_label = _make_label(hud_box, 42)
	status_label = _make_label(hud_box, 34)

	# Bottom control panel (solid) so the street above stays visible.
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	panel.add_theme_stylebox_override("panel", _box(Color("2a211a"), 28))
	layer.add_child(panel)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	panel.add_child(root)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 640)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 10)
	scroll.add_child(list)

	tap_button = _make_button(list, "", 48, Color("d9531e"))
	tap_button.custom_minimum_size = Vector2(0, 150)
	tap_button.pressed.connect(_on_tap)

	for i in GameState.STALLS.size():
		var b := _make_button(list, "", 36, STALL_COLORS[i].darkened(0.1))
		b.pressed.connect(func(): GameState.buy_stall(i))
		stall_buttons.append(b)

	prestige_button = _make_button(list, "", 34, Color("8a3fb5"))
	prestige_button.pressed.connect(func():
		_show_modal("Open a new branch?",
			"Your stalls and coins reset, but you keep a permanent income bonus.",
			"Open branch", "Cancel", func(): GameState.prestige()))

	daily_button = _make_button(list, "", 34, Color("2f8f5a"))
	daily_button.pressed.connect(func(): GameState.claim_daily(1.0))
	daily_ad_button = _make_button(list, "", 34, Color("2a7fb5"))
	daily_ad_button.pressed.connect(func(): AdService.show_rewarded("daily3"))

	var ads := HBoxContainer.new()
	ads.add_theme_constant_override("separation", 12)
	root.add_child(ads)
	var boost_btn := _make_button(ads, "Watch ad:\n2x income 30 min", 32, Color("2a7fb5"))
	boost_btn.pressed.connect(func(): AdService.show_rewarded("boost"))
	var chest_btn := _make_button(ads, "Watch ad:\nFree chest", 32, Color("2a7fb5"))
	chest_btn.pressed.connect(func(): AdService.show_rewarded("chest"))

	_build_modal()

func _build_modal() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	modal_dim = ColorRect.new()
	modal_dim.color = Color(0, 0, 0, 0.65)
	modal_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	modal_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	modal_dim.visible = false
	layer.add_child(modal_dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	modal_dim.add_child(center)
	var pc := PanelContainer.new()
	pc.custom_minimum_size = Vector2(900, 0)
	pc.add_theme_stylebox_override("panel", _box(Color("3a2e24"), 28))
	center.add_child(pc)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 24)
	pc.add_child(vb)
	modal_title = _make_label(vb, 56)
	modal_body = _make_label(vb, 40)
	modal_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	vb.add_child(row)
	modal_cancel = _make_button(row, "Cancel", 38, Color("6a6058"))
	modal_ok = _make_button(row, "OK", 38, Color("d9531e"))
	modal_cancel.pressed.connect(func(): modal_dim.visible = false)
	modal_ok.pressed.connect(func():
		modal_dim.visible = false
		if _modal_cb.is_valid():
			_modal_cb.call())

func _show_modal(title: String, body: String, ok_text: String, cancel_text: String, cb: Callable) -> void:
	modal_title.text = title
	modal_body.text = body
	modal_ok.text = ok_text
	modal_cancel.text = cancel_text
	modal_cancel.visible = cancel_text != ""
	_modal_cb = cb
	modal_dim.visible = true

func _make_label(parent: Control, size: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(l)
	return l

func _make_button(parent: Control, text: String, size: int, base: Color) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 120)
	b.add_theme_font_size_override("font_size", size)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_button(b, base)
	parent.add_child(b)
	return b

func _on_tap() -> void:
	GameState.tap()
	_bounce = 1.0
	Input.vibrate_handheld(15)

func _show_offline_popup() -> void:
	_show_modal("Welcome back!",
		"You earned %s while away.\nWatch an ad to double it?" % GameState.format_num(GameState.offline_gain),
		"Watch ad (x2)", "No thanks", func(): AdService.show_rewarded("offline"))

func _fmt_time(sec: int) -> String:
	return "%d:%02d" % [floori(sec / 60.0), sec % 60]

func _refresh() -> void:
	coin_label.text = GameState.format_num(GameState.coins) + " coins"
	rate_label.text = GameState.format_num(GameState.income_per_sec()) + " / sec"

	var parts: Array = []
	var left := GameState.boost_until - GameState.now()
	if left > 0:
		parts.append("2x boost %s" % _fmt_time(left))
	if GameState.prestige_points > 0:
		parts.append("Branch bonus x%.1f" % GameState.prestige_multiplier())
	status_label.text = "   |   ".join(parts)

	tap_button.text = "COOK!  +%s\nUpgrade tap: %s" % [
		GameState.format_num(GameState.tap_value()), GameState.format_num(GameState.tap_cost())]
	for i in GameState.STALLS.size():
		var s = GameState.STALLS[i]
		var cost := GameState.upgrade_cost(i)
		stall_buttons[i].text = "%s   Lv %d   -   %s" % [s.name, GameState.levels[i], GameState.format_num(cost)]
		stall_buttons[i].disabled = GameState.coins < cost
		stall_nodes[i].visible = GameState.levels[i] > 0

	var gain := GameState.prestige_gain()
	prestige_button.visible = gain > 0
	prestige_button.text = "Open new branch: +%d bonus (%.0f%% income each)" % [gain, GameState.PRESTIGE_BONUS_EACH * 100.0]

	if GameState.daily_ready():
		daily_button.visible = true
		daily_button.disabled = false
		daily_ad_button.visible = true
		daily_button.text = "Claim daily reward: %s" % GameState.format_num(GameState.daily_amount())
		daily_ad_button.text = "Watch ad: claim daily x3 (%s)" % GameState.format_num(GameState.daily_amount() * 3.0)
	else:
		daily_button.visible = true
		daily_ad_button.visible = false
		daily_button.disabled = true
		var d := GameState.daily_seconds_left()
		daily_button.text = "Next daily reward in %d:%02d" % [floori(d / 3600.0), floori((d % 3600) / 60.0)]

func _process(delta: float) -> void:
	_update_customers(delta)
	_ui_timer += delta
	if _ui_timer >= 0.1:
		_ui_timer = 0.0
		_refresh()
	if _bounce > 0.0:
		_bounce = maxf(0.0, _bounce - delta * 4.0)
		for s in stall_nodes:
			s.scale = Vector3.ONE * (1.0 + 0.06 * _bounce)
