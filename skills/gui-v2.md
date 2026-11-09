# GUI v2 — interactive, animated, non-slop

Native GuiObjects (not images): resolution-safe scale UDim2, UICorner/
UIStroke/UIPadding theme tokens, AnchorPoint-correct.

## Patterns (rbx_build_gui)

Base: panel, healthbar, inventory_grid, dialog, toast, button_row,
stat_label, shop_card, menu_list, progress, tabbed_panel, hud_stack.

v2 adds interactive composites:
- `slider` — track+knob+fill, IsOn/value wiring via LocalScript
- `toggle` — pill switch with animated knob, `IsOn` BoolValue
- `dropdown` — header + scrolling item list
- `radial_menu` — arc button fan
- `tabs_bar` — tab buttons + content pages
- `keybind_hint` — keycap + action rows
- `loading_screen` — overlay + progress + rotating tips
- `minimap_frame` — circular viewport container (UICorner=1)
- `game_hud` — composite: health+stamina+minimap+hotbar in one call

## Behaviors — `rbx_gui_component`

Attach a LocalScript behavior to ANY GuiObject:
`draggable`, `hover_fx` (scale+lift), `click_scale` (press squash).
Stack multiple — scripts are named `RbxFx_<behavior>` (re-call replaces).

## Animation — `rbx_gui_animate`

`slide_in` (direction), `fade`, `bounce`, `pulse` (looping). Implemented as
LocalScript (edit-mode tweens don't tick — the script plays on run).

## Anti-slop rules

- Volume of UI sounds ≤0.4 (`rbx_ui_sounds` default 0.35)
- One theme token set across ALL patterns — consistency beats novelty
- Scale UDim2, never offset pixels (`rbx_gui_audit` flags violations)
- Interactivity lives in LocalScripts — server Scripts never touch GUI
