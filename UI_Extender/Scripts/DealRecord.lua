-- Record of the local player's deals, shared by the diplomacy UI that keeps it and
-- the gameplay script that writes it into the save.
--
-- The game gives a deal no id, and forgets it once it ends. Only the interface can
-- list deals (DealManager.GetPlayerDeals returns nothing to a gameplay script), so
-- the interface compares that list with this record, the way the game's own report
-- screen reads a deal: by its players, the turn it was enacted and its items.
--
--   { deals = { { id, turn, a, b, ended, items = { item, ... } }, ... }, next = 0 }
--
-- a < b. id is this record's own number, negative, from next. turn is the turn the
-- deal was enacted. ended is the turn the game stopped listing it, or nil while it runs.
-- items include what the game deletes on the turn of the deal (lump gold, a city,
-- a great work, favor): the interface reads those from the deal table when it is accepted.

DealRecord = DealRecord or {};

-- Each player's record is a game property of its own, written only by the gameplay script.
DealRecord.ARCHIVE_PREFIX = "UIEXT_DEALS_P";
-- Where earlier versions kept the record of every player; read once to carry it over.
DealRecord.PROP = "UIEXT_DEAL_ARCHIVE";

-- Player operations from the interface to the gameplay script (EXECUTE_SCRIPT, OnStart).
DealRecord.OP_PUT = "UIExt_PutDealRecord";
DealRecord.OP_NOTIFY = "UIExt_NotifyDealEnded";

-- The notification about a finished deal. The game draws and activates its user-defined
-- types without any database change; the mark tells this mod's notifications apart.
-- USER_DEFINED_9 is a deal that ran its term (the deal-expired icon).
-- USER_DEFINED_8 is a deal cut short (the broken-promise icon). One type has one icon.
-- The pirate scenario claims slot 8, and only while that scenario is loaded.
DealRecord.NOTIFY_TYPE = "USER_DEFINED_9";
DealRecord.NOTIFY_BROKEN_TYPE = "USER_DEFINED_8";
DealRecord.NOTIFY_MARK = "UIExtDealEnded";

function DealRecord.ArchiveKey(player)
	return DealRecord.ARCHIVE_PREFIX .. tostring(player);
end

local function Call(object, method)
	if object == nil then return nil end
	local fn = object[method];
	if fn == nil then return nil end
	local ok, value = pcall(fn, object);
	if ok then return value end
	return nil;
end

local function Lookup(key)
	if key == nil or key == "" then return "" end
	if Locale == nil or Locale.Lookup == nil then return tostring(key) end
	local ok, text = pcall(Locale.Lookup, key);
	if ok and text ~= nil then return text end
	return tostring(key);
end

local function Format(key, ...)
	if Locale == nil or Locale.Lookup == nil then return tostring(key) end
	local ok, text = pcall(Locale.Lookup, key, ...);
	if ok and text ~= nil then return text end
	return tostring(key);
end

function DealRecord.Empty()
	return { deals = {}, next = 0 };
end

-- An archive saved as a table comes back with string keys, so ipairs would see nothing.
local function AsList(map)
	local list = {};
	if type(map) ~= "table" then return list end
	for _, value in pairs(map) do
		if type(value) == "table" then table.insert(list, value) end
	end
	return list;
end

local function Number(value, fallback)
	local n = tonumber(value);
	if n == nil then return fallback end
	return n;
end

local function ItemFromRaw(item)
	if type(item) ~= "table" or item.kind == nil or item.kind == "" then return nil end
	return {
		kind = item.kind,
		amount = Number(item.amount, 0),
		duration = Number(item.duration, 0),
		from = Number(item.from, nil),
		valueType = Number(item.valueType, -1),
		subType = Number(item.subType, -1),
		name = item.name or "",
		alliance = item.alliance == true or item.alliance == 1,
		mutual = item.mutual == true or item.mutual == 1,
	};
end

local function ItemsFromRaw(raw)
	local items = {};
	for _, item in ipairs(AsList(raw)) do
		local stored = ItemFromRaw(item);
		if stored ~= nil then table.insert(items, stored) end
	end
	return items;
end

