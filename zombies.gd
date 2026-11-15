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
#       CHASE -> TOWALL -> CLIMB -> SCREECH -> LEAP -> RECOVER       (monkey; FALL when knocked off)
#   - Special types belong to places: a wave holds "?" slots that become real types when their
#     pack picks its spawn point, from the ENV table and what stands round that point.
#   - Only a few zombies may attack at once ("attack tokens"); the rest ring the player.
#   - A wave is a budget of zombies released in a few packs from different directions.
const L = preload("res://layout.gd")
const Models = preload("res://models.gd")
const Rig = preload("res://zombie_rig.gd")

signal zombie_hit(pos: Vector3, dir: Vector3, headshot: bool)
# info: { "pos", "head_pos", "dir", "headshot", "type", "skin", "score_mult" }
signal zombie_killed(info: Dictionary)
signal player_hit(dmg: float, from_pos: Vector3)
signal wave_cleared(wave: int)

# the wall states come last on purpose: `state >= S_CLIMB` means "off the ground"
enum { S_SPAWN, S_CHASE, S_WINDUP, S_STRIKE, S_RECOVER, S_STAGGER, S_SWELL, S_TOWALL,
	S_CLIMB, S_SCREECH, S_LEAP, S_FALL }

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
	# ---- types that belong to a place (see ENV below); extra keys are explained at TYPE_DEFAULTS
	# monkey: escaped from the zoo. Runs to a wall, climbs it, screeches, leaps at the player.
	"monkey": {"hp": 30.0, "speed": 5.6, "speed_var": 0.8, "dmg": 9.0, "score": 3, "cost": 2, "first": 2,
		"ring": 2.6, "ring_var": 1.0, "atk_range": 3.2, "windup": 0.45, "creep": 0.0,
		"lunge_speed": 10.0, "lunge_time": 0.22, "reach": 1.4, "cone": 0.3, "recover": 0.9,
		"kb": 1.2, "stagger": 1.2, "poise": 0.0, "orbit": 2.4, "weave": 0.8, "weave_hz": 1.2,
		"live_cap": 4, "rise": 0.5, "explode": false, "label": Color(1.0, 0.62, 0.2),
		"climb": true, "intro": 2, "snd_windup": "monkey_chatter", "snd_idle": "monkey_chatter"},
	# hard hat: building sites and road works. The hat eats head shots until it is knocked off.
	"hardhat": {"hp": 70.0, "speed": 2.9, "speed_var": 0.8, "dmg": 14.0, "score": 2, "cost": 2, "first": 3,
		"ring": 1.7, "ring_var": 0.5, "atk_range": 2.5, "windup": 0.5, "creep": 0.3,
		"lunge_speed": 7.0, "lunge_time": 0.18, "reach": 1.6, "cone": 0.25, "recover": 0.8,
		"kb": 0.8, "stagger": 0.9, "poise": 0.0, "orbit": 0.8, "weave": 0.3, "weave_hz": 0.4,
		"live_cap": 5, "rise": 0.7, "explode": false, "label": Color(1.0, 0.85, 0.15),
		"helmet": 2},
	# riot cop: police roadblocks. The shield stops everything from the front while he walks.
	"riot": {"hp": 110.0, "speed": 2.5, "speed_var": 0.3, "dmg": 16.0, "score": 3, "cost": 3, "first": 6,
		"ring": 1.9, "ring_var": 0.3, "atk_range": 2.7, "windup": 0.7, "creep": 0.2,
		"lunge_speed": 7.0, "lunge_time": 0.2, "reach": 1.8, "cone": 0.2, "recover": 1.3,
		"kb": 0.5, "stagger": 1.0, "poise": 0.0, "orbit": 0.5, "weave": 0.1, "weave_hz": 0.3,
		"live_cap": 2, "rise": 0.8, "explode": false, "label": Color(0.45, 0.9, 1.0),
		"shield": true, "turn_rate": 2.0},
	# vendor: street markets and plazas. Hangs back and lobs hot dogs at a marked spot.
	"vendor": {"hp": 60.0, "speed": 2.4, "speed_var": 0.3, "dmg": 12.0, "score": 3, "cost": 2, "first": 5,
		"ring": 11.0, "ring_var": 2.0, "atk_range": 17.0, "windup": 0.8, "creep": 0.0,
		"lunge_speed": 0.0, "lunge_time": 0.0, "reach": 0.0, "cone": 0.0, "recover": 2.6,
		"kb": 0.8, "stagger": 1.0, "poise": 0.0, "orbit": 1.3, "weave": 0.2, "weave_hz": 0.3,
		"live_cap": 2, "rise": 0.8, "explode": false, "label": Color(1.0, 0.35, 0.25),
		"ranged": true, "needs_los": true, "back_max": 1.8, "alert": true, "snd_attack": "vendor_throw"},
	# pizza rat: pours out of subway stairwells four at a time. Tiny, quick, one pellet each;
	# a shove squashes them.
	"rat": {"hp": 10.0, "speed": 5.4, "speed_var": 1.2, "dmg": 4.0, "score": 1, "cost": 0.5, "first": 3,
		"ring": 1.2, "ring_var": 0.8, "atk_range": 1.9, "windup": 0.32, "creep": 0.5,
		"lunge_speed": 8.0, "lunge_time": 0.14, "reach": 1.2, "cone": 0.3, "recover": 0.6,
		"kb": 1.6, "stagger": 1.2, "poise": 0.0, "orbit": 2.6, "weave": 1.0, "weave_hz": 1.6,
		"live_cap": 10, "rise": 0.35, "explode": false, "label": Color(1.0, 0.8, 0.35),
		"squish": true, "from": "subway", "intro": 4, "snd_idle": "rat_squeak", "snd_windup": "rat_squeak"},
	# cabbie: taxi jams and pile-ups. Honks, then charges in a straight line; side-step it.
	"cabbie": {"hp": 60.0, "speed": 3.4, "speed_var": 0.6, "dmg": 18.0, "score": 2, "cost": 2, "first": 4,
		"ring": 8.5, "ring_var": 1.5, "atk_range": 13.0, "windup": 0.9, "creep": 0.0,
		"lunge_speed": 15.0, "lunge_time": 1.05, "reach": 1.5, "cone": 0.2, "recover": 1.7,
		"kb": 0.9, "stagger": 1.0, "poise": 0.0, "orbit": 1.3, "weave": 0.3, "weave_hz": 0.5,
		"live_cap": 2, "rise": 0.7, "explode": false, "label": Color(1.0, 0.85, 0.1),
		"needs_los": true, "back_max": 3.0, "alert": true, "snd_windup": "taxi_honk"},
}

