# Game Build Verification (rbx_scenario + snapshot/diff)

Stepwise game construction with an error-catching gate at every step. Adapted
from anti-slop QA gates: every build step produces evidence or it did not happen.

## The loop

1. `rbx_snapshot {label:'before'}` — freeze state.
2. Build step: `rbx_scenario {steps:[{cmd,args,expect:[...]}]}` — commands run
   in-place with assertions, `stop_on_fail` aborts on first failure.
3. `rbx_snapshot` + `rbx_diff` — prove the delta is exactly what you intended
   (no stray instances, no missed props).
4. Structural audit: `rbx_gui_audit` (UI), `rbx_security_scan` (scripts),
   `rbx_validate_asset` (meshes).
5. Visual gate: `rbx_render_thumbnail` → upstream `studio.screen_capture` when
   connected for pixels.

## Scenario step shape

```json
{"cmd":"terrain_generate","args":{"seed":7,"size":{"x":64,"y":32,"z":64}},
 "expect":[{"field":"chunks_written","eq":1},{"field":"max_height"}]}
```
expect entries: `{field:'a.b.c', eq:v}` exact, `{field:'p', contains:'x'}`
substring, `{field:'p'}` exists.

## Building a complete game — ordered pipeline

terrain → lighting → spawn/kit (`rbx_apply_kit`) → NPC rigs + armor → GUI +
sounds → scripts → scenario suite asserting every system → diff vs before →
playtest via upstream `studio.start_stop_play` + `rbx_console` error sweep.

## Failure triage

- `expect_failed` lists {field,got,want} — fix the arg, re-run single step.
- `error` = Luau exception — includes line; fix plugin-side or args.
- Stale results: `rbx_studios` freshness — always target `lastSeen < 30s`.
