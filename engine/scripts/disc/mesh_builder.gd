class_name DiscMeshBuilder
extends RefCounted
## Turns DiscDmd meshes into Godot ArrayMeshes and collision shapes.
##
## Coordinates: the disc world is z-up; Godot is y-up. to_godot() maps (x, y, z) to
## (x, z, -y), a proper rotation (no mirroring: signs read correctly in renders), so the game's
## +y (vehicle front, heading 0) becomes Godot -Z, the VehicleModelProvider forward.
## One scale constant turns game units into metres: WORLD_UNIT_M = 1/32 m. Checks: the
## in-game cars (inside the arena files) are 117-219 units long, giving 3.7 m (Lambo) to
## 6.8 m (semi), ice cream truck 4.8 m; measured top speeds (46-66 units per tick, 20 ticks/s)
## give 29-41 m/s. (1/64 m, the first guess, made the cars 2.4 m long.)
##
## Colours: dmd.vertex_colors() (pre-lit colour words, or GTE lighting from the normals) are
## baked into vertex colours as colour / 256 (8-bit vertex colours cannot exceed 1.0); the
## shader multiplies by 2, so shown colour = texel * colour / 128 like the PS1. Polygons with
## the "raw texture" bit (GPU code bit 0) show the texel unmodulated.
## Semi-transparent polygons (code bit 1) use the blend mode from tpage bits 5-6 and blend only
## texels with the STP bit (alpha DiscVram.STP_ALPHA in the atlas); untextured ones blend fully.
## Texture windows: see DiscAtlas.entry_param (CUSTOM0 = A, W; UV = raw texel coordinates).
## Sprites: quads whose four vertices sit at the centre; CUSTOM1 = (offset x, offset y, kind)
## in metres, expanded in the vertex shader (kind 0 upright about world up, 1 camera-facing).

const DiscDmdScript := preload("res://scripts/disc/dmd.gd")
const Ps1SettingsScript := preload("res://scripts/render/ps1_settings.gd")

const WORLD_UNIT_M := 1.0 / 32.0

enum Blend { OPAQUE, HALF, ADD, SUB, QUARTER, SKY }

static var _shaders := {}
static var sky_priority := 0

static func to_godot(v: Vector3) -> Vector3:
	return Vector3(v.x, v.z, -v.y)

static func blend_of(poly) -> int:
	if not (poly.code & 0x02):
		return Blend.OPAQUE
	var abr: int = (poly.tpage >> 5) & 3 if poly.is_textured() else 0
	return [Blend.HALF, Blend.ADD, Blend.SUB, Blend.QUARTER][abr]

## Vertex colours of a polygon or sprite as Godot colours (see header).
static func vertex_colors(mesh, poly) -> PackedColorArray:
	var out := PackedColorArray()
	var raw: bool = poly.is_textured() and poly.code & 0x01
	for c in DiscDmdScript.vertex_colors(mesh, poly):
		if raw:
			out.append(Color(0.5, 0.5, 0.5))
		else:
			out.append(Color((c & 0xFF) / 256.0, ((c >> 8) & 0xFF) / 256.0, ((c >> 16) & 0xFF) / 256.0))
	return out

## Triangle corner order (PS1 quads and sprites are 0-1-2 + 1-3-2).
static func corners(n: int) -> PackedInt32Array:
	return PackedInt32Array([0, 1, 2, 1, 3, 2]) if n == 4 else PackedInt32Array([0, 1, 2])

class _Surface:
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var c0 := PackedFloat32Array()
	var c1 := PackedFloat32Array()
	var normals := PackedVector3Array()

