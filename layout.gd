extends RefCounted
# The shared map contract. Use via: const L = preload("res://layout.gd")
#
# The level is an endless Manhattan-style street grid, generated from SEED and the block
# coordinates only, so the same place always looks the same. Ground is flat at y = 0.
#   - avenues run north-south (along Z) at x = i * PITCH, streets run east-west (along X) at
#     z = j * PITCH. Avenue 0 and street 0 cross at the origin (the spawn intersection).
#   - each street is a corridor 2 * CORRIDOR_HALF wide: road in the middle, a sidewalk each side.
#   - between the corridors lie square blocks, BLOCK metres a side. Block (bx, bz) spans
#     x in [bx * PITCH + 9, (bx + 1) * PITCH - 9] and the same in z.
#   - a "tile" (bx, bz) is the PITCH x PITCH square that world.gd streams as one unit: block
#     (bx, bz) plus intersection (bx, bz) on its north-west corner, the avenue segment on its west
#     side and the street segment on its north side.
#   - most blocks are solid buildings; "open" blocks (park, plaza, parking lot) can be walked.
#
# Everything here is static and position based: it works anywhere in the world, whether or not
# world.gd has built that place yet. world.gd draws exactly what block() describes.

const ROAD_HALF := 6.0        # road is 12 wide
const SIDEWALK := 3.0         # sidewalk width, raised kerb
const CORRIDOR_HALF := 9.0    # building faces are 9 m from each street's centre line
const KERB_H := 0.15          # sidewalk height above the road
const PITCH := 82.0           # distance between street centre lines
const BLOCK := 64.0           # PITCH - 2 * CORRIDOR_HALF
const LOT_DEPTH := 16.0       # depth of the buildings that line a block
const SEED := 20240611        # the city seed (fixed for now)

# Legacy: the two stairwells of the origin intersection (fx.gd still reads this constant).
# Everything else should use subway_entrances() / subway_near().
const SUBWAY_ENTRANCES := [Vector3(7.5, 0, 20), Vector3(-7.5, 0, -20)]

# facade styles (world.gd has one window texture per style)
const BRICK := 0
const DECO := 1
const GLASS := 2
const RIBBON := 3
const WARE := 4
const FLOOR_H := [3.2, 3.4, 3.5, 3.4, 4.0]    # metres per storey, per style
const TINTS := [
	[Color(0.62, 0.3, 0.24), Color(0.5, 0.25, 0.2), Color(0.72, 0.5, 0.36), Color(0.55, 0.36, 0.3), Color(0.42, 0.27, 0.24), Color(0.75, 0.68, 0.55)],
	[Color(0.85, 0.8, 0.68), Color(0.72, 0.7, 0.66), Color(0.8, 0.72, 0.58), Color(0.6, 0.62, 0.66)],
	[Color(0.7, 0.85, 1.0), Color(0.6, 0.9, 0.85), Color(0.9, 0.9, 0.95), Color(0.95, 0.8, 0.6), Color(0.55, 0.65, 0.85)],
	[Color(0.8, 0.8, 0.78), Color(0.65, 0.62, 0.58), Color(0.85, 0.78, 0.65), Color(0.55, 0.6, 0.62)],
	[Color(0.55, 0.28, 0.2), Color(0.45, 0.3, 0.25), Color(0.6, 0.45, 0.35), Color(0.4, 0.38, 0.36)],
]

# Sides of a block / lot: 0 = north (-Z), 1 = east (+X), 2 = south (+Z), 3 = west (-X).
# A lot's `sides` is a bit mask (1 << side) of the sides that face a street.
const SIDE_OUT := [Vector3(0, 0, -1), Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(-1, 0, 0)]

# What the buildings along one side of a block look like, per district.
const DISTRICTS := {
	"midtown": {"styles": [DECO, DECO, GLASS, RIBBON], "hmin": 34.0, "hmax": 68.0, "ads": false},
	"glass": {"styles": [GLASS, RIBBON, GLASS, DECO], "hmin": 30.0, "hmax": 58.0, "ads": true},
	"brick": {"styles": [BRICK, BRICK, BRICK, WARE], "hmin": 16.0, "hmax": 30.0, "ads": false},
	"industrial": {"styles": [WARE, WARE, BRICK], "hmin": 20.0, "hmax": 36.0, "ads": false},
}

