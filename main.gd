extends Node3D
# Zombie Bonk - a fast, goofy, pixelated zombie shooter.
# main.gd owns the game rules: player, gun, zombies, waves, scoring.
# Everything else lives in a module:
#   world.gd    - the city (roads, buildings, subway entrances)
#   clutter.gd  - street props
#   fx.gd       - lighting, sky and visual effects
#   hud.gd      - 2D UI and touch-control visuals
#   controls.gd - keyboard/mouse/touch input
#   layout.gd   - shared map dimensions and zombie path helper
#   build.gd    - shared box-building helpers
const B = preload("res://build.gd")
const L = preload("res://layout.gd")

const NAMES := ["Zombie McBite-Face", "Gary", "Brainy Bob", "Sir Groans-a-Lot", "Chompers",
	"Moaning Myrtle-ish", "Undead Ted", "Lil' Rotty", "Karen (Deceased)", "Big Steve"]
const SHIRTS := [Color(0.7, 0.1, 0.15), Color(0.1, 0.5, 0.5), Color(0.8, 0.6, 0.1), Color(0.4, 0.2, 0.6)]
const MAX_AMMO := 8

var world: Node3D
var clutter: Node3D
var fx: Node3D
var hud: CanvasLayer
var controls: Node

var player: CharacterBody3D
var cam: Camera3D
var pivot: Node3D
var gun: Node3D
var body_mesh: Node3D
var zombies: Array = []

var hp := 100.0
var ammo := MAX_AMMO
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
var dash_req := false
var third_person := false
var recoil := 0.0
var dead := false
var hurt_flash := 0.0
var started := false
var move_vel := Vector2.ZERO
var obstacles: Array = []  # [{pos, radius}] big props zombies walk around

func _ready() -> void:
	randomize()
	world = preload("res://world.gd").new()
	add_child(world)
	world.build()
	clutter = preload("res://clutter.gd").new()
	add_child(clutter)
	clutter.build()
	build_player()
	fx = preload("res://fx.gd").new()
	add_child(fx)
	fx.setup(cam)
	fx.attach_gun(gun)
	fx.add_street_lights(clutter.lamp_positions())
	fx.add_subway_globes([Vector3(6.25, 3.3, 17.15), Vector3(8.75, 3.3, 17.15), Vector3(-6.25, 3.3, -17.15), Vector3(-8.75, 3.3, -17.15)])
	obstacles = clutter.obstacles()
	hud = preload("res://hud.gd").new()
	add_child(hud)
	hud.build()
	controls = preload("res://controls.gd").new()
	add_child(controls)
	controls.setup(hud)
	controls.dash.connect(func(): dash_req = true)
	controls.reload.connect(start_reload)
	controls.toggle_view.connect(toggle_view)
	controls.start_pressed.connect(begin_game)
	hud.show_title()
	_debug_args()

# Developer/test switches, passed after `--` on the command line (never present on the web):
#   --autostart          start the game without a click
#   --god                player takes no damage
#   --pos=x,z            teleport the player       --yaw=deg  --pitch=deg   aim the camera
#   --shot=/abs/file.png --t=seconds               save a screenshot after t seconds, then quit
var _god := false
func _debug_args() -> void:
	var a := {}
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=")
		a[kv[0]] = kv[1] if kv.size() > 1 else ""
	_god = a.has("god")
	if a.has("pos"):
		var xz: PackedStringArray = a.pos.split(",")
		player.position = Vector3(float(xz[0]), 0.2, float(xz[1]))
	if a.has("yaw"):
		player.rotation.y = deg_to_rad(float(a.yaw))
	if a.has("pitch"):
		pivot.rotation.x = deg_to_rad(float(a.pitch))
	if a.has("autostart"):
		begin_game()
	if a.has("shot"):
		await get_tree().create_timer(float(a.get("t", "3"))).timeout
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(a.shot)
		get_tree().quit()

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
	B.box(body_mesh, Vector3(0.5, 0.6, 0.3), Vector3(0, 1.2, 0), Color(0.4, 0.4, 0.4))
	B.box(body_mesh, Vector3(0.35, 0.35, 0.35), Vector3(0, 1.7, 0), Color(0.9, 0.7, 0.55))
	B.box(body_mesh, Vector3(0.5, 0.8, 0.3), Vector3(0, 0.4, 0), Color(0.15, 0.25, 0.5))
	B.box(body_mesh, Vector3(0.45, 0.5, 0.2), Vector3(0, 1.2, 0.22), Color(0.7, 0.5, 0.1))  # backpack
	body_mesh.visible = false

	pivot = Node3D.new()
	pivot.position.y = 1.6
	player.add_child(pivot)
	cam = Camera3D.new()
	cam.fov = 85
	cam.far = 300
	pivot.add_child(cam)

	gun = Node3D.new()
	cam.add_child(gun)
	gun.position = Vector3(0.25, -0.22, -0.45)
	gun.scale = Vector3.ONE * 0.6
	B.box(gun, Vector3(0.08, 0.1, 0.4), Vector3.ZERO, Color(0.2, 0.2, 0.22))
	B.box(gun, Vector3(0.07, 0.16, 0.08), Vector3(0, -0.1, 0.12), Color(0.35, 0.2, 0.1))
	B.box(gun, Vector3(0.12, 0.12, 0.12), Vector3(0, -0.05, 0.22), Color(0.9, 0.7, 0.55))  # hand

