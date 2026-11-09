-- rbx-mcp builder: colonnade — row of N columns (base+shaft+capital) + entablature beam
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
MODEL.Name = cfg.name or "Colonnade"
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

local cols = cfg.n or 6
local spacing = cfg.spacing or 10
local h = cfg.h or 20
local col = cfg.color or "White"
local trim = cfg.trim or "Ghost grey"
local dark = cfg.dark or "Slate"

local baseH, capH = 1, 1.4
local shaftH = h - baseH - capH - 0.2

for i = 1, cols do
	local x = (i - (cols + 1) / 2) * spacing
	P{ Name = "Base" .. i, Size = Vector3.new(3.6, baseH, 3.6), CFrame = cf(x, baseH / 2, 0), BrickColor = bc(dark) }
	P{ Name = "Shaft" .. i, Shape = Enum.PartType.Cylinder, Size = Vector3.new(shaftH, 2.2, 2.2), CFrame = cf(x, baseH + shaftH / 2, 0) * CFrame.Angles(0, 0, math.rad(90)), BrickColor = bc(col) }
	P{ Name = "Capital" .. i, Size = Vector3.new(4, capH, 4), CFrame = cf(x, baseH + shaftH + capH / 2, 0), BrickColor = bc(trim) }
end

-- entablature: beam + thin cornice slab spanning the row
local total = (cols - 1) * spacing
P{ Name = "Entablature", Size = Vector3.new(total + 6, 2, 4.5), CFrame = cf(0, h + 0.8, 0), BrickColor = bc(col) }
P{ Name = "Cornice", Size = Vector3.new(total + 7.5, 0.8, 5.5), CFrame = cf(0, h + 2.2, 0), BrickColor = bc(trim) }

return { build = "colonnade", model = MPATH, parts = n, created = created }
