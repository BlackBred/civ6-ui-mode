-- Behaviour tests for UI/DealOverview.lua against the mocked Civ6 API. Run with: luajit tests/test_deal_overview.lua
local TESTS_DIR = arg[0]:match("^(.*)/[^/]*$") or ".";
local MOD_DIR = TESTS_DIR .. "/../UI_Extender";
package.path = TESTS_DIR .. "/?.lua;" .. package.path;
local Mock = require("mock_civ6");

local tests = {};
local function test(name, fn) table.insert(tests, { name = name, fn = fn }) end

local function Items(w, name, parent)
	local list = {};
	local im = w:Manager(name);
	if im == nil then return list end
	for _, inst in ipairs(im.items) do
		if inst.Top.parent == parent then table.insert(list, inst) end
	end
	return list;
end

-- What the deals tab shows: { header, sides = { { title, items = { text, ... } } } } per deal.
local function TabDeals(w, panel)
	local deals = {};
	for _, deal in ipairs(Items(w, "DealsTabDeal", panel.TabCards)) do
		local entry = { header = deal.Header.text, sides = {} };
		for _, side in ipairs(Items(w, "DealsTabSide", deal.Sides)) do
			local title, anchor = nil, nil;
			for _, id in ipairs({ "SharedTitle", "OursTitle", "TheirsTitle" }) do
				if not side[id].hidden then
					assert(title == nil, "two titles shown on one side");
					title = side[id].text;
					anchor = side[id].anchor;
				end
			end
			local texts = {};
			for _, item in ipairs(Items(w, "DealsTabItem", side.Items)) do
				table.insert(texts, item.Text.text);
			end
			table.insert(entry.sides, { title = title, items = texts, width = side.Top.w, anchor = anchor });
		end
		table.insert(deals, entry);
	end
	return deals;
end

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
	w:AddResource(2, "RESOURCE_IRON", "Iron", "RESOURCECLASS_STRATEGIC");
	w:AddResource(3, "RESOURCE_SPICES", "Spices");
	w.gameText["LOC_DIPLOACTION_ALLIANCE_NAME"] = "Alliance";
	return w;
end

local function Gold(from, amount, duration, enacted)
	return { type = "GOLD", from = from, amount = amount, duration = duration, enacted = enacted };
end

local function Silk(from, duration, enacted)
	return { type = "RESOURCES", from = from, amount = 1, duration = duration, enacted = enacted, valueType = 1 };
end

local function Spice(from, duration, enacted)
	return { type = "RESOURCES", from = from, amount = 1, duration = duration, enacted = enacted, valueType = 3 };
end

local function Iron(from, duration, enacted)
	return { type = "RESOURCES", from = from, amount = 2, duration = duration, enacted = enacted, valueType = 2 };
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
	check(root.hidden, "diplomacy panel is shown");
	check(w.Controls.ExpandButton.hidden, "expand button is shown");
	check(w.Controls.Title.text:find("India", 1, true), "title has no civ: " .. w.Controls.Title.text);
	local cards = w:Cards();
	eq(#cards, 1, "card count");
	eq(cards[1].Header.text, "Turns left: 20", "header");
	eq(cards[1].OursBody.text, "5 [ICON_GOLD] per turn", "ours");
	eq(cards[1].TheirsTitle.text, "Gandhi gives", "theirs title");
	eq(cards[1].TheirsBody.text, "1 [ICON_RESOURCE_SILK] Silk", "theirs");
	check(cards[1].SharedBody.hidden, "shared block shown for a one-sided deal");
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
	check(w.Controls.Root.hidden, "diplomacy panel is shown");
	check(w.Controls.Title.text:find("India", 1, true), "title has no civ: " .. w.Controls.Title.text);
end);

test("the diplomacy panel stays hidden when its buttons are clicked", function(w)
	w:AddDeal(0, 1, { Gold(0, 5, 30, 10) });
	w:Load();
	w:OpenDiplomacy(1);
	w.Controls.CollapseButton:Click();
	w.Controls.ExpandButton:Click();
	check(w.Controls.Root.hidden, "panel shown from the diplomacy screen");
	check(w.Controls.ExpandButton.hidden, "expand button shown from the diplomacy screen");
end);

