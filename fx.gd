extends Node3D
# Lighting, sky, fog and all visual effects (muzzle flash, tracers, impacts, goo, gibs, camera shake).
#
# Built for the Compatibility renderer (WebGL2) and phones:
#   - no shadows, a handful of real lights (3 pooled street-lamp lights, 2 subway globes,
#     1 muzzle flash, 1 "pop" flash) - everything else is faked with additive sprites
#   - every particle lives in one of six fixed-size MultiMesh pools that are integrated by
#     hand, so effects never allocate nodes during play and cost ~13 draw calls in total
#   - camera feel: weapon recoil and the shove are critically damped springs (directional, no
#     jitter); only explosions / getting hurt / headshot pops add a short decaying shake.
#     Everything the camera does is multiplied by `shake_scale` (0 = a perfectly still camera).
#   - all pools are drawn from the first frame (dead instances are zero-sized), so their
#     shaders are compiled on the title screen, not on the first shot
const L = preload("res://layout.gd")

const SUN_DIR := Vector3(0.10, 0.31, -0.945)     # direction *towards* the sun: low, down the avenue (-Z)
const LAMP_COL := Color(1.0, 0.72, 0.38)
const GLOBE_COL := Color(0.25, 1.0, 0.45)
const GOO := Color(0.42, 0.95, 0.18)
const LAMP_LIGHTS := 3                            # real lights shared between the nearest lamps
const LAMP_ENERGY := 3.0

# ---------------------------------------------------------------- particle pool
# A fixed ring of instances in one MultiMesh. Oldest particle is recycled when full.
class Pool:
	var mm := MultiMesh.new()
	var node := MultiMeshInstance3D.new()
	var n := 0
	var buf := PackedFloat32Array()
	var head := 0
	var live := 0
	var additive := false          # fade by darkening the colour instead of shrinking
	var life := PackedFloat32Array()
	var maxl := PackedFloat32Array()
	var grav := PackedFloat32Array()
	var drag := PackedFloat32Array()
	var grow := PackedFloat32Array()
	var fade := PackedFloat32Array()
	var spin := PackedFloat32Array()
	var ang := PackedFloat32Array()
	var pos := PackedVector3Array()
	var vel := PackedVector3Array()
	var axis := PackedVector3Array()
	var col := PackedColorArray()
	var fresh := PackedByteArray()  # 1 until drawn once, so even a 1-frame effect shows at low fps
	var kind := PackedInt32Array()  # 0 free flight, 1 bounces on the ground, 2 turns into a flat splat
	var bas: Array[Basis] = []

	func _init(parent: Node, mesh: Mesh, material: Material, count: int, is_additive: bool) -> void:
		n = count
		additive = is_additive
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = mesh
		mm.instance_count = n
		if "custom_aabb" in mm:
			mm.set("custom_aabb", AABB(Vector3(-200, -20, -200), Vector3(400, 200, 400)))
		buf.resize(n * 16)
		buf.fill(0.0)
		mm.buffer = buf
		life.resize(n)
		maxl.resize(n)
		grav.resize(n)
		drag.resize(n)
		grow.resize(n)
		fade.resize(n)
		spin.resize(n)
		ang.resize(n)
		pos.resize(n)
		vel.resize(n)
		axis.resize(n)
		col.resize(n)
		kind.resize(n)
		fresh.resize(n)
		bas.resize(n)
		node.multimesh = mm
		node.material_override = material
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.custom_aabb = AABB(Vector3(-200, -20, -200), Vector3(400, 200, 400))
		parent.add_child(node)

	func emit(p: Vector3, v: Vector3, b: Basis, c: Color, lifetime: float, gravity := 0.0, dragk := 0.0,
			growk := 0.0, fadek := 0.3, spink := 0.0, k := 0) -> void:
		var i := head
		head = (head + 1) % n
		if life[i] <= 0.0:
			live += 1
		life[i] = lifetime
		maxl[i] = lifetime
		grav[i] = gravity
		drag[i] = dragk
		grow[i] = growk
		fade[i] = fadek
		spin[i] = spink
		ang[i] = 0.0
		pos[i] = p
		vel[i] = v
		col[i] = c
		kind[i] = k
		fresh[i] = 1
		bas[i] = b
		if spink != 0.0:
			axis[i] = Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5).normalized()

	static func floor_y(p: Vector3) -> float:
		# roads repeat every block in the endless city; everything else walkable is raised sidewalk
		var lay = preload("res://layout.gd")
		return 0.0 if (absf(lay.lat(p.x)) <= 6.0 or absf(lay.lat(p.z)) <= 6.0) else 0.15

	func update(dt: float) -> void:
		if live == 0:
			return
		for i in n:
			var l := life[i]
			if l <= 0.0:
				continue
			if fresh[i] == 1:
				fresh[i] = 0
			else:
				l -= dt
			var o := i * 16
			if l <= 0.0:
				life[i] = 0.0
				live -= 1
				for j in 12:
					buf[o + j] = 0.0
				continue
			life[i] = l
			var t := 1.0 - l / maxl[i]
			var v := vel[i]
			var p := pos[i]
			var b := bas[i]
			if v != Vector3.ZERO or grav[i] != 0.0:
				v.y -= grav[i] * dt
				v *= maxf(0.0, 1.0 - drag[i] * dt)
				p += v * dt
				if kind[i] > 0 and v.y < 0.0:
					var fl := floor_y(p) + 0.04
					if p.y < fl:
						p.y = fl
						if kind[i] == 2:
							# goo lands: becomes a flat splat that lingers
							var s := b.x.length() * randf_range(2.2, 3.4)
							b = Basis.from_scale(Vector3(s, 0.03, s))
							bas[i] = b
							p.y = fl - 0.02 + randf() * 0.012
							v = Vector3.ZERO
							grav[i] = 0.0
							spin[i] = 0.0
							kind[i] = 0
							life[i] = 2.6
							maxl[i] = 2.6
							fade[i] = 0.25
							t = 0.0
						else:
							v = Vector3(v.x * 0.55, -v.y * 0.38, v.z * 0.55)
							spin[i] *= 0.5
							if v.y < 0.6:
								v = Vector3.ZERO
								grav[i] = 0.0
								spin[i] = 0.0
								kind[i] = 0
				vel[i] = v
				pos[i] = p
			if spin[i] != 0.0:
				ang[i] += spin[i] * dt
				b = Basis(axis[i], ang[i]) * b
			var f := minf(1.0, (1.0 - t) / fade[i])
			var c := col[i]
			if additive:
				b *= 1.0 + grow[i] * t
				c = Color(c.r * f, c.g * f, c.b * f, 1.0)
			else:
				b *= (1.0 + grow[i] * t) * f
			var x := b.x
			var y := b.y
			var z := b.z
			buf[o] = x.x
			buf[o + 1] = y.x
			buf[o + 2] = z.x
			buf[o + 3] = p.x
			buf[o + 4] = x.y
			buf[o + 5] = y.y
			buf[o + 6] = z.y
			buf[o + 7] = p.y
			buf[o + 8] = x.z
			buf[o + 9] = y.z
			buf[o + 10] = z.z
			buf[o + 11] = p.z
			buf[o + 12] = c.r
			buf[o + 13] = c.g
			buf[o + 14] = c.b
			buf[o + 15] = c.a
		mm.buffer = buf

# ---------------------------------------------------------------- state
var cam: Camera3D
var gun: Node3D
var env: Environment
var sun: DirectionalLight3D
var base_fov := 85.0

var lit: Pool      # shaded cubes: gibs, shells, masonry chips
var goo: Pool      # unshaded cubes: goo blobs + splats, dust/smoke puffs
var add: Pool      # additive cubes: sparks, tracers
var glow: Pool     # additive soft billboards: flashes
var ring: Pool     # additive ring billboards: headshot pop, blast shock rings
var gring: Pool    # additive rings lying flat on the ground: blast / shove / upgrade shockwaves

