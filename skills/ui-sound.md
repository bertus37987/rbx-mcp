# UI Sound Design (rbx_ui_sounds)

Non-slop UI audio: subtle, consistent, never spammy. One Folder of Sounds + one
LocalScript wires every GuiButton (current + future via DescendantAdded).

## Tool

`rbx_ui_sounds { path:'StarterGui.RbxGui', volume:0.35, sounds?{name=id} }`

Built-in map: click, hover, open, close, error, success, pop — classic Roblox
UI ids. Override any slot with your own `rbxassetid://`.

## Rules that keep it non-slop

- **Volume 0.2–0.4** for clicks/hovers; louder only for success/error events.
- **Hover must be quieter than click** (≈ half). If hover is annoying, drop it.
- **One sound per event type across the whole UI** — consistency IS the design.
- **Never loop UI sounds**, never stack >2 simultaneous, no music from buttons.
- Custom assets: upload via Creator Dashboard → `rbxassetid://<id>` → pass in
  `sounds{}` — replaces the defaults, same wiring.

## Extend the wiring

The generated `__RbxUISoundWire` LocalScript plays `click` on MouseButton1Click
and `hover` on MouseEnter. For open/close/success/error events, call
`require`-style: keep a `Sound` named per event and `Play()` it from your UI
controller at the moment the state changes (dialog open → `open`, purchase →
`success`, validation fail → `error`).
