-- Behaviour tests for UI/DealOverview.lua against the mocked Civ6 API. Run with: luajit tests/test_deal_overview.lua
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

local function NewWorld(opts)
	opts = opts or {};
	opts.modDir = MOD_DIR;
	opts.turn = opts.turn or 20;
	local w = Mock.new(opts);
	w:AddResource(1, "RESOURCE_SILK", "Silk");
	w.gameText["LOC_DIPLOACTION_ALLIANCE_NAME"] = "Alliance";
	return w;
end

local function Gold(from, amount, duration, enacted)
	return { type = "GOLD", from = from, amount = amount, duration = duration, enacted = enacted };
end

local function Silk(from, duration, enacted)
	return { type = "RESOURCES", from = from, amount = 1, duration = duration, enacted = enacted, valueType = 1 };
end

local function Alliance(from)
	return { type = "AGREEMENTS", subType = "ALLIANCE", from = from, duration = 0, subTypeName = "LOC_DIPLOACTION_ALLIANCE_NAME" };
end

local function Visible(c) return not c.hidden end

-- ---------------------------------------------------------------------------
test("loads without errors and stays hidden on the map", function(w)
	w:Load();
	w:Tick(30);
	check(Visible(w.Controls.DebugBox) == false, "debug box is shown");
	check(w.Controls.Root.hidden, "panel visible without diplomacy");
	check(w.Controls.ExpandButton.hidden, "expand button visible without diplomacy");
	local found = false;
	for _, l in ipairs(w.logs) do if l:find("initialized", 1, true) then found = true end end
	check(found, "no 'initialized' log line");
end);

