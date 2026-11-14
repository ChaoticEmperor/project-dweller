extends RefCounted
# The shared map contract. Use via: const L = preload("res://layout.gd")
#
# The level is one New York street intersection seen from above as a plus (+):
#   - a north-south avenue along the Z axis and an east-west street along the X axis,
#     crossing at the origin. Ground is flat at y = 0.
#   - each street is a corridor between tall buildings: road in the middle, a sidewalk each side.
#   - the four corner blocks (|x| > CORRIDOR_HALF and |z| > CORRIDOR_HALF) are solid buildings.
#   - each street arm ends at +/-ARM_LEN, where it is blocked off.

const ROAD_HALF := 6.0        # road is 12 wide (x or z from -6..6)
const SIDEWALK := 3.0         # sidewalk width, raised kerb
const CORRIDOR_HALF := 9.0    # building faces are at +/-9 from each street's centre line
const ARM_LEN := 48.0         # streets run from the centre out to +/-48
const KERB_H := 0.15          # sidewalk height above the road

# Subway entrances: stairwells on the avenue's sidewalks. Each one occupies a footprint
# 3 wide (x) by 6 long (z) centred on these points. Zombies climb out of them.
const SUBWAY_ENTRANCES := [Vector3(7.5, 0, 20), Vector3(-7.5, 0, -20)]

# Zombies spawn at the far ends of the four arms and at the subway entrances.
static func spawn_points() -> Array:
	var e := ARM_LEN - 4.0
	var pts := [Vector3(0, 0, -e), Vector3(0, 0, e), Vector3(-e, 0, 0), Vector3(e, 0, 0)]
	for s in SUBWAY_ENTRANCES:
		pts.append(Vector3(s.x - sign(s.x) * 2.5, 0, s.z))
	return pts

static func in_ns(p: Vector3) -> bool:  # inside the north-south avenue
	return abs(p.x) <= CORRIDOR_HALF

static func in_ew(p: Vector3) -> bool:  # inside the east-west street
	return abs(p.z) <= CORRIDOR_HALF

# Where a walker at `from` should head to reach `to` without cutting through a corner block.
static func nav_target(from: Vector3, to: Vector3) -> Vector3:
	if (in_ns(from) and in_ns(to)) or (in_ew(from) and in_ew(to)):
		return to
	if in_ns(from):
		return Vector3(clamp(from.x, -ROAD_HALF, ROAD_HALF), 0, clamp(to.z, -ROAD_HALF, ROAD_HALF))
	return Vector3(clamp(to.x, -ROAD_HALF, ROAD_HALF), 0, clamp(from.z, -ROAD_HALF, ROAD_HALF))

# Push a position back inside the plus-shaped street area.
static func clamp_to_streets(p: Vector3, margin := 0.5) -> Vector3:
	var h := CORRIDOR_HALF - margin
	var a := ARM_LEN - margin
	p.x = clamp(p.x, -a, a)
	p.z = clamp(p.z, -a, a)
	if abs(p.x) > h and abs(p.z) > h:
		# inside a corner block: snap to the nearer street
		if abs(p.x) - h < abs(p.z) - h:
			p.x = sign(p.x) * h
		else:
			p.z = sign(p.z) * h
	return p