# Optional keys of a TYPES row and their defaults:
# climb      runs up walls and leaps off them (the monkey state machine)
# helmet     head shots it shrugs off before the hat flies (one per volley)
# shield     has a hit box with part "shield" that blocks while it is in CHASE
# turn_rate  rad/s it can turn at (0 = snappy), so a shield can be flanked
# ranged     its strike is a lobbed projectile instead of a lunge
# needs_los  only attacks (and only keeps its distance) with a clear line to the player
# back_max   fastest it backs away to keep its ring distance (0 = no limit)
# alert      blinks red during the wind-up (long-range attacks need a loud telegraph)
# squish     a shove kills it
# from       "subway": comes out of the nearest stairwell on offer instead of the pack's spot
# intro      how many arrive the very first time the type appears in a run
# snd_*      sound names for its wind-up, strike and idle noises
# names      floating label names (NAMES_BY_TYPE)
const TYPE_DEFAULTS := {"climb": false, "helmet": 0, "shield": false, "turn_rate": 0.0, "ranged": false,
	"needs_los": false, "back_max": 0.0, "alert": false, "squish": false, "from": "", "intro": 1,
	"snd_windup": "zombie_windup", "snd_attack": "zombie_attack", "snd_idle": "zombie_groan"}

# ---- which special types belong where -------------------------------------------------
# ENV[biome][key] = {type: weight}. The keys that apply to a pack are "any", "block:<type>" for
# every block touching its spawn point or the player (L.block_type: towers walkups warehouse park
# plaza parking construction), "theme:<theme>" for the street segment(s) there (L.seg_theme:
# quiet taxi pileup roadblock bus works market el origin_*) and "subway" when a stairwell is
# within 30 m. The weights of all matching rows are added up and each "?" slot of the pack draws
# one type from them (types whose first wave has not come or whose live cap is full are left
# out). "commuter" in a row is the chance of no special at all.
# To add an environment: add a row. To add a biome: add a top-level entry named like
# L.biome_at() returns it; an unknown biome falls back to "downtown".
const ENV := {
	"downtown": {
		"any": {"commuter": 1.0, "monkey": 1.5},
		"block:park": {"monkey": 3.0},
		"block:construction": {"hardhat": 5.0},
		"block:warehouse": {"hardhat": 1.0, "rat": 1.0},
		"block:plaza": {"vendor": 2.5},
		"block:parking": {"cabbie": 2.0},
		"theme:works": {"hardhat": 4.0},
		"theme:roadblock": {"riot": 5.0},
		"theme:pileup": {"cabbie": 2.0, "riot": 1.5},
		"theme:taxi": {"cabbie": 3.5},
		"theme:market": {"vendor": 5.0},
		"theme:el": {"rat": 2.0},
		"subway": {"rat": 2.5},
	},
	# NOT ACTIVE YET: L.biome_at() only returns "downtown" today. These rows reuse the existing
	# types so the later biomes have something sensible from day one; replace them with their own
	# types when those exist.
	"residential": {
		"any": {"commuter": 1.5, "delivery": 1.5, "monkey": 0.5},
		"block:park": {"monkey": 3.0},
		"subway": {"rat": 3.0},
	},
	"beach": {"any": {"commuter": 1.0, "vendor": 2.0, "monkey": 1.0}},
	"desert": {"any": {"commuter": 1.0, "hardhat": 1.0, "bloater": 0.5}},
}
const ENV_SLOT := 2               # wave budget one "?" slot is worth
const ENV_SUBWAY_RANGE := 30.0

# monkey climbing (all heights are the monkey's feet above the street)
const WALL_SEEK := 17.0           # starts looking for a wall when this close to the player
const WALL_REACH := 14.0          # ... and takes one whose foot is at most this far away (the middle
                                  # of an intersection is 12.7 m from the nearest corner)
const WALL_MIN_H := 5.0           # walls lower than this are not climbed
const WALL_OFF := 0.42            # how far its centre hangs off the wall
const CLIMB_MIN := 4.0
const CLIMB_MAX := 7.5            # perch height range (and never above the wall top)
const CLIMB_SPEED := 4.8          # up, down and along the wall, m/s
const LEAP_MAX := 14.0            # longest leap (horizontal metres)
const LEAP_PERP := 12.5           # the player must be this close to the wall's plane for it to be worth climbing
const LEAP_WINDUP := 0.75         # the screech
const LEAP_REACH := 1.9           # landing this close to the player hurts
const WALL_MAX := 9.0             # longest time on one wall before it gives up and drops
const HANG_MAX := 3.5             # longest time hanging still (waiting for a turn / out of range)
const WALL_FAR := 26.0            # player further than this: drop and chase on foot
const KNOCK_STUN := 1.1           # seconds it lies dazed after being shot off a wall

# vendor hot dogs
const PROJ_N := 6
const PROJ_G := 12.0
const SPLAT_R := 2.2              # radius of the marked landing spot

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
const NAMES_BY_TYPE := {
	"delivery": NAMES_DELIVERY, "bloater": NAMES_BLOATER, "sanitation": NAMES_SANITATION,
	"monkey": ["Exhibit B", "Sir Flings-a-Lot", "Bananas Foster", "Curious Jorge", "Zoo Escapee #7", "Fire Escape Frank",
		"King Kinda", "Tailgate Tina", "Chimp Change"],
	"hardhat": ["Union Break Bill", "Scaffold Scott", "Jackhammer Jim", "OSHA Violation", "Permit Pending Pete",
		"Rebar Rita", "Noise Complaint Ned"],
	"riot": ["Officer Do-Not-Cross", "Sgt. Move Along", "Barricade Barry", "Nothing To See Here", "Det. Overtime"],
	"vendor": ["Dirty Water Dimitri", "Two For Five Frank", "Extra Onions Omar", "Cash Only Carl", "No Change Chuck"],
	"rat": ["Pizza Rat", "Slice Thief", "Third Rail Ralph", "Crumbs", "Subway Steve", "Express Rat", "Cheese Louise"],
	"cabbie": ["Off Duty Otto", "Meter's Running Mo", "Shortcut Sal", "No Airport Abe", "Honk If Undead"],
}

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
var _types := {}           # TYPES rows completed with TYPE_DEFAULTS and names (what z.T points at)
var _met := {}             # special types that have appeared in this run (first meetings are small)
var _best_z: Dictionary = {}   # who has waited longest for an attack token this frame
var _best_over := 0.0
var _projs: Array = []     # pooled vendor hot dogs: {node, area, marker, live, dead, proj, from, vel, vy, t, tf, to, dmg}
var _proj_live := 0
var _wallers: Array = []   # monkeys on a wall this frame (they keep out of each other's way)

