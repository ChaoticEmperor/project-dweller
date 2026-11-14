extends Node3D
# Street clutter and props: vehicles, street furniture, construction, outbreak mess.
#
# Everything static is merged into a few vertex-coloured meshes (one lit + one unshaded
# per map region), so the whole file costs roughly a dozen draw calls on phones.
# Colliders are separate invisible StaticBody3D boxes. Layout is deterministic (fixed seed).
#
# Arms:  N (-Z) taxi jam + pile-up      S (+Z) police roadblock
#        E (+X) crashed bus + bus stop  W (-X) construction site
const B = preload("res://build.gd")
const L = preload("res://layout.gd")

const TAXI := Color(0.95, 0.74, 0.08)
const GLASS := Color(0.13, 0.18, 0.26)
const TYRE := Color(0.07, 0.07, 0.08)
const DARK := Color(0.16, 0.17, 0.19)
const STEEL := Color(0.5, 0.52, 0.55)
const POLE := Color(0.17, 0.22, 0.2)
const WHITE := Color(0.9, 0.9, 0.88)
const ORANGE := Color(0.95, 0.42, 0.06)
const NYPD := Color(0.1, 0.25, 0.62)
const WOOD := Color(0.5, 0.33, 0.18)
const CARD := Color(0.66, 0.5, 0.32)
const BAG := Color(0.09, 0.09, 0.11)
const SHED := Color(0.1, 0.33, 0.2)
const RED := Color(0.8, 0.12, 0.1)
const LAMP_GLOW := Color(1.0, 0.86, 0.55)

const ARM_DIR := [Vector3(0, 0, -1), Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(-1, 0, 0)]
const ARM_PERP := [Vector3(1, 0, 0), Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, 1)]
const FACE_N := [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, -1, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]
const FACE_U := [Vector3(0, 1, 0), Vector3(0, 0, 1), Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0)]
const QUAD := [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]

var _batches := {}
var _obstacles: Array = []
var _lamps: Array = []
var _steam: Array = []
var _rng := RandomNumberGenerator.new()

func build() -> void:
	_rng.seed = 4242
	_corners()
	_lamp_rows()
	_arm_north()
	_arm_south()
	_arm_east()
	_arm_west()
	_centre()
	_litter()
	_flush()

# Big solid props zombies should walk around: [{ "pos": Vector3, "radius": float }, ...]
func obstacles() -> Array:
	return _obstacles

# World positions of street-lamp heads (fx.gd puts lights there).
func lamp_positions() -> Array:
	return _lamps

# Tops of the striped steam chimneys, in case fx.gd wants to puff steam out of them.
func steam_positions() -> Array:
	return _steam

# ---------------------------------------------------------------- helpers

func _xf(x: float, z: float, yaw_deg := 0.0, y := 0.0) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, deg_to_rad(yaw_deg)), Vector3(x, y, z))

# Transform on a sidewalk: arm 0..3 (N,S,E,W), side +1/-1 (towards +x for N/S arms, +z for
# E/W arms), d metres out from the origin, lat metres from the street centre line.
# Local -Z faces the road.
func _sp(arm: int, side: int, d: float, lat: float, extra_yaw := 0.0) -> Transform3D:
	var perp: Vector3 = ARM_PERP[arm] * float(side)
	var p: Vector3 = ARM_DIR[arm] * d + perp * lat
	var yaw := atan2(perp.x, perp.z) + deg_to_rad(extra_yaw)
	return Transform3D(Basis(Vector3.UP, yaw), Vector3(p.x, L.KERB_H, p.z))

func _chunk(p: Vector3) -> int:
	if abs(p.x) < 13.0 and abs(p.z) < 13.0:
		return 0
	if abs(p.z) > abs(p.x):
		return 1 if p.z < 0 else 2
	return 3 if p.x > 0 else 4

# Add a box to the merged mesh. pos/rot are local to t.
func _b(t: Transform3D, size: Vector3, pos: Vector3, col: Color, rot := Basis.IDENTITY, un := false) -> void:
	var x := t * Transform3D(rot, pos)
	var k := _chunk(t.origin) * 2 + (1 if un else 0)
	if not _batches.has(k):
		_batches[k] = [PackedVector3Array(), PackedVector3Array(), PackedColorArray(), PackedInt32Array()]
	var a: Array = _batches[k]
	var vs: PackedVector3Array = a[0]
	var ns: PackedVector3Array = a[1]
	var cs: PackedColorArray = a[2]
	var ix: PackedInt32Array = a[3]
	var h := size * 0.5
	for f in 6:
		var n: Vector3 = FACE_N[f]
		var u: Vector3 = FACE_U[f]
		var v := n.cross(u)
		var wn := (x.basis * n).normalized()
		var i0 := vs.size()
		for c in QUAD:
			vs.append(x * ((n + u * c.x + v * c.y) * h))
			ns.append(wn)
			cs.append(col)
		ix.append_array(PackedInt32Array([i0, i0 + 2, i0 + 1, i0, i0 + 3, i0 + 2]))
	a[0] = vs
	a[1] = ns
	a[2] = cs
	a[3] = ix

func _u(t: Transform3D, size: Vector3, pos: Vector3, col: Color, rot := Basis.IDENTITY) -> void:
	_b(t, size, pos, col, rot, true)

func _flush() -> void:
	for k in _batches:
		var a: Array = _batches[k]
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = a[0]
		arr[Mesh.ARRAY_NORMAL] = a[1]
		arr[Mesh.ARRAY_COLOR] = a[2]
		arr[Mesh.ARRAY_INDEX] = a[3]
		var m := ArrayMesh.new()
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		var mi := MeshInstance3D.new()
		mi.mesh = m
		var un: bool = int(k) % 2 == 1
		mi.material_override = _vmat(un)
		if un:
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
	_batches.clear()

