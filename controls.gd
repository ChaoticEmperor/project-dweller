extends Node
# All player input: keyboard + mouse on desktop, multi-touch on phones.
# main.gd reads the state below every frame; this script never moves the player itself.

signal dash            # dash requested
signal reload          # reload requested
signal toggle_view     # first/third person
signal start_pressed   # tap / click / Enter while the game is not running (title or game over)

const SENS := [0.0, 1.2, 1.8, 2.5, 3.3, 4.2]  # radians per full screen-width swipe, by level
const MOUSE_SENS := 0.003

var hud  # hud.gd instance
var game_active := false  # set by main: true while playing (started and not dead)
var touch_mode := false

var move := Vector2.ZERO   # x = strafe right, y = backwards (so forward is y = -1); length <= 1
var fire := false
var jump := false

var sens_level := 2
var _look := Vector2.ZERO  # accumulated yaw/pitch in radians
var _stick_id := -1
var _stick_origin := Vector2.ZERO
var _stick := Vector2.ZERO
var _look_id := -1
var _held := {}  # button name -> touch index

func setup(hud_node) -> void:
	hud = hud_node
	touch_mode = DisplayServer.is_touchscreen_available()
	hud.set_touch_mode(touch_mode)
	hud.set_sens(sens_level)

# Yaw (x) and pitch (y) change in radians since the last call. Positive x = turn right.
func take_look() -> Vector2:
	var l := _look
	_look = Vector2.ZERO
	return l

func _process(_dt: float) -> void:
	var k := Vector2.ZERO
	if Input.is_key_pressed(KEY_W): k.y -= 1
	if Input.is_key_pressed(KEY_S): k.y += 1
	if Input.is_key_pressed(KEY_A): k.x -= 1
	if Input.is_key_pressed(KEY_D): k.x += 1
	move = (k + _stick).limit_length(1.0)
	var mouse_fire := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	fire = mouse_fire or _held.has("fire")
	jump = Input.is_key_pressed(KEY_SPACE) or _held.has("jump")

func toggle_fullscreen() -> void:
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)

func _hit(name: String, p: Vector2) -> bool:
	return hud.button_active(name) and hud.button_rect(name).grow(8).has_point(p)

func _release_stick() -> void:
	_stick_id = -1
	_stick = Vector2.ZERO
	hud.set_stick(false, Vector2.ZERO, Vector2.ZERO)

func _input(ev: InputEvent) -> void:
	if ev is InputEventScreenTouch:
		if not touch_mode:
			touch_mode = true
			hud.set_touch_mode(true)
		var p: Vector2 = ev.position
		if ev.pressed:
			if _hit("full", p):
				toggle_fullscreen()
				return
			if not game_active:
				start_pressed.emit()
				return
			for n in hud.BUTTON_NAMES:
				if n != "full" and _hit(n, p):
					_held[n] = ev.index
					hud.set_button_down(n, true)
					match n:
						"dash": dash.emit()
						"reload": reload.emit()
						"view": toggle_view.emit()
						"sens":
							sens_level = sens_level % 5 + 1
							hud.set_sens(sens_level)
						"fire":
							if _look_id == -1:
								_look_id = ev.index  # aim while holding FIRE
					return
			if hud.stick_zone().has_point(p) and _stick_id == -1:
				_stick_id = ev.index
				_stick_origin = p
				hud.set_stick(true, p, Vector2.ZERO)
			elif _look_id == -1:
				_look_id = ev.index
		else:
			if ev.index == _stick_id:
				_release_stick()
			if ev.index == _look_id:
				_look_id = -1
			for n in _held.keys():
				if _held[n] == ev.index:
					_held.erase(n)
					hud.set_button_down(n, false)
	elif ev is InputEventScreenDrag:
		if ev.index == _stick_id:
			var r: float = hud.stick_radius()
			var off: Vector2 = (ev.position - _stick_origin).limit_length(r)
			var mag: float = off.length() / r
			# dead zone, then ramp up smoothly so small thumb wobble is ignored
			_stick = off.normalized() * clamp((mag - 0.15) / 0.85, 0.0, 1.0) if mag > 0.15 else Vector2.ZERO
			hud.set_stick(true, _stick_origin, off)
		elif ev.index == _look_id and game_active:
			# screen_relative ignores stretch scaling (Godot docs' advice for touch aiming);
			# dividing by window width makes a swipe turn the same angle on every phone.
			var d: Vector2 = ev.screen_relative / float(max(DisplayServer.window_get_size().x, 1))
			_look += Vector2(d.x, d.y * 0.8) * SENS[sens_level]

func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and game_active:
		_look += ev.relative * MOUSE_SENS
	if ev is InputEventMouseButton and ev.pressed:
		if _hit("full", ev.position) and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			toggle_fullscreen()
			return
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		if not game_active:
			start_pressed.emit()
	if ev is InputEventKey and ev.pressed and not ev.echo:
		match ev.keycode:
			KEY_ESCAPE: Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			KEY_V: toggle_view.emit()
			KEY_R: reload.emit()
			KEY_F: toggle_fullscreen()
			KEY_SHIFT: dash.emit()
			KEY_ENTER:
				if not game_active:
					start_pressed.emit()
