extends Node3D
# Things that fall from the sky or appear in the street for the player to grab:
# weapon crates, airdrops, pickups. main.gd calls update(dt) every frame while playing.
# Listen to main.wave_started / main.wave_ended to decide when to drop things.

var main: Node3D

func setup(main_node: Node3D) -> void:
	main = main_node

func update(_dt: float) -> void:
	pass

# Remove everything (restart).
func clear() -> void:
	pass
