-- rbx-mcp builder: stair_flight — N solid steps rising along +Z + side stringers
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
MODEL.Name = cfg.name or "StairFlight"
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

local steps = cfg.steps or 8
local sh = cfg.step_h or 1
local sd = cfg.step_d or 2
local w = cfg.w or 10
local col = cfg.color or "Slate"
local trim = cfg.trim or "Ghost grey"

-- solid steps (each a full-height box, tread at i*step_h)
for i = 1, steps do
	P{ Name = "Step" .. i, Size = Vector3.new(w, i * sh, sd), CFrame = cf(0, i * sh / 2, (i - 0.5) * sd), BrickColor = bc(i % 2 == 0 and trim or col) }
end

-- sloped side stringers following the top diagonal
local run, rise = steps * sd, steps * sh
local L = math.sqrt(run * run + rise * rise)
local ang = math.deg(math.atan2(rise, run))
for _, sx in ipairs({ -1, 1 }) do
	P{ Name = "Stringer", Size = Vector3.new(1, 1.4, L + 2), CFrame = cf(sx * (w / 2 + 0.2), rise / 2 + 0.3, run / 2) * CFrame.Angles(math.rad(-ang), 0, 0), BrickColor = bc(trim) }
end

return { build = "stair_flight", model = MPATH, parts = n, created = created }
