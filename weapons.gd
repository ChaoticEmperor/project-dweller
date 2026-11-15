extends Node
# The player's guns: which ones they carry, firing, reloading, switching, and the
# first-person gun model. main.gd calls update(dt) every frame while playing; everything
# else in the game talks to weapons through the functions and signals below (see SPECS.md).
const Models = preload("res://models.gd")

signal fired(id: String)
signal weapon_changed(id: String)
signal picked_up(id: String)

var main: Node3D
var gun: Node3D              # first-person model of the current weapon (child of the camera)
var current := "shotgun"     # id of the weapon in hand
var owned: Array = ["shotgun"]
var ammo := 8                # rounds in the current weapon
var reloading := 0.0         # seconds left of the current reload, 0 = not reloading
var _fire_cd := 0.0
var _recoil := 0.0
var _pump_t := 0.0
var _visible := true

func setup(main_node: Node3D) -> void:
	main = main_node
	gun = Models.make_gun()
	main.cam.add_child(gun)
	gun.position = Vector3(0.25, -0.22, -0.45)
	gun.scale = Vector3.ONE * 0.6
	main.fx.attach_gun(gun)
	ammo = max_ammo()

func max_ammo() -> int:
	return int(main.stat("max_ammo"))

func reload_frac() -> float:
	return clamp(1.0 - reloading / main.stat("reload_time"), 0.0, 1.0)

# What the HUD needs to draw the weapon panel.
func hud_info() -> Dictionary:
	return {"id": current, "name": "BOOMSTICK", "ammo": ammo, "max_ammo": max_ammo(), "reserve": -1,
		"slots": owned, "reloading": reloading > 0, "reload_frac": reload_frac()}

# Add a weapon to the inventory (or top it up if already owned) and switch to it.
func give(id: String, _rounds := -1) -> void:
	if not owned.has(id):
		owned.append(id)
	picked_up.emit(id)
	switch_to(id)

func has(id: String) -> bool:
	return owned.has(id)

func switch_to(id: String) -> void:
	if owned.has(id) and id != current:
		current = id
		weapon_changed.emit(id)

func next() -> void:
	switch_to(owned[(owned.find(current) + 1) % owned.size()])

# Fill the current weapon (used after an upgrade pick).
func refill() -> void:
	ammo = max_ammo()

# Hide the gun model in third-person view.
func set_view_visible(on: bool) -> void:
	_visible = on
	gun.visible = on

func start_reload() -> void:
	if reloading <= 0 and ammo < max_ammo() and main.started and not main.dead:
		reloading = main.stat("reload_time")
		main.fx.on_reload()
		main.sfx.play("reload")

func update(dt: float) -> void:
	var controls = main.controls
	_fire_cd -= dt
	if reloading > 0:
		reloading -= dt
		gun.rotation.x = -0.8
		if reloading <= 0:
			ammo = max_ammo()
			gun.rotation.x = 0
			main.sfx.play("pump")
	elif controls.fire and _fire_cd <= 0:
		if ammo > 0:
			_shoot()
		else:
			main.sfx.play("empty")
			start_reload()
	_recoil = lerp(_recoil, 0.0, dt * 12)
	if _pump_t > 0:
		_pump_t = max(_pump_t - dt, 0.0)
		Models.gun_pump(gun, sin(PI * (1.0 - _pump_t / 0.25)))
	gun.position.z = -0.45 + _recoil * 0.15
	if reloading <= 0:
		gun.rotation.x = _recoil * 0.5

func _shoot() -> void:
	var cam: Camera3D = main.cam
	ammo -= 1
	_fire_cd = main.stat("fire_cd")
	_recoil = 1.0
	_pump_t = 0.25
	main.fx.on_shoot()
	main.sfx.play("shoot", randf_range(0.95, 1.05))
	fired.emit(current)
	var space: PhysicsDirectSpaceState3D = main.get_world_3d().direct_space_state
	var boomed := false
	for i in int(main.stat("pellets")):
		var spread: Vector3 = Vector3(randf_range(-1, 1), randf_range(-1, 1), 0) * main.stat("spread") if i > 0 else Vector3.ZERO
		var from := cam.global_position
		var fwd: Vector3 = (-cam.global_transform.basis.z + cam.global_transform.basis * spread).normalized()
		var q := PhysicsRayQueryParameters3D.create(from, from + fwd * 80)
		q.exclude = [main.player.get_rid()]
		q.collide_with_areas = true
		var hit: Dictionary = space.intersect_ray(q)
		if hit.is_empty():
			continue
		var col: Object = hit.collider
		if col is Area3D and col.has_meta("zombie"):
			var head: bool = col.get_meta("head")
			main.zombies.hit(col.get_meta("zombie"), main.stat("damage") * (main.stat("head_mult") if head else 1.0), head, hit.position, fwd)
		else:
			main.fx.impact(hit.position, hit.normal)
		# explosive pellets upgrade: one small blast per shot, at the first thing hit
		if main.stat("explosive_radius") > 0 and not boomed:
			boomed = true
			main.zombies.damage_radius(hit.position, main.stat("explosive_radius"), main.stat("damage"))
			main.fx.explosion(hit.position, main.stat("explosive_radius"))
			main.sfx.play_at("explode", hit.position)
