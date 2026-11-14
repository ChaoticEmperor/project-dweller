extends RefCounted
# Shared helpers for building blocky geometry. Use via: const B = preload("res://build.gd")

static var _mats := {}

static func mat(c: Color, unshaded := false) -> StandardMaterial3D:
	var k := c.to_html() + ("u" if unshaded else "")
	if not _mats.has(k):
		var m := StandardMaterial3D.new()
		m.albedo_color = c
		m.roughness = 1.0
		if unshaded:
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		if c.a < 1.0:
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_mats[k] = m
	return _mats[k]

# A coloured box. collide=true also gives it a StaticBody3D so the player and bullets hit it.
static func box(parent: Node, size: Vector3, pos: Vector3, c: Color, collide := false, unshaded := false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat(c, unshaded)
	mi.position = pos
	parent.add_child(mi)
	if collide:
		collider(mi, size, Vector3.ZERO)
	return mi

# Invisible (or attached) box collider.
static func collider(parent: Node, size: Vector3, pos: Vector3) -> StaticBody3D:
	var sb := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = size
	cs.shape = sh
	sb.add_child(cs)
	sb.position = pos
	parent.add_child(sb)
	return sb
