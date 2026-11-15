extends Node3D
# Everything about zombies as game objects: types, spawning, wave pacing, movement,
# attacks, taking damage and dying. main.gd tells it when a wave starts and reports
# bullet hits; it reports back through signals. See SPECS.md for the frozen API.
#
# How it works, in short:
#   - TYPES is one table of numbers per zombie type; behaviour differences are flags in it.
#   - Each zombie is a Dictionary with a small state machine (S_* below):
#       SPAWN -> CHASE -> WINDUP -> STRIKE -> RECOVER -> CHASE ...   (melee types)
#       CHASE -> SWELL -> explode                                    (bloater)
#       any -> STAGGER -> CHASE                                      (when hit hard / shoved)
#   - Only a few zombies may attack at once ("attack tokens"); the rest ring the player.
#   - A wave is a budget of zombies released in a few packs from different directions.
const L = preload("res://layout.gd")
const Models = preload("res://models.gd")

signal zombie_hit(pos: Vector3, dir: Vector3, headshot: bool)
# info: { "pos", "head_pos", "dir", "headshot", "type", "skin", "score_mult" }
signal zombie_killed(info: Dictionary)
signal player_hit(dmg: float, from_pos: Vector3)
signal wave_cleared(wave: int)

enum { S_SPAWN, S_CHASE, S_WINDUP, S_STRIKE, S_RECOVER, S_STAGGER, S_SWELL }

# ---- tuning: one row per zombie type -------------------------------------------------
# hp / speed (+ random speed_var) / dmg / score multiplier / cost in wave budget / first wave
# ring       distance at which a zombie without an attack token stops and circles (+ ring_var)
# atk_range  distance at which it may start an attack
# windup     telegraph seconds; creep = fraction of speed it keeps while winding up
# lunge_*    the strike: it travels lunge_speed m/s for lunge_time s in a locked direction
# reach/cone the strike connects if the player is within reach and inside the cone (dot) of the lunge
# recover    seconds it stands still after a strike (a free shot for the player)
# kb/stagger how strongly knockback and stagger affect it; poise = damage needed during the
#            wind-up to interrupt it (0 = any stagger interrupts)
# orbit      circling speed while waiting; weave/weave_hz = side-to-side wander while walking
# live_cap   most of this type alive at once; rise = entrance animation seconds
const TYPES := {
	"commuter": {"hp": 50.0, "speed": 3.0, "speed_var": 1.3, "dmg": 10.0, "score": 1, "cost": 1, "first": 1,
		"ring": 1.6, "ring_var": 0.6, "atk_range": 2.4, "windup": 0.42, "creep": 0.35,
		"lunge_speed": 7.0, "lunge_time": 0.18, "reach": 1.5, "cone": 0.25, "recover": 0.7,
		"kb": 1.0, "stagger": 1.0, "poise": 0.0, "orbit": 0.9, "weave": 0.35, "weave_hz": 0.5,
		"live_cap": 999, "rise": 0.7, "explode": false, "label": Color(1, 1, 1)},
	"delivery": {"hp": 20.0, "speed": 6.2, "speed_var": 0.8, "dmg": 8.0, "score": 2, "cost": 1, "first": 3,
		"ring": 4.2, "ring_var": 1.2, "atk_range": 6.0, "windup": 0.5, "creep": 0.0,
		"lunge_speed": 16.0, "lunge_time": 0.4, "reach": 1.25, "cone": 0.3, "recover": 0.9,
		"kb": 1.3, "stagger": 1.2, "poise": 0.0, "orbit": 3.2, "weave": 1.0, "weave_hz": 1.4,
		"live_cap": 6, "rise": 0.5, "explode": false, "label": Color(1.0, 0.6, 0.85)},
	"bloater": {"hp": 110.0, "speed": 2.3, "speed_var": 0.3, "dmg": 30.0, "score": 2, "cost": 2, "first": 6,
		"ring": 0.9, "ring_var": 0.0, "atk_range": 2.5, "windup": 0.75, "creep": 0.0,
		"lunge_speed": 0.0, "lunge_time": 0.0, "reach": 0.0, "cone": 0.0, "recover": 0.0,
		"kb": 0.6, "stagger": 0.7, "poise": 0.0, "orbit": 0.0, "weave": 0.15, "weave_hz": 0.3,
		"live_cap": 3, "rise": 0.9, "explode": true, "label": Color(0.75, 1.0, 0.3)},
	"sanitation": {"hp": 800.0, "speed": 2.3, "speed_var": 0.0, "dmg": 28.0, "score": 5, "cost": 0, "first": 5,
		"ring": 2.4, "ring_var": 0.0, "atk_range": 3.1, "windup": 1.0, "creep": 0.2,
		"lunge_speed": 5.0, "lunge_time": 0.22, "reach": 3.2, "cone": 0.0, "recover": 1.4,
		"kb": 0.2, "stagger": 0.0, "poise": 200.0, "orbit": 0.5, "weave": 0.1, "weave_hz": 0.25,
		"live_cap": 2, "rise": 1.4, "explode": false, "label": Color(1.0, 0.85, 0.2)},
}

# bloater blast: when it goes off by itself (big) and when it is shot first (smaller)
const BLAST_SELF := {"radius": 4.0, "zombie_dmg": 90.0, "player_dmg": 30.0, "player_radius": 4.0}
const BLAST_SHOT := {"radius": 2.8, "zombie_dmg": 60.0, "player_dmg": 12.0, "player_radius": 2.0}
const BLAST_DELAY := 0.12         # a shot bloater pops a beat later, so chains ripple

