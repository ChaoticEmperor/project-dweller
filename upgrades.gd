extends RefCounted
# Between-wave upgrades. main.gd asks stat(name, base) for every tunable number, so an
# upgrade is just a set of modifiers on those stats (names and base values: SPECS.md).
#
# How a stat is computed
#   value = (base + sum of every "add" * level) * product of every "mul" ^ level
#   then clamped to the limits in LIMITS (so nothing can go silly however cards stack).
# Which stats add and which multiply is decided per card, by what reads best on a card:
#   counts and flat amounts ADD   - pellets, max_ammo, max_hp, wave_heal, heal_on_headshot,
#                                   head_mult, shove_reach, shove_arc, shove_damage,
#                                   explosive_radius, score_mult, combo_time, move_speed, dash_speed
#   rates and percentages MULTIPLY - damage, spread, fire_cd, reload_time, dash_cd, shove_cd,
#                                   shove_force
# Because adds go first, "+pellets" and "x damage" cards compound with each other, which is
# what makes a build feel like it snowballs.
#
# A card: id, title (<= 16 chars), desc (<= 40 chars), both in CAPITALS (the HUD font has
# no lowercase), color, icon (a hud.gd icon name), max level, tier and weight for the
# draft, and mods = { stat: ["add" | "mul", amount per level] }.
#
# Tiers keep the first drafts simple: tier 0 cards (plain "more gun / more health") are
# always in the pool, tier 1 unlocks after 1 pick, tier 2 (the build-defining and the
# risky ones) after 3 picks. Locked cards are only offered if the hand cannot be filled.

const TIER_UNLOCK := [0, 1, 3]

const C_GUN := Color(1.0, 0.56, 0.16)
const C_AMMO := Color(1.0, 0.86, 0.22)
const C_BODY := Color(0.47, 0.92, 0.36)
const C_MOVE := Color(0.4, 0.86, 1.0)
const C_SHOVE := Color(0.72, 0.56, 1.0)
const C_SCORE := Color(1.0, 0.45, 0.8)
const C_WILD := Color(0.96, 0.27, 0.27)

const POOL := [
	# ---- tier 0: simple and always useful ----
	{"id": "damage", "title": "ANGRY SHELLS", "desc": "+20% DAMAGE PER PELLET", "color": C_GUN, "icon": "shell",
		"max": 5, "tier": 0, "weight": 1.2, "mods": {"damage": ["mul", 1.2]}},
	{"id": "pump", "title": "GREASED PUMP", "desc": "SHOOT 18% FASTER", "color": C_GUN, "icon": "clock",
		"max": 4, "tier": 0, "weight": 1.0, "mods": {"fire_cd": ["mul", 0.82]}},
	{"id": "loader", "title": "SPEED LOADER", "desc": "RELOAD 25% FASTER", "color": C_AMMO, "icon": "clock",
		"max": 4, "tier": 0, "weight": 1.0, "mods": {"reload_time": ["mul", 0.75]}},
	{"id": "tube", "title": "LONGER TUBE", "desc": "+3 SHELLS BEFORE YOU RELOAD", "color": C_AMMO, "icon": "shell",
		"max": 4, "tier": 0, "weight": 1.0, "mods": {"max_ammo": ["add", 3.0]}},
	{"id": "sneakers", "title": "FAST SNEAKERS", "desc": "RUN 11% FASTER. SQUEAKY.", "color": C_MOVE, "icon": "boot",
		"max": 4, "tier": 0, "weight": 1.0, "mods": {"move_speed": ["add", 1.0]}},
	{"id": "skull", "title": "THICK SKULL", "desc": "+25 MAX HEALTH", "color": C_BODY, "icon": "heart",
		"max": 4, "tier": 0, "weight": 1.1, "mods": {"max_hp": ["add", 25.0]}},
	{"id": "snack", "title": "BIGGER SNACK", "desc": "+20 HEALTH BACK AFTER EVERY WAVE", "color": C_BODY, "icon": "heart",
		"max": 3, "tier": 0, "weight": 1.0, "mods": {"wave_heal": ["add", 20.0]}},
	# ---- tier 1: change how you play ----
	{"id": "buckshot", "title": "EXTRA BUCKSHOT", "desc": "+2 PELLETS, BUT A WIDER SPREAD", "color": C_GUN, "icon": "shell",
		"max": 3, "tier": 1, "weight": 1.0, "mods": {"pellets": ["add", 2.0], "spread": ["mul", 1.18]}},
	{"id": "choke", "title": "TIGHT CHOKE", "desc": "30% TIGHTER SPREAD, +8% DAMAGE", "color": C_GUN, "icon": "aim",
		"max": 3, "tier": 1, "weight": 0.9, "mods": {"spread": ["mul", 0.7], "damage": ["mul", 1.08]}},
	{"id": "headhunter", "title": "HEADHUNTER", "desc": "HEADSHOTS HIT 25% HARDER", "color": C_GUN, "icon": "skull",
		"max": 4, "tier": 1, "weight": 1.0, "mods": {"head_mult": ["add", 0.6]}},
	{"id": "espresso", "title": "TRIPLE ESPRESSO", "desc": "DASH 30% MORE OFTEN AND FURTHER", "color": C_MOVE, "icon": "bolt",
		"max": 3, "tier": 1, "weight": 0.9, "mods": {"dash_cd": ["mul", 0.7], "dash_speed": ["add", 3.0]}},
	{"id": "shove", "title": "MIGHTY SHOVE", "desc": "SHOVE HARDER, WIDER, MORE OFTEN", "color": C_SHOVE, "icon": "fist",
		"max": 3, "tier": 1, "weight": 0.9, "mods": {"shove_force": ["mul", 1.35], "shove_reach": ["add", 0.8],
		"shove_arc": ["add", 15.0], "shove_cd": ["mul", 0.82]}},
	{"id": "score", "title": "SHOW OFF", "desc": "+25% SCORE FOR EVERY BONK", "color": C_SCORE, "icon": "star",
		"max": 4, "tier": 1, "weight": 0.7, "mods": {"score_mult": ["add", 0.25]}},
	{"id": "combo", "title": "COMBO BREAKFAST", "desc": "COMBOS LAST 1 SECOND LONGER", "color": C_SCORE, "icon": "star",
		"max": 3, "tier": 1, "weight": 0.7, "mods": {"combo_time": ["add", 1.0]}},
	# ---- tier 2: build-defining or risky ----
	{"id": "boom", "title": "SPICY SHELLS", "desc": "EVERY SHOT EXPLODES A LITTLE", "color": C_WILD, "icon": "boom",
		"max": 3, "tier": 2, "weight": 0.9, "first": {"explosive_radius": 1.1},
		"mods": {"explosive_radius": ["add", 0.7]}},
	{"id": "vampire", "title": "VAMPIRE BONKS", "desc": "HEADSHOT KILLS HEAL 3 HEALTH", "color": C_WILD, "icon": "skull",
		"max": 3, "tier": 2, "weight": 0.9, "mods": {"heal_on_headshot": ["add", 3.0]}},
	{"id": "boots", "title": "SPIKY BOOTS", "desc": "SHOVES HURT: +40 DAMAGE", "color": C_SHOVE, "icon": "boot",
		"max": 3, "tier": 2, "weight": 0.8, "mods": {"shove_damage": ["add", 40.0], "shove_cd": ["mul", 0.9]}},
	{"id": "glass", "title": "GLASS CANNON", "desc": "+45% DAMAGE BUT -25 MAX HEALTH", "color": C_WILD, "icon": "boom",
		"max": 2, "tier": 2, "weight": 0.7, "mods": {"damage": ["mul", 1.45], "max_hp": ["add", -25.0]}},
]

