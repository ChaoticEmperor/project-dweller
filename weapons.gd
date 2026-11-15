extends Node
# The player's weapons: the table of what exists, which ones are carried, firing, reloading,
# switching, thrown hot sauce, the bonk meter, and the first-person models.
# main.gd calls update(dt) every frame while playing; everything else in the game talks to
# weapons through the functions and signals below (see SPECS.md).
#
# How a weapon works is decided by its "mode":
#   shot   - ray casts: pellets, spread, range falloff, optional piercing (most guns)
#   proj   - launches a pooled projectile that is moved by hand each frame (hot dog, pigeon)
#   stream - a short-range cone every tick that hurts a little and pushes a lot (hydrant)
#   melee  - a wide swing, no ammo (frying pan)
# Upgrade cards apply on top of each weapon's own numbers through main.upgrades (see the
# "numbers after upgrades" section for which card touches which weapon).
const GunModels = preload("res://gun_models.gd")
const Models = preload("res://models.gd")

signal fired(id: String)
signal weapon_changed(id: String)
signal picked_up(id: String)

const SLOTS := 3                # the starter + two found weapons
const STARTER := "shotgun"
const SWITCH_TIME := 0.28       # seconds a freshly drawn weapon cannot fire
const FRENZY_TIME := 7.0        # bonk frenzy: faster fire, free ammo, +25% damage
const FRENZY_FIRE := 0.6
const FRENZY_DAMAGE := 1.25
const BONK_KILL := 0.085        # meter gained per kill (about a dozen kills fill it) ...
const BONK_HEAD := 0.045        # ... plus this for a headshot kill
const PERFECT_AT := 0.55        # middle of the perfect-reload window, as a fraction of the reload
const PERFECT_HALF := 0.09      # half its width (the SMOOTH HANDS card widens it)
const PERFECT_BONUS := 0.30     # extra damage of a perfectly reloaded magazine
const FUMBLE_TIME := 0.3        # a mistimed second press costs this much
const THROW_CD := 12.0          # hot sauce cooldown
const SAUCE := {"damage": 90.0, "blast": 3.5, "burn_r": 3.0, "burn_time": 5.0, "burn_dmg": 16.0, "burn_tick": 0.4}
const PROJ_MAX := 8
const NO_SHELL := Color(0, 0, 0, 0)

# The weapon table. Missing keys take the values in DEFAULTS.
#   damage per pellet / per blast / per hose tick / per swing; cd = seconds between shots;
#   mag = magazine; reserve = spare rounds a fresh pickup comes with (-1 = endless);
#   near/far/far_k = full damage up to `near` metres, falling to far_k of it at `far`;
#   wave = first wave whose reward crate may hold it; weight = how often.
const DEFAULTS := {"pellets": 1.0, "spread": 0.0, "head": 2.4, "reload": 1.0, "reserve": -1, "near": 100.0, "far": 101.0,
	"far_k": 1.0, "range": 80.0, "pierce": 0, "kick": 1.0, "flash": 1.0, "tracer": Color(0.75, 0.6, 0.3), "tracer_w": 0.035,
	"shell": NO_SHELL, "snd_reload": "reload_mag", "snd_ready": "", "boom": 0, "heat": 0.0, "wave": 99, "weight": 0.0,
	"rest": Vector3.ZERO, "shove": []}
