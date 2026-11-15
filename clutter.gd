extends Node3D
# Street clutter and props: vehicles, street furniture, construction, outbreak mess.
#
# clutter.gd owns no nodes of its own any more: world.gd streams the city in pieces and asks
# this file for the props of each piece as a list of small build steps (one or two props
# each, so no frame does much work):
#   inter_steps(tile)      traffic lights, street-name signs and corner lamps of an intersection
#   seg_steps(tile, axis)  one street segment (axis 0 = avenue, 1 = street): lamps, sidewalk
#                          furniture, litter and the segment's theme (L.seg_theme): quiet, taxi,
#                          pileup, roadblock, bus, works, market, el, and the hand-made arms of
#                          the origin intersection (origin_n / s / e / w)
#   block_steps(tile)      what stands inside an open block: park, plaza, parking lot
#   lamp_points(tile)      where the tile's street-lamp heads are (fx.gd lights them)
# Every step writes boxes into world.gd's current mesh (W._box etc.), colliders into
# W.cur_cols and pathfinding obstacles into W.cur_circ / W.cur_rects. All placement is seeded
# from the tile coordinates, so a place always gets the same props.
#
# The clear-lane rule: props on the road stand in "slots" along a segment and each slot keeps
# to one half of the road (0.6 .. 5.6 m from the centre line), so the other half - at least
# 6 m - is free; slots are 9 m apart and at most 5 m long, leaving 4 m to cross over between
# them. Kerb-side things (parked cars, market stalls) keep the middle 7 m free instead.
# Intersections stay open. To add a theme: write a `_theme_x(S, pr, st)` that appends steps,
# keep to the rule, and list it in L.THEMES.
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
const CAR_COLS := [Color(0.2, 0.35, 0.6), Color(0.7, 0.15, 0.15), Color(0.12, 0.12, 0.14), Color(0.55, 0.57, 0.6),
	Color(0.2, 0.45, 0.3), Color(0.85, 0.85, 0.82), Color(0.45, 0.2, 0.55), Color(0.75, 0.45, 0.12)]

const ARM_DIR := [Vector3(0, 0, -1), Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(-1, 0, 0)]
const ARM_PERP := [Vector3(1, 0, 0), Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, 1)]
const SLOT0 := 8.0      # first road slot (metres along the segment) and the slot spacing
const SLOT_D := 9.0

var W: Node3D                               # world.gd (the mesh being built lives there)
var _rng := RandomNumberGenerator.new()

func setup(world: Node3D) -> void:
	W = world

# ---------------------------------------------------------------- helpers

func _xf(x: float, z: float, yaw_deg := 0.0, y := 0.0) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, deg_to_rad(yaw_deg)), Vector3(x, y, z))

# Transform on a sidewalk of the origin intersection: arm 0..3 (N,S,E,W), side +1/-1 (towards
# +x for N/S arms, +z for E/W arms), d metres out from the origin, lat metres from the street
# centre line. Local -Z faces the road.
func _sp(arm: int, side: int, d: float, lat: float, extra_yaw := 0.0) -> Transform3D:
	var perp: Vector3 = ARM_PERP[arm] * float(side)
	var p: Vector3 = ARM_DIR[arm] * d + perp * lat
	var yaw := atan2(perp.x, perp.z) + deg_to_rad(extra_yaw)
	return Transform3D(Basis(Vector3.UP, yaw), Vector3(p.x, L.KERB_H, p.z))

# A street segment of a tile: o = centre line where it leaves the intersection, dir = along it,
# perp = across it (+X for avenues, +Z for streets).
func _seg(t: Dictionary, axis: int) -> Dictionary:
	var org: Vector3 = t.org
	var dir := Vector3(0, 0, 1) if axis == 0 else Vector3(1, 0, 0)
	var perp := Vector3(1, 0, 0) if axis == 0 else Vector3(0, 0, 1)
	return {"o": org + dir * L.CORRIDOR_HALF, "dir": dir, "perp": perp, "yaw": atan2(-dir.x, -dir.z),
		"axis": axis, "t": t}

# Transform on the road of segment S: `along` metres from its start, `lat` metres to the
# perp side of the centre line. At yaw 0 local -Z points along the segment.
func _at(S: Dictionary, along: float, lat: float, yaw_deg := 0.0, y := 0.0) -> Transform3D:
	var p: Vector3 = (S.o as Vector3) + (S.dir as Vector3) * along + (S.perp as Vector3) * lat
	return Transform3D(Basis(Vector3.UP, float(S.yaw) + deg_to_rad(yaw_deg)), Vector3(p.x, y, p.z))

# Transform on a sidewalk of segment S (side +1 = perp side). Local -Z faces the road.
func _sw(S: Dictionary, side: float, along: float, lat: float, extra_yaw := 0.0) -> Transform3D:
	var perp: Vector3 = (S.perp as Vector3) * side
	var p: Vector3 = (S.o as Vector3) + (S.dir as Vector3) * along + perp * lat
	return Transform3D(Basis(Vector3.UP, atan2(perp.x, perp.z) + deg_to_rad(extra_yaw)), Vector3(p.x, L.KERB_H, p.z))

# Add a box to the mesh being built. pos/rot are local to t. un = unshaded (glows).
func _b(t: Transform3D, size: Vector3, pos: Vector3, col: Color, rot := Basis.IDENTITY, un := false) -> void:
	var x := t * Transform3D(rot, pos)
	W._box(W.glow if un else W.flat, size, x.origin, col, x.basis)

func _u(t: Transform3D, size: Vector3, pos: Vector3, col: Color, rot := Basis.IDENTITY) -> void:
	_b(t, size, pos, col, rot, true)

# Invisible collider box, local to t.
func _c(t: Transform3D, size: Vector3, pos: Vector3, rot := Basis.IDENTITY) -> void:
	W.cur_cols.append([t * Transform3D(rot, pos), size])

# Obstacle circles for zombie pathfinding, at the given local points.
func _o(t: Transform3D, r: float, pts := [Vector3.ZERO]) -> void:
	for lp: Vector3 in pts:
		var p: Vector3 = t * lp
		W.cur_circ.append(p.x)
		W.cur_circ.append(p.z)
		W.cur_circ.append(r)

# Small glowing pixel text on a prop (reads from the local +Z side at yaw 0).
func _label(t: Transform3D, text: String, pos: Vector3, yaw_deg: float, px: float, col: Color) -> void:
	var x := t * Transform3D(Basis(Vector3.UP, deg_to_rad(yaw_deg)), pos)
	var lines := text.split("\n")
	var s := px * 7.0
	for i in lines.size():
		W._text(W.glow, lines[i], x.origin + x.basis.y * (((lines.size() - 1) * 0.5 - i) * s * 6.5), x.basis.z, s, col, x.basis.y)

func _ry(deg: float) -> Basis:
	return Basis(Vector3.UP, deg_to_rad(deg))

func _seeded(seed_i: int, fn: Callable) -> void:
	_rng.seed = seed_i
	fn.call()