var flash: MeshInstance3D
var flash_t := 0.0
var flash_new := false
var muzzle_light: OmniLight3D
var pop_light: OmniLight3D
var pop_t := 0.0
var warm := 6      # frames during which hidden effects are kept drawn to compile their shaders

# Camera feel. Public knobs:
var shake_scale := 1.0        # multiplies every camera effect (kick, shake, lunge, fov punch); 0 = off
var hit_stop_enabled := true  # allow the tiny freeze on headshot kills

const REC_W := 22.0           # recoil spring stiffness (rad/s); critically damped, back to rest in ~0.25 s
const REC_PITCH := 0.03       # radians of muzzle climb at the peak of a single shot
const REC_BACK := 0.04        # metres the camera is pushed back at that peak
const REC_MAX := 1.8          # rapid fire stacks up to about this many "single shots" and no further
const SHV_W := 13.0           # shove lunge spring
const FIRE_COL := Color(1.0, 0.55, 0.15)
const TOXIC_COL := Color(0.55, 1.0, 0.2)
const BIG_BLAST := 3.2        # explosions with a larger radius are the toxic (bloater) kind

var trauma := 0.0
var rec := 0.0     # recoil spring position (1 = peak of one shot) and velocity
var rec_v := 0.0
var shv := 0.0     # shove lunge spring
var shv_v := 0.0
var shove_t := -1.0           # gun shove animation clock, <0 = idle
var gun_base := Vector3.ZERO  # gun rest position (main owns position.z / rotation.x, fx only touches x/y and yaw/roll)
var boom_t := -10.0           # clock time of the last explosion (rapid blasts are thinned out)
var pop_e := 3.0
var pop_dur := 0.16
var fov_add := 0.0
var _hs_on := false           # hit-stop in progress (Engine.time_scale lowered)
var _hs_until := 0            # real time (usec) at which it ends
var _hs_ended := 0
var roll := 0.0    # hurt roll impulse
var dip := 0.0     # landing dip
var punch := 0.0   # dash fov punch
var clock := 0.0

var shot_pending := false
var shot_tracers := 0
var shot_expect := 5          # pellets of the current shot; ones that hit nothing get a tracer into the haze
var muzzle_pos := Vector3.ZERO
var muzzle_local := Vector3(0, 0, -0.3)   # barrel tip in the gun node's space (set_muzzle)
var tr_col := Color(0.75, 0.6, 0.3)       # look of the current shot's tracers
var tr_w := 0.035

var lamps: Array[Vector3] = []
var globes: Array[Vector3] = []
var lamp_lights: Array[OmniLight3D] = []
var lamp_cur: Array[int] = []
var lamp_want: Array[int] = []
var lamp_scan := 0.0
var globe_lights: Array[OmniLight3D] = []
var halos: MultiMeshInstance3D
var pools: MultiMeshInstance3D
var glow_tex: ImageTexture
var flicker_i := -1
var flicker_v := 1.0
var surge := 0.0   # wave-start lamp surge

var motes: CPUParticles3D

# ---------------------------------------------------------------- setup
# Called once. Creates the sky/environment, lights and all effect pools.
func setup(camera: Camera3D) -> void:
	cam = camera
	base_fov = cam.fov
	_build_environment()
	_build_pools()
	_build_ambient()
	# default guess for the subway globe lamps; world.gd can override via add_subway_globes()
	var g: Array = []
	for s in L.SUBWAY_ENTRANCES:
		g.append(s + Vector3(0, 2.7, 3.0 * signf(-s.z)))
	add_subway_globes(g)

func _build_environment() -> void:
	var we := WorldEnvironment.new()
	env = Environment.new()
	var sky := Sky.new()
	var sh := Shader.new()
	sh.code = """
shader_type sky;
uniform vec3 sun_dir;
float hash(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}
void sky() {
	vec3 d = normalize(EYEDIR);
	float up = max(d.y, 0.0);
	float sd = max(dot(d, sun_dir), 0.0);
	float az = dot(normalize(d.xz + vec2(0.00001)), normalize(sun_dir.xz)) * 0.5 + 0.5;
	vec3 c = mix(vec3(0.05, 0.05, 0.19), vec3(0.30, 0.19, 0.46), pow(1.0 - up, 3.0));
	vec3 horizon = mix(vec3(0.50, 0.30, 0.52), vec3(1.0, 0.50, 0.26), az * az);
	c = mix(c, horizon, pow(1.0 - up, 7.0));
	c += vec3(1.0, 0.45, 0.2) * pow(sd, 24.0) * 0.45;
	c += vec3(1.0, 0.85, 0.6) * smoothstep(0.9990, 0.9994, sd);
	// chunky pixel stars, only high up and away from the sun
	vec3 cell = floor(d * 170.0);
	float st = step(0.9965, hash(cell)) * smoothstep(0.25, 0.7, up) * (1.0 - az * 0.7);
	c += vec3(0.8, 0.85, 1.0) * st * (0.4 + 0.6 * hash(cell + 7.0));
	if (d.y < 0.0) {
		c = mix(c, vec3(0.10, 0.08, 0.14), min(1.0, -d.y * 6.0));
	}
	COLOR = c;
}
"""
	var sm := ShaderMaterial.new()
	sm.shader = sh
	sm.set_shader_parameter("sun_dir", SUN_DIR.normalized())
	sky.sky_material = sm
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	# flat cool ambient: the street is in shade at dusk but zombies must read everywhere
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.56, 0.60, 0.74)
	env.ambient_light_energy = 0.9
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_white = 1.6
	# depth fog: warm-violet haze that swallows the far ends of the streets
	env.fog_enabled = true
	env.fog_light_color = Color(0.46, 0.30, 0.44)
	env.fog_light_energy = 1.0
	env.fog_density = 0.010
	env.fog_sky_affect = 0.0
	env.fog_sun_scatter = 0.25
	we.environment = env
	add_child(we)

	sun = DirectionalLight3D.new()
	sun.basis = Basis.looking_at(-SUN_DIR.normalized(), Vector3.UP)
	sun.light_color = Color(1.0, 0.62, 0.36)
	sun.light_energy = 1.25
	sun.light_specular = 0.0
	sun.shadow_enabled = false   # low sun in a canyon: real shadows would just black out the street
	add_child(sun)

