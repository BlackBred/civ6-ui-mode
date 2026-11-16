-- Active deals panel on the diplomacy screen.
include("InstanceManager");

ContextPtr:SetHide(false);

local LEFT_COLUMN_FALLBACK = 578;
local COLUMN_GAP = 6;
local SCREEN_MARGIN = 12;
local MAX_PANEL_FRACTION = 0.25;
local HEADER_HEIGHT = 36;
local FOOTER_HEIGHT = 40;
local SCROLL_TOP = 44;
local CARD_PADDING = 10;
local ROW_HEIGHT = 22;
local CHAR_WIDTH = 9;

local m_DealIM = nil;
local m_FlowBlockIM = nil;
local m_FlowIconIM = nil;
local m_Open = false;
local m_Expanded = true;
local m_OtherPlayerID = -1;
local m_CardWidth = 560;
local m_UpdateTick = 0;
local m_FlowSignature = "";
local m_FlowAttached = nil;
local m_FlowMissLogged = false;

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

local function HasOtherPlayer()
	return m_OtherPlayerID >= 0 and m_OtherPlayerID ~= LocalPlayerID();
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

-- ---------------------------------------------------------------------------
-- Import and export in the luxury list on the deal screen.
-- One icon per resource and direction. The number on the icon is the soonest
-- remaining turn count; a star means that count is the smallest of several deals.
-- A gold frame marks a deal with the leader who is open now.
-- ---------------------------------------------------------------------------
local FLOW_PER_ROW = 4;

local function ControlID(control)
	if control == nil or control.GetID == nil then return "" end
	local ok, id = pcall(control.GetID, control);
	if ok and id ~= nil then return id end
	return "";
end

local function ControlText(control)
	if control == nil or control.GetText == nil then return "" end
	local ok, text = pcall(control.GetText, control);
	if ok and text ~= nil then return text end
	return "";
end

local function ChildByID(control, id)
	if control == nil or control.GetChildren == nil then return nil end
	local ok, children = pcall(control.GetChildren, control);
	if not ok or children == nil then return nil end
	for _, child in ipairs(children) do
		if ControlID(child) == id then return child end
	end
	return nil;
end

-- Unknown structure counts as "has children", so a failed lookup cannot hide the vanilla list.
local function HasVisibleChildren(control)
	if control == nil or control.GetChildren == nil then return true end
	local ok, children = pcall(control.GetChildren, control);
	if not ok or children == nil then return true end
	for _, child in ipairs(children) do
		if child.IsHidden == nil or not child:IsHidden() then return true end
	end
	return false;
end

local function LuxuryResource(valueType)
	if GameInfo == nil or GameInfo.Resources == nil or valueType == nil then return nil end
	local resource = GameInfo.Resources[valueType];
	if resource == nil or resource.ResourceClassType ~= "RESOURCECLASS_LUXURY" then return nil end
	return resource;
end

local function FinishFlows(map)
	local list = {};
	for _, group in pairs(map) do
		table.sort(group.partners, function(a, b)
			if a.remaining ~= b.remaining then return a.remaining < b.remaining end
			if a.name ~= b.name then return a.name < b.name end
			return a.playerID < b.playerID;
		end);
		group.turns = group.partners[1].remaining;
		group.starred = #group.partners > 1;
		group.amount = 0;
		for _, partner in ipairs(group.partners) do
			group.amount = group.amount + partner.amount;
		end
		group.current = false;
		for _, partner in ipairs(group.partners) do
			if partner.current then group.current = true end
		end
		table.insert(list, group);
	end
	table.sort(list, function(a, b)
		if a.turns ~= b.turns then return a.turns < b.turns end
		return Lookup(a.resource.Name) < Lookup(b.resource.Name);
	end);
	return list;
end

