extends Node
# All player input: keyboard + mouse, gamepad, and multi-touch on phones.
# main.gd reads the state below every frame; this script never moves the player itself.
#
# Touch notes (Godot 4.3 web export):
# - InputEventScreenDrag.relative / screen_relative are NOT reliable with two fingers down:
#   the web platform stores the "previous position" per slot of the browser's changedTouches
#   list instead of per finger, so with one thumb on the stick and one aiming the deltas mix
#   up and the camera jumps. We therefore track every finger's last position ourselves.
# - Positions are in viewport pixels; dividing by the viewport width turns a drag into a
#   fraction of the screen width, so sensitivity is the same on every screen size and
#   device pixel ratio.
# - Browsers only allow fullscreen from touchEND (not touchstart), so FULL acts on release.

signal dash            # dash requested
signal reload          # reload requested
signal toggle_view     # first/third person
signal start_pressed   # tap / click / Enter while the game is not running (title or game over)

# Touch look: radians per full screen-width swipe at medium swipe speed, by SENS level 1..5.
const SENS := [0.0, 1.1, 1.8, 2.6, 3.5, 4.6]
const DEFAULT_SENS := 4
const LOOK_SLOW_GAIN := 0.75   # multiplier for slow, careful drags (precise aiming)
const LOOK_FAST_GAIN := 1.5    # multiplier for fast flicks (turning around)
const LOOK_SLOW_SPEED := 0.12  # swipe speed in screen widths per second: at/below = slow gain
const LOOK_FAST_SPEED := 1.3   # at/above = fast gain
const LOOK_SPEED_TAU := 0.06   # seconds; smooths the speed estimate only, never the motion
const PITCH_SCALE := 0.75      # vertical look is a bit slower than horizontal
const LOOK_SLOP := 2.0         # viewport px a finger must travel before it starts turning
const FIRE_SLOP := 6.0         # same for the finger on FIRE, so tapping FIRE does not nudge aim

const STICK_DEAD := 0.12       # fraction of the stick radius that does nothing
const STICK_FULL := 0.9        # fraction of the radius that already gives full speed
const STICK_CURVE := 1.4       # >1 = finer control at low speeds

const BUTTON_GROW := 8.0       # viewport px added around buttons for hit-testing
const SLIDE_OFF := 22.0        # sliding this far outside a held button lets go of it
const JUMP_BUFFER := 0.12      # seconds a jump tap is remembered (so quick taps never get lost)
const RESTART_GUARD := 0.6     # seconds after dying during which taps do not restart

const MOUSE_SENS := 0.0016     # radians per mouse count (CSS pixel on web) at DEFAULT_SENS
const PAD_DEAD := 0.2
const PAD_LOOK_SPEED := 3.2    # radians per second at full right-stick deflection, DEFAULT_SENS
const SETTINGS_PATH := "user://controls.cfg"

enum { ROLE_NONE, ROLE_STICK, ROLE_LOOK, ROLE_BUTTON }

class Touch:
	var role := ROLE_NONE
	var button := ""
	var pos := Vector2.ZERO   # last known position (viewport px)
	var slop := 0.0           # distance still to travel before this finger turns the camera

var hud  # hud.gd instance
var game_active := false  # set by main: true while playing (started and not dead)
var touch_mode := false

var move := Vector2.ZERO   # x = strafe right, y = backwards (so forward is y = -1); length <= 1
var fire := false
var jump := false

var sens_level := DEFAULT_SENS

var _look := Vector2.ZERO       # accumulated yaw/pitch in radians, handed out by take_look()
var _touch_raw := Vector2.ZERO  # touch drag since last frame, in screen widths
var _touch_speed := 0.0         # smoothed swipe speed, screen widths per second
var _touches := {}              # finger index -> Touch
var _stick_id := -1
var _stick_origin := Vector2.ZERO
var _stick := Vector2.ZERO
var _fire_held := 0             # fingers on FIRE
var _jump_held := 0             # fingers on JUMP
var _fire_latch := false        # a fire press happened since the last frame
var _jump_buf := 0.0
var _mouse_fire := false
var _mouse_scale := 1.0         # mouse counts -> CSS pixels (web reports them times devicePixelRatio)
var _view_w := 640.0
var _last_touch_ms := -100000
var _was_active := false
var _start_block := 0.0
var _pad := -1                  # gamepad in use (-1 until one sends input)
var _pad_fire := false
var _pad_jump := false

