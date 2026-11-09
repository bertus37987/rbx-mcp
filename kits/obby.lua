-- rbx-mcp kit: obby — spawn, checkpoints, kill bricks, leaderstats
-- Server prepends: local KIT_CONFIG = {...}; local PARENT_PATH = "..."
local cfg = KIT_CONFIG or {}
local created = {}

local function mk(class, props, parent)
	local i = Instance.new(class)
	for k, v in pairs(props or {}) do pcall(function() i[k] = v end) end
	i.Parent = parent
	return i
end

-- leaderstats
mk("Script", { Name = "Leaderstats", Source = [=[
local Players = game:GetService("Players")
Players.PlayerAdded:Connect(function(player)
	local stats = Instance.new("Folder")
	stats.Name = "leaderstats"
	stats.Parent = player
	local stage = Instance.new("IntValue")
	stage.Name = "Stage"
	stage.Value = 1
	stage.Parent = stats
end)
]=] }, game:GetService("ServerScriptService"))
table.insert(created, "ServerScriptService.Leaderstats")

-- checkpoints folder
local folder = mk("Folder", { Name = "Checkpoints" }, workspace)
table.insert(created, "Workspace.Checkpoints")

local stages = cfg.stages or 5
local startPos = cfg.start or Vector3.new(0, 5, 0)
for i = 1, stages do
	local cp = mk("Part", {
		Name = "Checkpoint" .. i, Anchored = true,
		Size = Vector3.new(6, 1, 6),
		Position = startPos + Vector3.new(i * (cfg.spacing or 30), 0, 0),
		Color = Color3.fromRGB(80, 160, 255),
		Transparency = 0.3,
	}, folder)
	cp:SetAttribute("Stage", i)
	mk("Script", { Name = "CheckpointLogic", Source = [=[
local checkpoint = script.Parent
checkpoint.Touched:Connect(function(hit)
	local hum = hit.Parent and hit.Parent:FindFirstChildOfClass("Humanoid")
	if not hum then return end
	local player = game:GetService("Players"):GetPlayerFromCharacter(hit.Parent)
	if not player then return end
	local stage = checkpoint:GetAttribute("Stage")
	if player.leaderstats.Stage.Value < stage then
		player.leaderstats.Stage.Value = stage
	end
end)
]=] }, cp)
end
table.insert(created, stages .. " checkpoints")

-- kill brick sample
local kill = mk("Part", {
	Name = "KillBrick", Anchored = true, Size = Vector3.new(8, 1, 8),
	Position = startPos + Vector3.new(15, -2, 8),
	Color = Color3.fromRGB(255, 60, 60),
}, workspace)
mk("Script", { Name = "Kill", Source = [=[
script.Parent.Touched:Connect(function(hit)
	local hum = hit.Parent and hit.Parent:FindFirstChildOfClass("Humanoid")
	if hum then hum.Health = 0 end
end)
]=] }, kill)
table.insert(created, "Workspace.KillBrick")

-- respawn at checkpoint
mk("Script", { Name = "CheckpointRespawn", Source = [=[
local Players = game:GetService("Players")
Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(char)
		local stage = player:WaitForChild("leaderstats").Stage.Value
		local cp = workspace.Checkpoints:FindFirstChild("Checkpoint" .. stage)
		if cp then
			char:PivotTo(cp.CFrame + Vector3.new(0, 4, 0))
		end
	end)
end)
]=] }, game:GetService("ServerScriptService"))
table.insert(created, "ServerScriptService.CheckpointRespawn")

return { kit = "obby", created = created }
