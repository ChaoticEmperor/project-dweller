extends Node3D
# Things that fall from the sky for the player to grab. main.gd calls update(dt) every
# frame while playing.
#
#   Wave reward - when a wave ends a weapon crate slams down a few steps from the player
#     (in front of them if there is room). It holds a random weapon: simpler guns in the
#     early waves, never the same one twice in a row. It stays until it is taken or the
#     next reward crate replaces it, so it can still be grabbed during the next wave.
#   Airdrops - now and then during a wave a parachute crate comes down 14-34 m away, marked
#     by smoke and a beam of light. It holds ammo, health, a power-up for a few seconds, or
#     (rarely) a weapon, and it is gone again 28 s after landing.
#
# Walk into a crate to take it. A weapon you already carry gives spare ammo. With every
# slot full, a new weapon is not taken automatically: the HUD shows what would be swapped
# and the player confirms (controls.grab: C / the GRAB touch button / d-pad down).
#
# Drops are placed with L.clamp_to_streets + main.nav.is_blocked only (plus a ray cast
# straight down for the height of the ground), so they keep working whatever the map is.
# Three drop objects exist for the whole game (crate, parachute and beam meshes each):
# nothing is created during play.
const L = preload("res://layout.gd")
const GunModels = preload("res://gun_models.gd")

const GOLD := Color(1.0, 0.82, 0.25)
const SKY := Color(0.4, 0.86, 1.0)
const PICK_R := 1.7             # walk this close (horizontally) to take a crate
const PROMPT_R := 2.6           # ... or this close to be offered a swap
const CRATE_FALL := 24.0        # m/s, the reward crate (no parachute: it is in a hurry)
const CHUTE_FALL := 5.0         # m/s, airdrops
const AIRDROP_LIFE := 28.0      # seconds an airdrop waits on the ground
const AIRDROP_FIRST := [10.0, 18.0]   # seconds into a wave before its first airdrop
const AIRDROP_GAP := [30.0, 50.0]     # ... and between later ones
const HEAL := 40.0
const POWERUPS := {
	"damage": {"name": "DOUBLE DAMAGE", "time": 12.0, "color": Color(0.96, 0.27, 0.27)},
	"ammo": {"name": "BOTTOMLESS AMMO", "time": 10.0, "color": Color(1.0, 0.86, 0.22)},
	"speed": {"name": "ESPRESSO RUSH", "time": 12.0, "color": Color(0.4, 0.86, 1.0),
		"mods": {"move_speed": 1.35, "dash_cd": 0.6}},
}

var main: Node3D
var last_weapon := ""           # what the previous reward crate held
var _drops: Array = []          # [0] = the wave reward crate, [1] and [2] = airdrops
var _powers := {}               # power-up id -> seconds left
var _power_list: Array = []
var _marker_list: Array = []
var _air_t := -1.0              # seconds until the next airdrop (<0: none planned)
var _wave_on := false
var _wired := false
var _prompt := {}
var _rng := RandomNumberGenerator.new()

func setup(main_node: Node3D) -> void:
	main = main_node
	_rng.randomize()
	var beams := [_beam_mesh(GOLD), _beam_mesh(SKY)]
	for i in 3:
		var root := Node3D.new()
		root.visible = false
		add_child(root)
		var crate := MeshInstance3D.new()
		crate.mesh = GunModels.prop("crate")
		root.add_child(crate)
		var chute := MeshInstance3D.new()
		chute.mesh = GunModels.prop("chute")
		root.add_child(chute)
		var beam := MeshInstance3D.new()
		beam.mesh = beams[0 if i == 0 else 1]
		beam.material_override = main.fx.additive_material()
		add_child(beam)
		beam.visible = false
		for mi in [crate, chute, beam]:
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_drops.append({"root": root, "crate": crate, "chute": chute, "beam": beam, "state": 0, "kind": "crate" if i == 0 else "airdrop",
			"content": {}, "pos": Vector3.ZERO, "y": 0.0, "t": 0.0, "fx": 0.0, "pulse": 0.0, "color": GOLD})
	main.wave_started.connect(_on_wave_started)
	main.wave_ended.connect(_on_wave_ended)

