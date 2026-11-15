extends Node3D
# The endless city: streams tiles of streets and buildings in around the player and frees
# the ones left behind. Static scenery only; what stands where is decided by layout.gd
# (L.block(), L.seg_theme(), L.subway_entrances()), the street props are drawn by clutter.gd,
# lights and sky live in fx.gd.
#
# A tile (see layout.gd) is built in pieces, each one merged mesh = one draw call:
#   base      always, for every tile out to the fog: ground, sidewalks, every building as
#             textured boxes with a shop-front texture at street level, towers, the elevated
#             train. Cheap (a few hundred vertices), so far tiles cost little.
#   units 0-3 "fronts": the street-level detail of one side of the block (shops, signs,
#             awnings, fire escapes, cornices, roof junk) - only near the player, and only
#             for sides that face them.
#   unit 4    the tile's intersection and avenue segment: road markings, subway stairwell,
#             traffic lights, lamps, street props (clutter.gd) + their colliders / nav obstacles.
#   unit 5    the tile's street segment, likewise.
#   unit 6    what stands inside an open block (park, plaza, parking lot).
# Work is queued nearest-first and done a step at a time (one building, one group of props)
# inside a per-frame time budget, so nothing hitches. One shader material draws everything:
# vertex colour alpha selects lit colour / glow / a layer of the facade texture array.
#
# Adding a block type (later stages): give it lots in layout.gd's _gen_block(), then draw it
# in _base_block() (far look), _front_steps() (street-level detail) and clutter.block_steps()
# (props inside open blocks). A new biome usually also wants facade layers: add images in
# _make_material() (layers 7+ are free) and a Chan for each.
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
const SHOP_NC := 8                           # shop-front cells per texture side (16 px each)
const SHOP_H := 4.95                         # height of the shop-front band
const Y := Vector3.UP
const X := Vector3.RIGHT
const Z := Vector3.BACK
const P := L.PITCH

# streaming distances (metres unless noted)
const BUDGET_USEC := 3000        # generation time per frame
const BUDGET_MAX_USEC := 8000    # ... when the frame rate is very low
const FAR_SQUARE := 2.6          # tiles kept within this many pitches (both axes) ...
const FAR_ALONG := 4.1           # ... and this far down the streets the player can look along
const FAR_ACROSS := 1.1
const FAR_KEEP := 0.45           # hysteresis (pitches) before a tile is freed
const FRONT_NEAR := 38.0         # build / free distances of the units
const FRONT_FAR := 50.0
const SEG_NEAR := 62.0
const SEG_FAR := 78.0
const COL_NEAR := 30.0           # prop colliders exist only this close to the player
const COL_FAR := 45.0
const BODY_NEAR := 100.0         # building colliders
const BODY_FAR := 125.0
const LAMP_RANGE := 100.0        # street lamps this close are handed to fx.gd (about 90 of them)

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
const CORP := ["BONK", "ZED CORP", "BRAINS INC", "NOPE BANK", "UNDEAD LIFE", "ZZZ HOTEL", "GRAVE CO"]

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

