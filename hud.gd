extends CanvasLayer
# All 2D UI: stats, crosshair, messages, title / game-over screens, and the VISUALS of
# the touch controls. Input handling lives in controls.gd, which asks this script where
# the buttons are (button_rect) and tells it what is pressed.
#
# The game renders at a low resolution (640x360, wider on wide screens) and is scaled up
# with nearest-neighbour filtering, so everything here is chunky pixel art measured in
# those small pixels. Nothing is loaded from disk: text uses a 5x7 bitmap font that is
# generated into a texture at start-up, and icons / round buttons are generated images.
#
# Two resolutions: the viewport can also be 960x540. Everything in this file is laid out
# and painted in "design pixels" - a 360-tall canvas, `vs` wide and tall - and the layers
# are scaled by `px` (1.0 at 360p, 1.5 at 540p), so the HUD is the same size on screen at
# both, just sharper at 540p. Only the functions controls.gd calls (button_rect,
# stick_zone, stick_radius, set_stick) and the draft's own input convert to and from
# real viewport pixels. At 1.5x, rectangles are snapped to whole pixels (_r) and small
# text / icons use a pre-smoothed copy of their texture, so nothing looks uneven.
#
# Structure: full-screen Controls stacked in this CanvasLayer, each painted by one
# function (no per-frame node creation):
#   vignette  - red screen-edge flash when hurt / low on health
#   game      - health, dash, shove, wave, score, combo, ammo, crosshair, floating "+100"s
#   overlay   - title screen, game-over screen, wave banner, centred messages
#   pad       - joystick and buttons
#   draft     - the between-wave upgrade cards (handles its own input while open)

const BUTTON_NAMES := ["fire", "jump", "dash", "reload", "view", "sens", "full", "shove", "res"]

# ---- palette ----
const INK := Color(0.07, 0.06, 0.12)
const PAPER := Color(0.98, 0.95, 0.86)
const GREEN := Color(0.47, 0.92, 0.36)
const DKGREEN := Color(0.2, 0.55, 0.25)
const YELLOW := Color(1.0, 0.86, 0.22)
const ORANGE := Color(1.0, 0.56, 0.16)
const RED := Color(0.96, 0.27, 0.27)
const DKRED := Color(0.6, 0.1, 0.16)
const CYAN := Color(0.4, 0.86, 1.0)
const PINK := Color(1.0, 0.45, 0.8)
const CLEAR := Color(0, 0, 0, 0)

const WAVE_BANNER_TIME := 2.4
const DRAFT_GUARD := 0.4   # seconds the draft ignores input after it opens
const DRAFT_OUT := 0.25    # closing animation
const CARD_W := 176.0
const CARD_H := 208.0
const CARD_GAP := 14.0
const WAVE_LINES := ["HERE THEY COME!", "BONK 'EM ALL!", "MORE BRAINS INBOUND", "THEY BROUGHT FRIENDS",
	"AIM FOR THE HEAD!", "GARY IS BACK", "KEEP BONKING!", "UH OH..."]

# 5x7 bitmap font: seven rows per glyph, each row a 5-bit number (bit 4 = left pixel).
const FONT := {
	"A": [14, 17, 17, 31, 17, 17, 17], "B": [30, 17, 17, 30, 17, 17, 30], "C": [14, 17, 16, 16, 16, 17, 14],
	"D": [30, 17, 17, 17, 17, 17, 30], "E": [31, 16, 16, 30, 16, 16, 31], "F": [31, 16, 16, 30, 16, 16, 16],
	"G": [14, 17, 16, 23, 17, 17, 15], "H": [17, 17, 17, 31, 17, 17, 17], "I": [14, 4, 4, 4, 4, 4, 14],
	"J": [7, 2, 2, 2, 2, 18, 12], "K": [17, 18, 20, 24, 20, 18, 17], "L": [16, 16, 16, 16, 16, 16, 31],
	"M": [17, 27, 21, 21, 17, 17, 17], "N": [17, 25, 21, 19, 17, 17, 17], "O": [14, 17, 17, 17, 17, 17, 14],
	"P": [30, 17, 17, 30, 16, 16, 16], "Q": [14, 17, 17, 17, 21, 18, 13], "R": [30, 17, 17, 30, 20, 18, 17],
	"S": [15, 16, 16, 14, 1, 1, 30], "T": [31, 4, 4, 4, 4, 4, 4], "U": [17, 17, 17, 17, 17, 17, 14],
	"V": [17, 17, 17, 17, 17, 10, 4], "W": [17, 17, 17, 21, 21, 27, 17], "X": [17, 17, 10, 4, 10, 17, 17],
	"Y": [17, 17, 10, 4, 4, 4, 4], "Z": [31, 1, 2, 4, 8, 16, 31],
	"0": [14, 17, 19, 21, 25, 17, 14], "1": [4, 12, 4, 4, 4, 4, 14], "2": [14, 17, 1, 2, 4, 8, 31],
	"3": [30, 1, 1, 14, 1, 1, 30], "4": [2, 6, 10, 18, 31, 2, 2], "5": [31, 16, 30, 1, 1, 17, 14],
	"6": [6, 8, 16, 30, 17, 17, 14], "7": [31, 1, 2, 4, 8, 8, 8], "8": [14, 17, 17, 14, 17, 17, 14],
	"9": [14, 17, 17, 15, 1, 2, 12],
	"!": [4, 4, 4, 4, 4, 0, 4], "?": [14, 17, 1, 2, 4, 0, 4], ".": [0, 0, 0, 0, 0, 12, 12],
	",": [0, 0, 0, 0, 12, 4, 8], ":": [0, 12, 12, 0, 12, 12, 0], "-": [0, 0, 0, 31, 0, 0, 0],
	"+": [0, 4, 4, 31, 4, 4, 0], "/": [1, 1, 2, 4, 8, 16, 16], "(": [2, 4, 8, 8, 8, 4, 2],
	")": [8, 4, 2, 2, 2, 4, 8], "'": [4, 4, 8, 0, 0, 0, 0], "%": [24, 25, 2, 4, 8, 19, 3],
	"*": [0, 21, 14, 31, 14, 21, 0], "[": [14, 8, 8, 8, 8, 8, 14], "]": [14, 2, 2, 2, 2, 2, 14],
	"_": [0, 0, 0, 0, 0, 0, 31], "=": [0, 0, 31, 0, 31, 0, 0], ">": [8, 4, 2, 1, 2, 4, 8],
	"<": [2, 4, 8, 16, 8, 4, 2], "#": [10, 10, 31, 10, 31, 10, 10],
}

# Little pixel icons. '.' is transparent; other letters are looked up in ICON_COLORS.
const ICON_COLORS := {"#": Color.WHITE, "g": Color(0.5, 0.75, 0.38), "d": Color(0.3, 0.5, 0.28),
	"y": Color(1, 1, 0.3), "k": Color(0.08, 0.05, 0.05), "r": Color(0.45, 0.08, 0.1),
	"w": Color(0.95, 0.95, 0.85), "h": Color(0.22, 0.14, 0.08)}
const ICON_HEART := [".##.##.", "#######", "#######", ".#####.", "..###..", "...#..."]
const ICON_BOLT := ["...##", "..##.", ".##..", "#####", "..##.", ".##..", "##..."]
const ICON_UP := ["...#...", "..###..", ".#####.", "#######", "..###..", "..###..", "..###.."]
const ICON_SHELL := ["..###..", ".#####.", ".#####.", ".#####.", ".#####.", ".......", "#######"]
const ICON_CLOCK := [".#####.", "#..#..#", "#..#..#", "#..##.#", "#.....#", "#.....#", ".#####."]
const ICON_BOOT := [".###...", ".###...", ".###...", ".###...", ".#####.", ".######", ".######"]
const ICON_AIM := ["...#...", "...#...", ".......", "##.#.##", ".......", "...#...", "...#..."]
const ICON_SKULL := [".#####.", "#######", "#..#..#", "#######", ".##.##.", ".#####.", ".#.#.#."]
const ICON_FIST := [".#.#.#.", "#######", "#######", "#######", "######.", ".#####.", "..####."]
const ICON_STAR := ["...#...", "...#...", "#######", ".#####.", "..###..", ".##.##.", "##...##"]
const ICON_BOOM := ["#..#..#", ".#.#.#.", "..###..", "#######", "..###..", ".#.#.#.", "#..#..#"]
const ICON_ZOMBIE := ["hhhhhhhhhh", "hhhhhhhhhh", "gggggggggg", "gyyggggyyg", "gykggggkyg", "gggggggggg",
	"ggggddgggg", "gggggggggg", "grrrrrrrrg", "grwrwrrwrg", "gggggggggg", ".dddddddd."]

