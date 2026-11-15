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
- Tone: comedic, blocky, original designs. An endless New York street grid at dusk.
- Map facts are in `layout.gd` (static, position based, valid anywhere in the infinite world); ground is flat at
  y = 0; +Y up; characters face -Z. Never assume the world is small or centred on the origin: positions grow
  without bound, only the area round the player exists as nodes (see world.gd).

## Who owns what (sprint 3)
| File | Owner | Role |
|---|---|---|
| `main.gd` (except world set-up lines), `build.gd`, `SPECS.md` (shared sections) | lead | game flow, glue |
| `weapons.gd`, `drops.gd`, `gun_models.gd` (new), `upgrades.gd`, `hud.gd`, `controls.gd`, `sfx.gd`, `fx.gd` | weapons agent | guns, combat mechanics, crates and airdrops, their UI/input/sound/effects |
| `world.gd`, `clutter.gd`, `layout.gd`, `nav.gd`, world-related lines of `main.gd` and `zombies.gd` | city agent | the endless streamed city, pathfinding window, spawn positions |
| `models.gd`, `zombie_rig.gd`, rest of `zombies.gd` | (not in this sprint — do not edit beyond what is listed above) | zombie looks and behaviour |

## main.gd (lead) — what other modules may read
- `main.player: CharacterBody3D` (feet at `position`, eye at +1.6), `main.cam: Camera3D`, `main.nav`, `main.fx`, `main.sfx`,
  `main.hud`, `main.upgrades`, `main.zombies`, `main.wave: int`, `main.hp: float`, `main.dead: bool`.
- `main.stat(name) -> float` — a tunable after upgrades. Base values (`main.BASE`):
  `pellets 5`, `spread 0.03`, `damage 25` (per pellet), `head_mult 2.4`, `fire_cd 0.16`, `reload_time 0.9`,
  `max_ammo 8`, `move_speed 9`, `dash_cd 0.8`, `dash_speed 28`, `max_hp 100`, `wave_heal 25`,
  `heal_on_headshot 0`, `shove_cd 1.2`, `shove_reach 3.5`, `shove_arc 80` (degrees), `shove_force 9`,
  `shove_damage 0`, `explosive_radius 0`, `score_mult 1`, `combo_time 2`.
- Signals: `wave_started(n)`, `wave_ended(n)`.
- Flow: title → `begin_game` → `next_wave` → `zombies.start_wave(n)` … `wave_cleared` → 2 s rest →
  `upgrades.roll(3)` → `hud.show_upgrades` → pick → `upgrades.take` → `next_wave`.
- Debug switches after `--`: `--autostart --god --pos=x,z --yaw=deg --pitch=deg --shot=/abs.png --t=sec --navtest --wave=n --hires`,
  `--run=dx,dz` (auto-walk corner to corner in that direction), `--run=zig` (turn at every corner), `--dash` (dash whenever
  ready), `--citystats` (print streaming / pathfinding / renderer numbers every 2 s).
- World glue (city agent): `_ready` creates `world`, `clutter`, `nav` (`clutter.setup(world)`, `world.build(clutter, nav)`) and
  calls `world.prebuild(player.position)` once everything exists; `_process` calls `world.update(player.position)` every
  frame (also on the title screen), hands `world.lamp_positions()` / `world.globe_positions()` to `fx.set_street_lights` /
  `fx.set_subway_globes` when `world.lights_changed` / `world.globes_changed` are set, and keeps the player on built,
  walkable ground with `world.hold(L.clamp_to_streets(player.position, 0.5))`.

## layout.gd (city agent) — the map contract, all static: `const L = preload("res://layout.gd")`
The city is generated from `L.SEED` and block coordinates only (same place = same content, forever).
- Grid: avenues run north-south at `x = i * L.PITCH`, streets east-west at `z = j * L.PITCH` (`PITCH` 82 m); avenue 0 and
  street 0 cross at the origin (the spawn intersection). Each is a corridor `2 * CORRIDOR_HALF` (18 m) wide: road
  (`ROAD_HALF` 6 either side of the centre line) plus a `SIDEWALK` (3 m, raised `KERB_H`, visual only) each side.
  Between corridors lie square blocks of `BLOCK` (64) m; block `(bx, bz)` spans `x in [bx*PITCH + 9, (bx+1)*PITCH - 9]`.
  A *tile* `(bx, bz)` = block `(bx, bz)` + intersection `(bx, bz)` at its north-west corner + the avenue segment on its
  west side + the street segment on its north side (`L.tile_of(p)`); tiles are what world.gd streams.