const W := {
	"shotgun": {"name": "BOOMSTICK", "mode": "shot", "damage": 25.0, "pellets": 5.0, "spread": 0.03, "cd": 0.16, "mag": 8,
		"reload": 0.9, "near": 14.0, "far": 35.0, "far_k": 0.5, "shell": Color(0.85, 0.2, 0.12), "snd": "shoot",
		"snd_reload": "reload", "snd_ready": "pump", "boom": 1, "color": Color(1.0, 0.56, 0.16), "icon": "w_shotgun"},
	"revolver": {"name": "SNUB NOSE", "mode": "shot", "damage": 60.0, "spread": 0.004, "head": 3.2, "cd": 0.26, "mag": 6,
		"reload": 1.0, "reserve": 60, "range": 110.0, "kick": 0.8, "flash": 0.7, "tracer": Color(0.9, 0.8, 0.45), "snd": "shoot_revolver",
		"boom": 1, "color": Color(0.80, 0.82, 0.92), "icon": "w_revolver", "wave": 1, "weight": 3.0},
	"smg": {"name": "RAT-A-TAT", "mode": "shot", "damage": 18.0, "spread": 0.014, "heat": 0.045, "head": 2.0, "cd": 0.05, "mag": 40,
		"reload": 1.3, "reserve": 200, "near": 18.0, "far": 40.0, "far_k": 0.5, "kick": 0.3, "flash": 0.55, "tracer": Color(0.9, 0.75, 0.2),
		"tracer_w": 0.025, "shell": Color(0.9, 0.75, 0.25), "snd": "shoot_smg", "boom": 4, "color": Color(1.0, 0.82, 0.15), "icon": "w_smg",
		"wave": 1, "weight": 3.0},
	"skewer": {"name": "KEBAB BOW", "mode": "shot", "damage": 95.0, "head": 3.5, "cd": 0.65, "mag": 4, "reload": 1.5, "reserve": 28,
		"range": 110.0, "pierce": 4, "kick": 0.6, "flash": 0.0, "tracer": Color(0.8, 0.9, 1.0), "tracer_w": 0.05, "snd": "shoot_bow",
		"boom": 1, "color": Color(0.55, 0.9, 0.45), "icon": "w_skewer", "wave": 2, "weight": 3.0},
	"double": {"name": "DOUBLE TROUBLE", "mode": "shot", "damage": 22.0, "pellets": 11.0, "spread": 0.085, "cd": 0.22, "mag": 2,
		"reload": 1.6, "reserve": 24, "near": 7.0, "far": 20.0, "far_k": 0.3, "kick": 2.2, "flash": 1.6, "shell": NO_SHELL,
		"snd": "shoot_double", "boom": 1, "shove": [5.5, 60.0, 8.0], "color": Color(0.96, 0.35, 0.25), "icon": "w_double",
		"wave": 2, "weight": 3.0},
	"launcher": {"name": "HOT DOG CANNON", "mode": "proj", "proj": "hotdog", "damage": 140.0, "blast": 4.2, "speed": 24.0, "cd": 0.7,
		"mag": 3, "reload": 2.0, "reserve": 12, "kick": 1.5, "flash": 0.9, "snd": "shoot_launcher", "color": Color(1.0, 0.85, 0.2),
		"icon": "w_launcher", "wave": 4, "weight": 3.0},
	"pigeon": {"name": "PIGEON POST", "mode": "proj", "proj": "pigeon", "damage": 70.0, "blast": 2.2, "speed": 15.0, "cd": 0.35,
		"mag": 6, "reload": 1.8, "reserve": 30, "kick": 0.5, "flash": 0.0, "snd": "shoot_pigeon", "color": Color(0.45, 0.65, 1.0),
		"icon": "w_pigeon", "wave": 4, "weight": 3.0},
	"hydrant": {"name": "HYDRANT HOSE", "mode": "stream", "damage": 15.0, "reach": 12.0, "arc": 30.0, "force": 6.0, "cd": 0.06,
		"mag": 120, "reload": 2.2, "reserve": 360, "kick": 0.08, "flash": 0.0, "snd": "hose", "color": Color(0.4, 0.86, 1.0),
		"icon": "w_hydrant", "wave": 2, "weight": 2.0},
	"pan": {"name": "FRYING PAN", "mode": "melee", "damage": 75.0, "reach": 3.3, "arc": 110.0, "force": 8.0, "cd": 0.42, "mag": 1,
		"kick": 0.0, "flash": 0.0, "snd": "swing", "rest": Vector3(0.75, 0.35, -0.5), "color": Color(0.72, 0.56, 1.0), "icon": "w_pan",
		"wave": 1, "weight": 2.0},
}

var main: Node3D
var gun: Node3D              # holder of the first-person models (child of the camera); fx animates it too
var current := STARTER       # id of the weapon in hand
var owned: Array = [STARTER]
var ammo := 8                # rounds in the current weapon's magazine
var reloading := 0.0         # seconds left of the current reload, 0 = not reloading
var mags := {}               # id -> rounds in the magazine of a carried weapon that is not in hand
var reserves := {}           # id -> spare rounds (-1 = endless)
var bonk := 0.0              # bonk meter 0..1
var frenzy_t := 0.0          # seconds of bonk frenzy left
var throw_t := 0.0           # seconds until the hot sauce is ready again
var juiced := false          # this magazine was perfectly reloaded (bonus damage)

var _models := {}            # id -> Node3D
var _fire_cd := 0.0
var _recoil := 0.0
var _pump_t := 0.0
var _switch_t := 0.0
var _swing_t := 0.0
var _throw_anim := 0.0
var _heat := 0.0             # smg: grows while spraying, widens the spread
var _spin := 0.0             # revolver cylinder angle (target)
var _shots := 0              # shots fired with the current weapon (for "every Nth shot" effects)
var _reload_total := 1.0
var _perfect := 0            # this reload's second press: 0 not used, 1 perfect, 2 fumbled
var _perfect_t := 0.0        # HUD flash after a perfect / fumble
var _empty_t := 0.0          # delay before switching away from a weapon that ran dry
var _visible := true
var _wired := false
var _proj: Array = []        # fixed pool of projectiles (Dictionaries)
var _puddles: Array = []     # fixed pool of burning hot-sauce puddles
var _slot_info: Array = []

func setup(main_node: Node3D) -> void:
	main = main_node
	gun = Node3D.new()
	main.cam.add_child(gun)
	gun.position = Vector3(0.25, -0.22, -0.45)
	gun.scale = Vector3.ONE * 0.6
	for id in W:
		var m: Node3D = GunModels.make(id)
		m.visible = false
		gun.add_child(m)
		_models[id] = m
	main.fx.attach_gun(gun)
	for i in PROJ_MAX:
		var node := MeshInstance3D.new()
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.mesh = GunModels.prop(["hotdog", "pigeon", "bottle"][i % 3])   # also builds the meshes now
		node.visible = false
		add_child(node)
		_proj.append({"node": node, "live": false, "kind": "", "pos": Vector3.ZERO, "vel": Vector3.ZERO, "t": 0.0,
			"dmg": 0.0, "r": 1.0, "trail": 0.0, "target": null, "seek": 0.0})
	for i in 2:
		_puddles.append({"t": 0.0, "pos": Vector3.ZERO, "tick": 0.0, "fx": 0.0})
	mags[STARTER] = max_ammo_of(STARTER)
	reserves[STARTER] = -1
	ammo = mags[STARTER]
	_apply_model()

