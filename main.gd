extends Node3D
# Zombie Bonk - a fast, goofy, pixelated zombie shooter.
# Everything is built in code so the project stays tiny.

const NAMES := ["Zombie McBite-Face", "Gary", "Brainy Bob", "Sir Groans-a-Lot", "Chompers",
	"Moaning Myrtle-ish", "Undead Ted", "Lil' Rotty", "Karen (Deceased)", "Big Steve"]
const SHIRTS := [Color(0.7, 0.1, 0.15), Color(0.1, 0.5, 0.5), Color(0.8, 0.6, 0.1), Color(0.4, 0.2, 0.6)]

var player: CharacterBody3D
var cam: Camera3D
var pivot: Node3D
var gun: Node3D
var flash: MeshInstance3D
var body_mesh: Node3D
var hud: Label
var center: Label
var cross: Label
var zombies: Array = []
var mats := {}

var hp := 100.0
var ammo := 8
var reloading := 0.0
var fire_cd := 0.0
var score := 0
var combo := 0
var combo_t := 0.0
var wave := 0
var to_spawn := 0
var spawn_t := 0.0
var dash_t := 0.0
var dash_cd := 0.0
var third_person := false
var shake := 0.0
var recoil := 0.0
var dead := false
var hurt_flash := 0.0

func mat(c: Color) -> StandardMaterial3D:
	var k := c.to_html()
	if not mats.has(k):
		var m := StandardMaterial3D.new()
		m.albedo_color = c
		m.roughness = 1.0
		mats[k] = m
	return mats[k]

