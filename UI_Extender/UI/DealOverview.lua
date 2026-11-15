-- Active deals panel on the diplomacy screen.
include("InstanceManager");

ContextPtr:SetHide(false);

local LEFT_COLUMN_FALLBACK = 578;
local COLUMN_GAP = 6;
local SCREEN_MARGIN = 12;
local TOP_LIMIT_FRACTION = 0.40;
local HEADER_HEIGHT = 36;
local FOOTER_HEIGHT = 40;
local SCROLL_TOP = 44;
local CARD_PADDING = 10;
local ROW_HEIGHT = 22;
local CHAR_WIDTH = 9;

local m_DealIM = nil;
local m_Open = false;
local m_Expanded = true;
local m_OtherPlayerID = -1;
local m_CardWidth = 560;
local m_UpdateTick = 0;

-- ---------------------------------------------------------------------------
-- Diagnostics: Lua.log (needs EnableTuner 1 in AppOptions.txt) plus an on-screen error line.
-- ---------------------------------------------------------------------------
local function Log(message)
	print("UIExt: " .. tostring(message));
end

local function ShowError(where, err)
	Log("ERROR " .. where .. ": " .. tostring(err));
	pcall(function()
		Controls.DebugLabel:SetText("UIExt " .. where .. ": " .. tostring(err));
		Controls.DebugBox:SetHide(false);
	end);
end

local function Try(where, fn, ...)
	local ok, err = pcall(fn, ...);
	if not ok then
		ShowError(where, err);
	end
	return ok;
end

-- ---------------------------------------------------------------------------
-- Text helpers
-- ---------------------------------------------------------------------------
local function Lookup(key)
	if key == nil or key == "" then return "" end
	local ok, text = pcall(Locale.Lookup, key);
	if ok and text ~= nil then return text end
	return tostring(key);
end

local function Format(key, ...)
	local ok, text = pcall(Locale.Lookup, key, ...);
	if ok and text ~= nil then return text end
	return tostring(key);
end

local function Call(object, method)
	local fn = object[method];
	if fn == nil then return nil end
	local ok, value = pcall(fn, object);
	if ok then return value end
	return nil;
end

local function LocalPlayerID()
	local id = Game.GetLocalPlayer();
	if id == nil or id < 0 then return -1 end
	return id;
end

local function LeaderName(playerID)
	local cfg = PlayerConfigurations[playerID];
	if cfg == nil then return "" end
	return Lookup(Call(cfg, "GetLeaderName"));
end

local function CivName(playerID)
	local cfg = PlayerConfigurations[playerID];
	if cfg == nil then return "" end
	return Lookup(Call(cfg, "GetCivilizationDescription"));
end

-- ---------------------------------------------------------------------------
-- Deal items
-- ---------------------------------------------------------------------------
local function ItemKind(rawType)
	if DealItemTypes == nil then return "" end
	for name, value in pairs(DealItemTypes) do
		if value == rawType then
			if name == "DIPLOMATIC_FAVOR" then return "FAVOR" end
			return name;
		end
	end
	return "";
end

local function AgreementIs(subType, name)
	return DealAgreementTypes ~= nil and DealAgreementTypes[name] ~= nil and subType == DealAgreementTypes[name];
end

local function IsMutual(subType)
	return AgreementIs(subType, "DEFENSIVE_PACT")
		or AgreementIs(subType, "RESEARCH_AGREEMENT")
		or AgreementIs(subType, "JOINT_WAR")
		or AgreementIs(subType, "THIRD_PARTY_WAR")
		or AgreementIs(subType, "MAKE_PEACE")
		or AgreementIs(subType, "ALLIANCE");
end

local function RemainingTurns(item, duration)
	if duration == nil or duration <= 0 then return nil end
	local current = Game.GetCurrentGameTurn();
	local enacted = Call(item, "GetEnactedTurn");
	if enacted ~= nil and enacted >= 0 then
		local remaining = duration - (current - enacted);
		if remaining < 0 then remaining = 0 end
		if remaining > duration then remaining = duration end
		return remaining;
	end
	local endTurn = Call(item, "GetEndTurn");
	if endTurn ~= nil and endTurn > 0 then
		return math.max(0, endTurn - current);
	end
	return nil;
