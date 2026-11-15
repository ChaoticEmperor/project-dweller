extends RefCounted
# Zombie pathfinding: a flow field on a 1 m grid, in a window that follows the player.
# One breadth-first flood from the player's position gives every walkable cell its
# distance to the player; each zombie then just walks "downhill". This is cheap for any
# number of zombies and can never jam on props the way direct steering does.
#
# The window is N x N cells (128 m a side). Its blocked cells come from layout.gd (streets
# and open blocks are free, buildings are not) plus the props world.gd has streamed in.
# All heavy work (re-centring the window, re-reading the props, the flood) is done in a
# back buffer, a slice per frame, and swapped in when complete - so readers always see a
# whole, consistent field (it may be a few frames behind the player, which nobody notices).
const L = preload("res://layout.gd")

const N := 128            # cells per side
const HALF := 64
const AGENT_R := 0.45     # zombie body radius used to fatten obstacles
const LOS_RANGE := 14.0   # within this distance a zombie with a clear line walks straight
const RECENTRE := 10      # move the window when the player is this many cells off its centre
const CORRIDOR_FREE := 8.4  # cells whose centre is within this of a street centre line are street
const BUDGET_USEC := 1200 # work per frame

var blocked := PackedByteArray()
var dist := PackedInt32Array()     # steps to the player, -1 = unreachable
var ox := -HALF                    # world x / z of the window's first cell
var oz := -HALF
var source: Object = null          # world.gd: nav_obstacles(Rect2) -> {circles, rects}
var rebuilds := 0                  # statistics
var floods := 0
var worst_usec := 0

var _b2 := PackedByteArray()       # back buffers
var _d2 := PackedInt32Array()
var _queue := PackedInt32Array()
var _nox := 0
var _noz := 0
var _stage := 0                    # 0 idle, 1 rows, 2 open blocks + props, 3 flood, 4 swap
var _full := false                 # the running job rebuilds blocked cells too
var _head := 0
var _tail := 0
var _last_cell := Vector2i(1 << 30, 0)
var _dirty := true
var _todo: Array = []
var _target := Vector3.ZERO

func _init() -> void:
	blocked.resize(N * N)
	blocked.fill(1)
	dist.resize(N * N)
	dist.fill(-1)
	_b2.resize(N * N)
	_d2.resize(N * N)
	_queue.resize(N * N)

# Props changed inside the window: re-read them (spread over the next frames).
func mark_dirty() -> void:
	_dirty = true

func window() -> Rect2:
	return Rect2(ox, oz, N, N)

func in_window(p: Vector3) -> bool:
	return p.x >= ox and p.z >= oz and p.x < ox + N and p.z < oz + N

func cell(p: Vector3) -> int:
	var cx := clampi(int(floor(p.x)) - ox, 0, N - 1)
	var cz := clampi(int(floor(p.z)) - oz, 0, N - 1)
	return cz * N + cx

func is_blocked(p: Vector3) -> bool:
	if not in_window(p):
		return not L.walkable(p, 0.6)
	return blocked[cell(p)] == 1

# True when a walker at p can reach the player (p inside the window and connected).
func reachable(p: Vector3) -> bool:
	return in_window(p) and dist[cell(p)] >= 0

# Walking distance in metres from p to the player, -1 if unknown.
func steps(p: Vector3) -> int:
	return dist[cell(p)] if in_window(p) else -1

# Called every frame with the player's position. Does at most BUDGET_USEC of work.
func update(target: Vector3) -> void:
	_target = target
	if _stage == 0:
		var cx := int(floor(target.x))
		var cz := int(floor(target.z))
		if _dirty or absi(cx - (ox + HALF)) > RECENTRE or absi(cz - (oz + HALF)) > RECENTRE:
			_start(true)
		elif Vector2i(cx, cz) != _last_cell:
			_start(false)
		else:
			return
	_run(BUDGET_USEC)

# Build the whole field now (start of the game, teleports).
func rebuild_now(target: Vector3) -> void:
	_target = target
	_stage = 0
	_start(true)
	_run(-1)

func _start(full: bool) -> void:
	_full = full
	_last_cell = Vector2i(int(floor(_target.x)), int(floor(_target.z)))
	if full:
		_dirty = false
		_nox = _last_cell.x - HALF
		_noz = _last_cell.y - HALF
		_stage = 1
		rebuilds += 1
	else:
		_nox = ox
		_noz = oz
		_stage = 3
		_seed_flood(blocked)
	floods += 1