func _unshaded(additive: bool, tex: Texture2D = null, billboard := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	if additive:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		m.disable_fog = true
	if tex:
		m.albedo_texture = tex
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	if billboard:
		m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		m.billboard_keep_scale = true
	return m

# White texture whose alpha is a chunky radial falloff (ring=true: a hollow ring).
func _radial_tex(size: int, is_ring: bool) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var h := size / 2.0
	for y in size:
		for x in size:
			var r := Vector2(x + 0.5 - h, y + 0.5 - h).length() / h
			var a := 0.0
			if is_ring:
				a = clampf(1.0 - absf(r - 0.78) / 0.16, 0.0, 1.0)
			else:
				a = pow(clampf(1.0 - r, 0.0, 1.0), 1.8)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	return ImageTexture.create_from_image(img)

func _build_pools() -> void:
	var cube := BoxMesh.new()
	var quad := QuadMesh.new()
	var lit_mat := StandardMaterial3D.new()
	lit_mat.vertex_color_use_as_albedo = true
	lit_mat.roughness = 1.0
	glow_tex = _radial_tex(32, false)
	lit = Pool.new(self, cube, lit_mat, 128, false)
	goo = Pool.new(self, cube, _unshaded(false), 128, false)
	add = Pool.new(self, cube, _unshaded(true), 96, true)
	glow = Pool.new(self, quad, _unshaded(true, glow_tex, true), 32, true)
	var ring_tex := _radial_tex(32, true)
	ring = Pool.new(self, quad, _unshaded(true, ring_tex, true), 12, true)
	var flat := QuadMesh.new()
	flat.orientation = PlaneMesh.FACE_Y
	gring = Pool.new(self, flat, _unshaded(true, ring_tex), 10, true)

	muzzle_light = _omni(Color(1.0, 0.75, 0.4), 9.0)
	pop_light = _omni(Color(0.8, 1.0, 0.5), 8.0)
	for i in LAMP_LIGHTS:
		lamp_lights.append(_omni(LAMP_COL, 13.0))
		lamp_cur.append(-1)
		lamp_want.append(-1)

func _omni(c: Color, rng: float) -> OmniLight3D:
	var l := OmniLight3D.new()
	l.light_color = c
	l.omni_range = rng
	l.omni_attenuation = 1.3
	l.light_specular = 0.0
	l.shadow_enabled = false
	l.light_energy = 0.01
	add_child(l)
	return l

func _build_ambient() -> void:
	# drifting ash / paper scraps around the camera
	motes = CPUParticles3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(0.05, 0.05)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(1.0, 0.82, 0.62)
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.billboard_keep_scale = true
	q.material = m
	motes.mesh = q
	motes.amount = 40
	motes.lifetime = 7.0
	motes.preprocess = 7.0
	motes.local_coords = false
	motes.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	motes.emission_box_extents = Vector3(11, 4, 11)
	motes.direction = Vector3(1, 0.15, 0.3)
	motes.spread = 40.0
	motes.gravity = Vector3(0, -0.12, 0)
	motes.initial_velocity_min = 0.2
	motes.initial_velocity_max = 0.9
	motes.scale_amount_min = 0.5
	motes.scale_amount_max = 1.8
	motes.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(motes)
	# steam: street vents + subway stairwells
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.albedo_texture = glow_tex
	sm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	sm.vertex_color_use_as_albedo = true
	sm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	sm.billboard_keep_scale = true
	var sq := QuadMesh.new()
	sq.material = sm
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.15, 1.0])
	ramp.colors = PackedColorArray([Color(0.8, 0.72, 0.85, 0.0), Color(0.8, 0.72, 0.85, 0.42), Color(0.6, 0.5, 0.7, 0.0)])
	var grow_curve := Curve.new()
	grow_curve.add_point(Vector2(0, 0.35))
	grow_curve.add_point(Vector2(1, 1.0))
	var vents: Array = [Vector3(3.5, 0.05, -14), Vector3(-16, 0.05, -3)]
	for s in L.SUBWAY_ENTRANCES:
		vents.append(s + Vector3(0, 0.6, 0))
	for v in vents:
		var st := CPUParticles3D.new()
		st.mesh = sq
		st.amount = 9
		st.lifetime = 3.6
		st.preprocess = 3.6
		st.local_coords = false
		st.direction = Vector3(0.25, 1, 0.05)
		st.spread = 14.0
		st.gravity = Vector3(0.25, 0.25, 0)
		st.initial_velocity_min = 0.9
		st.initial_velocity_max = 1.5
		st.scale_amount_min = 2.2
		st.scale_amount_max = 3.6
		st.scale_amount_curve = grow_curve
		st.color_ramp = ramp
		st.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		st.position = v
		add_child(st)

# Called once with the first-person gun node (child of the camera, barrel points along -Z).
# weapons.gd passes one holder node that every weapon model lives in; calling this again moves
# the muzzle flash over to the new node.
func attach_gun(g: Node3D) -> void:
	gun = g
	gun_base = g.position
	if flash != null:
		if flash.get_parent() != null:
			flash.get_parent().remove_child(flash)
		gun.add_child(flash)
		return
	# one merged cartoon star: a forward spike plus crossed blades
	var st := SurfaceTool.new()
	var bm := BoxMesh.new()
	var parts := [
		[Vector3(0.09, 0.09, 0.55), Vector3(0, 0, -0.26), 0.0],
		[Vector3(0.50, 0.05, 0.05), Vector3(0, 0, -0.03), 0.0],
		[Vector3(0.05, 0.50, 0.05), Vector3(0, 0, -0.03), 0.0],
		[Vector3(0.34, 0.04, 0.04), Vector3(0, 0, -0.06), PI / 4],
		[Vector3(0.04, 0.34, 0.04), Vector3(0, 0, -0.06), PI / 4],
		[Vector3(0.16, 0.16, 0.16), Vector3(0, 0, -0.05), PI / 4],
	]
	for p in parts:
		var t := Transform3D(Basis(Vector3(0, 0, 1), p[2]) * Basis.from_scale(p[0]), p[1])
		st.append_from(bm, 0, t)
	flash = MeshInstance3D.new()
	flash.mesh = st.commit()
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(1.0, 0.86, 0.32)   # opaque cartoon yellow: additive just clips to white
	m.disable_fog = true
	flash.material_override = m
	flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	flash.position = Vector3(0, 0.0, -0.24)
	flash.scale = Vector3.ONE * 0.001
	gun.add_child(flash)

# ---------------------------------------------------------------- street lamps / subway globes
# Called once after setup() with the street-lamp head positions from clutter.gd.
func add_street_lights(positions: Array) -> void:
	# The endless city replaces the lamp set as the player walks. Remember where each real
	# light is sitting so it stays lit on the same lamp instead of blinking off and on.
	var held: Array = []
	for i in LAMP_LIGHTS:
		held.append(lamps[lamp_cur[i]] if lamp_cur[i] >= 0 and lamp_cur[i] < lamps.size() else null)
	lamps.clear()
	for p in positions:
		lamps.append(p)
	flicker_i = lamps.size() / 3 if lamps.size() > 2 else -1
	for i in LAMP_LIGHTS:
		var keep := -1
		if held[i] != null:
			for j in lamps.size():
				if lamps[j].distance_squared_to(held[i]) < 0.04:
					keep = j
					break
		lamp_cur[i] = keep
		lamp_want[i] = keep
		if keep < 0:
			lamp_lights[i].light_energy = 0.0
	lamp_scan = 0.0
	_rebuild_static()

# Optional: exact world positions of the green subway globe lamps (replaces the default guess).
func add_subway_globes(positions: Array) -> void:
	globes.clear()
	for p in positions:
		globes.append(p)
	for l in globe_lights:
		l.queue_free()
	globe_lights.clear()
	for p in globes:
		var l := _omni(GLOBE_COL, 7.5)
		l.light_energy = 1.3
		l.position = p + Vector3(0, -0.4, 0)
		globe_lights.append(l)
	_rebuild_static()

func _static_mm(mesh: Mesh, material: Material) -> MultiMeshInstance3D:
	var node := MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	node.multimesh = mm
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	return node

func _rebuild_static() -> void:
	if halos == null:
		halos = _static_mm(QuadMesh.new(), _unshaded(true, glow_tex, true))
		var flat := QuadMesh.new()
		flat.orientation = PlaneMesh.FACE_Y
		var pm := _unshaded(true, _radial_tex(64, false))
		pm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR   # smooth on the ground, chunky in the air
		pools = _static_mm(flat, pm)
	var total := lamps.size() + globes.size()
	halos.multimesh.instance_count = total
	pools.multimesh.instance_count = total
	for i in total:
		var is_lamp := i < lamps.size()
		var p: Vector3 = lamps[i] if is_lamp else globes[i - lamps.size()]
		var hs := 3.0 if is_lamp else 1.9
		halos.multimesh.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3.ONE * hs), p))
		halos.multimesh.set_instance_color(i, _halo_col(is_lamp, 1.0))
		var gp := Vector3(p.x, 0.0, p.z)
		gp.y = Pool.floor_y(gp) + 0.035
		var ps := 11.0 if is_lamp else 6.0
		pools.multimesh.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3(ps, 1, ps)), gp))
		pools.multimesh.set_instance_color(i, _pool_col(is_lamp, 1.0))