test("timed gold and resource deal", function(w)
	w:AddDeal(0, 1, { Gold(0, 5, 30, 10), Silk(1, 30, 10) });
	w:Load();
	w:OpenDiplomacy(1);

	local root = w.Controls.Root;
	check(Visible(root), "panel hidden");
	check(w.Controls.Title.text:find("India", 1, true), "title has no civ: " .. w.Controls.Title.text);
	local cards = w:Cards();
	eq(#cards, 1, "card count");
	eq(cards[1].Header.text, "Turns left: 20", "header");
	eq(cards[1].OursBody.text, "5 [ICON_GOLD] per turn", "ours");
	eq(cards[1].TheirsTitle.text, "Gandhi gives", "theirs title");
	eq(cards[1].TheirsBody.text, "1 [ICON_RESOURCE_SILK] Silk", "theirs");
	check(cards[1].SharedBody.hidden, "shared block shown for a one-sided deal");

	check(root.x >= 0 and root.x + root.w <= w.screenW, string.format("panel off screen horizontally: x=%d w=%d", root.x, root.w));
	check(root.y >= 0 and root.y + root.h <= w.screenH, string.format("panel off screen vertically: y=%d h=%d", root.y, root.h));
	check(root.x > 560, "panel overlaps the leader column: x=" .. root.x);
end);

test("one-time items are not listed", function(w)
	w:AddDeal(0, 1, { Gold(0, 100, 0) });
	w:Load();
	w:OpenDiplomacy(1);
	eq(#w:Cards(), 0, "card count");
	check(Visible(w.Controls.EmptyLabel), "empty label hidden");
	check(w.Controls.Scroll.hidden, "scroll shown with no deals");
	eq(w.Controls.ExpandButton.text, "Deals: 0", "expand button");
end);

test("alliance is open-ended and shown once as shared", function(w)
	w:AddDeal(0, 1, { Alliance(0), Alliance(1) });
	w:Load();
	w:OpenDiplomacy(1);
	local cards = w:Cards();
	eq(#cards, 1, "card count");
	eq(cards[1].Header.text, "Until ended", "header");
	eq(cards[1].SharedBody.text, "Alliance", "shared");
	check(cards[1].OursBody.hidden and cards[1].TheirsBody.hidden, "alliance also listed per side");
end);

test("different durations show turns per line", function(w)
	w:AddDeal(0, 1, { Gold(0, 5, 30, 10), Silk(1, 10, 15) });
	w:Load();
	w:OpenDiplomacy(1);
	local card = w:Cards()[1];
	eq(card.Header.text, "Items end at different times", "header");
	eq(card.OursBody.text, "5 [ICON_GOLD] per turn · 20", "ours");
	eq(card.TheirsBody.text, "1 [ICON_RESOURCE_SILK] Silk · 5", "theirs");
end);

test("cards are sorted by soonest expiry", function(w)
	w:AddDeal(0, 1, { Gold(0, 5, 30, 10) });
	w:AddDeal(0, 1, { Gold(1, 2, 10, 13) });
	w:Load();
	w:OpenDiplomacy(1);
	local cards = w:Cards();
	eq(#cards, 2, "card count");
	eq(cards[1].Header.text, "Turns left: 3", "first card");
	eq(cards[2].Header.text, "Turns left: 20", "second card");
end);

test("partner found from the open session when no event names it", function(w)
	w:AddDeal(0, 1, { Gold(0, 5, 30, 10) });
	w.sessions[1] = 7;
	w:Load();
	w:OpenDiplomacy(nil);
	check(Visible(w.Controls.Root), "panel hidden");
	check(w.Controls.Title.text:find("India", 1, true), "title has no civ: " .. w.Controls.Title.text);
end);

test("collapse and expand", function(w)
	w:AddDeal(0, 1, { Gold(0, 5, 30, 10) });
	w:Load();
	w:OpenDiplomacy(1);
	w.Controls.CollapseButton:Click();
	check(w.Controls.Root.hidden, "panel still shown after collapse");
	check(Visible(w.Controls.ExpandButton), "expand button hidden after collapse");
	eq(w.Controls.ExpandButton.text, "Deals: 1", "expand button");
	w.Controls.ExpandButton:Click();
	check(Visible(w.Controls.Root), "panel hidden after expand");
end);

test("closing diplomacy hides everything", function(w)
	w:AddDeal(0, 1, { Gold(0, 5, 30, 10) });
	w:Load();
	w:OpenDiplomacy(1);
	w:CloseDiplomacy();
	check(w.Controls.Root.hidden, "panel left on the map");
	check(w.Controls.ExpandButton.hidden, "expand button left on the map");
end);

test("failing deal API does not break the panel", function(w)
	w.failDeals = true;
	w:Load();
	w:OpenDiplomacy(1);
	check(Visible(w.Controls.EmptyLabel), "empty label hidden");
end);

-- ---------------------------------------------------------------------------
-- Static checks
-- ---------------------------------------------------------------------------
local function StaticTests()
	local failures = {};
	local english, russian = Mock.ParseText(Mock.ReadFile(MOD_DIR .. "/Text/DealOverview_Text.xml"));
	for tag in pairs(english) do
		if russian[tag] == nil then table.insert(failures, "no ru_RU text for " .. tag) end
	end
	for _, file in ipairs({ "/UI/DealOverview.lua", "/UI/DealOverview.xml" }) do
		for tag in Mock.ReadFile(MOD_DIR .. file):gmatch("LOC_UIEXT_[%w_]+") do
			if english[tag] == nil then table.insert(failures, file .. " uses undefined " .. tag) end
		end
	end
	for path in Mock.ReadFile(MOD_DIR .. "/UI_Extender.modinfo"):gmatch("<File>(.-)</File>") do
		local f = io.open(MOD_DIR .. "/" .. path, "r");
		if f == nil then table.insert(failures, "modinfo lists missing file " .. path) else f:close() end
	end
	return failures;
end

-- ---------------------------------------------------------------------------
local failed = 0;
for _, t in ipairs(tests) do
	local w = NewWorld();
	local ok, err = pcall(t.fn, w);
	if ok then
		local problems = w:Errors();
		for _, line in ipairs(w:AllTexts()) do
			if line:find("LOC_", 1, true) then table.insert(problems, "unresolved text " .. line) end
		end
		if #problems > 0 then
			ok, err = false, table.concat(problems, "\n    ");
		end
	end
	if ok then
		print("ok    " .. t.name);
	else
		failed = failed + 1;
		print("FAIL  " .. t.name .. "\n    " .. tostring(err));
		if #w.logs > 0 then print("    mod log:\n      " .. table.concat(w.logs, "\n      ")) end
	end
end

local static = StaticTests();
if #static == 0 then
	print("ok    static: texts, LOC keys, modinfo files");
else
	failed = failed + 1;
	print("FAIL  static\n    " .. table.concat(static, "\n    "));
end

print(string.format("\n%d of %d failed", failed, #tests + 1));
os.exit(failed == 0 and 0 or 1);