func _vmat(un: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.roughness = 1.0
	if un:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m

# Invisible collider box, local to t.
func _c(t: Transform3D, size: Vector3, pos: Vector3, rot := Basis.IDENTITY) -> void:
	var sb := B.collider(self, size, Vector3.ZERO)
	sb.transform = t * Transform3D(rot, pos)

# Obstacle circles for zombie steering, at the given local points.
func _o(t: Transform3D, r: float, pts := [Vector3.ZERO]) -> void:
	for lp in pts:
		var p: Vector3 = t * lp
		_obstacles.append({"pos": Vector3(p.x, 0, p.z), "radius": r})

func _label(t: Transform3D, text: String, pos: Vector3, yaw_deg: float, px: float, col: Color) -> void:
	var l := Label3D.new()
	l.text = text
	l.font_size = 48
	l.pixel_size = px
	l.modulate = col
	l.outline_size = 0
	l.double_sided = false
	l.alpha_cut = Label3D.ALPHA_CUT_DISCARD
	l.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	l.transform = t * Transform3D(Basis(Vector3.UP, deg_to_rad(yaw_deg)), pos)
	add_child(l)

func _ry(deg: float) -> Basis:
	return Basis(Vector3.UP, deg_to_rad(deg))

# ---------------------------------------------------------------- vehicles (front = local -Z)

func _car(t: Transform3D, col: Color, kind := "", door := 0) -> void:
	_b(t, Vector3(2.0, 0.6, 4.4), Vector3(0, 0.62, 0), col)
	_b(t, Vector3(1.8, 0.5, 2.3), Vector3(0, 1.15, 0.25), GLASS)
	_b(t, Vector3(1.86, 0.5, 0.18), Vector3(0, 1.15, 0.25), col)
	_b(t, Vector3(1.86, 0.1, 2.36), Vector3(0, 1.45, 0.25), col)
	_b(t, Vector3(2.06, 0.2, 0.2), Vector3(0, 0.42, -2.2), DARK)
	_b(t, Vector3(2.06, 0.2, 0.2), Vector3(0, 0.42, 2.2), DARK)
	for sx in [-1.0, 1.0]:
		for sz in [-1.4, 1.4]:
			_b(t, Vector3(0.3, 0.7, 0.7), Vector3(sx * 0.92, 0.35, sz), TYRE)
		_u(t, Vector3(0.45, 0.16, 0.06), Vector3(sx * 0.65, 0.74, -2.21), Color(1, 0.95, 0.7))
		_b(t, Vector3(0.45, 0.16, 0.06), Vector3(sx * 0.65, 0.74, 2.21), Color(0.7, 0.08, 0.08))
	if kind == "taxi":
		_b(t, Vector3(2.03, 0.12, 2.6), Vector3(0, 0.72, 0.2), DARK)
		_u(t, Vector3(0.7, 0.2, 0.28), Vector3(0, 1.6, 0.1), Color(1, 0.95, 0.75))
	elif kind == "police":
		_b(t, Vector3(2.03, 0.16, 4.0), Vector3(0, 0.7, 0), NYPD)
		_b(t, Vector3(1.3, 0.08, 0.36), Vector3(0, 1.53, 0.1), DARK)
		_u(t, Vector3(0.55, 0.16, 0.3), Vector3(-0.35, 1.62, 0.1), Color(1, 0.12, 0.1))
		_u(t, Vector3(0.55, 0.16, 0.3), Vector3(0.35, 1.62, 0.1), Color(0.15, 0.35, 1))
	if door != 0:
		var a := 62.0 * door
		var hinge := Vector3(door * 1.02, 0.66, -0.75)
		_b(t, Vector3(0.1, 0.56, 1.1), hinge + _ry(a) * Vector3(0, 0, 0.55), col, _ry(a))
		_b(t, Vector3(0.08, 0.4, 0.9), hinge + Vector3(0, 0.5, 0) + _ry(a) * Vector3(0, 0, 0.55), GLASS, _ry(a))
	_c(t, Vector3(2.0, 1.45, 4.4), Vector3(0, 0.75, 0))
	_o(t, 1.2, [Vector3(0, 0, -1.1), Vector3(0, 0, 1.1)])

func _van(t: Transform3D, col: Color, stripe: Color, kind := "", doors_open := false) -> void:
	_b(t, Vector3(2.2, 2.0, 3.7), Vector3(0, 1.4, 0.95), col)
	_b(t, Vector3(2.1, 1.5, 1.5), Vector3(0, 1.15, -1.65), col)
	_b(t, Vector3(1.9, 0.6, 0.1), Vector3(0, 1.5, -2.38), GLASS)
	_b(t, Vector3(2.14, 0.5, 0.8), Vector3(0, 1.5, -1.8), GLASS)
	_b(t, Vector3(2.24, 0.3, 3.7), Vector3(0, 1.15, 0.95), stripe)
	_b(t, Vector3(2.2, 0.2, 0.2), Vector3(0, 0.45, -2.4), DARK)
	for sx in [-1.0, 1.0]:
		for sz in [-1.5, 1.8]:
			_b(t, Vector3(0.3, 0.8, 0.8), Vector3(sx * 1.0, 0.4, sz), TYRE)
		_u(t, Vector3(0.4, 0.18, 0.06), Vector3(sx * 0.7, 0.8, -2.41), Color(1, 0.95, 0.7))
	if kind == "ambulance":
		_b(t, Vector3(2.14, 0.25, 1.52), Vector3(0, 1.0, -1.65), stripe)
		_u(t, Vector3(0.6, 0.18, 0.3), Vector3(-0.5, 2.0, -1.5), Color(1, 0.12, 0.1))
		_u(t, Vector3(0.6, 0.18, 0.3), Vector3(0.5, 2.0, -1.5), WHITE)
		for sx in [-1.0, 1.0]:
			_b(t, Vector3(0.06, 0.9, 0.3), Vector3(sx * 1.11, 1.85, 0.95), stripe)
			_b(t, Vector3(0.06, 0.3, 0.9), Vector3(sx * 1.11, 1.85, 0.95), stripe)
	elif kind == "police":
		_u(t, Vector3(0.6, 0.18, 0.3), Vector3(-0.4, 2.0, -1.5), Color(1, 0.12, 0.1))
		_u(t, Vector3(0.6, 0.18, 0.3), Vector3(0.4, 2.0, -1.5), Color(0.15, 0.35, 1))
	if doors_open:
		_b(t, Vector3(2.0, 1.6, 0.1), Vector3(0, 1.4, 2.76), Color(0.1, 0.09, 0.08))
		for sx in [-1.0, 1.0]:
			var a: float = -70.0 * sx
			var hinge := Vector3(sx * 1.1, 1.4, 2.8)
			_b(t, Vector3(1.05, 1.8, 0.08), hinge + _ry(a) * Vector3(-sx * 0.52, 0, 0), col, _ry(a))
	_c(t, Vector3(2.2, 2.4, 5.2), Vector3(0, 1.2, 0.2))
	_o(t, 1.4, [Vector3(0, 0, -1.2), Vector3(0, 0, 1.6)])

func _bus(t: Transform3D) -> void:
	var body := Color(0.86, 0.88, 0.9)
	var blue := Color(0.1, 0.3, 0.66)
	_b(t, Vector3(2.6, 2.85, 11.0), Vector3(0, 1.8, 0), body)
	_b(t, Vector3(2.64, 0.55, 11.02), Vector3(0, 1.2, 0), blue)
	_b(t, Vector3(2.64, 0.9, 9.4), Vector3(0, 2.25, 0.4), GLASS)
	_b(t, Vector3(2.3, 1.25, 0.1), Vector3(0, 2.05, -5.48), GLASS)
	_b(t, Vector3(2.0, 0.4, 0.12), Vector3(0, 2.98, -5.48), Color(0.05, 0.05, 0.05))
	_label(t, "M42 NOPE", Vector3(0, 2.98, -5.56), 180, 0.007, Color(1, 0.6, 0.1))
	_b(t, Vector3(2.66, 0.25, 0.25), Vector3(0, 0.5, -5.45), DARK)
	_b(t, Vector3(2.66, 0.25, 0.25), Vector3(0, 0.5, 5.45), DARK)
	_b(t, Vector3(1.6, 0.3, 2.6), Vector3(0, 3.35, 1.5), Color(0.6, 0.62, 0.65))
	for sx in [-1.0, 1.0]:
		for sz in [-3.7, 3.4]:
			_b(t, Vector3(0.36, 1.0, 1.0), Vector3(sx * 1.2, 0.5, sz), TYRE)
		_u(t, Vector3(0.4, 0.2, 0.06), Vector3(sx * 0.9, 0.85, -5.51), Color(1, 0.95, 0.7))
		_b(t, Vector3(0.3, 0.4, 0.06), Vector3(sx * 1.0, 1.1, 5.51), Color(0.7, 0.08, 0.08))
	# doors (right side), hanging open
	for dz in [-4.4, 0.9]:
		_b(t, Vector3(0.06, 2.1, 1.2), Vector3(1.31, 1.5, dz), Color(0.06, 0.06, 0.08))
		_b(t, Vector3(0.6, 2.0, 0.08), Vector3(1.6, 1.5, dz - 0.62), blue)
		_b(t, Vector3(0.6, 2.0, 0.08), Vector3(1.6, 1.5, dz + 0.62), blue)
	_c(t, Vector3(2.6, 3.1, 11.0), Vector3(0, 1.7, 0))
	_o(t, 1.6, [Vector3(0, 0, -4.3), Vector3(0, 0, -1.45), Vector3(0, 0, 1.45), Vector3(0, 0, 4.3)])

func _hotdog_cart(t: Transform3D) -> void:
	_b(t, Vector3(1.1, 0.9, 2.0), Vector3(0, 0.85, 0), Color(0.72, 0.74, 0.78))
	_b(t, Vector3(1.14, 0.4, 2.04), Vector3(0, 0.75, 0), RED)
	_b(t, Vector3(1.2, 0.06, 2.1), Vector3(0, 1.33, 0), STEEL)
	for sz in [-0.7, 0.7]:
		_b(t, Vector3(1.24, 0.5, 0.5), Vector3(0, 0.25, sz), TYRE)
	_b(t, Vector3(0.1, 1.5, 0.1), Vector3(0, 2.05, 0), STEEL)
	var cols := [Color(0.95, 0.8, 0.1), Color(0.15, 0.35, 0.8)]
	for i in 4:
		var sx := -1.0 if i % 2 == 0 else 1.0
		var sz := -1.0 if i < 2 else 1.0
		_b(t, Vector3(1.1, 0.14, 1.1), Vector3(sx * 0.55, 2.75, sz * 0.55), cols[(i + (1 if i > 1 else 0)) % 2])
	_b(t, Vector3(1.0, 0.16, 1.0), Vector3(0, 2.9, 0), RED)
	# giant hot dog on top, because of course
	_b(t, Vector3(0.36, 0.3, 1.5), Vector3(0, 1.52, 0.1), Color(0.85, 0.65, 0.35))
	_b(t, Vector3(0.22, 0.2, 1.7), Vector3(0, 1.68, 0.1), Color(0.75, 0.25, 0.15))
	_label(t, "HOT DOGS", Vector3(-0.58, 0.75, 0), -90, 0.006, Color(1, 0.9, 0.3))
	_c(t, Vector3(1.2, 1.4, 2.1), Vector3(0, 0.7, 0))
	_o(t, 1.0)

# ---------------------------------------------------------------- street furniture

func _lamp(base: Vector3, dir: Vector3, reach := 1.6) -> void:
	var t := Transform3D(Basis(Vector3.UP, atan2(-dir.x, -dir.z)), base)
	_b(t, Vector3(0.4, 0.9, 0.4), Vector3(0, 0.45, 0), POLE)
	_b(t, Vector3(0.2, 6.3, 0.2), Vector3(0, 3.15, 0), POLE)
	_b(t, Vector3(0.14, 0.14, reach + 0.2), Vector3(0, 6.25, -reach * 0.5), POLE)
	_b(t, Vector3(0.5, 0.18, 0.95), Vector3(0, 6.2, -reach), POLE)
	_u(t, Vector3(0.38, 0.08, 0.8), Vector3(0, 6.08, -reach), LAMP_GLOW)
	_c(t, Vector3(0.3, 6.3, 0.3), Vector3(0, 3.15, 0))
	_lamps.append(t * Vector3(0, 6.05, -reach))

func _signal_head(t: Transform3D, pos: Vector3, face: float, lit: int) -> void:
	_b(t, Vector3(0.36, 1.2, 0.46), pos, Color(0.85, 0.63, 0.08))
	var cols := [Color(1, 0.1, 0.08), Color(1, 0.7, 0.1), Color(0.2, 1, 0.4)]
	for i in 3:
		var p := pos + Vector3(face * 0.19, 0.37 - i * 0.37, 0)
		var c: Color = cols[i]
		if i == lit:
			_u(t, Vector3(0.06, 0.28, 0.28), p, c)
		else:
			_b(t, Vector3(0.06, 0.28, 0.28), p, c.darkened(0.8))

# Corner signal pole: mast arm reaches out along local -Z, heads face local X * face.
func _traffic_light(t: Transform3D, face: float, lit: int) -> void:
	_b(t, Vector3(0.5, 0.6, 0.5), Vector3(0, 0.3, 0), POLE)
	_b(t, Vector3(0.24, 5.8, 0.24), Vector3(0, 2.9, 0), POLE)
	_b(t, Vector3(0.16, 0.16, 4.6), Vector3(0, 5.5, -2.3), POLE)
	_signal_head(t, Vector3(0, 4.85, -4.3), face, lit)
	_signal_head(t, Vector3(0, 4.85, -2.2), face, lit)
	_signal_head(t, Vector3(face * 0.3, 3.5, 0), face, lit)
	# walk / don't-walk boxes
	_b(t, Vector3(0.45, 0.45, 0.3), Vector3(0, 2.55, -0.27), DARK)
	_u(t, Vector3(0.3, 0.3, 0.04), Vector3(0, 2.55, -0.43), Color(1, 0.45, 0.05))
	_b(t, Vector3(0.3, 0.45, 0.45), Vector3(-face * 0.27, 2.55, 0), DARK)
	_u(t, Vector3(0.04, 0.3, 0.3), Vector3(-face * 0.43, 2.55, 0), Color(0.9, 0.95, 1.0))
	_c(t, Vector3(0.4, 5.8, 0.4), Vector3(0, 2.9, 0))

# Green street-name blades on a corner pole (world axes: avenue runs along Z, street along X).
func _street_signs(p: Vector3, labels: bool) -> void:
	var t := Transform3D(Basis.IDENTITY, p)
	var green := Color(0.05, 0.4, 0.2)
	_b(t, Vector3(0.08, 0.34, 1.9), Vector3(0, 4.3, 0), green)
	_b(t, Vector3(1.9, 0.34, 0.08), Vector3(0, 3.92, 0), green)
	if labels:
		_label(t, "BROADWAY", Vector3(0.06, 4.3, 0), 90, 0.0058, WHITE)
		_label(t, "BROADWAY", Vector3(-0.06, 4.3, 0), -90, 0.0058, WHITE)
		_label(t, "W 42 ST", Vector3(0, 3.92, 0.06), 0, 0.0058, WHITE)
		_label(t, "W 42 ST", Vector3(0, 3.92, -0.06), 180, 0.0058, WHITE)

func _hydrant(t: Transform3D) -> void:
	_b(t, Vector3(0.32, 0.6, 0.32), Vector3(0, 0.3, 0), RED)
	_b(t, Vector3(0.4, 0.1, 0.4), Vector3(0, 0.62, 0), STEEL)
	_b(t, Vector3(0.22, 0.16, 0.22), Vector3(0, 0.75, 0), RED)
	_b(t, Vector3(0.56, 0.16, 0.16), Vector3(0, 0.42, 0), RED)
	_c(t, Vector3(0.4, 0.85, 0.4), Vector3(0, 0.42, 0))

func _mailbox(t: Transform3D) -> void:
	var blue := Color(0.1, 0.22, 0.55)
	_b(t, Vector3(0.5, 0.2, 0.5), Vector3(0, 0.1, 0), DARK)
	_b(t, Vector3(0.65, 0.85, 0.65), Vector3(0, 0.62, 0), blue)
	_b(t, Vector3(0.65, 0.2, 0.45), Vector3(0, 1.15, 0), blue)
	_b(t, Vector3(0.45, 0.08, 0.04), Vector3(0, 0.95, -0.34), WHITE)
	_c(t, Vector3(0.65, 1.25, 0.65), Vector3(0, 0.62, 0))
	_o(t, 0.55)

func _news_boxes(t: Transform3D, n: int) -> void:
	var cols := [RED, Color(0.95, 0.8, 0.1), Color(0.15, 0.35, 0.8), Color(0.15, 0.55, 0.25), WHITE]
	var w := 0.55
	for i in n:
		var x := (i - (n - 1) * 0.5) * w
		_b(t, Vector3(0.3, 0.5, 0.3), Vector3(x, 0.25, 0), DARK)
		_b(t, Vector3(0.48, 0.7, 0.42), Vector3(x, 0.8, 0), cols[i % cols.size()])
		_b(t, Vector3(0.36, 0.3, 0.04), Vector3(x, 0.9, -0.21), GLASS)
	_c(t, Vector3(n * w, 1.15, 0.45), Vector3(0, 0.57, 0))
	_o(t, 0.6, [Vector3(-n * w * 0.25, 0, 0), Vector3(n * w * 0.25, 0, 0)])

func _trash(t: Transform3D, bags: int) -> void:
	_b(t, Vector3(0.62, 0.85, 0.62), Vector3(0, 0.43, 0), Color(0.12, 0.3, 0.2))
	_b(t, Vector3(0.7, 0.1, 0.7), Vector3(0, 0.88, 0), DARK)
	_b(t, Vector3(0.5, 0.25, 0.5), Vector3(0, 1.0, 0), BAG, _ry(30))
	for i in bags:
		var a := _rng.randf() * TAU
		var r := _rng.randf_range(0.55, 0.95)
		var s := _rng.randf_range(0.45, 0.7)
		var p := Vector3(cos(a) * r, s * 0.4, abs(sin(a)) * r * 0.6 + 0.1)
		_b(t, Vector3(s, s * 0.8, s), p, BAG if i % 3 != 2 else WHITE.darkened(0.15), _ry(_rng.randf() * 90))
	_c(t, Vector3(0.65, 0.95, 0.65), Vector3(0, 0.47, 0))
	_o(t, 0.55)

func _bench(t: Transform3D) -> void:
	_b(t, Vector3(1.9, 0.1, 0.5), Vector3(0, 0.5, 0), WOOD)
	_b(t, Vector3(1.9, 0.5, 0.1), Vector3(0, 0.9, 0.25), WOOD)
	for sx in [-0.8, 0.8]:
		_b(t, Vector3(0.1, 0.5, 0.5), Vector3(sx, 0.25, 0), DARK)
	_c(t, Vector3(1.9, 1.1, 0.55), Vector3(0, 0.55, 0.05))
	_o(t, 0.6, [Vector3(-0.5, 0, 0), Vector3(0.5, 0, 0)])

func _kiosk(t: Transform3D) -> void:
	_b(t, Vector3(0.95, 2.9, 0.35), Vector3(0, 1.45, 0), Color(0.55, 0.57, 0.6))
	_b(t, Vector3(0.97, 0.5, 0.37), Vector3(0, 0.9, 0), DARK)
	_u(t, Vector3(0.75, 1.4, 0.03), Vector3(0, 2.0, -0.18), Color(0.3, 0.62, 0.95))
	_u(t, Vector3(0.75, 1.4, 0.03), Vector3(0, 2.0, 0.18), Color(0.95, 0.35, 0.6))
	_u(t, Vector3(0.55, 0.3, 0.035), Vector3(0, 2.3, -0.18), WHITE)
	_c(t, Vector3(0.95, 2.9, 0.35), Vector3(0, 1.45, 0))
	_o(t, 0.55)

func _meter(t: Transform3D) -> void:
	_b(t, Vector3(0.1, 1.1, 0.1), Vector3(0, 0.55, 0), STEEL)
	_b(t, Vector3(0.22, 0.32, 0.16), Vector3(0, 1.22, 0), DARK)

func _shelter(t: Transform3D) -> void:
	_b(t, Vector3(4.4, 0.14, 1.7), Vector3(0, 2.55, 0), DARK)
	_b(t, Vector3(4.0, 1.9, 0.08), Vector3(0, 1.4, 0.75), Color(0.5, 0.66, 0.72))
	_b(t, Vector3(0.14, 2.1, 1.3), Vector3(2.0, 1.25, 0.1), DARK)
	_u(t, Vector3(0.03, 1.7, 1.1), Vector3(1.92, 1.3, 0.1), Color(0.95, 0.3, 0.55))
	_u(t, Vector3(0.03, 1.7, 1.1), Vector3(2.08, 1.3, 0.1), Color(0.3, 0.85, 0.9))
	for sx in [-2.0, 2.0]:
		_b(t, Vector3(0.12, 2.5, 0.12), Vector3(sx, 1.25, 0.75), DARK)
	_b(t, Vector3(0.12, 2.5, 0.12), Vector3(-2.0, 1.25, -0.6), DARK)
	_b(t, Vector3(2.6, 0.1, 0.45), Vector3(-0.5, 0.5, 0.45), STEEL)
	_c(t, Vector3(4.0, 2.5, 0.15), Vector3(0, 1.25, 0.75))
	_c(t, Vector3(0.2, 2.5, 1.3), Vector3(2.0, 1.25, 0.1))
	_o(t, 0.6, [Vector3(-1.5, 0, 0.3), Vector3(-0.5, 0, 0.3), Vector3(0.5, 0, 0.3), Vector3(1.5, 0, 0.3)])

func _bus_sign(t: Transform3D) -> void:
	_b(t, Vector3(0.12, 3.0, 0.12), Vector3(0, 1.5, 0), STEEL)
	_b(t, Vector3(0.7, 0.7, 0.08), Vector3(0, 2.9, 0), Color(0.1, 0.3, 0.66))
	_label(t, "BUS", Vector3(0, 2.9, -0.06), 180, 0.008, WHITE)
	_label(t, "BUS", Vector3(0, 2.9, 0.06), 0, 0.008, WHITE)

# Sidewalk shed: runs along local X, kerb side = local -Z.
func _scaffold(t: Transform3D, length: float) -> void:
	var n := int(length / 4.0)
	for i in n + 1:
		var x := -length * 0.5 + i * 4.0
		_b(t, Vector3(0.16, 2.7, 0.16), Vector3(x, 1.35, -1.05), STEEL)
		_b(t, Vector3(0.16, 2.7, 0.16), Vector3(x, 1.35, 1.0), STEEL)
		_b(t, Vector3(0.12, 0.12, 2.1), Vector3(x, 2.55, 0), STEEL)
		_c(t, Vector3(0.22, 2.7, 0.22), Vector3(x, 1.35, -1.05))
		if i < n and i % 2 == 0:
			var rot := Basis(Vector3(0, 0, 1), atan2(2.0, 4.0))
			_b(t, Vector3(4.4, 0.08, 0.08), Vector3(x + 2.0, 1.4, -1.05), STEEL, rot)
			_b(t, Vector3(4.4, 0.08, 0.08), Vector3(x + 2.0, 1.4, -1.05), STEEL, rot.inverse())
	_b(t, Vector3(length + 0.4, 0.16, 2.3), Vector3(0, 2.78, 0), WOOD.darkened(0.2))
	_b(t, Vector3(length + 0.4, 1.0, 0.1), Vector3(0, 3.35, -1.1), SHED)
	for sx in [-1.0, 1.0]:
		_b(t, Vector3(0.1, 1.0, 2.3), Vector3(sx * (length * 0.5 + 0.15), 3.35, 0), SHED)
	_u(t, Vector3(2.6, 0.4, 0.04), Vector3(0, 3.35, -1.16), WHITE)
	_label(t, "POST NO BRAINS", Vector3(0, 3.35, -1.19), 180, 0.005, Color(0.1, 0.1, 0.1))
	_c(t, Vector3(length + 0.4, 1.2, 2.3), Vector3(0, 3.3, 0))

# style 0 = blue police sawhorse, 1 = orange/white construction barricade
func _sawhorse(t: Transform3D, style: int) -> void:
	for sx in [-1.05, 1.05]:
		_b(t, Vector3(0.1, 1.05, 0.55), Vector3(sx, 0.52, 0), NYPD if style == 0 else WHITE)
	if style == 0:
		_b(t, Vector3(2.5, 0.3, 0.1), Vector3(0, 0.95, 0), NYPD)
		_b(t, Vector3(1.6, 0.14, 0.12), Vector3(0, 0.95, 0), WHITE)
	else:
		for i in 5:
			_b(t, Vector3(0.5, 0.3, 0.1), Vector3(-1.0 + i * 0.5, 0.95, 0), ORANGE if i % 2 == 0 else WHITE)
			_b(t, Vector3(0.5, 0.2, 0.1), Vector3(-1.0 + i * 0.5, 0.45, 0), WHITE if i % 2 == 0 else ORANGE)
		_u(t, Vector3(0.2, 0.2, 0.2), Vector3(1.05, 1.2, 0), Color(1, 0.7, 0.1))
	_c(t, Vector3(2.5, 1.1, 0.5), Vector3(0, 0.55, 0))
	_o(t, 0.75, [Vector3(-0.6, 0, 0), Vector3(0.6, 0, 0)])

func _jersey(t: Transform3D, col: Color) -> void:
	_b(t, Vector3(2.0, 0.45, 0.65), Vector3(0, 0.22, 0), col)
	_b(t, Vector3(2.0, 0.5, 0.32), Vector3(0, 0.7, 0), col)
	_c(t, Vector3(2.0, 0.95, 0.6), Vector3(0, 0.47, 0))
	_o(t, 0.7, [Vector3(-0.5, 0, 0), Vector3(0.5, 0, 0)])

func _cone(t: Transform3D) -> void:
	_b(t, Vector3(0.42, 0.06, 0.42), Vector3(0, 0.03, 0), ORANGE)
	_b(t, Vector3(0.28, 0.28, 0.28), Vector3(0, 0.2, 0), ORANGE)
	_b(t, Vector3(0.2, 0.14, 0.2), Vector3(0, 0.41, 0), WHITE)
	_b(t, Vector3(0.13, 0.22, 0.13), Vector3(0, 0.59, 0), ORANGE)

func _cones(pts: Array) -> void:
	# [x, z, knocked(0/1)]
	for c in pts:
		if c[2] == 1:
			var bas := Basis.from_euler(Vector3(0, _rng.randf() * TAU, PI / 2))
			_cone(Transform3D(bas, Vector3(c[0], 0.21, c[1])))
		else:
			_cone(_xf(c[0], c[1], _rng.randf() * 90.0))

func _chimney(t: Transform3D) -> void:
	_b(t, Vector3(1.0, 0.45, 1.0), Vector3(0, 0.22, 0), ORANGE)
	for i in 6:
		_b(t, Vector3(0.55, 0.46, 0.55), Vector3(0, 0.68 + i * 0.46, 0), WHITE if i % 2 == 0 else ORANGE)
	_c(t, Vector3(0.8, 3.2, 0.8), Vector3(0, 1.6, 0))
	_o(t, 0.7)
	_steam.append(t * Vector3(0, 3.25, 0))

func _excavator(t: Transform3D) -> void:
	var yel := Color(0.93, 0.7, 0.08)
	for sx in [-0.8, 0.8]:
		_b(t, Vector3(0.5, 0.6, 2.8), Vector3(sx, 0.3, 0), TYRE)
	_b(t, Vector3(1.9, 0.9, 2.2), Vector3(0, 1.1, 0.2), yel)
	_b(t, Vector3(0.9, 1.0, 1.1), Vector3(-0.45, 2.05, -0.2), GLASS)
	_b(t, Vector3(1.0, 0.1, 1.2), Vector3(-0.45, 2.6, -0.2), yel)
	_b(t, Vector3(1.9, 0.5, 0.7), Vector3(0, 1.8, 1.0), DARK)
	_b(t, Vector3(0.32, 0.32, 2.8), Vector3(0.45, 2.45, -1.6), yel, Basis(Vector3(1, 0, 0), deg_to_rad(38)))
	_b(t, Vector3(0.26, 0.26, 2.2), Vector3(0.45, 2.3, -3.1), yel, Basis(Vector3(1, 0, 0), deg_to_rad(-62)))
	_b(t, Vector3(0.8, 0.5, 0.6), Vector3(0.45, 1.2, -3.55), DARK)
	_c(t, Vector3(1.9, 2.6, 2.8), Vector3(0, 1.3, 0))
	_o(t, 1.5)

func _dumpster(t: Transform3D) -> void:
	var g := Color(0.12, 0.33, 0.3)
	_b(t, Vector3(1.8, 1.25, 3.8), Vector3(0, 0.72, 0), g)
	_b(t, Vector3(1.9, 0.12, 3.9), Vector3(0, 1.35, 0), g.darkened(0.3))
	_b(t, Vector3(1.4, 0.3, 1.4), Vector3(0.1, 1.5, -0.8), CARD, _ry(20))
	_b(t, Vector3(0.3, 0.3, 2.2), Vector3(-0.3, 1.55, 0.7), WOOD, Basis.from_euler(Vector3(0.3, 0.4, 0)))
	_b(t, Vector3(1.0, 0.4, 1.0), Vector3(0.2, 1.5, 1.2), BAG, _ry(40))
	_c(t, Vector3(1.8, 1.4, 3.8), Vector3(0, 0.7, 0))
	_o(t, 1.1, [Vector3(0, 0, -1.0), Vector3(0, 0, 1.0)])

func _potty(t: Transform3D) -> void:
	_b(t, Vector3(1.2, 2.2, 1.2), Vector3(0, 1.1, 0), Color(0.15, 0.4, 0.75))
	_b(t, Vector3(1.3, 0.14, 1.3), Vector3(0, 2.27, 0), WHITE)
	_b(t, Vector3(0.8, 1.8, 0.05), Vector3(0, 1.0, -0.61), Color(0.75, 0.8, 0.85))
	_label(t, "OCCUPIED", Vector3(0, 1.6, -0.65), 180, 0.004, Color(0.85, 0.1, 0.1))
	_c(t, Vector3(1.2, 2.3, 1.2), Vector3(0, 1.15, 0))
	_o(t, 0.85)

func _arrow_board(t: Transform3D) -> void:
	_b(t, Vector3(1.5, 0.25, 1.0), Vector3(0, 0.5, 0), ORANGE)
	for sx in [-0.8, 0.8]:
		_b(t, Vector3(0.2, 0.6, 0.6), Vector3(sx, 0.3, 0), TYRE)
	_b(t, Vector3(0.14, 1.4, 0.14), Vector3(0, 1.3, 0), STEEL)
	_b(t, Vector3(2.2, 1.2, 0.14), Vector3(0, 2.4, 0), Color(0.06, 0.06, 0.07))
	var amber := Color(1, 0.72, 0.1)
	for i in 6:
		_u(t, Vector3(0.16, 0.16, 0.05), Vector3(-0.75 + i * 0.25, 2.4, -0.08), amber)
	for d in [Vector2(0.8, 0), Vector2(0.55, 0.22), Vector2(0.55, -0.22), Vector2(0.3, 0.42), Vector2(0.3, -0.42)]:
		_u(t, Vector3(0.16, 0.16, 0.05), Vector3(d.x, 2.4 + d.y, -0.08), amber)
	_c(t, Vector3(2.2, 3.0, 1.0), Vector3(0, 1.5, 0))
	_o(t, 1.0)

func _work_sign(t: Transform3D) -> void:
	_b(t, Vector3(0.1, 1.2, 0.1), Vector3(0, 0.6, 0), STEEL)
	_b(t, Vector3(0.9, 0.08, 0.7), Vector3(0, 0.04, 0), DARK)
	_b(t, Vector3(1.0, 1.0, 0.06), Vector3(0, 1.75, 0), ORANGE, Basis(Vector3(0, 0, 1), PI / 4))
	_label(t, "ZOMBIES\nAT WORK", Vector3(0, 1.75, -0.05), 180, 0.0042, Color(0.05, 0.05, 0.05))

func _suitcase(t: Transform3D, col: Color) -> void:
	_b(t, Vector3(0.55, 0.75, 0.28), Vector3(0, 0.38, 0), col)
	_b(t, Vector3(0.3, 0.14, 0.08), Vector3(0, 0.82, 0), DARK)

func _suitcases(pts: Array) -> void:
	# [x, z, lying(0/1)] - road level only
	var cols := [Color(0.7, 0.15, 0.2), Color(0.15, 0.3, 0.6), Color(0.2, 0.5, 0.35), Color(0.75, 0.45, 0.12), Color(0.45, 0.2, 0.55)]
	var i := 0
	for s in pts:
		var yaw := _rng.randf() * TAU
		if s[2] == 1:
			_suitcase(Transform3D(Basis.from_euler(Vector3(PI / 2, yaw, 0)), Vector3(s[0], 0.14, s[1])), cols[i % 5])
		else:
			_suitcase(Transform3D(Basis(Vector3.UP, yaw), Vector3(s[0], 0, s[1])), cols[i % 5])
		i += 1

func _boxes(pts: Array) -> void:
	# [x, z, size, y]
	for bx in pts:
		var s: float = bx[2]
		var t := _xf(bx[0], bx[1], _rng.randf() * 90.0, bx[3])
		_b(t, Vector3(s, s * 0.8, s), Vector3(0, s * 0.4, 0), CARD)
		_b(t, Vector3(s * 1.02, s * 0.81, 0.1), Vector3(0, s * 0.4, 0), CARD.darkened(0.25))

func _shopping_cart(t: Transform3D) -> void:
	_b(t, Vector3(0.6, 0.45, 0.95), Vector3(0, 0.75, 0), Color(0.62, 0.64, 0.68))
	_b(t, Vector3(0.5, 0.08, 0.85), Vector3(0, 0.3, 0), STEEL)
	_b(t, Vector3(0.66, 0.08, 0.1), Vector3(0, 1.05, 0.5), RED)
	for sx in [-0.25, 0.25]:
		for sz in [-0.4, 0.4]:
			_b(t, Vector3(0.08, 0.3, 0.14), Vector3(sx, 0.13, sz), TYRE)

# Yellow tape strung between two points.
func _tape(a: Vector3, b: Vector3) -> void:
	var d := b - a
	var t := Transform3D(Basis(Vector3.UP, atan2(d.x, d.z)), (a + b) * 0.5)
	_b(t, Vector3(0.04, 0.14, d.length()), Vector3.ZERO, Color(0.98, 0.85, 0.1))

func _tape_post(x: float, z: float) -> void:
	var t := _xf(x, z)
	_b(t, Vector3(0.4, 0.1, 0.4), Vector3(0, 0.05, 0), DARK)
	_b(t, Vector3(0.1, 1.1, 0.1), Vector3(0, 0.55, 0), ORANGE)

# ---------------------------------------------------------------- placement

func _corners() -> void:
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var p := Vector3(sx * 6.6, 0, sz * 6.6)
			var over_avenue: bool = sx * sz > 0
			# local -Z runs along the mast arm
			var mast := Vector3(-sx, 0, 0) if over_avenue else Vector3(0, 0, -sz)
			var t := Transform3D(Basis(Vector3.UP, atan2(-mast.x, -mast.z)), p)
			# far-side signals: heads face back across the intersection
			var want := Vector3(0, 0, -sz) if over_avenue else Vector3(-sx, 0, 0)
			var face := 1.0 if (t.basis * Vector3(1, 0, 0)).dot(want) > 0 else -1.0
			_traffic_light(t, face, 0 if over_avenue else 2)
			_street_signs(p, over_avenue)
			_lamp(Vector3(sx * 8.2, 0, sz * 8.2), Vector3(-sx, 0, -sz).normalized(), 1.3)

func _lamp_rows() -> void:
	# arm, side, distances
	var rows := [
		[0, 1, [18.0, 34.0]], [0, -1, [26.0, 42.0]],
		[1, -1, [18.0, 34.0]], [1, 1, [26.0, 42.0]],
		[2, -1, [18.0, 34.0]], [2, 1, [26.0, 42.0]],
		[3, -1, [18.0, 34.0]], [3, 1, [26.0, 42.0]],
	]
	for r in rows:
		var perp: Vector3 = ARM_PERP[r[0]] * float(r[1])
		for d in r[2]:
			var p: Vector3 = ARM_DIR[r[0]] * d + perp * 6.35
			_lamp(Vector3(p.x, L.KERB_H, p.z), -perp)

func _arm_north() -> void:
	# taxi jam at the light, pile-up near the far end
	_car(_xf(-3.5, -13.0, 8), TAXI, "taxi", -1)
	_car(_xf(3.2, -15.5, -12), TAXI, "taxi")
	_car(_xf(0.5, -23.0, 35), Color(0.2, 0.35, 0.6), "", 1)
	_car(_xf(3.7, -28.5, 3), TAXI, "taxi", 1)
	_car(_xf(-3.5, -30.0, 190), TAXI, "taxi")
	_car(_xf(-2.0, -35.0, 70), TAXI, "taxi", -1)
	_car(Transform3D(Basis.from_euler(Vector3(0, deg_to_rad(-15), PI)), Vector3(-3.7, 1.52, -38.8)), Color(0.7, 0.15, 0.15))
	_car(Transform3D(Basis.from_euler(Vector3(deg_to_rad(13), deg_to_rad(28), 0)), Vector3(0.2, 0.3, -38.6)), TAXI, "taxi")
	_cones([[1.5, -18.5, 1], [-1.0, -26.5, 0], [2.6, -33.0, 1]])
	_suitcases([[-1.5, -17.5, 1], [5.0, -21.5, 0], [1.6, -31.5, 1], [4.6, -36.5, 0]])
	# sidewalks
	_hotdog_cart(_sp(0, 1, 11.8, 7.4, 90))
	for d in [15.0, 21.5, 25.0]:
		_meter(_sp(0, 1, d, 6.3))
	_news_boxes(_sp(0, 1, 22.0, 8.5), 4)
	_trash(_sp(0, 1, 27.5, 6.75), 4)
	_hydrant(_sp(0, 1, 30.5, 6.5))
	_bench(_sp(0, 1, 38.5, 8.5))
	_mailbox(_sp(0, -1, 12.5, 6.8))
	_kiosk(_sp(0, -1, 30.0, 6.9, 90))
	_boxes([[-8.3, -33.5, 0.7, L.KERB_H], [-8.2, -34.3, 0.6, L.KERB_H], [-8.3, -33.8, 0.5, L.KERB_H + 0.56]])
	_trash(_sp(0, -1, 37.5, 6.75), 3)

func _arm_south() -> void:
	# police roadblock
	_car(_xf(3.4, 12.5, 172), TAXI, "taxi", 1)
	_car(_xf(-3.2, 14.6, 195), Color(0.12, 0.12, 0.14), "", -1)
	_van(_xf(-3.6, 20.5, 172), WHITE, Color(0.85, 0.15, 0.1), "ambulance", true)
	_chimney(_xf(0.6, 21.5))
	var pc1 := _xf(-3.7, 27.0, 60)
	var pc2 := _xf(4.2, 33.0, -52)
	for pc in [pc1, pc2]:
		_car(pc, WHITE, "police", 1)
		_label(pc, "NYPD", Vector3(1.03, 0.92, 0.9), 90, 0.006, NYPD)
		_label(pc, "NYPD", Vector3(-1.03, 0.92, 0.9), -90, 0.006, NYPD)
	_sawhorse(_xf(4.2, 27.0, 4), 0)
	_sawhorse(_xf(-3.9, 33.6, -6), 0)
	_sawhorse(Transform3D(Basis.from_euler(Vector3(PI / 2, deg_to_rad(35), 0)), Vector3(4.9, 0.3, 29.6)), 0)
	_van(_xf(-4.0, 39.3, 4), WHITE, NYPD, "police")
	_tape(Vector3(6.25, 1.05, 26.0), Vector3(5.3, 1.0, 27.1))
	_tape(Vector3(-6.25, 1.05, 34.0), Vector3(-5.1, 1.0, 33.7))
	_tape_post(-1.4, 24.2)
	_tape_post(1.6, 24.0)
	_tape(Vector3(-1.4, 1.0, 24.2), Vector3(1.6, 1.0, 24.0))
	_tape(Vector3(1.6, 1.0, 24.0), Vector3(3.1, 1.0, 26.9))
	_tape(Vector3(-6.25, 1.2, 34.0), Vector3(-8.9, 1.2, 34.0))
	_tape(Vector3(-6.25, 1.2, 18.0), Vector3(-8.9, 1.2, 18.0))
	_cones([[-0.6, 36.5, 0], [1.2, 37.0, 1], [2.8, 36.4, 0], [0.0, 11.0, 1]])
	_suitcases([[1.0, 14.0, 0], [-5.2, 24.0, 1]])
	# sidewalks
	_mailbox(_sp(1, -1, 13.0, 6.8))
	for d in [15.5, 24.5, 29.0]:
		_meter(_sp(1, -1, d, 6.3))
	_hydrant(_sp(1, -1, 22.0, 6.5))
	_bench(_sp(1, -1, 28.5, 8.5))
	_kiosk(_sp(1, -1, 38.5, 6.9, 90))
	_trash(_sp(1, 1, 12.5, 6.75), 3)
	_news_boxes(_sp(1, 1, 30.0, 8.5), 3)
	_hydrant(_sp(1, 1, 36.5, 6.5))
	_boxes([[8.3, 38.5, 0.7, L.KERB_H], [8.1, 39.4, 0.55, L.KERB_H]])

func _arm_east() -> void:
	# crashed bus + bus stop
	_bus(_xf(24.0, -2.6, 70))
	_van(_xf(14.0, 3.5, -80), Color(0.36, 0.24, 0.14), Color(0.9, 0.7, 0.15), "", true)
	_boxes([[10.6, 3.6, 0.7, 0], [10.9, 4.6, 0.6, 0], [10.1, 4.4, 0.55, 0], [10.7, 3.8, 0.5, 0.56], [9.6, 2.6, 0.5, 0]])
	_car(_xf(34.0, 3.2, -105), TAXI, "taxi", 1)
	_car(_xf(37.5, -3.2, 95), Color(0.2, 0.45, 0.3))
	_shopping_cart(Transform3D(Basis.from_euler(Vector3(0, 0.6, PI / 2)), Vector3(11.0, 0.32, -3.4)))
	_suitcases([[19.5, -5.3, 0], [21.0, -5.6, 1], [22.6, -5.2, 0], [17.5, -4.0, 1], [26.0, 2.6, 1], [30.5, 4.4, 0], [16.8, -1.0, 0]])
	_cones([[30.5, -1.0, 1], [31.5, 0.6, 0]])
	# sidewalks
	_bus_sign(_sp(2, -1, 12.0, 6.4))
	_shelter(_sp(2, -1, 15.0, 8.0))
	_kiosk(_sp(2, -1, 27.5, 6.9, 90))
	_mailbox(_sp(2, -1, 31.0, 6.8))
	_trash(_sp(2, -1, 38.0, 6.75), 4)
	_news_boxes(_sp(2, 1, 11.5, 8.5), 3)
	_bench(_sp(2, 1, 16.0, 8.5))
	_trash(_sp(2, 1, 20.5, 6.75), 2)
	_hydrant(_sp(2, 1, 31.0, 6.5))
	for d in [14.0, 18.0, 22.5, 34.5, 38.5]:
		_meter(_sp(2, 1, d, 6.3))

func _arm_west() -> void:
	# construction site: fenced work zone in the north lanes, shed over the north sidewalk
	_scaffold(_sp(3, -1, 28.0, 7.8), 16.0)
	var i := 0
	for x in [-29.0, -26.9, -24.8, -22.7, -20.6, -18.5]:
		var skew := -18.0 if i == 3 else _rng.randf_range(-3.0, 3.0)
		_jersey(_xf(x, -1.2 + (0.5 if i == 3 else 0.0), skew), ORANGE if i % 2 == 0 else WHITE)
		i += 1
	_sawhorse(_xf(-17.3, -3.6, 84), 1)
	_sawhorse(_xf(-30.4, -3.7, 96), 1)
	_excavator(_xf(-25.3, -3.8, 60))
	_potty(_xf(-29.0, -4.9, 180))
	# dirt pile + road plate
	var dirt := Color(0.33, 0.25, 0.17)
	var dt := _xf(-20.8, -4.2, 15)
	_b(dt, Vector3(2.4, 0.6, 2.0), Vector3(0, 0.3, 0), dirt)
	_b(dt, Vector3(1.5, 0.5, 1.2), Vector3(0.1, 0.85, 0), dirt.lightened(0.08))
	_b(dt, Vector3(0.7, 0.4, 0.6), Vector3(0, 1.25, 0.1), dirt)
	_c(dt, Vector3(2.4, 1.0, 2.0), Vector3(0, 0.5, 0))
	_o(dt, 1.3)
	_b(_xf(-22.6, -2.6, 8), Vector3(2.2, 0.06, 1.5), Vector3(0, 0.03, 0), Color(0.25, 0.22, 0.2))
	_arrow_board(_xf(-16.0, -3.6, -90))
	_chimney(_xf(-13.0, -2.6))
	_work_sign(_xf(-11.0, -4.9, -90))
	_car(_xf(-14.0, 3.8, 86), Color(0.55, 0.57, 0.6), "", -1)
	_dumpster(_xf(-33.0, 4.8, 92))
	# pipe stack
	var pt := _xf(-34.0, -4.9, 90)
	for k in 3:
		_b(pt, Vector3(0.45, 0.45, 3.4), Vector3(-0.5 + k * 0.5, 0.23, 0), STEEL if k != 1 else STEEL.darkened(0.2))
	_b(pt, Vector3(0.45, 0.45, 3.4), Vector3(-0.25, 0.68, 0), STEEL.darkened(0.1))
	_b(pt, Vector3(0.45, 0.45, 3.4), Vector3(0.25, 0.68, 0), STEEL)
	_c(pt, Vector3(1.5, 0.9, 3.4), Vector3(0, 0.45, 0))
	_o(pt, 0.9, [Vector3(0, 0, -0.9), Vector3(0, 0, 0.9)])
	_car(_xf(-38.0, 1.6, 110), TAXI, "taxi", 1)
	_jersey(_xf(-40.6, -3.6, 70), Color(0.6, 0.6, 0.58))
	_jersey(_xf(-41.2, 4.6, 110), Color(0.6, 0.6, 0.58))
	_cones([[-12.0, -1.0, 0], [-14.5, -0.9, 0], [-16.8, -0.9, 1], [-31.6, -1.4, 0], [-32.5, -3.0, 1], [-27.5, 0.2, 1],
		[-21.5, 0.4, 0], [-10.4, -3.0, 0], [-36.0, -2.2, 1]])
	_suitcases([[-18.5, 2.2, 1], [-29.5, 3.0, 0]])
	# south sidewalk
	_hydrant(_sp(3, 1, 12.0, 6.5))
	_mailbox(_sp(3, 1, 16.0, 6.8))
	_bench(_sp(3, 1, 20.5, 8.5))
	_trash(_sp(3, 1, 30.0, 6.75), 3)
	_boxes([[-36.0, 8.2, 0.8, L.KERB_H], [-36.9, 8.3, 0.6, L.KERB_H], [-36.2, 8.2, 0.55, L.KERB_H + 0.64], [-38.2, 8.0, 0.7, L.KERB_H]])
	for d in [13.5, 18.0, 22.5]:
		_meter(_sp(3, 1, d, 6.3))
	# cement bags under the shed
	var bag := Color(0.7, 0.68, 0.62)
	var bt := _xf(-24.0, -8.3, 0, L.KERB_H)
	for k in 3:
		_b(bt, Vector3(1.2, 0.25, 0.7), Vector3(0, 0.13 + k * 0.25, 0), bag if k % 2 == 0 else bag.darkened(0.12), _ry(k * 7.0))

func _centre() -> void:
	# the intersection itself stays mostly open: it is the arena
	_car(_xf(3.8, -7.2, 40), TAXI, "taxi", -1)
	_cones([[-5.6, 4.6, 1], [-6.3, -3.2, 0], [5.4, 5.2, 0]])
	_shopping_cart(_xf(-4.8, 7.6, 30))
	_suitcases([[-7.0, 1.5, 1], [6.2, 2.4, 0]])
	_boxes([[-3.0, -8.6, 0.6, 0]])

# ---------------------------------------------------------------- scattered litter (MultiMesh)

func _zone_ok(p: Vector3, r: float, strict: bool) -> bool:
	var ch := L.CORRIDOR_HALF - r
	if abs(p.x) > ch and abs(p.z) > ch:
		return false
	if max(abs(p.x), abs(p.z)) > L.ARM_LEN - 3.0 - r:
		return false
	for s in L.SUBWAY_ENTRANCES:
		var sg: float = sign(s.x)
		var x0: float = min(s.x + sg * 1.5, s.x - sg * 3.5) - r
		var x1: float = max(s.x + sg * 1.5, s.x - sg * 3.5) + r
		if p.x > x0 and p.x < x1 and abs(p.z - s.z) < 3.0 + r:
			return false
	if strict:
		if Vector2(p.x, p.z).length() < 5.0 + r:
			return false
		for sp in L.spawn_points():
			if Vector2(p.x - sp.x, p.z - sp.z).length() < 3.0 + r:
				return false
	return true

func _ground_y(p: Vector3) -> float:
	# -1 means "on a kerb edge or a corner square: skip"
	var ax: float = abs(p.x)
	var az: float = abs(p.z)
	if ax <= 9.0 and az <= 9.0:
		return 0.0 if ax < 5.7 and az < 5.7 else -1.0
	var lat := ax if az > 9.0 else az
	if lat < 5.7:
		return 0.0
	return L.KERB_H if lat > 6.3 else -1.0

func _scatter_pt(strict: bool, r: float) -> Vector3:
	for attempt in 40:
		var along := _rng.randf_range(-45.0, 45.0)
		var lat := _rng.randf_range(-8.6, 8.6)
		var p := Vector3(lat, 0, along) if _rng.randf() < 0.5 else Vector3(along, 0, lat)
		if not _zone_ok(p, r, strict):
			continue
		var y := _ground_y(p)
		if y < 0.0:
			continue
		p.y = y
		return p
	return Vector3(0, -10, 0)

func _litter() -> void:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	mat.vertex_color_is_srgb = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	# flat sheets of paper / newspaper / flyers
	var quad := PlaneMesh.new()
	quad.size = Vector2(0.5, 0.36)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = quad
	mm.instance_count = 240
	var pcols := [Color(0.88, 0.87, 0.82), Color(0.72, 0.72, 0.7), Color(0.8, 0.78, 0.68), Color(0.9, 0.82, 0.3), Color(0.85, 0.5, 0.55)]
	for i in mm.instance_count:
		var p := _scatter_pt(false, 0.3)
		var bas := Basis(Vector3.UP, _rng.randf() * TAU).scaled(Vector3.ONE * _rng.randf_range(0.6, 1.1))
		mm.set_instance_transform(i, Transform3D(bas, p + Vector3(0, 0.02 + (i % 4) * 0.004, 0)))
		mm.set_instance_color(i, pcols[_rng.randi() % (5 if i % 3 == 0 else 3)])
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

	# small chunky junk: cups, cans, bricks, shoes
	var cube := BoxMesh.new()
	cube.size = Vector3(0.2, 0.2, 0.2)
	var mm2 := MultiMesh.new()
	mm2.transform_format = MultiMesh.TRANSFORM_3D
	mm2.use_colors = true
	mm2.mesh = cube
	mm2.instance_count = 110
	var jcols := [Color(0.85, 0.85, 0.85), Color(0.75, 0.15, 0.12), Color(0.15, 0.35, 0.7), Color(0.55, 0.3, 0.2), Color(0.1, 0.1, 0.12), Color(0.3, 0.6, 0.3)]
	for i in mm2.instance_count:
		var p := _scatter_pt(true, 0.3)
		var s := Vector3(_rng.randf_range(0.6, 1.3), _rng.randf_range(0.5, 1.2), _rng.randf_range(0.8, 1.8))
		var bas := Basis(Vector3.UP, _rng.randf() * TAU).scaled(s)
		mm2.set_instance_transform(i, Transform3D(bas, p + Vector3(0, 0.1 * s.y, 0)))
		mm2.set_instance_color(i, jcols[_rng.randi() % jcols.size()])
	var mi2 := MultiMeshInstance3D.new()
	mi2.multimesh = mm2
	mi2.material_override = mat
	mi2.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi2)
