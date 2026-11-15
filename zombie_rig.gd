extends Node3D
# One zombie's body: how it looks and how it animates. zombies.gd owns where it is,
# which way it faces and what it is doing; this script only makes that look good.
# Feet at y = 0, face toward -Z. See SPECS.md for the frozen API.
#
# Cost: each zombie is 6 draw calls (head, torso, two arms, two legs), each a single
# vertex-coloured mesh sharing ONE material for the whole game. Meshes are cached per
# look, so spawning only creates 9 nodes. The name label is created on first use.
#
# Tree:  rig -> _pose (death / rise) -> _parts (scale, squash) -> legs, chest -> head, arms

const SKINS := [Color(0.56, 0.78, 0.40), Color(0.48, 0.70, 0.52), Color(0.50, 0.66, 0.68), Color(0.70, 0.76, 0.38)]
const SHIRTS := [Color(0.92, 0.92, 0.88), Color(0.55, 0.72, 0.92), Color(0.72, 0.62, 0.86),
	Color(0.80, 0.90, 0.70), Color(0.62, 0.84, 0.78), Color(0.78, 0.80, 0.84)]
const JACKETS := [Color(0.33, 0.38, 0.54), Color(0.50, 0.41, 0.37)]
const PANTS := [Color(0.32, 0.33, 0.42), Color(0.30, 0.36, 0.58), Color(0.52, 0.41, 0.30), Color(0.60, 0.56, 0.45)]
const HAIRS := [Color(0.13, 0.10, 0.08), Color(0.36, 0.22, 0.10), Color(0.62, 0.60, 0.56), Color(0.55, 0.20, 0.10)]
const TIE := Color(0.95, 0.12, 0.14)
const EYE := Color(1.0, 0.95, 0.25)
const DARK := Color(0.08, 0.06, 0.08)
const PINK := Color(1.0, 0.16, 0.60)
const LIME := Color(0.56, 0.90, 0.16)
const LIME_HOT := Color(0.85, 1.0, 0.35)
const HIVIS := Color(0.80, 1.0, 0.10)
const SILVER := Color(0.86, 0.90, 0.94)
const METAL := Color(0.64, 0.68, 0.73)
# signature colours of the newer types
const FUR := Color(0.95, 0.50, 0.12)          # monkey
const HAT_YELLOW := Color(1.0, 0.80, 0.08)    # hard hat
const VEST_ORANGE := Color(1.0, 0.42, 0.05)
const NAVY := Color(0.24, 0.33, 0.62)         # riot cop
const SHIELD_CYAN := Color(0.35, 0.90, 1.0)
const KETCHUP := Color(0.92, 0.12, 0.10)      # vendor
const MUSTARD := Color(1.0, 0.82, 0.12)
const CAB_YELLOW := Color(1.0, 0.78, 0.05)    # cabbie
const CHEESE := Color(1.0, 0.74, 0.18)        # pizza rat
const RAT_GREY := Color(0.64, 0.58, 0.57)
const RAT_PINK := Color(1.0, 0.62, 0.66)

# body modes (set_mode): on the ground, climbing a wall (belly to it), perched on a wall
# facing out, flying through the air, tumbling down
const M_GROUND := 0
const M_CLIMB := 1
const M_PERCH := 2
const M_AIR := 3
const M_TUMBLE := 4

const D_PLANK := 0
const D_FACEPLANT := 1
const D_SPIN_SIT := 2
const D_KNEES := 3
const D_BACKFLIP := 4
const D_HOP := 5
const D_POP := 6

var type := "commuter"
var height := 2.0      # top of head, metres (after scale)
var radius := 0.35     # body radius, metres (after scale)
var skin := Color.WHITE

var _pose: Node3D
var _parts: Node3D
var _chest: MeshInstance3D
var _head: MeshInstance3D
var _arms: Array[MeshInstance3D] = []
var _legs: Array[MeshInstance3D] = []
var _label: Label3D
var _label_on := true

# proportions (before scale)
var _s := Vector3.ONE
var _leg := 0.82
var _leg_x := 0.15
var _neck := 0.64
var _head_size := Vector3(0.44, 0.42, 0.42)
var _hat := 0.0
var _tw := 0.6
var _td := 0.32
var _sh := Vector2(0.385, 0.56)

# personality
var _hunch := 0.1
var _lean_gain := 0.15
var _ref_speed := 4.0
var _cad := 3.4
var _stride := 0.65
var _limp := 0.0
var _limp_side := 1.0
var _tilt0 := 0.0
var _arm_base := [1.3, 1.3]
var _arm_up := [2.9, 2.9]
var _splay := 0.0
var _arm_swing := 0.16
var _ph := 0.0

# state
var _t := 0.0
var _phase := 0.0
var _walk := 0.0
var _spd := 0.0
var _windup := 0.0
var _strike_t := -1.0
var _strike_w := 1.0
var _fl := Vector3.ZERO
var _sq := 0.0
var _sqv := 0.0
var _swell := 0.0
var _flash_t := 0.0
var _mat_level := 0
var _twitch := 0.0
var _twitch_next := 2.0
var _rise_t := -1.0
var _rise_d := 1.0
var _frame := -1
var _dead := false
var _death := 0
var _death_t := 0.0
var _death_len := 1.0
var _fall := Vector3(0, 0, 1)
var _d0 := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
var _bumped := false
var _mode := M_GROUND
var _spin := 0.0
var _alert := 0.0
var _alert_on := false
var _guard := 1.0          # riot shield: 1 held in front, 0 swung aside
var _guard_to := 1.0
var _has_shield := false
var _shield_c := Vector3.ZERO     # shield centre / size, rig-local before scale
var _shield_size := Vector3.ZERO
var _has_hat := false
var _bare_head: ArrayMesh
var _hat_node: MeshInstance3D
var _hat_vel := Vector3.ZERO
var _hat_t := 0.0
var _vy := 0.0             # a body that dies up a wall falls to the street

static var _last_death := -1

# ---------------------------------------------------------------- shared material
static var _mat: ShaderMaterial
static var _levels: Array = []      # [null, glow1, glow2, glow3] material overrides
static var _flash_mat: ShaderMaterial
static var _alert_mat: ShaderMaterial
static var _cache := {}

const SHADER := """
shader_type spatial;
render_mode diffuse_lambert, specular_disabled;
// vertex colour = albedo; vertex alpha = how lit it is (0 = fully unshaded/glowing)
uniform vec3 tint = vec3(1.0);
uniform float tint_k = 0.0;
void vertex() {
	COLOR.rgb = mix(pow((COLOR.rgb + vec3(0.055)) / 1.055, vec3(2.4)), COLOR.rgb / 12.92, lessThan(COLOR.rgb, vec3(0.04045)));
}
void fragment() {
	vec3 c = mix(COLOR.rgb, tint, tint_k);
	float lit = COLOR.a * (1.0 - tint_k) * 0.88;   // a little self-light so nothing goes black in shade
	ALBEDO = c * lit;
	EMISSION = c * (1.0 - lit);
	ROUGHNESS = 1.0;
}
"""

# The one material every character mesh and the gun uses.
static func material() -> ShaderMaterial:
	if _mat == null:
		var sh := Shader.new()
		sh.code = SHADER
		_mat = ShaderMaterial.new()
		_mat.shader = sh
		_levels = [null]
		for k in [0.3, 0.55, 0.8]:
			var g := ShaderMaterial.new()
			g.shader = sh
			g.set_shader_parameter("tint", Vector3(0.80, 1.0, 0.25))
			g.set_shader_parameter("tint_k", k)
			_levels.append(g)
		_flash_mat = ShaderMaterial.new()
		_flash_mat.shader = sh
		_flash_mat.set_shader_parameter("tint", Vector3(1, 1, 1))
		_flash_mat.set_shader_parameter("tint_k", 1.0)
		_alert_mat = ShaderMaterial.new()
		_alert_mat.shader = sh
		_alert_mat.set_shader_parameter("tint", Vector3(1.0, 0.22, 0.08))
		_alert_mat.set_shader_parameter("tint_k", 0.5)
	return _mat

# Merges coloured boxes into one mesh. Face shading (dark undersides, lighter tops,
# darker lower edges) is baked into the vertex colours. emit 0..1 = unshaded amount.
class Sculpt:
	const FACES := [
		[Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)],
		[Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0)],
		[Vector3(0, 1, 0), Vector3(0, 0, 1), Vector3(1, 0, 0)],
		[Vector3(0, -1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)],
		[Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0)],
		[Vector3(0, 0, -1), Vector3(0, 1, 0), Vector3(1, 0, 0)],
	]
	const SU := [-1.0, 1.0, 1.0, -1.0]
	const SV := [-1.0, -1.0, 1.0, 1.0]
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()
	var i := PackedInt32Array()
	var glow := 0.0   # minimum unshaded amount for every box added (keeps the gun readable in shade)

	func box(size: Vector3, pos: Vector3, col: Color, emit := 0.0, rot := Vector3.ZERO) -> void:
		emit = maxf(emit, glow)
		var b := Basis.IDENTITY if rot == Vector3.ZERO else Basis.from_euler(rot)
		var h := size * 0.5
		for f in FACES:
			var fn: Vector3 = f[0]
			var fu: Vector3 = f[1]
			var fv: Vector3 = f[2]
			var wn := b * fn
			var shade := 1.0 + (0.10 * wn.y if wn.y > 0.0 else 0.40 * wn.y)
			shade *= 1.0 - 0.10 * maxf(wn.z, 0.0) - 0.05 * absf(wn.x)
			var base := v.size()
			for k in 4:
				var lp: Vector3 = (fn + fu * SU[k] + fv * SV[k]) * h
				var s := shade
				if fn.y == 0.0 and lp.y < 0.0:
					s *= 0.84
				s = lerpf(s, 1.0, emit * 0.6)
				v.append(pos + b * lp)
				n.append(wn)
				c.append(Color(col.r * s, col.g * s, col.b * s, 1.0 - emit))
			i.append_array([base, base + 2, base + 1, base, base + 3, base + 2])

	# the same box on both sides (x mirrored)
	func pair(size: Vector3, pos: Vector3, col: Color, emit := 0.0, rot := Vector3.ZERO) -> void:
		box(size, pos, col, emit, rot)
		box(size, Vector3(-pos.x, pos.y, pos.z), col, emit, Vector3(rot.x, -rot.y, -rot.z))

	func mesh() -> ArrayMesh:
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = v
		arr[Mesh.ARRAY_NORMAL] = n
		arr[Mesh.ARRAY_COLOR] = c
		arr[Mesh.ARRAY_INDEX] = i
		var m := ArrayMesh.new()
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		return m

# Turn a finished Sculpt into a mesh that uses the shared material.
static func bake(s: Sculpt) -> ArrayMesh:
	var m := s.mesh()
	m.surface_set_material(0, material())
	return m

