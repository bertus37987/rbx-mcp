-- rbx-mcp builder: curtain_wall — crenellated wall + walkway + corner turret at +X end
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
MODEL.Name = cfg.name or "CurtainWall"
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
local function drum(len, d, x, y, z, c, name)
	return P{ Name = name, Shape = Enum.PartType.Cylinder, Size = Vector3.new(len, d, d), CFrame = cf(x, y, z) * CFrame.Angles(0, 0, math.rad(90)), BrickColor = bc(c) }
end

local len, h = cfg.len or 64, cfg.h or 24
local th = cfg.thick or 6
local tr = cfg.turret_r or 6
local col = cfg.color or "Ghost grey"
local trim = cfg.trim or "White"
local dark = cfg.dark or "Slate"

P{ Name = "Wall", Size = Vector3.new(len, h, th), CFrame = cf(0, h / 2, 0), BrickColor = bc(col) }
P{ Name = "Walkway", Size = Vector3.new(len, 1, th + 5), CFrame = cf(0, h + 0.5, 1.5), BrickColor = bc(trim) }

local mw, gap = 2.5, 5
local cnt = math.floor((len - 4) / gap)
for i = 0, cnt - 1 do
	P{ Name = "Merlon" .. i, Size = Vector3.new(mw, 2.5, 1.5), CFrame = cf(-len / 2 + 3 + i * gap, h + 1.25, -th / 2 + 0.75), BrickColor = bc(i % 2 == 0 and col or dark) }
end

-- corner turret at the +X end: taller drum + cap disc + mini merlon ring
local turH = h + 8
local tx = len / 2 + 1
drum(turH, tr * 2, tx, turH / 2, 0, col, "Turret")
drum(1.4, tr * 2 + 2, tx, turH + 0.7, 0, trim, "TurretCap")
for k = 0, 5 do
	local a = k * math.pi / 3
	P{ Name = "TMerlon" .. k, Size = Vector3.new(1.5, 1.8, 1.5), CFrame = cf(tx + math.cos(a) * tr * 0.8, turH + 1.4 + 0.9, math.sin(a) * tr * 0.8) * CFrame.Angles(0, -a, 0), BrickColor = bc(dark) }
end
-- arrow slit on the turret face
P{ Name = "TurretSlit", Size = Vector3.new(0.5, 3.5, 0.8), CFrame = cf(tx - tr - 0.1, turH * 0.55, 0), BrickColor = bc("Really black") }

return { build = "curtain_wall", model = MPATH, parts = n, created = created }