func setup(main_node: Node3D) -> void:
	main = main_node
	_rng.randomize()
	_cell_head.resize(GRID * GRID)
	for id: String in TYPES:
		var row: Dictionary = (TYPES[id] as Dictionary).duplicate()
		for k: String in TYPE_DEFAULTS:
			if not row.has(k):
				row[k] = TYPE_DEFAULTS[k]
		row["names"] = NAMES_BY_TYPE.get(id, NAMES)
		_types[id] = row
	_build_projectiles()

# The vendor's hot dogs and their landing markers: built once, reused for the whole game.
func _build_projectiles() -> void:
	for i in PROJ_N:
		var node := MeshInstance3D.new()
		node.mesh = Models.zombie_prop("hotdog")
		node.visible = false
		add_child(node)
		var marker := MeshInstance3D.new()
		marker.mesh = Models.zombie_prop("marker")
		marker.visible = false
		add_child(marker)
		var pr := {"node": node, "marker": marker, "live": false, "dead": true, "proj": true, "from": Vector3.ZERO,
			"vel": Vector3.ZERO, "vy": 0.0, "t": 0.0, "tf": 1.0, "to": Vector3.ZERO, "dmg": 0.0}
		# shootable: weapons.gd hits any Area3D that carries "zombie"; hit() sees "proj" and pops it
		var a := Area3D.new()
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = Vector3(0.9, 0.9, 0.9)
		cs.shape = bs
		a.add_child(cs)
		a.set_meta("zombie", pr)
		a.set_meta("head", false)
		a.collision_layer = 0
		node.add_child(a)
		pr["area"] = a
		_projs.append(pr)

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
	# "?" slots: specials that are chosen from the surroundings when their pack spawns
	var n_env := 0
	if n >= 3:
		n_env = int(round(budget * min(0.10 + 0.015 * (n - 3), 0.26) / ENV_SLOT))
	if boss:  # the boss is the star: wave 5 is commuters only, later boss waves a lighter mix
		n_del = 0 if n == 5 else n_del / 2
		n_blo = n_blo / 2
		n_env = n_env / 2
	var n_com := maxi(budget - n_del * int(TYPES.delivery.cost) - n_blo * int(TYPES.bloater.cost) - n_env * ENV_SLOT, 3)
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
	for i in n_env:
		out[(1 + i) % nb].q.append("?")
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
	if n == 2:  # ... and with the monkeys: a pair that opens wave 2
		out.insert(0, {"q": ["monkey", "monkey"], "early": 0})
	return out

# Turn the "?" slots of a pack into real types, now that we know where it spawns (`at`).
# A slot is worth ENV_SLOT budget: two commuters, four rats, one of the bigger specials.
# The first time a type shows up in a run it comes alone (T.intro of them), ahead of the pack.
func _resolve_pack(q: Array, at: Vector3, ppos: Vector3) -> void:
	if not q.has("?"):
		return
	var w := _env_weights(at, ppos)
	var planned := {}
	var front: Array = []
	var out: Array = []
	for t: String in q:
		if t != "?":
			out.append(t)
			continue
		var pick := "commuter"
		var total := 0.0
		for k: String in w:
			if int(_live.get(k, 0)) + int(planned.get(k, 0)) < int(_types[k].live_cap):
				total += float(w[k])
		var r := _rng.randf() * total
		for k: String in w:
			if int(_live.get(k, 0)) + int(planned.get(k, 0)) < int(_types[k].live_cap):
				r -= float(w[k])
				if r <= 0.0:
					pick = k
					break
		var T: Dictionary = _types[pick]
		var count := maxi(1, int(round(ENV_SLOT / float(T.cost))))
		if pick != "commuter" and not _met.has(pick):
			_met[pick] = true
			count = int(T.intro)
			w.erase(pick)     # no more of them in this pack: meet it on its own first
			for i in count:
				front.append(pick)
		else:
			for i in count:
				out.append(pick)
		planned[pick] = int(planned.get(pick, 0)) + count
	_pending += front.size() + out.size() - q.size()
	q.clear()
	q.append_array(front)
	q.append_array(out)

# Weights of the special types for a pack spawning at `at` while the player is at `ppos`.
func _env_weights(at: Vector3, ppos: Vector3) -> Dictionary:
	var rows: Dictionary = ENV.get(L.biome_at(at), ENV.downtown)
	var keys := {"any": true}
	_env_keys(at, keys)
	_env_keys(ppos, keys)
	var w := {}
	for key: String in keys:
		var row: Dictionary = rows.get(key, {})
		for t: String in row:
			if _types.has(t) and wave >= int(_types[t].first):
				w[t] = float(w.get(t, 0.0)) + float(row[t])
	return w