func _halo_col(is_lamp: bool, k: float) -> Color:
	var c := LAMP_COL if is_lamp else GLOBE_COL
	var e := (0.75 if is_lamp else 0.6) * k
	return Color(c.r * e, c.g * e, c.b * e, 1.0)

func _pool_col(is_lamp: bool, k: float) -> Color:
	var c := LAMP_COL if is_lamp else GLOBE_COL
	var e := (0.55 if is_lamp else 0.3) * k
	return Color(c.r * e, c.g * e, c.b * e, 1.0)

func _update_lamps(dt: float) -> void:
	if lamps.is_empty():
		for l in lamp_lights:
			l.visible = warm > 0
		return
	lamp_scan -= dt
	if lamp_scan <= 0.0:
		lamp_scan = 0.25
		# aim a little ahead of the camera so lamps in view win
		var c := cam.global_position - cam.global_transform.basis.z * 4.0
		# nearest few lamps by a single pass (the city can hand us ~100 lamps; no full sort)
		var want: Array = []
		var want_d: Array = []
		for j in lamps.size():
			var dj: float = lamps[j].distance_squared_to(c)
			var k := want.size()
			while k > 0 and want_d[k - 1] > dj:
				k -= 1
			if k < LAMP_LIGHTS:
				want.insert(k, j)
				want_d.insert(k, dj)
				if want.size() > LAMP_LIGHTS:
					want.pop_back()
					want_d.pop_back()
		var free_slots: Array = []
		for i in LAMP_LIGHTS:
			if lamp_want[i] in want:
				want.erase(lamp_want[i])
			else:
				free_slots.append(i)
		for i in free_slots:
			lamp_want[i] = want.pop_back() if not want.is_empty() else -1
	# flicker one lamp, surge all of them briefly when a wave starts
	var sk := 1.0
	if surge > 0.0:
		surge = maxf(surge - dt, 0.0)
		if surge > 0.25:
			sk = 0.35 + 0.65 * absf(sin(surge * 31.0))
		else:
			sk = 1.0 + surge * 2.0
		for i in lamps.size():
			halos.multimesh.set_instance_color(i, _halo_col(true, sk))
			pools.multimesh.set_instance_color(i, _pool_col(true, sk))
		flicker_v = -1.0   # force the flickering lamp to be rewritten below
	if flicker_i >= 0:
		var nz := sin(clock * 23.0) * sin(clock * 3.7) + sin(clock * 0.9)
		var fv := 0.25 if nz > 1.25 else 1.0
		if fv != flicker_v:
			flicker_v = fv
			halos.multimesh.set_instance_color(flicker_i, _halo_col(true, fv * sk))
			pools.multimesh.set_instance_color(flicker_i, _pool_col(true, fv * sk))
	for i in LAMP_LIGHTS:
		var l := lamp_lights[i]
		if lamp_cur[i] != lamp_want[i]:
			# fade out, hop to the new lamp, fade back in - no popping
			l.light_energy -= dt * LAMP_ENERGY * 5.0
			if l.light_energy <= 0.0 or lamp_cur[i] < 0:
				lamp_cur[i] = lamp_want[i]
				l.light_energy = 0.0
				if lamp_cur[i] >= 0:
					l.position = lamps[lamp_cur[i]] + Vector3(0, -0.5, 0)
		elif lamp_cur[i] >= 0:
			var target := LAMP_ENERGY * sk * (maxf(flicker_v, 0.25) if lamp_cur[i] == flicker_i else 1.0)
			if surge > 0.0 or lamp_cur[i] == flicker_i:
				l.light_energy = target
			else:
				l.light_energy = move_toward(l.light_energy, target, dt * LAMP_ENERGY * 5.0)
		l.visible = lamp_cur[i] >= 0 and l.light_energy > 0.0

# ---------------------------------------------------------------- per frame
func _process(dt: float) -> void:
	if cam == null:
		return
	clock += dt
	if shot_pending:
		# pellets that hit nothing still get a tracer, out into the haze
		shot_pending = false
		var cb := cam.global_transform.basis
		for i in shot_expect - shot_tracers:
			var d := (-cb.z + cb.x * randf_range(-0.03, 0.03) + cb.y * randf_range(-0.03, 0.03)).normalized()
			_tracer(cam.global_position + d * 55.0)
	lit.update(dt)
	goo.update(dt)
	add.update(dt)
	glow.update(dt)
	ring.update(dt)
	gring.update(dt)
	if _hs_on and Time.get_ticks_usec() >= _hs_until:
		_end_hit_stop()

	if warm > 0:
		warm -= 1
		muzzle_light.global_position = cam.global_position
		pop_light.global_position = cam.global_position
	else:
		if flash_new:
			flash_new = false   # always show the flash for at least one rendered frame
		else:
			flash_t -= dt
		if flash:
			flash.visible = flash_t > 0.0
		muzzle_light.visible = flash_t > -0.03
		if muzzle_light.visible:
			muzzle_light.light_energy = 2.6 * clampf((flash_t + 0.03) / 0.08, 0.0, 1.0)
		pop_t -= dt
		pop_light.visible = pop_t > 0.0
		if pop_t > 0.0:
			pop_light.light_energy = pop_e * pop_t / pop_dur
	_update_lamps(dt)
	motes.global_position = cam.global_position + Vector3(0, 1.5, 0)

	# camera feel: springs for the directional stuff, a short decaying shake for the rest
	trauma = maxf(trauma - dt * 2.2, 0.0)
	var r2 := _spring(rec, rec_v, REC_W, dt)
	rec = r2.x
	rec_v = r2.y
	var s2 := _spring(shv, shv_v, SHV_W, dt)
	shv = s2.x
	shv_v = s2.y
	roll = roll * exp(-9.0 * dt)
	dip = dip * exp(-11.0 * dt)
	punch = maxf(punch - dt * 4.5, 0.0)
	var k := shake_scale
	var s := trauma * trauma
	cam.rotation = Vector3(rec * REC_PITCH - shv * 0.03 + _noise(31.0) * s * 0.02, _noise(57.0) * s * 0.02,
		roll + _noise(83.0) * s * 0.025) * k
	var fa := 9.0 * punch * punch * k
	if fa != fov_add:
		fov_add = fa
		cam.fov = base_fov + fa
	_update_gun_shove(dt)

# Critically damped spring towards 0, solved exactly so it is stable at any frame rate.
func _spring(x: float, v: float, w: float, dt: float) -> Vector2:
	var e := exp(-w * dt)
	var c := v + w * x
	return Vector2((x + c * dt) * e, (v - c * w * dt) * e)

# Two-handed push: the gun swings across the view like a bar, then settles back.
# Only position.x/y and rotation.y/z are touched, so main's recoil (position.z, rotation.x) is left alone.
func _update_gun_shove(dt: float) -> void:
	if shove_t < 0.0 or gun == null:
		return
	shove_t += dt
	var a := 0.0
	if shove_t < 0.06:
		a = 1.0 - pow(1.0 - shove_t / 0.06, 2.0)
	elif shove_t < 0.34:
		a = 1.0 - smoothstep(0.12, 0.34, shove_t)
	else:
		shove_t = -1.0
	gun.position.x = gun_base.x - 0.17 * a
	gun.position.y = gun_base.y + 0.07 * a
	gun.rotation.y = 1.15 * a
	gun.rotation.z = 0.25 * a

func _noise(seed_k: float) -> float:
	return sin(clock * 47.0 + seed_k) * 0.6 + sin(clock * 71.0 + seed_k * 2.3) * 0.4

# Camera offset to add this frame (main adds it to the camera pivot position).
func shake_offset() -> Vector3:
	var s := trauma * trauma
	return Vector3(_noise(11.0) * s * 0.05, _noise(19.0) * s * 0.05 - dip * 0.12 - shv * 0.03,
		rec * REC_BACK - shv * 0.11) * shake_scale

