-- rbx-mcp builder: spire — stacked shrinking cylinders + pyramid tip + orb finial
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
MODEL.Name = cfg.name or "Spire"
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
-- vertical-shaft cylinder: Part cylinders lie on X; rotate +90 deg about Z
local function drum(len, d, y, c, name)
	return P{ Name = name, Shape = Enum.PartType.Cylinder, Size = Vector3.new(len, d, d), CFrame = cf(0, y, 0) * CFrame.Angles(0, 0, math.rad(90)), BrickColor = bc(c) }
end
local function pyramid(p)
	local o = P(p)
	local m = Instance.new("SpecialMesh")
	m.MeshType = Enum.MeshType.Pyramid
	m.Parent = o
	return o
end

local h, r = cfg.h or 50, cfg.r or 10
local col = cfg.color or "White"
local trim = cfg.trim or "Ghost grey"
local dark = cfg.accent or "Really black"

local fracs = { 0.32, 0.26, 0.24, 0.18 } -- segment height share of the shaft
local radii = { r, r * 0.8, r * 0.62, r * 0.46 }
local shaft = h * 0.8

local y = 0
local lastR = r
for i = 1, 4 do
	local len = shaft * fracs[i]
	local rad = radii[i]
	drum(len, rad * 2, y + len / 2, i % 2 == 1 and col or trim, "Seg" .. i)
	if i < 4 then
		drum(1, rad * 2.2, y + len + 0.5, trim, "Ring" .. i)
		y += len + 1
	else
		y += len
	end
	lastR = rad
end

local tipH = h * 0.16
pyramid{ Name = "Tip", Size = Vector3.new(lastR * 1.7, tipH, lastR * 1.7), CFrame = cf(0, y + tipH / 2, 0), BrickColor = bc(dark) }
P{ Name = "Orb", Shape = Enum.PartType.Ball, Size = Vector3.new(lastR * 0.9, lastR * 0.9, lastR * 0.9), CFrame = cf(0, y + tipH + lastR * 0.4, 0), BrickColor = bc(trim) }

return { build = "spire", model = MPATH, parts = n, created = created }
