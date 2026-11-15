extends RefCounted
# First-person weapon models, the things weapons throw, and the drop crate / parachute.
# Use via: const GunModels = preload("res://gun_models.gd")
#
# Same approach as models.gd: merged, vertex-coloured boxes sharing the one material in
# zombie_rig.gd, so every model is 1-2 draw calls and no new shader is compiled.
# Every gun: barrel along -Z, grip near (0, -0.125, 0.29) like the shotgun (so the right
# hand is shared), a child Node3D "Muzzle" at the barrel tip and, where something moves,
# a child "Part" (revolver cylinder, loaded skewer, hot dog, pigeon head).
const Models = preload("res://models.gd")
const Rig = preload("res://zombie_rig.gd")

const SKIN := Models.SURVIVOR_SKIN
const JACKET := Models.JACKET
const STEEL := Models.STEEL
const WOOD := Models.WOOD
const DARK := Color(0.10, 0.09, 0.11)
const TAXI := Color(1.0, 0.78, 0.10)
const HYDRANT := Color(0.86, 0.14, 0.10)
const BRASS := Color(0.88, 0.68, 0.22)
const MAILBOX := Color(0.16, 0.32, 0.74)
const BUN := Color(0.90, 0.68, 0.36)
const SAUSAGE := Color(0.72, 0.22, 0.14)
const MUSTARD := Color(1.0, 0.85, 0.15)
const PIGEON := Color(0.58, 0.60, 0.66)

static var _cache := {}

# The first-person model for weapon `id` (ids: see weapons.gd).
static func make(id: String) -> Node3D:
	match id:
		"shotgun": return Models.make_gun()
		"revolver": return _revolver()
		"smg": return _smg()
		"skewer": return _skewer()
		"double": return _double()
		"launcher": return _launcher()
		"hydrant": return _hydrant()
		"pigeon": return _pigeon()
		"pan": return _pan()
	return Models.make_gun()