# Skyscraper shapes: tiers are [width, depth, top as a fraction of the height];
# h = [height at the origin intersection, min, max].
const TOWERS := [
	{"st": DECO, "tint": Color(0.78, 0.76, 0.72), "h": [100.0, 82.0, 125.0],
		"tiers": [[22, 22, 0.48], [17, 17, 0.76], [12, 12, 0.88], [8, 8, 0.95], [5, 5, 1.0]]},   # 0 art-deco needle
	{"st": GLASS, "tint": Color(0.7, 0.9, 1.0), "h": [91.0, 72.0, 118.0],
		"tiers": [[22, 20, 0.923], [16, 14, 1.0]]},                                                  # 1 glass slab
	{"st": BRICK, "tint": Color(0.58, 0.34, 0.26), "h": [62.0, 48.0, 70.0],
		"tiers": [[23, 23, 0.71], [18, 18, 1.0]]},                                                   # 2 brick giant
	{"st": RIBBON, "tint": Color(0.8, 0.8, 0.78), "h": [74.0, 58.0, 96.0],
		"tiers": [[24, 16, 1.0]]},                                                                   # 3 modernist slab
	{"st": WARE, "tint": Color(0.5, 0.3, 0.24), "h": [29.0, 25.0, 33.0],
		"tiers": [[28, 22, 1.0]]},                                                                   # 4 power plant
]

# The four blocks round the origin keep the hand-made look of the first map.
# corner: which corner lot (0 NW, 1 NE, 2 SE, 3 SW) touches the origin, its style and height;
# side: district per block side; tower: the skyscraper in the middle of the block.
const ORIGIN := {
	Vector2i(0, -1): {"corner": 3, "cst": DECO, "ch": 58.8, "district": "midtown", "side": {2: "industrial"}, "tower": 0},
	Vector2i(-1, -1): {"corner": 2, "cst": GLASS, "ch": 67.5, "district": "midtown", "side": {2: "glass"}, "tower": 1},
	Vector2i(0, 0): {"corner": 0, "cst": BRICK, "ch": 39.4, "district": "brick", "side": {0: "industrial"}, "tower": 2},
	Vector2i(-1, 0): {"corner": 1, "cst": RIBBON, "ch": 48.6, "district": "brick", "side": {0: "glass"}, "tower": 3},
}

# What fills a street segment (see clutter.gd). Picked by hash; one entry per 5 %.
const THEMES := ["quiet", "quiet", "quiet", "quiet", "quiet", "quiet", "taxi", "taxi", "taxi", "taxi",
	"roadblock", "roadblock", "bus", "bus", "works", "works", "market", "market", "pileup", "pileup"]

static var _cache := {}

# ---------------------------------------------------------------- seeded numbers
static func hash3(a: int, b: int, c: int) -> int:
	var h: int = (a * 374761393 + b * 668265263 + c * 1013904223 + SEED) & 0xffffffff
	h = ((h ^ (h >> 13)) * 1274126177) & 0xffffffff
	h = ((h ^ (h >> 16)) * 2246822519) & 0xffffffff
	return h ^ (h >> 15)

static func rand01(a: int, b: int, c: int) -> float:
	return float(hash3(a, b, c) % 65536) / 65536.0

# Smooth noise over block coordinates (used for districts).
static func _vnoise(x: float, z: float, salt: int) -> float:
	var ix := floori(x)
	var iz := floori(z)
	var fx := x - ix
	var fz := z - iz
	fx = fx * fx * (3.0 - 2.0 * fx)
	fz = fz * fz * (3.0 - 2.0 * fz)
	var a := lerpf(rand01(ix, iz, salt), rand01(ix + 1, iz, salt), fx)
	var b := lerpf(rand01(ix, iz + 1, salt), rand01(ix + 1, iz + 1, salt), fx)
	return lerpf(a, b, fz)

