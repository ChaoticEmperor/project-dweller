extends Node3D
# One zombie's body: how it looks and how it animates. zombies.gd owns where it is,
# which way it faces and what it is doing; this script only makes that look good.
# Feet at y = 0, face toward -Z. See SPECS.md for the frozen API.
const B = preload("res://build.gd")

const SKINS := [Color(0.5, 0.7, 0.35), Color(0.45, 0.62, 0.42), Color(0.4, 0.55, 0.5), Color(0.55, 0.66, 0.3)]
const SHIRTS := [Color(0.7, 0.1, 0.15), Color(0.1, 0.5, 0.5), Color(0.8, 0.6, 0.1), Color(0.4, 0.2, 0.6)]

var type := "commuter"
var height := 2.0      # top of head, metres (after scale)
var radius := 0.35     # body radius, metres (after scale)
var skin := Color.WHITE

var _parts: Node3D
var _head: Node3D
var _arms: Array = []
var _label: Label3D
var _phase := 0.0
var _windup := 0.0
var _flinch := 0.0
var _swell := 0.0
var _base_scale := 1.0
var _dead := false

func build(p_type: String, rng: RandomNumberGenerator) -> void:
	type = p_type
	match type:
		"delivery": _base_scale = 0.9
		"bloater": _base_scale = 1.2
		"sanitation": _base_scale = 1.7
		_: _base_scale = rng.randf_range(0.9, 1.08)
	skin = SKINS[rng.randi() % SKINS.size()]
	var shirt: Color = SHIRTS[rng.randi() % SHIRTS.size()]
	if type == "delivery": shirt = Color(1.0, 0.25, 0.6)
	if type == "bloater": shirt = Color(0.6, 1.0, 0.1)
	if type == "sanitation": shirt = Color(0.8, 0.9, 0.1)
	_parts = Node3D.new()
	add_child(_parts)
	_parts.scale = Vector3.ONE * _base_scale
	var w := 1.6 if type == "bloater" else 1.0
	B.box(_parts, Vector3(0.25, 0.8, 0.25), Vector3(-0.15, 0.4, 0), Color(0.2, 0.3, 0.55))
	B.box(_parts, Vector3(0.25, 0.8, 0.25), Vector3(0.15, 0.4, 0), Color(0.2, 0.3, 0.55))
	B.box(_parts, Vector3(0.6 * w, 0.7, 0.35 * w), Vector3(0, 1.15, 0), shirt)
	_arms = [B.box(_parts, Vector3(0.18, 0.18, 0.7), Vector3(-0.38 * w, 1.35, -0.35), skin),
		B.box(_parts, Vector3(0.18, 0.18, 0.7), Vector3(0.38 * w, 1.35, -0.35), skin)]
	_head = Node3D.new()
	_head.position = Vector3(0, 1.75, 0)
	_parts.add_child(_head)
	B.box(_head, Vector3(0.45, 0.45, 0.45), Vector3.ZERO, skin)
	B.box(_head, Vector3(0.08, 0.08, 0.02), Vector3(-0.1, 0.05, -0.23), Color(1, 1, 0.3))
	B.box(_head, Vector3(0.08, 0.08, 0.02), Vector3(0.1, 0.03, -0.23), Color(1, 1, 0.3))
	B.box(_head, Vector3(0.25, 0.06, 0.02), Vector3(0, -0.12, -0.23), Color(0.2, 0.05, 0.05))
	B.box(_head, Vector3(0.5, 0.12, 0.5), Vector3(0, 0.25, 0), Color(0.15, 0.1, 0.05))  # hair
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 24
	_label.pixel_size = 0.006
	_label.outline_size = 6
	_label.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_label.position.y = 2.3 * _base_scale
	add_child(_label)
	height = 2.0 * _base_scale
	radius = 0.35 * _base_scale * w
	_phase = rng.randf() * TAU

# Hit boxes in rig-local space: [{ "size": Vector3, "pos": Vector3, "head": bool }]
func hit_shapes() -> Array:
	var s := _base_scale
	var w := 1.6 if type == "bloater" else 1.0
	return [{"size": Vector3(0.7 * w, 1.5, 0.5 * w) * s, "pos": Vector3(0, 0.8, 0) * s, "head": false},
		{"size": Vector3(0.5, 0.5, 0.5) * s, "pos": Vector3(0, 1.75, 0) * s, "head": true}]

# World position of the head centre.
func head_position() -> Vector3:
	return _head.global_position

# Advance the animation. speed = how fast the zombie is moving over the ground (m/s).
func tick(dt: float, speed: float) -> void:
	if _dead:
		return
	_phase += dt * speed * 3.0
	_flinch = max(_flinch - dt * 6.0, 0.0)
	_parts.rotation.z = sin(_phase) * 0.15
	_parts.rotation.x = _flinch * 0.5
	_parts.position.y = abs(sin(_phase)) * 0.1
	_arms[0].rotation.x = sin(_phase) * 0.3 + _windup * 1.2
	_arms[1].rotation.x = -sin(_phase) * 0.3 + _windup * 1.2
	_head.rotation.z = sin(_phase * 0.5) * 0.3
	var sw := 1.0 + _swell * 0.35
	_parts.scale = Vector3(sw, 1.0, sw) * _base_scale

# Attack telegraph pose: 0 = normal, 1 = fully wound up and about to strike.
func set_windup(k: float) -> void:
	_windup = k

# The swing itself (called once at the moment the hit is resolved).
func strike() -> void:
	_windup = 0.0

# React to a hit coming from direction `dir` (world space), strength 0..1.
func flinch(_dir: Vector3, strength: float) -> void:
	_flinch = max(_flinch, strength)

# Brief white flash on being hit.
func flash(_duration := 0.06) -> void:
	pass

# 0..1 "about to explode" look (bloater).
func set_swell(k: float) -> void:
	_swell = k

# Headshot: remove the head.
func pop_head() -> void:
	_head.visible = false

# Play the death. Returns seconds until the rig has finished and may be freed.
func die(_dir: Vector3, _headshot: bool) -> float:
	_dead = true
	var tw := create_tween()
	tw.tween_property(_parts, "rotation:x", -PI / 2, 0.3).set_trans(Tween.TRANS_BOUNCE)
	tw.parallel().tween_property(_label, "position:y", _label.position.y + 1.2, 0.8)
	tw.tween_interval(0.6)
	tw.tween_property(self, "scale", Vector3(1.0, 0.01, 1.0), 0.25)
	return 1.75

# Entrance animation (climbing out / popping up), `duration` seconds.
func spawn_rise(_duration: float) -> void:
	pass

func set_label(text: String, color := Color.WHITE) -> void:
	_label.text = text
	_label.modulate = color

func set_label_visible(on: bool) -> void:
	_label.visible = on
