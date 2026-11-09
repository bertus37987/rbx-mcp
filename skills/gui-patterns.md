# rbx skill: gui patterns

Native GuiObject UI beats image-based UI: resolution-safe, interactive, editable, no asset moderation.

## Recipe

- `rbx_build_gui {pattern, config, theme, position}` → real tree.
- Theme tokens {bg, fg, accent, font, corner, stroke} — pass THE SAME object to every pattern in a set = guaranteed consistency.
- Position via anchor presets (top_right, bottom_left, center…) + pixel offset — never raw Position offsets.
- Wrap art images with `rbx_wrap_image` (AspectRatioConstraint + optional nine-slice) inside pattern frames.
- After building: `rbx_gui_audit` → fix reported issues → screenshot via upstream `studio.screen_capture`.

## Available patterns

panel, healthbar, inventory_grid, dialog, toast, button_row, stat_label, shop_card, menu_list, progress, tabbed_panel, hud_stack.

## Anti-patterns the audit catches

- UDim2 offsets ≠ 0 (dies on mobile/tv resolutions)
- ImageLabel stretched without AspectRatioConstraint
- TextScaled=false below ~28px absolute height
- Mixed corner radii across sibling frames