# Freeze the action for a few hundredths of a second (the "crunch" on a headshot kill).
# Safe by construction: the end time is in real time and checked every frame, overlapping calls
# only extend it (never past 0.1 s), stops are rate limited, and leaving the tree (restart)
# or losing focus always restores normal speed.
func hit_stop(seconds: float) -> void:
	if not hit_stop_enabled or seconds <= 0.0 or not is_inside_tree():
		return
	var now := Time.get_ticks_usec()
	if not _hs_on and now - _hs_ended < 250000:
		return
	_hs_until = maxi(_hs_until, now + int(minf(seconds, 0.1) * 1000000.0))
	if not _hs_on:
		_hs_on = true
		Engine.time_scale = 0.05

func _end_hit_stop() -> void:
	if _hs_on:
		_hs_on = false
		_hs_ended = Time.get_ticks_usec()
		Engine.time_scale = 1.0

func _exit_tree() -> void:
	_end_hit_stop()

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT \
			or what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_PREDELETE:
		_end_hit_stop()

# ---------------------------------------------------------------- helpers
func _rv(k: float) -> Vector3:
	return Vector3(randf_range(-k, k), randf_range(-k, k), randf_range(-k, k))

func _cube(s: float) -> Basis:
	return Basis.from_scale(Vector3(s, s, s))

func _tracer(to: Vector3) -> void:
	var d := to - muzzle_pos
	var dist := d.length()
	if dist < 1.5:
		return
	d /= dist
	var up := Vector3.UP if absf(d.y) < 0.98 else Vector3.RIGHT
	# a streak covering the outer part of the path, so it reads as moving away
	var seg := dist * 0.7
	var b := Basis.looking_at(d, up) * Basis.from_scale(Vector3(tr_w, tr_w, seg))
	add.emit(to - d * seg * 0.5, Vector3.ZERO, b, tr_col, 0.07, 0.0, 0.0, 0.0, 1.0)

func _sparks(p: Vector3, dir: Vector3, n: int, c: Color, speed: float) -> void:
	for i in n:
		var v := (dir + _rv(0.8)) * randf_range(0.5, 1.0) * speed
		add.emit(p, v, _cube(randf_range(0.04, 0.07)), c, randf_range(0.14, 0.3), 14.0, 1.0, 0.0, 1.0)

func _puffs(p: Vector3, dir: Vector3, n: int, c: Color, speed: float, size: float) -> void:
	for i in n:
		var v := dir * speed + _rv(speed * 0.7)
		goo.emit(p + _rv(size * 0.5), v, _cube(size * randf_range(0.7, 1.2)), c.darkened(randf() * 0.25),
			randf_range(0.3, 0.55), -0.8, 3.5, 1.2, 0.7, randf_range(-3, 3))

func _goo_burst(p: Vector3, dir: Vector3, n: int, speed: float) -> void:
	for i in n:
		var v := dir * speed + _rv(speed * 0.6) + Vector3(0, speed * 0.6, 0)
		var c := GOO.lerp(Color(0.75, 1.0, 0.25), randf() * 0.6).darkened(randf() * 0.2)
		goo.emit(p, v, _cube(randf_range(0.07, 0.13)), c, 1.6, 17.0, 0.4, 0.0, 0.3, randf_range(-8, 8), 2 if i % 2 == 0 else 0)

# ---------------------------------------------------------------- events
# The player fired.
# (The original single-shotgun call: a full kick, five tracers, a red shell.)
func on_shoot() -> void:
	on_fire(1.0, 1.0, Color(0.75, 0.6, 0.3), 0.035, Color(0.85, 0.2, 0.12))
	shot_expect = 5

# Where the barrel tip of the current weapon model is, in the gun node's space.
func set_muzzle(local: Vector3) -> void:
	muzzle_local = local + Vector3(0, 0, -0.02)
	if flash:
		flash.position = local + Vector3(0, 0, 0.04)

# Any weapon fired. kick: recoil in "shotgun shots" (0 = none); flash_k: muzzle flash size (0 = no
# flash, e.g. a crossbow); tracer colour / width for this shot; shell: colour of the ejected
# casing (alpha 0 = none). After this, impact() / zombie_hit() draw a tracer to each hit and
# tracer_to() to anywhere else, until end_shot().
func on_fire(kick := 1.0, flash_k := 1.0, tracer := Color(0.75, 0.6, 0.3), tracer_w := 0.035, shell := Color(0, 0, 0, 0)) -> void:
	# directional kick: an impulse into the recoil spring; the closer to the cap, the less it adds
	rec_v += REC_W * 2.718 * kick * clampf(1.0 - rec / REC_MAX, 0.2, 1.0)
	shot_pending = true
	shot_tracers = 0
	shot_expect = 0
	tr_col = tracer
	tr_w = tracer_w
	if gun == null:
		return
	muzzle_pos = gun.to_global(muzzle_local)
	var cb := cam.global_transform.basis
	if flash_k > 0.0:
		if flash:
			flash.visible = true
			flash.rotation.z = randf() * TAU
			flash.scale = Vector3(randf_range(0.55, 0.9), randf_range(0.55, 0.9), randf_range(0.7, 1.2)) * flash_k
		flash_t = 0.05
		flash_new = true
		warm = 0
		muzzle_light.global_position = muzzle_pos
		muzzle_light.visible = true
		muzzle_light.light_energy = 2.6
		glow.emit(muzzle_pos - cb.z * 0.25, Vector3.ZERO, _cube(0.7 * flash_k), Color(0.8, 0.45, 0.15), 0.06, 0.0, 0.0, 0.4, 1.0)
		# wisp of smoke
		goo.emit(muzzle_pos - cb.z * 0.5, -cb.z * 2.5 + Vector3(0, 0.6, 0), _cube(0.04), Color(0.5, 0.47, 0.55), 0.35, -0.5, 3.0, 1.2, 0.7)
	if shell.a > 0.0:
		var sb := cb * Basis.from_scale(Vector3(0.03, 0.03, 0.07))
		lit.emit(gun.to_global(Vector3(0.06, 0.05, 0.05)), cb.x * randf_range(1.8, 2.6) + cb.y * randf_range(2.2, 3.2) - cb.z * 0.5,
			sb, shell, 1.2, 18.0, 0.0, 0.0, 0.3, randf_range(14, 22), 1)

# A tracer of the current shot to a point nothing was hit at (a miss into the haze, the far
# end of a piercing shot).
func tracer_to(pos: Vector3) -> void:
	_tracer(pos)

# The current shot's ray casts are done: later hits (blasts, burning puddles) draw no tracers.
func end_shot() -> void:
	shot_pending = false

# A bullet hit scenery at `pos` (surface normal `normal`).
func impact(pos: Vector3, normal: Vector3) -> void:
	if shot_pending:
		shot_tracers += 1
		_tracer(pos)
	var p := pos + normal * 0.04
	_sparks(p, normal, 3, Color(1.0, 0.75, 0.35), 6.0)
	_puffs(p, normal, 2, Color(0.5, 0.47, 0.52), 1.2, 0.11)
	for i in 2:
		lit.emit(p, normal * randf_range(1.5, 3.0) + _rv(1.6) + Vector3(0, 1.5, 0), _cube(randf_range(0.05, 0.09)),
			Color(0.52, 0.5, 0.47).darkened(randf() * 0.4), 0.9, 18.0, 0.0, 0.0, 0.3, randf_range(-12, 12), 1)
	glow.emit(p, Vector3.ZERO, _cube(0.55), Color(1.0, 0.7, 0.35), 0.06, 0.0, 0.0, 0.0, 1.0)

