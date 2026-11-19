-- Stand-ins for the parts of the Civ6 UI API the mod uses.
-- Controls come from the mod's own XML, so a Lua/XML ID mismatch fails here the same way it would in game.
local M = {};

local function ReadFile(path)
	local f = assert(io.open(path, "r"), "cannot open " .. path);
	local s = f:read("*a");
	f:close();
	return s;
end
M.ReadFile = ReadFile;

-- ---------------------------------------------------------------------------
-- XML
-- ---------------------------------------------------------------------------
local function ParseElements(chunk)
	local list = {};
	for attrs in chunk:gmatch("<%w+(%s[^>]-)/?>") do
		local id = attrs:match('ID="([^"]+)"');
		if id ~= nil then
			table.insert(list, {
				id = id,
				hidden = attrs:match('Hidden="1"') ~= nil,
				padding = tonumber(attrs:match('StackPadding="(%d+)"')),
			});
		end
	end
	return list;
end

function M.ParseContext(xml)
	local top = xml:gsub("<Instance.-</Instance>", "");
	local instances = {};
	for name, body in xml:gmatch('<Instance%s+Name="([^"]+)"%s*>(.-)</Instance>') do
		instances[name] = ParseElements(body);
	end
	return ParseElements(top), instances;
end

function M.ParseText(xml)
	local english, russian = {}, {};
	local base = xml:match("<BaseGameText>(.-)</BaseGameText>") or "";
	for tag, value in base:gmatch('<Replace Tag="([^"]+)">%s*<Text>(.-)</Text>') do
		english[tag] = value;
	end
	local localized = xml:match("<LocalizedText>(.-)</LocalizedText>") or "";
	for tag, value in localized:gmatch('<Replace Tag="([^"]+)" Language="ru_RU">%s*<Text>(.-)</Text>') do
		russian[tag] = value;
	end
	return english, russian;
end

-- ---------------------------------------------------------------------------
-- Controls
-- ---------------------------------------------------------------------------
local Control = {};
Control.__index = Control;

local function NewControl(spec)
	return setmetatable({
		id = spec.id, hidden = spec.hidden or false, padding = spec.padding or 0,
		text = "", x = 0, y = 0, w = 0, h = 0, children = {}, callbacks = {},
	}, Control);
end

M.NewControl = NewControl;

function Control:SetHide(v) self.hidden = v and true or false end
function Control:IsHidden() return self.hidden end
function Control:SetText(t)
	assert(t == nil or type(t) == "string" or type(t) == "number", self.id .. ":SetText got " .. type(t));
	self.text = t == nil and "" or tostring(t);
end
function Control:GetText() return self.text end
function Control:SetOffsetVal(x, y) self.x, self.y = x, y end
function Control:GetOffsetX() return self.x end
function Control:GetOffsetY() return self.y end
function Control:SetSizeVal(w, h) self.w, self.h = w, h end
function Control:SetSizeX(w) self.w = w end
function Control:GetSizeX() return self.w end
function Control:GetSizeY() return self.h end
function Control:SetSelected(v) self.selected = v and true or false end
function Control:SetIcon(name) self.icon = name end
function Control:SetAnchor(anchor) self.anchor = anchor end

function Control:ChangeParent(parent)
	if self.parent ~= nil then
		local kept = {};
		for _, child in ipairs(self.parent.children) do
			if child ~= self then table.insert(kept, child) end
		end
		self.parent.children = kept;
	end
	self.parent = parent;
	if parent ~= nil then table.insert(parent.children, self) end
end
function Control:IsSelected() return self.selected == true end
function Control:SetWrapWidth(w) self.wrap = w end
function Control:ReprocessAnchoring() end
function Control:CalculateInternalSize() end
function Control:GetChildren() return self.children end
function Control:RegisterCallback(event, fn) self.callbacks[event] = fn end
function Control:GetID() return self.id end
function Control:GetParent() return self.parent end
function Control:SetToolTipString(text) self.tooltip = tostring(text or "") end
function Control:SetColor(color) self.color = color end

function Control:CalculateSize()
	local h, n = 0, 0;
	for _, c in ipairs(self.children) do
		if not c.hidden then
			h = h + c.h;
			n = n + 1;
		end
	end
	if n > 1 then h = h + (n - 1) * self.padding end
	self.h = h;
end

