-- Storage rules for concluded deals. Run with: luajit tests/test_deal_archive.lua
local TESTS_DIR = arg[0]:match("^(.*)/[^/]*$") or ".";
local MOD_DIR = TESTS_DIR .. "/../UI_Extender";
package.path = TESTS_DIR .. "/?.lua;" .. package.path;
local Mock = require("mock_civ6");

local tests = {};
local function test(name, fn) table.insert(tests, { name = name, fn = fn }) end

local function eq(actual, expected, what)
	if actual ~= expected then
		error(string.format("%s\n    expected: %s\n    actual:   %s", what or "values differ", tostring(expected), tostring(actual)), 2);
	end
end

local function check(value, what)
	if not value then error(what or "check failed", 2) end
end

local function LoadRecord()
	local env = {
		pairs = pairs, ipairs = ipairs, type = type, tostring = tostring, tonumber = tonumber,
		table = table, string = string, math = math, pcall = pcall, print = print,
		DealItemTypes = { GOLD = 1, RESOURCES = 2, AGREEMENTS = 3, DIPLOMATIC_FAVOR = 8 },
		DealAgreementTypes = { ALLIANCE = 2, OPEN_BORDERS = 1 },
	};
	local chunk = assert(loadfile(MOD_DIR .. "/Scripts/DealRecord.lua"));
	setfenv(chunk, env);
	chunk();
	return env.DealRecord;
end

local R = LoadRecord();

local function Gold(amount, from)
	return { kind = "GOLD", amount = amount, duration = 0, from = from, valueType = -1, subType = -1, name = "", alliance = false, mutual = false };
end

local function Silk(from, duration)
	return { kind = "RESOURCES", amount = 1, duration = duration or 30, from = from, valueType = 1, subType = -1, name = "", alliance = false, mutual = false };
end

local function Kinds(deal)
	local parts = {};
	for _, item in ipairs(deal.items) do
		table.insert(parts, item.kind .. ":" .. tostring(item.amount) .. ":" .. tostring(item.duration));
	end
	table.sort(parts);
	return table.concat(parts, ",");
end