## One ArrayMesh for the given meshes. xf maps Godot-axis game units to the final space
## (scale to metres plus any offset; no rotation when sprites are present).
## sky = true draws everything behind the scene (Blend.SKY; use with DiscSkyFollow).
## dynamic_light = true (vehicles): lit polygons keep their base colour and normals, and the
## shader lights them with the game's three lights in world space every frame, so a car's
## shading changes as it turns (the original does this; e.g. faces turned towards light 3
## go green).
static func build_mesh(meshes: Array, atlas, xf: Transform3D, sky := false, sprites := true, dynamic_light := false) -> ArrayMesh:
	var surf := {}   # "atlas:blend:sprite" -> _Surface
	var unit := xf.basis.get_scale().x
	for m in meshes:
		var verts: PackedVector3Array = m.vertices
		for p in m.polygons:
			var cols := vertex_colors(m, p)
			var nrm = null
			if dynamic_light:
				var li := _light_inputs(m, p)
				if not li.is_empty():
					cols = li[0]
					nrm = li[1]
			var pos := PackedVector3Array()
			for i in p.indices:
				pos.append(xf * to_godot(verts[i]))
			_add(surf, atlas, p, pos, cols, null, sky, nrm)
		if not sprites or sky:
			continue
		for s in m.sprites:
			var p = s[1]
			var c: Vector3 = xf * to_godot(s[0])
			var w: float = p.size.x * unit
			var h: float = p.size.y * unit
			var offs := [Vector2(-w, h), Vector2(w, h), Vector2(-w, -h), Vector2(w, -h)]   # TL TR BL BR
			var scols := vertex_colors(m, p)
			var snrm = null
			if dynamic_light:
				var sli := _light_inputs(m, p)
				if not sli.is_empty():
					scols = sli[0]
					snrm = sli[1]
			_add(surf, atlas, p, PackedVector3Array([c, c, c, c]), scols, offs, false, snrm)
	var mesh := ArrayMesh.new()
	var keys := surf.keys()
	keys.sort()
	var fmt := (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) | (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT)
	for sk in keys:
		var s: _Surface = surf[sk]
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = s.verts
		arr[Mesh.ARRAY_COLOR] = s.colors
		arr[Mesh.ARRAY_TEX_UV] = s.uvs
		arr[Mesh.ARRAY_CUSTOM0] = s.c0
		arr[Mesh.ARRAY_CUSTOM1] = s.c1
		arr[Mesh.ARRAY_NORMAL] = s.normals
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr, [], {}, fmt)
		var parts: PackedStringArray = sk.split(":")
		var a := int(parts[0])
		var tex: Texture2D = atlas.textures[a] if a >= 0 else null
		var size: Vector2 = atlas.size_of(a) if a >= 0 else Vector2.ONE
		mesh.surface_set_material(mesh.get_surface_count() - 1, material(int(parts[1]), parts[2] == "1", tex, size))
	return mesh

## [base colours (Godot colours, colour / 256), normals (Godot axes)] of a lit polygon, or []
## for a pre-lit one. Mirrors DiscDmd.vertex_colors without applying the lights.
static func _light_inputs(mesh, poly) -> Array:
	if poly.normals.is_empty():
		return []
	var sprite: bool = poly.kind == DiscDmdScript.Kind.SPRITE
	var nv: int = 4 if sprite else poly.indices.size()
	var ns: Array = []
	var have := true
	for i in poly.normals:
		if i >= mesh.normal_count():
			have = false
	if have:
		for i in poly.normals:
			ns.append(mesh.normals.slice(i * 3, i * 3 + 3))
	elif sprite:
		ns.append(mesh.raw_face_normals[poly])
	else:
		ns.append(DiscDmdScript.face_normal(mesh, poly))
	var raw: bool = poly.is_textured() and poly.code & 0x01
	if raw:
		return []
	var cols := PackedColorArray()
	var nrm := PackedVector3Array()
	for i in nv:
		var c: int = poly.colors[i] if poly.colors.size() >= nv else poly.colors[0]
		cols.append(Color((c & 0xFF) / 256.0, ((c >> 8) & 0xFF) / 256.0, ((c >> 16) & 0xFF) / 256.0))
		var n: PackedFloat64Array = ns[0] if ns.size() == 1 else ns[i % ns.size()]
		nrm.append(to_godot(Vector3(n[0], n[1], n[2])))
	return [cols, nrm]

