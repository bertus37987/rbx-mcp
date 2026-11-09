# Roblox Lighting & Atmosphere (rbx_lighting)

Anti-flat lighting for Roblox scenes. Goal: a scene that reads depth, time and
mood — not default-grey Studio light.

## Tool

`rbx_lighting { preset?, time_of_day?, technology?, props?, atmosphere?, sky?, effects? }`
Everything is undoable (one waypoint). Presets are starting points — adjust after.

## The recipe that stops "flat"

1. **Time + sun first.** `time_of_day` drives sun angle. Dawn/sunset give long
   shadows and warm light — noon gives boring top light (use for clarity tests).
2. **Atmosphere is the depth cue.** `atmosphere:{Density,Haze,Color,Offset}`
   — Haze>2 pushes distance into fog. No haze = everything pops same-distance.
3. **One post effect, not five.** SunRays for dawn/dusk shafts, Bloom only where
   emissives exist (night/neon), ColorCorrection Saturation ±0.1 max, TintColor
   subtle. DepthOfField only for showcase shots, never gameplay.
4. **Ambient separates zones.** `OutdoorAmbient` cool (night 25,30,55) vs warm
   interior lights → players read inside vs outside instantly.
5. **Technology:** `Future` for real games (per-pixel lights + shadows),
   `ShadowMap` for perf-constrained, `Voxel`/`Compatibility` only legacy.

## Presets (rbx_lighting preset=)

dawn | sunset | night | noon | storm | overcast — each bundles ClockTime +
atmosphere + fog + ambient + post. Override pieces after applying.

## Verification loop

`rbx_lighting` → `rbx_render_thumbnail` (or upstream `studio.screen_capture`) →
check: silhouettes readable at distance? sky/fog color coherent? bloom clipping?
Then adjust one knob — never re-randomize everything.

## Pair with terrain

Mountains generated with ridge>0.4 + `preset:'dawn'` or `'storm'` reads
dramatically better — long shadows expose the ridges.
