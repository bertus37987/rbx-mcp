-- rbx-mcp builder: courtyard — marble paved floor + fountain + corner planters
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
MODEL.Name = cfg.name or "Courtyard"
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
local function drum(len, d, x, y, z, c, name, mat)
	return P{ Name = name, Shape = Enum.PartType.Cylinder, Size = Vector3.new(len, d, d), CFrame = cf(x, y, z) * CFrame.Angles(0, 0, math.rad(90)), BrickColor = bc(c), Material = mat or Enum.Material.SmoothPlastic }
end

local w, d = cfg.w or 40, cfg.d or 40
local col = cfg.color or "White"
local trim = cfg.trim or "Slate"
local water = cfg.water or "Bright blue"
local green = cfg.shrub or "Bright green"

-- paved floor: marble base + raised border insets
P{ Name = "Paving", Size = Vector3.new(w, 0.6, d), CFrame = cf(0, 0.3, 0), BrickColor = bc(col), Material = Enum.Material.Marble }
P{ Name = "BorderN", Size = Vector3.new(w - 4, 0.25, 2), CFrame = cf(0, 0.72, -d / 2 + 2.5), BrickColor = bc(trim), Material = Enum.Material.Marble }
P{ Name = "BorderS", Size = Vector3.new(w - 4, 0.25, 2), CFrame = cf(0, 0.72, d / 2 - 2.5), BrickColor = bc(trim), Material = Enum.Material.Marble }
P{ Name = "BorderE", Size = Vector3.new(2, 0.25, d - 8), CFrame = cf(w / 2 - 2.5, 0.72, 0), BrickColor = bc(trim), Material = Enum.Material.Marble }
P{ Name = "BorderW", Size = Vector3.new(2, 0.25, d - 8), CFrame = cf(-(w / 2 - 2.5), 0.72, 0), BrickColor = bc(trim), Material = Enum.Material.Marble }

-- center fountain: basin + water disc + column + top bowl
drum(2, 10, 0, 1.6, 0, trim, "Basin")
drum(0.35, 8.2, 0, 2.45, 0, water, "Water", Enum.Material.Glass).Transparency = 0.3
drum(4.2, 1.6, 0, 2.7, 0, col, "Column")
drum(0.7, 4.4, 0, 4.95, 0, trim, "Bowl")
drum(0.2, 3.6, 0, 5.35, 0, water, "BowlWater", Enum.Material.Glass).Transparency = 0.3

-- corner planters: slate box + green shrub ball
for _, sx in ipairs({ -1, 1 }) do
	for _, sz in ipairs({ -1, 1 }) do
		local px, pz = sx * (w / 2 - 4), sz * (d / 2 - 4)
		P{ Name = "Planter", Size = Vector3.new(5, 1.6, 5), CFrame = cf(px, 1.4, pz), BrickColor = bc(trim) }
		P{ Name = "Shrub", Shape = Enum.PartType.Ball, Size = Vector3.new(3.4, 3.4, 3.4), CFrame = cf(px, 3.4, pz), BrickColor = bc(green) }
	end
end

return { build = "courtyard", model = MPATH, parts = n, created = created }