func _run(budget: int) -> void:
	var t0 := Time.get_ticks_usec()
	while _stage != 0:
		match _stage:
			1:
				_rows()
				_stage = 2
			2:
				if _todo.is_empty():
					_seal()
					_seed_flood(_b2)
					_stage = 3
				else:
					var item: Variant = _todo.pop_back()
					if item is Dictionary:
						_open_block(item)
					else:
						_prop(item)
			3:
				if _flood(_b2 if _full else blocked, t0, budget):
					_stage = 4
			4:
				if _full:
					var tb := blocked
					blocked = _b2
					_b2 = tb
					ox = _nox
					oz = _noz
				var td := dist
				dist = _d2
				_d2 = td
				_stage = 0
		if budget >= 0 and Time.get_ticks_usec() - t0 > budget:
			break
	worst_usec = maxi(worst_usec, Time.get_ticks_usec() - t0)

# Streets free, everything else blocked: built a whole row at a time.
func _rows() -> void:
	var tmpl := PackedByteArray()
	tmpl.resize(N)
	var free_row := PackedByteArray()
	free_row.resize(N)   # zero filled
	for cx in N:
		tmpl[cx] = 0 if absf(L.lat(_nox + cx + 0.5)) <= CORRIDOR_FREE else 1
	_b2.clear()
	for cz in N:
		_b2.append_array(free_row if absf(L.lat(_noz + cz + 0.5)) <= CORRIDOR_FREE else tmpl)
	# then, one per step: the props streamed in by world.gd, after the open blocks
	# (parks, plazas, parking lots); _todo is worked through from the back
	_todo.clear()
	if source != null:
		var data: Dictionary = source.nav_obstacles(Rect2(_nox, _noz, N, N))
		_todo.append_array(data.rects)
		_todo.append_array(data.circles)
	var p := L.PITCH
	for bz in range(floori(_noz / p), floori((_noz + N) / p) + 1):
		for bx in range(floori(_nox / p), floori((_nox + N) / p) + 1):
			var b: Dictionary = L.block(bx, bz)
			if b.open:
				_todo.append(b)

func _open_block(b: Dictionary) -> void:
	var r: Rect2 = b.rect
	_fill(r.position.x - 1.0, r.end.x + 1.0, r.position.y - 1.0, r.end.y + 1.0, 0)
	for lot: Dictionary in b.lots:
		var lr: Rect2 = (lot.r as Rect2).grow(AGENT_R)
		_fill(lr.position.x, lr.end.x, lr.position.y, lr.end.y, 1)

# Block the outermost ring of cells of the new window.
func _seal() -> void:
	for k in N:
		_b2[k] = 1
		_b2[(N - 1) * N + k] = 1
		_b2[k * N] = 1
		_b2[k * N + N - 1] = 1

func _fill(x0: float, x1: float, z0: float, z1: float, v: int) -> void:
	# cells whose centre lies in [x0, x1] x [z0, z1]
	var cx0 := maxi(int(ceil(x0 - 0.5)) - _nox, 0)
	var cx1 := mini(int(floor(x1 - 0.5)) - _nox, N - 1)
	var cz0 := maxi(int(ceil(z0 - 0.5)) - _noz, 0)
	var cz1 := mini(int(floor(z1 - 0.5)) - _noz, N - 1)
	for cz in range(cz0, cz1 + 1):
		var row := cz * N
		for cx in range(cx0, cx1 + 1):
			_b2[row + cx] = v

# One step of the solid things streamed in by world.gd (a unit's rects or circles).
func _prop(item: Variant) -> void:
	if item is Rect2:
		var g := (item as Rect2).grow(AGENT_R)
		_fill(g.position.x, g.end.x, g.position.y, g.end.y, 1)
		return
	var circ: PackedFloat32Array = item
	var i := 0
	var n := circ.size()
	while i < n:
		var px := circ[i]
		var pz := circ[i + 1]
		var r := circ[i + 2] + AGENT_R
		i += 3
		var r2 := r * r
		for cz in range(maxi(int(floor(pz - r)) - _noz, 0), mini(int(ceil(pz + r)) - _noz, N - 1) + 1):
			var dz := _noz + cz + 0.5 - pz
			for cx in range(maxi(int(floor(px - r)) - _nox, 0), mini(int(ceil(px + r)) - _nox, N - 1) + 1):
				var dx := _nox + cx + 0.5 - px
				if dx * dx + dz * dz < r2:
					_b2[cz * N + cx] = 1

# Seed the flood with the target cell, or the free cells around it if the player is
# standing somewhere zombies cannot (on a car roof, tight against a prop).
func _seed_flood(bl: PackedByteArray) -> void:
	_d2.fill(-1)
	_head = 0
	_tail = 0
	var tx := clampi(_last_cell.x - _nox, 0, N - 1)
	var tz := clampi(_last_cell.y - _noz, 0, N - 1)
	for rad in 5:
		for dz in range(-rad, rad + 1):
			for dx in range(-rad, rad + 1):
				var x := tx + dx
				var z := tz + dz
				if x < 0 or z < 0 or x >= N or z >= N:
					continue
				var i := z * N + x
				if bl[i] == 0 and _d2[i] < 0:
					_d2[i] = 0
					_queue[_tail] = i
					_tail += 1
		if _tail > 0:
			break