func begin_game() -> void:
	if dead:
		get_tree().reload_current_scene()
	elif not started:
		started = true
		hud.clear_message()
		next_wave()

func toggle_view() -> void:
	third_person = not third_person
	body_mesh.visible = third_person
	gun.visible = not third_person
	cam.position = Vector3(0.6, 0.4, 3.0) if third_person else Vector3.ZERO

func start_reload() -> void:
	if reloading <= 0 and ammo < MAX_AMMO and started and not dead:
		reloading = 0.9
		fx.on_reload()

func _process(dt: float) -> void:
	# Runs every rendered frame (not the fixed 60 Hz physics tick) so motion stays
	# smooth on 90/120 Hz phone screens.
	controls.game_active = started and not dead
	var look: Vector2 = controls.take_look()
	if not started or dead:
		return
	player.rotate_y(-look.x)
	pivot.rotation.x = clamp(pivot.rotation.x - look.y, -1.4, 1.4)

	# movement
	var inp: Vector2 = controls.move
	var dir := player.transform.basis * Vector3(inp.x, 0, inp.y)
	var speed := 9.0
	dash_cd -= dt
	if dash_req and dash_cd <= 0 and dir != Vector3.ZERO:
		dash_t = 0.18
		dash_cd = 0.8
		fx.on_dash()
	dash_req = false
	if dash_t > 0:
		dash_t -= dt
		speed = 28.0
	# ease toward the target speed instead of snapping (dashes stay instant)
	var target := Vector2(dir.x, dir.z) * speed
	move_vel = target if dash_t > 0 else move_vel.lerp(target, 1.0 - exp(-14.0 * dt))
	player.velocity.x = move_vel.x
	player.velocity.z = move_vel.y
	if player.is_on_floor():
		if controls.jump:
			player.velocity.y = 8.0
	else:
		player.velocity.y -= 22.0 * dt
	var was_air := not player.is_on_floor()
	var vy := player.velocity.y
	player.move_and_slide()
	if was_air and player.is_on_floor():
		fx.on_land(-vy)
	var cl: Vector3 = L.clamp_to_streets(player.position, 0.5)
	player.position.x = cl.x
	player.position.z = cl.z
	if player.position.y < -5:
		player.position.y = 1.0

	# shooting
	fire_cd -= dt
	if reloading > 0:
		reloading -= dt
		gun.rotation.x = -0.8
		if reloading <= 0:
			ammo = MAX_AMMO
			gun.rotation.x = 0
	elif controls.fire and fire_cd <= 0:
		if ammo > 0:
			shoot()
		else:
			start_reload()
	recoil = lerp(recoil, 0.0, dt * 12)
	gun.position.z = -0.45 + recoil * 0.15
	if reloading <= 0:
		gun.rotation.x = recoil * 0.5
	# head bob + shake
	var t := Time.get_ticks_msec() / 1000.0
	var bob := sin(t * 14) * 0.04 * dir.length() if player.is_on_floor() else 0.0
	pivot.position = Vector3(0, 1.6 + bob, 0) + fx.shake_offset()

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
	hud.update_stats({"hp": hp, "ammo": ammo, "max_ammo": MAX_AMMO, "reloading": reloading > 0,
		"score": score, "wave": wave, "combo": combo, "hurt": clamp(hurt_flash / 0.3, 0.0, 1.0),
		"dash_ready": clamp(1.0 - dash_cd / 0.8, 0.0, 1.0)})

func shoot() -> void:
	ammo -= 1
	fire_cd = 0.16
	recoil = 1.0
	fx.on_shoot()
	var space := get_world_3d().direct_space_state
	# shotgun-ish: 5 pellets
	for i in 5:
		var spread := Vector3(randf_range(-1, 1), randf_range(-1, 1), 0) * 0.03 if i > 0 else Vector3.ZERO
		var from := cam.global_position
		var fwd := (-cam.global_transform.basis.z + cam.global_transform.basis * spread).normalized()
		var q := PhysicsRayQueryParameters3D.create(from, from + fwd * 80)
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
			fx.impact(hit.position, hit.normal)

