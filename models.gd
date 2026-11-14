extends RefCounted
# Builds the characters and the gun. Use via: const Models = preload("res://models.gd")
const B = preload("res://build.gd")

const ZOMBIE_TYPES := ["commuter", "delivery", "bloater", "sanitation"]

# A zombie body. Returns a zombie_rig.gd node (see that file / SPECS.md for its API).
static func make_zombie(type: String, rng: RandomNumberGenerator) -> Node3D:
	var rig: Node3D = preload("res://zombie_rig.gd").new()
	rig.build(type, rng)
	return rig

# First-person gun. Barrel points along -Z, origin at the grip. Must contain a child
# Node3D named "Muzzle" at the barrel tip.
static func make_gun() -> Node3D:
	var gun := Node3D.new()
	B.box(gun, Vector3(0.08, 0.1, 0.4), Vector3.ZERO, Color(0.2, 0.2, 0.22))
	B.box(gun, Vector3(0.07, 0.16, 0.08), Vector3(0, -0.1, 0.12), Color(0.35, 0.2, 0.1))
	B.box(gun, Vector3(0.12, 0.12, 0.12), Vector3(0, -0.05, 0.22), Color(0.9, 0.7, 0.55))  # hand
	var m := Node3D.new()
	m.name = "Muzzle"
	m.position = Vector3(0, 0, -0.28)
	gun.add_child(m)
	return gun

# Third-person player body, feet at y = 0, facing -Z, about 1.9 m tall.
static func make_player_body() -> Node3D:
	var body := Node3D.new()
	B.box(body, Vector3(0.5, 0.6, 0.3), Vector3(0, 1.2, 0), Color(0.4, 0.4, 0.4))
	B.box(body, Vector3(0.35, 0.35, 0.35), Vector3(0, 1.7, 0), Color(0.9, 0.7, 0.55))
	B.box(body, Vector3(0.5, 0.8, 0.3), Vector3(0, 0.4, 0), Color(0.15, 0.25, 0.5))
	B.box(body, Vector3(0.45, 0.5, 0.2), Vector3(0, 1.2, 0.22), Color(0.7, 0.5, 0.1))  # backpack
	return body