static func _add(surf: Dictionary, atlas, p, pos: PackedVector3Array, cols: PackedColorArray, offs, sky: bool, nrm = null) -> void:
	var a := -1
	var key := 0
	if p.is_textured() and atlas != null:
		key = atlas.key_of(p)
		a = atlas.atlas_of(key)
	var sk := "%d:%d:%d" % [a, Blend.SKY if sky else blend_of(p), 1 if offs != null else 0]
	if not surf.has(sk):
		surf[sk] = _Surface.new()
	var s: _Surface = surf[sk]
	var param: Color = atlas.entry_param(key) if a >= 0 else Color(0, 0, 0, 0)
	var kind := float(p.sprite_kind) if offs != null else 0.0
	for c in corners(pos.size()):
		s.verts.append(pos[c])
		s.colors.append(cols[c] if c < cols.size() else cols[0])
		if a >= 0:
			var uv: int = p.uvs[c] if c < p.uvs.size() else p.uvs[0]
			s.uvs.append(Vector2(uv & 0xFF, (uv >> 8) & 0xFF))
		else:
			s.uvs.append(Vector2.ZERO)
		s.c0.append_array([param.r, param.g, param.b, param.a])
		if offs != null:
			var o: Vector2 = offs[c]
			s.c1.append_array([o.x, o.y, kind, 1.0 if nrm != null else 0.0])
		else:
			s.c1.append_array([0.0, 0.0, 0.0, 1.0 if nrm != null else 0.0])
		s.normals.append(nrm[c] if nrm != null and c < nrm.size() else Vector3.UP)