# Mesh of a thrown / dropped thing: "hotdog", "pigeon", "bottle", "crate", "chute". Cached.
static func prop(kind: String) -> ArrayMesh:
	if not _cache.has(kind):
		var m := Rig.Sculpt.new()
		m.glow = 0.25
		match kind:
			"hotdog":
				m.box(Vector3(0.16, 0.10, 0.34), Vector3(0, -0.02, 0), BUN)
				m.box(Vector3(0.09, 0.09, 0.42), Vector3(0, 0.04, 0), SAUSAGE)
				for k in 4:
					m.box(Vector3(0.05, 0.03, 0.05), Vector3(0.02 if k % 2 == 0 else -0.02, 0.09, -0.14 + k * 0.09), MUSTARD, 0.6)
			"pigeon":
				m.box(Vector3(0.16, 0.15, 0.30), Vector3(0, 0, 0.02), PIGEON)
				m.box(Vector3(0.12, 0.12, 0.12), Vector3(0, 0.10, -0.16), PIGEON.darkened(0.15))
				m.box(Vector3(0.04, 0.035, 0.07), Vector3(0, 0.08, -0.25), Color(1.0, 0.6, 0.15), 0.5)
				m.pair(Vector3(0.025, 0.03, 0.025), Vector3(0.062, 0.12, -0.19), Color(1.0, 0.45, 0.1), 1.0)
				m.pair(Vector3(0.26, 0.03, 0.18), Vector3(0.20, 0.05, 0.02), Color(0.86, 0.87, 0.92), 0.0, Vector3(0, 0, 0.35))
				m.box(Vector3(0.10, 0.03, 0.14), Vector3(0, 0.02, 0.22), PIGEON.darkened(0.3))
				m.box(Vector3(0.165, 0.05, 0.08), Vector3(0, 0.03, -0.08), Color(0.35, 0.75, 0.55), 0.3)   # shiny neck
			"bottle":
				m.box(Vector3(0.11, 0.20, 0.11), Vector3(0, -0.03, 0), Color(0.90, 0.16, 0.08), 0.4)
				m.box(Vector3(0.115, 0.08, 0.115), Vector3(0, -0.03, 0), Color(0.98, 0.95, 0.80))
				m.box(Vector3(0.05, 0.03, 0.12), Vector3(0, -0.03, 0), Color(0.95, 0.3, 0.1), 0.8)
				m.box(Vector3(0.06, 0.09, 0.06), Vector3(0, 0.11, 0), Color(0.90, 0.16, 0.08), 0.4)
				m.box(Vector3(0.07, 0.035, 0.07), Vector3(0, 0.17, 0), Color(0.2, 0.75, 0.25))
			"crate":
				# feet at y = 0, about 1 m cube: planks, steel corners, glowing question marks
				m.box(Vector3(1.0, 0.86, 1.0), Vector3(0, 0.47, 0), WOOD.lightened(0.12))
				for k in 3:
					m.box(Vector3(1.03, 0.05, 1.03), Vector3(0, 0.22 + k * 0.25, 0), WOOD.darkened(0.35))
				m.box(Vector3(1.06, 0.07, 1.06), Vector3(0, 0.035, 0), DARK)
				m.box(Vector3(1.06, 0.07, 1.06), Vector3(0, 0.905, 0), STEEL)
				for sx in [-1.0, 1.0]:
					for sz in [-1.0, 1.0]:
						m.box(Vector3(0.10, 0.90, 0.10), Vector3(sx * 0.48, 0.47, sz * 0.48), STEEL.darkened(0.15))
				var yel := Color(1.0, 0.88, 0.25)
				for side in 4:
					var b := Basis(Vector3.UP, side * PI * 0.5)
					var parts := [[Vector3(0.26, 0.07, 0.03), Vector3(0, 0.70, -0.515)], [Vector3(0.07, 0.14, 0.03), Vector3(0.10, 0.62, -0.515)],
						[Vector3(0.14, 0.07, 0.03), Vector3(0.04, 0.53, -0.515)], [Vector3(0.07, 0.10, 0.03), Vector3(0.0, 0.46, -0.515)],
						[Vector3(0.07, 0.07, 0.03), Vector3(0.0, 0.30, -0.515)], [Vector3(0.07, 0.10, 0.03), Vector3(-0.10, 0.65, -0.515)]]
					for p in parts:
						m.box(p[0], b * p[1], yel, 1.0, Vector3(0, side * PI * 0.5, 0))
			"chute":
				# origin at the crate's feet; canopy about 3.4 m above, with four lines
				var cols := [Color(0.95, 0.3, 0.2), Color(0.98, 0.95, 0.86)]
				for k in 5:
					var x := (k - 2) * 0.62
					var drop := absf(k - 2.0) * 0.22
					m.box(Vector3(0.62, 0.16, 2.2 - absf(k - 2.0) * 0.3), Vector3(x, 4.1 - drop, 0), cols[k % 2], 0.2, Vector3(0, 0, -(k - 2) * 0.28))
				m.box(Vector3(0.5, 0.14, 0.5), Vector3(0, 4.25, 0), Color(1.0, 0.85, 0.2), 0.4)
				for sx in [-1.0, 1.0]:
					for sz in [-1.0, 1.0]:
						m.box(Vector3(0.03, 3.2, 0.03), Vector3(sx * 0.80, 2.45, sz * 0.62), Color(0.9, 0.9, 0.85), 0.5,
							Vector3(sz * 0.07, 0, -sx * 0.22))
		_cache[kind] = Rig.bake(m)
	return _cache[kind]

# ---------------------------------------------------------------- shared pieces

static func _sculpt() -> Rig.Sculpt:
	var m := Rig.Sculpt.new()
	m.glow = 0.3
	return m

# Grip, right hand and sleeve (the same place as the shotgun's).
static func _grip(m: Rig.Sculpt, col: Color) -> void:
	m.box(Vector3(0.068, 0.16, 0.085), Vector3(0, -0.125, 0.29), col, 0.0, Vector3(0.45, 0, 0))
	m.box(Vector3(0.105, 0.10, 0.11), Vector3(0.008, -0.135, 0.285), SKIN, 0.0, Vector3(0.45, 0, 0))
	m.box(Vector3(0.03, 0.035, 0.06), Vector3(0.0, -0.085, 0.215), SKIN.darkened(0.1))
	m.box(Vector3(0.125, 0.125, 0.34), Vector3(0.05, -0.235, 0.47), JACKET, 0.0, Vector3(-0.45, -0.2, 0))
	m.box(Vector3(0.13, 0.13, 0.04), Vector3(0.022, -0.168, 0.335), JACKET.darkened(0.3), 0.0, Vector3(-0.45, -0.2, 0))

