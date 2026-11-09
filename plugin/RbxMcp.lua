--!native
-- RbxMcp — Studio plugin half of rbx-mcp.
-- One self-contained file: drop into Roblox/Plugins, click the toolbar button.
-- Long-polls the local broker at 127.0.0.1:58420, executes commands, posts results.
-- Mutations always record a ChangeHistoryService waypoint first (Edit>Undo works).

local HttpService = game:GetService("HttpService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local Selection = game:GetService("Selection")
local LogService = game:GetService("LogService")
local RunService = game:GetService("RunService")
local InsertService = game:GetService("InsertService")
local AssetService = game:GetService("AssetService")
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local TestService = game:GetService("TestService")
local StarterGui = game:GetService("StarterGui")

local PORT = 58420
local BASE = "http://127.0.0.1:" .. tostring(PORT)
local VERSION = "0.1.0"
local STUDIO_ID = HttpService:GenerateGUID(false)
local POLL_WAIT = 25

----------------------------------------------------------------------
-- serialization
----------------------------------------------------------------------
local function instancePath(inst)
	local parts = {}
	local cur = inst
	while cur and cur ~= game do
		table.insert(parts, 1, cur.Name)
		cur = cur.Parent
	end
	return table.concat(parts, ".")
end

local function toData(v, depth)
	depth = depth or 0
	local t = typeof(v)
	if t == "Instance" then
		return { __type = "Instance", path = instancePath(v), class = v.ClassName }
	elseif t == "Vector3" then
		return { __type = "Vector3", x = v.X, y = v.Y, z = v.Z }
	elseif t == "Vector2" then
		return { __type = "Vector2", x = v.X, y = v.Y }
	elseif t == "CFrame" then
		local c = { v:GetComponents() }
		return { __type = "CFrame", c = c }
	elseif t == "Color3" then
		return { __type = "Color3", r = v.R, g = v.G, b = v.B }
	elseif t == "BrickColor" then
		return { __type = "BrickColor", name = v.Name }
	elseif t == "EnumItem" then
		return { __type = "Enum", value = tostring(v) }
	elseif t == "UDim2" then
		return { __type = "UDim2", sx = v.X.Scale, ox = v.X.Offset, sy = v.Y.Scale, oy = v.Y.Offset }
	elseif t == "UDim" then
		return { __type = "UDim", s = v.Scale, o = v.Offset }
	elseif t == "Rect" then
		return { __type = "Rect", min = { v.Min.X, v.Min.Y }, max = { v.Max.X, v.Max.Y } }
	elseif t == "NumberRange" or t == "NumberSequence" or t == "ColorSequence" or t == "PhysicalProperties" then
		return { __type = t, value = tostring(v) }
	elseif t == "table" and depth < 4 then
		local out = {}
		for k, vv in pairs(v) do out[tostring(k)] = toData(vv, depth + 1) end
		return out
	elseif t == "string" or t == "number" or t == "boolean" then
		return v
	else
		return tostring(v)
	end
end

local function cframeFromData(d)
	if d.c then return CFrame.new(table.unpack(d.c)) end
	local pos = d.pos or { x = 0, y = 0, z = 0 }
	local rot = d.rotDeg or { x = 0, y = 0, z = 0 }
	return CFrame.new(pos.x or 0, pos.y or 0, pos.z or 0)
		* CFrame.Angles(math.rad(rot.x or 0), math.rad(rot.y or 0), math.rad(rot.z or 0))
end

-- accepts both [x,y,z] arrays and {x,y,z} objects (JSON callers send either)
local function v3(v, default)
	if type(v) ~= "table" then return default or Vector3.new() end
	return Vector3.new(v[1] or v.x or 0, v[2] or v.y or 0, v[3] or v.z or 0)
end

-- decode a JSON value against the expected Roblox property type
local function decodeProp(expectedType, value, current)
	if type(value) ~= "table" then
		if expectedType == "BrickColor" and type(value) == "string" then return BrickColor.new(value) end
		if expectedType == "Color3" and type(value) == "string" then
			local h = value:gsub("#", "")
			if #h == 6 then return Color3.fromRGB(tonumber(h:sub(1,2),16), tonumber(h:sub(3,4),16), tonumber(h:sub(5,6),16)) end
		end
		if expectedType == "EnumItem" and type(value) == "string" then
			local et, en = value:match("^Enum%.([%w_]+)%.([%w_]+)$")
			if not et and current then et, en = tostring(current):match("^Enum%.([%w_]+)%."), value end
			if et then
				local ok, e = pcall(function() return Enum[et][en] end)
				if ok then return e end
				error("bad enum " .. tostring(value))
			end
		end
		return value
	end
	if value.__type == "CFrame" or expectedType == "CFrame" then return cframeFromData(value) end
	if expectedType == "Vector3" or value.__type == "Vector3" then return Vector3.new(value.x or 0, value.y or 0, value.z or 0) end
	if expectedType == "Vector2" then return Vector2.new(value.x or 0, value.y or 0) end
	if expectedType == "Color3" or value.__type == "Color3" then
		if value.hex then
			local h = value.hex:gsub("#", "")
			return Color3.fromRGB(tonumber(h:sub(1, 2), 16), tonumber(h:sub(3, 4), 16), tonumber(h:sub(5, 6), 16))
		end
		return Color3.new(value.r or 0, value.g or 0, value.b or 0)
	end
	if expectedType == "BrickColor" then return BrickColor.new(value.name or value) end
	if expectedType == "UDim2" or value.__type == "UDim2" then
		return UDim2.new(value.sx or 0, value.ox or 0, value.sy or 0, value.oy or 0)
	end
	if expectedType == "UDim" then return UDim.new(value.s or 0, value.o or 0) end
	if expectedType == "EnumItem" and value.__type == "Enum" then
		local ok, e = pcall(function()
			local t, n = value.value:match("^Enum%.([%w_]+)%.([%w_]+)$")
			return Enum[t][n]
		end)
		if ok then return e end
		error("bad enum " .. tostring(value.value))
	end
	return value
end

local function resolvePath(path)
	if not path or path == "" or path == "game" or path == "DataModel" then return game end
	local cur = game
	for seg in tostring(path):gmatch("[^%.]+") do
		if seg == "game" then continue end
		cur = cur and cur:FindFirstChild(seg)
		if not cur then return nil, "path segment '" .. seg .. "' not found under " .. instancePath(cur or game) end
	end
	return cur
end

local function waypoint(label)
	pcall(function() ChangeHistoryService:SetWaypoint("rbx-mcp: " .. (label or "op")) end)
end

local function djb2(s)
	local h = 5381
	for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 4294967296 end
	return string.format("%08x", h)
end

----------------------------------------------------------------------
-- commands
----------------------------------------------------------------------
local Commands = {}

Commands.ping = function()
	return {
		ok = true, version = VERSION, place = game.Name, placeId = game.PlaceId,
		studioId = STUDIO_ID, running = RunService:IsRunning(),
	}
end

Commands.studios = function()
	return { studioId = STUDIO_ID, place = game.Name, placeId = game.PlaceId, version = VERSION,
		caps = { "run_luau", "tree", "crud", "gui", "terrain", "rig", "audit", "import" } }
end

Commands.run_luau = function(args)
	local code = args.code or ""
	local fn, cerr = loadstring("return (function()\n" .. code .. "\nend)()")
	if not fn then
		fn, cerr = loadstring(code) -- allow non-returning code
	end
	if not fn then error("compile error: " .. tostring(cerr)) end
	local t0 = os.clock()
	local ok, res = xpcall(fn, debug.traceback)
	return { ok = ok, result = toData(res), ms = math.floor((os.clock() - t0) * 1000) }
end

Commands.get_tree = function(args)
	local root, err = resolvePath(args.path)
	if not root then error(err) end
	local maxDepth = math.min(args.max_depth or 3, 10)
	local headLimit = args.head_limit or 200
	local it = args.instance_type
	local kws = {}
	for k in tostring(args.keywords or ""):gmatch("[^,%s]+") do table.insert(kws, string.lower(k)) end
	local out = {}
	local function matches(inst)
		if it and not inst:IsA(it) then return false end
		if #kws > 0 then
			local n = string.lower(inst.Name)
			local hit = false
			for _, k in ipairs(kws) do if string.find(n, k, 1, true) then hit = true break end end
			if not hit then return false end
		end
		return true
	end
	local function walk(inst, depth)
		if #out >= headLimit then return end
		local kids = inst:GetChildren()
		local row = {
			name = inst.Name, className = inst.ClassName, path = instancePath(inst),
			childCount = #kids,
		}
		if depth < maxDepth then
			row.children = {}
			for _, c in ipairs(kids) do
				if #out >= headLimit then break end
				if matches(c) then
					table.insert(row.children, walk(c, depth + 1))
				else
					row.unexplored = (row.unexplored or 0) + 1
				end
			end
		else
			row.unexplored = #kids
		end
		table.insert(out, row)
		return row
	end
	walk(root, 0)
	return { nodes = out, truncated = #out >= headLimit }
end

local COMMON_PROPS = {
	BasePart = { "Position", "Size", "CFrame", "Color", "Transparency", "Material", "Anchored", "CanCollide", "CanQuery", "Massless", "Reflectance", "CastShadow" },
	MeshPart = { "MeshId", "TextureID", "RenderFidelity", "CollisionFidelity", "DoubleSided" },
	SpecialMesh = { "MeshId", "TextureId", "MeshType", "Scale", "Offset" },
	GuiObject = { "Size", "Position", "AnchorPoint", "Visible", "ZIndex", "BackgroundColor3", "BackgroundTransparency", "BorderSizePixel", "LayoutOrder", "Rotation" },
	TextLabel = { "Text", "TextScaled", "TextSize", "Font", "FontFace", "TextColor3", "RichText" },
	TextButton = { "Text", "TextScaled", "TextSize", "Font", "FontFace", "TextColor3", "AutoButtonColor" },
	ImageLabel = { "Image", "ScaleType", "ImageColor3", "ImageTransparency", "SliceCenter", "SliceScale", "TileSize" },
	ImageButton = { "Image", "ScaleType", "ImageColor3", "AutoButtonColor" },
	Script = { "Source" }, LocalScript = { "Source" }, ModuleScript = { "Source" },
	Humanoid = { "Health", "MaxHealth", "WalkSpeed", "JumpPower", "JumpHeight", "RigType" },
	Attachment = { "CFrame", "WorldCFrame", "Axis", "SecondaryAxis" },
	Accessory = { "AccessoryType" },
	UICorner = { "CornerRadius" }, UIStroke = { "Thickness", "Color", "ApplyStrokeMode", "Transparency" },
	UIGradient = { "Color", "Rotation", "Transparency" }, UIPadding = { "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight" },
	UIListLayout = { "FillDirection", "HorizontalAlignment", "VerticalAlignment", "Padding", "SortOrder" },
	UIGridLayout = { "CellSize", "CellPadding", "FillDirectionMaxCells", "SortOrder" },
	UISizeConstraint = { "MinSize", "MaxSize" }, UIAspectRatioConstraint = { "AspectRatio", "AspectType", "DominantAxis" },
	ScreenGui = { "Enabled", "DisplayOrder", "IgnoreGuiInset", "ResetOnSpawn", "ZIndexBehavior" },
	SurfaceGui = { "CanvasSize", "AlwaysOnTop" },
	Model = { "PrimaryPart", "WorldPivot" },
	Tool = { "RequiresHandle" },
}

local function propsFor(inst)
	local out = {}
	local seen = {}
	local classes = { inst.ClassName }
	local function addFor(className)
		for _, p in ipairs(COMMON_PROPS[className] or {}) do
			if not seen[p] then
				seen[p] = true
				local ok, v = pcall(function() return inst[p] end)
				if ok then out[p] = toData(v) end
			end
		end
	end
	addFor(inst.ClassName)
	if inst:IsA("BasePart") then addFor("BasePart") end
	if inst:IsA("GuiObject") then addFor("GuiObject") end
	if inst:IsA("TextLabel") then addFor("TextLabel") end
	if inst:IsA("TextButton") then addFor("TextButton") end
	if inst:IsA("ImageLabel") then addFor("ImageLabel") end
	if inst:IsA("ImageButton") then addFor("ImageButton") end
	if inst:IsA("TextBox") then addFor("TextLabel") end
	-- attributes + tags always
	local attrs = {}
	pcall(function()
		for k, v in pairs(inst:GetAttributes()) do attrs[k] = toData(v) end
	end)
	out._attributes = attrs
	out._tags = CollectionService:GetTags(inst)
	return out
end

Commands.inspect = function(args)
	local inst, err = resolvePath(args.path)
	if not inst then error(err) end
	return {
		name = inst.Name, className = inst.ClassName, path = instancePath(inst),
		props = propsFor(inst),
		children = (function()
			local t = {}
			for _, c in ipairs(inst:GetChildren()) do table.insert(t, { name = c.Name, className = c.ClassName }) end
			return t
		end)(),
	}
end

Commands.console = function(args)
	local entries = LogService:GetLogHistory()
	local tail = args.tail or 100
	local level = args.level
	local out = {}
	local start = math.max(1, #entries - tail + 1)
	for i = start, #entries do
		local e = entries[i]
		local mt = tostring(e.messageType):match("%.(%w+)$") or tostring(e.messageType)
		if not level or level == "all" or mt == level then
			table.insert(out, { message = e.message, type = mt, time = e.time })
		end
	end
	return { entries = out }
end

Commands.read_script = function(args)
	local inst, err = resolvePath(args.path)
	if not inst then error(err) end
	if not inst:IsA("LuaSourceContainer") then error(inst.ClassName .. " has no Source") end
	return { path = instancePath(inst), className = inst.ClassName, source = inst.Source,
		hash = djb2(inst.Source), lines = select(2, inst.Source:gsub("\n", "\n")) + 1 }
end

Commands.write_script = function(args)
	local inst, err = resolvePath(args.path)
	if not inst then
		if not args.className then error(err .. " (pass className to create)") end
		local segs = {}
		for s in tostring(args.path):gmatch("[^%.]+") do table.insert(segs, s) end
		local name = table.remove(segs)
		local parent, perr = resolvePath(table.concat(segs, "."))
		if not parent then error(perr) end
		inst = Instance.new(args.className)
		inst.Name = name
		inst.Parent = parent
	end
	if not inst:IsA("LuaSourceContainer") then error(inst.ClassName .. " has no Source") end
	if args.expected_hash then
		local cur = djb2(inst.Source)
		if cur ~= args.expected_hash then
			error("hash mismatch: current=" .. cur .. " expected=" .. args.expected_hash .. " — script changed since read; re-read first")
		end
	end
	waypoint("write_script " .. instancePath(inst))
	inst.Source = args.source or ""
	return { path = instancePath(inst), hash = djb2(inst.Source), lines = select(2, inst.Source:gsub("\n", "\n")) + 1 }
end

Commands.create_instance = function(args)
	local parent, perr = resolvePath(args.parent_path)
	if not parent then error(perr) end
	waypoint("create " .. tostring(args.className))
	local inst = Instance.new(args.className)
	inst.Name = args.name or args.className
	local failed = {}
	for k, v in pairs(args.props or {}) do
		local ok, curT = pcall(function() return typeof(inst[k]) end)
		if ok then
			local ok2, e2 = pcall(function() inst[k] = decodeProp(curT, v, inst[k]) end)
			if not ok2 then table.insert(failed, { prop = k, error = tostring(e2) }) end
		else
			table.insert(failed, { prop = k, error = "no such property" })
		end
	end
	inst.Parent = parent
	return { path = instancePath(inst), failed_props = failed }
end

Commands.set_properties = function(args)
	local inst, err = resolvePath(args.path)
	if not inst then error(err) end
	waypoint("set_properties " .. instancePath(inst))
	local applied, failed = {}, {}
	for k, v in pairs(args.props or {}) do
		local ok, curT = pcall(function() return typeof(inst[k]) end)
		if ok then
			local ok2, e2 = pcall(function() inst[k] = decodeProp(curT, v, inst[k]) end)
			if ok2 then table.insert(applied, k) else table.insert(failed, { prop = k, error = tostring(e2) }) end
		else
			table.insert(failed, { prop = k, error = "no such property on " .. inst.ClassName })
		end
	end
	return { applied = applied, failed = failed }
end

Commands.delete = function(args)
	local inst, err = resolvePath(args.path)
	if not inst then error(err) end
	local p = instancePath(inst)
	waypoint("delete " .. p)
	inst:Destroy()
	return { removed = p }
end

Commands.checkpoint = function(args)
	waypoint(args.label or "manual")
	return { ok = true }
end

Commands.undo = function(args)
	local steps = args.steps or 1
	local done = 0
	for _ = 1, steps do
		local can = false
		pcall(function() can = ChangeHistoryService:GetCanUndo() end)
		if not can then break end
		pcall(function() ChangeHistoryService:Undo() end)
		done += 1
	end
	return { undone = done }
end

local SNAPSHOT_PROPS = { "Position", "Size", "CFrame", "Color", "Transparency", "Anchored", "Visible", "Text", "Image", "Enabled", "MeshId" }

Commands.snapshot = function(args)
	local root, err = resolvePath(args.path)
	if not root then error(err) end
	local includeHashes = args.include_source_hashes ~= false
	local nodes = {}
	local function walk(inst)
		local row = { path = instancePath(inst), className = inst.ClassName, props = {} }
		for _, p in ipairs(SNAPSHOT_PROPS) do
			local ok, v = pcall(function() return inst[p] end)
			if ok and v ~= nil then row.props[p] = toData(v) end
		end
		if includeHashes and inst:IsA("LuaSourceContainer") then row.hash = djb2(inst.Source) end
		table.insert(nodes, row)
		for _, c in ipairs(inst:GetChildren()) do walk(c) end
	end
	walk(root)
	return { nodes = nodes, count = #nodes }
end

Commands.dump_scripts = function()
	local out = {}
	local function walk(inst)
		if inst:IsA("LuaSourceContainer") then
			table.insert(out, { path = instancePath(inst), className = inst.ClassName, source = inst.Source })
		end
		for _, c in ipairs(inst:GetChildren()) do walk(c) end
	end
	walk(game)
	return { scripts = out, count = #out }
end

Commands.gui_audit = function()
	local issues = {}
	local function add(inst, issue, severity, fix)
		table.insert(issues, { path = instancePath(inst), issue = issue, severity = severity, fix = fix })
	end
	local function hasOffset(u) return u.X.Offset ~= 0 or u.Y.Offset ~= 0 end
	local roots = {}
	pcall(function() table.insert(roots, StarterGui) end)
	pcall(function()
		local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChild("PlayerGui")
		if pg then table.insert(roots, pg) end
	end)
	local cornerSeen = {}
	local function walk(inst)
		if inst:IsA("GuiObject") then
			if hasOffset(inst.Size) then
				add(inst, "pixel offsets in Size", "medium", "convert Size to scale-based UDim2 (Offset=0) for resolution safety")
			end
			if hasOffset(inst.Position) then
				add(inst, "pixel offsets in Position", "medium", "convert Position to scale-based UDim2")
			end
			if inst:IsA("ImageLabel") or inst:IsA("ImageButton") then
				local hasAspect = false
				for _, c in ipairs(inst:GetChildren()) do if c:IsA("UIAspectRatioConstraint") then hasAspect = true end end
				if not hasAspect and inst.Image ~= "" and math.abs(inst.Size.X.Scale - inst.Size.Y.Scale) > 0.001 then
					add(inst, "ImageLabel sized without AspectRatioConstraint", "low", "add UIAspectRatioConstraint so the image never distorts")
				end
			end
			if (inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox")) and not inst.TextScaled then
				local absY = inst.AbsoluteSize.Y
				if absY > 0 and absY < 28 then
					add(inst, "small text without TextScaled", "low", "set TextScaled=true or raise TextSize")
				end
			end
			if inst:IsA("Frame") or inst:IsA("ImageLabel") or inst:IsA("TextButton") then
				local hasCorner = false
				for _, c in ipairs(inst:GetChildren()) do if c:IsA("UICorner") then hasCorner = true end end
				local key = inst.Parent and instancePath(inst.Parent) or "?"
				if hasCorner then cornerSeen[key] = true end
				if cornerSeen[key] and not hasCorner then
					add(inst, "sibling frames have UICorner but this does not", "low", "add matching UICorner for style consistency")
				end
			end
		end
		for _, c in ipairs(inst:GetChildren()) do walk(c) end
	end
	for _, r in ipairs(roots) do walk(r) end
	table.sort(issues, function(a, b)
		local sev = { high = 0, medium = 1, low = 2 }
		return (sev[a.severity] or 9) < (sev[b.severity] or 9)
	end)
	return { issues = issues, count = #issues }
end

local SCAN_PATTERNS = {
	{ pat = "require%s*%(%s*%d+", sev = "high", what = "require(<numeric assetId>) — classic backdoor loader" },
	{ pat = "loadstring", sev = "high", what = "loadstring (remote code exec)" },
	{ pat = "getfenv", sev = "medium", what = "getfenv" },
	{ pat = "setfenv", sev = "medium", what = "setfenv" },
	{ pat = "HttpGet", sev = "medium", what = "HttpGet" },
	{ pat = "PostAsync", sev = "medium", what = "PostAsync" },
	{ pat = "getObjects", sev = "high", what = "InsertService-adjacent getObjects loader" },
	{ pat = "\\x%x%x", sev = "medium", what = "hex-escaped bytes (obfuscation)" },
	{ pat = "\\\\%d%d%d\\\\%d%d%d", sev = "medium", what = "decimal-escaped bytes (obfuscation)" },
	{ pat = "Roblox%.com%s*//", sev = "low", what = "suspicious URL form" },
}
Commands.security_scan = function()
	local findings = {}
	local function walk(inst)
		if inst:IsA("LuaSourceContainer") then
			local src = inst.Source or ""
			local ln = 0
			for line in (src .. "\n"):gmatch("(.-)\n") do
				ln += 1
				for _, sp in ipairs(SCAN_PATTERNS) do
					if string.find(line, sp.pat) then
						table.insert(findings, { path = instancePath(inst), line = ln, pattern = sp.what, severity = sp.sev })
						break
					end
				end
			end
		end
		-- nil-parented scripts can't exist in the datamodel; check weird containers
		if inst:IsA("LuaSourceContainer") and inst.ClassName == "Script" then
			local p = inst.Parent
			if p and (p:IsA("Folder") and (p.Name:lower():find("temp") or p.Name:lower():find("hidden"))) then
				table.insert(findings, { path = instancePath(inst), line = 0, pattern = "script inside suspicious folder '" .. p.Name .. "'", severity = "low" })
			end
		end
		for _, c in ipairs(inst:GetChildren()) do walk(c) end
	end
	walk(game)
	table.sort(findings, function(a, b)
		local sev = { high = 0, medium = 1, low = 2 }
		return (sev[a.severity] or 9) < (sev[b.severity] or 9)
	end)
	return { findings = findings, count = #findings }
end

Commands.validate_asset = function(args)
	local inst, err = resolvePath(args.path)
	if not inst then error(err) end
	local issues, stats = {}, { parts = 0, meshParts = 0, unanchored = 0, scripts = 0, extent = Vector3.new(0, 0, 0) }
	local minB, maxB = Vector3.new(math.huge, math.huge, math.huge), Vector3.new(-math.huge, -math.huge, -math.huge)
	local function walk(o)
		if o:IsA("BasePart") then
			stats.parts += 1
			if o:IsA("MeshPart") then stats.meshParts += 1 end
			if not o.Anchored then stats.unanchored += 1 end
			local p, s = o.Position, o.Size
			minB = Vector3.new(math.min(minB.X, p.X - s.X / 2), math.min(minB.Y, p.Y - s.Y / 2), math.min(minB.Z, p.Z - s.Z / 2))
			maxB = Vector3.new(math.max(maxB.X, p.X + s.X / 2), math.max(maxB.Y, p.Y + s.Y / 2), math.max(maxB.Z, p.Z + s.Z / 2))
			if o:IsA("MeshPart") then
				if o.MeshId == "" then table.insert(issues, { path = instancePath(o), issue = "MeshPart with empty MeshId" }) end
				if o.CanCollide and o.Name:lower():match("decor|detail|ornament|trim") then
					table.insert(issues, { path = instancePath(o), issue = "decorative part with CanCollide=true — physics cost", fix = "CanCollide=false" })
				end
				if o.CollisionFidelity == Enum.CollisionFidelity.Default and o:IsA("MeshPart") then
					table.insert(issues, { path = instancePath(o), issue = "CollisionFidelity=Default on MeshPart", fix = "Box for armor/props, PreciseConvexDecomposition only when needed" })
				end
			end
			if (o:IsA("MeshPart") or o:IsA("Part")) and o:IsA("MeshPart") and o.TextureID == "" then
				table.insert(issues, { path = instancePath(o), issue = "MeshPart without TextureID/SurfaceAppearance", severity = "low" })
			end
		end
		if o:IsA("LuaSourceContainer") then stats.scripts += 1 end
		for _, c in ipairs(o:GetChildren()) do walk(c) end
	end
	walk(inst)
	if stats.parts > 0 then stats.extent = maxB - minB end
	if stats.unanchored > 0 then table.insert(issues, { path = instancePath(inst), issue = stats.unanchored .. " unanchored part(s)", fix = "anchor static geometry or weld to rig" }) end
	if inst:IsA("Model") and not inst.PrimaryPart then
		table.insert(issues, { path = instancePath(inst), issue = "Model without PrimaryPart", fix = "set PrimaryPart for stable pivot" })
	end
	if stats.extent.X > 2048 or stats.extent.Y > 2048 or stats.extent.Z > 2048 then
		table.insert(issues, { path = instancePath(inst), issue = "extents exceed 2048 studs — streaming/render cost", severity = "medium" })
	end
	return { issues = issues, stats = stats }
end

----------------------------------------------------------------------
-- GUI pattern library — real GuiObject trees
----------------------------------------------------------------------
local THEMES = {
	dark = { bg = "#15161a", fg = "#f4f4f5", accent = "#3b82f6", stroke = "#26272c", font = "GothamBold", corner = 10, strokePx = 1 },
	light = { bg = "#ffffff", fg = "#111111", accent = "#0a84ff", stroke = "#e4e4e7", font = "GothamBold", corner = 12, strokePx = 1 },
	fantasy = { bg = "#1d1608", fg = "#f2e4b8", accent = "#d4a437", stroke = "#4d3d16", font = "Fantasy", corner = 8, strokePx = 2 },
	scifi = { bg = "#0a0e14", fg = "#d5f5ff", accent = "#22d3ee", stroke = "#134154", font = "SciFi", corner = 4, strokePx = 1 },
}
local function hex(c)
	if typeof(c) == "Color3" then return c end
	c = tostring(c or "#ffffff"):gsub("#", "")
	return Color3.fromRGB(tonumber(c:sub(1, 2), 16) or 0, tonumber(c:sub(3, 4), 16) or 0, tonumber(c:sub(5, 6), 16) or 0)
end
local function mergeTheme(t)
	local base = THEMES.light
	local out = {}
	for k, v in pairs(base) do out[k] = v end
	for k, v in pairs(t or {}) do out[k] = v end
	return out
end
local function rgbLit(c) -- theme color → "Color3.fromRGB(r, g, b)" literal for generated script source
	local cc = hex(c)
	return string.format("Color3.fromRGB(%d, %d, %d)",
		math.floor(cc.R * 255 + 0.5), math.floor(cc.G * 255 + 0.5), math.floor(cc.B * 255 + 0.5))
end

local ANCHORS = {
	top_left = { Vector2.new(0, 0), UDim2.new(0, 0, 0, 0) },
	top = { Vector2.new(0.5, 0), UDim2.new(0.5, 0, 0, 0) },
	top_right = { Vector2.new(1, 0), UDim2.new(1, 0, 0, 0) },
	left = { Vector2.new(0, 0.5), UDim2.new(0, 0, 0.5, 0) },
	center = { Vector2.new(0.5, 0.5), UDim2.new(0.5, 0, 0.5, 0) },
	right = { Vector2.new(1, 0.5), UDim2.new(1, 0, 0.5, 0) },
	bottom_left = { Vector2.new(0, 1), UDim2.new(0, 0, 1, 0) },
	bottom = { Vector2.new(0.5, 1), UDim2.new(0.5, 0, 1, 0) },
	bottom_right = { Vector2.new(1, 1), UDim2.new(1, 0, 1, 0) },
}
local function applyAnchor(gui, pos)
	local p = pos or {}
	local a = ANCHORS[p.anchor or "center"] or ANCHORS.center
	gui.AnchorPoint = a[1]
	local off = p.offset or { x = 0, y = 0 }
	gui.Position = UDim2.new(a[2].X.Scale, off.x or 0, a[2].Y.Scale, off.y or 0)
end
local function mk(class, props, parent)
	local i = Instance.new(class)
	for k, v in pairs(props or {}) do
		local ok, t = pcall(function() return typeof(i[k]) end)
		if ok then i[k] = decodeProp(t, v, i[k]) end
	end
	i.Parent = parent
	return i
end
local function styleFrame(f, theme)
	f.BackgroundColor3 = hex(theme.bg)
	f.BorderSizePixel = 0
	mk("UICorner", { CornerRadius = UDim.new(0, theme.corner or 10) }, f)
	mk("UIStroke", { Color = hex(theme.stroke or theme.bg), Thickness = theme.strokePx or 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, f)
	mk("UIPadding", { PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, f)
	return f
end
local function mkLabel(text, theme, parent)
	return mk("TextLabel", {
		Text = text or "", BackgroundTransparency = 1, TextColor3 = hex(theme.fg),
		Font = Enum.Font[theme.font] or Enum.Font.GothamBold, TextScaled = true,
		Size = UDim2.new(1, 0, 0, 20),
	}, parent)
end

local Patterns = {}

Patterns.panel = function(parent, cfg, theme)
	local f = styleFrame(mk("Frame", { Name = cfg.name or "Panel", Size = cfg.size or UDim2.new(0.3, 0, 0.4, 0) }), theme)
	mkLabel(cfg.title or "Panel", theme, f).Name = "Title"
	return f
end

Patterns.healthbar = function(parent, cfg, theme)
	local track = styleFrame(mk("Frame", { Name = cfg.name or "HealthBar", Size = cfg.size or UDim2.new(0.25, 0, 0, 24) }), theme)
	local fill = mk("Frame", { Name = "Fill", Size = UDim2.new(cfg.value or 1, 0, 1, 0), BackgroundColor3 = hex(cfg.color or theme.accent), BorderSizePixel = 0 }, track)
	mk("UICorner", { CornerRadius = UDim.new(0, theme.corner or 10) }, fill)
	mkLabel((cfg.value or 1) * 100 .. "/" .. (cfg.max or 100), theme, track).Name = "Label"
	return track
end

Patterns.inventory_grid = function(parent, cfg, theme)
	local slots = cfg.slots or 24
	local cols = cfg.columns or 6
	local rows = math.ceil(slots / cols)
	local f = styleFrame(mk("Frame", { Name = cfg.name or "Inventory", Size = UDim2.new(0.4, 0, 0.5, 0) }), theme)
	mkLabel(cfg.title or "Inventory", theme, f)
	local grid = mk("Frame", { Name = "Grid", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, -30), Position = UDim2.new(0, 0, 0, 28) }, f)
	mk("UIGridLayout", {
		CellSize = UDim2.new(1 / cols, -8, 0.9 / rows, 0),
		CellPadding = UDim2.new(0, 8, 0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, grid)
	for i = 1, slots do
		local slot = mk("ImageButton", {
			Name = "Slot" .. i, LayoutOrder = i,
			BackgroundColor3 = hex(theme.stroke or "#333"), Image = "", AutoButtonColor = true,
		}, grid)
		mk("UICorner", { CornerRadius = UDim.new(0, 6) }, slot)
		mk("UIAspectRatioConstraint", { AspectRatio = 1 }, slot)
		mk("UIStroke", { Color = hex(theme.accent), Thickness = 1 }, slot)
	end
	return f
end

Patterns.dialog = function(parent, cfg, theme)
	local f = styleFrame(mk("Frame", { Name = cfg.name or "Dialog", Size = cfg.size or UDim2.new(0.35, 0, 0.3, 0) }), theme)
	mkLabel(cfg.title or "Dialog", theme, f).Name = "Title"
	local body = mkLabel(cfg.body or "...", theme, f)
	body.Name = "Body"; body.Position = UDim2.new(0, 0, 0, 28); body.Size = UDim2.new(1, 0, 1, -84); body.TextWrapped = true
	local row = mk("Frame", { Name = "Buttons", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36), Position = UDim2.new(0, 0, 1, -40) }, f)
	mk("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8), HorizontalAlignment = Enum.HorizontalAlignment.Center }, row)
	for i, b in ipairs(cfg.buttons or { { text = "OK", id = "ok" } }) do
		local btn = mk("TextButton", {
			Name = "Btn_" .. (b.id or i), Text = b.text or "?", TextColor3 = hex(theme.bg),
			BackgroundColor3 = hex(theme.accent), Font = Enum.Font[theme.font] or Enum.Font.GothamBold,
			TextScaled = true, Size = UDim2.new(0, 96, 1, 0), AutoButtonColor = true,
		}, row)
		mk("UICorner", { CornerRadius = UDim.new(0, 8) }, btn)
	end
	return f
end

Patterns.toast = function(parent, cfg, theme)
	local f = styleFrame(mk("Frame", { Name = cfg.name or "Toast", Size = cfg.size or UDim2.new(0.28, 0, 0, 44) }), theme)
	mkLabel(cfg.text or "Notification", theme, f)
	return f
end

Patterns.button_row = function(parent, cfg, theme)
	local f = mk("Frame", { Name = cfg.name or "ButtonRow", BackgroundTransparency = 1, Size = cfg.size or UDim2.new(0.5, 0, 0, 40) }, parent)
	mk("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8), HorizontalAlignment = Enum.HorizontalAlignment.Center }, f)
	for i, b in ipairs(cfg.buttons or { { text = "Button" } }) do
		local btn = mk("TextButton", {
			Name = "Btn_" .. (b.id or i), Text = b.text or "?", TextColor3 = hex(theme.bg),
			BackgroundColor3 = hex(theme.accent), TextScaled = true,
			Size = UDim2.new(0, b.w or 110, 1, 0), AutoButtonColor = true,
			Font = Enum.Font[theme.font] or Enum.Font.GothamBold,
		}, f)
		mk("UICorner", { CornerRadius = UDim.new(0, 8) }, btn)
	end
	return f
end

Patterns.stat_label = function(parent, cfg, theme)
	local f = styleFrame(mk("Frame", { Name = cfg.name or "Stat", Size = cfg.size or UDim2.new(0.16, 0, 0, 34) }), theme)
	mkLabel((cfg.label or "Stat") .. ": " .. tostring(cfg.value or 0), theme, f)
	return f
end

Patterns.shop_card = function(parent, cfg, theme)
	local f = styleFrame(mk("Frame", { Name = cfg.name or "ShopCard", Size = cfg.size or UDim2.new(0.18, 0, 0.26, 0) }), theme)
	local img = mk("ImageLabel", { Name = "Icon", BackgroundTransparency = 1, Image = cfg.image or "", Size = UDim2.new(0.8, 0, 0.55, 0), Position = UDim2.new(0.1, 0, 0, 8), ScaleType = Enum.ScaleType.Fit }, f)
	mk("UIAspectRatioConstraint", { AspectRatio = 1 }, img)
	local price = mkLabel(cfg.price or "100", theme, f)
	price.Name = "Price"; price.Position = UDim2.new(0, 0, 0.62, 0); price.Size = UDim2.new(1, 0, 0, 22)
	local btn = mk("TextButton", {
		Name = "Buy", Text = cfg.button_text or "Buy", TextColor3 = hex(theme.bg),
		BackgroundColor3 = hex(theme.accent), TextScaled = true,
		Size = UDim2.new(0.8, 0, 0, 30), Position = UDim2.new(0.1, 0, 1, -38), AutoButtonColor = true,
		Font = Enum.Font[theme.font] or Enum.Font.GothamBold,
	}, f)
	mk("UICorner", { CornerRadius = UDim.new(0, 8) }, btn)
	return f
end

Patterns.menu_list = function(parent, cfg, theme)
	local f = styleFrame(mk("Frame", { Name = cfg.name or "Menu", Size = cfg.size or UDim2.new(0.24, 0, 0.5, 0) }), theme)
	mkLabel(cfg.title or "Menu", theme, f)
	local sf = mk("ScrollingFrame", {
		Name = "List", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, -30),
		Position = UDim2.new(0, 0, 0, 28), ScrollBarThickness = 4,
		CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, f)
	mk("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, sf)
	for i, item in ipairs(cfg.items or { "Item 1", "Item 2" }) do
		local b = mk("TextButton", {
			Name = "Item" .. i, Text = tostring(item), TextColor3 = hex(theme.fg),
			BackgroundColor3 = hex(theme.stroke or "#333"), TextScaled = true,
			Size = UDim2.new(1, 0, 0, 32), LayoutOrder = i, AutoButtonColor = true,
			Font = Enum.Font[theme.font] or Enum.Font.Gotham,
		}, sf)
		mk("UICorner", { CornerRadius = UDim.new(0, 6) }, b)
	end
	return f
end

Patterns.progress = function(parent, cfg, theme)
	local f = styleFrame(mk("Frame", { Name = cfg.name or "Progress", Size = cfg.size or UDim2.new(0.3, 0, 0, 30) }), theme)
	local track = mk("Frame", { Name = "Track", BackgroundColor3 = hex(theme.stroke or "#333"), Size = UDim2.new(1, 0, 0, 12), Position = UDim2.new(0, 0, 0.7, 0), BorderSizePixel = 0 }, f)
	mk("UICorner", { CornerRadius = UDim.new(0, 6) }, track)
	local fill = mk("Frame", { Name = "Fill", BackgroundColor3 = hex(theme.accent), Size = UDim2.new(cfg.value or 0.5, 0, 1, 0), BorderSizePixel = 0 }, track)
	mk("UICorner", { CornerRadius = UDim.new(0, 6) }, fill)
	mkLabel(cfg.label or "Level", theme, f)
	return f
end

Patterns.tabbed_panel = function(parent, cfg, theme)
	local f = styleFrame(mk("Frame", { Name = cfg.name or "TabbedPanel", Size = cfg.size or UDim2.new(0.4, 0, 0.45, 0) }), theme)
	local tabs = mk("Frame", { Name = "Tabs", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 32) }, f)
	mk("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4) }, tabs)
	local body = mk("Frame", { Name = "Body", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, -36), Position = UDim2.new(0, 0, 0, 34) }, f)
	for i, t in ipairs(cfg.tabs or { "Tab 1", "Tab 2" }) do
		local active = i == 1
		local b = mk("TextButton", {
			Name = "Tab_" .. i, Text = t, TextScaled = true, AutoButtonColor = true,
			TextColor3 = hex(active and theme.bg or theme.fg),
			BackgroundColor3 = hex(active and theme.accent or (theme.stroke or "#333")),
			Size = UDim2.new(0, 90, 1, 0), Font = Enum.Font[theme.font] or Enum.Font.GothamBold,
		}, tabs)
		mk("UICorner", { CornerRadius = UDim.new(0, 6) }, b)
		local page = mk("Frame", { Name = "Page_" .. i, BackgroundTransparency = 1, Visible = active, Size = UDim2.new(1, 0, 1, 0) }, body)
		mkLabel(t .. " content", theme, page)
	end
	return f
end

Patterns.hud_stack = function(parent, cfg, theme)
	local f = mk("Frame", { Name = cfg.name or "HUD", BackgroundTransparency = 1, Size = UDim2.new(0.22, 0, 0.4, 0) }, parent)
	mk("UIListLayout", { Padding = UDim.new(0, 8), VerticalAlignment = Enum.VerticalAlignment.Top }, f)
	for i, stat in ipairs(cfg.stats or { { label = "HP", value = 100 }, { label = "Gold", value = 0 } }) do
		local s = styleFrame(mk("Frame", { Name = "Stat" .. i, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = i }), theme)
		mkLabel(stat.label .. ": " .. tostring(stat.value), theme, s)
	end
	return f
end

Patterns.slider = function(parent, cfg, theme)
	local f = styleFrame(mk("Frame", { Name = cfg.name or "Slider", Size = cfg.size or UDim2.new(0.3, 0, 0, 44) }), theme)
	local lbl = mkLabel((cfg.label or "Value") .. ": " .. tostring(math.floor((cfg.value or 0.5) * 100 + 0.5)), theme, f)
	lbl.Name = "Label"
	local track = mk("Frame", { Name = "Track", BackgroundColor3 = hex(theme.stroke or "#333"),
		Size = UDim2.new(1, -16, 0, 8), Position = UDim2.new(0, 8, 1, -18), BorderSizePixel = 0 }, f)
	mk("UICorner", { CornerRadius = UDim.new(1, 0) }, track)
	local fill = mk("Frame", { Name = "Fill", BackgroundColor3 = hex(theme.accent),
		Size = UDim2.new(cfg.value or 0.5, 0, 1, 0), BorderSizePixel = 0 }, track)
	mk("UICorner", { CornerRadius = UDim.new(1, 0) }, fill)
	local knob = mk("Frame", { Name = "Knob", AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = hex(theme.fg),
		Size = UDim2.new(0, 16, 0, 16), Position = UDim2.new(cfg.value or 0.5, 0, 0.5, 0), BorderSizePixel = 0 }, track)
	mk("UICorner", { CornerRadius = UDim.new(1, 0) }, knob)
	mk("UIStroke", { Color = hex(theme.accent), Thickness = theme.strokePx or 1 }, knob)
	mk("BindableEvent", { Name = "OnChanged" }, f)
	local src = [=[
local root = script.Parent
local track = root:WaitForChild("Track")
local fill = track:WaitForChild("Fill")
local knob = track:WaitForChild("Knob")
local lbl = root:WaitForChild("Label")
local ev = root:WaitForChild("OnChanged")
local UIS = game:GetService("UserInputService")
local base = lbl.Text:gsub("%s*:.*", "")
local dragging = false
local function setAt(x)
	local a = math.clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
	fill.Size = UDim2.new(a, 0, 1, 0)
	knob.Position = UDim2.new(a, 0, 0.5, 0)
	lbl.Text = base .. ": " .. math.floor(a * 100 + 0.5)
	ev:Fire(a)
end
track.InputBegan:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		setAt(i.Position.X)
	end
end)
UIS.InputChanged:Connect(function(i)
	if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then setAt(i.Position.X) end
end)
UIS.InputEnded:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
end)
]=]
	mk("LocalScript", { Name = "RbxSlider", Source = src }, f)
	return f
end

Patterns.toggle = function(parent, cfg, theme)
	local f = mk("Frame", { Name = cfg.name or "Toggle", BackgroundTransparency = 1, Size = cfg.size or UDim2.new(0.14, 0, 0, 32) }, parent)
	local lbl = mkLabel(cfg.label or "Toggle", theme, f)
	lbl.Size = UDim2.new(0.6, 0, 1, 0); lbl.TextXAlignment = Enum.TextXAlignment.Left
	local track = mk("TextButton", { Name = "Track", Text = "", AutoButtonColor = false,
		BackgroundColor3 = cfg.value and hex(theme.accent) or hex(theme.stroke or "#333"),
		Size = UDim2.new(0.35, 0, 0.8, 0), Position = UDim2.new(0.62, 0, 0.1, 0) }, f)
	mk("UICorner", { CornerRadius = UDim.new(1, 0) }, track)
	local knob = mk("Frame", { Name = "Knob", AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = hex(theme.fg),
		Size = UDim2.new(1, 0, 0.75, 0), Position = UDim2.new(cfg.value and 0.78 or 0.22, 0, 0.5, 0), BorderSizePixel = 0 }, track)
	mk("UICorner", { CornerRadius = UDim.new(1, 0) }, knob)
	mk("UIAspectRatioConstraint", { AspectRatio = 1 }, knob)
	mk("BoolValue", { Name = "IsOn", Value = cfg.value or false }, f)
	local src = string.format([=[
local root = script.Parent
local track = root:WaitForChild("Track")
local knob = track:WaitForChild("Knob")
local isOn = root:WaitForChild("IsOn")
local TS = game:GetService("TweenService")
local ON, OFF = %s, %s
local function render(instant)
	local t = isOn.Value and 0.78 or 0.22
	local c = isOn.Value and ON or OFF
	if instant then
		knob.Position = UDim2.new(t, 0, 0.5, 0)
		track.BackgroundColor3 = c
	else
		TS:Create(knob, TweenInfo.new(0.18, Enum.EasingStyle.Quad), { Position = UDim2.new(t, 0, 0.5, 0) }):Play()
		TS:Create(track, TweenInfo.new(0.18), { BackgroundColor3 = c }):Play()
	end
end
track.MouseButton1Click:Connect(function() isOn.Value = not isOn.Value end)
isOn.Changed:Connect(function() render(false) end)
render(true)
]=], rgbLit(theme.accent), rgbLit(theme.stroke or "#333"))
	mk("LocalScript", { Name = "RbxToggle", Source = src }, f)
	return f
end

Patterns.dropdown = function(parent, cfg, theme)
	local items = cfg.items or { "Option 1", "Option 2", "Option 3" }
	local f = styleFrame(mk("Frame", { Name = cfg.name or "Dropdown", Size = cfg.size or UDim2.new(0.2, 0, 0, 36), ClipsDescendants = false }), theme)
	local head = mk("TextButton", { Name = "Header", Text = tostring(cfg.placeholder or items[1] or "Select"),
		TextColor3 = hex(theme.fg), BackgroundTransparency = 1, TextScaled = true, ZIndex = 5,
		Size = UDim2.new(1, 0, 0, 34), AutoButtonColor = false, Font = Enum.Font[theme.font] or Enum.Font.GothamBold }, f)
	local list = mk("ScrollingFrame", { Name = "List", Visible = false, ZIndex = 20,
		BackgroundColor3 = hex(theme.bg), BorderSizePixel = 0, ClipsDescendants = true,
		Size = UDim2.new(1, 0, 0, math.min(#items, 6) * 32), Position = UDim2.new(0, 0, 1, 2),
		ScrollBarThickness = 4, CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y }, f)
	mk("UICorner", { CornerRadius = UDim.new(0, theme.corner or 8) }, list)
	mk("UIStroke", { Color = hex(theme.stroke or theme.bg), Thickness = theme.strokePx or 1 }, list)
	mk("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, list)
	for i, it in ipairs(items) do
		local b = mk("TextButton", { Name = "Item" .. i, Text = tostring(it), TextColor3 = hex(theme.fg),
			BackgroundColor3 = hex(theme.stroke or "#333"), TextScaled = true, ZIndex = 20,
			Size = UDim2.new(1, 0, 0, 30), LayoutOrder = i, AutoButtonColor = true,
			Font = Enum.Font[theme.font] or Enum.Font.Gotham }, list)
		mk("UICorner", { CornerRadius = UDim.new(0, 5) }, b)
	end
	mk("BindableEvent", { Name = "OnChanged" }, f)
	local src = [=[
local root = script.Parent
local head = root:WaitForChild("Header")
local list = root:WaitForChild("List")
local ev = root:WaitForChild("OnChanged")
head.MouseButton1Click:Connect(function() list.Visible = not list.Visible end)
for _, b in ipairs(list:GetChildren()) do
	if b:IsA("GuiButton") then
		b.MouseButton1Click:Connect(function()
			head.Text = b.Text
			list.Visible = false
			ev:Fire(b.Text)
		end)
	end
end
]=]
	mk("LocalScript", { Name = "RbxDropdown", Source = src }, f)
	return f
end

Patterns.radial_menu = function(parent, cfg, theme)
	local items = cfg.items or { "A", "B", "C", "D" }
	local n = math.max(#items, 1)
	local arc = math.rad(cfg.arc or 360)
	local step = cfg.arc and (n > 1 and arc / (n - 1) or 0) or (math.pi * 2 / n)
	local a0 = -math.pi / 2 - (cfg.arc and arc / 2 or 0)
	local f = mk("Frame", { Name = cfg.name or "RadialMenu", BackgroundTransparency = 1,
		Size = cfg.size or UDim2.new(0.32, 0, 0.32, 0), Visible = cfg.visible or false }, parent)
	mk("UIAspectRatioConstraint", { AspectRatio = 1 }, f)
	local r = cfg.radius or 0.36
	for i, it in ipairs(items) do
		local a = a0 + (i - 1) * step
		local b = mk("TextButton", { Name = "Rad" .. i, Text = tostring(it), TextScaled = true, ZIndex = 5,
			AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5 + math.cos(a) * r, 0, 0.5 + math.sin(a) * r, 0),
			Size = UDim2.new(0.2, 0, 0.2, 0), BackgroundColor3 = hex(theme.accent), TextColor3 = hex(theme.bg),
			Font = Enum.Font[theme.font] or Enum.Font.GothamBold, AutoButtonColor = true }, f)
		mk("UICorner", { CornerRadius = UDim.new(1, 0) }, b)
		mk("UIStroke", { Color = hex(theme.stroke or theme.bg), Thickness = theme.strokePx or 1 }, b)
		mk("UIAspectRatioConstraint", { AspectRatio = 1 }, b)
	end
	local src = [=[
local root = script.Parent
local TS = game:GetService("TweenService")
local function pop()
	for _, b in ipairs(root:GetChildren()) do
		if b:IsA("GuiObject") then
			local final = b.Size
			b.Size = UDim2.new(0, 0, 0, 0)
			TS:Create(b, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Size = final }):Play()
		end
	end
end
root:GetPropertyChangedSignal("Visible"):Connect(function() if root.Visible then pop() end end)
if root.Visible then task.defer(pop) end
]=]
	mk("LocalScript", { Name = "RbxRadial", Source = src }, f)
	return f
end

Patterns.tabs_bar = function(parent, cfg, theme)
	local tabs = cfg.tabs or { "Tab 1", "Tab 2" }
	local f = styleFrame(mk("Frame", { Name = cfg.name or "TabsBar", Size = cfg.size or UDim2.new(0.4, 0, 0.45, 0) }), theme)
	local bar = mk("Frame", { Name = "Bar", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 32) }, f)
	mk("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, bar)
	local body = mk("Frame", { Name = "Pages", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, -38), Position = UDim2.new(0, 0, 0, 36) }, f)
	for i, t in ipairs(tabs) do
		local b = mk("TextButton", { Name = "Tab_" .. i, Text = tostring(t), TextScaled = true, AutoButtonColor = true,
			TextColor3 = hex(i == 1 and theme.bg or theme.fg), LayoutOrder = i,
			BackgroundColor3 = hex(i == 1 and theme.accent or (theme.stroke or "#333")),
			Size = UDim2.new(0, 90, 1, 0), Font = Enum.Font[theme.font] or Enum.Font.GothamBold }, bar)
		mk("UICorner", { CornerRadius = UDim.new(0, 6) }, b)
		local page = mk("ScrollingFrame", { Name = "Page_" .. i, BackgroundTransparency = 1, Visible = i == 1,
			Size = UDim2.new(1, 0, 1, 0), ScrollBarThickness = 4,
			CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y }, body)
		mkLabel(tostring(t) .. " content", theme, page)
	end
	local src = string.format([=[
local root = script.Parent
local bar = root:WaitForChild("Bar")
local body = root:WaitForChild("Pages")
local ON, OFF = %s, %s
local ON_T, OFF_T = %s, %s
for _, b in ipairs(bar:GetChildren()) do
	if b:IsA("GuiButton") then
		b.MouseButton1Click:Connect(function()
			local idx = b.Name:match("%%d+")
			for _, p in ipairs(body:GetChildren()) do
				if p:IsA("GuiObject") then p.Visible = p.Name == "Page_" .. idx end
			end
			for _, t in ipairs(bar:GetChildren()) do
				if t:IsA("GuiButton") then
					local sel = t == b
					t.BackgroundColor3 = sel and ON or OFF
					t.TextColor3 = sel and ON_T or OFF_T
				end
			end
		end)
	end
end
]=], rgbLit(theme.accent), rgbLit(theme.stroke or "#333"), rgbLit(theme.bg), rgbLit(theme.fg))
	mk("LocalScript", { Name = "RbxTabs", Source = src }, f)
	return f
end

Patterns.keybind_hint = function(parent, cfg, theme)
	local binds = cfg.binds or { { key = "E", action = "Interact" }, { key = "Q", action = "Menu" } }
	local f = styleFrame(mk("Frame", { Name = cfg.name or "Keybinds",
		Size = cfg.size or UDim2.new(0.18, 0, 0, #binds * 32 + 8) }), theme)
	mk("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, f)
	for i, b in ipairs(binds) do
		local row = mk("Frame", { Name = "Bind" .. i, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 26), LayoutOrder = i }, f)
		local cap = mk("TextLabel", { Name = "Key", Text = tostring(b.key or "?"), TextColor3 = hex(theme.fg),
			BackgroundColor3 = hex(theme.stroke or "#333"), TextScaled = false, TextSize = 15,
			Size = UDim2.new(0, 26, 1, 0), Font = Enum.Font.Code }, row)
		mk("UICorner", { CornerRadius = UDim.new(0, 6) }, cap)
		mk("UIStroke", { Color = hex(theme.accent), Thickness = 1 }, cap)
		local act = mkLabel(tostring(b.action or ""), theme, row)
		act.Position = UDim2.new(0, 34, 0, 0); act.Size = UDim2.new(1, -34, 1, 0)
		act.TextXAlignment = Enum.TextXAlignment.Left
	end
	return f
end

Patterns.loading_screen = function(parent, cfg, theme)
	local f = mk("Frame", { Name = cfg.name or "LoadingScreen", Size = UDim2.new(1, 0, 1, 0),
		BackgroundColor3 = hex(theme.bg), BorderSizePixel = 0, ZIndex = 100, Active = true }, parent)
	local logo = mkLabel(cfg.title or "LOADING", theme, f)
	logo.Name = "Logo"; logo.Size = UDim2.new(0.6, 0, 0.09, 0); logo.Position = UDim2.new(0.2, 0, 0.32, 0); logo.ZIndex = 101
	local track = mk("Frame", { Name = "Track", BackgroundColor3 = hex(theme.stroke or "#333"),
		Size = UDim2.new(0.4, 0, 0, 10), Position = UDim2.new(0.3, 0, 0.5, 0), BorderSizePixel = 0, ZIndex = 101 }, f)
	mk("UICorner", { CornerRadius = UDim.new(1, 0) }, track)
	local fill = mk("Frame", { Name = "Fill", BackgroundColor3 = hex(theme.accent),
		Size = UDim2.new(0, 0, 1, 0), BorderSizePixel = 0, ZIndex = 101 }, track)
	mk("UICorner", { CornerRadius = UDim.new(1, 0) }, fill)
	local tips = cfg.tips or { "Tip: explore the world!", "Tip: complete quests for rewards" }
	local tip = mkLabel(tostring(tips[1]), theme, f)
	tip.Name = "Tip"; tip.Position = UDim2.new(0, 0, 0.56, 0); tip.Size = UDim2.new(1, 0, 0, 22); tip.ZIndex = 101
	local lit = {}
	for _, t in ipairs(tips) do table.insert(lit, string.format("%q", tostring(t))) end
	local src = string.format([=[
local root = script.Parent
local tips = { %s }
local tip = root:WaitForChild("Tip")
local fill = root:WaitForChild("Track"):WaitForChild("Fill")
task.spawn(function()
	local i = 1
	while root.Parent do
		task.wait(4)
		i = (i %% #tips) + 1
		tip.Text = tips[i]
	end
end)
task.spawn(function()
	local t = 0
	while t < 1 and root.Parent do
		t += task.wait() / %d
		fill.Size = UDim2.new(math.min(t, 1), 0, 1, 0)
	end
end)
]=], table.concat(lit, ", "), cfg.duration or 10)
	mk("LocalScript", { Name = "RbxLoading", Source = src }, f)
	return f
end

Patterns.minimap_frame = function(parent, cfg, theme)
	local f = mk("Frame", { Name = cfg.name or "Minimap", Size = cfg.size or UDim2.new(0.16, 0, 0.16, 0),
		BackgroundColor3 = hex(theme.stroke or "#222"), BorderSizePixel = 0, ClipsDescendants = true }, parent)
	mk("UICorner", { CornerRadius = UDim.new(1, 0) }, f)
	mk("UIStroke", { Color = hex(theme.accent), Thickness = theme.strokePx or 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, f)
	mk("UIAspectRatioConstraint", { AspectRatio = 1 }, f)
	local img = mk("ImageLabel", { Name = "Map", Image = cfg.image or "", BackgroundTransparency = 0.6,
		BackgroundColor3 = hex(theme.bg), Size = UDim2.new(1, 0, 1, 0), ScaleType = Enum.ScaleType.Crop }, f)
	mk("UICorner", { CornerRadius = UDim.new(1, 0) }, img)
	return f
end

Patterns.game_hud = function(parent, cfg, theme)
	local f = mk("Frame", { Name = cfg.name or "GameHUD", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, 0) }, parent)
	local vitals = mk("Frame", { Name = "Vitals", BackgroundTransparency = 1,
		Size = UDim2.new(0.24, 0, 0.09, 0), Position = UDim2.new(0.02, 0, 0.9, 0) }, f)
	local function bar(name, y, col, val)
		local tr = mk("Frame", { Name = name, BackgroundColor3 = hex(theme.stroke or "#333"),
			Size = UDim2.new(1, 0, 0.42, 0), Position = UDim2.new(0, 0, y, 0), BorderSizePixel = 0 }, vitals)
		mk("UICorner", { CornerRadius = UDim.new(0, 6) }, tr)
		local fl = mk("Frame", { Name = "Fill", BackgroundColor3 = col, Size = UDim2.new(val or 1, 0, 1, 0), BorderSizePixel = 0 }, tr)
		mk("UICorner", { CornerRadius = UDim.new(0, 6) }, fl)
		local l = mkLabel(name, theme, tr)
		l.Size = UDim2.new(1, 0, 1, 0); l.TextXAlignment = Enum.TextXAlignment.Left
		l.Position = UDim2.new(0, 8, 0, 0); l.ZIndex = 3
	end
	bar("Health", 0, Color3.fromRGB(220, 70, 70), cfg.health or 1)
	bar("Stamina", 0.55, Color3.fromRGB(90, 200, 110), cfg.stamina or 1)
	local mm = Patterns.minimap_frame(f, { name = "Minimap", image = cfg.minimap_image }, theme)
	mm.Position = UDim2.new(0.82, 0, 0.78, 0)
	local hb = mk("Frame", { Name = "Hotbar", BackgroundTransparency = 1,
		Size = UDim2.new(0.32, 0, 0.08, 0), Position = UDim2.new(0.34, 0, 0.91, 0) }, f)
	mk("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, hb)
	for i = 1, 6 do
		local slot = mk("ImageLabel", { Name = "Slot" .. i, BackgroundColor3 = hex(theme.bg),
			Image = "", Size = UDim2.new(1 / 6, -7, 1, 0), LayoutOrder = i }, hb)
		mk("UICorner", { CornerRadius = UDim.new(0, 6) }, slot)
		mk("UIStroke", { Color = hex(theme.accent), Thickness = 1 }, slot)
		local k = mkLabel(tostring(i), theme, slot)
		k.Size = UDim2.new(0.4, 0, 0.45, 0); k.Position = UDim2.new(0.03, 0, 0.02, 0); k.ZIndex = 3
	end
	return f
end

Commands.build_gui = function(args)
	local parentPath = args.parent_path or "StarterGui"
	local parent, perr = resolvePath(parentPath)
	if not parent then error(perr) end
	local screenGui = parent
	if not parent:IsA("ScreenGui") and not parent:IsA("GuiObject") then
		screenGui = parent:FindFirstChild("RbxGui")
			or mk("ScreenGui", { Name = "RbxGui", ResetOnSpawn = false, IgnoreGuiInset = false }, parent)
	end
	local theme = mergeTheme(args.theme)
	local patFn = Patterns[args.pattern]
	if not patFn then error("unknown pattern '" .. tostring(args.pattern) .. "'. Options: panel, healthbar, inventory_grid, dialog, toast, button_row, stat_label, shop_card, menu_list, progress, tabbed_panel, hud_stack, slider, toggle, dropdown, radial_menu, tabs_bar, keybind_hint, loading_screen, game_hud, minimap_frame") end
	waypoint("build_gui " .. args.pattern)
	local root = patFn(screenGui, args.config or {}, theme)
	root.Parent = screenGui
	if args.name then root.Name = args.name end
	applyAnchor(root, args.position)
	local kids = {}
	for _, c in ipairs(root:GetDescendants()) do table.insert(kids, instancePath(c)) end
	return { root_path = instancePath(root), pattern = args.pattern, children = kids }
end

Commands.gui_theme = function(args)
	local root, err = resolvePath(args.path)
	if not root then error(err) end
	local theme = mergeTheme(args.theme)
	waypoint("gui_theme " .. instancePath(root))
	local changed = 0
	local function walk(inst)
		if inst:IsA("Frame") then inst.BackgroundColor3 = hex(theme.bg); changed += 1
		elseif inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox") then
			inst.TextColor3 = hex(theme.fg); changed += 1
			pcall(function() inst.Font = Enum.Font[theme.font] end)
		elseif inst:IsA("UIStroke") then inst.Color = hex(theme.accent); changed += 1
		elseif inst:IsA("UICorner") then inst.CornerRadius = UDim.new(0, theme.corner or 10); changed += 1
		end
		for _, c in ipairs(inst:GetChildren()) do walk(c) end
	end
	walk(root)
	return { themed = changed }
end

Commands.wrap_image = function(args)
	local parent, perr = resolvePath(args.parent_path or "StarterGui")
	if not parent then error(perr) end
	local screenGui = parent:IsA("ScreenGui") and parent or parent:FindFirstChild("RbxGuiImages") or mk("ScreenGui", { Name = "RbxGuiImages", ResetOnSpawn = false }, parent)
	waypoint("wrap_image")
	local img = mk("ImageLabel", {
		Name = args.name or "Image", BackgroundTransparency = 1,
		Image = args.image, ScaleType = args.nine_slice and Enum.ScaleType.Slice or Enum.ScaleType.Fit,
		Size = UDim2.new(0.15, 0, 0.15, 0),
	}, screenGui)
	if args.nine_slice and args.nine_slice.sliceCenter then
		local sc = args.nine_slice.sliceCenter
		img.SliceCenter = Rect.new(sc.x0 or 0, sc.y0 or 0, sc.x1 or 0, sc.y1 or 0)
		img.SliceScale = args.nine_slice.scale or 1
	end
	if args.aspect then mk("UIAspectRatioConstraint", { AspectRatio = args.aspect }, img) end
	applyAnchor(img, args.position)
	return { path = instancePath(img) }
end

-- edit-mode tweens don't tick: every animation/behavior ships as a LocalScript
Commands.gui_animate = function(args)
	local root, err = resolvePath(args.path)
	if not root then error(err) end
	if not root:IsA("GuiObject") then error(instancePath(root) .. " is not a GuiObject") end
	local preset = args.preset or "fade"
	local props = args.props or {}
	local dir = props.direction or args.direction or "left"
	local dur = tonumber(props.duration) or 0.4
	waypoint("gui_animate " .. preset)
	local function u2(u) return string.format("UDim2.new(%g, %g, %g, %g)", u.X.Scale, u.X.Offset, u.Y.Scale, u.Y.Offset) end
	local SRCS = {}
	SRCS.slide_in = string.format([=[
local gui = script.Parent
local TS = game:GetService("TweenService")
local base = %s
local off = {
	left = UDim2.new(-1.2, 0, base.Y.Scale, base.Y.Offset), right = UDim2.new(1.2, 0, base.Y.Scale, base.Y.Offset),
	top = UDim2.new(base.X.Scale, base.X.Offset, -1.2, 0), bottom = UDim2.new(base.X.Scale, base.X.Offset, 1.2, 0),
}
gui.Position = off[%q] or off.left
local t = TS:Create(gui, TweenInfo.new(%g, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = base })
t.Completed:Connect(function() script:Destroy() end)
t:Play()
]=], u2(root.Position), dir, dur)
	SRCS.fade = [=[
local gui = script.Parent
local TS = game:GetService("TweenService")
local props = {}
pcall(function() props.BackgroundTransparency = gui.BackgroundTransparency gui.BackgroundTransparency = 1 end)
pcall(function() props.TextTransparency = gui.TextTransparency gui.TextTransparency = 1 end)
pcall(function() props.ImageTransparency = gui.ImageTransparency gui.ImageTransparency = 1 end)
local t = TS:Create(gui, TweenInfo.new(0.5, Enum.EasingStyle.Quad), props)
t.Completed:Connect(function() script:Destroy() end)
t:Play()
]=]
	SRCS.bounce = string.format([=[
local gui = script.Parent
local TS = game:GetService("TweenService")
local baseP, baseS, anc = %s, %s, gui.AnchorPoint
local function sized(m) return UDim2.new(baseS.X.Scale * m, baseS.X.Offset * m, baseS.Y.Scale * m, baseS.Y.Offset * m) end
local function posFor(m) return UDim2.new(baseP.X.Scale - (0.5 - anc.X) * (m - 1) * baseS.X.Scale, baseP.X.Offset - (0.5 - anc.X) * (m - 1) * baseS.X.Offset,
	baseP.Y.Scale - (0.5 - anc.Y) * (m - 1) * baseS.Y.Scale, baseP.Y.Offset - (0.5 - anc.Y) * (m - 1) * baseS.Y.Offset) end
task.spawn(function()
	for _ = 1, 2 do
		local t1 = TS:Create(gui, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = sized(1.15), Position = posFor(1.15) })
		t1:Play() t1.Completed:Wait()
		local t2 = TS:Create(gui, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Size = baseS, Position = baseP })
		t2:Play() t2.Completed:Wait()
	end
	script:Destroy()
end)
]=], u2(root.Position), u2(root.Size))
	SRCS.pulse = string.format([=[
local gui = script.Parent
local TS = game:GetService("TweenService")
local baseP, baseS, anc = %s, %s, gui.AnchorPoint
local m = 1.06
local target = UDim2.new(baseS.X.Scale * m, baseS.X.Offset * m, baseS.Y.Scale * m, baseS.Y.Offset * m)
local pos = UDim2.new(baseP.X.Scale - (0.5 - anc.X) * (m - 1) * baseS.X.Scale, baseP.X.Offset - (0.5 - anc.X) * (m - 1) * baseS.X.Offset,
	baseP.Y.Scale - (0.5 - anc.Y) * (m - 1) * baseS.Y.Scale, baseP.Y.Offset - (0.5 - anc.Y) * (m - 1) * baseS.Y.Offset)
TS:Create(gui, TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Size = target, Position = pos }):Play()
]=], u2(root.Position), u2(root.Size))
	local src = SRCS[preset]
	if not src then error("unknown preset '" .. tostring(preset) .. "' — options: slide_in, fade, bounce, pulse") end
	local name = "RbxFx_" .. preset
	local old = root:FindFirstChild(name)
	if old then old:Destroy() end
	local s = Instance.new("LocalScript")
	s.Name = name; s.Source = src; s.Parent = root
	return { path = instancePath(s), preset = preset }
end

local GUI_BEHAVIORS = {
	draggable = [=[
local gui = script.Parent
local UIS = game:GetService("UserInputService")
local dragging, dragStart, startPos
gui.InputBegan:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		dragStart = i.Position
		startPos = gui.Position
	end
end)
UIS.InputChanged:Connect(function(i)
	if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
		local d = i.Position - dragStart
		gui.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
	end
end)
UIS.InputEnded:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
end)
]=],
	hover_fx = [=[
local gui = script.Parent
local TS = game:GetService("TweenService")
local baseS, baseT = gui.Size, gui.BackgroundTransparency
local function sized(m) return UDim2.new(baseS.X.Scale * m, baseS.X.Offset * m, baseS.Y.Scale * m, baseS.Y.Offset * m) end
gui.MouseEnter:Connect(function()
	TS:Create(gui, TweenInfo.new(0.15, Enum.EasingStyle.Quad), { Size = sized(1.05), BackgroundTransparency = math.max(baseT - 0.1, 0) }):Play()
end)
gui.MouseLeave:Connect(function()
	TS:Create(gui, TweenInfo.new(0.15, Enum.EasingStyle.Quad), { Size = baseS, BackgroundTransparency = baseT }):Play()
end)
]=],
	click_scale = [=[
local gui = script.Parent
local TS = game:GetService("TweenService")
local baseS = gui.Size
local function sized(m) return UDim2.new(baseS.X.Scale * m, baseS.X.Offset * m, baseS.Y.Scale * m, baseS.Y.Offset * m) end
local down = false
gui.InputBegan:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
		down = true
		TS:Create(gui, TweenInfo.new(0.08), { Size = sized(0.92) }):Play()
	end
end)
gui.InputEnded:Connect(function(i)
	if down and (i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch) then
		down = false
		TS:Create(gui, TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Size = baseS }):Play()
	end
end)
gui.MouseLeave:Connect(function()
	if down then down = false TS:Create(gui, TweenInfo.new(0.15), { Size = baseS }):Play() end
end)
]=],
}
Commands.gui_component = function(args)
	local root, err = resolvePath(args.path)
	if not root then error(err) end
	if not root:IsA("GuiObject") then error(instancePath(root) .. " is not a GuiObject") end
	local behavior = args.behavior or ""
	local src = GUI_BEHAVIORS[behavior]
	if not src then error("unknown behavior '" .. tostring(behavior) .. "' — options: draggable, hover_fx, click_scale") end
	waypoint("gui_component " .. behavior)
	local name = "RbxFx_" .. behavior
	local old = root:FindFirstChild(name)
	if old then old:Destroy() end
	local s = Instance.new("LocalScript")
	s.Name = name; s.Source = src; s.Parent = root
	return { path = instancePath(s), behavior = behavior }
end

----------------------------------------------------------------------
-- terrain — chunked WriteVoxels, fBm + ridged mountains
----------------------------------------------------------------------
local MAT_PROFILES = {
	alpine = { low = "Grass", mid = "Rock", high = "Snow", under = "Ground" },
	desert = { low = "Sand", mid = "Sandstone", high = "Rock", under = "Ground" },
	volcanic = { low = "Basalt", mid = "Rock", high = "CrackedLava", under = "Basalt" },
	plains = { low = "Grass", mid = "Grass", high = "Rock", under = "Ground" },
}
local function fbm(x, z, seed, octaves, ridge)
	local amp, freq, sum, norm = 1, 0.005, 0, 0
	for o = 1, octaves do
		local n = math.noise(x * freq, z * freq, seed + o * 17)
		if ridge and ridge > 0 then n = 1 - math.abs(n) end
		sum += n * amp
		norm += amp
		amp *= 0.5
		freq *= 2.1
	end
	sum /= norm
	if ridge and ridge > 0 then sum = sum ^ (1 + ridge) end
	return sum
end
Commands.terrain_generate = function(args)
	local size = args.size or { x = 512, z = 512 }
	local cx = (args.center and args.center.x) or 0
	local cz = (args.center and args.center.z) or 0
	local baseY = args.base_height or 8
	local mtnH = args.mountain_height or 160
	local rough = args.roughness or 1.0
	local ridge = args.ridge or 0.7
	local seed = args.seed or math.random(1, 1e6)
	local water = args.water_level
	local mats = MAT_PROFILES[args.materials or "alpine"] or MAT_PROFILES.alpine
	local octaves = math.clamp(math.floor(3 + rough * 3), 3, 7)
	local flat = args.flatten_zones or {}
	local terrain = workspace.Terrain
	waypoint("terrain_generate")

	local CELL = 4 -- WriteVoxels resolution: 4 studs per cell
	local CHUNK = 64 -- cells per axis per write
	local chunks = 0
	local minCellX = math.floor((cx - size.x / 2) / CELL)
	local minCellZ = math.floor((cz - size.z / 2) / CELL)
	local cellsX = math.ceil(size.x / CELL)
	local cellsZ = math.ceil(size.z / CELL)
	local maxY = baseY + mtnH
	local cellsY = math.ceil((maxY + CELL * 2) / CELL)
	local y0 = 0

	local function heightAt(wx, wz)
		local h = baseY + mtnH * fbm(wx, wz, seed, octaves, ridge)
		for _, z in ipairs(flat) do
			local dx, dz = wx - z.x, wz - z.z
			local dist = math.sqrt(dx * dx + dz * dz)
			if dist < z.r then
				local blend = math.clamp(dist / z.r, 0, 1)
				h = z.h * (1 - blend) + h * blend * 0.5 + h * 0.5 * blend
			end
		end
		return h
	end
	local function matFor(h, slope)
		if h < baseY - 4 then return Enum.Material[mats.under] or Enum.Material.Ground end
		if slope > 0.55 then return Enum.Material[mats.mid] or Enum.Material.Rock end
		if h > baseY + mtnH * 0.72 then return Enum.Material[mats.high] or Enum.Material.Snow end
		if h > baseY + mtnH * 0.35 then return Enum.Material[mats.mid] or Enum.Material.Rock end
		return Enum.Material[mats.low] or Enum.Material.Grass
	end

	for bx = 0, cellsX - 1, CHUNK do
		for bz = 0, cellsZ - 1, CHUNK do
			local sx = math.min(CHUNK, cellsX - bx)
			local sz = math.min(CHUNK, cellsZ - bz)
			local materials = {}
			local occupancy = {}
			for ix = 1, sx do
				materials[ix] = {}
				occupancy[ix] = {}
				for iy = 1, cellsY do
					materials[ix][iy] = {}
					occupancy[ix][iy] = {}
					for iz = 1, sz do
						local wx = (minCellX + bx + ix) * CELL
						local wz = (minCellZ + bz + iz) * CELL
						local wy = y0 + iy * CELL
						local h = heightAt(wx, wz)
						local occ = math.clamp((h - (wy - CELL / 2)) / CELL, 0, 1)
						occupancy[ix][iy][iz] = occ
						if occ <= 0.001 then
							if water and wy < water then
								materials[ix][iy][iz] = Enum.Material.Water
								occupancy[ix][iy][iz] = 1
							else
								materials[ix][iy][iz] = Enum.Material.Air
							end
						else
							local slope = math.abs(heightAt(wx + CELL, wz) - h) / CELL
							materials[ix][iy][iz] = matFor(h, slope)
						end
					end
				end
			end
			local region = Region3.new(
				Vector3.new((minCellX + bx) * CELL, y0, (minCellZ + bz) * CELL),
				Vector3.new((minCellX + bx + sx) * CELL, y0 + cellsY * CELL, (minCellZ + bz + sz) * CELL)
			)
			terrain:WriteVoxels(region:ExpandToGrid(CELL), CELL, materials, occupancy)
			chunks += 1
			task.wait() -- never freeze studio
		end
	end
	return { chunks_written = chunks, seed = seed, region_cells = { x = cellsX, y = cellsY, z = cellsZ }, max_height = maxY }
end

Commands.terrain_smooth = function(args)
	local c = args.region_center or { x = 0, y = 0, z = 0 }
	local s = args.region_size or { x = 128, y = 128, z = 128 }
	local terrain = workspace.Terrain
	local ok, err = pcall(function()
		terrain:SmoothRegion(Region3.new(
			Vector3.new(c.x - s.x / 2, c.y - s.y / 2, c.z - s.z / 2),
			Vector3.new(c.x + s.x / 2, c.y + s.y / 2, c.z + s.z / 2)
		):ExpandToGrid(4), 4, args.strength or 0.5)
	end)
	return { ok = ok, error = not ok and tostring(err) or nil }
end

----------------------------------------------------------------------
-- computable 3D: rigs, accessories, welds — NPC armor pipeline
----------------------------------------------------------------------
local ATTACHMENT_MAP = {
	hat = "HatAttachment", hair = "HairAttachment", face = "FaceFrontAttachment",
	neck = "NeckAttachment", waist = "WaistCenterAttachment", waistfront = "WaistFrontAttachment",
	waistback = "WaistBackAttachment", shoulder_l = "LeftShoulderAttachment", shoulder_r = "RightShoulderAttachment",
	back = "BodyBackAttachment", front = "BodyFrontAttachment", collar = "NeckRigAttachment",
}

local function findAttachment(rig, name)
	for _, d in ipairs(rig:GetDescendants()) do
		if d:IsA("Attachment") and d.Name == name then return d end
	end
	-- alias lookup
	local alias = ATTACHMENT_MAP[string.lower(name or "")]
	if alias then
		for _, d in ipairs(rig:GetDescendants()) do
			if d:IsA("Attachment") and d.Name == alias then return d end
		end
	end
	return nil
end

Commands.rig_npc = function(args)
	waypoint("rig_npc")
	local desc = Instance.new("HumanoidDescription")
	local d = args.description or {}
	for k, v in pairs(d) do pcall(function() desc[k] = v end) end
	local rigType = (args.rig_type == "R6") and Enum.HumanoidRigType.R6 or Enum.HumanoidRigType.R15
	local rig
	local ok, e = pcall(function()
		return Players:CreateHumanoidModelFromDescription(desc, rigType)
	end)
	if ok then rig = e else
		-- fallback: minimal block rig
		rig = Instance.new("Model")
		local torso = Instance.new("Part")
		torso.Name = "Torso"; torso.Size = Vector3.new(2, 2, 1); torso.Anchored = true
		torso.Parent = rig
		local hum = Instance.new("Humanoid"); hum.Parent = rig
		rig.PrimaryPart = torso
	end
	rig.Name = args.name or ("NPC_" .. rigType.Name)
	local p = args.position or { x = 0, y = 5, z = 0 }
	rig:PivotTo(CFrame.new(p.x or 0, p.y or 5, p.z or 0))
	rig.Parent = workspace
	return { path = instancePath(rig), rig_type = rigType.Name, fallback_used = not ok }
end

Commands.fit_accessory = function(args)
	local item, ierr = resolvePath(args.item_path)
	if not item then error(ierr) end
	local rig, rerr = resolvePath(args.rig_path)
	if not rig then error(rerr) end
	local target = findAttachment(rig, args.attachment)
	if not target then error("attachment '" .. tostring(args.attachment) .. "' not found on rig. Available: look under limb parts (Head/Torso) for *Attachment instances") end
	local mode = args.mode or "accessory"
	local offset = args.offset_cframe and cframeFromData(args.offset_cframe) or CFrame.new()
	waypoint("fit_accessory " .. item.Name)

	if mode == "weld" then
		local limb = target.Parent
		if not limb or not limb:IsA("BasePart") then error("attachment parent is not a BasePart") end
		local part = item:IsA("Model") and (item.PrimaryPart or item:FindFirstChildWhichIsA("BasePart", true)) or item
		part.CFrame = target.WorldCFrame * offset
		part.Anchored = false
		part.CanCollide = false
		part.Massless = true
		local w = Instance.new("WeldConstraint")
		w.Part0 = part; w.Part1 = limb; w.Parent = part
		part.Parent = item:IsA("Model") and item or part
		if item:IsA("Model") then item.Parent = rig else part.Parent = rig end
		return { path = instancePath(part), attachment = target.Name, mode = "weld" }
	end

	-- accessory mode: wrap as proper Accessory object
	local acc
	if item:IsA("Accessory") then acc = item else
		acc = Instance.new("Accessory")
		acc.Name = item.Name
		local handle = item:IsA("Model") and (item.PrimaryPart or item:FindFirstChildWhichIsA("BasePart", true)) or item
		handle.Name = "Handle"
		handle.Parent = acc
		if item:IsA("Model") then
			for _, c in ipairs(item:GetChildren()) do if c ~= handle then c.Parent = acc end end
		end
	end
	local handle = acc:FindFirstChild("Handle")
	if not handle then error("accessory has no Handle") end
	local att = handle:FindFirstChild(target.Name)
	if not att then
		att = Instance.new("Attachment")
		att.Name = target.Name
		att.Parent = handle
	end
	-- align: accessory attachment WorldCFrame == body attachment WorldCFrame
	handle.CFrame = target.WorldCFrame * att.CFrame:Inverse() * offset
	acc.Parent = rig
	local hum = rig:FindFirstChildOfClass("Humanoid")
	if hum then pcall(function() hum:AddAccessory(acc) end) end
	return { path = instancePath(acc), attachment = target.Name, mode = "accessory" }
end

Commands.attach_part = function(args)
	local item, ierr = resolvePath(args.item_path)
	if not item then error(ierr) end
	local rig, rerr = resolvePath(args.rig_path)
	if not rig then error(rerr) end
	waypoint("attach_part")
	local mode = args.mode or "mesh"
	if mode == "attachment" then
		local target = findAttachment(rig, args.target)
		if not target then error("attachment not found: " .. tostring(args.target)) end
		local ownAtt = item:IsA("Attachment") and item or item:FindFirstChildWhichIsA("Attachment", true)
		local part = item:IsA("BasePart") and item or item:FindFirstChildWhichIsA("BasePart", true)
		if not part then error("item has no BasePart") end
		local attInPart = ownAtt and ownAtt.Parent == part and ownAtt or Instance.new("Attachment")
		attInPart.Parent = part
		part.CFrame = target.WorldCFrame * attInPart.CFrame:Inverse()
		part.Anchored = false; part.CanCollide = false; part.Massless = true
		local w = Instance.new("WeldConstraint"); w.Part0 = part; w.Part1 = target.Parent; w.Parent = part
		part.Parent = rig
		return { path = instancePath(part), mode = "attachment" }
	elseif mode == "bone" then
		local bone = nil
		for _, d in ipairs(rig:GetDescendants()) do
			if d:IsA("Bone") and d.Name == args.target then bone = d break end
		end
		if not bone then error("no Bone named " .. tostring(args.target)) end
		local part = item:IsA("BasePart") and item or item:FindFirstChildWhichIsA("BasePart", true)
		part.CFrame = bone.TransformedWorldCFrame
		part.Anchored = false; part.CanCollide = false; part.Massless = true
		local w = Instance.new("WeldConstraint"); w.Part0 = part; w.Part1 = bone.Parent; w.Parent = part
		part.Parent = rig
		return { path = instancePath(part), mode = "bone" }
	else -- mesh: rigid weld at current pose
		local targetPart = rig:FindFirstChild(args.target, true)
		if not targetPart or not targetPart:IsA("BasePart") then error("target part not found: " .. tostring(args.target)) end
		local part = item:IsA("BasePart") and item or item:FindFirstChildWhichIsA("BasePart", true)
		part.Anchored = false; part.CanCollide = false; part.Massless = true
		local w = Instance.new("WeldConstraint"); w.Part0 = part; w.Part1 = targetPart; w.Parent = part
		part.Parent = rig
		return { path = instancePath(part), mode = "mesh" }
	end
end

Commands.equip_npc = function(args)
	local results = {}
	waypoint("equip_npc")
	for i, it in ipairs(args.items or {}) do
		local ok, r = pcall(Commands.fit_accessory, {
			item_path = it.item_path, rig_path = args.rig_path,
			attachment = it.attachment, mode = it.mode or "accessory",
			offset_cframe = it.offset_cframe,
		})
		table.insert(results, ok and r or { index = i, error = tostring(r) })
	end
	return { results = results }
end

Commands.import_mesh = function(args)
	waypoint("import_mesh")
	local content
	local ok, e = pcall(function() return Content.fromFile(args.file) end)
	if not ok then error("Content.fromFile failed: " .. tostring(e) .. " — use an absolute path the Studio process can read") end
	local mp
	ok, e = pcall(function() return AssetService:CreateMeshPartAsync(content) end)
	if not ok then error("CreateMeshPartAsync failed: " .. tostring(e)) end
	mp = e
	mp.Name = args.name or (args.file:match("[^\\/]+$") or "Mesh")
	if args.with_texture then
		pcall(function() mp.TextureID = tostring(Content.fromFile(args.with_texture)) end)
	end
	local parent, perr = resolvePath(args.parent_path or "Workspace")
	if not parent then error(perr) end
	mp.Parent = parent
	local report = Commands.validate_asset({ path = instancePath(mp) })
	return { path = instancePath(mp), validation = report }
end

Commands.insert_asset = function(args)
	waypoint("insert_asset " .. tostring(args.asset_id))
	local ok, m = pcall(function() return InsertService:LoadAsset(args.asset_id) end)
	if not ok then error("LoadAsset failed: " .. tostring(m)) end
	local parent, perr = resolvePath(args.parent_path or "Workspace")
	if not parent then error(perr) end
	m.Parent = parent
	return { path = instancePath(m), name = m.Name }
end

Commands.render_thumbnail = function(args)
	local inst, err = resolvePath(args.path)
	if not inst then error(err) end
	-- stage at a fixed spot and point the camera
	local pad = args.padding or 1.4
	local cf, size
	if inst:IsA("Model") then
		cf, size = inst:GetBoundingBox()
	elseif inst:IsA("BasePart") then
		cf, size = inst.CFrame, inst.Size
	else
		error("instance is not Model/BasePart")
	end
	local diag = size.Magnitude * pad
	local cam = workspace.CurrentCamera
	local eye = cf.Position + Vector3.new(diag, diag * 0.6, diag)
	local lookAt = cf.Position
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CFrame = CFrame.lookAt(eye, lookAt)
	return {
		camera = { position = toData(eye), look_at = toData(lookAt) },
		bounds = { size = toData(size), center = toData(cf.Position) },
		next = "call studio.screen_capture (upstream) with these camera coords",
	}
end

Commands.play_state = function(args)
	local action = args.action or "status"
	if action == "play" then
		local ok, e = pcall(function() TestService:Run(true) end)
		return { ok = ok, running = RunService:IsRunning(), note = not ok and tostring(e) or nil }
	elseif action == "stop" then
		local ok, e = pcall(function() game:Shutdown() end)
		return { ok = ok, running = RunService:IsRunning(), note = not ok and ("stop not permitted from plugin context — use studio.start_stop_play upstream: " .. tostring(e)) or nil }
	end
	return { running = RunService:IsRunning(), mode = RunService:IsRunMode() and "run" or "edit" }
end

----------------------------------------------------------------------
-- extended ops: selection, attributes/tags, transforms, batch, replace
----------------------------------------------------------------------
Commands.select_instance = function(args)
	local inst, err = resolvePath(args.path)
	if not inst then error(err) end
	Selection:Set({ inst })
	return { selected = instancePath(inst) }
end

Commands.set_attribute = function(args)
	local inst, err = resolvePath(args.path)
	if not inst then error(err) end
	waypoint("set_attribute")
	inst:SetAttribute(args.name, args.value)
	return { path = instancePath(inst), attribute = args.name, value = toData(args.value) }
end

Commands.tag = function(args)
	local inst, err = resolvePath(args.path)
	if not inst then error(err) end
	if args.remove then CollectionService:RemoveTag(inst, args.tag) else CollectionService:AddTag(inst, args.tag) end
	return { path = instancePath(inst), tag = args.tag, removed = args.remove or false }
end

Commands.move = function(args)
	local inst, err = resolvePath(args.path)
	if not inst then error(err) end
	local parent, perr = resolvePath(args.new_parent)
	if not parent then error(perr) end
	waypoint("move " .. instancePath(inst))
	inst.Parent = parent
	return { path = instancePath(inst) }
end

Commands.clone = function(args)
	local inst, err = resolvePath(args.path)
	if not inst then error(err) end
	waypoint("clone " .. instancePath(inst))
	local c = inst:Clone()
	if args.new_name then c.Name = args.new_name end
	local parent
	if args.parent_path then
		local perr
		parent, perr = resolvePath(args.parent_path)
		if not parent then error(perr) end
	else
		parent = inst.Parent
	end
	c.Parent = parent
	return { path = instancePath(c) }
end

Commands.find_replace = function(args)
	-- regex search & replace across LuaSourceContainers (or one script)
	local roots = {}
	if args.path then
		local r, err = resolvePath(args.path)
		if not r then error(err) end
		table.insert(roots, r)
	else
		table.insert(roots, game)
	end
	local hits, changed = {}, 0
	local patt, rep = args.pattern or "", args.replacement or ""
	waypoint("find_replace " .. patt)
	local function walk(inst)
		if inst:IsA("LuaSourceContainer") then
			local src = inst.Source
			if src:find(patt) then
				local ln = 0
				for line in (src .. "\n"):gmatch("(.-)\n") do
					ln += 1
					if line:find(patt) then table.insert(hits, { path = instancePath(inst), line = ln, text = line:sub(1, 120) }) end
				end
				if args.replacement then
					inst.Source = src:gsub(patt, rep)
					changed += 1
				end
			end
		end
		for _, c in ipairs(inst:GetChildren()) do walk(c) end
	end
	for _, r in ipairs(roots) do walk(r) end
	return { hits = hits, scripts_changed = changed }
end

Commands.batch = function(args)
	-- sequential ops under ONE waypoint: [{cmd, args}] → per-op results.
	-- On error the op aborts and everything before is left applied (undo via rbx_undo).
	waypoint("batch " .. tostring(#(args.ops or {})) .. " ops")
	local results = {}
	for i, op in ipairs(args.ops or {}) do
		local fn = Commands[op.cmd]
		if not fn then
			table.insert(results, { i = i, cmd = op.cmd, ok = false, error = "unknown command" })
			break
		end
		local ok, res = xpcall(function() return fn(op.args or {}) end, debug.traceback)
		table.insert(results, { i = i, cmd = op.cmd, ok = ok, result = ok and res or nil, error = ok and nil or tostring(res) })
		if not ok then break end
	end
	return { results = results, applied = #results }
end

Commands.terrain_clear = function(args)
	local c = args.region_center or { x = 0, y = 0, z = 0 }
	local s = args.region_size or { x = 512, y = 256, z = 512 }
	local terrain = workspace.Terrain
	waypoint("terrain_clear")
	terrain:FillBlock(
		CFrame.new(c.x or 0, c.y or 0, c.z or 0),
		Vector3.new(s.x or 512, s.y or 256, s.z or 512),
		Enum.Material.Air
	)
	return { cleared = true }
end

local BEHAVIOR_TMPL = {
	patrol = [=[
local rig = script.Parent
local hum = rig:FindFirstChildOfClass("Humanoid")
local points = {}
for _, p in ipairs(rig:GetChildren()) do
	if p:IsA("BasePart") and p.Name:match("^Waypoint") then table.insert(points, p) end
end
table.sort(points, function(a, b) return a.Name < b.Name end)
task.spawn(function()
	while task.wait(0.5) do
		for _, wp in ipairs(points) do
			hum:MoveTo(wp.Position)
			hum.MoveToFinished:Wait(30)
		end
	end
end)
]=],
	idle = [=[
local rig = script.Parent
local hum = rig:FindFirstChildOfClass("Humanoid")
local origin = rig:GetPivot().Position
task.spawn(function()
	while task.wait(math.random(2, 5)) do
		local a = math.random() * math.pi * 2
		local d = math.random() * 6
		hum:MoveTo(origin + Vector3.new(math.cos(a) * d, 0, math.sin(a) * d))
		hum.MoveToFinished:Wait(10)
	end
end)
]=],
	chase = [=[
local rig = script.Parent
local hum = rig:FindFirstChildOfClass("Humanoid")
local Players = game:GetService("Players")
task.spawn(function()
	while task.wait(0.5) do
		local best, bd = nil, math.huge
		for _, p in ipairs(Players:GetPlayers()) do
			local c = p.Character
			if c and c:FindFirstChild("HumanoidRootPart") then
				local d = (c.HumanoidRootPart.Position - rig:GetPivot().Position).Magnitude
				if d < bd and d < 60 then best, bd = c, d end
			end
		end
		if best then hum:MoveTo(best.HumanoidRootPart.Position) end
	end
end)
]=],
}
Commands.npc_behavior = function(args)
	local rig, err = resolvePath(args.rig_path)
	if not rig then error(err) end
	local kind = args.behavior or "idle"
	local src = BEHAVIOR_TMPL[kind]
	if not src then error("unknown behavior '" .. kind .. "' — options: patrol, idle, chase") end
	waypoint("npc_behavior " .. kind)
	local s = Instance.new("Script")
	s.Name = "Behavior_" .. kind
	s.Source = src
	s.Parent = rig
	if kind == "patrol" and args.waypoints then
		for i, wp in ipairs(args.waypoints) do
			local p = Instance.new("Part")
			p.Name = "Waypoint" .. i
			p.Anchored = true
			p.CanCollide = false
			p.Transparency = 0.7
			p.Size = Vector3.new(1, 1, 1)
			p.CFrame = CFrame.new(wp.x or 0, wp.y or 3, wp.z or 0)
			p.Parent = rig
		end
	end
	return { path = instancePath(rig) .. "." .. s.Name, behavior = kind }
end

Commands.build_animation = function(args)
	-- keyframes: [{time, parts={PartName={pos={x,y,z}, rotDeg={x,y,z}}}}]
	-- builds a KeyframeSequence stored under the rig (edit-mode artifact)
	local rig, err = resolvePath(args.rig_path or "Workspace")
	if not rig then error(err) end
	waypoint("build_animation " .. (args.name or "Anim"))
	local ks = Instance.new("KeyframeSequence")
	ks.Name = args.name or "Animation"
	ks.Loop = args.loop or false
	ks.Priority = Enum.AnimationPriority[args.priority or "Action"]
	local function poseTree(parent, partName, data)
		local pose = Instance.new("Pose")
		pose.Name = partName
		pose.CFrame = cframeFromData(data or {})
		pose.EasingStyle = Enum.PoseEasingStyle[args.easing_style or "Linear"]
		pose.EasingDirection = Enum.PoseEasingDirection[args.easing_dir or "InOut"]
		pose.Parent = parent
	end
	for _, kf in ipairs(args.keyframes or {}) do
		local key = Instance.new("Keyframe")
		key.Time = kf.time or 0
		for partName, data in pairs(kf.parts or {}) do poseTree(key, partName, data) end
		key.Parent = ks
	end
	ks.Parent = rig
	return { path = instancePath(ks), keyframes = #(args.keyframes or {}) }
end

Commands.install_module = function(args)
	local parent, perr = resolvePath("ReplicatedStorage")
	if not parent then error(perr) end
	local pkgs = parent:FindFirstChild("Packages") or Instance.new("Folder")
	pkgs.Name = "Packages"; pkgs.Parent = parent
	waypoint("install_module " .. tostring(args.name))
	local mod = pkgs:FindFirstChild(args.name)
	if not mod then
		mod = Instance.new("ModuleScript")
		mod.Name = args.name
		mod.Parent = pkgs
	end
	if args.files then
		-- multi-file module: rebuild the repo's relative tree as nested
		-- ModuleScripts/Folders so require(script.X) resolves naturally
		for _, c in ipairs(mod:GetChildren()) do c:Destroy() end
		for rel, src in pairs(args.files) do
			local segs = {}
			for s in tostring(rel):gmatch("[^/]+") do table.insert(segs, s) end
			local leaf = (segs[#segs] or ""):gsub("%.lua[u]?$", "")
			segs[#segs] = nil
			if leaf == "init" and #segs == 0 then
				mod.Source = src -- entry file is the root module itself
			else
				local cur = mod
				for _, s in ipairs(segs) do
					local nxt = cur:FindFirstChild(s)
					if not nxt then nxt = Instance.new("Folder"); nxt.Name = s; nxt.Parent = cur end
					cur = nxt
				end
				local ms = cur:FindFirstChild(leaf) or Instance.new("ModuleScript")
				ms.Name = leaf; ms.Source = src; ms.Parent = cur
			end
		end
		local count = 0
		for _ in pairs(args.files) do count += 1 end
		return { installed = args.name, path = instancePath(mod), files = count }
	end
	mod.Source = args.source or ""
	return { installed = args.name, path = instancePath(mod), bytes = #mod.Source }
end

----------------------------------------------------------------------
-- lighting & atmosphere ---------------------------------------------------
local Lighting = game:GetService("Lighting")
Commands.lighting = function(args)
	waypoint("lighting")
	local changed = {}
	for k, v in pairs(args.props or {}) do
		local ok, curT = pcall(function() return typeof(Lighting[k]) end)
		if ok then
			local ok2, e2 = pcall(function() Lighting[k] = decodeProp(curT, v, Lighting[k]) end)
			table.insert(changed, ok2 and k or (k .. " FAILED:" .. tostring(e2)))
		else table.insert(changed, k .. " NO_PROP") end
	end
	if args.time_of_day then Lighting.ClockTime = args.time_of_day; table.insert(changed, "ClockTime") end
	if args.technology then pcall(function() Lighting.Technology = Enum.Technology[args.technology] end); table.insert(changed, "Technology") end
	if args.atmosphere then
		local at = Lighting:FindFirstChildOfClass("Atmosphere") or Instance.new("Atmosphere")
		for k, v in pairs(args.atmosphere) do pcall(function() at[k] = v end) end
		at.Parent = Lighting; table.insert(changed, "Atmosphere")
	end
	if type(args.sky) == "table" then
		local sky = Lighting:FindFirstChildOfClass("Sky") or Instance.new("Sky")
		for k, v in pairs(args.sky) do pcall(function() sky[k] = v end) end
		sky.Parent = Lighting; table.insert(changed, "Sky")
	elseif type(args.sky) == "string" then
		local NEBULA = { "12064107", "12064152", "12064121", "12063984", "12064115", "12064131" }
		local presets = {
			starfield = { StarCount = 5000, CelestialBodiesShown = true,
				SkyboxBk = "rbxassetid://" .. NEBULA[1], SkyboxDn = "rbxassetid://" .. NEBULA[2],
				SkyboxFt = "rbxassetid://" .. NEBULA[3], SkyboxLf = "rbxassetid://" .. NEBULA[4],
				SkyboxRt = "rbxassetid://" .. NEBULA[5], SkyboxUp = "rbxassetid://" .. NEBULA[6] },
			moon = { StarCount = 3000, CelestialBodiesShown = true, MoonAngularSize = 18,
				SkyboxBk = "rbxassetid://" .. NEBULA[1], SkyboxDn = "rbxassetid://" .. NEBULA[2],
				SkyboxFt = "rbxassetid://" .. NEBULA[3], SkyboxLf = "rbxassetid://" .. NEBULA[4],
				SkyboxRt = "rbxassetid://" .. NEBULA[5], SkyboxUp = "rbxassetid://" .. NEBULA[6] },
			sun = { StarCount = 0, CelestialBodiesShown = true, SunAngularSize = 24 },
		}
		local sp = presets[args.sky]
		if sp then
			local sky = Lighting:FindFirstChildOfClass("Sky") or Instance.new("Sky")
			for _, k in ipairs({ "SkyboxBk", "SkyboxDn", "SkyboxFt", "SkyboxLf", "SkyboxRt", "SkyboxUp" }) do
				pcall(function() sky[k] = "" end)
			end
			for k, v in pairs(sp) do pcall(function() sky[k] = v end) end
			sky.Parent = Lighting; table.insert(changed, "sky:" .. args.sky)
		end
	end
	if args.fog then
		if args.fog.start then pcall(function() Lighting.FogStart = args.fog.start end) end
		if args.fog["end"] then pcall(function() Lighting.FogEnd = args.fog["end"] end) end
		if args.fog.color then pcall(function() Lighting.FogColor = decodeProp("Color3", args.fog.color) end) end
		table.insert(changed, "fog")
	end
	if args.style then
		local map = {
			realistic = { "Realistic", "Future", "Unified" }, soft = { "Soft", "Voxel", "ShadowMap" },
			physical = { "Physical", "ShadowMap", "Voxel" }, vivid = { "Vivid", "Future", "ShadowMap" },
		}
		local tried = map[string.lower(tostring(args.style))] or { tostring(args.style) }
		local applied
		for _, n in ipairs(tried) do
			if not applied and pcall(function() Lighting.Technology = Enum.Technology[n] end) then applied = n end
		end
		table.insert(changed, "style:" .. tostring(applied or "FAILED"))
	end
	for cls, props in pairs(args.effects or {}) do
		local eff = Lighting:FindFirstChildOfClass(cls .. "Effect") or Instance.new(cls .. "Effect")
		for k, v in pairs(props) do
			local ok, curT = pcall(function() return typeof(eff[k]) end)
			if ok then pcall(function() eff[k] = decodeProp(curT, v, eff[k]) end) end
		end
		eff.Parent = Lighting; table.insert(changed, cls)
	end
	local PRESETS = {
		dawn = { ClockTime = 6.2, atmosphere = { Density = 0.4, Haze = 3, Color = Color3.fromRGB(255, 214, 189) },
			effects = { SunRays = { Intensity = 0.08, Spread = 0.6 }, ColorCorrection = { TintColor = Color3.fromRGB(255, 230, 210), Saturation = 0.05 } } },
		sunset = { ClockTime = 17.8, atmosphere = { Density = 0.42, Haze = 4, Color = Color3.fromRGB(255, 183, 138) },
			effects = { SunRays = { Intensity = 0.12, Spread = 0.8 }, ColorCorrection = { TintColor = Color3.fromRGB(255, 214, 180), Saturation = 0.08 } } },
		night = { ClockTime = 0, atmosphere = { Density = 0.5, Haze = 8 }, FogEnd = 900, FogColor = Color3.fromRGB(10, 12, 24),
			OutdoorAmbient = Color3.fromRGB(25, 30, 55), effects = { Bloom = { Intensity = 0.4, Threshold = 1.2, Size = 24 }, ColorCorrection = { TintColor = Color3.fromRGB(180, 195, 255), Saturation = -0.1 } } },
		noon = { ClockTime = 12, atmosphere = { Density = 0.28, Haze = 1.5 }, effects = { ColorCorrection = { Saturation = 0.03 } } },
		storm = { ClockTime = 15, atmosphere = { Density = 0.6, Haze = 12 }, FogEnd = 400, FogColor = Color3.fromRGB(70, 78, 90),
			OutdoorAmbient = Color3.fromRGB(90, 95, 110), effects = { ColorCorrection = { TintColor = Color3.fromRGB(190, 200, 220), Saturation = -0.2 } } },
		overcast = { ClockTime = 13, atmosphere = { Density = 0.45, Haze = 6 }, FogEnd = 1400, OutdoorAmbient = Color3.fromRGB(140, 140, 145) },
	}
	local pre = args.preset and PRESETS[args.preset]
	if pre then
		for k, v in pairs(pre) do
			if k == "atmosphere" then
				local at = Lighting:FindFirstChildOfClass("Atmosphere") or Instance.new("Atmosphere")
				for kk, vv in pairs(v) do pcall(function() at[kk] = vv end) end; at.Parent = Lighting
			elseif k == "effects" then
				for cls, props in pairs(v) do
					local eff = Lighting:FindFirstChildOfClass(cls .. "Effect") or Instance.new(cls .. "Effect")
					for kk, vv in pairs(props) do pcall(function() eff[kk] = vv end) end; eff.Parent = Lighting
				end
			else pcall(function() Lighting[k] = v end) end
		end
		table.insert(changed, "preset:" .. args.preset)
	end
	local tech = select(2, pcall(function() return tostring(Lighting.Technology) end))
	return { changed = changed, clock = Lighting.ClockTime, technology = tech }
end

-- ui sound effects ---------------------------------------------------------
local UI_SOUNDS = {
	click = "rbxassetid://6895079853", hover = "rbxassetid://6895079711",
	open = "rbxassetid://6895079786", close = "rbxassetid://6895079827",
	error = "rbxassetid://5507672147", success = "rbxassetid://6536792323",
	pop = "rbxassetid://9085427562",
}
Commands.ui_sounds = function(args)
	local root, err = resolvePath(args.path)
	if not root then error(err) end
	waypoint("ui_sounds")
	for k, v in pairs(args.sounds or {}) do UI_SOUNDS[k] = v end
	local holder = root:FindFirstChild("__RbxUISounds") or Instance.new("Folder")
	holder.Name = "__RbxUISounds"; holder.Parent = root
	local holderPath = instancePath(holder)
	for name, id in pairs(UI_SOUNDS) do
		local s = holder:FindFirstChild(name) or Instance.new("Sound")
		s.Name = name; s.SoundId = id; s.Volume = args.volume or 0.35; s.Parent = holder
	end
	local src = 'local gui = script.Parent\nlocal snd = gui:WaitForChild("__RbxUISounds")\n'
		.. 'local function play(n) local s = snd:FindFirstChild(n) if s then s:Play() end end\n'
		.. 'local function wire(o)\n\tif o:IsA("GuiButton") then\n'
		.. '\t\to.MouseButton1Click:Connect(function() play("click") end)\n'
		.. '\t\to.MouseEnter:Connect(function() play("hover") end)\n\tend\n'
		.. '\tfor _, c in ipairs(o:GetChildren()) do wire(c) end\nend\nwire(gui)\ngui.DescendantAdded:Connect(wire)'
	local ls = root:FindFirstChild("__RbxUISoundWire") or Instance.new("LocalScript")
	ls.Name = "__RbxUISoundWire"; ls.Source = src; ls.Parent = root
	return { sounds_holder = holderPath, script = instancePath(ls) }
end

----------------------------------------------------------------------
-- worldgen v2: editable mesh, kits, vfx, materials, populate, optimize
----------------------------------------------------------------------
local pendingMeshes = {}

Commands.editable_mesh = function(args)
	local name = args.name or "RbxMesh"
	local p = pendingMeshes[name] or { verts = {}, faces = {}, uvs = {}, normals = {} }
	pendingMeshes[name] = p
	local prev = #p.verts
	for _, v in ipairs(args.verts or {}) do table.insert(p.verts, v3(v)) end
	local added = #p.verts - prev
	-- face indices: relative to this batch's verts when they fit, else global 1-based
	local maxF, minF = 0, math.huge
	for _, f in ipairs(args.faces or {}) do
		maxF = math.max(maxF, f[1], f[2], f[3])
		minF = math.min(minF, f[1], f[2], f[3])
	end
	local fbase = (added > 0 and maxF <= added) and prev or 0
	local zshift = (minF == 0) and 1 or 0 -- tolerate 0-based callers
	for _, f in ipairs(args.faces or {}) do
		table.insert(p.faces, { f[1] + fbase + zshift, f[2] + fbase + zshift, f[3] + fbase + zshift })
	end
	for _, uv in ipairs(args.uvs or {}) do table.insert(p.uvs, uv) end
	for _, n in ipairs(args.normals or {}) do table.insert(p.normals, n) end
	if not args.done then return { name = name, staged = true, verts = #p.verts, faces = #p.faces } end
	pendingMeshes[name] = nil
	if #p.verts < 3 or #p.faces == 0 then error("editable_mesh '" .. name .. "' incomplete: " .. #p.verts .. " verts / " .. #p.faces .. " faces") end
	waypoint("editable_mesh " .. name)
	local em = AssetService:CreateEditableMesh()
	local ids = {}
	for i, v in ipairs(p.verts) do
		local ok, id = pcall(function() return em:AddVertex(v) end)
		ids[i] = ok and id or nil
		if i % 100 == 0 then task.wait() end
	end
	for i, uv in ipairs(p.uvs) do
		if ids[i] then pcall(function() em:SetUV(ids[i], Vector2.new(uv[1] or uv.u or 0, uv[2] or uv.v or 0)) end) end
		if i % 100 == 0 then task.wait() end
	end
	for i, n in ipairs(p.normals) do
		if ids[i] then pcall(function() em:SetVertexNormal(ids[i], v3(n)) end) end
		if i % 100 == 0 then task.wait() end
	end
	local tris = 0
	for i, f in ipairs(p.faces) do
		local a, b, c = ids[f[1]], ids[f[2]], ids[f[3]]
		if a and b and c then
			if pcall(function() em:AddTriangle(a, b, c) end) then tris += 1 end
		end
		if i % 100 == 0 then task.wait() end
	end
	local mp = AssetService:CreateMeshPartAsync(em)
	mp.Name = name
	mp.Anchored = true
	local parent, perr = resolvePath(args.parent_path or "Workspace")
	if not parent then error(perr) end
	mp.Parent = parent
	return { path = instancePath(mp), verts = #p.verts, tris = tris }
end

local function kitRoot(kit)
	local ss = game:GetService("ServerStorage")
	local root = ss:FindFirstChild("RbxKit")
	return root and root:FindFirstChild(tostring(kit))
end

Commands.kit_pieces = function(args)
	local kit = kitRoot(args.kit)
	if not kit then error("kit '" .. tostring(args.kit) .. "' not found under ServerStorage.RbxKit") end
	local out = {}
	for _, c in ipairs(kit:GetChildren()) do
		local size
		pcall(function()
			if c:IsA("Model") then local _, s = c:GetBoundingBox(); size = s
			elseif c:IsA("BasePart") then size = c.Size end
		end)
		table.insert(out, { name = c.Name, className = c.ClassName, size = size and toData(size) or nil })
	end
	return { kit = tostring(args.kit), pieces = out }
end

Commands.kit_place = function(args)
	local kit = kitRoot(args.kit)
	if not kit then error("kit '" .. tostring(args.kit) .. "' not found under ServerStorage.RbxKit") end
	local piece = kit:FindFirstChild(tostring(args.piece))
	if not piece then error("piece '" .. tostring(args.piece) .. "' not found in kit '" .. tostring(args.kit) .. "' — use kit_pieces to list") end
	local parent, perr = resolvePath(args.parent_path or "Workspace")
	if not parent then error(perr) end
	waypoint("kit_place " .. tostring(args.piece) .. " x" .. tostring(#(args.transforms or {})))
	local placed, paths = 0, {}
	for _, t in ipairs(args.transforms or {}) do
		local rot = t.rot or {}
		local cf = CFrame.new(v3(t.pos)) * CFrame.Angles(math.rad(rot[1] or rot.x or 0), math.rad(rot[2] or rot.y or 0), math.rad(rot[3] or rot.z or 0))
		local c = piece:Clone()
		local sc = t.scale
		if c:IsA("Model") then
			if sc then
				local s = type(sc) == "number" and sc or (sc[1] or sc.x or 1)
				pcall(function() c:ScaleTo(s) end)
			end
			c:PivotTo(cf)
		elseif c:IsA("BasePart") then
			if sc then
				local s = type(sc) == "number" and Vector3.new(sc, sc, sc) or v3(sc, Vector3.new(1, 1, 1))
				pcall(function() c.Size = Vector3.new(c.Size.X * s.X, c.Size.Y * s.Y, c.Size.Z * s.Z) end)
			end
			c.CFrame = cf
		else
			pcall(function() c:PivotTo(cf) end)
		end
		c.Parent = parent
		placed += 1
		if #paths < 10 then table.insert(paths, instancePath(c)) end
	end
	return { placed = placed, paths = paths }
end

local FIRE_TEXTURE = "rbxasset://textures/particles/fire_main.dds"
local SMOKE_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

Commands.vfx = function(args)
	local preset = tostring(args.preset or "")
	local scale = tonumber(args.scale) or 1
	local props = args.props or {}
	local created, ownPart = {}, false
	local function nsScale(seq, s)
		if s == 1 then return seq end
		local ks = {}
		for i, k in ipairs(seq.Keypoints) do
			ks[i] = NumberSequenceKeypoint.new(k.Time, k.Value * s, k.Envelope * s)
		end
		return NumberSequence.new(ks)
	end
	local function emit(parent, cfg)
		local pe = Instance.new("ParticleEmitter")
		for k, v in pairs(cfg) do pcall(function() pe[k] = v end) end
		pe.Size = nsScale(pe.Size, scale)
		for k, v in pairs(props) do
			local ok, t = pcall(function() return typeof(pe[k]) end)
			if ok then
				pcall(function()
					if k == "Color" and type(v) == "table" and v.r then pe[k] = ColorSequence.new(Color3.new(v.r, v.g, v.b))
					elseif k == "Size" and type(v) == "number" then pe[k] = NumberSequence.new(v)
					elseif (k == "Speed" or k == "Lifetime" or k == "RotSpeed") and type(v) == "number" then pe[k] = NumberRange.new(v)
					else pe[k] = decodeProp(t, v, pe[k]) end
				end)
			end
		end
		pe.Parent = parent
		table.insert(created, pe)
		return pe
	end
	local parent, perr = resolvePath(args.parent_path or "Workspace")
	if not parent then error(perr) end
	local function newPart(size, cf, semi)
		local p = Instance.new("Part")
		p.Name = "RbxVfx_" .. preset:gsub("%.", "_")
		p.Anchored = true; p.CanCollide = false; p.CanQuery = false; p.CanTouch = false
		p.Transparency = semi and 0.3 or 1
		p.Size = size; p.CFrame = cf; p.Parent = parent
		ownPart = true
		table.insert(created, p)
		return p
	end
	local function host(defaultSize, yOff, semi)
		if args.path then
			local inst, err = resolvePath(args.path)
			if not inst then error(err) end
			local part = inst:IsA("BasePart") and inst or inst:FindFirstChildWhichIsA("BasePart", true)
			if not part then error("no BasePart at '" .. tostring(args.path) .. "'") end
			return part
		end
		return newPart(defaultSize, CFrame.new(v3(args.position) + Vector3.new(0, yOff or 0, 0)), semi)
	end
	waypoint("vfx " .. preset)
	local nr, nseq, cseq, rgb = NumberRange.new, NumberSequence.new, ColorSequence.new, Color3.fromRGB
	local kind, sub = preset:match("^(%w+)%.?(%w*)$")
	if kind == "fire" then
		local part = host(Vector3.new(0.6, 0.6, 0.6), 0.3, true)
		local big = (sub == "brazier" or sub == "campfire") and 1.8 or 1
		if sub == "chimney_smoke" then
			emit(part, { Rate = 14, Lifetime = nr(2, 4), Speed = nr(2.5, 4),
				Size = nseq(1.2, 4), Color = cseq(rgb(120, 120, 125)), Transparency = nseq(0.65, 1),
				Texture = SMOKE_TEXTURE, EmissionDirection = Enum.NormalId.Top, SpreadAngle = Vector2.new(12, 12),
				WindAffectsDrag = true, Drag = 0.2, RotSpeed = nr(-15, 15) })
		else
			emit(part, { Rate = 45 * big, Lifetime = nr(0.35, 0.8), Speed = nr(1.5, 3.5),
				Size = nseq({ NumberSequenceKeypoint.new(0, 0.7 * big), NumberSequenceKeypoint.new(1, 0.1) }),
				Color = cseq(rgb(255, 170, 60), rgb(255, 70, 10)), LightEmission = 1, LightInfluence = 0,
				Texture = FIRE_TEXTURE, EmissionDirection = Enum.NormalId.Top, SpreadAngle = Vector2.new(10, 10),
				RotSpeed = nr(-40, 40), Drag = 0.5 })
			emit(part, { Rate = 10 * big, Lifetime = nr(0.9, 1.6), Speed = nr(1, 2.5),
				Size = nseq(0.5 * big, 2.2 * big), Color = cseq(rgb(55, 55, 58)), Transparency = nseq(0.55, 1),
				Texture = SMOKE_TEXTURE, EmissionDirection = Enum.NormalId.Top, SpreadAngle = Vector2.new(18, 18) })
			if sub == "campfire" then
				emit(part, { Rate = 22, Lifetime = nr(0.8, 1.6), Speed = nr(4, 8), Size = nseq(0.08, 0.02),
					Color = cseq(rgb(255, 190, 80)), LightEmission = 1, Texture = SPARKLE_TEXTURE,
					EmissionDirection = Enum.NormalId.Top, SpreadAngle = Vector2.new(28, 28), Drag = 1.2 })
			end
			local l = Instance.new("PointLight")
			l.Color = rgb(255, 150, 50); l.Range = 26 * big; l.Brightness = 2; l.Parent = part
			table.insert(created, l)
		end
	elseif kind == "weather" then
		local pos = v3(args.position)
		local yOff = (sub == "mist") and 1 or 30
		local part = newPart(Vector3.new(80, 1, 80) * scale, CFrame.new(pos + Vector3.new(0, yOff, 0)))
		local W = {
			rain = { Rate = 700, Lifetime = nr(0.4, 0.9), Speed = nr(55, 75), Size = nseq(0.2, 0.3),
				Color = cseq(rgb(170, 190, 220)), Transparency = nseq(0.35, 0.55), Squash = nseq(2.5, 3.5),
				EmissionDirection = Enum.NormalId.Bottom, SpreadAngle = Vector2.new(2, 2), LightInfluence = 0.6 },
			snow = { Rate = 180, Lifetime = nr(4, 7), Speed = nr(3.5, 7), Size = nseq(0.3, 0.5),
				Color = cseq(rgb(255, 255, 255)), EmissionDirection = Enum.NormalId.Bottom,
				SpreadAngle = Vector2.new(10, 10), RotSpeed = nr(-40, 40), WindAffectsDrag = true, Drag = 1 },
			mist = { Rate = 24, Lifetime = nr(4, 8), Speed = nr(0.5, 1.5), Size = nseq(8, 14),
				Color = cseq(rgb(200, 205, 215)), Transparency = nseq(0.85, 0.97), Texture = SMOKE_TEXTURE,
				EmissionDirection = Enum.NormalId.Top, SpreadAngle = Vector2.new(180, 180), RotSpeed = nr(-15, 15) },
			embers = { Rate = 40, Lifetime = nr(2, 4), Speed = nr(2, 5), Size = nseq(0.12, 0.03),
				Color = cseq(rgb(255, 160, 60), rgb(255, 80, 20)), LightEmission = 1, Texture = SPARKLE_TEXTURE,
				EmissionDirection = Enum.NormalId.Top, SpreadAngle = Vector2.new(180, 180), WindAffectsDrag = true },
			leaves = { Rate = 30, Lifetime = nr(5, 9), Speed = nr(2, 6), Size = nseq(0.35, 0.5),
				Color = cseq(rgb(120, 160, 60), rgb(160, 130, 50)), EmissionDirection = Enum.NormalId.Bottom,
				SpreadAngle = Vector2.new(180, 180), RotSpeed = nr(-120, 120), WindAffectsDrag = true, Drag = 0.8 },
		}
		emit(part, W[sub] or W.rain)
	elseif kind == "magic" then
		local part = host(Vector3.new(0.5, 0.5, 0.5), 1.2, true)
		if sub == "portal" then
			emit(part, { Rate = 90, Lifetime = nr(0.6, 1.2), Speed = nr(6, 10), Size = nseq(0.5, 0.1),
				Color = cseq(rgb(140, 80, 255), rgb(60, 160, 255)), LightEmission = 1, Texture = SPARKLE_TEXTURE,
				EmissionDirection = Enum.NormalId.Top, SpreadAngle = Vector2.new(4, 4), RotSpeed = nr(-60, 60) })
			emit(part, { Rate = 50, Lifetime = nr(0.8, 1.4), Speed = nr(1, 2), Size = nseq(0.4, 0.05),
				Color = cseq(rgb(200, 140, 255)), LightEmission = 1, Texture = SPARKLE_TEXTURE,
				EmissionDirection = Enum.NormalId.Top, SpreadAngle = Vector2.new(180, 180), Drag = 2 })
			local l = Instance.new("PointLight"); l.Color = rgb(160, 100, 255); l.Range = 18; l.Brightness = 1.5; l.Parent = part
			table.insert(created, l)
		elseif sub == "rune" then
			emit(part, { Rate = 60, Lifetime = nr(0.8, 1.4), Speed = nr(0.5, 1.5), Size = nseq(0.3, 0.05),
				Color = cseq(rgb(80, 220, 255), rgb(40, 120, 255)), LightEmission = 1, Texture = SPARKLE_TEXTURE,
				EmissionDirection = Enum.NormalId.Top, SpreadAngle = Vector2.new(180, 180), Drag = 3 })
		else -- heal
			emit(part, { Rate = 45, Lifetime = nr(0.8, 1.5), Speed = nr(2, 4), Size = nseq(0.35, 0.05),
				Color = cseq(rgb(140, 255, 160), rgb(60, 200, 120)), LightEmission = 1, Texture = SPARKLE_TEXTURE,
				EmissionDirection = Enum.NormalId.Top, SpreadAngle = Vector2.new(160, 160), Drag = 1.5 })
		end
	elseif kind == "explosion" then
		local part = host(Vector3.new(1, 1, 1), 0.5, true)
		local big = sub == "large" and 2.2 or 1
		local pe = emit(part, { Rate = 0, Lifetime = nr(0.3, 0.8), Speed = nr(18 * big, 30 * big),
			Size = nseq(1.5 * big, 0.2), Color = cseq(rgb(255, 200, 90), rgb(255, 90, 20)), LightEmission = 1,
			Texture = FIRE_TEXTURE, EmissionDirection = Enum.NormalId.Top, SpreadAngle = Vector2.new(180, 180), Drag = 2 })
		local sp = emit(part, { Rate = 0, Lifetime = nr(0.4, 1), Speed = nr(30 * big, 55 * big), Size = nseq(0.15, 0.03),
			Color = cseq(rgb(255, 230, 140)), LightEmission = 1, Texture = SPARKLE_TEXTURE,
			EmissionDirection = Enum.NormalId.Top, SpreadAngle = Vector2.new(180, 180), Drag = 1 })
		local l = Instance.new("PointLight"); l.Color = rgb(255, 170, 80); l.Range = 30 * big; l.Brightness = 8; l.Parent = part
		table.insert(created, l)
		pe:Emit(math.floor(60 * big))
		sp:Emit(math.floor(40 * big))
		local Debris = game:GetService("Debris")
		Debris:AddItem(pe, 5); Debris:AddItem(sp, 5); Debris:AddItem(l, 5)
		if ownPart then Debris:AddItem(part, 5) end
	elseif kind == "banner" or preset == "banner" then
		if not args.path then error("banner requires path to an existing part") end
		local part = host(Vector3.new(1, 1, 1), 0, false)
		local len = tonumber(props.length) or 6
		local w = tonumber(props.width) or 2
		local a0 = mk("Attachment", { Name = "BannerTop" }, part)
		local a1 = mk("Attachment", { Name = "BannerBottom", Position = Vector3.new(0, -len, 0) }, part)
		local beam = mk("Beam", { Attachment0 = a0, Attachment1 = a1, Width0 = w, Width1 = w * 0.9, Segments = 8,
			Color = ColorSequence.new(rgb(170, 30, 30), rgb(140, 20, 20)), FaceCamera = true }, part)
		table.insert(created, a0); table.insert(created, a1); table.insert(created, beam)
		local s = Instance.new("Script")
		s.Name = "RbxBannerSway"
		s.Source = [=[
local part = script.Parent
local a = part:WaitForChild("BannerBottom")
local beam = part:FindFirstChildOfClass("Beam")
local base = a.Position
local w0 = beam and beam.Width0 or 2
local t = 0
game:GetService("RunService").Heartbeat:Connect(function(dt)
	t += dt
	a.Position = base + Vector3.new(math.sin(t * 1.7) * 0.15, math.sin(t * 2.3) * 0.1, math.cos(t * 1.3) * 0.15)
	if beam then beam.Width1 = w0 * (1 + math.sin(t * 3) * 0.06) end
end)
]=]
		s.Parent = part
		table.insert(created, s)
	else
		error("unknown vfx preset '" .. preset .. "' — groups: fire.*, weather.*, magic.*, explosion.*, banner")
	end
	local paths = {}
	for _, i in ipairs(created) do table.insert(paths, instancePath(i)) end
	return { paths = paths, preset = preset }
end

Commands.material = function(args)
	if not args.material and not args.variant then error("pass material or variant") end
	local inst, err = resolvePath(args.path or "Workspace")
	if not inst then error(err) end
	waypoint("material " .. instancePath(inst))
	local applied, variantName, baseMat = {}, nil, nil
	if args.variant then
		local v = args.variant
		variantName = v.name or "RbxVariant"
		local okB, bm = pcall(function() return Enum.Material[v.base or "SmoothPlastic"] end)
		baseMat = (okB and bm) or Enum.Material.SmoothPlastic
		local ms = game:GetService("MaterialService")
		local mv = ms:FindFirstChild(variantName)
		if mv and not mv:IsA("MaterialVariant") then mv:Destroy(); mv = nil end
		if not mv then
			mv = Instance.new("MaterialVariant")
			mv.Name = variantName
			mv.Parent = ms
		end
		mv.BaseMaterial = baseMat
		if v.brickColor then pcall(function() mv.BrickColor = BrickColor.new(tostring(v.brickColor)) end) end
		for k, val in pairs(v.props or {}) do
			pcall(function() mv[k] = decodeProp(typeof(mv[k]), val, mv[k]) end)
		end
	end
	local targets = {}
	if inst:IsA("BasePart") then
		table.insert(targets, inst)
	else
		for _, d in ipairs(inst:GetDescendants()) do
			if d:IsA("BasePart") then table.insert(targets, d) end
		end
	end
	for _, p in ipairs(targets) do
		if variantName then
			pcall(function() p.Material = baseMat end)
			if pcall(function() p.MaterialVariant = variantName end) then applied[instancePath(p)] = variantName end
		else
			local okM, m = pcall(function() return Enum.Material[tostring(args.material)] end)
			if okM and m then pcall(function() p.Material = m end); applied[instancePath(p)] = tostring(args.material) end
		end
	end
	if args.terrain and variantName then
		pcall(function() workspace.Terrain:SetMaterialVariant(baseMat, variantName) end)
		applied["Terrain"] = variantName
	end
	local n = 0
	for _ in pairs(applied) do n += 1 end
	return { applied = n, variant_name = variantName }
end

local NPC_TONES = {
	Color3.fromRGB(255, 204, 153), Color3.fromRGB(234, 184, 146), Color3.fromRGB(204, 142, 105),
	Color3.fromRGB(160, 95, 53), Color3.fromRGB(124, 92, 70), Color3.fromRGB(105, 64, 40),
}
Commands.populate = function(args)
	local rigType = (args.rig_type == "R6") and Enum.HumanoidRigType.R6 or Enum.HumanoidRigType.R15
	local count = math.clamp(args.count or 5, 1, 60)
	local area = args.area or {}
	local center = v3(area.center)
	local radius = area.radius or 20
	local names = args.names or {}
	local jobs = args.jobs or {}
	local rng = Random.new(math.floor(args.outfit_seed or (os.clock() * 1000)) % 2147483647)
	waypoint("populate x" .. count)
	local paths, created = {}, 0
	for i = 1, count do
		local desc = Instance.new("HumanoidDescription")
		local tone = NPC_TONES[rng:NextInteger(1, #NPC_TONES)]
		desc.HeadColor = tone
		desc.TorsoColor = Color3.fromRGB(rng:NextInteger(40, 220), rng:NextInteger(40, 220), rng:NextInteger(40, 220))
		local leg = Color3.fromRGB(rng:NextInteger(30, 90), rng:NextInteger(30, 90), rng:NextInteger(30, 90))
		desc.LeftLegColor = leg; desc.RightLegColor = leg
		desc.LeftArmColor = rng:NextNumber() < 0.5 and desc.TorsoColor or tone
		desc.RightArmColor = desc.LeftArmColor
		desc.HeightScale = 0.95 + rng:NextNumber() * 0.1
		desc.WidthScale = 0.94 + rng:NextNumber() * 0.12
		desc.BodyTypeScale = rng:NextNumber() * 0.3
		local ok, rig = pcall(function() return Players:CreateHumanoidModelFromDescription(desc, rigType) end)
		if ok and rig then
			local nm = #names > 0 and tostring(names[((i - 1) % #names) + 1]) or "Citizen"
			rig.Name = nm .. "_" .. i
			local a = rng:NextNumber() * math.pi * 2
			local d = math.sqrt(rng:NextNumber()) * radius
			local pos = center + Vector3.new(math.cos(a) * d, 3, math.sin(a) * d)
			rig:PivotTo(CFrame.new(pos) * CFrame.Angles(0, rng:NextNumber() * math.pi * 2, 0))
			local head = rig:FindFirstChild("Head")
			if head then
				local bb = Instance.new("BillboardGui")
				bb.Name = "Nametag"; bb.Size = UDim2.new(6, 0, 1, 0); bb.StudsOffset = Vector3.new(0, 2.4, 0)
				bb.Adornee = head; bb.Parent = head
				local tl = Instance.new("TextLabel")
				tl.Size = UDim2.new(1, 0, 1, 0); tl.BackgroundTransparency = 1; tl.Text = nm
				tl.TextColor3 = Color3.new(1, 1, 1); tl.TextStrokeTransparency = 0.6
				tl.TextScaled = true; tl.Font = Enum.Font.GothamBold; tl.Parent = bb
			end
			local job = #jobs > 0 and jobs[((i - 1) % #jobs) + 1] or nil
			if job then
				local jt = tostring(job.type or "idle")
				if jt == "patrol" and job.waypoints then
					for wi, wp in ipairs(job.waypoints) do
						local w = Instance.new("Part")
						w.Name = "Waypoint" .. wi; w.Anchored = true; w.CanCollide = false
						w.Transparency = 1; w.Size = Vector3.new(1, 1, 1); w.CFrame = CFrame.new(v3(wp))
						w.Parent = rig
					end
					local s = Instance.new("Script"); s.Name = "Behavior_patrol"; s.Source = BEHAVIOR_TMPL.patrol; s.Parent = rig
				elseif jt == "vendor" or jt == "guard" then
					local spot = job.spot and v3(job.spot) or pos
					local out = Vector3.new(spot.X - center.X, 0, spot.Z - center.Z)
					if out.Magnitude < 0.01 then out = Vector3.new(0, 0, 1) end
					rig:PivotTo(CFrame.lookAt(spot + Vector3.new(0, 3, 0), spot + Vector3.new(0, 3, 0) + out.Unit))
				else
					local s = Instance.new("Script"); s.Name = "Behavior_idle"; s.Source = BEHAVIOR_TMPL.idle; s.Parent = rig
				end
			end
			rig.Parent = workspace
			waypoint("populate " .. rig.Name)
			created += 1
			if #paths < 50 then table.insert(paths, instancePath(rig)) end
		end
	end
	return { created = created, paths = paths }
end

Commands.optimize = function(args)
	local root, err = resolvePath(args.path or "Workspace")
	if not root then error(err) end
	local decorWords = { "decor", "prop", "detail", "vfx", "light", "grass", "leaf" }
	local report = { parts = 0, unanchored = 0, can_collide_on = 0, can_collide_off = 0, decor_colliders = 0 }
	local groups, examples = {}, {}
	local function nameHit(n)
		n = n:lower()
		for _, w in ipairs(decorWords) do
			if n:find(w, 1, true) then return true end
		end
		return false
	end
	local function isDecor(o)
		if nameHit(o.Name) then return true end
		local p, depth = o.Parent, 0
		while p and p ~= game and depth < 3 do
			if nameHit(p.Name) then return true end
			p = p.Parent; depth += 1
		end
		return false
	end
	local all = root:GetDescendants()
	if root:IsA("BasePart") then table.insert(all, 1, root) end
	for _, o in ipairs(all) do
		if o:IsA("BasePart") then
			report.parts += 1
			if not o.Anchored then report.unanchored += 1 end
			if o.CanCollide then report.can_collide_on += 1 else report.can_collide_off += 1 end
			groups[o.Name] = (groups[o.Name] or 0) + 1
			if o.CanCollide and isDecor(o) then
				report.decor_colliders += 1
				if #examples < 20 then table.insert(examples, instancePath(o)) end
			end
		end
	end
	local top = {}
	for n, c in pairs(groups) do table.insert(top, { name = n, count = c }) end
	table.sort(top, function(a, b) return a.count > b.count end)
	report.top_groups = {}
	for i = 1, math.min(15, #top) do report.top_groups[i] = top[i] end
	report.decor_examples = examples
	local fixed = {}
	if args.apply then
		waypoint("optimize apply " .. instancePath(root))
		local anchored, optimized = 0, 0
		for _, o in ipairs(all) do
			if o:IsA("BasePart") then
				if not o.Anchored then pcall(function() o.Anchored = true end); anchored += 1 end
				if (o.CanCollide or o.CanQuery or o.CanTouch) and isDecor(o) then
					pcall(function() o.CanCollide = false; o.CanQuery = false; o.CanTouch = false end)
					optimized += 1
				end
			end
		end
		fixed.anchored = anchored
		fixed.decor_optimized = optimized
		fixed.streaming = {}
		for _, p in ipairs({ "StreamingEnabled", "StreamingMeshLOD" }) do
			if pcall(function() workspace[p] = true end) then table.insert(fixed.streaming, p) end
		end
	end
	return { report = report, fixed = fixed }
end

local AUDIO_IDS = {
	forest = "rbxassetid://9112854440", wind = "rbxassetid://9112854440", cave = "rbxassetid://9112854440",
	city = "rbxassetid://9112854440", night = "rbxassetid://9112854440", cathedral = "rbxassetid://9112854440",
}
Commands.audio = function(args)
	local preset = tostring(args.preset or "")
	local kind, sub = preset:match("^(%w+)%.?(%w*)$")
	local SoundService = game:GetService("SoundService")
	waypoint("audio " .. preset)
	if kind == "reverb" then
		local map = { cave = "Cave", cathedral = "ConcertHall", sewer = "SewerPipe", arena = "Arena", city = "City" }
		local ename = map[sub] or tostring(sub)
		local ok, e = pcall(function() SoundService.AmbientReverb = Enum.ReverbType[ename] end)
		if not ok then
			ok, e = pcall(function() SoundService.AmbientReverb = Enum.ReverbType.GenericReverb end)
			if ok then ename = "GenericReverb" end
		end
		return { preset = preset, applied = ok, reverb = ename, error = not ok and tostring(e) or nil }
	end
	if kind ~= "ambience" and kind ~= "music" then
		error("unknown audio preset '" .. preset .. "' — groups: ambience.*, music.layer, reverb.*")
	end
	local holder
	if args.path then
		local inst, ierr = resolvePath(args.path)
		if not inst then error(ierr) end
		holder = inst
	else
		local parent, perr = resolvePath(args.parent_path or "Workspace")
		if not parent then error(perr) end
		local p = Instance.new("Part")
		p.Name = "RbxAudio_" .. preset:gsub("%.", "_"); p.Anchored = true
		p.CanCollide = false; p.CanQuery = false; p.CanTouch = false; p.Transparency = 1
		p.Size = Vector3.new(1, 1, 1); p.CFrame = CFrame.new(v3(args.position)); p.Parent = parent
		holder = p
	end
	local s = Instance.new("Sound")
	s.Name = "RbxAudio_" .. tostring(sub)
	s.SoundId = args.sound_id or AUDIO_IDS[sub] or AUDIO_IDS.forest
	s.Looped = true; s.Volume = args.volume or 0.4
	s.RollOffMinDistance = 8; s.RollOffMaxDistance = args.max_distance or 80
	if kind == "music" then
		local sg = SoundService:FindFirstChild("Music")
		if not sg then sg = Instance.new("SoundGroup"); sg.Name = "Music"; sg.Parent = SoundService end
		s.SoundGroup = sg
	end
	s.Parent = holder
	pcall(function() s:Play() end)
	return { path = instancePath(s), preset = preset }
end

Commands.cutscene = function(args)
	local name = args.name or "Cutscene1"
	local wps = args.waypoints or {}
	if #wps == 0 then error("cutscene needs at least one waypoint") end
	waypoint("cutscene " .. name)
	local lines = { "local WPS = {" }
	for _, w in ipairs(wps) do
		local p = v3(w.pos); local l = w.look and v3(w.look) or p
		table.insert(lines, string.format("\t{ pos = Vector3.new(%g, %g, %g), look = Vector3.new(%g, %g, %g), dur = %g, fov = %s },",
			p.X, p.Y, p.Z, l.X, l.Y, l.Z, tonumber(w.dur) or 2, w.fov and string.format("%g", w.fov) or "nil"))
	end
	table.insert(lines, "}")
	local src = table.concat(lines, "\n") .. "\n" .. string.format([=[
local SHAKE = %g
local LETTERBOX = %s
local DOF = %s
local Players = game:GetService("Players")
local TS = game:GetService("TweenService")
local RS = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local cam = workspace.CurrentCamera
local gui
if LETTERBOX then
	gui = Instance.new("ScreenGui")
	gui.Name = "RbxCutsceneLB"; gui.IgnoreGuiInset = true; gui.ResetOnSpawn = false; gui.DisplayOrder = 60
	local top = Instance.new("Frame")
	top.BackgroundColor3 = Color3.new(0, 0, 0); top.BorderSizePixel = 0
	top.Size = UDim2.new(1, 0, 0.1, 0); top.Position = UDim2.new(0, 0, -0.1, 0); top.Parent = gui
	local bot = top:Clone(); bot.Position = UDim2.new(0, 0, 1, 0); bot.Parent = gui
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	TS:Create(top, TweenInfo.new(0.8, Enum.EasingStyle.Quad), { Position = UDim2.new(0, 0, 0, 0) }):Play()
	TS:Create(bot, TweenInfo.new(0.8, Enum.EasingStyle.Quad), { Position = UDim2.new(0, 0, 0.9, 0) }):Play()
end
local dof
if DOF then
	dof = game:GetService("Lighting"):FindFirstChildOfClass("DepthOfFieldEffect") or Instance.new("DepthOfFieldEffect")
	dof.FarIntensity = 0; dof.Parent = game:GetService("Lighting")
	TS:Create(dof, TweenInfo.new(1), { FarIntensity = 0.6 }):Play()
end
local skipped = false
local conn = UIS.InputBegan:Connect(function(i) if i.KeyCode == Enum.KeyCode.Space then skipped = true end end)
cam.CameraType = Enum.CameraType.Scriptable
local baseFov = cam.FieldOfView
for _, w in ipairs(WPS) do
	if skipped then break end
	local t0 = os.clock()
	local dur = math.max(w.dur or 2, 0.05)
	local cf0 = cam.CFrame
	local target = CFrame.lookAt(w.pos, w.look)
	if w.fov then TS:Create(cam, TweenInfo.new(dur, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), { FieldOfView = w.fov }):Play() end
	while not skipped do
		local a = math.clamp((os.clock() - t0) / dur, 0, 1)
		cam.CFrame = cf0:Lerp(target, 0.5 - math.cos(a * math.pi) / 2)
		if SHAKE > 0 then
			cam.CFrame = cam.CFrame * CFrame.new((math.random() - 0.5) * SHAKE, (math.random() - 0.5) * SHAKE, 0)
		end
		if a >= 1 then break end
		RS.RenderStepped:Wait()
	end
end
cam.CFrame = CFrame.lookAt(WPS[#WPS].pos, WPS[#WPS].look)
cam.CameraType = Enum.CameraType.Custom
TS:Create(cam, TweenInfo.new(0.5), { FieldOfView = baseFov }):Play()
if dof then TS:Create(dof, TweenInfo.new(0.6), { FarIntensity = 0 }):Play() end
conn:Disconnect()
if gui then
	for _, f in ipairs(gui:GetChildren()) do
		if f:IsA("GuiObject") then
			local out = f.Position.Y.Scale < 0.5 and UDim2.new(0, 0, -0.1, 0) or UDim2.new(0, 0, 1, 0)
			TS:Create(f, TweenInfo.new(0.5), { Position = out }):Play()
		end
	end
	task.delay(0.6, function() gui:Destroy() end)
end
script:Destroy()
]=], tonumber(args.shake) or 0, tostring(args.letterbox ~= false), tostring(args.dof == true))
	local parent
	pcall(function() parent = game:GetService("StarterPlayer"):FindFirstChild("StarterPlayerScripts") end)
	parent = parent or StarterGui
	local old = parent:FindFirstChild(name)
	if old then old:Destroy() end
	local s = Instance.new("LocalScript")
	s.Name = name; s.Source = src; s.Parent = parent
	return { path = instancePath(s), steps = #wps }
end

-- scenario runner ---------------------------------------------------------
Commands.scenario = function(args)
	local report = { steps = {}, passed = 0, failed = 0 }
	local function checkExpect(ex, res)
		local cur, pass
		if ex.field == "parts_in_region" then
			local r = ex.region or {}
			local mn, mx = v3(r.min), v3(r.max)
			cur = #workspace:GetPartBoundsInBox(CFrame.new((mn + mx) / 2), mx - mn)
			pass = (ex.min == nil or cur >= ex.min) and (ex.max == nil or cur <= ex.max)
		elseif ex.field == "count_under" then
			local inst = resolvePath(ex.path)
			cur = inst and #inst:GetDescendants() or -1
			pass = (ex.min == nil or cur >= ex.min) and (ex.max == nil or cur <= ex.max) and (ex.eq == nil or cur == ex.eq)
		elseif ex.field == "memory_mb" then
			local mb
			pcall(function() mb = game:GetService("Stats"):GetTotalMemoryUsageMb() end)
			cur = mb or (collectgarbage("count") / 1024)
			pass = (ex.min == nil or cur >= ex.min) and (ex.max == nil or cur <= ex.max)
		elseif ex.field == "attr_eq" then
			local inst = resolvePath(ex.path)
			cur = inst and inst:GetAttribute(ex.attr) or nil
			pass = cur == ex.eq
		else
			cur = res
			for seg in tostring(ex.field):gmatch("[^%.]+") do cur = cur and cur[seg] end
			if ex.eq ~= nil then pass = cur == ex.eq
			elseif ex.contains ~= nil then pass = tostring(cur):find(tostring(ex.contains), 1, true) ~= nil
			else pass = cur ~= nil end
		end
		return pass, cur
	end
	for i, step in ipairs(args.steps or {}) do
		local fn = Commands[step.cmd]
		local entry = { i = i, cmd = step.cmd or "shot" }
		if step.shot then
			local spec = step.shot.camera or {}
			local pos = v3(spec.pos)
			local look = spec.look and v3(spec.look) or pos
			local cam = workspace.CurrentCamera
			cam.CameraType = Enum.CameraType.Scriptable
			cam.CFrame = CFrame.lookAt(pos, look)
			entry.ok = true
			entry.result = { camera_spec = { pos = spec.pos, look = spec.look } }
		elseif not fn then
			entry.ok = false; entry.error = "unknown cmd '" .. tostring(step.cmd) .. "'"
		else
			local ok, res = xpcall(function() return fn(step.args or {}) end, debug.traceback)
			entry.ok = ok
			if ok then
				local fails = {}
				for _, ex in ipairs(step.expect or {}) do
					local pass, cur = checkExpect(ex, res)
					if not pass then
						local want = ex.eq or ex.contains
							or ((ex.min ~= nil or ex.max ~= nil) and (tostring(ex.min) .. ".." .. tostring(ex.max))) or "exists"
						table.insert(fails, { field = ex.field, got = tostring(cur), want = want })
					end
				end
				entry.result = toData(res)
				if #fails > 0 then entry.ok = false; entry.expect_failed = fails end
			else entry.error = tostring(res) end
		end
		if entry.ok then report.passed += 1 else report.failed += 1 end
		table.insert(report.steps, entry)
		if entry.ok == false and args.stop_on_fail then break end
	end
	return report
end

-- transport: long-poll loop
----------------------------------------------------------------------
local running = false
local function post(path, body)
	local ok, res = pcall(function()
		return HttpService:RequestAsync({
			Url = BASE .. path, Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = HttpService:JSONEncode(body or {}),
		})
	end)
	if not ok then return nil, tostring(res) end
	if not res.Success then return nil, "HTTP " .. tostring(res.StatusCode) end
	if not res.Body or res.Body == "" then return {} end
	local ok2, parsed = pcall(function() return HttpService:JSONDecode(res.Body) end)
	return ok2 and parsed or {}, ok2 and nil or "json decode failed"
end

local function sendResult(lease, ok, payload)
	local eok, encoded = pcall(function()
		return HttpService:JSONEncode({ lease = lease, ok = ok, result = payload })
	end)
	if not eok then
		encoded = HttpService:JSONEncode({ lease = lease, ok = false, result = "result not JSON-serializable: " .. tostring(encoded) })
	end
	-- chunk very large results (broker reassembles)
	local CHUNK = 480000
	if #encoded <= CHUNK then
		post("/v1/result", { lease = lease, ok = ok, result = payload })
	else
		local raw = HttpService:JSONEncode(payload)
		local total = math.ceil(#raw / CHUNK)
		for i = 0, total - 1 do
			post("/v1/result", { lease = lease, ok = ok, chunk = i, total = total, data = raw:sub(i * CHUNK + 1, (i + 1) * CHUNK) })
		end
	end
end

local toolbar = plugin:CreateToolbar("RbxMcp")
local button = toolbar:CreateButton("rbx-mcp", "Connect to rbx-mcp broker (127.0.0.1:" .. PORT .. ")", "")
button.ClickableWhenViewportHidden = true

local gen = 0          -- connection generation: stale loops self-terminate
local lastTick = 0     -- last successful poll/command time (watchdog probe)

local function connect()
	if running then return end
	running = true
	button:SetActive(true)
	local hello = post("/v1/hello", {
		studioId = STUDIO_ID, place = game.Name, placeId = game.PlaceId, version = VERSION,
		caps = { "run_luau", "tree", "crud", "gui", "terrain", "rig", "audit", "import" },
	})
	if not hello then
		warn("[rbx-mcp] broker not reachable on " .. BASE .. " — run `rbx-mcp broker` or connect via an agent")
		running = false
		button:SetActive(false)
		return
	end
	print("[rbx-mcp] connected to broker — studioId " .. STUDIO_ID)
	gen += 1
	local myGen = gen
	lastTick = os.clock()
	task.spawn(function()
		while running and gen == myGen do
			-- whole iteration protected: a thrown error must never kill the loop
			local iterOk, iterErr = xpcall(function()
				local cmd, err = post("/v1/poll", { studioId = STUDIO_ID, wait = POLL_WAIT })
				lastTick = os.clock() -- any completed request proves liveness
				if cmd and cmd.id then
					local fn = Commands[cmd.cmd]
					if not fn then
						sendResult(cmd.lease, false, "unknown command '" .. tostring(cmd.cmd) .. "'")
					else
						local ok, res = xpcall(function() return fn(cmd.args or {}) end, debug.traceback)
						sendResult(cmd.lease, ok, ok and res or tostring(res))
					end
				elseif err and not tostring(err):find("HTTP 204") then
					task.wait(2) -- broker down → gentle retry
				else
					task.wait(0.25) -- idle: don't spin-tight-poll the broker
				end
			end, debug.traceback)
			if not iterOk then
				warn("[rbx-mcp] poll loop error (continuing): " .. tostring(iterErr))
				pcall(function()
					post("/v1/result", { lease = "loop", ok = false, result = "loop error: " .. tostring(iterErr) })
				end)
				task.wait(2)
			end
		end
	end)
end

local function disconnect()
	running = false
	button:SetActive(false)
end

-- watchdog: if the poll loop stops producing heartbeats while "connected"
-- (wedged RequestAsync, dead thread, broker restarted under us), force a
-- reconnect — the retry loop below picks it up and spawns a fresh loop.
task.spawn(function()
	while true do
		task.wait(15)
		if running and os.clock() - lastTick > 120 then
			warn("[rbx-mcp] watchdog: no poll progress in 120s — reconnecting")
			disconnect()
		end
	end
end)

button.Click:Connect(function()
	if running then disconnect() else connect() end
end)

plugin.Unloading:Connect(disconnect)

-- auto-connect with retry — broker may start after Studio loads us
task.spawn(function()
	task.wait(2)
	while true do
		if not running then pcall(connect) end
		task.wait(10)
	end
end)
