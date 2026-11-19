-- Writes concluded deals into the save. The interface also stores the same text
-- in GameConfiguration at the moment of the deal: SetProperty from that context
-- does not reach the save, and the player operation arrives after one-time items
-- are already gone.
--
-- This script still records every machine's deals into the game property. On load
-- it keeps one-time items the configuration already has, and it never writes the
-- configuration itself, so a later backfill cannot wipe them.
include("DealRecord");

local function Log(message)
	print("UIExt: " .. tostring(message));
end

local function Call(object, method)
	if object == nil then return nil end
	local fn = object[method];
	if fn == nil then return nil end
	local ok, value = pcall(fn, object);
	if ok then return value end
	return nil;
end

local function CurrentTurn()
	if Game == nil or Game.GetCurrentGameTurn == nil then return 0 end
	local ok, turn = pcall(function() return Game.GetCurrentGameTurn() end);
	if ok and type(turn) == "number" then return turn end
	return 0;
end

local function Load()
	local property = nil;
	if Game ~= nil and Game.GetProperty ~= nil then
		local ok, raw = pcall(Game.GetProperty, Game, DealRecord.PROP);
		if ok then property = raw end
	end
	local config = nil;
	if GameConfiguration ~= nil and GameConfiguration.GetValue ~= nil then
		local ok, raw = pcall(GameConfiguration.GetValue, DealRecord.PROP);
		if ok then config = raw end
	end
	return DealRecord.MergeArchives(property, config);
end

local function Save(data)
	if Game == nil or Game.SetProperty == nil then return end
	-- A string is what the game actually writes into the save. A table does not come back.
	-- The configuration copy is left to the interface: overwriting it here would
	-- replace a complete archive with whatever this script managed to see.
	pcall(Game.SetProperty, Game, DealRecord.PROP, DealRecord.EncodeArchive(data));
end

local function EachItem(deal, fn)
	if deal == nil or deal.Items == nil then return end
	local ok, iter, state, first = pcall(deal.Items, deal);
	if not ok or iter == nil then return end
	for item in iter, state, first do
		fn(item);
	end
end

local function ItemsOf(deal)
	local list = {};
	EachItem(deal, function(item)
		local stored = DealRecord.FromItem(item);
		if stored ~= nil then table.insert(list, stored) end
	end);
	return list;
end

local function EnactedTurn(deal, fallback)
	local turn = nil;
	EachItem(deal, function(item)
		local enacted = Call(item, "GetEnactedTurn");
		if enacted ~= nil and enacted >= 0 and (turn == nil or enacted < turn) then
			turn = enacted;
		end
	end);
	if turn == nil then return fallback end
	return turn;
end

local function LiveFrom(deal, a, b, fallbackTurn)
	local id = Call(deal, "GetID");
	if id == nil then return nil end
	return {
		id = id,
		a = a,
		b = b,
		turn = EnactedTurn(deal, fallbackTurn),
		items = ItemsOf(deal),
	};
end

local function ReadPair(a, b)
	local list = {};
	if DealManager == nil or DealManager.GetPlayerDeals == nil then return list end
	local ok, deals = pcall(DealManager.GetPlayerDeals, a, b);
	if not ok or type(deals) ~= "table" then return list end
	local turn = CurrentTurn();
	for _, deal in ipairs(deals) do
		local live = LiveFrom(deal, a, b, turn);
		if live ~= nil then table.insert(list, live) end
	end
	return list;
end

local function ReadWorking(a, b)
	local list = {};
	if DealManager == nil or DealManager.GetWorkingDeal == nil or DealDirection == nil then return list end
	local seen = {};
	local function take(direction, fromID, toID)
		local ok, deal = pcall(DealManager.GetWorkingDeal, direction, fromID, toID);
		if not ok or deal == nil then return end
		for _, item in ipairs(ItemsOf(deal)) do
			local key = DealRecord.ItemKey(item);
			if not seen[key] then
				seen[key] = true;
				table.insert(list, item);
			end
		end
	end
	take(DealDirection.OUTGOING, a, b);
	take(DealDirection.INCOMING, a, b);
	take(DealDirection.OUTGOING, b, a);
	take(DealDirection.INCOMING, b, a);
	return list;
end

local function AliveIDs()
	local ids = {};
	if PlayerManager == nil or PlayerManager.GetAliveMajors == nil then return ids end
	local ok, majors = pcall(PlayerManager.GetAliveMajors);
	if not ok or majors == nil then return ids end
	for _, player in ipairs(majors) do
		local id = Call(player, "GetID");
		if id ~= nil then table.insert(ids, id) end
	end
	table.sort(ids);
	return ids;
end

local function AllLive()
	local list = {};
	local ids = AliveIDs();
	for i = 1, #ids do
		for j = i + 1, #ids do
			for _, live in ipairs(ReadPair(ids[i], ids[j])) do
				table.insert(list, live);
			end
		end
	end
	return list;
end

local function OnSnapshotPayload(payload)
	if type(payload) ~= "table" then return end
	local data = Load();
	local before = #data.deals;
	data = DealRecord.OnSnapshot(data, {
		a = payload.a,
		b = payload.b,
		turn = payload.turn,
		accepted = payload.accepted,
		-- `items` is a name the operation itself uses, so the text rides as uiextItems.
		items = DealRecord.DecodeItems(payload.uiextItems or payload.items),
	});
	Save(data);
	if #data.deals ~= before then
		Log("archive snapshot deals=" .. tostring(#data.deals));
	end
end

local function OnEnacted(firstID, secondID)
	if firstID == nil or secondID == nil then return end
	local ok, err = pcall(function()
		local data = Load();
		local before = #data.deals;
		data = DealRecord.OnEnacted(data, {
			a = firstID,
			b = secondID,
			turn = CurrentTurn(),
			live = ReadPair(firstID, secondID),
			working = ReadWorking(firstID, secondID),
		});
		Save(data);
		if #data.deals ~= before then
			Log("archive enacted " .. tostring(firstID) .. "," .. tostring(secondID) .. " deals=" .. tostring(#data.deals));
		end
	end);
	if not ok then Log("archive " .. tostring(err)) end
end

local function OnOperation(_, params)
	local ok, err = pcall(OnSnapshotPayload, params);
	if not ok then Log("snapshot " .. tostring(err)) end
end

local function Initialize()
	if DealRecord == nil then
		error("DealRecord.lua is not loaded: it must be listed in ImportFiles in the modinfo");
	end
	local data = DealRecord.Backfill(Load(), AllLive());
	Save(data);
	Events.DiplomacyDealEnacted.Add(OnEnacted);
	GameEvents.UIExt_OnDealSnapshot.Add(OnOperation);
	if ExposedMembers ~= nil then
		ExposedMembers.UIExt = ExposedMembers.UIExt or {};
		ExposedMembers.UIExt.RecordSnapshot = OnSnapshotPayload;
	end
	Log("archive ready deals=" .. tostring(#data.deals));
end

local ok, err = pcall(Initialize);
if not ok then Log("archive init " .. tostring(err)) end
