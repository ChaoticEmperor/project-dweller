extends Node
# All sound. Every sound is synthesised in code at start-up into AudioStreamWAV
# buffers (Godot's web export plays those with low latency; live-generated audio
# is not supported in the web's default "Sample" playback mode).
# See SPECS.md for the frozen list of sound names.
#
# Web notes (Godot 4.3 "Sample" playback, checked against the engine source):
# - no bus effects, no generators, so echo/crush/drive are baked into the buffers;
# - a pitch set before play() is not sent to the browser, so it is set again after play();
# - a looping sample is restarted by a browser "ended" event, late and separately for each
#   player, so on the web the two music layers are not looped by the engine: both are
#   re-triggered together from _process every 16 s (the loop starts and ends in silence);
# - every start copies the whole sample inside the browser, so the second layer would start
#   a few ms late: both buffers carry PRE seconds of silent lead-in, and the second layer
#   skips as much of its lead-in as its start call took last time;
# - AudioStreamPlayer has no pan, so play_at only gets quieter with distance.

const SR := 22050        # sound effects, mono 16-bit
const MSR := 11025       # music, mono 16-bit (lo-fi on purpose)
const MUSIC_SECONDS := 16.0   # 8 bars of 4/4 at 120 bpm; a 16th note is 0.125 s
const PRE := 0.03         # silent lead-in baked into both music layers (see the web notes)
const POOL := 14
const MUSIC_DB := -9.0
const SFX_DB := -3.0      # headroom so a shot, a bonk and the music can overlap without clipping
const SIN := 0
const SQR := 1
const SAW := 2
const TRI := 3

# name: [peak level 0..1, cooldown ms, random pitch spread, priority (may steal a voice)]
const CONF := {
	"shoot": [0.97, 60, 0.0, 1],
	"pump": [0.5, 80, 0.03, 0],
	"reload": [0.5, 100, 0.03, 0],
	"empty": [0.4, 120, 0.02, 0],
	"dash": [0.5, 100, 0.04, 0],
	"jump": [0.4, 80, 0.03, 0],
	"land": [0.45, 100, 0.05, 0],
	"hurt": [0.8, 150, 0.05, 1],
	"death_player": [0.8, 500, 0.0, 1],
	"hit": [0.55, 45, 0.0, 0],
	"headshot": [0.85, 45, 0.0, 1],
	"kill": [0.5, 50, 0.0, 1],
	"shove": [0.7, 100, 0.04, 0],
	"wave_start": [0.7, 500, 0.0, 1],
	"wave_clear": [0.6, 500, 0.0, 1],
	"upgrade_pick": [0.55, 200, 0.0, 1],
	"ui_click": [0.3, 40, 0.0, 0],
	"zombie_spawn": [0.5, 120, 0.1, 0],
	"zombie_groan": [0.45, 350, 0.12, 0],
	"zombie_windup": [0.5, 120, 0.08, 0],
	"zombie_attack": [0.65, 100, 0.08, 0],
	"bloater_swell": [0.55, 200, 0.05, 0],
	"explode": [0.97, 80, 0.05, 1],
	"boss_step": [0.8, 150, 0.05, 0],
	# weapons
	"shoot_revolver": [0.9, 60, 0.0, 1],
	"shoot_smg": [0.7, 40, 0.04, 1],
	"shoot_bow": [0.7, 80, 0.03, 1],
	"shoot_double": [1.0, 60, 0.0, 1],
	"shoot_launcher": [0.85, 100, 0.03, 1],
	"shoot_pigeon": [0.7, 80, 0.08, 1],
	"hose": [0.5, 150, 0.06, 0],
	"swing": [0.6, 120, 0.05, 0],
	"pan_hit": [0.95, 100, 0.04, 1],
	"reload_mag": [0.5, 100, 0.03, 0],
	"switch": [0.4, 80, 0.04, 0],
	"perfect": [0.6, 100, 0.0, 1],
	"throw": [0.5, 100, 0.05, 0],
	"glass": [0.7, 80, 0.06, 1],
	"pigeon_pop": [0.8, 80, 0.08, 1],
	"frenzy": [0.7, 500, 0.0, 1],
	# drops
	"crate_land": [0.8, 200, 0.04, 1],
	"airdrop": [0.6, 500, 0.0, 1],
	"pickup": [0.6, 150, 0.0, 1],
	"powerup": [0.65, 200, 0.0, 1],
	"heal": [0.55, 200, 0.0, 1],
	"ammo": [0.55, 150, 0.0, 1],
}

# Built once and kept across scene reloads (a restart must not rebuild or re-register samples).
static var _cache := {}

var setup_ms := 0.0          # time the synthesis took (0 when the cache was reused)
var music_ms := 0.0          # time the music took (spread over the frames after setup)
var sample_bytes := 0        # total PCM bytes held

var _streams := {}           # name -> Array of AudioStreamWAV variants
var _last := {}              # name -> [msec of last play, its volume_db]
var _pool: Array[AudioStreamPlayer] = []
var _busy_until := PackedInt64Array()
var _listener: Node3D
var _mus_a: AudioStreamPlayer    # calm layer: bass, kick, theremin
var _mus_b: AudioStreamPlayer    # horde layer: snare, hats, lead
var _music_on := false
var _ready_music := false
var _playing := false
var _web := OS.has_feature("web")
var _loop_at := 0            # usec: when the web build re-triggers the music
var _lag := 0.0              # seconds layer B's start call is expected to take
var _lag_prev := 1.0
var _mus_gain := 0.0
var _int_target := 0.0
var _int := 0.0
var _volume := 1.0
var _muted := false

var _sr := SR                # rate the generators below are writing at
var _nz := PackedFloat32Array()
var _ni := 0
var _tables := {}

func setup() -> void:
	if _cache.is_empty():
		var t0 := Time.get_ticks_usec()
		_build_all()
		_cache["ms"] = (Time.get_ticks_usec() - t0) / 1000.0
		setup_ms = _cache["ms"]
	_streams = _cache["streams"]
	sample_bytes = _cache["bytes"]
	for i in POOL:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_pool.append(p)
	_busy_until.resize(POOL)
	process_mode = Node.PROCESS_MODE_ALWAYS  # music keeps going if the tree is ever paused
	_mus_a = AudioStreamPlayer.new()
	_mus_a.volume_db = -60.0
	add_child(_mus_a)
	_mus_b = AudioStreamPlayer.new()
	_mus_b.volume_db = -60.0
	add_child(_mus_b)
	_apply_master()
	set_process(false)
	if _cache.has("music_b"):
		_music_ready()
	else:
		_build_music()  # carries on over the next few frames; music starts when it is done

