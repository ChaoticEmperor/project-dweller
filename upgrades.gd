extends RefCounted
# Between-wave upgrades. main.gd asks stat(name, base) for every tunable number, so an
# upgrade is just a modifier on one or more stats. See SPECS.md for the stat names.

func reset() -> void:
	pass

# Offer `n` different upgrades: [{ "id": String, "title": String, "desc": String, "color": Color }]
# An empty array means "no draft" (main then skips straight to the next wave).
func roll(_n: int, _rng: RandomNumberGenerator) -> Array:
	return []

func take(_id: String) -> void:
	pass

func level(_id: String) -> int:
	return 0

# The value of a stat after all taken upgrades are applied.
func stat(_name: String, base: float) -> float:
	return base