# The ENV keys that apply at p: the blocks that touch it, its street segment(s), a subway nearby.
func _env_keys(p: Vector3, keys: Dictionary) -> void:
	for sx: float in [-12.0, 12.0]:
		for sz: float in [-12.0, 12.0]:
			keys["block:" + L.block_type(floori((p.x + sx) / L.PITCH), floori((p.z + sz) / L.PITCH))] = true
	if L.in_ns(p):
		keys["theme:" + L.seg_theme(0, roundi(p.x / L.PITCH), floori(p.z / L.PITCH))] = true
	if L.in_ew(p):
		keys["theme:" + L.seg_theme(1, floori(p.x / L.PITCH), roundi(p.z / L.PITCH))] = true
	if not L.subway_near(p, ENV_SUBWAY_RANGE).is_empty():
		keys["subway"] = true

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
	_met.clear()
	for pr: Dictionary in _projs:
		_end_proj(pr)
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
		_resolve_pack(q, _last_pos, ppos)   # the "?" slots become what belongs round here
	var qi := -1
	for i in q.size():
		if int(_live.get(q[i], 0)) < int(TYPES[q[i]].live_cap):
			qi = i
			break
	if qi < 0:
		# only capped specials left in this pack: hand them to the next pack, or wait for room
		if _burst_i + 1 < _bursts.size():
			_bursts[_burst_i + 1].q.append_array(q)
			q.clear()
			_lull = _lull_base
			_lull_age = 0.0
		return
	var type: String = q[qi]
	q.remove_at(qi)
	_pending -= 1
	var pt := _pt2 if (q.size() + _burst_n > 9 and _burst_n % 3 == 2) else _pt
	if type == "sanitation" and _pts[pt].subway:  # too big for a subway stairwell
		pt = _pick_point(ppos, camf, -1, -1, true)
	elif _types[type].from == "subway" and not _pts[pt].subway:
		# rats pour out of the nearest stairwell on offer (if there is one)
		var best_d := 45.0
		var base: Vector3 = _pts[pt].pos
		for i in _pts.size():
			if _pts[i].subway:
				var sd: float = (_pts[i].pos as Vector3).distance_to(base)
				if sd < best_d:
					best_d = sd
					pt = i
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
		var zs: int = z.state
		var lost: bool = (zs == S_CHASE or zs == S_TOWALL) and (d > STRAY_DIST or (d > 20.0 and not nav.reachable(p)))
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
	var T: Dictionary = _types[type]
	var nav = main.nav
	_met[type] = true
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
	var names: Array = T.names
	# a rat pack would bury the screen in names: only one in four gets one
	var nm: String = names[_rng.randi() % names.size()]
	rig.set_label("" if T.squish and _rng.randf() < 0.75 else nm, T.label)
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
		"prog_t": 1.0, "prog_pos": pos, "pure": 0.0, "step_t": 0.0, "lab": false,
		# specials: hard hat, shield, line of sight, and the monkey's wall business
		"helmet": int(T.helmet), "helmet_t": -10.0, "guard": false, "ring0": 0.0, "los": false, "los_t": 0.0,
		"wall_cd": _rng.randf_range(0.0, 1.0), "wall_p": Vector3.ZERO, "wall_n": Vector3.ZERO, "wall_top": 0.0,
		"climb_y": 0.0, "wall_t": 0.0, "hang": 0.0, "edge_ok": true, "edge_dir": 0.0, "fq_t": 0.0,
		"from": Vector3.ZERO, "to": Vector3.ZERO, "tf": 1.0, "arc": 1.0, "vy": 0.0, "stun": 0.0,
		"hv": Vector3.ZERO, "lat_lo": 0.0, "lat_hi": 0.0, "slot": _rng.randf_range(-4.0, 4.0)}
	z.ring0 = z.ring
	for sh: Dictionary in rig.hit_shapes():
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
		if sh.get("part", "") == "shield":
			# a hit box that takes no damage: hit() works out from the hit position that a shot
			# landed on it. Only solid while the shield is up.
			a.set_meta("part", "shield")
			a.collision_layer = 0
			z["shield_area"] = a
			z["shield_pos"] = sh.pos
			z["shield_half"] = (sh.size as Vector3) * 0.5 + Vector3(0.1, 0.1, 0.12)
	if T.climb:   # hit boxes move when it goes from all fours to upright on a wall
		var gs: Array = []
		var cl: Array = []
		for sh: Dictionary in rig.hit_shapes():
			gs.append(sh.pos)
		for sh: Dictionary in rig.climb_shapes():
			cl.append(sh.pos)
		z["shapes_g"] = gs
		z["shapes_c"] = cl
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
	if z.has("proj"):   # a vendor's hot dog, shot out of the air
		_pop_proj(z, pos, dir)
		return
	var rig: Node3D = z.rig
	var T: Dictionary = z.T
	if z.guard and T.shield:
		# riot shield: anything that lands on it (in front of the body) is stopped dead
		var lp: Vector3 = rig.to_local(pos) - (z.shield_pos as Vector3)
		var sh: Vector3 = z.shield_half
		if absf(lp.x) < sh.x and absf(lp.y) < sh.y and absf(lp.z) < sh.z:
			main.sfx.play_at("shield_clang", pos, _rng.randf_range(0.92, 1.08))
			main.fx.impact(pos, -dir)
			rig.flinch(dir, 0.12)
			return
	if headshot and (int(z.helmet) > 0 or _time - float(z.helmet_t) < 0.08):
		# hard hat: a volley to the head costs it one notch and does nothing else
		if _time - float(z.helmet_t) >= 0.08:
			z.helmet_t = _time
			z.helmet = int(z.helmet) - 1
			if int(z.helmet) <= 0:
				rig.knock_hat(dir)
				main.sfx.play_at("helmet_off", pos)
			else:
				main.sfx.play_at("helmet_clang", pos, _rng.randf_range(0.95, 1.05))
		main.fx.impact(pos, -dir)
		rig.flinch(dir, 0.5)
		return
	z.hp -= dmg
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
	if st >= S_CLIMB:   # shot off the wall (or out of the air): it falls and lies dazed
		z.kb = Vector3.ZERO
		if st == S_FALL:
			z.stun = maxf(float(z.stun), KNOCK_STUN)
		else:
			_drop(z, KNOCK_STUN)
		return
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
	if st == S_SPAWN or st == S_SWELL or st >= S_CLIMB or dur <= 0.0:
		return
	if st == S_WINDUP or st == S_STRIKE:
		z.rig.set_windup(0.0)
		z.rig.set_alert(0.0)
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
	var squished: Array = []
	for z in list:
		if int(z.state) >= S_CLIMB:
			continue   # up a wall or in the air: out of reach
		var d: Vector3 = z.rig.position - origin
		d.y = 0
		var len := d.length()
		if len < reach and (len < 0.6 or f.dot(d / len) > cos_arc):
			var T: Dictionary = z.T
			if T.squish:
				squished.append(z)
			var push := (f + (d / len if len > 0.01 else f) * 0.5).normalized()
			z.kb = push * force * 1.3 * (0.3 if float(T.poise) > 0.0 else 1.0)
			z.rig.flinch(f, 1.0)
			z.rig.flash()
			_stagger(z, 0.35 if float(T.poise) > 0.0 else 0.9)
			z.atk_cd = max(float(z.atk_cd), 0.8)
			n += 1
	for z: Dictionary in squished:   # rats do not survive a boot
		hit(z, 9999.0, false, z.rig.position + Vector3(0, 0.3, 0), f)
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
	if _proj_live > 0:
		_update_projectiles(dt, ppos)
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
	_wallers.clear()
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
		if st == S_WINDUP or st == S_STRIKE or st == S_SCREECH or st == S_LEAP:
			tokens += 1
		if st == S_CLIMB or st == S_SCREECH:
			_wallers.append(z)
	var max_tokens := 2 if wave < 4 else 3
	var think_every := 1 if n <= 12 else (2 if n <= 26 else 3)
	var straggler := _pending == 0 and n <= 2
	var blend: float = 1.0 - exp(-ACCEL * dt)
	var kb_keep: float = exp(-KB_DECAY * dt)
	var turn: float = 1.0 - exp(-9.0 * dt)
	var sfx = main.sfx
	var detonate: Array = []
	_best_z = {}
	_best_over = 0.0

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
		if st >= S_CLIMB:   # on a wall or in the air: off the pathfinding grid, its own rules
			_wall_step(z, rig, st, dt, ppos, dx, dz, d, camf)
			continue
		if T.shield and (st == S_CHASE) != z.guard:
			_set_guard(z, st == S_CHASE)
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
				if T.needs_los:
					# long-range attackers keep their distance only while they can see the player
					z.los_t -= dt
					if z.los_t <= 0.0:
						z.los_t = 0.4
						z.los = d < 28.0 and L.sight_clear(pos, ppos)
						z.ring = z.ring0 if z.los else 1.8
				if d < float(T.atk_range) and z.atk_cd <= 0.0 and (z.los or not T.needs_los):
					if T.explode:
						z.state = S_SWELL
						z.t = 0.0
						sfx.play_at("bloater_swell", pos)
					else:
						# wait for an attack token; zombies the player cannot see wait longer
						z.wait += dt
						var seen: bool = (-dx * camf.x - dz * camf.z) * inv > VIEW_DOT
						var over: float = float(z.wait) - (WAIT_SEEN if seen else WAIT_UNSEEN)
						if over >= _best_over:
							_best_over = over
							_best_z = z
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
							if z.los:
								z.ring0 = z.ring
					z.prog_pos = pos
				if z.pure > 0.0:
					z.pure -= dt
				if z.type == "sanitation":
					z.step_t -= dt
					if z.step_t <= 0.0:
						z.step_t = 0.65
						sfx.play_at("boss_step", pos)
				if T.climb:
					# monkey: is there a wall worth climbing between here and the player?
					z.wall_cd -= dt
					if z.wall_cd <= 0.0 and d < WALL_SEEK:
						z.wall_cd = 0.5
						if _find_wall(z, pos, ppos):
							z.state = S_TOWALL
							z.t = 0.0
							z.prog_t = 0.7
							z.prog_pos = pos
							z.wait = 0.0
			S_TOWALL:
				# monkey running for the foot of its wall (straight there, a few metres at most)
				z.t += dt
				var wp: Vector3 = z.wall_p
				var wn: Vector3 = z.wall_n
				var off: float = (pos.x - wp.x) * wn.x + (pos.z - wp.z) * wn.z
				var tx := wp.x + wn.x * 0.8 - pos.x
				var tz := wp.z + wn.z * 0.8 - pos.z
				var tl := sqrt(tx * tx + tz * tz)
				z.prog_t -= dt
				var stalled := false
				if z.prog_t <= 0.0:
					z.prog_t = 0.7
					var pp: Vector3 = z.prog_pos
					stalled = absf(pp.x - pos.x) + absf(pp.z - pos.z) < 0.5
					z.prog_pos = pos
				if off < 2.3 and tl < 2.4:
					_start_climb(z)
				elif stalled or float(z.t) > 3.5 or d > WALL_FAR:
					z.state = S_CHASE   # something in the way, or the player left: on foot then
					z.wall_cd = _rng.randf_range(2.5, 4.0)
					z.prog_pos = pos
				elif tl > 0.001:
					want = Vector3(tx / tl, 0, tz / tl) * (float(z.speed) * 1.3)
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
				if T.alert:
					rig.set_alert(min(k, 1.0))
				face_player = true
				want = Vector3(dx * inv, 0, dz * inv) * (float(z.speed) * float(T.creep))
				if k >= 1.0:
					rig.set_alert(0.0)
					rig.strike()
					sfx.play_at(T.snd_attack, pos)
					if T.ranged:
						# the hot dog is on its way to where the player stands now
						_throw(rig, pos, ppos, z.dmg)
						z.state = S_RECOVER
						z.t = T.recover
					else:
						# commit: the lunge direction is locked now, so moving away dodges it
						z.lunge = Vector3(dx * inv, 0, dz * inv) if d > 0.001 else z.head
						z.state = S_STRIKE
						z.t = T.lunge_time
						z.struck = false
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
				if T.ranged:           # a thrower keeps shuffling sideways between throws
					want = Vector3(-dz * inv, 0, dx * inv) * (float(z.side) * float(T.orbit))
				elif d < float(z.ring):  # back off to the ring after a swing
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
				if z.los:   # long-range types: the shorter distance sticks (it would be reset otherwise)
					z.ring0 = z.ring
			rig.position = np
		# face where it is going (or the player while attacking / waiting)
		var hx := vel.x
		var hz := vel.z
		if face_player or (st == S_CHASE and d < float(z.ring) + 0.6) or hx * hx + hz * hz < 0.25:
			hx = dx
			hz = dz
		if st != S_STAGGER and (hx != 0.0 or hz != 0.0):
			if float(T.turn_rate) > 0.0:   # slow to turn: get round the side of it
				rig.rotation.y = rotate_toward(rig.rotation.y, atan2(-hx, -hz), float(T.turn_rate) * dt)
			else:
				rig.rotation.y = lerp_angle(rig.rotation.y, atan2(-hx, -hz), turn)
		rig.tick(dt, min(moved, vel.length()))

	if not _best_z.is_empty() and tokens < max_tokens and _grant_cd <= 0.0 and _hurt_block <= 0.0:
		var bs: int = _best_z.state
		if bs == S_CHASE:
			_grant_cd = TOKEN_GAP
			_best_z.state = S_WINDUP
			_best_z.t = 0.0
			_best_z.poise_dmg = 0.0
			sfx.play_at(_best_z.T.snd_windup, _best_z.rig.position)
		elif bs == S_CLIMB:
			_grant_cd = TOKEN_GAP
			_best_z.state = S_SCREECH
			_best_z.t = 0.0
			_best_z.rig.set_mode(Rig.M_PERCH)
			sfx.play_at("monkey_screech", _best_z.rig.position)

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
		var gs: int = g.state
		if gp.distance_to(ppos) < 22.0 and (gs == S_CHASE or gs == S_CLIMB):
			sfx.play_at(g.T.snd_idle, gp, _rng.randf_range(0.85, 1.15))