test("the deal list shows on the deal screen and hides when it closes", function(w)
	w:AddDeal(0, 1, { Gold(0, 5, 30, 10) });
	w:Load();
	w:OpenDiplomacy(1);
	check(w.Controls.Root.hidden, "panel shown before the deal screen");
	w:OpenDeal();
	check(Visible(w.Controls.Root), "panel hidden on the deal screen");
	eq(w.Controls.Root.x, 540, "panel placed right next to the trade banner (534 + 6)");
	check(w.Controls.Root.x + w.Controls.Root.w <= w.screenW, "panel runs off the right edge");
	w:CloseDeal();
	w:OpenDeal();
	check(Visible(w.Controls.Root), "panel hidden on the second deal screen");
	eq(w.Controls.Root.x, 540, "second opening keeps the position");
	w:CloseDeal();
	check(w.Controls.Root.hidden, "panel left after the deal screen closed");
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

test("luxury export to the open leader shows the turns and a gold frame", function(w)
	w:AddDeal(0, 1, { Silk(0, 30, 10) });
	w:Load();
	w:OpenDiplomacy(1);
	eq(#w:FlowBlocks(), 0, "flows shown before the deal screen");
	w:OpenDeal();

	local blocks = w:FlowBlocks();
	eq(#blocks, 1, "block count");
	eq(blocks[1].Title.text, "Export", "block title");
	eq(blocks[1].Top.parent, w.luxuryList, "block parent");
	local icons = w:FlowIcons();
	eq(#icons, 1, "icon count");
	eq(icons[1].Turns.text, "20", "turns");
	eq(icons[1].Amount.text, "1", "amount");
	check(icons[1].Highlight.hidden == false, "current leader not highlighted");
	local tip = icons[1].Top.tooltip;
	check(tip:find("Silk", 1, true) ~= nil, "tooltip resource: " .. tostring(tip));
	check(tip:find("Gandhi · 1 · 20", 1, true) ~= nil, "tooltip partner: " .. tostring(tip));
	check(tip:find("*", 1, true) == nil, "star on a single deal");
end);

test("several partners show the soonest turn and a star", function(w)
	w.players[2] = { leader = "Cleopatra", civ = "Egypt" };
	w:AddDeal(0, 1, { Silk(0, 30, 15) });
	w:AddDeal(0, 2, { Silk(0, 30, 5) });
	w:Load();
	w:OpenDiplomacy(1);
	w:OpenDeal();

	local icons = w:FlowIcons();
	eq(#icons, 1, "icon count");
	eq(icons[1].Turns.text, "15*", "soonest turns");
	eq(icons[1].Amount.text, "2", "summed amount");
	check(icons[1].Highlight.hidden == false, "open leader not highlighted");
	local tip = icons[1].Top.tooltip;
	check(tip:find("Cleopatra · 1 · 15", 1, true) ~= nil, "soonest partner: " .. tostring(tip));
	check(tip:find("[COLOR_Gold]Gandhi · 1 · 25 turns left[ENDCOLOR]", 1, true) ~= nil, "open leader: " .. tostring(tip));
	check(tip:find("[COLOR_Gold]Cleopatra", 1, true) == nil, "other leader colored");
end);

test("import and export are separate blocks", function(w)
	w.players[2] = { leader = "Cleopatra", civ = "Egypt" };
	w:AddDeal(0, 1, { Silk(1, 30, 18) });
	w:AddDeal(0, 2, { Spice(0, 30, 16) });
	w:Load();
	w:OpenDiplomacy(1);
	w:OpenDeal();

	local blocks = w:FlowBlocks();
	eq(#blocks, 2, "block count");
	eq(blocks[1].Title.text, "Import", "first block");
	eq(blocks[2].Title.text, "Export", "second block");
	local icons = w:FlowIcons();
	eq(icons[1].Turns.text, "28", "import turns");
	eq(icons[1].Amount.text, "1", "import amount");
	check(icons[1].Highlight.hidden == false, "import from the open leader");
	check(icons[1].Top.tooltip:find("Import", 1, true) ~= nil, "import heading");
	eq(icons[2].Turns.text, "26", "export turns");
	eq(icons[2].Amount.text, "1", "export amount");
	check(icons[2].Highlight.hidden, "export to someone else is highlighted");
	check(icons[2].Top.tooltip:find("Cleopatra · 1 · 26", 1, true) ~= nil, "export tooltip: " .. tostring(icons[2].Top.tooltip));
end);

test("strategic and one-time resources are not listed as flows", function(w)
	w:AddDeal(0, 1, { Iron(0, 30, 10), Silk(1, 0, 10) });
	w:Load();
	w:OpenDiplomacy(1);
	w:OpenDeal();
	eq(#w:FlowBlocks(), 0, "block count");
	eq(#w:FlowIcons(), 0, "icon count");
end);

test("closing the deal screen removes import and export", function(w)
	w:AddDeal(0, 1, { Silk(0, 30, 10) });
	w:Load();
	w:OpenDiplomacy(1);
	w:OpenDeal();
	eq(#w:FlowIcons(), 1, "icon count");
	w:CloseDeal();
	eq(#w:FlowBlocks(), 0, "blocks left after close");
	eq(#w:FlowIcons(), 0, "icons left after close");
	eq(#w.luxuryList.children, 2, "luxury list children");
end);

test("deals tab appears in the intel report when the game rebuilds the tabs", function(w)
	w:AddDeal(0, 1, { Gold(0, 5, 30, 10), Silk(1, 30, 10) });
	w:Load();
	local report = w:IntelReport();
	w.LuaEvents.DiploScene_RefreshTabs(1);

	local button, panel = w:DealsTab();
	eq(button.Button.parent, report.stack, "button parent");
	eq(button.ButtonIcon.icon, "ICON_UNIT_TRADER_WHITE", "button icon");
	check(panel.Top.hidden, "panel shown before click");
	eq(panel.Top.parent, report.container, "panel parent");
	local deals = TabDeals(w, panel);
	eq(#deals, 1, "deal count");
	eq(deals[1].header, "Turns left: 20", "header");
	eq(#deals[1].sides, 2, "side count");
	eq(deals[1].sides[1].title, "You give", "ours title");
	eq(table.concat(deals[1].sides[1].items, "|"), "5 [ICON_GOLD] per turn", "ours");
	eq(deals[1].sides[2].title, "Gandhi gives", "theirs title");
	eq(table.concat(deals[1].sides[2].items, "|"), "1 [ICON_RESOURCE_SILK] Silk", "theirs");
	eq(deals[1].sides[1].width, 470, "side fits the report width");
	eq(panel.Top.w, 470, "panel fits the report width");
	check(panel.TabEmpty.hidden, "empty label shown with a deal");
end);

test("deals tab button returns to the end when the game reattaches its tabs", function(w)
	w:Load();
	local report = w:IntelReport();
	w.LuaEvents.DiploScene_RefreshTabs(1);
	local button = w:DealsTab();
	local gameButton = Mock.NewControl({ id = "GameTab" });
	table.insert(report.stack.children, 1, gameButton);
	gameButton.parent = report.stack;
	gameButton:ChangeParent(report.stack);
	eq(report.stack.children[#report.stack.children], gameButton, "game button moved last");
	w.LuaEvents.DiploScene_RefreshTabs(1);
	eq(report.stack.children[#report.stack.children], button.Button, "deals button is last again");
end);

test("a wrapped title does not separate the bullets or drop a single bullet", function(w)
	w.players[1].leader = "Cleopatra of Egypt";
	w:AddDeal(0, 1, { Gold(1, 4, 30, 10), Silk(1, 30, 10) });
	w:Load();
	w:IntelReport();
	w.LuaEvents.DiploScene_RefreshTabs(1);
	local _, panel = w:DealsTab();
	local deal = Items(w, "DealsTabDeal", panel.TabCards)[1];
	local side = Items(w, "DealsTabSide", deal.Sides)[1];
	local rows = Items(w, "DealsTabItem", side.Items);
	eq(#rows, 2, "item count");
	eq(rows[1].Top.h, 22, "first row");
	eq(rows[2].Top.h, 22, "second row");
	eq(side.Items.y, 0, "bullets start at the top");
	eq(side.Items.h, 46, "no blank row between bullets");
	eq(side.Top.h, 46, "side is no taller than its bullets");
	eq(side.TheirsTitle.y, 0, "title starts on the first bullet");
	eq(side.TheirsTitle.anchor, "L,T", "title anchor");

	w.deals = {};
	w:AddDeal(0, 1, { Gold(1, 1, 30, 10) });
	w.Events.DiplomacyDealEnacted();
	deal = Items(w, "DealsTabDeal", panel.TabCards)[1];
	side = Items(w, "DealsTabSide", deal.Sides)[1];
	eq(side.Items.y, 0, "single bullet stays at the top");
	eq(side.Items.h, 22, "single bullet row");
	eq(side.TheirsTitle.y, 0, "title stays on that bullet");
	check(side.Top.h > side.Items.h, "the wrapped second line has room under the bullet");
end);

test("a two-line side title stays pinned to the top of its row", function(w)
	w:AddDeal(0, 1, { Gold(1, 3, 30, 10) });
	w:Load();
	w:IntelReport();
	w.LuaEvents.DiploScene_RefreshTabs(1);
	local _, panel = w:DealsTab();
	local deal = TabDeals(w, panel)[1];
	eq(deal.sides[1].title, "Gandhi gives", "title");
	eq(deal.sides[1].anchor, "L,T", "title anchor");
end);

test("deals tab is added once per rebuild, not twice", function(w)
	w:Load();
	local report = w:IntelReport();
	w.LuaEvents.DiploScene_RefreshTabs(1);
	w.LuaEvents.DiploScene_RefreshTabs(1);
	eq(#report.stack.children, 1, "buttons in the same report");

	-- The game destroys the old report when it rebuilds, so it is gone from the tree.
	w.view.children = {};
	local newer = w:IntelReport();
	w.LuaEvents.DiploScene_RefreshTabs(1);
	eq(#newer.stack.children, 1, "buttons in the rebuilt report");
	eq(#report.stack.children, 0, "old report no longer holds the button");
end);

test("deals tab is added from the update tick when no event arrives", function(w)
	w:AddDeal(0, 1, { Gold(0, 5, 30, 10) });
	w:Load();
	local report = w:IntelReport();
	w:OpenDiplomacy(1);
	local button, panel = w:DealsTab();
	eq(button.Button.parent, report.stack, "button parent");
	eq(#panel.TabCards.children, 1, "card count");
end);

test("clicking the deals tab shows its panel and hides the game's panel", function(w)
	w:AddDeal(0, 1, { Gold(0, 5, 30, 10) });
	w:Load();
	local report = w:IntelReport();
	local other = Mock.NewControl({ id = "OtherTab" });
	other.selected = true;
	table.insert(report.stack.children, other);
	w.LuaEvents.DiploScene_RefreshTabs(1);
	local button, panel = w:DealsTab();

	button.Button:Click();
	check(not panel.Top.hidden, "deals panel still hidden after click");
	check(report.gamePanel.hidden, "game panel still shown after click");
	eq(report.header.text, "INTEL REPORT: DEALS", "header");
	check(button.Button:IsSelected(), "deals button not selected");
	check(not other.selected, "other tab button still selected");
end);

test("deals button highlight follows the panel", function(w)
	w:Load();
	local report = w:IntelReport();
	w.LuaEvents.DiploScene_RefreshTabs(1);
	local button, panel = w:DealsTab();
	w:OpenDiplomacy(1);

	button.Button:Click();
	w:Tick(10);
	check(button.Button:IsSelected(), "highlight off while the panel is open");

	-- The game's own tab takes over: it hides every other panel, including ours.
	for _, child in ipairs(report.container.children) do
		child:SetHide(child ~= report.gamePanel);
	end
	report.gamePanel:SetHide(false);
	w:Tick(10);
	check(not button.Button:IsSelected(), "highlight stays on after another tab is clicked");
end);

test("deals tab updates when a deal is enacted", function(w)
	w:Load();
	local report = w:IntelReport();
	w.LuaEvents.DiploScene_RefreshTabs(1);
	local _, panel = w:DealsTab();
	eq(#panel.TabCards.children, 0, "card count before");
	check(not panel.TabEmpty.hidden, "empty label hidden without deals");

	w:AddDeal(0, 1, { Gold(0, 5, 30, 10) });
	w.Events.DiplomacyDealEnacted();
	eq(#panel.TabCards.children, 1, "card count after");
	check(panel.TabEmpty.hidden, "empty label shown with a deal");
	eq(TabDeals(w, panel)[1].header, "Turns left: 20", "header");
end);

test("deals tab shows a shared alliance and per-line turns", function(w)
	w:AddDeal(0, 1, { Alliance(0), Alliance(1), Gold(0, 5, 30, 10), Silk(1, 10, 15) });
	w:Load();
	w:IntelReport();
	w.LuaEvents.DiploScene_RefreshTabs(1);
	local _, panel = w:DealsTab();
	local deal = TabDeals(w, panel)[1];
	eq(deal.header, "Items end at different times", "header");
	eq(deal.sides[1].title, "Shared", "shared title");
	eq(table.concat(deal.sides[1].items, "|"), "Alliance · Until ended", "shared");
	eq(table.concat(deal.sides[2].items, "|"), "5 [ICON_GOLD] per turn · 20", "ours");
	eq(table.concat(deal.sides[3].items, "|"), "1 [ICON_RESOURCE_SILK] Silk · 5", "theirs");
end);

test("reused side blocks show only their own title", function(w)
	w:AddDeal(0, 1, { Gold(0, 5, 30, 10) });
	w:Load();
	w:IntelReport();
	w.LuaEvents.DiploScene_RefreshTabs(1);
	w.deals = {};
	w:AddDeal(0, 1, { Gold(1, 3, 30, 10) });
	w.Events.DiplomacyDealEnacted();
	local _, panel = w:DealsTab();
	local deal = TabDeals(w, panel)[1];
	eq(#deal.sides, 1, "side count");
	eq(deal.sides[1].title, "Gandhi gives", "title");
end);

test("deals tab says when there is nothing lasting", function(w)
	w:AddDeal(0, 1, { Gold(0, 100, 0) });
	w:Load();
	w:IntelReport();
	w.LuaEvents.DiploScene_RefreshTabs(1);
	local _, panel = w:DealsTab();
	eq(#panel.TabCards.children, 0, "card count");
	check(not panel.TabEmpty.hidden, "empty label hidden");
end);

test("failing deal API leaves the luxury list untouched", function(w)
	w.failDeals = true;
	w:Load();
	w:OpenDiplomacy(1);
	w:OpenDeal();
	eq(#w:FlowBlocks(), 0, "block count");
	eq(#w:Errors(), 0, "error count");
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
	-- The tab is added next to the game's report tabs, not by replacing the diplomacy script.
	local overlay = Mock.ReadFile(MOD_DIR .. "/UI/DealOverview.lua");
	for _, needle in ipairs({ "DiploScene_RefreshTabs", "IntelTabButtonStack", "IntelPanelContainer", "DealsTabButton" }) do
		if overlay:find(needle, 1, true) == nil then
			table.insert(failures, "deals tab missing " .. needle);
		end
	end
	local modinfo = Mock.ReadFile(MOD_DIR .. "/UI_Extender.modinfo");
	if modinfo:find("ReplaceUIScript", 1, true) ~= nil then
		table.insert(failures, "modinfo replaces the diplomacy script again");
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