# ---------------------------------------------------------------- building
func build(p_type: String, rng: RandomNumberGenerator) -> void:
	type = p_type
	material()
	_ph = rng.randf() * TAU
	_phase = _ph
	_tilt0 = rng.randf_range(-0.22, 0.22)
	if rng.randf() < 0.35:
		_limp = rng.randf_range(0.35, 0.7)
		_limp_side = 1.0 if rng.randf() < 0.5 else -1.0
	var cad_var := rng.randf_range(0.9, 1.15)
	_twitch_next = rng.randf_range(0.5, 4.0)
	var head_m: ArrayMesh
	var torso_m: ArrayMesh
	var arm_m: Array = [null, null]
	var leg_m: ArrayMesh
	match type:
		"delivery":
			_s = Vector3.ONE * 0.9
			skin = SKINS[rng.randi() % SKINS.size()]
			_leg = 0.85; _leg_x = 0.11; _neck = 0.58; _head_size = Vector3(0.36, 0.36, 0.36); _hat = 0.08
			_tw = 0.46; _td = 0.5; _sh = Vector2(0.27, 0.5)
			_hunch = 0.42; _lean_gain = 0.2; _ref_speed = 7.0; _stride = 0.85
			_arm_base = [rng.randf_range(0.75, 1.0), rng.randf_range(0.75, 1.0)]
			_arm_up = [2.5, 2.5]
			_limp = 0.0
			head_m = _delivery_head(skin)
			torso_m = _delivery_torso()
			arm_m = [_delivery_arm(skin), _delivery_arm(skin)]
			leg_m = _delivery_leg()
		"bloater":
			_s = Vector3.ONE * 1.2
			skin = LIME
			_leg = 0.34; _leg_x = 0.26; _neck = 0.9; _head_size = Vector3(0.42, 0.36, 0.4); _hat = 0.1
			_tw = 1.15; _td = 0.95; _sh = Vector2(0.6, 0.62)
			_hunch = 0.05; _lean_gain = 0.06; _ref_speed = 2.0; _stride = 0.55
			_arm_base = [0.9, 0.9]
			_arm_up = [2.3, 2.3]
			_splay = 0.55
			head_m = _bloater_head()
			torso_m = _bloater_torso()
			arm_m = [_bloater_arm(), _bloater_arm()]
			leg_m = _bloater_leg()
		"sanitation":
			_s = Vector3.ONE * rng.randf_range(1.7, 1.8)
			skin = SKINS[rng.randi() % SKINS.size()]
			_leg = 0.75; _leg_x = 0.19; _neck = 0.74; _head_size = Vector3(0.42, 0.4, 0.42); _hat = 0.12
			_tw = 0.8; _td = 0.44; _sh = Vector2(0.52, 0.6)
			_hunch = 0.16; _lean_gain = 0.1; _ref_speed = 2.5; _stride = 0.5
			_arm_base = [1.15, 0.75]
			_arm_up = [2.6, 3.0]
			_splay = 0.12
			head_m = _sanitation_head(skin)
			torso_m = _sanitation_torso()
			arm_m = [_sanitation_arm(skin, false), _sanitation_arm(skin, true)]
			leg_m = _sanitation_leg()
		"monkey":
			_s = Vector3.ONE * 1.35
			skin = FUR
			_leg = 0.36; _leg_x = 0.12; _neck = 0.46; _head_size = Vector3(0.36, 0.32, 0.32); _hat = 0.12
			_tw = 0.42; _td = 0.30; _sh = Vector2(0.27, 0.40)
			_hunch = 0.8; _lean_gain = 0.15; _ref_speed = 6.0; _stride = 0.9
			_arm_base = [0.8, 0.8]      # = the hunch: arms hang straight down, knuckles on the street
			_arm_up = [2.9, 2.9]
			_arm_swing = 0.6
			_limp = 0.0
			head_m = _monkey_head()
			torso_m = _monkey_torso()
			arm_m = [_monkey_arm(), _monkey_arm()]
			leg_m = _monkey_leg()
		"rat":
			_s = Vector3.ONE * rng.randf_range(1.4, 1.65)
			skin = RAT_GREY
			_leg = 0.13; _leg_x = 0.10; _neck = 0.50; _head_size = Vector3(0.22, 0.18, 0.24); _hat = 0.0
			_tw = 0.26; _td = 0.22; _sh = Vector2(0.1, 0.42)
			_hunch = 1.4; _lean_gain = 0.04; _ref_speed = 6.0; _stride = 0.9
			_arm_base = [1.4, 1.4]
			_arm_up = [1.4, 1.4]
			_limp = 0.0
			_tilt0 *= 0.4
			head_m = _rat_head()
			torso_m = _rat_torso()
			leg_m = _rat_leg()      # no arm meshes: the front paws are part of the body (4 draw calls)
		"hardhat":
			var si := rng.randi() % SKINS.size()
			skin = SKINS[si]
			_s = Vector3(1.12, rng.randf_range(0.96, 1.04), 1.12)
			_hat = 0.18
			_tw = 0.64; _td = 0.36
			_hunch = rng.randf_range(0.08, 0.18)
			_stride = 0.5
			_arm_base = [1.25 - _hunch, 0.2]     # left arm grabs, right arm drags a wrench
			_arm_up = [2.6, 3.0]
			head_m = _hardhat_head(si, true)
			_bare_head = _hardhat_head(si, false)
			_has_hat = true
			torso_m = _hardhat_torso()
			arm_m = [_hardhat_arm(si, false), _hardhat_arm(si, true)]
			leg_m = _hardhat_leg()
		"riot":
			var si := rng.randi() % SKINS.size()
			skin = SKINS[si]
			_s = Vector3.ONE * 1.08
			_hat = 0.06
			_tw = 0.66; _td = 0.38; _sh = Vector2(0.40, 0.56)
			_hunch = 0.08; _lean_gain = 0.05; _ref_speed = 3.0; _stride = 0.42
			_arm_base = [1.05, 0.45]     # left arm holds the shield out in front, right arm a baton
			_arm_up = [2.5, 2.9]
			_arm_swing = 0.05
			_limp = 0.0
			_has_shield = true
			_shield_c = Vector3(-0.12, _leg + 0.10, -0.50)
			_shield_size = Vector3(0.80, 1.18, 0.07)
			head_m = _riot_head(si)
			torso_m = _riot_torso()
			arm_m = [_riot_arm(true, _arm_base[0] - _hunch, _shield_c - Vector3(-_sh.x, _leg + _sh.y, 0), _shield_size), _riot_arm(false, 0.0, Vector3.ZERO, Vector3.ZERO)]
			leg_m = _riot_leg()
		"vendor":
			var si := rng.randi() % SKINS.size()
			skin = SKINS[si]
			_s = Vector3(1.15, 1.0, 1.15)
			_hat = 0.12
			_tw = 0.74; _td = 0.5; _sh = Vector2(0.44, 0.56)
			_hunch = 0.05; _lean_gain = 0.05; _ref_speed = 2.5; _stride = 0.4
			_arm_base = [0.45, 1.25]     # right arm holds the next hot dog up
			_arm_up = [0.7, 3.4]
			head_m = _vendor_head(si)
			torso_m = _vendor_torso()
			arm_m = [_vendor_arm(si, false), _vendor_arm(si, true)]
			leg_m = _vendor_leg()
		"cabbie":
			var si := rng.randi() % SKINS.size()
			skin = SKINS[si]
			_s = Vector3(1.0, 1.02, 1.0)
			_hat = 0.30
			_hunch = 0.3; _lean_gain = 0.25; _ref_speed = 6.0; _stride = 0.7
			_arm_base = [1.25, 1.25]     # both hands on the wheel
			_arm_up = [1.7, 1.7]
			_arm_swing = 0.04
			_limp = 0.0
			head_m = _cabbie_head(si)
			torso_m = _cabbie_torso()
			arm_m = [_cabbie_arm(si), _cabbie_arm(si)]
			leg_m = _cabbie_leg()
		_:
			var r := rng.randf()
			var sx := rng.randf_range(0.95, 1.05)
			var sy := rng.randf_range(0.95, 1.05)
			if r < 0.3:
				sx = rng.randf_range(0.82, 0.9); sy = rng.randf_range(1.08, 1.17)
			elif r < 0.6:
				sx = rng.randf_range(1.14, 1.28); sy = rng.randf_range(0.84, 0.92)
			_s = Vector3(sx, sy, sx)
			var si := rng.randi() % SKINS.size()
			skin = SKINS[si]
			var shirt := rng.randi() % SHIRTS.size()
			var jacket := (rng.randi() % JACKETS.size()) if rng.randf() < 0.3 else -1
			var pants := rng.randi() % PANTS.size()
			var hair := rng.randi() % 6
			var prop := rng.randi() % 5     # 0,1 briefcase (left/right)  2,3 coffee (left/right)  4 nothing
			_hat = [0.02, 0.1, 0.08, 0.22, 0.04, 0.08][hair]
			_hunch = rng.randf_range(0.02, 0.22)
			_lean_gain = 0.1
			_stride = rng.randf_range(0.45, 0.58)
			_arm_base = [rng.randf_range(1.05, 1.5) - _hunch, rng.randf_range(1.05, 1.5) - _hunch]
			if prop < 2:
				_arm_base[prop] = 0.15
			elif prop < 4:
				_arm_base[prop - 2] = 1.5 - _hunch
			head_m = _commuter_head(si, hair)
			torso_m = _commuter_torso(shirt, jacket)
			for a in 2:
				var p := 0
				if prop == a: p = 1
				elif prop - 2 == a: p = 2
				arm_m[a] = _commuter_arm(si, shirt, jacket, p)
			leg_m = _commuter_leg(pants)
	_cad = TAU / (2.3 * _leg * _s.y) * cad_var

	_pose = Node3D.new()
	add_child(_pose)
	_parts = Node3D.new()
	_parts.scale = _s
	_pose.add_child(_parts)
	for a in 2:
		var lg := MeshInstance3D.new()
		lg.mesh = leg_m
		lg.position = Vector3((a * 2 - 1) * _leg_x, _leg, 0)
		_parts.add_child(lg)
		_legs.append(lg)
	_chest = MeshInstance3D.new()
	_chest.mesh = torso_m
	_chest.position = Vector3(0, _leg, 0)
	_parts.add_child(_chest)
	_head = MeshInstance3D.new()
	_head.mesh = head_m
	_head.position = Vector3(0, _neck, 0)
	_chest.add_child(_head)
	for a in 2:
		var am := MeshInstance3D.new()
		am.mesh = arm_m[a]
		am.position = Vector3((a * 2 - 1) * _sh.x, _sh.y, 0)
		_chest.add_child(am)
		_arms.append(am)
	height = (_leg + (_neck + _head_size.y + _hat) * cos(_hunch)) * _s.y
	if type == "vendor":
		height = (_leg + 1.56) * _s.y     # the umbrella
	elif type == "rat":
		height = 0.5 * _s.y               # the pizza slice on its back
	radius = maxf(_tw, _td) * 0.5 * _s.x
	set_process(false)
	_pose_now(0.0)

# ---- commuter
static func _commuter_head(si: int, hair: int) -> ArrayMesh:
	var key := "ch%d_%d" % [si, hair]
	if _cache.has(key):
		return _cache[key]
	var sk: Color = SKINS[si]
	var hc: Color = HAIRS[(hair + si) % HAIRS.size()]
	var m := Sculpt.new()
	_face(m, sk, hc, 0.44, 0.42, 0.42)
	match hair:
		0:  # bald with a brave comb-over
			for k in 3:
				m.box(Vector3(0.40, 0.02, 0.035), Vector3(0.0, 0.43, -0.1 + k * 0.1), hc)
		1:  # flat top
			m.box(Vector3(0.46, 0.11, 0.44), Vector3(0, 0.465, 0), hc)
			m.pair(Vector3(0.03, 0.14, 0.08), Vector3(0.225, 0.34, -0.04), hc)
		2:  # side part with a fringe
			m.box(Vector3(0.47, 0.08, 0.45), Vector3(0, 0.45, 0), hc)
			m.box(Vector3(0.28, 0.09, 0.05), Vector3(-0.09, 0.40, -0.215), hc)
			m.box(Vector3(0.47, 0.22, 0.05), Vector3(0, 0.34, 0.215), hc)
		3:  # bowler hat
			m.box(Vector3(0.62, 0.04, 0.60), Vector3(0, 0.43, 0), Color(0.12, 0.12, 0.15))
			m.box(Vector3(0.42, 0.19, 0.40), Vector3(0, 0.54, 0), Color(0.12, 0.12, 0.15))
			m.box(Vector3(0.43, 0.05, 0.41), Vector3(0, 0.475, 0), TIE, 0.4)
		4:  # receding, with glasses
			m.pair(Vector3(0.05, 0.16, 0.30), Vector3(0.235, 0.36, 0.04), hc)
			m.box(Vector3(0.40, 0.10, 0.05), Vector3(0, 0.38, 0.215), hc)
			m.box(Vector3(0.48, 0.035, 0.03), Vector3(0, 0.345, -0.235), DARK)
			m.pair(Vector3(0.03, 0.035, 0.2), Vector3(0.235, 0.345, -0.13), DARK)
		_:  # bob
			m.box(Vector3(0.48, 0.09, 0.46), Vector3(0, 0.455, 0), hc)
			m.pair(Vector3(0.05, 0.36, 0.40), Vector3(0.24, 0.26, 0.03), hc)
			m.box(Vector3(0.48, 0.36, 0.05), Vector3(0, 0.26, 0.225), hc)
			m.box(Vector3(0.40, 0.06, 0.04), Vector3(0, 0.41, -0.215), hc)
	_cache[key] = bake(m)
	return _cache[key]

# A zombie face on the front of a head box whose base sits on the neck (y = 0).
static func _face(m: Sculpt, sk: Color, brow: Color, w: float, h: float, d: float, eye := EYE) -> void:
	var z := -d * 0.5
	m.box(Vector3(w, h, d), Vector3(0, h * 0.5, 0), sk)
	m.pair(Vector3(0.05, 0.11, 0.09), Vector3(w * 0.5 + 0.015, h * 0.52, 0.0), sk.darkened(0.12))
	m.box(Vector3(0.07, 0.08, 0.06), Vector3(0, h * 0.47, z - 0.02), sk.darkened(0.15))
	# mismatched glowing eyes
	m.box(Vector3(0.125, 0.125, 0.03), Vector3(-w * 0.24, h * 0.66, z - 0.005), eye, 1.0)
	m.box(Vector3(0.045, 0.05, 0.03), Vector3(-w * 0.20, h * 0.65, z - 0.012), DARK)
	m.box(Vector3(0.085, 0.075, 0.03), Vector3(w * 0.25, h * 0.63, z - 0.005), eye, 1.0)
	m.box(Vector3(0.035, 0.035, 0.03), Vector3(w * 0.25, h * 0.63, z - 0.012), DARK)
	m.box(Vector3(0.16, 0.04, 0.04), Vector3(w * 0.24, h * 0.78, z - 0.01), brow, 0.0, Vector3(0, 0, 0.3))
	# mouth, one tooth, underbite
	m.box(Vector3(w * 0.5, 0.075, 0.03), Vector3(0.01, h * 0.25, z - 0.004), DARK)
	m.box(Vector3(0.05, 0.05, 0.03), Vector3(0.06, h * 0.23, z - 0.012), Color(0.95, 0.93, 0.8), 0.5)
	m.box(Vector3(w * 0.62, 0.07, 0.07), Vector3(0, h * 0.10, z - 0.025), sk.darkened(0.08))