enum { SCREEN_NONE, SCREEN_TITLE, SCREEN_OVER }

static var best_score := 0   # survives the scene reload after a game over

var touch_mode := false
var screen := SCREEN_NONE
var vs := Vector2(640, 360)   # size of the canvas in design pixels (360 tall, or more)
var px := 1.0                 # real viewport pixels per design pixel
var real := Vector2(640, 360) # real viewport size
var time := 0.0

var vignette: TextureRect
var game: Control
var pad: Control
var overlay: Control
var draft: Control

var font_img: Image
var font_tex: ImageTexture     # 1:1 atlas, drawn with nearest-neighbour scaling
var font_aa: ImageTexture      # the atlas pre-scaled by px, for small text at 540p
var font_aa_k := 1.0           # texels of font_aa per texel of font_tex
var glyph_ix := {}     # unicode code point -> cell number in font_tex
var icon_img := {}     # icon name -> Image
var tex := {}          # icon name -> ImageTexture
var tex_aa := {}       # icon name -> ImageTexture pre-scaled by px
var ring_tex := {}     # real diameter -> ImageTexture (outlined ring, dark see-through middle)
var solid_tex := {}    # real diameter -> ImageTexture (outlined filled disc)

# touch controls
var rects := {}        # button name -> Rect2 in viewport coordinates
var down := {}         # button name -> bool
var sens_level := 2
var stick_home := Vector2.ZERO
var stick_center := Vector2.ZERO
var stick_offset := Vector2.ZERO
var stick_active := false

# stats (latest values from main.gd) and the little animations hanging off them
var have_stats := false
var hp := 100.0
var hp_trail := 100.0
var hp_flash := 0.0
var ammo := 0
var max_ammo := 8
var reloading := false
var reload_frac := 0.0
var max_hp := 100.0
var shove_ready := 1.0
var shove_flash := 0.0
var zombies_left := 0
var left_str := ""
var quality_label := "360P"
var score := 0
var shown_score := 0.0
var score_pop := 0.0
var score_str := "0"
var wave := 0
var wave_str := ""
var combo := 0
var combo_shown := 0
var combo_str := ""
var combo_pop := 0.0
var combo_frac := 0.0
var combo_fade := 0.0
var hurt := 0.0
var dash_ready := 1.0
var dash_flash := 0.0
var play_time := 0.0
var cross_kick := 0.0
var hit_t := 0.0
var hit_head := false
var kill_t := 0.0
var floaters := []     # fixed pool of {t, text, head, x}
var floater_next := 0

# run summary for the game-over screen
var kills := 0
var headshots := 0
var best_combo := 0
var over_score := 0
var over_wave := 0
var over_best := false
var over_t := 0.0

var msg_lines := PackedStringArray()
var msg_t := 0.0
var banner_t := 0.0
var banner_line := ""

# upgrade draft
var draft_cards: Array = []
var draft_cb := Callable()
var draft_open := false
var draft_t := 0.0
var draft_out := 0.0      # > 0 while the closing animation plays
var draft_sel := -1       # highlighted card (hover / arrow keys)
var draft_picked := -1
var draft_press := {}     # touch index (or -1 for the mouse) -> card pressed
var draft_wave := 0
var taken: Array = []     # upgrades picked this run: {id, title, color, icon, n}

# ------------------------------------------------------------------ building

# Called once.
func build() -> void:
	_build_font()
	var icons := {"heart": ICON_HEART, "bolt": ICON_BOLT, "up": ICON_UP, "zombie": ICON_ZOMBIE,
		"shell": ICON_SHELL, "clock": ICON_CLOCK, "boot": ICON_BOOT, "aim": ICON_AIM, "skull": ICON_SKULL,
		"fist": ICON_FIST, "star": ICON_STAR, "boom": ICON_BOOM}
	for n in icons:
		var img := _bitmap(icons[n], ICON_COLORS)
		# even sizes, so the 1.5x copy is a whole number of pixels
		var even := Image.create(img.get_width() + (img.get_width() & 1), img.get_height() + (img.get_height() & 1), false, Image.FORMAT_RGBA8)
		even.blit_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i.ZERO)
		icon_img[n] = even
		tex[n] = ImageTexture.create_from_image(even)
	_retex()
	for i in 6:
		floaters.append({"t": 0.0, "text": "", "head": false, "x": 0.0})
	for n in BUTTON_NAMES:
		rects[n] = Rect2()
		down[n] = false

	vignette = TextureRect.new()
	vignette.texture = _vignette_tex()
	vignette.stretch_mode = TextureRect.STRETCH_SCALE
	vignette.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	vignette.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vignette.modulate.a = 0.0
	add_child(vignette)
	game = _layer(_draw_game)
	overlay = _layer(_draw_overlay)
	pad = _layer(_draw_pad)   # on top, so FULL stays crisp over the title screen
	draft = _layer(_draw_draft)
	draft.visible = false
	get_viewport().size_changed.connect(_layout)
	_layout()

func _layer(painter: Callable) -> Control:
	var c := Control.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(c)
	c.draw.connect(painter)
	return c

func _layout() -> void:
	real = get_viewport().get_visible_rect().size
	# 1.0 at 640x360, 1.5 at 960x540. With aspect "expand" one side can be longer, so take
	# the smaller ratio: the canvas is then at least 640x360 design pixels.
	var k: float = max(min(real.x / 640.0, real.y / 360.0), 0.25)
	if abs(k - round(k * 2.0) * 0.5) < 0.02:
		k = round(k * 2.0) * 0.5
	if k != px:
		px = k
		_retex()
	vs = (real / px).floor()
	vignette.position = Vector2.ZERO
	vignette.size = real
	for c in [game, pad, overlay, draft]:
		c.position = Vector2.ZERO
		c.size = vs
		c.scale = Vector2(px, px)
	# small system buttons, top-right (FULL and the resolution toggle also on desktop)
	rects["full"] = Rect2(vs.x - 50, 5, 44, 24)
	rects["res"] = Rect2(vs.x - 99, 5, 44, 24)
	rects["view"] = Rect2(vs.x - 148, 5, 44, 24)
	rects["sens"] = Rect2(vs.x - 197, 5, 44, 24)
	# thumb cluster, bottom-right (the right-centre of the screen stays free for aiming)
	rects["fire"] = Rect2(vs.x - 96, vs.y - 100, 74, 74)
	rects["jump"] = Rect2(vs.x - 160, vs.y - 62, 52, 52)
	rects["dash"] = Rect2(vs.x - 148, vs.y - 126, 52, 52)
	rects["reload"] = Rect2(vs.x - 78, vs.y - 154, 48, 48)
	rects["shove"] = Rect2(vs.x - 218, vs.y - 62, 52, 52)
	stick_home = Vector2(88, vs.y - 84)
	if not stick_active:
		stick_center = stick_home
	pad.queue_redraw()
	game.queue_redraw()
	overlay.queue_redraw()
	draft.queue_redraw()

# (Re)build the textures that depend on the scale.
func _retex() -> void:
	ring_tex.clear()
	solid_tex.clear()
	font_aa = _smooth(font_img, font_tex)
	font_aa_k = float(font_aa.get_width()) / float(font_tex.get_width())
	for n in icon_img:
		tex_aa[n] = _smooth(icon_img[n], tex[n])

# A copy of `img` scaled by px with soft edges (each texel covers exactly px pixels), for
# art drawn 1:1 at a half-step scale such as 1.5x. At whole scales the original is fine.
func _smooth(img: Image, plain: ImageTexture) -> ImageTexture:
	var n := int(round(px * 2.0))
	if n < 3 or (n & 1) == 0 or abs(px * 2.0 - n) > 0.01:
		return plain
	var big := img.duplicate() as Image
	big.resize(img.get_width() * n, img.get_height() * n, Image.INTERPOLATE_NEAREST)
	big.resize(img.get_width() * n / 2, img.get_height() * n / 2, Image.INTERPOLATE_BILINEAR)
	return ImageTexture.create_from_image(big)

# Outlined bitmap from rows of text. Drawn with a modulate colour, the white ('#') part
# takes that colour and the outline stays dark.
func _bitmap(rows: Array, colors: Dictionary) -> Image:
	var h := rows.size()
	var w: int = rows[0].length()
	var img := Image.create(w + 2, h + 2, false, Image.FORMAT_RGBA8)
	for y in h:
		var row: String = rows[y]
		for x in w:
			var ch := row[x]
			if ch != ".":
				img.set_pixel(x + 1, y + 1, colors[ch])
	_outline(img)
	return img