# Two crossed, very tall quads that fade out towards the top (drawn additively).
func _beam_mesh(c: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var lo := Color(c.r * 0.34, c.g * 0.34, c.b * 0.34)
	var hi := Color(0, 0, 0)
	for k in 2:
		var side := Vector3(0.42, 0, 0) if k == 0 else Vector3(0, 0, 0.42)
		var pts := [[-side, lo], [side, lo], [side + Vector3(0, 45, 0), hi], [-side + Vector3(0, 45, 0), hi]]
		for j in [0, 1, 2, 0, 2, 3]:
			st.set_color(pts[j][1])
			st.add_vertex(pts[j][0])
	return st.commit()

# ---------------------------------------------------------------- what other scripts read

# Is this power-up running? ids: "damage", "ammo", "speed".
func power(id: String) -> bool:
	return float(_powers.get(id, 0.0)) > 0.0

# Running power-ups for the HUD: [{id, name, color, left (s), frac (1 -> 0)}].
func powerups() -> Array:
	_power_list.clear()
	for id in _powers:
		if _powers[id] > 0.0:
			var p: Dictionary = POWERUPS[id]
			_power_list.append({"id": id, "name": p.name, "color": p.color, "left": _powers[id], "frac": _powers[id] / float(p.time)})
	return _power_list

# Every drop in the world for the HUD's markers:
# [{pos (world, top of the crate), kind "crate" | "airdrop", label, color, left (s before it is gone, -1 = stays), falling}].
func markers() -> Array:
	_marker_list.clear()
	for d in _drops:
		if d.state == 0:
			continue
		var left := -1.0
		if d.kind == "airdrop" and d.state == 2:
			left = AIRDROP_LIFE - float(d.t)
		_marker_list.append({"pos": Vector3(d.pos.x, float(d.y) + 1.3, d.pos.z), "kind": d.kind, "color": d.color,
			"label": "WEAPON" if d.kind == "crate" else "AIRDROP", "left": left, "falling": d.state == 1})
	return _marker_list

# The swap the player is being offered right now: {text, color} or {} when there is none.
func prompt() -> Dictionary:
	return _prompt

# ---------------------------------------------------------------- when things drop

func _on_wave_started(n: int) -> void:
	_wave_on = true
	_air_t = _rng.randf_range(AIRDROP_FIRST[0], AIRDROP_FIRST[1]) + (6.0 if n == 1 else 0.0)

func _on_wave_ended(n: int) -> void:
	_wave_on = false
	_air_t = -1.0
	var d: Dictionary = _drops[0]
	if d.state != 0:
		_remove(d, true)
	var id := roll_weapon(n, last_weapon)
	last_weapon = id
	var spot := _reward_spot()
	_spawn(d, spot, {"type": "weapon", "id": id}, GOLD, 22.0)
	_toast("WEAPON CRATE!", GOLD)

# A random found weapon for wave n's crate. Weighted by the table in weapons.gd (each weapon
# has a first wave and a weight); weapons already carried come up less often; never `avoid`.
func roll_weapon(n: int, avoid := "") -> String:
	var W: Dictionary = main.weapons.W
	var ids: Array = []
	var weights: Array = []
	var total := 0.0
	for id in W:
		var w: Dictionary = W[id]
		var first: int = w.get("wave", 99)
		var wt: float = w.get("weight", 0.0)
		if wt <= 0.0 or n < first or id == avoid:
			continue
		if n < first + 2:
			wt *= 0.6          # a newly unlocked weapon starts out rarer
		if main.weapons.has(id):
			wt *= 0.35
		ids.append(id)
		weights.append(wt)
		total += wt
	if ids.is_empty():
		return "revolver"
	var r := _rng.randf() * total
	for i in ids.size():
		r -= weights[i]
		if r < 0.0:
			return ids[i]
	return ids[ids.size() - 1]

func _roll_airdrop() -> Dictionary:
	var wp: Node = main.weapons
	var needs_ammo := false
	for id in wp.owned:
		var cap: int = wp.reserve_cap(id)
		if cap > 0 and int(wp.reserves.get(id, 0)) < cap:
			needs_ammo = true
	var hurt: bool = main.hp < main.stat("max_hp") * 0.5
	var opts := [["ammo", 3.0 if needs_ammo else 0.0], ["health", 5.0 if hurt else 2.0], ["power", 3.5],
		["weapon", 1.5 if main.wave >= 2 else 0.0]]
	var total := 0.0
	for o in opts:
		total += o[1]
	var r := _rng.randf() * total
	var type := "power"
	for o in opts:
		r -= o[1]
		if r < 0.0:
			type = o[0]
			break
	match type:
		"weapon":
			return {"type": "weapon", "id": roll_weapon(main.wave + 3, last_weapon)}
		"power":
			var keys: Array = POWERUPS.keys()
			return {"type": "power", "id": keys[_rng.randi() % keys.size()]}
	return {"type": type, "id": ""}

# ---------------------------------------------------------------- where

func _free(p: Vector3) -> bool:
	if main.nav.is_blocked(p):
		return false
	for o in [Vector3(0.8, 0, 0), Vector3(-0.8, 0, 0), Vector3(0, 0, 0.8), Vector3(0, 0, -0.8)]:
		if main.nav.is_blocked(p + o):
			return false
	return true

# A free street spot between min_d and max_d metres from the player; null if none was found.
# `toward` (optional, flat unit vector): only look within about 70 degrees of that direction.
func find_spot(min_d: float, max_d: float, toward := Vector3.ZERO, tries := 24) -> Variant:
	var pp: Vector3 = main.player.position
	for i in tries:
		var a := _rng.randf() * TAU
		if toward != Vector3.ZERO:
			a = atan2(toward.z, toward.x) + _rng.randf_range(-1.2, 1.2)
		var d := _rng.randf_range(min_d, max_d)
		var p: Vector3 = L.clamp_to_streets(Vector3(pp.x + cos(a) * d, 0, pp.z + sin(a) * d), 2.0)
		p.y = 0.0
		var dist := Vector2(p.x - pp.x, p.z - pp.z).length()
		if dist < min_d * 0.75 or dist > max_d or not _free(p):
			continue
		return p
	return null

func _reward_spot() -> Vector3:
	var f: Vector3 = -main.player.global_transform.basis.z
	f.y = 0.0
	f = f.normalized()
	var spot = find_spot(5.0, 10.0, f, 16)
	if spot == null:
		spot = find_spot(3.5, 12.0)
	if spot == null:
		spot = find_spot(1.5, 20.0, Vector3.ZERO, 40)
	if spot == null:
		spot = Vector3(main.player.position.x, 0.0, main.player.position.z)   # where the player stands is street
	return spot

# Height of the ground at p (kerbs, whatever the map has), by a ray straight down.
func _ground_y(p: Vector3) -> float:
	var q := PhysicsRayQueryParameters3D.create(Vector3(p.x, 3.0, p.z), Vector3(p.x, -2.0, p.z))
	q.exclude = [main.player.get_rid()]
	var hit: Dictionary = main.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return 0.0
	return clampf(hit.position.y, 0.0, 0.6)

# ---------------------------------------------------------------- life of a drop

func _spawn(d: Dictionary, spot: Vector3, content: Dictionary, color: Color, height: float) -> void:
	d.state = 1
	d.content = content
	d.color = color
	d.pos = Vector3(spot.x, _ground_y(spot), spot.z)
	d.y = d.pos.y + height
	d.t = 0.0
	d.fx = 0.0
	d.pulse = 0.0
	var root: Node3D = d.root
	root.position = Vector3(spot.x, d.y, spot.z)
	root.rotation = Vector3(0, _rng.randf() * TAU, 0)
	root.scale = Vector3.ONE
	root.visible = true
	d.chute.visible = d.kind == "airdrop"
	d.crate.visible = true
	var beam: MeshInstance3D = d.beam
	beam.position = d.pos
	beam.visible = true

func _remove(d: Dictionary, puff: bool) -> void:
	if puff and d.state != 0:
		main.fx.crate_land(Vector3(d.pos.x, d.y, d.pos.z), d.color)
	d.state = 0
	d.root.visible = false
	d.beam.visible = false

func _try_airdrop() -> void:
	var slot = null
	for i in [1, 2]:
		if _drops[i].state == 0:
			slot = _drops[i]
			break
	if slot == null:
		return
	var spot = find_spot(14.0, 34.0)
	if spot == null:
		spot = find_spot(10.0, 40.0, Vector3.ZERO, 40)
	if spot == null:
		_air_t = 5.0   # nowhere free just now: try again shortly
		return
	_spawn(slot, spot, _roll_airdrop(), SKY, 32.0)
	main.sfx.play("airdrop")
	_toast("AIRDROP INCOMING!", SKY)

func update(dt: float) -> void:
	if not _wired and main.controls != null:
		_wired = true
		if main.controls.has_signal("grab"):
			main.controls.connect("grab", _on_grab)
	# power-ups run down
	for id in _powers:
		if _powers[id] > 0.0:
			_powers[id] -= dt
			if _powers[id] <= 0.0:
				_powers[id] = 0.0
				main.upgrades.clear_temp("power_" + id)
	# the next airdrop (not while the last few zombies are being hunted down)
	if _wave_on and _air_t >= 0.0:
		_air_t -= dt
		if _air_t <= 0.0:
			_air_t = _rng.randf_range(AIRDROP_GAP[0], AIRDROP_GAP[1])
			if main.zombies.alive_count() > 3:
				_try_airdrop()
	_prompt = {}
	var pp: Vector3 = main.player.position
	for d in _drops:
		if d.state == 0:
			continue
		var root: Node3D = d.root
		var beam: MeshInstance3D = d.beam
		d.fx -= dt
		d.pulse -= dt
		if d.state == 1:
			var chute: bool = d.kind == "airdrop"
			d.y = float(d.y) - (CHUTE_FALL if chute else CRATE_FALL) * dt
			if chute:
				d.t = float(d.t) + dt
				root.rotation.z = sin(float(d.t) * 1.7) * 0.09
				root.rotation.x = cos(float(d.t) * 1.3) * 0.06
			if d.y <= d.pos.y:
				d.y = d.pos.y
				d.state = 2
				d.t = 0.0
				root.rotation.x = 0.0
				root.rotation.z = 0.0
				d.chute.visible = false
				main.fx.crate_land(d.pos, d.color)
				main.sfx.play_at("crate_land", d.pos)
			root.position.y = d.y
		else:
			d.t = float(d.t) + dt
			# landed: a little bounce at first, then a slow turn so the "?" catches the eye
			var squash := maxf(0.0, 1.0 - float(d.t) * 4.0)
			root.scale = Vector3(1.0 + 0.2 * squash, 1.0 - 0.25 * squash, 1.0 + 0.2 * squash)
			root.rotation.y += dt * 0.6
			if d.kind == "airdrop":
				var left := AIRDROP_LIFE - float(d.t)
				if left <= 0.0:
					_remove(d, true)
					continue
				root.visible = left > 6.0 or fmod(left, 0.4) < 0.26   # blinks before it goes
		# smoke and a pulse on the ground at the landing spot; the beam breathes
		if d.fx <= 0.0:
			d.fx = 0.22
			var pulse: bool = d.pulse <= 0.0
			if pulse:
				d.pulse = 1.1
			main.fx.beacon(d.pos, d.color, pulse)
		var bw := 1.0 + 0.25 * sin(float(d.t) * 5.0 + float(d.y))
		beam.scale = Vector3(bw, 1.0, bw)
		# taking it
		var flat := Vector2(d.pos.x - pp.x, d.pos.z - pp.z).length()
		if d.y - d.pos.y < 1.2 and absf(pp.y - d.pos.y) < 2.5:
			if flat < PICK_R and _auto_take(d):
				_take(d)
			elif flat < PROMPT_R and d.content.type == "weapon" and not main.weapons.can_take(d.content.id):
				var W: Dictionary = main.weapons.W
				_prompt = {"text": "SWAP %s FOR %s" % [W[main.weapons.replace_target()].name, W[d.content.id].name],
					"color": W[d.content.id].color, "drop": d}

func _auto_take(d: Dictionary) -> bool:
	return d.content.type != "weapon" or main.weapons.can_take(d.content.id)

func _on_grab() -> void:
	if _prompt.is_empty() or not main.started or main.dead or main.drafting:
		return
	var d: Dictionary = _prompt.drop
	_prompt = {}
	if d.state != 0:
		_take(d)

func _take(d: Dictionary) -> void:
	var c: Dictionary = d.content
	var col: Color = d.color
	match c.type:
		"weapon":
			var w: Dictionary = main.weapons.W[c.id]
			col = w.color
			if main.weapons.has(c.id):
				_toast("+AMMO: %s" % w.name, col)
				main.sfx.play("ammo")
			else:
				_toast("NEW WEAPON: %s" % w.name, col)
				main.sfx.play("pickup")
			main.weapons.give(c.id)
		"ammo":
			if main.weapons.add_ammo(0.5):
				_toast("AMMO FOR EVERYTHING!", POWERUPS.ammo.color)
				main.sfx.play("ammo")
			else:   # nothing needed any: do not waste the trip
				_heal(HEAL * 0.5)
		"health":
			_heal(HEAL)
		"power":
			give_power(c.id)
			col = POWERUPS[c.id].color
	main.fx.pickup(d.pos, col)
	_remove(d, false)

func _heal(amount: float) -> void:
	main.hp = minf(main.hp + amount, main.stat("max_hp"))
	_toast("+%d HEALTH" % int(amount), Color(0.47, 0.92, 0.36))
	main.sfx.play("heal")

# Start (or restart) a power-up: "damage" (x2), "ammo" (nothing uses ammo), "speed".
func give_power(id: String) -> void:
	if not POWERUPS.has(id):
		return
	var p: Dictionary = POWERUPS[id]
	_powers[id] = float(p.time)
	if p.has("mods"):
		main.upgrades.set_temp("power_" + id, p.mods)
	main.sfx.play("powerup")
	main.fx.power_burst(p.color)
	_toast("%s!" % p.name, p.color)

func _toast(text: String, col: Color) -> void:
	if main.hud != null and main.hud.has_method("toast"):
		main.hud.toast(text, col)

# Remove everything (restart).
func clear() -> void:
	for d in _drops:
		_remove(d, false)
	for id in _powers:
		main.upgrades.clear_temp("power_" + id)
	_powers.clear()
	_prompt = {}
	_air_t = -1.0
	_wave_on = false
