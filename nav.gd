extends RefCounted
# Zombie pathfinding: a flow field on a 1 m grid.
# One breadth-first flood from the player's position gives every walkable cell its
# distance to the player; each zombie then just walks "downhill". This is cheap for any
# number of zombies and can never jam on props the way direct steering does.
const L = preload("res://layout.gd")

const HALF := 48          # grid covers x,z in [-48, 48)
const N := 96             # cells per side
const AGENT_R := 0.45     # zombie body radius used to fatten obstacles
const LOS_RANGE := 14.0   # within this distance a zombie with a clear line walks straight

var blocked := PackedByteArray()
var dist := PackedInt32Array()     # steps to the player, -1 = unreachable
var _queue := PackedInt32Array()
var _last_cell := -1

# obstacles: [{pos: Vector3, radius: float}], rects: [Rect2] in x/z that are solid.
func build(obstacles: Array, rects: Array) -> void:
	blocked.resize(N * N)
	dist.resize(N * N)
	_queue.resize(N * N)
	var h: float = L.CORRIDOR_HALF - 0.6
	var a: float = L.ARM_LEN - 0.6
	for cz in N:
		for cx in N:
			var x := cx - HALF + 0.5
			var z := cz - HALF + 0.5
			var ok: bool = (abs(x) <= h or abs(z) <= h) and abs(x) <= a and abs(z) <= a
			blocked[cz * N + cx] = 0 if ok else 1
	for ob in obstacles:
		var r: float = ob.radius + AGENT_R
		var p: Vector3 = ob.pos
		for cz in range(int(floor(p.z - r)) + HALF, int(ceil(p.z + r)) + HALF + 1):
			for cx in range(int(floor(p.x - r)) + HALF, int(ceil(p.x + r)) + HALF + 1):
				if cx < 0 or cz < 0 or cx >= N or cz >= N:
					continue
				var dx := cx - HALF + 0.5 - p.x
				var dz := cz - HALF + 0.5 - p.z
				if dx * dx + dz * dz < r * r:
					blocked[cz * N + cx] = 1
	for rc in rects:
		var g: Rect2 = rc.grow(AGENT_R)
		for cz in N:
			for cx in N:
				if g.has_point(Vector2(cx - HALF + 0.5, cz - HALF + 0.5)):
					blocked[cz * N + cx] = 1
	_last_cell = -1

func cell(p: Vector3) -> int:
	var cx := clampi(int(floor(p.x)) + HALF, 0, N - 1)
	var cz := clampi(int(floor(p.z)) + HALF, 0, N - 1)
	return cz * N + cx

func is_blocked(p: Vector3) -> bool:
	if abs(p.x) >= HALF or abs(p.z) >= HALF:
		return true
	return blocked[cell(p)] == 1

# Re-flood from the target (the player). Cheap to call every frame: it only does
# work when the target has moved to a different cell.
func update(target: Vector3) -> void:
	var c := cell(target)
	if c == _last_cell:
		return
	_last_cell = c
	dist.fill(-1)
	var head := 0
	var tail := 0
	# seed with the target cell, or the free cells around it if the player is standing
	# somewhere zombies cannot (on a car roof, tight against a prop)
	var tx := c % N
	var tz := c / N
	for rad in 4:
		for dz in range(-rad, rad + 1):
			for dx in range(-rad, rad + 1):
				var x := tx + dx
				var z := tz + dz
				if x < 0 or z < 0 or x >= N or z >= N:
					continue
				var i := z * N + x
				if blocked[i] == 0 and dist[i] < 0:
					dist[i] = 0
					_queue[tail] = i
					tail += 1
		if tail > 0:
			break
	while head < tail:
		var i := _queue[head]
		head += 1
		var d := dist[i] + 1
		var x := i % N
		if x > 0 and blocked[i - 1] == 0 and dist[i - 1] < 0:
			dist[i - 1] = d
			_queue[tail] = i - 1
			tail += 1
		if x < N - 1 and blocked[i + 1] == 0 and dist[i + 1] < 0:
			dist[i + 1] = d
			_queue[tail] = i + 1
			tail += 1
		if i >= N and blocked[i - N] == 0 and dist[i - N] < 0:
			dist[i - N] = d
			_queue[tail] = i - N
			tail += 1
		if i < N * N - N and blocked[i + N] == 0 and dist[i + N] < 0:
			dist[i + N] = d
			_queue[tail] = i + N
			tail += 1

func _clear_line(from: Vector3, to: Vector3) -> bool:
	var d := to - from
	d.y = 0
	var len := d.length()
	if len > LOS_RANGE:
		return false
	var steps := int(len / 0.5) + 1
	for s in range(1, steps):
		if is_blocked(from + d * (float(s) / steps)):
			return false
	return true

# Unit direction a walker at `p` should move in to reach `target`.
func direction(p: Vector3, target: Vector3) -> Vector3:
	var straight := target - p
	straight.y = 0
	if straight.length() < 0.01:
		return Vector3.ZERO
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
		var to_cell := Vector3(best % N - HALF + 0.5, 0, best / N - HALF + 0.5) - p
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
	return Vector3(i % N - HALF + 0.5, 0, i / N - HALF + 0.5)

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