func _outline(img: Image) -> void:
	var src := img.duplicate() as Image
	for y in img.get_height():
		for x in img.get_width():
			if src.get_pixel(x, y).a > 0.0:
				continue
			var near := false
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var nx: int = x + dx
					var ny: int = y + dy
					if nx >= 0 and ny >= 0 and nx < img.get_width() and ny < img.get_height() and src.get_pixel(nx, ny).a > 0.0:
						near = true
			if near:
				img.set_pixel(x, y, Color(0.04, 0.03, 0.08, 1.0))

# Font atlas: 16 glyphs per row, each in a 7x9 cell (5x7 glyph + outline), 1 px apart.
func _build_font() -> void:
	var keys := FONT.keys()
	var atlas := Image.create(16 * 8, ((keys.size() + 1 + 15) >> 4) * 10, false, Image.FORMAT_RGBA8)
	for i in keys.size():
		var cell := i + 1   # cell 0 stays empty
		var rows := []
		for bits in FONT[keys[i]]:
			var s := ""
			for b in 5:
				s += "#" if (bits >> (4 - b)) & 1 else "."
			rows.append(s)
		var g := _bitmap(rows, ICON_COLORS)
		atlas.blit_rect(g, Rect2i(0, 0, 7, 9), Vector2i((cell & 15) * 8, (cell >> 4) * 10))
		var code: int = keys[i].unicode_at(0)
		glyph_ix[code] = cell
		if code >= 65 and code <= 90:
			glyph_ix[code + 32] = cell   # lowercase draws as capitals
	font_img = atlas
	font_tex = ImageTexture.create_from_image(atlas)

# `design_d` is the diameter in design pixels; the image is made at the real size.
func _disc_tex(design_d: int, solid: bool) -> ImageTexture:
	var cache := solid_tex if solid else ring_tex
	var d := int(round(design_d * px))
	if cache.has(d):
		return cache[d]
	var img := Image.create(d, d, false, Image.FORMAT_RGBA8)
	var r := d / 2.0
	var ring_w: float = round((2.0 if design_d < 80 else 3.0) * px)
	for y in d:
		for x in d:
			var dist := Vector2(x + 0.5 - r, y + 0.5 - r).length()
			if dist > r:
				continue
			if dist > r - 1.0:
				img.set_pixel(x, y, Color(0.04, 0.03, 0.08, 0.85))
			elif solid:
				var v := 1.0 if y < d * 0.62 else 0.8   # flat pixel-art shading on the lower part
				img.set_pixel(x, y, Color(v, v, v, 1.0))
			elif dist > r - 1.0 - ring_w:
				img.set_pixel(x, y, Color.WHITE)
			else:
				img.set_pixel(x, y, Color(0.05, 0.04, 0.1, 0.42))
	var t := ImageTexture.create_from_image(img)
	cache[d] = t
	return t

func _vignette_tex() -> ImageTexture:
	var img := Image.create(160, 90, false, Image.FORMAT_RGBA8)
	for y in 90:
		for x in 160:
			var d := Vector2((x + 0.5) / 80.0 - 1.0, (y + 0.5) / 45.0 - 1.0).length()
			var a: float = pow(clamp((d - 0.55) / 0.75, 0.0, 1.0), 1.4)
			img.set_pixel(x, y, Color(0.9, 0.05, 0.08, a))
	return ImageTexture.create_from_image(img)

# ------------------------------------------------------------------ drawing helpers

func _text_w(s: String, sc: float) -> float:
	return (s.length() * 6 - 1) * sc

# Bitmap text. `pos` is the top-left of the letters (align 0), their top-centre (1) or
# top-right (2); letters are 7*sc tall. A second colour gives a two-tone logo look.
func _text(ci: CanvasItem, s: String, pos: Vector2, sc: float, col: Color, align := 0, col2 := CLEAR) -> void:
	var n := s.length()
	var x := pos.x
	if align == 1:
		x -= _text_w(s, sc) * 0.5
	elif align == 2:
		x -= _text_w(s, sc)
	x = _snap(floor(x) - sc)
	var y: float = _snap(floor(pos.y) - sc)
	# small text at 1.5x uses the smoothed atlas; bigger text scales the sharp one
	var t := font_tex
	var k := 1.0
	if sc * px < 2.0:
		t = font_aa
		k = font_aa_k
	for i in n:
		var cell: int = glyph_ix.get(s.unicode_at(i), 0)
		if cell > 0:
			var sx := float((cell & 15) * 8) * k
			var sy := float((cell >> 4) * 10) * k
			if col2.a > 0.0:
				ci.draw_texture_rect_region(t, Rect2(x, y, 7 * sc, 5 * sc), Rect2(sx, sy, 7 * k, 5 * k), col)
				ci.draw_texture_rect_region(t, Rect2(x, y + 5 * sc, 7 * sc, 4 * sc), Rect2(sx, sy + 5 * k, 7 * k, 4 * k), col2)
			else:
				ci.draw_texture_rect_region(t, Rect2(x, y, 7 * sc, 9 * sc), Rect2(sx, sy, 7 * k, 9 * k), col)
		x += 6 * sc

# Chunky logo lettering: dark extruded copy underneath, two-tone face on top.
func _logo(ci: CanvasItem, s: String, pos: Vector2, sc: float, top: Color, bottom: Color, depth: Color) -> void:
	var e: float = max(1.0, floor(sc * 0.5))
	_text(ci, s, pos + Vector2(e, e), sc, depth, 1)
	_text(ci, s, pos, sc, top, 1, bottom)

func _icon_at(ci: CanvasItem, name: String, pos: Vector2, sc: float, col := Color.WHITE) -> void:
	var t: ImageTexture = tex[name]
	var size := t.get_size() * sc
	if sc * px < 2.0:
		t = tex_aa[name]
	ci.draw_texture_rect(t, Rect2(Vector2(_snap(floor(pos.x)), _snap(floor(pos.y))), size), false, col)

func _icon_mid(ci: CanvasItem, name: String, mid: Vector2, sc: float, col := Color.WHITE) -> void:
	var t: ImageTexture = tex[name]
	_icon_at(ci, name, mid - t.get_size() * sc * 0.5, sc, col)

# Nearest design coordinate that lands on a whole real pixel.
func _snap(v: float) -> float:
	return v if px == 1.0 else round(v * px) / px

# Filled rectangle, snapped to whole real pixels so that 1-pixel lines keep an even
# thickness at 1.5x (they become 2 real pixels).
func _r(ci: CanvasItem, r: Rect2, col: Color) -> void:
	if px == 1.0:
		ci.draw_rect(r, col)
		return
	var w: float = round(r.size.x * px)
	var h: float = round(r.size.y * px)
	if w <= 0.0 or h <= 0.0:
		return
	ci.draw_rect(Rect2(round(r.position.x * px) / px, round(r.position.y * px) / px, w / px, h / px), col)

# Rounded-corner box: translucent fill with a 1 px border.
func _box(ci: CanvasItem, r: Rect2, fill: Color, border: Color) -> void:
	_r(ci, Rect2(r.position + Vector2(1, 1), r.size - Vector2(2, 2)), fill)
	_r(ci, Rect2(r.position.x + 1, r.position.y, r.size.x - 2, 1), border)
	_r(ci, Rect2(r.position.x + 1, r.end.y - 1, r.size.x - 2, 1), border)
	_r(ci, Rect2(r.position.x, r.position.y + 1, 1, r.size.y - 2), border)
	_r(ci, Rect2(r.end.x - 1, r.position.y + 1, 1, r.size.y - 2), border)

func _a(c: Color, a: float) -> Color:
	return Color(c.r, c.g, c.b, a)

func _blink(period := 0.9) -> bool:
	return fmod(time, period) < period * 0.6

func _reset(ci: CanvasItem) -> void:
	ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

# ------------------------------------------------------------------ per-frame