- `L.clamp_to_streets(p: Vector3, margin := 0.5) -> Vector3` push a point back onto walkable ground (streets, sidewalks,
  and the open blocks: parks, plazas, parking lots — outside their buildings). `L.in_street(p, margin := 0.0) -> bool`
  (road or sidewalk only), `L.walkable(p, margin := 0.0) -> bool` (streets + open blocks), `L.in_ns(p)` / `L.in_ew(p)`
  (inside an avenue / a street), `L.lat(v)` (signed offset from the nearest street centre line),
  `L.sight_clear(a, b) -> bool` (no building between two street-level points).
- `L.biome_at(p: Vector3) -> String` — `"downtown"` everywhere for now (`L.biome_of_block(bx, bz)` decides).
- `L.nearest_facade(p: Vector3) -> {pos: Vector3, normal: Vector3, height: float, top: float, kind: String}` — closest
  point on a building wall at ground level, unit normal pointing into the street, `height` = top of that wall in metres
  (the roof; for a stepped tower its first setback; for a building site the top of the steel frame), `top` = highest
  point of the building. Same numbers world.gd draws. No building within a block or two: height 0, zero normal.
- `L.block(bx, bz) -> Dictionary` (cached; treat as read-only): `type` (`towers`, `walkups`, `warehouse`, `park`, `plaza`,
  `parking`, `construction`), `biome`, `district`, `rect: Rect2` (x/z), `open: bool` (walkable inside), `seed`,
  `lots: [{r: Rect2, h, top, st (facade style 0-4), tint, kind ("bldg" | "podium" | "tower" | "site"), sides (bit mask
  `1 << side` of street-facing sides; side 0 N, 1 E, 2 S, 3 W), seed, ads, + tiers / variant / landmark / name (tower),
  h1 (site)}]`, `trees: [Vector3(x, size, z)]` and `feature` (park / plaza centre piece).
- Streets: `L.seg_theme(axis, bx, bz) -> String` (axis 0 = the tile's avenue segment, 1 = its street segment; themes
  `quiet taxi pileup roadblock bus works market el origin_n/s/e/w`), `L.is_el(i)` (avenue i carries the elevated train),
  `L.avenue_name(i)`, `L.street_name(j, east)`.
- Subway stairwells: `L.subway_entrances(bx, bz) -> [{pos: Vector3, dir: Vector3}]` for a tile's avenue segment (footprint
  3 x 6 m centred on `pos`, stairs descend along `dir`), `L.subway_near(p, radius) -> Array` of the same,
  `L.subway_spawn(e) -> Vector3` (where a zombie climbing out appears). The old constant `L.SUBWAY_ENTRANCES` (the two
  at the origin) only remains because fx.gd still reads it. `L.spawn_points()`, `L.nav_target()` and `L.ARM_LEN` are gone.
- Seeded helpers for other generators: `L.hash3(a, b, c) -> int`, `L.rand01(a, b, c) -> float`.
- **Adding a biome (stage 3):** make `biome_of_block()` choose it (noise over block coordinates), give `block_type()` /
  `_gen_block()` its block types and lots (keep `open` and `lots` truthful: clamp, nav and colliders read them), add
  street themes to `L.THEMES` / `seg_theme()`, then draw them in world.gd / clutter.gd (below).