func _exit_tree() -> void:
	if _mus_a != null:
		_mus_a.stop()
		_mus_b.stop()

func _music_ready() -> void:
	_mus_a.stream = _cache["music_a"]
	_mus_b.stream = _cache["music_b"]
	sample_bytes = _cache["bytes"]
	music_ms = _cache.get("music_ms", 0.0)
	if _web:  # hand the buffers to the browser now, so both layers can start in the same instant
		for st in [_mus_a.stream, _mus_b.stream]:
			if not AudioServer.is_stream_registered_as_sample(st):
				AudioServer.register_stream_as_sample(st)
	_ready_music = true

# Play a sound by name. Unknown names are ignored silently.
func play(sound: String, pitch := 1.0, volume_db := 0.0) -> void:
	var c = CONF.get(sound)
	if c == null or not _streams.has(sound) or not is_inside_tree():
		return
	var now := Time.get_ticks_msec()
	var last = _last.get(sound)
	if last != null and now - last[0] < c[1] and volume_db < last[1] + 6.0:
		return  # same sound just played (a pellet volley, a crowd): one is enough
	var slot := -1
	var free_n := 0
	var oldest := 0
	for i in POOL:
		if _busy_until[i] <= now:
			free_n += 1
			if slot < 0:
				slot = i
		if _busy_until[i] < _busy_until[oldest]:
			oldest = i
	if c[3] == 0:
		if free_n < 3:
			return  # keep the last voices for the sounds that matter
	elif slot < 0:
		slot = oldest
	_last[sound] = [now, volume_db]
	var variants: Array = _streams[sound]
	var st: AudioStreamWAV = variants[randi() % variants.size()]
	var pt: float = clampf(pitch * (1.0 + randf_range(-c[2], c[2])), 0.3, 3.0)
	var p := _pool[slot]
	p.stop()
	p.stream = st
	p.volume_db = volume_db + SFX_DB
	p.pitch_scale = pt
	p.play()
	p.pitch_scale = pt  # web: only a change made while playing reaches the browser
	_busy_until[slot] = now + int(st.get_length() / pt * 1000.0) + 30

# Play a sound that comes from a place in the world (quieter with distance from the listener).
func play_at(sound: String, pos: Vector3, pitch := 1.0) -> void:
	var d := 0.0
	if is_instance_valid(_listener) and _listener.is_inside_tree():
		d = _listener.global_position.distance_to(pos)
	if d > 70.0:
		return
	play(sound, pitch, -24.0 * log(1.0 + d / 7.0) / log(10.0))

# The node sounds are heard from (the camera).
func set_listener(node: Node3D) -> void:
	_listener = node

func set_music(on: bool) -> void:
	_music_on = on
	set_process(true)

# 0 = calm, 1 = full horde; lets the music react to the action.
func set_intensity(k: float) -> void:
	_int_target = clampf(k, 0.0, 1.0)

# Master volume, 0..1.
func set_volume(k: float) -> void:
	_volume = clampf(k, 0.0, 1.0)
	_apply_master()

func get_volume() -> float:
	return _volume

# Flips mute; returns true when now muted.
func toggle_mute() -> bool:
	_muted = not _muted
	_apply_master()
	return _muted

func is_muted() -> bool:
	return _muted

func _apply_master() -> void:
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(_volume, 0.0001)))
	AudioServer.set_bus_mute(0, _muted or _volume <= 0.001)

func _process(dt: float) -> void:
	if _music_on and _ready_music and not _playing:
		_playing = true
		_mus_gain = 0.0
		_int = _int_target
		_apply_music()
		_start_layers()
	elif _web and _playing and Time.get_ticks_usec() >= _loop_at - 8000:
		_start_layers()
	_mus_gain = move_toward(_mus_gain, 1.0 if _music_on else 0.0, dt * (1.2 if _music_on else 2.5))
	_int = move_toward(_int, _int_target, dt * 0.7)
	_apply_music()
	if not _music_on and _mus_gain <= 0.0:
		_mus_a.stop()
		_mus_b.stop()
		_playing = false
		set_process(false)

# Both layers start back to back so they stay in step.
func _start_layers() -> void:
	var now := Time.get_ticks_usec()
	var period := int(MUSIC_SECONDS * 1000000.0)
	_loop_at = _loop_at + period if absi(now - _loop_at) < 60000 else now + period
	_mus_a.stop()
	_mus_b.stop()
	_mus_a.play()
	var t1 := Time.get_ticks_usec()
	_mus_b.play(_lag if _web else 0.0)
	var took := (Time.get_ticks_usec() - t1) / 1000000.0
	_lag = clampf(minf(took, _lag_prev), 0.0, PRE)
	_lag_prev = took

func _apply_music() -> void:
	var a := MUSIC_DB + linear_to_db(maxf(_mus_gain, 0.001))
	var b := a + linear_to_db(maxf(sqrt(_int), 0.001))
	if absf(a - _mus_a.volume_db) > 0.25:
		_mus_a.volume_db = a
	if absf(b - _mus_b.volume_db) > 0.25:
		_mus_b.volume_db = b

# ---------------------------------------------------------------- synthesis