static func _commuter_torso(shirt: int, jacket: int) -> ArrayMesh:
	var key := "ct%d_%d" % [shirt, jacket]
	if _cache.has(key):
		return _cache[key]
	var sc: Color = SHIRTS[shirt]
	var m := Sculpt.new()
	if jacket >= 0:
		var jc: Color = JACKETS[jacket]
		m.box(Vector3(0.62, 0.64, 0.34), Vector3(0, 0.33, 0), jc)
		m.box(Vector3(0.22, 0.52, 0.03), Vector3(0, 0.38, -0.165), sc)
		m.pair(Vector3(0.09, 0.30, 0.035), Vector3(0.12, 0.49, -0.17), jc.lightened(0.1), 0.0, Vector3(0, 0, -0.35))
	else:
		m.box(Vector3(0.60, 0.62, 0.32), Vector3(0, 0.33, 0), sc)
		m.box(Vector3(0.22, 0.12, 0.03), Vector3(-0.16, -0.01, -0.15), sc.darkened(0.06))   # untucked flap
		m.box(Vector3(0.11, 0.11, 0.025), Vector3(-0.17, 0.44, -0.165), sc.darkened(0.12))  # pocket
		m.box(Vector3(0.025, 0.07, 0.03), Vector3(-0.19, 0.49, -0.168), Color(0.2, 0.4, 1.0), 0.8)  # pen
		m.box(Vector3(0.20, 0.16, 0.02), Vector3(0.14, 0.2, -0.163), Color(0.32, 0.42, 0.16))  # mystery stain
		if shirt % 2 == 0:
			m.box(Vector3(0.24, 0.18, 0.02), Vector3(0.05, 0.40, 0.165), Color(1.0, 0.95, 0.6), 0.6, Vector3(0, 0, 0.15))  # sticky note
			m.box(Vector3(0.14, 0.03, 0.025), Vector3(0.05, 0.42, 0.167), DARK, 0.0, Vector3(0, 0, 0.15))
		else:
			m.box(Vector3(0.34, 0.20, 0.02), Vector3(0, 0.44, 0.163), sc.darkened(0.2))  # sweat patch
	m.box(Vector3(0.63, 0.07, 0.35), Vector3(0, 0.035, 0), Color(0.14, 0.10, 0.08))  # belt
	m.box(Vector3(0.08, 0.06, 0.03), Vector3(0, 0.035, -0.17), Color(1.0, 0.8, 0.2), 0.8)
	m.pair(Vector3(0.13, 0.07, 0.10), Vector3(0.10, 0.635, -0.12), Color(0.96, 0.96, 0.94), 0.0, Vector3(0, 0, 0.3))  # collar
	# the loosened tie: knot pulled off-centre, tail hanging askew
	m.box(Vector3(0.09, 0.08, 0.05), Vector3(0.03, 0.555, -0.185), TIE, 0.55)
	m.box(Vector3(0.10, 0.40, 0.035), Vector3(0.085, 0.36, -0.19), TIE, 0.55, Vector3(0, 0, 0.26))
	m.box(Vector3(0.20, 0.07, 0.20), Vector3(0, 0.66, 0), Color(0.45, 0.08, 0.08))  # neck (shows when the head pops)
	_cache[key] = bake(m)
	return _cache[key]

# prop: 0 none, 1 briefcase, 2 coffee
static func _commuter_arm(si: int, shirt: int, jacket: int, prop: int) -> ArrayMesh:
	var key := "ca%d_%d_%d_%d" % [si, shirt, jacket, prop]
	if _cache.has(key):
		return _cache[key]
	var sk: Color = SKINS[si]
	var sleeve: Color = JACKETS[jacket] if jacket >= 0 else SHIRTS[shirt]
	var m := Sculpt.new()
	m.box(Vector3(0.16, 0.34, 0.17), Vector3(0, -0.13, 0), sleeve)
	if jacket >= 0:
		m.box(Vector3(0.15, 0.26, 0.15), Vector3(0, -0.41, 0), sleeve)
		m.box(Vector3(0.16, 0.04, 0.16), Vector3(0, -0.53, 0), SHIRTS[shirt])
	else:
		m.box(Vector3(0.17, 0.05, 0.18), Vector3(0, -0.29, 0), sleeve.darkened(0.1))  # rolled-up cuff
		m.box(Vector3(0.13, 0.26, 0.13), Vector3(0, -0.42, 0), sk)
	m.box(Vector3(0.16, 0.15, 0.16), Vector3(0, -0.61, 0), sk.darkened(0.05))
	if prop == 1:
		var bc := Color(0.42, 0.24, 0.10)
		m.box(Vector3(0.05, 0.08, 0.14), Vector3(0, -0.70, 0), DARK)
		m.box(Vector3(0.12, 0.32, 0.48), Vector3(0, -0.89, 0), bc)
		m.box(Vector3(0.13, 0.05, 0.49), Vector3(0, -0.80, 0), bc.darkened(0.3))
		m.pair(Vector3(0.14, 0.06, 0.06), Vector3(0, -0.80, 0.0), Color(1.0, 0.82, 0.25), 0.9)
	elif prop == 2:
		m.box(Vector3(0.14, 0.14, 0.26), Vector3(0, -0.63, -0.14), Color(0.98, 0.97, 0.92), 0.6)
		m.box(Vector3(0.15, 0.15, 0.07), Vector3(0, -0.63, -0.17), Color(0.62, 0.36, 0.14), 0.3)
		m.box(Vector3(0.155, 0.155, 0.03), Vector3(0, -0.63, -0.275), Color(0.75, 0.75, 0.78), 0.4)
	_cache[key] = bake(m)
	return _cache[key]

static func _commuter_leg(pants: int) -> ArrayMesh:
	var key := "cl%d" % pants
	if _cache.has(key):
		return _cache[key]
	var pc: Color = PANTS[pants]
	var m := Sculpt.new()
	m.box(Vector3(0.22, 0.76, 0.24), Vector3(0, -0.36, 0), pc)
	m.box(Vector3(0.24, 0.10, 0.36), Vector3(0, -0.77, -0.05), Color(0.16, 0.12, 0.10))
	_cache[key] = bake(m)
	return _cache[key]

# ---- delivery
static func _delivery_head(sk: Color) -> ArrayMesh:
	var key := "dh" + sk.to_html()
	if _cache.has(key):
		return _cache[key]
	var m := Sculpt.new()
	_face(m, sk, DARK, 0.36, 0.36, 0.36)
	m.box(Vector3(0.10, 0.16, 0.03), Vector3(0.0, 0.02, -0.20), Color(1.0, 0.45, 0.55), 0.5)   # tongue out
	var white := Color(0.93, 0.93, 0.96)
	m.box(Vector3(0.42, 0.13, 0.44), Vector3(0, 0.375, 0.0), white, 0.25)
	m.box(Vector3(0.34, 0.06, 0.36), Vector3(0, 0.46, 0.0), white, 0.25)
	m.box(Vector3(0.12, 0.20, 0.46), Vector3(0, 0.40, 0.0), PINK, 0.7)
	m.box(Vector3(0.30, 0.03, 0.10), Vector3(0, 0.325, -0.26), DARK)
	m.pair(Vector3(0.03, 0.30, 0.04), Vector3(0.19, 0.17, 0.02), DARK)
	_cache[key] = bake(m)
	return _cache[key]

static func _delivery_torso() -> ArrayMesh:
	if _cache.has("dt"):
		return _cache["dt"]
	var jc := Color(0.34, 0.42, 0.56)
	var m := Sculpt.new()
	m.box(Vector3(0.42, 0.58, 0.24), Vector3(0, 0.30, 0), jc)
	m.box(Vector3(0.43, 0.07, 0.25), Vector3(0, 0.42, 0), PINK, 0.7)
	m.pair(Vector3(0.07, 0.50, 0.03), Vector3(0.14, 0.33, -0.125), PINK.darkened(0.25), 0.4)
	# the cube: a hot-pink insulated backpack, wider than the body
	m.box(Vector3(0.84, 0.84, 0.56), Vector3(0, 0.56, 0.41), PINK, 0.6)
	m.box(Vector3(0.87, 0.06, 0.59), Vector3(0, 0.84, 0.41), PINK.darkened(0.35), 0.3)
	m.box(Vector3(0.40, 0.40, 0.02), Vector3(0, 0.52, 0.70), Color(1, 1, 1), 0.9)
	m.box(Vector3(0.16, 0.16, 0.025), Vector3(0.08, 0.60, 0.703), PINK, 0.6)
	m.box(Vector3(0.16, 0.07, 0.16), Vector3(0, 0.60, 0), Color(0.45, 0.08, 0.08))
	_cache["dt"] = bake(m)
	return _cache["dt"]

static func _delivery_arm(sk: Color) -> ArrayMesh:
	var key := "da" + sk.to_html()
	if _cache.has(key):
		return _cache[key]
	var m := Sculpt.new()
	m.box(Vector3(0.12, 0.52, 0.12), Vector3(0, -0.22, 0), Color(0.34, 0.42, 0.56))
	m.box(Vector3(0.13, 0.05, 0.13), Vector3(0, -0.45, 0), PINK, 0.7)
	m.box(Vector3(0.13, 0.16, 0.13), Vector3(0, -0.56, 0), sk)
	_cache[key] = bake(m)
	return _cache[key]

static func _delivery_leg() -> ArrayMesh:
	if _cache.has("dl"):
		return _cache["dl"]
	var m := Sculpt.new()
	m.box(Vector3(0.15, 0.78, 0.16), Vector3(0, -0.37, 0), Color(0.18, 0.20, 0.27))
	m.box(Vector3(0.155, 0.05, 0.165), Vector3(0, -0.40, 0), PINK, 0.6)
	m.box(Vector3(0.17, 0.10, 0.32), Vector3(0, -0.80, -0.06), Color(0.95, 0.95, 0.95), 0.3)
	_cache["dl"] = bake(m)
	return _cache["dl"]

# ---- bloater
static func _bloater_head() -> ArrayMesh:
	if _cache.has("bh"):
		return _cache["bh"]
	var m := Sculpt.new()
	_face(m, LIME, LIME.darkened(0.5), 0.42, 0.36, 0.40, Color(1.0, 1.0, 0.75))
	m.pair(Vector3(0.12, 0.12, 0.12), Vector3(0.20, 0.08, -0.12), LIME_HOT, 0.8)   # cheeks
	# manhole cover worn as a hat (an octagon made of three slabs), tilted
	var iron := Color(0.50, 0.49, 0.55)
	var r := Vector3(-0.22, 0, 0.13)
	var c := Vector3(0.03, 0.43, 0.02)
	m.box(Vector3(0.92, 0.11, 0.40), c, iron, 0.0, r)
	m.box(Vector3(0.40, 0.11, 0.92), c, iron, 0.0, r)
	m.box(Vector3(0.67, 0.112, 0.67), c, iron, 0.0, r)
	var up := Basis.from_euler(r)
	for ix in 3:
		for iz in 3:
			m.box(Vector3(0.10, 0.03, 0.10), c + up * Vector3((ix - 1) * 0.2, 0.065, (iz - 1) * 0.2), iron.darkened(0.45), 0.0, r)
	_cache["bh"] = bake(m)
	return _cache["bh"]

static func _bloater_torso() -> ArrayMesh:
	if _cache.has("bt"):
		return _cache["bt"]
	var m := Sculpt.new()
	var body := LIME
	m.box(Vector3(0.92, 0.22, 0.78), Vector3(0, 0.11, 0), Color(0.34, 0.24, 0.40))   # shorts
	m.box(Vector3(1.15, 0.50, 0.95), Vector3(0, 0.44, 0), body, 0.25)
	m.box(Vector3(0.80, 0.38, 0.14), Vector3(0, 0.42, -0.53), body.lightened(0.15), 0.3)   # belly
	m.box(Vector3(0.08, 0.08, 0.03), Vector3(0, 0.36, -0.605), body.darkened(0.6))
	m.box(Vector3(1.0, 0.28, 0.82), Vector3(0, 0.80, 0), Color(0.86, 0.84, 0.74))   # vest that gave up
	m.box(Vector3(0.50, 0.10, 0.84), Vector3(0, 0.90, 0), body, 0.25)
	# glowing boils
	for p in [Vector3(-0.38, 0.52, -0.47), Vector3(0.42, 0.34, -0.46), Vector3(0.585, 0.5, 0.1), Vector3(-0.585, 0.4, -0.1),
			Vector3(0.2, 0.55, 0.48), Vector3(-0.3, 0.38, 0.48), Vector3(0.22, 0.6, -0.60)]:
		m.box(Vector3(0.15, 0.15, 0.15), p, LIME_HOT, 1.0)
	m.box(Vector3(0.24, 0.06, 0.24), Vector3(0, 0.955, 0), Color(0.3, 0.45, 0.05))
	_cache["bt"] = bake(m)
	return _cache["bt"]

