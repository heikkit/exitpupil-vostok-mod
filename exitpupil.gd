extends Node

const DEBUG := false

const MCM_PATH          := "res://ModConfigurationMenu/Scripts/Doink Oink/MCM_Helpers.tres"
const LIKHO_CATALOG_PATH := "res://mods/likhos-weapon-handling-fixes/Scripts/ScopeCatalog.gd"
const MOD_ID   := "exitpupil"
const MOD_NAME := "ExitPupil"
const MOD_DESC := "ExitPupil — physics-based optic brightness simulation"

var gameData = preload("res://Resources/GameData.tres")
var rig: Node = null
var last_zoom := -1
var last_optic: Node3D = null
var sun_light: DirectionalLight3D = null
var moon_light: DirectionalLight3D = null
var smoothed_lum := 0.5		# exponentially smoothed ambient light level (0 = pitch dark, 1 = bright noon)
var last_printed_lum := -1.0
var current_scope_efficiency := 1.0
# current_exit_pupil is stored as a class variable (not just computed in _update_pip) so that
# _update_ambient can re-push it to the shader every physics frame. This is necessary because
# Likho's Optic.gd unconditionally replaces pip_mat.shader on the first rendered frame, which
# resets all ShaderMaterial uniforms back to their shader defaults.
var current_exit_pupil := 7.0
var intensity := 1.0		# configurable via MCM; scales the overall dimming effect (0 = off, 1 = full)
var last_aiming := false
var _likho_catalog = null	# Likho's ScopeCatalog script, loaded at startup if present

var overlay_layer: CanvasLayer = null
var overlay_rect: ColorRect = null

const PUPIL_MAX := 7.0		# maximum useful exit pupil — matches a fully dark-adapted human eye (mm)
const MAX_SUN_ENERGY := 2.0	# tune if scope is too bright/dark at noon
const MOON_SCALE := 0.08	# moon is much dimmer perceptually than sun
const LUM_ADAPT_SPEED := 0.3	# eye adaptation speed; lower = smoother but slower response

const SCOPE_DATA := {
	# Objective lens diameters (mm) — real-world optical specs, constant across vanilla/Likho.
	# Vanilla magnifications are derived from the game's hardcoded FOV values with baseFOV=60°:
	#   variable zoom 1/2/3: FOV 60°→25°→10°  →  mag 1.0×/2.4×/6.0×
	#   fixed:               FOV 15°           →  mag 4.0×
	# When Likho's ScopeCatalog is present, _get_mags() replaces these with his mag_range values.

	"Leopard": {"obj": 24.0,                  "mags": [1.0, 2.4, 6.0]},	# vanilla LPVO — Likho: Mark 8 CQBSS 1.1-8x24
	"Vudu":    {"obj": 24.0, "obj_likho": 28.0, "mags": [1.0, 2.4, 6.0]},	# vanilla: 1-6x24 — Likho: 1-10x28
	"ACOG":    {"obj": 32.0, "mags": [4.0]},			# Trijicon ACOG TA31 4x32
	"HMR":     {"obj": 24.0, "mags": [4.0]},			# Leupold HAMR 4x24
	"POSP":    {"obj": 24.0, "mags": [4.0]},			# vanilla: fixed 4x — Likho: variable 2-6x via catalog
	"PU":      {"obj": 21.0, "mags": [4.0]},			# vanilla: same FOV as ACOG — Likho: 3.5x via catalog
}

func _ready() -> void:
	_init_config()
	_load_likho_catalog()
	get_tree().node_added.connect(_on_node_added)
	_create_overlay()
	if DEBUG:
		print("[ExitPupil] mod loaded")

func _init_config() -> void:
	var template := ConfigFile.new()
	_create_config(template)

	var config_dir := "user://MCM/" + MOD_ID
	var file_path  := config_dir + "/config.ini"
	var helper = load(MCM_PATH) if ResourceLoader.exists(MCM_PATH) else null

	if not FileAccess.file_exists(file_path):
		DirAccess.open("user://").make_dir(config_dir)
		template.save(file_path)
	elif helper:
		helper.CheckConfigurationHasUpdated(MOD_ID, template, file_path)
		template.load(file_path)

	_load_config(template)

	if helper:
		helper.RegisterConfiguration(MOD_ID, MOD_NAME, config_dir, MOD_DESC, {
			"config.ini": _load_config
		})

func _load_config(config: ConfigFile) -> void:
	intensity = config.get_value("Float", "intensity", {}).get("value", 1.0)
	if DEBUG:
		print("[ExitPupil] config loaded — intensity: ", intensity)