# Give every step its own seed, so what it draws does not depend on build order.
func _wrap(steps: Array, t: Dictionary, salt: int) -> Array:
	var out: Array = []
	for i in steps.size():
		out.append(_seeded.bind(L.hash3(t.bx, t.bz, salt * 1000 + i), steps[i]))
	return out

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

# Green street-name blades on a corner pole (the avenue blade runs along Z, the street blade along X).
func _street_signs(p: Vector3, avenue: String, street: String) -> void:
	var t := Transform3D(Basis.IDENTITY, p)
	var green := Color(0.05, 0.4, 0.2)
	_b(t, Vector3(0.08, 0.34, 1.9), Vector3(0, 4.3, 0), green)
	_b(t, Vector3(1.9, 0.34, 0.08), Vector3(0, 3.92, 0), green)
	if avenue != "":
		var px := minf(0.045, 1.7 / (avenue.length() * 4.0))
		W._text(W.glow, avenue, p + Vector3(0.06, 4.3, 0), Vector3.RIGHT, px, WHITE)
		W._text(W.glow, avenue, p + Vector3(-0.06, 4.3, 0), Vector3.LEFT, px, WHITE)
		px = minf(0.045, 1.7 / (street.length() * 4.0))
		W._text(W.glow, street, p + Vector3(0, 3.92, 0.06), Vector3.BACK, px, WHITE)
		W._text(W.glow, street, p + Vector3(0, 3.92, -0.06), Vector3.FORWARD, px, WHITE)

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

# A market stall: long axis local Z (along the street).
func _stall(t: Transform3D, col: Color) -> void:
	_b(t, Vector3(1.2, 0.9, 2.6), Vector3(0, 0.45, 0), WOOD)
	_b(t, Vector3(1.26, 0.3, 2.66), Vector3(0, 0.75, 0), col.darkened(0.3))
	for sx in [-0.65, 0.65]:
		for sz in [-1.35, 1.35]:
			_b(t, Vector3(0.08, 2.5, 0.08), Vector3(sx, 1.25, sz), STEEL)
	for i in 4:
		_b(t, Vector3(1.9, 0.1, 0.72), Vector3(0, 2.55, -1.08 + i * 0.72), col if i % 2 == 0 else WHITE)
	var goods := [Color(0.85, 0.3, 0.1), Color(0.3, 0.6, 0.2), Color(0.9, 0.75, 0.15), Color(0.6, 0.2, 0.5), RED]
	for i in 3:
		_b(t, Vector3(0.8, 0.3, 0.6), Vector3(0, 1.05, -0.8 + i * 0.8), goods[_rng.randi() % goods.size()])
	_u(t, Vector3(0.2, 0.2, 0.2), Vector3(0, 2.3, 0), LAMP_GLOW)
	_c(t, Vector3(1.4, 2.6, 2.8), Vector3(0, 1.3, 0))
	_o(t, 0.85, [Vector3(0, 0, -0.7), Vector3(0, 0, 0.7)])

# A parked car seen from a distance: a third of the boxes of _car.
func _car_lo(t: Transform3D, col: Color) -> void:
	_b(t, Vector3(2.0, 0.6, 4.4), Vector3(0, 0.62, 0), col)
	_b(t, Vector3(1.8, 0.5, 2.3), Vector3(0, 1.15, 0.25), GLASS)
	_b(t, Vector3(1.86, 0.1, 2.36), Vector3(0, 1.45, 0.25), col)
	for sz in [-1.4, 1.4]:
		_b(t, Vector3(2.14, 0.7, 0.7), Vector3(0, 0.35, sz), TYRE)
	_b(t, Vector3(1.7, 0.16, 0.06), Vector3(0, 0.74, -2.21), Color(0.8, 0.76, 0.56))
	_b(t, Vector3(1.7, 0.16, 0.06), Vector3(0, 0.74, 2.21), Color(0.7, 0.08, 0.08))
	_c(t, Vector3(2.0, 1.45, 4.4), Vector3(0, 0.75, 0))
	_o(t, 1.2, [Vector3(0, 0, -1.1), Vector3(0, 0, 1.1)])

# ---------------------------------------------------------------- lamps

# Every street lamp of a tile: [base, direction toward the road, reach, unit id, corner lamp?].
func _lamp_specs(t: Dictionary) -> Array:
	var out: Array = []
	var o: Vector3 = t.org
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			out.append([Vector3(o.x + sx * 8.2, 0, o.z + sz * 8.2), Vector3(-sx, 0, -sz).normalized(), 1.3, 4, true])
	var ents: Array = L.subway_entrances(t.bx, t.bz)
	for axis in 2:
		var S := _seg(t, axis)
		var so: Vector3 = S.o
		var sdir: Vector3 = S.dir
		for side: float in [1.0, -1.0]:
			var perp: Vector3 = (S.perp as Vector3) * side
			var a := 9.0 if side > 0 else 17.0
			while a < 60.0:
				var p: Vector3 = so + sdir * a + perp * 6.35
				var ok := true
				if axis == 0:
					for e: Dictionary in ents:
						var ep: Vector3 = e.pos
						if signf(ep.x - o.x) == side and absf(ep.z - p.z) < 4.5:
							ok = false
				if ok:
					out.append([Vector3(p.x, L.KERB_H, p.z), -perp, 1.6, 4 + axis, false])
				a += 16.0
	var b: Dictionary = t.b
	var c: Vector2 = (b.rect as Rect2).get_center()
	var h := L.KERB_H
	match String(b.type):
		"park":
			for s: float in [-1.0, 1.0]:
				out.append([Vector3(c.x + s * 3.0, h, c.y + s * 16.0), Vector3(-s, 0, 0), 1.6, 6, false])
				out.append([Vector3(c.x + s * 16.0, h, c.y - s * 3.0), Vector3(0, 0, s), 1.6, 6, false])
		"plaza":
			for sx: float in [-1.0, 1.0]:
				for sz: float in [-1.0, 1.0]:
					out.append([Vector3(c.x + sx * 25.0, h, c.y + sz * 25.0), Vector3(-sx, 0, -sz).normalized(), 1.6, 6, false])
		"parking":
			for s: float in [-1.0, 1.0]:
				out.append([Vector3(c.x + s * 14.0, h, c.y), Vector3(-s, 0, 0), 1.6, 6, false])
	return out

# World positions of the tile's street-lamp heads (fx.gd puts lights there).
func lamp_points(t: Dictionary) -> Array:
	var out: Array = []
	for sp: Array in _lamp_specs(t):
		var d: Vector3 = sp[1]
		out.append(Transform3D(Basis(Vector3.UP, atan2(-d.x, -d.z)), sp[0]) * Vector3(0, 6.05, -float(sp[2])))
	return out

func _lamps_of(t: Dictionary, unit: int, corner: bool) -> void:
	for sp: Array in _lamp_specs(t):
		if int(sp[3]) == unit and bool(sp[4]) == corner:
			_lamp(sp[0], sp[1], sp[2])

# ---------------------------------------------------------------- intersections