func _build_all() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1977
	_nz.resize(16384)
	for i in 16384:
		_nz[i] = rng.randf() * 2.0 - 1.0
	_cache["bytes"] = 0
	_sr = SR
	var s := {}
	var b: PackedFloat32Array

	# shotgun: crack + noise blast + low thump, driven hard, with a slap-back tail
	b = _buf(0.62)
	_noise(b, 0.0, 0.03, 1.0, 9000, 6000, 1500, 0.0005)
	_noise(b, 0.0, 0.3, 1.0, 7000, 450, 0, 0.001, 4)
	_noise(b, 0.0, 0.5, 0.45, 900, 180, 0, 0.002)
	_tone(b, 0.0, 0.28, 170, 40, SIN, 1.1, 0.001)
	_tone(b, 0.0, 0.12, 96, 48, SQR, 0.35, 0.001)
	_drive(b, 1.6)
	_echo(b, 0.085, 0.28)
	s["shoot"] = [_wav(b, "shoot")]

	b = _buf(0.3)  # chk-chk
	_noise(b, 0.0, 0.06, 0.9, 3500, 1500, 600)
	_tone(b, 0.0, 0.035, 820, 600, SQR, 0.3, 0.001, 2, 0.3)
	_noise(b, 0.13, 0.08, 1.0, 2600, 900, 400)
	_tone(b, 0.13, 0.05, 520, 380, SQR, 0.35, 0.001, 2, 0.3)
	_tone(b, 0.13, 0.07, 150, 90, SIN, 0.5)
	s["pump"] = [_wav(b, "pump")]

	b = _buf(0.42)  # two shells pushed in, then a thunk
	_noise(b, 0.0, 0.05, 0.7, 4000, 2000, 900)
	_tone(b, 0.0, 0.06, 300, 420, TRI, 0.45)
	_noise(b, 0.15, 0.05, 0.7, 4000, 2000, 900)
	_tone(b, 0.15, 0.06, 360, 520, TRI, 0.45)
	_noise(b, 0.3, 0.04, 0.6, 2500, 1000, 300)
	_tone(b, 0.3, 0.1, 200, 110, SIN, 0.6)
	s["reload"] = [_wav(b, "reload")]

	b = _buf(0.09)  # dry click
	_noise(b, 0.0, 0.02, 0.8, 6000, 3000, 2000)
	_tone(b, 0.0, 0.03, 1700, 1500, SQR, 0.3, 0.001, 2, 0.25)
	_tone(b, 0.035, 0.04, 900, 800, SQR, 0.15, 0.001, 2, 0.25)
	s["empty"] = [_wav(b, "empty")]

	b = _buf(0.3)  # whoosh
	_noise(b, 0.0, 0.3, 1.0, 500, 4500, 200, 0.1)
	_tone(b, 0.0, 0.22, 180, 520, SAW, 0.12, 0.06)
	s["dash"] = [_wav(b, "dash")]

	b = _buf(0.2)  # classic rising blip
	_tone(b, 0.0, 0.2, 240, 640, SQR, 0.6, 0.003, 2, 0.25)
	s["jump"] = [_wav(b, "jump")]

	b = _buf(0.16)
	_tone(b, 0.0, 0.14, 130, 48, SIN, 1.0, 0.001)
	_tone(b, 0.0, 0.05, 260, 130, SQR, 0.2, 0.001)
	_noise(b, 0.0, 0.08, 0.7, 1500, 400)
	s["land"] = [_wav(b, "land")]

	b = _buf(0.32)  # crunchy "ow"
	_growl(b, 0.0, 0.3, 330, 210, 120, 1.0, 2500, 700, 38, 0.5, 0.004, 0.1)
	_noise(b, 0.0, 0.06, 0.7, 3000, 800)
	_crush(b, 3, 24.0)
	s["hurt"] = [_wav(b, "hurt")]

	b = _buf(1.55)  # sad trombone: wah wah wah waaah
	var tb := [233.1, 220.0, 207.7, 196.0]
	for i in 4:
		var last := i == 3
		_growl(b, i * 0.3, 0.62 if last else 0.27, tb[i], tb[i], tb[i] * (0.93 if last else 1.0),
				0.9, 450, 1700, 6.5 if last else 0.0, 0.35, 0.03, 0.25 if last else 0.06, false)
	_crush(b, 2, 40.0)
	_echo(b, 0.12, 0.2)
	s["death_player"] = [_wav(b, "death_player")]

	b = _buf(0.13)  # wet smack
	_noise(b, 0.0, 0.11, 1.0, 1800, 300)
	_tone(b, 0.0, 0.09, 340, 110, SIN, 0.7, 0.001)
	_tone(b, 0.02, 0.06, 700, 250, SAW, 0.15)
	s["hit"] = [_wav(b, "hit")]

	b = _buf(0.33)  # hollow cartoon bonk with a little boing after it
	_tone(b, 0.0, 0.11, 620, 260, SIN, 1.0, 0.001)
	_tone(b, 0.0, 0.07, 1240, 700, TRI, 0.35, 0.001, 4)
	_noise(b, 0.0, 0.012, 0.6, 5000, 3000, 1500)
	_tone(b, 0.03, 0.29, 310, 245, SIN, 0.45, 0.005, 2, 0.5, 28.0, 0.06)
	s["headshot"] = [_wav(b, "headshot")]

	b = _buf(0.18)  # two-note coin blip (main raises its pitch with the combo)
	_tone(b, 0.0, 0.058, 660, 660, SQR, 0.6, 0.002, 0)
	_tone(b, 0.055, 0.12, 990, 990, SQR, 0.6, 0.002)
	_tone(b, 0.055, 0.12, 1980, 1980, TRI, 0.2, 0.002, 4)
	s["kill"] = [_wav(b, "kill")]

	b = _buf(0.28)  # swing and thump
	_noise(b, 0.0, 0.2, 1.0, 400, 3000, 150, 0.05)
	_tone(b, 0.04, 0.2, 170, 55, SIN, 0.6, 0.004)
	_tone(b, 0.04, 0.06, 300, 180, SQR, 0.25)
	s["shove"] = [_wav(b, "shove")]

	b = _buf(1.3)  # dun dun DUNNN (the last note is a tritone up)
	var ws := [[0.0, 110.0, 0.17], [0.2, 110.0, 0.17], [0.4, 155.6, 0.75]]
	for w in ws:
		var long: bool = w[2] > 0.5
		_tone(b, w[0], w[2], w[1], w[1], SAW, 0.6, 0.004, 2 if long else 1, 0.5, 6.0, 0.012 if long else 0.0)
		_tone(b, w[0], w[2], w[1] * 2.0, w[1] * 2.0, SQR, 0.25, 0.004, 2, 0.25)
		_noise(b, w[0], 0.08, 0.5, 1200, 300)
	_crush(b, 2, 48.0)
	_echo(b, 0.13, 0.3)
	s["wave_start"] = [_wav(b, "wave_start")]

	b = _buf(1.0)  # happy major arpeggio
	var wc := [523.3, 659.3, 784.0, 1046.5]
	for i in 4:
		var d := 0.45 if i == 3 else 0.1
		_tone(b, i * 0.08, d, wc[i], wc[i], SQR, 0.5, 0.003)
		_tone(b, i * 0.08, d, wc[i] * 2.0, wc[i] * 2.0, TRI, 0.2, 0.003)
	_echo(b, 0.11, 0.3)
	s["wave_clear"] = [_wav(b, "wave_clear")]

	b = _buf(0.7)  # power-up run with a shimmer on top
	var up := [0, 4, 7, 12, 16, 19, 24, 28]
	for i in 8:
		var f := 440.0 * pow(2.0, up[i] / 12.0)
		_tone(b, i * 0.045, 0.06, f, f, SQR, 0.5, 0.002, 1, 0.25)
	_tone(b, 0.36, 0.3, 1760, 1760, TRI, 0.4, 0.003, 2, 0.5, 9.0, 0.01)
	_echo(b, 0.09, 0.25)
	s["upgrade_pick"] = [_wav(b, "upgrade_pick")]

	b = _buf(0.05)
	_tone(b, 0.0, 0.045, 1100, 900, SQR, 0.5, 0.001)
	s["ui_click"] = [_wav(b, "ui_click")]

	b = _buf(0.56)  # dirt and a rising moan
	_noise(b, 0.0, 0.5, 0.8, 300, 900, 0, 0.15)
	_growl(b, 0.05, 0.48, 85, 130, 170, 0.8, 800, 1600, 22, 0.6, 0.1, 0.15)
	s["zombie_spawn"] = [_wav(b, "zombie_spawn")]

	# groans: buzzy voice (saw + sub pulse) through a moving low-pass with a rattle
	var groans := []
	b = _buf(0.8)   # "uuuhh", falling
	_growl(b, 0.0, 0.8, 140, 120, 95, 1.0, 1100, 700, 27, 0.55, 0.08, 0.3)
	_noise(b, 0.0, 0.8, 0.12, 1200, 600, 0, 0.1)
	groans.append(_wav(b, "zombie_groan"))
	b = _buf(0.9)   # "ooaah"
	_growl(b, 0.0, 0.9, 105, 155, 125, 1.0, 800, 1600, 23, 0.6, 0.12, 0.3)
	_noise(b, 0.0, 0.9, 0.12, 1200, 600, 0, 0.1)
	groans.append(_wav(b, "zombie_groan"))
	b = _buf(0.55)  # short grunt
	_growl(b, 0.0, 0.55, 175, 150, 105, 1.0, 1400, 800, 31, 0.5, 0.05, 0.25)
	groans.append(_wav(b, "zombie_groan"))
	b = _buf(1.0)   # "braaains?" with a question mark
	_growl(b, 0.0, 1.0, 125, 130, 185, 1.0, 700, 1500, 19, 0.7, 0.15, 0.25)
	_growl(b, 0.5, 0.5, 188, 196, 278, 0.3, 500, 900, 0, 0.0, 0.2, 0.2, false)
	groans.append(_wav(b, "zombie_groan"))
	s["zombie_groan"] = groans

	b = _buf(0.4)  # rising snarl
	_growl(b, 0.0, 0.4, 110, 170, 270, 1.0, 800, 2200, 30, 0.6, 0.03, 0.05)
	s["zombie_windup"] = [_wav(b, "zombie_windup")]

	b = _buf(0.28)  # swipe, snarl, snap
	_noise(b, 0.0, 0.14, 0.9, 800, 4000, 300, 0.03)
	_growl(b, 0.05, 0.22, 220, 140, 90, 1.0, 1800, 600, 45, 0.5, 0.005, 0.1)
	_noise(b, 0.1, 0.03, 0.7, 5000, 2500, 1500)
	s["zombie_attack"] = [_wav(b, "zombie_attack")]

	b = _buf(1.0)  # balloon being overfilled
	_tone(b, 0.0, 1.0, 110, 420, TRI, 0.7, 0.1, 0, 0.5, 9.0, 0.05)
	_tone(b, 0.0, 1.0, 110, 420, SQR, 0.2, 0.3, 0, 0.15, 9.0, 0.05)
	_noise(b, 0.0, 1.0, 0.3, 800, 5000, 300, 0.9, 0)
	s["bloater_swell"] = [_wav(b, "bloater_swell")]

	b = _buf(1.1)  # big boom with a splat in it
	_noise(b, 0.0, 0.04, 1.0, 10000, 5000, 1000, 0.0005)
	_noise(b, 0.0, 0.7, 1.0, 5000, 150)
	_noise(b, 0.0, 1.0, 0.6, 500, 90, 0, 0.005)
	_tone(b, 0.0, 0.5, 110, 28, SIN, 1.2, 0.001)
	_noise(b, 0.05, 0.25, 0.4, 2500, 700, 200, 0.02)
	_drive(b, 1.8)
	_echo(b, 0.11, 0.35)
	s["explode"] = [_wav(b, "explode")]

	b = _buf(0.42)  # heavy stomp
	_tone(b, 0.0, 0.3, 75, 30, SIN, 1.2, 0.002)
	_tone(b, 0.0, 0.08, 160, 80, SQR, 0.5, 0.001)
	_noise(b, 0.0, 0.15, 0.9, 1200, 200)
	_drive(b, 1.5)
	_echo(b, 0.09, 0.25)
	s["boss_step"] = [_wav(b, "boss_step")]

	_build_weapon_sounds(s)
	_cache["streams"] = s

