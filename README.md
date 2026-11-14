# Zombie Bonk
Fast, goofy, pixelated 3D zombie FPS made with Godot 4.3 set in a New York street intersection at dusk. Everything is built in code: `main.gd` (rules), `world.gd` (city), `clutter.gd` (props), `fx.gd` (lighting/effects), `hud.gd` (UI), `controls.gd` (input), `layout.gd` + `build.gd` (shared).

Open the folder in Godot 4.3+ and press Play.

**Controls (keyboard):** WASD/arrows move · Mouse aim · LMB shoot · RMB or E shove · R reload · Shift dash · Space jump · V first/third person · F fullscreen · G resolution (360p/540p) · M mute · [ ] sensitivity · Esc free mouse · Enter restart

**Controls (touch):** left side = joystick · swipe right side to look (dragging on FIRE also aims) · FIRE / JUMP / DASH / SHOVE / RELOAD buttons · VIEW · SENS · 360P/540P · FULL

Headshots pop heads for bonus points and quick kills build a combo. Waves arrive in packs; after each wave you pick one of three upgrades. Zombie types: commuters, fast delivery guys (wave 3+), exploding bloaters (wave 6+) and a sanitation boss every fifth wave. All sound is synthesised in code.

`SPECS.md` describes how the scripts talk to each other and who owns which file.

## Web deploy (Firebase Hosting)
1. Put your Firebase project ID in `.firebaserc`.
2. Add a repo secret `FIREBASE_SERVICE_ACCOUNT` (JSON key of a service account with the *Firebase Hosting Admin* role).
3. Push to `main` (or run the workflow manually) — GitHub Actions exports the game with Godot and deploys it.

Manual deploy: export with `godot --headless --export-release Web web/index.html`, then `firebase deploy --only hosting`.