-- Text (the saved form) or a table, possibly with string keys, into a clean archive.
-- accepted is kept only as read: earlier versions stored one-time items there.
function DealRecord.Normalize(data)
	if type(data) == "string" then data = DealRecord.DecodeArchive(data) end
	if type(data) ~= "table" then return DealRecord.Empty() end
	local deals = {};
	for _, deal in ipairs(AsList(data.deals)) do
		local a, b = Number(deal.a, nil), Number(deal.b, nil);
		if a ~= nil and b ~= nil then
			table.insert(deals, {
				id = Number(deal.id, nil),
				turn = Number(deal.turn, 0),
				a = math.min(a, b),
				b = math.max(a, b),
				ended = Number(deal.ended, nil),
				items = ItemsFromRaw(deal.items),
			});
		end
	end
	local accepted = {};
	for _, snap in ipairs(AsList(data.accepted)) do
		local a, b = Number(snap.a, nil), Number(snap.b, nil);
		if a ~= nil and b ~= nil then
			table.insert(accepted, { a = math.min(a, b), b = math.max(a, b), turn = Number(snap.turn, 0), items = ItemsFromRaw(snap.items) });
		end
	end
	local nextID = Number(data.next, 0);
	for _, deal in ipairs(deals) do
		if deal.id ~= nil and deal.id < nextID then nextID = deal.id end
	end
	if nextID > 0 then nextID = 0 end
	return { deals = deals, accepted = accepted, next = nextID };
end

function DealRecord.Pair(a, b)
	if a > b then return b, a end
	return a, b;
end

function DealRecord.PairKey(a, b)
	a, b = DealRecord.Pair(a, b);
	return tostring(a) .. ":" .. tostring(b);
end

function DealRecord.Kind(rawType)
	if DealItemTypes == nil or rawType == nil then return "" end
	for name, value in pairs(DealItemTypes) do
		if value == rawType then
			if name == "DIPLOMATIC_FAVOR" then return "FAVOR" end
			return name;
		end
	end
	return "";
end

-- The game's item type for a stored kind. Favor is FAVOR in one ruleset and DIPLOMATIC_FAVOR in another.
function DealRecord.TypeOf(kind)
	if DealItemTypes == nil or kind == nil then return nil end
	if kind == "FAVOR" then return DealItemTypes.FAVOR or DealItemTypes.DIPLOMATIC_FAVOR end
	return DealItemTypes[kind];
end

local function AgreementNamed(subType, name)
	return DealAgreementTypes ~= nil and DealAgreementTypes[name] ~= nil and subType == DealAgreementTypes[name];
end

function DealRecord.IsMutualType(subType)
	return AgreementNamed(subType, "DEFENSIVE_PACT")
		or AgreementNamed(subType, "RESEARCH_AGREEMENT")
		or AgreementNamed(subType, "JOINT_WAR")
		or AgreementNamed(subType, "THIRD_PARTY_WAR")
		or AgreementNamed(subType, "MAKE_PEACE")
		or AgreementNamed(subType, "ALLIANCE");
end

-- An alliance is the one duration-0 item the game keeps. Everything else with no
-- duration is handed over immediately and then deleted.
function DealRecord.IsInstant(item)
	if item == nil or item.alliance then return false end
	return (item.duration or 0) <= 0;
end

function DealRecord.Lasting(items)
	local list = {};
	for _, item in ipairs(items or {}) do
		if not DealRecord.IsInstant(item) then table.insert(list, item) end
	end
	return list;
end

function DealRecord.ItemKey(item)
	return table.concat({
		tostring(item.kind or ""),
		tostring(item.amount or 0),
		tostring(item.duration or 0),
		tostring(item.from or -1),
		tostring(item.valueType or -1),
		tostring(item.subType or -1),
	}, ":");
end

function DealRecord.CopyItem(item)
	return {
		kind = item.kind or "",
		amount = item.amount or 0,
		duration = item.duration or 0,
		from = item.from,
		valueType = item.valueType or -1,
		subType = item.subType or -1,
		name = item.name or "",
		alliance = item.alliance and true or false,
		mutual = item.mutual and true or false,
	};
end