# The sounds of the found weapons, the gadgets and the drops. Kept short: every sample is
# computed in script at start-up.
func _build_weapon_sounds(s: Dictionary) -> void:
	var b: PackedFloat32Array

	b = _buf(0.36)  # revolver: a dry, hard crack with a ring to it
	_noise(b, 0.0, 0.02, 1.0, 10000, 7000, 2000, 0.0005)
	_noise(b, 0.0, 0.16, 0.9, 6000, 700, 0, 0.001, 4)
	_tone(b, 0.0, 0.12, 300, 80, SIN, 0.9, 0.001)
	_tone(b, 0.0, 0.2, 1900, 1500, TRI, 0.12, 0.001, 4)
	_drive(b, 1.5)
	_echo(b, 0.07, 0.22)
	s["shoot_revolver"] = [_wav(b, "shoot_revolver")]

	b = _buf(0.11)  # smg: a short clacky pop (it repeats eighteen times a second)
	_noise(b, 0.0, 0.015, 1.0, 9000, 6000, 1800, 0.0005)
	_noise(b, 0.0, 0.07, 0.8, 5000, 900, 0, 0.001, 4)
	_tone(b, 0.0, 0.05, 240, 110, SQR, 0.5, 0.001, 2, 0.3)
	_drive(b, 1.4)
	s["shoot_smg"] = [_wav(b, "shoot_smg")]

	b = _buf(0.3)  # crossbow: twang, thunk and a whistle
	_tone(b, 0.0, 0.2, 210, 150, TRI, 0.8, 0.001, 2, 0.5, 38.0, 0.08)
	_tone(b, 0.0, 0.05, 110, 60, SIN, 0.8, 0.001)
	_noise(b, 0.0, 0.03, 0.6, 3000, 1200, 500)
	_noise(b, 0.02, 0.25, 0.35, 2500, 6000, 1500, 0.02)
	s["shoot_bow"] = [_wav(b, "shoot_bow")]

	b = _buf(0.7)  # double barrel: the shotgun, lower and fatter
	_noise(b, 0.0, 0.03, 1.0, 8000, 5000, 1200, 0.0005)
	_noise(b, 0.0, 0.38, 1.0, 6000, 300, 0, 0.001, 4)
	_noise(b, 0.0, 0.6, 0.55, 700, 120, 0, 0.002)
	_tone(b, 0.0, 0.36, 130, 30, SIN, 1.3, 0.001)
	_tone(b, 0.0, 0.14, 80, 40, SQR, 0.4, 0.001)
	_drive(b, 2.0)
	_echo(b, 0.1, 0.32)
	s["shoot_double"] = [_wav(b, "shoot_double")]

	b = _buf(0.4)  # launcher: a hollow "foomp" out of a tube
	_tone(b, 0.0, 0.22, 240, 70, SIN, 1.0, 0.004)
	_tone(b, 0.0, 0.1, 480, 180, TRI, 0.3, 0.002)
	_noise(b, 0.0, 0.3, 0.6, 1400, 300, 0, 0.01)
	_echo(b, 0.08, 0.2)
	s["shoot_launcher"] = [_wav(b, "shoot_launcher")]

	b = _buf(0.34)  # pigeon: an indignant coo and a flap
	_tone(b, 0.0, 0.14, 520, 700, SIN, 0.7, 0.01, 0, 0.5, 30.0, 0.05)
	_tone(b, 0.14, 0.16, 660, 480, SIN, 0.7, 0.01, 2, 0.5, 30.0, 0.05)
	for k in 3:
		_noise(b, 0.05 + k * 0.08, 0.05, 0.5, 1800, 600, 200, 0.01)
	s["shoot_pigeon"] = [_wav(b, "shoot_pigeon")]

	b = _buf(0.22)  # hose: a rush of water (retriggered while the trigger is held)
	_noise(b, 0.0, 0.22, 1.0, 3200, 2400, 500, 0.03, 0)
	_noise(b, 0.0, 0.22, 0.4, 700, 500, 0, 0.03, 0)
	s["hose"] = [_wav(b, "hose")]

	b = _buf(0.2)  # a heavy thing swung through the air
	_noise(b, 0.0, 0.2, 1.0, 300, 2600, 120, 0.06)
	_tone(b, 0.0, 0.18, 120, 300, SAW, 0.1, 0.05)
	s["swing"] = [_wav(b, "swing")]

	b = _buf(0.5)  # frying pan on a skull: clang with a wobble
	_tone(b, 0.0, 0.45, 880, 860, SIN, 0.8, 0.001, 2, 0.5, 11.0, 0.02)
	_tone(b, 0.0, 0.35, 1320, 1290, TRI, 0.4, 0.001, 4)
	_tone(b, 0.0, 0.25, 2210, 2180, SIN, 0.25, 0.001, 4)
	_tone(b, 0.0, 0.08, 220, 90, SIN, 0.9, 0.001)
	_noise(b, 0.0, 0.02, 0.8, 6000, 3000, 1000)
	s["pan_hit"] = [_wav(b, "pan_hit")]

	b = _buf(0.36)  # magazine out, magazine in, slap
	_noise(b, 0.0, 0.04, 0.8, 3500, 1500, 700)
	_tone(b, 0.0, 0.04, 500, 360, SQR, 0.3, 0.001, 2, 0.3)
	_noise(b, 0.16, 0.04, 0.9, 4500, 2000, 900)
	_tone(b, 0.16, 0.05, 640, 760, SQR, 0.3, 0.001, 2, 0.3)
	_noise(b, 0.27, 0.04, 0.7, 2500, 900, 300)
	_tone(b, 0.27, 0.08, 190, 100, SIN, 0.6)
	s["reload_mag"] = [_wav(b, "reload_mag")]

	b = _buf(0.14)  # weapon switch: cloth and a click
	_noise(b, 0.0, 0.1, 0.7, 900, 2600, 300, 0.03)
	_noise(b, 0.09, 0.03, 0.8, 5000, 2500, 1200)
	_tone(b, 0.09, 0.04, 900, 700, SQR, 0.25, 0.001, 2, 0.3)
	s["switch"] = [_wav(b, "switch")]

	b = _buf(0.3)  # perfect reload: a bright ding-ding
	_tone(b, 0.0, 0.1, 1320, 1320, SIN, 0.7, 0.001, 4)
	_tone(b, 0.07, 0.22, 1980, 1980, SIN, 0.7, 0.001, 4)
	_tone(b, 0.07, 0.22, 3960, 3960, TRI, 0.15, 0.001, 4)
	s["perfect"] = [_wav(b, "perfect")]

	b = _buf(0.22)  # throw: a grunt of effort and a whoosh
	_noise(b, 0.0, 0.2, 1.0, 400, 3200, 150, 0.05)
	_tone(b, 0.0, 0.1, 160, 110, SAW, 0.25, 0.01)
	s["throw"] = [_wav(b, "throw")]

	b = _buf(0.4)  # bottle smashing
	_noise(b, 0.0, 0.05, 1.0, 12000, 8000, 3000, 0.0005)
	for k in 6:
		var f := 2400.0 + ((k * 977) % 2600)
		_tone(b, 0.01 + k * 0.035, 0.12, f, f * 0.97, SIN, 0.3, 0.001, 4)
	_noise(b, 0.03, 0.3, 0.4, 9000, 5000, 3500, 0.01)
	s["glass"] = [_wav(b, "glass")]

	b = _buf(0.5)  # a pigeon arrives: small pop, squawk
	_noise(b, 0.0, 0.25, 1.0, 5000, 400, 0, 0.001, 4)
	_tone(b, 0.0, 0.2, 150, 50, SIN, 1.0, 0.001)
	_tone(b, 0.04, 0.2, 900, 500, SAW, 0.3, 0.005, 2, 0.5, 45.0, 0.1)
	_drive(b, 1.4)
	_echo(b, 0.09, 0.25)
	s["pigeon_pop"] = [_wav(b, "pigeon_pop")]

	b = _buf(0.9)  # bonk frenzy: a fast rising fanfare
	var fr := [0, 4, 7, 12, 7, 12, 16]
	for i in 7:
		var f := 523.3 * pow(2.0, fr[i] / 12.0)
		var last := i == 6
		_tone(b, i * 0.07, 0.4 if last else 0.075, f, f, SQR, 0.5, 0.002, 2 if last else 1, 0.25)
		_tone(b, i * 0.07, 0.4 if last else 0.075, f * 2.0, f * 2.0, TRI, 0.2, 0.002)
	_echo(b, 0.1, 0.3)
	s["frenzy"] = [_wav(b, "frenzy")]

	b = _buf(0.5)  # crate hits the street
	_tone(b, 0.0, 0.3, 95, 35, SIN, 1.2, 0.001)
	_noise(b, 0.0, 0.2, 1.0, 2500, 250)
	_noise(b, 0.06, 0.12, 0.5, 5000, 1500, 800)   # planks rattle
	_tone(b, 0.0, 0.07, 240, 120, SQR, 0.4, 0.001)
	_drive(b, 1.5)
	_echo(b, 0.09, 0.25)
	s["crate_land"] = [_wav(b, "crate_land")]

	b = _buf(0.9)  # airdrop incoming: a two-tone radio call, twice
	for k in 2:
		_tone(b, k * 0.42, 0.14, 880, 880, SQR, 0.5, 0.004, 0, 0.25)
		_tone(b, k * 0.42 + 0.15, 0.2, 1174.7, 1174.7, SQR, 0.5, 0.004, 1, 0.25)
		_noise(b, k * 0.42, 0.36, 0.12, 5000, 4000, 2500, 0.01, 0)
	_crush(b, 2, 32.0)
	_echo(b, 0.12, 0.25)
	s["airdrop"] = [_wav(b, "airdrop")]

	b = _buf(0.55)  # picking up a weapon: chunky click, then a proud little rise
	_noise(b, 0.0, 0.04, 0.9, 4000, 1500, 600)
	_tone(b, 0.0, 0.07, 180, 110, SIN, 0.7)
	var pk := [392.0, 523.3, 659.3, 784.0]
	for i in 4:
		_tone(b, 0.07 + i * 0.06, 0.25 if i == 3 else 0.07, pk[i], pk[i], SQR, 0.45, 0.002, 2 if i == 3 else 1, 0.25)
	_echo(b, 0.1, 0.25)
	s["pickup"] = [_wav(b, "pickup")]

	b = _buf(0.6)  # power-up: a rising sweep with sparkle
	_tone(b, 0.0, 0.4, 220, 1760, SAW, 0.4, 0.01, 1)
	_tone(b, 0.0, 0.4, 440, 3520, TRI, 0.3, 0.01, 1)
	_tone(b, 0.34, 0.24, 1760, 1760, SIN, 0.5, 0.003, 2, 0.5, 12.0, 0.02)
	_echo(b, 0.08, 0.3)
	s["powerup"] = [_wav(b, "powerup")]

	b = _buf(0.45)  # health: two soft rising notes
	_tone(b, 0.0, 0.16, 523.3, 523.3, SIN, 0.7, 0.01)
	_tone(b, 0.0, 0.16, 1046.5, 1046.5, TRI, 0.2, 0.01)
	_tone(b, 0.14, 0.3, 784.0, 784.0, SIN, 0.7, 0.01)
	_tone(b, 0.14, 0.3, 1568.0, 1568.0, TRI, 0.2, 0.01)
	s["heal"] = [_wav(b, "heal")]

	b = _buf(0.34)  # ammo: shells rattling into a pocket
	for k in 4:
		_noise(b, k * 0.06, 0.04, 0.8, 5000, 2200, 1200)
		_tone(b, k * 0.06, 0.05, 700.0 + k * 130.0, 600.0 + k * 130.0, SQR, 0.25, 0.001, 2, 0.3)
	_tone(b, 0.24, 0.09, 200, 120, SIN, 0.5)
	s["ammo"] = [_wav(b, "ammo")]

