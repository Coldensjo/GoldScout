-- Gold Scout gathering and session tracking.
--
-- GoldScoutDB.gather: one line per node gathered (herbs, ore, skins, fishing, opened objects):
--   "time|char|kind|node|mapID|x|y|skill|itemID:n,itemID:n"
--   x, y are map percentages; skill is the gathering skill at that moment.
-- GoldScoutDB.chars[key].sessions: one entry per login, money by source and items looted:
--   { start, stop, zone, money = { loot, vendor, mail, quest, ah, training, travel, other }, items = { [id] = n } }

local MAX_GATHER = 50000
local MAX_SESSIONS = 500

-- spell name -> kind; names are localized by the client, so compare against the spell IDs' names
local GATHER_SPELLS = {
	herb = { 2366, 2368, 3570, 11993 },
	mining = { 2575, 2576, 3564, 10248 },
	skinning = { 8613, 8617, 8618, 10768 },
	fishing = { 7620, 7731, 7732, 18248 },
	open = { 3365, 6247, 6477, 6478, 21651, 22810 },
}
local SKILL = { herb = "Herbalism", mining = "Mining", skinning = "Skinning", fishing = "Fishing" }

local _, ns = ...

local spellKind = {}
local function SpellName(id)
	if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(id) end
	return (GetSpellInfo(id))
end
-- English names as a fallback, in case this client uses other spell IDs
local NAMES = { ["Herb Gathering"] = "herb", ["Herbalism"] = "herb", ["Mining"] = "mining", ["Skinning"] = "skinning",
	["Fishing"] = "fishing", ["Opening"] = "open" }

local function BuildSpells()
	for name, kind in pairs(NAMES) do spellKind[name] = kind end
	for kind, ids in pairs(GATHER_SPELLS) do
		for _, id in ipairs(ids) do
			spellKind[id] = kind
			local name = SpellName(id)
			if name then spellKind[name] = kind end
		end
	end
end

local key, char, session

-- Journal.lua asks this to tell gathering loot apart from mobs and chests
function ns.GatherKind(spellID)
	return spellKind[spellID] or spellKind[SpellName(spellID) or ""]
end

local function Debug(...)
	if GoldScoutDB and GoldScoutDB.debug then print("|cffffd200Gold Scout debug|r", ...) end
end
local pending, lastTarget

local function Position()
	local map = C_Map.GetBestMapForUnit("player")
	if not map then return 0, 0, 0 end
	local pos = C_Map.GetPlayerMapPosition(map, "player")
	if not pos then return map, 0, 0 end
	local x, y = pos:GetXY()
	return map, math.floor(x * 1000 + 0.5) / 10, math.floor(y * 1000 + 0.5) / 10
end

local function SkillRank(kind)
	local name = SKILL[kind]
	local s = name and char.skills and char.skills[name]
	return s and s[1] or 0
end

------------------------------------------------------------------------------------------------
-- Loot messages: everything you receive goes through these, including bonus items that never
-- show in the loot window

local function Pattern(fmt)
	if not fmt then return nil end
	return "^" .. fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%s", "(.+)"):gsub("%%d", "(%%d+)") .. "$"
