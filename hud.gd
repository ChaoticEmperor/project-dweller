extends CanvasLayer
# All 2D UI: stats, crosshair, messages, and the VISUALS of the touch controls.
# Input handling lives in controls.gd, which asks this script where the buttons are.
# The game renders at a low resolution (about 640x360, wider on wide screens) and is
# scaled up with nearest-neighbour filtering, so everything here is in those small pixels.

const BUTTON_NAMES := ["fire", "jump", "dash", "reload", "view", "sens", "full"]

var touch_mode := false
var stats: Label
var cross: Label
var center: Label
var touch_ui: Control
var stick_base: ColorRect
var stick_knob: ColorRect
var buttons := {}  # name -> ColorRect
var msg_t := 0.0

func _label(parent: Node, txt: String, size: int) -> Label:
	var l := Label.new()
	l.text = txt
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 4)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l

func _btn(parent: Node, txt: String, sz: Vector2) -> ColorRect:
	var r := ColorRect.new()
	r.color = Color(1, 1, 1, 0.18)
	r.size = sz
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(r)
	var l := _label(r, txt, 14)
	l.size = sz
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return r

# Called once.
func build() -> void:
	stats = _label(self, "", 14)
	stats.position = Vector2(8, 6)
	cross = _label(self, "+", 18)
	center = _label(self, "", 24)
	center.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	buttons["full"] = _btn(self, "FULL", Vector2(52, 26))
	touch_ui = Control.new()
	touch_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(touch_ui)
	stick_base = ColorRect.new()
	stick_base.color = Color(1, 1, 1, 0.12)
	stick_base.size = Vector2(110, 110)
	stick_base.mouse_filter = Control.MOUSE_FILTER_IGNORE
	touch_ui.add_child(stick_base)
	stick_knob = ColorRect.new()
	stick_knob.color = Color(1, 1, 1, 0.35)
	stick_knob.size = Vector2(44, 44)
	stick_knob.mouse_filter = Control.MOUSE_FILTER_IGNORE
	touch_ui.add_child(stick_knob)
	buttons["fire"] = _btn(touch_ui, "FIRE", Vector2(84, 84))
	buttons["fire"].color = Color(1, 0.3, 0.2, 0.3)
	buttons["jump"] = _btn(touch_ui, "JUMP", Vector2(60, 46))
	buttons["dash"] = _btn(touch_ui, "DASH", Vector2(60, 46))
	buttons["reload"] = _btn(touch_ui, "RELOAD", Vector2(64, 30))
	buttons["view"] = _btn(touch_ui, "VIEW", Vector2(52, 26))
	buttons["sens"] = _btn(touch_ui, "SENS 2", Vector2(64, 26))
	get_viewport().size_changed.connect(_layout)
	_layout()

func _layout() -> void:
	var vs := get_viewport().get_visible_rect().size
	cross.position = vs / 2 - Vector2(5, 12)
	center.size = Vector2(vs.x, 100)
	center.position = Vector2(0, vs.y * 0.25)
	buttons["full"].position = Vector2(vs.x - 60, 6)
	buttons["view"].position = Vector2(vs.x - 120, 6)
	buttons["sens"].position = Vector2(vs.x - 192, 6)
	stick_base.position = Vector2(30, vs.y - 140)
	set_stick(false, Vector2.ZERO, Vector2.ZERO)
	buttons["fire"].position = Vector2(vs.x - 110, vs.y - 120)
	buttons["jump"].position = Vector2(vs.x - 180, vs.y - 70)
	buttons["dash"].position = Vector2(vs.x - 180, vs.y - 130)
	buttons["reload"].position = Vector2(vs.x - 100, vs.y - 165)
	touch_ui.visible = touch_mode

func _process(dt: float) -> void:
	if msg_t > 0:
		msg_t -= dt
		if msg_t <= 0:
			center.text = ""

# ---- interface used by controls.gd ----

func set_touch_mode(on: bool) -> void:
	touch_mode = on
	_layout()

# Screen rectangle (viewport coordinates) of a button; see BUTTON_NAMES.
func button_rect(name: String) -> Rect2:
	var b: Control = buttons[name]
	return Rect2(b.global_position, b.size)

# Is the button currently usable? (touch-only buttons are hidden on desktop)
func button_active(name: String) -> bool:
	return name == "full" or touch_mode

# Touches that start inside this rectangle drive the movement joystick.
func stick_zone() -> Rect2:
	var vs := get_viewport().get_visible_rect().size
	return Rect2(0, vs.y * 0.25, vs.x * 0.45, vs.y * 0.75)

# Joystick visuals. `origin` is where the thumb went down, `offset` the current
# displacement from it (already limited to stick_radius()).
func set_stick(active: bool, _origin: Vector2, offset: Vector2) -> void:
	var c := stick_base.position + stick_base.size / 2
	stick_knob.position = c - stick_knob.size / 2 + (offset if active else Vector2.ZERO)

func stick_radius() -> float:
	return 50.0

func set_button_down(name: String, down: bool) -> void:
	buttons[name].modulate = Color(1.6, 1.6, 1.6) if down else Color.WHITE

func set_sens(level: int) -> void:
	buttons["sens"].get_child(0).text = "SENS %d" % level

# ---- interface used by main.gd ----

# d has: hp, ammo, max_ammo, reloading (bool), score, wave, combo, hurt (0..1), dash_ready (0..1)
func update_stats(d: Dictionary) -> void:
	stats.text = "HP %d   AMMO %d/%d%s\nSCORE %d   WAVE %d%s%s" % [
		int(d.hp), d.ammo, d.max_ammo, "  RELOADING" if d.reloading else "", d.score, d.wave,
		("   COMBO x%d!" % d.combo) if d.combo > 1 else "",
		"" if touch_mode else "\n[V] view  [Shift] dash  [R] reload  [F] fullscreen"]
	stats.add_theme_color_override("font_color", Color(1, 0.3, 0.3) if d.hurt > 0 else Color.WHITE)

# Big centred message. duration 0 = stays until replaced/cleared.
func show_message(text: String, duration := 0.0) -> void:
	center.text = text
	msg_t = duration

func clear_message() -> void:
	center.text = ""
	msg_t = 0.0

# Title / game-over screens. `tap_word` is "Tap" or "Click"/"[Enter]".
func show_title() -> void:
	show_message("ZOMBIE BONK\n%s to start" % ("Tap" if touch_mode else "Click"))

func show_game_over(score: int, wave: int) -> void:
	show_message("YOU GOT BONKED!\nScore %d  -  Wave %d\n%s to try again" % [score, wave, "Tap" if touch_mode else "[Enter]"])

func on_hit(_headshot: bool) -> void:  # a pellet hit a zombie
	pass

func on_kill(_points: int, _headshot: bool) -> void:
	pass

func on_wave(wave: int) -> void:
	show_message("WAVE %d" % wave, 2.0)
