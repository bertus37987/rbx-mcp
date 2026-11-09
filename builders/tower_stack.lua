-- rbx-mcp builder: tower_stack — 3 shrinking drums + crenellated crown + arrow-slit insets
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
MODEL.Name = cfg.name or "TowerStack"
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
local function drum(len, d, y, c, name)
	return P{ Name = name, Shape = Enum.PartType.Cylinder, Size = Vector3.new(len, d, d), CFrame = cf(0, y, 0) * CFrame.Angles(0, 0, math.rad(90)), BrickColor = bc(c) }
end

local h, r = cfg.h or 60, cfg.r or 12
local col = cfg.color or "Ghost grey"
local trim = cfg.trim or "Slate"
local dark = cfg.dark or "Really black"

local fracs = { 0.45, 0.32, 0.23 }
local radii = { r, r * 0.85, r * 0.7 }
local mids = {} -- mid-height of upper drums (for arrow slits)

local y = 0
for i = 1, 3 do
	local len = h * fracs[i]
	drum(len, radii[i] * 2, y + len / 2, col, "Drum" .. i)
	mids[i] = y + len / 2
	if i < 3 then
		drum(1.2, radii[i] * 2.12, y + len + 0.6, trim, "Band" .. i)
		y += len + 1.2
	else
		y += len
	end
end

-- arrow-slit insets: thin dark parts flush on the two upper drums
for i = 2, 3 do
	local rad = radii[i]
	local sy = mids[i]
	P{ Name = "SlitPX" .. i, Size = Vector3.new(0.4, 3.5, 0.9), CFrame = cf(rad - 0.05, sy, 0), BrickColor = bc(dark) }
	P{ Name = "SlitNX" .. i, Size = Vector3.new(0.4, 3.5, 0.9), CFrame = cf(-(rad - 0.05), sy, 0), BrickColor = bc(dark) }
	P{ Name = "SlitPZ" .. i, Size = Vector3.new(0.9, 3.5, 0.4), CFrame = cf(0, sy, rad - 0.05), BrickColor = bc(dark) }
	P{ Name = "SlitNZ" .. i, Size = Vector3.new(0.9, 3.5, 0.4), CFrame = cf(0, sy, -(rad - 0.05)), BrickColor = bc(dark) }
end

-- crenellated crown: cap disc + merlon ring on the rim
local r3 = radii[3]
drum(1.2, r3 * 2.3, y + 0.6, trim, "Crown")
for k = 0, 7 do
	local a = k * math.pi / 4
	P{ Name = "Merlon" .. k, Size = Vector3.new(1.8, 2, 1.8), CFrame = cf(math.cos(a) * r3 * 0.85, y + 1.2 + 1, math.sin(a) * r3 * 0.85) * CFrame.Angles(0, -a, 0), BrickColor = bc(k % 2 == 0 and col or trim) }
end

return { build = "tower_stack", model = MPATH, parts = n, created = created }
