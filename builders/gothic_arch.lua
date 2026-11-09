-- rbx-mcp builder: gothic_arch — freestanding pointed arch on two columns
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
MODEL.Name = cfg.name or "GothicArch"
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
local function W(p)
	local o = Instance.new("WedgePart")
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

local span, h = cfg.span or 16, cfg.h or 24
local thick = cfg.thick or 3
local col = cfg.color or "Ghost grey"
local trim = cfg.trim or "White"

local baseH, capH = 1.5, 1.2
local shaftH = h * 0.6
local springY = baseH + shaftH + capH
local peak = math.max(1, math.min(span * 0.5, h - springY)) -- keep apex at/below h

for _, sx in ipairs({ -1, 1 }) do
	local x = sx * span / 2
	P{ Name = "ColBase", Size = Vector3.new(4, baseH, 4), CFrame = cf(x, baseH / 2, 0), BrickColor = bc(trim) }
	P{ Name = "ColShaft", Shape = Enum.PartType.Cylinder, Size = Vector3.new(shaftH, 2.6, 2.6), CFrame = cf(x, baseH + shaftH / 2, 0) * CFrame.Angles(0, 0, math.rad(90)), BrickColor = bc(col) }
	P{ Name = "ColCap", Size = Vector3.new(4.4, capH, 4.4), CFrame = cf(x, baseH + shaftH + capH / 2, 0), BrickColor = bc(trim) }
end

-- arch top: two wedges leaning into the point (downslope faces outward)
local run = span / 2 + 2 -- slight overhang past column centres
W{ Name = "ArchL", Size = Vector3.new(thick, peak, run), CFrame = cf(-run / 2, springY + peak / 2, 0) * CFrame.Angles(0, math.rad(90), 0), BrickColor = bc(col) }
W{ Name = "ArchR", Size = Vector3.new(thick, peak, run), CFrame = cf(run / 2, springY + peak / 2, 0) * CFrame.Angles(0, math.rad(-90), 0), BrickColor = bc(col) }
P{ Name = "Keystone", Size = Vector3.new(1.6, 2, thick + 0.6), CFrame = cf(0, springY + peak - 0.8, 0), BrickColor = bc(trim) }

return { build = "gothic_arch", model = MPATH, parts = n, created = created }