const SHADER := "
shader_type spatial;
uniform sampler2DArray tex_alb : source_color, filter_nearest_mipmap, repeat_enable;
uniform sampler2DArray tex_emi : source_color, filter_nearest_mipmap, repeat_enable;
varying float v_mode;
void vertex() {
	v_mode = COLOR.a;
	COLOR.rgb = mix(pow((COLOR.rgb + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), COLOR.rgb * (1.0 / 12.92), lessThan(COLOR.rgb, vec3(0.04045)));
}
void fragment() {
	int m = int(v_mode * 10.0 + 0.5);
	ROUGHNESS = 1.0;
	if (m >= 10) {
		ALBEDO = COLOR.rgb;
	} else if (m == 9) {
		ALBEDO = vec3(0.0);
		SPECULAR = 0.0;
		EMISSION = COLOR.rgb;
	} else {
		vec3 uvw = vec3(UV, float(m));
		ALBEDO = texture(tex_alb, uvw).rgb * COLOR.rgb;
		EMISSION = texture(tex_emi, uvw).rgb * 1.1;
	}
}
"

# A "channel": how the vertices written through it are drawn (see the shader).
class Chan:
	var mode := 1.0        # vertex alpha: 1 = lit colour, 0.9 = glow, n / 10 = texture layer n
	var shade := false     # bake a little directional shading into the colour
	func _init(m: float, s: bool) -> void:
		mode = m
		shade = s

var rng := RandomNumberGenerator.new()
var lit := Chan.new(1.0, true)       # lit, vertex coloured, with baked shading (buildings)
var flat := Chan.new(1.0, false)     # lit, vertex coloured, as given (props)
var glow := Chan.new(0.9, false)     # unshaded (signs, lit shop windows, lamps)
var fac: Array = []                  # one Chan per facade style (texture layers 0-4)
var pave := Chan.new(0.5, false)     # sidewalk paving (layer 5)
var shopc := Chan.new(0.6, false)    # far shop fronts (layer 6)
var mat: ShaderMaterial

var clutter: Node3D
var nav: RefCounted

# the mesh being built (one job at a time)
var _v := PackedVector3Array()
var _n := PackedVector3Array()
var _c := PackedColorArray()
var _uv := PackedVector2Array()
var _idx := PackedInt32Array()
var _off := Vector3.ZERO
# what the unit being built adds besides its mesh (clutter.gd writes these too)
var cur_cols: Array = []                    # [[Transform3D, size: Vector3], ...] box colliders
var cur_circ := PackedFloat32Array()        # x, z, radius triples: obstacles for nav.gd
var cur_rects: Array = []                   # Rect2: solid footprints for nav.gd

var tiles := {}                # Vector2i -> tile Dictionary
var _jobs: Array = []
var _cur: Variant = null
var _pos := Vector3(1e9, 0, 1e9)
var _tiles_at := Vector3(1e9, 0, 1e9)
var _lights_at := Vector3(1e9, 0, 1e9)
var _frame := 0
var _last_update_usec := 0
var _last_ok := Vector3.ZERO
var _ground: StaticBody3D
var _skyline: MeshInstance3D
var _shop_cells: Array = []    # per shop texture cell: [closed, glow index, sign bg index, sign fg index]
var _shapes := {}
var _lamps: Array = []
var _globes: Array = []
var lights_changed := false    # set when lamp_positions() changed: main.gd hands them to fx.gd
var globes_changed := false    # the same for globe_positions()

# statistics (see stats())
var holds := 0
var _nverts := 0
var _frame_usec_max := 0
var _gen_usec := 0
var _gen_frames := 0
var _job_stats := {}           # kind -> [count, usec, vertices]
var _step_usec_max := 0
var _step_worst := ""

# ================================================================ public
func build(clutter_node: Node3D = null, nav_ref: RefCounted = null) -> void:
	clutter = clutter_node
	nav = nav_ref
	rng.seed = L.SEED
	for i in 5:
		fac.append(Chan.new(i * 0.1, false))
	_make_material()
	_ground = B.collider(self, Vector3(700, 2, 700), Vector3(0, -1, 0))
	_make_skyline()
	if nav != null:
		nav.source = self

# Build everything the player needs at `pos` right now (game start, teleports). Blocks.
func prebuild(pos: Vector3) -> void:
	_pos = pos
	_last_ok = pos
	_refresh_tiles()
	_refresh_units()
	_run_jobs(-1)
	_refresh_units()
	_refresh_lights()
	_follow(pos)
	if nav != null:
		nav.rebuild_now(pos)

# Called every frame with the player's position: stream the city.
func update(pos: Vector3) -> void:
	_pos = pos
	_frame += 1
	if absf(pos.x - _tiles_at.x) + absf(pos.z - _tiles_at.z) > 6.0:
		_refresh_tiles()
	if _frame % 6 == 0:
		_refresh_units()
	if absf(pos.x - _lights_at.x) + absf(pos.z - _lights_at.z) > 20.0:
		_refresh_lights()
	_follow(pos)
	# a little more time per frame when frames are long anyway (a slow phone must still keep
	# up with a running player): 12 % of the frame, between BUDGET_USEC and BUDGET_MAX_USEC
	var t0 := Time.get_ticks_usec()
	var budget := clampi((t0 - _last_update_usec) * 12 / 100, BUDGET_USEC, BUDGET_MAX_USEC)
	_last_update_usec = t0
	_run_jobs(budget)
	var el := Time.get_ticks_usec() - t0
	_frame_usec_max = maxi(_frame_usec_max, el)
	if el > 50:
		_gen_usec += el
		_gen_frames += 1

# Keep the player out of places that are not built yet: returns `p`, or the last good
# position when the ground under p has no props / colliders yet (counted in `holds`).
func hold(p: Vector3) -> Vector3:
	if absf(p.x - _last_ok.x) + absf(p.z - _last_ok.z) > 30.0:
		prebuild(p)   # teleported
	var t: Variant = tiles.get(L.tile_of(p))
	if t != null and t.base != null:
		var ok := true
		for u: Variant in t.units:
			if u != null and int(u.id) >= 4 and int(u.state) != 2 and _rect_dist(u.rect, p.x, p.z) < 1.0:
				ok = false
		if ok:
			_last_ok = p
			return p
	holds += 1
	return Vector3(_last_ok.x, p.y, _last_ok.z)

# Places zombies may appear: on the streets round `center`, between min_d and max_d metres
# away, never inside a prop or a building and always connected to the player. Each entry is
# {pos: Vector3, subway: bool}; subway ones are beside a stairwell (the zombie climbs out).
func spawn_points(center: Vector3, min_d: float, max_d: float) -> Array:
	var out: Array = []
	var loose: Array = []
	var i0 := floori((center.x - max_d) / P + 0.5)
	var i1 := floori((center.x + max_d) / P + 0.5)
	var j0 := floori((center.z - max_d) / P + 0.5)
	var j1 := floori((center.z + max_d) / P + 0.5)
	var cands: Array = []
	var step := 6.0
	var n := int(max_d / step) + 1
	for i in range(i0, i1 + 1):
		if absf(i * P - center.x) > max_d:
			continue
		for k in range(-n, n + 1):
			cands.append(Vector3(i * P, 0, snappedf(center.z, step) + k * step))
	for j in range(j0, j1 + 1):
		if absf(j * P - center.z) > max_d:
			continue
		for k in range(-n, n + 1):
			cands.append(Vector3(snappedf(center.x, step) + k * step, 0, j * P))
	for p: Vector3 in cands:
		var d := Vector2(p.x - center.x, p.z - center.z).length()
		if d < min_d or d > max_d:
			continue
		loose.append({"pos": p, "subway": false})
		if nav == null or (not nav.is_blocked(p) and nav.reachable(p)):
			out.append({"pos": p, "subway": false})
	for e: Dictionary in L.subway_near(center, max_d):
		var sp := L.subway_spawn(e)
		var d := Vector2(sp.x - center.x, sp.z - center.z).length()
		if d >= min_d and (nav == null or (not nav.is_blocked(sp) and nav.reachable(sp))):
			out.append({"pos": sp, "subway": true})
	return out if not out.is_empty() else loose

# Street-lamp heads near the player (fx.gd puts halos and lights there).
func lamp_positions() -> Array:
	return _lamps

# The green globe lamps of the nearest subway stairwells.
func globe_positions() -> Array:
	return _globes

# Solid things inside `rect` for the pathfinding window: {circles: [PackedFloat32Array of
# x, z, radius triples], rects: [Rect2]}. Buildings are not included (nav reads layout.gd).
func nav_obstacles(rect: Rect2) -> Dictionary:
	var circles: Array = []
	var rects: Array = []
	for t: Dictionary in tiles.values():
		for u: Variant in t.units:
			if u == null or int(u.state) != 2 or not rect.intersects(u.rect):
				continue
			if not (u.circ as PackedFloat32Array).is_empty():
				circles.append(u.circ)
			rects.append_array(u.rects)
	return {"circles": circles, "rects": rects}

# Numbers for the streaming tests (--citystats).
func stats() -> Dictionary:
	var built := 0
	var bodies := 0
	var shapes := 0
	for t: Dictionary in tiles.values():
		if t.body != null:
			bodies += 1
			shapes += (t.body as Node).get_child_count()
		for u: Variant in t.units:
			if u != null and int(u.state) == 2:
				built += 1
				if u.body != null:
					bodies += 1
					shapes += (u.body as Node).get_child_count()
	return {"tiles": tiles.size(), "units": built, "queue": _jobs.size() + (1 if _cur != null else 0),
		"verts": _nverts, "meshes": get_child_count() - bodies - 1, "bodies": bodies, "shapes": shapes,
		"frame_usec_max": _frame_usec_max, "gen_usec_avg": _gen_usec / maxi(_gen_frames, 1), "holds": holds,
		"jobs": _job_stats, "lamps": _lamps.size(), "step_usec_max": _step_usec_max, "step_worst": _step_worst}

func reset_stats() -> void:
	_frame_usec_max = 0
	_step_usec_max = 0
	_gen_usec = 0
	_gen_frames = 0

# A fingerprint of everything built for tile `key` (determinism tests).
func tile_hash(key: Vector2i) -> int:
	var t: Variant = tiles.get(key)
	if t == null:
		return 0
	var h := 0
	var nodes: Array = [t.base]
	for u: Variant in t.units:
		if u != null:
			nodes.append(u.mesh)
			h = (h * 31 + (u.cols as Array).size() * 7 + (u.circ as PackedFloat32Array).size()) & 0xffffffff
	for m: Variant in nodes:
		if m == null:
			h = (h * 31 + 1) & 0xffffffff
			continue
		var arr: Array = (m as MeshInstance3D).mesh.surface_get_arrays(0)
		var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var acc := Vector3.ZERO
		for i in range(0, vs.size(), 7):
			acc += vs[i] * float(i % 13 + 1)
		h = (h * 31 + vs.size() * 1009 + int(acc.x * 10.0) + int(acc.y * 10.0) * 3 + int(acc.z * 10.0) * 7) & 0xffffffff
	return h

# ================================================================ streaming
static func _rect_dist(r: Rect2, x: float, z: float) -> float:
	var dx := maxf(maxf(r.position.x - x, x - r.end.x), 0.0)
	var dz := maxf(maxf(r.position.y - z, z - r.end.y), 0.0)
	return sqrt(dx * dx + dz * dz)

func _want(bx: int, bz: int, slack: float) -> bool:
	var ddx := absf((bx + 0.5) * P - _pos.x) / P
	var ddz := absf((bz + 0.5) * P - _pos.z) / P
	return (ddx <= FAR_SQUARE + slack and ddz <= FAR_SQUARE + slack) \
		or (ddx <= FAR_ACROSS + slack and ddz <= FAR_ALONG + slack) \
		or (ddz <= FAR_ACROSS + slack and ddx <= FAR_ALONG + slack)

func _refresh_tiles() -> void:
	_tiles_at = _pos
	var cbx := floori(_pos.x / P)
	var cbz := floori(_pos.z / P)
	L.prune(cbx, cbz, 7)
	for key: Vector2i in tiles.keys():
		if not _want(key.x, key.y, FAR_KEEP):
			_free_tile(tiles[key])
	for bz in range(cbz - 5, cbz + 6):
		for bx in range(cbx - 5, cbx + 6):
			if _want(bx, bz, 0.0) and not tiles.has(Vector2i(bx, bz)):
				_new_tile(Vector2i(bx, bz))

func _new_tile(key: Vector2i) -> void:
	var b: Dictionary = L.block(key.x, key.y)
	var org := Vector3(key.x * P, 0, key.y * P)
	var t := {"key": key, "bx": key.x, "bz": key.y, "org": org, "b": b, "base": null, "nv": 0,
		"rect": Rect2(org.x - 9, org.z - 9, P, P), "units": [], "body": null, "dead": false, "lamps": []}
	var r: Rect2 = b.rect
	var mask := 0
	for lot: Dictionary in b.lots:
		mask |= int(lot.sides)
	var fr := [Rect2(r.position.x, r.position.y - 0.5, r.size.x, 0.5), Rect2(r.end.x, r.position.y, 0.5, r.size.y),
		Rect2(r.position.x, r.end.y, r.size.x, 0.5), Rect2(r.position.x - 0.5, r.position.y, 0.5, r.size.y)]
	for s in 4:
		t.units.append(_new_unit(t, s, fr[s]) if mask & (1 << s) else null)
	t.units.append(_new_unit(t, 4, Rect2(org.x - 9, org.z - 9, 18, P)))
	t.units.append(_new_unit(t, 5, Rect2(org.x + 9, org.z - 9, L.BLOCK, 18)))
	t.units.append(_new_unit(t, 6, r) if b.open else null)
	if clutter != null:
		t.lamps = clutter.lamp_points(t)
	tiles[key] = t
	_jobs.append({"t": t, "u": null, "rect": t.rect, "dead": false})

func _new_unit(t: Dictionary, id: int, rect: Rect2) -> Dictionary:
	return {"id": id, "t": t, "rect": rect, "state": 0, "mesh": null, "nv": 0, "body": null, "job": null,
		"cols": [], "circ": PackedFloat32Array(), "rects": []}

func _free_tile(t: Dictionary) -> void:
	t.dead = true
	for u: Variant in t.units:
		if u != null:
			_free_unit(u)
			u.t = null   # break the tile <-> unit reference cycle so both are released
	t.units = []
	if t.base != null:
		(t.base as Node).queue_free()
		_nverts -= int(t.nv)
	if t.body != null:
		(t.body as Node).queue_free()
	tiles.erase(t.key)

func _free_unit(u: Dictionary) -> void:
	if u.job != null:
		u.job.dead = true
		u.job = null
	if u.mesh != null:
		(u.mesh as Node).queue_free()
		u.mesh = null
		_nverts -= int(u.nv)
	if u.body != null:
		(u.body as Node).queue_free()
		u.body = null
	if int(u.state) == 2 and nav != null and (not (u.circ as PackedFloat32Array).is_empty() or not (u.rects as Array).is_empty()):
		if (nav.window() as Rect2).intersects(u.rect):
			nav.mark_dirty()
	u.cols = []
	u.circ = PackedFloat32Array()
	u.rects = []
	u.state = 0

# Decide which units and colliders should exist, from the player's distance to each.
func _refresh_units() -> void:
	var px := _pos.x
	var pz := _pos.z
	for t: Dictionary in tiles.values():
		var td := _rect_dist(t.rect, px, pz)
		if t.body == null:
			if td < BODY_NEAR and t.base != null:
				t.body = _block_body(t)
		elif td > BODY_FAR:
			(t.body as Node).queue_free()
			t.body = null
		if td > SEG_FAR + 4.0:
			for u: Variant in t.units:
				if u != null and int(u.state) != 0:
					_free_unit(u)
			continue
		for u: Variant in t.units:
			if u == null:
				continue
			var id: int = u.id
			var r: Rect2 = u.rect
			var d := _rect_dist(r, px, pz)
			var near := SEG_NEAR
			var far := SEG_FAR
			if id < 4:
				near = FRONT_NEAR
				far = FRONT_FAR
				# a front the player is behind cannot be seen
				var out: Vector3 = L.SIDE_OUT[id]
				var c := r.get_center()
				if (px - c.x) * out.x + (pz - c.y) * out.z < -1.0:
					d = 1e9
			var st: int = u.state
			if st == 0:
				if d < near:
					u.state = 1
					u.job = {"t": t, "u": u, "rect": r, "dead": false}
					_jobs.append(u.job)
			elif d > far:
				_free_unit(u)
			elif st == 2:
				if u.body == null:
					if d < COL_NEAR and not (u.cols as Array).is_empty():
						u.body = _make_body(u.cols)
				elif d > COL_FAR:
					(u.body as Node).queue_free()
					u.body = null

func _refresh_lights() -> void:
	_lights_at = _pos
	var lamps: Array = []
	for t: Dictionary in tiles.values():
		if _rect_dist(t.rect, _pos.x, _pos.z) < LAMP_RANGE:
			for lp: Vector3 in t.lamps:
				if absf(lp.x - _pos.x) + absf(lp.z - _pos.z) < LAMP_RANGE * 1.3:
					lamps.append(lp)
	var globes: Array = []
	var ents: Array = L.subway_near(_pos, 70.0)
	ents.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return (a.pos as Vector3).distance_squared_to(_pos) < (b.pos as Vector3).distance_squared_to(_pos))
	for e: Dictionary in ents.slice(0, 2):
		for sd: float in [-1.0, 1.0]:
			globes.append((e.pos as Vector3) + (e.dir as Vector3) * -2.85 + X * (sd * 1.25) + Y * 3.3)
	if lamps != _lamps:
		_lamps = lamps
		lights_changed = true
	if globes != _globes:
		_globes = globes
		globes_changed = true