function DealRecord.FromItem(item)
	local kind = DealRecord.Kind(Call(item, "GetType"));
	if kind == "" then return nil end
	local fromPlayer = Call(item, "GetFromPlayerID");
	if fromPlayer == nil then return nil end
	local subType = Call(item, "GetSubType") or -1;
	local name = Call(item, "GetSubTypeNameID");
	if name == nil or name == "" then name = Call(item, "GetValueTypeNameID") or "" end
	local alliance = kind == "AGREEMENTS" and AgreementNamed(subType, "ALLIANCE");
	return {
		kind = kind,
		amount = Call(item, "GetAmount") or 0,
		duration = Call(item, "GetDuration") or 0,
		from = fromPlayer,
		valueType = Call(item, "GetValueType") or -1,
		subType = subType,
		name = name or "",
		alliance = alliance and true or false,
		mutual = kind == "AGREEMENTS" and DealRecord.IsMutualType(subType) or false,
	};
end

function DealRecord.FindID(data, id)
	id = tonumber(id);
	if id == nil then return nil end
	for _, deal in ipairs(data.deals) do
		if tonumber(deal.id) == id then return deal end
	end
	return nil;
end

-- True when every live item is part of the snapshot. An empty live list does not
-- match: a leftover shell must not absorb an unrelated deal.
function DealRecord.Covers(snapshotItems, liveItems)
	if liveItems == nil or #liveItems == 0 then return false end
	local have = {};
	for _, item in ipairs(snapshotItems or {}) do
		have[DealRecord.ItemKey(item)] = true;
	end
	for _, item in ipairs(liveItems) do
		if not have[DealRecord.ItemKey(item)] then return false end
	end
	return true;
end

local function SameItems(x, y)
	if #x ~= #y then return false end
	return DealRecord.Covers(x, y) and DealRecord.Covers(y, x);
end

function DealRecord.MergeItems(deal, items)
	local seen = {};
	for _, item in ipairs(deal.items) do
		seen[DealRecord.ItemKey(item)] = true;
	end
	for _, item in ipairs(items or {}) do
		if item.from ~= nil and item.kind ~= nil and item.kind ~= "" then
			local copy = DealRecord.CopyItem(item);
			local key = DealRecord.ItemKey(copy);
			if not seen[key] then
				seen[key] = true;
				table.insert(deal.items, copy);
			end
		end
	end
end

function DealRecord.AddRecord(data, a, b, turn, items)
	data.next = math.min(data.next or 0, 0) - 1;
	local deal = { id = data.next, turn = turn or 0, a = math.min(a, b), b = math.max(a, b), items = {} };
	DealRecord.MergeItems(deal, items);
	table.insert(data.deals, deal);
	return deal;
end

-- ---------------------------------------------------------------------------
-- Matching the game's deal list
-- ---------------------------------------------------------------------------
function DealRecord.IsOneTime(deal)
	if deal == nil or deal.items == nil or #deal.items == 0 then return false end
	for _, item in ipairs(deal.items) do
		if not DealRecord.IsInstant(item) then return false end
	end
	return true;
end

-- The running record that is this live deal { a, b, turn, items }: same players, enacted
-- on the same turn, holding every lasting item the game lists. The game drops one-time
-- items and, one by one, items whose term is over, so the record may hold more.
-- taken: records already matched to another live deal.
function DealRecord.FindRecord(data, live, taken)
	if data == nil or live == nil or live.a == nil or live.b == nil then return nil end
	local lasting = DealRecord.Lasting(live.items);
	if #lasting == 0 then return nil end
	local a, b = DealRecord.Pair(live.a, live.b);
	local found, exact = nil, nil;
	for _, deal in ipairs(data.deals) do
		if deal.a == a and deal.b == b and deal.turn == live.turn and deal.ended == nil
			and not (taken ~= nil and taken[deal]) and DealRecord.Covers(deal.items, lasting) then
			found = found or deal;
			if exact == nil and SameItems(DealRecord.Lasting(deal.items), lasting) then exact = deal end
		end
	end
	return exact or found;
end

-- The turn the last lasting item runs out, or nil when an item has no term.
function DealRecord.ExpectedEnd(deal)
	local longest = nil;
	for _, item in ipairs(deal.items or {}) do
		if not DealRecord.IsInstant(item) then
			if (item.duration or 0) <= 0 then return nil end
			if longest == nil or item.duration > longest then longest = item.duration end
		end
	end
	if longest == nil then return nil end
	return (deal.turn or 0) + longest;