func _wire() -> void:
	# controls and zombies are created after weapons in main._ready, so connect on first use
	if _wired or main.controls == null or main.zombies == null:
		return
	_wired = true
	var c: Node = main.controls
	if c.has_signal("weapon_next"):
		c.connect("weapon_next", next)
		c.connect("weapon_prev", prev)
		c.connect("weapon_slot", switch_slot)
		c.connect("throw", throw_sauce)
	main.zombies.zombie_killed.connect(_on_killed)

func _playing() -> bool:
	return main.started and not main.dead and not main.drafting

# ---------------------------------------------------------------- numbers after upgrades
# Which card touches what:
#   damage (ANGRY AMMO, CHOKE, GLASS CANNON)  every weapon, the hot sauce and every blast
#   fire_cd (GREASED PUMP)                    every weapon
#   reload_time (SPEED LOADER)                every weapon with a magazine
#   max_ammo (LONGER TUBE)                    every magazine, in proportion (+3 per 8 rounds)
#   pellets (EXTRA BUCKSHOT)                  shotguns only (weapons with more than one pellet)
#   spread, head_mult                         every ray-cast weapon
#   explosive_radius (SPICY SHELLS)           ray-cast weapons (the smg every 4th shot); half of
#                                             it is added to projectile and sauce blasts
#   reserve_mult, blast_mult, pierce, melee_*, hose_*, flock, throw_cd, perfect_*, bonk_gain:
#                                             the weapon cards in upgrades.gd

func _w(id: String, key: String) -> Variant:
	var w: Dictionary = W[id]
	return w[key] if w.has(key) else DEFAULTS[key]

func _up(name: String, base: float) -> float:
	return main.upgrades.stat(name, base)

func _power(id: String) -> bool:
	var d: Node = main.drops
	return d != null and d.has_method("power") and d.power(id)

func free_ammo() -> bool:
	return frenzy_t > 0.0 or _power("ammo")

func damage_mult() -> float:
	var k := 1.0
	if _power("damage"):
		k *= 2.0
	if frenzy_t > 0.0:
		k *= FRENZY_DAMAGE
	return k

func damage_of(id: String) -> float:
	var d: float = _up("damage", float(_w(id, "damage"))) * damage_mult()
	if juiced and id == current:
		d *= 1.0 + _up("perfect_bonus", PERFECT_BONUS)
	if _w(id, "mode") == "melee":
		d *= _up("melee_mult", 1.0)
	return d

func cooldown_of(id: String) -> float:
	var base: float = _w(id, "cd")
	var cd: float = maxf(base * main.upgrades.mul("fire_cd"), minf(0.07, base * 0.7))
	return cd * (FRENZY_FIRE if frenzy_t > 0.0 else 1.0)

func reload_time_of(id: String) -> float:
	return _up("reload_time", float(_w(id, "reload")))

func max_ammo_of(id: String) -> int:
	if _w(id, "mode") == "melee":
		return 1
	var base: int = _w(id, "mag")
	var extra: float = main.upgrades.add("max_ammo")   # counted in shotgun shells: +3 per level
	return clampi(base + int(ceil(extra * base / 8.0 - 0.001)), 1, maxi(base * 3, 20 if id == STARTER else 0))

# Spare rounds a full pickup of this weapon gives (-1 = endless).
func reserve_cap(id: String) -> int:
	var r: int = _w(id, "reserve")
	return r if r < 0 else int(round(r * _up("reserve_mult", 1.0)))

func blast_of(base: float) -> float:
	return (base + 0.5 * _up("explosive_radius", 0.0)) * _up("blast_mult", 1.0)

func max_ammo() -> int:
	return max_ammo_of(current)

func reload_frac() -> float:
	return clamp(1.0 - reloading / maxf(_reload_total, 0.01), 0.0, 1.0)

func reserve() -> int:
	return reserves.get(current, -1)

func is_melee() -> bool:
	return _w(current, "mode") == "melee"

func throw_time() -> float:
	return _up("throw_cd", THROW_CD)

func perfect_window() -> Vector2:
	var h: float = _up("perfect_window", PERFECT_HALF)
	return Vector2(PERFECT_AT - h, PERFECT_AT + h)