func _process(dt: float) -> void:
	time += dt
	if msg_t > 0.0:
		msg_t -= dt
		if msg_t <= 0.0:
			msg_lines = PackedStringArray()
	banner_t = max(banner_t - dt, 0.0)
	score_pop = max(score_pop - dt * 4.0, 0.0)
	combo_pop = max(combo_pop - dt * 5.0, 0.0)
	if combo < 2:
		combo_fade = max(combo_fade - dt * 3.0, 0.0)
	hp_flash = max(hp_flash - dt * 3.0, 0.0)
	dash_flash = max(dash_flash - dt * 4.0, 0.0)
	shove_flash = max(shove_flash - dt * 4.0, 0.0)
	cross_kick = max(cross_kick - dt * 7.0, 0.0)
	hit_t = max(hit_t - dt, 0.0)
	kill_t = max(kill_t - dt, 0.0)
	hp_trail = max(hp, hp_trail - dt * 45.0)
	if shown_score != score:
		shown_score = move_toward(shown_score, score, max(60.0, abs(score - shown_score) * 6.0) * dt)
		score_str = str(int(round(shown_score)))
	for f in floaters:
		if f.t > 0.0:
			f.t -= dt
	if screen == SCREEN_NONE and have_stats:
		play_time += dt
	if screen == SCREEN_OVER:
		over_t += dt

	# red screen edges: sharp flash when bitten, slow heartbeat when nearly dead
	var v: float = hurt * 0.85
	if screen == SCREEN_OVER:
		v = 0.7
	elif have_stats and hp <= 30.0:
		v = max(v, 0.28 + 0.2 * sin(time * 7.0))
	vignette.modulate.a = v
	vignette.visible = v > 0.01

	game.visible = have_stats and screen == SCREEN_NONE
	if game.visible:
		game.queue_redraw()
	overlay.visible = screen != SCREEN_NONE or banner_t > 0.0 or not msg_lines.is_empty()
	if overlay.visible:
		overlay.queue_redraw()
	if dash_ready < 1.0 or dash_flash > 0.0 or shove_ready < 1.0 or shove_flash > 0.0:
		pad.queue_redraw()
	if get_viewport().get_visible_rect().size != real:
		_layout()   # belt and braces: the resolution toggle should also emit size_changed

	if draft_open:
		draft_t += min(dt, 0.05)   # capped: a frame hitch must not eat the input guard
	elif draft_out > 0.0:
		draft_out = max(draft_out - dt, 0.0)
	draft.visible = draft_open or draft_out > 0.0
	if draft.visible:
		draft.queue_redraw()

# ------------------------------------------------------------------ game HUD

func _draw_game() -> void:
	var g := game
	var low := hp <= 30.0
	# --- health, top-left ---
	var beat := 1.0
	if low:
		beat = 1.0 + 0.25 * max(sin(time * 14.0), 0.0)
	_icon_mid(g, "heart", Vector2(16, 15), 2.0 * beat, RED.lerp(Color.WHITE, hp_flash))
	# the bar grows and shrinks a little with max health (upgrades change it)
	var bar := Rect2(30, 8, clamp(104.0 + (max_hp - 100.0) * 0.4, 70.0, 150.0), 13)
	_box(g, bar, _a(INK, 0.75), INK)
	var inner := Rect2(bar.position + Vector2(2, 2), bar.size - Vector2(4, 4))
	var frac: float = clamp(hp / max(max_hp, 1.0), 0.0, 1.0)
	var trail: float = clamp(hp_trail / max(max_hp, 1.0), 0.0, 1.0)
	if trail > frac:
		_r(g, Rect2(inner.position, Vector2(round(inner.size.x * trail), inner.size.y)), PAPER)
	var hp_col := GREEN
	if frac < 0.3:
		hp_col = RED if _blink(0.3) else ORANGE
	elif frac < 0.6:
		hp_col = YELLOW
	hp_col = hp_col.lerp(Color.WHITE, hp_flash)
	var fill_w: float = round(inner.size.x * frac)
	if fill_w > 0:
		_r(g, Rect2(inner.position, Vector2(fill_w, inner.size.y)), hp_col)
		_r(g, Rect2(inner.position, Vector2(fill_w, 2)), hp_col.lightened(0.45))
		_r(g, Rect2(inner.position.x, inner.end.y - 2, fill_w, 2), hp_col.darkened(0.3))
	for i in range(1, 4):   # quarter notches
		_r(g, Rect2(inner.position.x + inner.size.x * i / 4.0, inner.position.y, 1, inner.size.y), _a(INK, 0.45))
	var hp_str := str(int(ceil(max(hp, 0.0))))
	_text(g, hp_str, Vector2(bar.end.x + 5, 11), 1, PAPER.lerp(RED, hp_flash))
	if max_hp != 100.0:
		_text(g, "/%d" % int(max_hp), Vector2(bar.end.x + 5 + hp_str.length() * 6, 11), 1, _a(PAPER, 0.55))
	if low and _blink(0.5):
		_text(g, "LOW!", Vector2(bar.end.x + 5, 22), 1, RED)

	# --- dash cooldown, under the health bar ---
	var ready := dash_ready >= 1.0
	var dcol := YELLOW.lerp(Color.WHITE, dash_flash) if ready else Color(0.6, 0.6, 0.66)
	_icon_at(g, "bolt", Vector2(30, 24), 1, dcol)
	var dbar := Rect2(40, 26, 58, 6)
	_r(g, dbar, INK)
	_r(g, Rect2(dbar.position + Vector2(1, 1), Vector2(round((dbar.size.x - 2) * dash_ready), dbar.size.y - 2)), dcol)
	if ready:
		_text(g, "DASH", Vector2(102, 25), 1, dcol)

	# --- shove cooldown, under the dash bar ---
	var sready := shove_ready >= 1.0
	var scol := Color(0.78, 0.64, 1.0).lerp(Color.WHITE, shove_flash) if sready else Color(0.6, 0.6, 0.66)
	_icon_at(g, "fist", Vector2(29, 34), 1, scol)
	var sbar := Rect2(40, 37, 58, 6)
	_r(g, sbar, INK)
	_r(g, Rect2(sbar.position + Vector2(1, 1), Vector2(round((sbar.size.x - 2) * shove_ready), sbar.size.y - 2)), scol)
	if sready:
		_text(g, "SHOVE", Vector2(102, 36), 1, scol)

	# --- upgrades taken so far: one small icon each (a digit when stacked) ---
	var up := Vector2(8, 48)
	for u in taken:
		_icon_at(g, u.icon, up, 1, u.color)
		up.x += 12
		if u.n > 1:
			_text(g, str(u.n), up + Vector2(-1, 2), 1, _a(PAPER, 0.8))
			up.x += 8
		if up.x > 140:
			up = Vector2(8, up.y + 11)

	# --- wave + zombies left + score, top-centre ---
	var cx: float = floor(vs.x * 0.5)
	var ww: float = _text_w(wave_str, 1) + 12
	var lw: float = _text_w(left_str, 1) + 12 if zombies_left > 0 else -4.0
	var wx: float = floor(cx - (ww + 4 + lw) * 0.5)
	_box(g, Rect2(wx, 4, ww, 13), _a(INK, 0.7), _a(GREEN, 0.9))
	_text(g, wave_str, Vector2(wx + 6, 7), 1, GREEN)
	if zombies_left > 0:
		# the last stragglers get a louder colour so you know to go and find them
		var lcol := _a(PAPER, 0.85)
		if zombies_left <= 3:
			lcol = YELLOW if _blink(0.5) else ORANGE
		_box(g, Rect2(wx + ww + 4, 4, lw, 13), _a(INK, 0.7), _a(lcol, 0.7))
		_text(g, left_str, Vector2(wx + ww + 10, 7), 1, lcol)
	var pop: float = 1.0 + 0.4 * score_pop
	g.draw_set_transform(Vector2(cx, 28), 0.0, Vector2(pop, pop))
	_text(g, score_str, Vector2(0, -7), 2, PAPER.lerp(YELLOW, min(score_pop * 1.5, 1.0)), 1)
	_reset(g)

	# --- combo ---
	if combo_fade > 0.0 and combo_shown > 1:
		var heat: float = clamp((combo_shown - 2) / 6.0, 0.0, 1.0)
		var ccol := YELLOW.lerp(RED, heat)
		if combo_shown >= 6 and fmod(time, 0.16) < 0.08:
			ccol = PINK
		var shake := Vector2(sin(time * 47.0), cos(time * 39.0)) * (0.6 + heat * 1.8)
		var cs: float = (1.0 + 0.6 * combo_pop) * min(combo_fade * 2.0, 1.0)
		g.draw_set_transform(Vector2(cx, 50) + shake, sin(time * 9.0) * 0.04 * (1.0 + heat), Vector2(cs, cs))
		_text(g, combo_str, Vector2(0, -7), 2, _a(ccol, min(combo_fade * 2.0, 1.0)), 1)
		_reset(g)
		if combo > 1:
			var bw: float = round(60.0 * combo_frac)
			_r(g, Rect2(cx - 31, 61, 62, 4), _a(INK, 0.8))
			_r(g, Rect2(cx - bw * 0.5, 62, bw, 2), ccol)

	# --- ammo, bottom-centre ---
	var sw := 8.0
	var total := max_ammo * sw - 2.0
	var ax: float = floor(cx - total * 0.5)
	var ay: float = vs.y - 24
	var filled := float(ammo)
	if reloading:
		filled = max_ammo * reload_frac
	_box(g, Rect2(ax - 5, ay - 4, total + 10, 22), _a(INK, 0.55), _a(INK, 0.9))
	for i in max_ammo:
		var x := ax + i * sw
		if i < int(filled):
			var hop := 0.0
			if reloading and i == int(filled) - 1:
				hop = -2.0
			_r(g, Rect2(x + 1, ay + hop, 4, 1), RED)
			_r(g, Rect2(x, ay + 1 + hop, 6, 9), RED)
			_r(g, Rect2(x + 1, ay + 1 + hop, 1, 9), RED.lightened(0.45))
			_r(g, Rect2(x, ay + 10 + hop, 6, 4), YELLOW)
			_r(g, Rect2(x, ay + 12 + hop, 6, 1), ORANGE)
		else:
			_r(g, Rect2(x, ay + 1, 6, 13), Color(1, 1, 1, 0.13))
	if reloading:
		if _blink(0.3):
			_text(g, "RELOADING", Vector2(cx, ay - 15), 1, YELLOW, 1)
	elif ammo == 0:
		if _blink(0.4):
			_text(g, "EMPTY! RELOAD" if touch_mode else "EMPTY! PRESS R", Vector2(cx, ay - 15), 1, RED, 1)
	elif ammo <= 2 and _blink(0.6):
		_text(g, "LOW AMMO", Vector2(cx, ay - 15), 1, ORANGE, 1)

	# --- desktop reminder of the keys, fades out after a while ---
	if not touch_mode and play_time < 14.0:
		var ka: float = clamp(14.0 - play_time, 0.0, 1.0) * 0.9
		_text(g, "SHIFT DASH  SPACE JUMP", Vector2(8, vs.y - 38), 1, _a(PAPER, ka))
		_text(g, "E SHOVE  R RELOAD", Vector2(8, vs.y - 26), 1, _a(PAPER, ka))
		_text(g, "V VIEW  G RESOLUTION", Vector2(8, vs.y - 14), 1, _a(PAPER, ka))

	_draw_crosshair(g)