# A bullet hit a zombie at `pos`, travelling in `dir`.
func zombie_hit(pos: Vector3, dir: Vector3, headshot: bool) -> void:
	if shot_pending:
		shot_tracers += 1
		_tracer(pos)
	var back := -dir
	_goo_burst(pos + back * 0.05, back, 3, 2.4)
	_goo_burst(pos, dir, 1, 3.5)   # one blob punches out the far side
	glow.emit(pos + back * 0.1, Vector3.ZERO, _cube(0.7 if headshot else 0.5), Color(0.5, 1.0, 0.3), 0.07, 0.0, 0.0, 0.6, 1.0)
	if headshot:
		_sparks(pos, back, 3, Color(1.0, 0.95, 0.4), 5.0)

# A zombie died. `head_pos` is its head position, `skin` its skin colour.
func zombie_death(head_pos: Vector3, skin: Color, headshot: bool) -> void:
	var body := head_pos - Vector3(0, 0.75, 0)
	# poof of dust + chunks + a few pixels that float away
	_puffs(body, Vector3.UP, 7, Color(0.55, 0.6, 0.5), 2.2, 0.2)
	for i in 4:
		lit.emit(body + _rv(0.25), _rv(2.5) + Vector3(0, 3.5, 0), _cube(randf_range(0.09, 0.15)),
			skin.darkened(randf() * 0.3), 1.4, 18.0, 0.0, 0.0, 0.3, randf_range(-10, 10), 1)
	for i in 5:
		goo.emit(body + _rv(0.4), _rv(0.5) + Vector3(0, randf_range(0.8, 1.6), 0), _cube(randf_range(0.04, 0.07)),
			GOO.lerp(Color(1, 1, 0.5), randf()), randf_range(0.9, 1.5), 0.0, 0.6, 0.0, 0.5, randf_range(-4, 4))
	if not headshot:
		return
	# BONK: the hero effect
	trauma = minf(trauma + 0.25, 0.8)
	for i in 10:
		var c := skin.darkened(randf() * 0.25)
		if i < 3:
			c = Color(0.95, 0.5, 0.65)      # brain bits
		elif i == 3:
			c = Color(1.0, 1.0, 0.35)        # an eye
		elif i == 4:
			c = Color(0.15, 0.1, 0.05)       # hair
		lit.emit(head_pos + _rv(0.12), _rv(3.2) + Vector3(0, randf_range(3.5, 7.5), 0), _cube(randf_range(0.1, 0.19)),
			c, 1.7, 17.0, 0.0, 0.0, 0.3, randf_range(-14, 14), 1)
	_goo_burst(head_pos, Vector3.UP, 8, 3.6)
	_sparks(head_pos, Vector3.UP, 8, Color(0.8, 1.0, 0.35), 7.0)
	ring.emit(head_pos, Vector3.ZERO, _cube(0.5), Color(0.9, 1.0, 0.45), 0.28, 0.0, 0.0, 6.5, 1.0)
	glow.emit(head_pos, Vector3.ZERO, _cube(2.4), Color(0.85, 1.0, 0.45), 0.13, 0.0, 0.0, 0.8, 1.0)
	_pop(head_pos + Vector3(0, 0.2, 0), Color(0.8, 1.0, 0.5), 3.0, 0.16, 8.0)
	hit_stop(0.04)

# The player took `dmg` damage.
func player_hurt(dmg: float) -> void:
	trauma = minf(trauma + 0.45 + dmg * 0.01, 0.9)
	roll = (0.05 if randf() < 0.5 else -0.05) * clampf(dmg / 10.0, 1.0, 1.6)

# Generic burst of n bouncing cubes of colour c at p, thrown along `push`.
func gibs(p: Vector3, c: Color, n: int, push: Vector3) -> void:
	for i in mini(n, 16):
		lit.emit(p, push * 4.0 + Vector3(randf_range(-3, 3), randf_range(2, 6), randf_range(-3, 3)), _cube(0.12),
			c.darkened(randf() * 0.2), 1.5, 20.0, 0.0, 0.0, 0.3, randf_range(-12, 12), 1)

# ---- optional extras (wire from main.gd) ----
# The player started a dash: brief FOV punch.
func on_dash() -> void:
	punch = 1.0

# The player landed after a fall; `speed` = downward speed at touchdown (m/s).
func on_land(speed: float) -> void:
	if speed < 4.0:
		return
	dip = clampf(speed / 12.0, 0.3, 1.0)
	var p := cam.global_position
	p.y = Pool.floor_y(p) + 0.1
	_puffs(p - cam.global_transform.basis.z * 0.5, Vector3.UP, 3, Color(0.5, 0.47, 0.52), 1.0, 0.12)

# A zombie appeared at `pos` (feet): sickly green puff.
func zombie_spawn(pos: Vector3) -> void:
	_puffs(pos + Vector3(0, 0.5, 0), Vector3.UP, 6, Color(0.4, 0.7, 0.35), 2.0, 0.22)
	glow.emit(pos + Vector3(0, 1.0, 0), Vector3.ZERO, _cube(2.5), Color(0.25, 0.7, 0.3), 0.3, 0.0, 0.0, 0.5, 1.0)

# Wave `n` started: street lamps stutter, then surge.
func on_wave(_n: int) -> void:
	surge = 0.7

# A reload started: two spent shells drop from the gun.
func on_reload() -> void:
	if gun == null:
		return
	var cb := cam.global_transform.basis
	for i in 2:
		lit.emit(gun.to_global(Vector3(0.05, -0.05, 0.1)), cb.x * randf_range(0.5, 1.2) + Vector3(0, 1.0, 0) + _rv(0.4),
			cb * Basis.from_scale(Vector3(0.03, 0.03, 0.07)), Color(0.85, 0.2, 0.12), 1.6, 18.0, 0.0, 0.0, 0.3, randf_range(10, 18), 1)

# ---- shove / explosions / upgrades (see SPECS.md) ----

func _pop(p: Vector3, c: Color, energy: float, dur: float, rng: float) -> void:
	pop_light.global_position = p
	pop_light.light_color = c
	pop_light.omni_range = rng
	pop_e = energy
	pop_dur = dur
	pop_t = dur
	warm = 0

# Flat (yaw-only) forward direction of the camera.
func _flat_fwd() -> Vector3:
	var cb := cam.global_transform.basis
	var f := Vector3(-cb.z.x, 0.0, -cb.z.z)
	if f.length() < 0.05:
		f = Vector3(cb.y.x, 0.0, cb.y.z)   # looking straight up/down
	return f.normalized()

func _ground_ring(p: Vector3, c: Color, d0: float, d1: float, lifetime: float) -> void:
	p.y = Pool.floor_y(p) + 0.06
	gring.emit(p, Vector3.ZERO, Basis.from_scale(Vector3(d0, 1.0, d0)), c, lifetime, 0.0, 0.0, d1 / d0 - 1.0, 0.6)

# A comic impact star facing the camera: two crossed bars and a flash.
func _star(p: Vector3, c: Color, size: float) -> void:
	var cb := cam.global_transform.basis * Basis(Vector3(0, 0, 1), randf() * PI)
	add.emit(p, Vector3.ZERO, cb * Basis.from_scale(Vector3(size, size * 0.2, 0.02)), c, 0.13, 0.0, 0.0, 0.7, 0.6)
	add.emit(p, Vector3.ZERO, cb * Basis.from_scale(Vector3(size * 0.2, size, 0.02)), c, 0.13, 0.0, 0.0, 0.7, 0.6)
	glow.emit(p, Vector3.ZERO, _cube(size * 1.3), Color(c.r * 0.6, c.g * 0.6, c.b * 0.6), 0.1, 0.0, 0.0, 0.5, 1.0)