## world.gd / clutter.gd (city agent) — the streamed city
- `world.build(clutter, nav)` once; `world.prebuild(pos)` builds everything needed round `pos` synchronously (start,
  teleports); `world.update(pos)` every frame streams: tiles within ~2.6 blocks (4.1 along the streets you can look
  down) get a cheap **base** mesh (ground, sidewalks, every building as textured boxes, towers, elevated train); near
  the player each tile gains **units**, each one merged mesh: 0-3 the street-level detail of one side of the block
  (shops, signs, fire escapes, roofs; built within 38 m when the player is in front of it, freed beyond 50 m), 4 the
  intersection + avenue segment and 5 the street segment (road markings, subway stairwell, lamps, traffic lights, props;
  62 / 78 m), 6 the inside of an open block. Work is queued nearest-first and done in small steps within ~3 ms per frame.
  Everything left behind is freed (tiles, meshes, colliders, cached block data).
- Colliders: one ground box that follows the player; one box per solid block (per building in open blocks) within
  ~100 m; prop colliders only within ~30 m. `world.hold(p) -> Vector3` returns `p`, or the last good position if the
  ground under `p` has no props / colliders yet (never observed in tests; counted in `world.holds`).
- `world.spawn_points(center, min_d, max_d) -> [{pos: Vector3, subway: bool}]` street spots (and subway stairwells) round
  `center`, never inside props / buildings and always connected to the player in the nav window.
- `world.lamp_positions()`, `world.globe_positions()` (+ flags `lights_changed`, `globes_changed`),
  `world.nav_obstacles(rect)` (for nav.gd), `world.stats()`, `world.tile_hash(key)` (determinism tests).
- One `ShaderMaterial` (`world.mat`) draws the whole city. Vertex colour alpha selects the look: 1.0 lit vertex colour,
  0.9 unshaded glow, n / 10 = layer n of two `Texture2DArray`s (albedo, emission; 128 px): 0-4 window facades (brick,
  deco, glass, ribbon, warehouse), 5 sidewalk paving, 6 far shop fronts; 7 and 8 are free. Meshes are written through
  channels (`world.lit`, `flat`, `glow`, `fac[st]`, `pave`, `shopc`) with `world._quad / _box / _text ...`.
- clutter.gd draws props into the mesh world.gd is building: `inter_steps(tile)`, `seg_steps(tile, axis)`,
  `block_steps(tile)` return lists of small build steps; `lamp_points(tile)` lists lamp heads. Props add colliders to
  `world.cur_cols` and pathfinding obstacles to `world.cur_circ` (x, z, radius) / `world.cur_rects`.
- Clear-lane rule (keep it when adding props): road props stand in slots 9 m apart, each slot keeps to one half of the
  road (0.6 .. 5.6 m from the centre line) and is at most 5 m long; kerb-side things keep the middle 7 m free;
  intersections stay open. A 1.5 m-radius disc can travel every street and cross every intersection.
- **Adding a block type:** lots in `L._gen_block()`; far look in `world._base_lots()` / `_base_block()`; street-level
  detail in `world._front_lot()`; props inside open blocks in `clutter.block_steps()` (+ lamps in `_lamp_specs()`).
  **Adding a street theme:** a `clutter._theme_x(S, pr, st)` + an entry in `L.THEMES`. **Later stages:** day/night and
  weather can drive `world.mat` shader parameters (all emission goes through it); enterable buildings / stations hang
  off lots (`sides`, `r`) and `L.subway_entrances()`.

## nav.gd (city agent)
- A flow field in a 128 x 128 m window of 1 m cells that follows the player. `nav.update(target)` is called by main each
  frame: it re-centres the window when the player is 10 m off centre, re-reads streamed props when told
  (`nav.mark_dirty()`, world.gd does this) and re-floods when the player changes cell — all in a back buffer, at most
  ~1.2 ms per frame, swapped in when complete, so readers never see a half-built field. `nav.rebuild_now(target)` does it
  at once.
- `nav.direction(from: Vector3, to: Vector3) -> Vector3` unit direction to walk (routes round props/corners; straight
  toward `to` outside the window). `nav.is_blocked(p: Vector3) -> bool` — true inside props/buildings (outside the
  window it answers from layout.gd alone).