func _draw_crosshair(g: Control) -> void:
	var c := (vs * 0.5).floor()
	if reloading:
		# a filling ring instead of the ticks: you cannot shoot right now
		var p := reload_frac
		g.draw_arc(c, 9, 0, TAU, 20, _a(INK, 0.7), 4.0)
		g.draw_arc(c, 9, -PI * 0.5, -PI * 0.5 + TAU * p, 20, YELLOW, 2.0)
	else:
		var gap: float = 3.0 + round(cross_kick * 5.0)
		var col := PAPER if ammo > 0 else RED
		for d in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
			var along: Vector2 = d * (gap + 3.0)
			var half := Vector2(abs(d.x) * 3.0 + abs(d.y), abs(d.y) * 3.0 + abs(d.x))
			_r(g, Rect2(c + along - half - Vector2(1, 1), half * 2 + Vector2(2, 2)), _a(INK, 0.85))
			_r(g, Rect2(c + along - half, half * 2), col)
	_r(g, Rect2(c - Vector2(2, 2), Vector2(4, 4)), _a(INK, 0.85))
	_r(g, Rect2(c - Vector2(1, 1), Vector2(2, 2)), PAPER)

	# hit marker: white X for a body hit, bigger yellow X for a headshot, red burst for a kill
	if hit_t > 0.0 or kill_t > 0.0:
		var k: float = kill_t / 0.35
		var h: float = hit_t / 0.18
		var col := YELLOW if hit_head else PAPER
		var a := 5.0 + (1.0 - h) * 2.0
		var b := a + (7.0 if hit_head else 4.0)
		if kill_t > 0.0:
			col = RED.lerp(YELLOW, k) if hit_head else RED
			a = 6.0 + (1.0 - k) * 5.0
			b = a + 8.0
		for d in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
			g.draw_line(c + d * (a - 1.0), c + d * (b + 1.0), INK, 4.0)
			g.draw_line(c + d * a, c + d * b, col, 2.0)

	# floating score for each kill
	for f in floaters:
		if f.t > 0.0:
			var age: float = 1.0 - f.t / 0.9
			var p := c + Vector2(f.x, -26.0 - age * 30.0)
			var fa: float = clamp(f.t / 0.3, 0.0, 1.0)
			var fs: float = 2.0 if age > 0.08 else 3.0
			_text(g, f.text, p, fs, _a(YELLOW if f.head else PAPER, fa), 1)
			if f.head:
				_text(g, "HEADSHOT!", p + Vector2(0, -10), 1, _a(ORANGE, fa), 1)

# ------------------------------------------------------------------ touch controls

func _draw_round(name: String, label: String, col: Color, icon := "", label_sc := 1.0) -> void:
	var r: Rect2 = rects[name]
	var d := int(r.size.x)
	var mid := r.get_center()
	var is_down: bool = down[name]
	var tc := col.lerp(Color.WHITE, 0.35)
	var push := Vector2.ZERO
	if is_down:
		pad.draw_texture_rect(_disc_tex(d, true), r, false, _a(col, 0.92))
		tc = Color.WHITE
		push = Vector2(0, 1)
	else:
		pad.draw_texture_rect(_disc_tex(d, false), r, false, col)
	if icon != "":
		_icon_mid(pad, icon, mid + Vector2(0, -6) + push, 2, tc)
		_text(pad, label, mid + Vector2(0, 7) + push, label_sc, tc, 1)
	else:
		_text(pad, label, mid + Vector2(0, -3.5 * label_sc) + push, label_sc, tc, 1)

func _draw_small(name: String, label: String) -> void:
	var r: Rect2 = rects[name]
	var is_down: bool = down[name]
	_box(pad, r, _a(PAPER, 0.75) if is_down else _a(INK, 0.6), _a(PAPER, 0.85))
	var y := r.position.y + (4.0 if name == "sens" else 8.0)
	_text(pad, label, Vector2(r.get_center().x, y), 1, PAPER, 1)

func _draw_pad() -> void:
	_draw_small("full", "FULL")
	_draw_small("res", quality_label)
	if not touch_mode or screen != SCREEN_NONE or draft_open:
		return
	_draw_small("view", "VIEW")
	_draw_small("sens", "SENS")
	var sr: Rect2 = rects["sens"]
	for i in 5:   # sensitivity level as five pips
		_r(pad, Rect2(sr.position.x + 8 + i * 6, sr.position.y + 15, 4, 4), CYAN if i < sens_level else _a(PAPER, 0.25))

	# joystick: the base follows the thumb while it is held
	var base_a := 0.95 if stick_active else 0.6
	pad.draw_texture_rect(_disc_tex(112, false), Rect2(stick_center - Vector2(56, 56), Vector2(112, 112)), false, _a(PAPER, base_a))
	for d in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
		_r(pad, Rect2(stick_center + d * 44 - Vector2(2, 2), Vector2(4, 4)), _a(PAPER, base_a * 0.7))
	var kp := stick_center + stick_offset
	pad.draw_texture_rect(_disc_tex(46, true), Rect2((kp - Vector2(23, 23)).floor(), Vector2(46, 46)), false,
		_a(PAPER, 0.95) if stick_active else _a(PAPER, 0.7))

	_draw_round("fire", "FIRE", ORANGE.lerp(RED, 0.5), "", 2.0)
	_draw_round("jump", "JUMP", CYAN, "up")
	_draw_round("reload", "RELOAD", GREEN)
	var ready := dash_ready >= 1.0
	_draw_round("dash", "DASH", YELLOW.lerp(Color.WHITE, dash_flash) if ready else Color(0.55, 0.55, 0.6), "bolt")
	if not ready:
		var dr: Rect2 = rects["dash"]
		pad.draw_arc(dr.get_center(), dr.size.x * 0.5 - 2.0, -PI * 0.5, -PI * 0.5 + TAU * dash_ready, 24, YELLOW, 2.0)
	var sready := shove_ready >= 1.0
	var violet := Color(0.72, 0.56, 1.0)
	_draw_round("shove", "SHOVE", violet.lerp(Color.WHITE, shove_flash) if sready else Color(0.55, 0.55, 0.6), "fist")
	if not sready:
		var hr: Rect2 = rects["shove"]
		pad.draw_arc(hr.get_center(), hr.size.x * 0.5 - 2.0, -PI * 0.5, -PI * 0.5 + TAU * shove_ready, 24, violet, 2.0)

# ------------------------------------------------------------------ overlays

func _draw_overlay() -> void:
	var o := overlay
	var cx: float = floor(vs.x * 0.5)
	if screen == SCREEN_TITLE:
		_draw_title(o, cx)
	elif screen == SCREEN_OVER:
		_draw_game_over(o, cx)
	if banner_t > 0.0 and screen == SCREEN_NONE:
		_draw_banner(o, cx)
	if not msg_lines.is_empty():
		var y: float = floor(vs.y * 0.3) - msg_lines.size() * 9
		for line in msg_lines:
			_text(o, line, Vector2(cx, y), 2, PAPER, 1)
			y += 20

