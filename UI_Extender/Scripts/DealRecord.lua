-- Plain record of a concluded deal, shared by the gameplay script that writes the save
-- and the diplomacy UI that reads it back.
--
-- The game deletes one-time items (lump gold, a city, a great work, favor) on the
-- turn the deal is enacted, and deletes the whole deal when it expires. This table
-- is what Game:SetProperty stores under DealRecord.PROP for the rest of the game.
--
--   { deals = { { id, turn, a, b, items = { item, ... } }, ... },
--     pending = { { a, b, turn, accepted, items }, ... },
--     missed = { { a, b, turn }, ... },
--     next = 0 }
--
-- a < b. id is the game's deal id, or a negative number when the game had already
-- dropped the deal before it could be read. pending is the latest proposal or
-- acceptance for a pair that is not in deals yet. missed marks an enactment that
-- left nothing to read, so a snapshot that arrives afterwards still becomes a deal.

DealRecord = DealRecord or {};

DealRecord.PROP = "UIEXT_DEAL_ARCHIVE";

local function Call(object, method)
	if object == nil then return nil end
	local fn = object[method];
	if fn == nil then return nil end
	local ok, value = pcall(fn, object);
	if ok then return value end
	return nil;
end

function DealRecord.Empty()
	return { deals = {}, pending = {}, missed = {}, next = 0 };
end

function DealRecord.Normalize(data)
	if type(data) ~= "table" then return DealRecord.Empty() end
	if type(data.deals) ~= "table" then data.deals = {} end
	if type(data.pending) ~= "table" then data.pending = {} end
	if type(data.missed) ~= "table" then data.missed = {} end
	if type(data.next) ~= "number" or data.next > 0 then data.next = 0 end
	return data;
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
	if id == nil then return nil end
	for _, deal in ipairs(data.deals) do
		if deal.id == id then return deal end
	end
	return nil;
end

-- True when every live item is part of the snapshot. An empty live deal does not
-- match: a leftover shell must not absorb an unrelated proposal.
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

function DealRecord.AddLive(data, live)
	if live == nil or live.id == nil or DealRecord.FindID(data, live.id) ~= nil then return nil end
	if live.a == nil or live.b == nil then return nil end
	local deal = {
		id = live.id,
		turn = live.turn or 0,
		a = math.min(live.a, live.b),
		b = math.max(live.a, live.b),
		items = {},
	};
	DealRecord.MergeItems(deal, live.items);
	table.insert(data.deals, deal);
	return deal;
end

function DealRecord.AddSynthetic(data, a, b, turn, items)
	data.next = (data.next or 0) - 1;
	local deal = {
		id = data.next,
		turn = turn or 0,
		a = math.min(a, b),
		b = math.max(a, b),
		items = {},
	};
	DealRecord.MergeItems(deal, items);
	table.insert(data.deals, deal);
	return deal;
end

function DealRecord.Backfill(data, lives)
	data = DealRecord.Normalize(data);
	local list = {};
	for _, live in ipairs(lives or {}) do table.insert(list, live) end
	table.sort(list, function(x, y) return (x.id or 0) < (y.id or 0) end);
	for _, live in ipairs(list) do
		DealRecord.AddLive(data, live);
	end
	return data;
end

local function FindCovered(data, a, b, turn, items)
	local found = nil;
	for _, deal in ipairs(data.deals) do
		if deal.a == a and deal.b == b and deal.turn == turn and DealRecord.Covers(items, deal.items) then
			found = deal;
		end
	end
	return found;
end

local function HasPairTurn(data, a, b, turn)
	for _, deal in ipairs(data.deals) do
		if deal.a == a and deal.b == b and deal.turn == turn then return true end
	end
	return false;
end

-- Merge into a deal enacted this turn, or record the snapshot itself when the
-- game had already deleted the deal. Returns true when the snapshot was used.
local function ApplyExtras(data, a, b, turn, items, allowSynthetic)
	if items == nil or #items == 0 then return false end
	local target = FindCovered(data, a, b, turn, items);
	if target ~= nil then
		DealRecord.MergeItems(target, items);
		return true;
	end
	if allowSynthetic and not HasPairTurn(data, a, b, turn) then
		DealRecord.AddSynthetic(data, a, b, turn, items);
		return true;
	end
	return false;
end

function DealRecord.SetPending(data, snap)
	local a, b = DealRecord.Pair(snap.a, snap.b);
	local kept = {};
	for _, pending in ipairs(data.pending) do
		if not (pending.a == a and pending.b == b) then table.insert(kept, pending) end
	end
	data.pending = kept;
	local copy = { a = a, b = b, turn = snap.turn or 0, accepted = snap.accepted and true or false, items = {} };
	DealRecord.MergeItems(copy, snap.items);
	table.insert(data.pending, copy);
end

function DealRecord.TakePending(data, a, b)
	a, b = DealRecord.Pair(a, b);
	local found = nil;
	local kept = {};
	for _, pending in ipairs(data.pending) do
		if pending.a == a and pending.b == b then found = pending else table.insert(kept, pending) end
	end
	data.pending = kept;
	return found;
end

function DealRecord.NoteMiss(data, a, b, turn)
	a, b = DealRecord.Pair(a, b);
	for _, miss in ipairs(data.missed) do
		if miss.a == a and miss.b == b and miss.turn == turn then return end
	end
	table.insert(data.missed, { a = a, b = b, turn = turn });