func _init() -> void:
	process_priority = -100  # run before main.gd so it reads this frame's input, not last frame's

func setup(hud_node) -> void:

	hud = hud_node
	_load_settings()
	touch_mode = DisplayServer.is_touchscreen_available()
	hud.set_touch_mode(touch_mode)
	hud.set_sens(sens_level)
	get_viewport().size_changed.connect(_measure)
	_measure()

func _measure() -> void:
	_view_w = maxf(get_viewport().get_visible_rect().size.x, 1.0)
	_mouse_scale = 1.0 / maxf(DisplayServer.screen_get_scale(), 0.1) if OS.has_feature("web") else 1.0

# Yaw (x) and pitch (y) change in radians since the last call. Positive x = turn right,
# positive y = look down.
func take_look() -> Vector2:
	var l := _look
	_look = Vector2.ZERO
	return l

func toggle_fullscreen() -> void:
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)

func set_sens_level(level: int) -> void:
	sens_level = clampi(level, 1, SENS.size() - 1)
	hud.set_sens(sens_level)
	_save_settings()

# ---------------- per frame ----------------

func _process(dt: float) -> void:
	if _was_active and not game_active:
		# just died: let go of everything and ignore the taps that were meant for zombies
		_release_all()
		_start_block = RESTART_GUARD
	_was_active = game_active
	_start_block = maxf(_start_block - dt, 0.0)

	var m := _stick
	if Input.is_physical_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP): m.y -= 1
	if Input.is_physical_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN): m.y += 1
	if Input.is_physical_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT): m.x -= 1
	if Input.is_physical_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT): m.x += 1
	var pad_fire := false
	if _pad >= 0:
		m += _pad_stick(JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y)
		var r := _pad_stick(JOY_AXIS_RIGHT_X, JOY_AXIS_RIGHT_Y)
		if game_active and r != Vector2.ZERO:
			# squared response: gentle near the centre, fast at the rim
			_look += Vector2(r.x, r.y * PITCH_SCALE) * (r.length() * PAD_LOOK_SPEED * _sens_ratio() * dt)
		pad_fire = _pad_fire or Input.get_joy_axis(_pad, JOY_AXIS_TRIGGER_RIGHT) > 0.5
	move = m.limit_length(1.0)

	if _mouse_fire and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		_mouse_fire = false
	fire = _fire_held > 0 or _mouse_fire or _fire_latch or pad_fire
	_fire_latch = false
	jump = _jump_held > 0 or _jump_buf > 0.0 or _pad_jump or Input.is_key_pressed(KEY_SPACE)
	_jump_buf = maxf(_jump_buf - dt, 0.0)

	# Touch look: slow drags turn less per centimetre (precise aim), fast flicks turn more.
	# Only the speed estimate is smoothed; the finger's movement is applied in full, at once.
	if _touch_raw != Vector2.ZERO or _touch_speed > 0.001:
		var inst := _touch_raw.length() / maxf(dt, 0.001)
		_touch_speed = lerpf(_touch_speed, inst, 1.0 - exp(-dt / LOOK_SPEED_TAU))
		var gain: float = SENS[sens_level] * lerpf(LOOK_SLOW_GAIN, LOOK_FAST_GAIN,
			smoothstep(LOOK_SLOW_SPEED, LOOK_FAST_SPEED, _touch_speed))
		_look += Vector2(_touch_raw.x, _touch_raw.y * PITCH_SCALE) * gain
		_touch_raw = Vector2.ZERO

func _sens_ratio() -> float:
	return SENS[sens_level] / SENS[DEFAULT_SENS]

func _pad_stick(ax: int, ay: int) -> Vector2:
	var v := Vector2(Input.get_joy_axis(_pad, ax), Input.get_joy_axis(_pad, ay))
	var l := v.length()
	if l <= PAD_DEAD:
		return Vector2.ZERO
	return v / l * minf((l - PAD_DEAD) / (1.0 - PAD_DEAD), 1.0)

# ---------------- events ----------------

func _notification(what: int) -> void:
	# Losing focus (app switch, notification shade, browser UI) can swallow the touch-up
	# events, so drop every finger and button rather than risk a stuck stick or trigger.
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT \
			or what == NOTIFICATION_APPLICATION_PAUSED:
		if hud:
			_release_all()