local function CollectFlows(localID, currentID)
	local buckets = { import = {}, export = {} };
	if DealManager == nil or PlayerManager == nil or localID < 0 then return {}, {} end
	local ok, majors = pcall(PlayerManager.GetAliveMajors);
	if not ok or majors == nil then return {}, {} end
	for _, other in ipairs(majors) do
		local otherID = other:GetID();
		if otherID ~= localID then
			local got, deals = pcall(DealManager.GetPlayerDeals, localID, otherID);
			if got and deals ~= nil then
				for _, deal in ipairs(deals) do
					local iok, iter, state, first = pcall(deal.Items, deal);
					if iok and iter ~= nil then
						for item in iter, state, first do
							if ItemKind(Call(item, "GetType")) == "RESOURCES" then
								local duration = Call(item, "GetDuration") or 0;
								local resource = LuxuryResource(Call(item, "GetValueType"));
								local fromPlayer = Call(item, "GetFromPlayerID");
								if duration > 0 and resource ~= nil and fromPlayer ~= nil then
									local remaining = RemainingTurns(item, duration);
									if remaining ~= nil then
										local direction = fromPlayer == localID and "export" or "import";
										local valueType = Call(item, "GetValueType");
										local group = buckets[direction][valueType];
										if group == nil then
											group = { resource = resource, partners = {} };
											buckets[direction][valueType] = group;
										end
										table.insert(group.partners, {
											playerID = otherID,
											name = LeaderName(otherID),
											amount = Call(item, "GetAmount") or 0,
											remaining = remaining,
											current = otherID == currentID,
										});
									end
								end
							end
						end
					end
				end
			end
		end
	end
	return FinishFlows(buckets.import), FinishFlows(buckets.export);
end

local function FlowSignature(importList, exportList)
	local parts = {};
	local function add(direction, list)
		for _, group in ipairs(list) do
			local bits = { direction, tostring(group.resource.ResourceType), tostring(group.turns), group.starred and "*" or "" };
			for _, partner in ipairs(group.partners) do
				table.insert(bits, table.concat({
					tostring(partner.playerID), tostring(partner.remaining), tostring(partner.amount), partner.current and "!" or "",
				}, ":"));
			end
			table.insert(parts, table.concat(bits, ","));
		end
	end
	add("import", importList);
	add("export", exportList);
	return table.concat(parts, "|");
end

local function FlowTooltip(heading, group)
	local lines = { heading, Lookup(group.resource.Name) };
	for _, partner in ipairs(group.partners) do
		local line = Format("LOC_UIEXT_FLOW_PARTNER", partner.name, partner.amount, partner.remaining);
		if partner.current then
			line = "[COLOR_Gold]" .. line .. "[ENDCOLOR]";
		end
		table.insert(lines, line);
	end
	return table.concat(lines, "[NEWLINE]");
end

local function SetTip(control, text)
	if control ~= nil and control.SetToolTipString ~= nil then
		pcall(control.SetToolTipString, control, text);
	end
end

local function ApplyResourceIcon(image, resource)
	if IconManager == nil or image == nil or resource == nil then return end
	local ok, x, y, sheet, size = pcall(IconManager.FindIconAtlasNearestSize, IconManager, "ICON_" .. resource.ResourceType, 42, true);
	if not ok or sheet == nil or sheet == "" then return end
	pcall(function() image:SetTexture(x, y, sheet) end);
	if type(size) == "number" and size > 0 then
		pcall(function() image:SetSizeVal(size, size) end);
	end
end

local function DealViewOpen()
	local view = ContextPtr:LookUpControl("/InGame/DiplomacyDealView");
	return view ~= nil and view.IsHidden ~= nil and not view:IsHidden();
end

local function FindLuxuryList()
	local stack = ContextPtr:LookUpControl("/InGame/DiplomacyDealView/MyInventory/MyInventoryScroll/MyInventoryStack");
	if stack == nil or stack.GetChildren == nil then return nil end
	local ok, groups = pcall(stack.GetChildren, stack);
	if not ok or groups == nil then return nil end
	local want = Lookup("LOC_DIPLOMACY_DEAL_LUXURY_RESOURCES");
	for _, group in ipairs(groups) do
		local label = ChildByID(ChildByID(group, "Title"), "TitleText");
		if label ~= nil and ControlText(label) == want then return group end
	end
	return nil;