# ---- special types ---------------------------------------------------------------------

# Riot shield up or down: the rig swings it, and its hit box only exists while it is up.
func _set_guard(z: Dictionary, on: bool) -> void:
	z.guard = on
	z.rig.set_guard(on)
	(z.shield_area as Area3D).collision_layer = 1 if on else 0

# Monkey hit boxes: on all fours (ground) or upright (wall / air).
func _set_shapes(z: Dictionary, upright: bool) -> void:
	var ps: Array = z.shapes_c if upright else z.shapes_g
	var areas: Array = z.areas
	for i in areas.size():
		(areas[i] as Area3D).position = ps[i]

# Is `f` (from L.nearest_facade) a wall the monkey at `pos` could attack the player from?
func _wall_ok(f: Dictionary, pos: Vector3, ppos: Vector3) -> bool:
	var n: Vector3 = f.normal
	if n == Vector3.ZERO or float(f.height) < WALL_MIN_H:
		return false
	var fp: Vector3 = f.pos
	if (fp.x - pos.x) * (fp.x - pos.x) + (fp.z - pos.z) * (fp.z - pos.z) > WALL_REACH * WALL_REACH:
		return false
	var dn := (ppos.x - fp.x) * n.x + (ppos.z - fp.z) * n.z   # how far the player stands out from that wall
	return dn > 0.5 and dn < LEAP_PERP