# The ground collider and the distant skyline follow the player.
func _follow(pos: Vector3) -> void:
	if absf(pos.x - _ground.position.x) + absf(pos.z - _ground.position.z) > 150.0:
		_ground.position = Vector3(pos.x, -1, pos.z)
	_skyline.position = Vector3(pos.x, 0, pos.z)

func _shape(size: Vector3) -> BoxShape3D:
	var key := size.snapped(Vector3(0.01, 0.01, 0.01))
	var s: Variant = _shapes.get(key)
	if s == null:
		s = BoxShape3D.new()
		s.size = size
		_shapes[key] = s
	return s

func _make_body(cols: Array) -> StaticBody3D:
	var sb := StaticBody3D.new()
	for c: Array in cols:
		var cs := CollisionShape3D.new()
		cs.shape = _shape(c[1])
		cs.transform = c[0]
		sb.add_child(cs)
	add_child(sb)
	return sb

func _block_body(t: Dictionary) -> StaticBody3D:
	var b: Dictionary = t.b
	var cols: Array = []
	if not b.open:
		var c: Vector2 = (b.rect as Rect2).get_center()
		cols.append([Transform3D(Basis.IDENTITY, Vector3(c.x, 60, c.y)), Vector3(L.BLOCK, 120, L.BLOCK)])
	else:
		for lot: Dictionary in b.lots:
			var r: Rect2 = lot.r
			var c := r.get_center()
			cols.append([Transform3D(Basis.IDENTITY, Vector3(c.x, 60, c.y)), Vector3(r.size.x, 120, r.size.y)])
	return _make_body(cols)

# ---------------------------------------------------------------- job queue
func _run_jobs(budget: int) -> void:
	var t0 := Time.get_ticks_usec()
	while true:
		if _cur == null:
			_cur = _next_job()
			if _cur == null:
				return
			_begin(_cur)
		var job: Dictionary = _cur
		if job.dead or job.t.dead:
			_cur = null
			continue
		var s0 := Time.get_ticks_usec()
		var steps: Array = job.steps
		(steps[job.i] as Callable).call()
		job.i += 1
		var su := Time.get_ticks_usec() - s0
		job.usec += su
		if su > _step_usec_max and budget >= 0:
			_step_usec_max = su
			_step_worst = ("base" if job.u == null else "unit%d" % int(job.u.id)) + "/" + str((steps[int(job.i) - 1] as Callable).get_method()) + "#" + str(int(job.i) - 1)
		if int(job.i) >= steps.size():
			s0 = Time.get_ticks_usec()
			_finish(job)
			job.usec += Time.get_ticks_usec() - s0
			var kind := "base" if job.u == null else ("front" if int(job.u.id) < 4 else "street")
			var js: Array = _job_stats.get(kind, [0, 0, 0])
			js[0] += 1
			js[1] += int(job.usec)
			js[2] += _v.size()
			_job_stats[kind] = js
			_cur = null
		if budget >= 0 and Time.get_ticks_usec() - t0 > budget:
			return

func _next_job() -> Variant:
	var best := -1
	var best_d := 1e18
	var i := 0
	while i < _jobs.size():
		var j: Dictionary = _jobs[i]
		if j.dead or j.t.dead:
			_jobs[i] = _jobs[_jobs.size() - 1]
			_jobs.pop_back()
			continue
		var d := _rect_dist(j.rect, _pos.x, _pos.z)
		if d < best_d:
			best_d = d
			best = i
		i += 1
	if best < 0:
		return null
	var job: Dictionary = _jobs[best]
	_jobs[best] = _jobs[_jobs.size() - 1]
	_jobs.pop_back()
	return job

func _begin(job: Dictionary) -> void:
	var t: Dictionary = job.t
	_v = PackedVector3Array()
	_n = PackedVector3Array()
	_c = PackedColorArray()
	_uv = PackedVector2Array()
	_idx = PackedInt32Array()
	_off = t.org
	cur_cols = []
	cur_circ = PackedFloat32Array()
	cur_rects = []
	job.i = 0
	job.usec = 0
	var steps: Array = []
	if job.u == null:
		steps.append(_base_ground.bind(t))
		var n: int = (t.b.lots as Array).size()
		var k := 0
		while k < n:
			steps.append(_base_lots.bind(t, k, mini(k + 6, n)))
			k += 6
		steps.append(_base_block.bind(t))
	else:
		var id: int = job.u.id
		if id < 4:
			steps = _front_steps(t, id)
		elif id == 4:
			steps = [_marks_inter.bind(t), _marks_avenue.bind(t)]
			for e: Dictionary in L.subway_entrances(t.bx, t.bz):
				steps.append(_subway_a.bind(e.pos, e.dir))
				steps.append(_subway_b.bind(e.pos, e.dir))
			if L.is_el(t.bx):
				steps.append(_el_columns.bind(t))
			if clutter != null:
				steps.append_array(clutter.inter_steps(t))
				steps.append_array(clutter.seg_steps(t, 0))
		elif id == 5:
			steps = [_marks_street.bind(t)]
			if clutter != null:
				steps.append_array(clutter.seg_steps(t, 1))
		elif clutter != null:
			steps = clutter.block_steps(t)
	if steps.is_empty():
		steps.append(func() -> void: pass)
	job.steps = steps

func _finish(job: Dictionary) -> void:
	var t: Dictionary = job.t
	var mi: MeshInstance3D = _flush() if not _v.is_empty() else null
	if job.u == null:
		t.base = mi
		t.nv = _v.size()
	else:
		var u: Dictionary = job.u
		u.mesh = mi
		u.nv = _v.size()
		u.cols = cur_cols
		u.circ = cur_circ
		u.rects = cur_rects
		u.state = 2
		u.job = null
		if nav != null and (not cur_circ.is_empty() or not cur_rects.is_empty()) and (nav.window() as Rect2).intersects(u.rect):
			nav.mark_dirty()
	_nverts += _v.size()