const LIVE_CAP_TOUCH := 28
const LIVE_CAP_DESKTOP := 40
const SPAWN_MIN_DIST := 15.0      # never spawn closer to the player than this
const SPAWN_MAX_DIST := 45.0      # ... nor further away (the city is endless)
const STRAY_DIST := 70.0          # a zombie left this far behind is moved near the player
const HURT_TOKEN_BLOCK := 1.0     # no new attacks for this long after the player was hurt
const TOKEN_GAP := 0.3            # least time between two zombies starting an attack
const WAIT_SEEN := 0.1            # how long a zombie in view must be in range before attacking
const WAIT_UNSEEN := 1.0          # ... and one the player cannot see (behind them)
const VIEW_DOT := 0.4             # cos of the half-angle counted as "the player can see it"
const LABEL_NEAREST := 8
const LABEL_RANGE := 22.0
const PLAYER_GAP := 0.8           # closest a zombie's edge may come to the player's centre
const ACCEL := 7.0                # how fast walking velocity follows what the zombie wants
const KB_DECAY := 7.0             # knockback velocity dies off at this rate (1/s)
const GRID := 48                  # separation buckets: 2 m cells over the 96 m map

const NAMES := ["Zombie McBite-Face", "Gary", "Brainy Bob", "Sir Groans-a-Lot", "Chompers",
	"Moaning Myrtle-ish", "Undead Ted", "Lil' Rotty", "Karen (Deceased)", "Big Steve",
	"Stand Clear Stan", "Showtime Shawn", "Delayed Dave", "Local Larry", "Express Ethan",
	"Metrocard Marge", "Swipe Again Sam", "Bagel Barry", "Schmear Sheila", "Bodega Bruce",
	"Pizza Rat Pat", "Dollar Slice Dee", "Jaywalkin' Jay", "Rent's Due Ruth", "Sixth Floor Walkup",
	"Brunch Line Brenda", "Open Mic Mike", "Finance Bro Chad", "Intern (Unpaid)", "Halal Cart Hal",
	"Pigeon Whisperer", "Midtown Marv", "Cab Hailer Cal", "Hey I'm Walkin' Here", "Fuhgeddabout Phil",
	"Lost Tourist", "Times Square Elmo-ish", "Bridge & Tunnel Bev", "Coffee Regular Reg", "Roommate #4",
	"Broker Fee Brad", "Stoop Sitter Sal", "Dog Walker Dawn", "Sublet Susan", "L Train Lou",
	"Chopped Cheese Chuck", "Signal Problems Sid", "Manspreader Max"]
const NAMES_DELIVERY := ["30 Min Or Less", "Extra Guac Gus", "No-Tip Tony", "Bike Lane Brad", "Wrong Order Ray",
	"Leave At Door Lenny", "Five Star Freddy", "Cold Fries Kyle", "Surge Pricing Sue"]
const NAMES_BLOATER := ["Gas Leak Greg", "Hot Dog Water Walt", "Bodega Burrito Bob", "Gyro Regret Gene",
	"Street Meat Pete", "Third Slice Theo", "Dirty Water Dan"]
const NAMES_SANITATION := ["Trash Day Trevor", "Big Sal, Local 831", "Alternate Side Al", "Bulk Pickup Bruno",
	"The Commissioner"]

var main: Node3D           # main.gd: read main.player (CharacterBody3D), main.nav, main.fx, main.sfx
var list: Array = []       # live zombies (Dictionaries)
var wave := 0
var intensity := 0.0       # 0 calm .. ~1.5 player is being mauled; delays the next pack

var _rng := RandomNumberGenerator.new()
var _active := false
var _bursts: Array = []    # packs still to release this wave: [{q: [type...], early: int}]
var _burst_i := 0
var _pending := 0          # zombies of this wave not spawned yet
var _spawn_t := 0.0
var _spawn_gap := 0.3
var _lull := 0.0           # time left before the next pack (runs slower under pressure)
var _lull_age := 0.0
var _lull_base := 4.0
var _pt := -1              # spawn point of the current pack, and a second one for big packs
var _pt2 := -1
var _pts: Array = []       # spawn points on offer for the current pack: [{pos, subway}]
var _last_pos := Vector3(1e9, 0, 1e9)   # where the previous pack came from
var _reloc_t := 0.0
var _burst_n := 0
var _live := {}            # type -> how many alive
var _booms: Array = []     # delayed bloater blasts: [{pos, t, blast}]
var _time := 0.0
var _frame := 0
var _hurt_block := 0.0
var _grant_cd := 0.0
var _label_t := 0.0
var _groan_t := 2.0
# scratch arrays reused every frame (no per-frame allocation)
var _px := PackedFloat32Array()
var _pz := PackedFloat32Array()
var _rad := PackedFloat32Array()
var _next := PackedInt32Array()
var _cell_head := PackedInt32Array()
var _d2 := PackedFloat32Array()

func setup(main_node: Node3D) -> void:
	main = main_node
	_rng.randomize()
	_cell_head.resize(GRID * GRID)

# ---- waves -----------------------------------------------------------------------------

# Begin wave n (1-based). Emits wave_cleared(n) once every zombie of the wave is dead.
func start_wave(n: int) -> void:
	wave = n
	_bursts = _compose(n)
	_pending = 0
	for b in _bursts:
		_pending += b.q.size()
	_burst_i = 0
	_pt = -1
	_spawn_t = 1.5
	_spawn_gap = 0.5 if n <= 2 else 0.3
	_lull_base = max(2.0, 4.5 - 0.15 * n)
	_active = true