func inter_steps(t: Dictionary) -> Array:
	var o: Vector3 = t.org
	var st: Array = []
	var ave := L.avenue_name(t.bx)
	for sz: float in [-1.0, 1.0]:
		var f := func() -> void:
			for sx: float in [-1.0, 1.0]:
				var p := Vector3(o.x + sx * 6.6, 0, o.z + sz * 6.6)
				var over_avenue: bool = sx * sz > 0
				# local -Z runs along the mast arm
				var mast := Vector3(-sx, 0, 0) if over_avenue else Vector3(0, 0, -sz)
				var tr := Transform3D(Basis(Vector3.UP, atan2(-mast.x, -mast.z)), p)
				# far-side signals: heads face back across the intersection
				var want := Vector3(0, 0, -sz) if over_avenue else Vector3(-sx, 0, 0)
				var face := 1.0 if (tr.basis * Vector3(1, 0, 0)).dot(want) > 0 else -1.0
				_traffic_light(tr, face, 0 if over_avenue else 2)
				_street_signs(p, ave if over_avenue else "", L.street_name(t.bz, sx > 0))
		st.append(f)
	st.append(_lamps_of.bind(t, 4, true))
	if t.bx == 0 and t.bz == 0:
		st.append(_centre)
	elif L.hash3(t.bx, t.bz, 90) % 100 < 15:
		var q := 1.0 if L.hash3(t.bx, t.bz, 91) % 2 == 0 else -1.0
		var tr := _xf(o.x + q * 3.8, o.z - q * 7.2, 40.0 * q)
		var f := func() -> void: _car(tr, TAXI, "taxi", -1)
		st.append(f)
	return _wrap(st, t, 1)

func _centre() -> void:
	# the origin intersection stays mostly open: it is the arena
	_car(_xf(3.8, -7.2, 40), TAXI, "taxi", -1)
	_cones([[-5.6, 4.6, 1], [-6.3, -3.2, 0], [5.4, 5.2, 0]])
	_shopping_cart(_xf(-4.8, 7.6, 30))
	_suitcases([[-7.0, 1.5, 1], [6.2, 2.4, 0]])
	_boxes([[-3.0, -8.6, 0.6, 0]])

# ---------------------------------------------------------------- street segments

func seg_steps(t: Dictionary, axis: int) -> Array:
	var S := _seg(t, axis)
	var theme: String = L.seg_theme(axis, t.bx, t.bz)
	var pr := RandomNumberGenerator.new()
	pr.seed = L.hash3(t.bx, t.bz, 70 + axis)
	var st: Array = []
	var skip: Array = []     # [side, from, to]: stretches of sidewalk that take no furniture
	st.append(_lamps_of.bind(t, 4 + axis, false))
	match theme:
		"origin_n": st.append_array(_arm_north())
		"origin_s": st.append_array(_arm_south())
		"origin_e": st.append_array(_arm_east())
		"origin_w": st.append_array(_arm_west())
		"taxi": _theme_taxi(S, pr, st)
		"quiet": _theme_parked(S, pr, st, 4.9, 0.22)
		"el": _theme_parked(S, pr, st, 5.0, 0.3)
		"pileup": _theme_pileup(S, pr, st)
		"roadblock": _theme_roadblock(S, pr, st)
		"bus": _theme_bus(S, pr, st, skip)
		"works": _theme_works(S, pr, st, skip)
		"market": _theme_market(S, pr, st)
	if not theme.begins_with("origin"):
		if axis == 0:
			for e: Dictionary in L.subway_entrances(t.bx, t.bz):
				var ep: Vector3 = e.pos
				var a: float = ep.z - (S.o as Vector3).z
				skip.append([signf(ep.x - (t.org as Vector3).x), a - 5.0, a + 5.0])
		_furniture(S, pr, st, skip, 0.25 if theme == "market" else 0.45)
	st.append(_litter.bind(S))
	return _wrap(st, t, 2 + axis)

func _slot(i: int) -> float:
	return SLOT0 + i * SLOT_D

func _sgn(pr: RandomNumberGenerator) -> float:
	return 1.0 if pr.randf() < 0.5 else -1.0

func _add_car(S: Dictionary, pr: RandomNumberGenerator, st: Array, along: float, lat: float, yaw: float, taxi_p: float) -> void:
	var taxi := pr.randf() < taxi_p
	var col: Color = TAXI if taxi else CAR_COLS[pr.randi() % CAR_COLS.size()]
	var door := 0
	if pr.randf() < 0.3:
		door = 1 if pr.randf() < 0.5 else -1
	var tr := _at(S, along, lat, yaw)
	var f := func() -> void: _car(tr, col, "taxi" if taxi else "", door)
	st.append(f)

# Cones and dropped luggage near the given road spots (no collision: decoration).
func _add_mess(S: Dictionary, pr: RandomNumberGenerator, st: Array, spots: Array) -> void:
	var cones: Array = []
	var cases: Array = []
	for sp: Vector2 in spots:
		for k in 2:
			var p := _at(S, sp.x + pr.randf_range(-3.0, 3.0), clampf(sp.y + pr.randf_range(-2.0, 2.0), -5.5, 5.5)).origin
			if pr.randf() < 0.5:
				cones.append([p.x, p.z, pr.randi() % 2])
			else:
				cases.append([p.x, p.z, pr.randi() % 2])
	if cones.is_empty() and cases.is_empty():
		return
	var f := func() -> void:
		_cones(cones)
		_suitcases(cases)
	st.append(f)

# Cars parked along both kerbs (the middle of the road stays free).
func _theme_parked(S: Dictionary, pr: RandomNumberGenerator, st: Array, lat: float, p: float) -> void:
	for i in 6:
		for side: float in [1.0, -1.0]:
			if pr.randf() >= p:
				continue
			var yaw := (180.0 if pr.randf() < 0.5 else 0.0) + pr.randf_range(-3.0, 3.0)
			if pr.randf() < 0.12 and lat < 4.95:
				var tr := _at(S, _slot(i), side * 4.8, yaw)
				var brown := pr.randf() < 0.5
				var f := func() -> void:
					if brown:
						_van(tr, Color(0.36, 0.24, 0.14), Color(0.9, 0.7, 0.15))
					else:
						_van(tr, WHITE, Color(0.2, 0.4, 0.7))
				st.append(f)
			else:
				_add_car(S, pr, st, _slot(i), side * lat, yaw, 0.25)

# Abandoned traffic: a car in most slots, each keeping to one half of the road.
func _theme_taxi(S: Dictionary, pr: RandomNumberGenerator, st: Array) -> void:
	var spots: Array = []
	for i in 6:
		if pr.randf() >= 0.65:
			continue
		var side := _sgn(pr)
		var lat := side * pr.randf_range(2.5, 3.7)
		var along := _slot(i) + pr.randf_range(-0.4, 0.4)
		_add_car(S, pr, st, along, lat, pr.randf_range(-14.0, 14.0) + (180.0 if pr.randf() < 0.3 else 0.0), 0.7)
		if pr.randf() < 0.4:
			spots.append(Vector2(along, lat))
	_add_mess(S, pr, st, spots)