end

local function AgreementName(item, subType)
	local nameID = Call(item, "GetSubTypeNameID");
	if nameID ~= nil and nameID ~= "" then return Lookup(nameID) end
	local info = GameInfo.DiplomaticActions[subType];
	if info ~= nil then return Lookup(info.Name) end
	return "";
end

local function ItemText(item, kind, amount, subType)
	if kind == "GOLD" then
		return Format("LOC_UIEXT_DEALS_GOLD_PER_TURN", amount);
	elseif kind == "RESOURCES" then
		local resource = GameInfo.Resources[Call(item, "GetValueType")];
		if resource ~= nil then
			return tostring(amount) .. " [ICON_" .. resource.ResourceType .. "] " .. Lookup(resource.Name);
		end
		return tostring(amount) .. " " .. Lookup(Call(item, "GetValueTypeNameID"));
	elseif kind == "AGREEMENTS" then
		return AgreementName(item, subType);
	end
	return Lookup(Call(item, "GetValueTypeNameID"));
end

-- Only lasting items: the game drops one-time items on the turn the deal is enacted.
local function DescribeItem(item)
	local kind = ItemKind(Call(item, "GetType"));
	if kind ~= "GOLD" and kind ~= "RESOURCES" and kind ~= "AGREEMENTS" then return nil end

	local duration = Call(item, "GetDuration") or 0;
	local subType = Call(item, "GetSubType") or -1;
	local isAlliance = kind == "AGREEMENTS" and AgreementIs(subType, "ALLIANCE");
	if duration <= 0 and not isAlliance then return nil end

	local fromPlayer = Call(item, "GetFromPlayerID");
	if fromPlayer == nil then return nil end

	local remaining = RemainingTurns(item, duration);
	return {
		text = ItemText(item, kind, Call(item, "GetAmount") or 0, subType),
		fromPlayer = fromPlayer,
		remaining = remaining,
		openEnded = remaining == nil,
		mutual = kind == "AGREEMENTS" and IsMutual(subType),
	};
end

local function ReadDeal(deal, localID)
	local card = { ours = {}, theirs = {}, shared = {} };
	local seenShared = {};
	local ok, iter, state, first = pcall(deal.Items, deal);
	if not ok or iter == nil then return card end
	for item in iter, state, first do
		local entry = DescribeItem(item);
		if entry ~= nil then
			if entry.mutual then
				if not seenShared[entry.text] then
					seenShared[entry.text] = true;
					table.insert(card.shared, entry);
				end
			elseif entry.fromPlayer == localID then
				table.insert(card.ours, entry);
			else
				table.insert(card.theirs, entry);
			end
		end
	end
	return card;
end

local function SoonestTurns(card)
	local soonest = nil;
	for _, list in ipairs({ card.ours, card.theirs, card.shared }) do
		for _, e in ipairs(list) do
			if e.remaining ~= nil and (soonest == nil or e.remaining < soonest) then
				soonest = e.remaining;
			end
		end
	end
	return soonest;
end

local function GatherDeals(localID, otherID)
	local cards = {};
	if DealManager == nil then return cards end
	local ok, deals = pcall(DealManager.GetPlayerDeals, localID, otherID);
	if not ok or deals == nil then return cards end
	for _, deal in ipairs(deals) do
		local card = ReadDeal(deal, localID);
		if #card.ours + #card.theirs + #card.shared > 0 then
			card.soonest = SoonestTurns(card);
			table.insert(cards, card);
		end
	end
	table.sort(cards, function(a, b)
		if a.soonest == nil then return false end
		if b.soonest == nil then return true end
		return a.soonest < b.soonest;
	end);
	return cards;
end