# ---------------------------------------------------------------- where am I
# Signed offset from the nearest street centre line.
static func lat(v: float) -> float:
	return v - roundf(v / PITCH) * PITCH

# The tile (see top of file) that contains p.
static func tile_of(p: Vector3) -> Vector2i:
	return Vector2i(floori((p.x + CORRIDOR_HALF) / PITCH), floori((p.z + CORRIDOR_HALF) / PITCH))

static func block_rect(bx: int, bz: int) -> Rect2:
	return Rect2(bx * PITCH + CORRIDOR_HALF, bz * PITCH + CORRIDOR_HALF, BLOCK, BLOCK)

# Which environment a place belongs to. Stage 3 adds "residential", "beach", "desert":
# decide it here (per block, from noise), and give _gen_block() block types for it.
static func biome_of_block(_bx: int, _bz: int) -> String:
	return "downtown"

static func biome_at(p: Vector3) -> String:
	return biome_of_block(floori(p.x / PITCH), floori(p.z / PITCH))

# True on a road or sidewalk (inside a street corridor, `margin` away from the building line).
static func in_street(p: Vector3, margin := 0.0) -> bool:
	var h := CORRIDOR_HALF - margin
	return absf(lat(p.x)) <= h or absf(lat(p.z)) <= h

static func in_ns(p: Vector3) -> bool:  # inside a north-south avenue
	return absf(lat(p.x)) <= CORRIDOR_HALF

static func in_ew(p: Vector3) -> bool:  # inside an east-west street
	return absf(lat(p.z)) <= CORRIDOR_HALF

# True anywhere a character may stand: streets, and open blocks outside their buildings.
static func walkable(p: Vector3, margin := 0.0) -> bool:
	if in_street(p, margin):
		return true
	var b := block(floori(p.x / PITCH), floori(p.z / PITCH))
	if not b.open:
		return false
	var q := Vector2(p.x, p.z)
	for lot: Dictionary in b.lots:
		var r: Rect2 = lot.r
		if r.grow(margin).has_point(q):
			return false
	return true

# Push a point back onto walkable ground (street, sidewalk, park, plaza, parking lot).
static func clamp_to_streets(p: Vector3, margin := 0.5) -> Vector3:
	var h := CORRIDOR_HALF - margin
	var lx := lat(p.x)
	var lz := lat(p.z)
	if absf(lx) <= h or absf(lz) <= h:
		return p
	var b := block(floori(p.x / PITCH), floori(p.z / PITCH))
	if not b.open:
		# inside a solid block: snap to the nearer street
		if absf(lx) - h < absf(lz) - h:
			p.x += signf(lx) * h - lx
		else:
			p.z += signf(lz) * h - lz
		return p
	var q := Vector2(p.x, p.z)
	for lot: Dictionary in b.lots:
		var r: Rect2 = (lot.r as Rect2).grow(margin)
		if r.has_point(q):
			var dl := q.x - r.position.x
			var dr := r.end.x - q.x
			var dt := q.y - r.position.y
			var db := r.end.y - q.y
			var m := minf(minf(dl, dr), minf(dt, db))
			if m == dl:
				p.x = r.position.x
			elif m == dr:
				p.x = r.end.x
			elif m == dt:
				p.z = r.position.y
			else:
				p.z = r.end.y
			return p
	return p

# True when no building stands between a and b (both at street level).
static func sight_clear(a: Vector3, b: Vector3) -> bool:
	var d := b - a
	d.y = 0
	var n := int(d.length() / 3.0) + 1
	for i in range(1, n):
		if not walkable(a + d * (float(i) / n)):
			return false
	return true