# The player shoved; `hit_count` zombies were knocked back.
# Costs 9 additive cubes + 4 puffs + 1 ground ring, plus per zombie hit (max 4) 2 cubes, 1 glow, 2 sparks.
func on_shove(hit_count: int) -> void:
	var hit := hit_count > 0
	shv_v += SHV_W * 2.718 * (1.5 if hit else 1.0) * clampf(1.0 - shv / 1.6, 0.2, 1.0)
	shove_t = 0.0
	if hit:
		trauma = minf(trauma + 0.3, 0.7)
	var f := _flat_fwd()
	var eye := cam.global_position
	var c := Color(0.5, 0.65, 0.85) if not hit else Color(0.9, 0.7, 0.3)
	# the swoosh: an arc of streaks that races out through the shove cone
	for i in 9:
		var d := f.rotated(Vector3.UP, deg_to_rad(-40.0 + 10.0 * i + randf_range(-2.0, 2.0)))
		var b := Basis.looking_at(d, Vector3.UP) * Basis.from_scale(Vector3(0.2, 0.035, 0.12))
		add.emit(eye + d * 1.1 + Vector3(0, -0.5, 0), d * randf_range(13.0, 16.0), b, c, 0.2, 0.0, 5.5, 2.2, 0.7)
	var feet := Vector3(eye.x, 0.0, eye.z)
	_ground_ring(feet + f * 1.2, Color(c.r * 0.5, c.g * 0.5, c.b * 0.5), 1.2, 6.5, 0.24)
	for i in 4:
		var d := f.rotated(Vector3.UP, deg_to_rad(randf_range(-35.0, 35.0)))
		var p := feet + d * randf_range(1.2, 2.4)
		p.y = Pool.floor_y(p) + 0.12
		_puffs(p, d + Vector3(0, 0.25, 0), 1, Color(0.55, 0.52, 0.58), 3.0, 0.14)
	# bonk stars roughly where the shoved zombies stood
	var n := mini(hit_count, 4)
	for i in n:
		var a := (float(i) + 0.5) / n * 70.0 - 35.0 + randf_range(-6.0, 6.0)
		var d := f.rotated(Vector3.UP, deg_to_rad(a))
		var p := eye + d * randf_range(1.7, 2.6) + Vector3(0, randf_range(-0.45, -0.1), 0)
		_star(p, Color(0.95, 0.7, 0.12), 0.5)
		_sparks(p, d, 2, Color(1.0, 0.9, 0.5), 5.0)

# A blast at `pos` with the given radius (explosive pellets, bloater).
# Radius above BIG_BLAST = the toxic lime kind with goo; smaller = a fiery pop.
func explosion(pos: Vector3, radius: float) -> void:
	explosion_colored(pos, radius, radius > BIG_BLAST)

# Same, with the look chosen by the caller. Budget per blast (full / thinned when blasts come
# faster than every 0.12 s): 1 ground ring, 1 air ring, 2 glows, sparks 5+2r (max 14) / half,
# smoke 2+r (max 6) / half, chunks 2+r (max 6) / half, toxic only: 10 goo blobs / 5.
func explosion_colored(pos: Vector3, radius: float, toxic: bool) -> void:
	var r := clampf(radius, 0.5, 8.0)
	var q := 0.5 if clock - boom_t < 0.12 else 1.0
	boom_t = clock
	var c := TOXIC_COL if toxic else FIRE_COL
	var hot := c.lerp(Color(1, 1, 0.8), 0.6)
	if pos.y - Pool.floor_y(pos) < 2.5:
		_ground_ring(pos, c, r * 0.6, r * 2.56, 0.2 + r * 0.04)
	ring.emit(pos, Vector3.ZERO, _cube(r * 0.5), Color(c.r * 0.7, c.g * 0.7, c.b * 0.7), 0.2, 0.0, 0.0, 3.2, 0.7)
	glow.emit(pos, Vector3.ZERO, _cube(r * 2.4), Color(c.r * 0.75, c.g * 0.75, c.b * 0.75), 0.13, 0.0, 0.0, 0.6, 1.0)
	glow.emit(pos, Vector3.ZERO, _cube(r * 0.9), hot, 0.07, 0.0, 0.0, 0.3, 1.0)
	var up := Vector3(0, 0.6, 0)
	for i in int(minf(5.0 + r * 2.0, 14.0) * q):
		var v := (up + _rv(1.0)).normalized() * randf_range(0.5, 1.0) * (5.0 + r * 2.5)
		add.emit(pos, v, _cube(randf_range(0.06, 0.11)), hot, randf_range(0.2, 0.4), 12.0, 1.5, 0.0, 1.0)
	var smoke := Color(0.3, 0.42, 0.22) if toxic else Color(0.33, 0.3, 0.33)
	_puffs(pos, Vector3.UP, int(minf(2.0 + r, 6.0) * q), smoke, 1.2 + r * 0.6, 0.16 + r * 0.06)
	for i in int(minf(2.0 + r, 6.0) * q):
		var cc := GOO.darkened(randf() * 0.4) if toxic else Color(0.3, 0.28, 0.27).lightened(randf() * 0.25)
		lit.emit(pos + _rv(0.2), _rv(2.0 + r) + Vector3(0, randf_range(3.0, 5.0 + r), 0), _cube(randf_range(0.08, 0.15)),
			cc, 1.3, 18.0, 0.0, 0.0, 0.3, randf_range(-12, 12), 1)
	if toxic:
		_goo_burst(pos + Vector3(0, 0.3, 0), Vector3.UP, int(10 * q), 3.0 + r * 0.5)
	_pop(pos + Vector3(0, 0.5, 0), c, 3.0 + minf(r, 5.0) * 0.6, 0.12 + r * 0.02, maxf(8.0, r * 3.0))
	# shake: bigger and closer = harder; a small shell far away adds nothing
	var d := pos.distance_to(cam.global_position)
	var k := clampf(1.0 - d / (8.0 + r * 4.0), 0.0, 1.0)
	trauma = minf(trauma + (0.1 + r * 0.1) * k * q, 0.85)

# The player picked an upgrade: a golden "powered up" burst in front of the camera.
# Costs 14 additive cubes, 2 air rings, 1 ground ring, 1 glow.
func on_upgrade() -> void:
	power_burst(Color(1.0, 0.82, 0.25))

# The same burst in any colour (power-ups, bonk frenzy).
func power_burst(gold: Color) -> void:
	var f := _flat_fwd()
	var eye := cam.global_position
	punch = maxf(punch, 0.6)
	glow.emit(eye + f * 1.6, Vector3.ZERO, _cube(2.6), Color(gold.r * 0.6, gold.g * 0.6, gold.b * 0.6), 0.3, 0.0, 0.0, 0.8, 1.0)
	ring.emit(eye + f * 2.0, Vector3.ZERO, _cube(0.5), gold, 0.4, 0.0, 0.0, 7.0, 0.7)
	ring.emit(eye + f * 2.0, Vector3.ZERO, _cube(0.3), Color(1, 1, 0.8), 0.3, 0.0, 0.0, 5.0, 0.7)
	_ground_ring(Vector3(eye.x, 0.0, eye.z), gold, 1.0, 7.0, 0.5)
	for i in 14:
		var d := f.rotated(Vector3.UP, deg_to_rad(-70.0 + 140.0 * i / 13.0))
		var p := eye + d * randf_range(1.3, 2.0) + Vector3(0, randf_range(-1.3, -0.5), 0)
		add.emit(p, Vector3(0, randf_range(3.0, 6.0), 0) + d * 0.5, Basis.from_scale(Vector3(0.05, 0.16, 0.05)),
			gold.lerp(Color.WHITE, randf() * 0.3) * 0.85, randf_range(0.45, 0.8), -1.0, 1.5, 0.0, 0.6)
	_pop(eye + f * 1.2, gold, 3.0, 0.25, 8.0)

# Replace the whole set of street lamps / subway globes (the endless city calls these
# whenever the blocks around the player change). Same as add_* but named for that use.
func set_street_lights(positions: Array) -> void:
	add_street_lights(positions)