- `nav.in_window(p)`, `nav.reachable(p) -> bool` (inside the window and connected to the player), `nav.steps(p) -> int`
  (walking distance in metres, -1 unknown), `nav.cell(p)` + `nav.dist[]` / `nav.blocked[]` (window-local cell index),
  `nav.window() -> Rect2`.

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
- Endless city: packs spawn at `main.world.spawn_points(player, 15, 45)` (out of view where possible); a zombie more
  than 70 m from the player, or cut off from the nav window for 2 s, is moved to a fresh out-of-view spawn point
  (`_relocate_strays`), so a wave can always be finished.
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
- Weapon / drop names (frozen too): `shoot_revolver shoot_smg shoot_bow shoot_double shoot_launcher shoot_pigeon hose swing
  pan_hit reload_mag switch perfect throw glass pigeon_pop frenzy crate_land airdrop pickup powerup heal ammo`
  (played by weapons.gd and drops.gd).
- Called by: main (player and scoring sounds), zombies.gd (`zombie_*`, `bloater_swell`, `explode`, `boss_step` via `play_at`),
  hud.gd (`ui_click`).

## weapons.gd (extends Node)
- `setup(main)`; `update(dt)` — main calls it every frame while playing (not during the upgrade draft). It reads
  `main.controls.fire`, fires, reloads, moves projectiles and burning puddles, animates the gun model and calls
  `main.zombies.hit / shove / damage_radius`, `main.fx`, `main.sfx`. It connects itself to `main.controls`
  (`weapon_next`, `weapon_prev`, `weapon_slot`, `throw`) and `main.zombies.zombie_killed` on its first `update`.
- Vars: `current: String` (weapon id), `owned: Array` of ids (max `SLOTS` = 3, slot 1 is always the starter `shotgun`),
  `ammo: int` (magazine of the current weapon), `reloading: float`, `gun: Node3D` (holder of all first-person models, child of
  the camera; only the current model is visible), `mags` / `reserves` (id -> rounds; reserve -1 = endless),
  `bonk` (meter 0..1), `frenzy_t`, `throw_t`, `juiced`.
- `max_ammo() -> int`, `reload_frac() -> float`, `hud_info() -> Dictionary` (`id, name, ammo, max_ammo, reserve` (-1 = infinite),
  `slots, reloading, reload_frac` plus `color, icon, melee, slot_info [{id, name, color, icon, ammo, reserve, melee}],
  perfect_lo, perfect_hi, perfect (0 unused / 1 hit / 2 fumbled), perfect_t, juiced, bonk, frenzy (1..0), throw_ready (0..1), free_ammo`),
  `give(id, rounds := -1)`, `has(id)`, `can_take(id)`, `replace_target()`, `add_reserve(id, rounds)`, `add_ammo(frac) -> bool`,
  `switch_to(id)`, `next()`, `prev()`, `switch_slot(i)`, `refill()`, `start_reload()` (called again during a reload = the
  perfect-reload try), `throw_sauce()`, `set_view_visible(on)`, `free_ammo()`, `damage_mult()`,
  per-weapon numbers after upgrades: `damage_of(id)`, `cooldown_of(id)`, `reload_time_of(id)`, `max_ammo_of(id)`, `reserve_cap(id)`.
- Signals: `fired(id)`, `weapon_changed(id)`, `picked_up(id)`.
- The table `W` (id -> name, mode, numbers, sounds, HUD colour/icon, first crate wave, weight; defaults in `DEFAULTS`).
  Ids (frozen): `shotgun` BOOMSTICK (starter, endless ammo), `revolver` SNUB NOSE, `smg` RAT-A-TAT, `skewer` KEBAB BOW (pierces),
  `double` DOUBLE TROUBLE, `launcher` HOT DOG CANNON (arcing blast), `pigeon` PIGEON POST (homing), `hydrant` HYDRANT HOSE
  (pushes), `pan` FRYING PAN (melee). Modes: `shot` (ray casts), `proj` (pooled projectile, moved by hand), `stream`, `melee`.
- Upgrade stats apply on top of each weapon's own base numbers through `main.upgrades` (`stat(name, weapon_base)`, or
  `add(name)` / `mul(name)` where the weapon clamps for itself): damage, fire_cd, reload_time and max_ammo (in proportion)
  on every weapon; pellets only on shotguns; spread / head_mult / explosive_radius on ray-cast weapons.
