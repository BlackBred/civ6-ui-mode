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
	data = R.Backfill(data, { { id = 1001, a = 3, b = 0, turn = 35, items = { Silk(3, 30) } } });
	eq(#data.deals, 1, "listed again on load");
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

test("the end turn round-trips as text and an older archive line still reads", function()
	local data = R.Backfill(R.Empty(), { { id = 1001, a = 0, b = 1, turn = 10, items = { Silk(1, 30) } } });
	data.deals[1].ended = 40;
	local back = R.Normalize(R.EncodeArchive(data));
	eq(back.deals[1].ended, 40, "ended");
	local older = R.Normalize("D\t1001\t10\t0\t1\tRESOURCES/1/30/1/1/-1//~N\t0");
	eq(#older.deals, 1, "older deal");
	eq(older.deals[1].ended, nil, "no end turn yet");
end);

test("a deal that ran its term ends with the term, one cut short ends when it is gone", function()
	local data = R.Backfill(R.Empty(), {
		{ id = 1001, a = 0, b = 1, turn = 10, items = { Silk(1, 30) } },
		{ id = 1002, a = 0, b = 1, turn = 20, items = { Silk(0, 30) } },
		{ id = 1003, a = 0, b = 1, turn = 20, items = { Gold(50, 0) } },
		{ id = 1004, a = 0, b = 2, turn = 5, items = { Silk(2, 10) } },
	});
	local marked = R.MarkEnded(data, { [1002] = true }, 45, 1, 0);
	eq(marked, 1, "marked");
	eq(R.FindID(data, 1001).ended, 40, "expired deal ends with its term");
	eq(R.FindID(data, 1002).ended, nil, "running deal");
	eq(R.FindID(data, 1003).ended, nil, "a one-time deal needs no end turn");
	eq(R.FindID(data, 1004).ended, nil, "another pair is left alone");
	eq(R.MarkEnded(data, {}, 46, 0, 1), 1, "the second deal is gone");
	eq(R.FindID(data, 1002).ended, 46, "cut short");
	eq(R.MarkEnded(data, {}, 50, 0, 1), 0, "an end turn is kept");
	eq(R.MarkEnded(data, nil, 50, 0, 2), 0, "a failed read ends nothing");
end);

test("history lists finished deals of the pair, the latest first", function()
	local data = R.Backfill(R.Empty(), {
		{ id = 1001, a = 0, b = 1, turn = 10, items = { Silk(1, 30) } },
		{ id = 1002, a = 0, b = 1, turn = 20, items = { Gold(50, 0) } },
		{ id = 1003, a = 0, b = 1, turn = 30, items = { Silk(0, 30) } },
		{ id = 1004, a = 0, b = 2, turn = 12, items = { Gold(5, 2) } },
	});
	R.MarkEnded(data, { [1003] = true }, 45, 0, 1);
	local list = R.History(data, 1, 0, { [1003] = true });
	eq(#list, 2, "history count");
	eq(list[1].id, 1001, "ended on turn 40");
	eq(list[2].id, 1002, "one-time on turn 20");
	eq(R.EndedTurn(list[2]), 20, "one-time end turn");
end);

test("a recorded copy of a deal stored under its own id is not listed twice", function()
	local data = R.Empty();
	R.AddSynthetic(data, 0, 1, 10, { Gold(100, 0), Silk(1, 30) });
	R.AddLive(data, { id = 1001, a = 0, b = 1, turn = 10, items = { Silk(1, 30) } });
	R.MarkEnded(data, {}, 50, 0, 1);
	local list = R.History(data, 0, 1, {});
	eq(#list, 1, "history count");
	eq(list[1].id, 1001, "the real deal");
end);

test("the end turn survives merging the property with the configuration", function()
	local live = { { id = 1001, a = 0, b = 1, turn = 10, items = { Silk(1, 30) } } };
	local property = R.Backfill(R.Empty(), live);
	property.deals[1].ended = 41;
	local config = R.Backfill(R.Empty(), live);
	eq(R.MergeArchives(property, config).deals[1].ended, 41, "from the property");
	eq(R.MergeArchives(config, property).deals[1].ended, 41, "from the configuration");
end);

test("a keyed deal table is one deal however often it arrives", function()
	local data = R.OnSnapshot(R.Empty(), { a = 0, b = 3, turn = 92, accepted = 1, items = { Gold(60, 0) }, key = "p0t92n1" });
	data = R.OnSnapshot(data, { a = 3, b = 0, turn = 92, accepted = 1, items = { Gold(60, 0) }, key = "p0t92n1" });
	data = R.OnEnacted(data, { a = 0, b = 3, turn = 92, live = {}, working = { Gold(60, 0) } });
	eq(#data.deals, 1, "deal count");
	eq(#data.pending, 0, "pending");
	eq(data.deals[1].keys[1], "p0t92n1", "key");
end);

test("two equal gifts in one turn are two deals, in either order of events", function()
	local function gift(data, key, interfaceFirst)
		local snap = { a = 0, b = 3, turn = 92, accepted = 1, items = { Gold(60, 0) }, key = key };
		local enact = { a = 0, b = 3, turn = 92, live = {}, working = { Gold(60, 0) } };
		if interfaceFirst then
			data = R.OnSnapshot(data, snap);
			data = R.OnEnacted(data, enact);
		else
			data = R.OnEnacted(data, enact);
			data = R.OnSnapshot(data, snap);
		end
		return R.OnSnapshot(data, snap);
	end
	for _, interfaceFirst in ipairs({ true, false }) do
		local data = gift(R.Empty(), "p0t92n1", interfaceFirst);
		data = gift(data, "p0t92n2", interfaceFirst);
		data = R.Normalize(R.EncodeArchive(data));
		eq(#data.deals, 2, "deal count, interface first: " .. tostring(interfaceFirst));
		eq(#R.History(data, 0, 3, {}), 2, "history count, interface first: " .. tostring(interfaceFirst));
	end
end);

test("both humans' keys for one deal make one record, their second equal deal another", function()
	local data = R.Empty();
	for _, key in ipairs({ "p0t50n1", "p1t50n1", "p0t50n2", "p1t50n2" }) do
		data = R.OnSnapshot(data, { a = 0, b = 1, turn = 50, accepted = 1, items = { Gold(60, 0) }, key = key });
	end
	eq(#data.deals, 2, "deal count");
	eq(#data.deals[1].keys, 2, "first deal keys");
	eq(#data.deals[2].keys, 2, "second deal keys");
end);

test("a recorded copy becomes the live deal once the game lists it", function()
	local data = R.OnSnapshot(R.Empty(), { a = 0, b = 1, turn = 35, accepted = 1, items = { Gold(100, 0), Silk(1, 30) }, key = "p0t35n1" });
	eq(#data.deals, 1, "copy");
	data = R.OnEnacted(data, { a = 0, b = 1, turn = 35, live = { { id = 1001, a = 0, b = 1, turn = 35, items = { Silk(1, 30) } } }, working = {} });
	eq(#data.deals, 1, "deal count");
	eq(data.deals[1].id, 1001, "game id");
	eq(Kinds(data.deals[1]), "GOLD:100:0,RESOURCES:1:30", "items");
end);

test("keys survive the text form and merging, and equal accepted tables stay apart", function()
	local data = R.Empty();
	R.AddAccepted(data, { a = 0, b = 1, turn = 9, items = { Gold(60, 0) }, key = "p0t9n1" });
	R.AddAccepted(data, { a = 0, b = 1, turn = 9, items = { Gold(60, 0) }, key = "p0t9n2" });
	R.AddAccepted(data, { a = 0, b = 1, turn = 9, items = { Gold(60, 0) }, key = "p0t9n2" });
	eq(#data.accepted, 2, "accepted count");
	R.AddSynthetic(data, 0, 1, 9, { Gold(60, 0) }, { "p0t9n1" });
	local back = R.Normalize(R.EncodeArchive(data));
	eq(back.deals[1].keys[1], "p0t9n1", "deal key");
	eq(back.accepted[2].keys[1], "p0t9n2", "accepted key");
	local key = R.NewKey(back, 0, 9, 0);
	eq(key, "p0t9n3", "next key");
	local live = R.Empty();
	R.AddLive(live, { id = 1005, a = 0, b = 1, turn = 9, items = { Gold(60, 0) }, keys = { "p0t9n1" } });
	local merged = R.MergeArchives(back, live);
	eq(#merged.deals, 1, "merged by key");
	eq(merged.deals[1].id, 1005, "game id wins");
end);

test("each enactment without a deal table from the interface is still one deal", function()
	local data = R.Empty();
	for _ = 1, 2 do
		data = R.OnEnacted(data, { a = 0, b = 3, turn = 90, live = {}, working = { Gold(10, 0) } });
	end
	data = R.OnEnacted(data, { a = 0, b = 3, turn = 90, live = {}, working = { Gold(100, 0) } });
	data = R.Normalize(R.EncodeArchive(data));
	eq(#data.deals, 3, "deal count");
	eq(#R.History(data, 0, 3, {}), 3, "history count");
	check(data.deals[1].enacted and data.deals[2].enacted and data.deals[3].enacted, "enactment marks survive the text form");
end);

test("the interface's keys join the records the enactments made, one each", function()
	local data = R.Empty();
	for n = 1, 2 do
		data = R.OnEnacted(data, { a = 0, b = 3, turn = 90, live = {}, working = { Gold(10, 0) } });
		data = R.OnSnapshot(data, { a = 0, b = 3, turn = 90, accepted = 1, items = { Gold(10, 0) }, key = "p0t90n" .. n });
	end
	eq(#data.deals, 2, "deal count");
	eq(#data.deals[1].keys, 1, "first deal keys");
	eq(#data.deals[2].keys, 1, "second deal keys");
	check(data.deals[1].keys[1] ~= data.deals[2].keys[1], "each deal has its own key");
end);

test("two different deals recorded under one number on two sides are both kept", function()
	local property = R.Empty();
	R.AddSynthetic(property, 0, 1, 92, { Gold(60, 0) }, { "p0t92n1" });
	local config = R.Empty();
	R.AddSynthetic(config, 0, 1, 92, { Gold(60, 0) }, { "p0t92n2" });
	local merged = R.MergeArchives(property, config);
	eq(#merged.deals, 2, "deal count");
	check(merged.deals[1].id ~= merged.deals[2].id, "numbers differ");
	local again = R.MergeArchives(merged, config);
	eq(#again.deals, 2, "merging again adds nothing");
	local fresh = R.AddSynthetic(again, 0, 1, 93, { Gold(1, 0) });
	local same = 0;
	for _, deal in ipairs(again.deals) do
		if deal.id == fresh.id then same = same + 1 end
	end
	eq(same, 1, "a new number is not taken");
end);

test("the gameplay script notes the turn a deal stopped being listed", function()
	local w = Mock.new({ modDir = MOD_DIR, turn = 35, players = {
		[0] = { leader = "Peter", civ = "Russia" },
		[1] = { leader = "Gandhi", civ = "India" },
	} });
	w:AddDeal(0, 1, { { type = "RESOURCES", from = 1, amount = 1, duration = 30, enacted = 30, valueType = 1 } }, 1001);
	w:LoadGameplay();
	w.turn = 36;
	w.Events.TurnBegin(36);
	eq(R.Normalize(w.properties[R.PROP]).deals[1].ended, nil, "still running");
	w.deals = {};
	w.turn = 42;
	w.Events.TurnBegin(42);
	eq(R.Normalize(w.properties[R.PROP]).deals[1].ended, 42, "ended");
end);

test("a lasting deal recorded before the game listed it takes its game id next turn", function()
	local w = Mock.new({ modDir = MOD_DIR, turn = 90, players = {
		[0] = { leader = "Peter", civ = "Russia" },
		[3] = { leader = "Wilhelmina", civ = "Netherlands" },
	} });
	w:LoadGameplay();
	w.Events.DiplomacyDealEnacted(0, 3);
	w.exposed.UIExt.RecordSnapshot({
		a = 0, b = 3, turn = 90, accepted = 1, uiextKey = "p0t90n1",
		uiextItems = R.EncodeItems({ Silk(0, 30), Gold(1, 3) }),
	});
	local data = R.Normalize(w.properties[R.PROP]);
	eq(#data.deals, 1, "recorded copy");
	check(data.deals[1].id < 0, "no game id yet");
	w:AddDeal(0, 3, { { type = "RESOURCES", from = 0, amount = 1, duration = 30, enacted = 90, valueType = 1 } }, 1005);
	w.turn = 91;
	w.Events.TurnBegin(91);
	data = R.Normalize(w.properties[R.PROP]);
	eq(#data.deals, 1, "deal count");
	eq(data.deals[1].id, 1005, "game id");
	eq(Kinds(data.deals[1]), "GOLD:1:0,RESOURCES:1:30", "items");
	eq(data.deals[1].keys[1], "p0t90n1", "key kept");
	local journal = w.properties[R.LOG_GAMEPLAY];
	check(journal:find("t90 GP enact (0,3) live=[]", 1, true), "enactment with an empty list: " .. journal);
	check(journal:find("GP snap direct (0,3) key=p0t90n1", 1, true), "snapshot");
	check(journal:find("t91 GP turn -> 1005 -1->1005", 1, true), "promotion");
end);

test("the journal keeps only the latest lines", function()
	local text;
	for i = 1, R.LOG_LINES + 5 do text = R.AppendLog(text, "line " .. i) end
	local count = select(2, text:gsub("~", "")) + 1;
	eq(count, R.LOG_LINES, "line count");
	eq(text:sub(1, 7), "line 6~", "oldest kept");
	eq(R.AppendLog(nil, "a~b"), "a-b", "separator in a line");
end);

test("the journal describes what an update did to the deals", function()
	local before = R.Empty();
	R.AddSynthetic(before, 0, 3, 90, { Silk(0, 30) }, { "p0t90n1" });
	local after = R.DecodeArchive(R.EncodeArchive(before));
	after.deals[1].id = 1005;
	after.deals[1].enacted = true;
	R.AddSynthetic(after, 0, 3, 90, { Gold(60, 0) }, { "p0t90n2" });
	eq(R.Changes(before, after), "new -2[GOLD60/0<0]{p0t90n2}; 1005 -1->1005 e", "changes");
	eq(R.Changes(before, before), "no change", "nothing");
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