func _draw_banner(o: Control, cx: float) -> void:
	var age := WAVE_BANNER_TIME - banner_t
	var tin: float = clamp(age / 0.25, 0.0, 1.0)
	var tout: float = clamp(banner_t / 0.3, 0.0, 1.0)
	var open: float = ease(tin, 0.4) * tout
	var y: float = floor(vs.y * 0.23)
	var h: float = round(46.0 * open)
	var mid := y + 23.0
	_r(o, Rect2(0, mid - h * 0.5, vs.x, h), _a(INK, 0.72))
	_r(o, Rect2(0, mid - h * 0.5, vs.x, 2), GREEN)
	_r(o, Rect2(0, mid + h * 0.5 - 2, vs.x, 2), GREEN)
	if open < 0.6:
		return
	# the words slam in from the left, drift a little, then leave to the right
	var slide: float = (1.0 - ease(tin, 0.25)) * -vs.x * 0.6 + (1.0 - tout) * vs.x * 0.6 + (age - 1.2) * 6.0
	_logo(o, wave_str, Vector2(cx + slide, y + 6), 3, PAPER, GREEN, DKGREEN)
	_text(o, banner_line, Vector2(cx - slide * 0.5, y + 33), 1, YELLOW, 1)

func _draw_title(o: Control, cx: float) -> void:
	_r(o, Rect2(Vector2.ZERO, vs), _a(INK, 0.62))
	_r(o, Rect2(0, 0, vs.x, 26), _a(INK, 0.5))
	_r(o, Rect2(0, vs.y - 26, vs.x, 26), _a(INK, 0.5))
	var bob: float = round(sin(time * 2.2) * 3.0)
	# logo
	_logo(o, "ZOMBIE", Vector2(cx, 34 + bob), 6, Color(0.75, 1.0, 0.5), GREEN, Color(0.1, 0.3, 0.16))
	_logo(o, "BONK!", Vector2(cx, 88 - bob), 8, Color(1.0, 0.95, 0.45), ORANGE, DKRED)
	# a pair of onlookers
	for side in [-1.0, 1.0]:
		var hx: float = cx + side * min(190.0, vs.x * 0.5 - 60.0)
		o.draw_set_transform(Vector2(hx, 92 - bob), side * 0.18 + sin(time * 2.6 + side) * 0.12, Vector2.ONE)
		_icon_mid(o, "zombie", Vector2.ZERO, 4)
		_reset(o)
	_text(o, "A FAST, GOOFY UNDEAD WHACK-'EM-UP", Vector2(cx, 166), 1, _a(PAPER, 0.85), 1)

	if touch_mode:
		_box(o, Rect2(cx - 150, 186, 300, 50), _a(INK, 0.7), _a(PAPER, 0.5))
		_text(o, "LEFT THUMB: MOVE     RIGHT THUMB: SWIPE TO AIM", Vector2(cx, 196), 1, PAPER, 1)
		_text(o, "FIRE - JUMP - DASH - SHOVE - RELOAD ON THE RIGHT", Vector2(cx, 210), 1, _a(PAPER, 0.8), 1)
		_text(o, "AIM FOR THE HEAD FOR BONUS POINTS!", Vector2(cx, 224), 1, YELLOW, 1)
	else:
		var keys := [["WASD", "MOVE"], ["MOUSE", "AIM"], ["LMB", "SHOOT"], ["R", "RELOAD"],
			["E", "SHOVE"], ["SHIFT", "DASH"], ["SPACE", "JUMP"], ["V", "VIEW"], ["F", "FULLSCREEN"],
			["G", "RESOLUTION"]]
		_box(o, Rect2(cx - 132, 178, 264, 92), _a(INK, 0.7), _a(PAPER, 0.5))
		for i in keys.size():
			var kx: float = cx - 120 + (i / 5) * 130
			var ky: float = 185 + (i % 5) * 16
			_box(o, Rect2(kx, ky, 40, 13), Color(0.2, 0.19, 0.3), _a(PAPER, 0.8))
			_r(o, Rect2(kx + 1, ky + 11, 38, 1), _a(PAPER, 0.35))
			_text(o, keys[i][0], Vector2(kx + 20, ky + 3), 1, YELLOW, 1)
			_text(o, keys[i][1], Vector2(kx + 47, ky + 3), 1, PAPER)

	if _blink():
		_text(o, "TAP TO START" if touch_mode else "CLICK TO START", Vector2(cx, 282), 2, YELLOW, 1)
	if best_score > 0:
		_text(o, "BEST %d" % best_score, Vector2(cx, 306), 1, CYAN, 1)
	_text(o, "HEADSHOTS SCORE MORE - CHAIN KILLS FOR COMBOS", Vector2(cx, vs.y - 16), 1, _a(PAPER, 0.7), 1)

func _draw_game_over(o: Control, cx: float) -> void:
	var fade: float = clamp(over_t / 0.5, 0.0, 1.0)
	_r(o, Rect2(Vector2.ZERO, vs), Color(0.16, 0.02, 0.06, 0.72 * fade))
	# headline drops in and bounces
	var drop: float = clamp(over_t / 0.6, 0.0, 1.0)
	var yoff: float = round((1.0 - ease(drop, 0.3)) * -140.0 + (sin(drop * PI * 3.0) * 6.0 * (1.0 - drop)))
	_text(o, "YOU GOT", Vector2(cx, 30 + yoff), 3, PAPER, 1)
	_logo(o, "BONKED!", Vector2(cx, 62 + yoff + round(sin(time * 2.4) * 2.0)), 7, Color(1.0, 0.8, 0.4), RED, Color(0.3, 0.03, 0.08))
	if over_t < 0.5:
		return
	for side in [-1.0, 1.0]:
		var hx: float = cx + side * min(210.0, vs.x * 0.5 - 50.0)
		o.draw_set_transform(Vector2(hx, 190), side * 0.2 + sin(time * 5.0 + side) * 0.2, Vector2.ONE)
		_icon_mid(o, "zombie", Vector2.ZERO, 4)
		_reset(o)

	# score card
	var card := Rect2(cx - 120, 128, 240, 112)
	_box(o, card, _a(INK, 0.85), _a(PAPER, 0.7))
	var count: float = clamp((over_t - 0.5) / 1.0, 0.0, 1.0)
	_text(o, "SCORE", Vector2(cx, 136), 1, _a(PAPER, 0.75), 1)
	_text(o, str(int(over_score * ease(count, 0.4))), Vector2(cx, 148), 3, YELLOW, 1)
	if count >= 1.0:
		if over_best:
			if _blink(0.4):
				_text(o, "* NEW BEST! *", Vector2(cx, 175), 1, PINK, 1)
		else:
			_text(o, "BEST %d" % best_score, Vector2(cx, 175), 1, CYAN, 1)
	_r(o, Rect2(card.position.x + 10, 188, card.size.x - 20, 1), _a(PAPER, 0.3))
	var rows := [["WAVE", over_wave, GREEN], ["BONKS", kills, PAPER], ["HEADSHOTS", headshots, ORANGE], ["BEST COMBO", best_combo, PINK]]
	for i in rows.size():
		var rx: float = card.position.x + 14 + (i & 1) * 112
		var ry: float = 199 + (i >> 1) * 20
		_text(o, rows[i][0], Vector2(rx, ry), 1, _a(PAPER, 0.75))
		_text(o, str(rows[i][1]), Vector2(rx + 100, ry - 3), 2, rows[i][2], 2)

	if over_t > 1.2 and _blink():
		_text(o, "TAP TO TRY AGAIN" if touch_mode else "CLICK OR PRESS ENTER TO RETRY", Vector2(cx, 262), 2, YELLOW, 1)

	# the build you died with
	if not taken.is_empty():
		_text(o, "YOUR UPGRADES", Vector2(cx, 288), 1, _a(PAPER, 0.6), 1)
		var names := []
		var widths := []
		for u in taken:
			var s: String = u.title + (" X%d" % u.n if u.n > 1 else "")
			names.append(s)
			widths.append(_text_w(s, 1))
		var y := 300.0
		var i := 0
		while i < names.size() and y < vs.y - 8:
			var j := i   # fit as many as possible on this line, then centre it
			var w := 0.0
			while j < names.size() and (j == i or w + 14 + widths[j] <= vs.x - 40):
				w += (14 if j > i else 0) + widths[j]
				j += 1
			var x: float = floor(cx - w * 0.5)
			for k in range(i, j):
				_text(o, names[k], Vector2(x, y), 1, taken[k].color)
				x += widths[k] + 14
			i = j
			y += 11

# ------------------------------------------------------------------ interface used by controls.gd