end

-- Compares the record with the deals the game lists now.
-- lives: { { a, b, turn, items }, ... } for every pair in pairs (PairKey -> true) the game answered for.
-- A live deal with no record gets one. A running record the game no longer lists has
-- ended: now, or with its term when that was already over (a save played without the mod).
-- A record from the turn of its deal is never ended: the game may not list the deal yet.
-- Returns the records that were added or changed, and those that ended.
function DealRecord.Track(data, lives, pairs, now)
	local taken, changed, finished = {}, {}, {};
	for _, live in ipairs(lives or {}) do
		if #DealRecord.Lasting(live.items) > 0 then
			local deal = DealRecord.FindRecord(data, live, taken);
			if deal == nil then
				deal = DealRecord.AddRecord(data, live.a, live.b, live.turn, live.items);
				table.insert(changed, deal);
			else
				local count = #deal.items;
				DealRecord.MergeItems(deal, live.items);
				if #deal.items ~= count then table.insert(changed, deal) end
			end
			taken[deal] = true;
		end
	end
	for _, deal in ipairs(data.deals) do
		if deal.ended == nil and not taken[deal] and pairs ~= nil and pairs[DealRecord.PairKey(deal.a, deal.b)]
			and #deal.items > 0 and not DealRecord.IsOneTime(deal) and (deal.turn or 0) < now then
			local expected = DealRecord.ExpectedEnd(deal);
			local ended = now;
			if expected ~= nil and expected < now then ended = expected end
			deal.ended = math.max(ended, deal.turn or 0);
			table.insert(finished, deal);
		end
	end
	return changed, finished;
end

-- The deal table the local player saw enacted (snap: { a, b, turn, items }). With lasting
-- items it joins the record of that deal, or starts it before the game lists the deal.
-- One-time items alone are a deal of their own, finished on that turn.
function DealRecord.Accept(data, snap)
	if snap == nil or snap.a == nil or snap.b == nil or snap.items == nil or #snap.items == 0 then return nil end
	local a, b = DealRecord.Pair(snap.a, snap.b);
	if #DealRecord.Lasting(snap.items) > 0 then
		for _, deal in ipairs(data.deals) do
			if deal.a == a and deal.b == b and deal.turn == snap.turn and deal.ended == nil
				and DealRecord.Covers(snap.items, DealRecord.Lasting(deal.items)) then
				DealRecord.MergeItems(deal, snap.items);
				return deal;
			end
		end
	end
	return DealRecord.AddRecord(data, a, b, snap.turn, snap.items);
end