func _theme_pileup(S: Dictionary, pr: RandomNumberGenerator, st: Array) -> void:
	var s := _sgn(pr)
	var k0 := 1 + pr.randi() % 3
	for i in 6:
		if i == k0:
			_add_car(S, pr, st, _slot(i), s * 3.1, 35.0, 0.5)
		elif i == k0 + 1:
			var p := _at(S, _slot(i), s * 2.7).origin
			var tr := Transform3D(Basis.from_euler(Vector3(0, float(S.yaw) + deg_to_rad(-15.0), PI)), Vector3(p.x, 1.52, p.z))
			var col: Color = CAR_COLS[pr.randi() % CAR_COLS.size()]
			var f := func() -> void: _car(tr, col)
			st.append(f)
		elif i == k0 + 2:
			_add_car(S, pr, st, _slot(i), s * 3.2, 70.0, 1.0)
		elif pr.randf() < 0.35:
			_add_car(S, pr, st, _slot(i), _sgn(pr) * pr.randf_range(2.5, 3.7), pr.randf_range(-14.0, 14.0), 0.7)
	_add_mess(S, pr, st, [Vector2(_slot(k0), s * 3.0), Vector2(_slot(k0 + 1), s * 3.0), Vector2(_slot(k0 + 2), s * 3.0)])

func _theme_roadblock(S: Dictionary, pr: RandomNumberGenerator, st: Array) -> void:
	var s := _sgn(pr)
	if pr.randf() < 0.4:
		_add_car(S, pr, st, _slot(0), -s * 3.0, pr.randf_range(-10.0, 10.0), 0.6)
	var amb := _at(S, _slot(1), -s * 3.4, 172.0)
	var f1 := func() -> void: _van(amb, WHITE, Color(0.85, 0.15, 0.1), "ambulance", true)
	st.append(f1)
	var pc1 := _at(S, _slot(2), s * 3.2, 60.0)
	var pc2 := _at(S, _slot(4), -s * 3.2, -52.0)
	for pc: Transform3D in [pc1, pc2]:
		var f := func() -> void:
			_car(pc, WHITE, "police", 1)
			_label(pc, "NYPD", Vector3(1.03, 0.92, 0.9), 90, 0.006, NYPD)
			_label(pc, "NYPD", Vector3(-1.03, 0.92, 0.9), -90, 0.006, NYPD)
		st.append(f)
	var sh := _at(S, _slot(3), s * 3.4, 4.0)
	var a := _at(S, _slot(3), s * 4.7).origin
	var b := _at(S, _slot(2) + 1.6, s * 4.9).origin
	var pvan := _at(S, _slot(5), s * 3.6, 4.0)
	var f2 := func() -> void:
		_sawhorse(sh, 0)
		_tape(a + Vector3(0, 1.0, 0), b + Vector3(0, 1.0, 0))
		_van(pvan, WHITE, NYPD, "police")
	st.append(f2)
	_add_mess(S, pr, st, [Vector2(_slot(3), s * 3.0), Vector2(_slot(1), -s * 3.0)])

func _theme_bus(S: Dictionary, pr: RandomNumberGenerator, st: Array, skip: Array) -> void:
	var s := _sgn(pr)
	if pr.randf() < 0.4:
		_add_car(S, pr, st, _slot(0), -s * 3.0, pr.randf_range(-10.0, 10.0), 0.6)
	var bt := _at(S, 20.0, s * 3.3, pr.randf_range(-6.0, 6.0) + (180.0 if pr.randf() < 0.5 else 0.0))
	var f1 := func() -> void: _bus(bt)
	st.append(f1)
	var vt := _at(S, _slot(3), -s * 3.4, pr.randf_range(-10.0, 10.0))
	var bp := _at(S, _slot(3) - 1.0, -s * 1.2).origin
	var f2 := func() -> void:
		_van(vt, Color(0.36, 0.24, 0.14), Color(0.9, 0.7, 0.15), "", true)
		_boxes([[bp.x, bp.z, 0.7, 0], [bp.x + 0.4, bp.z + 0.9, 0.6, 0], [bp.x - 0.5, bp.z + 0.5, 0.55, 0]])
	st.append(f2)
	if pr.randf() < 0.5:
		_add_car(S, pr, st, _slot(4), s * 3.1, pr.randf_range(-12.0, 12.0), 0.7)
	if pr.randf() < 0.4:
		_add_car(S, pr, st, _slot(5), _sgn(pr) * 3.1, pr.randf_range(-12.0, 12.0), 0.7)
	var f3 := func() -> void:
		_bus_sign(_sw(S, s, 12.0, 6.4))
		_shelter(_sw(S, s, 16.0, 8.0))
	st.append(f3)
	skip.append([s, 9.0, 23.0])
	_add_mess(S, pr, st, [Vector2(20.0, s * 3.5), Vector2(24.0, s * 2.5)])

# Road works: one half of the road fenced off for 28 m.
func _theme_works(S: Dictionary, pr: RandomNumberGenerator, st: Array, skip: Array) -> void:
	var s := _sgn(pr)
	var f1 := func() -> void:
		for k in 12:
			_jersey(_at(S, 15.5 + k * 2.1, s * 0.9, 90.0 + _rng.randf_range(-3.0, 3.0)), ORANGE if k % 2 == 0 else WHITE)
	st.append(f1)
	var f2 := func() -> void:
		_excavator(_at(S, 23.0, s * 3.6, 20.0))
		_potty(_at(S, 31.0, s * 4.7, 180.0))
	st.append(f2)
	var f3 := func() -> void:
		var dirt := Color(0.33, 0.25, 0.17)
		var dt := _at(S, 18.2, s * 4.0, 15.0)
		_b(dt, Vector3(2.4, 0.6, 2.0), Vector3(0, 0.3, 0), dirt)
		_b(dt, Vector3(1.5, 0.5, 1.2), Vector3(0.1, 0.85, 0), dirt.lightened(0.08))
		_b(dt, Vector3(0.7, 0.4, 0.6), Vector3(0, 1.25, 0.1), dirt)
		_c(dt, Vector3(2.4, 1.0, 2.0), Vector3(0, 0.5, 0))
		_o(dt, 1.3)
		_b(_at(S, 27.5, s * 2.6, 8.0), Vector3(2.2, 0.06, 1.5), Vector3(0, 0.03, 0), Color(0.25, 0.22, 0.2))
		var pt := _at(S, 36.0, s * 4.6)
		for k in 3:
			_b(pt, Vector3(0.45, 0.45, 3.4), Vector3(-0.5 + k * 0.5, 0.23, 0), STEEL if k != 1 else STEEL.darkened(0.2))
		_b(pt, Vector3(0.45, 0.45, 3.4), Vector3(-0.25, 0.68, 0), STEEL.darkened(0.1))
		_b(pt, Vector3(0.45, 0.45, 3.4), Vector3(0.25, 0.68, 0), STEEL)
		_c(pt, Vector3(1.5, 0.9, 3.4), Vector3(0, 0.45, 0))
		_o(pt, 0.9, [Vector3(0, 0, -0.9), Vector3(0, 0, 0.9)])
	st.append(f3)
	var f4 := func() -> void:
		_sawhorse(_at(S, 13.2, s * 3.3, 6.0), 1)
		_sawhorse(_at(S, 41.3, s * 3.3, -8.0), 1)
		_arrow_board(_at(S, 16.2, s * 3.4, 180.0))
		_chimney(_at(S, 39.0, s * 2.8))
		_work_sign(_at(S, 11.5, s * 4.8, 180.0))
		var cs: Array = []
		for k in 6:
			var p := _at(S, 12.0 + k * 6.0, s * _rng.randf_range(1.6, 2.4)).origin
			cs.append([p.x, p.z, 1 if k % 3 == 2 else 0])
		_cones(cs)
	st.append(f4)
	var f5 := func() -> void:
		_scaffold(_sw(S, s, 28.0, 7.8), 16.0)
		var bag := Color(0.7, 0.68, 0.62)
		var bt := _sw(S, s, 24.0, 8.3)
		for k in 3:
			_b(bt, Vector3(1.2, 0.25, 0.7), Vector3(0, 0.13 + k * 0.25, 0), bag if k % 2 == 0 else bag.darkened(0.12), _ry(k * 7.0))
	st.append(f5)
	skip.append([s, 17.0, 39.0])
	if pr.randf() < 0.4:
		_add_car(S, pr, st, _slot(5), _sgn(pr) * 3.1, pr.randf_range(-12.0, 12.0), 0.5)

