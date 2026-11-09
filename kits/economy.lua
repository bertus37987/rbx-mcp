-- rbx-mcp kit: economy — currency leaderstat + server API + buy remote
local cfg = KIT_CONFIG or {}
local currency = cfg.currency or "Coins"
local created = {}

local function mk(class, props, parent)
	local i = Instance.new(class)
	for k, v in pairs(props or {}) do pcall(function() i[k] = v end) end
	i.Parent = parent
	return i
end

mk("Script", { Name = "EconomyService", Source = ([=[
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local store = DataStoreService:GetDataStore("Economy_v1")
local CURRENCY = %q

local Economy = {}

Players.PlayerAdded:Connect(function(player)
	local stats = Instance.new("Folder")
	stats.Name = "leaderstats"; stats.Parent = player
	local bal = Instance.new("IntValue")
	bal.Name = CURRENCY; bal.Value = %d; bal.Parent = stats
	local ok, saved = pcall(function() return store:GetAsync("u_" .. player.UserId) end)
	if ok and type(saved) == "number" then bal.Value = saved end
end)

Players.PlayerRemoving:Connect(function(player)
	local bal = player:FindFirstChild("leaderstats") and player.leaderstats:FindFirstChild(CURRENCY)
	if bal then pcall(function() store:SetAsync("u_" .. player.UserId, bal.Value) end) end
end)

local function getBal(player)
	return player.leaderstats[CURRENCY].Value
end
function Economy.Add(player, n) player.leaderstats[CURRENCY].Value += n return getBal(player) end
function Economy.Spend(player, n)
	local bal = player.leaderstats[CURRENCY]
	if bal.Value < n then return false, "insufficient funds" end
	bal.Value -= n
	return true, bal.Value
end

local buy = Instance.new("RemoteFunction")
buy.Name = "RequestBuy"; buy.Parent = ReplicatedStorage
buy.OnServerInvoke = function(player, itemId, price)
	local ok, res = Economy.Spend(player, tonumber(price) or 0)
	if not ok then return { ok = false, error = res } end
	return { ok = true, item = itemId, balance = res }
end

game:BindToClose(function()
	for _, p in ipairs(Players:GetPlayers()) do
		local bal = p:FindFirstChild("leaderstats") and p.leaderstats:FindFirstChild(CURRENCY)
		if bal then pcall(function() store:SetAsync("u_" .. p.UserId, bal.Value) end) end
	end
end)

_G.Economy = Economy
]=]):format(currency, cfg.starting_balance or 0) }, game:GetService("ServerScriptService"))
table.insert(created, "ServerScriptService.EconomyService")
table.insert(created, "ReplicatedStorage.RequestBuy")

return { kit = "economy", created = created, note = "Client calls ReplicatedStorage.RequestBuy:InvokeServer(itemId, price)" }
