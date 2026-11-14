# Zombie Bonk — module contract

This file is the frozen interface between the game's scripts. Each script has one owner
during a parallel work sprint; nobody edits a file they do not own. Anything listed here
may be relied on by other files, so **signatures and meanings below must not change**
(adding new things is fine — report them so they can be wired).

## Ground rules
- Godot 4.3, GDScript only. Web export: WebGL2, Compatibility renderer, single-threaded, runs on phones.
- No imported assets. Geometry, textures and sound are generated in code.
- Base render size 640x360 (optionally 960x540), stretch mode `viewport`, aspect `expand`,
  nearest-neighbour upscale. Lay out 2D from `get_viewport().get_visible_rect().size`.
- Phones matter: no per-frame node creation, pool effects, share materials (`B.mat` caches by
  colour — do not create a new colour per object), few draw calls, at most ~7 unshadowed OmniLights.
- Tone: comedic, blocky, original designs. New York street intersection at dusk.
- Map facts are in `layout.gd`; ground is flat at y = 0; +Y up; characters face -Z.

## Who owns what
| File | Owner (sprint 2) | Role |
|---|---|---|
| `main.gd`, `layout.gd`, `build.gd`, `nav.gd`, `SPECS.md` | lead | game flow, glue, shared helpers |
| `sfx.gd` | audio | all sound |
| `models.gd`, `zombie_rig.gd`, `textures.gd` (new, optional) | art | character/gun looks and animation |
| `zombies.gd` | zombies | types, AI, spawning, wave pacing |
| `upgrades.gd`, `hud.gd` | upgrades+UI | upgrade pool, draft screen, HUD |
| `fx.gd`, `controls.gd` | juice | visual effects, camera feel, input |
| `world.gd`, `clutter.gd` | (not in this sprint — do not edit) | city and props |

## main.gd (lead) — what other modules may read
- `main.player: CharacterBody3D` (feet at `position`, eye at +1.6), `main.cam: Camera3D`, `main.nav`, `main.fx`, `main.sfx`,
  `main.hud`, `main.upgrades`, `main.zombies`, `main.wave: int`, `main.hp: float`, `main.dead: bool`.
- `main.stat(name) -> float` — a tunable after upgrades. Base values (`main.BASE`):
  `pellets 5`, `spread 0.03`, `damage 25` (per pellet), `head_mult 2.4`, `fire_cd 0.16`, `reload_time 0.9`,
  `max_ammo 8`, `move_speed 9`, `dash_cd 0.8`, `dash_speed 28`, `max_hp 100`, `wave_heal 25`,
  `heal_on_headshot 0`, `shove_cd 1.2`, `shove_reach 3.5`, `shove_arc 80` (degrees), `shove_force 9`,
  `shove_damage 0`, `explosive_radius 0`, `score_mult 1`, `combo_time 2`.
- Flow: title → `begin_game` → `next_wave` → `zombies.start_wave(n)` … `wave_cleared` → 2 s rest →
  `upgrades.roll(3)` → `hud.show_upgrades` → pick → `upgrades.take` → `next_wave`.
- Debug switches after `--`: `--autostart --god --pos=x,z --yaw=deg --pitch=deg --shot=/abs.png --t=sec --navtest --wave=n --hires`.

## nav.gd (lead)
- `nav.direction(from: Vector3, to: Vector3) -> Vector3` unit direction to walk (routes round props/corners).
- `nav.is_blocked(p: Vector3) -> bool` — true inside props/buildings. `nav.update(target)` is called by main each frame.

