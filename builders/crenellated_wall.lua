-- rbx-mcp builder: crenellated_wall — curtain wall segment + walkway + alternating merlons
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
MODEL.Name = cfg.name or "CrenellatedWall"
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

local len, h = cfg.len or 48, cfg.h or 18
local th = cfg.thick or 5
local walk = cfg.walk; if walk == nil then walk = true end
local col = cfg.color or "Ghost grey"
local trim = cfg.trim or "White"
local dark = cfg.dark or "Slate"

-- wall runs along X, front face at -Z
P{ Name = "Wall", Size = Vector3.new(len, h, th), CFrame = cf(0, h / 2, 0), BrickColor = bc(col) }

if walk then
	P{ Name = "Walkway", Size = Vector3.new(len, 1, th + 5), CFrame = cf(0, h + 0.5, 1.5), BrickColor = bc(trim) }
	P{ Name = "RearCurb", Size = Vector3.new(len, 1.2, 0.8), CFrame = cf(0, h + 1.6, th / 2 + 3.4), BrickColor = bc(dark) }
end

-- alternating merlons on the front top edge
local mw, gap = 2.5, 5
local cnt = math.floor((len - 4) / gap)
for i = 0, cnt - 1 do
	P{ Name = "Merlon" .. i, Size = Vector3.new(mw, 2.5, 1.5), CFrame = cf(-len / 2 + 3 + i * gap, h + 1.25, -th / 2 + 0.75), BrickColor = bc(i % 2 == 0 and col or dark) }
end

return { build = "crenellated_wall", model = MPATH, parts = n, created = created }
