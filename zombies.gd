extends Node3D
# Everything about zombies as game objects: types, spawning, wave pacing, movement,
# attacks, taking damage and dying. main.gd tells it when a wave starts and reports
# bullet hits; it reports back through signals. See SPECS.md for the frozen API.
const L = preload("res://layout.gd")
const Models = preload("res://models.gd")

signal zombie_hit(pos: Vector3, dir: Vector3, headshot: bool)
# info: { "pos", "head_pos", "dir", "headshot", "type", "skin", "score_mult" }
signal zombie_killed(info: Dictionary)
signal player_hit(dmg: float, from_pos: Vector3)
signal wave_cleared(wave: int)

const NAMES := ["Zombie McBite-Face", "Gary", "Brainy Bob", "Sir Groans-a-Lot", "Chompers",
	"Moaning Myrtle-ish", "Undead Ted", "Lil' Rotty", "Karen (Deceased)", "Big Steve"]

var main: Node3D           # main.gd: read main.player (CharacterBody3D), main.nav, main.fx, main.sfx
var list: Array = []       # live zombies (Dictionaries)
var wave := 0
var _to_spawn := 0
var _spawn_t := 0.0
var _active := false
var _rng := RandomNumberGenerator.new()

func setup(main_node: Node3D) -> void:
	main = main_node
	_rng.randomize()

# Begin wave n (1-based). Emits wave_cleared(n) once every zombie of the wave is dead.
func start_wave(n: int) -> void:
	wave = n
	_to_spawn = 4 + n * 3
	_spawn_t = 1.5
	_active = true

func alive_count() -> int:
	return list.size() + _to_spawn

# Remove every zombie (used on restart).
func clear() -> void:
	for z in list:
		z.rig.queue_free()
	list.clear()
	_to_spawn = 0
	_active = false

func _spawn() -> void:
	var player: Node3D = main.player
	var pts: Array = L.spawn_points().filter(func(p): return p.distance_to(player.position) > 12.0)
	if pts.is_empty():
		pts = L.spawn_points()
	var pos: Vector3 = L.clamp_to_streets(pts[_rng.randi() % pts.size()] + Vector3(_rng.randf_range(-1.5, 1.5), 0, _rng.randf_range(-1.5, 1.5)), 1.0)
	var big := _rng.randf() < 0.12 and wave > 2
	var type := "sanitation" if big else "commuter"
	var rig: Node3D = Models.make_zombie(type, _rng)
	add_child(rig)
	rig.position = pos
	rig.set_label(NAMES[_rng.randi() % NAMES.size()])
	var z := {"rig": rig, "type": type, "hp": (150.0 if big else 50.0) + wave * 5,
		"speed": (2.2 if big else _rng.randf_range(3.0, 4.5)) + wave * 0.2,
		"atk": 0.0, "dead": false, "score_mult": 3 if big else 1, "dmg": 20.0 if big else 10.0}
	for sh in rig.hit_shapes():
		var a := Area3D.new()
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = sh.size
		cs.shape = bs
		a.add_child(cs)
		a.position = sh.pos
		a.set_meta("zombie", z)
		a.set_meta("head", sh.head)
		rig.add_child(a)
	list.append(z)
	main.fx.zombie_spawn(pos)
	main.sfx.play_at("zombie_spawn", pos)

# A bullet (or anything else) hit zombie `z` (the value of the Area3D's "zombie" meta).
func hit(z: Dictionary, dmg: float, headshot: bool, pos: Vector3, dir: Vector3) -> void:
	if z.dead:
		return
	z.hp -= dmg
	var rig: Node3D = z.rig
	rig.flinch(dir, 0.6)
	rig.flash()
	rig.position += Vector3(dir.x, 0, dir.z).normalized() * 0.25  # knockback
	zombie_hit.emit(pos, dir, headshot)
	if z.hp <= 0:
		_kill(z, dir, headshot)