-- Header text and whether each line needs its own turn count.
local function CardTiming(card)
	local turns = nil;
	local uniform = true;
	local anyOpen = false;
	local anyTimed = false;
	for _, list in ipairs({ card.ours, card.theirs, card.shared }) do
		for _, e in ipairs(list) do
			if e.openEnded then
				anyOpen = true;
			else
				anyTimed = true;
				if turns == nil then
					turns = e.remaining;
				elseif turns ~= e.remaining then
					uniform = false;
				end
			end
		end
	end
	if not anyTimed then return Lookup("LOC_UIEXT_DEALS_OPEN_ENDED"), false end
	if anyOpen or not uniform then return Lookup("LOC_UIEXT_DEALS_MIXED"), true end
	if turns <= 0 then return Lookup("LOC_UIEXT_DEALS_EXPIRES_NOW"), false end
	return Format("LOC_UIEXT_DEALS_REMAINING", turns), false;
end

-- ---------------------------------------------------------------------------
-- Card layout
-- ---------------------------------------------------------------------------
local function LineTexts(entries, showTurns)
	local lines = {};
	for _, e in ipairs(entries) do
		if showTurns and not e.openEnded then
			table.insert(lines, Format("LOC_UIEXT_DEALS_ITEM_TURNS", e.text, e.remaining));
		elseif showTurns then
			table.insert(lines, e.text .. " · " .. Lookup("LOC_UIEXT_DEALS_OPEN_ENDED"));
		else
			table.insert(lines, e.text);
		end
	end
	return lines;
end

-- Approximate on-screen width: icon tags draw as about two characters, UTF-8 counted by code points.
local function VisibleLength(line)
	local plain = line:gsub("%[.-%]", "xx");
	local _, count = plain:gsub("[^\128-\191]", "");
	return count;
end

local function TextHeight(lines, width)
	local perRow = math.max(1, math.floor(width / CHAR_WIDTH));
	local height = 0;
	for _, line in ipairs(lines) do
		height = height + math.max(1, math.ceil(VisibleLength(line) / perRow)) * ROW_HEIGHT;
	end
	return height;
end

local function PlaceBlock(titleLabel, bodyLabel, x, y, width, title, lines)
	if #lines == 0 then
		titleLabel:SetHide(true);
		bodyLabel:SetHide(true);
		return y;
	end
	titleLabel:SetOffsetVal(x, y);
	if title ~= nil then titleLabel:SetText(title) end
	titleLabel:SetHide(false);
	y = y + 20;
	bodyLabel:SetOffsetVal(x, y);
	bodyLabel:SetWrapWidth(width);
	bodyLabel:SetText(table.concat(lines, "[NEWLINE]"));
	bodyLabel:SetHide(false);
	return y + TextHeight(lines, width);
end

local function PopulateCard(inst, card, leaderName)
	local header, showTurns = CardTiming(card);
	inst.Header:SetText(header);

	local fullWidth = m_CardWidth - CARD_PADDING * 2;
	local y = 30;
	y = PlaceBlock(inst.SharedTitle, inst.SharedBody, CARD_PADDING, y, fullWidth, nil, LineTexts(card.shared, showTurns));
	if #card.shared > 0 then y = y + 6 end

	local colWidth = math.floor((fullWidth - CARD_PADDING) / 2);
	local leftX = CARD_PADDING;
	local rightX = CARD_PADDING * 2 + colWidth;
	local ours = LineTexts(card.ours, showTurns);
	local theirs = LineTexts(card.theirs, showTurns);
	local oursTitle = Lookup("LOC_UIEXT_DEALS_WE_GIVE");
	local theirsTitle = Format("LOC_UIEXT_DEALS_THEY_GIVE", leaderName);

	local theirsX = rightX;
	if #ours == 0 then theirsX = leftX end
	local yOurs = PlaceBlock(inst.OursTitle, inst.OursBody, leftX, y, colWidth, oursTitle, ours);
	local yTheirs = PlaceBlock(inst.TheirsTitle, inst.TheirsBody, theirsX, y, colWidth, theirsTitle, theirs);
	y = math.max(yOurs, yTheirs);

	local height = y + 8;
	inst.Top:SetSizeVal(m_CardWidth, height);
	inst.Background:SetSizeVal(m_CardWidth, height);
	inst.TopRule:SetSizeVal(m_CardWidth, 1);