static func _bloater_arm() -> ArrayMesh:
	if _cache.has("ba"):
		return _cache["ba"]
	var m := Sculpt.new()
	m.box(Vector3(0.20, 0.34, 0.20), Vector3(0, -0.13, 0), LIME, 0.25)
	m.box(Vector3(0.24, 0.16, 0.24), Vector3(0, -0.36, 0), LIME.lightened(0.12), 0.3)
	_cache["ba"] = bake(m)
	return _cache["ba"]

static func _bloater_leg() -> ArrayMesh:
	if _cache.has("bl"):
		return _cache["bl"]
	var m := Sculpt.new()
	m.box(Vector3(0.24, 0.28, 0.26), Vector3(0, -0.12, 0), LIME.darkened(0.15), 0.2)
	m.box(Vector3(0.27, 0.09, 0.36), Vector3(0, -0.295, -0.04), Color(0.18, 0.12, 0.2))
	_cache["bl"] = bake(m)
	return _cache["bl"]

# ---- sanitation
static func _sanitation_head(sk: Color) -> ArrayMesh:
	var key := "sh" + sk.to_html()
	if _cache.has(key):
		return _cache[key]
	var m := Sculpt.new()
	_face(m, sk, DARK, 0.42, 0.40, 0.42, Color(1.0, 0.45, 0.12))
	m.box(Vector3(0.36, 0.045, 0.04), Vector3(0, 0.325, -0.225), DARK)   # one long angry brow
	m.box(Vector3(0.44, 0.13, 0.30), Vector3(0, 0.07, -0.07), Color(0.2, 0.17, 0.15))   # stubble
	# hi-vis hard hat
	m.box(Vector3(0.46, 0.13, 0.46), Vector3(0, 0.455, 0.0), HIVIS, 0.6)
	m.box(Vector3(0.34, 0.06, 0.36), Vector3(0, 0.54, 0.0), HIVIS, 0.6)
	m.box(Vector3(0.50, 0.035, 0.62), Vector3(0, 0.40, -0.05), HIVIS.darkened(0.15), 0.5)
	m.box(Vector3(0.08, 0.17, 0.48), Vector3(0, 0.49, 0.0), SILVER, 0.7)
	_cache[key] = bake(m)
	return _cache[key]

static func _sanitation_torso() -> ArrayMesh:
	if _cache.has("st"):
		return _cache["st"]
	var cov := Color(0.34, 0.54, 0.47)
	var m := Sculpt.new()
	m.box(Vector3(0.78, 0.74, 0.42), Vector3(0, 0.37, 0), cov)
	m.box(Vector3(0.90, 0.30, 0.50), Vector3(0, 0.20, -0.02), cov)   # gut
	# vest: two front panels, a back, silver bands
	m.pair(Vector3(0.33, 0.56, 0.05), Vector3(0.235, 0.45, -0.225), HIVIS, 0.6)
	m.box(Vector3(0.82, 0.56, 0.05), Vector3(0, 0.45, 0.225), HIVIS, 0.6)
	m.pair(Vector3(0.05, 0.56, 0.44), Vector3(0.395, 0.45, 0.0), HIVIS, 0.6)
	m.pair(Vector3(0.335, 0.08, 0.06), Vector3(0.235, 0.34, -0.228), SILVER, 0.8)
	m.box(Vector3(0.83, 0.08, 0.06), Vector3(0, 0.34, 0.228), SILVER, 0.8)
	m.pair(Vector3(0.09, 0.30, 0.06), Vector3(0.24, 0.56, -0.228), SILVER, 0.8)
	m.pair(Vector3(0.09, 0.30, 0.06), Vector3(0.24, 0.56, 0.228), SILVER, 0.8)
	m.pair(Vector3(0.24, 0.05, 0.46), Vector3(0.26, 0.745, 0.0), HIVIS, 0.6)
	m.box(Vector3(0.22, 0.07, 0.22), Vector3(0, 0.76, 0), Color(0.45, 0.08, 0.08))
	_cache["st"] = bake(m)
	return _cache["st"]

# right arm swings a trash can; left arm just grabs
static func _sanitation_arm(sk: Color, can: bool) -> ArrayMesh:
	var key := "sa%s%s" % [sk.to_html(), "c" if can else "l"]
	if _cache.has(key):
		return _cache[key]
	var cov := Color(0.34, 0.54, 0.47)
	var glove := Color(1.0, 0.52, 0.10)
	var m := Sculpt.new()
	m.box(Vector3(0.24, 0.40, 0.26), Vector3(0, -0.16, 0), cov)
	m.box(Vector3(0.20, 0.26, 0.21), Vector3(0, -0.45, 0), cov.darkened(0.1))
	m.box(Vector3(0.25, 0.06, 0.26), Vector3(0, -0.34, 0), SILVER, 0.8)
	m.box(Vector3(0.25, 0.19, 0.25), Vector3(0, -0.66, 0), glove, 0.45)
	if can:
		var y := -1.05
		m.box(Vector3(0.06, 0.10, 0.20), Vector3(0, -0.77, 0), DARK)
		m.box(Vector3(0.44, 0.52, 0.44), Vector3(0, y, 0), METAL, 0.2)
		for k in 3:
			m.box(Vector3(0.47, 0.04, 0.47), Vector3(0, y - 0.16 + k * 0.16, 0), METAL.darkened(0.3))
		m.box(Vector3(0.50, 0.05, 0.50), Vector3(0, y + 0.26, 0), SILVER, 0.6)
		m.box(Vector3(0.36, 0.02, 0.36), Vector3(0, y + 0.27, 0), DARK)
		m.box(Vector3(0.50, 0.05, 0.50), Vector3(0, y - 0.26, 0), SILVER, 0.6)
	_cache[key] = bake(m)
	return _cache[key]

static func _sanitation_leg() -> ArrayMesh:
	if _cache.has("sl"):
		return _cache["sl"]
	var cov := Color(0.34, 0.54, 0.47)
	var m := Sculpt.new()
	m.box(Vector3(0.28, 0.68, 0.30), Vector3(0, -0.32, 0), cov)
	m.box(Vector3(0.29, 0.07, 0.31), Vector3(0, -0.48, 0), SILVER, 0.8)
	m.box(Vector3(0.30, 0.13, 0.42), Vector3(0, -0.685, -0.05), Color(0.12, 0.09, 0.07))
	_cache["sl"] = bake(m)
	return _cache["sl"]

# ---- monkey (escaped from the zoo): orange fur, long arms, curly tail, a little red fez
static func _monkey_head() -> ArrayMesh:
	if _cache.has("mh"):
		return _cache["mh"]
	var face := Color(0.62, 0.82, 0.42)
	var m := Sculpt.new()
	m.box(Vector3(0.36, 0.32, 0.32), Vector3(0, 0.16, 0), FUR, 0.45)
	m.box(Vector3(0.28, 0.20, 0.03), Vector3(0, 0.17, -0.165), face)
	m.box(Vector3(0.22, 0.13, 0.11), Vector3(0, 0.075, -0.20), face.lightened(0.12))          # muzzle
	m.box(Vector3(0.17, 0.04, 0.03), Vector3(0, 0.055, -0.262), DARK)
	m.box(Vector3(0.04, 0.055, 0.03), Vector3(-0.05, 0.035, -0.268), Color(0.97, 0.95, 0.85), 0.6)
	m.box(Vector3(0.04, 0.055, 0.03), Vector3(0.055, 0.035, -0.268), Color(0.97, 0.95, 0.85), 0.6)
	m.box(Vector3(0.11, 0.11, 0.03), Vector3(-0.085, 0.205, -0.185), EYE, 1.0)
	m.box(Vector3(0.04, 0.045, 0.03), Vector3(-0.07, 0.20, -0.192), DARK)
	m.box(Vector3(0.075, 0.07, 0.03), Vector3(0.09, 0.195, -0.185), EYE, 1.0)
	m.box(Vector3(0.03, 0.03, 0.03), Vector3(0.09, 0.195, -0.192), DARK)
	m.pair(Vector3(0.07, 0.18, 0.06), Vector3(0.215, 0.18, 0.0), FUR.lightened(0.15), 0.3)   # big ears
	m.pair(Vector3(0.03, 0.10, 0.03), Vector3(0.235, 0.18, -0.02), RAT_PINK, 0.3)
	m.box(Vector3(0.19, 0.13, 0.19), Vector3(0.04, 0.385, 0.0), KETCHUP, 0.6, Vector3(0, 0, -0.15))   # fez
	m.box(Vector3(0.03, 0.12, 0.03), Vector3(0.16, 0.40, 0.0), MUSTARD, 0.9)                          # tassel
	_cache["mh"] = bake(m)
	return _cache["mh"]

static func _monkey_torso() -> ArrayMesh:
	if _cache.has("mt"):
		return _cache["mt"]
	var m := Sculpt.new()
	m.box(Vector3(0.42, 0.46, 0.30), Vector3(0, 0.23, 0), FUR, 0.45)
	m.box(Vector3(0.26, 0.30, 0.03), Vector3(0, 0.22, -0.155), Color(0.98, 0.80, 0.52), 0.3)   # belly
	m.box(Vector3(0.44, 0.05, 0.32), Vector3(0, 0.40, 0), Color(0.2, 0.5, 1.0), 0.6)           # zoo collar
	m.box(Vector3(0.07, 0.08, 0.03), Vector3(0.0, 0.34, -0.17), MUSTARD, 0.9)                  # its tag
	# the tail: out, up and curled over (it stands up behind the hunched body)
	m.box(Vector3(0.07, 0.07, 0.34), Vector3(0, 0.04, 0.30), FUR.darkened(0.1), 0.45)
	m.box(Vector3(0.07, 0.07, 0.30), Vector3(0, 0.04, 0.60), FUR.darkened(0.1), 0.45)
	m.box(Vector3(0.07, 0.24, 0.07), Vector3(0, 0.13, 0.75), FUR.darkened(0.1), 0.45)
	m.box(Vector3(0.07, 0.07, 0.20), Vector3(0, 0.25, 0.68), FUR.darkened(0.1), 0.45)
	m.box(Vector3(0.14, 0.05, 0.14), Vector3(0, 0.475, 0), Color(0.45, 0.08, 0.08))
	_cache["mt"] = bake(m)
	return _cache["mt"]

static func _monkey_arm() -> ArrayMesh:
	if _cache.has("ma"):
		return _cache["ma"]
	var m := Sculpt.new()
	m.box(Vector3(0.12, 0.36, 0.12), Vector3(0, -0.15, 0), FUR, 0.45)
	m.box(Vector3(0.10, 0.30, 0.10), Vector3(0, -0.45, 0), FUR.darkened(0.12), 0.3)
	m.box(Vector3(0.14, 0.12, 0.14), Vector3(0, -0.64, 0), Color(0.62, 0.82, 0.42))
	_cache["ma"] = bake(m)
	return _cache["ma"]

static func _monkey_leg() -> ArrayMesh:
	if _cache.has("ml"):
		return _cache["ml"]
	var m := Sculpt.new()
	m.box(Vector3(0.14, 0.30, 0.15), Vector3(0, -0.14, 0), FUR.darkened(0.08), 0.3)
	m.box(Vector3(0.15, 0.07, 0.25), Vector3(0, -0.325, -0.04), Color(0.62, 0.82, 0.42))
	_cache["ml"] = bake(m)
	return _cache["ml"]

# ---- pizza rat: a sewer rat the size of a dog with a slice on its back. The body is the
# "torso", bent right over, so in this mesh +Y points at the nose and +Z is the back.
static func _rat_head() -> ArrayMesh:
	if _cache.has("rh"):
		return _cache["rh"]
	var m := Sculpt.new()
	m.box(Vector3(0.22, 0.18, 0.24), Vector3(0, 0.09, 0), RAT_GREY)
	m.box(Vector3(0.14, 0.12, 0.12), Vector3(0, 0.06, -0.17), RAT_GREY.lightened(0.1))      # snout
	m.box(Vector3(0.07, 0.06, 0.05), Vector3(0, 0.09, -0.245), RAT_PINK, 0.5)
	m.box(Vector3(0.07, 0.07, 0.03), Vector3(0, 0.0, -0.225), Color(0.97, 0.95, 0.8), 0.6)   # buck teeth
	m.pair(Vector3(0.06, 0.06, 0.03), Vector3(0.075, 0.12, -0.125), EYE, 1.0)
	m.pair(Vector3(0.12, 0.13, 0.04), Vector3(0.13, 0.21, 0.06), RAT_PINK, 0.35)             # ears
	_cache["rh"] = bake(m)
	return _cache["rh"]