# Left hand cupping something whose underside centre is at `at`, forearm coming in from the lower left.
static func _left(m: Rig.Sculpt, at: Vector3) -> void:
	var o := at - Vector3(0, -0.075, -0.11)
	m.box(Vector3(0.115, 0.07, 0.11), o + Vector3(-0.012, -0.10, -0.11), SKIN)
	m.box(Vector3(0.03, 0.07, 0.10), o + Vector3(0.05, -0.062, -0.11), SKIN.darkened(0.08))
	m.box(Vector3(0.095, 0.095, 0.34), o + Vector3(-0.125, -0.185, 0.065), JACKET, 0.0, Vector3(-0.42, 0.62, 0))
	m.box(Vector3(0.105, 0.105, 0.04), o + Vector3(-0.045, -0.125, -0.05), JACKET.darkened(0.3), 0.0, Vector3(-0.42, 0.62, 0))

static func _finish(body: Rig.Sculpt, muzzle: Vector3, part: Rig.Sculpt = null, part_pos := Vector3.ZERO) -> Node3D:
	var gun := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = Rig.bake(body)
	gun.add_child(mi)
	if part != null:
		var p := MeshInstance3D.new()
		p.name = "Part"
		p.mesh = Rig.bake(part)
		p.position = part_pos
		gun.add_child(p)
	var mz := Node3D.new()
	mz.name = "Muzzle"
	mz.position = muzzle
	gun.add_child(mz)
	return gun

# ---------------------------------------------------------------- the guns

# Snub Nose: stubby revolver held in one hand; "Part" is the cylinder (spin it about Z).
static func _revolver() -> Node3D:
	var m := _sculpt()
	m.box(Vector3(0.05, 0.055, 0.17), Vector3(0, 0.01, 0.045), STEEL)                        # barrel
	m.box(Vector3(0.032, 0.03, 0.13), Vector3(0, -0.03, 0.065), STEEL.darkened(0.2))         # under-lug
	m.box(Vector3(0.016, 0.022, 0.02), Vector3(0, 0.048, -0.025), Color(1.0, 0.55, 0.1), 1.0) # sight
	m.box(Vector3(0.05, 0.035, 0.16), Vector3(0, 0.06, 0.19), STEEL.lightened(0.1))          # top strap
	m.box(Vector3(0.05, 0.03, 0.16), Vector3(0, -0.06, 0.19), STEEL.darkened(0.1))           # bottom of frame
	m.box(Vector3(0.055, 0.13, 0.04), Vector3(0, 0.0, 0.275), STEEL)                         # recoil shield
	m.box(Vector3(0.02, 0.05, 0.035), Vector3(0, 0.075, 0.285), DARK, 0.0, Vector3(-0.5, 0, 0))  # hammer
	m.box(Vector3(0.02, 0.05, 0.07), Vector3(0, -0.105, 0.21), STEEL)                        # trigger guard
	_grip(m, WOOD.darkened(0.2))
	var p := _sculpt()
	p.box(Vector3(0.095, 0.095, 0.10), Vector3.ZERO, Color(0.74, 0.76, 0.84))
	p.box(Vector3(0.095, 0.095, 0.10), Vector3.ZERO, Color(0.62, 0.64, 0.72), 0.0, Vector3(0, 0, PI / 4))
	p.box(Vector3(0.03, 0.03, 0.105), Vector3(0, 0.032, 0), MUSTARD, 0.7)                    # one brass round showing
	return _finish(m, Vector3(0, 0.01, -0.05), p, Vector3(0, 0.0, 0.185))

