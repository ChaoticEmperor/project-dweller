extends Node
# All sound. Every sound is synthesised in code at start-up into AudioStreamWAV
# buffers (Godot's web export plays those with low latency; live-generated audio
# is not supported in the web's default "Sample" playback mode).
# See SPECS.md for the frozen list of sound names.

func setup() -> void:
	pass

# Play a sound by name. Unknown names must be ignored silently.
func play(_name: String, _pitch := 1.0, _volume_db := 0.0) -> void:
	pass

# Play a sound that comes from a place in the world (quieter with distance from the listener).
func play_at(_name: String, _pos: Vector3, _pitch := 1.0) -> void:
	pass

# The node sounds are heard from (the camera).
func set_listener(_node: Node3D) -> void:
	pass

func set_music(_on: bool) -> void:
	pass

# 0 = calm, 1 = full horde; lets the music react to the action.
func set_intensity(_k: float) -> void:
	pass