func set_touch_mode(on: bool) -> void:
	touch_mode = on
	_layout()

# Screen rectangle (viewport coordinates) of a button; see BUTTON_NAMES.
func button_rect(name: String) -> Rect2:
	var r: Rect2 = rects.get(name, Rect2())
	return Rect2(r.position * px, r.size * px)

# Is the button currently usable? (touch-only buttons are hidden on desktop)
func button_active(name: String) -> bool:
	return name == "full" or name == "res" or touch_mode

# Touches that start inside this rectangle drive the movement joystick.
func stick_zone() -> Rect2:
	return Rect2(0, real.y * 0.25, real.x * 0.45, real.y * 0.75)

# Joystick visuals. `origin` is where the thumb went down, `offset` the current
# displacement from it (already limited to stick_radius()); both in viewport pixels.
func set_stick(active: bool, origin: Vector2, offset: Vector2) -> void:
	stick_active = active
	if active:
		origin /= px
		stick_center = Vector2(clamp(origin.x, 58.0, vs.x - 58.0), clamp(origin.y, 58.0, vs.y - 58.0))
		stick_offset = offset / px
	else:
		stick_center = stick_home
		stick_offset = Vector2.ZERO
	pad.queue_redraw()

func stick_radius() -> float:
	return 50.0 * px

func set_button_down(name: String, is_down: bool) -> void:
	down[name] = is_down
	pad.queue_redraw()

func set_sens(level: int) -> void:
	sens_level = level
	pad.queue_redraw()

# ------------------------------------------------------------------ interface used by main.gd

# d has: hp, max_hp, ammo, max_ammo, reloading (bool), reload_frac (0..1), score, wave, combo,
# combo_frac (0..1 of the combo timer left), hurt (0..1), dash_ready (0..1), shove_ready (0..1),
# zombies_left. Every key is optional.
func update_stats(d: Dictionary) -> void:
	var new_hp: float = d.get("hp", hp)
	var new_score: int = d.get("score", score)
	max_hp = d.get("max_hp", 100.0)
	if not have_stats:
		have_stats = true
		hp_trail = new_hp
		shown_score = new_score
		score_str = str(new_score)
	elif new_hp < hp:
		hp_flash = 1.0
	hp = new_hp
	var new_ammo: int = d.get("ammo", ammo)
	if new_ammo < ammo:
		cross_kick = 1.0
	ammo = new_ammo
	max_ammo = int(d.get("max_ammo", max_ammo))
	reloading = d.get("reloading", false)
	reload_frac = clamp(d.get("reload_frac", 0.0), 0.0, 1.0)
	if new_score > score:
		score_pop = 1.0
	score = new_score
	var new_wave: int = d.get("wave", wave)
	if new_wave != wave:
		wave = new_wave
		wave_str = "WAVE %d" % wave
	var new_combo: int = d.get("combo", 0)
	if new_combo != combo:
		combo = new_combo
		if combo > 1:
			combo_shown = combo
			combo_str = "COMBO X%d!" % combo
			combo_pop = 1.0
			combo_fade = 1.0
		best_combo = max(best_combo, combo)
	combo_frac = clamp(d.get("combo_frac", 0.0), 0.0, 1.0)
	hurt = d.get("hurt", 0.0)
	var dr: float = d.get("dash_ready", 1.0)
	if dr >= 1.0 and dash_ready < 1.0:
		dash_flash = 1.0
	dash_ready = dr
	var sr: float = d.get("shove_ready", 1.0)
	if sr >= 1.0 and shove_ready < 1.0:
		shove_flash = 1.0
	shove_ready = sr
	var zl: int = d.get("zombies_left", 0)
	if zl != zombies_left or left_str == "":
		zombies_left = zl
		left_str = "LAST ONE!" if zl == 1 else "ZOMBIES LEFT %d" % zl

# Big centred message. duration 0 = stays until replaced/cleared.
func show_message(text: String, duration := 0.0) -> void:
	msg_lines = text.split("\n")
	msg_t = duration

# Also dismisses the title screen: main.gd calls this when the game starts.
func clear_message() -> void:
	msg_lines = PackedStringArray()
	msg_t = 0.0
	if screen == SCREEN_TITLE:
		screen = SCREEN_NONE
		pad.queue_redraw()

func show_title() -> void:
	screen = SCREEN_TITLE
	msg_lines = PackedStringArray()
	pad.queue_redraw()

func show_game_over(final_score: int, final_wave: int) -> void:
	screen = SCREEN_OVER
	msg_lines = PackedStringArray()
	banner_t = 0.0
	over_score = final_score
	over_wave = final_wave
	over_best = final_score > best_score and final_score > 0
	best_score = max(best_score, final_score)
	over_t = 0.0
	pad.queue_redraw()

func on_hit(headshot: bool) -> void:  # a pellet hit a zombie
	# several pellets land in the same frame; a headshot among them wins
	if headshot or hit_t <= 0.12:
		hit_head = headshot
	hit_t = 0.18

func on_kill(points: int, headshot: bool) -> void:
	kills += 1
	if headshot:
		headshots += 1
	hit_head = headshot
	kill_t = 0.35
	var f: Dictionary = floaters[floater_next]
	f.t = 0.9
	f.text = "+%d" % points
	f.head = headshot
	f.x = (floater_next % 3 - 1) * 56.0
	floater_next = (floater_next + 1) % floaters.size()

func on_wave(new_wave: int) -> void:
	wave = new_wave
	wave_str = "WAVE %d" % wave
	banner_line = WAVE_LINES[(wave - 1) % WAVE_LINES.size()]
	banner_t = WAVE_BANNER_TIME

# ------------------------------------------------------------------ upgrade draft

# True while a full-screen choice (the upgrade draft) is waiting for the player.
# controls.gd stays silent meanwhile; the input is handled in _input below.
func modal_open() -> bool:
	return draft_open

# Text of the small resolution button ("360P" / "540P").
func set_quality_label(text: String) -> void:
	quality_label = text
	if pad != null:
		pad.queue_redraw()

# Show the upgrade cards and call on_pick.call(id) exactly once, when the player picks.
# cards: [{id, title, desc, color}] plus, optionally, icon (an icon name from build()),
# level (levels already owned) and max (shown as pips).
func show_upgrades(cards: Array, on_pick: Callable) -> void:
	if cards.is_empty():
		return
	draft_cards = cards
	draft_cb = on_pick
	draft_open = true
	draft_t = 0.0
	draft_out = 0.0
	draft_sel = -1
	draft_picked = -1
	draft_press.clear()
	draft_wave = wave
	banner_t = 0.0
	draft.visible = true
	draft.queue_redraw()
	pad.queue_redraw()

func _pick(i: int) -> void:
	if not draft_open or i < 0 or i >= draft_cards.size():
		return
	draft_open = false   # first, so that nothing can pick twice
	draft_picked = i
	draft_out = DRAFT_OUT
	draft_press.clear()
	var c: Dictionary = draft_cards[i]
	var found := false
	for u in taken:
		if u.id == c.id:
			u.n += 1
			found = true
	if not found:
		taken.append({"id": c.id, "title": c.get("title", ""), "color": c.get("color", PAPER),
			"icon": _card_icon(c), "n": 1})
	var m := get_parent()
	if m != null and "sfx" in m and m.sfx != null and m.sfx.has_method("play"):
		m.sfx.play("ui_click")
	pad.queue_redraw()
	var cb := draft_cb
	draft_cb = Callable()
	if cb.is_valid():
		cb.call(c.id)

func _card_icon(c: Dictionary) -> String:
	var n: String = c.get("icon", "up")
	return n if tex.has(n) else "up"

# Where card i rests, in design pixels.
func _card_rect(i: int) -> Rect2:
	var n := draft_cards.size()
	var gap: float = CARD_GAP + clamp(floor((vs.x - 640.0) / 6.0), 0.0, 18.0)
	var total: float = n * CARD_W + (n - 1) * gap
	return Rect2(floor((vs.x - total) * 0.5) + i * (CARD_W + gap), floor((vs.y - 360.0) * 0.5) + 92.0, CARD_W, CARD_H)

# Card under a point given in real viewport pixels, or -1.
func _card_at(p: Vector2) -> int:
	p /= px
	for i in draft_cards.size():
		if _card_rect(i).grow(4.0).has_point(p):
			return i
	return -1

# Split into lines of at most `width` characters, breaking at spaces.
func _wrap(s: String, width: int) -> PackedStringArray:
	var out := PackedStringArray()
	var line := ""
	for w in s.split(" ", false):
		if line != "" and line.length() + 1 + w.length() > width:
			out.append(line)
			line = w
		else:
			line = w if line == "" else line + " " + w
	if line != "":
		out.append(line)
	return out

