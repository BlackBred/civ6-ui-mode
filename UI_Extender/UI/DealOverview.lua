-- Deals panel on the deal screen: current deals and the history of finished ones.
include("InstanceManager");
include("DealRecord");

ContextPtr:SetHide(false);

local LEFT_COLUMN_FALLBACK = 578;
local DEAL_BANNER_EDGE = 534;
local MIN_PANEL_WIDTH = 360;
local COLUMN_GAP = 6;
local SCREEN_MARGIN = 12;
local MAX_PANEL_FRACTION = 0.25;
local HEADER_HEIGHT = 36;
local FOOTER_HEIGHT = 40;
local SCROLL_TOP = 44;
local CARD_PADDING = 10;
local ROW_HEIGHT = 22;
local CHAR_WIDTH = 9;
local DEAL_STACK_PADDING = 8;

local m_DealIM = nil;
local m_FlowBlockIM = nil;
local m_FlowIconIM = nil;
local m_Open = false;
local m_Expanded = true;
local m_ShowHistory = false;
local m_OtherPlayerID = -1;
local m_CardWidth = 560;
local m_UpdateTick = 0;
local m_DealViewWasOpen = false;
local m_FlowSignature = "";
local m_FlowMy = nil;
local m_FlowTheir = nil;
local m_FlowMissLogged = false;
-- One-time items are already gone from DealManager when the card is drawn, so the
-- contents of the deal table are kept while the deal screen is open (m_Watch).
local m_Watch = nil;
-- The local player's deal record (see DealRecord), loaded once; nil until then.
local m_Archive = nil;
local m_PollTick = 0;
-- The finished deal a notification asked for: { id, turn }. Highlighted in the history,
-- which is scrolled to it once.
local m_Focus = nil;
local m_FocusScrolled = false;

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
	return DealRecord.Kind(rawType);
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

local function EntryFor(stored, item)
	local text = DealRecord.ItemLabel(stored);
	if text == "" or stored.from == nil then return nil end
	local instant = DealRecord.IsInstant(stored);
	local remaining = nil;
	if not instant and item ~= nil then
		remaining = RemainingTurns(item, stored.duration);
	end
	return {
		key = DealRecord.ItemKey(stored),
		text = text,
		fromPlayer = stored.from,
		remaining = remaining,
		openEnded = (not instant) and remaining == nil,
		instant = instant,
		mutual = stored.mutual and true or false,
	};
end

local function AddEntry(card, entry, seen, seenShared)
	if entry == nil or seen[entry.key] then return end
	seen[entry.key] = true;
	if entry.mutual then
		if not seenShared[entry.text] then
			seenShared[entry.text] = true;
			table.insert(card.shared, entry);
		end
	elseif entry.fromPlayer == card.localID then
		table.insert(card.ours, entry);
	else
		table.insert(card.theirs, entry);
	end
end

local function IsNetworkGame()
	if GameConfiguration == nil or GameConfiguration.IsNetworkMultiplayer == nil then return false end
	local ok, value = pcall(GameConfiguration.IsNetworkMultiplayer);
	return ok and value == true;
end

local function CurrentTurn()
	local ok, turn = pcall(Game.GetCurrentGameTurn);
	if ok and type(turn) == "number" then return turn end
	return 0;
end

-- The gameplay script's functions, present in single player once that script has loaded.
local function Exposed(name)
	if IsNetworkGame() or ExposedMembers == nil or ExposedMembers.UIExt == nil then return nil end
	return ExposedMembers.UIExt[name];
end

-- Journal in the save, kept by the gameplay script (see DealRecord.AppendLog).
-- The counter is shared with that script.
local m_Seq = 0;

local function Journal(text)
	local seq;
	if ExposedMembers ~= nil then
		ExposedMembers.UIExt = ExposedMembers.UIExt or {};
		ExposedMembers.UIExt.LogSeq = (ExposedMembers.UIExt.LogSeq or 0) + 1;
		seq = ExposedMembers.UIExt.LogSeq;
	else
		m_Seq = m_Seq + 1;
		seq = m_Seq;
	end
	local line = tostring(seq) .. " t" .. tostring(CurrentTurn()) .. " UI " .. text;
	Log(line);
	local append = Exposed("AppendJournal");
	if append ~= nil then pcall(append, line) end
end

local function DealEnactedTurn(deal)
	local turn = nil;
	local ok, iter, state, first = pcall(deal.Items, deal);
	if not ok or iter == nil then return nil end
	for item in iter, state, first do
		local enacted = Call(item, "GetEnactedTurn");
		if enacted ~= nil and enacted >= 0 and (turn == nil or enacted < turn) then
			turn = enacted;
		end
	end
	return turn;
end

-- What was handed over at once comes first on each side, then what runs for a term.
local function InstantsFirst(card)
	for _, list in ipairs({ card.ours, card.theirs, card.shared }) do
		local instants, lasting = {}, {};
		for _, e in ipairs(list) do
			table.insert(e.instant and instants or lasting, e);
		end
		for i = #list, 1, -1 do list[i] = nil end
		for _, e in ipairs(instants) do table.insert(list, e) end
		for _, e in ipairs(lasting) do table.insert(list, e) end
	end
end

-- ---------------------------------------------------------------------------
-- Deal record. The game gives a deal no id and forgets it once it ends, so this
-- context compares the game's list with the record, the way the game's report
-- screen reads a deal: by its players, its enactment turn and its items.
-- The gameplay script writes the record into the save and sends notifications.
-- ---------------------------------------------------------------------------
-- Text, or a table from a version that saved one.
local function ArchiveText(key)
	if Game == nil or Game.GetProperty == nil then return nil end
	local ok, text = pcall(Game.GetProperty, Game, key);
	if ok and (type(text) == "string" or type(text) == "table") then return text end
	return nil;
end

-- Single player calls the gameplay script directly. A network game sends a player
-- operation instead: it runs on every machine, so their saves stay the same.
local function SendToGameplay(direct, operation, value, params)
	if IsNetworkGame() then
		if UI ~= nil and UI.RequestPlayerOperation ~= nil and PlayerOperations ~= nil then
			params.OnStart = operation;
			pcall(UI.RequestPlayerOperation, LocalPlayerID(), PlayerOperations.EXECUTE_SCRIPT, params);
		end
		return;
	end
	local fn = Exposed(direct);
	if fn ~= nil then pcall(fn, LocalPlayerID(), value) end
end

local function PutRecord(deal)
	local line = DealRecord.EncodeRecord(deal);
	SendToGameplay("PutRecord", DealRecord.OP_PUT, line, { uiextLine = line });
end

local function Announce(deal)
	local localID = LocalPlayerID();
	local partner = deal.a == localID and deal.b or deal.a;
	local message, summary = DealRecord.Notice(deal, localID, LeaderName(partner));
	local params = {
		uiextType = DealRecord.NotifyType(deal),
		uiextMessage = message,
		uiextSummary = summary,
		uiextPartner = partner,
		uiextDealID = deal.id,
		uiextTurn = deal.turn,
	};
	SendToGameplay("Notify", DealRecord.OP_NOTIFY, params, params);
end