# The closest building wall to p: {pos: point on the wall at ground level, normal: unit vector
# pointing away from the wall (into the street), height: top of that wall in metres (the roof,
# or the first setback of a stepped tower), top: highest point of the building, kind: lot kind}.
# Heights are the ones world.gd draws (both read block()). Empty-handed (no building within a
# block or two) it returns height 0 and a zero normal.
static func nearest_facade(p: Vector3) -> Dictionary:
	var q := Vector2(p.x, p.z)
	var cbx := floori(p.x / PITCH)
	var cbz := floori(p.z / PITCH)
	var best_d := 1e9
	var best_c := q
	var best_n := Vector2.ZERO
	var best_lot := {}
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var b := block(cbx + dx, cbz + dz)
			var br: Rect2 = b.rect
			var bc := Vector2(clampf(q.x, br.position.x, br.end.x), clampf(q.y, br.position.y, br.end.y))
			if bc.distance_to(q) >= best_d:
				continue
			for lot: Dictionary in b.lots:
				if int(lot.sides) == 0 and not b.open:
					continue
				var r: Rect2 = lot.r
				var c := Vector2(clampf(q.x, r.position.x, r.end.x), clampf(q.y, r.position.y, r.end.y))
				var n := Vector2.ZERO
				var d := 0.0
				if c != q:
					d = c.distance_to(q)
					var off := q - c
					n = Vector2(signf(off.x), 0) if absf(off.x) >= absf(off.y) else Vector2(0, signf(off.y))
				else:
					# inside the footprint: the nearest wall, seen from outside
					var dl := q.x - r.position.x
					var dr := r.end.x - q.x
					var dt := q.y - r.position.y
					var db := r.end.y - q.y
					var m := minf(minf(dl, dr), minf(dt, db))
					d = -m
					if m == dl:
						c.x = r.position.x
						n = Vector2(-1, 0)
					elif m == dr:
						c.x = r.end.x
						n = Vector2(1, 0)
					elif m == dt:
						c.y = r.position.y
						n = Vector2(0, -1)
					else:
						c.y = r.end.y
						n = Vector2(0, 1)
				if d < best_d:
					best_d = d
					best_c = c
					best_n = n
					best_lot = lot
	if best_lot.is_empty():
		return {"pos": p, "normal": Vector3.ZERO, "height": 0.0, "top": 0.0, "kind": ""}
	return {"pos": Vector3(best_c.x, 0, best_c.y), "normal": Vector3(best_n.x, 0, best_n.y),
		"height": float(best_lot.h), "top": float(best_lot.top), "kind": String(best_lot.kind)}

# ---------------------------------------------------------------- streets
# Avenues that carry the elevated train (never the spawn avenue or its neighbours).
static func _el_raw(i: int) -> bool:
	return absi(i) > 1 and hash3(i, 0, 21) % 4 == 0

static func is_el(i: int) -> bool:
	return _el_raw(i) and not _el_raw(i - 1)

# Theme of a street segment. axis 0 = the avenue segment of tile (bx, bz) (south of
# intersection (bx, bz)), axis 1 = its street segment (east of the intersection).
static func seg_theme(axis: int, bx: int, bz: int) -> String:
	if axis == 0:
		if bx == 0 and bz == 0:
			return "origin_s"
		if bx == 0 and bz == -1:
			return "origin_n"
		if is_el(bx):
			return "el"
	else:
		if bx == 0 and bz == 0:
			return "origin_e"
		if bx == -1 and bz == 0:
			return "origin_w"
	var t: String = THEMES[hash3(bx, bz, 31 + axis) % THEMES.size()]
	if t == "market" and axis == 0:
		t = "taxi"
	return t

static func avenue_name(i: int) -> String:
	if i == 0:
		return "BROADWAY"
	if i > 0:
		return "%d AVE" % i
	var k := -i - 1
	var s := "AVE " + char(65 + k % 26)
	return s if k < 26 else s + str(k / 26 + 1)

# Streets are numbered like Manhattan: street 0 is 42nd, numbers rise to the north (-Z).
static func street_name(j: int, east: bool) -> String:
	var n := 42 - j
	var pre := "E " if east else "W "
	if n >= 1:
		return pre + str(n) + " ST"
	return pre + "SOUTH " + str(1 - n)

