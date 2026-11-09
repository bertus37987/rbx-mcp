-- rbx-mcp kit: dialog — branching NPC dialogue: engine module + prompt wiring + typewriter UI
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

-- serialize JSON-friendly config tables to a Luau literal (reserved keys quoted)
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

-- 1) engine module ---------------------------------------------------------------
mk("ModuleScript", { Name = "RbxDialog", Source = [=[
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Dialog = {}
Dialog.actions = {}    -- named side effects for {type="action", fn="name"}
Dialog.conditions = {} -- named predicates for option ["if"]
Dialog.started = Instance.new("BindableEvent")
Dialog.ended = Instance.new("BindableEvent")

local remote = ReplicatedStorage:FindFirstChild("RbxDialogEvent")
if not remote then
	remote = Instance.new("RemoteEvent")
	remote.Name = "RbxDialogEvent"
	remote.Parent = ReplicatedStorage
end
Dialog.remote = remote

Dialog.demoTree = {
	{ id = "start", type = "line", speaker = "Guard", text = "Halt! State your business, traveler.", next = "ask" },
	{ id = "ask", type = "choice", options = {
		{ text = "Just passing through.", ["goto"] = "pass" },
		{ text = "None of your concern.", ["goto"] = "rude" },
	} },
	{ id = "pass", type = "line", speaker = "Guard", text = "Then keep to the road, and keep your blade sheathed.", next = "bye" },
	{ id = "rude", type = "line", speaker = "Guard", text = "Watch your tongue. The keep sees everything.", next = "bye" },
	{ id = "bye", type = "line", speaker = "Guard", text = "Move along now.", next = "done" },
	{ id = "done", type = "end" },
}

local sessions = {}

local function indexOf(tree, ref)
	if type(ref) == "number" then return ref end
	if ref == nil then return nil end
	for i, nd in ipairs(tree) do
		if nd.id == ref then return i end
	end
	return nil
end

local function runCond(c, ctx)
	if type(c) == "function" then return not not c(ctx) end
	local f = Dialog.conditions[c]
	return f and not not f(ctx) or false
end
local function runFn(f, ctx)
	if type(f) == "function" then return f(ctx) end
	local g = Dialog.actions[f]
	if g then return g(ctx) end
end

local step -- forward declaration

local function finish(player)
	local s = sessions[player]
	if not s then return end
	sessions[player] = nil
	remote:FireClient(player, "close")
	Dialog.ended:Fire(player, s.ctx)
end
Dialog.finish = finish

step = function(player)
	local s = sessions[player]
	if not s then return end
	local node = s.tree[s.i]
	if node == nil or node.type == "end" then
		return finish(player)
	end
	if node.type == "line" then
		s.pending = "advance"
		remote:FireClient(player, "node", { kind = "line", speaker = node.speaker or s.ctx.speaker or "NPC", text = tostring(node.text or "") })
	elseif node.type == "choice" then
		s.opts = {}
		local texts = {}
		for _, o in ipairs(node.options or {}) do
			if o["if"] == nil or runCond(o["if"], s.ctx) then
				table.insert(s.opts, o)
				table.insert(texts, tostring(o.text or "..."))
			end
		end
		if #texts == 0 then return finish(player) end
		s.pending = "choose"
		remote:FireClient(player, "node", { kind = "choice", speaker = node.speaker or s.ctx.speaker or "NPC", options = texts })
	elseif node.type == "action" then
		runFn(node.fn, s.ctx)
		s.i = indexOf(s.tree, node.next) or (s.i + 1)
		return step(player)
	else
		s.i += 1
		return step(player)
	end
end

function Dialog.start(a, b, c)
	local player, tree, ctx
	if typeof(a) == "Instance" and a:IsA("Player") then
		player, tree, ctx = a, b, c or {}
	else
		tree, ctx = a, b or {}
		player = ctx.player
	end
	if not player or type(tree) ~= "table" then return nil, "Dialog.start needs player + tree" end
	if sessions[player] then finish(player) end
	local s = { tree = tree, ctx = ctx, i = 1, pending = nil }
	sessions[player] = s
	Dialog.started:Fire(player, ctx)
	step(player)
	return s
end

remote.OnServerEvent:Connect(function(player, action, arg)
	local s = sessions[player]
	if not s then return end
	if action == "advance" and s.pending == "advance" then
		s.pending = nil
		s.i = indexOf(s.tree, s.tree[s.i].next) or (s.i + 1)
		step(player)
	elseif action == "choose" and s.pending == "choose" then
		local pick = (s.opts or {})[tonumber(arg) or 1] or (s.opts or {})[1]
		s.pending = nil
		s.i = pick and (indexOf(s.tree, pick["goto"] or pick.next or pick.to) or (#s.tree + 1)) or (#s.tree + 1)
		step(player)
	elseif action == "close" then
		finish(player)
	end
end)

Players.PlayerRemoving:Connect(function(p) sessions[p] = nil end)

return Dialog
]=] }, game:GetService("ReplicatedStorage"))
table.insert(created, "ReplicatedStorage.RbxDialog")

-- 2) server prompt wiring --------------------------------------------------------
mk("Script", { Name = "RbxDialogServer", Source = sub([=[
local Dialog = require(game:GetService("ReplicatedStorage").RbxDialog)
local NPC_PATH = "@NPC@"
local PROMPT_TEXT = "@PROMPT@"
local TREE = @TREE@ or Dialog.demoTree

local function resolvePath(path)
	local node = game
	for part in string.gmatch(path, "[^%.]+") do
		if part ~= "game" then node = node and node:FindFirstChild(part) end
	end
	return node
end

local npc = resolvePath(NPC_PATH)
if not npc then -- fallback: first Workspace model with 'npc' in the name
	for _, d in ipairs(game:GetService("Workspace"):GetDescendants()) do
		if d:IsA("Model") and string.find(string.lower(d.Name), "npc") then npc = d break end
	end
end

local attach = npc and (npc:IsA("BasePart") and npc or npc:FindFirstChildWhichIsA("BasePart", true))
if attach then
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = PROMPT_TEXT
	prompt.ObjectText = npc.Name
	prompt.MaxActivationDistance = 12
	prompt.Parent = attach
	prompt.Triggered:Connect(function(player)
		Dialog.start(player, TREE, { npc = npc, speaker = npc.Name })
	end)
else
	warn("[RbxDialog] no NPC at '" .. NPC_PATH .. "' — set kit config npc_path")
end
]=], {
	NPC = cfg.npc_path or "Workspace.NPC",
	PROMPT = cfg.prompt_text or "Talk",
	TREE = cfg.tree and lit(cfg.tree) or "nil",
}) }, game:GetService("ServerScriptService"))
table.insert(created, "ServerScriptService.RbxDialogServer")

-- 3) client UI (panel + speaker + typewriter + 4 choice buttons) -----------------
mk("LocalScript", { Name = "RbxDialogUI", Source = [=[
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local remote = ReplicatedStorage:WaitForChild("RbxDialogEvent")

local gui = Instance.new("ScreenGui")
gui.Name = "RbxDialogGui"
gui.ResetOnSpawn = false

local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.Size = UDim2.new(0.55, 0, 0.24, 0)
panel.Position = UDim2.new(0.225, 0, 0.72, 0)
panel.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
panel.BorderSizePixel = 0
panel.Visible = false
panel.Parent = gui
local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 10); corner.Parent = panel
local stroke = Instance.new("UIStroke"); stroke.Color = Color3.fromRGB(200, 170, 90); stroke.Thickness = 2; stroke.Parent = panel

local speaker = Instance.new("TextLabel")
speaker.BackgroundTransparency = 1
speaker.Position = UDim2.new(0, 18, 0, 8)
speaker.Size = UDim2.new(1, -36, 0, 22)
speaker.Font = Enum.Font.GothamBold
speaker.TextSize = 18
speaker.TextXAlignment = Enum.TextXAlignment.Left
speaker.TextColor3 = Color3.fromRGB(230, 200, 120)
speaker.Parent = panel

local body = Instance.new("TextLabel")
body.BackgroundTransparency = 1
body.Position = UDim2.new(0, 18, 0, 34)
body.Size = UDim2.new(1, -36, 1, -64)
body.Font = Enum.Font.Gotham
body.TextSize = 16
body.TextWrapped = true
body.TextXAlignment = Enum.TextXAlignment.Left
body.TextYAlignment = Enum.TextYAlignment.Top
body.TextColor3 = Color3.fromRGB(235, 235, 240)
body.Parent = panel

local hint = Instance.new("TextLabel")
hint.BackgroundTransparency = 1
hint.AnchorPoint = Vector2.new(1, 1)
hint.Position = UDim2.new(1, -14, 1, -8)
hint.Size = UDim2.new(0, 220, 0, 16)
hint.Font = Enum.Font.Gotham
hint.TextSize = 12
hint.TextXAlignment = Enum.TextXAlignment.Right
hint.TextColor3 = Color3.fromRGB(150, 150, 160)
hint.Text = "[E / click] continue"
hint.Parent = panel

local btnHolder = Instance.new("Frame")
btnHolder.BackgroundTransparency = 1
btnHolder.Position = UDim2.new(0, 18, 0, 36)
btnHolder.Size = UDim2.new(1, -36, 1, -54)
btnHolder.Visible = false
btnHolder.Parent = panel
local list = Instance.new("UIListLayout")
list.Padding = UDim.new(0, 6)
list.Parent = btnHolder

local buttons = {}
for i = 1, 4 do
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, 0, 0, 30)
	b.BackgroundColor3 = Color3.fromRGB(35, 35, 48)
	b.Font = Enum.Font.Gotham
	b.TextSize = 15
	b.TextColor3 = Color3.fromRGB(230, 230, 240)
	b.Visible = false
	b.Parent = btnHolder
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = b
	b.MouseButton1Click:Connect(function() remote:FireServer("choose", i) end)
	buttons[i] = b
end
gui.Parent = player:WaitForChild("PlayerGui")

local typing = false
local function typeText(text)
	body.Text = text
	body.MaxVisibleGraphemes = 0
	typing = true
	task.spawn(function()
		for i = 1, #text do
			if not typing then break end
			body.MaxVisibleGraphemes = i
			task.wait(0.018)
		end
		typing = false
		body.MaxVisibleGraphemes = -1
	end)
end

local function showChoices(show)
	for _, b in ipairs(buttons) do b.Visible = false end
	hint.Visible = not show
	body.Visible = not show
	btnHolder.Visible = show
end

remote.OnClientEvent:Connect(function(kind, node)
	if kind == "close" then panel.Visible = false return end
	if kind ~= "node" or type(node) ~= "table" then return end
	panel.Visible = true
	speaker.Text = tostring(node.speaker or "")
	if node.kind == "line" then
		showChoices(false)
		typeText(tostring(node.text or ""))
	elseif node.kind == "choice" then
		showChoices(true)
		for i, b in ipairs(buttons) do
			local t = node.options and node.options[i]
			b.Visible = t ~= nil
			b.Text = t and (i .. ". " .. tostring(t)) or ""
		end
	end
end)

local function advance()
	if not panel.Visible then return end
	if typing then
		typing = false
		body.MaxVisibleGraphemes = -1
	else
		remote:FireServer("advance")
	end
end
panel.InputBegan:Connect(function(inp)
	if inp.UserInputType == Enum.UserInputType.MouseButton1 then advance() end
end)
UserInputService.InputBegan:Connect(function(inp, gpe)
	if not gpe and inp.KeyCode == Enum.KeyCode.E then advance() end
end)
]=] }, game:GetService("StarterGui"))
table.insert(created, "StarterGui.RbxDialogUI")

return { kit = "dialog", created = created, note = "server: require(ReplicatedStorage.RbxDialog).start(player, tree, ctx); client waits on RbxDialogEvent" }