# ================================================================ mesh batching
func _make_material() -> void:
	var albs: Array[Image] = []
	var emis: Array[Image] = []
	for st in 5:
		var pr := _facade_images(st)
		albs.append(pr[0])
		emis.append(pr[1])
	var pv := _paving_images()
	albs.append(pv[0])
	emis.append(pv[1])
	var sh := _shop_images()
	albs.append(sh[0])
	emis.append(sh[1])
	var ta := Texture2DArray.new()
	ta.create_from_images(albs)
	var te := Texture2DArray.new()
	te.create_from_images(emis)
	var s := Shader.new()
	s.code = SHADER
	mat = ShaderMaterial.new()
	mat.shader = s
	mat.set_shader_parameter("tex_alb", ta)
	mat.set_shader_parameter("tex_emi", te)

func _flush() -> MeshInstance3D:
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = _v
	arr[Mesh.ARRAY_NORMAL] = _n
	arr[Mesh.ARRAY_COLOR] = _c
	arr[Mesh.ARRAY_TEX_UV] = _uv
	arr[Mesh.ARRAY_INDEX] = _idx
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	am.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.mesh = am
	mi.position = _off
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi

func _vert(b: Chan, p: Vector3, nrm: Vector3, col: Color, uv: Vector2) -> void:
	_v.append(p - _off)
	_n.append(nrm)
	_uv.append(uv)
	if b.shade:
		var k := 0.82 + 0.18 * nrm.y + 0.07 * nrm.x + 0.03 * nrm.z
		_c.append(Color(col.r * k, col.g * k, col.b * k, b.mode))
	else:
		_c.append(Color(col.r, col.g, col.b, b.mode))

# Quad p0..p3 (in loop order) facing `nrm`; winding is fixed up automatically.
func _quad(b: Chan, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, nrm: Vector3, col: Color,
		u0 := Vector2.ZERO, u1 := Vector2.ZERO, u2 := Vector2.ZERO, u3 := Vector2.ZERO) -> void:
	var s := _v.size()
	_vert(b, p0, nrm, col, u0)
	_vert(b, p1, nrm, col, u1)
	_vert(b, p2, nrm, col, u2)
	_vert(b, p3, nrm, col, u3)
	if (p1 - p0).cross(p2 - p0).dot(nrm) > 0.0:
		_idx.append_array([s, s + 2, s + 1, s, s + 3, s + 2])
	else:
		_idx.append_array([s, s + 1, s + 2, s, s + 2, s + 3])

func _tri(b: Chan, p0: Vector3, p1: Vector3, p2: Vector3, nrm: Vector3, col: Color) -> void:
	var s := _v.size()
	_vert(b, p0, nrm, col, Vector2.ZERO)
	_vert(b, p1, nrm, col, Vector2.ZERO)
	_vert(b, p2, nrm, col, Vector2.ZERO)
	if (p1 - p0).cross(p2 - p0).dot(nrm) > 0.0:
		_idx.append_array([s, s + 2, s + 1])
	else:
		_idx.append_array([s, s + 1, s + 2])

