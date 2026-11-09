-- rbx-mcp builder: gothic_wall — wall segment + top trim + pointed-arch cutout illusion
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
MODEL.Name = cfg.name or "GothicWall"
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

local w, h, th = cfg.w or 24, cfg.h or 28, cfg.thick or 4
local col = cfg.color or "Ghost grey"
local trim = cfg.trim or "White"
local dark = cfg.dark or "Really black"
local panel = cfg.panel or "Slate"

P{ Name = "Wall", Size = Vector3.new(w, h, th), CFrame = cf(0, h / 2, 0), BrickColor = bc(col) }
P{ Name = "TopTrim", Size = Vector3.new(w + 1.5, 1.5, th + 1.5), CFrame = cf(0, h - 0.75, 0), BrickColor = bc(trim) }

-- pointed-arch cutout illusion on the -Z face: layered dark insets
local aw = w * 0.45   -- arch width
local ah = h * 0.42   -- rectangular panel height
local peak = w * 0.22 -- rise of the point
local fz = -th / 2    -- front face plane

P{ Name = "ArchFrame", Size = Vector3.new(aw + 2, ah + 2, 0.5), CFrame = cf(0, (ah + 2) / 2, fz - 0.05), BrickColor = bc(dark) }
P{ Name = "ArchPanel", Size = Vector3.new(aw, ah, 0.5), CFrame = cf(0, ah / 2, fz - 0.35), BrickColor = bc(panel) }

-- pointed caps: black frame wedges behind slightly smaller panel wedges.
-- WedgePart slopes down toward local -Z; rotating +/-90 deg about Y lays the
-- run along X with the high edge meeting at the arch centre.
local function peakPair(size, rise, base, z, depth, c, name)
	local run = size / 2
	W{ Name = name .. "L", Size = Vector3.new(depth, rise, run), CFrame = cf(-run / 2, base + rise / 2, z) * CFrame.Angles(0, math.rad(90), 0), BrickColor = bc(c) }
	W{ Name = name .. "R", Size = Vector3.new(depth, rise, run), CFrame = cf(run / 2, base + rise / 2, z) * CFrame.Angles(0, math.rad(-90), 0), BrickColor = bc(c) }
end
peakPair(aw + 2, peak + 1, ah - 1, fz - 0.05, 0.5, dark, "FramePeak")
peakPair(aw, peak, ah, fz - 0.35, 0.5, panel, "PanelPeak")

return { build = "gothic_wall", model = MPATH, parts = n, created = created }