# Two 16 s loops at 120 bpm in A minor (Am, F, Dm, E; two bars each). Both begin and end in
# silence. Layer A is always heard; layer B fades in with set_intensity.
func _build_music() -> void:
	var t0 := Time.get_ticks_usec()
	_sr = MSR
	var st := 0.125  # one 16th note
	var a := _buf(MUSIC_SECONDS)
	var roots := [45, 45, 41, 41, 38, 38, 40, 40]
	var fifths := [52, 52, 48, 48, 45, 45, 47, 47]
	var pad := [69, 72, 69, 65, 65, 74, 76, 68]
	for bar in 8:
		var t := bar * 2.0
		var r: int = roots[bar]
		var f: int = fifths[bar]
		# layer A: bouncing octave bass, kick, off-beat tick, theremin
		var line := [r, r + 12, f, r + 12, r, r + 12, f, r + 12]
		if bar == 7:
			line = [40, 52, 44, 56, 47, 59, 44, 0]
		for i in 8:
			if line[i] > 0:
				_tone(a, t + i * 0.25, 0.23, _hz(line[i]), _hz(line[i]), SQR, 0.5 if i % 2 == 0 else 0.3, 0.003)
		for k in ([0, 8, 14] if bar % 2 == 1 and bar < 7 else [0, 8]):
			_tone(a, t + k * st, 0.14, 150, 42, SIN, 0.9, 0.001)
			_noise(a, t + k * st, 0.02, 0.25, 3000, 1500)
		for k in [2, 6, 10, 14]:
			if bar < 7 or k < 14:
				_noise(a, t + k * st, 0.03, 0.16, 5000, 4000, 2500)
		_tone(a, t + 0.02, 1.9, _hz(pad[bar]), _hz(pad[bar]), SIN, 0.17, 0.15, 0, 0.5, 5.5, 0.012)
	var used := Time.get_ticks_usec() - t0
	await (Engine.get_main_loop() as SceneTree).process_frame
	t0 = Time.get_ticks_usec()
	_sr = MSR
	_cache["music_a"] = _wav(_lead_in(a), "", 0.6, not _web)
	used += Time.get_ticks_usec() - t0
	await (Engine.get_main_loop() as SceneTree).process_frame
	t0 = Time.get_ticks_usec()
	_sr = MSR
	var b := _buf(MUSIC_SECONDS)
	for bar in 8:
		var t := bar * 2.0
		var r: int = roots[bar]
		# layer B: snare, 16th hats, extra kick, bass stab
		for k in [4, 12]:
			_noise(b, t + k * st, 0.13, 0.7, 4500, 1500, 300)
			_tone(b, t + k * st, 0.07, 210, 150, TRI, 0.45, 0.001)
		for k in 16:
			if k % 2 == 1 and (bar < 7 or k < 8):
				_noise(b, t + k * st, 0.02, 0.14, 5000, 4500, 3000)
		_tone(b, t + 10 * st, 0.12, 150, 45, SIN, 0.6, 0.001)
		if bar < 7:
			_tone(b, t, 0.1, _hz(r + 12), _hz(r + 12), SAW, 0.22, 0.003)
			_tone(b, t + 6 * st, 0.1, _hz(r + 12), _hz(r + 12), SAW, 0.22, 0.003)
	var fill := [120, 122, 124, 125, 126]
	for i in 5:
		_noise(b, fill[i] * st, 0.09, 0.45 + i * 0.08, 4500, 1500, 300)
	# lead: [16th step, length in steps, midi note]
	var lead := [
		[0, 2, 76], [3, 1, 72], [4, 2, 76], [6, 2, 81], [8, 2, 80], [10, 2, 76], [12, 2, 72], [14, 2, 71],
		[16, 4, 69], [20, 2, 72], [22, 2, 76], [24, 2, 75], [26, 6, 76],
		[32, 2, 77], [35, 1, 72], [36, 2, 77], [38, 2, 81], [40, 2, 79], [42, 2, 77], [44, 2, 72], [46, 2, 69],
		[48, 4, 65], [52, 2, 69], [54, 2, 72], [56, 2, 71], [58, 6, 72],
		[64, 2, 74], [67, 1, 69], [68, 2, 74], [70, 2, 77], [72, 2, 76], [74, 2, 74], [76, 2, 69], [78, 2, 65],
		[80, 3, 74], [83, 3, 77], [86, 2, 81], [88, 2, 80], [90, 6, 81],
		[96, 2, 80], [99, 1, 76], [100, 2, 80], [102, 2, 83], [104, 2, 81], [106, 2, 80], [108, 2, 77], [110, 2, 76],
		[112, 2, 76], [114, 2, 75], [116, 2, 74], [118, 2, 72], [120, 3, 71],
	]
	for n in lead:
		var hz := _hz(n[2])
		_tone(b, n[0] * st, n[1] * st * 0.92, hz, hz, SQR, 0.3, 0.004, 0 if n[1] > 2 else 1, 0.25, 5.5, 0.006 if n[1] > 2 else 0.0)
	used += Time.get_ticks_usec() - t0
	await (Engine.get_main_loop() as SceneTree).process_frame
	t0 = Time.get_ticks_usec()
	_sr = MSR
	_cache["music_b"] = _wav(_lead_in(b), "", 0.6, not _web)
	_sr = SR
	_nz = PackedFloat32Array()
	_tables.clear()
	_cache["music_ms"] = (used + Time.get_ticks_usec() - t0) / 1000.0
	_music_ready()