# What the HUD needs to draw the weapon panel and the meters.
func hud_info() -> Dictionary:
	_slot_info.resize(owned.size())
	for i in owned.size():
		var id: String = owned[i]
		var s = _slot_info[i]
		if s == null:
			s = {}
			_slot_info[i] = s
		s["id"] = id
		s["name"] = W[id].name
		s["color"] = W[id].color
		s["icon"] = W[id].icon
		s["ammo"] = ammo if id == current else int(mags.get(id, 0))
		s["reserve"] = int(reserves.get(id, -1))
		s["melee"] = _w(id, "mode") == "melee"
	var win := perfect_window()
	return {"id": current, "name": W[current].name, "ammo": ammo, "max_ammo": max_ammo(), "reserve": reserve(),
		"slots": owned, "reloading": reloading > 0, "reload_frac": reload_frac(),
		"color": W[current].color, "icon": W[current].icon, "melee": is_melee(), "slot_info": _slot_info,
		"perfect_lo": win.x, "perfect_hi": win.y, "perfect": _perfect, "perfect_t": _perfect_t, "juiced": juiced,
		"bonk": bonk, "frenzy": clampf(frenzy_t / FRENZY_TIME, 0.0, 1.0), "throw_ready": clampf(1.0 - throw_t / throw_time(), 0.0, 1.0),
		"free_ammo": free_ammo()}

# ---------------------------------------------------------------- inventory

func has(id: String) -> bool:
	return owned.has(id)

# Would give(id) work without throwing a carried weapon away?
func can_take(id: String) -> bool:
	return owned.has(id) or owned.size() < SLOTS

# The weapon give() would replace when every slot is full: the one in hand, or (holding
# the starter) the found weapon with the least ammo left.
func replace_target() -> String:
	if current != STARTER:
		return current
	var best := ""
	var best_k := INF
	for id in owned:
		if id == STARTER:
			continue
		var k := 1.0
		if _w(id, "mode") != "melee":
			k = float(int(mags.get(id, 0)) + int(reserves.get(id, 0))) / float(max_ammo_of(id) + maxi(reserve_cap(id), 1))
		if k < best_k:
			best_k = k
			best = id
	return best

# Add a weapon to the inventory and switch to it. Already carried: tops up its spare ammo
# instead (rounds, or half a full pickup). Every slot full: replaces replace_target().
func give(id: String, rounds := -1) -> void:
	if not W.has(id):
		return
	if owned.has(id):
		add_reserve(id, rounds if rounds >= 0 else int(ceil(reserve_cap(id) * 0.5)))
		picked_up.emit(id)
		return
	if owned.size() >= SLOTS:
		var out := replace_target()
		owned[owned.find(out)] = id
		mags.erase(out)
		reserves.erase(out)
		if current == out:
			current = ""
	else:
		owned.append(id)
	mags[id] = max_ammo_of(id)
	reserves[id] = rounds if rounds >= 0 else reserve_cap(id)
	picked_up.emit(id)
	switch_to(id)

# Spare rounds for one weapon; returns how many actually fitted.
func add_reserve(id: String, rounds: int) -> int:
	if not owned.has(id) or int(reserves.get(id, -1)) < 0:
		return 0
	var before: int = reserves[id]
	reserves[id] = mini(before + rounds, reserve_cap(id))
	return int(reserves[id]) - before

# Top up every found weapon by `frac` of a full pickup (ammo drops). False if nothing needed any.
func add_ammo(frac: float) -> bool:
	var any := false
	for id in owned:
		if add_reserve(id, int(ceil(reserve_cap(id) * frac))) > 0:
			any = true
	return any

func switch_to(id: String) -> void:
	if not owned.has(id) or id == current:
		return
	if current != "":
		mags[current] = ammo
	reloading = 0.0
	gun.rotation.x = 0.0
	current = id
	ammo = int(mags.get(id, max_ammo_of(id)))
	juiced = false
	_switch_t = SWITCH_TIME
	_fire_cd = 0.0
	_heat = 0.0
	_empty_t = 0.0
	_swing_t = 0.0
	_apply_model()
	main.sfx.play("switch")
	weapon_changed.emit(id)

func next() -> void:
	if _playing() and owned.size() > 1:
		switch_to(owned[(owned.find(current) + 1) % owned.size()])

func prev() -> void:
	if _playing() and owned.size() > 1:
		switch_to(owned[(owned.find(current) + owned.size() - 1) % owned.size()])

func switch_slot(i: int) -> void:
	if _playing() and i >= 0 and i < owned.size():
		switch_to(owned[i])

# Fill the current magazine for free (used after an upgrade pick).
func refill() -> void:
	ammo = max_ammo()
	reloading = 0.0

# Hide the gun model in third-person view.
func set_view_visible(on: bool) -> void:
	_visible = on
	gun.visible = on

func _apply_model() -> void:
	for id in _models:
		_models[id].visible = id == current
	var m: Node3D = _models[current]
	main.fx.set_muzzle((m.get_node("Muzzle") as Node3D).position)
	main.upgrades.set_weapons(owned)

# ---------------------------------------------------------------- reloading

# Start a reload - or, pressed again while reloading, try for the perfect reload: inside
# the marked window the reload finishes at once and the magazine hits harder; outside it
# the reload takes a little longer. One try per reload.
func start_reload() -> void:
	if not main.started or main.dead:
		return
	if reloading > 0:
		_try_perfect()
		return
	if is_melee() or ammo >= max_ammo():
		return
	if reserve() == 0:
		main.sfx.play("empty")
		return
	_reload_total = reload_time_of(current)
	reloading = _reload_total
	_perfect = 0
	juiced = false
	if _w(current, "shell") != NO_SHELL:
		main.fx.on_reload()
	main.sfx.play(_w(current, "snd_reload"))

