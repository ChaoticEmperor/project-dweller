extends RefCounted
# Builds the characters and the gun. Use via: const Models = preload("res://models.gd")
# Everything here is merged, vertex-coloured box sculpture sharing one material
# (see zombie_rig.gd: Rig.material() and Rig.Sculpt).
const Rig = preload("res://zombie_rig.gd")

const ZOMBIE_TYPES := ["commuter", "delivery", "bloater", "sanitation"]

const SURVIVOR_SKIN := Color(0.90, 0.68, 0.52)
const JACKET := Color(0.78, 0.26, 0.16)
const STEEL := Color(0.56, 0.59, 0.68)
const WOOD := Color(0.66, 0.40, 0.18)

# A zombie body. Returns a zombie_rig.gd node (see that file / SPECS.md for its API).
static func make_zombie(type: String, rng: RandomNumberGenerator) -> Node3D:
	var rig: Node3D = Rig.new()
	rig.build(type, rng)
	return rig

# Optional: build every cached zombie mesh up front (about 150 small meshes) so that no
# spawn during play has to build geometry. Safe to call more than once.
static func prewarm() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	for t in ZOMBIE_TYPES:
		for k in (120 if t == "commuter" else 6):
			make_zombie(t, rng).free()

# First-person pump shotgun. Barrel points along -Z, origin at the grip. Children:
# "Muzzle" (Node3D at the barrel tip) and "Pump" (the fore-end and the left hand; slide
# it with Models.gun_pump). 2 draw calls.
static func make_gun() -> Node3D:
	var gun := Node3D.new()
	var m := Rig.Sculpt.new()
	m.glow = 0.3
	m.box(Vector3(0.052, 0.052, 0.50), Vector3(0, 0, -0.03), STEEL)                       # barrel
	m.box(Vector3(0.066, 0.066, 0.035), Vector3(0, 0, -0.262), STEEL.lightened(0.25))     # muzzle ring
	m.box(Vector3(0.046, 0.046, 0.40), Vector3(0, -0.052, -0.06), STEEL.darkened(0.2))    # magazine tube
	m.box(Vector3(0.05, 0.03, 0.03), Vector3(0, -0.03, -0.24), STEEL.lightened(0.1))      # barrel band
	m.box(Vector3(0.018, 0.022, 0.018), Vector3(0, 0.036, -0.262), Color(1.0, 0.55, 0.1), 1.0)  # bead sight
	m.box(Vector3(0.082, 0.125, 0.23), Vector3(0, -0.022, 0.165), Color(0.70, 0.72, 0.80))      # receiver
	m.box(Vector3(0.03, 0.012, 0.20), Vector3(0, 0.045, 0.165), STEEL)                    # top rib
	m.box(Vector3(0.012, 0.035, 0.09), Vector3(0.041, -0.005, 0.14), Rig.DARK)            # ejection port
	m.box(Vector3(0.012, 0.012, 0.012), Vector3(0.043, -0.045, 0.21), Color(1.0, 0.2, 0.15), 1.0)  # safety dot
	m.box(Vector3(0.02, 0.05, 0.07), Vector3(0, -0.105, 0.20), STEEL)                     # trigger guard
	m.box(Vector3(0.068, 0.16, 0.085), Vector3(0, -0.125, 0.29), WOOD, 0.0, Vector3(0.45, 0, 0))   # grip
	m.box(Vector3(0.07, 0.11, 0.30), Vector3(0, -0.085, 0.46), WOOD.darkened(0.1), 0.0, Vector3(-0.22, 0, 0))  # stock
	# right hand on the grip and its sleeve
	m.box(Vector3(0.105, 0.10, 0.11), Vector3(0.008, -0.135, 0.285), SURVIVOR_SKIN, 0.0, Vector3(0.45, 0, 0))
	m.box(Vector3(0.03, 0.035, 0.06), Vector3(0.0, -0.085, 0.215), SURVIVOR_SKIN.darkened(0.1))   # trigger finger
	m.box(Vector3(0.125, 0.125, 0.34), Vector3(0.05, -0.235, 0.47), JACKET, 0.0, Vector3(-0.45, -0.2, 0))
	m.box(Vector3(0.13, 0.13, 0.04), Vector3(0.022, -0.168, 0.335), JACKET.darkened(0.3), 0.0, Vector3(-0.45, -0.2, 0))
	var body := MeshInstance3D.new()
	body.mesh = Rig.bake(m)
	gun.add_child(body)

	var p := Rig.Sculpt.new()
	p.glow = 0.3
	p.box(Vector3(0.082, 0.075, 0.17), Vector3(0, -0.05, -0.11), WOOD)                    # fore-end
	for k in 4:
		p.box(Vector3(0.088, 0.05, 0.014), Vector3(0, -0.05, -0.17 + k * 0.04), WOOD.darkened(0.35))
	# left hand under the pump and its forearm coming in from the lower left
	p.box(Vector3(0.115, 0.07, 0.11), Vector3(-0.012, -0.10, -0.11), SURVIVOR_SKIN)
	p.box(Vector3(0.03, 0.07, 0.10), Vector3(0.05, -0.062, -0.11), SURVIVOR_SKIN.darkened(0.08))
	p.box(Vector3(0.095, 0.095, 0.34), Vector3(-0.125, -0.185, 0.065), JACKET, 0.0, Vector3(-0.42, 0.62, 0))
	p.box(Vector3(0.105, 0.105, 0.04), Vector3(-0.045, -0.125, -0.05), JACKET.darkened(0.3), 0.0, Vector3(-0.42, 0.62, 0))
	var pump := MeshInstance3D.new()
	pump.name = "Pump"
	pump.mesh = Rig.bake(p)
	gun.add_child(pump)

	var mz := Node3D.new()
	mz.name = "Muzzle"
	mz.position = Vector3(0, 0, -0.28)
	gun.add_child(mz)
	return gun