function Control:Click()
	local fn = self.callbacks[M.Mouse.eLClick];
	assert(fn ~= nil, self.id .. " has no click callback");
	fn();
end

local function ControlSet(specs, what)
	local set = {};
	for _, spec in ipairs(specs) do
		set[spec.id] = NewControl(spec);
	end
	return setmetatable(set, {
		__index = function(_, key)
			error(what .. " has no control '" .. tostring(key) .. "'", 2);
		end,
	});
end

local function EventTable()
	return setmetatable({}, {
		__index = function(t, name)
			local handlers = {};
			local ev = setmetatable({
				Add = function(fn) table.insert(handlers, fn) end,
				Remove = function(fn)
					for i, h in ipairs(handlers) do
						if h == fn then table.remove(handlers, i) return end
					end
				end,
			}, {
				__call = function(_, ...)
					for _, h in ipairs(handlers) do h(...) end
				end,
			});
			rawset(t, name, ev);
			return ev;
		end,
	});
end

M.Mouse = { eLClick = 1, eRClick = 2 };

local DEAL_ITEM_TYPES = { GOLD = 1, RESOURCES = 2, AGREEMENTS = 3, CITIES = 4, UNITS = 5, GREATWORK = 6, CAPTIVE = 7, DIPLOMATIC_FAVOR = 8 };
local AGREEMENT_TYPES = {
	OPEN_BORDERS = 1, ALLIANCE = 2, DEFENSIVE_PACT = 3, RESEARCH_AGREEMENT = 4,
	JOINT_WAR = 5, THIRD_PARTY_WAR = 6, MAKE_PEACE = 7,
};

-- ---------------------------------------------------------------------------
-- World
-- ---------------------------------------------------------------------------
local World = {};
World.__index = World;

-- opts: modDir, localPlayer, turn, players = { [id] = { leader, civ } }, screen = { w, h }, gameText
function M.new(opts)
	opts = opts or {};
	local w = setmetatable({}, World);
	w.modDir = assert(opts.modDir, "modDir is required");
	w.localPlayer = opts.localPlayer or 0;
	w.turn = opts.turn or 1;
	w.players = opts.players or { [0] = { leader = "Peter", civ = "Russia" }, [1] = { leader = "Gandhi", civ = "India" } };
	w.screenW = (opts.screen and opts.screen[1]) or 1920;
	w.screenH = (opts.screen and opts.screen[2]) or 1080;
	w.deals = {};
	w.sessions = {};
	w.logs = {};
	w.managers = {};
	w.resources = {};
	w.greatWorks = {};
	w.actions = {};
	w.gameText = opts.gameText or {};
	w.failDeals = false;
	w.properties = {};
	w.config = {};
	w.operations = {};
	w.exposed = {};
	w.working = nil;
	w.onSend = nil;

	local contextSpecs, instanceSpecs = M.ParseContext(ReadFile(w.modDir .. "/UI/DealOverview.xml"));
	w.instanceSpecs = instanceSpecs;
	w.Controls = ControlSet(contextSpecs, "Controls");
	w.text = M.ParseText(ReadFile(w.modDir .. "/Text/DealOverview_Text.xml"));

	w.view = NewControl({ id = "DiplomacyActionView", hidden = true });
	w.playerContainer = NewControl({ id = "PlayerContainer" });
	local column = NewControl({ id = "LeaderColumn" });
	column.w = 560;
	table.insert(w.playerContainer.children, column);

	w.dealView = NewControl({ id = "DiplomacyDealView", hidden = true });
	-- As in the game: the animated parents of the deal banner are Size="parent,parent".
	w.tradePanelFade = NewControl({ id = "TradePanelFade" });
	w.tradePanelSlide = NewControl({ id = "TradePanelSlide" });
	w.tradePanelFade.w = w.screenW;
	w.tradePanelSlide.w = w.screenW;
	table.insert(w.tradePanelFade.children, w.tradePanelSlide);
	table.insert(w.dealView.children, w.tradePanelFade);

	local function LuxuryColumn(scrollID, stackID)
		local scroll = NewControl({ id = scrollID });
		local stack = NewControl({ id = stackID });
		local list = NewControl({ id = "List" });
		local title = NewControl({ id = "Title" });
		local titleText = NewControl({ id = "TitleText" });
		local listStack = NewControl({ id = "ListStack" });
		titleText.parent = title;
		title.parent = list;
		listStack.parent = list;
		list.parent = stack;
		stack.parent = scroll;
		scroll.parent = w.dealView;
		table.insert(title.children, titleText);
		table.insert(list.children, title);
		table.insert(list.children, listStack);
		table.insert(stack.children, list);
		table.insert(w.dealView.children, scroll);
		return stack, list, titleText;
	end

	w.inventoryStack, w.luxuryList, w.luxuryTitleText = LuxuryColumn("MyInventoryScroll", "MyInventoryStack");
	w.theirInventoryStack, w.theirLuxuryList, w.theirLuxuryTitleText = LuxuryColumn("TheirInventoryScroll", "TheirInventoryStack");
	return w;