static func _rat_torso() -> ArrayMesh:
	if _cache.has("rt"):
		return _cache["rt"]
	var m := Sculpt.new()
	m.box(Vector3(0.26, 0.50, 0.22), Vector3(0, 0.25, 0), RAT_GREY)
	m.box(Vector3(0.32, 0.26, 0.27), Vector3(0, 0.12, 0.0), RAT_GREY.darkened(0.12))         # haunches
	m.box(Vector3(0.05, 0.26, 0.05), Vector3(0, -0.12, 0.03), RAT_PINK, 0.35)                # tail
	m.box(Vector3(0.04, 0.24, 0.04), Vector3(0.03, -0.34, 0.06), RAT_PINK, 0.35, Vector3(0, 0, 0.3))
	m.pair(Vector3(0.06, 0.06, 0.15), Vector3(0.11, 0.42, -0.16), RAT_PINK, 0.2)             # front paws
	# the slice, point forward, wider than the rat
	var crust := Color(0.80, 0.52, 0.22)
	m.box(Vector3(0.52, 0.08, 0.07), Vector3(0, 0.03, 0.16), crust, 0.3)
	m.box(Vector3(0.46, 0.13, 0.04), Vector3(0, 0.13, 0.16), CHEESE, 0.85)
	m.box(Vector3(0.34, 0.13, 0.04), Vector3(0, 0.26, 0.16), CHEESE, 0.85)
	m.box(Vector3(0.22, 0.13, 0.04), Vector3(0, 0.39, 0.16), CHEESE, 0.85)
	m.box(Vector3(0.10, 0.12, 0.04), Vector3(0, 0.51, 0.16), CHEESE, 0.85)
	m.box(Vector3(0.09, 0.09, 0.02), Vector3(-0.10, 0.15, 0.185), KETCHUP, 0.5)
	m.box(Vector3(0.08, 0.08, 0.02), Vector3(0.07, 0.27, 0.185), KETCHUP, 0.5)
	m.box(Vector3(0.07, 0.07, 0.02), Vector3(-0.02, 0.40, 0.185), KETCHUP, 0.5)
	_cache["rt"] = bake(m)
	return _cache["rt"]

static func _rat_leg() -> ArrayMesh:
	if _cache.has("rl"):
		return _cache["rl"]
	var m := Sculpt.new()
	m.box(Vector3(0.08, 0.10, 0.10), Vector3(0, -0.05, 0), RAT_GREY.darkened(0.2))
	m.box(Vector3(0.07, 0.04, 0.16), Vector3(0, -0.11, -0.04), RAT_PINK, 0.2)
	_cache["rl"] = bake(m)
	return _cache["rl"]

# ---- hard hat (building-site worker): yellow hat that takes two head shots, orange vest
static func _hat_boxes(m: Sculpt, y: float) -> void:
	m.box(Vector3(0.50, 0.15, 0.50), Vector3(0, y + 0.075, 0.0), HAT_YELLOW, 0.65)
	m.box(Vector3(0.38, 0.08, 0.40), Vector3(0, y + 0.19, 0.0), HAT_YELLOW, 0.65)
	m.box(Vector3(0.70, 0.04, 0.74), Vector3(0, y + 0.02, -0.03), HAT_YELLOW.darkened(0.12), 0.55)   # brim all round
	m.box(Vector3(0.09, 0.20, 0.52), Vector3(0, y + 0.15, 0.0), Color(1.0, 0.95, 0.6), 0.8)

static func _hardhat_hat() -> ArrayMesh:
	if _cache.has("hhat"):
		return _cache["hhat"]
	var m := Sculpt.new()
	_hat_boxes(m, -0.1)
	_cache["hhat"] = bake(m)
	return _cache["hhat"]

static func _hardhat_head(si: int, hat: bool) -> ArrayMesh:
	var key := "hh%d%s" % [si, "h" if hat else "b"]
	if _cache.has(key):
		return _cache[key]
	var sk: Color = SKINS[si]
	var m := Sculpt.new()
	_face(m, sk, DARK, 0.44, 0.42, 0.42)
	m.box(Vector3(0.46, 0.15, 0.32), Vector3(0, 0.07, -0.07), Color(0.24, 0.2, 0.17))   # stubble
	if hat:
		_hat_boxes(m, 0.41)
	else:
		m.pair(Vector3(0.05, 0.14, 0.30), Vector3(0.235, 0.36, 0.04), DARK)                # what hair is left
		m.box(Vector3(0.40, 0.12, 0.05), Vector3(0, 0.36, 0.215), DARK)
		m.box(Vector3(0.14, 0.09, 0.14), Vector3(0.06, 0.45, -0.02), Color(1.0, 0.45, 0.5), 0.5)   # a fresh bump
	_cache[key] = bake(m)
	return _cache[key]

static func _hardhat_torso() -> ArrayMesh:
	if _cache.has("ht"):
		return _cache["ht"]
	var tee := Color(0.62, 0.66, 0.72)
	var m := Sculpt.new()
	m.box(Vector3(0.62, 0.64, 0.34), Vector3(0, 0.33, 0), tee)
	m.box(Vector3(0.70, 0.26, 0.42), Vector3(0, 0.18, -0.02), tee)                        # lunch
	m.pair(Vector3(0.27, 0.54, 0.05), Vector3(0.19, 0.42, -0.185), VEST_ORANGE, 0.6)
	m.box(Vector3(0.66, 0.54, 0.05), Vector3(0, 0.42, 0.185), VEST_ORANGE, 0.6)
	m.pair(Vector3(0.05, 0.54, 0.36), Vector3(0.315, 0.42, 0.0), VEST_ORANGE, 0.6)
	m.pair(Vector3(0.275, 0.07, 0.06), Vector3(0.19, 0.30, -0.19), SILVER, 0.8)
	m.pair(Vector3(0.275, 0.07, 0.06), Vector3(0.19, 0.52, -0.19), SILVER, 0.8)
	m.box(Vector3(0.67, 0.07, 0.06), Vector3(0, 0.30, 0.19), SILVER, 0.8)
	m.box(Vector3(0.67, 0.07, 0.06), Vector3(0, 0.52, 0.19), SILVER, 0.8)
	m.box(Vector3(0.72, 0.08, 0.44), Vector3(0, 0.035, -0.02), Color(0.45, 0.28, 0.12))   # tool belt
	m.box(Vector3(0.14, 0.18, 0.08), Vector3(0.30, -0.04, -0.06), Color(0.45, 0.28, 0.12).darkened(0.2))
	m.box(Vector3(0.04, 0.20, 0.04), Vector3(0.30, 0.06, -0.06), Color(0.9, 0.2, 0.15), 0.5)   # screwdriver
	m.box(Vector3(0.20, 0.07, 0.20), Vector3(0, 0.66, 0), Color(0.45, 0.08, 0.08))
	_cache["ht"] = bake(m)
	return _cache["ht"]

static func _hardhat_arm(si: int, wrench: bool) -> ArrayMesh:
	var key := "ha%d%s" % [si, "w" if wrench else "n"]
	if _cache.has(key):
		return _cache[key]
	var sk: Color = SKINS[si]
	var m := Sculpt.new()
	m.box(Vector3(0.18, 0.20, 0.19), Vector3(0, -0.07, 0), Color(0.62, 0.66, 0.72))
	m.box(Vector3(0.15, 0.36, 0.15), Vector3(0, -0.33, 0), sk)
	m.box(Vector3(0.18, 0.17, 0.18), Vector3(0, -0.60, 0), Color(0.85, 0.62, 0.25))       # work glove
	if wrench:
		m.box(Vector3(0.06, 0.06, 0.62), Vector3(0, -0.62, -0.32), METAL, 0.3)
		m.box(Vector3(0.07, 0.20, 0.10), Vector3(0, -0.62, -0.66), SILVER, 0.5)
		m.box(Vector3(0.075, 0.07, 0.06), Vector3(0, -0.62, -0.70), DARK)
	_cache[key] = bake(m)
	return _cache[key]

static func _hardhat_leg() -> ArrayMesh:
	if _cache.has("hl"):
		return _cache["hl"]
	var m := Sculpt.new()
	m.box(Vector3(0.24, 0.74, 0.26), Vector3(0, -0.35, 0), Color(0.28, 0.38, 0.62))
	m.box(Vector3(0.26, 0.13, 0.40), Vector3(0, -0.755, -0.05), Color(0.72, 0.52, 0.22))
	_cache["hl"] = bake(m)
	return _cache["hl"]

# ---- riot cop: navy armour, glowing visor, a big cyan shield on the left arm
static func _riot_head(si: int) -> ArrayMesh:
	var key := "qh%d" % si
	if _cache.has(key):
		return _cache[key]
	var sk: Color = SKINS[si]
	var m := Sculpt.new()
	_face(m, sk, DARK, 0.42, 0.40, 0.42)
	m.box(Vector3(0.48, 0.22, 0.48), Vector3(0, 0.37, 0.0), NAVY)                    # helmet
	m.box(Vector3(0.48, 0.30, 0.20), Vector3(0, 0.20, 0.14), NAVY)
	m.pair(Vector3(0.04, 0.30, 0.30), Vector3(0.23, 0.22, -0.02), NAVY)
	m.box(Vector3(0.46, 0.13, 0.03), Vector3(0, 0.30, -0.25), SHIELD_CYAN, 1.0, Vector3(-0.25, 0, 0))   # visor, up
	m.box(Vector3(0.10, 0.06, 0.03), Vector3(0, 0.44, -0.245), MUSTARD, 0.9)          # badge
	_cache[key] = bake(m)
	return _cache[key]

static func _riot_torso() -> ArrayMesh:
	if _cache.has("qt"):
		return _cache["qt"]
	var m := Sculpt.new()
	m.box(Vector3(0.66, 0.66, 0.38), Vector3(0, 0.33, 0), NAVY)
	m.box(Vector3(0.56, 0.36, 0.06), Vector3(0, 0.42, -0.20), NAVY.darkened(0.3))    # chest plate
	m.box(Vector3(0.56, 0.36, 0.06), Vector3(0, 0.42, 0.20), NAVY.darkened(0.3))
	m.box(Vector3(0.40, 0.09, 0.02), Vector3(0, 0.46, 0.235), Color(1, 1, 1), 0.8)   # white bar on the back
	m.box(Vector3(0.10, 0.10, 0.03), Vector3(-0.15, 0.50, -0.235), MUSTARD, 0.9)
	m.pair(Vector3(0.26, 0.12, 0.44), Vector3(0.36, 0.62, 0.0), NAVY.darkened(0.3))  # shoulder pads
	m.box(Vector3(0.68, 0.08, 0.40), Vector3(0, 0.035, 0), DARK)
	m.box(Vector3(0.20, 0.07, 0.20), Vector3(0, 0.68, 0), Color(0.45, 0.08, 0.08))
	_cache["qt"] = bake(m)
	return _cache["qt"]

# The shield is part of the left arm, built so that it stands upright in front of the body
# when the arm is at its walking angle `th`; `c` is its centre relative to the shoulder.
static func _riot_arm(shield: bool, th: float, c: Vector3, size: Vector3) -> ArrayMesh:
	var key := "qa%s" % ("s" if shield else "b")
	if _cache.has(key):
		return _cache[key]
	var m := Sculpt.new()
	m.box(Vector3(0.20, 0.36, 0.21), Vector3(0, -0.14, 0), NAVY)
	m.box(Vector3(0.17, 0.26, 0.18), Vector3(0, -0.43, 0), NAVY.darkened(0.25))
	m.box(Vector3(0.19, 0.15, 0.19), Vector3(0, -0.61, 0), DARK)
	if shield:
		var inv := Basis(Vector3.RIGHT, -th)
		var r := Vector3(-th, 0, 0)
		var up := Vector3(0, 1, 0)
		var fw := Vector3(0, 0, -1)
		m.box(size, inv * c, SHIELD_CYAN, 0.65, r)
		m.box(Vector3(size.x + 0.06, 0.07, size.z + 0.03), inv * (c + up * (size.y * 0.5)), NAVY, 0.0, r)
		m.box(Vector3(size.x + 0.06, 0.07, size.z + 0.03), inv * (c - up * (size.y * 0.5)), NAVY, 0.0, r)
		m.box(Vector3(size.x * 0.8, 0.16, 0.03), inv * (c + up * 0.18 + fw * 0.04), Color(1, 1, 1), 0.9, r)    # stripe
		m.box(Vector3(size.x * 0.5, 0.10, 0.03), inv * (c + up * 0.40 + fw * 0.04), NAVY, 0.0, r)             # window
	else:
		m.box(Vector3(0.06, 0.06, 0.60), Vector3(0, -0.62, -0.28), DARK)                                         # baton
	_cache[key] = bake(m)
	return _cache[key]