# Subway stairwells on the avenue segment of tile (bx, bz): [{pos, dir}]. Each occupies a
# footprint 3 wide (x) by 6 long (z) centred on pos, on a sidewalk; the stairs go down along
# dir (+Z or -Z), the open end faces the other way. Zombies climb out of them.
static func subway_entrances(bx: int, bz: int) -> Array:
	if bx == 0 and bz == 0:
		return [{"pos": Vector3(7.5, 0, 20), "dir": Vector3(0, 0, 1)}]
	if bx == 0 and bz == -1:
		return [{"pos": Vector3(-7.5, 0, -20), "dir": Vector3(0, 0, -1)}]
	var h := hash3(bx, bz, 41)
	if h % 100 >= 28:
		return []
	var side := 1.0 if (h >> 8) % 2 == 0 else -1.0
	var north := (h >> 9) % 2 == 0
	var z := bz * PITCH + 20.0 if north else (bz + 1) * PITCH - 20.0
	return [{"pos": Vector3(bx * PITCH + side * 7.5, 0, z), "dir": Vector3(0, 0, 1.0 if north else -1.0)}]

# All stairwells within `radius` of p.
static func subway_near(p: Vector3, radius: float) -> Array:
	var out: Array = []
	var t0 := tile_of(p - Vector3(radius, 0, radius))
	var t1 := tile_of(p + Vector3(radius, 0, radius))
	for bz in range(t0.y, t1.y + 1):
		for bx in range(t0.x, t1.x + 1):
			for e: Dictionary in subway_entrances(bx, bz):
				var ep: Vector3 = e.pos
				if Vector2(ep.x - p.x, ep.z - p.z).length() <= radius:
					out.append(e)
	return out

# Where a zombie climbing out of stairwell `e` appears (on the road beside it).
static func subway_spawn(e: Dictionary) -> Vector3:
	var ep: Vector3 = e.pos
	return Vector3(ep.x - signf(lat(ep.x)) * 2.5, 0, ep.z)

# ---------------------------------------------------------------- blocks
static func district(bx: int, bz: int) -> String:
	var n := _vnoise(bx * 0.37 + 0.2, bz * 0.37 + 0.6, 11)
	if n < 0.38:
		return "brick"
	if n < 0.52:
		return "industrial"
	if n < 0.8:
		return "midtown"
	return "glass"

# Block types of the downtown biome: towers, walkups, warehouse (lined with buildings),
# park, plaza, parking (open: walkable), construction (one building site).
static func block_type(bx: int, bz: int) -> String:
	if ORIGIN.has(Vector2i(bx, bz)):
		return "towers"
	var k := hash3(bx, bz, 5) % 100
	if k < 7:
		return "park"
	if k < 12:
		return "plaza"
	if k < 18:
		return "parking"
	if k < 24:
		return "construction"
	var d := district(bx, bz)
	if d == "brick":
		return "walkups"
	if d == "industrial":
		return "warehouse"
	return "towers"

# Everything about block (bx, bz), cached. Keys:
#   bx, bz, type, biome, district, seed, rect: Rect2 (x/z footprint), open: bool (walkable inside),
#   lots: [{r: Rect2, h: wall top, top: highest point, st: facade style, tint: Color,
#           kind: "bldg" | "podium" | "tower" | "site", sides: street-facing sides (bit mask),
#           seed: int, ads: bool, + per kind: tiers/variant/landmark (tower), h1 (site)}],
#   trees: [Vector3(x, size, z)] (park), feature: String (park / plaza centre piece).
static func block(bx: int, bz: int) -> Dictionary:
	var key := Vector2i(bx, bz)
	var hit: Variant = _cache.get(key)
	if hit != null:
		return hit
	if _cache.size() > 2000:
		_cache.clear()
	var b := _gen_block(bx, bz)
	_cache[key] = b
	return b

# Forget cached blocks more than `keep` blocks away from (bx, bz) (world.gd calls this as the
# player moves, so memory stays flat however far they walk).
static func prune(bx: int, bz: int, keep: int) -> void:
	if _cache.size() < (2 * keep + 1) * (2 * keep + 1) + 80:
		return
	for key: Vector2i in _cache.keys():
		if absi(key.x - bx) > keep or absi(key.y - bz) > keep:
			_cache.erase(key)