# Returns true when the flood is complete. The window's outermost ring of cells is always
# blocked (see _seal), so the loop needs no bounds checks.
func _flood(bl: PackedByteArray, t0: int, budget: int) -> bool:
	var head := _head
	var tail := _tail
	# work on local references (faster than member access); the members are emptied
	# meanwhile so the arrays are not copied on the first write
	var d2 := _d2
	var q := _queue
	_d2 = PackedInt32Array()
	_queue = PackedInt32Array()
	var n := 0
	while head < tail:
		var i := q[head]
		head += 1
		var d := d2[i] + 1
		var j := i - 1
		if bl[j] == 0 and d2[j] < 0:
			d2[j] = d
			q[tail] = j
			tail += 1
		j = i + 1
		if bl[j] == 0 and d2[j] < 0:
			d2[j] = d
			q[tail] = j
			tail += 1
		j = i - N
		if bl[j] == 0 and d2[j] < 0:
			d2[j] = d
			q[tail] = j
			tail += 1
		j = i + N
		if bl[j] == 0 and d2[j] < 0:
			d2[j] = d
			q[tail] = j
			tail += 1
		n += 1
		if (n & 255) == 0 and budget >= 0 and Time.get_ticks_usec() - t0 > budget:
			break
	_d2 = d2
	_queue = q
	_head = head
	_tail = tail
	return head >= tail

func _clear_line(from: Vector3, to: Vector3) -> bool:
	var d := to - from
	d.y = 0
	var len := d.length()
	if len > LOS_RANGE:
		return false
	var steps_n := int(len / 0.5) + 1
	for s in range(1, steps_n):
		if is_blocked(from + d * (float(s) / steps_n)):
			return false
	return true

# Unit direction a walker at `p` should move in to reach `target`.
func direction(p: Vector3, target: Vector3) -> Vector3:
	var straight := target - p
	straight.y = 0
	if straight.length() < 0.01:
		return Vector3.ZERO
	if not in_window(p):
		return straight.normalized()
	if _clear_line(p, target):
		return straight.normalized()
	var c := cell(p)
	var cx := c % N
	var cz := c / N
	if blocked[c] == 1 or dist[c] < 0:
		# shoved into a prop: head for the nearest cell that knows the way
		var best := -1
		var best_d := 1 << 30
		for dz in range(-2, 3):
			for dx in range(-2, 3):
				var x := cx + dx
				var z := cz + dz
				if x < 0 or z < 0 or x >= N or z >= N:
					continue
				var i := z * N + x
				if blocked[i] == 0 and dist[i] >= 0:
					var score: int = dist[i] + (absi(dx) + absi(dz)) * 3
					if score < best_d:
						best_d = score
						best = i
		if best < 0:
			return straight.normalized()
		var to_cell := _centre(best) - p
		to_cell.y = 0
		return to_cell.normalized()
	# walk downhill: look a few cells ahead along the steepest descent and aim at the
	# furthest one that is in a clear straight line, so paths are smooth, not blocky
	var c1 := _lower(c)
	if c1 < 0:
		return straight.normalized()
	var aim := c1
	var c3 := _lower(_lower(c1))
	if c3 >= 0 and _clear_line(p, _centre(c3)):
		aim = c3
	var to_aim := _centre(aim) - p
	to_aim.y = 0
	if to_aim.length() < 0.01:
		return straight.normalized()
	return to_aim.normalized()

func _centre(i: int) -> Vector3:
	return Vector3(i % N + ox + 0.5, 0, i / N + oz + 0.5)

# The neighbouring cell that is strictly closer to the player (-1 if none / invalid).
# Diagonals are allowed only when both cells beside them are free (no corner cutting).
func _lower(c: int) -> int:
	if c < 0:
		return -1
	var cx := c % N
	var cz := c / N
	var best := -1
	var best_d: float = dist[c]
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dz == 0:
				continue
			var x := cx + dx
			var z := cz + dz
			if x < 0 or z < 0 or x >= N or z >= N:
				continue
			var i := z * N + x
			if blocked[i] == 1 or dist[i] < 0:
				continue
			var cost: float = dist[i]
			if dx != 0 and dz != 0:
				if blocked[cz * N + x] == 1 or blocked[z * N + cx] == 1:
					continue
				cost += 0.4  # a diagonal is worth less than two straight steps, more than one
			if cost < best_d - 0.01:
				best_d = cost
				best = i
	return best
