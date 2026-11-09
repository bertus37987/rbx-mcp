# rbx skill: verification loop

The discipline that makes agent-built Roblox work trustworthy.

## The loop

1. `rbx_studios` → pick studio_id
2. `rbx_checkpoint {label: "before-X"}` — undo anchor
3. `rbx_snapshot {label: "before-X"}` — structural baseline
4. mutate (rbx_write_script / rbx_build_gui / rbx_fit_accessory / rbx_apply_kit / rbx_run_luau)
5. `rbx_snapshot {label: "after-X"}` → `rbx_diff {a, b}` — prove the delta
6. Visual proof: `rbx_render_thumbnail` → `studio.screen_capture` (upstream) for 3D/UI; `rbx_console` for errors
7. Failures → `rbx_undo` + re-attempt with the error as context

## Rules

- Never claim a GUI works without rbx_gui_audit + a screenshot.
- Never insert third-party assets without rbx_security_scan.
- Never equip armor without rbx_validate_asset on the item first.
- Long DataModel writes MUST chunk + task.wait() (run_luau description has the rules).
- rbx_write_script(expected_hash) guards against clobbering concurrent edits.