# How many zombies wave n is worth (a commuter costs 1).
func wave_budget(n: int) -> int:
	return mini(int(6 + 3 * n + 0.12 * n * n), 110)

# Build the packs for wave n: which types, in which pack, in which order.
func _compose(n: int) -> Array:
	var budget := wave_budget(n)
	var boss := n % 5 == 0
	if boss:
		budget = int(budget * 0.65)
	var n_del := 0
	var n_blo := 0
	if n >= 4:
		n_del = int(round(budget * min(0.12 + 0.025 * (n - 4), 0.32)))
	if n == 6:
		n_blo = 1
	elif n >= 7:
		n_blo = maxi(1, int(round(budget * min(0.10 + 0.02 * (n - 7), 0.28) / TYPES.bloater.cost)))
	if boss:  # the boss is the star: wave 5 is commuters only, later boss waves a lighter mix
		n_del = 0 if n == 5 else n_del / 2
		n_blo = n_blo / 2
	var n_com := maxi(budget - n_del * int(TYPES.delivery.cost) - n_blo * int(TYPES.bloater.cost), 3)
	var total := n_com + n_del + n_blo
	var nb := clampi(2 + total / 12, 2, 4) if n < 12 else clampi(total / 14, 4, 6)
	var out: Array = []
	for i in nb:
		out.append({"q": [], "early": 2})
	for i in n_com:
		out[i % nb].q.append("commuter")
	# specials go to the later packs first, so each wave opens with something readable
	for i in n_del:
		out[(nb - 1 - i % nb + nb) % nb if nb > 1 else 0].q.append("delivery")
	for b in out:
		_shuffle(b.q)
	for i in n_blo:  # a bloater walks in the middle of its pack: shoot it there
		var q: Array = out[1 + i % (nb - 1)].q
		q.insert(q.size() / 2, "bloater")
	if boss:
		for i in (2 if n >= 20 else 1):
			out[mini(1 + i, nb - 1)].q.insert(0, "sanitation")
	if n == 3:  # first meeting with the delivery zombie: a pair, on their own
		out.insert(0, {"q": ["delivery", "delivery"], "early": 0})
	return out

# Zombie hp grows only slowly with the wave (the gun should keep feeling strong).
func _hp_scale() -> float:
	return min(1.0 + 0.03 * (wave - 1), 1.6)

func _shuffle(a: Array) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := _rng.randi() % (i + 1)
		var t = a[i]
		a[i] = a[j]
		a[j] = t

func live_cap() -> int:
	return LIVE_CAP_TOUCH if main.controls != null and main.controls.touch_mode else LIVE_CAP_DESKTOP

func alive_count() -> int:
	return list.size() + _pending

# Remove every zombie (used on restart).
func clear() -> void:
	for z in list:
		z.dead = true
		z.rig.queue_free()
	list.clear()
	_live.clear()
	_bursts.clear()
	_booms.clear()
	_pending = 0
	_active = false
	intensity = 0.0

# Release the wave's packs: zombies of a pack come out quickly one after another, then
# there is a lull (longer while the player is being hurt) before the next pack.
func _run_spawner(dt: float, ppos: Vector3, camf: Vector3) -> void:
	if _burst_i >= _bursts.size():
		return
	var b: Dictionary = _bursts[_burst_i]
	var q: Array = b.q
	if q.is_empty():
		_lull -= dt * (0.25 if intensity > 0.5 else 1.0)
		_lull_age += dt
		if _lull <= 0.0 or _lull_age > 14.0 or (_lull_age > 1.0 and list.size() <= int(b.early)):
			_burst_i += 1
			_pt = -1
		return
	_spawn_t -= dt
	if _spawn_t > 0.0 or list.size() >= live_cap():
		return
	var qi := -1
	for i in q.size():
		if int(_live.get(q[i], 0)) < int(TYPES[q[i]].live_cap):
			qi = i
			break
	if qi < 0:
		# only capped specials left in this pack: hand them to the next pack, or wait for room
		if _burst_i + 1 < _bursts.size() and _pt >= 0:
			_bursts[_burst_i + 1].q.append_array(q)
			q.clear()
			_lull = _lull_base
			_lull_age = 0.0
		return
	if _pt >= 0:
		# endless city: the pack's spawn point goes stale when the player runs off
		var pd: float = (_pts[_pt].pos as Vector3).distance_to(ppos)
		if pd > SPAWN_MAX_DIST + 15.0 or pd < SPAWN_MIN_DIST - 5.0:
			_pt = -1
	if _pt < 0:
		_pts = main.world.spawn_points(ppos, SPAWN_MIN_DIST, SPAWN_MAX_DIST)
		if _pts.is_empty():
			_pts = [{"pos": L.clamp_to_streets(ppos + Vector3(20, 0, 0), 1.0), "subway": false}]
		_pt = _pick_point(ppos, camf, -1, -1)
		_pt2 = _pick_point(ppos, camf, -1, _pt)
		_last_pos = _pts[_pt].pos
		_burst_n = 0
	var type: String = q[qi]
	q.remove_at(qi)
	_pending -= 1
	var pt := _pt2 if (q.size() + _burst_n > 9 and _burst_n % 3 == 2) else _pt
	if type == "sanitation" and _pts[pt].subway:  # too big for a subway stairwell
		pt = _pick_point(ppos, camf, -1, -1, true)
	_burst_n += 1
	_spawn(type, pt)
	_spawn_t = _spawn_gap
	if q.is_empty():
		_lull = _lull_base
		_lull_age = 0.0