func _try_perfect() -> void:
	if _perfect != 0:
		return
	var f := reload_frac()
	var win := perfect_window()
	_perfect_t = 0.8
	if f >= win.x and f <= win.y:
		_perfect = 1
		_finish_reload()
		juiced = true
		main.sfx.play("perfect")
	else:
		_perfect = 2
		reloading += FUMBLE_TIME
		_reload_total += FUMBLE_TIME
		main.sfx.play("empty")

func _finish_reload() -> void:
	reloading = 0.0
	gun.rotation.x = 0.0
	var need := max_ammo() - ammo
	var r := reserve()
	if r >= 0 and not free_ammo():
		need = mini(need, r)
		reserves[current] = r - need
	ammo += need
	var snd: String = _w(current, "snd_ready")
	if snd != "":
		main.sfx.play(snd)

# ---------------------------------------------------------------- per frame


func update(dt: float) -> void:
	_wire()
	var controls: Node = main.controls
	var w: Dictionary = W[current]
	_fire_cd -= dt
	throw_t = maxf(throw_t - dt, 0.0)
	_switch_t = maxf(_switch_t - dt, 0.0)
	_perfect_t = maxf(_perfect_t - dt, 0.0)
	_heat = maxf(_heat - dt * 1.6, 0.0)
	if frenzy_t > 0.0:
		frenzy_t -= dt
		if frenzy_t <= 0.0:
			frenzy_t = 0.0
			main.upgrades.clear_temp("frenzy")
	if reloading > 0:
		reloading -= dt
		if reloading <= 0:
			_finish_reload()
	elif _switch_t <= 0.0 and controls.fire and _fire_cd <= 0:
		if w.mode == "melee":
			_swing()
		elif ammo > 0:
			_shoot()
		elif reserve() != 0:
			main.sfx.play("empty")
			start_reload()
		else:
			main.sfx.play("empty")
			_fire_cd = 0.3
	# a found weapon with nothing left: put it away
	if ammo <= 0 and reserve() == 0 and w.mode != "melee" and reloading <= 0:
		_empty_t += dt
		if _empty_t > 0.45:
			_empty_t = 0.0
			_switch_away()
	else:
		_empty_t = 0.0
	_update_projectiles(dt)
	_update_puddles(dt)
	_animate(dt)

func _switch_away() -> void:
	for id in owned:
		if id != current and (_w(id, "mode") == "melee" or int(mags.get(id, 0)) > 0 or int(reserves.get(id, -1)) != 0):
			_toast("OUT OF AMMO!", Color(1.0, 0.56, 0.16))
			switch_to(id)
			return

func _toast(text: String, col: Color) -> void:
	if main.hud != null and main.hud.has_method("toast"):
		main.hud.toast(text, col)

func _aim() -> Vector3:
	return -main.cam.global_transform.basis.z

func _flat_aim() -> Vector3:
	var f := _aim()
	f.y = 0.0
	return f.normalized() if f.length() > 0.05 else -main.player.global_transform.basis.z

# ---------------------------------------------------------------- firing

func _shoot() -> void:
	var id := current
	if not free_ammo():
		ammo -= 1
	_fire_cd = cooldown_of(id)
	_recoil = clampf(float(_w(id, "kick")), 0.25, 1.6)
	_pump_t = 0.25
	_shots += 1
	_spin += PI / 3.0
	main.sfx.play(_w(id, "snd"), randf_range(0.95, 1.05))
	fired.emit(id)
	main.fx.on_fire(_w(id, "kick"), _w(id, "flash"), _w(id, "tracer"), _w(id, "tracer_w"), _w(id, "shell"))
	match _w(id, "mode"):
		"shot": _fire_rays(id)
		"proj": _fire_projectile(id)
		"stream": _fire_stream(id)
	main.fx.end_shot()

func _falloff(id: String, dist: float) -> float:
	var near: float = _w(id, "near")
	var far: float = _w(id, "far")
	return lerpf(1.0, float(_w(id, "far_k")), clampf((dist - near) / maxf(far - near, 0.01), 0.0, 1.0))

