-- rbx-mcp builder: buttress — stepped flying buttress: pier + 2 sloped flights + pinnacle
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
MODEL.Name = cfg.name or "Buttress"
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
-- Roblox has no Cone part — SpecialMesh Pyramid is the closest built-in apex
local function pyramid(p)
	local o = P(p)
	local m = Instance.new("SpecialMesh")
	m.MeshType = Enum.MeshType.Pyramid
	m.Parent = o
	return o
end

local h, depth = cfg.h or 30, cfg.depth or 10
local th = cfg.thick or 3.5
local col = cfg.color or "Ghost grey"
local dark = cfg.dark or "Really black"

-- pier at +Z (wall sits at -Z); flights slope down toward the pier
local pierH = h * 0.5
local pierZ = depth / 2
P{ Name = "Pier", Size = Vector3.new(4, pierH, 4), CFrame = cf(0, pierH / 2, pierZ), BrickColor = bc(col) }
local pierFront = pierZ - 2

-- a flight wedge covers z in [zHi, zHi+run], high edge at the -Z (wall) side:
-- 180 deg about Y points the wedge's local -Z downslope toward +Z
local function flight(run, rise, zHi, yBase, name)
	W{ Name = name, Size = Vector3.new(th, rise, run), CFrame = cf(0, yBase + rise / 2, zHi + run / 2) * CFrame.Angles(0, math.rad(180), 0), BrickColor = bc(col) }
end

local r1, s1 = depth * 0.5, h * 0.28
local r2, s2 = depth * 0.38, h * 0.3
local y1 = pierH - 1
flight(r1, s1, pierFront - r1, y1, "Flight1")          -- z: pierFront-r1 .. pierFront
flight(r2, s2, pierFront - r1 - r2, y1 + s1, "Flight2") -- steeper upper arm

-- springer block where the upper flight meets the wall
local wallZ = pierFront - r1 - r2
P{ Name = "Springer", Size = Vector3.new(th + 1, 4, 3), CFrame = cf(0, y1 + s1 + s2 - 2, wallZ - 1.5), BrickColor = bc(col) }

-- pinnacle: drum + pyramid spire on the pier
P{ Name = "PinDrum", Shape = Enum.PartType.Cylinder, Size = Vector3.new(3, 1.8, 1.8), CFrame = cf(0, pierH + 1.5, pierZ) * CFrame.Angles(0, 0, math.rad(90)), BrickColor = bc(col) }
pyramid{ Name = "Pinnacle", Size = Vector3.new(2.6, 3.5, 2.6), CFrame = cf(0, pierH + 3 + 1.75, pierZ), BrickColor = bc(dark) }

return { build = "buttress", model = MPATH, parts = n, created = created }