# Choose a spawn point (an index into _pts, the street spots world.gd offers round the
# player): out of sight if possible, never close, not where the last pack came from,
# otherwise the nearest (so the pack arrives soon).
func _pick_point(ppos: Vector3, camf: Vector3, avoid: int, avoid2: int, street_only := false) -> int:
	var nav = main.nav
	var best := 0
	var best_s := -1e9
	for i in _pts.size():
		var sp: Dictionary = _pts[i]
		if street_only and sp.subway:
			continue
		var p: Vector3 = sp.pos
		var to := p - ppos
		to.y = 0
		var d := to.length()
		var steps: int = nav.steps(p)
		var walk: float = float(steps) if steps >= 0 else d
		var s := -walk * 0.5 + _rng.randf_range(-6.0, 6.0)
		if d < SPAWN_MIN_DIST or walk < SPAWN_MIN_DIST:
			s -= 1000.0 - d
		if not (d > 0.01 and camf.dot(to / d) > VIEW_DOT and L.sight_clear(ppos, p)):
			s += 100.0  # the player cannot see it
		if i == avoid or i == avoid2 or p.distance_to(_last_pos) < 12.0:
			s -= 60.0
		if s > best_s:
			best_s = s
			best = i
	return best

# Endless city: a zombie the player has outrun (far behind, or cut off from the pathfinding
# window) is moved to a fresh out-of-view spawn point near the player instead of being left
# stranded, so a wave can always be finished.
func _relocate_strays(ppos: Vector3, camf: Vector3) -> void:
	var nav = main.nav
	var pts: Array = []
	for z in list:
		var p: Vector3 = z.rig.position
		var d := Vector2(p.x - ppos.x, p.z - ppos.z).length()
		var lost: bool = int(z.state) == S_CHASE and (d > STRAY_DIST or (d > 20.0 and not nav.reachable(p)))
		if not lost:
			z.lost = 0
			continue
		z.lost = int(z.get("lost", 0)) + 1
		if int(z.lost) < 4 and d <= STRAY_DIST:
			continue   # cut off: give the flow field two seconds to catch up first
		if pts.is_empty():
			pts = main.world.spawn_points(ppos, SPAWN_MIN_DIST, SPAWN_MAX_DIST)
			if pts.is_empty():
				return
		var best := -1
		var best_s := -1e9
		for i in pts.size():
			var sp: Dictionary = pts[i]
			if sp.subway and z.type == "sanitation":
				continue
			var q: Vector3 = sp.pos
			var to := q - ppos
			to.y = 0
			var qd := to.length()
			var s := _rng.randf_range(0.0, 20.0) - absf(qd - 30.0)
			if not (camf.dot(to / maxf(qd, 0.01)) > VIEW_DOT and L.sight_clear(ppos, q)):
				s += 100.0
			if s > best_s:
				best_s = s
				best = i
		if best < 0:
			continue
		var np: Vector3 = pts[best].pos
		for k in 8:
			var c: Vector3 = L.clamp_to_streets(np + Vector3(_rng.randf_range(-3.0, 3.0), 0, _rng.randf_range(-3.0, 3.0)), 1.0)
			if not nav.is_blocked(c):
				np = c
				break
		var rise: float = float(z.T.rise) + (0.5 if pts[best].subway else 0.0)
		z.rig.position = np
		z.state = S_SPAWN
		z.t = rise
		z.vel = Vector3.ZERO
		z.kb = Vector3.ZERO
		z.prog_pos = np
		z.lost = 0
		z.rig.spawn_rise(rise)
		main.fx.zombie_spawn(np)

func _spawn(type: String, pt: int) -> void:
	var T: Dictionary = TYPES[type]
	var nav = main.nav
	var base: Vector3 = _pts[pt].pos
	var pos := base
	for i in 8:
		var c: Vector3 = L.clamp_to_streets(base + Vector3(_rng.randf_range(-3.0, 3.0), 0, _rng.randf_range(-3.0, 3.0)), 1.0)
		if not nav.is_blocked(c):
			pos = c
			break
	var rig: Node3D = Models.make_zombie(type, _rng)
	add_child(rig)
	rig.position = pos
	var to_p: Vector3 = main.player.position - pos
	rig.rotation.y = atan2(-to_p.x, -to_p.z)
	var names: Array = NAMES
	match type:
		"delivery": names = NAMES_DELIVERY
		"bloater": names = NAMES_BLOATER
		"sanitation": names = NAMES_SANITATION
	rig.set_label(names[_rng.randi() % names.size()], T.label)
	rig.set_label_visible(false)
	# difficulty: mostly more zombies and nastier mixes; speed creeps up, hp only a little
	var hp: float = T.hp * _hp_scale()
	if type == "sanitation":
		hp = T.hp * (1.0 + 0.5 * (wave / 5 - 1))
	var speed: float = (T.speed + _rng.randf() * float(T.speed_var)) * (1.0 + min(0.025 * (wave - 1), 0.35))
	var rise: float = T.rise + (0.5 if _pts[pt].subway else 0.0)  # subway spawns climb the stairs
	var z := {"rig": rig, "type": type, "hp": hp, "dead": false, "score_mult": T.score, "dmg": T.dmg,
		"T": T, "state": S_SPAWN, "t": rise, "speed": speed, "areas": [],
		"ring": float(T.ring) + _rng.randf() * float(T.ring_var), "side": 1.0 if _rng.randf() < 0.5 else -1.0,
		"vel": Vector3.ZERO, "kb": Vector3.ZERO, "want": Vector3.ZERO, "head": Vector3(0, 0, -1),
		"lunge": Vector3.ZERO, "struck": false, "atk_cd": 0.0, "wait": 0.0, "recent": 0.0, "poise_dmg": 0.0,
		"ph1": _rng.randf() * TAU, "ph2": _rng.randf() * TAU, "lane": _rng.randf_range(0.2, 0.6),
		"lane_hz": _rng.randf_range(0.07, 0.13), "gait_t": _rng.randf_range(2.0, 6.0), "gait_k": 1.0,
		"prog_t": 1.0, "prog_pos": pos, "pure": 0.0, "step_t": 0.0, "lab": false}
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
		z.areas.append(a)
	list.append(z)
	_live[type] = int(_live.get(type, 0)) + 1
	rig.spawn_rise(rise)
	main.fx.zombie_spawn(pos)
	main.sfx.play_at("zombie_spawn", pos)

