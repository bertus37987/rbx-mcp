-- rbx-mcp builder: keep — 2 stacked boxes + corner pilasters + crenellated top + door inset
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
MODEL.Name = cfg.name or "Keep"
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

local w, h = cfg.w or 40, cfg.h or 44
local d = cfg.d or (w * 0.9)
local col = cfg.color or "Ghost grey"
local trim = cfg.trim or "Slate"
local dark = cfg.dark or "Really black"

local lowH = h * 0.55
P{ Name = "Lower", Size = Vector3.new(w, lowH, d), CFrame = cf(0, lowH / 2, 0), BrickColor = bc(col) }
local uw, ud = w * 0.8, d * 0.8
P{ Name = "Upper", Size = Vector3.new(uw, h - lowH, ud), CFrame = cf(0, lowH + (h - lowH) / 2, 0), BrickColor = bc(col) }

-- corner pilaster strips on the lower box (proud of both faces)
for _, sx in ipairs({ -1, 1 }) do
	for _, sz in ipairs({ -1, 1 }) do
		P{ Name = "Pilaster", Size = Vector3.new(3.5, lowH + 0.5, 3.5), CFrame = cf(sx * (w / 2 - 0.8), (lowH + 0.5) / 2, sz * (d / 2 - 0.8)), BrickColor = bc(trim) }
	end
end

-- crenellated top: merlons around the upper box perimeter
local topY = h
local idx = 0
local function merlon(x, z, sxz)
	P{ Name = "Merlon" .. idx, Size = sxz, CFrame = cf(x, topY + 1.1, z), BrickColor = bc(idx % 2 == 0 and col or trim) }
	idx += 1
end
for x = -uw / 2 + 2, uw / 2 - 2, 5 do
	merlon(x, -ud / 2 + 0.75, Vector3.new(2.5, 2.2, 1.5))
	merlon(x, ud / 2 - 0.75, Vector3.new(2.5, 2.2, 1.5))
end
for z = -ud / 2 + 4.5, ud / 2 - 4.5, 5 do
	merlon(-uw / 2 + 0.75, z, Vector3.new(1.5, 2.2, 2.5))
	merlon(uw / 2 - 0.75, z, Vector3.new(1.5, 2.2, 2.5))
end

-- door arch inset on the front (-Z) face: dark opening + pointed wedge cap
local fz = -d / 2
P{ Name = "DoorFrame", Size = Vector3.new(7, 9.5, 0.5), CFrame = cf(0, 4.75, fz - 0.1), BrickColor = bc(trim) }
P{ Name = "DoorPanel", Size = Vector3.new(5.5, 7.5, 0.5), CFrame = cf(0, 3.75, fz - 0.3), BrickColor = bc(dark) }
local function doorPeak(size, rise, base, z, c, name)
	local run = size / 2
	W{ Name = name .. "L", Size = Vector3.new(0.5, rise, run), CFrame = cf(-run / 2, base + rise / 2, z) * CFrame.Angles(0, math.rad(90), 0), BrickColor = bc(c) }
	W{ Name = name .. "R", Size = Vector3.new(0.5, rise, run), CFrame = cf(run / 2, base + rise / 2, z) * CFrame.Angles(0, math.rad(-90), 0), BrickColor = bc(c) }
end
doorPeak(7, 2, 7.5, fz - 0.1, trim, "DoorFramePeak")
doorPeak(5.5, 1.6, 7.5, fz - 0.3, dark, "DoorPeak")

return { build = "keep", model = MPATH, parts = n, created = created }
