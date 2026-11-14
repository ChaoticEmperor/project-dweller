extends Node3D
# Street clutter and props: cars, taxis, trash, hydrants, signs, barricades, etc.
const B = preload("res://build.gd")
const L = preload("res://layout.gd")

func build() -> void:
	for i in 6:
		var along := randf_range(14, 40) * (1 if i % 2 == 0 else -1)
		var side := randf_range(-4, 4)
		var p := Vector3(side, 0, along) if i < 3 else Vector3(along, 0, side)
		var c := B.box(self, Vector3(1.8, 1.0, 4.0), p + Vector3(0, 0.5, 0), Color(0.9, 0.75, 0.1), true)
		c.rotation.y = randf_range(-0.4, 0.4) + (0.0 if i < 3 else PI / 2)
		B.box(c, Vector3(1.6, 0.6, 2.0), Vector3(0, 0.8, 0), Color(0.2, 0.2, 0.25))

# Big solid props zombies should walk around: [{ "pos": Vector3, "radius": float }, ...]
func obstacles() -> Array:
	return []

# World positions of street-lamp heads (fx.gd puts lights there).
func lamp_positions() -> Array:
	return []