func _box(b: Chan, size: Vector3, pos: Vector3, col: Color, bas := Basis.IDENTITY) -> void:
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
func _mm(b: Chan, x0: float, x1: float, y0: float, y1: float, z0: float, z1: float, col: Color) -> void:
	_box(b, Vector3(absf(x1 - x0), absf(y1 - y0), absf(z1 - z0)), Vector3((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2), col)

# Box in a wall-relative frame: origin o, `dir` along the wall, `out` away from it (both axis-aligned).
func _ob(b: Chan, o: Vector3, dir: Vector3, out: Vector3, u0: float, u1: float, y0: float, y1: float,
		d0: float, d1: float, col: Color) -> void:
	var size := dir.abs() * absf(u1 - u0) + out.abs() * absf(d1 - d0) + Y * absf(y1 - y0)
	_box(b, size, o + dir * ((u0 + u1) / 2) + out * ((d0 + d1) / 2) + Y * ((y0 + y1) / 2), col)

# Flat panel on a wall (one quad), `d` out from it.
func _pan(b: Chan, o: Vector3, dir: Vector3, out: Vector3, u0: float, u1: float, y0: float, y1: float, d: float, col: Color) -> void:
	var p := o + out * d
	_quad(b, p + dir * u0 + Y * y0, p + dir * u1 + Y * y0, p + dir * u1 + Y * y1, p + dir * u0 + Y * y1, out, col)

# Box in a transformed frame (for tilted things).
func _tb(b: Chan, xf: Transform3D, size: Vector3, lp: Vector3, col: Color) -> void:
	_box(b, size, xf * lp, col, xf.basis)

# Square beam from p to q.
func _beam(b: Chan, p: Vector3, q: Vector3, t: float, col: Color, t2 := -1.0) -> void:
	var d := q - p
	var bx := d.normalized()
	var ref := Y if abs(bx.y) < 0.99 else X
	var bz := bx.cross(ref).normalized()
	var by := bz.cross(bx)
	_box(b, Vector3(d.length(), t, t2 if t2 > 0 else t), (p + q) / 2, col, Basis(bx, by, bz))

# 8-sided prism (water tanks, chimneys, manholes).
func _cyl(b: Chan, c: Vector3, r: float, h: float, col: Color, r_top := -1.0) -> void:
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
func _text(b: Chan, s: String, c: Vector3, nrm: Vector3, px: float, col: Color, up := Vector3.UP) -> void:
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

func _vtext(b: Chan, s: String, c: Vector3, nrm: Vector3, px: float, col: Color) -> void:
	var h := s.length() * 6 * px
	for i in s.length():
		_text(b, s[i], c + Y * (h / 2 - (i * 6 + 3) * px), nrm, px, col)

# ---------------------------------------------------------------- textures
# One layer of window cells per facade style: [albedo, emission].
func _facade_images(st: int) -> Array:
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
	return [alb, emi]

# Sidewalk paving: one slab per cell (a cell is 1 m along the kerb, 0.9 m across).
func _paving_images() -> Array:
	var S := NC * CP
	var alb := Image.create(S, S, false, Image.FORMAT_RGB8)
	var emi := Image.create(S, S, false, Image.FORMAT_RGB8)
	emi.fill(Color.BLACK)
	for cy in NC:
		for cx in NC:
			var c := Color(0.5, 0.5, 0.49).darkened(rng.randf_range(0.0, 0.16))
			if rng.randf() < 0.04:
				c = c.darkened(0.25)
			for py in CP:
				for px in CP:
					var k := 0.86 if (px == 0 or py == 0) else 1.0 + rng.randf_range(-0.03, 0.03)
					alb.set_pixel(cx * CP + px, cy * CP + py, Color(c.r * k, c.g * k, c.b * k))
	alb.generate_mipmaps()
	emi.generate_mipmaps()
	return [alb, emi]

# Shop fronts as seen from afar: SHOP_NC x SHOP_NC cells, one shop each. The albedo is
# multiplied by the building's base colour; windows and signs glow. The real shop geometry
# (built close up by _shops) reads the same per-cell choices from _shop_cells.
func _shop_images() -> Array:
	var S := NC * CP
	var W := S / SHOP_NC
	var alb := Image.create(S, S, false, Image.FORMAT_RGB8)
	var emi := Image.create(S, S, false, Image.FORMAT_RGB8)
	emi.fill(Color.BLACK)
	for cy in SHOP_NC:
		for cx in SHOP_NC:
			var closed := rng.randf() < 0.22
			var gi := rng.randi() % SHOP_GLOW.size()
			var bi := rng.randi() % SIGN_BG.size()
			var fi := rng.randi() % SIGN_FG.size()
			_shop_cells.append([closed, gi, bi, fi])
			var gc: Color = SHOP_GLOW[gi]
			var bg: Color = SIGN_BG[bi]
			var fg: Color = SIGN_FG[fi]
			for py in W:
				for px in W:
					var col := Color(0.8, 0.8, 0.8)
					var em := Color.BLACK
					if py < 2:
						col = Color(0.97, 0.97, 0.97)   # the lighter lintel
					elif py >= 3 and py <= 5 and px >= 1 and px <= 14:
						em = bg
						if py == 4 and px >= 3 and px <= 12 and (px + cx) % 3 != 0:
							em = fg
						col = em
					elif py >= 6 and py <= 12 and px >= 2 and px <= 14:
						if closed:
							em = Color(0.45, 0.47, 0.5) * (0.3 if py % 2 == 0 else 0.2)   # shutter
						elif px == 11:
							col = Color(0.5, 0.5, 0.5)
						else:
							em = gc * (0.55 if py == 9 else 1.0)
							if px >= 12:
								em = gc * 0.8
							col = em
					elif py >= 13 and px >= 12 and px <= 14 and not closed:
						em = gc * 0.8
						col = em
					alb.set_pixel(cx * W + px, cy * W + py, col)
					emi.set_pixel(cx * W + px, cy * W + py, em)
	alb.generate_mipmaps()
	emi.generate_mipmaps()
	return [alb, emi]

# ================================================================ base (far) look
func _mark(x0: float, x1: float, z0: float, z1: float, col: Color, y := 0.02) -> void:
	_quad(flat, Vector3(x0, y, z0), Vector3(x1, y, z0), Vector3(x1, y, z1), Vector3(x0, y, z1), Y, col)

func _base_ground(t: Dictionary) -> void:
	var o: Vector3 = t.org
	var asphalt := Color(0.17, 0.17, 0.19)
	_mark(o.x - 9, o.x + 73, o.z - 6, o.z + 6, asphalt, 0.0)
	_mark(o.x - 6, o.x + 6, o.z - 9, o.z - 6, asphalt, 0.0)
	_mark(o.x - 6, o.x + 6, o.z + 6, o.z + 73, asphalt, 0.0)
	var ents: Array = L.subway_entrances(t.bx, t.bz)
	for sx: float in [-1.0, 1.0]:
		var hole := Vector2(-1, -1)
		for e: Dictionary in ents:
			var ep: Vector3 = e.pos
			if signf(ep.x - o.x) == sx:
				hole = Vector2(ep.z - o.z - 9.0, ep.z - o.z - 3.0)
		_walk(Vector3(o.x + sx * 6, 0, o.z - 9), Z, X * sx, 3.0, Vector2(-1, -1), 2)
		_walk(Vector3(o.x + sx * 6, 0, o.z + 6), Z, X * sx, 67.0, hole, 1)
	for sz: float in [-1.0, 1.0]:
		_walk(Vector3(o.x + 9, 0, o.z + sz * 6), X, Z * sz, 64.0, Vector2(-1, -1), 0)
	if L.is_el(t.bx):
		_el_base(t)

# One sidewalk strip: `side` points from the kerb toward the buildings.
# hole = (from, to) along the strip left open; caps: 1 = kerb face at the start, 2 = at the end.
func _walk(o: Vector3, dir: Vector3, side: Vector3, length: float, hole: Vector2, caps: int) -> void:
	var h := L.KERB_H
	var kerb := Color(0.62, 0.62, 0.6)
	var segs := [[0.0, length]]
	if hole.x >= 0:
		segs = [[0.0, hole.x], [hole.y, length]]
	for sg: Array in segs:
		var a: float = sg[0]
		var bb: float = sg[1]
		_ob(lit, o, dir, side, a, bb, -0.1, h, 0.0, 0.3, kerb)
		var p0 := o + dir * a + side * 0.3 + Y * h
		var p1 := o + dir * bb + side * 0.3 + Y * h
		var ua := p0.dot(dir) / NC
		var ub := p1.dot(dir) / NC
		_quad(pave, p0, p1, p1 + side * 2.7, p0 + side * 2.7, Y, Color.WHITE,
			Vector2(ua, 0), Vector2(ub, 0), Vector2(ub, 3.0 / NC), Vector2(ua, 3.0 / NC))
	if caps & 1:
		_quad(lit, o, o + side * 3, o + side * 3 + Y * h, o + Y * h, -dir, kerb)
	if caps & 2:
		var e := o + dir * length
		_quad(lit, e, e + side * 3, e + side * 3 + Y * h, e + Y * h, dir, kerb)

func _base_lots(t: Dictionary, from: int, to: int) -> void:
	var b: Dictionary = t.b
	var lots: Array = b.lots
	for i in range(from, to):
		var lot: Dictionary = lots[i]
		rng.seed = lot.seed
		match String(lot.kind):
			"tower":
				_tower_base(lot)
			"site":
				_site_base(lot)
			_:
				var r: Rect2 = lot.r
				var sides: int = lot.sides
				_facade(lot.st, r.position.x, r.end.x, r.position.y, r.end.y, SHOP_H if sides != 0 else 0.0, lot.h, lot.tint)
				_mark(r.position.x, r.end.x, r.position.y, r.end.y, Color(0.16, 0.16, 0.17), float(lot.h))
				for s in 4:
					if sides & (1 << s):
						_band(lot, s)

# What a block shows besides its lots (open ground, trees).
func _base_block(t: Dictionary) -> void:
	var b: Dictionary = t.b
	var r: Rect2 = b.rect
	var h := L.KERB_H
	match String(b.type):
		"park":
			var grass := Color(0.15, 0.29, 0.13)
			var path := Color(0.55, 0.5, 0.42)
			var c := r.get_center()
			for sx: float in [-1.0, 1.0]:
				for sz: float in [-1.0, 1.0]:
					_mark(c.x + sx * 2.0, c.x + sx * 32.0, c.y + sz * 2.0, c.y + sz * 32.0, grass.darkened(0.06 * (sx + sz)), h)
				_mark(c.x + sx * 2.0, c.x + sx * 32.0, c.y - 2.0, c.y + 2.0, path, h)
			_mark(c.x - 2.0, c.x + 2.0, r.position.y, r.end.y, path, h)
			for tr: Vector3 in b.trees:
				_tree(Vector3(tr.x, h, tr.z), tr.y)
		"plaza":
			var p0 := Vector3(r.position.x, h, r.position.y)
			var s := L.BLOCK / 2.0 / NC
			_quad(pave, p0, p0 + X * L.BLOCK, p0 + X * L.BLOCK + Z * L.BLOCK, p0 + Z * L.BLOCK, Y, Color(1.0, 0.95, 0.86),
				Vector2(0, 0), Vector2(s, 0), Vector2(s, s), Vector2(0, s))
		"parking":
			_mark(r.position.x, r.end.x, r.position.y, r.end.y, Color(0.12, 0.12, 0.14), h)

func _tree(p: Vector3, s: float) -> void:
	rng.seed = int(p.x * 13.0) + int(p.z * 7.0)
	var leaf := Color(0.14, 0.34, 0.14).lightened(rng.randf() * 0.12)
	_box(lit, Vector3(0.5, 2.6 * s, 0.5), p + Y * (1.3 * s), Color(0.3, 0.2, 0.13))
	_box(lit, Vector3(3.4, 2.2, 3.4) * s, p + Y * (3.4 * s), leaf, Basis(Y, rng.randf() * 1.5))
	_box(lit, Vector3(2.3, 1.7, 2.3) * s, p + Y * (5.1 * s), leaf.lightened(0.08), Basis(Y, rng.randf() * 1.5))

# Four textured walls of a box. Windows are aligned to the top edge.
func _facade(st: int, x0: float, x1: float, z0: float, z1: float, y0: float, y1: float, tint: Color) -> void:
	var b: Chan = fac[st]
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

# Frame of one side of a lot: [start on the building line, along, out toward the street, width].
func _side_frame(r: Rect2, side: int) -> Array:
	match side:
		0: return [Vector3(r.position.x, 0, r.position.y), X, -Z, r.size.x]
		1: return [Vector3(r.end.x, 0, r.position.y), Z, X, r.size.y]
		2: return [Vector3(r.position.x, 0, r.end.y), X, Z, r.size.x]
	return [Vector3(r.position.x, 0, r.position.y), Z, -X, r.size.y]

func _shop_count(w: float) -> int:
	return maxi(1, roundi(w / 6.0))

# Which shop-texture cells a lot side starts at: (first column, row).
func _shop_cell0(lot: Dictionary, side: int) -> Vector2i:
	var h := L.hash3(int(lot.seed) & 0xffffff, side, 7)
	return Vector2i(h % SHOP_NC, (h >> 5) % SHOP_NC)

func _shop_base(st: int, tint: Color) -> Color:
	if st == GLASS:
		return Color(0.2, 0.21, 0.24)
	if st == DECO or st == RIBBON:
		return tint.darkened(0.55)
	return tint.darkened(0.4)

# The far look of a row of shops: one textured quad.
func _band(lot: Dictionary, side: int) -> void:
	var f := _side_frame(lot.r, side)
	var a: Vector3 = f[0]
	var dir: Vector3 = f[1]
	var w: float = f[3]
	var c0 := _shop_cell0(lot, side)
	var u0 := float(c0.x) / SHOP_NC
	var u1 := float(c0.x + _shop_count(w)) / SHOP_NC
	var v0 := float(c0.y) / SHOP_NC
	var v1 := float(c0.y + 1) / SHOP_NC
	_quad(shopc, a, a + dir * w, a + dir * w + Y * SHOP_H, a + Y * SHOP_H, f[2], _shop_base(lot.st, lot.tint) * 1.25,
		Vector2(u0, v1), Vector2(u1, v1), Vector2(u1, v0), Vector2(u0, v0))

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

func _water_tower(p: Vector3) -> void:
	var iron := Color(0.14, 0.13, 0.13)
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			_box(lit, Vector3(0.22, 2.4, 0.22), p + Vector3(sx * 1.0, 1.2, sz * 1.0), iron)
	_box(lit, Vector3(2.6, 0.2, 2.6), p + Y * 2.4, iron)
	_cyl(lit, p + Y * 2.5, 1.7, 3.0, Color(0.42, 0.28, 0.17))
	_cyl(lit, p + Y * 5.5, 1.9, 1.3, Color(0.3, 0.3, 0.32), 0.1)

# A skyscraper with its crown, by variant (see L.TOWERS). Drawn whole in the base mesh:
# towers are the landmarks you steer by.
func _tower_base(lot: Dictionary) -> void:
	var r: Rect2 = lot.r
	var c := r.get_center()
	var tiers: Array = lot.tiers
	var st: int = lot.st
	var top: float = tiers[tiers.size() - 1][2]
	var tw: float = tiers[tiers.size() - 1][0]
	var td: float = tiers[tiers.size() - 1][1]
	var red := Color(1, 0.15, 0.1)
	_tower(c.x, c.y, tiers, st, lot.tint)
	match int(lot.variant):
		0:
			_box(lit, Vector3(2.2, 6, 2.2), Vector3(c.x, top + 3, c.y), Color(0.7, 0.72, 0.75))
			_box(lit, Vector3(0.7, 16, 0.7), Vector3(c.x, top + 14, c.y), Color(0.75, 0.77, 0.8))
			for i in range(maxi(tiers.size() - 3, 0), tiers.size()):
				var w: float = tiers[i][0]
				_box(glow, Vector3(w + 0.2, 0.5, w + 0.2), Vector3(c.x, float(tiers[i][2]) + 0.6, c.y), Color(1.0, 0.85, 0.5))
		1:
			var w0: float = tiers[0][0]
			var d0: float = tiers[0][1]
			_box(glow, Vector3(w0 + 0.3, 0.8, d0 + 0.3), Vector3(c.x, float(tiers[0][2]) - 1.5, c.y), Color(0.35, 0.9, 1.0))
			_box(lit, Vector3(0.5, 22, 0.5), Vector3(c.x, top + 11, c.y), Color(0.6, 0.6, 0.62))
			_box(glow, Vector3(0.9, 0.9, 0.9), Vector3(c.x, top + 22, c.y), red)
		2:
			_water_tower(Vector3(c.x - 4.5, top + 0.6, c.y - 4.5))
			_water_tower(Vector3(c.x + 4.5, top + 0.6, c.y + 3.5))
			var nm: String = lot.name if lot.name != "" else CORP[rng.randi() % CORP.size()]
			_billboard(Vector3(c.x, top + 5.5, c.y - td / 2 - 0.3), -Z, 16, 6, Color(0.75, 0.08, 0.1), [nm], false)
			_billboard(Vector3(c.x - tw / 2 - 0.3, top + 5.5, c.y), -X, 16, 6, Color(0.75, 0.08, 0.1), [nm], false)
		3:
			_box(lit, Vector3(10, 4, 8), Vector3(c.x, top + 2.8, c.y), Color(0.4, 0.42, 0.45))
			var nm: String = lot.name if lot.name != "" else CORP[rng.randi() % CORP.size()]
			_billboard(Vector3(c.x, top + 3.0, c.y - td / 2 - 0.2), -Z, 20, 4.5, Color(0.05, 0.1, 0.3), [nm], false)
			_billboard(Vector3(c.x + tw / 2 + 0.2, top + 3.0, c.y), X, 14, 4.5, Color(0.05, 0.1, 0.3), [nm], false)
		_:
			for i in 3:   # power plant: striped smokestacks
				var p := Vector3(c.x - 9.0 + i * 9.0, top, c.y)
				_cyl(lit, p, 2.6, 34, Color(0.55, 0.36, 0.3), 1.8)
				_cyl(lit, p + Y * 34, 1.9, 3, Color(0.85, 0.85, 0.85), 1.85)
				_cyl(lit, p + Y * 37, 1.85, 3, Color(0.8, 0.12, 0.1), 1.8)
				_box(glow, Vector3(0.9, 0.9, 0.9), p + Y * 43.5, red)
	if lot.landmark:
		_box(glow, Vector3(tw + 0.6, 1.4, td + 0.6), Vector3(c.x, top - 3.0, c.y), Color(1.0, 0.45, 0.75))
		_box(lit, Vector3(1.0, 26, 1.0), Vector3(c.x, top + 13, c.y), Color(0.7, 0.7, 0.72))
		_box(glow, Vector3(1.6, 1.6, 1.6), Vector3(c.x, top + 26.5, c.y), red)

# A building site: finished floors below, a steel skeleton above, a tower crane.
func _site_base(lot: Dictionary) -> void:
	var r: Rect2 = lot.r
	var h1: float = lot.h1
	var h: float = lot.h
	var c := r.get_center()
	var steel := Color(0.42, 0.2, 0.14)
	var board := Color(0.12, 0.3, 0.36)
	_facade(lot.st, r.position.x, r.end.x, r.position.y, r.end.y, SHOP_H, h1, lot.tint)
	for s in 4:   # hoarding at street level
		var f := _side_frame(r, s)
		_pan(lit, f[0], f[1], f[2], 0, f[3], 0, SHOP_H, 0.0, board.darkened(0.1 * (s % 2)))
	var y := h1
	while y <= h + 0.01:
		_mm(lit, r.position.x + 0.3, r.end.x - 0.3, y, y + 0.4, r.position.y + 0.3, r.end.y - 0.3, Color(0.5, 0.5, 0.5))
		y += 4.0
	for k in 5:
		var u := 0.6 + k * (L.BLOCK - 1.2) / 4.0
		for e: float in [0.6, L.BLOCK - 0.6]:
			_mm(lit, r.position.x + u - 0.3, r.position.x + u + 0.3, h1, h, r.position.y + e - 0.3, r.position.y + e + 0.3, steel)
			if k > 0 and k < 4:
				_mm(lit, r.position.x + e - 0.3, r.position.x + e + 0.3, h1, h, r.position.y + u - 0.3, r.position.y + u + 0.3, steel)
	# crane
	var yel := Color(0.9, 0.7, 0.08)
	var m := Vector3(c.x + 8.0, 0, c.y - 6.0)
	var jy := h + 22.0
	var a := rng.randf() * TAU
	var bas := Basis(Y, a)
	_box(lit, Vector3(1.6, jy - h1, 1.6), m + Y * ((jy + h1) / 2), yel)
	_box(lit, Vector3(52, 1.3, 1.3), m + Y * jy + bas * Vector3(12, 0, 0), yel, bas)
	_box(lit, Vector3(4, 3, 2.4), m + Y * (jy - 1.2) + bas * Vector3(-12, 0, 0), Color(0.4, 0.4, 0.42), bas)
	_box(lit, Vector3(2.6, 2.4, 2.6), m + Y * (jy - 2.0), Color(0.85, 0.85, 0.8))
	_box(lit, Vector3(0.4, 4, 0.4), m + Y * (jy + 2.0), yel)
	_box(glow, Vector3(0.8, 0.8, 0.8), m + Y * (jy + 4.3), Color(1, 0.15, 0.1))
	_box(lit, Vector3(0.16, 18, 0.16), m + Y * (jy - 9.0) + bas * Vector3(26, 0, 0), Color(0.12, 0.12, 0.12))

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

# The elevated train over avenue t.bx, for this tile's stretch.
func _el_base(t: Dictionary) -> void:
	var o: Vector3 = t.org
	var steel := Color(0.14, 0.24, 0.2)
	var z0 := o.z - 9.0
	var z1 := o.z + 73.0
	for k in 5:
		var z := o.z + 13.0 + k * 14.0
		for sx: float in [-1.0, 1.0]:
			_box(lit, Vector3(0.8, 6.6, 0.8), Vector3(o.x + sx * 3.4, 3.3, z), steel)
		_box(lit, Vector3(7.8, 0.9, 0.9), Vector3(o.x, 6.5, z), steel)
	for sx: float in [-1.0, 1.0]:
		_mm(lit, o.x + sx * 3.4 - 0.3, o.x + sx * 3.4 + 0.3, 6.6, 8.0, z0, z1, steel)
		_mm(lit, o.x + sx * 3.9 - 0.08, o.x + sx * 3.9 + 0.08, 8.0, 9.1, z0, z1, steel.darkened(0.2))
	_mm(lit, o.x - 3.7, o.x + 3.7, 7.6, 8.0, z0, z1, Color(0.2, 0.19, 0.18))
	var hsh := L.hash3(t.bx, t.bz, 51)
	if hsh % 100 < 35:   # a train stopped on the viaduct
		for i in 3:
			var cz := o.z + 22.5 + i * 18.3
			_mm(lit, o.x - 1.45, o.x + 1.45, 8.35, 11.6, cz - 8.8, cz + 8.8, Color(0.6, 0.63, 0.66))
			_mm(glow, o.x - 1.48, o.x + 1.48, 10.1, 11.0, cz - 8.2, cz + 8.2, Color(0.95, 0.9, 0.7))
			_mm(lit, o.x - 1.47, o.x + 1.47, 9.15, 9.45, cz - 8.82, cz + 8.82, Color(0.1, 0.2, 0.55))
	if (hsh >> 8) % 100 < 22:   # a station over the intersection
		for sx: float in [-1.0, 1.0]:
			_mm(lit, o.x + sx * 4.0, o.x + sx * 6.4, 8.0, 8.3, o.z - 16, o.z + 16, Color(0.3, 0.3, 0.3))
			_mm(lit, o.x + sx * 5.9, o.x + sx * 6.3, 8.3, 11.2, o.z - 16, o.z + 16, steel)
			_mm(glow, o.x + sx * 5.8, o.x + sx * 5.9, 9.2, 10.6, o.z - 15, o.z + 15, Color(0.95, 0.85, 0.55))
			_mm(lit, o.x + sx * 3.6, o.x + sx * 6.8, 11.2, 11.5, o.z - 17, o.z + 17, steel.darkened(0.3))
		var nm := L.street_name(t.bz, true).substr(2)
		_billboard(Vector3(o.x, 12.6, o.z - 9.2), -Z, 9.0, 1.6, Color(0.03, 0.05, 0.08), [nm], false)
		_billboard(Vector3(o.x, 12.6, o.z + 9.2), Z, 9.0, 1.6, Color(0.03, 0.05, 0.08), [nm], false)

func _el_columns(t: Dictionary) -> void:
	var o: Vector3 = t.org
	for k in 5:
		var z := o.z + 13.0 + k * 14.0
		for sx: float in [-1.0, 1.0]:
			var x := o.x + sx * 3.4
			cur_cols.append([Transform3D(Basis.IDENTITY, Vector3(x, 3.3, z)), Vector3(0.8, 6.6, 0.8)])
			cur_rects.append(Rect2(x - 0.4, z - 0.4, 0.8, 0.8))
			_beam(lit, Vector3(x, 4.6, z + 0.5), Vector3(x, 6.4, z + 2.4), 0.3, Color(0.14, 0.24, 0.2))
			_beam(lit, Vector3(x, 4.6, z - 0.5), Vector3(x, 6.4, z - 2.4), 0.3, Color(0.14, 0.24, 0.2))

# Distant towers that follow the player, so every gap in the roofline has city behind it.
# They sit just inside the far clip, deep in the fog, and leave the four street axes open.
func _make_skyline() -> void:
	_off = Vector3.ZERO
	rng.seed = L.hash3(7, 7, 7)
	var sts := [GLASS, DECO, RIBBON, GLASS]
	for i in 30:
		var ang := TAU * (i + rng.randf() * 0.5) / 30.0
		var r := rng.randf_range(238.0, 262.0)
		var p := Vector3(cos(ang) * r, 0, sin(ang) * r)
		var w := rng.randf_range(18.0, 30.0)
		var h := rng.randf_range(60.0, 135.0)
		if absf(p.x) < 26.0 or absf(p.z) < 26.0:
			continue
		var st: int = sts[i % 4]
		var tints: Array = L.TINTS[st]
		_tower(p.x, p.z, [[w, w, h * 0.7], [w * 0.7, w * 0.7, h]], st, tints[rng.randi() % tints.size()])
	_skyline = _flush()

# ================================================================ fronts (street-level detail)
func _front_steps(t: Dictionary, side: int) -> Array:
	var steps: Array = []
	for lot: Dictionary in t.b.lots:
		if int(lot.sides) & (1 << side):
			for part in 3:
				steps.append(_front_lot.bind(lot, side, part))
	return steps

# part 0 = roof, 1 = shops, 2 = fire escape or billboard
func _front_lot(lot: Dictionary, side: int, part: int) -> void:
	rng.seed = L.hash3(int(lot.seed) & 0xffffff, side, 3 + part)
	var r: Rect2 = lot.r
	var f := _side_frame(r, side)
	var a: Vector3 = f[0]
	var dir: Vector3 = f[1]
	var out: Vector3 = f[2]
	var w: float = f[3]
	var st: int = lot.st
	var h: float = lot.h
	var sides: int = lot.sides
	if String(lot.kind) == "site":
		if part == 1:
			_site_front(a, dir, out, w)
		return
	if part == 0:
		# the first street-facing side of a lot also brings its roof
		var first := 0
		while not (sides & (1 << first)):
			first += 1
		if first == side:
			_bldg_top(lot)
		return
	if part == 1:
		_shops(a, dir, out, w, _shop_base(st, lot.tint), lot, side)
		return
	if (st == BRICK or st == WARE) and h < 45.0:
		if rng.randf() < 0.7:
			_fire_escape(a, dir, out, rng.randf_range(2.5, w - 2.5), h, FLOOR[st])
	elif w >= 10.0 and h > 22.0 and (lot.ads or rng.randf() < 0.18):
		var bh := minf(7.0, h - 14.0)
		_billboard(a + dir * (w / 2) + out * 0.35 + Y * rng.randf_range(9.0, maxf(9.5, minf(18.0, h - bh - 3.0))),
			out, w - 3.0, bh, AD_COLS[rng.randi() % AD_COLS.size()], ADS[rng.randi() % ADS.size()])

# Cornice / cap and rooftop junk of a plain building.
func _bldg_top(lot: Dictionary) -> void:
	var r: Rect2 = lot.r
	var st: int = lot.st
	var h: float = lot.h
	var tint: Color = lot.tint
	var c := r.get_center()
	var w := r.size.x
	var d := r.size.y
	if st == GLASS:
		_box(lit, Vector3(w + 0.1, 0.7, d + 0.1), Vector3(c.x, h + 0.3, c.y), Color(0.14, 0.16, 0.2))
	else:
		var cc := tint.lightened(0.12) if st == DECO else tint.darkened(0.3)
		_box(lit, Vector3(w + 0.7, 1.0, d + 0.7), Vector3(c.x, h + 0.1, c.y), cc)
		_box(lit, Vector3(w - 0.6, 0.3, d - 0.6), Vector3(c.x, h + 0.56, c.y), Color(0.16, 0.16, 0.17))
	if h > 46.0:
		return   # nobody at street level sees this roof
	var top := h + 0.6
	var jx := c.x + rng.randf_range(-0.25, 0.25) * w
	var jz := c.y + rng.randf_range(-0.25, 0.25) * d
	_box(lit, Vector3(3.2, 2.8, 3.2), Vector3(jx, top + 1.4, jz), tint.darkened(0.4) if st != GLASS else Color(0.3, 0.32, 0.35))
	if st != GLASS and rng.randf() < 0.65:
		_water_tower(Vector3(c.x - sign(jx - c.x + 0.01) * w * 0.25, top, c.y - sign(jz - c.y + 0.01) * d * 0.25))
	else:
		_box(lit, Vector3(2.4, 1.2, 1.6), Vector3(c.x - sign(jx - c.x + 0.01) * w * 0.25, top + 0.6, c.y), Color(0.5, 0.52, 0.54))

func _site_front(a: Vector3, dir: Vector3, out: Vector3, w: float) -> void:
	var u := 6.0
	var i := 0
	while u < w - 6.0:
		if i % 2 == 0:
			_pan(lit, a, dir, out, u - 2.6, u + 2.6, 1.3, 2.5, 0.03, Color(0.85, 0.85, 0.8))
			_text(lit, "POST NO BRAINS" if i % 4 == 0 else "ZOMBIES AT WORK", a + dir * u + out * 0.05 + Y * 1.9, out, 0.085, Color(0.1, 0.1, 0.1))
		else:
			var ad: Array = ADS[rng.randi() % ADS.size()]
			_pan(glow, a, dir, out, u - 1.6, u + 1.6, 0.8, 3.4, 0.03, AD_COLS[rng.randi() % AD_COLS.size()].darkened(0.3))
			_text(glow, ad[0], a + dir * u + out * 0.05 + Y * 2.1, out, 0.14, Color(1, 1, 1))
		u += 9.0
		i += 1
	_ob(lit, a, dir, out, 0, w, SHOP_H, SHOP_H + 0.3, 0, 0.25, Color(0.3, 0.3, 0.32))

func _shops(a: Vector3, dir: Vector3, out: Vector3, w: float, base: Color, lot: Dictionary, side: int) -> void:
	_ob(lit, a, dir, out, 0, w, 0, 4.5, 0, 0.15, base)
	_ob(lit, a, dir, out, 0, w, 4.5, SHOP_H, 0, 0.4, base.lightened(0.18))
	var n := _shop_count(w)
	var sw := w / n
	var c0 := _shop_cell0(lot, side)
	var dark := Color(0.1, 0.1, 0.11)
	for i in n:
		var u := i * sw
		var cell: Array = _shop_cells[c0.y * SHOP_NC + (c0.x + i) % SHOP_NC]
		_ob(lit, a, dir, out, maxf(u - 0.3, 0.0), u + 0.3, 0, 4.5, 0.15, 0.32, base.lightened(0.1))
		var gc: Color = SHOP_GLOW[cell[1]]
		if cell[0]:
			# closed: roll-down shutter
			_pan(lit, a, dir, out, u + 0.6, u + sw - 0.6, 0.15, 3.0, 0.22, Color(0.45, 0.47, 0.5))
			for k in 7:
				_pan(lit, a, dir, out, u + 0.6, u + sw - 0.6, 0.45 + k * 0.38, 0.52 + k * 0.38, 0.25, Color(0.3, 0.31, 0.34))
		else:
			var dl := u + sw - 1.9      # door on the far end
			_pan(glow, a, dir, out, u + 0.6, dl - 0.2, 0.9, 3.0, 0.2, gc)
			_pan(glow, a, dir, out, u + 0.6, dl - 0.2, 1.75, 1.95, 0.22, gc * 0.55)
			_pan(glow, a, dir, out, u + 0.6, dl - 0.2, 0.9, 1.15, 0.22, gc * 0.4)
			var panes := maxf(1.0, round((dl - 0.8 - u) / 1.5))
			for j in int(panes) + 1:
				var mu := u + 0.6 + j * (dl - 0.8 - u) / panes
				_pan(lit, a, dir, out, mu - 0.06, mu + 0.06, 0.9, 3.0, 0.26, dark)
			_pan(lit, a, dir, out, dl, dl + 1.3, 0.15, 3.0, 0.22, dark)
			_pan(glow, a, dir, out, dl + 0.2, dl + 1.1, 0.5, 2.7, 0.24, gc * 0.8)
		# sign
		var nm: String = SHOP_NAMES[rng.randi() % SHOP_NAMES.size()]
		var bg: Color = SIGN_BG[cell[2]]
		_ob(glow, a, dir, out, u + 0.5, u + sw - 0.5, 3.3, 4.3, 0.15, 0.34, bg)
		var px := minf(0.15, (sw - 1.6) / (nm.length() * 4.0))
		_text(glow, nm, a + dir * (u + sw / 2) + out * 0.36 + Y * 3.8, out, px, SIGN_FG[cell[3]])
		var roll := rng.randf()
		if roll < 0.45:
			_awning(a, dir, out, u + 0.5, u + sw - 0.5, AD_COLS[rng.randi() % AD_COLS.size()].darkened(0.2))
		elif roll < 0.6:
			_blade(a + dir * (u + 0.2), dir, out, nm.split(" ")[0], bg)
	_ob(lit, a, dir, out, w - 0.3, w, 0, 4.5, 0.15, 0.32, base.lightened(0.1))

func _awning(a: Vector3, dir: Vector3, out: Vector3, u0: float, u1: float, col: Color) -> void:
	var n := maxi(2, roundi((u1 - u0) / 1.0))
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
		for e: float in [-1.9, 1.82]:
			_ob(lit, a, dir, out, u + e, u + e + 0.08, y + 0.95, y + 1.05, 0.0, 1.15, iron)
		for j in 3:
			var pu := u - 1.9 + j * 1.86
			_ob(lit, a, dir, out, pu, pu + 0.08, y, y + 1.0, 1.07, 1.15, iron)
		# stair down to the platform below
		if h - (k + 1) * fh > 6.0:
			var p := a + dir * (u + flip * 1.3) + out * 0.6 + Y * (y + 0.1)
			_beam(lit, p, p - dir * (flip * 2.6) - Y * fh, 0.1, iron, 0.55)
		else:
			_ob(lit, a, dir, out, u - 0.3 * flip - 0.25, u - 0.3 * flip + 0.25, y - 2.4, y, 1.0, 1.08, iron)
		flip = -flip
		k += 1

# ================================================================ streets (near detail)
func _patches(o: Vector3, dir: Vector3, perp: Vector3, length: float, n: int) -> void:
	var asphalt := Color(0.17, 0.17, 0.19)
	for i in n:
		var along := rng.randf_range(0.0, length - 7.0)
		var across := rng.randf_range(-5.5, 4.0)
		var w := minf(rng.randf_range(1.0, 4.0), 5.9 - across)
		var l := rng.randf_range(1.5, 7.0)
		var c := asphalt.lightened(rng.randf_range(0.015, 0.04)) if i % 3 else asphalt.darkened(0.18)
		var p := o + dir * along + perp * across + Y * 0.01
		_quad(flat, p, p + dir * l, p + dir * l + perp * w, p + perp * w, Y, c)
	for i in 2:
		if rng.randf() < 0.6:
			var p := o + dir * rng.randf_range(4.0, length - 4.0) + perp * rng.randf_range(-3.5, 3.5)
			_cyl(lit, p, 0.55, 0.02, Color(0.3, 0.27, 0.24))
			_cyl(lit, p + Y * 0.005, 0.4, 0.02, Color(0.12, 0.11, 0.11))

func _marks_inter(t: Dictionary) -> void:
	var o: Vector3 = t.org
	rng.seed = L.hash3(t.bx, t.bz, 61)
	var white := Color(0.8, 0.8, 0.76)
	for s: float in [-1.0, 1.0]:
		for k in 10:
			var c0 := -5.7 + k * 1.2
			_mark(o.x + c0, o.x + c0 + 0.65, o.z + s * 6.4, o.z + s * 8.9, white)
			_mark(o.x + s * 6.4, o.x + s * 8.9, o.z + c0, o.z + c0 + 0.65, white)
		_mark(o.x - 5.8, o.x + 5.8, o.z + s * 10.0, o.z + s * 10.5, white)
		_mark(o.x + s * 10.0, o.x + s * 10.5, o.z - 5.8, o.z + 5.8, white)
	_patches(o + Vector3(0, 0, -6), Z, X, 12.0, 3)

func _marks_avenue(t: Dictionary) -> void:
	var o: Vector3 = t.org
	rng.seed = L.hash3(t.bx, t.bz, 62)
	var white := Color(0.8, 0.8, 0.76)
	var z := 12.0
	while z < 69.0:
		for x: float in [-3.0, 0.0, 3.0]:
			_mark(o.x + x - 0.1, o.x + x + 0.1, o.z + z, o.z + z + 2.2, white)
		z += 5.0
	_patches(o + Vector3(0, 0, 9), Z, X, 64.0, 10)
	# subway ventilation grates in the sidewalk
	for i in 2:
		if rng.randf() < 0.5:
			var g := o + Vector3((1.0 if i == 0 else -1.0) * 7.6, 0, rng.randf_range(26.0, 60.0))
			_mm(lit, g.x - 0.7, g.x + 0.7, 0.15, 0.17, g.z - 2.0, g.z + 2.0, Color(0.07, 0.07, 0.08))
			for k in 5:
				_mm(lit, g.x - 0.7, g.x + 0.7, 0.17, 0.185, g.z - 2.0 + k * 1.0 - 0.06, g.z - 2.0 + k * 1.0 + 0.06, Color(0.3, 0.3, 0.31))

func _marks_street(t: Dictionary) -> void:
	var o: Vector3 = t.org
	rng.seed = L.hash3(t.bx, t.bz, 63)
	var white := Color(0.8, 0.8, 0.76)
	var yellow := Color(0.85, 0.65, 0.1)
	_mark(o.x + 11.5, o.x + 70.5, o.z - 0.3, o.z - 0.12, yellow)
	_mark(o.x + 11.5, o.x + 70.5, o.z + 0.12, o.z + 0.3, yellow)
	var x := 12.0
	while x < 69.0:
		for zz: float in [-3.2, 3.2]:
			_mark(o.x + x, o.x + x + 2.2, o.z + zz - 0.1, o.z + zz + 0.1, white)
		x += 5.0
	_patches(o + Vector3(9, 0, 0), X, Z, 64.0, 10)

# Subway entrance at c (see L.subway_entrances): the stairs go down along d.
func _subway_a(c: Vector3, d: Vector3) -> void:
	var h := L.KERB_H
	var stone := Color(0.6, 0.6, 0.58)
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
	cur_cols.append([Transform3D(Basis.IDENTITY, c + Y * 2.0), Vector3(3, 4, 6)])
	cur_rects.append(Rect2(c.x - 1.5, c.z - 3.0, 3.0, 6.0))

func _subway_b(c: Vector3, d: Vector3) -> void:
	var h := L.KERB_H
	var stone := Color(0.6, 0.6, 0.58)
	var green := Color(0.08, 0.3, 0.16)
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
