-- rbx-mcp builder: interior_shell — floor + 4 thick walls + ceiling + window-glass insets
-- Server prepends: local BUILD_CONFIG = {...} (or KIT_CONFIG); local PARENT_PATH = "..."
local cfg = BUILD_CONFIG or KIT_CONFIG or {}
local created = {}

local function resolve()
	local r = game:GetService("Workspace")
	for n in string.gmatch(PARENT_PATH or "Workspace", "[^%.]+") do
		r = n == "Workspace" and r or (r:FindFirstChild(n) or error("path " .. tostring(PARENT_PATH) .. " not found"))
	end
	return r
end
local ROOT = resolve()
local BASE = (PARENT_PATH == nil or PARENT_PATH == "") and "Workspace" or PARENT_PATH

local MODEL = Instance.new("Model")
MODEL.Name = cfg.name or "InteriorShell"
MODEL.Parent = ROOT
local MPATH = BASE .. "." .. MODEL.Name
table.insert(created, MPATH)

local OFF = Vector3.new()
if type(cfg.origin) == "table" then
	OFF = Vector3.new(cfg.origin.x or cfg.origin[1] or 0, cfg.origin.y or cfg.origin[2] or 0, cfg.origin.z or cfg.origin[3] or 0)
elseif typeof(cfg.origin) == "Vector3" then OFF = cfg.origin end

local n = 0
local function P(p)
	local o = Instance.new("Part")
	o.Anchored = true
	o.Material = Enum.Material.SmoothPlastic
	o.TopSurface = Enum.SurfaceType.Smooth
	o.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in pairs(p) do pcall(function() o[k] = v end) end
	o.Parent = MODEL
	n += 1
	return o
end
local function bc(c) return BrickColor.new(c) end
local function cf(x, y, z) return CFrame.new(OFF.X + x, OFF.Y + y, OFF.Z + z) end

local w, d, h = cfg.w or 30, cfg.d or 24, cfg.h or 12
local wins = cfg.windows or 2
local t = math.max(cfg.thick or 3, 2.5) -- realistic-lighting rule: walls >= 2.5 studs
local col = cfg.color or "Slate"
local trim = cfg.trim or "Ghost grey"
local glass = cfg.glass or "Really black"

P{ Name = "Floor", Size = Vector3.new(w, 1, d), CFrame = cf(0, 0.5, 0), BrickColor = bc(trim) }
P{ Name = "WallN", Size = Vector3.new(w, h, t), CFrame = cf(0, 1 + h / 2, -d / 2 + t / 2), BrickColor = bc(col) }
P{ Name = "WallS", Size = Vector3.new(w, h, t), CFrame = cf(0, 1 + h / 2, d / 2 - t / 2), BrickColor = bc(col) }
P{ Name = "WallE", Size = Vector3.new(t, h, d - 2 * t), CFrame = cf(w / 2 - t / 2, 1 + h / 2, 0), BrickColor = bc(col) }
P{ Name = "WallW", Size = Vector3.new(t, h, d - 2 * t), CFrame = cf(-(w / 2 - t / 2), 1 + h / 2, 0), BrickColor = bc(col) }
P{ Name = "Ceiling", Size = Vector3.new(w, 1, d), CFrame = cf(0, 1 + h + 0.5, 0), BrickColor = bc(col) }

-- window cutout illusion: dark glass insets flush on the front (-Z) outer face
local spacing = (w - 2 * t) / (wins + 1)
for i = 1, wins do
	P{
		Name = "Window" .. i,
		Size = Vector3.new(3.5, 4.5, 0.5),
		CFrame = cf(-w / 2 + t + spacing * i, 1 + h * 0.55, -d / 2 + 0.3),
		BrickColor = bc(glass), Material = Enum.Material.Glass, Transparency = 0.25,
	}
end

return { build = "interior_shell", model = MPATH, parts = n, created = created }