# Street market: stalls along both kerbs, strings of bulbs overhead.
func _theme_market(S: Dictionary, pr: RandomNumberGenerator, st: Array) -> void:
	var cols := [RED, Color(0.15, 0.35, 0.8), Color(0.15, 0.55, 0.25), Color(0.9, 0.6, 0.1), Color(0.6, 0.2, 0.55)]
	for side: float in [1.0, -1.0]:
		var a := 6.0
		while a < 58.0:
			var r := pr.randf()
			var tr := _at(S, a, side * 5.0, 0.0 if side > 0 else 180.0)
			var col: Color = cols[pr.randi() % cols.size()]
			if r < 0.5:
				var f := func() -> void: _stall(tr, col)
				st.append(f)
			elif r < 0.62:
				var f := func() -> void: _hotdog_cart(tr)
				st.append(f)
			elif r < 0.75:
				var p := tr.origin
				var f := func() -> void: _boxes([[p.x, p.z, 0.8, 0], [p.x + 0.7, p.z + 0.5, 0.6, 0], [p.x + 0.1, p.z + 0.1, 0.5, 0.64]])
				st.append(f)
			a += 6.5
	var f2 := func() -> void:
		var bulbs := [Color(1, 0.3, 0.25), Color(1, 0.85, 0.3), Color(0.35, 0.9, 0.5), Color(0.4, 0.6, 1.0)]
		for a2: float in [10.0, 24.0, 38.0, 52.0]:
			var tr := _at(S, a2, 0.0)
			_b(tr, Vector3(13.0, 0.04, 0.04), Vector3(0, 5.6, 0), DARK)
			for k in 8:
				_u(tr, Vector3(0.22, 0.22, 0.22), Vector3(-5.6 + k * 1.6, 5.45, 0), bulbs[k % 4])
	st.append(f2)

# Sidewalk furniture in slots between the lamps.
func _furniture(S: Dictionary, pr: RandomNumberGenerator, st: Array, skip: Array, density: float) -> void:
	for side: float in [1.0, -1.0]:
		var plan: Array = []
		for i in 8:
			var a := 5.0 + i * 8.0
			var kind := pr.randi() % 8
			var extra := pr.randi()
			if pr.randf() > density:
				continue
			var blocked := false
			for sk: Array in skip:
				if float(sk[0]) == side and a > float(sk[1]) and a < float(sk[2]):
					blocked = true
			if not blocked:
				plan.append([kind, a, extra])
		if plan.is_empty():
			continue
		var f := func() -> void:
			for it: Array in plan:
				var a: float = it[1]
				match int(it[0]):
					0, 1:
						_meter(_sw(S, side, a, 6.3))
						_meter(_sw(S, side, a + 2.0, 6.3))
					2: _hydrant(_sw(S, side, a, 6.5))
					3: _trash(_sw(S, side, a, 6.75), 2 + int(it[2]) % 3)
					4: _mailbox(_sw(S, side, a, 6.8))
					5: _kiosk(_sw(S, side, a, 6.9, 90))
					6: _bench(_sw(S, side, a, 8.5))
					_: _news_boxes(_sw(S, side, a, 8.5), 3 + int(it[2]) % 2)
		st.append(f)

# Scattered paper and small junk (no collision).
func _litter(S: Dictionary) -> void:
	var so: Vector3 = S.o
	var sdir: Vector3 = S.dir
	var sperp: Vector3 = S.perp
	var holes: Array = L.subway_entrances(S.t.bx, S.t.bz) if int(S.axis) == 0 else []
	var pcols := [Color(0.88, 0.87, 0.82), Color(0.72, 0.72, 0.7), Color(0.8, 0.78, 0.68), Color(0.9, 0.82, 0.3), Color(0.85, 0.5, 0.55)]
	var jcols := [Color(0.85, 0.85, 0.85), Color(0.75, 0.15, 0.12), Color(0.15, 0.35, 0.7), Color(0.55, 0.3, 0.2), Color(0.1, 0.1, 0.12), Color(0.3, 0.6, 0.3)]
	for i in 30:
		var lat := _rng.randf_range(-8.6, 8.6)
		var al := absf(lat)
		var p := so + sdir * _rng.randf_range(1.0, 63.0) + sperp * lat
		var yaw := _rng.randf() * TAU
		var k := _rng.randf()
		var ok := not (al > 5.7 and al < 6.3)
		for e: Dictionary in holes:
			var ep: Vector3 = e.pos
			if absf(p.x - ep.x) < 2.0 and absf(p.z - ep.z) < 3.5:
				ok = false
		if not ok:
			continue
		p.y = 0.0 if al < 6.0 else L.KERB_H
		var bas := Basis(Vector3.UP, yaw)
		if i < 21:
			var s := 0.6 + k * 0.5
			var ax := bas.x * (0.25 * s)
			var az := bas.z * (0.18 * s)
			var q := p + Vector3(0, 0.02 + (i % 4) * 0.004, 0)
			W._quad(W.flat, q - ax - az, q + ax - az, q + ax + az, q - ax + az, Vector3.UP, pcols[i % (5 if i % 3 == 0 else 3)])
		else:
			var sz := Vector3(0.12 + k * 0.14, 0.1 + k * 0.14, 0.16 + (1.0 - k) * 0.2)
			W._box(W.flat, sz, p + Vector3(0, sz.y * 0.5, 0), jcols[i % jcols.size()], bas)

# ---------------------------------------------------------------- the origin intersection's arms
# Hand-placed, as in the first map. Each returns its props as small steps.