# Pick the wall a monkey at `pos` should climb to get at the player: the nearest one if the
# player is within leaping distance of it, else the wall nearest the player (straight across
# the street). Fills z.wall_p (a point at the foot of the wall), z.wall_n, z.wall_top.
func _find_wall(z: Dictionary, pos: Vector3, ppos: Vector3) -> bool:
	var f: Dictionary = L.nearest_facade(pos)
	if not _wall_ok(f, pos, ppos):
		f = L.nearest_facade(ppos)
		var n: Vector3 = f.normal
		if n == Vector3.ZERO:
			return false
		var fp: Vector3 = f.pos
		var off := (pos.x - fp.x) * n.x + (pos.z - fp.z) * n.z
		if off < 0.3 or off > 19.0:
			return false
		# the point of that wall straight in front of me; check the wall really is there
		var q := Vector3(pos.x - n.x * off, 0, pos.z - n.z * off)
		if _wall_at(q, n) <= 0.0:
			return false
		f = L.nearest_facade(q + n * 0.3)
		if not _wall_ok(f, pos, ppos):
			return false
	var wn: Vector3 = f.normal
	var wp: Vector3 = f.pos
	var top: float = f.height
	# not half off the end of the wall: keep 0.8 m of it on either side
	var t := Vector3(-wn.z, 0, wn.x)
	for sgn: float in [1.0, -1.0]:
		if _wall_at(wp + t * (sgn * 0.8), wn) <= 0.0:
			wp -= t * (sgn * 0.8)
	var h := _wall_at(wp, wn)
	if h < WALL_MIN_H:
		return false
	z.wall_p = wp
	z.wall_n = wn
	z.wall_top = minf(top, h)
	return true

# Height of the wall with outward normal n at ground point q, or 0 if there is no such wall there.
func _wall_at(q: Vector3, n: Vector3) -> float:
	var f: Dictionary = L.nearest_facade(q + n * 0.3)
	var fp: Vector3 = f.pos
	if (f.normal as Vector3).dot(n) < 0.99 or absf(fp.x - q.x) + absf(fp.z - q.z) > 0.5:
		return 0.0
	return f.height

func _start_climb(z: Dictionary) -> void:
	var rig: Node3D = z.rig
	z.state = S_CLIMB
	z.wall_t = 0.0
	z.hang = 0.0
	z.wait = 0.0
	z.edge_ok = true
	z.edge_dir = 0.0
	z.lat_lo = 0.0
	z.lat_hi = 0.0
	z.fq_t = 0.0
	z.los = false
	z.los_t = 0.0
	z.climb_y = minf(_rng.randf_range(CLIMB_MIN, CLIMB_MAX), float(z.wall_top) - rig.height - 0.3)
	z.vel = Vector3.ZERO
	z.kb = Vector3.ZERO
	rig.set_mode(Rig.M_CLIMB)
	_set_shapes(z, true)
	main.sfx.play_at("monkey_chatter", rig.position)

# Leave the wall (or the air): fall to a free spot on the street below. stun > 0 = knocked
# off (tumbles, then lies dazed for that long); 0 = let go on purpose.
func _drop(z: Dictionary, stun: float) -> void:
	var rig: Node3D = z.rig
	var p: Vector3 = rig.position
	var n: Vector3 = z.wall_n
	var here := Vector3(p.x, 0, p.z)
	var base := here if int(z.state) == S_LEAP else here + n * 0.9
	var to: Vector3 = L.clamp_to_streets(base, 0.7)
	var nav = main.nav
	if nav.is_blocked(to):
		for k in 10:
			var c: Vector3 = L.clamp_to_streets(base + n * _rng.randf_range(0.0, 2.5)
				+ Vector3(-n.z, 0, n.x) * _rng.randf_range(-2.5, 2.5), 0.7)
			if not nav.is_blocked(c):
				to = c
				break
	z.to = to
	z.hv = (to - here) / maxf(sqrt(2.0 * maxf(p.y, 0.0) / 28.0), 0.12)
	z.state = S_FALL
	z.vy = 0.0
	z.stun = stun
	z.wait = 0.0
	rig.set_windup(0.0)
	rig.set_alert(0.0)
	rig.set_mode(Rig.M_TUMBLE if stun > 0.0 else Rig.M_AIR)

