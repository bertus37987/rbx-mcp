-- rbx-mcp kit: world — day/night cycle + atmosphere lerps + weather machine + ambient zones
-- Server prepends: local KIT_CONFIG = {...}; local PARENT_PATH = "..."
local cfg = KIT_CONFIG or BUILD_CONFIG or {}
local created = {}

local function mk(class, props, parent)
	local i = Instance.new(class)
	for k, v in pairs(props or {}) do pcall(function() i[k] = v end) end
	i.Parent = parent
	return i
end

local function sub(src, t)
	return (src:gsub("@([%w_]+)@", function(k) return t[k] end))
end

local RESERVED = { ["if"]=true, ["goto"]=true, ["end"]=true, ["local"]=true, ["function"]=true,
	["then"]=true, ["else"]=true, ["elseif"]=true, ["while"]=true, ["do"]=true, ["for"]=true,
	["in"]=true, ["repeat"]=true, ["until"]=true, ["return"]=true, ["break"]=true, ["and"]=true,
	["or"]=true, ["not"]=true, ["true"]=true, ["false"]=true, ["nil"]=true, ["continue"]=true }
local function lit(v)
	local t = type(v)
	if t == "string" then return string.format("%q", v) end
	if t == "number" or t == "boolean" then return tostring(v) end
	if t ~= "table" then return "nil" end
	if type(v.x) == "number" and type(v.y) == "number" and type(v.z) == "number" then
		return string.format("Vector3.new(%g,%g,%g)", v.x, v.y, v.z)
	end
	local parts = {}
	for i = 1, #v do parts[i] = lit(v[i]) end -- array part first, in order
	local named = {}
	for k, val in pairs(v) do
		if type(k) ~= "number" then
			local key = (type(k) == "string" and k:match("^[A-Za-z_][%w_]*$") and not RESERVED[k])
				and (k .. " = ") or ("[" .. lit(k) .. "] = ")
			table.insert(named, key .. lit(val))
		end
	end
	for _, s in ipairs(named) do table.insert(parts, s) end
	return "{" .. table.concat(parts, ", ") .. "}"
end
local function vec3(t)
	t = t or {}
	return string.format("Vector3.new(%g,%g,%g)", t.x or t[1] or 0, t.y or t[2] or 0, t.z or t[3] or 0)
end