static func _riot_leg() -> ArrayMesh:
	if _cache.has("ql"):
		return _cache["ql"]
	var m := Sculpt.new()
	m.box(Vector3(0.24, 0.72, 0.26), Vector3(0, -0.34, 0), NAVY)
	m.box(Vector3(0.26, 0.16, 0.10), Vector3(0, -0.38, -0.12), NAVY.darkened(0.35))   # knee pad
	m.box(Vector3(0.26, 0.13, 0.40), Vector3(0, -0.755, -0.05), DARK)
	_cache["ql"] = bake(m)
	return _cache["ql"]

# ---- hot-dog vendor: a ketchup-and-mustard cart umbrella strapped to his back
static func _vendor_head(si: int) -> ArrayMesh:
	var key := "vh%d" % si
	if _cache.has(key):
		return _cache[key]
	var sk: Color = SKINS[si]
	var m := Sculpt.new()
	_face(m, sk, DARK, 0.46, 0.42, 0.44)
	m.box(Vector3(0.34, 0.07, 0.05), Vector3(0, 0.155, -0.245), DARK)                      # moustache
	m.box(Vector3(0.40, 0.12, 0.42), Vector3(0, 0.47, 0.0), Color(0.97, 0.97, 0.94), 0.4)  # paper hat
	m.box(Vector3(0.41, 0.04, 0.43), Vector3(0, 0.44, 0.0), KETCHUP, 0.6)
	_cache[key] = bake(m)
	return _cache[key]

static func _vendor_torso() -> ArrayMesh:
	if _cache.has("vt"):
		return _cache["vt"]
	var white := Color(0.95, 0.95, 0.92)
	var m := Sculpt.new()
	m.box(Vector3(0.70, 0.64, 0.42), Vector3(0, 0.33, 0), white)
	m.box(Vector3(0.78, 0.34, 0.54), Vector3(0, 0.20, -0.03), white)                 # belly
	for k in 5:   # striped apron
		m.box(Vector3(0.12, 0.60, 0.03), Vector3(-0.24 + k * 0.12, 0.26, -0.31), KETCHUP if k % 2 == 0 else white, 0.5)
	m.box(Vector3(0.09, 0.20, 0.09), Vector3(-0.36, 0.06, -0.20), KETCHUP, 0.7)      # squeezy bottles on the belt
	m.box(Vector3(0.09, 0.20, 0.09), Vector3(0.36, 0.06, -0.20), MUSTARD, 0.7)
	m.box(Vector3(0.22, 0.07, 0.22), Vector3(0, 0.66, 0), Color(0.45, 0.08, 0.08))
	# the umbrella: pole up the back, eight panels
	m.box(Vector3(0.05, 1.50, 0.05), Vector3(0, 0.80, 0.27), METAL)
	var y := 1.46
	for k in 4:
		m.box(Vector3(1.50, 0.07, 0.62), Vector3(0, y + k * 0.004, 0.27), KETCHUP if k % 2 == 0 else MUSTARD, 0.7, Vector3(0, k * PI * 0.25, 0))
	m.box(Vector3(0.60, 0.10, 0.60), Vector3(0, y + 0.07, 0.27), KETCHUP, 0.7)
	m.box(Vector3(0.10, 0.10, 0.10), Vector3(0, y + 0.16, 0.27), MUSTARD, 0.9)
	_cache["vt"] = bake(m)
	return _cache["vt"]

static func _vendor_arm(si: int, hotdog: bool) -> ArrayMesh:
	var key := "va%d%s" % [si, "h" if hotdog else "n"]
	if _cache.has(key):
		return _cache[key]
	var sk: Color = SKINS[si]
	var m := Sculpt.new()
	m.box(Vector3(0.19, 0.24, 0.20), Vector3(0, -0.09, 0), Color(0.95, 0.95, 0.92))
	m.box(Vector3(0.15, 0.34, 0.15), Vector3(0, -0.36, 0), sk)
	m.box(Vector3(0.17, 0.15, 0.17), Vector3(0, -0.60, 0), sk.darkened(0.05))
	if hotdog:
		m.box(Vector3(0.14, 0.12, 0.40), Vector3(0, -0.70, -0.02), Color(0.90, 0.68, 0.36), 0.3)
		m.box(Vector3(0.09, 0.09, 0.48), Vector3(0, -0.75, -0.02), KETCHUP.darkened(0.15), 0.4)
		m.box(Vector3(0.04, 0.03, 0.36), Vector3(0, -0.80, -0.02), MUSTARD, 0.8)
	else:
		m.box(Vector3(0.03, 0.03, 0.40), Vector3(0.04, -0.62, -0.22), METAL, 0.4)      # tongs
		m.box(Vector3(0.03, 0.03, 0.40), Vector3(-0.04, -0.62, -0.22), METAL, 0.4)
	_cache[key] = bake(m)
	return _cache[key]

static func _vendor_leg() -> ArrayMesh:
	if _cache.has("vl"):
		return _cache["vl"]
	var m := Sculpt.new()
	m.box(Vector3(0.25, 0.76, 0.27), Vector3(0, -0.36, 0), Color(0.22, 0.22, 0.26))
	m.box(Vector3(0.255, 0.10, 0.275), Vector3(0, -0.20, 0), Color(0.95, 0.95, 0.92))
	m.box(Vector3(0.26, 0.10, 0.38), Vector3(0, -0.77, -0.05), Color(0.95, 0.95, 0.95), 0.2)
	_cache["vl"] = bake(m)
	return _cache["vl"]

# ---- cabbie: lit TAXI roof sign on the head, checker band, both hands on the wheel
static func _cabbie_head(si: int) -> ArrayMesh:
	var key := "kh%d" % si
	if _cache.has(key):
		return _cache[key]
	var sk: Color = SKINS[si]
	var m := Sculpt.new()
	_face(m, sk, DARK, 0.44, 0.42, 0.42)
	m.box(Vector3(0.48, 0.09, 0.46), Vector3(0, 0.44, 0.0), Color(0.25, 0.2, 0.17))     # flat cap
	m.box(Vector3(0.40, 0.03, 0.16), Vector3(0, 0.41, -0.28), Color(0.25, 0.2, 0.17))
	m.box(Vector3(0.70, 0.22, 0.22), Vector3(0, 0.60, 0.0), CAB_YELLOW, 1.0)            # the roof sign
	m.box(Vector3(0.36, 0.09, 0.23), Vector3(0, 0.60, 0.0), DARK)
	m.pair(Vector3(0.05, 0.23, 0.23), Vector3(0.36, 0.60, 0.0), DARK)
	_cache[key] = bake(m)
	return _cache[key]

static func _cabbie_torso() -> ArrayMesh:
	if _cache.has("kt"):
		return _cache["kt"]
	var m := Sculpt.new()
	m.box(Vector3(0.60, 0.62, 0.32), Vector3(0, 0.33, 0), CAB_YELLOW, 0.5)
	for k in 6:   # checker band, front and back
		var c := DARK if k % 2 == 0 else Color(1, 1, 1)
		m.box(Vector3(0.10, 0.09, 0.335), Vector3(-0.25 + k * 0.10, 0.40, 0), c, 0.3)
		m.box(Vector3(0.10, 0.09, 0.335), Vector3(-0.25 + k * 0.10, 0.31, 0), Color(1, 1, 1) if k % 2 == 0 else DARK, 0.3)
	m.box(Vector3(0.63, 0.07, 0.35), Vector3(0, 0.035, 0), Color(0.14, 0.10, 0.08))
	m.box(Vector3(0.20, 0.07, 0.20), Vector3(0, 0.66, 0), Color(0.45, 0.08, 0.08))
	# the steering wheel he never let go of
	var wc := Vector3(0, 0.34, -0.66)
	var r := Vector3(-0.5, 0, 0)
	var b := Basis.from_euler(r)
	m.box(Vector3(0.50, 0.06, 0.06), wc + b * Vector3(0, 0.22, 0), DARK, 0.0, r)
	m.box(Vector3(0.50, 0.06, 0.06), wc + b * Vector3(0, -0.22, 0), DARK, 0.0, r)
	m.box(Vector3(0.06, 0.50, 0.06), wc + b * Vector3(0.22, 0, 0), DARK, 0.0, r)
	m.box(Vector3(0.06, 0.50, 0.06), wc + b * Vector3(-0.22, 0, 0), DARK, 0.0, r)
	m.box(Vector3(0.40, 0.05, 0.04), wc, METAL, 0.3, r)
	m.box(Vector3(0.12, 0.12, 0.06), wc, CAB_YELLOW, 0.9, r)
	_cache["kt"] = bake(m)
	return _cache["kt"]

static func _cabbie_arm(si: int) -> ArrayMesh:
	var key := "ka%d" % si
	if _cache.has(key):
		return _cache[key]
	var sk: Color = SKINS[si]
	var m := Sculpt.new()
	m.box(Vector3(0.16, 0.34, 0.17), Vector3(0, -0.13, 0), CAB_YELLOW, 0.5)
	m.box(Vector3(0.13, 0.26, 0.13), Vector3(0, -0.42, 0), sk)
	m.box(Vector3(0.16, 0.15, 0.16), Vector3(0, -0.61, 0), sk.darkened(0.05))
	_cache[key] = bake(m)
	return _cache[key]

static func _cabbie_leg() -> ArrayMesh:
	if _cache.has("kl"):
		return _cache["kl"]
	var m := Sculpt.new()
	m.box(Vector3(0.22, 0.76, 0.24), Vector3(0, -0.36, 0), Color(0.36, 0.34, 0.36))
	m.box(Vector3(0.24, 0.10, 0.36), Vector3(0, -0.77, -0.05), Color(0.95, 0.95, 0.95), 0.2)
	_cache["kl"] = bake(m)
	return _cache["kl"]

# ---- props zombies.gd throws about (shared material, cached)
static func prop(kind: String) -> ArrayMesh:
	var key := "prop_" + kind
	if _cache.has(key):
		return _cache[key]
	var m := Sculpt.new()
	match kind:
		"hotdog":      # the vendor's hot dog, far too big, far too much mustard
			m.box(Vector3(0.30, 0.20, 0.70), Vector3(0, -0.03, 0), Color(0.90, 0.68, 0.36), 0.4)
			m.box(Vector3(0.18, 0.18, 0.86), Vector3(0, 0.08, 0), KETCHUP.darkened(0.1), 0.5)
			for k in 5:
				m.box(Vector3(0.10, 0.06, 0.10), Vector3(0.04 if k % 2 == 0 else -0.04, 0.18, -0.30 + k * 0.15), MUSTARD, 0.9)
		_:             # "marker": a flat warning ring of radius 1 where something is about to land
			for k in 12:
				var a := k * TAU / 12.0
				m.box(Vector3(0.46, 0.02, 0.12), Vector3(cos(a), 0, sin(a)), KETCHUP if k % 2 == 0 else MUSTARD, 1.0, Vector3(0, -a + PI * 0.5, 0))
			m.box(Vector3(0.5, 0.02, 0.1), Vector3.ZERO, KETCHUP, 1.0, Vector3(0, PI * 0.25, 0))
			m.box(Vector3(0.5, 0.02, 0.1), Vector3.ZERO, KETCHUP, 1.0, Vector3(0, -PI * 0.25, 0))
	_cache[key] = bake(m)
	return _cache[key]

# ---------------------------------------------------------------- queries
# Hit boxes in rig-local space: [{ "size": Vector3, "pos": Vector3, "head": bool }]
func hit_shapes() -> Array:
	var up := Basis(Vector3.RIGHT, -(_hunch + _lean_gain * 0.6))   # typical walking lean
	var hip := Vector3(0, _leg * 0.96, 0)
	var head_c: Vector3 = (hip + up * Vector3(0, _neck + (_head_size.y + _hat) * 0.5, 0)) * _s
	var chest_c: Vector3 = (hip + up * Vector3(0, _neck * 0.5, 0)) * _s
	var arm_w := 0.0 if type == "bloater" else 0.24
	var out := [
		{"size": Vector3(_tw + arm_w, _neck + 0.06, maxf(_td, 0.36) + 0.08) * _s, "pos": chest_c, "head": false},
		{"size": (_head_size + Vector3(0.08, _hat + 0.04, 0.08)) * _s, "pos": head_c, "head": true},
	]
	if _leg > 0.4:
		out.append({"size": Vector3(_leg_x * 2.0 + 0.3, _leg, 0.36) * _s, "pos": Vector3(0, _leg * 0.5, 0) * _s, "head": false})
	else:
		out[0].size.y += _leg * _s.y
		out[0].pos.y -= _leg * _s.y * 0.5
	if _has_shield:   # stops bullets, takes no damage (zombies.gd decides from "part")
		out.append({"size": (_shield_size + Vector3(0.06, 0.06, 0.07)) * _s, "pos": _shield_c * _s, "head": false, "part": "shield"})
	return out