# The screech is over: jump for where the player is standing right now.
func _start_leap(z: Dictionary, ppos: Vector3) -> void:
	var rig: Node3D = z.rig
	var p: Vector3 = rig.position
	var n: Vector3 = z.wall_n
	var dx := ppos.x - p.x
	var dz := ppos.z - p.z
	var dist := sqrt(dx * dx + dz * dz)
	var dir := Vector3(dx / dist, 0, dz / dist) if dist > 0.01 else n
	var reach := clampf(dist - 0.9, 0.6, LEAP_MAX + 2.0)    # lands just short of the player's toes
	var to: Vector3 = L.clamp_to_streets(Vector3(p.x, 0, p.z) + dir * reach, 0.7)
	var nav = main.nav
	var ok: bool = not nav.is_blocked(to)
	if not ok:
		for back: float in [0.8, 1.6, 2.4]:
			var c: Vector3 = L.clamp_to_streets(to - dir * back, 0.7)
			if not nav.is_blocked(c):
				to = c
				ok = true
				break
	if not ok or not L.sight_clear(Vector3(p.x, 0, p.z) + n * 1.2, to):
		_drop(z, 0.0)   # nowhere to land: climb down instead
		return
	z.from = p
	z.to = to
	z.tf = clampf(reach / 13.0, 0.5, 1.0)
	z.arc = 1.0 + 0.08 * reach
	z.t = 0.0
	z.state = S_LEAP
	rig.set_windup(0.0)
	rig.set_alert(0.0)
	rig.set_mode(Rig.M_AIR)
	rig.rotation.y = atan2(-dir.x, -dir.z)
	main.sfx.play_at("monkey_leap", p)

# One frame of a monkey that is on a wall or in the air (states S_CLIMB and later).
func _wall_step(z: Dictionary, rig: Node3D, st: int, dt: float, ppos: Vector3, dx: float, dz: float, d: float,
		camf: Vector3) -> void:
	var p: Vector3 = rig.position
	var n: Vector3 = z.wall_n
	match st:
		S_CLIMB:
			var wp: Vector3 = z.wall_p
			var tx := -n.z
			var tz := n.x
			var off := (p.x - wp.x) * n.x + (p.z - wp.z) * n.z       # out from the wall
			var lat := (p.x - wp.x) * tx + (p.z - wp.z) * tz         # along it
			off = move_toward(off, WALL_OFF, 9.0 * dt)               # the hop onto the wall ...
			var lo: float = z.lat_lo                                 # ... and onto the stretch of it
			var hi: float = z.lat_hi                                 # that is known to be there
			if lat < lo:
				lat = move_toward(lat, lo, 9.0 * dt)
			elif lat > hi:
				lat = move_toward(lat, hi, 9.0 * dt)
			var moved := 0.0
			# along the wall toward the player, as long as the wall goes on
			var sp := (ppos.x - wp.x) * tx + (ppos.z - wp.z) * tz + float(z.slot) - lat
			var dirl := 0.0
			if absf(sp) > 1.5 and d > 8.0:
				dirl = signf(sp)
			if _wallers.size() > 1:
				# another monkey on the same patch of wall: shuffle apart instead
				for w: Dictionary in _wallers:
					if is_same(w, z) or (w.wall_n as Vector3).dot(n) < 0.9:
						continue
					var q: Vector3 = w.rig.position
					var wl := (q.x - p.x) * tx + (q.z - p.z) * tz
					if absf(wl) < 1.2 and absf(q.y - p.y) < 1.7 and absf((q.x - p.x) * n.x + (q.z - p.z) * n.z) < 1.5:
						dirl = -signf(wl) if absf(wl) > 0.01 else (1.0 if z.rig.get_instance_id() > w.rig.get_instance_id() else -1.0)
						break
			if dirl != 0.0 and p.y > 1.5:
				z.fq_t -= dt
				if dirl != float(z.edge_dir) or float(z.fq_t) <= 0.0:
					z.fq_t = 0.25
					z.edge_dir = dirl
					# look 2 m ahead (a quarter second of climbing plus a margin from the wall's end)
					var h := _wall_at(Vector3(wp.x + tx * (lat + dirl * 2.0), 0, wp.z + tz * (lat + dirl * 2.0)), n)
					z.edge_ok = h >= WALL_MIN_H
					if z.edge_ok:
						z.wall_top = minf(float(z.wall_top), h)
				if z.edge_ok:
					lat += dirl * CLIMB_SPEED * dt
					moved = CLIMB_SPEED
					if lat < lo:
						z.lat_lo = lat
					elif lat > hi:
						z.lat_hi = lat
				else:
					dirl = 0.0
			# up (or down, if the wall got lower)
			var ty: float = minf(float(z.climb_y), float(z.wall_top) - rig.height - 0.3)
			var ny := move_toward(p.y, ty, CLIMB_SPEED * dt)
			if ny != p.y:
				moved = CLIMB_SPEED
			rig.position = Vector3(wp.x + tx * lat + n.x * off, ny, wp.z + tz * lat + n.z * off)
			z.wall_t += dt
			z.los_t -= dt
			if z.los_t <= 0.0:
				z.los_t = 0.4
				z.los = L.sight_clear(Vector3(rig.position.x, 0, rig.position.z) + n * 1.2, ppos)
			var ready: bool = moved == 0.0 and d <= LEAP_MAX and z.los
			if moved == 0.0:
				z.hang += dt
			if ready:
				# hanging there, looking at the player, waiting for its turn to pounce
				rig.set_mode(Rig.M_PERCH)
				rig.rotation.y = lerp_angle(rig.rotation.y, atan2(-dx, -dz), 1.0 - exp(-8.0 * dt))
				z.wait += dt
				var seen: bool = d > 0.001 and (-dx * camf.x - dz * camf.z) / d > VIEW_DOT
				var over: float = float(z.wait) - (WAIT_SEEN if seen else WAIT_UNSEEN)
				if over >= _best_over:
					_best_over = over
					_best_z = z
			else:
				rig.set_mode(Rig.M_CLIMB)
				rig.rotation.y = lerp_angle(rig.rotation.y, atan2(n.x, n.z), 1.0 - exp(-12.0 * dt))
				z.wait = maxf(float(z.wait) - dt, 0.0)
			rig.tick(dt, moved)
			# never stays up there: too long on the wall, bored of hanging, or the player has gone
			if float(z.wall_t) > WALL_MAX or float(z.hang) > HANG_MAX or d > WALL_FAR:
				_drop(z, 0.0)
		S_SCREECH:
			z.t += dt
			var k: float = float(z.t) / LEAP_WINDUP
			rig.set_windup(minf(k, 1.0))
			rig.set_alert(minf(k, 1.0))
			rig.rotation.y = lerp_angle(rig.rotation.y, atan2(-dx, -dz), 1.0 - exp(-10.0 * dt))
			rig.tick(dt, 0.0)
			if d > WALL_FAR:
				_drop(z, 0.0)
			elif k >= 1.0:
				_start_leap(z, ppos)
		S_LEAP:
			z.t += dt
			var u: float = minf(float(z.t) / float(z.tf), 1.0)
			var a: Vector3 = z.from
			var b: Vector3 = z.to
			rig.position = Vector3(lerpf(a.x, b.x, u), a.y * (1.0 - u) + float(z.arc) * 4.0 * u * (1.0 - u), lerpf(a.z, b.z, u))
			rig.tick(dt, 0.0)
			if u >= 1.0:
				_land(z, rig, b)
				var ldx := ppos.x - b.x
				var ldz := ppos.z - b.z
				if ldx * ldx + ldz * ldz < LEAP_REACH * LEAP_REACH and ppos.y < 2.6:
					_hurt_player(z.dmg, b)   # stood still: it lands on you
				rig.strike()
				z.state = S_RECOVER
				z.t = z.T.recover
				z.wall_cd = _rng.randf_range(1.5, 3.0)
				main.sfx.play_at("zombie_attack", b)
		S_FALL:
			z.vy = float(z.vy) + 28.0 * dt
			var ny := p.y - float(z.vy) * dt
			var hv: Vector3 = z.hv
			if ny > 0.0:
				rig.position = Vector3(p.x + hv.x * dt, ny, p.z + hv.z * dt)
				rig.tick(dt, 0.0)
			else:
				var to: Vector3 = z.to
				_land(z, rig, to)
				z.wall_cd = _rng.randf_range(3.0, 5.0)
				if float(z.stun) > 0.0:
					z.state = S_STAGGER
					z.t = z.stun
					rig.flinch(-n, 1.0)
					main.sfx.play_at("monkey_thud", to)
				else:
					z.state = S_CHASE
					z.atk_cd = 0.4