func box(parent: Node, size: Vector3, pos: Vector3, c: Color, collide := false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat(c)
	mi.position = pos
	parent.add_child(mi)
	if collide:
		var sb := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var sh := BoxShape3D.new()
		sh.size = size
		cs.shape = sh
		sb.add_child(cs)
		mi.add_child(sb)
	return mi

func _ready() -> void:
	randomize()
	build_world()
	build_player()
	build_hud()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	next_wave()

# ---------------- WORLD ----------------
func build_world() -> void:
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

	box(self, Vector3(120, 1, 120), Vector3(0, -0.5, 0), Color(0.22, 0.35, 0.08), true)
	# grass tufts
	var greens := [Color(0.55, 0.7, 0.15), Color(0.45, 0.6, 0.1), Color(0.7, 0.8, 0.2)]
	for i in 500:
		var p := Vector3(randf_range(-40, 40), 0.25, randf_range(-40, 40))
		var t := box(self, Vector3(0.15, randf_range(0.3, 0.7), 0.15), p, greens[i % 3])
		t.rotation.z = randf_range(-0.3, 0.3)
	# fence ring
	for side in 4:
		for i in range(-15, 16):
			var a := float(i) * 1.2
			var pos: Vector3
			match side:
				0: pos = Vector3(a, 0.6, -18)
				1: pos = Vector3(a, 0.6, 18)
				2: pos = Vector3(-18, 0.6, a)
				_: pos = Vector3(18, 0.6, a)
			if abs(a) < 2.5:
				continue  # gaps where zombies stumble in
			var plank := box(self, Vector3(0.3, randf_range(1.0, 1.4), 0.3), pos, Color(0.6, 0.65, 0.75).darkened(randf() * 0.3))
			plank.rotation.z = randf_range(-0.15, 0.15)
	# houses
	for i in 10:
		var ang := TAU * i / 10.0
		var d := randf_range(26, 34)
		var p := Vector3(cos(ang) * d, 0, sin(ang) * d)
		var w := randf_range(5, 8)
		var h := randf_range(4, 7)
		var hc: Color = [Color(0.8, 0.8, 0.7), Color(0.6, 0.65, 0.6), Color(0.75, 0.7, 0.6)][i % 3]
		box(self, Vector3(w, h, w), p + Vector3(0, h / 2, 0), hc, true)
		var roof := box(self, Vector3(w * 0.8, w * 0.8, w + 0.4), p + Vector3(0, h, 0), Color(0.45, 0.25, 0.2))
		roof.rotation.z = PI / 4
		roof.scale.y = 0.6
	# cover crates / cars
	for i in 8:
		var p := Vector3(randf_range(-14, 14), 0, randf_range(-14, 14))
		if p.length() < 4:
			continue
		var c := box(self, Vector3(2.2, 1.0, 1.2), p + Vector3(0, 0.5, 0), Color(0.3, 0.3, 0.35), true)
		c.rotation.y = randf() * PI
		box(c, Vector3(1.2, 0.6, 1.1), Vector3(0, 0.8, 0), Color(0.5, 0.15, 0.1))

# ---------------- PLAYER ----------------
func build_player() -> void:
	player = CharacterBody3D.new()
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	cs.shape = cap
	cs.position.y = 0.9
	player.add_child(cs)
	player.position = Vector3(0, 0.1, 0)
	add_child(player)

	body_mesh = Node3D.new()
	player.add_child(body_mesh)
	box(body_mesh, Vector3(0.5, 0.6, 0.3), Vector3(0, 1.2, 0), Color(0.4, 0.4, 0.4))
	box(body_mesh, Vector3(0.35, 0.35, 0.35), Vector3(0, 1.7, 0), Color(0.9, 0.7, 0.55))
	box(body_mesh, Vector3(0.5, 0.8, 0.3), Vector3(0, 0.4, 0), Color(0.15, 0.25, 0.5))
	box(body_mesh, Vector3(0.45, 0.5, 0.2), Vector3(0, 1.2, 0.22), Color(0.7, 0.5, 0.1))  # backpack
	body_mesh.visible = false

	pivot = Node3D.new()
	pivot.position.y = 1.6
	player.add_child(pivot)
	cam = Camera3D.new()
	cam.fov = 85
	pivot.add_child(cam)

	gun = Node3D.new()
	cam.add_child(gun)
	gun.position = Vector3(0.25, -0.22, -0.45)
	gun.scale = Vector3.ONE * 0.6
	box(gun, Vector3(0.08, 0.1, 0.4), Vector3.ZERO, Color(0.2, 0.2, 0.22))
	box(gun, Vector3(0.07, 0.16, 0.08), Vector3(0, -0.1, 0.12), Color(0.35, 0.2, 0.1))
	box(gun, Vector3(0.12, 0.12, 0.12), Vector3(0, -0.05, 0.22), Color(0.9, 0.7, 0.55))  # hand
	flash = box(gun, Vector3(0.15, 0.15, 0.15), Vector3(0, 0, -0.28), Color(1, 0.9, 0.3))
	flash.material_override = StandardMaterial3D.new()
	flash.material_override.albedo_color = Color(1, 0.85, 0.2)
	flash.material_override.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flash.visible = false

func build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	hud = Label.new()
	hud.position = Vector2(6, 4)
	hud.add_theme_font_size_override("font_size", 10)
	hud.add_theme_color_override("font_outline_color", Color.BLACK)
	hud.add_theme_constant_override("outline_size", 3)
	layer.add_child(hud)
	cross = Label.new()
	cross.text = "+"
	cross.add_theme_font_size_override("font_size", 12)
	cross.position = Vector2(196, 104)
	layer.add_child(cross)
	center = Label.new()
	center.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	center.size = Vector2(400, 40)
	center.position = Vector2(0, 60)
	center.add_theme_font_size_override("font_size", 16)
	center.add_theme_color_override("font_outline_color", Color.BLACK)
	center.add_theme_constant_override("outline_size", 4)
	layer.add_child(center)

func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not dead:
		player.rotate_y(-ev.relative.x * 0.003)
		pivot.rotation.x = clamp(pivot.rotation.x - ev.relative.y * 0.003, -1.4, 1.4)
	if ev is InputEventMouseButton and ev.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if ev is InputEventKey and ev.pressed and not ev.echo:
		match ev.keycode:
			KEY_ESCAPE: Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			KEY_V: toggle_view()
			KEY_R: start_reload()
			KEY_ENTER:
				if dead: get_tree().reload_current_scene()

func toggle_view() -> void:
	third_person = not third_person
	body_mesh.visible = third_person
	gun.visible = not third_person
	cam.position = Vector3(0.6, 0.4, 3.0) if third_person else Vector3.ZERO

func start_reload() -> void:
	if reloading <= 0 and ammo < 8:
		reloading = 0.9

func _physics_process(dt: float) -> void:
	if dead:
		center.text = "YOU GOT BONKED!\nScore %d  -  Wave %d\n[Enter] to try again" % [score, wave]
		return
	# movement
	var inp := Vector2.ZERO
	if Input.is_key_pressed(KEY_W): inp.y -= 1
	if Input.is_key_pressed(KEY_S): inp.y += 1
	if Input.is_key_pressed(KEY_A): inp.x -= 1
	if Input.is_key_pressed(KEY_D): inp.x += 1
	var dir := (player.transform.basis * Vector3(inp.x, 0, inp.y)).normalized()
	var speed := 9.0
	dash_cd -= dt
	if Input.is_key_pressed(KEY_SHIFT) and dash_cd <= 0 and dir != Vector3.ZERO:
		dash_t = 0.18
		dash_cd = 0.8
	if dash_t > 0:
		dash_t -= dt
		speed = 28.0
	player.velocity.x = dir.x * speed
	player.velocity.z = dir.z * speed
	if player.is_on_floor():
		if Input.is_key_pressed(KEY_SPACE):
			player.velocity.y = 8.0
	else:
		player.velocity.y -= 22.0 * dt
	player.move_and_slide()
	player.position.x = clamp(player.position.x, -17, 17)
	player.position.z = clamp(player.position.z, -17, 17)

	# shooting
	fire_cd -= dt
	if reloading > 0:
		reloading -= dt
		gun.rotation.x = -0.8
		if reloading <= 0:
			ammo = 8
			gun.rotation.x = 0
	elif Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and fire_cd <= 0:
		if ammo > 0:
			shoot()
		else:
			start_reload()
	recoil = lerp(recoil, 0.0, dt * 12)
	gun.position.z = -0.45 + recoil * 0.15
	gun.rotation.x = recoil * 0.5 if reloading <= 0 else gun.rotation.x
	if fire_cd < 0.05:
		flash.visible = false
	# bob + shake
	var t := Time.get_ticks_msec() / 1000.0
	var bob := sin(t * 14) * 0.04 * dir.length() if player.is_on_floor() else 0.0
	shake = max(shake - dt * 3, 0)
	pivot.position = Vector3(randf_range(-1, 1) * shake * 0.1, 1.6 + bob + randf_range(-1, 1) * shake * 0.1, 0)

	# combo
	combo_t -= dt
	if combo_t <= 0:
		combo = 0

	# waves
	if to_spawn > 0:
		spawn_t -= dt
		if spawn_t <= 0:
			spawn_zombie()
			to_spawn -= 1
			spawn_t = max(0.25, 1.2 - wave * 0.1)
	elif zombies.is_empty():
		next_wave()

	update_zombies(dt)
	hurt_flash = max(hurt_flash - dt, 0)
	hud.text = "HP %d   AMMO %d/8%s\nSCORE %d   WAVE %d%s\n[V] view  [Shift] dash  [R] reload" % [
		int(hp), ammo, "  RELOADING" if reloading > 0 else "", score, wave,
		("   COMBO x%d!" % combo) if combo > 1 else ""]
	hud.add_theme_color_override("font_color", Color(1, 0.3, 0.3) if hurt_flash > 0 else Color.WHITE)

func shoot() -> void:
	ammo -= 1
	fire_cd = 0.16
	recoil = 1.0
	shake = 0.4
	flash.visible = true
	flash.rotation = Vector3(randf(), randf(), randf())
	var space := get_world_3d().direct_space_state
	# shotgun-ish: 5 pellets
	for i in 5:
		var spread := Vector3(randf_range(-1, 1), randf_range(-1, 1), 0) * 0.03 if i > 0 else Vector3.ZERO
		var from := cam.global_position
		var fwd := -cam.global_transform.basis.z + cam.global_transform.basis * spread
		var to := from + fwd.normalized() * 60
		var q := PhysicsRayQueryParameters3D.create(from, to)
		q.exclude = [player.get_rid()]
		q.collide_with_areas = true
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			continue
		var col: Object = hit.collider
		if col is Area3D and col.has_meta("zombie"):
			var z: Dictionary = col.get_meta("zombie")
			if z.get("dead", false):
				continue
			var head: bool = col.get_meta("head")
			hit_zombie(z, 60.0 if head else 25.0, head, hit.position, fwd)
		else:
			gibs(hit.position, Color(0.6, 0.55, 0.4), 2, Vector3.UP)

func gibs(p: Vector3, c: Color, n: int, push: Vector3) -> void:
	for i in n:
		var g := RigidBody3D.new()
		var cs := CollisionShape3D.new()
		var sh := BoxShape3D.new()
		sh.size = Vector3.ONE * 0.12
		cs.shape = sh
		g.add_child(cs)
		box(g, sh.size, Vector3.ZERO, c)
		g.collision_layer = 0
		g.collision_mask = 1
		add_child(g)
		g.global_position = p
		g.linear_velocity = push * 4 + Vector3(randf_range(-3, 3), randf_range(2, 6), randf_range(-3, 3))
		get_tree().create_timer(1.5).timeout.connect(g.queue_free)

# ---------------- ZOMBIES ----------------
func next_wave() -> void:
	wave += 1
	to_spawn = 4 + wave * 3
	spawn_t = 1.5
	hp = min(hp + 25, 100)
	center.text = "WAVE %d" % wave
	get_tree().create_timer(2.0).timeout.connect(func(): if not dead: center.text = "")

func spawn_zombie() -> void:
	var root := Node3D.new()
	add_child(root)
	var gaps := [Vector3(0, 0, -20), Vector3(0, 0, 20), Vector3(-20, 0, 0), Vector3(20, 0, 0)]
	root.position = gaps.pick_random() + Vector3(randf_range(-1.5, 1.5), 0, randf_range(-1.5, 1.5))
	var big := randf() < 0.12 and wave > 2
	var s := 1.6 if big else randf_range(0.85, 1.1)
	root.scale = Vector3.ONE * s
	var skin := Color(0.5, 0.7, 0.35).lerp(Color(0.4, 0.55, 0.5), randf())
	var parts := Node3D.new()
	root.add_child(parts)
	box(parts, Vector3(0.25, 0.8, 0.25), Vector3(-0.15, 0.4, 0), Color(0.2, 0.3, 0.55))
	box(parts, Vector3(0.25, 0.8, 0.25), Vector3(0.15, 0.4, 0), Color(0.2, 0.3, 0.55))
	box(parts, Vector3(0.6, 0.7, 0.35), Vector3(0, 1.15, 0), SHIRTS.pick_random())
	var arm_l := box(parts, Vector3(0.18, 0.18, 0.7), Vector3(-0.38, 1.35, -0.35), skin)
	var arm_r := box(parts, Vector3(0.18, 0.18, 0.7), Vector3(0.38, 1.35, -0.35), skin)
	var head := Node3D.new()
	head.position = Vector3(0, 1.75, 0)
	parts.add_child(head)
	box(head, Vector3(0.45, 0.45, 0.45), Vector3.ZERO, skin)
	box(head, Vector3(0.08, 0.08, 0.02), Vector3(-0.1, 0.05, -0.23), Color(1, 1, 0.3))
	box(head, Vector3(0.08, 0.08, 0.02), Vector3(0.1, 0.03, -0.23), Color(1, 1, 0.3))
	box(head, Vector3(0.25, 0.06, 0.02), Vector3(0, -0.12, -0.23), Color(0.2, 0.05, 0.05))
	box(head, Vector3(0.5, 0.12, 0.5), Vector3(0, 0.25, 0), Color(0.15, 0.1, 0.05))  # hair
	var label := Label3D.new()
	label.text = NAMES.pick_random()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 24
	label.pixel_size = 0.006
	label.position.y = 2.3
	label.outline_size = 6
	label.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	root.add_child(label)

	var z := {"root": root, "parts": parts, "head": head, "arms": [arm_l, arm_r], "label": label,
		"hp": (150.0 if big else 50.0) + wave * 5, "speed": (2.2 if big else randf_range(3.0, 4.5)) + wave * 0.2,
		"phase": randf() * TAU, "atk": 0.0, "dead": false, "big": big, "skin": skin}
	# hitboxes
	for info in [[Vector3(0.7, 1.5, 0.5), Vector3(0, 0.8, 0), false], [Vector3(0.5, 0.5, 0.5), Vector3(0, 1.75, 0), true]]:
		var a := Area3D.new()
		var cs := CollisionShape3D.new()
		var sh := BoxShape3D.new()
		sh.size = info[0]
		cs.shape = sh
		a.add_child(cs)
		a.position = info[1]
		a.set_meta("zombie", z)
		a.set_meta("head", info[2])
		root.add_child(a)
	zombies.append(z)

func hit_zombie(z: Dictionary, dmg: float, headshot: bool, p: Vector3, dir: Vector3) -> void:
	z.hp -= dmg
	gibs(p, Color(0.3, 0.6, 0.1), 3, dir)
	z.root.position += Vector3(dir.x, 0, dir.z).normalized() * 0.25  # knockback
	if z.hp <= 0:
		z.dead = true
		combo += 1
		combo_t = 2.0
		score += (150 if headshot else 100) * combo * (3 if z.big else 1)
		if headshot:
			z.head.visible = false
			gibs(z.head.global_position, z.skin, 8, Vector3.UP)
			z.label.text = "BONK!"
		else:
			z.label.text = ["oof", "ow", "bleh", "x_x"].pick_random()
		z.label.modulate = Color(1, 0.9, 0.2)
		var tw := create_tween()
		tw.tween_property(z.parts, "rotation:x", -PI / 2, 0.3).set_trans(Tween.TRANS_BOUNCE)
		tw.parallel().tween_property(z.label, "position:y", 3.5, 0.8)
		tw.tween_interval(0.6)
		tw.tween_property(z.root, "scale", Vector3(1.0, 0.01, 1.0) * z.root.scale.x, 0.25)
		tw.tween_callback(z.root.queue_free)
		zombies.erase(z)

func update_zombies(dt: float) -> void:
	var t := Time.get_ticks_msec() / 1000.0
	for z in zombies:
		var root: Node3D = z.root
		var to: Vector3 = player.global_position - root.global_position
		to.y = 0
		var d := to.length()
		if d > 0.1:
			root.look_at(root.global_position - to.normalized(), Vector3.UP)
		# separation so they don't stack
		var push := Vector3.ZERO
		for o in zombies:
			if o != z:
				var off: Vector3 = root.position - o.root.position
				off.y = 0
				if off.length() < 0.8 and off.length() > 0.001:
					push += off.normalized() * (0.8 - off.length())
		if d > 1.1:
			root.position += to.normalized() * z.speed * dt + push * 3 * dt
		# goofy waddle
		var ph: float = t * z.speed * 3.0 + z.phase
		z.parts.rotation.z = sin(ph) * 0.15
		z.parts.position.y = abs(sin(ph)) * 0.1
		z.arms[0].rotation.x = sin(ph) * 0.3
		z.arms[1].rotation.x = -sin(ph) * 0.3
		z.head.rotation.z = sin(ph * 0.5) * 0.3
		z.atk -= dt
		if d < 1.4 and z.atk <= 0:
			z.atk = 0.8
			var dmg := 20.0 if z.big else 10.0
			hp -= dmg
			hurt_flash = 0.3
			shake = 0.8
			if hp <= 0:
				dead = true
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
