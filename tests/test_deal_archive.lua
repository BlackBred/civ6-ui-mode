-- Rules of the deal record and the gameplay script that stores it. Run with: luajit tests/test_deal_archive.lua
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

local function Gold(amount, from, duration)
	return { kind = "GOLD", amount = amount, duration = duration or 0, from = from, valueType = -1, subType = -1, name = "", alliance = false, mutual = false };
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

local PAIR_0_1 = { ["0:1"] = true };

test("item text survives the player-operation encoding", function()
	local items = { Gold(100, 0), Silk(1, 30) };
	items[1].name = "a/b;c\\d~e\tf";
	local back = R.DecodeItems(R.EncodeItems(items));
	eq(#back, 2, "item count");
	eq(back[1].kind, "GOLD", "kind");
	eq(back[1].amount, 100, "amount");
	eq(back[1].from, 0, "from");
	eq(back[1].name, "a/b;c\\d~e\tf", "name");
	eq(back[2].kind, "RESOURCES", "resource");
	eq(back[2].duration, 30, "duration");
end);

test("a record survives the text form, and archives of earlier versions still read", function()
	local data = R.Empty();
	local deal = R.AddRecord(data, 1, 0, 10, { Gold(100, 0), Silk(1, 30) });
	deal.ended = 40;
	local text = R.EncodeArchive(data);
	check(text:find("\n", 1, true) == nil, "archive is a single line");
	local back = R.Normalize(text);
	eq(#back.deals, 1, "deal count");
	eq(back.deals[1].id, -1, "id");
	eq(back.deals[1].a, 0, "low player first");
	eq(back.deals[1].ended, 40, "ended");
	eq(back.next, -1, "next number");
	eq(Kinds(back.deals[1]), "GOLD:100:0,RESOURCES:1:30", "items");

	local older = R.Normalize("D\t-3\t10\t0\t1\tRESOURCES/1/30/1/1/-1//\t\tp0t10n1\t1~N\t-3");
	eq(#older.deals, 1, "line with keys and an enactment mark");
	eq(older.deals[1].ended, nil, "still running");
	eq(older.next, -3, "next");
	local table_ = R.Normalize({
		deals = { ["1"] = { id = "-1", turn = "35", a = "3", b = "0", items = { ["1"] = Gold(100, 0) } } },
	});
	eq(#table_.deals, 1, "archive saved as a table");
	eq(table_.deals[1].b, 3, "pair order");
end);

test("a deal the game lists gets one record, however often it is read", function()
	local data = R.Empty();
	local live = { a = 1, b = 0, turn = 10, items = { Silk(1, 30), Gold(5, 0, 30) } };
	local changed = R.Track(data, { live }, PAIR_0_1, 10);
	eq(#changed, 1, "new record");
	eq(#data.deals, 1, "deal count");
	eq(data.deals[1].turn, 10, "enactment turn");
	changed = R.Track(data, { live }, PAIR_0_1, 11);
	eq(#changed, 0, "nothing new");
	eq(#data.deals, 1, "still one record");
end);

test("a deal gone with its term ran out, one gone earlier was cut short", function()
	local data = R.Empty();
	R.Track(data, {
		{ a = 0, b = 1, turn = 10, items = { Silk(1, 30) } },
		{ a = 0, b = 1, turn = 12, items = { Gold(3, 0, 30) } },
	}, PAIR_0_1, 12);
	local _, finished = R.Track(data, { { a = 0, b = 1, turn = 12, items = { Gold(3, 0, 30) } } }, PAIR_0_1, 40);
	eq(#finished, 1, "one ended");
	eq(finished[1].turn, 10, "the silk deal");
	eq(finished[1].ended, 40, "ended with its term");
	check(R.RanItsTerm(finished[1]), "ran its term");
	eq(R.NotifyType(finished[1]), R.NOTIFY_TYPE, "expired notification");
	_, finished = R.Track(data, {}, PAIR_0_1, 25 + 20);
	eq(#finished, 1, "the second one");
	eq(finished[1].ended, 42, "a term over long ago ends with the term");
	data = R.Empty();
	R.Track(data, { { a = 0, b = 1, turn = 10, items = { Silk(1, 30) } } }, PAIR_0_1, 10);
	_, finished = R.Track(data, {}, PAIR_0_1, 25);
	eq(finished[1].ended, 25, "cut short");
	check(not R.RanItsTerm(finished[1]), "did not run its term");
	eq(R.NotifyType(finished[1]), R.NOTIFY_BROKEN_TYPE, "broken notification");
	_, finished = R.Track(data, {}, PAIR_0_1, 26);
	eq(#finished, 0, "an end is noted once");
end);

test("nothing ends on the turn of the deal, or for a pair the game did not answer for", function()
	local data = R.Empty();
	R.Accept(data, { a = 0, b = 1, turn = 90, items = { Silk(0, 30), Gold(50, 1) } });
	local _, finished = R.Track(data, {}, PAIR_0_1, 90);
	eq(#finished, 0, "not listed yet on its own turn");
	_, finished = R.Track(data, {}, {}, 95);
	eq(#finished, 0, "the game could not be asked");
	_, finished = R.Track(data, {}, PAIR_0_1, 95);
	eq(#finished, 1, "gone afterwards");
end);

test("a deal table accepted before the game lists the deal is that deal, with its one-time items", function()
	local data = R.Empty();
	local deal = R.Accept(data, { a = 0, b = 1, turn = 35, items = { Gold(100, 0), Gold(10, 0, 30), Silk(1, 30) } });
	check(deal ~= nil, "record");
	local changed = R.Track(data, { { a = 0, b = 1, turn = 35, items = { Gold(10, 0, 30), Silk(1, 30) } } }, PAIR_0_1, 35);
	eq(#changed, 0, "the listed deal is the accepted one");
	eq(#data.deals, 1, "deal count");
	eq(Kinds(data.deals[1]), "GOLD:100:0,GOLD:10:30,RESOURCES:1:30", "items");
end);

test("a deal table accepted after the game lists the deal joins its record", function()
	local data = R.Empty();
	R.Track(data, { { a = 0, b = 1, turn = 35, items = { Silk(1, 30) } } }, PAIR_0_1, 35);
	R.Accept(data, { a = 0, b = 1, turn = 35, items = { Gold(100, 0), Silk(1, 30) } });
	eq(#data.deals, 1, "deal count");
	eq(Kinds(data.deals[1]), "GOLD:100:0,RESOURCES:1:30", "items");
end);

test("one-time deals are finished on their turn and listed in the history", function()
	local data = R.Empty();
	R.Accept(data, { a = 0, b = 1, turn = 92, items = { Gold(60, 0) } });
	R.Accept(data, { a = 0, b = 1, turn = 92, items = { Gold(60, 0) } });
	R.Accept(data, { a = 0, b = 1, turn = 92, items = { Gold(100, 0), { kind = "FAVOR", amount = 20, duration = 0, from = 1 } } });
	eq(#data.deals, 3, "two equal gifts are two deals");
	local _, finished = R.Track(data, {}, PAIR_0_1, 93);
	eq(#finished, 0, "a one-time deal is not announced");
	local history = R.History(data, 1, 0);
	eq(#history, 3, "history count");
	eq(R.EndedTurn(history[1]), 92, "one-time end turn");
end);

test("two deals with one leader in one turn keep their own items and end apart", function()
	local data = R.Empty();
	R.Accept(data, { a = 0, b = 1, turn = 99, items = { Gold(100, 0), Gold(10, 0, 30) } });
	R.Accept(data, { a = 0, b = 1, turn = 99, items = { { kind = "FAVOR", amount = 1, duration = 0, from = 0 }, Gold(1, 0, 30) } });
	local lives = {
		{ a = 0, b = 1, turn = 99, items = { Gold(10, 0, 30) } },
		{ a = 0, b = 1, turn = 99, items = { Gold(1, 0, 30) } },
	};
	local changed = R.Track(data, lives, PAIR_0_1, 100);
	eq(#changed, 0, "both listed deals are recorded already");
	eq(#data.deals, 2, "deal count");
	eq(Kinds(data.deals[1]), "GOLD:100:0,GOLD:10:30", "first deal");
	eq(Kinds(data.deals[2]), "FAVOR:1:0,GOLD:1:30", "second deal");
	local _, finished = R.Track(data, { lives[2] }, PAIR_0_1, 110);
	eq(#finished, 1, "one ended");
	eq(finished[1], data.deals[1], "the first one");
end);

test("two equal deals in one turn are two records, and one of them can end alone", function()
	local data = R.Empty();
	local live = { a = 0, b = 1, turn = 50, items = { Silk(0, 30) } };
	R.Track(data, { live, live }, PAIR_0_1, 50);
	eq(#data.deals, 2, "deal count");
	R.Track(data, { live, live }, PAIR_0_1, 51);
	eq(#data.deals, 2, "no third");
	local _, finished = R.Track(data, { live }, PAIR_0_1, 60);
	eq(#finished, 1, "one ended");
end);

test("the history lists finished deals of the pair, the latest first", function()
	local data = R.Empty();
	R.Track(data, {
		{ a = 0, b = 1, turn = 10, items = { Silk(1, 30) } },
		{ a = 0, b = 1, turn = 30, items = { Silk(0, 30) } },
		{ a = 0, b = 2, turn = 12, items = { Silk(2, 10) } },
	}, { ["0:1"] = true, ["0:2"] = true }, 30);
	R.Accept(data, { a = 0, b = 1, turn = 20, items = { Gold(50, 0) } });
	R.Track(data, { { a = 0, b = 1, turn = 30, items = { Silk(0, 30) } } }, PAIR_0_1, 45);
	local list = R.History(data, 1, 0);
	eq(#list, 2, "history count");
	eq(list[1].turn, 10, "ended on turn 40");
	eq(list[2].turn, 20, "one-time on turn 20");
end);

test("an archive of an earlier version is carried over for the local player", function()
	local legacy = table.concat({
		"D\t-1\t35\t0\t1\tGOLD/100/0/0/-1/-1//;GOLD/10/30/0/-1/-1//\t\tp0t35n1\t1",
		"D\t1006\t35\t0\t1\tGOLD/10/30/0/-1/-1//\t",
		"D\t-2\t10\t0\t1\tRESOURCES/1/30/1/1/-1//\t40",
		"D\t-3\t12\t1\t2\tGOLD/5/0/2/-1/-1//\t",
		"D\t-4\t20\t0\t3\tRESOURCES/1/30/0/1/-1//\t",
		"A\t20\t0\t3\tGOLD/7/0/3/-1/-1//;RESOURCES/1/30/0/1/-1//\tp0t20n1",
		"N\t-4",
	}, "~");
	local data = R.Empty();
	local added = R.Import(data, legacy, 0);
	eq(#added, 3, "records carried over");
	eq(#data.deals, 3, "one deal stored twice is one record; another pair's deal stays out");
	eq(Kinds(data.deals[1]), "GOLD:100:0,GOLD:10:30", "first deal with its lump sum");
	eq(data.deals[2].ended, 40, "end turn kept");
	eq(Kinds(data.deals[3]), "GOLD:7:0,RESOURCES:1:30", "one-time items kept apart then");
	check(data.deals[1].id < 0 and data.deals[2].id < data.deals[1].id, "own numbers");
end);

test("a record line replaces the one with its id", function()
	local data = R.Empty();
	local first = R.AddRecord(data, 0, 1, 10, { Silk(1, 30) });
	R.AddRecord(data, 0, 1, 11, { Gold(5, 0) });
	local text = R.EncodeArchive(data);
	first.ended = 40;
	text = R.PutLine(text, R.EncodeRecord(first));
	local back = R.Normalize(text);
	eq(#back.deals, 2, "replaced, not added");
	eq(R.FindID(back, -1).ended, 40, "new content");
	text = R.PutLine(nil, R.EncodeRecord({ id = -7, turn = 3, a = 0, b = 1, items = { Gold(1, 0) } }));
	eq(R.Normalize(text).next, -7, "a new number is not reused");
	eq(R.PutLine(text, "garbage"), text, "a broken line changes nothing");
end);

test("the journal keeps only the latest lines", function()
	local text;
	for i = 1, R.LOG_LINES + 5 do text = R.AppendLog(text, "line " .. i) end
	local count = select(2, text:gsub("~", "")) + 1;
	eq(count, R.LOG_LINES, "line count");
	eq(text:sub(1, 7), "line 6~", "oldest kept");
	eq(R.AppendLog(nil, "a~b"), "a-b", "separator in a line");
end);

-- ---------------------------------------------------------------------------
-- The gameplay script
-- ---------------------------------------------------------------------------
local function GameplayWorld()
	local w = Mock.new({ modDir = MOD_DIR, turn = 40, players = {
		[0] = { leader = "Peter", civ = "Russia" },
		[1] = { leader = "Gandhi", civ = "India" },
	} });
	w:LoadGameplay();
	return w;
end

test("the gameplay script stores each player's record under its own property", function()
	local w = GameplayWorld();
	local exposed = w.exposed.UIExt;
	check(exposed ~= nil and exposed.PutRecord ~= nil and exposed.ReadArchive ~= nil, "functions for the interface");
	exposed.PutRecord(0, R.EncodeRecord({ id = -1, turn = 10, a = 0, b = 1, items = { Silk(1, 30) } }));
	w.GameEvents[R.OP_PUT](1, { uiextLine = R.EncodeRecord({ id = -1, turn = 12, a = 0, b = 1, items = { Gold(5, 1) } }) });
	eq(#R.Normalize(w.properties[R.ArchiveKey(0)]).deals, 1, "player 0");
	eq(R.Normalize(w.properties[R.ArchiveKey(1)]).deals[1].turn, 12, "player 1, from a player operation");
	eq(exposed.ReadArchive(0), w.properties[R.ArchiveKey(0)], "read back");
end);

test("the gameplay script sends the notification it is handed", function()
	local w = GameplayWorld();
	local params = {
		uiextType = R.NOTIFY_TYPE, uiextMessage = "Deal with Gandhi expired", uiextSummary = "text",
		uiextPartner = 1, uiextDealID = -2, uiextTurn = 10,
	};
	check(w.exposed.UIExt.Notify(0, params), "sent");
	w.GameEvents[R.OP_NOTIFY](0, params);
	eq(#w.notifications, 2, "directly and from a player operation");
	local sent = w.notifications[1];
	eq(sent.player, 0, "player");
	eq(sent.type, 509, "type");
	eq(sent.params.Message, "Deal with Gandhi expired", "title");
	eq(sent.params[R.NOTIFY_MARK], 1, "mark");
	eq(sent.params.UIExtDealID, -2, "deal");
	check(not w.exposed.UIExt.Notify(0, { uiextType = "NO_SUCH_TYPE" }), "an unknown type sends nothing");
end);

test("the gameplay script keeps the journal of both contexts", function()
	local w = GameplayWorld();
	w.exposed.UIExt.AppendJournal("7 t40 UI hello");
	local journal = w.properties[R.LOG_GAMEPLAY];
	check(journal:find("t40 GP ready", 1, true), "own line: " .. journal);
	check(journal:find("7 t40 UI hello", 1, true), "interface line: " .. journal);
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