# ---- taking damage ---------------------------------------------------------------------

# A bullet (or anything else) hit zombie `z` (the value of the Area3D's "zombie" meta).
func hit(z: Dictionary, dmg: float, headshot: bool, pos: Vector3, dir: Vector3) -> void:
	if z.dead:
		return
	z.hp -= dmg
	var rig: Node3D = z.rig
	var T: Dictionary = z.T
	var flat := Vector3(dir.x, 0, dir.z)
	if flat.length_squared() > 0.0001:
		flat = flat.normalized()
	rig.flinch(dir, clamp(0.35 + dmg / 80.0, 0.0, 1.0))
	rig.flash()
	zombie_hit.emit(pos, dir, headshot)
	if z.hp <= 0:
		_kill(z, dir, headshot)
		return
	# knockback is a shove of velocity that dies away, not a jump in position
	var kb: Vector3 = z.kb + flat * clamp(dmg / 25.0, 0.5, 4.0) * 1.6 * float(T.kb)
	if kb.length() > 8.0:
		kb = kb.normalized() * 8.0
	z.kb = kb
	z.recent += dmg
	var st: int = z.state
	if st == S_SPAWN or st == S_SWELL:
		return
	if float(T.poise) > 0.0:
		# heavyweights shrug bullets off, but enough damage during the wind-up breaks it
		if st == S_WINDUP:
			z.poise_dmg += dmg
			if z.poise_dmg >= float(T.poise):
				_stagger(z, 0.8)
		return
	var dur := 0.15
	if z.recent >= 120.0:
		dur = 0.45
	elif z.recent >= 60.0:
		dur = 0.3
	if headshot:
		dur += 0.1
	_stagger(z, dur * float(T.stagger))

# Put a zombie into STAGGER; cancels a wind-up or a strike that has not landed.
func _stagger(z: Dictionary, dur: float) -> void:
	var st: int = z.state
	if st == S_SPAWN or st == S_SWELL or dur <= 0.0:
		return
	if st == S_WINDUP or st == S_STRIKE:
		z.rig.set_windup(0.0)
		z.atk_cd = 0.6
	if st == S_STAGGER:
		z.t = max(float(z.t), dur)
	else:
		z.state = S_STAGGER
		z.t = dur
	z.wait = 0.0

func _remove(z: Dictionary) -> void:
	z.dead = true
	for a in z.areas:
		a.collision_layer = 0  # a corpse must not soak up bullets
	list.erase(z)
	_live[z.type] = int(_live.get(z.type, 1)) - 1

func _kill(z: Dictionary, dir: Vector3, headshot: bool) -> void:
	var rig: Node3D = z.rig
	var info := {"pos": rig.position, "head_pos": rig.head_position(), "dir": dir, "headshot": headshot,
		"type": z.type, "skin": rig.skin, "score_mult": z.score_mult}
	_remove(z)
	rig.set_label_visible(true)
	if headshot:
		rig.pop_head()
		rig.set_label("BONK!", Color(1, 0.9, 0.2))
	else:
		rig.set_label(["oof", "ow", "bleh", "x_x"][_rng.randi() % 4], Color(1, 0.9, 0.2))
	var t: float = rig.die(dir, headshot)
	get_tree().create_timer(t).timeout.connect(rig.queue_free)
	if z.T.explode:
		_booms.append({"pos": rig.position, "t": BLAST_DELAY, "blast": BLAST_SHOT})
	zombie_killed.emit(info)

# A blast at `pos`: hurts the player if close and every zombie in range.
func _explode(pos: Vector3, blast: Dictionary) -> void:
	main.fx.explosion(pos, blast.radius)
	main.sfx.play_at("explode", pos)
	var to: Vector3 = main.player.position - pos
	if to.length() < float(blast.player_radius):
		_hurt_player(blast.player_dmg, pos)
	# other bloaters caught in the blast go off too (a beat later): chain reactions
	for z in list.duplicate():
		if z.T.explode and not z.dead and z.rig.position.distance_to(pos) < float(blast.radius):
			var d: Vector3 = z.rig.position - pos
			hit(z, z.hp, false, z.rig.position + Vector3(0, 1, 0), d.normalized() if d.length() > 0.01 else Vector3.FORWARD)
	damage_radius(pos, blast.radius, float(blast.zombie_dmg) * _hp_scale())

func _hurt_player(dmg: float, from: Vector3) -> void:
	_hurt_block = HURT_TOKEN_BLOCK
	intensity = min(intensity + dmg / 30.0, 1.5)
	player_hit.emit(dmg, from)