# Optional animation hook: slide the pump (and the left hand) back. k = 0 forward … 1 fully racked.
static func gun_pump(gun: Node3D, k: float) -> void:
	var p := gun.get_node_or_null("Pump") as Node3D
	if p:
		p.position.z = clampf(k, 0.0, 1.0) * 0.085

# Third-person survivor, feet at y = 0, facing -Z, about 1.9 m tall. 1 draw call.
static func make_player_body() -> Node3D:
	var body := Node3D.new()
	var m := Rig.Sculpt.new()
	var jeans := Color(0.30, 0.46, 0.78)
	var boot := Color(0.34, 0.22, 0.14)
	var pack := Color(0.55, 0.62, 0.32)
	# legs (a slight stance) and boots
	m.pair(Vector3(0.23, 0.80, 0.26), Vector3(0.15, 0.48, 0.0), jeans)
	m.pair(Vector3(0.25, 0.14, 0.38), Vector3(0.15, 0.07, -0.05), boot)
	m.pair(Vector3(0.24, 0.05, 0.27), Vector3(0.15, 0.17, 0.0), jeans.lightened(0.2))   # turn-ups
	m.box(Vector3(0.56, 0.08, 0.32), Vector3(0, 0.90, 0), Color(0.12, 0.09, 0.07))      # belt
	# jacket: red flannel with darker checks
	m.box(Vector3(0.58, 0.62, 0.34), Vector3(0, 1.24, 0), JACKET)
	for k in 3:
		m.box(Vector3(0.59, 0.035, 0.35), Vector3(0, 1.05 + k * 0.18, 0), JACKET.darkened(0.4))
	m.pair(Vector3(0.035, 0.63, 0.35), Vector3(0.16, 1.24, 0), JACKET.darkened(0.4))
	m.box(Vector3(0.14, 0.5, 0.02), Vector3(0, 1.28, -0.172), Color(0.85, 0.85, 0.8))   # t-shirt
	m.pair(Vector3(0.16, 0.07, 0.12), Vector3(0.13, 1.56, -0.10), JACKET.lightened(0.1), 0.0, Vector3(0, 0, 0.35))
	# backpack with a bedroll and a glow-stick so the player reads from behind at dusk
	m.box(Vector3(0.50, 0.56, 0.24), Vector3(0, 1.24, 0.29), pack)
	m.box(Vector3(0.36, 0.22, 0.06), Vector3(0, 1.12, 0.43), pack.darkened(0.2))
	m.box(Vector3(0.62, 0.17, 0.17), Vector3(0, 1.60, 0.27), Color(0.60, 0.52, 0.36))
	m.pair(Vector3(0.05, 0.19, 0.19), Vector3(0.20, 1.60, 0.27), Rig.DARK)
	m.box(Vector3(0.05, 0.22, 0.05), Vector3(0.20, 1.20, 0.435), Color(0.3, 1.0, 0.9), 1.0)
	m.pair(Vector3(0.07, 0.50, 0.03), Vector3(0.19, 1.30, -0.175), pack.darkened(0.25))
	# arms holding the shotgun across the front
	m.box(Vector3(0.17, 0.36, 0.18), Vector3(0.375, 1.36, -0.03), JACKET, 0.0, Vector3(0.5, 0, 0))
	m.box(Vector3(0.15, 0.15, 0.36), Vector3(0.33, 1.17, -0.27), JACKET, 0.0, Vector3(0.1, -0.35, 0))
	m.box(Vector3(0.14, 0.13, 0.14), Vector3(0.22, 1.16, -0.46), SURVIVOR_SKIN)
	m.box(Vector3(0.17, 0.36, 0.18), Vector3(-0.375, 1.36, -0.06), JACKET, 0.0, Vector3(0.8, 0, 0))
	m.box(Vector3(0.15, 0.15, 0.40), Vector3(-0.27, 1.19, -0.38), JACKET, 0.0, Vector3(0.05, 0.55, 0))
	m.box(Vector3(0.14, 0.13, 0.14), Vector3(-0.10, 1.17, -0.60), SURVIVOR_SKIN)
	# shotgun
	m.box(Vector3(0.07, 0.07, 0.80), Vector3(0.10, 1.22, -0.62), STEEL, 0.0, Vector3(0.0, 0.38, 0))
	m.box(Vector3(0.09, 0.10, 0.22), Vector3(-0.06, 1.19, -0.66), WOOD, 0.0, Vector3(0.0, 0.38, 0))
	m.box(Vector3(0.08, 0.12, 0.30), Vector3(0.29, 1.19, -0.20), WOOD.darkened(0.1), 0.0, Vector3(0.0, 0.38, 0))
	# head: face, messy hair, backwards cap
	m.box(Vector3(0.18, 0.10, 0.18), Vector3(0, 1.58, 0), SURVIVOR_SKIN.darkened(0.15))
	m.box(Vector3(0.40, 0.38, 0.40), Vector3(0, 1.80, 0), SURVIVOR_SKIN)
	m.pair(Vector3(0.07, 0.07, 0.02), Vector3(0.09, 1.83, -0.205), Rig.DARK)
	m.box(Vector3(0.16, 0.035, 0.02), Vector3(0.0, 1.71, -0.205), Color(0.45, 0.2, 0.18))
	m.box(Vector3(0.42, 0.14, 0.14), Vector3(0, 1.70, 0.16), Color(0.30, 0.18, 0.08))
	m.box(Vector3(0.44, 0.13, 0.44), Vector3(0, 1.99, 0.0), Color(0.15, 0.35, 0.75))
	m.box(Vector3(0.30, 0.04, 0.20), Vector3(0, 1.94, 0.30), Color(0.15, 0.35, 0.75).darkened(0.2))
	m.box(Vector3(0.12, 0.08, 0.02), Vector3(0, 2.0, -0.225), Color(1.0, 0.85, 0.2), 0.8)
	var mi := MeshInstance3D.new()
	mi.mesh = Rig.bake(m)
	body.add_child(mi)
	return body
