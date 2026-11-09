-- rbx-mcp kit: cutscene — cinematic camera-spline LocalScript (letterbox + DoF + skip)
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

-- waypoints -> Luau literal with real Vector3 values
local function wpLit(list)
	local out = {}
	for _, w in ipairs(list) do
		local function vec(t, dy)
			t = t or {}
			return string.format("Vector3.new(%g,%g,%g)", t.x or t[1] or 0, t.y or t[2] or dy or 0, t.z or t[3] or 0)
		end
		table.insert(out, string.format("{ pos = %s, look = %s, dur = %g, fov = %g }",
			vec(w.pos, 10), vec(w.look, 10), w.dur or 3, w.fov or 70))
	end
	return "{ " .. table.concat(out, ", ") .. " }"
end

local WPS = cfg.waypoints or { -- default: 3-point orbit demo around (0,10,0)
	{ pos = { x = 24, y = 14, z = 24 }, look = { x = 0, y = 10, z = 0 }, dur = 4 },
	{ pos = { x = -24, y = 18, z = 12 }, look = { x = 0, y = 10, z = 0 }, dur = 4 },
	{ pos = { x = 0, y = 12, z = 30 }, look = { x = 0, y = 10, z = 0 }, dur = 4, fov = 55 },
}

local sps = game:GetService("StarterPlayer"):FindFirstChild("StarterPlayerScripts") or game:GetService("StarterPlayer")

mk("LocalScript", { Name = "RbxCutscene", Source = sub([=[
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")

local WPS = @WPS@
local LETTERBOX = @LETTERBOX@
local TRIGGER = "@TRIGGER@"

local player = Players.LocalPlayer
local playing = false

local function letterbox()
	local gui = Instance.new("ScreenGui")
	gui.Name = "RbxCutsceneBars"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 50
	local top = Instance.new("Frame")
	top.BackgroundColor3 = Color3.new(0, 0, 0)
	top.BorderSizePixel = 0
	top.AnchorPoint = Vector2.new(0.5, 1) -- parked just above the screen
	top.Size = UDim2.new(1, 0, 0.12, 0)
	top.Position = UDim2.new(0.5, 0, 0, 0)
	top.Parent = gui
	local bot = top:Clone()
	bot.AnchorPoint = Vector2.new(0.5, 0) -- parked just below
	bot.Position = UDim2.new(0.5, 0, 1, 0)
	bot.Parent = gui
	gui.Parent = player:WaitForChild("PlayerGui")
	return gui, top, bot
end

local function play()
	if playing or #WPS == 0 then return end
	local cam = workspace.CurrentCamera
	if not cam then return end
	playing = true
	local skip = false
	local prevFov = cam.FieldOfView
	cam.CameraType = Enum.CameraType.Scriptable

	local gui, top, bot
	if LETTERBOX then
		gui, top, bot = letterbox()
		TweenService:Create(top, TweenInfo.new(0.7, Enum.EasingStyle.Quad), { Position = UDim2.new(0.5, 0, 0.12, 0) }):Play()
		TweenService:Create(bot, TweenInfo.new(0.7, Enum.EasingStyle.Quad), { Position = UDim2.new(0.5, 0, 0.88, 0) }):Play()
	end

	local dof = Instance.new("DepthOfFieldEffect")
	dof.FarIntensity = 0.5
	dof.NearIntensity = 0.4
	dof.InFocusRadius = 24
	dof.Parent = Lighting

	local conn = UserInputService.InputBegan:Connect(function(inp, gpe)
		if not gpe and inp.KeyCode == Enum.KeyCode.Space then skip = true end
	end)

	-- cosine-eased flythrough: each waypoint's dur is travel time INTO it;
	-- first segment eases from the live camera into wp[1]
	local from, fromFov = cam.CFrame, prevFov
	for _, wp in ipairs(WPS) do
		local to = CFrame.lookAt(wp.pos, wp.look)
		local t = 0
		while t < wp.dur and not skip do
			t += RunService.RenderStepped:Wait()
			local a = math.clamp(t / wp.dur, 0, 1)
			local e = 0.5 - 0.5 * math.cos(a * math.pi)
			local cf = from:Lerp(to, e)
			cam.CFrame = cf
			cam.FieldOfView = fromFov + (wp.fov - fromFov) * e
			dof.FocusDistance = (wp.look - cf.Position).Magnitude
		end
		from, fromFov = to, wp.fov
		if skip then break end
	end

	conn:Disconnect()
	dof:Destroy()
	if gui then
		local t1 = TweenService:Create(top, TweenInfo.new(0.5), { Position = UDim2.new(0.5, 0, 0, 0) })
		TweenService:Create(bot, TweenInfo.new(0.5), { Position = UDim2.new(0.5, 0, 1, 0) }):Play()
		t1:Play()
		t1.Completed:Wait()
		gui:Destroy()
	end
	cam.CameraType = Enum.CameraType.Custom
	cam.FieldOfView = prevFov
	playing = false
end

-- trigger plumbing: local bindable for replay + optional named external trigger
local ev = Instance.new("BindableEvent")
ev.Name = "RbxCutscenePlay"
ev.Parent = ReplicatedStorage
ev.Event:Connect(play)
if TRIGGER ~= "" then
	local ext = ReplicatedStorage:WaitForChild(TRIGGER, 10)
	if ext and ext:IsA("BindableEvent") then
		ext.Event:Connect(play)
	elseif ext and ext:IsA("RemoteEvent") then
		ext.OnClientEvent:Connect(play)
	else
		warn("[RbxCutscene] trigger '" .. TRIGGER .. "' not found in ReplicatedStorage")
	end
else
	task.delay(2, play) -- auto-play the demo once on join
end
]=], {
	WPS = wpLit(WPS),
	LETTERBOX = cfg.letterbox == false and "false" or "true",
	TRIGGER = cfg.trigger_bindable or "",
}) }, sps)
table.insert(created, "StarterPlayer.StarterPlayerScripts.RbxCutscene")

return { kit = "cutscene", created = created, note = "client: fire ReplicatedStorage.RbxCutscenePlay to replay; Space skips" }