end

-- ---------------------------------------------------------------------------
-- Diplomacy screen
-- ---------------------------------------------------------------------------
local function DiplomacyIsOpen()
	local view = ContextPtr:LookUpControl("/InGame/DiplomacyActionView");
	return view ~= nil and not view:IsHidden();
end

-- Layout offsets rather than screen position: the column slides in from the left when the screen opens.
local function LeftColumnEdge()
	local edge = 0;
	pcall(function()
		local container = ContextPtr:LookUpControl("/InGame/DiplomacyActionView/PlayerContainer");
		if container == nil then return end
		local base = container:GetOffsetX();
		for _, child in ipairs(container:GetChildren()) do
			local right = base + child:GetOffsetX() + child:GetSizeX();
			if right > edge then edge = right end
		end
	end);
	local screenW = UIManager:GetScreenSizeVal();
	if edge < 200 or edge > screenW * 0.6 then
		edge = LEFT_COLUMN_FALLBACK;
	end
	return edge;
end

local function RememberPlayerFromSession()
	local localID = LocalPlayerID();
	if localID < 0 or DiplomacyManager == nil then return end
	local ok, majors = pcall(PlayerManager.GetAliveMajors);
	if not ok or majors == nil then return end
	for _, other in ipairs(majors) do
		local otherID = other:GetID();
		if otherID ~= localID then
			local found, sessionID = pcall(DiplomacyManager.FindOpenSessionID, localID, otherID);
			if found and sessionID ~= nil and sessionID >= 0 then
				m_OtherPlayerID = otherID;
				return;
			end
		end
	end
end

local function HasOtherPlayer()
	return m_OtherPlayerID >= 0 and m_OtherPlayerID ~= LocalPlayerID();
end

-- ---------------------------------------------------------------------------
-- Panel
-- ---------------------------------------------------------------------------
local function PanelFrame()
	local screenW, screenH = UIManager:GetScreenSizeVal();
	local left = LeftColumnEdge() + COLUMN_GAP;
	local width = screenW - left - SCREEN_MARGIN;
	if width < 360 then width = 360 end
	return left, width, screenW, screenH;
end

local function ApplyVisibility()
	local show = m_Open and HasOtherPlayer();
	Controls.Root:SetHide((not show) or (not m_Expanded));
	Controls.ExpandButton:SetHide((not show) or m_Expanded);
end

