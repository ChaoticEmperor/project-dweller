extends Node3D
# Zombie Bonk - a fast, goofy, pixelated zombie shooter.
# main.gd owns the game rules that tie everything together: the player, the gun,
# scoring, and the flow of a run (waves, rest, upgrade draft, game over).
# Everything else lives in a module (see SPECS.md for how they talk to each other):
#   world.gd    - the city (roads, buildings, subway entrances)
#   clutter.gd  - street props
#   fx.gd       - lighting, sky and visual effects
#   hud.gd      - 2D UI and touch-control visuals
#   controls.gd - keyboard/mouse/touch input
#   zombies.gd  - zombie types, spawning, wave pacing, movement, attacks
#   models.gd / zombie_rig.gd - how characters and the gun look and animate
#   sfx.gd      - sound, synthesised in code
#   weapons.gd  - the guns: inventory, firing, reloading, the first-person gun model
#   drops.gd    - weapon crates and airdrops
#   upgrades.gd - between-wave upgrades (modifiers on the stats below)
#   nav.gd      - zombie pathfinding (flow field)
#   layout.gd / build.gd - shared map dimensions and box helpers
const B = preload("res://build.gd")
const L = preload("res://layout.gd")
const Models = preload("res://models.gd")

# Base values of every tunable number. Always read them through stat() so upgrades apply.
const BASE := {
	"pellets": 5.0, "spread": 0.03, "damage": 25.0, "head_mult": 2.4, "fire_cd": 0.16,
	"reload_time": 0.9, "max_ammo": 8.0, "move_speed": 9.0, "dash_cd": 0.8, "dash_speed": 28.0,
	"max_hp": 100.0, "wave_heal": 25.0, "heal_on_headshot": 0.0, "shove_cd": 1.2, "shove_reach": 3.5,
	"shove_arc": 80.0, "shove_force": 9.0, "shove_damage": 0.0, "explosive_radius": 0.0,
	"score_mult": 1.0, "combo_time": 2.0,
}

var world: Node3D
var clutter: Node3D
var fx: Node3D
var hud: CanvasLayer
var controls: Node
var zombies: Node3D
var sfx: Node
var upgrades: RefCounted
var nav: RefCounted
var weapons: Node
var drops: Node3D

signal wave_started(n: int)
signal wave_ended(n: int)

var player: CharacterBody3D
var cam: Camera3D
var pivot: Node3D
var body_mesh: Node3D

var hp := 100.0
var score := 0
var combo := 0
var combo_t := 0.0
var wave := 0
var dash_t := 0.0
var dash_cd := 0.0
var dash_req := false
var shove_cd := 0.0
var third_person := false
var dead := false
var hurt_flash := 0.0
var started := false
var drafting := false      # the upgrade cards are on screen
var rest_t := -1.0         # >0 while resting between waves
var move_vel := Vector2.ZERO
var air_t := 0.0
var hi_res := false
var rng := RandomNumberGenerator.new()

func stat(name: String) -> float:
	return upgrades.stat(name, BASE[name])

func _ready() -> void:
	randomize()
	rng.randomize()
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
	fx.add_street_lights(clutter.lamp_positions())
	fx.add_subway_globes([Vector3(6.25, 3.3, 17.15), Vector3(8.75, 3.3, 17.15), Vector3(-6.25, 3.3, -17.15), Vector3(-8.75, 3.3, -17.15)])
	nav = preload("res://nav.gd").new()
	var stairs: Array = []  # the two subway stairwells are solid too
	for e in L.SUBWAY_ENTRANCES:
		stairs.append(Rect2(e.x - 1.5, e.z - 3.0, 3.0, 6.0))
	nav.build(clutter.obstacles(), stairs)
	sfx = preload("res://sfx.gd").new()
	add_child(sfx)
	sfx.setup()
	sfx.set_listener(cam)
	upgrades = preload("res://upgrades.gd").new()
	upgrades.reset()
	weapons = preload("res://weapons.gd").new()
	add_child(weapons)
	weapons.setup(self)
	drops = preload("res://drops.gd").new()
	add_child(drops)
	drops.setup(self)
	zombies = preload("res://zombies.gd").new()
	add_child(zombies)
	zombies.setup(self)
	zombies.zombie_hit.connect(_on_zombie_hit)
	zombies.zombie_killed.connect(_on_zombie_killed)
	zombies.player_hit.connect(_on_player_hit)
	zombies.wave_cleared.connect(_on_wave_cleared)
	hud = preload("res://hud.gd").new()
	add_child(hud)
	hud.build()
	controls = preload("res://controls.gd").new()
	add_child(controls)
	controls.setup(hud)
	controls.dash.connect(func(): dash_req = true)
	controls.reload.connect(func(): weapons.start_reload())
	controls.toggle_view.connect(toggle_view)
	controls.start_pressed.connect(begin_game)
	controls.shove.connect(do_shove)
	controls.toggle_quality.connect(toggle_quality)
	controls.toggle_mute.connect(func(): if sfx.has_method("toggle_mute"): sfx.toggle_mute())
	Models.prewarm()  # build the zombie meshes now so the first spawns do not hitch
	hud.show_title()
	_debug_args()