# [min, max] after all upgrades.
const LIMITS := {
	"pellets": [1.0, 14.0], "spread": [0.0, 0.09], "damage": [1.0, 400.0], "head_mult": [1.0, 6.0],
	"fire_cd": [0.07, 2.0], "reload_time": [0.25, 5.0], "max_ammo": [1.0, 20.0],
	"move_speed": [3.0, 14.0], "dash_cd": [0.25, 5.0], "dash_speed": [10.0, 40.0],
	"max_hp": [25.0, 300.0], "wave_heal": [0.0, 150.0], "heal_on_headshot": [0.0, 15.0],
	"shove_cd": [0.35, 5.0], "shove_reach": [1.0, 7.0], "shove_arc": [20.0, 160.0],
	"shove_force": [1.0, 26.0], "shove_damage": [0.0, 200.0], "explosive_radius": [0.0, 4.0],
	"score_mult": [0.1, 5.0], "combo_time": [0.5, 8.0],
}

var levels := {}        # id -> level taken
var picks := 0          # total cards taken this run
var _add := {}          # stat -> summed additions   (rebuilt by take/reset, so stat() is cheap:
var _mul := {}          # stat -> combined multiplier  main.gd calls it many times per frame)

func reset() -> void:
	levels.clear()
	picks = 0
	_rebuild()

func level(id: String) -> int:
	return levels.get(id, 0)

func card(id: String) -> Dictionary:
	for c in POOL:
		if c.id == id:
			return c
	return {}

# Offer `n` different upgrades:
#   [{ id, title, desc, color, icon, level (current), max }]
# Never a card already at its max level. Fewer than n if fewer are left; an empty array
# means "no draft" (main then skips straight to the next wave).
func roll(n: int, rng: RandomNumberGenerator) -> Array:
	var open: Array = []     # unlocked cards
	var locked: Array = []   # not unlocked yet: only used to fill the hand
	for c in POOL:
		if level(c.id) >= c.max:
			continue
		if picks >= TIER_UNLOCK[c.tier]:
			open.append(c)
		else:
			locked.append(c)
	var out: Array = []
	for pool in [open, locked]:
		while out.size() < n and not pool.is_empty():
			var total := 0.0
			for c in pool:
				total += c.weight
			var r := (rng.randf() if rng != null else randf()) * total
			var pick: int = pool.size() - 1
			for i in pool.size():
				r -= pool[i].weight
				if r < 0.0:
					pick = i
					break
			var c: Dictionary = pool[pick]
			pool.remove_at(pick)
			out.append({"id": c.id, "title": c.title, "desc": c.desc, "color": c.color, "icon": c.icon,
				"level": level(c.id), "max": c.max})
	return out

func take(id: String) -> void:
	var c := card(id)
	if c.is_empty() or level(id) >= c.max:
		return
	levels[id] = level(id) + 1
	picks += 1
	_rebuild()

func _rebuild() -> void:
	_add.clear()
	_mul.clear()
	for c in POOL:
		var lv: int = level(c.id)
		if lv <= 0:
			continue
		for s in c.mods:
			var m: Array = c.mods[s]
			if m[0] == "add":
				_add[s] = _add.get(s, 0.0) + m[1] * lv
			else:
				_mul[s] = _mul.get(s, 1.0) * pow(m[1], lv)
		# "first": a one-off amount for owning the card at all (level 1 has to be worth it)
		for s in c.get("first", {}):
			_add[s] = _add.get(s, 0.0) + c.first[s]

# The value of a stat after all taken upgrades are applied.
func stat(name: String, base: float) -> float:
	var v: float = (base + _add.get(name, 0.0)) * _mul.get(name, 1.0)
	var lim = LIMITS.get(name)
	if lim != null:
		v = clamp(v, lim[0], lim[1])
	return v