mk("Script", { Name = "RbxWorld", Source = sub([=[
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local CYCLE_MIN = @CYCLE@
local CLIMATE = "@CLIMATE@"
local ZONES = @ZONES@
local RAIN_ID = "@RAIN@"
local SNOW_ID = "@SNOW@"
local CENTER = @CENTER@

local atmo = Lighting:FindFirstChildOfClass("Atmosphere") or Instance.new("Atmosphere")
atmo.Parent = Lighting

-- 4 time-of-day presets, lerped by ClockTime (night wraps past 24)
local PRESETS = {
	{ t = 0,    Density = 0.45, Haze = 3.5, Color = Color3.fromRGB(55, 65, 100),   Decay = Color3.fromRGB(30, 35, 60),   Ambient = Color3.fromRGB(25, 30, 55),   Outdoor = Color3.fromRGB(30, 35, 60),    Fog = Color3.fromRGB(45, 55, 85),    FogEnd = 900,  Bright = 0.6 },
	{ t = 6,    Density = 0.38, Haze = 2.2, Color = Color3.fromRGB(255, 190, 150), Decay = Color3.fromRGB(120, 80, 60),  Ambient = Color3.fromRGB(80, 70, 90),   Outdoor = Color3.fromRGB(120, 100, 110), Fog = Color3.fromRGB(235, 175, 140), FogEnd = 2200, Bright = 1.8 },
	{ t = 13,   Density = 0.28, Haze = 1.2, Color = Color3.fromRGB(200, 220, 255), Decay = Color3.fromRGB(90, 95, 110),  Ambient = Color3.fromRGB(95, 100, 120), Outdoor = Color3.fromRGB(140, 150, 170), Fog = Color3.fromRGB(190, 210, 235), FogEnd = 4000, Bright = 2.4 },
	{ t = 18.5, Density = 0.36, Haze = 2.6, Color = Color3.fromRGB(255, 150, 110), Decay = Color3.fromRGB(110, 60, 50),  Ambient = Color3.fromRGB(90, 60, 80),   Outdoor = Color3.fromRGB(130, 90, 100), Fog = Color3.fromRGB(245, 140, 105), FogEnd = 2000, Bright = 1.5 },
}

local function presetAt(t)
	local n = #PRESETS
	for i = 1, n do
		local a = PRESETS[i]
		local b = PRESETS[i % n + 1]
		local t2 = b.t
		if t2 <= a.t then t2 += 24 end
		local tt = t < a.t and t + 24 or t
		if tt >= a.t and tt < t2 then
			return a, b, (tt - a.t) / (t2 - a.t)
		end
	end
	return PRESETS[1], PRESETS[1], 0
end

-- weather emitters: big invisible ceiling parts, created once, toggled by state
local function emitter(name, rate, speed, life, size, color, accel)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Transparency = 1
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Size = Vector3.new(240, 1, 240)
	p.Position = CENTER + Vector3.new(0, 90, 0)
	local e = Instance.new("ParticleEmitter")
	e.Enabled = false
	e.Rate = rate
	e.Lifetime = NumberRange.new(life)
	e.Speed = NumberRange.new(speed * 0.9, speed * 1.1)
	e.EmissionDirection = Enum.NormalId.Bottom
	e.VelocitySpread = 6
	e.Size = NumberSequence.new(size)
	e.Color = ColorSequence.new(color)
	e.Transparency = NumberSequence.new(0.15)
	e.Acceleration = accel or Vector3.new()
	e.Parent = p
	p.Parent = Workspace
	return e
end

local rainE = emitter("RbxRain", 500, 65, 1.5, 0.15, Color3.fromRGB(170, 190, 220), Vector3.new(0, -30, 0))
local snowE = emitter("RbxSnow", 120, 7, 8, 0.45, Color3.fromRGB(245, 245, 255))

local function snd(id, parent)
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Looped = true
	s.Volume = 0.35
	s.Parent = parent
	return s
end
local rainS = snd(RAIN_ID, rainE.Parent)
local snowS = snd(SNOW_ID, snowE.Parent)

local weather = "clear"
local precip = 0 -- smoothed 0..1, drives the fog bump
local function setWeather(w)
	weather = w
	rainE.Enabled = (w == "rain")
	snowE.Enabled = (w == "snow")
	if RAIN_ID ~= "" then
		if w == "rain" then rainS:Play() else rainS:Stop() end
	end
	if SNOW_ID ~= "" then
		if w == "snow" then snowS:Play() else snowS:Stop() end
	end
end

local nextRoll = os.clock() + 45

local clock = Lighting.ClockTime
RunService.Heartbeat:Connect(function(dt)
	-- day/night: full 24h in CYCLE_MIN minutes
	clock = (clock + dt * 24 / (CYCLE_MIN * 60)) % 24
	Lighting.ClockTime = clock
	precip += ((weather ~= "clear" and 1 or 0) - precip) * math.min(1, dt * 0.6)
	if os.clock() >= nextRoll then
		nextRoll = os.clock() + 90 + math.random(60) -- re-roll roughly every ~2 min
		setWeather(math.random() < 0.7 and "clear" or (CLIMATE == "arctic" and "snow" or "rain"))
	end
	local a, b, x = presetAt(clock)
	atmo.Density = a.Density + (b.Density - a.Density) * x + precip * 0.05
	atmo.Haze = a.Haze + (b.Haze - a.Haze) * x
	atmo.Color = a.Color:Lerp(b.Color, x)
	atmo.Decay = a.Decay:Lerp(b.Decay, x)
	Lighting.Ambient = a.Ambient:Lerp(b.Ambient, x)
	Lighting.OutdoorAmbient = a.Outdoor:Lerp(b.Outdoor, x)
	Lighting.FogColor = a.Fog:Lerp(b.Fog, x)
	Lighting.Brightness = a.Bright + (b.Bright - a.Bright) * x
	Lighting.FogEnd = (a.FogEnd + (b.FogEnd - a.FogEnd) * x) * (1 - precip * 0.35)
	Lighting.FogStart = 50
end)

-- ambient audio zones: looped sound on an invisible roll-off part
for i, z in ipairs(ZONES) do
	local p = Instance.new("Part")
	p.Name = "AmbientZone" .. i
	p.Anchored = true
	p.Transparency = 1
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Size = Vector3.new(4, 4, 4)
	p.Position = z.pos or CENTER
	local sid = tostring(z.sound_id or "")
	if sid:match("^%d+$") then sid = "rbxassetid://" .. sid end
	local s = Instance.new("Sound")
	s.SoundId = sid
	s.Looped = true
	s.Volume = z.volume or 0.5
	s.RollOffMode = Enum.RollOffMode.InverseTapered
	s.RollOffMinDistance = 6
	s.RollOffMaxDistance = z.radius or 40
	s.Parent = p
	p.Parent = Workspace
	if sid ~= "" then s:Play() end
end
]=], {
	CYCLE = cfg.cycle_minutes or 10,
	CLIMATE = cfg.climate or "temperate",
	ZONES = lit(cfg.zones or {}),
	RAIN = cfg.rain_sound or "",
	SNOW = cfg.snow_sound or "",
	CENTER = vec3(cfg.center),
}) }, game:GetService("ServerScriptService"))
table.insert(created, "ServerScriptService.RbxWorld")

return { kit = "world", created = created, note = "day/night lerp + 70/30 weather machine (" .. (cfg.climate or "temperate") .. "); zones play looped roll-off audio" }