end

local function ClearFlows()
	if m_FlowIconIM ~= nil then m_FlowIconIM:ResetInstances() end
	if m_FlowBlockIM ~= nil then m_FlowBlockIM:ResetInstances() end
end

local function Relayout(control)
	local current = control;
	for _ = 1, 4 do
		if current == nil then return end
		pcall(function() current:CalculateSize() end);
		pcall(function() current:ReprocessAnchoring() end);
		pcall(function() current:CalculateInternalSize() end);
		if current.GetParent == nil then return end
		local ok, parent = pcall(current.GetParent, current);
		if not ok then return end
		current = parent;
	end
end

local function ApplyGroupVisibility(list, hasFlows)
	if hasFlows then
		list:SetHide(false);
		return;
	end
	if not HasVisibleChildren(ChildByID(list, "ListStack")) then
		list:SetHide(true);
	end
end

local function FillBlock(list, title, groups)
	local block = m_FlowBlockIM:GetInstance(list);
	block.Title:SetText(title);
	for _, group in ipairs(groups) do
		local icon = m_FlowIconIM:GetInstance(block.Icons);
		ApplyResourceIcon(icon.Icon, group.resource);
		local turnsKey = group.starred and "LOC_UIEXT_FLOW_TURNS_MANY" or "LOC_UIEXT_FLOW_TURNS";
		icon.Turns:SetText(Format(turnsKey, group.turns));
		icon.Amount:SetText(tostring(group.amount));
		icon.Highlight:SetHide(not group.current);
		local tip = FlowTooltip(title, group);
		SetTip(icon.Top, tip);
		SetTip(icon.Icon, tip);
		SetTip(icon.Turns, tip);
		SetTip(icon.Amount, tip);
		SetTip(icon.Plate, tip);
		SetTip(icon.Frame, tip);
		SetTip(icon.Highlight, tip);
		if icon.Top.SetConsumeMouse ~= nil then
			pcall(icon.Top.SetConsumeMouse, icon.Top, true);
		end
	end
	pcall(function() block.Icons:CalculateSize() end);
	pcall(function() block.Top:CalculateSize() end);
	local rows = math.ceil(#groups / FLOW_PER_ROW);
	if rows < 1 then rows = 1 end
	local want = 22 + rows * 54;
	if block.Top:GetSizeY() < want then
		block.Top:SetSizeVal(236, want);
	end
end

local function UpdateResourceFlows()
	if m_FlowBlockIM == nil then return end
	if not (m_Open and HasOtherPlayer() and DealViewOpen()) then
		if m_FlowSignature ~= "" or m_FlowAttached ~= nil then
			m_FlowSignature = "";
			m_FlowAttached = nil;
			ClearFlows();
		end
		return;
	end

	local importList, exportList = CollectFlows(LocalPlayerID(), m_OtherPlayerID);
	local signature = FlowSignature(importList, exportList);
	local list = FindLuxuryList();
	if list == nil then
		if not m_FlowMissLogged then
			m_FlowMissLogged = true;
			Log("luxury list not found");
		end
		if m_FlowSignature ~= "" or m_FlowAttached ~= nil then
			m_FlowSignature = "";
			m_FlowAttached = nil;
			ClearFlows();
		end
		return;
	end

	if signature == m_FlowSignature and m_FlowAttached == list then
		local wasHidden = list:IsHidden();
		ApplyGroupVisibility(list, signature ~= "");
		if wasHidden and not list:IsHidden() then Relayout(list) end
		return;
	end

	ClearFlows();
	if #importList > 0 then
		FillBlock(list, Lookup("LOC_UIEXT_FLOW_IMPORT"), importList);
	end
	if #exportList > 0 then
		FillBlock(list, Lookup("LOC_UIEXT_FLOW_EXPORT"), exportList);
	end
	ApplyGroupVisibility(list, signature ~= "");
	Relayout(list);
	m_FlowSignature = signature;
	m_FlowAttached = list;
	Log("flows import=" .. tostring(#importList) .. " export=" .. tostring(#exportList));
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
-- Deals tab in the intel report (Доклад разведки).
-- The DLC rebuilds that report on every player change and fires DiploScene_RefreshTabs.
-- This context adds a button and a panel into the report's own controls, found by ID.
-- Nothing of the game's script is replaced, so the DLC and other mods keep working.
-- ---------------------------------------------------------------------------
local REPORT_SEARCH_LIMIT = 4000;
local DEALS_TAB_ICON = "ICON_UNIT_TRADER_WHITE";
local TAB_WIDTH = 470;
local TAB_TITLE_WRAP = 150;
local TAB_ITEM_WRAP = 210;
local TAB_ROW_HEIGHT = 22;

local m_TabButtonIM = nil;
local m_TabPanelIM = nil;
local m_TabDealIM = nil;
local m_TabSideIM = nil;
local m_TabItemIM = nil;
local m_Tab = nil;
local m_TabMissLogged = false;

local function FindDescendant(root, wantedID)
	if root == nil or root.GetChildren == nil then return nil end
	local queue = { root };
	local head = 1;
	while head <= #queue and head <= REPORT_SEARCH_LIMIT do
		local node = queue[head];
		head = head + 1;
		if ControlID(node) == wantedID then return node end
		local ok, children = pcall(node.GetChildren, node);
		if ok and children ~= nil then
			for _, child in ipairs(children) do
				table.insert(queue, child);
			end
		end
	end
	return nil;
end

local function FindReport()
	local view = ContextPtr:LookUpControl("/InGame/DiplomacyActionView");
	if view == nil then return nil end
	local stack = FindDescendant(view, "IntelTabButtonStack");
	local container = FindDescendant(view, "IntelPanelContainer");
	if stack == nil or container == nil then return nil end
	return {
		stack = stack,
		container = container,
		header = FindDescendant(view, "IntelHeader"),
	};
end

-- ChangeParent appends, so repeating it on a control that is already last would be pointless.
local function MoveToEnd(control, parent)
	if control == nil or parent == nil or parent.GetChildren == nil or control.ChangeParent == nil then return end
	local ok, children = pcall(parent.GetChildren, parent);
	if not ok or children == nil or #children == 0 or children[#children] == control then return end
	pcall(control.ChangeParent, control, parent);
end

local function PlaceDealsTabLast()
	if m_Tab == nil then return end
	MoveToEnd(m_Tab.button.Button, m_Tab.stack);
	MoveToEnd(m_Tab.panel.Top, m_Tab.container);
	pcall(function() m_Tab.stack:CalculateSize() end);
end

local function SyncDealsTabSelection()
	if m_Tab == nil then return end
	local shown = false;
	pcall(function() shown = not m_Tab.panel.Top:IsHidden() end);
	pcall(function() m_Tab.button.Button:SetSelected(shown) end);
end

local function TabTextHeight(text, width)
	local perRow = math.max(1, math.floor(width / CHAR_WIDTH));
	return math.max(1, math.ceil(VisibleLength(text) / perRow)) * TAB_ROW_HEIGHT;
end

-- The title is drawn over the left column, starting on the first bullet.
-- A wrapped second line hangs under that bullet and must not push the next bullet down,
-- and a single bullet must stay on the first line rather than sink to the last.
local function LockTabSide(side, label, title)
	local itemsH = side.Items:GetSizeY();
	if itemsH < TAB_ROW_HEIGHT then itemsH = TAB_ROW_HEIGHT end
	local titleH = TabTextHeight(title, TAB_TITLE_WRAP);
	pcall(function() label:SetAnchor("L,T") end);
	pcall(function() label:SetOffsetVal(60, 0) end);
	pcall(function() side.Items:SetAnchor("L,T") end);
	pcall(function() side.Items:SetOffsetVal(0, 0) end);
	pcall(function() side.Items:SetSizeVal(TAB_WIDTH, itemsH) end);
	side.Top:SetSizeVal(TAB_WIDTH, math.max(itemsH, titleH));
end

-- One block per side: label in the label column, one bulleted line per item in the value column.
local function AddTabSide(deal, titleID, title, lines)
	if #lines == 0 then return nil end
	local side = m_TabSideIM:GetInstance(deal.Sides);
	side.SharedTitle:SetHide(true);
	side.OursTitle:SetHide(true);
	side.TheirsTitle:SetHide(true);
	local label = side[titleID];
	label:SetText(title);
	label:SetHide(false);
	for _, line in ipairs(lines) do
		local item = m_TabItemIM:GetInstance(side.Items);
		item.Text:SetText(line);
		item.Top:SetSizeVal(TAB_WIDTH, TAB_ROW_HEIGHT);
	end
	side.Items:CalculateSize();
	LockTabSide(side, label, title);
	return { side = side, label = label, title = title };
end

local function AddTabDeal(card, leader)
	local deal = m_TabDealIM:GetInstance(m_Tab.panel.TabCards);
	local header, showTurns = CardTiming(card);
	deal.Header:SetText(header);
	local locked = {};
	local function add(titleID, title, lines)
		local entry = AddTabSide(deal, titleID, title, lines);
		if entry ~= nil then table.insert(locked, entry) end
	end
	add("SharedTitle", Lookup("LOC_UIEXT_DEALS_SHARED"), LineTexts(card.shared, showTurns));
	add("OursTitle", Lookup("LOC_UIEXT_DEALS_WE_GIVE"), LineTexts(card.ours, showTurns));
	add("TheirsTitle", Format("LOC_UIEXT_DEALS_THEY_GIVE", leader), LineTexts(card.theirs, showTurns));
	deal.Sides:CalculateSize();
	deal.Top:CalculateSize();
	-- Measuring the parent can grow a side around a wrapped title. Lock the bullets back to the top.
	for _, entry in ipairs(locked) do
		LockTabSide(entry.side, entry.label, entry.title);
	end
end

local function RefreshDealsTab()
	if m_Tab == nil or m_Tab.playerID < 0 then return end
	local cards = GatherDeals(LocalPlayerID(), m_Tab.playerID);
	local leader = LeaderName(m_Tab.playerID);
	m_TabItemIM:ResetInstances();
	m_TabSideIM:ResetInstances();
	m_TabDealIM:ResetInstances();
	for _, card in ipairs(cards) do
		AddTabDeal(card, leader);
	end
	local panel = m_Tab.panel;
	panel.TabCards:CalculateSize();
	panel.TabEmpty:SetHide(#cards > 0);
	local height = #cards > 0 and panel.TabCards:GetSizeY() or panel.TabEmpty:GetSizeY();
	panel.Top:SetSizeVal(TAB_WIDTH, height + 8);
	Relayout(panel.Top);
end

local function ShowDealsTab()
	if m_Tab == nil then return end
	for _, child in ipairs(m_Tab.container:GetChildren()) do
		if child ~= m_Tab.panel.Top then child:SetHide(true) end
	end
	m_Tab.panel.Top:SetHide(false);
	-- The game's own buttons do not know about this one, so clear them here.
	pcall(function()
		for _, child in ipairs(m_Tab.stack:GetChildren()) do
			if child ~= m_Tab.button.Button then child:SetSelected(false) end
		end
	end);
	if m_Tab.header ~= nil then
		m_Tab.header:SetText(Locale.ToUpper(Lookup("LOC_UIEXT_DEALS_REPORT")));
	end
	m_Tab.container:CalculateSize();
	SyncDealsTabSelection();
end

local function InjectDealsTab(playerID)
	if playerID == nil or playerID < 0 then return end
	local report = FindReport();
	if report == nil then
		if not m_TabMissLogged then
			m_TabMissLogged = true;
			Log("intel report not found");
		end
		return;
	end

	if m_Tab == nil or m_Tab.stack ~= report.stack or m_Tab.container ~= report.container then
		m_TabItemIM:ResetInstances();
		m_TabSideIM:ResetInstances();
		m_TabDealIM:ResetInstances();
		m_TabButtonIM:ResetInstances();
		m_TabPanelIM:ResetInstances();

		local button = m_TabButtonIM:GetInstance(report.stack);
		local panel = m_TabPanelIM:GetInstance(report.container);
		panel.Top:SetHide(true);
		button.ButtonIcon:SetIcon(DEALS_TAB_ICON);
		button.Button:SetToolTipString(Lookup("LOC_UIEXT_DEALS_TAB_TOOLTIP"));
		button.Button:RegisterCallback(Mouse.eLClick, ShowDealsTab);
		report.stack:CalculateSize();

		m_Tab = {
			stack = report.stack,
			container = report.container,
			header = report.header,
			button = button,
			panel = panel,
			playerID = playerID,
		};
		m_TabMissLogged = false;
		Log("deals tab added player=" .. tostring(playerID));
	end
	m_Tab.playerID = playerID;
	-- The game reattaches its own tabs with ChangeParent, which moves each of them to the
	-- end of the stack and leaves ours at the front. Putting ours back last undoes that.
	PlaceDealsTabLast();
	RefreshDealsTab();
end

local function OnRefreshTabs(playerID)
	Try("deals tab", InjectDealsTab, playerID);
end

-- Runs from the update tick: adds the tab if the game rebuilt the report without an event,
-- and keeps the button highlight in step with the panel.
local function SyncDealsTab()
	if m_Open and HasOtherPlayer() then
		local report = FindReport();
		if report ~= nil and (m_Tab == nil or m_Tab.stack ~= report.stack) then
			InjectDealsTab(m_OtherPlayerID);
		end
	end
	PlaceDealsTabLast();
	SyncDealsTabSelection();
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
	-- The list is only on the deal screen. The diplomacy window uses the intel-report tab.
	local show = m_Open and HasOtherPlayer() and DealViewOpen();
	Controls.Root:SetHide((not show) or (not m_Expanded));
	Controls.ExpandButton:SetHide((not show) or m_Expanded);
end

local function RefreshUnsafe()
	if not (m_Open and HasOtherPlayer()) then
		ApplyVisibility();
		UpdateResourceFlows();
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

	local maxScroll = math.max(ROW_HEIGHT * 4, math.floor(screenH * MAX_PANEL_FRACTION) - SCROLL_TOP - FOOTER_HEIGHT - 8);
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
	UpdateResourceFlows();
end

local function Refresh()
	Try("refresh", RefreshUnsafe);
end

local function Hide()
	Controls.Root:SetHide(true);
	Controls.ExpandButton:SetHide(true);
	UpdateResourceFlows();
	m_Tab = nil;
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
	Try("deals tab", RefreshDealsTab);
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
	Try("flows", UpdateResourceFlows);
	Try("deals tab", SyncDealsTab);
	Try("panel", ApplyVisibility);
end

-- ---------------------------------------------------------------------------
local function Initialize()
	m_DealIM = InstanceManager:new("DealCard", "Top", Controls.DealStack);
	m_FlowBlockIM = InstanceManager:new("FlowBlock", "Top", Controls.FlowHost);
	m_FlowIconIM = InstanceManager:new("FlowIcon", "Top", Controls.FlowHost);
	m_TabButtonIM = InstanceManager:new("DealsTabButton", "Button", Controls.FlowHost);
	m_TabPanelIM = InstanceManager:new("DealsTabPanel", "Top", Controls.FlowHost);
	m_TabDealIM = InstanceManager:new("DealsTabDeal", "Top", Controls.FlowHost);
	m_TabSideIM = InstanceManager:new("DealsTabSide", "Top", Controls.FlowHost);
	m_TabItemIM = InstanceManager:new("DealsTabItem", "Top", Controls.FlowHost);
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
	LuaEvents.DiploScene_RefreshTabs.Add(OnRefreshTabs);
	Log("initialized");
end

Try("init", Initialize);