func _create_config(config: ConfigFile) -> void:
	config.set_value("Category", "General", {"menu_pos": 0})
	config.set_value("Float", "intensity", {
		"name": "Dimming intensity",
		"tooltip": "Scales the overall brightness effect. 1.0 = full simulation, 0.0 = no dimming.",
		"default": 1.0,
		"value": 1.0,
		"menu_pos": 1,
		"category": "General",
		"minRange": 0.0,
		"maxRange": 2.0,
	})

func _load_likho_catalog() -> void:
	if ResourceLoader.exists(LIKHO_CATALOG_PATH):
		_likho_catalog = load(LIKHO_CATALOG_PATH)
	if DEBUG:
		if _likho_catalog:
			print("[ExitPupil] Likho ScopeCatalog loaded — using Likho magnification values")
		else:
			print("[ExitPupil] Likho ScopeCatalog not found — using vanilla FOV-derived magnification")

func _get_mags(file: String) -> Array:
	if _likho_catalog:
		var m: Array = _likho_catalog.get_mag_range(file)
		if not m.is_empty():
			return m
	return SCOPE_DATA[file].mags

func _get_obj(file: String) -> float:
	var data: Dictionary = SCOPE_DATA[file]
	if _likho_catalog and data.has("obj_likho"):
		return data.obj_likho
	return data.obj

func _create_overlay() -> void:
	# Full-screen overlay used to apply exit-pupil darkening in non-PIP mode (see _update_overlay).
	# MOUSE_FILTER_IGNORE is required — Control nodes intercept all input by default, even at alpha=0.
	overlay_layer = CanvasLayer.new()
	overlay_layer.layer = 10
	add_child(overlay_layer)
	overlay_rect = ColorRect.new()
	overlay_rect.color = Color(0.0, 0.0, 0.0, 0.0)
	overlay_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay_layer.add_child(overlay_rect)

func _on_node_added(node: Node) -> void:
	if node.get_script() and node.get_script().resource_path.ends_with("WeaponRig.gd"):
		if DEBUG:
			print("[ExitPupil] WeaponRig found: ", node.name)
		rig = node
	if node.name == "Planet":
		_find_lights(node)

func _find_lights(planet: Node) -> void:
	sun_light = planet.find_child("Sun", true, false).find_child("Light", true, false) as DirectionalLight3D
	moon_light = planet.find_child("Moon", true, false).find_child("Light", true, false) as DirectionalLight3D
	if DEBUG:
		if sun_light and moon_light:
			print("[ExitPupil] lights found — sun: ", sun_light.light_energy, " moon: ", moon_light.light_energy)
		else:
			print("[ExitPupil] WARNING: lights not found")

func _physics_process(delta: float) -> void:
	_update_ambient(delta)
	_update_overlay()
	if not rig or not rig.activeOptic or not rig.slotData:
		last_aiming = false
		return
	var optic: Node3D = rig.activeOptic
	var zoom: int = rig.slotData.zoom
	var aiming: bool = gameData.isAiming
	if DEBUG and aiming and not last_aiming:
		# ADS entry — dump full attachmentData so we can verify Likho 2.5.x field names
		var ad = optic.attachmentData
		print("[ExitPupil] === ADS entry ===")
		print("[ExitPupil]   optic node:  ", optic.name)
		print("[ExitPupil]   .file:       ", ad.get("file"))
		print("[ExitPupil]   .scope:      ", ad.get("scope"))
		print("[ExitPupil]   .variable:   ", ad.get("variable"))
		print("[ExitPupil]   zoom:        ", zoom)
		print("[ExitPupil]   PIP:         ", gameData.PIP)
		print("[ExitPupil]   secondaryOptic: ", gameData.get("secondaryOptic"))
		print("[ExitPupil]   smoothed_lum: ", snapped(smoothed_lum, 0.001))
		# Force re-evaluation so the pip log fires even if optic/zoom didn't change
		last_optic = null
		last_zoom  = -1
	last_aiming = aiming
	if optic == last_optic and zoom == last_zoom:
		return
	last_optic = optic
	last_zoom = zoom
	_update_pip(optic, zoom)

