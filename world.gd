extends Node3D
# The city: ground, roads, sidewalks, buildings, subway entrances, street-end barriers.
# Static scenery only. Props/clutter live in clutter.gd; lights and sky live in fx.gd.
#
# Everything is baked into a handful of big meshes (one lit vertex-colour mesh, one
# unshaded "glow" mesh, one mesh per facade texture) so the whole city costs ~7 draw calls.
# Collision is a few big invisible boxes: flat ground (the kerb is visual only, so the
# player never snags on it), the four corner blocks, the four arm ends, the two stairwells.
#
# Orientation: north = -Z (midtown towers, tower straddling the avenue), south = +Z
# (brick walk-ups, quarantine wall, bridge), east = +X (warehouses, elevated train),
# west = -X (glass, billboards, container wall, crane).
const B = preload("res://build.gd")
const L = preload("res://layout.gd")

const BRICK := 0
const DECO := 1
const GLASS := 2
const RIBBON := 3
const WARE := 4
const BAY := [2.4, 1.6, 1.5, 3.0, 3.2]      # metres per window bay, per style
const FLOOR := [3.2, 3.4, 3.5, 3.4, 4.0]    # metres per storey, per style
const NC := 16                               # window cells per texture side
const CP := 8                                # pixels per cell
const Y := Vector3.UP
const X := Vector3.RIGHT
const Z := Vector3.BACK

const TINTS := [
	[Color(0.62, 0.3, 0.24), Color(0.5, 0.25, 0.2), Color(0.72, 0.5, 0.36), Color(0.55, 0.36, 0.3), Color(0.42, 0.27, 0.24), Color(0.75, 0.68, 0.55)],
	[Color(0.85, 0.8, 0.68), Color(0.72, 0.7, 0.66), Color(0.8, 0.72, 0.58), Color(0.6, 0.62, 0.66)],
	[Color(0.7, 0.85, 1.0), Color(0.6, 0.9, 0.85), Color(0.9, 0.9, 0.95), Color(0.95, 0.8, 0.6), Color(0.55, 0.65, 0.85)],
	[Color(0.8, 0.8, 0.78), Color(0.65, 0.62, 0.58), Color(0.85, 0.78, 0.65), Color(0.55, 0.6, 0.62)],
	[Color(0.55, 0.28, 0.2), Color(0.45, 0.3, 0.25), Color(0.6, 0.45, 0.35), Color(0.4, 0.38, 0.36)],
]
const LIT_COLS := [Color(1.0, 0.8, 0.42), Color(1.0, 0.8, 0.42), Color(1.0, 0.9, 0.62), Color(1.0, 0.72, 0.35),
	Color(0.8, 0.9, 1.0), Color(0.45, 0.6, 1.0), Color(1.0, 0.5, 0.7)]
const SHOP_NAMES := ["PIZZA", "DELI", "BAGELS", "PAWN", "LAUNDRY", "BODEGA", "TATTOO", "HOT DOGS", "BOOKS",
	"DINER", "NAILS", "COFFEE", "LIQUOR", "BARBER", "BRAINS 2 GO", "99C STORE", "TACOS", "VINYL", "NOODLES",
	"BONK MART", "KEYS", "BAR", "GYM", "PHARMACY", "HATS", "CAMERAS", "DONUTS", "CHECKS CASHED"]
const SIGN_BG := [Color(0.5, 0.08, 0.08), Color(0.05, 0.2, 0.45), Color(0.08, 0.32, 0.15), Color(0.08, 0.08, 0.1),
	Color(0.45, 0.22, 0.04), Color(0.33, 0.08, 0.4)]
const SIGN_FG := [Color(1.0, 0.9, 0.3), Color(1, 1, 1), Color(0.4, 1.0, 1.0), Color(1.0, 0.5, 0.8), Color(0.5, 1.0, 0.4)]
const SHOP_GLOW := [Color(0.95, 0.8, 0.5), Color(0.7, 0.85, 0.95), Color(0.95, 0.65, 0.45), Color(0.65, 0.95, 0.7)]
const ADS := [["BONK", "COLA"], ["EAT", "BRAINS"], ["HOTEL", "ZZZ"], ["ZOMBIE", "THE MUSICAL"], ["I", "BONK", "NY"],
	["BIG", "SALE"], ["NEWS", "24H"], ["TAXI", "TV"]]
const AD_COLS := [Color(0.85, 0.1, 0.12), Color(0.1, 0.65, 0.25), Color(0.1, 0.3, 0.85), Color(0.9, 0.5, 0.05),
	Color(0.75, 0.1, 0.6), Color(0.05, 0.6, 0.7)]

# 3x5 pixel font, rows top to bottom.
const FONT := {
	"A": "010101111101101", "B": "110101110101110", "C": "011100100100011", "D": "110101101101110",
	"E": "111100110100111", "F": "111100110100100", "G": "011100101101011", "H": "101101111101101",
	"I": "111010010010111", "J": "001001001101010", "K": "101101110101101", "L": "100100100100111",
	"M": "101111111101101", "N": "110101101101101", "O": "111101101101111", "P": "110101110100100",
	"Q": "010101101111011", "R": "110101110101101", "S": "011100010001110", "T": "111010010010010",
	"U": "101101101101111", "V": "101101101101010", "W": "101101111111101", "X": "101101010101101",
	"Y": "101101010010010", "Z": "111001010100111", "0": "111101101101111", "1": "010110010010111",
	"2": "110001010100111", "3": "110001010001110", "4": "101101111001001", "5": "111100110001110",
	"6": "011100111101111", "7": "111001010010010", "8": "111101111101111", "9": "111101111001110",
	"!": "010010010000010", "-": "000000111000000", ".": "000000000000010", "'": "010010000000000",
}

class Batch:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()
	var uv := PackedVector2Array()
	var idx := PackedInt32Array()
	var shade := false

var rng := RandomNumberGenerator.new()
var lit := Batch.new()          # lit, vertex coloured
var glow := Batch.new()         # unshaded, vertex coloured (signs, lit shop windows, lamps)
var fac: Array = []             # one Batch per facade style
var _name_i := 0
var _ad_i := 0

func build() -> void:
	rng.seed = 20240611
	lit.shade = true
	for i in 5:
		fac.append(Batch.new())
	_ground()
	_buildings()
	for s: Vector3 in L.SUBWAY_ENTRANCES:
		_subway(s)
	_end_north()
	_end_south()
	_end_east()
	_end_west()
	_skyline()
	_colliders()
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.roughness = 1.0
	_flush(lit, m)
	var g := StandardMaterial3D.new()
	g.vertex_color_use_as_albedo = true
	g.vertex_color_is_srgb = true
	g.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var gi := _flush(glow, g)
	gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for i in 5:
		_flush(fac[i], _facade_mat(i))

# ---------------------------------------------------------------- mesh batching
func _flush(b: Batch, m: Material) -> MeshInstance3D:
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = b.v
	arr[Mesh.ARRAY_NORMAL] = b.n
	arr[Mesh.ARRAY_COLOR] = b.c
	arr[Mesh.ARRAY_TEX_UV] = b.uv
	arr[Mesh.ARRAY_INDEX] = b.idx
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	am.surface_set_material(0, m)
	var mi := MeshInstance3D.new()
	mi.mesh = am
	add_child(mi)
	return mi

func _vert(b: Batch, p: Vector3, nrm: Vector3, col: Color, uv: Vector2) -> void:
	b.v.append(p)
	b.n.append(nrm)
	b.uv.append(uv)
	if b.shade:
		var k := 0.82 + 0.18 * nrm.y + 0.07 * nrm.x + 0.03 * nrm.z
		b.c.append(Color(col.r * k, col.g * k, col.b * k))
	else:
		b.c.append(col)

# Quad p0..p3 (in loop order) facing `nrm`; winding is fixed up automatically.
func _quad(b: Batch, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, nrm: Vector3, col: Color,
		u0 := Vector2.ZERO, u1 := Vector2.ZERO, u2 := Vector2.ZERO, u3 := Vector2.ZERO) -> void:
	var s := b.v.size()
	_vert(b, p0, nrm, col, u0)
	_vert(b, p1, nrm, col, u1)
	_vert(b, p2, nrm, col, u2)
	_vert(b, p3, nrm, col, u3)
	if (p1 - p0).cross(p2 - p0).dot(nrm) > 0.0:
		b.idx.append_array([s, s + 2, s + 1, s, s + 3, s + 2])
	else:
		b.idx.append_array([s, s + 1, s + 2, s, s + 2, s + 3])

func _tri(b: Batch, p0: Vector3, p1: Vector3, p2: Vector3, nrm: Vector3, col: Color) -> void:
	var s := b.v.size()
	_vert(b, p0, nrm, col, Vector2.ZERO)
	_vert(b, p1, nrm, col, Vector2.ZERO)
	_vert(b, p2, nrm, col, Vector2.ZERO)
	if (p1 - p0).cross(p2 - p0).dot(nrm) > 0.0:
		b.idx.append_array([s, s + 2, s + 1])
	else:
		b.idx.append_array([s, s + 1, s + 2])

