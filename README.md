# Zombie Bonk
Fast, goofy, pixelated 3D zombie FPS made with Godot 4.3 (all built in `main.gd`).

Open the folder in Godot 4.3+ and press Play.

**Controls:** WASD move · Mouse aim · LMB shoot (5-pellet boomstick) · R reload · Shift dash · Space jump · V toggle first/third person · Esc free mouse · Enter restart

Headshots pop heads off for bonus points; quick kills build a combo multiplier. Waves get bigger and faster; big zombies hit harder and are worth 3x.

## Web deploy (Firebase Hosting)
1. Put your Firebase project ID in `.firebaserc`.
2. Add a repo secret `FIREBASE_SERVICE_ACCOUNT` (JSON key of a service account with the *Firebase Hosting Admin* role).
3. Push to `main` (or run the workflow manually) — GitHub Actions exports the game with Godot and deploys it.

Manual deploy: export with `godot --headless --export-release Web web/index.html`, then `firebase deploy --only hosting`.