# Developer/test switches, passed after `--` on the command line (never present on the web):
#   --autostart          start the game without a click
#   --god                player takes no damage
#   --pos=x,z            teleport the player       --yaw=deg  --pitch=deg   aim the camera
#   --shot=/abs/file.png --t=seconds               save a screenshot after t seconds, then quit
#   --navtest            print every zombie that fails to make progress toward the player
#   --wave=n             start at wave n           --hires   start at 960x540
var _god := false
var _navtest := false
var _nav_t := 0.0
func _debug_args() -> void:
	var a := {}
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=")
		a[kv[0]] = kv[1] if kv.size() > 1 else ""
	_god = a.has("god")
	_navtest = a.has("navtest")
	if a.has("hires"):
		toggle_quality()
	if a.has("wave"):
		wave = int(a.wave) - 1
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

func _nav_check(dt: float) -> void:
	_nav_t += dt
	if _nav_t < 3.0:
		return
	_nav_t = 0.0
	var stuck := 0
	for z in zombies.list:
		var p: Vector3 = z.rig.position
		var far: bool = p.distance_to(player.position) > 2.5
		# only a zombie that has barely moved for two checks in a row (6 s) counts;
		# one that is circling the player can pass near its old spot once by chance
		if z.has("nav_last") and far and p.distance_to(z.nav_last) < 0.6:
			z.nav_n = z.get("nav_n", 0) + 1
			if z.nav_n >= 2:
				stuck += 1
				print("STUCK at ", p.snapped(Vector3(0.1, 0.1, 0.1)), " type=", z.type)
		else:
			z.nav_n = 0
		z.nav_last = p
	print("NAV zombies=", zombies.list.size(), " stuck=", stuck, " wave=", wave)

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
	body_mesh = Models.make_player_body()
	player.add_child(body_mesh)
	body_mesh.visible = false
	pivot = Node3D.new()
	pivot.position.y = 1.6
	player.add_child(pivot)
	cam = Camera3D.new()
	cam.fov = 85
	cam.far = 300
	pivot.add_child(cam)

func begin_game() -> void:
	if dead:
		get_tree().reload_current_scene()
	elif not started:
		started = true
		hud.clear_message()
		sfx.set_music(true)
		next_wave()

func toggle_view() -> void:
	third_person = not third_person
	body_mesh.visible = third_person
	weapons.set_view_visible(not third_person)
	cam.position = Vector3(0.6, 0.4, 3.0) if third_person else Vector3.ZERO

# Switch between the chunky 640x360 look and a sharper 960x540.
func toggle_quality() -> void:
	hi_res = not hi_res
	get_window().content_scale_size = Vector2i(960, 540) if hi_res else Vector2i(640, 360)
	hud.set_quality_label("540P" if hi_res else "360P")

func do_shove() -> void:
	if not started or dead or drafting or shove_cd > 0:
		return
	shove_cd = stat("shove_cd")
	var fwd := -player.global_transform.basis.z
	var n: int = zombies.shove(player.position, fwd, stat("shove_reach"), stat("shove_arc"), stat("shove_force"))
	if stat("shove_damage") > 0 and n > 0:
		zombies.damage_radius(player.position + fwd * 1.5, stat("shove_reach"), stat("shove_damage"))
	fx.on_shove(n)
	sfx.play("shove")

func next_wave() -> void:
	wave += 1
	hp = min(hp + stat("wave_heal"), stat("max_hp"))
	hud.on_wave(wave)
	fx.on_wave(wave)
	sfx.play("wave_start")
	zombies.start_wave(wave)
	wave_started.emit(wave)

func _on_wave_cleared(_n: int) -> void:
	sfx.play("wave_clear")
	wave_ended.emit(_n)
	rest_t = 2.0  # short breather, then the upgrade draft (if any), then the next wave

func _start_draft() -> void:
	var cards: Array = upgrades.roll(3, rng)
	if cards.is_empty():
		next_wave()
		return
	drafting = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	hud.show_upgrades(cards, _on_upgrade_picked)

func _on_upgrade_picked(id: String) -> void:
	if not drafting:
		return
	drafting = false
	upgrades.take(id)
	sfx.play("upgrade_pick")
	fx.on_upgrade()
	weapons.refill()
	hp = min(hp, stat("max_hp"))  # an upgrade can lower max health
	if not controls.touch_mode:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	next_wave()

func _on_zombie_hit(pos: Vector3, dir: Vector3, headshot: bool) -> void:
	fx.zombie_hit(pos, dir, headshot)
	hud.on_hit(headshot)
	sfx.play("headshot" if headshot else "hit", randf_range(0.94, 1.06))