func _box(b: Batch, size: Vector3, pos: Vector3, col: Color, bas := Basis.IDENTITY) -> void:
	var ax := bas.x * (size.x * 0.5)
	var ay := bas.y * (size.y * 0.5)
	var az := bas.z * (size.z * 0.5)
	_quad(b, pos + ax - ay - az, pos + ax + ay - az, pos + ax + ay + az, pos + ax - ay + az, bas.x, col)
	_quad(b, pos - ax - ay - az, pos - ax + ay - az, pos - ax + ay + az, pos - ax - ay + az, -bas.x, col)
	_quad(b, pos + ay - az - ax, pos + ay + az - ax, pos + ay + az + ax, pos + ay - az + ax, bas.y, col)
	_quad(b, pos - ay - az - ax, pos - ay + az - ax, pos - ay + az + ax, pos - ay - az + ax, -bas.y, col)
	_quad(b, pos + az - ax - ay, pos + az + ax - ay, pos + az + ax + ay, pos + az - ax + ay, bas.z, col)
	_quad(b, pos - az - ax - ay, pos - az + ax - ay, pos - az + ax + ay, pos - az - ax + ay, -bas.z, col)

# Axis-aligned box given min/max corners.
func _mm(b: Batch, x0: float, x1: float, y0: float, y1: float, z0: float, z1: float, col: Color) -> void:
	_box(b, Vector3(absf(x1 - x0), absf(y1 - y0), absf(z1 - z0)), Vector3((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2), col)

# Box in a wall-relative frame: origin o, `dir` along the wall, `out` away from it (both axis-aligned).
func _ob(b: Batch, o: Vector3, dir: Vector3, out: Vector3, u0: float, u1: float, y0: float, y1: float,
		d0: float, d1: float, col: Color) -> void:
	var size := dir.abs() * absf(u1 - u0) + out.abs() * absf(d1 - d0) + Y * absf(y1 - y0)
	_box(b, size, o + dir * ((u0 + u1) / 2) + out * ((d0 + d1) / 2) + Y * ((y0 + y1) / 2), col)

# Box in a transformed frame (for tilted wrecks).
func _tb(b: Batch, xf: Transform3D, size: Vector3, lp: Vector3, col: Color) -> void:
	_box(b, size, xf * lp, col, xf.basis)

# Square beam from p to q.
func _beam(b: Batch, p: Vector3, q: Vector3, t: float, col: Color, t2 := -1.0) -> void:
	var d := q - p
	var bx := d.normalized()
	var ref := Y if abs(bx.y) < 0.99 else X
	var bz := bx.cross(ref).normalized()
	var by := bz.cross(bx)
	_box(b, Vector3(d.length(), t, t2 if t2 > 0 else t), (p + q) / 2, col, Basis(bx, by, bz))

# 8-sided prism (water tanks, chimneys, manholes).
func _cyl(b: Batch, c: Vector3, r: float, h: float, col: Color, r_top := -1.0) -> void:
	var rt := r if r_top < 0 else r_top
	for i in 8:
		var a0 := TAU * i / 8.0
		var a1 := TAU * (i + 1) / 8.0
		var d0 := Vector3(cos(a0), 0, sin(a0))
		var d1 := Vector3(cos(a1), 0, sin(a1))
		var nn := (d0 + d1).normalized()
		if h > 0.0:
			_quad(b, c + d0 * r, c + d0 * rt + Y * h, c + d1 * rt + Y * h, c + d1 * r, nn, col)
		_tri(b, c + Y * h, c + d0 * rt + Y * h, c + d1 * rt + Y * h, Y, col)

# Pixel text centred on `c`, on a surface facing `nrm`.
func _text(b: Batch, s: String, c: Vector3, nrm: Vector3, px: float, col: Color, up := Vector3.UP) -> void:
	var right := up.cross(nrm).normalized()
	var w := (s.length() * 4 - 1) * px
	var o := c - right * (w / 2) + up * (2.5 * px)
	for i in s.length():
		var g: String = FONT.get(s[i], "")
		if g == "":
			continue
		for r in 5:
			var run := 0
			for k in 4:
				if k < 3 and g[r * 3 + k] == "1":
					run += 1
				elif run > 0:
					var p := o + right * ((i * 4 + k - run) * px) - up * (r * px)
					_quad(b, p, p + right * (run * px), p + right * (run * px) - up * px, p - up * px, nrm, col)
					run = 0

func _vtext(b: Batch, s: String, c: Vector3, nrm: Vector3, px: float, col: Color) -> void:
	var h := s.length() * 6 * px
	for i in s.length():
		_text(b, s[i], c + Y * (h / 2 - (i * 6 + 3) * px), nrm, px, col)

# ---------------------------------------------------------------- facade textures
func _facade_mat(st: int) -> StandardMaterial3D:
	var S := NC * CP
	var alb := Image.create(S, S, false, Image.FORMAT_RGB8)
	var emi := Image.create(S, S, false, Image.FORMAT_RGB8)
	var base_p: float = [0.3, 0.4, 0.42, 0.45, 0.14][st]
	for cy in NC:
		var fp := base_p * rng.randf_range(0.3, 1.7)
		var run_lit := false
		for cx in NC:
			var lit_w := rng.randf() < fp
			if st == GLASS or st == RIBBON:   # offices light up in runs
				if rng.randf() < 0.45:
					run_lit = rng.randf() < fp
				lit_w = run_lit
			var lc: Color = LIT_COLS[rng.randi() % (LIT_COLS.size() if st == BRICK else 5)]
			if st == GLASS or st == RIBBON:
				lc = LIT_COLS[2 + rng.randi() % 3]
			lc = lc * rng.randf_range(0.65, 1.0)
			var gl := Color(0.08, 0.1, 0.14).lightened(rng.randf() * 0.08)
			var blind := rng.randi() % 3
			for py in CP:
				for px in CP:
					var nz := rng.randf_range(-0.05, 0.05)
					var col := Color(0.82 + nz, 0.82 + nz, 0.82 + nz)
					var win := false
					var k := 1.0
					if st == BRICK:
						if py % 2 == 1:
							col = col.darkened(0.06)
						if py == 1 and px >= 1 and px <= 6:
							col = Color(0.98, 0.96, 0.92)
						if py == 7 and px >= 1 and px <= 6:
							col = Color(0.9, 0.88, 0.84)
						win = px >= 2 and px <= 5 and py >= 2 and py <= 6
						if win and py == 4:
							k = 0.6
						if win and py < 2 + blind:
							k = 0.75
					elif st == DECO:
						col = Color(0.95 + nz, 0.95 + nz, 0.95 + nz) if (px < 2 or px > 5) else Color(0.6 + nz, 0.6 + nz, 0.62 + nz)
						if px >= 2 and px <= 5 and py == 1:
							col = Color(0.45, 0.45, 0.48)
						win = px >= 2 and px <= 5 and py >= 3
						if win and (px == 2 or px == 5) and py == 3:
							k = 0.7
					elif st == GLASS:
						col = Color(0.3, 0.36, 0.42)
						if py < 2 and px > 0:
							col = Color(0.14, 0.2, 0.27)
						win = px > 0 and py >= 2
						gl = Color(0.1, 0.19, 0.3).lightened(0.12 * (7 - py) / 5.0)
					elif st == RIBBON:
						if py == 3:
							col = col.darkened(0.2)
						win = py >= 4 and px > 0
						if py >= 4 and px == 0:
							col = Color(0.3, 0.3, 0.32)
					else:
						if py % 2 == 1:
							col = col.darkened(0.08)
						if py == 1 and px >= 1 and px <= 6:
							col = Color(0.95, 0.9, 0.85)
						win = px >= 1 and px <= 6 and py >= 2 and py <= 6
						if win and (px == 3 or py == 4):
							k = 0.55
						elif win and rng.randf() < 0.12:
							k = 1.6
					var em := Color.BLACK
					if win:
						if lit_w:
							col = lc * (0.9 * minf(k, 1.0))
							em = lc * minf(k, 1.0)
						else:
							col = gl * k
					alb.set_pixel(cx * CP + px, cy * CP + py, col)
					emi.set_pixel(cx * CP + px, cy * CP + py, em)
	alb.generate_mipmaps()
	emi.generate_mipmaps()
	var m := StandardMaterial3D.new()
	m.albedo_texture = ImageTexture.create_from_image(alb)
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.roughness = 1.0
	m.emission_enabled = true
	m.emission = Color.BLACK
	m.emission_texture = ImageTexture.create_from_image(emi)
	m.emission_energy_multiplier = 1.1
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	return m

# Four textured walls of a box. Windows are aligned to the top edge.
func _facade(st: int, x0: float, x1: float, z0: float, z1: float, y0: float, y1: float, tint: Color) -> void:
	var b: Batch = fac[st]
	var fl: float = (y1 - y0) / FLOOR[st]
	var c := [Vector3(x0, 0, z0), Vector3(x1, 0, z0), Vector3(x1, 0, z1), Vector3(x0, 0, z1)]
	var nr := [-Z, X, Z, -X]
	for i in 4:
		var p: Vector3 = c[i]
		var q: Vector3 = c[(i + 1) % 4]
		var bays := maxf(1.0, round(p.distance_to(q) / BAY[st]))
		var uo := float(rng.randi() % NC)
		var vo := float(rng.randi() % NC)
		var ua := uo / NC
		var ub := (uo + bays) / NC
		var va := vo / NC
		var vb := (vo + fl) / NC
		_quad(b, p + Y * y0, p + Y * y1, q + Y * y1, q + Y * y0, nr[i], tint,
			Vector2(ua, vb), Vector2(ua, va), Vector2(ub, va), Vector2(ub, vb))

func _tint(st: int) -> Color:
	var a: Array = TINTS[st]
	return a[rng.randi() % a.size()]

# A plain building: textured walls, cornice/cap, rooftop junk.
func _bldg(x0: float, x1: float, z0: float, z1: float, h: float, st: int, tint: Color, junk := true) -> void:
	_facade(st, x0, x1, z0, z1, 0.0, h, tint)
	var cx := (x0 + x1) / 2
	var cz := (z0 + z1) / 2
	var w := x1 - x0
	var d := z1 - z0
	if st == GLASS:
		_box(lit, Vector3(w + 0.1, 0.7, d + 0.1), Vector3(cx, h + 0.3, cz), Color(0.14, 0.16, 0.2))
	else:
		var cc := tint.lightened(0.12) if st == DECO else tint.darkened(0.3)
		_box(lit, Vector3(w + 0.7, 1.0, d + 0.7), Vector3(cx, h + 0.1, cz), cc)
		_box(lit, Vector3(w - 0.6, 0.3, d - 0.6), Vector3(cx, h + 0.56, cz), Color(0.16, 0.16, 0.17))
	if not junk:
		return
	var top := h + 0.6
	var jx := cx + rng.randf_range(-0.25, 0.25) * w
	var jz := cz + rng.randf_range(-0.25, 0.25) * d
	_box(lit, Vector3(3.2, 2.8, 3.2), Vector3(jx, top + 1.4, jz), tint.darkened(0.4) if st != GLASS else Color(0.3, 0.32, 0.35))
	if st != GLASS and rng.randf() < 0.65:
		_water_tower(Vector3(cx - sign(jx - cx + 0.01) * w * 0.25, top, cz - sign(jz - cz + 0.01) * d * 0.25))
	else:
		for i in 2:
			_box(lit, Vector3(2.4, 1.2, 1.6), Vector3(cx - sign(jx - cx + 0.01) * w * 0.25, top + 0.6, cz + (i * 2 - 1) * d * 0.2), Color(0.5, 0.52, 0.54))

func _water_tower(p: Vector3) -> void:
	var iron := Color(0.14, 0.13, 0.13)
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			_box(lit, Vector3(0.22, 2.4, 0.22), p + Vector3(sx * 1.0, 1.2, sz * 1.0), iron)
	_box(lit, Vector3(2.6, 0.2, 2.6), p + Y * 2.4, iron)
	_cyl(lit, p + Y * 2.5, 1.7, 3.0, Color(0.42, 0.28, 0.17))
	_cyl(lit, p + Y * 3.4, 1.76, 0.2, iron)
	_cyl(lit, p + Y * 4.6, 1.76, 0.2, iron)
	_cyl(lit, p + Y * 5.5, 1.9, 1.3, Color(0.3, 0.3, 0.32), 0.1)

# Stepped tower: tiers = [[width, depth, top_y], ...]
func _tower(cx: float, cz: float, tiers: Array, st: int, tint: Color) -> void:
	var y0 := 0.0
	for t: Array in tiers:
		var w: float = t[0]
		var d: float = t[1]
		var y1: float = t[2]
		_facade(st, cx - w / 2, cx + w / 2, cz - d / 2, cz + d / 2, y0, y1, tint)
		var cc := Color(0.14, 0.16, 0.2) if st == GLASS else tint.lightened(0.1)
		_box(lit, Vector3(w + 0.5, 0.8, d + 0.5), Vector3(cx, y1 + 0.2, cz), cc)
		y0 = y1

# ---------------------------------------------------------------- street-level detail
func _shops(a: Vector3, dir: Vector3, out: Vector3, w: float, base: Color) -> void:
	_ob(lit, a, dir, out, 0, w, 0, 4.5, 0, 0.15, base)
	_ob(lit, a, dir, out, 0, w, 4.5, 4.95, 0, 0.4, base.lightened(0.18))
	var n := maxi(1, roundi(w / 6.0))
	var sw := w / n
	for i in n:
		var u := i * sw
		_ob(lit, a, dir, out, maxf(u - 0.3, 0.0), u + 0.3, 0, 4.5, 0.15, 0.32, base.lightened(0.1))
		var gc: Color = SHOP_GLOW[rng.randi() % SHOP_GLOW.size()]
		if rng.randf() < 0.22:
			# closed: roll-down shutter
			_ob(lit, a, dir, out, u + 0.6, u + sw - 0.6, 0.15, 3.0, 0.15, 0.22, Color(0.45, 0.47, 0.5))
			for k in 7:
				_ob(lit, a, dir, out, u + 0.6, u + sw - 0.6, 0.45 + k * 0.38, 0.52 + k * 0.38, 0.22, 0.25, Color(0.3, 0.31, 0.34))
		else:
			var dl := u + sw - 1.9      # door on the right
			_ob(glow, a, dir, out, u + 0.6, dl - 0.2, 0.9, 3.0, 0.15, 0.2, gc)
			_ob(glow, a, dir, out, u + 0.6, dl - 0.2, 1.75, 1.95, 0.2, 0.22, gc * 0.55)
			_ob(glow, a, dir, out, u + 0.6, dl - 0.2, 0.9, 1.15, 0.2, 0.22, gc * 0.4)
			var panes := maxf(1.0, round((dl - 0.8 - u) / 1.5))
			for j in int(panes) + 1:
				var mu := u + 0.6 + j * (dl - 0.8 - u) / panes
				_ob(lit, a, dir, out, mu - 0.06, mu + 0.06, 0.9, 3.0, 0.2, 0.26, Color(0.1, 0.1, 0.11))
			_ob(lit, a, dir, out, dl, dl + 1.3, 0.15, 3.0, 0.15, 0.22, Color(0.1, 0.1, 0.11))
			_ob(glow, a, dir, out, dl + 0.2, dl + 1.1, 0.5, 2.7, 0.22, 0.24, gc * 0.8)
		# sign
		var nm: String = SHOP_NAMES[_name_i % SHOP_NAMES.size()]
		_name_i += 1
		var bg: Color = SIGN_BG[rng.randi() % SIGN_BG.size()]
		_ob(glow, a, dir, out, u + 0.5, u + sw - 0.5, 3.3, 4.3, 0.15, 0.34, bg)
		var px := minf(0.15, (sw - 1.6) / (nm.length() * 4.0))
		_text(glow, nm, a + dir * (u + sw / 2) + out * 0.36 + Y * 3.8, out, px, SIGN_FG[rng.randi() % SIGN_FG.size()])
		if rng.randf() < 0.55:
			_awning(a, dir, out, u + 0.5, u + sw - 0.5, AD_COLS[rng.randi() % AD_COLS.size()].darkened(0.2))
		elif rng.randf() < 0.3:
			_blade(a + dir * (u + 0.2), dir, out, nm.split(" ")[0], bg)
	_ob(lit, a, dir, out, w - 0.3, w, 0, 4.5, 0.15, 0.32, base.lightened(0.1))

func _awning(a: Vector3, dir: Vector3, out: Vector3, u0: float, u1: float, col: Color) -> void:
	var n := maxi(2, roundi((u1 - u0) / 0.6))
	var sw := (u1 - u0) / n
	var nt := (out * 0.45 + Y * 0.9).normalized()
	for i in n:
		var c := col if i % 2 == 0 else Color(0.85, 0.83, 0.78)
		var p0 := a + dir * (u0 + i * sw) + out * 0.2 + Y * 3.2
		var p1 := p0 + dir * sw
		var q0 := p0 + out * 1.25 - Y * 0.65
		var q1 := q0 + dir * sw
		_quad(lit, p0, p1, q1, q0, nt, c)
		_quad(lit, p0, p1, q1, q0, -nt, c.darkened(0.3))
		_quad(lit, q0, q1, q1 - Y * 0.3, q0 - Y * 0.3, out, c)
		_quad(lit, q0, q1, q1 - Y * 0.3, q0 - Y * 0.3, -out, c.darkened(0.3))
	for e: float in [u0, u1]:
		var p := a + dir * e + out * 0.2 + Y * 3.2
		var nn := dir if e == u1 else -dir
		_tri(lit, p, p + out * 1.25 - Y * 0.65, p - Y * 0.65, nn, col.darkened(0.15))
		_tri(lit, p, p + out * 1.25 - Y * 0.65, p - Y * 0.65, -nn, col.darkened(0.15))

# Vertical sign sticking out of a wall, readable from both directions along the street.
func _blade(p: Vector3, dir: Vector3, out: Vector3, s: String, bg: Color) -> void:
	var px := 0.13
	var h := s.length() * 6 * px + 0.3
	var c := p + out * 0.9 + Y * (6.0 + h / 2)
	_box(glow, dir.abs() * 0.2 + out.abs() * 0.9 + Y * h, c, bg)
	_box(lit, dir.abs() * 0.1 + out.abs() * 0.5 + Y * 0.1, p + out * 0.25 + Y * (6.0 + h - 0.3), Color(0.1, 0.1, 0.1))
	var fg: Color = SIGN_FG[rng.randi() % SIGN_FG.size()]
	_vtext(glow, s, c + dir * 0.11, dir, px, fg)
	_vtext(glow, s, c - dir * 0.11, -dir, px, fg)

func _fire_escape(a: Vector3, dir: Vector3, out: Vector3, u: float, h: float, fh: float) -> void:
	var iron := Color(0.1, 0.1, 0.11)
	var k := 1
	var flip := 1.0
	while h - k * fh > 6.0:
		var y := h - k * fh - 0.25
		_ob(lit, a, dir, out, u - 1.9, u + 1.9, y, y + 0.12, 0.0, 1.15, iron)
		_ob(lit, a, dir, out, u - 1.9, u + 1.9, y + 0.95, y + 1.05, 1.07, 1.15, iron)
		_ob(lit, a, dir, out, u - 1.9, u + 1.9, y + 0.5, y + 0.57, 1.08, 1.14, iron)
		for e: float in [-1.9, 1.82]:
			_ob(lit, a, dir, out, u + e, u + e + 0.08, y + 0.95, y + 1.05, 0.0, 1.15, iron)
		for j in 5:
			var pu := u - 1.9 + j * 0.93
			_ob(lit, a, dir, out, pu, pu + 0.08, y, y + 1.0, 1.07, 1.15, iron)
		# stair down to the platform below
		if h - (k + 1) * fh > 6.0:
			var p := a + dir * (u + flip * 1.3) + out * 0.6 + Y * (y + 0.1)
			_beam(lit, p, p - dir * (flip * 2.6) - Y * fh, 0.1, iron, 0.55)
		else:
			_ob(lit, a, dir, out, u - 0.3 * flip - 0.25, u - 0.3 * flip + 0.25, y - 2.4, y, 1.0, 1.08, iron)
		flip = -flip
		k += 1

func _billboard(c: Vector3, nrm: Vector3, w: float, h: float, bg: Color, lines: Array, frame := true) -> void:
	var right := Y.cross(nrm)
	if frame:
		_box(lit, right.abs() * (w + 0.5) + Y * (h + 0.5) + nrm.abs() * 0.4, c - nrm * 0.1, Color(0.08, 0.08, 0.09))
	_box(glow, right.abs() * w + Y * h + nrm.abs() * 0.3, c + nrm * 0.02, bg)
	var n := lines.size()
	var longest := 1
	for s: String in lines:
		longest = maxi(longest, s.length())
	var px := minf((w - 1.0) / (longest * 4.0), (h - 0.8) / (n * 6.5))
	for i in n:
		var fg := Color(1, 1, 1) if i % 2 == 0 else Color(1.0, 0.92, 0.3)
		_text(glow, lines[i], c + nrm * 0.19 + Y * ((n - 1) * 0.5 - i) * px * 6.5, nrm, px, fg)

func _next_ad() -> Array:
	_ad_i += 1
	return ADS[(_ad_i - 1) % ADS.size()]

# ---------------------------------------------------------------- buildings
# A terrace of buildings along one side of a street. o = start of the frontage on the
# building line, dir = along the street (away from the intersection), out = toward the street.
func _row(o: Vector3, dir: Vector3, out: Vector3, t0: float, t1: float, styles: Array, hmin: float, hmax: float,
		detail_to: float, ads := false) -> void:
	var t := t0
	var prev_h := 0.0
	while t < t1 - 0.1:
		var w := float(rng.randi_range(4, 7)) * 2.0
		if t1 - (t + w) < 7.0:
			w = t1 - t
		var st: int = styles[rng.randi() % styles.size()]
		var h := rng.randf_range(hmin, hmax)
		if abs(h - prev_h) < 5.0:
			h += 8.0
		h = ceilf(h / FLOOR[st]) * FLOOR[st] + 1.0
		prev_h = h
		var tint := _tint(st)
		var a := o + dir * t
		var e := a + dir * w - out * 16.0
		var detail := t < detail_to
		_bldg(minf(a.x, e.x), maxf(a.x, e.x), minf(a.z, e.z), maxf(a.z, e.z), h, st, tint, t < detail_to + 30.0)
		if detail:
			_shops(a, dir, out, w, _shop_base(st, tint))
			if (st == BRICK or st == WARE) and h < 45.0:
				_fire_escape(a, dir, out, rng.randf_range(2.5, w - 2.5), h, FLOOR[st])
			elif ads and w >= 10.0:
				var bh := minf(7.0, h - 14.0)
				_billboard(a + dir * (w / 2) + out * 0.35 + Y * rng.randf_range(9.0, maxf(9.5, minf(18.0, h - bh - 3.0))),
					out, w - 3.0, bh, AD_COLS[rng.randi() % AD_COLS.size()], _next_ad())
		t += w

func _shop_base(st: int, tint: Color) -> Color:
	if st == GLASS:
		return Color(0.2, 0.21, 0.24)
	if st == DECO or st == RIBBON:
		return tint.darkened(0.55)
	return tint.darkened(0.4)

func _buildings() -> void:
	var corner_st := {Vector2(1, -1): DECO, Vector2(-1, -1): GLASS, Vector2(1, 1): BRICK, Vector2(-1, 1): RIBBON}
	var corner_h := {Vector2(1, -1): 58.8, Vector2(-1, -1): 67.5, Vector2(1, 1): 39.4, Vector2(-1, 1): 48.6}
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			var key := Vector2(sx, sz)
			var o := Vector3(sx * 9, 0, sz * 9)
			var av_dir := Vector3(0, 0, sz)
			var av_out := Vector3(-sx, 0, 0)
			var st_dir := Vector3(sx, 0, 0)
			var st_out := Vector3(0, 0, -sz)
			# corner building, shops on both streets
			var cs: int = corner_st[key]
			var chh: float = corner_h[key]
			var ct := _tint(cs)
			_bldg(minf(o.x, o.x + sx * 16), maxf(o.x, o.x + sx * 16), minf(o.z, o.z + sz * 16), maxf(o.z, o.z + sz * 16),
				chh, cs, ct)
			_shops(o, av_dir, av_out, 16.0, _shop_base(cs, ct))
			_shops(o, st_dir, st_out, 16.0, _shop_base(cs, ct))
			if cs == BRICK:
				_fire_escape(o, av_dir, av_out, 11.0, chh, FLOOR[cs])
				_fire_escape(o, st_dir, st_out, 6.0, chh, FLOOR[cs])
			# avenue frontage (north = midtown towers, south = brick walk-ups)
			if sz < 0:
				_row(o, av_dir, av_out, 16.0, 101.0, [DECO, DECO, GLASS, RIBBON], 34.0, 68.0, 41.0)
			else:
				_row(o, av_dir, av_out, 16.0, 61.0, [BRICK, BRICK, BRICK, WARE], 16.0, 30.0, 41.0)
			# street frontage (east = warehouses, west = glass and billboards)
			if sx > 0:
				_row(o, st_dir, st_out, 16.0, 41.0, [WARE, WARE, BRICK], 20.0, 36.0, 41.0)
			else:
				_row(o, st_dir, st_out, 16.0, 91.0, [GLASS, RIBBON, GLASS, DECO], 30.0, 58.0, 41.0, true)
			# block interior: podium filling the gap, with a skyscraper on it
			var px0 := minf(sx * 25, sx * 50)
			var pz0 := minf(sz * 25, sz * 50)
			_bldg(px0, px0 + 25, pz0, pz0 + 25, 21.4, RIBBON, _tint(RIBBON), false)
	# the four skyscrapers
	# NE: art-deco needle with a stepped crown
	_tower(37.5, -37.5, [[22, 22, 48], [17, 17, 76], [12, 12, 88], [8, 8, 95], [5, 5, 100]], DECO, Color(0.78, 0.76, 0.72))
	_box(lit, Vector3(2.2, 6, 2.2), Vector3(37.5, 103, -37.5), Color(0.7, 0.72, 0.75))
	_box(lit, Vector3(0.7, 16, 0.7), Vector3(37.5, 114, -37.5), Color(0.75, 0.77, 0.8))
	for t: Array in [[12.2, 88.6], [8.2, 95.6], [5.2, 100.6]]:
		_box(glow, Vector3(t[0], 0.5, t[0]), Vector3(37.5, t[1], -37.5), Color(1.0, 0.85, 0.5))
	# NW: glass slab with a glowing crown
	_tower(-37.5, -37.5, [[22, 20, 84], [16, 14, 91]], GLASS, Color(0.7, 0.9, 1.0))
	_box(glow, Vector3(22.3, 0.8, 20.3), Vector3(-37.5, 82.5, -37.5), Color(0.35, 0.9, 1.0))
	_box(lit, Vector3(0.5, 22, 0.5), Vector3(-37.5, 102, -37.5), Color(0.6, 0.6, 0.62))
	_box(glow, Vector3(0.9, 0.9, 0.9), Vector3(-37.5, 113, -37.5), Color(1, 0.15, 0.1))
	# SE: brick giant with rooftop tanks and a sign
	_tower(37.5, 37.5, [[23, 23, 44], [18, 18, 62]], BRICK, Color(0.58, 0.34, 0.26))
	_water_tower(Vector3(33, 62.6, 33))
	_water_tower(Vector3(42, 62.6, 41))
	_billboard(Vector3(37.5, 67.5, 28.2), -Z, 16, 6, Color(0.75, 0.08, 0.1), ["BONK"], false)
	_billboard(Vector3(28.2, 67.5, 37.5), -X, 16, 6, Color(0.75, 0.08, 0.1), ["BONK"], false)
	# SW: modernist office slab
	_tower(-37.5, 37.5, [[24, 16, 74]], RIBBON, Color(0.8, 0.8, 0.78))
	_box(lit, Vector3(10, 4, 8), Vector3(-37.5, 76.8, 37.5), Color(0.4, 0.42, 0.45))
	_billboard(Vector3(-37.5, 77, 29.3), -Z, 20, 4.5, Color(0.05, 0.1, 0.3), ["ZED CORP"], false)
	_billboard(Vector3(-25.3, 77, 37.5), X, 14, 4.5, Color(0.05, 0.1, 0.3), ["ZED CORP"], false)

# ---------------------------------------------------------------- ground
func _mark(x0: float, x1: float, z0: float, z1: float, col: Color, y := 0.02) -> void:
	_quad(lit, Vector3(x0, y, z0), Vector3(x1, y, z0), Vector3(x1, y, z1), Vector3(x0, y, z1), Y, col)

func _ground() -> void:
	var asphalt := Color(0.17, 0.17, 0.19)
	# one big ground plane, with a hole left over each subway stairwell
	var ents: Array = L.SUBWAY_ENTRANCES.duplicate()
	ents.sort_custom(func(p: Vector3, q: Vector3) -> bool: return p.z < q.z)
	var zc := -260.0
	for e: Vector3 in ents:
		_mark(-260, 260, zc, e.z - 2.6, asphalt, 0.0)
		_mark(-260, e.x - 1.0, e.z - 2.6, e.z + 2.6, asphalt, 0.0)
		_mark(e.x + 1.0, 260, e.z - 2.6, e.z + 2.6, asphalt, 0.0)
		zc = e.z + 2.6
	_mark(-260, 260, zc, 260, asphalt, 0.0)
	# worn patches and repairs
	for i in 46:
		var along := rng.randf_range(-46, 46)
		var across := rng.randf_range(-5.5, 4.0)
		var w := rng.randf_range(1.0, 4.0)
		var l := rng.randf_range(1.5, 7.0)
		var c := asphalt.lightened(rng.randf_range(0.015, 0.04)) if i % 3 else asphalt.darkened(0.18)
		if i % 2 == 0:
			_mark(across, minf(across + w, 5.9), along, along + l, c, 0.01)
		else:
			_mark(along, along + l, across, minf(across + w, 5.9), c, 0.01)
	var white := Color(0.8, 0.8, 0.76)
	var yellow := Color(0.85, 0.65, 0.1)
	for s: float in [-1.0, 1.0]:
		# avenue: three dashed white lane lines
		var z := 12.0
		while z < 100.0:
			for x: float in [-3.0, 0.0, 3.0]:
				_mark(x - 0.1, x + 0.1, s * z, s * (z + 2.2), white)
			z += 5.0
		# cross street: double yellow centre line, white edge dashes
		_mark(s * 11.5, s * 100.0, -0.3, -0.12, yellow)
		_mark(s * 11.5, s * 100.0, 0.12, 0.3, yellow)
		var x2 := 12.0
		while x2 < 100.0:
			for zz: float in [-3.2, 3.2]:
				_mark(s * x2, s * (x2 + 2.2), zz - 0.1, zz + 0.1, white)
			x2 += 5.0
		# zebra crossings and stop lines
		for k in 10:
			var c0 := -5.7 + k * 1.2
			_mark(c0, c0 + 0.65, s * 6.4, s * 8.9, white)
			_mark(s * 6.4, s * 8.9, c0, c0 + 0.65, white)
		_mark(-5.8, 5.8, s * 10.0, s * 10.5, white)
		_mark(s * 10.0, s * 10.5, -5.8, 5.8, white)
	# manholes
	for p: Vector2 in [Vector2(1.5, 2), Vector2(-3.5, 16), Vector2(2, -27), Vector2(22, -1.5), Vector2(-31, 2.5),
			Vector2(-1, 38), Vector2(38, 3), Vector2(-16, -3)]:
		_cyl(lit, Vector3(p.x, 0, p.y), 0.55, 0.02, Color(0.3, 0.27, 0.24))
		_cyl(lit, Vector3(p.x, 0.005, p.y), 0.4, 0.02, Color(0.12, 0.11, 0.11))
	# sidewalks
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			var hole := Vector2(-1, -1)
			for e: Vector3 in L.SUBWAY_ENTRANCES:
				if sign(e.x) == sx and sign(e.z) == sz:
					hole = Vector2(abs(e.z) - 9.0, abs(e.z) - 3.0)
			_walk(Vector3(sx * 6, 0, sz * 6), Vector3(0, 0, sz), Vector3(sx, 0, 0), (110.0 if sz < 0 else 64.0), hole)
			_walk(Vector3(sx * 9, 0, sz * 6), Vector3(sx, 0, 0), Vector3(0, 0, sz), (41.0 if sx > 0 else 91.0), Vector2(-1, -1))
	# subway ventilation grates in the sidewalk
	for g: Vector3 in [Vector3(7.6, 0, -30), Vector3(-7.6, 0, 31), Vector3(7.6, 0, 33), Vector3(-7.6, 0, -34)]:
		_mm(lit, g.x - 0.7, g.x + 0.7, 0.15, 0.17, g.z - 2.0, g.z + 2.0, Color(0.07, 0.07, 0.08))
		for k in 9:
			_mm(lit, g.x - 0.7, g.x + 0.7, 0.17, 0.185, g.z - 2.0 + k * 0.5 - 0.06, g.z - 2.0 + k * 0.5 + 0.06, Color(0.3, 0.3, 0.31))

# One sidewalk strip: `side` points from the kerb toward the buildings. Tiled near the
# play area, a single slab further out. hole = (from, to) along the strip left open.
func _walk(o: Vector3, dir: Vector3, side: Vector3, length: float, hole: Vector2) -> void:
	var h := L.KERB_H
	var kerb := Color(0.62, 0.62, 0.6)
	var near := minf(length, 45.0)
	var segs := [[0.0, near]]
	if hole.x >= 0:
		segs = [[0.0, hole.x], [hole.y, near]]
	for sg: Array in segs:
		var a: float = sg[0]
		var bb: float = sg[1]
		_ob(lit, o, dir, side, a, bb, -0.1, h, 0.0, 0.3, kerb)
		var t := a
		while t < bb - 0.01:
			for r in 3:
				var c := Color(0.5, 0.5, 0.49).darkened(rng.randf_range(0.0, 0.16))
				if rng.randf() < 0.04:
					c = c.darkened(0.25)
				var p := o + dir * t + side * (0.3 + r * 0.9) + Y * h
				_quad(lit, p, p + dir, p + dir + side * 0.9, p + side * 0.9, Y, c)
			t += 1.0
	_quad(lit, o, o + side * 3, o + side * 3 + Y * h, o + Y * h, -dir, kerb)
	if length > near:
		_ob(lit, o, dir, side, near, length, -0.1, h, 0.0, 3.0, Color(0.46, 0.46, 0.45))

# ---------------------------------------------------------------- subway entrance
func _subway(c: Vector3) -> void:
	var s: float = sign(c.z)
	var d := Vector3(0, 0, s)          # points away from the intersection; stairs descend this way
	var h := L.KERB_H
	var stone := Color(0.6, 0.6, 0.58)
	var green := Color(0.08, 0.3, 0.16)
	# paving frame around the opening (opening: 2 wide, 5.2 long)
	_ob(lit, c, d, X, -3.0, 3.0, -0.1, h, -1.5, -1.0, stone)
	_ob(lit, c, d, X, -3.0, 3.0, -0.1, h, 1.0, 1.5, stone)
	_ob(lit, c, d, X, -3.0, -2.6, -0.1, h, -1.0, 1.0, stone)
	_ob(lit, c, d, X, 2.6, 3.0, -0.1, h, -1.0, 1.0, stone)
	# stairs: lit by the street at the top, by the station at the bottom
	for k in 12:
		var top := h - (k + 1) * 0.27
		var f := k / 11.0
		var col := Color(0.42, 0.42, 0.4).lerp(Color(0.07, 0.07, 0.08), minf(f * 1.7, 1.0))
		if f > 0.45:
			col = Color(0.07, 0.07, 0.08).lerp(Color(0.5, 0.42, 0.22), (f - 0.45) / 0.55)
		if k % 2 == 1:
			col = col * 0.72
		_ob(glow, c, d, X, -2.6 + k * 0.4, -2.2 + k * 0.4, -3.6, top, -1.0, 1.0, col)
		_ob(glow, c, d, X, -2.6 + k * 0.4, -2.44 + k * 0.4, top, top + 0.01, -1.0, 1.0, col.lerp(Color(0.9, 0.75, 0.2), 0.45))
	_ob(glow, c, d, X, 2.2, 2.6, -3.6, h - 13 * 0.27, -1.0, 1.0, Color(0.55, 0.47, 0.25))
	# tiled walls, darker with depth
	for sd: float in [-1.0, 1.0]:
		_ob(glow, c, d, X, -2.6, 2.6, -1.0, h - 0.02, sd * 1.0, sd * 1.2, Color(0.4, 0.42, 0.38))
		_ob(glow, c, d, X, -2.6, 2.6, -1.3, -1.0, sd * 0.98, sd * 1.2, Color(0.1, 0.3, 0.18))
		_ob(glow, c, d, X, -2.6, 2.6, -2.4, -1.3, sd * 1.0, sd * 1.2, Color(0.2, 0.21, 0.19))
		_ob(glow, c, d, X, -2.6, 2.6, -3.6, -2.4, sd * 1.0, sd * 1.2, Color(0.42, 0.38, 0.22))
	_ob(glow, c, d, X, 2.6, 2.8, -1.0, h - 0.02, -1.2, 1.2, Color(0.4, 0.42, 0.38))
	_ob(glow, c, d, X, 2.6, 2.8, -1.3, -1.0, -1.2, 1.2, Color(0.1, 0.3, 0.18))
	_ob(glow, c, d, X, 2.6, 2.8, -3.6, -1.3, -1.2, 1.2, Color(0.95, 0.85, 0.5))   # the bright mezzanine below
	_ob(glow, c, d, X, 2.58, 2.6, -2.2, -1.6, -0.8, 0.8, Color(0.05, 0.05, 0.06))
	_text(glow, "TRAINS", c + d * 2.57 + Y * -1.9, -d, 0.06, Color(1, 1, 1))
	# low wall + green railing on three sides
	var rails := [[-2.8, 2.8, -1.4, -1.1], [-2.8, 2.8, 1.1, 1.4], [2.7, 3.0, -1.4, 1.4]]
	for r: Array in rails:
		var r0: float = r[0]
		var r1: float = r[1]
		var r2: float = r[2]
		var r3: float = r[3]
		_ob(lit, c, d, X, r0, r1, h, 0.45, r2, r3, stone)
		_ob(lit, c, d, X, r0, r1, 1.2, 1.3, r2 + 0.08, r3 - 0.08, green)
		_ob(lit, c, d, X, r0, r1, 0.8, 0.88, r2 + 0.1, r3 - 0.1, green)
	for sd: float in [-1.0, 1.0]:
		for k in 6:
			_ob(lit, c, d, X, -2.7 + k * 1.1, -2.58 + k * 1.1, 0.45, 1.3, sd * 1.19, sd * 1.31, green)
			_ob(lit, c, d, X, -2.15 + k * 1.1, -2.07 + k * 1.1, 0.45, 1.2, sd * 1.21, sd * 1.29, green)
		_ob(lit, c, d, X, 2.79, 2.91, 0.45, 1.3, sd * 0.45 - 0.06, sd * 0.45 + 0.06, green)
		# globe lamp post at the open end
		_ob(lit, c, d, X, -2.95, -2.75, h, 3.0, sd * 1.25 - 0.1, sd * 1.25 + 0.1, green)
		_ob(lit, c, d, X, -3.0, -2.7, h, 0.6, sd * 1.25 - 0.15, sd * 1.25 + 0.15, green.darkened(0.3))
		_ob(glow, c, d, X, -3.1, -2.6, 3.0, 3.28, sd * 1.25 - 0.25, sd * 1.25 + 0.25, Color(0.95, 0.95, 0.85))
		_ob(glow, c, d, X, -3.1, -2.6, 3.28, 3.55, sd * 1.25 - 0.25, sd * 1.25 + 0.25, Color(0.2, 0.95, 0.4))
	# sign over the open end
	_ob(glow, c, d, X, -2.92, -2.78, 2.25, 2.85, -1.15, 1.15, Color(0.03, 0.1, 0.06))
	_text(glow, "SUBWAY", c + d * -2.93 + Y * 2.55, -d, 0.085, Color(1, 1, 1))
	_text(glow, "SUBWAY", c + d * -2.77 + Y * 2.55, d, 0.085, Color(1, 1, 1))
	B.collider(self, Vector3(3, 4, 6), c + Y * 2.0)

# ---------------------------------------------------------------- arm ends
# North: crashed bus + police line; the avenue runs on to a tower built across it.
func _end_north() -> void:
	var xf := Transform3D(Basis(Y, deg_to_rad(9.0)), Vector3(-0.3, 0, -50.3))
	var body := Color(0.82, 0.84, 0.86)
	_tb(lit, xf, Vector3(12.4, 2.75, 2.6), Vector3(0, 1.85, 0), body)
	_tb(lit, xf, Vector3(12.44, 0.35, 2.64), Vector3(0, 1.05, 0), Color(0.1, 0.25, 0.6))
	_tb(lit, xf, Vector3(12.0, 0.25, 2.3), Vector3(0, 3.3, 0), Color(0.6, 0.62, 0.64))
	_tb(lit, xf, Vector3(11.2, 0.95, 2.66), Vector3(0.3, 2.25, 0), Color(0.07, 0.09, 0.12))
	_tb(lit, xf, Vector3(12.46, 1.2, 2.2), Vector3(0, 2.2, 0), Color(0.07, 0.09, 0.12))
	for i in 7:
		_tb(lit, xf, Vector3(0.14, 0.95, 2.68), Vector3(-5.3 + i * 1.87, 2.25, 0), body)
	for wx: float in [-4.0, 3.6]:
		_tb(lit, xf, Vector3(1.1, 1.1, 2.7), Vector3(wx, 0.55, 0), Color(0.06, 0.06, 0.07))
		_tb(lit, xf, Vector3(0.5, 0.5, 2.74), Vector3(wx, 0.55, 0), Color(0.5, 0.5, 0.5))
	_tb(lit, xf, Vector3(1.2, 2.1, 0.1), Vector3(4.6, 1.5, 1.3), Color(0.25, 0.27, 0.3))
	_tb(glow, xf, Vector3(4.6, 0.5, 0.06), Vector3(-2.5, 3.0, 1.31), Color(0.05, 0.04, 0.02))
	_text(glow, "NOT IN SERVICE", xf * Vector3(-2.5, 3.0, 1.36), xf.basis.z, 0.075, Color(1.0, 0.6, 0.1))
	# police sawhorses + concrete barriers closing the sidewalks and the gaps
	for s: float in [-1.0, 1.0]:
		var o := Vector3(s * 7.6, 0, -48.5)
		_mm(lit, o.x - 1.6, o.x + 1.6, 0.9, 1.3, o.z - 0.06, o.z + 0.06, Color(0.1, 0.25, 0.7))
		_text(lit, "POLICE LINE", o + Vector3(0, 1.1, 0.07), Z, 0.05, Color(1, 1, 1))
		for e: float in [-1.3, 1.3]:
			_beam(lit, o + Vector3(e, 1.0, 0), o + Vector3(e, 0.15, 0.45), 0.1, Color(0.8, 0.8, 0.8))
			_beam(lit, o + Vector3(e, 1.0, 0), o + Vector3(e, 0.15, -0.45), 0.1, Color(0.8, 0.8, 0.8))
		_mm(lit, s * 5.6, s * 9.0, 0.0, 1.0, -49.9, -49.3, Color(0.6, 0.6, 0.58))
		_mm(lit, s * 5.6, s * 9.0, 1.0, 1.25, -49.75, -49.45, Color(0.55, 0.55, 0.53))
	# the tower that straddles the avenue (z -110 .. -134)
	var tt := Color(0.8, 0.76, 0.66)
	_tower(0, -122, [[52, 24, 30], [34, 20, 62], [24, 16, 84], [16, 12, 96]], DECO, tt)
	for i in 4:   # stepped pyramid roof
		_box(lit, Vector3(14 - i * 3.4, 3, 10 - i * 2.4), Vector3(0, 98 + i * 3, -122), Color(0.3, 0.55, 0.45))
	_box(lit, Vector3(0.8, 14, 0.8), Vector3(0, 116, -122), Color(0.7, 0.7, 0.6))
	_box(glow, Vector3(1.4, 1.4, 1.4), Vector3(0, 110, -122), Color(1.0, 0.8, 0.4))
	_mm(lit, -8, 8, 0, 13, -110.3, -109.9, tt.darkened(0.25))       # portal frame
	_mm(glow, -6, 6, 0, 10, -110.4, -109.8, Color(0.03, 0.03, 0.05))  # road tunnel through the base
	_mm(glow, -6, 6, 10, 10.6, -110.45, -109.75, Color(1.0, 0.8, 0.4))
	_billboard(Vector3(0, 71, -111.9), Z, 7, 7, Color(1.0, 0.93, 0.75), [], false)   # clock face
	_mm(lit, -0.3, 0.3, 71, 74, -111.7, -111.6, Color(0.1, 0.1, 0.1))
	_mm(lit, 0, 2.2, 70.7, 71.3, -111.7, -111.6, Color(0.1, 0.1, 0.1))

# South: quarantine wall; beyond it the avenue runs onto a suspension bridge.
func _end_south() -> void:
	var conc := Color(0.58, 0.58, 0.56)
	for i in 6:   # wall panels either side of the gate
		var x0 := -9.0 + i
		_mm(lit, x0, x0 + 0.96, 0, 4.6 + (i % 2) * 0.15, 48.2, 48.8, conc.darkened(0.06 * (i % 3)))
		_mm(lit, -x0 - 0.96, -x0, 0, 4.6 + (i % 2) * 0.15, 48.2, 48.8, conc.darkened(0.06 * ((i + 1) % 3)))
	_mm(lit, -3.0, 3.0, 0, 4.2, 48.35, 48.6, Color(0.22, 0.27, 0.25))          # steel gate
	for i in 8:
		_mm(lit, -3.0 + i * 0.75, -3.0 + i * 0.75 + 0.38, 0.1, 0.9, 48.3, 48.36, Color(0.9, 0.75, 0.1))
		_mm(lit, -2.62 + i * 0.75, -2.62 + i * 0.75 + 0.37, 0.1, 0.9, 48.3, 48.36, Color(0.08, 0.08, 0.08))
	_mm(lit, -0.06, 0.06, 0.9, 4.2, 48.3, 48.36, Color(0.1, 0.1, 0.1))
	_mm(lit, -3.4, 3.4, 4.2, 5.6, 48.2, 48.8, conc)
	_text(glow, "QUARANTINE", Vector3(0, 4.9, 48.18), -Z, 0.15, Color(1.0, 0.2, 0.15))
	_text(lit, "KEEP OUT", Vector3(-6.0, 3.0, 48.18), -Z, 0.12, Color(0.75, 0.1, 0.1))
	_text(lit, "NO BRAINS", Vector3(6.0, 2.6, 48.18), -Z, 0.1, Color(0.1, 0.3, 0.1))
	_mm(lit, -9, 9, 4.9, 5.0, 48.45, 48.55, Color(0.15, 0.15, 0.15))             # wire
	for s: float in [-1.0, 1.0]:   # guard towers
		for e: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
			_box(lit, Vector3(0.25, 7, 0.25), Vector3(s * 7 + e.x * 1.1, 3.5, 51 + e.y * 1.1), Color(0.2, 0.22, 0.2))
		_box(lit, Vector3(3.0, 0.25, 3.0), Vector3(s * 7, 7, 51), Color(0.2, 0.22, 0.2))
		_box(lit, Vector3(2.8, 1.1, 2.8), Vector3(s * 7, 7.6, 51), Color(0.3, 0.34, 0.28))
		_box(glow, Vector3(2.5, 0.8, 2.5), Vector3(s * 7, 8.5, 51), Color(0.9, 0.85, 0.6))
		_box(lit, Vector3(3.4, 0.3, 3.4), Vector3(s * 7, 9.1, 51), Color(0.2, 0.22, 0.2))
	# bridge: deck from z=70, stone tower at z=106..112
	var stone := Color(0.55, 0.47, 0.38)
	var water := Color(0.07, 0.12, 0.17)
	var cable := Color(0.2, 0.2, 0.22)
	for s: float in [-1.0, 1.0]:
		_mark(s * 14.5, s * 260, 70.0, 260.0, water, 0.03)
		_mm(lit, s * 13.0, s * 14.5, 0, 1.4, 70, 250, Color(0.3, 0.3, 0.32))
		_mm(lit, s * 15.5, s * 11.0, 0, 62, 106, 112, stone)
		for j in 7:   # diagonal stays
			var zz := 100.0 - j * 4.5
			_beam(lit, Vector3(s * 13.2, 60, 106), Vector3(s * 13.2, 1.4, zz), 0.3, cable)
			_beam(lit, Vector3(s * 1.0, 60, 106), Vector3(s * 1.0, 0.0, zz), 0.3, cable)
		# pointed arch
		_mm(lit, s * 11.0, s * 9.5, 30, 34, 106, 112, stone)
		_mm(lit, s * 2.0, s * 3.5, 30, 34, 106, 112, stone)
		_mm(lit, s * 11.0, s * 8.0, 34, 38, 106, 112, stone)
		_mm(lit, s * 2.0, s * 5.0, 34, 38, 106, 112, stone)
		_beam(lit, Vector3(s * 13.2, 61, 106), Vector3(s * 13.2, 1.0, 71), 0.6, cable)
	_mm(lit, -2.0, 2.0, 0, 62, 106, 112, stone)
	_mm(lit, -11.0, 11.0, 38, 62, 106, 112, stone)
	_mm(lit, -16.5, 16.5, 62, 65, 105, 113, stone.lightened(0.1))
	_mm(lit, -12, 12, 65, 67, 106.5, 111.5, stone)

# East: the elevated train. A car has come off the viaduct and lies across the street.
func _end_east() -> void:
	var steel := Color(0.14, 0.24, 0.2)
	var z := -126.0
	while z <= 126.0:
		for x: float in [52.6, 59.4]:
			_box(lit, Vector3(0.8, 6.6, 0.8), Vector3(x, 3.3, z), steel)
			_beam(lit, Vector3(x, 4.6, z + 0.5), Vector3(x, 6.4, z + 2.4), 0.3, steel)
			_beam(lit, Vector3(x, 4.6, z - 0.5), Vector3(x, 6.4, z - 2.4), 0.3, steel)
		_box(lit, Vector3(7.8, 0.9, 0.9), Vector3(56, 6.5, z), steel)
		z += 14.0
	for x: float in [52.6, 59.4]:
		var e: float = sign(x - 56.0) * 0.5
		_mm(lit, x - 0.3, x + 0.3, 6.6, 8.0, -130, 130, steel)
		_mm(lit, x + e - 0.08, x + e + 0.08, 8.0, 9.1, -130, 130, steel.darkened(0.2))
	_mm(lit, 52.3, 59.7, 7.6, 8.0, -130, 130, Color(0.2, 0.19, 0.18))
	# station on the far side, over the street
	_mm(lit, 60.0, 62.4, 8.0, 8.3, -16, 16, Color(0.3, 0.3, 0.3))
	_mm(lit, 61.9, 62.3, 8.3, 11.2, -16, 16, steel)
	_mm(glow, 61.8, 61.9, 9.2, 10.6, -15, 15, Color(0.95, 0.85, 0.55))
	for i in 11:
		_mm(lit, 61.7, 61.82, 8.3, 11.2, -15.15 + i * 3.0, -14.85 + i * 3.0, steel)
	_mm(lit, 59.6, 62.8, 11.2, 11.5, -17, 17, steel.darkened(0.3))
	_billboard(Vector3(59.9, 12.4, 0), -X, 9.0, 1.6, Color(0.03, 0.05, 0.08), ["BONK ST"], false)
	# train on the viaduct (three cars), last car derailed onto the street
	for i in 3:
		_train_car(Transform3D(Basis.IDENTITY, Vector3(54.6, 8.0, -54.0 + i * 18.3)), true)
	var fx := Transform3D(Basis(Y, deg_to_rad(-4.0)) * Basis(Z, deg_to_rad(-13.0)), Vector3(50.6, 0.25, 0.3))
	_train_car(fx, false)
	_mm(lit, 48.4, 53, 0, 0.6, 5.5, 9, Color(0.35, 0.33, 0.3))   # rubble under it
	_mm(lit, 49, 52.5, 0, 0.9, -9, -6.5, Color(0.3, 0.3, 0.3))
	# power plant closing the street far to the east
	_bldg(128, 150, -40, 40, 29.0, WARE, Color(0.5, 0.3, 0.24), false)
	for i in 4:
		var cz := -24.0 + i * 16.0
		_cyl(lit, Vector3(139, 29, cz), 3.0, 44, Color(0.55, 0.36, 0.3), 2.0)
		_cyl(lit, Vector3(139, 66, cz), 2.2, 3, Color(0.85, 0.85, 0.85), 2.1)
		_cyl(lit, Vector3(139, 72, cz), 2.07, 3, Color(0.8, 0.12, 0.1), 2.0)
		_box(glow, Vector3(0.9, 0.9, 0.9), Vector3(139, 75.6, cz), Color(1, 0.15, 0.1))
	# far side of the elevated avenue, and the street beyond it
	for sz: float in [-1.0, 1.0]:
		var o := Vector3(62.5, 0, sz * 9)
		_bldg(62.5, 78.5, minf(sz * 9, sz * 25), maxf(sz * 9, sz * 25), 37.0, WARE, _tint(WARE))
		_row(o, Vector3(0, 0, sz), -X, 16.0, 120.0, [WARE, BRICK, WARE, RIBBON], 20.0, 44.0, -100.0)
		_row(o, X, Vector3(0, 0, -sz), 16.0, 65.5, [WARE, WARE, BRICK], 18.0, 40.0, -100.0)
		_ob(lit, Vector3(62.5, 0, sz * 6), X, Vector3(0, 0, sz), 0, 66, -0.1, L.KERB_H, 0, 3, Color(0.46, 0.46, 0.45))

# A subway car. Origin at rail level, centre of the car, long axis Z, doors face -X.
func _train_car(xf: Transform3D, lights: bool) -> void:
	var silver := Color(0.6, 0.63, 0.66)
	_tb(lit, xf, Vector3(2.9, 3.0, 17.6), Vector3(0, 2.1, 0), silver)
	_tb(lit, xf, Vector3(2.5, 0.3, 17.2), Vector3(0, 3.7, 0), silver.darkened(0.25))
	_tb(lit, xf, Vector3(2.4, 0.7, 16.0), Vector3(0, 0.35, 0), Color(0.08, 0.08, 0.09))
	_tb(lit, xf, Vector3(2.94, 0.3, 17.64), Vector3(0, 1.3, 0), Color(0.1, 0.2, 0.55))
	var wc := Color(0.95, 0.9, 0.7) if lights else Color(0.05, 0.06, 0.08)
	var wb := glow if lights else lit
	for i in 4:
		_tb(wb, xf, Vector3(2.96, 0.95, 2.5), Vector3(0, 2.55, -6.3 + i * 4.2), wc)
	for i in 3:   # doors
		_tb(lit, xf, Vector3(2.98, 2.2, 1.3), Vector3(0, 1.85, -4.2 + i * 4.2), silver.darkened(0.12))
		_tb(wb, xf, Vector3(3.0, 0.8, 0.9), Vector3(0, 2.55, -4.2 + i * 4.2), wc)
	for e: float in [-1.0, 1.0]:
		_tb(wb, xf, Vector3(1.6, 1.0, 0.06), Vector3(0, 2.5, e * 8.81), wc)
	# route bullet
	_tb(glow, xf, Vector3(0.06, 0.9, 0.9), Vector3(-1.47, 2.6, 7.7), Color(0.6, 0.25, 0.75))
	_text(glow, "Z", xf * Vector3(-1.51, 2.6, 7.7), -xf.basis.x, 0.14, Color(1, 1, 1), xf.basis.y)

# West: wall of shipping containers, a tower crane over the street, billboards closing the view.
func _end_west() -> void:
	var cols := [Color(0.6, 0.2, 0.12), Color(0.12, 0.3, 0.5), Color(0.15, 0.4, 0.25), Color(0.75, 0.45, 0.08),
		Color(0.5, 0.5, 0.52), Color(0.45, 0.12, 0.15), Color(0.1, 0.35, 0.4)]
	var placed := [[-6.1, 0.0, 0.0], [0.0, 0.0, 0.05], [6.1, 0.0, -0.03], [-5.4, 2.6, 0.06], [0.9, 2.6, -0.05],
		[6.6, 2.6, 0.1], [-2.0, 5.2, -0.12]]
	for i in placed.size():
		var p: Array = placed[i]
		var xf := Transform3D(Basis(Y, p[2]), Vector3(-49.9, p[1], p[0]))
		_container(xf, cols[i])
	_billboard(Vector3(-48.3, 1.9, 0.0), X, 5.0, 1.8, Color(0.9, 0.45, 0.05), ["ROAD", "CLOSED"], false)
	_text(lit, "BONK CO", Vector3(-48.5, 4.1, -5.4), X, 0.16, Color(0.9, 0.9, 0.85))
	_text(lit, "ZED LINE", Vector3(-48.5, 4.0, 6.6), X, 0.14, Color(0.9, 0.9, 0.85))
	# tower crane standing just past the wall, jib reaching back over the street
	var yel := Color(0.9, 0.7, 0.08)
	var m := Vector3(-58, 0, -6.9)
	_box(lit, Vector3(3.4, 0.8, 3.4), m + Y * 0.4, Color(0.5, 0.5, 0.5))
	for e: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		_box(lit, Vector3(0.3, 50, 0.3), m + Vector3(e.x * 0.9, 25.8, e.y * 0.9), yel)
	for i in 12:
		var y := 1.0 + i * 4.1
		var sg := 1.0 if i % 2 == 0 else -1.0
		for e: float in [-1.0, 1.0]:
			_beam(lit, m + Vector3(-0.9 * sg, y, e * 0.9), m + Vector3(0.9 * sg, y + 4.1, e * 0.9), 0.18, yel)
			_beam(lit, m + Vector3(e * 0.9, y, -0.9 * sg), m + Vector3(e * 0.9, y + 4.1, 0.9 * sg), 0.18, yel)
	_box(lit, Vector3(2.6, 2.4, 2.6), m + Y * 52, Color(0.85, 0.85, 0.8))      # cab
	_box(glow, Vector3(1.6, 0.9, 2.64), m + Y * 52.2, Color(0.8, 0.9, 0.95))
	var jy := 54.0
	for e: float in [-1.0, 1.0]:
		_beam(lit, m + Vector3(-14, jy, e * 0.7), m + Vector3(40, jy, e * 0.7), 0.3, yel)
	_beam(lit, m + Vector3(-14, jy + 1.6, 0), m + Vector3(40, jy + 1.6, 0), 0.3, yel)
	for i in 18:
		var x := -14.0 + i * 3.0
		_beam(lit, m + Vector3(x, jy, -0.7), m + Vector3(x + 1.5, jy + 1.6, 0), 0.16, yel)
		_beam(lit, m + Vector3(x + 1.5, jy + 1.6, 0), m + Vector3(x + 3.0, jy, 0.7), 0.16, yel)
		_beam(lit, m + Vector3(x, jy, -0.7), m + Vector3(x + 3.0, jy, 0.7), 0.16, yel)
	_box(lit, Vector3(4, 3, 2.4), m + Vector3(-12, jy - 1.2, 0), Color(0.4, 0.4, 0.42))   # counterweight
	_beam(lit, m + Y * 62, m + Vector3(30, jy + 1.6, 0), 0.14, Color(0.15, 0.15, 0.15))
	_beam(lit, m + Y * 62, m + Vector3(-13, jy + 1.6, 0), 0.14, Color(0.15, 0.15, 0.15))
	_box(lit, Vector3(0.4, 10, 0.4), m + Y * 58, yel)
	_box(glow, Vector3(0.7, 0.7, 0.7), m + Y * 63.3, Color(1, 0.15, 0.1))
	# a container dangling over the street
	var hook := m + Vector3(22, jy, 0)
	_box(lit, Vector3(0.16, 26, 0.16), hook - Y * 13, Color(0.12, 0.12, 0.12))
	var cxf := Transform3D(Basis(Y, 0.5) * Basis(X, 0.08), hook - Y * 30.5)
	for e: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		_beam(lit, hook - Y * 26, cxf * Vector3(e.x * 1.1, 2.6, e.y * 2.8), 0.12, Color(0.12, 0.12, 0.12))
	_container(cxf, Color(0.75, 0.45, 0.08))
	# the view closes on a wall of billboards
	_bldg(-126, -100, -34, 34, 64.0, GLASS, Color(0.6, 0.7, 0.9), false)
	_billboard(Vector3(-99.6, 13, 0), X, 16, 12, Color(0.85, 0.08, 0.1), ["BONK", "COLA"])
	_billboard(Vector3(-99.6, 30, 0), X, 16, 13, Color(0.1, 0.6, 0.25), ["EAT", "BRAINS"])
	_billboard(Vector3(-99.6, 47, 0), X, 16, 12, Color(0.9, 0.6, 0.05), ["ZOMBIE", "THE", "MUSICAL"])
	_billboard(Vector3(-99.6, 59, 0), X, 16, 5, Color(0.1, 0.2, 0.8), ["I BONK NY"])

# Shipping container, origin at the middle of its base, long axis Z.
func _container(xf: Transform3D, c: Color) -> void:
	_tb(lit, xf, Vector3(2.44, 2.6, 6.06), Vector3(0, 1.3, 0), c)
	for k in 11:
		_tb(lit, xf, Vector3(2.5, 2.3, 0.14), Vector3(0, 1.3, -2.7 + k * 0.54), c.darkened(0.22))
	_tb(lit, xf, Vector3(2.52, 0.16, 6.1), Vector3(0, 2.52, 0), c.darkened(0.3))
	_tb(lit, xf, Vector3(2.52, 0.16, 6.1), Vector3(0, 0.08, 0), c.darkened(0.3))

# Distant towers so every gap in the roofline has city behind it.
func _skyline() -> void:
	var sts := [GLASS, DECO, RIBBON, GLASS]
	for i in 26:
		var ang := TAU * (i + rng.randf() * 0.6) / 26.0
		var r := rng.randf_range(125.0, 175.0)
		var p := Vector3(cos(ang) * r, 0, sin(ang) * r)
		if abs(p.x) < 24.0 or abs(p.z) < 24.0:
			continue
		if p.z > 60.0 and i % 2 == 0:
			continue   # leave river sky around the bridge
		var st: int = sts[i % 4]
		var w := rng.randf_range(18.0, 30.0)
		var h := rng.randf_range(60.0, 125.0)
		_tower(p.x, p.z, [[w, w, h * 0.7], [w * 0.7, w * 0.7, h]], st, _tint(st))

# ---------------------------------------------------------------- collision
func _colliders() -> void:
	var ch := L.CORRIDOR_HALF
	var a := L.ARM_LEN
	B.collider(self, Vector3(400, 2, 400), Vector3(0, -1, 0))
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			B.collider(self, Vector3(60, 120, 60), Vector3(sx * (ch + 30), 60, sz * (ch + 30)))
	for d: Vector3 in [Z, -Z, X, -X]:
		var size := Vector3(ch * 2 + 2, 120, 2) if d.z != 0 else Vector3(2, 120, ch * 2 + 2)
		B.collider(self, size, d * (a + 1.0) + Y * 60)