# Rotate a loop so PRE seconds of silence from its tail become its lead-in.
func _lead_in(b: PackedFloat32Array) -> PackedFloat32Array:
	var k := b.size() - int(PRE * _sr)
	var rot := b.slice(k)
	rot.append_array(b.slice(0, k))
	return rot

func _hz(midi: int) -> float:
	return 440.0 * pow(2.0, (midi - 69) / 12.0)

func _buf(seconds: float) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	b.resize(int(seconds * _sr))
	return b

# Oscillator with an exponential pitch sweep f0 -> f1.
# shape: 0 = held (short release), 1 = linear decay, 2 = squared, 4 = fourth power.
func _tone(b: PackedFloat32Array, t0: float, dur: float, f0: float, f1: float, wave: int, amp: float,
		att := 0.002, shape := 2, duty := 0.5, vib_hz := 0.0, vib_depth := 0.0) -> void:
	var o := int(t0 * _sr)
	var n := mini(int(dur * _sr), b.size() - o)
	if n <= 0:
		return
	var k := pow(f1 / f0, 1.0 / n)
	var f := f0 / _sr
	var ph := 0.0
	var an := maxi(1, int(att * _sr))
	var rn := maxf(1.0, minf(0.03 * _sr, n * 0.25))
	var inv := 1.0 / n
	var vstep := TAU * vib_hz / _sr
	var tb := _table(wave, duty)
	var s := 0.0
	var e := 0.0
	for i in n:
		s = tb[int(ph * 1024.0)]
		if vib_depth > 0.0:
			ph += f * (1.0 + vib_depth * sin(vstep * i))
		else:
			ph += f
		if ph >= 1.0:
			ph -= 1.0
		f *= k
		if shape == 0:
			e = minf(1.0, (n - i) / rn)
		else:
			e = 1.0 - i * inv
			if shape >= 2:
				e *= e
			if shape == 4:
				e *= e
		if i < an:
			e *= float(i) / an
		b[o + i] += s * e * amp