# Rat-A-Tat: a taxi-yellow machine pistol with a checker band and a roof light.
static func _smg() -> Node3D:
	var m := _sculpt()
	m.box(Vector3(0.078, 0.105, 0.36), Vector3(0, -0.005, 0.10), TAXI)                       # body
	m.box(Vector3(0.082, 0.026, 0.33), Vector3(0, 0.005, 0.10), DARK)                        # checker band
	for k in 5:
		m.box(Vector3(0.086, 0.026, 0.033), Vector3(0, 0.005, -0.032 + k * 0.066), Color(0.98, 0.95, 0.86))
	m.box(Vector3(0.056, 0.056, 0.15), Vector3(0, 0.0, -0.14), DARK.lightened(0.12))         # barrel shroud
	for k in 3:
		m.box(Vector3(0.06, 0.02, 0.02), Vector3(0, 0.0, -0.10 - k * 0.04), DARK)
	m.box(Vector3(0.034, 0.034, 0.05), Vector3(0, 0.0, -0.235), STEEL)                       # muzzle
	m.box(Vector3(0.042, 0.22, 0.062), Vector3(0, -0.155, 0.05), DARK.lightened(0.08), 0.0, Vector3(0.12, 0, 0))  # magazine
	m.box(Vector3(0.05, 0.035, 0.085), Vector3(0, 0.065, 0.12), Color(1.0, 0.95, 0.6), 1.0)  # roof light
	m.box(Vector3(0.054, 0.012, 0.09), Vector3(0, 0.048, 0.12), DARK)
	m.box(Vector3(0.022, 0.022, 0.20), Vector3(0, 0.02, 0.37), DARK.lightened(0.1))          # wire stock
	m.box(Vector3(0.05, 0.09, 0.022), Vector3(0, -0.005, 0.47), DARK.lightened(0.1))
	m.box(Vector3(0.02, 0.05, 0.07), Vector3(0, -0.105, 0.21), DARK)                         # trigger guard
	_grip(m, DARK.lightened(0.1))
	_left(m, Vector3(0, -0.25, 0.03))
	return _finish(m, Vector3(0, 0.0, -0.27))

# Kebab Bow: a crossbow that fires loaded skewers; "Part" is the skewer on the rail.
static func _skewer() -> Node3D:
	var m := _sculpt()
	m.box(Vector3(0.06, 0.075, 0.56), Vector3(0, -0.03, 0.10), WOOD)                         # tiller
	m.box(Vector3(0.024, 0.014, 0.44), Vector3(0, 0.012, 0.02), STEEL.lightened(0.15))       # rail
	m.pair(Vector3(0.30, 0.035, 0.045), Vector3(0.15, -0.005, -0.15), STEEL.darkened(0.25), 0.0, Vector3(0, -0.38, 0))  # limbs
	m.pair(Vector3(0.05, 0.05, 0.06), Vector3(0.285, -0.005, -0.095), Color(0.9, 0.25, 0.2))  # limb tips
	m.pair(Vector3(0.008, 0.008, 0.33), Vector3(0.145, 0.0, 0.045), Color(0.95, 0.95, 0.9), 0.6, Vector3(0, 1.05, 0))  # string
	m.box(Vector3(0.07, 0.05, 0.05), Vector3(0, -0.005, -0.185), STEEL)                      # stirrup block
	m.box(Vector3(0.02, 0.05, 0.07), Vector3(0, -0.105, 0.21), STEEL)
	m.box(Vector3(0.07, 0.11, 0.26), Vector3(0, -0.085, 0.45), WOOD.darkened(0.12), 0.0, Vector3(-0.22, 0, 0))  # stock
	_grip(m, WOOD)
	_left(m, Vector3(0, -0.07, -0.06))
	var p := _sculpt()
	p.box(Vector3(0.012, 0.012, 0.56), Vector3(0, 0, 0), Color(0.86, 0.90, 0.94), 0.5)
	p.box(Vector3(0.024, 0.024, 0.05), Vector3(0, 0, -0.29), Color(0.95, 0.97, 1.0), 0.8)
	var bits := [Color(0.55, 0.30, 0.16), Color(0.35, 0.75, 0.25), Color(0.9, 0.22, 0.15), Color(0.95, 0.92, 0.8), Color(0.55, 0.30, 0.16)]
	for k in bits.size():
		p.box(Vector3(0.05, 0.05, 0.045), Vector3(0, 0, -0.2 + k * 0.058), bits[k], 0.15, Vector3(0, 0, k * 0.5))
	return _finish(m, Vector3(0, 0.03, -0.36), p, Vector3(0, 0.045, -0.06))