# The same boxes (same order and sizes) placed for a body that is upright on a wall or in the
# air (set_mode other than M_GROUND). zombies.gd moves its hit boxes when the mode changes.
func climb_shapes() -> Array:
	var out := hit_shapes()
	var body_y := _leg + _neck * 0.5
	if _leg <= 0.4:
		body_y -= _leg * 0.5
	out[0].pos = Vector3(0, body_y, 0) * _s
	out[1].pos = Vector3(0, _leg + _neck + (_head_size.y + _hat) * 0.5, 0) * _s
	return out

# World position of the head centre.
func head_position() -> Vector3:
	if not is_inside_tree():
		return position + Vector3(0, height - _head_size.y * 0.5 * _s.y, 0)
	return _head.global_transform * Vector3(0, _head_size.y * 0.5, 0)

# ---------------------------------------------------------------- animation
# Advance the animation. speed = how fast the zombie is moving over the ground (m/s).
func tick(dt: float, speed: float) -> void:
	if _dead:
		return
	_frame = Engine.get_process_frames()
	_pose_now(dt, speed)

func _process(dt: float) -> void:
	if _dead:
		_death_step(dt)
	elif _rise_t >= 0.0:
		if _frame != Engine.get_process_frames():
			_pose_now(dt, 0.0)   # nobody ticked us this frame: keep rising anyway
	else:
		set_process(false)

func _pose_now(dt: float, speed := 0.0) -> void:
	_t += dt
	_spd = lerpf(_spd, speed, 1.0 - exp(-8.0 * dt))
	_walk = lerpf(_walk, clampf(speed / (_ref_speed * 0.5), 0.0, 1.0), 1.0 - exp(-9.0 * dt))
	_phase += dt * minf(_spd * _cad, 24.0)
	_fl *= exp(-7.0 * dt)
	_step_scale(dt)
	if _flash_t > 0.0:
		_flash_t -= dt
		if _flash_t <= 0.0:
			_apply_mat()
	# idle twitch
	_twitch_next -= dt
	if _twitch_next <= 0.0:
		_twitch_next = randf_range(1.6, 5.0)
		_twitch = 0.28
	_twitch = maxf(_twitch - dt, 0.0)
	var tw := sin(_twitch * 45.0) * _twitch * 2.2
	# telegraph blink (set_alert), shield arm, a hard hat in flight
	if _alert > 0.0:
		var on := sin(_t * (16.0 + 26.0 * _alert)) > 0.0
		if on != _alert_on:
			_alert_on = on
			_apply_mat()
	elif _alert_on:
		_alert_on = false
		_apply_mat()
	if _guard != _guard_to:
		_guard = move_toward(_guard, _guard_to, dt * 7.0)
	if _hat_node != null:
		_hat_step(dt)

	var s := sin(_phase)
	var w := _walk
	var idle := 1.0 - w
	var run := clampf(_spd / _ref_speed, 0.0, 1.4)

	# attack: wind-up pulls everything back, strike throws it forward
	var wu := _windup
	var sk := 0.0
	if _strike_t >= 0.0:
		_strike_t += dt
		if _strike_t < 0.09:
			var q := _strike_t / 0.09
			wu = maxf(wu, _strike_w * (1.0 - q))
			sk = q * q
		elif _strike_t < 0.55:
			sk = 1.0 - smoothstep(0.0, 1.0, (_strike_t - 0.09) / 0.46)
		else:
			_strike_t = -1.0
	# rising out of the ground
	var rise := 0.0
	if _rise_t >= 0.0:
		_rise_t += dt
		var r := clampf(_rise_t / _rise_d, 0.0, 1.0)
		var e := 1.0 - (1.0 - r) * (1.0 - r)
		rise = 1.0 - smoothstep(0.55, 1.0, r)
		_pose.position = Vector3(0, -(1.0 - e) * (height + 0.15), 0)
		_pose.rotation = Vector3(0, 0, sin(r * 16.0) * 0.13 * (1.0 - r))
		if r >= 1.0:
			_rise_t = -1.0
			_pose.position = Vector3.ZERO
			_pose.rotation = Vector3.ZERO
			_sqv += 3.5   # pop!
			set_process(false)
	if _mode != M_GROUND:
		_pose_mode(dt, sin(_phase), wu)
		return

	# legs and hips
	var amp := _stride * w
	var limp_l := 1.0 - _limp if _limp_side < 0.0 else 1.0
	var limp_r := 1.0 - _limp if _limp_side > 0.0 else 1.0
	var bob := -absf(s) * 0.07 * w * (_leg / 0.8) - _limp * 0.07 * w * maxf(s * _limp_side, 0.0)
	bob -= wu * 0.05
	_legs[0].rotation.x = s * amp * limp_l - sk * 0.25
	_legs[1].rotation.x = -s * amp * limp_r + sk * 0.35 + wu * 0.2
	_legs[0].position.y = _leg + bob
	_legs[1].position.y = _leg + bob

	# chest
	var lean := _hunch + _lean_gain * run * w
	var cx := -lean + wu * 0.5 - sk * 0.65 + _fl.z * 0.65 + rise * 0.25
	var cz := s * 0.07 * w + sin(_t * 1.1 + _ph) * 0.035 * idle + _limp * _limp_side * 0.16 * s * w - _fl.x * 0.6
	var cy := -s * 0.14 * w + tw * 0.15
	_chest.rotation = Vector3(cx, cy, cz)
	_chest.position = Vector3(0, _leg + bob, -sk * 0.22 + wu * 0.08)

	# head
	_head.rotation = Vector3(
		lean * 0.75 - wu * 0.3 + sk * 0.3 + _fl.z * 0.6 + sin(_t * 2.3 + _ph) * 0.04,
		sin(_t * 0.7 + _ph) * 0.22 * idle + tw * 0.5,
		_tilt0 + sin(_phase * 0.5 + _ph) * 0.13 + tw + _swell * sin(_t * 31.0) * 0.12)

	# arms
	var fl_len := _fl.length()
	for a in 2:
		var side := a * 2.0 - 1.0
		var base: float = _arm_base[a]
		var ang := base + sin(_phase + a * PI + 0.7) * _arm_swing * w + sin(_t * 1.7 + a * 2.0 + _ph) * 0.05
		ang -= idle * 0.12 * minf(base, 1.0)
		ang = lerpf(ang, _arm_up[a], wu)
		ang = lerpf(ang, 0.55, sk)
		ang = lerpf(ang, 3.0, rise)
		ang += fl_len * 0.7 + _swell * (0.5 + sin(_t * 23.0 + a) * 0.25)
		var out := _splay + wu * 0.35 + rise * 0.2 + fl_len * 0.3
		if a == 0 and _has_shield:
			out += (1.0 - _guard) * 1.25      # guard down: the shield swings out of the way
		_arms[a].rotation = Vector3(ang, 0, side * out)

# The poses of a body that is not walking on the ground (monkeys): s = sin of the limb cycle.
func _pose_mode(dt: float, s: float, wu: float) -> void:
	_legs[0].position.y = _leg
	_legs[1].position.y = _leg
	_chest.position = Vector3(0, _leg, 0)
	match _mode:
		M_CLIMB:    # belly to the wall, hand over hand
			_legs[0].rotation.x = 0.9 + s * 0.6
			_legs[1].rotation.x = 0.9 - s * 0.6
			_chest.rotation = Vector3(0.1, s * 0.14, s * 0.1 - _fl.x * 0.5)
			_head.rotation = Vector3(0.35, sin(_t * 2.6 + _ph) * 0.6, _tilt0)
			_arms[0].rotation = Vector3(2.75 + s * 0.5, 0, -0.12)
			_arms[1].rotation = Vector3(2.75 - s * 0.5, 0, 0.12)
		M_PERCH:    # back to the wall, hanging by one arm; winds up into a screech
			var shake := sin(_t * 38.0) * wu
			_legs[0].rotation.x = -0.75
			_legs[1].rotation.x = -0.55 + shake * 0.15
			_chest.rotation = Vector3(-0.5 - wu * 0.25, sin(_t * 2.0 + _ph) * 0.12, shake * 0.06)
			_head.rotation = Vector3(0.15 + wu * 0.35, sin(_t * 1.3 + _ph) * 0.3 * (1.0 - wu), _tilt0 + shake * 0.12)
			_arms[0].rotation = Vector3(3.9, 0, -0.25)
			_arms[1].rotation = Vector3(lerpf(0.7, 2.7, wu) + shake * 0.4, 0, 0.3 + 0.5 * wu)
		M_AIR:      # the leap: arms out front, legs trailing
			_legs[0].rotation.x = -0.6
			_legs[1].rotation.x = -0.95
			_chest.rotation = Vector3(-0.95, 0, sin(_t * 9.0) * 0.08)
			_head.rotation = Vector3(0.8, 0, _tilt0)
			_arms[0].rotation = Vector3(2.6, 0, -0.75)
			_arms[1].rotation = Vector3(2.6, 0, 0.75)
		_:          # knocked off: head over heels, everything flailing
			_spin += dt * 11.0
			var c := Vector3(0, height * 0.45, 0)
			var rot := Basis(Vector3.RIGHT, _spin)
			_pose.transform = Transform3D(rot, c - rot * c)
			var f := sin(_t * 24.0)
			_legs[0].rotation.x = f * 0.9
			_legs[1].rotation.x = -f * 0.9
			_chest.rotation = Vector3(-0.3, 0, 0)
			_head.rotation = Vector3(0.3, 0, f * 0.3)
			_arms[0].rotation = Vector3(2.2 + f, 0, -1.0)
			_arms[1].rotation = Vector3(2.2 - f, 0, 1.0)

# A knocked-off hard hat: flies, bounces once, lies there for a moment.
func _hat_step(dt: float) -> void:
	_hat_t += dt
	if _hat_t > 1.8:
		_hat_node.queue_free()
		_hat_node = null
		return
	var hp := _hat_node.position
	if hp.y > 0.12 or _hat_vel.y > 0.0:
		_hat_vel.y -= 20.0 * dt
		hp += _hat_vel * dt
		_hat_node.rotate_object_local(Vector3(1, 0, 0.3).normalized(), 12.0 * dt)
		if hp.y <= 0.12:
			hp.y = 0.12
			if _hat_vel.y < -4.0:
				_hat_vel = Vector3(_hat_vel.x * 0.5, -_hat_vel.y * 0.35, _hat_vel.z * 0.5)
			else:
				_hat_vel = Vector3.ZERO
				_hat_node.rotation = Vector3(0, _hat_node.rotation.y, 0)
		_hat_node.position = hp

func _step_scale(dt: float) -> void:
	# squash-and-stretch spring
	_sqv += (-190.0 * _sq - 15.0 * _sqv) * dt
	_sq = clampf(_sq + _sqv * dt, -0.4, 0.4)
	var y := 1.0 + _sq + _windup * 0.05
	var xz := 1.0 - _sq * 0.5
	if _swell > 0.0:
		var pulse := sin(_t * (8.0 + 20.0 * _swell))
		xz *= 1.0 + _swell * (0.26 + 0.08 * pulse)
		y *= 1.0 + _swell * (0.10 - 0.06 * pulse)
		var lvl := 0
		if _swell > 0.04:
			lvl = clampi(int(_swell * 2.99) + (1 if pulse > 0.0 else 0), 0, 3)
		if lvl != _mat_level:
			_mat_level = lvl
			_apply_mat()
	elif _mat_level != 0:
		_mat_level = 0
		_apply_mat()
	_parts.scale = Vector3(_s.x * xz, _s.y * y, _s.z * xz)

func _apply_mat() -> void:
	var m: Material = _flash_mat if _flash_t > 0.0 else (_alert_mat if _alert_on else _levels[_mat_level])
	_chest.material_override = m
	_head.material_override = m
	for a in 2:
		_arms[a].material_override = m
		_legs[a].material_override = m

# Attack telegraph pose: 0 = normal, 1 = fully wound up and about to strike.
func set_windup(k: float) -> void:
	_windup = clampf(k, 0.0, 1.0)

# The swing itself (called once at the moment the hit is resolved).
func strike() -> void:
	_strike_w = maxf(_windup, 0.6)
	_windup = 0.0
	_strike_t = 0.0
	_sqv += 1.5

# Body mode (monkeys): M_GROUND walking, M_CLIMB on a wall facing it, M_PERCH on a wall facing
# out (set_windup drives its screech), M_AIR leaping, M_TUMBLE knocked off and falling.
func set_mode(mode: int) -> void:
	if mode == _mode:
		return
	_mode = mode
	_spin = 0.0
	if _rise_t < 0.0 and not _dead:
		_pose.transform = Transform3D.IDENTITY

# 0..1 "about to do something nasty" blink (a red flicker that speeds up); 0 switches it off.
func set_alert(k: float) -> void:
	_alert = clampf(k, 0.0, 1.0)

# Riot shield up (in front of the body) or swung aside.
func set_guard(on: bool) -> void:
	_guard_to = 1.0 if on else 0.0

func has_hat() -> bool:
	return _has_hat