func _draw_draft() -> void:
	var d := draft
	var cx: float = floor(vs.x * 0.5)
	var top: float = floor((vs.y - 360.0) * 0.5)
	var closing := not draft_open
	var q: float = draft_out / DRAFT_OUT if closing else 1.0   # 1 -> 0 while closing
	var fade: float = clamp(draft_t / 0.2, 0.0, 1.0) * q
	_r(d, Rect2(Vector2.ZERO, vs), _a(INK, 0.76 * fade))
	if not closing:
		# header drops in from the top
		var hin: float = clamp(draft_t / 0.25, 0.0, 1.0)
		var hy: float = top + round((1.0 - ease(hin, 0.3)) * -70.0)
		_r(d, Rect2(0, hy, vs.x, 80), _a(INK, 0.45))
		_r(d, Rect2(0, hy + 80, vs.x, 2), _a(GREEN, 0.9))
		_logo(d, "WAVE %d CLEARED!" % draft_wave, Vector2(cx, hy + 16), 3, PAPER, GREEN, DKGREEN)
		_text(d, "PICK ONE UPGRADE", Vector2(cx, hy + 52), 2, YELLOW, 1)
	for i in draft_cards.size():
		var r := _card_rect(i)
		var t: float = clamp((draft_t - 0.08 - i * 0.07) / 0.3, 0.0, 1.0) - 1.0
		var e: float = 1.0 + 2.70158 * t * t * t + 1.70158 * t * t   # ease out, with a little overshoot
		r.position.y += round((1.0 - e) * (vs.y - r.position.y + 12.0))
		var pressed := draft_press.values().has(i)
		var hot := draft_sel == i and not closing
		if closing:
			if i != draft_picked:
				r.position.y += round((1.0 - q) * (1.0 - q) * 160.0)
			else:
				r.position.y -= round((1.0 - q) * 10.0)
		elif pressed:
			r.position.y += 1.0
		elif hot:
			r.position.y -= 5.0
		_draw_card(d, i, draft_cards[i], r, hot, pressed)
		if closing and i == draft_picked:
			_r(d, r, _a(Color.WHITE, 0.8 * q))
	if not closing and draft_t > DRAFT_GUARD:
		var hint := "TAP A CARD" if touch_mode else "CLICK A CARD OR PRESS 1 - %d" % draft_cards.size()
		_text(d, hint, Vector2(cx, top + 92 + CARD_H + 16), 1, _a(PAPER, 0.8 if _blink(1.2) else 0.55), 1)

func _draw_card(d: Control, i: int, c: Dictionary, r: Rect2, hot: bool, pressed: bool) -> void:
	var col: Color = c.get("color", PAPER)
	var x := r.position.x
	var y := r.position.y
	var mid: float = x + r.size.x * 0.5
	# drop shadow, coloured frame, dark body
	if not pressed:
		_r(d, Rect2(x + 3, y + 5, r.size.x, r.size.y), _a(INK, 0.55))
	var frame := col
	if pressed:
		frame = Color.WHITE
	elif hot:
		frame = col.lerp(Color.WHITE, 0.55 + 0.35 * sin(time * 9.0))
	_box(d, r, frame, INK)
	_r(d, Rect2(x + 3, y + 3, r.size.x - 6, r.size.y - 6), Color(0.2, 0.19, 0.31) if hot or pressed else Color(0.13, 0.12, 0.21))
	# coloured band with the icon
	var band := Rect2(x + 3, y + 3, r.size.x - 6, 46)
	_r(d, band, col.darkened(0.5))
	_r(d, Rect2(band.position.x, band.end.y - 3, band.size.x, 3), col)
	for k in 6:   # a few diagonal-ish sparkles so the band is not a flat block
		_r(d, Rect2(band.position.x + 10 + ((k * 53 + i * 31) % int(band.size.x - 20)), band.position.y + 6 + (k * 17) % 30, 2, 2), _a(col, 0.45))
	var bob: float = round(sin(time * 3.0 + i * 1.3) * 1.5) if hot else 0.0
	_icon_mid(d, _card_icon(c), Vector2(mid, band.position.y + 21 + bob), 4, col.lerp(Color.WHITE, 0.35))
	# title (two lines if long) and description
	var lines := _wrap(c.get("title", ""), 13)
	var ty: float = y + 59 + (2 - min(lines.size(), 2)) * 9
	for k in min(lines.size(), 2):
		_text(d, lines[k], Vector2(mid, ty + k * 18), 2, PAPER, 1, col.lerp(PAPER, 0.35))
	var desc := _wrap(c.get("desc", ""), 26)
	for k in min(desc.size(), 3):
		_text(d, desc[k], Vector2(mid, y + 104 + k * 11), 1, _a(PAPER, 0.85), 1)
	# level pips: owned ones solid, the one this pick adds blinking
	var mx: int = c.get("max", 0)
	var lv: int = c.get("level", 0)
	if mx > 0:
		var pw := 12.0
		var px0: float = floor(mid - (mx * pw - 3.0) * 0.5)
		for k in mx:
			var pr := Rect2(px0 + k * pw, y + 146, 9, 6)
			_r(d, pr.grow(1), INK)
			if k < lv:
				_r(d, pr, col)
			elif k == lv:
				_r(d, pr, col.lerp(Color.WHITE, 0.6) if _blink(0.5) else _a(col, 0.35))
			else:
				_r(d, pr, Color(1, 1, 1, 0.12))
		if lv == 0:
			_text(d, "NEW!", Vector2(mid, y + 158), 1, YELLOW, 1)
		else:
			_text(d, "LEVEL %d > %d" % [lv, lv + 1], Vector2(mid, y + 158), 1, _a(PAPER, 0.75), 1)
	# how to pick it
	if touch_mode:
		_text(d, "TAP", Vector2(mid, r.end.y - 21), 1, _a(col, 0.9), 1)
	else:
		var kr := Rect2(mid - 9, r.end.y - 25, 18, 14)
		_box(d, kr, Color(0.2, 0.19, 0.3), _a(PAPER, 0.8))
		_r(d, Rect2(kr.position.x + 1, kr.end.y - 2, kr.size.x - 2, 1), _a(PAPER, 0.35))
		_text(d, str(i + 1), Vector2(mid, kr.position.y + 3), 1, YELLOW, 1)

# Input for the draft only. A card is picked when a press AND its release land on the same
# card, so a thumb still holding FIRE when the cards appear (its press came earlier)
# cannot pick anything, and neither can anything in the first DRAFT_GUARD seconds.
func _input(ev: InputEvent) -> void:
	if not draft_open:
		return
	var armed := draft_t >= DRAFT_GUARD
	if ev is InputEventScreenTouch:
		_draft_pointer(ev.index, ev.pressed, ev.position, armed)
	elif ev is InputEventMouseButton:
		if ev.button_index == MOUSE_BUTTON_LEFT:
			_draft_pointer(-1, ev.pressed, ev.position, armed)
	elif ev is InputEventMouseMotion:
		var h := _card_at(ev.position)
		if h >= 0 or draft_press.is_empty():
			draft_sel = h
	elif ev is InputEventKey:
		if not ev.pressed or ev.echo or not armed:
			return
		var n := draft_cards.size()
		match ev.keycode:
			KEY_1, KEY_KP_1: _pick(0)
			KEY_2, KEY_KP_2: _pick(1)
			KEY_3, KEY_KP_3: _pick(2)
			KEY_LEFT, KEY_A: draft_sel = n - 1 if draft_sel < 0 else (draft_sel + n - 1) % n
			KEY_RIGHT, KEY_D: draft_sel = 0 if draft_sel < 0 else (draft_sel + 1) % n
			KEY_ENTER, KEY_KP_ENTER: _pick(draft_sel)
			_: return
	elif ev is InputEventJoypadButton:
		if not ev.pressed or not armed:
			return
		var n := draft_cards.size()
		match ev.button_index:
			JOY_BUTTON_DPAD_LEFT: draft_sel = n - 1 if draft_sel < 0 else (draft_sel + n - 1) % n
			JOY_BUTTON_DPAD_RIGHT: draft_sel = 0 if draft_sel < 0 else (draft_sel + 1) % n
			JOY_BUTTON_A: _pick(draft_sel)
			_: return
	else:
		return
	get_viewport().set_input_as_handled()

func _draft_pointer(id: int, pressed: bool, pos: Vector2, armed: bool) -> void:
	var i := _card_at(pos)
	if pressed:
		if armed and i >= 0:
			draft_press[id] = i
			draft_sel = i
	else:
		var was: int = draft_press.get(id, -1)
		draft_press.erase(id)
		if was >= 0 and was == i:
			_pick(i)
