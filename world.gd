extends Node3D
# The city: ground, roads, sidewalks, buildings, subway entrances, street-end barriers.
# Static scenery only. Props/clutter live in clutter.gd; lights and sky live in fx.gd.
const B = preload("res://build.gd")
const L = preload("res://layout.gd")

func build() -> void:
	var a := L.ARM_LEN
	var ch := L.CORRIDOR_HALF
	B.box(self, Vector3(a * 2 + 40, 1, a * 2 + 40), Vector3(0, -0.5, 0), Color(0.18, 0.18, 0.2), true)
	# sidewalks along each arm
	for sx in [-1, 1]:
		for sz in [-1, 1]:
			var len := a - ch
			var mid := ch + len / 2
			B.box(self, Vector3(L.SIDEWALK, L.KERB_H, len), Vector3(sx * (L.ROAD_HALF + 1.5), L.KERB_H / 2, sz * mid), Color(0.55, 0.55, 0.55), true)
			B.box(self, Vector3(len, L.KERB_H, L.SIDEWALK), Vector3(sx * mid, L.KERB_H / 2, sz * (L.ROAD_HALF + 1.5)), Color(0.55, 0.55, 0.55), true)
			# corner block: one big placeholder tower
			var size := a - ch
			var h := randf_range(30, 60)
			B.box(self, Vector3(size, h, size), Vector3(sx * (ch + size / 2), h / 2, sz * (ch + size / 2)), Color(0.45, 0.4, 0.38), true)
	# street-end walls
	for d in [Vector3(0, 0, 1), Vector3(0, 0, -1), Vector3(1, 0, 0), Vector3(-1, 0, 0)]:
		var sz2 := Vector3(ch * 2, 6, 1) if d.z != 0 else Vector3(1, 6, ch * 2)
		B.box(self, sz2, d * a + Vector3(0, 3, 0), Color(0.3, 0.3, 0.32), true)
	for s in L.SUBWAY_ENTRANCES:
		B.box(self, Vector3(3, 1.1, 6), s + Vector3(0, 0.55, 0), Color(0.1, 0.35, 0.2), true)