end
local SELF_LOOT = {}
for _, g in ipairs({ "LOOT_ITEM_SELF_MULTIPLE", "LOOT_ITEM_PUSHED_SELF_MULTIPLE", "LOOT_ITEM_SELF", "LOOT_ITEM_PUSHED_SELF",
	"LOOT_ITEM_CREATED_SELF_MULTIPLE", "LOOT_ITEM_CREATED_SELF" }) do
	local p = Pattern(_G[g])
	if p then SELF_LOOT[#SELF_LOOT + 1] = { p, g:find("CREATED") ~= nil } end
end

local function ParseLoot(msg)
	for _, p in ipairs(SELF_LOOT) do
		local link, n = msg:match(p[1])
		if link then
			local id = tonumber(link:match("item:(%d+)"))
			return id, tonumber(n) or 1, p[2]
		end
	end
end

-- The node's name as the tooltip shows it while the cursor is on it (gathering by click)
local function TooltipNode()
	if not GameTooltip:IsShown() or GameTooltip:GetOwner() ~= UIParent then return nil end
	local line = _G.GameTooltipTextLeft1
	local text = line and line:GetText()
	return text and text ~= "" and text or nil
end

-- Herb nodes are named like the herb they give: the largest stack is the node
local function NodeFromLoot(kind, items)
	if kind ~= "herb" then return nil end
	local best, most
	for id, n in pairs(items) do
		if not most or n > most then best, most = id, n end
	end
	return best and C_Item.GetItemInfo(best) or nil
end
ns.NodeFromLoot = NodeFromLoot

local function Finish()
	if not pending then return end
	local p = pending
	pending = nil
	local items = {}
	for id, n in pairs(p.items) do items[#items + 1] = id .. ":" .. n end
	if #items == 0 then
		Debug("gathered", p.node or "?", "but no loot was seen")
		return
	end
	p.node = p.node or NodeFromLoot(p.kind, p.items)
	Debug("logged", p.kind, p.node or "?", table.concat(items, ","))
	local log = GoldScoutDB.gather
	log[#log + 1] = table.concat({ p.t, key, p.kind, p.node or "?", p.map, p.x, p.y, p.skill, table.concat(items, ",") }, "|")
	if #log > MAX_GATHER then table.remove(log, 1) end
end

------------------------------------------------------------------------------------------------
-- Money by source

local context = {}
local lastMoney
local recentQuest = 0

local function Source()
	if context.merchant then return "vendor" end
	if context.mail then return "mail" end
	if context.ah then return "ah" end
	if context.loot then return "loot" end
	if context.trainer then return "training" end
	if context.taxi then return "travel" end
	if GetTime() - recentQuest < 3 then return "quest" end
	return "other"
end

local function Money()
	local now = GetMoney()
	if lastMoney and session then
		local delta = now - lastMoney
		if delta ~= 0 then
			local src = Source()
			session.money[src] = (session.money[src] or 0) + delta
		end
		session.stop = time()
	end
	lastMoney = now
end

local function StartSession()
	char.sessions = char.sessions or {}
	session = { start = time(), stop = time(), zone = GetZoneText(), money = {}, items = {}, startMoney = GetMoney() }
	table.insert(char.sessions, session)
	if #char.sessions > MAX_SESSIONS then table.remove(char.sessions, 1) end
	lastMoney = GetMoney()
end

------------------------------------------------------------------------------------------------

local f = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "UNIT_SPELLCAST_SENT", "UNIT_SPELLCAST_SUCCEEDED", "CHAT_MSG_LOOT", "LOOT_CLOSED",
	"LOOT_OPENED", "PLAYER_MONEY", "MERCHANT_SHOW", "MERCHANT_CLOSED", "MAIL_SHOW", "MAIL_CLOSED",
	"AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "TRAINER_SHOW", "TRAINER_CLOSED", "TAXIMAP_OPENED", "TAXIMAP_CLOSED",
	"QUEST_TURNED_IN", "QUEST_COMPLETE" }) do
	pcall(f.RegisterEvent, f, e)
end

local OPEN = { MERCHANT_SHOW = "merchant", MAIL_SHOW = "mail", AUCTION_HOUSE_SHOW = "ah", TRAINER_SHOW = "trainer",
	TAXIMAP_OPENED = "taxi", LOOT_OPENED = "loot" }
local CLOSE = { MERCHANT_CLOSED = "merchant", MAIL_CLOSED = "mail", AUCTION_HOUSE_CLOSED = "ah", TRAINER_CLOSED = "trainer",
	TAXIMAP_CLOSED = "taxi" }

f:SetScript("OnEvent", function(_, e, ...)
	if e == "PLAYER_LOGIN" then
		local name, realm = UnitFullName("player")
		key = name .. "-" .. (realm or GetRealmName() or "")
		GoldScoutDB = GoldScoutDB or {}
		GoldScoutDB.chars = GoldScoutDB.chars or {}
		GoldScoutDB.gather = GoldScoutDB.gather or {}
		GoldScoutDB.chars[key] = GoldScoutDB.chars[key] or {}
		char = GoldScoutDB.chars[key]
		BuildSpells()
		StartSession()
		return
	end
	if not char then return end

	if OPEN[e] then
		context[OPEN[e]] = true
	elseif CLOSE[e] then
		-- money from closing a window (e.g. the last mail) can arrive a moment later
		local what = CLOSE[e]
		C_Timer.After(1, function() context[what] = nil end)
	end

	if e == "UNIT_SPELLCAST_SENT" then
		local unit, target, _, spellID = ...
		if unit == "player" and (spellKind[spellID] or spellKind[SpellName(spellID) or ""]) then
			-- never keep the previous node's name: a cast without a target falls back to the tooltip
			lastTarget = (target and target ~= "" and target) or TooltipNode()
		end
	elseif e == "UNIT_SPELLCAST_SUCCEEDED" then
		local unit, _, spellID = ...
		local kind = unit == "player" and (spellKind[spellID] or spellKind[SpellName(spellID) or ""])
		if unit == "player" then Debug("spell", spellID, SpellName(spellID) or "?", kind or "not a gather") end
		if kind then
			Finish()
			local node = lastTarget or TooltipNode()
			lastTarget = nil
			local map, x, y = Position()
			pending = { t = time(), kind = kind, node = node, map = map, x = x, y = y, skill = SkillRank(kind), items = {} }
			-- a node whose loot never arrives (full bags, interrupted) is dropped after a while
			local this = pending
			C_Timer.After(kind == "fishing" and 40 or 20, function() if pending == this then Finish() end end)
		end
	elseif e == "CHAT_MSG_LOOT" then
		local id, n, created = ParseLoot((...))
		Debug("loot", id or "unparsed: " .. tostring((...)), n or "", pending and "-> node" or "")
		if id and not created then
			if session then session.items[id] = (session.items[id] or 0) + n end
			if pending then pending.items[id] = (pending.items[id] or 0) + n end
		end
	elseif e == "LOOT_CLOSED" then
		C_Timer.After(1, function() context.loot = nil end)
		-- bonus items can be pushed just after the window closes
		local this = pending
		if this then C_Timer.After(2, function() if pending == this then Finish() end end) end
	elseif e == "QUEST_TURNED_IN" or e == "QUEST_COMPLETE" then
		recentQuest = GetTime()
	elseif e == "PLAYER_MONEY" then
		Money()
	end
end)
