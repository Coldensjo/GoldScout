-- Gold Scout journal: a log of nearly everything the character does that touches gold or items.
-- GoldScoutDB.journal, one line per event, "time|char|type|...":
--   loot   |source|id|name|zone|money|itemID:n,...   source = Creature, GameObject, Item, or herb, mining, skinning,
--                                                    fishing for gathering; what dropped
--                                                    (also items left on the corpse), money in copper
--   inv    |context|money|itemID:+n,itemID:-n         bag + equipment change and money change, by what was going on:
--                                                    vendor, mail, ah, trade, training, travel, craft, loot, quest, other
--   used   |itemID:n,itemID:n                        consumed (food, potions, ammo...), summed per minute
--   repair |copper                                     paid at a vendor to repair
--   wear   |death/spirit/combat|copper                 repair bill added by a death, the spirit healer or fighting
--   delete |itemID|n                                  an item picked up and destroyed
--   craft  |itemID|n                                  "You create: ..."
--   roll   |need/greed/pass/won|itemID
--   quest  |questID|xp|money
--   level  |level
--   death  |zone|x|y

local MAX_LINES = 80000

local _, ns = ...

local key
local gathering, gatheredAt -- last gathering cast (herb, mining, skinning, fishing), its loot is tagged with it
local log

local function Add(...)
	if not log then return end
	log[#log + 1] = time() .. "|" .. key .. "|" .. table.concat({ ... }, "|")
	if #log > MAX_LINES then table.remove(log, 1) end
end

ns.Log = Add -- Character.lua writes its lines through this

local function ID(link)
	return link and tonumber(link:match("item:(%d+)"))
end

local function Pattern(fmt)
	if not fmt then return nil end
	return "^" .. fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%s", "(.+)"):gsub("%%d", "(%%d+)") .. "$"
end

-- "Creature-0-4615-2991-76543-254626-0000496963" -> "Creature", 254626
local function ParseGUID(guid)
	if not guid then return nil end
	local kind, _, _, _, _, id = strsplit("-", guid)
	return kind, tonumber(id)
end

------------------------------------------------------------------------------------------------
-- What is going on right now (used to explain bag and money changes)

local open = {}
local recent = {}
local function Mark(what, seconds) recent[what] = GetTime() + (seconds or 3) end
local function Recent(what) return recent[what] and recent[what] > GetTime() end

local function Context(lost)
	if open.bank then return nil end -- moving things to and from the bank is not a change
	if open.merchant then return "vendor" end
	-- the auction house before the mailbox: with both open (or the mailbox not reported closed), posting
	-- at the auction house was logged as mail
	if open.ah then return "ah" end
	if open.mail then return "mail" end
	if open.trade then return "trade" end
	if open.trainer then return "training" end
	if open.taxi then return "travel" end
	if open.craft or Recent("craft") then return "craft" end
	if open.loot or Recent("loot") then return "loot" end
	if Recent("quest") then return "quest" end
	if Recent("roll") then return "loot" end
	return lost and "use" or "other"
end

------------------------------------------------------------------------------------------------
-- Inventory ledger: compare bags + equipped items + money with the last snapshot

local Container = C_Container or {}
local GetNumSlots = Container.GetContainerNumSlots or GetContainerNumSlots
local GetInfo = Container.GetContainerItemInfo

local function Snapshot()
	local items = {}
	for bag = 0, 4 do
		for slot = 1, (GetNumSlots(bag) or 0) do
			local info = GetInfo and GetInfo(bag, slot)
			if info and info.itemID then items[info.itemID] = (items[info.itemID] or 0) + (info.stackCount or 1) end
		end
	end
	for slot = 1, 19 do
		local id = GetInventoryItemID("player", slot)
		if id then items[id] = (items[id] or 0) + 1 end
	end
	return items, GetMoney()
end

local lastItems, lastMoney

-- Consumption (food, potions, ammo) is summed and written once a minute, not once per arrow
local usedBuffer = {}
-- Repair bill of the equipped gear, read from the item tooltips (nil when the client does not say)
local scanTip
local function RepairBill()
	local total, known = 0, false
	for slot = 1, 18 do
		local cost
		if C_TooltipInfo and C_TooltipInfo.GetInventoryItem then
			local ok, data = pcall(C_TooltipInfo.GetInventoryItem, "player", slot)
			if ok and data and data.repairCost then cost = data.repairCost end
		end
		if not cost then
			scanTip = scanTip or CreateFrame("GameTooltip", "GoldScoutScanTip", nil, "GameTooltipTemplate")
			scanTip:SetOwner(UIParent, "ANCHOR_NONE")
			local ok, _, _, c = pcall(scanTip.SetInventoryItem, scanTip, "player", slot)
			if ok and type(c) == "number" then cost = c end
			scanTip:Hide()
		end
		if cost then
			total, known = total + cost, true
		end
	end
	return known and total or nil
end

local lastBill, wearBuffer, wearQueued = nil, 0, false
local function CheckWear(cause)
	local bill = RepairBill()
	if GoldScoutDB.debug then print("|cffffd200Gold Scout debug|r repair bill", bill or "unknown", cause or "") end
	if not bill then return end
	if lastBill and bill > lastBill then
		local d = bill - lastBill
		if cause then Add("wear", cause, d) else wearBuffer = wearBuffer + d end
	end
	lastBill = bill
end

local function FlushUsed()
	local parts = {}
	for id, n in pairs(usedBuffer) do parts[#parts + 1] = id .. ":" .. n end
	if #parts > 0 then Add("used", table.concat(parts, ",")) end
	usedBuffer = {}
	if wearBuffer > 0 then
		Add("wear", "combat", wearBuffer)
		wearBuffer = 0
	end
end

-- Deleting: an item is picked up on the cursor, the cursor empties, and the item is gone while no
-- vendor, mail, trade or auction house is open. Putting it back leaves it in the bags.
local cursorItem, droppedItem, droppedAt
local function Deletable()
	return droppedItem and GetTime() - droppedAt < 3
		and not (open.merchant or open.mail or open.ah or open.trade or open.bank)
end

local function Ledger()
	if not log then return end
	local items, money = Snapshot()
	if lastItems then
		local changes, lost = {}, false
		for id, n in pairs(items) do
			local d = n - (lastItems[id] or 0)
			if d ~= 0 then changes[#changes + 1] = id .. ":" .. (d > 0 and "+" or "") .. d end
			if d < 0 then lost = true end
		end
		for id, n in pairs(lastItems) do
			if not items[id] then
				changes[#changes + 1] = id .. ":-" .. n
				lost = true
			end
		end
		if lost and Deletable() then
			local before, after = lastItems[droppedItem] or 0, items[droppedItem] or 0
			if after < before then
				Add("delete", droppedItem, before - after)
				local prefix = droppedItem .. ":"
				for i = #changes, 1, -1 do
					if changes[i]:sub(1, #prefix) == prefix then table.remove(changes, i) end
				end
				lost = false
				for _, c in ipairs(changes) do if c:find(":%-") then lost = true end end
			end
			droppedItem = nil
		end
		local dm = money - lastMoney
		if #changes > 0 or dm ~= 0 then
			local ctx = Context(lost)
			if ctx == "use" then
				local rest = {}
				for _, c in ipairs(changes) do
					local id, d = c:match("^(%d+):(%-?%+?%d+)$")
					d = tonumber(d)
					if d and d < 0 then
						usedBuffer[tonumber(id)] = (usedBuffer[tonumber(id)] or 0) - d
					else
						rest[#rest + 1] = c
					end
				end
				if #rest > 0 or dm ~= 0 then Add("inv", "other", dm, table.concat(rest, ",")) end
			elseif ctx == "vendor" and #changes == 0 and dm < 0 then
				Add("repair", -dm)
				lastBill = RepairBill()
			elseif ctx then
				Add("inv", ctx, dm, table.concat(changes, ","))
			end
		end
	end
	lastItems, lastMoney = items, money
end

local ledgerQueued
local function QueueLedger()
	if ledgerQueued then return end
	ledgerQueued = true
	C_Timer.After(0.4, function()
		ledgerQueued = false
		Ledger()
	end)
end

------------------------------------------------------------------------------------------------
-- Loot windows

local names = {}      -- guid -> name, from targets, mouseover and nameplates
local nameOrder = {}
local function Remember(guid, name)
	if not name or names[guid] then return end
	names[guid] = name
	nameOrder[#nameOrder + 1] = guid
	if #nameOrder > 2000 then names[table.remove(nameOrder, 1)] = nil end
end
local looted = {}     -- guids already recorded (reopening a corpse shows what is left)
local lootedOrder = {}
local pendingLoot
local lastObject      -- name of the object or node last cast on

local function LootOpened()
	local sourceGUID
	local items = {}
	for i = 1, GetNumLootItems() do
		local guid = GetLootSourceInfo(i)
		sourceGUID = sourceGUID or guid
		local link = GetLootSlotLink(i)
		local _, _, qty = GetLootSlotInfo(i)
		local id = ID(link)
		if id then items[#items + 1] = id .. ":" .. (qty or 1) end
	end
	local gather = gatheredAt and GetTime() - gatheredAt < 5 and gathering
	-- a corpse is looted and later skinned: those are two different loots of one GUID
	local seen = sourceGUID and (sourceGUID .. (gather or ""))
	if seen and looted[seen] then return end
	if seen then
		looted[seen] = true
		lootedOrder[#lootedOrder + 1] = seen
		if #lootedOrder > 500 then looted[table.remove(lootedOrder, 1)] = nil end
	end
	local kind, id = ParseGUID(sourceGUID)
	local name = sourceGUID and names[sourceGUID]
	if not name and sourceGUID and UnitGUID("target") == sourceGUID then name = UnitName("target") end
	if not name and kind == "Creature" and id and KillValueDB and KillValueDB.learned and KillValueDB.learned[id] then
		name = KillValueDB.learned[id].name
	end
	if not name and kind == "GameObject" then
		local tip = GameTooltip:IsShown() and _G.GameTooltipTextLeft1 and _G.GameTooltipTextLeft1:GetText()
		name = lastObject or (tip ~= "" and tip or nil)
	end
	if gather then kind = gather end
	if kind == "Creature" and ns.LootedCorpse then ns.LootedCorpse(sourceGUID, name) end
	if GoldScoutDB.debug then print("|cffffd200Gold Scout debug|r loot window", kind or "?", name or "?", #items .. " items") end
	pendingLoot = { kind = kind or "?", id = id or 0, name = name or "?", zone = GetZoneText(), money = GetMoney(), items = items }
end

local function LootClosed()
	local p = pendingLoot
	pendingLoot = nil
	if not p then return end
	-- loot money arrives as the window closes
	C_Timer.After(0.5, function()
		Add("loot", p.kind, p.id, p.name, p.zone, math.max(0, GetMoney() - p.money), table.concat(p.items, ","))
	end)
end

------------------------------------------------------------------------------------------------

local CREATED = { Pattern(LOOT_ITEM_CREATED_SELF_MULTIPLE), Pattern(LOOT_ITEM_CREATED_SELF) }
local WON = Pattern(LOOT_ROLL_YOU_WON)
-- Roll choices come from chat ("You have selected Need for: ..."), never from hooks: hooking
-- Blizzard functions can taint actions only the Blizzard UI may do
local ROLLS = {}
for g, what in pairs({ LOOT_ROLL_NEED_SELF = "need", LOOT_ROLL_GREED_SELF = "greed", LOOT_ROLL_PASSED_SELF = "pass",
	LOOT_ROLL_PASSED_SELF_AUTO = "pass", LOOT_ROLL_DISENCHANT_SELF = "disenchant" }) do
	local p = Pattern(_G[g])
	if p then ROLLS[#ROLLS + 1] = { p, what } end
end

local OPEN = { MERCHANT_SHOW = "merchant", MAIL_SHOW = "mail", AUCTION_HOUSE_SHOW = "ah", TRADE_SHOW = "trade",
	TRAINER_SHOW = "trainer", TAXIMAP_OPENED = "taxi",
	BANKFRAME_OPENED = "bank", TRADE_SKILL_SHOW = "craft", CRAFT_SHOW = "craft", LOOT_OPENED = "loot" }
local CLOSE = { MERCHANT_CLOSED = "merchant", MAIL_CLOSED = "mail", AUCTION_HOUSE_CLOSED = "ah", TRADE_CLOSED = "trade",
	TRAINER_CLOSED = "trainer", TAXIMAP_CLOSED = "taxi",
	BANKFRAME_CLOSED = "bank", TRADE_SKILL_CLOSE = "craft", CRAFT_CLOSE = "craft", LOOT_CLOSED = "loot" }

local f = CreateFrame("Frame")
-- Never register COMBAT_LOG_EVENT_UNFILTERED: this client forbids it for addons and blames the addon
-- with an "only available to the Blizzard UI" popup. Kill counts come from KillValue instead.
local events = { "PLAYER_LOGIN", "PLAYER_LOGOUT", "BAG_UPDATE_DELAYED", "PLAYER_EQUIPMENT_CHANGED",
	"PLAYER_MONEY", "CHAT_MSG_LOOT", "QUEST_TURNED_IN", "PLAYER_LEVEL_UP", "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST", "UPDATE_INVENTORY_DURABILITY", "UNIT_SPELLCAST_SENT",
	"UPDATE_MOUSEOVER_UNIT", "NAME_PLATE_UNIT_ADDED",
	"UNIT_SPELLCAST_SUCCEEDED", "PLAYER_TARGET_CHANGED", "CURSOR_CHANGED", "LOOT_READY" }
for e in pairs(OPEN) do events[#events + 1] = e end
for e in pairs(CLOSE) do events[#events + 1] = e end
for _, e in ipairs(events) do pcall(f.RegisterEvent, f, e) end

f:SetScript("OnEvent", function(_, e, ...)
	if e == "PLAYER_LOGOUT" then
		FlushUsed()
		return
	end
	if e == "PLAYER_LOGIN" then
		C_Timer.NewTicker(60, FlushUsed)
		local name, realm = UnitFullName("player")
		key = name .. "-" .. (realm or GetRealmName() or "")
		GoldScoutDB = GoldScoutDB or {}
		GoldScoutDB.journal = GoldScoutDB.journal or {}
		log = GoldScoutDB.journal
		lastItems, lastMoney = Snapshot()
		C_Timer.After(3, function() lastBill = RepairBill() end)
		return
	end
	if not log then return end

	if OPEN[e] then open[OPEN[e]] = true end
	if CLOSE[e] then
		local what = CLOSE[e]
		-- changes caused by the window (the last mail, the last sale) can land a moment after it closes
		C_Timer.After(1, function() open[what] = nil end)
		if what == "bank" then C_Timer.After(1.2, function() lastItems, lastMoney = Snapshot() end) end
		if what == "loot" then Mark("loot", 2) end
	end

	if e == "LOOT_READY" or e == "LOOT_OPENED" then
		-- with auto loot the window can be emptied before LOOT_OPENED, so read it at LOOT_READY;
		-- the first of the two wins
		if not pendingLoot then
			local ok, err = pcall(LootOpened)
			if not ok and GoldScoutDB.debug then print("|cffffd200Gold Scout debug|r loot read failed:", err) end
		end
	elseif e == "LOOT_CLOSED" then
		LootClosed()
	elseif e == "PLAYER_TARGET_CHANGED" or e == "UPDATE_MOUSEOVER_UNIT" or e == "NAME_PLATE_UNIT_ADDED" then
		-- remember names of mobs seen, for loot from mobs that were never targeted
		local unit = (e == "PLAYER_TARGET_CHANGED" and "target") or (e == "UPDATE_MOUSEOVER_UNIT" and "mouseover") or ...
		local guid = unit and UnitGUID(unit)
		if guid and not UnitIsPlayer(unit) then Remember(guid, UnitName(unit)) end
	elseif e == "UNIT_SPELLCAST_SENT" then
		local unit, target = ...
		if unit == "player" and target and target ~= "" then lastObject = target end
	elseif e == "UNIT_SPELLCAST_SUCCEEDED" then
		local unit, _, spellID = ...
		if unit == "player" and open.craft then Mark("craft", 4) end
		local g = unit == "player" and ns.GatherKind and ns.GatherKind(spellID)
		if g and g ~= "open" then gathering, gatheredAt = g, GetTime() end
	elseif e == "CHAT_MSG_LOOT" then
		local msg = ...
		for _, p in ipairs(CREATED) do
			local link, n = msg:match(p)
			if link then
				Mark("craft", 4)
				Add("craft", ID(link) or 0, tonumber(n) or 1)
				break
			end
		end
		local won = WON and msg:match(WON)
		if won then Add("roll", "won", ID(won) or 0) end
		for _, r in ipairs(ROLLS) do
			local a, b = msg:match(r[1])
			local link = (a and a:find("|Hitem:") and a) or (b and b:find("|Hitem:") and b)
			if link then
				Mark("roll", 30)
				Add("roll", r[2], ID(link) or 0)
				break
			end
		end
	elseif e == "CURSOR_CHANGED" then
		local what, id = GetCursorInfo()
		if what == "item" then
			cursorItem = id
		elseif cursorItem then
			droppedItem, droppedAt, cursorItem = cursorItem, GetTime(), nil
			QueueLedger()
		end
	elseif e == "QUEST_TURNED_IN" then
		local questID, xp, money = ...
		Mark("quest", 3)
		Add("quest", questID or 0, xp or 0, money or 0)
	elseif e == "PLAYER_LEVEL_UP" then
		Add("level", (...))
	elseif e == "PLAYER_DEAD" then
		local map = C_Map.GetBestMapForUnit("player")
		local pos = map and C_Map.GetPlayerMapPosition(map, "player")
		local x, y = 0, 0
		if pos then x, y = pos:GetXY() end
		Add("death", GetZoneText(), math.floor(x * 1000) / 10, math.floor(y * 1000) / 10)
		Mark("death", 5)
		C_Timer.After(2, function() CheckWear("death") end)
	elseif e == "PLAYER_ALIVE" or e == "PLAYER_UNGHOST" then
		-- coming back at the spirit healer costs extra durability
		Mark("revive", 5)
		C_Timer.After(2, function() CheckWear(UnitIsGhost("player") and nil or "spirit") end)
	elseif e == "UPDATE_INVENTORY_DURABILITY" then
		if not wearQueued and not Recent("death") and not Recent("revive") then
			wearQueued = true
			C_Timer.After(1, function() wearQueued = false CheckWear() end)
		end
	end

	if e == "BAG_UPDATE_DELAYED" or e == "PLAYER_EQUIPMENT_CHANGED" or e == "PLAYER_MONEY" then
		QueueLedger()
	end
end)