## Triangle soup (for ConcavePolygonShape3D) of every non-sprite polygon.
static func collision_faces(meshes: Array, xf: Transform3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	for m in meshes:
		var verts: PackedVector3Array = m.vertices
		for p in m.polygons:
			for c in corners(p.indices.size()):
				out.append(xf * to_godot(verts[p.indices[c]]))
	return out

## Axis-aligned bounds (Godot axes, game units) of the vertices the polygons use.
static func bounds(meshes: Array) -> AABB:
	var first := true
	var box := AABB()
	for m in meshes:
		for v in m.vertices:
			var g := to_godot(v)
			if first:
				box = AABB(g, Vector3.ZERO)
				first = false
			else:
				box = box.expand(g)
	return box

## A flat square (size metres, y = 0) in one colour, drawn with the disc shader (so it gets the
## same projection, depth cue and colour handling as the level): the arena's clear colour.
static func flat_quad(size: float, color: Color) -> ArrayMesh:
	var h := size * 0.5
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(-h, 0, -h), Vector3(h, 0, -h), Vector3(-h, 0, h), Vector3(h, 0, -h), Vector3(h, 0, h), Vector3(-h, 0, h)])
	var c := Color(color.r * 0.5, color.g * 0.5, color.b * 0.5, 0.0)   # alpha 0: no depth cue (clear colour)
	arr[Mesh.ARRAY_COLOR] = PackedColorArray([c, c, c, c, c, c])
	arr[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	m.surface_set_material(0, material(Blend.SKY, false, null, Vector2.ONE))   # behind everything, like a clear colour
	return m

static func material(blend: int, sprite: bool, tex: Texture2D, atlas_size: Vector2) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _shader(blend, sprite)
	m.set_shader_parameter("textured", tex != null)
	m.set_shader_parameter("atlas_size", atlas_size)
	if tex:
		m.set_shader_parameter("tex", tex)
	if blend != Blend.OPAQUE and blend != Blend.SKY:
		m.render_priority = 1
	if blend == Blend.SKY:
		m.render_priority = sky_priority
	return m

## Sampling: nearest-neighbour unless the player turned it off (Ps1Settings "nearest").
static func _shader(blend: int, sprite: bool) -> Shader:
	var nearest: bool = Ps1SettingsScript.get_value("nearest")
	var sk := "%d:%d:%d" % [blend, 1 if sprite else 0, 1 if nearest else 0]
	if _shaders.has(sk):
		return _shaders[sk]
	var mode := "blend_mix"
	var sky := "false"
	match blend:
		Blend.HALF, Blend.ADD, Blend.QUARTER: mode = "blend_premul_alpha"
		Blend.SUB: mode = "blend_sub"
		Blend.SKY:
			# Squeezed into a thin band just in front of the far plane (ps1_far_band ..
			# ps1_far), keeping its own depth order: like the PS1, which sorts the sky into
			# the far end of its ordering table, every level polygon draws over it.
			mode = "blend_mix, depth_draw_always"
			sky = "true"
	var view := "vec4 c = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);"
	if sprite:
		view += """
	vec3 right = vec3(1.0, 0.0, 0.0);
	vec3 up = vec3(0.0, 1.0, 0.0);
	if (CUSTOM1.z < 0.5) {   // upright: turn about the world up axis only
		up = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
		right = normalize(cross(vec3(0.0, 0.0, -1.0), up));
	}
	c.xyz += right * CUSTOM1.x + up * CUSTOM1.y;"""
	var out := ""
	match blend:
		Blend.OPAQUE:
			out = "ALBEDO = col;"
		Blend.SKY:
			# drawn in the transparent pass (after every opaque polygon) at the far plane, so
			# the depth test leaves it only where nothing else was drawn
			out = "ALBEDO = col;"
		Blend.HALF:
			out = "ALBEDO = stp ? col * 0.5 : col; ALPHA = stp ? 0.5 : 1.0;"
		Blend.ADD:
			out = "ALBEDO = col; ALPHA = stp ? 0.0 : 1.0;"
		Blend.QUARTER:
			out = "ALBEDO = stp ? col * 0.25 : col; ALPHA = stp ? 0.0 : 1.0;"
		Blend.SUB:
			out = "if (!stp) { discard; } ALBEDO = col;"
	var filt := "filter_nearest" if nearest else "filter_linear_mipmap_anisotropic"
	var sh := Shader.new()
	sh.code = """shader_type spatial;
render_mode unshaded, cull_disabled, %s;
// PS1 look (scripts/render/ps1_settings.gd): globals set by Ps1Settings.apply().
global uniform float ps1_xstretch;   // the game's view is 1/0.9 wider than tall
global uniform vec2 ps1_snap;        // vertex snapping grid (320x240), 0 = off
global uniform float ps1_affine;     // 1 = affine (PS1) texture mapping
global uniform float ps1_color15;    // 1 = 15-bit colour with the PS1 dither
global uniform vec3 ps1_fog;         // depth cue: clamp(x + y / depth_m), z = on
global uniform float ps1_far;        // clip-space z / w of the far plane (renderer-dependent)
global uniform float ps1_far_band;   // z / w where the sky band starts
global uniform float ps1_linearize;  // 1 = convert display-space colour to linear (renderer-dependent)
uniform sampler2D tex : %s, repeat_disable;
uniform bool textured = true;
uniform vec2 atlas_size = vec2(1.0);
uniform float menu_light = 0.0;   // 1: neutral white light (vehicle-select turntable)
uniform vec4 tint = vec4(0.0);   // per-vehicle flash: rgb, amount (per-instance material copies)
varying vec4 win;
varying vec3 uvw;      // (uv * w, w): divided per pixel for affine mapping
varying float vdepth;
void vertex() {
	win = CUSTOM0;
	if (CUSTOM1.w > 0.5) {
		// GTE lighting in world space (DiscDmd.LIGHTS / AMBIENT, Godot axes)
		vec3 n = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
		vec3 f = vec3(0.125);
		f += vec3(200.0, 200.0, 200.0) / 256.0 * max(0.0, dot(vec3(617.0, 2046.0, 3494.0) / 4096.0, n));
		f += vec3(128.0, 75.0, 75.0) / 256.0 * max(0.0, dot(vec3(-3425.0, 1056.0, -1982.0) / 4096.0, n));
		f += vec3(60.0, 128.0, 60.0) / 256.0 * max(0.0, dot(vec3(3332.0, 1398.0, -1928.0) / 4096.0, n));
		if (menu_light > 0.5) {
			// the original's select screen shows the cars in neutral white light
			vec3 l = normalize((INV_VIEW_MATRIX * vec4(0.35, 0.6, 1.0, 0.0)).xyz);   // from the viewer, upper right
			f = vec3(0.45 + 0.75 * max(0.0, dot(l, n)));
		}
		COLOR.rgb = min(floor(COLOR.rgb * 256.0 * f), vec3(255.0)) / 256.0;
	}
	%s
	vdepth = -c.z;
	vec4 p = PROJECTION_MATRIX * c;
	p.x *= ps1_xstretch;
	if (ps1_snap.x > 0.0 && p.w > 0.5) {
		// snap on-screen vertices to the 320x240 pixel grid (vertices far off screen or very
		// close to the camera are left alone so clipping stays stable)
		vec2 ndc = p.xy / p.w;
		if (abs(ndc.x) < 3.0 && abs(ndc.y) < 3.0) {
			vec2 half_res = ps1_snap * 0.5;
			p.xy = floor(ndc * half_res + 0.5) / half_res * p.w;
		}
	}
	if (%s) { p.z = p.w * mix(ps1_far_band, ps1_far, clamp(p.w / 1000.0, 0.0, 1.0)); }
	POSITION = p;
	uvw = vec3(UV * p.w, p.w);
}
void fragment() {
	vec3 col = COLOR.rgb * 2.0;   // PS1: texel * colour / 128 (vertex colour holds colour / 256)
	bool stp = true;              // untextured semi-transparent polygons blend everywhere
	if (textured) {
		vec2 uv = ps1_affine > 0.5 ? uvw.xy / uvw.z : UV;
		vec2 g = uv / atlas_size;  // continuous coordinates for mip selection
		vec2 px = win.xy + mod(uv, win.zw);   // texture window wrap (no-op when win.zw = 256)
		vec4 t = textureGrad(tex, px / atlas_size, dFdx(g), dFdy(g));
		if (t.a < 0.4) { discard; }   // colour 0 is transparent
		col *= t.rgb;
		stp = t.a < 0.9;              // STP texels carry alpha 200/255
	}
	if (ps1_fog.z > 0.5 && !%s && COLOR.a > 0.5) {
		col *= 1.0 - clamp(ps1_fog.x + ps1_fog.y / max(vdepth, 0.01), 0.0, 1.0);
	}
	// colourise towards tint.rgb keeping the brightness (frozen cars go blue in the original)
	col = clamp(mix(col, vec3(dot(col, vec3(0.3, 0.59, 0.11))) * tint.rgb, tint.a), 0.0, 1.0);
	if (ps1_color15 > 0.5) {
		// 15-bit frame buffer with the GPU's 4x4 ordered dither (offsets -4..+3 of 255)
		vec2 cell = ps1_snap.x > 0.0 ? floor(FRAGCOORD.xy * ps1_snap / VIEWPORT_SIZE) : floor(FRAGCOORD.xy);
		int ix = int(mod(cell.x, 4.0));
		int iy = int(mod(cell.y, 4.0));
		int m[16] = int[16](-4, 0, -3, 1, 2, -2, 3, -1, -3, 1, -4, 0, 3, -1, 2, -2);
		float d = float(m[iy * 4 + ix]);
		col = floor(clamp(col * 255.0 + d, 0.0, 255.0) / 8.0) * 8.0 / 255.0;
	}
	if (ps1_linearize > 0.5) {
		col = mix(col / 12.92, pow((col + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), col));
	}
	%s
}
""" % [mode, filt, view, sky, sky, out]
	_shaders[sk] = sh
	return sh