# Push back / stagger every zombie in a cone in front of `origin`. Returns how many were hit.
func shove(origin: Vector3, forward: Vector3, reach: float, arc_deg: float, force: float) -> int:
	var n := 0
	var f := Vector3(forward.x, 0, forward.z).normalized()
	var cos_arc := cos(deg_to_rad(arc_deg * 0.5))
	for z in list:
		var d: Vector3 = z.rig.position - origin
		d.y = 0
		var len := d.length()
		if len < reach and (len < 0.6 or f.dot(d / len) > cos_arc):
			var T: Dictionary = z.T
			var push := (f + (d / len if len > 0.01 else f) * 0.5).normalized()
			z.kb = push * force * 1.3 * (0.3 if float(T.poise) > 0.0 else 1.0)
			z.rig.flinch(f, 1.0)
			z.rig.flash()
			_stagger(z, 0.35 if float(T.poise) > 0.0 else 0.9)
			z.atk_cd = max(float(z.atk_cd), 0.8)
			n += 1
	return n

# Damage every zombie within `radius` of `pos` (explosions). Returns how many were hit.
func damage_radius(pos: Vector3, radius: float, dmg: float) -> int:
	var n := 0
	for z in list.duplicate():
		if z.dead:
			continue
		var d: Vector3 = z.rig.position - pos
		if d.length() < radius:
			hit(z, dmg, false, z.rig.position + Vector3(0, 1, 0), d.normalized() if d.length() > 0.01 else Vector3.FORWARD)
			n += 1
	return n

# ---- per-frame -------------------------------------------------------------------------