func _arm_north() -> Array:
	# taxi jam at the light, pile-up further up
	return [
		func() -> void:
			_car(_xf(-3.5, -13.0, 8), TAXI, "taxi", -1)
			_car(_xf(3.2, -15.5, -12), TAXI, "taxi"),
		func() -> void:
			_car(_xf(0.9, -22.5, 35), Color(0.2, 0.35, 0.6), "", 1)
			_car(_xf(3.7, -28.5, 3), TAXI, "taxi", 1),
		func() -> void:
			_car(_xf(-3.9, -31.5, 190), TAXI, "taxi")
			_car(_xf(-2.0, -35.0, 70), TAXI, "taxi", -1),
		func() -> void:
			_car(Transform3D(Basis.from_euler(Vector3(0, deg_to_rad(-15), PI)), Vector3(-3.7, 1.52, -38.8)), Color(0.7, 0.15, 0.15))
			_car(Transform3D(Basis.from_euler(Vector3(deg_to_rad(13), deg_to_rad(28), 0)), Vector3(-0.6, 0.3, -38.6)), TAXI, "taxi"),
		func() -> void:
			_cones([[1.5, -18.5, 1], [-1.0, -26.5, 0], [2.6, -33.0, 1]])
			_suitcases([[-1.5, -17.5, 1], [5.0, -21.5, 0], [1.6, -31.5, 1], [4.6, -36.5, 0]])
			_hotdog_cart(_sp(0, 1, 11.8, 7.4, 90))
			for d in [15.0, 21.5, 25.0]:
				_meter(_sp(0, 1, d, 6.3))
			_news_boxes(_sp(0, 1, 22.0, 8.5), 4),
		func() -> void:
			_trash(_sp(0, 1, 27.5, 6.75), 4)
			_hydrant(_sp(0, 1, 30.5, 6.5))
			_bench(_sp(0, 1, 38.5, 8.5))
			_mailbox(_sp(0, -1, 12.5, 6.8))
			_kiosk(_sp(0, -1, 30.0, 6.9, 90))
			_boxes([[-8.3, -33.5, 0.7, L.KERB_H], [-8.2, -34.3, 0.6, L.KERB_H], [-8.3, -33.8, 0.5, L.KERB_H + 0.56]])
			_trash(_sp(0, -1, 37.5, 6.75), 3),
	]

func _arm_south() -> Array:
	# police roadblock
	return [
		func() -> void:
			_car(_xf(3.4, 12.5, 172), TAXI, "taxi", 1)
			_car(_xf(-3.2, 14.6, 195), Color(0.12, 0.12, 0.14), "", -1),
		func() -> void:
			_van(_xf(-3.6, 20.5, 172), WHITE, Color(0.85, 0.15, 0.1), "ambulance", true)
			_chimney(_xf(0.6, 21.5)),
		func() -> void:
			var pc1 := _xf(-3.7, 27.0, 60)
			var pc2 := _xf(4.2, 33.0, -52)
			for pc: Transform3D in [pc1, pc2]:
				_car(pc, WHITE, "police", 1)
				_label(pc, "NYPD", Vector3(1.03, 0.92, 0.9), 90, 0.006, NYPD)
				_label(pc, "NYPD", Vector3(-1.03, 0.92, 0.9), -90, 0.006, NYPD),
		func() -> void:
			_sawhorse(_xf(4.2, 27.0, 4), 0)
			_sawhorse(_xf(-3.9, 33.6, -6), 0)
			_sawhorse(Transform3D(Basis.from_euler(Vector3(PI / 2, deg_to_rad(35), 0)), Vector3(4.9, 0.3, 29.6)), 0)
			_van(_xf(-4.0, 39.3, 4), WHITE, NYPD, "police"),
		func() -> void:
			_tape(Vector3(6.25, 1.05, 26.0), Vector3(5.3, 1.0, 27.1))
			_tape(Vector3(-6.25, 1.05, 34.0), Vector3(-5.1, 1.0, 33.7))
			_tape_post(-1.4, 24.2)
			_tape_post(1.6, 24.0)
			_tape(Vector3(-1.4, 1.0, 24.2), Vector3(1.6, 1.0, 24.0))
			_tape(Vector3(1.6, 1.0, 24.0), Vector3(3.1, 1.0, 26.9))
			_tape(Vector3(-6.25, 1.2, 34.0), Vector3(-8.9, 1.2, 34.0))
			_tape(Vector3(-6.25, 1.2, 18.0), Vector3(-8.9, 1.2, 18.0))
			_cones([[-0.6, 36.5, 0], [1.2, 37.0, 1], [2.8, 36.4, 0], [0.0, 11.0, 1]])
			_suitcases([[1.0, 14.0, 0], [-5.2, 24.0, 1]]),
		func() -> void:
			_mailbox(_sp(1, -1, 13.0, 6.8))
			for d in [15.5, 23.5, 29.0]:
				_meter(_sp(1, -1, d, 6.3))
			_hydrant(_sp(1, -1, 21.0, 6.5))
			_bench(_sp(1, -1, 30.5, 8.5))
			_kiosk(_sp(1, -1, 38.5, 6.9, 90))
			_trash(_sp(1, 1, 12.5, 6.75), 3)
			_news_boxes(_sp(1, 1, 30.0, 8.5), 3)
			_hydrant(_sp(1, 1, 36.5, 6.5))
			_boxes([[8.3, 38.5, 0.7, L.KERB_H], [8.1, 39.4, 0.55, L.KERB_H]]),
	]

func _arm_east() -> Array:
	# crashed bus + bus stop
	return [
		func() -> void:
			_bus(_xf(24.0, -2.9, 81)),
		func() -> void:
			_van(_xf(14.0, 3.5, -80), Color(0.36, 0.24, 0.14), Color(0.9, 0.7, 0.15), "", true)
			_boxes([[10.6, 3.6, 0.7, 0], [10.9, 4.6, 0.6, 0], [10.1, 4.4, 0.55, 0], [10.7, 3.8, 0.5, 0.56], [9.6, 2.6, 0.5, 0]]),
		func() -> void:
			_car(_xf(34.0, 3.2, -105), TAXI, "taxi", 1)
			_car(_xf(42.5, -3.2, 95), Color(0.2, 0.45, 0.3)),
		func() -> void:
			_shopping_cart(Transform3D(Basis.from_euler(Vector3(0, 0.6, PI / 2)), Vector3(11.0, 0.32, -3.4)))
			_suitcases([[19.5, -5.3, 0], [21.0, -5.6, 1], [22.6, -5.2, 0], [17.5, -4.0, 1], [26.0, 2.6, 1], [30.5, 4.4, 0], [16.8, -1.0, 0]])
			_cones([[30.5, -1.0, 1], [31.5, 0.6, 0]])
			_bus_sign(_sp(2, -1, 12.0, 6.4))
			_shelter(_sp(2, -1, 15.0, 8.0)),
		func() -> void:
			_kiosk(_sp(2, -1, 28.5, 6.9, 90))
			_mailbox(_sp(2, -1, 31.5, 6.8))
			_trash(_sp(2, -1, 38.0, 6.75), 4)
			_news_boxes(_sp(2, 1, 11.5, 8.5), 3)
			_bench(_sp(2, 1, 16.0, 8.5))
			_trash(_sp(2, 1, 20.5, 6.75), 2)
			_hydrant(_sp(2, 1, 31.0, 6.5))
			for d in [14.0, 22.5, 36.0, 38.5]:
				_meter(_sp(2, 1, d, 6.3)),
	]