func _fire_rays(id: String) -> void:
	var cam: Camera3D = main.cam
	var space: PhysicsDirectSpaceState3D = main.get_world_3d().direct_space_state
	var base_pellets: float = _w(id, "pellets")
	var pellets: int = int(_up("pellets", base_pellets)) if base_pellets > 1.0 else 1
	var spread: float = _up("spread", float(_w(id, "spread"))) + _heat
	var dmg := damage_of(id)
	var head_mult: float = _up("head_mult", float(_w(id, "head")))
	var pierce: int = _w(id, "pierce")
	if pierce > 0:
		pierce += int(_up("pierce", 0.0))
	var boom_every: int = _w(id, "boom")
	var boom_r: float = _up("explosive_radius", 0.0) if boom_every > 0 and _shots % boom_every == 0 else 0.0
	var boomed := false
	var from := cam.global_position
	var cb := cam.global_transform.basis
	var reach: float = _w(id, "range")
	_heat = minf(_heat + float(_w(id, "heat")) * 0.12, float(_w(id, "heat")))
	for i in pellets:
		var off := Vector3.ZERO
		if spread > 0.0 and (i > 0 or pellets == 1):
			off = Vector3(randf_range(-1, 1), randf_range(-1, 1), 0) * spread
		var fwd: Vector3 = (-cb.z + cb * off).normalized()
		var exclude: Array[RID] = [main.player.get_rid()]
		var seen: Array = []
		var left := pierce + 1
		var guard := 0
		while left > 0 and guard < 14:
			guard += 1
			var q := PhysicsRayQueryParameters3D.create(from, from + fwd * reach)
			q.exclude = exclude
			q.collide_with_areas = true
			var hit: Dictionary = space.intersect_ray(q)
			if hit.is_empty():
				main.fx.tracer_to(from + fwd * 55.0)
				break
			var col: Object = hit.collider
			if col is Area3D and col.has_meta("zombie"):
				exclude.append(hit.rid)
				var z: Dictionary = col.get_meta("zombie")
				if seen.has(z):
					continue   # another hit box of a zombie this pellet already went through
				seen.append(z)
				var head: bool = col.get_meta("head")
				var k: float = _falloff(id, from.distance_to(hit.position)) * pow(0.85, seen.size() - 1)
				main.zombies.hit(z, dmg * k * (head_mult if head else 1.0), head, hit.position, fwd)
				left -= 1
			else:
				main.fx.impact(hit.position, hit.normal)
				left = 0
			# explosive rounds upgrade: one small blast per shot, at the first thing hit
			if boom_r > 0.0 and not boomed:
				boomed = true
				main.zombies.damage_radius(hit.position, boom_r, _up("damage", float(_w(id, "damage"))))
				main.fx.explosion(hit.position, boom_r)
				main.sfx.play_at("explode", hit.position)
	var sh: Array = _w(id, "shove")
	if sh.size() == 3:   # a blast big enough to knock the front row back
		main.zombies.shove(main.player.position, _flat_aim(), sh[0], sh[1], sh[2])

func _fire_stream(id: String) -> void:
	var fwd := _aim()
	main.fx.water(fwd, 26.0)
	if _shots % 3 != 0:
		return
	# every third tick: hurt what is inside the cone a little, and push it back a lot
	var reach: float = _up("hose_reach", float(_w(id, "reach")))
	var cos_arc := cos(deg_to_rad(float(_w(id, "arc")) * 0.5))
	var from: Vector3 = main.cam.global_position
	var dmg := damage_of(id)
	var n := 0
	for z in main.zombies.list.duplicate():
		if z.dead:
			continue
		var c: Vector3 = z.rig.position + Vector3(0, 1.0, 0)
		var d := c - from
		var dist := d.length()
		if dist < reach and (dist < 1.5 or fwd.dot(d / dist) > cos_arc):
			main.zombies.hit(z, dmg, false, c - fwd * 0.3, fwd)
			n += 1
			if n <= 2:
				main.fx.water_splash(c)
	main.zombies.shove(main.player.position, _flat_aim(), reach, float(_w(id, "arc")), _up("hose_force", float(_w(id, "force"))))

func _swing() -> void:
	var id := current
	_fire_cd = cooldown_of(id)
	_swing_t = 0.3
	fired.emit(id)
	main.sfx.play(_w(id, "snd"), randf_range(0.92, 1.08))
	var f := _flat_aim()
	var reach: float = _up("melee_reach", float(_w(id, "reach")))
	var arc: float = _w(id, "arc")
	var cos_arc := cos(deg_to_rad(arc * 0.5))
	var origin: Vector3 = main.player.position
	var hits: Array = []
	var aimed = null
	var best := -2.0
	for z in main.zombies.list:
		if z.dead:
			continue
		var d: Vector3 = z.rig.position - origin
		d.y = 0
		var l := d.length()
		var dot := f.dot(d / l) if l > 0.01 else 1.0
		if l < reach and (l < 0.7 or dot > cos_arc):
			hits.append(z)
			if dot > best:
				best = dot
				aimed = z
	var dmg := damage_of(id)
	for z in hits:
		# the zombie you are looking at takes it on the head: that is the bonk
		if z == aimed:
			main.zombies.hit(z, dmg * 1.5, true, z.rig.head_position(), f)
		else:
			main.zombies.hit(z, dmg, false, z.rig.position + Vector3(0, 1.1, 0), f)
	main.zombies.shove(origin, f, reach, arc, float(_w(id, "force")))
	main.fx.on_swing(hits.size())
	if not hits.is_empty():
		main.sfx.play("pan_hit", randf_range(0.92, 1.08))

# ---------------------------------------------------------------- projectiles