func set_subway_globes(positions: Array) -> void:
	add_subway_globes(positions)

# ---------------------------------------------------------------- weapons, projectiles, drops
# Everything below reuses the pools above (no new nodes, materials or shaders).

# The additive, unshaded, vertex-coloured material of the spark pool, for other scripts'
# glowing meshes (drop beams) so they do not compile a shader of their own.
func additive_material() -> Material:
	return add.node.material_override

# A melee swing: a fast arc of streaks from right to left, a short lunge, bonk stars on hits.
# Costs 7 additive cubes, plus per zombie hit (max 4) 2 cubes, 1 glow, 2 sparks.
func on_swing(hit_count: int) -> void:
	var hit := hit_count > 0
	shv_v += SHV_W * 2.718 * (0.9 if hit else 0.5) * clampf(1.0 - shv / 1.6, 0.2, 1.0)
	if hit:
		trauma = minf(trauma + 0.22, 0.6)
	var f := _flat_fwd()
	var eye := cam.global_position
	var c := Color(0.22, 0.22, 0.26) if not hit else Color(0.45, 0.36, 0.14)
	for i in 7:
		var d := f.rotated(Vector3.UP, deg_to_rad(-48.0 + 16.0 * i))
		var side := d.cross(Vector3.UP)
		var b := Basis.looking_at(side, Vector3.UP) * Basis.from_scale(Vector3(0.03, 0.025, 0.42))
		add.emit(eye + d * 1.5 + Vector3(0, -0.25 - 0.03 * i, 0), -side * 9.0 + d * 3.0, b, c, 0.14, 0.0, 6.0, 0.6, 0.7)
	var n := mini(hit_count, 4)
	for i in n:
		var a := (float(i) + 0.5) / n * 80.0 - 40.0 + randf_range(-6.0, 6.0)
		var d := f.rotated(Vector3.UP, deg_to_rad(a))
		var p := eye + d * randf_range(1.6, 2.4) + Vector3(0, randf_range(-0.3, 0.1), 0)
		_star(p, Color(1.0, 0.85, 0.2), 0.6)
		_sparks(p, d, 2, Color(1.0, 0.9, 0.5), 5.0)

# One tick of the hydrant hose: three fat droplets flying out of the muzzle along `dir`.
func water(dir: Vector3, speed: float) -> void:
	if gun == null:
		return
	var from := gun.to_global(muzzle_local)
	for i in 3:
		var c := Color(0.45, 0.75, 1.0).lerp(Color(0.9, 0.97, 1.0), randf() * 0.6)
		goo.emit(from + dir * (0.2 + i * 0.5), dir * speed * randf_range(0.45, 1.0) + _rv(0.9), _cube(randf_range(0.11, 0.18)), c,
			randf_range(0.4, 0.55), 5.0, 0.3, 1.8, 0.45, randf_range(-6, 6))

# Spray where the hose lands on something.
func water_splash(pos: Vector3) -> void:
	_puffs(pos, Vector3.UP, 2, Color(0.75, 0.9, 1.0), 2.0, 0.16)

# One puff left behind by something flying (hot dog smoke, pigeon feathers, sauce drips).
func trail(pos: Vector3, c: Color, size := 0.12) -> void:
	goo.emit(pos, _rv(0.4), _cube(size), c, 0.4, -0.6, 2.0, 1.0, 0.7, randf_range(-4, 4))

# A puff of flat feathers (a pigeon arrived).
func feathers(pos: Vector3) -> void:
	for i in 7:
		var c := Color(0.9, 0.9, 0.95).darkened(randf() * 0.35)
		lit.emit(pos + _rv(0.2), _rv(3.0) + Vector3(0, 2.0, 0), Basis.from_scale(Vector3(0.14, 0.02, 0.07)), c,
			1.4, 4.0, 2.5, 0.0, 0.3, randf_range(-9, 9), 1)

# A burning hot-sauce puddle of radius r: call a few times a second while it burns.
# Costs 3 additive cubes and one soft ring on the ground per call.
func fire_patch(pos: Vector3, r: float) -> void:
	var fl := Pool.floor_y(pos)
	for i in 3:
		var a := randf() * TAU
		var d := sqrt(randf()) * r
		var p := Vector3(pos.x + cos(a) * d, fl + 0.1, pos.z + sin(a) * d)
		var c := FIRE_COL.lerp(Color(1.0, 0.9, 0.3), randf() * 0.7)
		add.emit(p, Vector3(0, randf_range(1.5, 3.0), 0), Basis.from_scale(Vector3(0.14, 0.3, 0.14)), c * 0.8,
			randf_range(0.35, 0.6), -1.5, 0.5, -0.5, 0.8)
	gring.emit(Vector3(pos.x, fl + 0.05, pos.z), Vector3.ZERO, Basis.from_scale(Vector3(r * 1.9, 1.0, r * 1.9)),
		Color(0.5, 0.16, 0.03), 0.3, 0.0, 0.0, 0.08, 0.9)

# Something was picked up at `pos`: a ring, a flash and sparks in colour c.
func pickup(pos: Vector3, c: Color) -> void:
	var p := pos + Vector3(0, 0.8, 0)
	ring.emit(p, Vector3.ZERO, _cube(0.6), c, 0.35, 0.0, 0.0, 6.0, 0.7)
	glow.emit(p, Vector3.ZERO, _cube(3.0), Color(c.r * 0.6, c.g * 0.6, c.b * 0.6), 0.25, 0.0, 0.0, 0.6, 1.0)
	_ground_ring(pos, c, 1.0, 6.0, 0.4)
	for i in 10:
		add.emit(p + _rv(0.4), Vector3(randf_range(-1.5, 1.5), randf_range(3.0, 6.5), randf_range(-1.5, 1.5)),
			Basis.from_scale(Vector3(0.05, 0.16, 0.05)), c.lerp(Color.WHITE, randf() * 0.4) * 0.85, randf_range(0.4, 0.75), 4.0, 1.0, 0.0, 0.6)
	_pop(p, c, 3.0, 0.25, 9.0)
	punch = maxf(punch, 0.35)

# A crate hit the street at `pos`: dust, splinters, a thump you can feel if it is close.
func crate_land(pos: Vector3, c: Color) -> void:
	_puffs(pos + Vector3(0, 0.2, 0), Vector3.UP, 6, Color(0.55, 0.52, 0.5), 2.6, 0.24)
	_ground_ring(pos, c, 1.2, 7.0, 0.35)
	for i in 4:
		lit.emit(pos + Vector3(0, 0.3, 0), _rv(3.0) + Vector3(0, 4.0, 0), _cube(randf_range(0.07, 0.12)),
			Color(0.66, 0.42, 0.2).darkened(randf() * 0.3), 1.2, 18.0, 0.0, 0.0, 0.3, randf_range(-12, 12), 1)
	var k := clampf(1.0 - pos.distance_to(cam.global_position) / 20.0, 0.0, 1.0)
	trauma = minf(trauma + 0.35 * k, 0.7)

# The marker of a drop: a puff of coloured smoke rising from `pos` and a slow ring on the ground.
# Call a few times a second. Costs 1 puff, and a ground ring when `pulse` is true.
func beacon(pos: Vector3, c: Color, pulse: bool) -> void:
	goo.emit(pos + Vector3(randf_range(-0.2, 0.2), 0.3, randf_range(-0.2, 0.2)), Vector3(randf_range(-0.3, 0.3), randf_range(2.2, 3.2), randf_range(-0.3, 0.3)),
		_cube(randf_range(0.22, 0.34)), c.darkened(randf() * 0.2), randf_range(1.3, 1.9), -0.3, 0.5, 1.6, 0.6, randf_range(-2, 2))
	if pulse:
		_ground_ring(pos, Color(c.r * 0.6, c.g * 0.6, c.b * 0.6), 1.0, 5.0, 0.7)