end

function DealRecord.HasMiss(data, a, b, turn)
	a, b = DealRecord.Pair(a, b);
	for _, miss in ipairs(data.missed) do
		if miss.a == a and miss.b == b and miss.turn == turn then return true end
	end
	return false;
end

function DealRecord.ClearMiss(data, a, b, turn)
	a, b = DealRecord.Pair(a, b);
	local kept = {};
	for _, miss in ipairs(data.missed) do
		if not (miss.a == a and miss.b == b and miss.turn == turn) then table.insert(kept, miss) end
	end
	data.missed = kept;
end

local function DealsThisTurn(data, a, b, turn)
	local list = {};
	for _, deal in ipairs(data.deals) do
		if deal.a == a and deal.b == b and deal.turn == turn then table.insert(list, deal) end
	end
	return list;
end

local function MergeCovered(candidates, items)
	for i = #candidates, 1, -1 do
		if DealRecord.Covers(items, candidates[i].items) then
			DealRecord.MergeItems(candidates[i], items);
			return true;
		end
	end
	return false;
end

local function FillShell(candidates, items)
	for i = #candidates, 1, -1 do
		if #candidates[i].items == 0 then
			DealRecord.MergeItems(candidates[i], items);
			return true;
		end
	end
	return false;
end

-- A proposal is not proof of what was enacted. Trust it on the turn it was made,
-- or when the working deal still contains every item that was proposed.
-- An acceptance is the deal that was just sent, so it is kept either way.
local function SnapshotConfirmed(pending, turn, working)
	if pending.accepted or pending.turn == turn then return true end
	if working == nil then return false end
	local have = {};
	for _, item in ipairs(working) do
		have[DealRecord.ItemKey(item)] = true;
	end
	for _, item in ipairs(pending.items) do
		if not have[DealRecord.ItemKey(item)] then return false end
	end
	return true;
end

-- info: { a, b, turn, live = { { id, a, b, turn, items }, ... }, working = { item, ... } }
function DealRecord.OnEnacted(data, info)
	data = DealRecord.Normalize(data);
	if info == nil or info.a == nil or info.b == nil then return data end
	local a, b = DealRecord.Pair(info.a, info.b);
	local turn = info.turn or 0;
	local fresh = {};
	for _, live in ipairs(info.live or {}) do
		local deal = DealRecord.AddLive(data, live);
		if deal ~= nil then table.insert(fresh, deal) end
	end
	local used = false;
	local pending = DealRecord.TakePending(data, a, b);
	if pending ~= nil and SnapshotConfirmed(pending, turn, info.working) then
		local candidates = #fresh > 0 and fresh or DealsThisTurn(data, a, b, turn);
		if MergeCovered(candidates, pending.items) then
			used = true;
		elseif pending.accepted and FillShell(fresh, pending.items) then
			used = true;
		elseif pending.accepted and not HasPairTurn(data, a, b, turn) then
			DealRecord.AddSynthetic(data, a, b, turn, pending.items);
			used = true;
		end
		if used then DealRecord.ClearMiss(data, a, b, pending.turn or turn) end
	end
	if info.working ~= nil and #info.working > 0 then
		local candidates = #fresh > 0 and fresh or DealsThisTurn(data, a, b, turn);
		if MergeCovered(candidates, info.working) or FillShell(candidates, info.working) then
			used = true;
			DealRecord.ClearMiss(data, a, b, turn);
		elseif not HasPairTurn(data, a, b, turn) then
			DealRecord.AddSynthetic(data, a, b, turn, info.working);
			used = true;
			DealRecord.ClearMiss(data, a, b, turn);
		end
	end
	if #fresh == 0 and not used and not HasPairTurn(data, a, b, turn) then
		DealRecord.NoteMiss(data, a, b, turn);
	end
	return data;
end

local function Accepted(value)
	return value == true or value == 1;
end

-- snap: { a, b, turn, accepted, items }
function DealRecord.OnSnapshot(data, snap)
	data = DealRecord.Normalize(data);
	if snap == nil or snap.a == nil or snap.b == nil then return data end
	local a, b = DealRecord.Pair(snap.a, snap.b);
	local turn = snap.turn or 0;
	local accepted = Accepted(snap.accepted);
	if ApplyExtras(data, a, b, turn, snap.items, false) then
		DealRecord.ClearMiss(data, a, b, turn);
		return data;
	end
	if accepted and DealRecord.HasMiss(data, a, b, turn) then
		DealRecord.AddSynthetic(data, a, b, turn, snap.items);
		DealRecord.ClearMiss(data, a, b, turn);
		return data;
	end
	snap.accepted = accepted;
	DealRecord.SetPending(data, snap);
	return data;
end

-- The player operation carries a string, because a nested table is not a safe argument.
local function Esc(text)
	return (tostring(text or ""):gsub("\\", "\\\\"):gsub("/", "\\/"):gsub(";", "\\;"));
end

local function Unesc(text)
	local out = {};
	local i = 1;
	while i <= #text do
		if text:sub(i, i) == "\\" and i < #text then
			local nextChar = text:sub(i + 1, i + 1);
			if nextChar == "\\" then table.insert(out, "\\");
			elseif nextChar == "/" then table.insert(out, "/");
			elseif nextChar == ";" then table.insert(out, ";");
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