local function RefreshUnsafe()
	if not (m_Open and HasOtherPlayer()) then
		ApplyVisibility();
		return;
	end

	local left, width, screenW, screenH = PanelFrame();
	local scrollW = width - 16;
	m_CardWidth = scrollW - 16;

	local otherID = m_OtherPlayerID;
	local civ = CivName(otherID);
	local title = Lookup("LOC_UIEXT_DEALS_TITLE");
	if civ ~= "" then title = title .. "  ·  " .. civ end
	Controls.Title:SetText(title);

	local cards = GatherDeals(LocalPlayerID(), otherID);
	Controls.ExpandButton:SetText(Lookup("LOC_UIEXT_DEALS_EXPAND") .. ": " .. tostring(#cards));

	Log("refresh player=" .. tostring(otherID) .. " civ=" .. civ .. " cards=" .. tostring(#cards));

	m_DealIM:ResetInstances();
	local leader = LeaderName(otherID);
	for i, card in ipairs(cards) do
		Log(string.format("  card %d: ours=%d theirs=%d shared=%d soonest=%s",
			i, #card.ours, #card.theirs, #card.shared, tostring(card.soonest)));
		PopulateCard(m_DealIM:GetInstance(), card, leader);
	end
	Controls.DealStack:CalculateSize();
	Controls.DealStack:ReprocessAnchoring();

	local contentH = Controls.DealStack:GetSizeY();
	local empty = #cards == 0;
	if empty then contentH = 30 end
	Controls.EmptyLabel:SetHide(not empty);
	Controls.Scroll:SetHide(empty);

	local maxScroll = math.floor(screenH * (1 - TOP_LIMIT_FRACTION)) - SCREEN_MARGIN - SCROLL_TOP - FOOTER_HEIGHT - 8;
	local scrollH = math.min(contentH, maxScroll);
	local panelH = SCROLL_TOP + scrollH + 8 + FOOTER_HEIGHT;
	local top = screenH - SCREEN_MARGIN - panelH;

	Controls.Root:SetOffsetVal(left, top);
	Controls.Root:SetSizeVal(width, panelH);
	Controls.Scroll:SetSizeVal(scrollW, scrollH);
	Controls.DealStack:SetSizeX(m_CardWidth);
	Controls.Root:ReprocessAnchoring();
	pcall(function() Controls.Scroll:CalculateInternalSize() end);

	Controls.ExpandButton:SetOffsetVal(left + 10, screenH - SCREEN_MARGIN - FOOTER_HEIGHT + 7);

	ApplyVisibility();
end

local function Refresh()
	Try("refresh", RefreshUnsafe);
end

local function Hide()
	Controls.Root:SetHide(true);
	Controls.ExpandButton:SetHide(true);
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
local function OnToggle()
	m_Expanded = not m_Expanded;
	ApplyVisibility();
end

local function OnPlayerChosen(playerID)
	if playerID ~= nil and playerID >= 0 then
		m_OtherPlayerID = playerID;
	end
	if m_Open then Refresh() end
end

local function OnSceneClosed()
	m_Open = false;
	m_OtherPlayerID = -1;
	Hide();
end

local function OnDealsChanged()
	if m_Open then Refresh() end
end

-- Visibility follows the diplomacy screen itself, so no event can leave the panel on the map.
local function UpdateStep()
	local open = DiplomacyIsOpen();
	if open ~= m_Open then
		m_Open = open;
		Log("diplomacy " .. (open and "opened" or "closed") .. " player=" .. tostring(m_OtherPlayerID));
		if open then
			m_Expanded = true;
			if not HasOtherPlayer() then RememberPlayerFromSession() end
			Refresh();
		else
			m_OtherPlayerID = -1;
			Hide();
		end
	elseif open and not HasOtherPlayer() then
		RememberPlayerFromSession();
		if HasOtherPlayer() then Refresh() end
	end
end

local function OnUpdate()
	m_UpdateTick = m_UpdateTick + 1;
	if m_UpdateTick < 5 then return end
	m_UpdateTick = 0;
	Try("update", UpdateStep);
end

-- ---------------------------------------------------------------------------
local function Initialize()
	m_DealIM = InstanceManager:new("DealCard", "Top", Controls.DealStack);
	ContextPtr:SetUpdate(OnUpdate);

	Controls.CollapseButton:RegisterCallback(Mouse.eLClick, OnToggle);
	Controls.ExpandButton:RegisterCallback(Mouse.eLClick, OnToggle);

	LuaEvents.DiploScene_SceneOpened.Add(OnPlayerChosen);
	LuaEvents.DiploScene_LeaderSelect.Add(OnPlayerChosen);
	LuaEvents.DiplomacyRibbon_OpenDiplomacyActionView.Add(OnPlayerChosen);
	LuaEvents.TopPanel_OpenDiplomacyActionView.Add(OnPlayerChosen);
	LuaEvents.DiploScene_SceneClosed.Add(OnSceneClosed);
	LuaEvents.DiplomacyActionView_ShowIngameUI.Add(OnSceneClosed);
	LuaEvents.DiploPopup_HideDeal.Add(OnDealsChanged);
	Events.DiplomacyDealEnacted.Add(OnDealsChanged);
	Log("initialized");
end

Try("init", Initialize);