func _input(ev: InputEvent) -> void:
	if ev is InputEventScreenTouch:
		_last_touch_ms = Time.get_ticks_msec()
		if not touch_mode:
			_set_touch_mode(true)
		if ev.pressed:
			_touch_down(ev.index, ev.position)
		else:
			_touch_up(ev.index, not ev.canceled)
	elif ev is InputEventScreenDrag:
		_touch_drag(ev.index, ev.position)
	elif ev is InputEventMouseMotion:
		if game_active and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			# screen_relative is not affected by the viewport stretch (Godot docs' advice for aiming)
			_look += ev.screen_relative * (MOUSE_SENS * _mouse_scale * _sens_ratio())
	elif ev is InputEventMouseButton:
		_mouse_button(ev)
	elif ev is InputEventKey:
		if ev.pressed and not ev.echo:
			_key_down(ev.keycode)
	elif ev is InputEventJoypadButton:
		_pad = ev.device
		_pad_button(ev.button_index, ev.pressed)
	elif ev is InputEventJoypadMotion:
		if absf(ev.axis_value) > 0.5:
			_pad = ev.device

func _try_start() -> void:
	if not game_active and _start_block <= 0.0:
		start_pressed.emit()

func _set_touch_mode(on: bool) -> void:
	touch_mode = on
	if not on:
		_release_all()
	hud.set_touch_mode(on)

# ---------------- touch ----------------

func _hit(name: String, p: Vector2) -> bool:
	return hud.button_active(name) and hud.button_rect(name).grow(BUTTON_GROW).has_point(p)

# The button under p; where grown hit areas overlap, the one whose centre is nearest wins.
func _button_at(p: Vector2) -> String:
	var best := ""
	var best_d := INF
	for n in hud.BUTTON_NAMES:
		if _hit(n, p):
			var d: float = hud.button_rect(n).get_center().distance_squared_to(p)
			if d < best_d:
				best_d = d
				best = n
	return best

func _touch_down(index: int, p: Vector2) -> void:
	if _touches.has(index):
		_touch_up(index, false)  # we missed its release; never keep a ghost finger
	_measure()
	var t := Touch.new()
	t.pos = p
	t.slop = LOOK_SLOP
	var b := _button_at(p)
	if b == "full":
		t.role = ROLE_BUTTON
		t.button = b
		hud.set_button_down(b, true)
	elif not game_active:
		_try_start()
	elif b != "":
		t.role = ROLE_BUTTON
		t.button = b
		hud.set_button_down(b, true)
		match b:
			"fire":
				_fire_held += 1
				_fire_latch = true
				t.slop = FIRE_SLOP
			"jump":
				_jump_held += 1
				_jump_buf = JUMP_BUFFER
			"dash": dash.emit()
			"reload": reload.emit()
			"view": toggle_view.emit()
			"sens": set_sens_level(sens_level % (SENS.size() - 1) + 1)
	elif _stick_id == -1 and hud.stick_zone().has_point(p):
		t.role = ROLE_STICK
		_stick_id = index
		_stick_origin = p
		_stick = Vector2.ZERO
		hud.set_stick(true, p, Vector2.ZERO)
	else:
		t.role = ROLE_LOOK
	_touches[index] = t

func _touch_drag(index: int, p: Vector2) -> void:
	var t: Touch = _touches.get(index)
	if t == null:
		return
	var d := p - t.pos  # our own per-finger delta; see the note at the top of the file
	t.pos = p
	match t.role:
		ROLE_STICK:
			_update_stick(p)
		ROLE_LOOK:
			_add_look(t, d)
		ROLE_BUTTON:
			if t.button == "fire":
				_add_look(t, d)  # hold FIRE and drag to aim; it keeps firing wherever the thumb goes
			elif not hud.button_rect(t.button).grow(SLIDE_OFF).has_point(p):
				_release_button(t)

func _touch_up(index: int, act: bool) -> void:
	var t: Touch = _touches.get(index)
	if t == null:
		return
	_touches.erase(index)
	if t.role == ROLE_STICK:
		_release_stick()
	elif t.role == ROLE_BUTTON:
		var b := t.button
		_release_button(t)
		if b == "full" and act and _hit(b, t.pos):
			toggle_fullscreen()

func _add_look(t: Touch, d: Vector2) -> void:
	if not game_active:
		return
	if t.slop > 0.0:
		# swallow only the first few pixels of travel, not the whole event
		var l := d.length()
		if l <= t.slop:
			t.slop -= l
			return
		d *= (l - t.slop) / l
		t.slop = 0.0
	_touch_raw += d / _view_w

