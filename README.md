# ExitPupil

A [Road to Vostok](https://store.steampowered.com/app/1937470/Road_to_Vostok/) mod that simulates physics-based optic brightness using real-world exit pupil mechanics.

Available on [ModWorkshop](https://modworkshop.net/mod/56890).

Developed with [Claude](https://claude.ai).

---

## How it works

The **exit pupil** of a scope is the diameter of the light cone that exits the eyepiece:

```
exit_pupil = objective_diameter / magnification   (mm)
```

A fully dark-adapted human eye has a maximum pupil diameter of ~7 mm. If the scope's exit pupil is smaller than 7 mm, not all available light enters the eye — the image dims. The efficiency is quadratic because both dimensions of the pupil area scale with diameter:

```
scope_efficiency = clamp((exit_pupil / 7.0)², 0, 1)
```

This is computed per scope, per zoom level, every time you change magnification. The result drives a shader uniform on the scope's PIP (picture-in-picture) sub-viewport material, and a full-screen overlay for non-PIP rendering.

Ambient light level (sun/moon energy, smoothed over time to simulate eye adaptation) is tracked separately and modulates both the exit pupil effect and an outdoor brightness compensation curve that prevents the PIP image from appearing blown out in daylight.

---

## Scope data

Real-world objective lens diameters are used to compute exit pupils. Magnification values depend on whether [Likho's VosTac](#likhos-vostac-compatibility) is installed.

| Scope | Objective | Vanilla mags | Likho mags |
|---|---|---|---|
| Leupold Mark 8 CQBSS (Leopard) | 24 mm | 1.0×, 2.4×, 6.0× | 1.1×, 3.0×, 8.0× |
| EOTech Vudu 1-10x (Vudu) | **28 mm** | 1.0×, 2.4×, 6.0× | 1.0×, 3.2×, 10.0× |
| Trijicon ACOG TA31 | 32 mm | 4.0× | 4.0× |
| Leupold HAMR 4× | 24 mm | 4.0× | 4.0× |
| POSP 2-6× | 24 mm | 4.0× (fixed) | 2.0×, 3.5×, 6.0× |
| Soviet PU 3.5× | 21 mm | 4.0× | 3.5× |

Vanilla magnifications are derived from the game's hardcoded ADS FOV values (`baseFOV=60° / aimFOV`), not guessed from real-world scope markings. The Vudu uses a different objective diameter under Likho because his mod models the 1-10×28 variant rather than the vanilla 1-6×24.

---

## Likho's VosTac compatibility

If [Likho's VosTac](https://modworkshop.net/mod/56366) is installed, ExitPupil loads his `ScopeCatalog.gd` at startup and reads `mag_range` directly from it — no hardcoded values, no coordination required. This means:

- Magnification values are always in sync with whatever Likho ships
- Any number of discrete zoom steps is supported automatically; the zoom index is looked up with a clamped array index into `mag_range`, so adding more steps to a scope requires no changes to ExitPupil
- Likho's magnification schema MCM setting (Discrete / Normalized / Short) is respected, since `get_mag_range()` is called live on each zoom change

If Likho's mod is not installed, ExitPupil falls back to the vanilla FOV-derived magnification table above and works fully standalone.

---

## PIP shader

`Shaders/PIP.gdshader` replaces the vanilla PIP scope shader. It handles:

- **Exit pupil dimming** — `scope_efficiency` applied as a multiplier, blended by darkness level so it only penalises in genuinely dim conditions
- **Outdoor brightness compensation** — a `smoothstep` curve that dims the PIP image as ambient light rises, preventing the sub-viewport from looking blown out against the surroundings in daylight
- **Depth-of-field blur** — a 3×3 box kernel, driven by `blur_radius` which Likho's WeaponRig sets at higher zoom levels
- **Optical transmission baseline** — a `base_brightness` factor (0.73) representing real glass transmission loss

Declaring `blur_radius` as a uniform also serves as the compatibility signal that prevents Likho's `Optic.gd` from swapping in its own `PIP_NVG.gdshader`, since it checks for that property before deciding whether to replace the material.

---

## MCM support

An intensity slider (0.0–2.0) is exposed via [Mod Configuration Menu](https://modworkshop.net/mod/53713) if installed. At 0.0 the effect is disabled entirely; at 1.0 it runs at full simulation strength; values above 1.0 exaggerate the effect beyond physical accuracy.

---

## Installation

Drop `exitpupil.vmz` into your Road to Vostok `mods/` folder. The mod self-updates via ModWorkshop when a new version is available.

To build from source, run `deploy.ps1` (not included in the repository — edit paths for your machine from the template in the session notes).