# Hard hat: knock it off (the head underneath is bare from now on); it flies along `dir`.
func knock_hat(dir: Vector3) -> void:
	if not _has_hat:
		return
	_has_hat = false
	_head.mesh = _bare_head
	if not is_inside_tree():
		return
	_hat_node = MeshInstance3D.new()
	_hat_node.mesh = _hardhat_hat()
	_hat_node.top_level = true
	add_child(_hat_node)
	_hat_node.global_transform = Transform3D(Basis.from_scale(_s), _head.global_transform * Vector3(0, 0.5, 0))
	var flat := Vector3(dir.x, 0, dir.z)
	flat = flat.normalized() if flat.length_squared() > 0.0001 else Vector3(0, 0, 1)
	_hat_vel = flat * 3.5 + Vector3(randf_range(-1.0, 1.0), 6.0, randf_range(-1.0, 1.0))
	_hat_t = 0.0

# React to a hit coming from direction `dir` (world space), strength 0..1.
func flinch(dir: Vector3, strength: float) -> void:
	var l := _local_dir(dir)
	_fl = (_fl + l * strength).limit_length(1.2)
	_sqv -= 2.6 * strength

func _local_dir(dir: Vector3) -> Vector3:
	var l := Vector3(dir.x, 0, dir.z).rotated(Vector3.UP, -rotation.y)
	return l.normalized() if l.length() > 0.01 else Vector3(0, 0, 1)

# Brief white flash on being hit.
func flash(duration := 0.06) -> void:
	var was := _flash_t > 0.0
	_flash_t = maxf(duration, 0.02)
	if not was:
		_apply_mat()

# 0..1 "about to explode" look (bloater).
func set_swell(k: float) -> void:
	_swell = clampf(k, 0.0, 1.0)

# Headshot: remove the head.
func pop_head() -> void:
	_head.visible = false

# Entrance animation (climbing out / popping up), `duration` seconds.
func spawn_rise(duration: float) -> void:
	_rise_d = maxf(duration, 0.05)
	_rise_t = 0.0
	_pose.position = Vector3(0, -(height + 0.15), 0)
	set_process(true)

func set_label(text: String, color := Color.WHITE) -> void:
	if _label == null:
		if text == "":
			return
		_label = Label3D.new()
		_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_label.font_size = 24
		_label.pixel_size = 0.006
		_label.outline_size = 6
		_label.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		_label.position.y = height + 0.3
		add_child(_label)
	_label.text = text
	_label.modulate = color
	_label.visible = _label_on and text != ""

func set_label_visible(on: bool) -> void:
	_label_on = on
	if _label:
		_label.visible = on and _label.text != ""

# ---------------------------------------------------------------- dying
# Play the death. Returns seconds until the rig has finished and may be freed.
func die(dir: Vector3, headshot: bool) -> float:
	if _dead:
		return maxf(_death_len - _death_t, 0.0)
	_dead = true
	_rise_t = -1.0
	_windup = 0.0
	_mode = M_GROUND
	_guard_to = 0.0
	if _alert_on or _alert > 0.0:
		_alert = 0.0
		_alert_on = false
		_apply_mat()
	_fall = _local_dir(dir)
	var back := _fall.z    # > 0: knocked onto its back, < 0: shot from behind
	var weights := [3.0 if absf(back) > 0.3 else 1.5, 0.6 if back > 0.3 else 2.0, 1.5, 1.5, 4.0 if headshot else 0.7, 1.2, 0.0]
	if type == "sanitation" or type == "bloater" or type == "riot" or type == "vendor":
		weights[D_BACKFLIP] = 0.0   # too heavy to fly
		weights[D_HOP] = 0.6
	elif type == "rat":             # too low for the sitting and kneeling gags: flip or flop
		weights = [2.0, 0.0, 0.0, 0.0, 3.0, 0.0, 0.0]
	elif type == "monkey":
		weights[D_SPIN_SIT] = 0.0
		weights[D_KNEES] = 0.0
		weights[D_BACKFLIP] += 2.0
	if _swell >= 0.5:
		_death = D_POP
	else:
		if _last_death >= 0:
			weights[_last_death] = 0.0
		var total := 0.0
		for x in weights:
			total += x
		var pick := randf() * total
		_death = D_PLANK
		for k in weights.size():
			pick -= weights[k]
			if pick <= 0.0:
				_death = k
				break
		_last_death = _death
	return _start_death()

func _start_death() -> float:
	_death_t = 0.0
	_bumped = false
	_pose.position = Vector3.ZERO
	_pose.rotation = Vector3.ZERO
	_d0 = [_arms[0].rotation.x, _arms[1].rotation.x, _legs[0].rotation.x, _legs[1].rotation.x, _chest.rotation.x, _head.rotation.x]
	match _death:
		D_FACEPLANT:
			_fall = Vector3(0, 0, -1)
		D_HOP:
			_fall = Vector3(1.0 if _fall.x >= 0.0 else -1.0, 0, 0)
	_death_len = [1.7, 1.8, 2.3, 2.0, 1.8, 2.0, 0.3][_death]
	set_process(true)
	return _death_len

static func _bounce(q: float) -> float:
	if q < 0.3636:
		return 7.5625 * q * q
	if q < 0.7273:
		q -= 0.5455
		return 7.5625 * q * q + 0.75
	if q < 0.9091:
		q -= 0.8182
		return 7.5625 * q * q + 0.9375
	q -= 0.9545
	return 7.5625 * q * q + 0.984375

# tip the whole body over toward `f` (rig-local), pivoting at the feet
func _tip(f: Vector3, ang: float, lie: float) -> void:
	_pose.basis = Basis(Vector3.UP.cross(f).normalized(), ang)
	_pose.position.y = sin(clampf(ang, 0.0, PI * 0.5)) * lie

func _limbs(k: float, a0: float, a1: float, l0: float, l1: float, cx: float, hx: float) -> void:
	_arms[0].rotation.x = lerpf(_d0[0], a0, k)
	_arms[1].rotation.x = lerpf(_d0[1], a1, k)
	_legs[0].rotation.x = lerpf(_d0[2], l0, k)
	_legs[1].rotation.x = lerpf(_d0[3], l1, k)
	_chest.rotation.x = lerpf(_d0[4], cx, k)
	_head.rotation.x = lerpf(_d0[5], hx, k)

func _bump(strength: float) -> void:
	if not _bumped:
		_bumped = true
		_sqv -= strength

func _death_step(dt: float) -> void:
	_death_t += dt
	_t += dt
	var t := _death_t
	var k := minf(t / 0.12, 1.0)
	var lie_back := maxf(_td * 0.5, 0.17) * _s.z
	var lie_side := _tw * 0.5 * _s.x
	_step_scale(dt)
	if _flash_t > 0.0:
		_flash_t -= dt
		if _flash_t <= 0.0:
			_apply_mat()
	if position.y > 0.0:    # died up a wall or in mid-air: drop to the street
		_vy += 28.0 * dt
		position.y = maxf(position.y - _vy * dt, 0.0)
	if _hat_node != null:
		_hat_step(dt)
	match _death:
		D_PLANK:   # stiff as a board, straight over, one bounce
			var q := clampf(t / 0.62, 0.0, 1.0)
			_tip(_fall, PI * 0.5 * _bounce(q), lie_back)
			var kick := sin(q * PI) * 0.8
			_limbs(k, 2.7, 2.9, kick, -kick * 0.5, 0.15 * sin(q * PI), 0.3)
			_arm_z(0.5 * q)
		D_FACEPLANT:   # windmill the arms, lose, eat pavement, feet kick up
			if t < 0.42:
				_tip(_fall, -0.2 * sin(t / 0.42 * PI), lie_back)
				_limbs(k, _d0[0] + t * 22.0, _d0[1] + t * 22.0 + PI, 0.3 * sin(t * 30.0), -0.3 * sin(t * 30.0), 0.2, 0.3)
				_arm_z(0.5)
			else:
				var q := clampf((t - 0.42) / 0.3, 0.0, 1.0)
				_tip(_fall, PI * 0.5 * q * q, lie_back)
				var u := maxf(t - 0.72, 0.0)
				var legs := 0.0 if q < 1.0 else -1.1 * exp(-u * 4.0) * absf(cos(u * 10.0))
				if q >= 1.0:
					_bump(3.0)
				_limbs(1.0, 2.9, 2.8, legs, legs * 0.7, 0.0, 0.25)
				_arm_z(0.5 + 0.3 * q)
		D_SPIN_SIT:   # pirouette, sit down hard, flop onto the back
			var q1 := clampf(t / 0.9, 0.0, 1.0)
			var yaw := (1.0 - (1.0 - q1) * (1.0 - q1)) * TAU * 2.0 * (1.0 if _fall.x >= 0.0 else -1.0)
			var q2 := smoothstep(0.45, 0.85, t)
			var q3 := _bounce(clampf((t - 1.15) / 0.45, 0.0, 1.0)) if t > 1.15 else 0.0
			_pose.basis = Basis(Vector3.UP, yaw)
			_pose.position.y = -(_leg - 0.13) * _s.y * q2
			if q2 >= 1.0:
				_bump(3.5)
			_limbs(k, lerpf(0.3, 2.9, q3), lerpf(0.3, 2.9, q3), 1.5 * q2, 1.5 * q2, 1.45 * q3 - 0.15 * q2 * (1.0 - q3), -0.3 * q2 + 0.5 * q3)
			_arm_z(1.4 * (1.0 - q3) + 0.3)
		D_KNEES:   # drops to the knees, thinks about it, tips forward
			var q1 := smoothstep(0.0, 0.26, t)
			var q2 := _bounce(clampf((t - 0.85) / 0.4, 0.0, 1.0)) if t > 0.85 else 0.0
			_pose.position.y = -(_leg - 0.14) * _s.y * q1
			if q1 >= 1.0:
				_bump(3.0)
			var sway := sin(t * 8.0) * 0.14 * q1 * (1.0 - q2)
			_limbs(k, lerpf(0.1, 2.8, q2), lerpf(0.1, 2.8, q2), -1.5 * q1, -1.5 * q1, sway - 1.5 * q2, -0.55 * (1.0 - q2) + 0.2 * q2)
			_chest.rotation.z = sway * 0.6
			_arm_z(0.15)
		D_BACKFLIP:   # launched: one and a quarter turns, lands flat on its back
			var q := clampf(t / 0.75, 0.0, 1.0)
			var e := 1.0 - (1.0 - q) * (1.0 - q) * 0.6 - 0.4 * (1.0 - q)
			var rot := Basis(Vector3.UP.cross(_fall).normalized(), (TAU + PI * 0.5) * e)
			var c := Vector3(0, height * 0.5, 0)
			var u := maxf(t - 0.75, 0.0)
			var target := _fall * (1.1 * q) + Vector3.UP * (lerpf(height * 0.5, lie_back, q) + 3.6 * q * (1.0 - q)
				+ absf(sin(u * 13.0)) * 0.18 * exp(-u * 6.0))
			_pose.transform = Transform3D(rot, target - rot * c + _fall * (height * 0.5 * q))
			_limbs(k, 2.9, 2.6, 0.7 * sin(q * PI), -0.5 * sin(q * PI), 0.0, 0.3)
			_arm_z(0.6)
		D_HOP:   # hops on one leg, arms flapping, then timber sideways
			var side := _fall.x
			if t < 0.7:
				_pose.position.y = absf(sin(t * TAU * 1.45)) * 0.22
				_pose.basis = Basis(Vector3.UP.cross(_fall).normalized(), 0.3 * t / 0.7 + sin(t * 20.0) * 0.05)
				_arm_z(1.2 + sin(t * 26.0) * 0.5)
			else:
				var q := clampf((t - 0.7) / 0.42, 0.0, 1.0)
				_tip(_fall, lerpf(0.3, PI * 0.5, _bounce(q)), lie_side)
				_arm_z(1.2)
			_limbs(k, 0.4, 0.4, 1.1 if side < 0.0 else 0.0, 1.1 if side > 0.0 else 0.0, 0.0, 0.2)
		D_POP:   # bloater going off: balloon, then gone
			var q := t / 0.3
			var sc := 1.0 + 0.5 * sin(minf(q, 0.5) * PI) if q < 0.5 else maxf(1.5 * (1.0 - (q - 0.5) * 2.0), 0.01)
			_pose.scale = Vector3.ONE * sc
	if _label:
		if t < 0.8:
			_label.position.y += dt * 1.3
	# sink into the street
	var ts := _death_len - 0.35
	if t > ts and _death != D_POP:
		var q := clampf((t - ts) / 0.35, 0.0, 1.0)
		scale = Vector3(1.0 + 0.2 * q, maxf(1.0 - q, 0.02), 1.0 + 0.2 * q)
		if _label:
			_label.visible = false
	if t >= _death_len:
		visible = false
		set_process(false)

func _arm_z(z: float) -> void:
	_arms[0].rotation.z = -z
	_arms[1].rotation.z = z