func _launch(kind: String, from: Vector3, vel: Vector3, dmg: float, radius: float) -> void:
	var p: Dictionary = _proj[0]
	for c in _proj:   # a free one, or else the oldest
		if not c.live:
			p = c
			break
		if c.t > p.t:
			p = c
	var node: MeshInstance3D = p.node
	node.mesh = GunModels.prop(kind)
	node.position = from
	node.visible = true
	p.live = true
	p.kind = kind
	p.pos = from
	p.vel = vel
	p.t = 0.0
	p.dmg = dmg
	p.r = radius
	p.trail = 0.0
	p.target = null
	p.seek = 0.0

func _fire_projectile(id: String) -> void:
	var cam: Camera3D = main.cam
	var cb := cam.global_transform.basis
	var fwd := -cb.z
	var from := cam.global_position + fwd * 0.7 + cb.x * 0.15 - cb.y * 0.12
	var kind: String = _w(id, "proj")
	var speed: float = _w(id, "speed")
	var r := blast_of(float(_w(id, "blast")))
	if kind == "pigeon":
		var birds := int(_up("flock", 1.0))
		for i in birds:
			var d := fwd if birds == 1 else fwd.rotated(cb.y, (i - (birds - 1) * 0.5) * 0.3)
			_launch(kind, from, d * speed + Vector3(0, 1.5, 0), damage_of(id), r)
	else:
		_launch(kind, from, fwd * speed + Vector3(0, 2.0, 0), damage_of(id), r)

# Throw a bottle of hot sauce: a blast, then a burning puddle. On a cooldown, no ammo.
func throw_sauce() -> void:
	if not _playing() or throw_t > 0.0:
		return
	throw_t = throw_time()
	_throw_anim = 0.3
	var cb: Basis = main.cam.global_transform.basis
	_launch("bottle", main.cam.global_position - cb.z * 0.6 - cb.x * 0.2, -cb.z * 17.0 + Vector3(0, 4.5, 0),
		_up("damage", SAUCE.damage) * damage_mult(), blast_of(SAUCE.blast))
	main.sfx.play("throw")

func _nearest_zombie(pos: Vector3, max_d: float) -> Variant:
	var best = null
	var best_d := max_d * max_d
	for z in main.zombies.list:
		if z.dead:
			continue
		var d: float = (z.rig.position + Vector3(0, 1.0, 0)).distance_squared_to(pos)
		if d < best_d:
			best_d = d
			best = z
	return best

func _update_projectiles(dt: float) -> void:
	var space: PhysicsDirectSpaceState3D = null
	for p in _proj:
		if not p.live:
			continue
		if space == null:
			space = main.get_world_3d().direct_space_state
		p.t += dt
		var pos: Vector3 = p.pos
		var vel: Vector3 = p.vel
		var kind: String = p.kind
		var boom := false
		if kind == "pigeon":
			# homing: pick the nearest zombie now and then, and turn towards its chest
			p.seek -= dt
			if p.seek <= 0.0 or (p.target != null and p.target.dead):
				p.seek = 0.25
				p.target = _nearest_zombie(pos + vel.normalized() * 4.0, 28.0)
			if p.target != null:
				var chest: Vector3 = p.target.rig.position + Vector3(0, 1.1, 0)
				var to := chest - pos
				if to.length() < 0.9:
					boom = true
				else:
					var sp := vel.length()
					vel = vel.normalized().lerp(to.normalized(), clampf(7.0 * dt, 0.0, 1.0)).normalized() * sp
			else:
				vel.y = lerpf(vel.y, 0.0, clampf(3.0 * dt, 0.0, 1.0))
		else:
			vel.y -= (14.0 if kind == "hotdog" else 18.0) * dt
		var to_pos := pos + vel * dt
		var at := to_pos
		if not boom:
			var q := PhysicsRayQueryParameters3D.create(pos, to_pos)
			q.exclude = [main.player.get_rid()]
			q.collide_with_areas = true
			var hit: Dictionary = space.intersect_ray(q)
			if not hit.is_empty():
				boom = true
				at = hit.position
			elif to_pos.y < 0.15:
				boom = true
				at = Vector3(to_pos.x, 0.15, to_pos.z)
			elif p.t > (3.5 if kind == "pigeon" else 6.0):
				boom = true
		if boom:
			_explode(p, at)
			continue
		p.pos = to_pos
		p.vel = vel
		var node: MeshInstance3D = p.node
		var dir := vel.normalized()
		var b := Basis.looking_at(dir, Vector3.UP if absf(dir.y) < 0.95 else Vector3.RIGHT)
		if kind == "pigeon":
			b = b * Basis(Vector3(0, 0, 1), sin(p.t * 30.0) * 0.5)   # flapping, more or less
		elif kind == "hotdog":
			b = b * Basis(Vector3(1, 0, 0), p.t * 9.0)
		else:
			b = b * Basis(Vector3(1, 0, 0), p.t * 14.0)
		node.transform = Transform3D(b * (1.6 if kind != "bottle" else 1.3), to_pos)
		p.trail -= dt
		if p.trail <= 0.0:
			p.trail = 0.06
			match kind:
				"hotdog": main.fx.trail(to_pos, Color(0.6, 0.57, 0.6), 0.14)
				"pigeon": main.fx.trail(to_pos, Color(0.9, 0.9, 0.95), 0.07)
				_: main.fx.trail(to_pos, Color(1.0, 0.4, 0.1), 0.08)