# One cycle of a waveform, 1024 steps (a table lookup is far cheaper than branching per sample).
func _table(wave: int, duty: float) -> PackedFloat32Array:
	var key := wave * 100 + int(duty * 99.0)
	if _tables.has(key):
		return _tables[key]
	var tb := PackedFloat32Array()
	tb.resize(1026)
	for j in 1026:
		var ph := (j + 0.5) / 1024.0
		match wave:
			SIN: tb[j] = sin(ph * TAU)
			SQR: tb[j] = (1.0 if ph < duty else -1.0) - (2.0 * duty - 1.0)  # no DC at any duty
			SAW: tb[j] = ph * 2.0 - 1.0
			_: tb[j] = 4.0 * absf(fposmod(ph, 1.0) - 0.5) - 1.0
	_tables[key] = tb
	return tb

# White noise through a one-pole low-pass that sweeps lp0 -> lp1 (Hz), optional high-pass.
func _noise(b: PackedFloat32Array, t0: float, dur: float, amp: float, lp0: float, lp1: float,
		hp := 0.0, att := 0.001, shape := 2) -> void:
	var o := int(t0 * _sr)
	var n := mini(int(dur * _sr), b.size() - o)
	if n <= 0:
		return
	var a := 1.0 - exp(-TAU * minf(lp0, _sr * 0.45) / _sr)
	var a1 := 1.0 - exp(-TAU * minf(lp1, _sr * 0.45) / _sr)
	var ak := pow(a1 / a, 1.0 / n)
	var am := sqrt(a * a1)
	amp *= minf(1.0 / sqrt(am / (2.0 - am)), 8.0)  # make up the level the filter removes
	var ah := 1.0 - exp(-TAU * hp / _sr)
	var y := 0.0
	var yh := 0.0
	var an := maxi(1, int(att * _sr))
	var rn := maxf(1.0, minf(0.03 * _sr, n * 0.25))
	var inv := 1.0 / n
	var ni := _ni
	_ni = (_ni + n + 977) & 16383
	var s := 0.0
	var e := 0.0
	for i in n:
		y += a * (_nz[ni] - y)
		ni = (ni + 1) & 16383
		a *= ak
		s = y
		if hp > 0.0:
			yh += ah * (y - yh)
			s = y - yh
		if shape == 0:
			e = minf(1.0, (n - i) / rn)
		else:
			e = 1.0 - i * inv
			if shape >= 2:
				e *= e
			if shape == 4:
				e *= e
		if i < an:
			e *= float(i) / an
		b[o + i] += s * e * amp