# Back on the street at `at`: on all fours again, with a puff of dust.
func _land(z: Dictionary, rig: Node3D, at: Vector3) -> void:
	rig.position = Vector3(at.x, 0, at.z)
	rig.set_mode(Rig.M_GROUND)
	_set_shapes(z, false)
	z.vel = Vector3.ZERO
	z.kb = Vector3.ZERO
	z.prog_pos = rig.position
	z.prog_t = 1.0
	z.lost = 0
	main.fx.impact(Vector3(at.x, 0.1, at.z), Vector3.UP)

# ---- vendor hot dogs: pooled, moved by hand, no physics --------------------------------

# Lob one from the vendor at `pos` to where the player stands now. The landing spot is marked
# on the ground from the moment it leaves his hand.
func _throw(rig: Node3D, pos: Vector3, ppos: Vector3, dmg: float) -> void:
	var pr: Dictionary = {}
	for c: Dictionary in _projs:
		if not c.live:
			pr = c
			break
	if pr.is_empty():
		return
	var from := Vector3(pos.x, rig.height * 0.8, pos.z)
	var to: Vector3 = L.clamp_to_streets(Vector3(ppos.x, 0, ppos.z), 0.3)
	var flat := Vector3(to.x - from.x, 0, to.z - from.z)
	var tf := clampf(flat.length() / 9.0, 1.1, 1.9)
	pr.live = true
	pr.dead = false
	pr.from = from
	pr.to = to
	pr.vel = flat / tf
	pr.vy = (0.5 * PROJ_G * tf * tf - from.y) / tf
	pr.t = 0.0
	pr.tf = tf
	pr.dmg = dmg
	var node: MeshInstance3D = pr.node
	node.position = from
	node.visible = true
	(pr.area as Area3D).collision_layer = 1
	var marker: MeshInstance3D = pr.marker
	# sidewalks and open blocks are drawn a kerb higher than the road
	var on_road: bool = absf(L.lat(to.x)) <= L.ROAD_HALF or absf(L.lat(to.z)) <= L.ROAD_HALF
	marker.position = Vector3(to.x, 0.06 if on_road else L.KERB_H + 0.06, to.z)
	marker.scale = Vector3.ONE * SPLAT_R
	marker.visible = true
	_proj_live += 1

func _end_proj(pr: Dictionary) -> void:
	if pr.live:
		_proj_live -= 1
	pr.live = false
	pr.dead = true
	(pr.node as MeshInstance3D).visible = false
	(pr.marker as MeshInstance3D).visible = false
	(pr.area as Area3D).collision_layer = 0

# A hot dog was shot in flight: it bursts harmlessly.
func _pop_proj(pr: Dictionary, pos: Vector3, dir: Vector3) -> void:
	_end_proj(pr)
	main.fx.gibs(pos, Color(1.0, 0.82, 0.12), 6, dir * 0.3)
	main.sfx.play_at("splat", pos, 1.3)
	zombie_hit.emit(pos, dir, false)

func _update_projectiles(dt: float, ppos: Vector3) -> void:
	for pr: Dictionary in _projs:
		if not pr.live:
			continue
		var t: float = float(pr.t) + dt
		pr.t = t
		var tf: float = pr.tf
		var marker: MeshInstance3D = pr.marker
		if t >= tf:
			var to: Vector3 = pr.to
			_end_proj(pr)
			var at := Vector3(to.x, 0.3, to.z)
			main.fx.explosion_colored(at, 1.2, false)
			main.fx.gibs(at, Color(1.0, 0.82, 0.12), 6, Vector3.ZERO)
			main.sfx.play_at("splat", at)
			var ddx := ppos.x - to.x
			var ddz := ppos.z - to.z
			if ddx * ddx + ddz * ddz < SPLAT_R * SPLAT_R and ppos.y < 2.2:
				_hurt_player(pr.dmg, at)
			continue
		var from: Vector3 = pr.from
		var vel: Vector3 = pr.vel
		var node: MeshInstance3D = pr.node
		node.position = Vector3(from.x + vel.x * t, from.y + float(pr.vy) * t - 0.5 * PROJ_G * t * t, from.z + vel.z * t)
		node.rotation = Vector3(t * 9.0, atan2(-vel.x, -vel.z), 0)
		# the marker throbs faster as the hot dog comes down
		var u := t / tf
		marker.scale = Vector3.ONE * (SPLAT_R * (1.0 + 0.08 * sin(t * (10.0 + 30.0 * u))))
		marker.rotation.y = t * 1.5

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
		if float(T.back_max) > 0.0 and out > float(T.back_max):
			out = T.back_max      # keeps its distance, but can be run down
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
