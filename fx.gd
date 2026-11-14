extends Node3D
# Lighting, sky, fog and all visual effects (muzzle flash, impacts, gibs, camera shake).
const B = preload("res://build.gd")

var cam: Camera3D
var flash: MeshInstance3D
var flash_t := 0.0
var shake := 0.0

# Called once. Creates the sky/environment and lights.
func setup(camera: Camera3D) -> void:
	cam = camera
	var env := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.3, 0.55, 0.95)
	sm.sky_horizon_color = Color(0.75, 0.85, 0.95)
	sm.ground_horizon_color = Color(0.5, 0.6, 0.4)
	sky.sky_material = sm
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.45, 0.5, 0.6)
	e.ambient_light_energy = 0.6
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.fog_enabled = true
	e.fog_light_color = Color(0.7, 0.8, 0.85)
	e.fog_density = 0.012
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 35, 0)
	sun.light_energy = 0.9
	sun.light_color = Color(1, 0.95, 0.8)
	sun.shadow_enabled = true
	add_child(sun)

# Called once with the first-person gun node (child of the camera, barrel points along -Z).
func attach_gun(gun: Node3D) -> void:
	flash = B.box(gun, Vector3(0.15, 0.15, 0.15), Vector3(0, 0, -0.28), Color(1, 0.85, 0.2), false, true)
	flash.visible = false

func _process(dt: float) -> void:
	flash_t -= dt
	if flash and flash_t <= 0:
		flash.visible = false
	shake = max(shake - dt * 3, 0.0)

# The player fired.
func on_shoot() -> void:
	shake = max(shake, 0.4)
	if flash:
		flash.visible = true
		flash.rotation = Vector3(randf(), randf(), randf())
		flash_t = 0.06

# A bullet hit scenery at `pos` (surface normal `normal`).
func impact(pos: Vector3, _normal: Vector3) -> void:
	gibs(pos, Color(0.6, 0.55, 0.4), 2, Vector3.UP)

# A bullet hit a zombie at `pos`, travelling in `dir`.
func zombie_hit(pos: Vector3, dir: Vector3, _headshot: bool) -> void:
	gibs(pos, Color(0.3, 0.6, 0.1), 3, dir)

# A zombie died. `head_pos` is its head position, `skin` its skin colour.
func zombie_death(head_pos: Vector3, skin: Color, headshot: bool) -> void:
	if headshot:
		gibs(head_pos, skin, 8, Vector3.UP)

# The player took `dmg` damage.
func player_hurt(_dmg: float) -> void:
	shake = max(shake, 0.8)

# Camera offset to add this frame (main adds it to the camera pivot position).
func shake_offset() -> Vector3:
	return Vector3(randf_range(-1, 1), randf_range(-1, 1), 0) * shake * 0.1

func gibs(p: Vector3, c: Color, n: int, push: Vector3) -> void:
	for i in n:
		var g := RigidBody3D.new()
		var cs := CollisionShape3D.new()
		var sh := BoxShape3D.new()
		sh.size = Vector3.ONE * 0.12
		cs.shape = sh
		g.add_child(cs)
		B.box(g, sh.size, Vector3.ZERO, c)
		g.collision_layer = 0
		g.collision_mask = 1
		add_child(g)
		g.global_position = p
		g.linear_velocity = push * 4 + Vector3(randf_range(-3, 3), randf_range(2, 6), randf_range(-3, 3))
		get_tree().create_timer(1.5).timeout.connect(g.queue_free)

# Called once after setup() with the street-lamp head positions from clutter.gd.
func add_street_lights(_positions: Array) -> void:
	pass