- Other mechanics that live here: perfect reload (press reload again inside the window: instant finish, +30% damage for that
  magazine; outside it: +0.3 s), hot sauce (thrown bottle on a 12 s cooldown: blast, then a burning puddle), bonk meter (kills
  fill it; full = 7 s frenzy: fire rate x1.67, free ammo, +25% damage, quicker shove and dash).
- Hit detection: ray casts against `Area3D` hit boxes carrying meta `"zombie"` and `"head"`; anything else is scenery.
- Weapon view models, projectile meshes and the crate / parachute meshes are built in `gun_models.gd`
  (`GunModels.make(id) -> Node3D` with children `Muzzle` and optionally `Part`; `GunModels.prop(kind) -> ArrayMesh`).

## drops.gd (extends Node3D)
- `setup(main)`, `update(dt)` (every frame while playing), `clear()`.
- Wave reward: on `main.wave_ended` a weapon crate lands 5-10 m from the player (in front if possible) and stays until taken
  or replaced by the next reward. Airdrops: during a wave (first after 10-18 s, then every 30-50 s, not while 3 or fewer zombies
  are left) a parachute crate lands 14-34 m away and waits 28 s. Contents: ammo, health (+40), a power-up, or a weapon.
- Placement uses only `L.clamp_to_streets(p, 2.0)` and `not main.nav.is_blocked(p)` (plus a physics ray straight down for the
  ground height). Three drop objects exist for the whole game; nothing is created during play.
- Walking into a crate takes it. A weapon the player cannot hold (every slot full) is offered instead: `prompt()` is non-empty
  and `main.controls.grab` confirms the swap.
- For other scripts: `power(id) -> bool` (ids `damage` x2 damage 12 s, `ammo` nothing uses ammo 10 s, `speed` x1.35 move 12 s),
  `give_power(id)`, `powerups() -> [{id, name, color, left, frac}]`,
  `markers() -> [{pos, kind ("crate" | "airdrop"), label, color, left (-1 = stays), falling}]`, `prompt() -> {text, color} | {}`,
  `roll_weapon(wave, avoid := "") -> id`, `find_spot(min_d, max_d, toward := Vector3.ZERO, tries := 24) -> Vector3 | null`.
- Power-ups that change `main.stat` values do it through `main.upgrades.set_temp` / `clear_temp`.

## upgrades.gd (extends RefCounted)
- `reset()`, `roll(n: int, rng) -> [{id, title, desc, color}]` (empty = no draft), `take(id)`, `level(id) -> int`,
  `stat(name: String, base: float) -> float` for the stat names listed under main.gd.
- `add(name)` / `mul(name)`: the raw modifiers (value = (base + add) * mul) for callers that clamp for themselves.
- `set_temp(key, {stat: multiplier})` / `clear_temp(key)`: temporary boosts (power-ups, bonk frenzy) that also reach `main.stat`.
- `set_weapons(ids)`: weapons.gd reports what is carried; cards with `"needs": [weapon ids]` are only offered then.
- Extra stat names read by weapons.gd with their own base values: `reserve_mult` (1), `throw_cd` (12), `blast_mult` (1),
  `perfect_window` (0.09), `perfect_bonus` (0.3), `bonk_gain` (1), `pierce` (0), `melee_mult` (1), `melee_reach`, `hose_force`,
  `hose_reach`, `flock` (1). 27 cards in total.

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
- `update_stats` also takes `weapon` (= `weapons.hud_info()`): weapon panel bottom-centre (slots, magazine as rounds or a bar,
  spare ammo), perfect-reload window on the reload ring, hot sauce and bonk meter bars under the shove bar.
- `toast(text, color := PAPER, big := false)`: a short message under the combo ("NEW WEAPON: ...", "AIRDROP INCOMING!").
- Reads `get_parent().drops` each frame (guarded): `markers()` (tag over a visible drop, edge arrow + distance otherwise),
  `powerups()` (timers top-right), `prompt()` (the swap offer).