func _on_zombie_killed(info: Dictionary) -> void:
	combo += 1
	combo_t = stat("combo_time")
	var pts := int((150 if info.headshot else 100) * combo * info.score_mult * stat("score_mult"))
	score += pts
	hud.on_kill(pts, info.headshot)
	fx.zombie_death(info.head_pos, info.skin, info.headshot)
	sfx.play("kill", 1.0 + min(combo, 12) * 0.06)  # rising pitch as the combo grows
	if info.headshot and stat("heal_on_headshot") > 0:
		hp = min(hp + stat("heal_on_headshot"), stat("max_hp"))

func _on_player_hit(dmg: float, _from: Vector3) -> void:
	if dead:
		return
	if not _god:
		hp -= dmg
	hurt_flash = 0.3
	fx.player_hurt(dmg)
	sfx.play("hurt")
	if hp <= 0:
		dead = true
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		sfx.play("death_player")
		sfx.set_music(false)
		hud.show_game_over(score, wave)

func _process(dt: float) -> void:
	# Runs every rendered frame (not the fixed 60 Hz physics tick) so motion stays
	# smooth on 90/120 Hz phone screens.
	controls.game_active = started and not dead and not drafting
	var look: Vector2 = controls.take_look()
	if not started or dead or drafting:
		return
	player.rotate_y(-look.x)
	pivot.rotation.x = clamp(pivot.rotation.x - look.y, -1.4, 1.4)

	# movement
	var inp: Vector2 = controls.move
	var dir := player.transform.basis * Vector3(inp.x, 0, inp.y)
	var speed := stat("move_speed")
	dash_cd -= dt
	shove_cd -= dt
	if dash_req and dash_cd <= 0:
		if dir == Vector3.ZERO:
			dir = -player.transform.basis.z  # standing still: dash forward
		dash_t = 0.18
		dash_cd = stat("dash_cd")
		fx.on_dash()
		sfx.play("dash")
	dash_req = false
	if dash_t > 0:
		dash_t -= dt
		speed = stat("dash_speed")
	# ease toward the target speed instead of snapping (dashes stay instant)
	var target := Vector2(dir.x, dir.z) * speed
	move_vel = target if dash_t > 0 else move_vel.lerp(target, 1.0 - exp(-14.0 * dt))
	player.velocity.x = move_vel.x
	player.velocity.z = move_vel.y
	# coyote time: a jump still works for a moment after stepping off something
	air_t = 0.0 if player.is_on_floor() else air_t + dt
	if controls.jump and air_t < 0.1:
		player.velocity.y = 8.0
		air_t = 1.0
		sfx.play("jump")
	if not player.is_on_floor():
		player.velocity.y -= 22.0 * dt
	var was_air := not player.is_on_floor()
	var vy := player.velocity.y
	player.move_and_slide()
	if was_air and player.is_on_floor():
		fx.on_land(-vy)
		sfx.play("land")
	var cl: Vector3 = L.clamp_to_streets(player.position, 0.5)
	player.position.x = cl.x
	player.position.z = cl.z
	if player.position.y < -5:
		player.position.y = 1.0

	weapons.update(dt)
	drops.update(dt)
	# head bob + shake
	var t := Time.get_ticks_msec() / 1000.0
	var bob := sin(t * 14) * 0.04 * dir.length() if player.is_on_floor() else 0.0
	pivot.position = Vector3(0, 1.6 + bob, 0) + fx.shake_offset()

	combo_t -= dt
	if combo_t <= 0:
		combo = 0

	# run flow: rest after a wave, then the upgrade draft, then the next wave
	if rest_t > 0:
		rest_t -= dt
		if rest_t <= 0:
			_start_draft()

	nav.update(player.position)
	zombies.update(dt)
	sfx.set_intensity(clamp(max(zombies.list.size() / 24.0, zombies.intensity), 0.0, 1.0))
	if _navtest:
		_nav_check(dt)
	hurt_flash = max(hurt_flash - dt, 0)
	hud.update_stats({"hp": hp, "max_hp": stat("max_hp"), "ammo": weapons.ammo, "max_ammo": weapons.max_ammo(),
		"reloading": weapons.reloading > 0, "reload_frac": weapons.reload_frac(), "weapon": weapons.hud_info(),
		"score": score, "wave": wave, "combo": combo, "combo_frac": clamp(combo_t / stat("combo_time"), 0.0, 1.0),
		"hurt": clamp(hurt_flash / 0.3, 0.0, 1.0),
		"dash_ready": clamp(1.0 - dash_cd / stat("dash_cd"), 0.0, 1.0),
		"shove_ready": clamp(1.0 - shove_cd / stat("shove_cd"), 0.0, 1.0),
		"zombies_left": zombies.alive_count()})