# Double Trouble: sawn-off side-by-side.
static func _double() -> Node3D:
	var m := _sculpt()
	m.pair(Vector3(0.062, 0.062, 0.40), Vector3(0.034, 0.0, -0.03), STEEL.darkened(0.12))    # barrels
	m.pair(Vector3(0.072, 0.072, 0.03), Vector3(0.034, 0.0, -0.225), STEEL.lightened(0.2))
	m.pair(Vector3(0.036, 0.036, 0.01), Vector3(0.034, 0.0, -0.243), DARK)                   # bores
	m.box(Vector3(0.02, 0.014, 0.38), Vector3(0, 0.035, -0.03), STEEL)                       # rib
	m.box(Vector3(0.018, 0.02, 0.018), Vector3(0, 0.05, -0.215), Color(1.0, 0.55, 0.1), 1.0)
	m.box(Vector3(0.145, 0.06, 0.17), Vector3(0, -0.05, -0.07), WOOD)                        # fore-end
	m.box(Vector3(0.145, 0.12, 0.15), Vector3(0, -0.015, 0.20), Color(0.72, 0.74, 0.82))     # action
	m.box(Vector3(0.148, 0.02, 0.10), Vector3(0, 0.0, 0.20), BRASS)
	m.pair(Vector3(0.022, 0.045, 0.03), Vector3(0.036, 0.06, 0.26), DARK, 0.0, Vector3(-0.5, 0, 0))  # hammers
	m.box(Vector3(0.02, 0.05, 0.07), Vector3(0, -0.105, 0.21), STEEL)
	m.box(Vector3(0.075, 0.11, 0.16), Vector3(0, -0.10, 0.41), WOOD.darkened(0.1), 0.0, Vector3(-0.3, 0, 0))  # sawn stock
	_grip(m, WOOD)
	_left(m, Vector3(0, -0.08, -0.07))
	return _finish(m, Vector3(0, 0.0, -0.26))

# Hot Dog Cannon: a cart-steel tube with an awning; "Part" is the hot dog in the muzzle.
static func _launcher() -> Node3D:
	var m := _sculpt()
	m.box(Vector3(0.155, 0.155, 0.52), Vector3(0, 0.02, 0.02), Color(0.78, 0.80, 0.86))      # tube
	m.box(Vector3(0.18, 0.18, 0.045), Vector3(0, 0.02, -0.235), Color(0.9, 0.2, 0.15))       # front ring
	m.box(Vector3(0.12, 0.12, 0.01), Vector3(0, 0.02, -0.26), DARK)                          # bore
	m.box(Vector3(0.18, 0.18, 0.045), Vector3(0, 0.02, 0.26), MUSTARD)                       # rear ring
	for k in 5:                                                                              # awning stripes
		m.box(Vector3(0.20, 0.03, 0.074), Vector3(0, 0.125, -0.15 + k * 0.074), Color(0.9, 0.2, 0.15) if k % 2 == 0 else Color(0.98, 0.95, 0.86))
	m.pair(Vector3(0.012, 0.04, 0.012), Vector3(0.08, 0.105, -0.17), STEEL)                  # awning posts
	m.pair(Vector3(0.012, 0.04, 0.012), Vector3(0.08, 0.105, 0.17), STEEL)
	m.box(Vector3(0.04, 0.10, 0.04), Vector3(-0.10, 0.0, 0.10), Color(0.9, 0.16, 0.1), 0.3)  # ketchup
	m.box(Vector3(0.02, 0.03, 0.02), Vector3(-0.10, 0.065, 0.10), Color(0.98, 0.95, 0.86))
	m.box(Vector3(0.04, 0.10, 0.04), Vector3(-0.10, 0.0, 0.16), MUSTARD, 0.3)                # mustard
	m.box(Vector3(0.02, 0.03, 0.02), Vector3(-0.10, 0.065, 0.16), Color(0.98, 0.95, 0.86))
	m.box(Vector3(0.02, 0.05, 0.07), Vector3(0, -0.105, 0.21), STEEL)
	_grip(m, DARK.lightened(0.1))
	_left(m, Vector3(0, -0.06, -0.09))
	var p := _sculpt()
	p.box(Vector3(0.10, 0.06, 0.10), Vector3(0, -0.012, 0), BUN)
	p.box(Vector3(0.055, 0.055, 0.14), Vector3(0, 0.02, -0.02), SAUSAGE)
	p.box(Vector3(0.025, 0.02, 0.10), Vector3(0, 0.05, -0.02), MUSTARD, 0.6)
	return _finish(m, Vector3(0, 0.02, -0.30), p, Vector3(0, 0.02, -0.27))