# Buzzy voice: saw (+ a sub pulse when sub is on) gliding f0 -> f1 -> f2 through a sweeping
# low-pass, with a sawtooth tremolo (am_hz, am_depth) for the rattle in a zombie's throat.
func _growl(b: PackedFloat32Array, t0: float, dur: float, f0: float, f1: float, f2: float, amp: float,
		lp0: float, lp1: float, am_hz: float, am_depth: float, att: float, rel: float, sub := true) -> void:
	var o := int(t0 * _sr)
	var n := mini(int(dur * _sr), b.size() - o)
	if n <= 0:
		return
	var h := n / 2
	var k1 := pow(f1 / f0, 1.0 / h)
	var k2 := pow(f2 / f1, 1.0 / (n - h))
	var f := f0 / _sr
	var ph := 0.0
	var ph2 := 0.0
	var a := 1.0 - exp(-TAU * lp0 / _sr)
	var ak := pow((1.0 - exp(-TAU * lp1 / _sr)) / a, 1.0 / n)
	var y := 0.0
	var aph := 0.0
	var ast := am_hz / _sr
	var an := maxf(1.0, att * _sr)
	var rn := maxf(1.0, rel * _sr)
	var subg := 0.35 if sub else 0.0
	var s := 0.0
	for i in n:
		ph += f
		if ph >= 1.0:
			ph -= 1.0
		ph2 += f * 0.503
		if ph2 >= 1.0:
			ph2 -= 1.0
		s = ph * 2.0 - 1.0 + (subg if ph2 < 0.5 else -subg)
		y += a * (s - y)
		a *= ak
		f *= k1 if i < h else k2
		aph += ast
		if aph >= 1.0:
			aph -= 1.0
		b[o + i] += y * (1.0 - am_depth * aph) * minf(1.0, minf(i / an, (n - i) / rn)) * amp

# Retro grit: hold every sample for `hold` samples and round it to `levels` steps.
func _crush(b: PackedFloat32Array, hold: int, levels: float) -> void:
	var v := 0.0
	for i in b.size():
		if i % hold == 0:
			v = roundf(b[i] * levels) / levels
		b[i] = v

func _drive(b: PackedFloat32Array, gain: float) -> void:
	for i in b.size():
		b[i] = tanh(b[i] * gain)

# Feedback echo baked into the buffer.
func _echo(b: PackedFloat32Array, delay: float, gain: float) -> void:
	var d := int(delay * _sr)
	for i in range(d, b.size()):
		b[i] += b[i - d] * gain

# Remove DC, normalise to a peak, fade the ends, pack as 16-bit mono.
func _wav(b: PackedFloat32Array, sound: String, peak := 1.0, loop := false) -> AudioStreamWAV:
	if sound != "":
		peak = CONF[sound][0]
	var n := b.size()
	var sum := 0.0
	var lo := 0.0
	var hi := 0.0
	var v := 0.0
	for i in n:
		v = b[i]
		sum += v
		if v > hi:
			hi = v
		elif v < lo:
			lo = v
	var dc := sum / n
	var g := peak * 32767.0 / maxf(maxf(hi - dc, dc - lo), 0.0001)
	var fade := mini(int(0.008 * _sr), n / 4)
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	for i in n:
		bytes.encode_s16(i * 2, int((b[i] - dc) * g))
	for i in fade:  # the tail goes to exactly zero (every sound already starts from zero)
		var k := float(i) / fade
		var j := (n - 1 - i) * 2
		bytes.encode_s16(j, int(bytes.decode_s16(j) * k))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = _sr
	w.stereo = false
	w.data = bytes
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = n
	_cache["bytes"] += n * 2
	return w