## zombies.gd (extends Node3D)
- `setup(main: Node3D)`; `start_wave(n: int)`; `update(dt: float)` (main calls every frame while playing);
  `alive_count() -> int` (alive + still to spawn); `clear()`; `list: Array` of live zombie Dictionaries,
  each with at least `rig: Node3D` (its `position` is the zombie's feet), `type: String`, `hp: float`, `dead: bool`.
- `hit(z: Dictionary, dmg: float, headshot: bool, pos: Vector3, dir: Vector3)` — main calls for each pellet;
  `z` is the `"zombie"` meta of the `Area3D` hit box, which also carries meta `"head": bool`.
- `shove(origin, forward, reach, arc_deg, force) -> int`; `damage_radius(pos, radius, dmg) -> int`.
- Signals: `zombie_hit(pos, dir, headshot)`, `zombie_killed(info)` with `info = {pos, head_pos, dir, headshot, type, skin, score_mult}`,
  `player_hit(dmg, from_pos)`, `wave_cleared(wave)`.
- Zombies never use physics bodies for movement; they move their rig's `position`/`rotation.y` and must stay
  out of `nav.is_blocked` cells and inside `L.clamp_to_streets`.
- Zombie types (ids, frozen): `commuter` (standard), `delivery` (fast, weak, lunges), `bloater` (slow, swells then
  explodes, hurting player and zombies), `sanitation` (huge slow boss).
- zombies.gd calls `main.fx.zombie_spawn(pos)`, `main.fx.explosion(pos, radius)` and `main.sfx.play_at(...)` itself;
  hit/kill effects and sounds are triggered by main from the signals — do not double them.

## models.gd / zombie_rig.gd
- `Models.make_zombie(type: String, rng: RandomNumberGenerator) -> Node3D` returns a rig (script `zombie_rig.gd`).
- `Models.make_gun() -> Node3D` first-person gun, barrel along -Z, with a child `Node3D` named `Muzzle` at the barrel tip.
  main positions/scales the gun and animates recoil by moving the whole node.
- `Models.make_player_body() -> Node3D` third-person body, feet at y 0, facing -Z.
- `Models.gun_pump(gun, k)` slides the pump (k 0..1); `Models.prewarm()` fills the mesh cache at start-up.
- Rig API (zombies.gd drives it; the rig never moves its own root transform except in `die`/`spawn_rise`):
  - vars `type: String`, `height: float` (m), `radius: float` (m), `skin: Color`
  - `build(type, rng)` (called by Models), `hit_shapes() -> [{size: Vector3, pos: Vector3, head: bool}]` (rig-local boxes)
  - `head_position() -> Vector3` (world)
  - `tick(dt: float, speed: float)` every frame; `speed` = ground speed in m/s (0 = standing)
  - `set_windup(k: float)` 0..1 attack telegraph pose; `strike()` the swing
  - `flinch(dir: Vector3, strength: float)` 0..1; `flash(duration := 0.06)` white hit flash
  - `set_swell(k: float)` 0..1 about-to-explode look; `pop_head()`
  - `die(dir: Vector3, headshot: bool) -> float` plays the death, returns seconds until it may be freed
  - `spawn_rise(duration: float)` entrance animation
  - `set_label(text: String, color := Color.WHITE)`, `set_label_visible(on: bool)`

## sfx.gd (extends Node)
- `setup()`, `play(name: String, pitch := 1.0, volume_db := 0.0)`, `play_at(name, pos: Vector3, pitch := 1.0)`,
  `set_listener(node: Node3D)`, `set_music(on: bool)`, `set_intensity(k: float)` (0 calm … 1 full horde),
  `set_volume(k)`, `get_volume()`, `toggle_mute() -> bool`, `is_muted()`.
- Unknown names are ignored silently. Frozen names: `shoot pump reload empty dash jump land hurt death_player
  hit headshot kill shove wave_start wave_clear upgrade_pick ui_click zombie_spawn zombie_groan zombie_windup
  zombie_attack bloater_swell explode boss_step`.
- Called by: main (player and scoring sounds), zombies.gd (`zombie_*`, `bloater_swell`, `explode`, `boss_step` via `play_at`),
  hud.gd (`ui_click`).

## upgrades.gd (extends RefCounted)
- `reset()`, `roll(n: int, rng) -> [{id, title, desc, color}]` (empty = no draft), `take(id)`, `level(id) -> int`,
  `stat(name: String, base: float) -> float` for the stat names listed under main.gd.

## hud.gd (extends CanvasLayer)
- Existing: `build`, `set_touch_mode`, `button_rect(name) -> Rect2` (real viewport rect), `button_active(name)`,
  `stick_zone`, `set_stick`, `stick_radius`, `set_button_down`, `set_sens`, `update_stats(d)`, `show_message`,
  `clear_message`, `show_title`, `show_game_over(score, wave)`, `on_hit(headshot)`, `on_kill(points, headshot)`, `on_wave(n)`, `BUTTON_NAMES`.
- `update_stats` keys: `hp, max_hp, ammo, max_ammo, reloading, reload_frac, score, wave, combo, combo_frac, hurt,
  dash_ready, shove_ready, zombies_left` (read with `d.get(key, default)`).
- `modal_open() -> bool`; `show_upgrades(cards, on_pick: Callable)` shows the draft, handles its own taps/clicks/keys 1-3
  and calls `on_pick.call(id)` exactly once; `set_quality_label(text)`.
- `BUTTON_NAMES` gains `"shove"` (touch action button) and `"res"` (small top-right button, shown on desktop too).
- Must look right at viewport heights 360 and 540 (everything is scaled by `min(width / 640, height / 360)`).
- Upgrade card dictionaries also carry `icon`, `level` and `max` for the draft screen.

## controls.gd (extends Node)
- Vars `game_active` (set by main), `touch_mode`, `move`, `fire`, `jump`, `sens_level`; `setup(hud)`, `take_look()`,
  `toggle_fullscreen()`, `set_sens_level()`.
- Signals: `dash`, `reload`, `toggle_view`, `start_pressed`, `shove`, `toggle_quality`, `toggle_mute`.
- While `hud.modal_open()` is true, controls emits nothing and leaves all input to the HUD.
- Never use `InputEventScreenDrag.relative`/`screen_relative` (Godot web bug #94346) — track positions per touch index.

## fx.gd (extends Node3D)
- Existing: `setup(cam)`, `attach_gun(gun)`, `add_street_lights`, `add_subway_globes`, `on_shoot`, `impact(pos, normal)`,
  `zombie_hit(pos, dir, headshot)`, `zombie_death(head_pos, skin, headshot)`, `player_hurt(dmg)`, `shake_offset()`,
  `gibs`, `on_dash`, `on_land(speed)`, `zombie_spawn(pos)`, `on_wave(n)`, `on_reload`.
- New: `on_shove(hit_count: int)`, `explosion(pos, radius)`, `explosion_colored(pos, radius, toxic)`, `on_upgrade()`,
  `hit_stop(seconds)`, vars `shake_scale := 1.0`, `hit_stop_enabled`.
- fx writes `cam.rotation` and `cam.fov`; nothing else may.

## Testing (Godot binary path is given in each task brief as `G`)
- Script check: `timeout 60 $G --headless --quit-after 300 -- --autostart 2>&1 | grep -iE "script error|parse error" -A3`
  (ignore `Parameter "m" is null`).
- Screenshot: `timeout 60 xvfb-run -a -s "-screen 0 1280x720x24" $G --rendering-driver opengl3 -- --autostart --god --pos=0,10 --yaw=0 --pitch=0 --shot=/abs/out.png --t=6`
  then look at the PNG. Yaw 0 looks toward -Z; positive pitch looks up.
- Pathing check: add `--navtest --fixed-fps 30` style run (see main.gd `_nav_check`): `stuck=` must stay 0.