# Hydrant Hose: a fire hydrant carried sideways, with a brass nozzle.
static func _hydrant() -> Node3D:
	var m := _sculpt()
	m.box(Vector3(0.135, 0.135, 0.34), Vector3(0, 0.0, 0.07), HYDRANT)                       # barrel of the hydrant
	m.box(Vector3(0.10, 0.10, 0.345), Vector3(0, 0.0, 0.07), HYDRANT.lightened(0.12), 0.0, Vector3(0, 0, PI / 4))
	m.box(Vector3(0.16, 0.16, 0.035), Vector3(0, 0.0, 0.235), HYDRANT.darkened(0.2))         # bonnet flange
	m.box(Vector3(0.11, 0.11, 0.05), Vector3(0, 0.0, 0.275), HYDRANT)
	m.box(Vector3(0.05, 0.05, 0.04), Vector3(0, 0.0, 0.315), STEEL)                          # operating nut
	m.pair(Vector3(0.05, 0.075, 0.075), Vector3(0.088, 0.0, 0.10), HYDRANT.lightened(0.2))   # side caps
	m.pair(Vector3(0.02, 0.04, 0.04), Vector3(0.12, 0.0, 0.10), STEEL)
	m.box(Vector3(0.16, 0.16, 0.03), Vector3(0, 0.0, -0.105), HYDRANT.darkened(0.2))         # front flange
	m.box(Vector3(0.075, 0.075, 0.13), Vector3(0, 0.0, -0.18), BRASS)                        # nozzle
	m.box(Vector3(0.09, 0.09, 0.025), Vector3(0, 0.0, -0.165), BRASS.darkened(0.25))
	m.box(Vector3(0.055, 0.055, 0.04), Vector3(0, 0.0, -0.26), BRASS.lightened(0.2))
	m.box(Vector3(0.06, 0.025, 0.06), Vector3(0, 0.08, 0.03), Color(0.98, 0.97, 0.9), 0.5)   # pressure gauge
	m.box(Vector3(0.012, 0.03, 0.035), Vector3(0.008, 0.085, 0.025), Color(0.9, 0.1, 0.1), 0.8, Vector3(0, 0.6, 0))
	m.box(Vector3(0.02, 0.05, 0.07), Vector3(0, -0.105, 0.21), STEEL)
	_grip(m, DARK.lightened(0.1))
	_left(m, Vector3(0, -0.07, -0.05))
	return _finish(m, Vector3(0, 0.0, -0.29))