# Called by main every frame while the game is running.
func update(dt: float) -> void:
	dt = min(dt, 0.1)
	_time += dt
	_frame += 1
	var nav = main.nav
	var ppos: Vector3 = main.player.position
	var camf: Vector3 = -main.cam.global_transform.basis.z
	camf.y = 0
	camf = camf.normalized() if camf.length_squared() > 0.0001 else Vector3(0, 0, -1)
	_hurt_block -= dt
	_grant_cd -= dt
	intensity = max(intensity - 0.15 * dt, 0.0)
	if _active:
		_run_spawner(dt, ppos, camf)
	if not _booms.is_empty():
		var i := 0
		while i < _booms.size():
			var b: Dictionary = _booms[i]
			b.t -= dt
			if b.t <= 0.0:
				_booms.remove_at(i)
				_explode(b.pos, b.blast)
			else:
				i += 1
	var n := list.size()
	if n == 0:
		if _active and _pending == 0 and _booms.is_empty():
			_active = false
			wave_cleared.emit(wave)
		return

	_reloc_t -= dt
	if _reloc_t <= 0.0:
		_reloc_t = 0.5
		_relocate_strays(ppos, camf)

	# pass 1: copy positions into flat arrays and bucket them in 2 m cells (a grid centred
	# on the player), count attackers
	_px.resize(n)
	_pz.resize(n)
	_rad.resize(n)
	_next.resize(n)
	_cell_head.fill(-1)
	var tokens := 0
	for i in n:
		var z: Dictionary = list[i]
		var p: Vector3 = z.rig.position
		_px[i] = p.x
		_pz[i] = p.z
		_rad[i] = z.rig.radius
		var c := clampi(int((p.z - ppos.z) * 0.5 + 24.0), 0, GRID - 1) * GRID + clampi(int((p.x - ppos.x) * 0.5 + 24.0), 0, GRID - 1)
		_next[i] = _cell_head[c]
		_cell_head[c] = i
		var st: int = z.state
		if st == S_WINDUP or st == S_STRIKE:
			tokens += 1
	var max_tokens := 2 if wave < 4 else 3
	var think_every := 1 if n <= 12 else (2 if n <= 26 else 3)
	var straggler := _pending == 0 and n <= 2
	var blend: float = 1.0 - exp(-ACCEL * dt)
	var kb_keep: float = exp(-KB_DECAY * dt)
	var turn: float = 1.0 - exp(-9.0 * dt)
	var sfx = main.sfx
	var detonate: Array = []
	var best_z: Dictionary = {}   # who has waited longest for an attack token
	var best_over := 0.0

	# pass 2: think (some of them), act, move (all of them)
	for i in n:
		var z: Dictionary = list[i]
		var rig: Node3D = z.rig
		var T: Dictionary = z.T
		var pos := Vector3(_px[i], 0.0, _pz[i])
		var dx := ppos.x - pos.x
		var dz := ppos.z - pos.z
		var d := sqrt(dx * dx + dz * dz)
		var inv := 1.0 / d if d > 0.001 else 0.0
		var st: int = z.state
		var want := Vector3.ZERO
		var face_player := false
		if float(z.recent) > 0.0:
			z.recent = max(float(z.recent) - 200.0 * dt, 0.0)
		match st:
			S_CHASE:
				z.atk_cd -= dt
				if d < 3.5 or (i + _frame) % think_every == 0:
					_think(i, z, T, pos, dx, dz, d, ppos, nav, straggler)
				want = z.want
				z.gait_t -= dt
				if z.gait_t <= 0.0:  # now and then: a stumble, or a burst of speed
					var r := _rng.randf()
					if z.gait_k != 1.0:
						z.gait_k = 1.0
						z.gait_t = _rng.randf_range(2.5, 6.0)
					elif r < 0.2:
						z.gait_k = 0.35
						z.gait_t = 0.5
					elif r < 0.45:
						z.gait_k = 1.5
						z.gait_t = 0.9
					else:
						z.gait_t = _rng.randf_range(2.0, 5.0)
				if d < float(T.atk_range) and z.atk_cd <= 0.0:
					if T.explode:
						z.state = S_SWELL
						z.t = 0.0
						sfx.play_at("bloater_swell", pos)
					else:
						# wait for an attack token; zombies the player cannot see wait longer
						z.wait += dt
						var seen: bool = (-dx * camf.x - dz * camf.z) * inv > VIEW_DOT
						var over: float = float(z.wait) - (WAIT_SEEN if seen else WAIT_UNSEEN)
						if over >= best_over:
							best_over = over
							best_z = z
				elif z.wait > 0.0:
					z.wait = max(float(z.wait) - dt, 0.0)
				# safety net: not getting anywhere -> drop the fancy footwork for a moment
				z.prog_t -= dt
				if z.prog_t <= 0.0:
					z.prog_t = 1.0
					var pp: Vector3 = z.prog_pos
					if absf(pp.x - pos.x) + absf(pp.z - pos.z) < 0.3:
						z.side = -float(z.side)
						if d > float(z.ring) + 1.5:
							z.pure = 2.0
						elif float(z.ring) > 1.6:
							z.ring = float(z.ring) - 0.5  # cannot circle here (props): close in instead
					z.prog_pos = pos
				if z.pure > 0.0:
					z.pure -= dt
				if z.type == "sanitation":
					z.step_t -= dt
					if z.step_t <= 0.0:
						z.step_t = 0.65
						sfx.play_at("boss_step", pos)
			S_SPAWN:
				z.t -= dt
				face_player = true
				if z.t <= 0.0:
					z.state = S_CHASE
					z.prog_pos = pos
			S_STAGGER:
				z.t -= dt
				if z.t <= 0.0:
					z.state = S_CHASE
					z.atk_cd = max(float(z.atk_cd), 0.35)
			S_WINDUP:
				z.t += dt
				var k: float = float(z.t) / float(T.windup)
				rig.set_windup(min(k, 1.0))
				face_player = true
				want = Vector3(dx * inv, 0, dz * inv) * (float(z.speed) * float(T.creep))
				if k >= 1.0:
					# commit: the lunge direction is locked now, so moving away dodges it
					z.lunge = Vector3(dx * inv, 0, dz * inv) if d > 0.001 else z.head
					z.state = S_STRIKE
					z.t = T.lunge_time
					z.struck = false
					rig.strike()
					sfx.play_at("zombie_attack", pos)
					if z.type == "sanitation":
						sfx.play_at("boss_step", pos)
			S_STRIKE:
				z.t -= dt
				var lg: Vector3 = z.lunge
				want = lg * float(T.lunge_speed)
				z.vel = want
				if not z.struck and d < float(T.reach) and (d < 0.6 or (dx * lg.x + dz * lg.z) * inv > float(T.cone)) \
						and ppos.y < 2.6:
					z.struck = true
					_hurt_player(z.dmg, pos)
				if z.t <= 0.0:
					z.state = S_RECOVER
					z.t = T.recover
			S_RECOVER:
				z.t -= dt
				face_player = true
				if d < float(z.ring):  # back off to the ring after a swing
					want = Vector3(-dx * inv, 0, -dz * inv) * 1.5
				if z.t <= 0.0:
					z.state = S_CHASE
					z.atk_cd = _rng.randf_range(0.3, 0.9)
					z.wait = 0.0
			S_SWELL:
				z.t += dt
				face_player = true
				rig.set_swell(min(float(z.t) / float(T.windup), 1.0))
				if z.t >= float(T.windup):
					detonate.append(z)

		# move: walking velocity eases toward what the zombie wants; knockback rides on top
		var vel: Vector3 = z.vel
		vel = vel + (want - vel) * blend
		z.vel = vel
		var kb: Vector3 = z.kb
		var step := vel * dt
		if kb.x != 0.0 or kb.z != 0.0:
			step += kb * dt
			kb *= kb_keep
			z.kb = kb if kb.length_squared() > 0.01 else Vector3.ZERO
		var moved := 0.0
		if step.x != 0.0 or step.z != 0.0:
			var np := pos + step
			if nav.is_blocked(np) and not nav.is_blocked(pos):
				var sx := Vector3(np.x, 0, pos.z)
				var sz := Vector3(pos.x, 0, np.z)
				if not nav.is_blocked(sx):
					np = sx
				elif not nav.is_blocked(sz):
					np = sz
				else:
					np = pos
				if st == S_STRIKE:
					z.t = 0.0  # lunged into something: the strike ends here
			np = L.clamp_to_streets(np, 0.6)
			if nav.is_blocked(np) and not nav.is_blocked(pos):
				np = pos
			# never walk (or lunge) into the player's face
			var nd2 := (ppos.x - np.x) * (ppos.x - np.x) + (ppos.z - np.z) * (ppos.z - np.z)
			var keep: float = PLAYER_GAP + _rad[i]
			if nd2 < keep * keep and nd2 < d * d:
				np = pos
			moved = (absf(np.x - pos.x) + absf(np.z - pos.z)) / dt
			if st == S_CHASE and moved < 0.3 * (absf(step.x) + absf(step.z)) / dt and d < float(z.ring) + 0.6:
				# circling into a prop: turn round, and close in if that keeps happening
				z.side = -float(z.side)
				z.ring = max(float(z.ring) - 0.3, 1.5)
				z.want = Vector3.ZERO
			rig.position = np
		# face where it is going (or the player while attacking / waiting)
		var hx := vel.x
		var hz := vel.z
		if face_player or (st == S_CHASE and d < float(z.ring) + 0.6) or hx * hx + hz * hz < 0.25:
			hx = dx
			hz = dz
		if st != S_STAGGER and (hx != 0.0 or hz != 0.0):
			rig.rotation.y = lerp_angle(rig.rotation.y, atan2(-hx, -hz), turn)
		rig.tick(dt, min(moved, vel.length()))

	if not best_z.is_empty() and tokens < max_tokens and _grant_cd <= 0.0 and _hurt_block <= 0.0 \
			and best_z.state == S_CHASE:
		_grant_cd = TOKEN_GAP
		best_z.state = S_WINDUP
		best_z.t = 0.0
		best_z.poise_dmg = 0.0
		sfx.play_at("zombie_windup", best_z.rig.position)

	for z in detonate:
		if not z.dead:
			var p: Vector3 = z.rig.position
			_remove(z)
			z.rig.queue_free()
			_explode(p, BLAST_SELF)

	_label_t -= dt
	if _label_t <= 0.0:
		_label_t = 0.3
		_update_labels(ppos)
	_groan_t -= dt
	if _groan_t <= 0.0 and not list.is_empty():
		_groan_t = _rng.randf_range(1.5, 4.0)
		var g: Dictionary = list[_rng.randi() % list.size()]
		var gp: Vector3 = g.rig.position
		if gp.distance_to(ppos) < 22.0 and g.state == S_CHASE:
			sfx.play_at("zombie_groan", gp, _rng.randf_range(0.85, 1.15))