-- Loads the local player's record once. In single player it comes through the gameplay
-- script, which may load after this context, so until then nothing is tracked.
local function EnsureArchive()
	if m_Archive ~= nil then return true end
	local localID = LocalPlayerID();
	if localID < 0 then return false end
	local text;
	if IsNetworkGame() then
		text = ArchiveText(DealRecord.ArchiveKey(localID));
	else
		local read = Exposed("ReadArchive");
		if read == nil then return false end
		local ok, value = pcall(read, localID);
		text = ok and value or nil;
	end
	m_Archive = DealRecord.Normalize(text);
	if text == nil then
		-- Earlier versions kept every player's deals under one property and in the configuration.
		local added = DealRecord.Import(m_Archive, ArchiveText(DealRecord.PROP), localID);
		local ok, config = pcall(GameConfiguration.GetValue, DealRecord.PROP);
		for _, deal in ipairs(DealRecord.Import(m_Archive, ok and config or nil, localID)) do
			table.insert(added, deal);
		end
		for _, deal in ipairs(added) do PutRecord(deal) end
		if #added > 0 then Journal("imported " .. tostring(#added)) end
	end
	Journal("loaded deals=" .. tostring(#m_Archive.deals));
	return true;
end

-- The deal as the game lists it: its players, the turn it was enacted and its items.
-- An item the game marks expired no longer counts.
local function LiveDeal(deal, a, b, now)
	local items, turn = {}, nil;
	local ok, iter, state, first = pcall(deal.Items, deal);
	if ok and iter ~= nil then
		for item in iter, state, first do
			if Call(item, "IsExpired") ~= true then
				local stored = DealRecord.FromItem(item);
				if stored ~= nil then table.insert(items, stored) end
				local enacted = Call(item, "GetEnactedTurn");
				if enacted ~= nil and enacted >= 0 and (turn == nil or enacted < turn) then turn = enacted end
			end
		end
	end
	return { a = a, b = b, turn = turn or now, items = items };
end

-- Everyone the local player may have a deal with: the living majors, and the partner of
-- every running record, so a deal with an eliminated player also ends.
local function Partners(localID)
	local ids, seen = {}, {};
	local function add(id)
		if id ~= nil and id ~= localID and not seen[id] then
			seen[id] = true;
			table.insert(ids, id);
		end
	end
	if PlayerManager ~= nil and PlayerManager.GetAliveMajors ~= nil then
		local ok, majors = pcall(PlayerManager.GetAliveMajors);
		for _, player in ipairs(ok and majors or {}) do add(Call(player, "GetID")) end
	end
	for _, deal in ipairs(m_Archive ~= nil and m_Archive.deals or {}) do
		if deal.ended == nil then add(deal.a == localID and deal.b or deal.a) end
	end
	table.sort(ids);
	return ids;
end

-- The local player's deals as the game lists them, and the pairs the game answered for:
-- a pair it failed to list ends nothing.
local function ReadLives(localID)
	local lives, answered = {}, {};
	if DealManager == nil or DealManager.GetPlayerDeals == nil then return lives, answered end
	local now = CurrentTurn();
	for _, otherID in ipairs(Partners(localID)) do
		local ok, deals = pcall(DealManager.GetPlayerDeals, localID, otherID);
		if ok and type(deals) == "table" then
			answered[DealRecord.PairKey(localID, otherID)] = true;
			for _, deal in ipairs(deals) do
				table.insert(lives, LiveDeal(deal, localID, otherID, now));
			end
		end
	end
	return lives, answered;
end

-- Compares the record with the game's list, stores what changed and announces what ended.
-- A deal found gone long after it ended (a save first played with this version) is not announced.
local function Sync(why)
	if not EnsureArchive() then return end
	local localID = LocalPlayerID();
	local lives, answered = ReadLives(localID);
	local now = CurrentTurn();
	local changed, finished = DealRecord.Track(m_Archive, lives, answered, now);
	local notes = {};
	for _, deal in ipairs(changed) do
		PutRecord(deal);
		table.insert(notes, "+" .. DealRecord.Brief(deal));
	end
	for _, deal in ipairs(finished) do
		PutRecord(deal);
		local announce = deal.ended >= now - 1;
		if announce then Announce(deal) end
		table.insert(notes, "end " .. DealRecord.Brief(deal) .. (announce and " notified" or ""));
	end
	if #notes > 0 then Journal(why .. " " .. table.concat(notes, "; ")) end
end

-- Live items, plus one-time items the game already deleted, from the record of the deal.
local function ReadDeal(deal, localID, otherID)
	local card = { ours = {}, theirs = {}, shared = {}, localID = localID };
	local seen = {};
	local seenShared = {};
	local live = {};
	local ok, iter, state, first = pcall(deal.Items, deal);
	if ok and iter ~= nil then
		for item in iter, state, first do
			local stored = DealRecord.FromItem(item);
			if stored ~= nil then
				table.insert(live, stored);
				AddEntry(card, EntryFor(stored, item), seen, seenShared);
			end
		end
	end

	local function addInstants(items)
		for _, stored in ipairs(items or {}) do
			if DealRecord.IsInstant(stored) then
				AddEntry(card, EntryFor(stored, nil), seen, seenShared);
			end
		end
	end

	local enacted = DealEnactedTurn(deal);
	card.turn = enacted;
	if m_Archive ~= nil and otherID ~= nil then
		local record = DealRecord.FindRecord(m_Archive, { a = localID, b = otherID, turn = enacted, items = live });
		if record ~= nil then addInstants(record.items) end
	end

	InstantsFirst(card);
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
	EnsureArchive();
	local ok, deals = pcall(DealManager.GetPlayerDeals, localID, otherID);
	if not ok or deals == nil then return cards end
	for _, deal in ipairs(deals) do
		local card = ReadDeal(deal, localID, otherID);
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
-- Finished deals, from the save. The game forgets a deal once it ends.
-- ---------------------------------------------------------------------------
local function HistoryCard(deal, localID)
	local card = { ours = {}, theirs = {}, shared = {}, localID = localID };
	local ended = DealRecord.EndedTurn(deal);
	local items = deal.items;
	card.history = { start = deal.turn, ended = ended, oneTime = DealRecord.IsOneTime(deal), record = deal, items = items };
	local seen, seenShared = {}, {};
	for _, stored in ipairs(items) do
		local entry = EntryFor(stored, nil);
		if entry ~= nil and not entry.instant then
			entry.untilTurn = DealRecord.ItemEnd(deal, stored, ended);
		end
		AddEntry(card, entry, seen, seenShared);
	end
	InstantsFirst(card);
	return card;
end

local function GatherHistory(localID, otherID)
	local cards = {};
	Sync("history");
	if m_Archive == nil then return cards end
	for _, deal in ipairs(DealRecord.History(m_Archive, localID, otherID)) do
		local card = HistoryCard(deal, localID);
		if #card.ours + #card.theirs + #card.shared > 0 then
			table.insert(cards, card);
		end
	end
	return cards;
end

-- ---------------------------------------------------------------------------
-- Import and export in the luxury lists on the deal screen.
-- Our column shows both directions. Their column shows only import: luxuries
-- they already buy, which are not worth offering them.
-- One icon per resource and direction. The number on the icon is the soonest
-- remaining turn count; a star means that count is the smallest of several deals.
-- A gold frame marks a deal with the leader in the opposite column.
--
-- Their import currently includes trades between two other players. That is
-- useful and stays for now, but it may be information the local player should
-- not have. TODO: decide whether a deal is visible only under some diplomacy
-- condition (intel level, diplomatic visibility, an embassy, or something
-- else). That is game logic, not a UI change.
-- A leader the local player has not met must not be named. Trading with an
-- unmet Cleopatra must not say "Cleopatra". Today every partner is named.
-- ---------------------------------------------------------------------------
local FLOW_PER_ROW = 4;
local MY_LUXURY_STACK = "/InGame/DiplomacyDealView/MyInventory/MyInventoryScroll/MyInventoryStack";
local THEIR_LUXURY_STACK = "/InGame/DiplomacyDealView/TheirInventory/TheirInventoryScroll/TheirInventoryStack";
-- Light washes, 0–1. Obvious beside each other, not a solid plate.
local IMPORT_TINT = { 0.25, 0.70, 0.32, 0.06 };
local EXPORT_TINT = { 0.75, 0.22, 0.20, 0.06 };

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

local function CollectFlows(subjectID, highlightID)
	local buckets = { import = {}, export = {} };
	if DealManager == nil or PlayerManager == nil or subjectID < 0 then return {}, {} end
	local ok, majors = pcall(PlayerManager.GetAliveMajors);
	if not ok or majors == nil then return {}, {} end
	for _, other in ipairs(majors) do
		local otherID = other:GetID();
		if otherID ~= subjectID then
			local got, deals = pcall(DealManager.GetPlayerDeals, subjectID, otherID);
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
										local direction = fromPlayer == subjectID and "export" or "import";
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
											current = otherID == highlightID,
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

local function FindLuxuryList(stackPath)
	local stack = ContextPtr:LookUpControl(stackPath);
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

local function ApplyTint(box, tint)
	if box == nil or UI == nil or UI.GetColorValue == nil then return end
	pcall(box.SetColor, box, UI.GetColorValue(tint[1], tint[2], tint[3], tint[4]));
end

local function FillBlock(list, title, groups, tint)
	local block = m_FlowBlockIM:GetInstance(list);
	block.Title:SetText(title);
	ApplyTint(block.Tint, tint);
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
	pcall(function() block.Body:CalculateSize() end);
	local rows = math.ceil(#groups / FLOW_PER_ROW);
	if rows < 1 then rows = 1 end
	local height = 26 + rows * 54;
	pcall(function()
		local measured = block.Body:GetSizeY() + 4;
		if measured > height then height = measured end
	end);
	block.Top:SetSizeVal(236, height);
end

local function KeepFlowList(list, hasFlows)
	if list == nil then return end
	local wasHidden = list:IsHidden();
	ApplyGroupVisibility(list, hasFlows);
	if wasHidden and not list:IsHidden() then Relayout(list) end
end

local function UpdateResourceFlows()
	if m_FlowBlockIM == nil then return end
	if not (m_Open and HasOtherPlayer() and DealViewOpen()) then
		if m_FlowSignature ~= "" or m_FlowMy ~= nil or m_FlowTheir ~= nil then
			m_FlowSignature = "";
			m_FlowMy = nil;
			m_FlowTheir = nil;
			ClearFlows();
		end
		return;
	end

	local localID = LocalPlayerID();
	local otherID = m_OtherPlayerID;
	local importList, exportList = CollectFlows(localID, otherID);
	local theirImport = CollectFlows(otherID, localID);
	local signature = FlowSignature(importList, exportList) .. "||" .. FlowSignature(theirImport, {});
	local myList = FindLuxuryList(MY_LUXURY_STACK);
	local theirList = FindLuxuryList(THEIR_LUXURY_STACK);
	if (myList == nil or theirList == nil) and not m_FlowMissLogged then
		m_FlowMissLogged = true;
		Log("luxury list missing mine=" .. tostring(myList ~= nil) .. " theirs=" .. tostring(theirList ~= nil));
	end
	if myList == nil and theirList == nil then
		if m_FlowSignature ~= "" or m_FlowMy ~= nil or m_FlowTheir ~= nil then
			m_FlowSignature = "";
			m_FlowMy = nil;
			m_FlowTheir = nil;
			ClearFlows();
		end
		return;
	end

	local mineShown = #importList + #exportList > 0;
	local theirsShown = #theirImport > 0;
	if signature == m_FlowSignature and m_FlowMy == myList and m_FlowTheir == theirList then
		KeepFlowList(myList, mineShown);
		KeepFlowList(theirList, theirsShown);
		return;
	end

	ClearFlows();
	if myList ~= nil then
		if #importList > 0 then
			FillBlock(myList, Lookup("LOC_UIEXT_FLOW_IMPORT"), importList, IMPORT_TINT);
		end
		if #exportList > 0 then
			FillBlock(myList, Lookup("LOC_UIEXT_FLOW_EXPORT"), exportList, EXPORT_TINT);
		end
		ApplyGroupVisibility(myList, mineShown);
		Relayout(myList);
	end
	if theirList ~= nil then
		if #theirImport > 0 then
			FillBlock(theirList, Lookup("LOC_UIEXT_FLOW_IMPORT"), theirImport, IMPORT_TINT);
		end
		ApplyGroupVisibility(theirList, theirsShown);
		Relayout(theirList);
	end
	m_FlowSignature = signature;
	m_FlowMy = myList;
	m_FlowTheir = theirList;
	Log("flows import=" .. tostring(#importList) .. " export=" .. tostring(#exportList) .. " theirImport=" .. tostring(#theirImport));
end

-- "35 (1200 BC)": the turn with its calendar year.
local function TurnText(turn)
	if Calendar ~= nil and Calendar.MakeYearStr ~= nil then
		local ok, year = pcall(Calendar.MakeYearStr, turn);
		if ok and type(year) == "string" and year ~= "" then
			return Format("LOC_UIEXT_HISTORY_TURN_YEAR", turn, year);
		end
	end
	return tostring(turn);
end

-- A finished deal states when it ran. A line that stopped earlier than the deal gets its own last turn.
local function HistoryTiming(card)
	local history = card.history;
	if history.oneTime then
		return Format("LOC_UIEXT_HISTORY_ONCE", TurnText(history.start)), false;
	end
	local uniform = true;
	for _, list in ipairs({ card.ours, card.theirs, card.shared }) do
		for _, e in ipairs(list) do
			if e.untilTurn ~= nil and e.untilTurn ~= history.ended then uniform = false end
		end
	end
	return Format("LOC_UIEXT_HISTORY_PERIOD", TurnText(history.start), TurnText(history.ended)), not uniform;
end

-- Header text and whether each lasting line needs its own turn count.
-- One-time items are already handed over, so they do not change the countdown.
local function CardTiming(card)
	if card.history ~= nil then return HistoryTiming(card) end
	local turns = nil;
	local uniform = true;
	local anyOpen = false;
	local anyTimed = false;
	for _, list in ipairs({ card.ours, card.theirs, card.shared }) do
		for _, e in ipairs(list) do
			if e.instant then
				-- nothing to count down
			elseif e.openEnded then
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
	local header, showTurns;
	if not anyTimed and not anyOpen then
		header, showTurns = Lookup("LOC_UIEXT_DEALS_ONE_TIME_DEAL"), false;
	elseif not anyTimed then
		header, showTurns = Lookup("LOC_UIEXT_DEALS_OPEN_ENDED"), false;
	elseif anyOpen or not uniform then
		header, showTurns = Lookup("LOC_UIEXT_DEALS_MIXED"), true;
	elseif turns <= 0 then
		header, showTurns = Lookup("LOC_UIEXT_DEALS_EXPIRES_NOW"), false;
	else
		header, showTurns = Format("LOC_UIEXT_DEALS_REMAINING", turns), false;
	end
	if card.turn ~= nil then
		header = header .. " · " .. Format("LOC_UIEXT_DEALS_SINCE_TURN", card.turn);
	end
	return header, showTurns;
end

-- ---------------------------------------------------------------------------
-- A finished deal put back on the table. The deal screen takes the outgoing working
-- deal as it finds it whenever it is shown, so the items go there and the screen is
-- shown again. Every item is checked first: with one of them no longer possible, or
-- not affordable now, the table stays as it was.
-- ---------------------------------------------------------------------------
local OPTION_AGREEMENTS = { "JOINT_WAR", "THIRD_PARTY_WAR", "RESEARCH_AGREEMENT", "ALLIANCE" };

local function Possible(fromID, toID, itemType, deal, subType)
	if DealManager == nil or DealManager.GetPossibleDealItems == nil then return {} end
	local ok, list;
	if subType ~= nil then
		ok, list = pcall(DealManager.GetPossibleDealItems, fromID, toID, itemType, subType, deal);
	else
		ok, list = pcall(DealManager.GetPossibleDealItems, fromID, toID, itemType, deal);
	end
	if ok and type(list) == "table" then return list end
	return {};
end

-- As on the deal screen: an item that only waits for its counterpart can still be offered.
local function Usable(entry)
	if entry.IsValid ~= false then return true end
	return DealValidationResult ~= nil and entry.ValidationResult == DealValidationResult.MISSING_DEPENDENCY;
end

local function NeedsOption(subType)
	if DealAgreementTypes == nil then return false end
	for _, name in ipairs(OPTION_AGREEMENTS) do
		if DealAgreementTypes[name] ~= nil and DealAgreementTypes[name] == subType then return true end
	end
	return false;
end

-- The game's offer of this item right now, or nil.
local function OfferFor(stored, fromID, toID, deal)
	local itemType = DealRecord.TypeOf(stored.kind);
	if itemType == nil then return nil end
	if stored.kind == "AGREEMENTS" then
		local found = nil;
		for _, entry in ipairs(Possible(fromID, toID, itemType, deal)) do
			if found == nil and entry.SubType == stored.subType and Usable(entry) then found = entry end
		end
		if found == nil or not NeedsOption(stored.subType) then return found end
		for _, entry in ipairs(Possible(fromID, toID, itemType, deal, stored.subType)) do
			if entry.ForType == stored.valueType then return entry end
		end
		return nil;
	end
	for _, entry in ipairs(Possible(fromID, toID, itemType, deal)) do
		if entry.ForType == stored.valueType and Usable(entry) then return entry end
	end
	return nil;
end

-- A resource with no term is handed over together with its city, not on its own.
local function RidesWithCity(stored)
	return stored.kind == "RESOURCES" and DealRecord.IsInstant(stored);
end

local function Holds(stored, toID, deal)
	local player = Players ~= nil and Players[stored.from] or nil;
	if player == nil then return false end
	local kind = stored.kind;
	if kind == "GOLD" then
		-- The per-turn limit is only known to the item itself, so it is checked when added.
		if not DealRecord.IsInstant(stored) then return true end
		local treasury = Call(player, "GetTreasury");
		local balance = treasury ~= nil and Call(treasury, "GetGoldBalance") or nil;
		return type(balance) == "number" and math.floor(balance) >= (stored.amount or 0);
	elseif kind == "FAVOR" then
		local favor = Call(player, "GetFavor");
		return type(favor) == "number" and favor >= (stored.amount or 0);
	elseif kind == "RESOURCES" then
		if RidesWithCity(stored) then return true end
		local resources = Call(player, "GetResources");
		if resources == nil or resources.GetResourceAmount == nil then return false end
		local ok, have = pcall(resources.GetResourceAmount, resources, stored.valueType);
		return ok and type(have) == "number" and have >= (stored.amount or 0);
	elseif kind == "AGREEMENTS" or kind == "GREATWORK" or kind == "CITIES" or kind == "CAPTIVE" then
		return OfferFor(stored, stored.from, toID, deal) ~= nil;
	end
	return false;
end

local function Set(item, method, ...)
	local fn = item[method];
	if fn == nil then return false end
	return (pcall(fn, item, ...));
end

local function HasAgreement(deal, subType)
	local agreements = DealItemTypes ~= nil and DealItemTypes.AGREEMENTS or nil;
	local ok, iter, state, first = pcall(deal.Items, deal);
	if not ok or iter == nil then return false end
	for item in iter, state, first do
		if Call(item, "GetType") == agreements and Call(item, "GetSubType") == subType then return true end
	end
	return false;
end

local function Put(deal, stored, toID)
	local kind = stored.kind;
	local itemType = DealRecord.TypeOf(kind);
	if itemType == nil then return false end
	if RidesWithCity(stored) then return true end
	local entry = nil;
	if kind == "AGREEMENTS" then
		-- Both sides of a shared agreement are stored; the game adds the second one itself.
		if stored.mutual and HasAgreement(deal, stored.subType) then return true end
		entry = OfferFor(stored, stored.from, toID, deal);
		if entry == nil then return false end
	end
	local ok, item;
	if kind == "CITIES" then
		ok, item = pcall(deal.AddItemOfType, deal, itemType, stored.from, toID, stored.subType, stored.valueType);
	else
		ok, item = pcall(deal.AddItemOfType, deal, itemType, stored.from);
	end
	if not ok or item == nil then return false end
	if kind == "GOLD" or kind == "FAVOR" then
		-- The duration first: the limit for gold per turn differs from a lump sum.
		Set(item, "SetDuration", stored.duration or 0);
		local max = Call(item, "GetMaxAmount");
		if type(max) ~= "number" or max < (stored.amount or 0) then return false end
		Set(item, "SetAmount", stored.amount);
		return true;
	elseif kind == "RESOURCES" then
		Set(item, "SetValueType", stored.valueType);
		Set(item, "SetAmount", stored.amount);
		Set(item, "SetDuration", stored.duration);
	elseif kind == "AGREEMENTS" then
		Set(item, "SetSubType", stored.subType);
		Set(item, "SetDuration", stored.duration or 0);
		if NeedsOption(stored.subType) then
			Set(item, "SetValueType", entry.ForType);
			if type(entry.Parameters) == "table" and entry.Parameters.WarType ~= nil then
				Set(item, "SetParameterValue", "WarType", entry.Parameters.WarType);
			end
		end
	elseif kind == "GREATWORK" or kind == "CITIES" then
		Set(item, "SetSubType", stored.subType);
		Set(item, "SetValueType", stored.valueType);
	elseif kind == "CAPTIVE" then
		Set(item, "SetValueType", stored.valueType);
	end
	if item.IsValid == nil then return true end
	local valid, result = pcall(item.IsValid, item, deal);
	return valid and result ~= false;
end

-- nil when a locked item is on the table: such an item cannot be put back as it was.
local function ItemsOnTable(deal)
	local list = {};
	local ok, iter, state, first = pcall(deal.Items, deal);
	if not ok or iter == nil then return list end
	for item in iter, state, first do
		if Call(item, "IsLocked") == true then return nil end
		local stored = DealRecord.FromItem(item);
		if stored ~= nil then table.insert(list, stored) end
	end
	return list;
end

local function FillTable(localID, otherID, items)
	pcall(DealManager.ClearWorkingDeal, DealDirection.OUTGOING, localID, otherID);
	local deal = DealManager.GetWorkingDeal(DealDirection.OUTGOING, localID, otherID);
	if deal == nil then return false end
	for _, stored in ipairs(items) do
		local toID = stored.from == localID and otherID or localID;
		if not Put(deal, stored, toID) then return false end
	end
	if deal.Validate ~= nil then pcall(deal.Validate, deal) end
	return true;
end

-- When the other side opened the session, showing the screen again copies their proposal over ours.
local function SessionIsOurs(localID, otherID)
	if DiplomacyManager == nil or DiplomacyManager.FindOpenSessionID == nil or DiplomacyManager.GetSessionInfo == nil then return true end
	local ok, sessionID = pcall(DiplomacyManager.FindOpenSessionID, localID, otherID);
	if not ok or sessionID == nil or sessionID < 0 then return true end
	local got, info = pcall(DiplomacyManager.GetSessionInfo, sessionID);
	if not got or type(info) ~= "table" or info.FromPlayer == nil then return true end
	return info.FromPlayer ~= otherID;
end

local function ShowDealScreenAgain()
	local view = ContextPtr:LookUpControl("/InGame/DiplomacyDealView");
	if view == nil or view.SetHide == nil then return end
	pcall(view.SetHide, view, true);
	pcall(view.SetHide, view, false);
end

-- Returns why the table was left alone, or nil once the deal is on it.
local function ProposeAgain(items)
	if not (HasOtherPlayer() and DealViewOpen()) then return "no deal screen" end
	if DealManager == nil or DealManager.GetWorkingDeal == nil or DealManager.ClearWorkingDeal == nil or DealDirection == nil then
		return "no deal API";
	end
	local localID, otherID = LocalPlayerID(), m_OtherPlayerID;
	if items == nil or #items == 0 then return "empty" end
	for _, stored in ipairs(items) do
		if stored.from ~= localID and stored.from ~= otherID then return "another player's item" end
	end
	if DealManager.HasPendingDeal ~= nil then
		local ok, pending = pcall(DealManager.HasPendingDeal, localID, otherID);
		if ok and pending then return "a deal is pending" end
	end
	if not SessionIsOurs(localID, otherID) then return "their proposal is open" end
	local deal = DealManager.GetWorkingDeal(DealDirection.OUTGOING, localID, otherID);
	if deal == nil then return "no working deal" end
	local before = ItemsOnTable(deal);
	if before == nil then return "a locked item is on the table" end
	local sharedSeen = {};
	for _, stored in ipairs(items) do
		local toID = stored.from == localID and otherID or localID;
		local repeatShared = stored.mutual and sharedSeen[stored.subType];
		if stored.mutual then sharedSeen[stored.subType] = true end
		if not repeatShared and not Holds(stored, toID, deal) then
			return "not available " .. DealRecord.ItemsBrief({ stored });
		end
	end
	if not FillTable(localID, otherID, items) then
		FillTable(localID, otherID, before);
		return "the game refused an item";
	end
	ShowDealScreenAgain();
	if UI ~= nil and UI.PlaySound ~= nil then pcall(UI.PlaySound, "UI_GreatWorks_Put_Down") end
	return nil;
end

local function OnPickHistory(history)
	Try("repeat", function()
		local why = ProposeAgain(history.items);
		Log("repeat deal " .. tostring(history.record.id) .. " -> " .. (why or "on the table"));
	end);
end

-- ---------------------------------------------------------------------------
-- Card layout
-- ---------------------------------------------------------------------------
-- plainOnce: the one-time column already says "one-time", so no suffix is added.
local function LineTexts(entries, showTurns, plainOnce)
	local lines = {};
	for _, e in ipairs(entries) do
		if e.instant then
			table.insert(lines, plainOnce and e.text or Format("LOC_UIEXT_DEALS_ITEM_ONCE", e.text));
		elseif showTurns and e.untilTurn ~= nil then
			table.insert(lines, Format("LOC_UIEXT_HISTORY_ITEM_UNTIL", e.text, e.untilTurn));
		elseif showTurns and not e.openEnded then
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

local ONCE_GAP = 12;

local function SplitOnce(entries)
	local lasting, once = {}, {};
	for _, e in ipairs(entries) do
		table.insert(e.instant and once or lasting, e);
	end
	return lasting, once;
end

local function PlaceBody(label, x, y, width, lines)
	label:SetOffsetVal(x, y);
	label:SetWrapWidth(width);
	label:SetText(table.concat(lines, "[NEWLINE]"));
	label:SetHide(false);
	return y + TextHeight(lines, width);
end

-- One side of the card. "You give" stays on its own line. Under it, "Per turn"
-- and "One-time" share the next line, with a vertical divider between them.
-- Without one-time items there is no second column and no divider.
local function PlaceSide(inst, prefix, x, y, width, title, lasting, once, showTurns)
	local titleLabel, bodyLabel = inst[prefix .. "Title"], inst[prefix .. "Body"];
	local termTitle = inst[prefix .. "TermTitle"];
	local onceTitle, onceBody = inst[prefix .. "OnceTitle"], inst[prefix .. "OnceBody"];
	local divider = inst[prefix .. "Divider"];
	local lastingLines = LineTexts(lasting, showTurns, false);
	local onceLines = LineTexts(once, showTurns, true);

	if #onceLines == 0 then
		termTitle:SetHide(true);
		onceTitle:SetHide(true);
		onceBody:SetHide(true);
		divider:SetHide(true);
		return PlaceBlock(titleLabel, bodyLabel, x, y, width, title, lastingLines);
	end

	titleLabel:SetOffsetVal(x, y);
	titleLabel:SetText(title);
	titleLabel:SetHide(false);
	local headY = y + 20;

	local leftW = math.floor((width - ONCE_GAP) / 2);
	local rightX = x + leftW + ONCE_GAP;
	local rightW = width - leftW - ONCE_GAP;
	local bodyY = headY + 20;
	local yLeft = bodyY;
	if #lastingLines == 0 then
		termTitle:SetHide(true);
		bodyLabel:SetHide(true);
	else
		termTitle:SetOffsetVal(x, headY);
		termTitle:SetText(Lookup("LOC_UIEXT_DEALS_PER_TURN"));
		termTitle:SetHide(false);
		yLeft = PlaceBody(bodyLabel, x, bodyY, leftW, lastingLines);
	end
	onceTitle:SetOffsetVal(rightX, headY);
	onceTitle:SetText(Lookup("LOC_UIEXT_DEALS_ONCE"));
	onceTitle:SetHide(false);
	local yRight = PlaceBody(onceBody, rightX, bodyY, rightW, onceLines);

	local bottom = math.max(yLeft, yRight);
	divider:SetOffsetVal(x + leftW + math.floor(ONCE_GAP / 2), headY);
	divider:SetSizeVal(1, bottom - headY);
	divider:SetHide(false);
	return bottom;
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
	local oursLasting, oursOnce = SplitOnce(card.ours);
	local theirsLasting, theirsOnce = SplitOnce(card.theirs);
	local oursTitle = Lookup("LOC_UIEXT_DEALS_WE_GIVE");
	local theirsTitle = Format("LOC_UIEXT_DEALS_THEY_GIVE", leaderName);

	local theirsX = rightX;
	if #card.ours == 0 then theirsX = leftX end
	local yOurs = PlaceSide(inst, "Ours", leftX, y, colWidth, oursTitle, oursLasting, oursOnce, showTurns);
	local yTheirs = PlaceSide(inst, "Theirs", theirsX, y, colWidth, theirsTitle, theirsLasting, theirsOnce, showTurns);
	y = math.max(yOurs, yTheirs);

	local height = y + 8;
	inst.Top:SetSizeVal(m_CardWidth, height);
	inst.Background:SetSizeVal(m_CardWidth, height);
	inst.TopRule:SetSizeVal(m_CardWidth, 1);
	inst.Focus:SetSizeVal(m_CardWidth, height);
	inst.Focus:SetHide(not card.focused);

	-- A finished deal can be put back on the table with one click.
	local history = card.history;
	inst.Pick:SetHide(history == nil);
	if history ~= nil then
		inst.Pick:SetSizeVal(m_CardWidth, height);
		inst.Pick:SetToolTipString(Lookup("LOC_UIEXT_HISTORY_REPEAT_TIP"));
		inst.Pick:RegisterCallback(Mouse.eLClick, function() OnPickHistory(history) end);
	end
end

-- The history card a notification asked for: the same deal, or else one that started on that turn.
local function FocusIndex(cards)
	if m_Focus == nil then return nil end
	for i, card in ipairs(cards) do
		if card.history ~= nil and m_Focus.id ~= nil and card.history.record.id == m_Focus.id then return i end
	end
	for i, card in ipairs(cards) do
		if card.history ~= nil and m_Focus.turn ~= nil and card.history.record.turn == m_Focus.turn then return i end
	end
	return nil;
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

-- One entry of the tab, a deal or a trade route. sides: { { titleID, title, lines }, ... }
local function AddTabEntry(parent, header, sides)
	local deal = m_TabDealIM:GetInstance(parent);
	deal.Header:SetText(header);
	local locked = {};
	for _, s in ipairs(sides) do
		local entry = AddTabSide(deal, s[1], s[2], s[3]);
		if entry ~= nil then table.insert(locked, entry) end
	end
	deal.Sides:CalculateSize();
	deal.Top:CalculateSize();
	-- Measuring the parent can grow a side around a wrapped title. Lock the bullets back to the top.
	for _, entry in ipairs(locked) do
		LockTabSide(entry.side, entry.label, entry.title);
	end
end

local function AddTabDeal(card, leader)
	local header, showTurns = CardTiming(card);
	AddTabEntry(m_Tab.panel.TabCards, header, {
		{ "SharedTitle", Lookup("LOC_UIEXT_DEALS_SHARED"), LineTexts(card.shared, showTurns) },
		{ "OursTitle", Lookup("LOC_UIEXT_DEALS_WE_GIVE"), LineTexts(card.ours, showTurns) },
		{ "TheirsTitle", Format("LOC_UIEXT_DEALS_THEY_GIVE", leader), LineTexts(card.theirs, showTurns) },
	});
end

-- ---------------------------------------------------------------------------
-- Trade routes between the local player and the leader of the report, both ways.
-- A route names its cities, its trader and what each city earns. How many turns
-- it has left the game does not tell.
-- ---------------------------------------------------------------------------
local function PlayerCities(playerID)
	local player = Players ~= nil and Players[playerID] or nil;
	if player == nil then return nil end
	return Call(player, "GetCities");
end

local function RouteCityName(playerID, cityID)
	local cities = PlayerCities(playerID);
	if cities ~= nil and cities.FindID ~= nil then
		local ok, city = pcall(cities.FindID, cities, cityID);
		if ok and city ~= nil then return Lookup(Call(city, "GetName")) end
	end
	return Lookup("LOC_UIEXT_DEALS_CITY_UNNAMED");
end

local function AmountText(amount)
	local rounded = math.floor(amount * 10 + 0.5) / 10;
	if rounded == math.floor(rounded) then return string.format("%d", rounded) end
	return string.format("%.1f", rounded);
end

local function RouteYieldsText(yields)
	local parts = {};
	for _, y in ipairs(type(yields) == "table" and yields or {}) do
		local amount = tonumber(y.Amount) or 0;
		local info = GameInfo ~= nil and GameInfo.Yields ~= nil and GameInfo.Yields[y.YieldIndex] or nil;
		if amount ~= 0 and info ~= nil then
			table.insert(parts, (amount > 0 and "+" or "") .. AmountText(amount) .. " " .. (info.IconString or Lookup(info.Name)));
		end
	end
	if #parts == 0 then return Lookup("LOC_UIEXT_ROUTES_NO_YIELD") end
	return table.concat(parts, "  ");
end

local function CollectRoutes(fromID, toID, list)
	local cities = PlayerCities(fromID);
	if cities == nil or cities.Members == nil then return end
	local ok, iter, state, first = pcall(cities.Members, cities);
	if not ok or iter == nil then return end
	for _, city in iter, state, first do
		local trade = Call(city, "GetTrade");
		local routes = trade ~= nil and Call(trade, "GetOutgoingRoutes") or nil;
		for _, route in ipairs(type(routes) == "table" and routes or {}) do
			if route.DestinationCityPlayer == toID then
				table.insert(list, {
					ours = fromID == LocalPlayerID(),
					origin = RouteCityName(fromID, route.OriginCityID),
					destination = RouteCityName(toID, route.DestinationCityID),
					originYields = RouteYieldsText(route.OriginYields),
					destinationYields = RouteYieldsText(route.DestinationYields),
				});
			end
		end
	end
end

-- Our routes first, then theirs; each group by city names.
local function GatherRoutes(localID, otherID)
	local list = {};
	CollectRoutes(localID, otherID, list);
	CollectRoutes(otherID, localID, list);
	table.sort(list, function(a, b)
		if a.ours ~= b.ours then return a.ours end
		if a.origin ~= b.origin then return a.origin < b.origin end
		return a.destination < b.destination;
	end);
	return list;
end

local function AddTabRoute(route, leader)
	local header;
	if route.ours then
		header = Format("LOC_UIEXT_ROUTES_OURS", route.origin, route.destination);
	else
		header = Format("LOC_UIEXT_ROUTES_THEIRS", route.origin, route.destination, leader);
	end
	AddTabEntry(m_Tab.panel.TabRoutes, header, {
		{ route.ours and "OursTitle" or "TheirsTitle", route.origin, { route.originYields } },
		{ route.ours and "TheirsTitle" or "OursTitle", route.destination, { route.destinationYields } },
	});
end

local function RefreshDealsTab()
	if m_Tab == nil or m_Tab.playerID < 0 then return end
	local localID = LocalPlayerID();
	local cards = GatherDeals(localID, m_Tab.playerID);
	local routes = GatherRoutes(localID, m_Tab.playerID);
	local leader = LeaderName(m_Tab.playerID);
	m_TabItemIM:ResetInstances();
	m_TabSideIM:ResetInstances();
	m_TabDealIM:ResetInstances();
	for _, card in ipairs(cards) do
		AddTabDeal(card, leader);
	end
	for _, route in ipairs(routes) do
		AddTabRoute(route, leader);
	end
	local panel = m_Tab.panel;
	panel.TabCards:CalculateSize();
	panel.TabRoutes:CalculateSize();
	panel.TabEmpty:SetHide(#cards > 0);
	panel.RoutesEmpty:SetHide(#routes > 0);
	panel.TabBody:CalculateSize();
	panel.Top:SetSizeVal(TAB_WIDTH, panel.TabBody:GetSizeY() + 8);
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
	-- The deal screen banner has no ID and its animated parents span the whole screen,
	-- so its edge comes from the game's layout: Offset 20 plus Size 514.
	if DealViewOpen() then return DEAL_BANNER_EDGE end

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
	-- Never let a bad edge push the panel off screen.
	if left < 0 or left > screenW - SCREEN_MARGIN - MIN_PANEL_WIDTH then
		left = math.max(0, screenW - SCREEN_MARGIN - MIN_PANEL_WIDTH);
	end
	local width = screenW - left - SCREEN_MARGIN;
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

	local current = GatherDeals(LocalPlayerID(), otherID);
	Controls.ExpandButton:SetText(Lookup("LOC_UIEXT_DEALS_EXPAND") .. ": " .. tostring(#current));
	local cards = current;
	if m_ShowHistory then cards = GatherHistory(LocalPlayerID(), otherID) end
	Controls.EmptyLabel:SetText(Lookup(m_ShowHistory and "LOC_UIEXT_HISTORY_EMPTY" or "LOC_UIEXT_DEALS_EMPTY"));

	Log("refresh player=" .. tostring(otherID) .. " civ=" .. civ .. " cards=" .. tostring(#cards)
		.. (m_ShowHistory and " history" or ""));

	m_DealIM:ResetInstances();
	local leader = LeaderName(otherID);
	local focusIndex = m_ShowHistory and FocusIndex(cards) or nil;
	local focusY, cardY = 0, 0;
	for i, card in ipairs(cards) do
		Log(string.format("  card %d: ours=%d theirs=%d shared=%d soonest=%s",
			i, #card.ours, #card.theirs, #card.shared, tostring(card.soonest)));
		card.focused = i == focusIndex;
		if card.focused then focusY = cardY end
		local inst = m_DealIM:GetInstance();
		PopulateCard(inst, card, leader);
		cardY = cardY + inst.Top:GetSizeY() + DEAL_STACK_PADDING;
	end
	Controls.DealStack:CalculateSize();
	Controls.DealStack:ReprocessAnchoring();

	local empty = #cards == 0;
	Controls.EmptyLabel:SetHide(not empty);
	Controls.Scroll:SetHide(empty);

	-- Always the full height, so switching tabs does not resize the panel.
	local scrollH = math.max(ROW_HEIGHT * 4, math.floor(screenH * MAX_PANEL_FRACTION) - SCROLL_TOP - FOOTER_HEIGHT - 8);
	local panelH = SCROLL_TOP + scrollH + 8 + FOOTER_HEIGHT;
	local top = screenH - SCREEN_MARGIN - panelH;

	Controls.Root:SetOffsetVal(left, top);
	Controls.Root:SetSizeVal(width, panelH);
	Controls.Scroll:SetSizeVal(scrollW, scrollH);
	Controls.DealStack:SetSizeX(m_CardWidth);
	Controls.Root:ReprocessAnchoring();
	pcall(function() Controls.Scroll:CalculateInternalSize() end);
	if focusIndex ~= nil and not m_FocusScrolled then
		m_FocusScrolled = true;
		local range = Controls.DealStack:GetSizeY() - scrollH;
		local value = range > 0 and math.max(0, math.min(1, focusY / range)) or 0;
		pcall(function() Controls.Scroll:SetScrollValue(value) end);
	end

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
	m_Focus = nil;
	m_FocusScrolled = false;
end

-- ---------------------------------------------------------------------------
-- What was on the deal table. The game deletes one-time items while it enacts
-- the deal, before any event reaches this context, so the table is read while
-- the deal screen is open. When the deal is enacted, that copy joins its record.
-- ---------------------------------------------------------------------------
local function WorkingItems(localID, otherID)
	if DealManager == nil or DealManager.GetWorkingDeal == nil or DealDirection == nil then return {} end
	local function read(direction, a, b)
		local ok, deal = pcall(DealManager.GetWorkingDeal, direction, a, b);
		if not ok or deal == nil or deal.Items == nil then return {} end
		local list = {};
		local iok, iter, state, first = pcall(deal.Items, deal);
		if not iok or iter == nil then return list end
		for item in iter, state, first do
			local stored = DealRecord.FromItem(item);
			if stored ~= nil then table.insert(list, stored) end
		end
		return list;
	end
	local items = read(DealDirection.OUTGOING, localID, otherID);
	if #items == 0 then items = read(DealDirection.INCOMING, localID, otherID) end
	return items;
end

local function WatchDealTable()
	if not (m_Open and HasOtherPlayer() and DealViewOpen()) then return end
	local localID = LocalPlayerID();
	local items = WorkingItems(localID, m_OtherPlayerID);
	if #items == 0 then return end
	m_Watch = {
		key = DealRecord.PairKey(localID, m_OtherPlayerID),
		a = localID,
		b = m_OtherPlayerID,
		turn = Game.GetCurrentGameTurn(),
		items = items,
	};
end

local function TakeWatchFor(firstID, secondID)
	if m_Watch == nil or firstID == nil or secondID == nil then return nil end
	if m_Watch.key ~= DealRecord.PairKey(firstID, secondID) then return nil end
	if m_Watch.turn ~= Game.GetCurrentGameTurn() then
		m_Watch = nil;
		return nil;
	end
	local snap = m_Watch;
	m_Watch = nil;
	return snap;
end

-- ---------------------------------------------------------------------------
-- Diagnostics in the journal: how the diplomacy screen and the deal screen change
-- around a click on the deal button. Only changes are written, so the journal is
-- not filled every frame.
-- ---------------------------------------------------------------------------
-- "-" no such control, "0" hidden, "1" shown.
local function Shown(path)
	local control = ContextPtr:LookUpControl(path);
	if control == nil or control.IsHidden == nil then return "-" end
	local ok, hidden = pcall(control.IsHidden, control);
	if not ok then return "?" end
	return hidden and "0" or "1";
end

local ACTION_PATHS = { "/InGame/DiplomacyActionView", "/InGame/Diplomacy/DiplomacyActionView" };
local DEAL_PATHS = { "/InGame/DiplomacyDealView", "/InGame/Diplomacy/DiplomacyDealView" };

local function ActionViewPath()
	for _, path in ipairs(ACTION_PATHS) do
		if ContextPtr:LookUpControl(path) ~= nil then return path end
	end
	return nil;
end

local function ScreenState()
	local action = ActionViewPath();
	local bits = {
		"av=" .. Shown(ACTION_PATHS[1]) .. Shown(ACTION_PATHS[2]),
		"dv=" .. Shown(DEAL_PATHS[1]) .. Shown(DEAL_PATHS[2]),
	};
	if action ~= nil then
		table.insert(bits, "conv=" .. Shown(action .. "/ConversationContainer"));
		table.insert(bits, "over=" .. Shown(action .. "/OverviewContainer"));
		table.insert(bits, "fade=" .. Shown(action .. "/BlackFade"));
	end
	local localID = LocalPlayerID();
	if HasOtherPlayer() and DiplomacyManager ~= nil and DiplomacyManager.FindOpenSessionID ~= nil then
		local ok, sessionID = pcall(DiplomacyManager.FindOpenSessionID, localID, m_OtherPlayerID);
		local session = ok and sessionID ~= nil and sessionID >= 0 and sessionID or nil;
		local from = nil;
		if session ~= nil and DiplomacyManager.GetSessionInfo ~= nil then
			local got, info = pcall(DiplomacyManager.GetSessionInfo, session);
			if got and type(info) == "table" then from = info.FromPlayer end
		end
		table.insert(bits, "with=" .. tostring(m_OtherPlayerID) .. " session=" .. tostring(session) .. " from=" .. tostring(from));
	end
	table.insert(bits, "open=" .. (m_Open and "1" or "0"));
	return table.concat(bits, " ");
end

local m_ScreenState = nil;

local function DiagScreen()
	local state = ScreenState();
	if state == m_ScreenState then return end
	m_ScreenState = state;
	Journal("diag screen " .. state);
end

local function KeyName(value)
	if value == nil or DiplomacyManager == nil or DiplomacyManager.GetKeyName == nil then return tostring(value) end
	local ok, name = pcall(DiplomacyManager.GetKeyName, value);
	if ok and name ~= nil then return tostring(name) end
	return tostring(value);
end

local function OnDiagStatement(fromID, toID, variants)
	Try("diag", function()
		local localID = LocalPlayerID();
		if fromID ~= localID and toID ~= localID then return end
		variants = type(variants) == "table" and variants or {};
		Journal("diag statement " .. tostring(fromID) .. "->" .. tostring(toID)
			.. " " .. KeyName(variants.StatementType) .. "/" .. KeyName(variants.StatementSubType)
			.. " response=" .. tostring(variants.ResponseType) .. " session=" .. tostring(variants.SessionID));
		DiagScreen();
	end);
end

local function DiagInput(input)
	if input == nil or input.GetMessageType == nil or KeyEvents == nil then return end
	local message = input:GetMessageType();
	if message == KeyEvents.KeyUp and Keys ~= nil and input:GetKey() == Keys.VK_ESCAPE then
		Journal("diag escape | " .. ScreenState());
	elseif MouseEvents ~= nil and message == MouseEvents.LButtonUp then
		local action = Shown(ACTION_PATHS[1]) .. Shown(ACTION_PATHS[2]);
		local deal = Shown(DEAL_PATHS[1]) .. Shown(DEAL_PATHS[2]);
		-- Clicks on the deal screen itself would push the useful lines out of the journal.
		if action:find("1", 1, true) and not deal:find("1", 1, true) then
			Journal("diag click | " .. ScreenState());
		end
	end
end

local function RegisterDiagnostics()
	Events.DiplomacyStatement.Add(OnDiagStatement);
	Events.DiplomacySessionClosed.Add(function(sessionID)
		Try("diag", function() Journal("diag session closed " .. tostring(sessionID) .. " | " .. ScreenState()) end);
	end);
	Events.LeaderScreenFinishedLoading.Add(function()
		Try("diag", function() Journal("diag leader loaded | " .. ScreenState()) end);
	end);
	LuaEvents.DiploPopup_ShowMakeDeal.Add(function(playerID)
		Try("diag", function() Journal("diag show deal " .. tostring(playerID) .. " | " .. ScreenState()) end);
	end);
	if ContextPtr.SetInputHandler ~= nil then
		-- Only watches: the input always goes on to the game.
		ContextPtr:SetInputHandler(function(input)
			pcall(DiagInput, input);
			return false;
		end, true);
	end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
local function OnToggle()
	m_Expanded = not m_Expanded;
	ApplyVisibility();
end

local function ShowTabSelection()
	local function mark(prefix, selected)
		Controls[prefix]:SetSelected(selected);
		Controls[prefix .. "Selected"]:SetHide(not selected);
		Controls[prefix .. "Label"]:SetHide(selected);
		Controls[prefix .. "SelectedLabel"]:SetHide(not selected);
	end
	mark("CurrentTab", not m_ShowHistory);
	mark("HistoryTab", m_ShowHistory);
end

local function SelectTab(history)
	m_ShowHistory = history;
	ShowTabSelection();
	if m_Open then Refresh() end
end

-- The deal screen with this leader, on the history tab, at the finished deal.
-- At war there is no deal screen, so the diplomacy screen opens instead.
local function OpenHistoryOf(partnerID, focus)
	local localID = LocalPlayerID();
	if localID < 0 or partnerID == nil or partnerID < 0 or partnerID == localID then return end
	m_OtherPlayerID = partnerID;
	m_Focus = focus;
	m_FocusScrolled = false;
	m_ShowHistory = true;
	ShowTabSelection();
	local atWar = false;
	pcall(function() atWar = Players[localID]:GetDiplomacy():IsAtWarWith(partnerID) == true end);
	if atWar or DiplomacyManager == nil or DiplomacyManager.RequestSession == nil then
		LuaEvents.DiplomacyRibbon_OpenDiplomacyActionView(partnerID);
		Log("notification opens diplomacy player=" .. tostring(partnerID) .. (atWar and " at war" or ""));
		return;
	end
	-- As the game's own "make a deal": start from an empty table unless a deal is pending.
	if DealManager ~= nil and DealManager.ClearWorkingDeal ~= nil and DealDirection ~= nil then
		local ok, pending = pcall(DealManager.HasPendingDeal, localID, partnerID);
		if not (ok and pending) then
			pcall(DealManager.ClearWorkingDeal, DealDirection.OUTGOING, localID, partnerID);
		end
	end
	pcall(DiplomacyManager.RequestSession, localID, partnerID, "MAKE_DEAL");
	Log("notification opens deal history player=" .. tostring(partnerID) .. " deal=" .. tostring(focus and focus.id));
end

local function NotificationValue(notification, key)
	if notification == nil or notification.GetValue == nil then return nil end
	local ok, value = pcall(notification.GetValue, notification, key);
	if ok then return value end
	return nil;
end

local function OnUserNotification(playerID, notificationID)
	Try("notification", function()
		if playerID ~= LocalPlayerID() or NotificationManager == nil or NotificationManager.Find == nil then return end
		local ok, notification = pcall(NotificationManager.Find, playerID, notificationID);
		if not ok or notification == nil then return end
		if NotificationValue(notification, DealRecord.NOTIFY_MARK) == nil then return end
		OpenHistoryOf(tonumber(NotificationValue(notification, "UIExtPartner")), {
			id = tonumber(NotificationValue(notification, "UIExtDealID")),
			turn = tonumber(NotificationValue(notification, "UIExtTurn")),
		});
	end);
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

local function OnDealEnacted(firstID, secondID)
	Try("deal record", function()
		local snap = TakeWatchFor(firstID, secondID);
		if snap ~= nil and EnsureArchive() then
			local deal = DealRecord.Accept(m_Archive, snap);
			if deal ~= nil then
				PutRecord(deal);
				Journal("accepted " .. DealRecord.Brief(deal));
			end
		end
		Sync("enact");
	end);
	OnDealsChanged();
end

-- A deal runs out between turns, and war cancels deals at once; both are seen here.
local function OnDealsMayHaveEnded(why)
	Try("deal record", Sync, why);
	OnDealsChanged();
end

-- The game may list a new deal, or drop a cancelled one, a moment after its event,
-- so the record is also compared with the game every few seconds.
local POLL_STEPS = 60;

local function PollDeals()
	m_PollTick = m_PollTick + 1;
	if m_PollTick < POLL_STEPS and m_Archive ~= nil then return end
	m_PollTick = 0;
	Sync("poll");
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
	local dealOpen = DealViewOpen();
	if dealOpen ~= m_DealViewWasOpen then
		m_DealViewWasOpen = dealOpen;
		-- A fresh negotiation: what was on the table last time is not this deal.
		if dealOpen then m_Watch = nil end
		if m_Open and HasOtherPlayer() then
			Refresh();
		end
	end
	Try("diag", DiagScreen);
	Try("watch", WatchDealTable);
	Try("deal record", PollDeals);
	Try("flows", UpdateResourceFlows);
	Try("deals tab", SyncDealsTab);
	Try("panel", ApplyVisibility);
end

-- ---------------------------------------------------------------------------
local function Initialize()
	if DealRecord == nil then
		error("DealRecord.lua is not loaded: it must be listed in ImportFiles in the modinfo");
	end
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
	Controls.CurrentTab:RegisterCallback(Mouse.eLClick, function() SelectTab(false) end);
	Controls.HistoryTab:RegisterCallback(Mouse.eLClick, function() SelectTab(true) end);
	ShowTabSelection();

	LuaEvents.DiploScene_SceneOpened.Add(OnPlayerChosen);
	LuaEvents.DiploScene_LeaderSelect.Add(OnPlayerChosen);
	LuaEvents.DiplomacyRibbon_OpenDiplomacyActionView.Add(OnPlayerChosen);
	LuaEvents.TopPanel_OpenDiplomacyActionView.Add(OnPlayerChosen);
	LuaEvents.DiploScene_SceneClosed.Add(OnSceneClosed);
	LuaEvents.DiplomacyActionView_ShowIngameUI.Add(OnSceneClosed);
	LuaEvents.DiploPopup_HideDeal.Add(OnDealsChanged);
	Events.DiplomacyDealEnacted.Add(OnDealEnacted);
	Events.LocalPlayerTurnBegin.Add(function() OnDealsMayHaveEnded("turn") end);
	Events.DiplomacyDeclareWar.Add(function() OnDealsMayHaveEnded("war") end);
	LuaEvents.DiploScene_RefreshTabs.Add(OnRefreshTabs);
	LuaEvents.NotificationPanel_UserNotificationActivate.Add(OnUserNotification);
	Try("diag", RegisterDiagnostics);
	Log("initialized");
end

Try("init", Initialize);