# Pigeon Post: a street mailbox with the next pigeon sitting on top ("Part").
static func _pigeon() -> Node3D:
	var m := _sculpt()
	m.box(Vector3(0.17, 0.16, 0.38), Vector3(0, 0.015, 0.06), MAILBOX)                       # box
	m.box(Vector3(0.14, 0.035, 0.38), Vector3(0, 0.105, 0.06), MAILBOX.lightened(0.12))      # rounded top
	m.box(Vector3(0.175, 0.035, 0.24), Vector3(0, 0.0, 0.06), Color(0.98, 0.95, 0.86))       # white band
	m.box(Vector3(0.178, 0.012, 0.10), Vector3(0, 0.0, 0.06), Color(0.9, 0.2, 0.15))
	m.box(Vector3(0.13, 0.11, 0.012), Vector3(0, 0.02, -0.132), DARK)                        # opening
	m.box(Vector3(0.15, 0.02, 0.05), Vector3(0, 0.085, -0.15), MAILBOX.darkened(0.2), 0.0, Vector3(-0.5, 0, 0))  # flap
	m.box(Vector3(0.03, 0.022, 0.03), Vector3(0.09, 0.06, 0.20), Color(1.0, 0.3, 0.2), 0.8)  # flag
	m.box(Vector3(0.012, 0.07, 0.012), Vector3(0.09, 0.03, 0.20), STEEL)
	m.box(Vector3(0.02, 0.05, 0.07), Vector3(0, -0.105, 0.21), STEEL)
	_grip(m, DARK.lightened(0.1))
	_left(m, Vector3(0, -0.065, -0.07))
	# the next pigeon waits on top of the box, where the player can see it
	var p := _sculpt()
	p.box(Vector3(0.09, 0.075, 0.13), Vector3(0, 0, 0.02), PIGEON)
	p.box(Vector3(0.065, 0.065, 0.065), Vector3(0, 0.06, -0.05), PIGEON.darkened(0.15))
	p.box(Vector3(0.068, 0.025, 0.045), Vector3(0, 0.03, -0.035), Color(0.35, 0.75, 0.55), 0.3)
	p.box(Vector3(0.025, 0.02, 0.04), Vector3(0, 0.055, -0.10), Color(1.0, 0.6, 0.15), 0.5)
	p.pair(Vector3(0.012, 0.016, 0.016), Vector3(0.034, 0.07, -0.065), Color(1.0, 0.45, 0.1), 1.0)
	p.box(Vector3(0.06, 0.02, 0.06), Vector3(0, -0.01, 0.10), PIGEON.darkened(0.3))
	return _finish(m, Vector3(0, 0.02, -0.21), p, Vector3(0, 0.165, 0.0))

# Frying Pan: handle towards the hand, pan forward, a fried egg stuck to it. Swung, not fired.
static func _pan() -> Node3D:
	var m := _sculpt()
	m.box(Vector3(0.04, 0.04, 0.36), Vector3(0, -0.07, 0.14), DARK.lightened(0.1))           # handle
	m.box(Vector3(0.05, 0.05, 0.04), Vector3(0, -0.07, 0.33), Color(0.9, 0.25, 0.2))         # handle end
	var iron := Color(0.20, 0.20, 0.24)
	m.box(Vector3(0.30, 0.04, 0.30), Vector3(0, -0.07, -0.18), iron)                         # pan
	m.box(Vector3(0.30, 0.04, 0.30), Vector3(0, -0.07, -0.18), iron.lightened(0.06), 0.0, Vector3(0, PI / 4, 0))
	m.box(Vector3(0.33, 0.03, 0.33), Vector3(0, -0.045, -0.18), iron.lightened(0.15))        # rim
	m.box(Vector3(0.27, 0.035, 0.27), Vector3(0, -0.04, -0.18), iron.darkened(0.3))          # inside
	m.box(Vector3(0.15, 0.012, 0.13), Vector3(0.02, -0.02, -0.17), Color(0.98, 0.97, 0.92), 0.3)   # egg
	m.box(Vector3(0.09, 0.012, 0.10), Vector3(-0.04, -0.02, -0.21), Color(0.98, 0.97, 0.92), 0.3)
	m.box(Vector3(0.055, 0.025, 0.055), Vector3(0.02, -0.012, -0.18), MUSTARD, 0.6)          # yolk
	# hand round the handle and the sleeve (no pistol grip on a pan)
	m.box(Vector3(0.10, 0.09, 0.11), Vector3(0.0, -0.075, 0.25), SKIN)
	m.box(Vector3(0.125, 0.125, 0.34), Vector3(0.04, -0.14, 0.46), JACKET, 0.0, Vector3(-0.3, -0.15, 0))
	m.box(Vector3(0.13, 0.13, 0.04), Vector3(0.012, -0.095, 0.31), JACKET.darkened(0.3), 0.0, Vector3(-0.3, -0.15, 0))
	return _finish(m, Vector3(0, -0.05, -0.30))