func _kill(z: Dictionary, dir: Vector3, headshot: bool) -> void:
	z.dead = true
	var rig: Node3D = z.rig
	var info := {"pos": rig.position, "head_pos": rig.head_position(), "dir": dir, "headshot": headshot,
		"type": z.type, "skin": rig.skin, "score_mult": z.score_mult}
	if headshot:
		rig.pop_head()
		rig.set_label("BONK!", Color(1, 0.9, 0.2))
	else:
		rig.set_label(["oof", "ow", "bleh", "x_x"][_rng.randi() % 4], Color(1, 0.9, 0.2))
	var t: float = rig.die(dir, headshot)
	get_tree().create_timer(t).timeout.connect(rig.queue_free)
	list.erase(z)
	zombie_killed.emit(info)

# Push back / stagger every zombie in a cone in front of `origin`. Returns how many were hit.
func shove(origin: Vector3, forward: Vector3, reach: float, arc_deg: float, force: float) -> int:
	var n := 0
	var f := Vector3(forward.x, 0, forward.z).normalized()
	for z in list:
		var d: Vector3 = z.rig.position - origin
		d.y = 0
		if d.length() < reach and (d.length() < 0.6 or f.dot(d.normalized()) > cos(deg_to_rad(arc_deg * 0.5))):
			z.rig.position = L.clamp_to_streets(z.rig.position + f * force * 0.4, 0.6)
			z.rig.flinch(f, 1.0)
			z.atk = max(z.atk, 0.8)
			n += 1
	return n

# Damage every zombie within `radius` of `pos` (explosions). Returns how many were hit.
func damage_radius(pos: Vector3, radius: float, dmg: float) -> int:
	var n := 0
	for z in list.duplicate():
		var d: Vector3 = z.rig.position - pos
		if d.length() < radius:
			hit(z, dmg, false, z.rig.position + Vector3(0, 1, 0), d.normalized() if d.length() > 0.01 else Vector3.FORWARD)
			n += 1
	return n

# Called by main every frame while the game is running.
func update(dt: float) -> void:
	var player: Node3D = main.player
	var nav = main.nav
	if _to_spawn > 0:
		_spawn_t -= dt
		if _spawn_t <= 0:
			_spawn()
			_to_spawn -= 1
			_spawn_t = max(0.25, 1.2 - wave * 0.1)
	elif list.is_empty() and _active:
		_active = false
		wave_cleared.emit(wave)
	for z in list:
		var rig: Node3D = z.rig
		var to: Vector3 = nav.direction(rig.position, player.position)
		var to_player: Vector3 = player.position - rig.position
		to_player.y = 0
		var d := to_player.length()
		if d < 2.0:
			to = to_player.normalized()
		if to.length() > 0.1:
			rig.rotation.y = lerp_angle(rig.rotation.y, atan2(-to.x, -to.z), 1.0 - exp(-10.0 * dt))
		var push := Vector3.ZERO
		for o in list:
			if o != z:
				var off: Vector3 = rig.position - o.rig.position
				off.y = 0
				if off.length() < 0.8 and off.length() > 0.001:
					push += off.normalized() * (0.8 - off.length())
		var moving := 0.0
		if d > 1.1:
			var step: Vector3 = to * z.speed * dt + push * 3 * dt
			var np: Vector3 = rig.position + step
			if nav.is_blocked(np) and not nav.is_blocked(rig.position):
				var sx := rig.position + Vector3(step.x, 0, 0)
				var sz := rig.position + Vector3(0, 0, step.z)
				if not nav.is_blocked(sx):
					np = sx
				elif not nav.is_blocked(sz):
					np = sz
				else:
					np = rig.position
			rig.position = L.clamp_to_streets(np, 0.6)
			moving = z.speed
		rig.tick(dt, moving)
		z.atk -= dt
		if d < 1.4 and z.atk <= 0:
			z.atk = 0.8
			rig.strike()
			player_hit.emit(z.dmg, rig.position)