static func _gen_block(bx: int, bz: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash3(bx, bz, 1)
	var b := {"bx": bx, "bz": bz, "type": block_type(bx, bz), "biome": biome_of_block(bx, bz),
		"district": district(bx, bz), "seed": hash3(bx, bz, 2), "rect": block_rect(bx, bz),
		"open": false, "lots": [], "trees": [], "feature": ""}
	var r: Rect2 = b.rect
	var c := r.get_center()
	match String(b.type):
		"park":
			b.open = true
			b.feature = "fountain" if rng.randf() < 0.5 else "statue"
			for gz in 5:
				for gx in 5:
					if gx == 2 or gz == 2:
						continue   # the paths cross here
					b.trees.append(Vector3(r.position.x + 6.5 + gx * 12.75 + rng.randf_range(-2.5, 2.5),
						rng.randf_range(0.8, 1.35), r.position.y + 6.5 + gz * 12.75 + rng.randf_range(-2.5, 2.5)))
		"plaza":
			b.open = true
			b.feature = "sculpture" if rng.randf() < 0.5 else "flags"
			b.lots.append(_tower_lot(c, rng.randi() % 2, rng.randf_range(125.0, 165.0), 1.2, rng, true))
		"parking":
			b.open = true
		"construction":
			var st: int = GLASS if rng.randf() < 0.5 else RIBBON
			var h1 := float(rng.randi_range(4, 9)) * float(FLOOR_H[st])
			var lot := _lot(r, h1 + rng.randi_range(3, 5) * 4.0, st, _pick_tint(st, rng), "site", 15, rng.randi())
			lot.h1 = h1
			lot.top = float(lot.h) + 26.0   # the crane
			b.lots.append(lot)
		_:
			_gen_buildings(b, rng, ORIGIN.get(Vector2i(bx, bz), {}))
	return b

static func _lot(r: Rect2, h: float, st: int, tint: Color, kind: String, sides: int, seed_i: int) -> Dictionary:
	return {"r": r, "h": h, "top": h, "st": st, "tint": tint, "kind": kind, "sides": sides, "seed": seed_i, "ads": false}

static func _pick_tint(st: int, rng: RandomNumberGenerator) -> Color:
	var a: Array = TINTS[st]
	return a[rng.randi() % a.size()]

static func _tower_lot(c: Vector2, variant: int, height: float, scale: float, rng: RandomNumberGenerator, landmark: bool) -> Dictionary:
	var tv: Dictionary = TOWERS[variant]
	var tiers: Array = []
	for t: Array in tv.tiers:
		tiers.append([float(t[0]) * scale, float(t[1]) * scale, float(t[2]) * height])
	var w: float = tiers[0][0]
	var d: float = tiers[0][1]
	var lot := _lot(Rect2(c.x - w / 2, c.y - d / 2, w, d), tiers[0][2], tv.st, tv.tint, "tower", 0, rng.randi())
	lot.tiers = tiers
	lot.variant = variant
	lot.landmark = landmark
	lot.name = ""                                          # rooftop sign ("" = world.gd picks one)
	lot.top = height + (47.0 if variant == 4 else 14.0)   # spire / antenna / smokestacks
	return lot

# A block lined with buildings: four corner lots, a row along each side, something in the middle.
static func _gen_buildings(b: Dictionary, rng: RandomNumberGenerator, ov: Dictionary) -> void:
	var r: Rect2 = b.rect
	var x0 := r.position.x
	var z0 := r.position.y
	var x1 := r.end.x
	var z1 := r.end.y
	var dd := LOT_DEPTH
	var dn: String = ov.get("district", b.district)
	b.district = dn
	var side_d := [dn, dn, dn, dn]
	var so: Dictionary = ov.get("side", {})
	for k: int in so:
		side_d[k] = so[k]
	var lots: Array = b.lots
	var crect := [Rect2(x0, z0, dd, dd), Rect2(x1 - dd, z0, dd, dd), Rect2(x1 - dd, z1 - dd, dd, dd), Rect2(x0, z1 - dd, dd, dd)]
	var csides := [1 | 8, 1 | 2, 4 | 2, 4 | 8]
	var cdist := [0, 0, 2, 2]
	for i in 4:
		var dc: Dictionary = DISTRICTS[side_d[cdist[i]]]
		var sts: Array = dc.styles
		var st: int = sts[rng.randi() % sts.size()]
		var h := rng.randf_range(dc.hmin, dc.hmax)
		h = ceilf(h / float(FLOOR_H[st])) * float(FLOOR_H[st]) + 1.0
		var tint := _pick_tint(st, rng)
		if int(ov.get("corner", -1)) == i:
			st = ov.cst
			h = ov.ch
			tint = _pick_tint(st, rng)
		var lot := _lot(crect[i], h, st, tint, "bldg", csides[i], rng.randi())
		lot.ads = dc.ads
		lots.append(lot)
	for side in 4:
		var dc: Dictionary = DISTRICTS[side_d[side]]
		var sts: Array = dc.styles
		var t := dd
		var t1 := BLOCK - dd
		var prev_h := 0.0
		while t < t1 - 0.1:
			var w := float(rng.randi_range(4, 7)) * 2.0
			if t1 - (t + w) < 7.0:
				w = t1 - t
			var st: int = sts[rng.randi() % sts.size()]
			var h := rng.randf_range(dc.hmin, dc.hmax)
			if absf(h - prev_h) < 5.0:
				h += 8.0
			h = ceilf(h / float(FLOOR_H[st])) * float(FLOOR_H[st]) + 1.0
			prev_h = h
			var lr: Rect2
			match side:
				0: lr = Rect2(x0 + t, z0, w, dd)
				1: lr = Rect2(x1 - dd, z0 + t, dd, w)
				2: lr = Rect2(x0 + t, z1 - dd, w, dd)
				_: lr = Rect2(x0, z0 + t, dd, w)
			var lot := _lot(lr, h, st, _pick_tint(st, rng), "bldg", 1 << side, rng.randi())
			lot.ads = dc.ads
			lots.append(lot)
			t += w
	# the middle of the block
	var ir := Rect2(x0 + dd, z0 + dd, BLOCK - 2 * dd, BLOCK - 2 * dd)
	var tv := -1
	var roll := rng.randf()
	if ov.has("tower"):
		tv = ov.tower
	elif dn == "midtown" or dn == "glass":
		if roll < 0.75:
			tv = [0, 1, 3, 1][rng.randi() % 4]
	elif dn == "brick":
		if roll < 0.2:
			tv = 2
	elif roll < 0.3:
		tv = 4
	var pst: int = RIBBON
	var ph := 21.4
	if dn == "brick":
		pst = BRICK
		ph = 3.2 * rng.randi_range(4, 6) + 1.0
	elif dn == "industrial":
		pst = WARE
		ph = 4.0 * rng.randi_range(5, 7) + 1.0
	if ov.has("tower"):
		pst = RIBBON
		ph = 21.4
	if tv == 4:
		ph = 12.0
	lots.append(_lot(ir, ph, pst, _pick_tint(pst, rng), "podium", 0, rng.randi()))
	if tv >= 0:
		var tw: Dictionary = TOWERS[tv]
		var hs: Array = tw.h
		var landmark := (not ov.has("tower")) and tv < 2 and rng.randf() < 0.14
		var height: float = hs[0]
		if not ov.has("tower"):
			height = rng.randf_range(hs[1], hs[2])
		if landmark:
			height = rng.randf_range(150.0, 178.0)
		var tl := _tower_lot(ir.get_center(), tv, height, 1.25 if landmark else 1.0, rng, landmark)
		if ov.has("tower"):
			tl.name = ["", "", "BONK", "ZED CORP", ""][tv]
		elif tv != 4:
			tl.tint = _pick_tint(tl.st, rng)
		lots.append(tl)