func _update_stick(p: Vector2) -> void:
	var r: float = maxf(hud.stick_radius(), 1.0)
	var off := p - _stick_origin
	var l := off.length()
	if l > r:
		# the base follows the thumb, so reversing direction never needs a long way back
		_stick_origin += off * ((l - r) / l)
		off *= r / l
		l = r
	var a := clampf((l / r - STICK_DEAD) / (STICK_FULL - STICK_DEAD), 0.0, 1.0)
	_stick = off / l * pow(a, STICK_CURVE) if a > 0.0 else Vector2.ZERO
	hud.set_stick(true, _stick_origin, off)

func _release_stick() -> void:
	_stick_id = -1
	_stick = Vector2.ZERO
	hud.set_stick(false, Vector2.ZERO, Vector2.ZERO)

func _release_button(t: Touch) -> void:
	match t.button:
		"fire": _fire_held = maxi(_fire_held - 1, 0)
		"jump": _jump_held = maxi(_jump_held - 1, 0)
	hud.set_button_down(t.button, false)
	t.role = ROLE_NONE
	t.button = ""

func _release_all() -> void:
	for t: Touch in _touches.values():
		if t.role == ROLE_BUTTON:
			hud.set_button_down(t.button, false)
	_touches.clear()
	_release_stick()
	_fire_held = 0
	_jump_held = 0
	_fire_latch = false
	_jump_buf = 0.0
	_mouse_fire = false
	_pad_fire = false
	_pad_jump = false
	_touch_raw = Vector2.ZERO
	_touch_speed = 0.0

# ---------------- mouse, keyboard, gamepad ----------------

func _mouse_button(ev: InputEventMouseButton) -> void:
	if ev.button_index != MOUSE_BUTTON_LEFT:
		return
	if not ev.pressed:
		_mouse_fire = false
		return
	if Time.get_ticks_msec() - _last_touch_ms < 700:
		return  # a mouse click the browser made up after a touch
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		if _hit("full", ev.position):
			toggle_fullscreen()
			return
		# This click only grabs the pointer (and starts the game); it does not shoot.
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_try_start()
	elif game_active:
		_mouse_fire = true
		_fire_latch = true
	else:
		_try_start()

func _key_down(key: int) -> void:
	if touch_mode:
		_set_touch_mode(false)  # a real keyboard: hide the touch buttons until the next touch
	match key:
		KEY_ESCAPE: Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		KEY_V: toggle_view.emit()
		KEY_R: reload.emit()
		KEY_F: toggle_fullscreen()
		KEY_SHIFT: dash.emit()
		KEY_SPACE:
			_jump_buf = JUMP_BUFFER
			_try_start()
		KEY_ENTER, KEY_KP_ENTER: _try_start()
		KEY_BRACKETLEFT, KEY_MINUS: _nudge_sens(-1)
		KEY_BRACKETRIGHT, KEY_EQUAL: _nudge_sens(1)

func _nudge_sens(by: int) -> void:
	set_sens_level(sens_level + by)
	hud.show_message("SENS %d" % sens_level, 1.0)

func _pad_button(button: int, pressed: bool) -> void:
	match button:
		JOY_BUTTON_A: _pad_jump = pressed
		JOY_BUTTON_RIGHT_SHOULDER: _pad_fire = pressed
	if not pressed:
		return
	match button:
		JOY_BUTTON_A:
			_jump_buf = JUMP_BUFFER
			_try_start()
		JOY_BUTTON_RIGHT_SHOULDER: _fire_latch = game_active
		JOY_BUTTON_B, JOY_BUTTON_LEFT_SHOULDER, JOY_BUTTON_LEFT_STICK: dash.emit()
		JOY_BUTTON_X: reload.emit()
		JOY_BUTTON_Y: toggle_view.emit()
		JOY_BUTTON_START: _try_start()
		JOY_BUTTON_DPAD_LEFT: _nudge_sens(-1)
		JOY_BUTTON_DPAD_RIGHT: _nudge_sens(1)

# ---------------- settings ----------------

func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		var v = cfg.get_value("controls", "sens", DEFAULT_SENS)
		if v is int or v is float:
			sens_level = clampi(int(v), 1, SENS.size() - 1)

func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("controls", "sens", sens_level)
	cfg.save(SETTINGS_PATH)  # may fail (e.g. private browsing); then the level just isn't remembered