test("item text survives the player-operation encoding", function()
	local items = { Gold(100, 0), Silk(1, 30) };
	items[1].name = "a/b;c\\d";
	local back = R.DecodeItems(R.EncodeItems(items));
	eq(#back, 2, "item count");
	eq(back[1].kind, "GOLD", "kind");
	eq(back[1].amount, 100, "amount");
	eq(back[1].from, 0, "from");
	eq(back[1].name, "a/b;c\\d", "name");
	eq(back[2].kind, "RESOURCES", "resource");
	eq(back[2].duration, 30, "duration");
end);

test("enacted deal is stored once", function()
	local data = R.Empty();
	data = R.OnEnacted(data, {
		a = 0, b = 3, turn = 35,
		live = { { id = 1001, a = 0, b = 3, turn = 35, items = { Silk(3, 30) } } },
		working = { Silk(3, 30), Gold(5, 0) },
	});
	eq(#data.deals, 1, "deal count");
	eq(data.deals[1].id, 1001, "id");
	eq(data.deals[1].a, 0, "low id");
	eq(data.deals[1].b, 3, "high id");
	eq(Kinds(data.deals[1]), "GOLD:5:0,RESOURCES:1:30", "items");
	data = R.OnEnacted(data, {
		a = 3, b = 0, turn = 35,
		live = { { id = 1001, a = 3, b = 0, turn = 35, items = { Silk(3, 30) } } },
		working = {},
	});
	eq(#data.deals, 1, "duplicate enactment");
end);

test("acceptance before the event puts the lump sum on the deal", function()
	local data = R.OnSnapshot(R.Empty(), { a = 1, b = 0, turn = 35, accepted = 1, items = { Gold(100, 0), Silk(1, 30) } });
	eq(#data.deals, 0, "not concluded yet");
	eq(#data.pending, 1, "waiting");
	data = R.OnEnacted(data, {
		a = 0, b = 1, turn = 35,
		live = { { id = 1001, a = 0, b = 1, turn = 35, items = { Silk(1, 30) } } },
		working = {},
	});
	eq(#data.deals, 1, "deal count");
	eq(#data.pending, 0, "pending left over");
	eq(Kinds(data.deals[1]), "GOLD:100:0,RESOURCES:1:30", "items");
end);

test("a rejected proposal does not attach to a later deal", function()
	local data = R.OnSnapshot(R.Empty(), { a = 0, b = 1, turn = 10, accepted = 0, items = { Gold(100, 0), Silk(1, 30) } });
	data = R.OnEnacted(data, {
		a = 0, b = 1, turn = 28,
		live = { { id = 1008, a = 0, b = 1, turn = 28, items = { Silk(1, 30) } } },
		working = { Silk(1, 30) },
	});
	eq(Kinds(data.deals[1]), "RESOURCES:1:30", "later silk deal");
	eq(#data.pending, 0, "old proposal still pending");
end);

test("the snapshot can arrive after the deal is already stored", function()
	local data = R.OnEnacted(R.Empty(), {
		a = 0, b = 1, turn = 35,
		live = { { id = 1001, a = 0, b = 1, turn = 35, items = { Silk(1, 30) } } },
		working = {},
	});
	data = R.OnSnapshot(data, { a = 0, b = 1, turn = 35, accepted = 1, items = { Gold(100, 0), Silk(1, 30) } });
	eq(#data.deals, 1, "no second record");
	eq(Kinds(data.deals[1]), "GOLD:100:0,RESOURCES:1:30", "items");
end);

test("a same-turn proposal is part of the deal", function()
	local data = R.OnSnapshot(R.Empty(), { a = 0, b = 1, turn = 35, accepted = false, items = { Gold(40, 1), Silk(0, 30) } });
	data = R.OnEnacted(data, {
		a = 0, b = 1, turn = 35,
		live = { { id = 1001, a = 0, b = 1, turn = 35, items = { Silk(0, 30) } } },
		working = {},
	});
	eq(Kinds(data.deals[1]), "GOLD:40:0,RESOURCES:1:30", "items");
end);

test("a deal the game already deleted is kept from the acceptance", function()
	local data = R.OnEnacted(R.Empty(), { a = 0, b = 1, turn = 12, live = {}, working = {} });
	check(R.HasMiss(data, 0, 1, 12), "enactment was not remembered");
	data = R.OnSnapshot(data, { a = 0, b = 1, turn = 12, accepted = 1, items = { Gold(15, 0) } });
	eq(#data.deals, 1, "deal count");
	eq(data.deals[1].id < 0, true, "synthetic id");
	eq(Kinds(data.deals[1]), "GOLD:15:0", "items");
	check(not R.HasMiss(data, 0, 1, 12), "miss still open");
end);

test("a snapshot attaches only to the live deal it covers", function()
	local function lastingGold(amount, from)
		local item = Gold(amount, from);
		item.duration = 30;
		return item;
	end
	local favor = {
		kind = "DIPLOMATIC_FAVOR", amount = 1, duration = 0, from = 0,
		valueType = -1, subType = -1, name = "", alliance = false, mutual = false,
	};
	local lives = {
		{ id = 1007, a = 0, b = 3, turn = 99, items = { lastingGold(10, 0), Silk(3, 30) } },
		{ id = 1009, a = 0, b = 3, turn = 99, items = { lastingGold(1, 0) } },
	};
	local data = R.Remember(R.Empty(), lives, { Gold(100, 0), lastingGold(10, 0), Silk(3, 30) }, 99);
	data = R.Remember(data, lives, { favor, lastingGold(1, 0) }, 99);
	eq(#data.deals, 2, "deals");
	local first, second = nil, nil;
	for _, deal in ipairs(data.deals) do
		if deal.id == 1007 then first = deal end
		if deal.id == 1009 then second = deal end
	end
	eq(Kinds(first), "GOLD:100:0,GOLD:10:30,RESOURCES:1:30", "first deal");
	eq(Kinds(second), "DIPLOMATIC_FAVOR:1:0,GOLD:1:30", "second deal");
end);

test("backfill adds current deals and does not duplicate them", function()
	local live = { { id = 1001, a = 2, b = 0, turn = 8, items = { Silk(2, 30) } } };
	local data = R.Backfill(R.Empty(), live);
	data = R.Backfill(data, live);
	eq(#data.deals, 1, "deal count");
	eq(data.deals[1].a, 0, "pair order");
	eq(Kinds(data.deals[1]), "RESOURCES:1:30", "items");
end);

test("the archive round-trips as text, and a table with text keys still reads", function()
	local data = R.OnEnacted(R.Empty(), {
		a = 0, b = 3, turn = 35,
		live = { { id = 1001, a = 0, b = 3, turn = 35, items = { Silk(3, 30) } } },
		working = { Silk(3, 30), Gold(100, 0) },
	});
	local text = R.EncodeArchive(data);
	check(type(text) == "string", "encoded archive");
	check(text:find("\n", 1, true) == nil, "archive is a single line");
	local back = R.Normalize(text);
	eq(#back.deals, 1, "deal count");
	eq(Kinds(back.deals[1]), "GOLD:100:0,RESOURCES:1:30", "items");
	local fromLines = R.Normalize(text:gsub("~", "\n"));
	eq(Kinds(fromLines.deals[1]), "GOLD:100:0,RESOURCES:1:30", "newline archive still reads");

	local legacy = R.Normalize({
		deals = { ["1"] = { id = "1001", turn = "35", a = "0", b = "3", items = { ["1"] = Gold(100, 0) } } },
	});
	eq(#legacy.deals, 1, "legacy deal count");
	eq(Kinds(legacy.deals[1]), "GOLD:100:0", "legacy items");
end);

test("the gameplay script records a deal that is already in the game", function()
	local w = Mock.new({ modDir = MOD_DIR, turn = 35, players = {
		[0] = { leader = "Peter", civ = "Russia" },
		[1] = { leader = "Gandhi", civ = "India" },
	} });
	w:AddDeal(0, 1, {
		{ type = "GOLD", from = 0, amount = 5, duration = 30, enacted = 35 },
		{ type = "RESOURCES", from = 1, amount = 1, duration = 30, enacted = 35, valueType = 1 },
	}, 1001);
	w:LoadGameplay();
	check(type(w.properties[R.PROP]) == "string", "archive is stored as text");
	local data = R.Normalize(w.properties[R.PROP]);
	eq(#data.deals, 1, "backfill");
	eq(data.deals[1].id, 1001, "id");
	eq(#data.deals[1].items, 2, "items");
	w:AddDeal(0, 1, {
		{ type = "GOLD", from = 1, amount = 9, duration = 0, enacted = 36 },
	}, 1002);
	w.turn = 36;
	w.Events.DiplomacyDealEnacted(0, 1);
	data = R.Normalize(w.properties[R.PROP]);
	eq(#data.deals, 2, "second deal");
	eq(data.deals[2].id, 1002, "new id");
end);

local failed = 0;
for _, t in ipairs(tests) do
	local ok, err = pcall(t.fn);
	if ok then
		print("ok    " .. t.name);
	else
		failed = failed + 1;
		print("FAIL  " .. t.name .. "\n    " .. tostring(err));
	end
end
print(string.format("\n%d of %d failed", failed, #tests));
os.exit(failed == 0 and 0 or 1);