func _arm_west() -> Array:
	# construction site: fenced work zone in the north lanes, shed over the north sidewalk
	return [
		func() -> void:
			_scaffold(_sp(3, -1, 28.0, 7.8), 16.0),
		func() -> void:
			var i := 0
			for x in [-29.0, -26.9, -24.8, -22.7, -20.6, -18.5]:
				var skew := -18.0 if i == 3 else _rng.randf_range(-3.0, 3.0)
				_jersey(_xf(x, -1.2 + (0.5 if i == 3 else 0.0), skew), ORANGE if i % 2 == 0 else WHITE)
				i += 1
			_sawhorse(_xf(-17.3, -3.6, 84), 1)
			_sawhorse(_xf(-30.4, -3.7, 96), 1),
		func() -> void:
			_excavator(_xf(-25.3, -3.8, 60))
			_potty(_xf(-29.0, -4.9, 180)),
		func() -> void:
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
			_work_sign(_xf(-11.0, -4.9, -90)),
		func() -> void:
			_car(_xf(-14.0, 3.8, 86), Color(0.55, 0.57, 0.6), "", -1)
			_dumpster(_xf(-33.0, 4.8, 92))
			# pipe stack
			var pt := _xf(-34.0, -4.9, 90)
			for k in 3:
				_b(pt, Vector3(0.45, 0.45, 3.4), Vector3(-0.5 + k * 0.5, 0.23, 0), STEEL if k != 1 else STEEL.darkened(0.2))
			_b(pt, Vector3(0.45, 0.45, 3.4), Vector3(-0.25, 0.68, 0), STEEL.darkened(0.1))
			_b(pt, Vector3(0.45, 0.45, 3.4), Vector3(0.25, 0.68, 0), STEEL)
			_c(pt, Vector3(1.5, 0.9, 3.4), Vector3(0, 0.45, 0))
			_o(pt, 0.9, [Vector3(0, 0, -0.9), Vector3(0, 0, 0.9)]),
		func() -> void:
			_car(_xf(-40.0, 2.6, 100), TAXI, "taxi", 1)
			_cones([[-12.0, -1.0, 0], [-14.5, -0.9, 0], [-16.8, -0.9, 1], [-31.6, -1.4, 0], [-32.5, -3.0, 1], [-27.5, 0.2, 1],
				[-21.5, 0.4, 0], [-10.4, -3.0, 0], [-36.0, -2.2, 1]])
			_suitcases([[-18.5, 2.2, 1], [-29.5, 3.0, 0]]),
		func() -> void:
			# south sidewalk
			_hydrant(_sp(3, 1, 12.0, 6.5))
			_mailbox(_sp(3, 1, 18.5, 6.8))
			_bench(_sp(3, 1, 21.5, 8.5))
			_trash(_sp(3, 1, 29.0, 6.75), 3)
			_boxes([[-36.0, 8.2, 0.8, L.KERB_H], [-36.9, 8.3, 0.6, L.KERB_H], [-36.2, 8.2, 0.55, L.KERB_H + 0.64], [-38.2, 8.0, 0.7, L.KERB_H]])
			for d in [13.5, 23.0, 26.0]:
				_meter(_sp(3, 1, d, 6.3))
			# cement bags under the shed
			var bag := Color(0.7, 0.68, 0.62)
			var bt := _xf(-24.0, -8.3, 0, L.KERB_H)
			for k in 3:
				_b(bt, Vector3(1.2, 0.25, 0.7), Vector3(0, 0.13 + k * 0.25, 0), bag if k % 2 == 0 else bag.darkened(0.12), _ry(k * 7.0)),
	]

# ---------------------------------------------------------------- open blocks

func block_steps(t: Dictionary) -> Array:
	var st: Array = []
	var pr := RandomNumberGenerator.new()
	pr.seed = L.hash3(t.bx, t.bz, 80)
	st.append(_lamps_of.bind(t, 6, false))
	match String(t.b.type):
		"park": _block_park(t, st)
		"plaza": _block_plaza(t, st)
		"parking": _block_parking(t, pr, st)
	return _wrap(st, t, 4)

func _block_park(t: Dictionary, st: Array) -> void:
	var b: Dictionary = t.b
	var c: Vector2 = (b.rect as Rect2).get_center()
	var h := L.KERB_H
	var f1 := func() -> void:
		for tr: Vector3 in b.trees:
			var x := Transform3D(Basis.IDENTITY, Vector3(tr.x, h, tr.z))
			_c(x, Vector3(0.6, 3.0, 0.6), Vector3(0, 1.5, 0))
			_o(x, 0.45)
		var p := Vector3(c.x, h, c.y)
		var x := Transform3D(Basis.IDENTITY, p)
		var stone := Color(0.6, 0.6, 0.58)
		if String(b.feature) == "fountain":
			W._cyl(W.lit, p, 3.4, 0.7, stone)
			W._cyl(W.flat, p + Vector3(0, 0.71, 0), 2.9, 0.0, Color(0.2, 0.45, 0.6))
			W._cyl(W.lit, p, 0.5, 2.2, stone)
			W._cyl(W.lit, p + Vector3(0, 2.2, 0), 0.6, 0.4, stone, 1.4)
			_c(x, Vector3(6.4, 1.4, 6.4), Vector3(0, 0.7, 0))
			_o(x, 3.4)
		else:
			# a monument to the unknown bonker
			var bronze := Color(0.3, 0.42, 0.36)
			_b(x, Vector3(2.6, 1.6, 2.6), Vector3(0, 0.8, 0), stone)
			for sx in [-0.3, 0.3]:
				_b(x, Vector3(0.4, 1.2, 0.4), Vector3(sx, 2.2, 0), bronze)
			_b(x, Vector3(1.1, 1.3, 0.6), Vector3(0, 3.4, 0), bronze)
			_b(x, Vector3(0.6, 0.6, 0.6), Vector3(0, 4.35, 0), bronze)
			_b(x, Vector3(0.3, 1.4, 0.3), Vector3(0.75, 4.4, 0), bronze)
			_b(x, Vector3(0.2, 0.2, 2.2), Vector3(0.75, 5.1, -0.6), bronze)
			_b(x, Vector3(0.7, 0.7, 0.9), Vector3(0.75, 5.1, -1.7), bronze.lightened(0.15))
			for nz: float in [-1.0, 1.0]:
				W._text(W.lit, "BONK", p + Vector3(0, 0.9, nz * 1.31), Vector3(0, 0, nz), 0.12, Color(0.15, 0.15, 0.15))
			_c(x, Vector3(2.6, 5.0, 2.6), Vector3(0, 2.5, 0))
			_o(x, 1.8)
	st.append(f1)
	var f2 := func() -> void:
		for sx: float in [-1.0, 1.0]:
			for dz: float in [-22.0, -10.0, 10.0, 22.0]:
				_bench(Transform3D(Basis(Vector3.UP, sx * PI / 2), Vector3(c.x + sx * 3.2, h, c.y + dz)))
	st.append(f2)
	var f3 := func() -> void:
		for sz: float in [-1.0, 1.0]:
			_trash(Transform3D(Basis.IDENTITY, Vector3(c.x + 3.0, h, c.y + sz * 28.0)), 2)
			_trash(Transform3D(Basis.IDENTITY, Vector3(c.x + sz * 28.0, h, c.y - 3.0)), 1)
		_hotdog_cart(Transform3D(Basis(Vector3.UP, PI / 2), Vector3(c.x - 5.5, h, c.y - 5.5)))
	st.append(f3)