end

function World:AddResource(index, resourceType, name, className)
	self.resources[index] = {
		Index = index,
		ResourceType = resourceType,
		Name = "LOC_" .. resourceType .. "_NAME",
		ResourceClassType = className or "RESOURCECLASS_LUXURY",
	};
	self.gameText["LOC_" .. resourceType .. "_NAME"] = name;
end

-- items: { type = "GOLD", from = 0, amount = 5, duration = 30, enacted = 10, subType = "ALLIANCE", valueType = 1, name = "LOC_..." }
function World:AddDeal(a, b, items, id)
	table.insert(self.deals, { a = a, b = b, items = items, id = id or (1000 + #self.deals) });
end

local function NewItem(spec)
	local item = {};
	function item:GetType() return DEAL_ITEM_TYPES[spec.type] end
	function item:GetAmount() return spec.amount or 0 end
	function item:GetDuration() return spec.duration or 0 end
	function item:GetSubType() return spec.subType and AGREEMENT_TYPES[spec.subType] or -1 end
	function item:GetFromPlayerID() return spec.from end
	function item:GetEnactedTurn() return spec.enacted or -1 end
	function item:GetValueType() return spec.valueType or -1 end
	function item:GetValueTypeNameID() return spec.name end
	if spec.subTypeName ~= nil then
		function item:GetSubTypeNameID() return spec.subTypeName end
	end
	if spec.endTurn ~= nil then
		function item:GetEndTurn() return spec.endTurn end
	end
	return item;
end

local function NewDeal(spec)
	local deal = {};
	function deal:GetID() return spec.id end
	function deal:Items()
		local i = 0;
		return function()
			i = i + 1;
			if spec.items[i] == nil then return nil end
			return NewItem(spec.items[i]);
		end
	end
	return deal;
end

function World:Lookup(key, ...)
	local template = self.text[key] or self.gameText[key];
	if template == nil then return key end
	local args = { ... };
	return (template:gsub("{(%d+)_[^}]*}", function(n)
		local v = args[tonumber(n)];
		if v == nil then return nil end
		return tostring(v);
	end));
end

function World:Environment()
	local w = self;
	local InstanceManager = {};
	InstanceManager.__index = InstanceManager;
	function InstanceManager:new(name, rootID, parent)
		local specs = assert(w.instanceSpecs[name], "no <Instance Name=\"" .. tostring(name) .. "\">");
		local im = setmetatable({ name = name, specs = specs, root = rootID, parent = parent, items = {} }, InstanceManager);
		table.insert(w.managers, im);
		return im;
	end
	function InstanceManager:GetInstance(parent)
		parent = parent or self.parent;
		local inst = ControlSet(self.specs, "instance");
		local root = inst[self.root];
		root.hidden = false;
		root.parent = parent;
		table.insert(parent.children, root);
		table.insert(self.items, inst);
		return inst;
	end
	function InstanceManager:ResetInstances()
		for _, inst in ipairs(self.items) do
			local root = inst[self.root];
			root.hidden = true;
			local parent = root.parent;
			if parent ~= nil then
				local kept = {};
				for _, child in ipairs(parent.children) do
					if child ~= root then table.insert(kept, child) end
				end
				parent.children = kept;
			end
		end
		self.items = {};
	end

	local players = {};
	for id, p in pairs(w.players) do
		players[id] = {
			GetLeaderName = function() return p.leader end,
			GetCivilizationDescription = function() return p.civ end,
		};
	end

	return {
		-- As in the game: a mod file is found by include only when the modinfo imports it.
		-- A missing file is skipped silently, the same way the game does.
		include = function(file)
			if file == nil or file == "InstanceManager" then return end
			local name = file:gsub("%.lua$", "");
			local modinfo = ReadFile(w.modDir .. "/UI_Extender.modinfo");
			for block in modinfo:gmatch("<ImportFiles.-</ImportFiles>") do
				for path in block:gmatch("<File>(.-)</File>") do
					if path:match("([^/]+)%.lua$") == name then
						local chunk = assert(loadfile(w.modDir .. "/" .. path));
						setfenv(chunk, getfenv(2));
						chunk();
						return;
					end
				end
			end
		end,
		print = function(...)
			local parts = {};
			for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
			table.insert(w.logs, table.concat(parts, "\t"));
		end,
		InstanceManager = InstanceManager,
		Controls = w.Controls,
		Mouse = M.Mouse,
		LuaEvents = w.LuaEvents,
		Events = w.Events,
		ContextPtr = {
			SetHide = function() end,
			SetUpdate = function(_, fn) w.update = fn end,
			LookUpControl = function(_, path)
				if path == "/InGame/DiplomacyActionView" then return w.view end
				if path == "/InGame/DiplomacyActionView/PlayerContainer" then return w.playerContainer end
				if path == "/InGame/DiplomacyDealView" then return w.dealView end
				if path == "/InGame/DiplomacyDealView/MyInventory/MyInventoryScroll/MyInventoryStack" then return w.inventoryStack end
				if path == "/InGame/DiplomacyDealView/TheirInventory/TheirInventoryScroll/TheirInventoryStack" then return w.theirInventoryStack end
				return nil;
			end,
		},
		UIManager = { GetScreenSizeVal = function() return w.screenW, w.screenH end },
		Locale = {
			Lookup = function(key, ...) return w:Lookup(key, ...) end,
			ToUpper = function(s) return string.upper(s) end,
		},
		Game = {
			GetLocalPlayer = function() return w.localPlayer end,
			GetCurrentGameTurn = function() return w.turn end,
			GetProperty = function(_, key) return w.properties[key] end,
			SetProperty = function(_, key, value) w.properties[key] = value end,
		},
		GameConfiguration = {
			GetValue = function(key) return w.config[key] end,
			SetValue = function(key, value) w.config[key] = value end,
			IsNetworkMultiplayer = function() return false end,
		},
		PlayerConfigurations = players,
		PlayerManager = {
			GetAliveMajors = function()
				local list = {};
				for id in pairs(w.players) do
					table.insert(list, { GetID = function() return id end });
				end
				table.sort(list, function(x, y) return x:GetID() < y:GetID() end);
				return list;
			end,
		},
		DiplomacyManager = {
			FindOpenSessionID = function(_, other) return w.sessions[other] or -1 end,
		},
		DealManager = {
			GetPlayerDeals = function(a, b)
				if w.failDeals then error("GetPlayerDeals failed") end
				local list = {};
				for _, d in ipairs(w.deals) do
					if (d.a == a and d.b == b) or (d.a == b and d.b == a) then
						table.insert(list, NewDeal(d));
					end
				end
				return list;
			end,
			GetWorkingDeal = function(_, a, b)
				local spec = w.working;
				if spec == nil or spec.a ~= a or spec.b ~= b then return nil end
				return NewDeal(spec);
			end,
			SendWorkingDeal = function(action, a, b)
				if w.onSend ~= nil then w.onSend(action, a, b) end
			end,
		},
		UI = {
			GetColorValue = function(r, g, b, a)
				return string.format("%.2f,%.2f,%.2f,%.2f", r, g, b, a or 1);
			end,
			RequestPlayerOperation = function(player, op, params)
				table.insert(w.operations, { player = player, op = op, params = params });
			end,
		},
		PlayerOperations = { EXECUTE_SCRIPT = 1 },
		DealDirection = { INCOMING = 0, OUTGOING = 1 },
		DealProposalAction = { PROPOSED = 0, ACCEPTED = 1, REJECTED = 2 },
		ExposedMembers = w.exposed,
		GameEvents = w.GameEvents,
		DealItemTypes = DEAL_ITEM_TYPES,
		DealAgreementTypes = AGREEMENT_TYPES,
		GameInfo = { Resources = w.resources, DiplomaticActions = w.actions, GreatWorks = w.greatWorks },
	};
end

function World:OpenEnv(file)
	self.LuaEvents = self.LuaEvents or EventTable();
	self.Events = self.Events or EventTable();
	self.GameEvents = self.GameEvents or EventTable();
	local env = self:Environment();
	setmetatable(env, { __index = _G });
	local chunk = assert(loadfile(file));
	setfenv(chunk, env);
	chunk();
	return env;
end

function World:Load()
	self.env = self:OpenEnv(self.modDir .. "/UI/DealOverview.lua");
	assert(self.update ~= nil, "mod did not call ContextPtr:SetUpdate");
	return self;
end

-- Loading a save: Game properties survive, every Lua context and handler starts over.
function World:Reload()
	self.LuaEvents = nil;
	self.Events = nil;
	self.GameEvents = nil;
	self.managers = {};
	for key in pairs(self.exposed) do self.exposed[key] = nil end
	self.update = nil;
	self.view.hidden = true;
	self.dealView.hidden = true;
	self:LoadGameplay();
	return self:Load();
end

function World:LoadGameplay()
	self.gameplay = self:OpenEnv(self.modDir .. "/Scripts/DealArchive.lua");
	return self;
end

function World:Tick(frames)
	for _ = 1, frames or 10 do self.update() end
end

function World:OpenDiplomacy(playerID)
	if playerID ~= nil then
		self.LuaEvents.DiplomacyRibbon_OpenDiplomacyActionView(playerID);
	end
	self.view.hidden = false;
	if playerID ~= nil then
		self.LuaEvents.DiploScene_SceneOpened(playerID);
	end
	self:Tick();
end

function World:CloseDiplomacy()
	self.view.hidden = true;
	self.LuaEvents.DiploScene_SceneClosed();
	self:Tick();
end

function World:OpenDeal()
	if self.gameText["LOC_DIPLOMACY_DEAL_LUXURY_RESOURCES"] == nil then
		self.gameText["LOC_DIPLOMACY_DEAL_LUXURY_RESOURCES"] = "Luxury Resources";
	end
	self.luxuryTitleText.text = self:Lookup("LOC_DIPLOMACY_DEAL_LUXURY_RESOURCES");
	self.theirLuxuryTitleText.text = self:Lookup("LOC_DIPLOMACY_DEAL_LUXURY_RESOURCES");
	self.dealView.hidden = false;
	self:Tick();
end

function World:CloseDeal()
	self.dealView.hidden = true;
	self:Tick();
end

function World:Manager(name)
	for _, im in ipairs(self.managers) do
		if im.name == name then return im end
	end
	return nil;
end

function World:Cards()
	local im = self:Manager("DealCard");
	assert(im ~= nil, "DealCard manager missing");
	return im.items;
end

-- Builds the intel report the game makes for a diplomacy partner: tab buttons, panel container, header.
function World:IntelReport()
	local stack = M.NewControl({ id = "IntelTabButtonStack" });
	local container = M.NewControl({ id = "IntelPanelContainer" });
	container.w = 500;
	local header = M.NewControl({ id = "IntelHeader" });
	local game = M.NewControl({ id = "IntelPanel" });
	local gamePanel = M.NewControl({ id = "OverviewPanel" });
	table.insert(container.children, gamePanel);
	table.insert(game.children, stack);
	table.insert(game.children, container);
	table.insert(game.children, header);
	table.insert(self.view.children, game);
	return { stack = stack, container = container, header = header, gamePanel = gamePanel };
end

function World:DealsTab()
	local button = self:Manager("DealsTabButton");
	local panel = self:Manager("DealsTabPanel");
	assert(button ~= nil and panel ~= nil, "deals tab managers missing");
	return button.items[1], panel.items[1];
end

function World:FlowBlocks()
	local im = self:Manager("FlowBlock");
	return im and im.items or {};
end

function World:FlowIcons()
	local im = self:Manager("FlowIcon");
	return im and im.items or {};
end

function World:Errors()
	local list = {};
	for _, line in ipairs(self.logs) do
		if line:find("ERROR", 1, true) then table.insert(list, line) end
	end
	return list;
end

-- Every text the mod has put on screen, for catching unresolved LOC_ keys.
function World:AllTexts()
	local list = {};
	local function collect(set)
		for _, c in pairs(set) do
			if c.text ~= "" then table.insert(list, c.id .. "=" .. c.text) end
		end
	end
	collect(self.Controls);
	for _, im in ipairs(self.managers) do
		for _, inst in ipairs(im.items) do collect(inst) end
	end
	return list;
end

return M;