func _update_ambient(delta: float) -> void:
	# Re-push shader uniforms every frame. This must happen unconditionally before the sun/moon
	# gate below so that exit_pupil and ambient_lum stay correct indoors and survive Likho's
	# one-time shader swap, which resets all ShaderMaterial uniforms to shader defaults.
	if last_optic:
		var pip_mat: ShaderMaterial = last_optic.get("PIP")
		if pip_mat:
			pip_mat.set_shader_parameter("ambient_lum", smoothed_lum)
			pip_mat.set_shader_parameter("exit_pupil", current_exit_pupil)
			pip_mat.set_shader_parameter("intensity", intensity)

	# Outdoor light tracking — only available when the Planet node is loaded.
	if not sun_light or not moon_light:
		return
	var target_lum: float
	if sun_light.light_cull_mask != 0:
		target_lum = clamp(sun_light.light_energy / MAX_SUN_ENERGY, 0.0, 1.0)
	else:
		target_lum = clamp(moon_light.light_energy * MOON_SCALE, 0.0, 1.0)
	smoothed_lum = lerp(smoothed_lum, target_lum, delta * LUM_ADAPT_SPEED)
	if DEBUG and abs(smoothed_lum - last_printed_lum) > 0.02:
		var energy := sun_light.light_energy if sun_light.light_cull_mask != 0 else moon_light.light_energy
		var which := "sun" if sun_light.light_cull_mask != 0 else "moon"
		print("[ExitPupil] smoothed_lum: ", snapped(smoothed_lum, 0.001), "  (", which, " energy: ", snapped(energy, 0.01), ")")
		last_printed_lum = smoothed_lum

func _update_overlay() -> void:
	# In non-PIP mode there is no sub-viewport — the scope view is just the main camera at a
	# narrowed FOV. The shader approach does not apply, so we replicate the exit-pupil darkness
	# penalty via a full-screen CanvasLayer overlay instead.
	# base_brightness and dim are intentionally omitted here; those correct for the PIP
	# sub-viewport's fixed internal exposure and have no equivalent in non-PIP rendering.
	var is_non_pip_scope_ads: bool = (
		rig != null
		and rig.activeOptic != null
		and gameData.isAiming
		and not gameData.PIP
		and not gameData.secondaryOptic
		and (rig.activeOptic.attachmentData.scope or rig.activeOptic.attachmentData.variable)
		and SCOPE_DATA.has(rig.activeOptic.attachmentData.file)
	)
	if not is_non_pip_scope_ads:
		overlay_rect.color = Color(0.0, 0.0, 0.0, 0.0)
		return
	var darkness: float = intensity * (1.0 - smoothstep(0.0, 0.4, smoothed_lum))
	var scope_factor: float = lerp(1.0, current_scope_efficiency, darkness)
	overlay_rect.color = Color(0.0, 0.0, 0.0, 1.0 - scope_factor)

func _update_pip(optic: Node3D, zoom: int) -> void:
	var file: String = optic.attachmentData.file
	if not SCOPE_DATA.has(file):
		if DEBUG:
			print("[ExitPupil] no data for scope: ", file, " — skipping")
		return
	var pip_mat: ShaderMaterial = optic.get("PIP")
	if pip_mat == null:
		if DEBUG:
			print("[ExitPupil] PIP material is null for: ", file)
		return
	# Compute exit pupil for the current zoom level and derive scope efficiency.
	# exit_pupil = objective_diameter / magnification (mm).
	# Efficiency is the fraction of light delivered relative to a fully open 7mm pupil,
	# squared because both dimensions of the pupil area scale with diameter.
	var mags: Array = _get_mags(file)
	var mag_index := clamp(zoom - 1, 0, mags.size() - 1)
	var mag: float = mags[mag_index]
	var obj: float = _get_obj(file)
	var mag_source := "Likho" if _likho_catalog else "vanilla"
	current_exit_pupil = obj / mag
	var ep_ratio: float = current_exit_pupil / PUPIL_MAX
	current_scope_efficiency = minf(1.0, ep_ratio * ep_ratio)
	if DEBUG:
		var shader_path: String = pip_mat.shader.resource_path if pip_mat.shader else "(null)"
		var vp_tex = get_viewport().get_texture()
		print("[ExitPupil] --- zoom change ---")
		print("[ExitPupil] scope=", file, "  zoom=", zoom, "  obj=", obj, "mm  mag=", mag, "x (", mag_source, ")  EP=", snapped(current_exit_pupil, 0.1), "mm  eff=", snapped(current_scope_efficiency, 0.01))
		print("[ExitPupil] pip_mat.shader=", shader_path)
		print("[ExitPupil] pip_mat active=", pip_mat.get_shader_parameter("active"))
		print("[ExitPupil] viewport tex=", vp_tex, "  size=", get_viewport().size)
		print("[ExitPupil] sun_light=", sun_light, "  moon_light=", moon_light)
		print("[ExitPupil] smoothed_lum=", snapped(smoothed_lum, 0.001), "  gameData.PIP=", gameData.PIP)