-- Carries the deals of player over from an archive of an earlier version. One deal
-- could be stored there twice, and its one-time items separately in accepted.
function DealRecord.Import(data, legacy, player)
	legacy = DealRecord.Normalize(legacy);
	local added = {};
	for _, old in ipairs(legacy.deals) do
		if (old.a == player or old.b == player) and #old.items > 0 then
			local items = {};
			for _, item in ipairs(old.items) do table.insert(items, item) end
			local lasting = DealRecord.Lasting(old.items);
			for _, snap in ipairs(legacy.accepted) do
				if snap.a == old.a and snap.b == old.b and snap.turn == old.turn and DealRecord.Covers(snap.items, lasting) then
					for _, item in ipairs(snap.items) do
						if DealRecord.IsInstant(item) then table.insert(items, item) end
					end
				end
			end
			local same = nil;
			for _, deal in ipairs(data.deals) do
				if deal.a == old.a and deal.b == old.b and deal.turn == old.turn
					and (SameItems(deal.items, items) or (#lasting > 0 and DealRecord.Covers(deal.items, lasting))) then
					same = deal;
				end
			end
			if same == nil then
				same = DealRecord.AddRecord(data, old.a, old.b, old.turn, items);
				same.ended = old.ended;
				table.insert(added, same);
			else
				DealRecord.MergeItems(same, items);
				if same.ended == nil then same.ended = old.ended end
			end
		end
	end
	return added;
end

-- ---------------------------------------------------------------------------
-- Event journal kept in the save. The Mac build writes no Lua.log, so the save
-- is the only place to read afterwards what the game reported and when.
-- ---------------------------------------------------------------------------
DealRecord.LOG_GAMEPLAY = "UIEXT_LOG_GAMEPLAY";
DealRecord.LOG_LINES = 300;

function DealRecord.AppendLog(text, line)
	local lines = {};
	if type(text) == "string" and text ~= "" then
		for part in (text .. "~"):gmatch("(.-)~") do table.insert(lines, part) end
	end
	table.insert(lines, (tostring(line):gsub("~", "-")));
	local first = math.max(1, #lines - DealRecord.LOG_LINES + 1);
	return table.concat(lines, "~", first, #lines);
end

function DealRecord.ItemsBrief(items)
	local parts = {};
	for _, item in ipairs(items or {}) do
		table.insert(parts, tostring(item.kind) .. tostring(item.amount) .. "/" .. tostring(item.duration)
			.. "<" .. tostring(item.from));
	end
	return "[" .. table.concat(parts, ",") .. "]";
end

function DealRecord.Brief(deal)
	return tostring(deal.id) .. "(" .. tostring(deal.a) .. "," .. tostring(deal.b) .. ")t" .. tostring(deal.turn)
		.. DealRecord.ItemsBrief(deal.items) .. (deal.ended ~= nil and (" ended=" .. tostring(deal.ended)) or "");
end

-- ---------------------------------------------------------------------------
-- Finished deals
-- ---------------------------------------------------------------------------
function DealRecord.ItemEnd(deal, item, ended)
	local duration = item.duration or 0;
	if duration <= 0 then return ended end
	return math.min((deal.turn or 0) + duration, ended);
end

function DealRecord.EndedTurn(deal)
	if DealRecord.IsOneTime(deal) then return deal.turn or 0 end
	return deal.ended;
end

-- True when the deal lasted until its last term ran out, false when it was cut short or had no term.
-- A deal gone one turn before its term still counts: which of the two turns the game drops it on is not verified.
function DealRecord.RanItsTerm(deal)
	local expected = DealRecord.ExpectedEnd(deal);
	return expected ~= nil and deal.ended ~= nil and deal.ended >= expected - 1;
end

-- Which user-defined notification carries this ending, so the two endings can have different icons.
function DealRecord.NotifyType(deal)
	if DealRecord.RanItsTerm(deal) then return DealRecord.NOTIFY_TYPE end
	return DealRecord.NOTIFY_BROKEN_TYPE;
end

local function Shown(name)
	if name == nil or name == "" then return "" end
	return Lookup(name);
end

function DealRecord.ItemLabel(stored)
	local kind = stored.kind;
	local amount = stored.amount or 0;
	if kind == "GOLD" then
		if (stored.duration or 0) > 0 then
			return Format("LOC_UIEXT_DEALS_GOLD_PER_TURN", amount);
		end
		return Format("LOC_UIEXT_DEALS_GOLD_LUMP", amount);
	elseif kind == "FAVOR" then
		return Format("LOC_UIEXT_DEALS_FAVOR", amount);
	elseif kind == "RESOURCES" then
		local resource = GameInfo ~= nil and GameInfo.Resources ~= nil and GameInfo.Resources[stored.valueType] or nil;
		if resource ~= nil then
			return tostring(amount) .. " [ICON_" .. resource.ResourceType .. "] " .. Lookup(resource.Name);
		end
		local name = Shown(stored.name);
		if name ~= "" then return tostring(amount) .. " " .. name end
		return tostring(amount);
	elseif kind == "AGREEMENTS" then
		if stored.name ~= nil and stored.name ~= "" then return Lookup(stored.name) end
		local info = GameInfo ~= nil and GameInfo.DiplomaticActions ~= nil and GameInfo.DiplomaticActions[stored.subType] or nil;
		if info ~= nil then return Lookup(info.Name) end
		return "";
	elseif kind == "CITIES" then
		local name = Shown(stored.name);
		if name == "" then return Lookup("LOC_UIEXT_DEALS_CITY_UNNAMED") end
		return Format("LOC_UIEXT_DEALS_CITY", name);
	elseif kind == "GREATWORK" then
		local name = "";
		if GameInfo ~= nil and GameInfo.GreatWorks ~= nil then
			local info = GameInfo.GreatWorks[stored.valueType];
			if info ~= nil then name = Lookup(info.Name) end
		end
		if name == "" then name = Shown(stored.name) end
		if name == "" then return Lookup("LOC_UIEXT_DEALS_GREAT_WORK") end
		return Format("LOC_UIEXT_DEALS_GREAT_WORK_NAMED", name);
	end
	return Shown(stored.name);
end

-- Title and text of the notification that a deal finished, as seen by viewer.
-- What was handed over at once is marked as one-time; lasting items read as they ran.
function DealRecord.Notice(deal, viewer, partnerName)
	local gave, got, shared, seenShared = {}, {}, {}, {};
	for _, item in ipairs(deal.items or {}) do
		local text = DealRecord.ItemLabel(item);
		if text ~= "" then
			if DealRecord.IsInstant(item) then text = Format("LOC_UIEXT_DEALS_ITEM_ONCE", text) end
			if item.mutual then
				if not seenShared[text] then
					seenShared[text] = true;
					table.insert(shared, text);
				end
			elseif item.from == viewer then
				table.insert(gave, text);
			else
				table.insert(got, text);
			end
		end
	end
	local lines = {};
	if #shared > 0 then table.insert(lines, Format("LOC_UIEXT_NOTIFY_SHARED", table.concat(shared, ", "))) end
	if #gave > 0 then table.insert(lines, Format("LOC_UIEXT_NOTIFY_GAVE", table.concat(gave, ", "))) end
	if #got > 0 then table.insert(lines, Format("LOC_UIEXT_NOTIFY_GOT", table.concat(got, ", "))) end
	table.insert(lines, Lookup("LOC_UIEXT_NOTIFY_OPEN"));
	local title = DealRecord.RanItsTerm(deal) and "LOC_UIEXT_NOTIFY_EXPIRED" or "LOC_UIEXT_NOTIFY_ENDED";
	return Format(title, partnerName), table.concat(lines, "[NEWLINE]");
end

-- Finished deals of the pair, the latest first.
function DealRecord.History(data, a, b)
	local list = {};
	if data == nil or data.deals == nil or a == nil or b == nil then return list end
	a, b = DealRecord.Pair(a, b);
	for _, deal in ipairs(data.deals) do
		if deal.a == a and deal.b == b and #deal.items > 0 and DealRecord.EndedTurn(deal) ~= nil then
			table.insert(list, deal);
		end
	end
	table.sort(list, function(x, y)
		local ex, ey = DealRecord.EndedTurn(x), DealRecord.EndedTurn(y);
		if ex ~= ey then return ex > ey end
		if x.turn ~= y.turn then return x.turn > y.turn end
		return (x.id or 0) < (y.id or 0);
	end);
	return list;
end

-- ---------------------------------------------------------------------------
-- Text form. A player operation carries strings safely, and a game property keeps a
-- string reliably, so a record travels and is saved as one line.
-- ---------------------------------------------------------------------------
local function Esc(text)
	return (tostring(text or "")
		:gsub("\\", "\\\\")
		:gsub("/", "\\/")
		:gsub(";", "\\;")
		:gsub("~", "\\~")
		:gsub("\n", "\\n")
		:gsub("\t", "\\t"));
end

local function Unesc(text)
	local out = {};
	local i = 1;
	while i <= #text do
		if text:sub(i, i) == "\\" and i < #text then
			local nextChar = text:sub(i + 1, i + 1);
			if nextChar == "n" then table.insert(out, "\n");
			elseif nextChar == "t" then table.insert(out, "\t");
			else table.insert(out, nextChar); end
			i = i + 2;
		else
			table.insert(out, text:sub(i, i));
			i = i + 1;
		end
	end
	return table.concat(out);
end

local function SplitEscaped(text, separator)
	local parts = {};
	local current = {};
	local i = 1;
	while i <= #text do
		if text:sub(i, i) == "\\" and i < #text then
			table.insert(current, text:sub(i, i + 1));
			i = i + 2;
		elseif text:sub(i, i) == separator then
			table.insert(parts, table.concat(current));
			current = {};
			i = i + 1;
		else
			table.insert(current, text:sub(i, i));
			i = i + 1;
		end
	end
	table.insert(parts, table.concat(current));
	return parts;
end

function DealRecord.EncodeItems(items)
	local parts = {};
	for _, item in ipairs(items or {}) do
		local flags = (item.alliance and "a" or "") .. (item.mutual and "m" or "");
		table.insert(parts, table.concat({
			Esc(item.kind),
			tostring(item.amount or 0),
			tostring(item.duration or 0),
			tostring(item.from or -1),
			tostring(item.valueType or -1),
			tostring(item.subType or -1),
			flags,
			Esc(item.name),
		}, "/"));
	end
	return table.concat(parts, ";");
end

function DealRecord.DecodeItems(text)
	local items = {};
	if text == nil or text == "" then return items end
	for _, part in ipairs(SplitEscaped(text, ";")) do
		if part ~= "" then
			local fields = SplitEscaped(part, "/");
			local flags = fields[7] or "";
			table.insert(items, {
				kind = Unesc(fields[1] or ""),
				amount = tonumber(fields[2]) or 0,
				duration = tonumber(fields[3]) or 0,
				from = tonumber(fields[4]),
				valueType = tonumber(fields[5]) or -1,
				subType = tonumber(fields[6]) or -1,
				alliance = flags:find("a", 1, true) ~= nil,
				mutual = flags:find("m", 1, true) ~= nil,
				name = Unesc(fields[8] or ""),
			});
		end
	end
	return items;
end

local function Fields(line)
	local list = {};
	for field in (line .. "\t"):gmatch("(.-)\t") do
		table.insert(list, field);
	end
	return list;
end

-- "D", id, turn, a, b, items, ended. Earlier versions wrote two more fields, which are ignored.
function DealRecord.EncodeRecord(deal)
	return table.concat({
		"D", tostring(deal.id), tostring(deal.turn or 0), tostring(deal.a), tostring(deal.b),
		DealRecord.EncodeItems(deal.items),
		deal.ended ~= nil and tostring(deal.ended) or "",
	}, "\t");
end

function DealRecord.DecodeRecord(line)
	if type(line) ~= "string" or line:sub(1, 2) ~= "D\t" then return nil end
	local fields = Fields(line:sub(3));
	local id, a, b = tonumber(fields[1]), tonumber(fields[3]), tonumber(fields[4]);
	if id == nil or a == nil or b == nil then return nil end
	return {
		id = id,
		turn = tonumber(fields[2]) or 0,
		a = math.min(a, b),
		b = math.max(a, b),
		items = DealRecord.DecodeItems(fields[5]),
		ended = tonumber(fields[6]),
	};
end

-- One line: a newline inside a saved property is not reliable.
function DealRecord.EncodeArchive(data)
	data = type(data) == "table" and data or DealRecord.Empty();
	local lines = {};
	for _, deal in ipairs(data.deals or {}) do
		table.insert(lines, DealRecord.EncodeRecord(deal));
	end
	table.insert(lines, "N\t" .. tostring(data.next or 0));
	return table.concat(lines, "~");
end

function DealRecord.DecodeArchive(text)
	local data = DealRecord.Empty();
	data.accepted = {};
	if type(text) ~= "string" or text == "" then return data end
	text = text:gsub("\n", "~");
	for _, line in ipairs(SplitEscaped(text, "~")) do
		local kind = line:sub(1, 1);
		local fields = Fields(line:sub(3));
		if kind == "D" then
			local deal = DealRecord.DecodeRecord(line);
			if deal ~= nil then table.insert(data.deals, deal) end
		elseif kind == "A" then
			table.insert(data.accepted, {
				turn = tonumber(fields[1]) or 0,
				a = tonumber(fields[2]),
				b = tonumber(fields[3]),
				items = DealRecord.DecodeItems(fields[4]),
			});
		elseif kind == "N" then
			data.next = tonumber(fields[1]) or 0;
		end
	end
	return data;
end

-- Puts the record into the archive text in place of the one with its id.
function DealRecord.PutLine(text, line)
	local deal = DealRecord.DecodeRecord(line);
	local data = DealRecord.Normalize(text);
	if deal == nil then return DealRecord.EncodeArchive(data) end
	local replaced = false;
	for i, have in ipairs(data.deals) do
		if have.id == deal.id then
			data.deals[i] = deal;
			replaced = true;
		end
	end
	if not replaced then table.insert(data.deals, deal) end
	if deal.id < (data.next or 0) then data.next = deal.id end
	return DealRecord.EncodeArchive(data);
end