func _block_plaza(t: Dictionary, st: Array) -> void:
	var b: Dictionary = t.b
	var c: Vector2 = (b.rect as Rect2).get_center()
	var h := L.KERB_H
	var stone := Color(0.62, 0.6, 0.56)
	var f1 := func() -> void:
		for q: Vector2 in [Vector2(22, 9), Vector2(22, -9), Vector2(-22, 9), Vector2(-22, -9), Vector2(9, 22), Vector2(-9, 22), Vector2(9, -22), Vector2(-9, -22)]:
			var x := Transform3D(Basis.IDENTITY, Vector3(c.x + q.x, h, c.y + q.y))
			_b(x, Vector3(3.0, 0.7, 3.0), Vector3(0, 0.35, 0), stone)
			_b(x, Vector3(2.4, 0.9, 2.4), Vector3(0, 1.1, 0), Color(0.14, 0.34, 0.14))
			_c(x, Vector3(3.0, 1.6, 3.0), Vector3(0, 0.8, 0))
			_o(x, 1.7)
	st.append(f1)
	var f2 := func() -> void:
		for sx: float in [-1.0, 1.0]:
			_bench(Transform3D(Basis(Vector3.UP, sx * PI / 2), Vector3(c.x + sx * 28.0, h, c.y)))
			_bench(Transform3D(Basis(Vector3.UP, 0.0 if sx > 0 else PI), Vector3(c.x, h, c.y + sx * 28.0)))
		var p := Vector3(c.x + 18.0, h, c.y + 26.0)
		var x := Transform3D(Basis.IDENTITY, p)
		if String(b.feature) == "sculpture":
			# the big mallet
			_b(x, Vector3(3.0, 0.8, 3.0), Vector3(0, 0.4, 0), stone)
			var tilt := Basis(Vector3(0, 0, 1), deg_to_rad(24))
			_b(x, Vector3(0.5, 6.0, 0.5), Vector3(-0.2, 3.6, 0), WOOD, tilt)
			_b(x, Vector3(1.8, 2.4, 1.8), Vector3(-1.5, 6.6, 0), RED, tilt)
			W._text(W.lit, "BONK PLAZA", p + Vector3(0, 0.45, 1.51), Vector3(0, 0, 1), 0.06, Color(0.15, 0.15, 0.15))
			_c(x, Vector3(3.0, 4.0, 3.0), Vector3(0, 2.0, 0))
			_o(x, 1.8)
		else:
			var cols := [RED, Color(0.15, 0.35, 0.8), Color(0.95, 0.8, 0.1), Color(0.15, 0.55, 0.25), WHITE]
			for k in 5:
				var fx := Transform3D(Basis.IDENTITY, Vector3(c.x - 12.0 + k * 6.0, h, c.y + 28.0))
				_b(fx, Vector3(0.14, 8.0, 0.14), Vector3(0, 4.0, 0), STEEL)
				_b(fx, Vector3(1.6, 1.0, 0.05), Vector3(0.85, 7.3, 0), cols[k])
				_c(fx, Vector3(0.3, 8.0, 0.3), Vector3(0, 4.0, 0))
	st.append(f2)

func _block_parking(t: Dictionary, pr: RandomNumberGenerator, st: Array) -> void:
	var b: Dictionary = t.b
	var r: Rect2 = b.rect
	var h := L.KERB_H
	var x0 := r.position.x
	var z0 := r.position.y
	var f1 := func() -> void:
		var white := Color(0.75, 0.75, 0.72)
		for rz: float in [8.0, 24.0, 40.0, 56.0]:
			for k in 17:
				var x := x0 + 6.0 + k * 3.2 - 1.6
				W._quad(W.flat, Vector3(x - 0.06, h + 0.02, z0 + rz - 2.6), Vector3(x + 0.06, h + 0.02, z0 + rz - 2.6),
					Vector3(x + 0.06, h + 0.02, z0 + rz + 2.6), Vector3(x - 0.06, h + 0.02, z0 + rz + 2.6), Vector3.UP, white)
		# fences on the east and west sides, with a gate gap in the middle
		for fx: float in [x0 + 0.3, r.end.x - 0.3]:
			for fz: float in [z0 + 14.0, z0 + 50.0]:
				var x := Transform3D(Basis.IDENTITY, Vector3(fx, h, fz))
				_b(x, Vector3(0.06, 1.5, 26.0), Vector3(0, 0.85, 0), Color(0.4, 0.42, 0.44))
				_b(x, Vector3(0.12, 0.1, 26.0), Vector3(0, 1.65, 0), STEEL)
				_c(x, Vector3(0.2, 1.7, 26.0), Vector3(0, 0.85, 0))
				W.cur_rects.append(Rect2(fx - 0.2, fz - 13.0, 0.4, 26.0))
		# attendant's booth
		var bt := Transform3D(Basis.IDENTITY, Vector3(x0 + 4.0, h, z0 + 32.0))
		_b(bt, Vector3(2.4, 2.6, 2.4), Vector3(0, 1.3, 0), WHITE)
		_b(bt, Vector3(2.6, 0.2, 2.6), Vector3(0, 2.7, 0), RED)
		_u(bt, Vector3(0.05, 0.9, 1.6), Vector3(1.21, 1.7, 0), Color(0.95, 0.85, 0.55))
		_label(bt, "PARK", Vector3(0, 2.25, 1.22), 0, 0.012, RED)
		_b(bt, Vector3(0.14, 0.14, 5.0), Vector3(1.6, 1.0, 2.5), ORANGE)
		_c(bt, Vector3(2.4, 2.8, 2.4), Vector3(0, 1.4, 0))
		_o(bt, 1.6)
	st.append(f1)
	var cars: Array = []
	for rz: float in [8.0, 24.0, 40.0, 56.0]:
		for k in 16:
			if pr.randf() < 0.4 and not (rz == 24.0 and k < 2) and not (rz == 40.0 and k < 2):
				cars.append([Transform3D(Basis(Vector3.UP, (PI if pr.randf() < 0.5 else 0.0) + pr.randf_range(-0.05, 0.05)),
					Vector3(x0 + 6.0 + k * 3.2, h, z0 + rz)), TAXI if pr.randf() < 0.15 else CAR_COLS[pr.randi() % CAR_COLS.size()]])
	var i := 0
	while i < cars.size():
		var part: Array = cars.slice(i, i + 4)
		var f := func() -> void:
			for cr: Array in part:
				_car_lo(cr[0], cr[1])
		st.append(f)
		i += 4