- `BUTTON_NAMES` gains `"weapon"` (next weapon), `"throw"` (hot sauce) and `"grab"` (swap; `button_active("grab")` is true
  only in touch mode while a swap is offered). Weapon icons are `w_<id>`.

## controls.gd (extends Node)
- Vars `game_active` (set by main), `touch_mode`, `move`, `fire`, `jump`, `sens_level`; `setup(hud)`, `take_look()`,
  `toggle_fullscreen()`, `set_sens_level()`.
- Signals: `dash`, `reload`, `toggle_view`, `start_pressed`, `shove`, `toggle_quality`, `toggle_mute`,
  `weapon_next`, `weapon_prev`, `weapon_slot(i)` (0-based), `throw`, `grab`.
- Weapon bindings: keys 1-3 slot, Q next, mouse wheel previous / next, T or middle mouse throw, C swap; touch buttons
  `weapon`, `throw`, `grab`; gamepad d-pad up next weapon, LT throw, d-pad down swap.
- While `hud.modal_open()` is true, controls emits nothing and leaves all input to the HUD.
- Never use `InputEventScreenDrag.relative`/`screen_relative` (Godot web bug #94346) — track positions per touch index.

## fx.gd (extends Node3D)
- Existing: `setup(cam)`, `attach_gun(gun)`, `add_street_lights`, `add_subway_globes`, `on_shoot`, `impact(pos, normal)`,
  `zombie_hit(pos, dir, headshot)`, `zombie_death(head_pos, skin, headshot)`, `player_hurt(dmg)`, `shake_offset()`,
  `gibs`, `on_dash`, `on_land(speed)`, `zombie_spawn(pos)`, `on_wave(n)`, `on_reload`.
- New: `on_shove(hit_count: int)`, `explosion(pos, radius)`, `explosion_colored(pos, radius, toxic)`, `on_upgrade()`,
  `hit_stop(seconds)`, vars `shake_scale := 1.0`, `hit_stop_enabled`.
- fx writes `cam.rotation` and `cam.fov`; nothing else may.
- Weapons: `attach_gun(holder)` (weapons.gd passes one holder node; fx moves only its x / y / yaw / roll), `set_muzzle(local)`,
  `on_fire(kick, flash_k, tracer_col, tracer_w, shell_col)` then `impact` / `zombie_hit` draw tracers until `end_shot()`,
  `tracer_to(pos)`, `on_swing(hits)`, `water(dir, speed)`, `water_splash(pos)`, `trail(pos, col, size)`, `feathers(pos)`,
  `fire_patch(pos, r)`, `power_burst(col)`. `on_shoot()` still works (the old shotgun call).
- Drops: `pickup(pos, col)`, `crate_land(pos, col)`, `beacon(pos, col, pulse)`, `additive_material()` (shared, for drop beams).
- `set_street_lights(positions)` / `set_subway_globes(positions)` replace the whole set (for the streamed city).

## Testing (Godot binary path is given in each task brief as `G`)
- Script check: `timeout 60 $G --headless --quit-after 300 -- --autostart 2>&1 | grep -iE "script error|parse error" -A3`
  (ignore `Parameter "m" is null`).
- Screenshot: `timeout 60 xvfb-run -a -s "-screen 0 1280x720x24" $G --rendering-driver opengl3 -- --autostart --god --pos=0,10 --yaw=0 --pitch=0 --shot=/abs/out.png --t=6`
  then look at the PNG. Yaw 0 looks toward -Z; positive pitch looks up.
- Pathing check: add `--navtest --fixed-fps 30` style run (see main.gd `_nav_check`): `stuck=` must stay 0. Try several
  `--pos` (other intersections, mid-block, a park) and `--run=zig`.
- Streaming check: `$G --headless --fixed-fps 60 --quit-after 14000 -- --autostart --god --citystats --run=0,-1 [--dash]`
  prints a `CITY ...` line every 2 s: `holds` must stay 0, `verts` / `nodes` / `mem_mb` flat, `gen_max_us` near 3000.