# ---------------- ZOMBIES ----------------
func next_wave() -> void:
	wave += 1
	to_spawn = 4 + wave * 3
	spawn_t = 1.5
	hp = min(hp + 25, 100)
	hud.on_wave(wave)
	fx.on_wave(wave)

func spawn_zombie() -> void:
	var root := Node3D.new()
	add_child(root)
	# prefer spawn points that are not right on top of the player
	var pts: Array = L.spawn_points().filter(func(p): return p.distance_to(player.position) > 12.0)
	if pts.is_empty():
		pts = L.spawn_points()
	root.position = L.clamp_to_streets(pts.pick_random() + Vector3(randf_range(-1.5, 1.5), 0, randf_range(-1.5, 1.5)), 1.0)
	fx.zombie_spawn(root.position)
	var big := randf() < 0.12 and wave > 2
	var s := 1.6 if big else randf_range(0.85, 1.1)
	root.scale = Vector3.ONE * s
	var skin := Color(0.5, 0.7, 0.35).lerp(Color(0.4, 0.55, 0.5), randf())
	var parts := Node3D.new()
	root.add_child(parts)
	B.box(parts, Vector3(0.25, 0.8, 0.25), Vector3(-0.15, 0.4, 0), Color(0.2, 0.3, 0.55))
	B.box(parts, Vector3(0.25, 0.8, 0.25), Vector3(0.15, 0.4, 0), Color(0.2, 0.3, 0.55))
	B.box(parts, Vector3(0.6, 0.7, 0.35), Vector3(0, 1.15, 0), SHIRTS.pick_random())
	var arm_l := B.box(parts, Vector3(0.18, 0.18, 0.7), Vector3(-0.38, 1.35, -0.35), skin)
	var arm_r := B.box(parts, Vector3(0.18, 0.18, 0.7), Vector3(0.38, 1.35, -0.35), skin)
	var head := Node3D.new()
	head.position = Vector3(0, 1.75, 0)
	parts.add_child(head)
	B.box(head, Vector3(0.45, 0.45, 0.45), Vector3.ZERO, skin)
	B.box(head, Vector3(0.08, 0.08, 0.02), Vector3(-0.1, 0.05, -0.23), Color(1, 1, 0.3))
	B.box(head, Vector3(0.08, 0.08, 0.02), Vector3(0.1, 0.03, -0.23), Color(1, 1, 0.3))
	B.box(head, Vector3(0.25, 0.06, 0.02), Vector3(0, -0.12, -0.23), Color(0.2, 0.05, 0.05))
	B.box(head, Vector3(0.5, 0.12, 0.5), Vector3(0, 0.25, 0), Color(0.15, 0.1, 0.05))  # hair
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
	fx.zombie_hit(p, dir, headshot)
	hud.on_hit(headshot)
	z.root.position += Vector3(dir.x, 0, dir.z).normalized() * 0.25  # knockback
	if z.hp <= 0:
		z.dead = true
		combo += 1
		combo_t = 2.0
		var pts: int = (150 if headshot else 100) * combo * (3 if z.big else 1)
		score += pts
		hud.on_kill(pts, headshot)
		fx.zombie_death(z.head.global_position, z.skin, headshot)
		if headshot:
			z.head.visible = false
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
		# head for the player, going round the corner blocks via the intersection
		var goal: Vector3 = L.nav_target(root.position, player.position)
		var to: Vector3 = goal - root.position
		to.y = 0
		var to_player: Vector3 = player.position - root.position
		to_player.y = 0
		var d := to_player.length()
		if to.length() > 0.1:
			root.look_at(root.global_position - to.normalized(), Vector3.UP)
		# separation so they don't stack
		var push := Vector3.ZERO
		for o in zombies:
			if o != z:
				var off: Vector3 = root.position - o.root.position
				off.y = 0
				if off.length() < 0.8 and off.length() > 0.001:
					push += off.normalized() * (0.8 - off.length())
		if d > 1.1 and to.length() > 0.05:
			root.position += to.normalized() * z.speed * dt + push * 3 * dt
			# slide around big props (cars, bus, barriers)
			for ob in obstacles:
				var od: Vector3 = root.position - ob.pos
				od.y = 0
				var rr: float = ob.radius + 0.35
				var ol := od.length()
				if ol < rr and ol > 0.001:
					var n := od / ol
					# push out, plus a sideways nudge so they don't jam nose-first into the prop
					var side := Vector3(-n.z, 0, n.x)
					if side.dot(to) < 0:
						side = -side
					root.position += n * (rr - ol) + side * z.speed * dt * 0.6
			root.position = L.clamp_to_streets(root.position, 0.6)
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
			if not _god:
				hp -= dmg
			hurt_flash = 0.3
			fx.player_hurt(dmg)
			if hp <= 0:
				dead = true
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				hud.show_game_over(score, wave)