func _explode(p: Dictionary, at: Vector3) -> void:
	p.live = false
	p.node.visible = false
	var r: float = p.r
	# zombies.damage_radius measures from the zombies' feet, so centre the damage near the ground
	var feet := Vector3(at.x, maxf(at.y - 1.0, 0.0), at.z)
	main.zombies.damage_radius(feet, r, p.dmg)
	main.fx.explosion_colored(at, r, false)
	match p.kind:
		"hotdog":
			main.sfx.play_at("explode", at)
			main.fx.gibs(at, Color(1.0, 0.85, 0.15), 5, Vector3.ZERO)
		"pigeon":
			main.sfx.play_at("pigeon_pop", at)
			main.fx.feathers(at)
		_:
			main.sfx.play_at("glass", at)
			main.sfx.play_at("explode", at, 1.3)
			var pd: Dictionary = _puddles[0] if _puddles[0].t <= _puddles[1].t else _puddles[1]
			pd.t = SAUCE.burn_time
			pd.pos = Vector3(at.x, 0.0, at.z)
			pd.tick = SAUCE.burn_tick
			pd.fx = 0.0

func _update_puddles(dt: float) -> void:
	for pd in _puddles:
		if pd.t <= 0.0:
			continue
		pd.t -= dt
		pd.tick -= dt
		pd.fx -= dt
		var r: float = SAUCE.burn_r * _up("blast_mult", 1.0)
		if pd.fx <= 0.0:
			pd.fx = 0.13
			main.fx.fire_patch(pd.pos, r)
		if pd.tick <= 0.0:
			pd.tick = SAUCE.burn_tick
			main.zombies.damage_radius(pd.pos, r, _up("damage", SAUCE.burn_dmg) * damage_mult())

# ---------------------------------------------------------------- bonk meter

func _on_killed(info: Dictionary) -> void:
	if frenzy_t > 0.0:
		return
	bonk += (BONK_KILL + (BONK_HEAD if info.get("headshot", false) else 0.0)) * _up("bonk_gain", 1.0)
	if bonk >= 1.0:
		bonk = 0.0
		frenzy_t = FRENZY_TIME
		main.upgrades.set_temp("frenzy", {"shove_cd": 0.5, "dash_cd": 0.6})
		main.sfx.play("frenzy")
		main.fx.power_burst(Color(1.0, 0.45, 0.8))
		_toast("BONK FRENZY!", Color(1.0, 0.45, 0.8))

# ---------------------------------------------------------------- model animation

func _animate(dt: float) -> void:
	var id := current
	var m: Node3D = _models[id]
	_recoil = lerp(_recoil, 0.0, dt * 12)
	_throw_anim = maxf(_throw_anim - dt, 0.0)
	_swing_t = maxf(_swing_t - dt, 0.0)
	# the holder: recoil slide and muzzle climb, or tipped up while reloading (fx owns x / y / yaw / roll)
	gun.position.z = -0.45 + _recoil * 0.15
	var tip := minf(1.0, minf(reload_frac(), 1.0 - reload_frac()) * 8.0 + 0.3) if reloading > 0 else 0.0
	gun.rotation.x = -0.55 * tip if reloading > 0 else _recoil * 0.5
	# the model inside it: drawn up from below after a switch, dipped while throwing
	var rest: Vector3 = _w(id, "rest")
	var down := ease(_switch_t / SWITCH_TIME, 2.0) * 0.5 + sin(_throw_anim / 0.3 * PI) * 0.25
	m.position = Vector3(0, -down - 0.16 * tip, 0)
	m.rotation = rest + Vector3(-down * 1.2, 0, 0)
	var part := m.get_node_or_null("Part") as Node3D
	match id:
		"shotgun":
			if _pump_t > 0:
				_pump_t = maxf(_pump_t - dt, 0.0)
				Models.gun_pump(m, sin(PI * (1.0 - _pump_t / 0.25)))
		"revolver":
			part.rotation.z = lerp_angle(part.rotation.z, _spin, clampf(dt * 18.0, 0.0, 1.0))
		"smg":
			m.position += Vector3(randf_range(-1, 1), randf_range(-1, 1), 0) * 0.006 * _recoil
		"hydrant":
			if _fire_cd > -0.05 and ammo > 0:
				m.position += Vector3(randf_range(-1, 1), randf_range(-1, 1), 0) * 0.005
		"skewer", "launcher", "pigeon":
			# the loaded round disappears with the shot and comes back when the next is ready
			part.visible = ammo > 0 and reloading <= 0 and _fire_cd < cooldown_of(id) * 0.45
		"pan":
			if _swing_t > 0.0:
				var k := 1.0 - _swing_t / 0.3
				var s := sin(minf(k * 1.6, 1.0) * PI)   # out fast, back slower
				m.rotation = rest + Vector3(-1.5 * s, 1.5 * s, 0.6 * s)
				m.position += Vector3(-0.25 * s, 0.05 * s, -0.12 * s)