# Decide where zombie i wants to go this frame (result in z.want, a velocity).
func _think(i: int, z: Dictionary, T: Dictionary, pos: Vector3, dx: float, dz: float, d: float,
		ppos: Vector3, nav, straggler: bool) -> void:
	var head: Vector3 = z.head
	var side: float = z.side
	var ring: float = z.ring
	# neighbours from the 3x3 buckets around us: push apart, and notice anyone dead ahead
	var push_x := 0.0
	var push_z := 0.0
	var ahead := false
	var ri := _rad[i]
	var cx := clampi(int((pos.x - ppos.x) * 0.5 + 24.0), 0, GRID - 1)
	var cz := clampi(int((pos.z - ppos.z) * 0.5 + 24.0), 0, GRID - 1)
	for gz in range(maxi(cz - 1, 0), mini(cz + 2, GRID)):
		for gx in range(maxi(cx - 1, 0), mini(cx + 2, GRID)):
			var j := _cell_head[gz * GRID + gx]
			while j >= 0:
				if j != i:
					var ox := pos.x - _px[j]
					var oz := pos.z - _pz[j]
					var dd := ox * ox + oz * oz
					if dd < 3.0 and dd > 0.000001:
						var l := sqrt(dd)
						var gap := ri + _rad[j] + 0.25
						if l < gap:
							var f := (gap - l) / l
							push_x += ox * f
							push_z += oz * f
						if -(ox * head.x + oz * head.z) > 0.8 * l:
							ahead = true
				j = _next[j]
	var inv := 1.0 / d if d > 0.001 else 0.0
	var want: Vector3
	if d < ring + 0.15:
		# close enough: hold the ring and circle, waiting for a turn to attack
		var tx := -dz * inv * side
		var tz := dx * inv * side
		var out: float = (ring - d) * 3.0
		want = Vector3(tx * float(T.orbit) - dx * inv * out, 0, tz * float(T.orbit) - dz * inv * out)
		z.head = Vector3(dx * inv, 0, dz * inv)
	else:
		var dir: Vector3
		if d < 2.0:
			dir = Vector3(dx * inv, 0, dz * inv)
		else:
			dir = nav.direction(pos, ppos)
		var px := -dir.z
		var pz := dir.x
		if z.pure <= 0.0:
			# personal lane drift + weave, fading out on the final approach
			var fade: float = clamp((d - ring - 1.0) / 5.0, 0.0, 1.0)
			var lat: float = (sin(_time * TAU * float(T.weave_hz) + float(z.ph1)) * float(T.weave) \
					+ sin(_time * TAU * float(z.lane_hz) + float(z.ph2)) * float(z.lane)) * fade
			if ahead:
				lat += side * 0.9  # someone is in the way: go round, do not queue
			dir = Vector3(dir.x + px * lat, 0, dir.z + pz * lat)
			if dir.length_squared() > 0.0001:
				dir = dir.normalized()
		z.head = dir
		var sp: float = float(z.speed) * float(z.gait_k)
		if d < ring + 4.0:
			sp *= 1.25                                   # last few metres: go for it
		elif d > 18.0:
			sp *= 1.0 + min((d - 18.0) / 15.0, 1.0) * 0.7  # hurry while far away
		if straggler and d > 10.0:
			sp *= 2.0                                    # no dull chase after the last one
		want = dir * sp
	if z.pure <= 0.0:
		var pl := sqrt(push_x * push_x + push_z * push_z)
		if pl > 0.0001:
			var k: float = min(pl * 4.0, 2.5) / pl
			want.x += push_x * k
			want.z += push_z * k
	z.want = want

# Floating names only on the nearest few: Label3Ds are draw calls.
func _update_labels(ppos: Vector3) -> void:
	var n := list.size()
	_d2.resize(n)
	for i in n:
		var p: Vector3 = list[i].rig.position
		_d2[i] = (p.x - ppos.x) * (p.x - ppos.x) + (p.z - ppos.z) * (p.z - ppos.z)
	var limit := LABEL_RANGE * LABEL_RANGE
	if n > LABEL_NEAREST:
		var sorted := _d2.duplicate()
		sorted.sort()
		limit = min(limit, sorted[LABEL_NEAREST - 1])
	for i in n:
		var z: Dictionary = list[i]
		var on: bool = _d2[i] <= limit
		if on != z.lab:
			z.lab = on
			z.rig.set_label_visible(on)
