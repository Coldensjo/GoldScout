-- Gold Scout raid log: who you grouped with, boss kills and wipes, everyone's loot rolls, who received
-- what, trades, and a snapshot of the guild roster. Shown on the Raid tab of the overview, where the
-- search box filters every view down to the people (or items) it names.
-- GoldScoutDB.raid, one line per event, "time|char|type|...":
--   group |start|party/raid|Name:CLASS,...        a group formed or joined (members at that moment)
--   group |end|party/raid|seconds                 it dissolved or you left
--   group |convert|raid                           the party became a raid
--   group |join|Name:CLASS                        someone joined while you were in it
--   group |leave|Name:CLASS                       someone left
--   boss  |kill/wipe|encounterID|name|zone|seconds|Name:CLASS,...|party/raid   who was in the group for it
--   roll  |who|need/greed/disenchant/pass|itemID  a roll choice (yours too)
--   rolled|who|need/greed/disenchant|itemID|value the dice
--   won   |who|itemID|value                       the winner (value blank when the client does not say)
--   loot  |who|itemID|n                           loot received while grouped (rolled or handed out)
--   trade |partner|gave itemID:n,...|got itemID:n,...|copper gave|copper got
-- GoldScoutDB.guilds[guild] = { realm, t, members = { [name] = { class, level, rank, last } } }

local MAX_LINES = 40000

local _, ns = ...

local key, me
local log

local function Add(...)
	if not log then return end
	log[#log + 1] = time() .. "|" .. key .. "|" .. table.concat({ ... }, "|")
	if #log > MAX_LINES then table.remove(log, 1) end
end

local function ID(link)
	return link and tonumber(link:match("item:(%d+)"))
end

-- A global string ("%s won: %s", "%1$s |3-3(%2$s) won: %3$s") into a Lua pattern and the order of
-- its arguments, so the captures come back as the format's arguments 1, 2, 3...
local function Pattern(fmt)
	if not fmt then return nil end
	fmt = fmt:gsub("|3%-%d+%((%%%d*%$?s)%)", "%1") -- declension wrappers keep their argument
	local order, n = {}, 0
	local p = fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
	p = p:gsub("%%(%d*)%%?%$?([sd])", function(pos, kind)
		n = n + 1
		order[n] = tonumber(pos) or n
		return kind == "s" and "(.-)" or "(%d+)"
	end)
	return { "^" .. p .. "$", order }
end

local function Match(msg, c)
	local caps = { msg:match(c[1]) }
	if #caps == 0 then return nil end
	local out = {}
	for i, v in ipairs(caps) do out[c[2][i] or i] = v end
	return unpack(out, 1, #caps)
end

------------------------------------------------------------------------------------------------
-- Who is in the group

local inGroup -- { kind = "party"/"raid", t, members = { name = class } }

local function Members()
	local list = {}
	local n = GetNumGroupMembers()
	if IsInRaid() then
		for i = 1, n do
			local name = UnitName("raid" .. i)
			local _, class = UnitClass("raid" .. i)
			if name and name ~= UNKNOWNOBJECT then list[name] = class or "?" end
		end
	else
		list[me] = select(2, UnitClass("player")) or "?"
		for i = 1, math.max(0, n - 1) do
			local name = UnitName("party" .. i)
			local _, class = UnitClass("party" .. i)
			if name and name ~= UNKNOWNOBJECT then list[name] = class or "?" end
		end
	end
	return list
end

local function MemberString(members)
	local parts = {}
	for name, class in pairs(members) do parts[#parts + 1] = name .. ":" .. class end
	table.sort(parts)
	return table.concat(parts, ",")
end

local function Roster()
	if not log then return end
	local grouped = IsInGroup()
	if grouped and not inGroup then
		inGroup = { kind = IsInRaid() and "raid" or "party", t = GetTime(), members = Members() }
		Add("group", "start", inGroup.kind, MemberString(inGroup.members))
	elseif not grouped and inGroup then
		Add("group", "end", inGroup.kind, math.floor(GetTime() - inGroup.t))
		inGroup = nil
	elseif grouped then
		local now = Members()
		local kind = IsInRaid() and "raid" or "party"
		if kind ~= inGroup.kind then
			-- a party became a raid: one group, the members carry over
			inGroup.kind = kind
			Add("group", "convert", kind)
		end
		for name, class in pairs(now) do
			if not inGroup.members[name] then Add("group", "join", name .. ":" .. class) end
		end
		for name, class in pairs(inGroup.members) do
			if not now[name] then Add("group", "leave", name .. ":" .. class) end
		end
		inGroup.members = now
	end
end

local rosterQueued
local function QueueRoster()
	if rosterQueued then return end
	rosterQueued = true
	C_Timer.After(1, function()
		rosterQueued = false
		Roster()
	end)
end

------------------------------------------------------------------------------------------------
-- Bosses: ENCOUNTER_START/END say how it went; BOSS_KILL is the fallback when there was no encounter

local encounters = {} -- id -> { name, t, members }
local ended = {}      -- id -> time of the last recorded end, so BOSS_KILL and ENCOUNTER_END log once

local function BossEnd(id, name, success)
	id = tonumber(id) or 0
	if ended[id] and GetTime() - ended[id] < 10 then return end
	ended[id] = GetTime()
	local enc = encounters[id]
	encounters[id] = nil
	local members = inGroup and inGroup.members or Members()
	if enc then
		for n, c in pairs(enc.members) do members[n] = members[n] or c end
	end
	Add("boss", success and "kill" or "wipe", id, name or (enc and enc.name) or "?", GetRealZoneText() or "?",
		enc and math.floor(GetTime() - enc.t) or 0, MemberString(members), IsInRaid() and "raid" or "party")
end

------------------------------------------------------------------------------------------------
-- Loot chat: rolls, dice, winners, who received what

local who = {} -- { pattern, handler }
local function On(fmt, handler)
	local p = Pattern(fmt)
	if p then who[#who + 1] = { p, handler } end
end

local function Chat(msg)
	for _, w in ipairs(who) do
		local a, b, c, d = Match(msg, w[1])
		if a then
			if w[2](a, b, c, d) ~= false then return end
		end
	end
end

-- The formats differ between clients ("%s won: %s", "%1$s |3-3(%2$s) won: %3$s (Need - %4$d)",
-- "[Loot]: %s (Need - %d) Won: %s"), so the captures are sorted out by what they look like: the item
-- link, the last number (the dice) and the first other text (the name)
local function Scan(...)
	local name, link, value
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		if type(v) == "string" then
			if v:find("|Hitem:") then link = link or v
			elseif v:match("^%d+$") then value = v
			elseif v ~= "" then name = name or v end
		end
	end
	return name, link, value
end

local function Choice(what, self)
	return function(...)
		local name, link = Scan(...)
		local id = ID(link)
		if not id then return false end
		Add("roll", self and me or name or "?", what, id)
	end
end
local function Dice(what)
	return function(...)
		local name, link, value = Scan(...)
		local id = ID(link)
		if not id then return false end
		Add("rolled", name or "?", what, id, value or "")
	end
end
local function Won(self)
	return function(...)
		local name, link, value = Scan(...)
		local id = ID(link)
		if not id then return false end
		Add("won", self and me or name or "?", id, value or "")
	end
end

-- Your own messages first: "You won: %s" also fits "%s won: %s" with "You" as the name. Then the
-- longer formats: "%s receives loot: %sx%d." also fits "%s receives loot: %s."
On(LOOT_ROLL_YOU_WON_NO_SPAM_NEED, Won(true))
On(LOOT_ROLL_YOU_WON_NO_SPAM_GREED, Won(true))
On(LOOT_ROLL_YOU_WON_NO_SPAM_DE, Won(true))
On(LOOT_ROLL_YOU_WON, Won(true))
On(LOOT_ROLL_NEED_SELF, Choice("need", true))
On(LOOT_ROLL_GREED_SELF, Choice("greed", true))
On(LOOT_ROLL_DISENCHANT_SELF, Choice("disenchant", true))
On(LOOT_ROLL_PASSED_SELF_AUTO, Choice("pass", true))
On(LOOT_ROLL_PASSED_SELF, Choice("pass", true))
On(LOOT_ROLL_ALL_PASSED, function() end) -- "Everyone passed on: %s" is not a person
On(LOOT_ROLL_WON_NO_SPAM_NEED, Won())
On(LOOT_ROLL_WON_NO_SPAM_GREED, Won())
On(LOOT_ROLL_WON_NO_SPAM_DE, Won())
On(LOOT_ROLL_WON, Won())
On(LOOT_ROLL_ROLLED_NEED, Dice("need"))
On(LOOT_ROLL_ROLLED_GREED, Dice("greed"))
On(LOOT_ROLL_ROLLED_DE, Dice("disenchant"))
On(LOOT_ROLL_NEED, Choice("need"))
On(LOOT_ROLL_GREED, Choice("greed"))
On(LOOT_ROLL_DISENCHANT, Choice("disenchant"))
On(LOOT_ROLL_PASSED_AUTO, Choice("pass"))
On(LOOT_ROLL_PASSED_AUTO_FEMALE, Choice("pass"))
On(LOOT_ROLL_PASSED, Choice("pass"))
On(LOOT_ITEM_SELF_MULTIPLE, function(link, n)
	local id = ID(link)
	if not id or not IsInGroup() then return false end
	Add("loot", me, id, n or 1)
end)
On(LOOT_ITEM_SELF, function(link)
	local id = ID(link)
	if not id or not IsInGroup() then return false end
	Add("loot", me, id, 1)
end)
On(LOOT_ITEM_MULTIPLE, function(name, link, n)
	local id = ID(link)
	if not id or not IsInGroup() then return false end
	Add("loot", name, id, n or 1)
end)
On(LOOT_ITEM, function(name, link)
	local id = ID(link)
	if not id or not IsInGroup() then return false end
	Add("loot", name, id, 1)
end)

------------------------------------------------------------------------------------------------
-- Trades: the window's contents are read at every change, and written when the client says it went through

local trade -- { partner, gave, got, moneyGave, moneyGot }

local function TradeRead()
	if not trade then return end
	local gave, got = {}, {}
	for i = 1, 6 do
		local link = GetTradePlayerItemLink and GetTradePlayerItemLink(i)
		local id = ID(link)
		if id then
			local _, _, n = GetTradePlayerItemInfo(i)
			gave[#gave + 1] = id .. ":" .. (n or 1)
		end
		link = GetTradeTargetItemLink and GetTradeTargetItemLink(i)
		id = ID(link)
		if id then
			local _, _, n = GetTradeTargetItemInfo(i)
			got[#got + 1] = id .. ":" .. (n or 1)
		end
	end
	trade.gave, trade.got = table.concat(gave, ","), table.concat(got, ",")
	trade.moneyGave = tonumber(GetPlayerTradeMoney and GetPlayerTradeMoney()) or 0
	trade.moneyGot = tonumber(GetTargetTradeMoney and GetTargetTradeMoney()) or 0
end

local function TradeDone()
	local t = trade
	trade = nil
	if not t then return end
	if t.gave == "" and t.got == "" and t.moneyGave == 0 and t.moneyGot == 0 then return end
	Add("trade", t.partner or "?", t.gave, t.got, t.moneyGave, t.moneyGot)
end

------------------------------------------------------------------------------------------------
-- Guild roster

local guildSavedAt = 0
local function SaveGuild()
	if not IsInGuild() or not GetNumGuildMembers then return end
	local guild = GetGuildInfo("player")
	if not guild then return end
	local n = GetNumGuildMembers()
	if n == 0 or GetTime() - guildSavedAt < 300 then return end
	guildSavedAt = GetTime()
	GoldScoutDB.guilds = GoldScoutDB.guilds or {}
	local members = {}
	for i = 1, n do
		local name, rank, _, level, _, _, _, _, online, _, class = GetGuildRosterInfo(i)
		if name then
			name = name:match("^[^-]+") or name
			local last = time()
			if not online and GetGuildRosterLastOnline then
				local y, m, d, h = GetGuildRosterLastOnline(i)
				if y then last = time() - (((y or 0) * 365 + (m or 0) * 30 + (d or 0)) * 86400 + (h or 0) * 3600) end
			end
			members[name] = { class = class or "?", level = level or 0, rank = rank or "", last = last }
		end
	end
	GoldScoutDB.guilds[guild] = { realm = GetRealmName(), t = time(), members = members }
end

------------------------------------------------------------------------------------------------

local f = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_LOGOUT", "GROUP_ROSTER_UPDATE", "GROUP_JOINED", "GROUP_LEFT",
	"ENCOUNTER_START", "ENCOUNTER_END", "BOSS_KILL", "CHAT_MSG_LOOT", "TRADE_SHOW", "TRADE_CLOSED",
	"TRADE_ACCEPT_UPDATE", "TRADE_PLAYER_ITEM_CHANGED", "TRADE_TARGET_ITEM_CHANGED", "TRADE_MONEY_CHANGED",
	"UI_INFO_MESSAGE", "GUILD_ROSTER_UPDATE", "PLAYER_GUILD_UPDATE" }) do
	pcall(f.RegisterEvent, f, e)
end

f:SetScript("OnEvent", function(_, e, ...)
	if e == "PLAYER_LOGIN" then
		local name, realm = UnitFullName("player")
		me = name
		key = name .. "-" .. (realm or GetRealmName() or "")
		GoldScoutDB = GoldScoutDB or {}
		GoldScoutDB.raid = GoldScoutDB.raid or {}
		log = GoldScoutDB.raid
		C_Timer.After(5, Roster)
		C_Timer.After(8, function()
			if IsInGuild() then
				if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() elseif GuildRoster then GuildRoster() end
			end
		end)
		return
	end
	if not log then return end

	if e == "PLAYER_LOGOUT" then
		if inGroup then Add("group", "end", inGroup.kind, math.floor(GetTime() - inGroup.t)) end
	elseif e == "GROUP_ROSTER_UPDATE" or e == "GROUP_JOINED" or e == "GROUP_LEFT" then
		QueueRoster()
	elseif e == "ENCOUNTER_START" then
		local id, name = ...
		encounters[tonumber(id) or 0] = { name = name, t = GetTime(), members = Members() }
	elseif e == "ENCOUNTER_END" then
		local id, name, _, _, success = ...
		BossEnd(id, name, success == 1 or success == true)
	elseif e == "BOSS_KILL" then
		local id, name = ...
		BossEnd(id, name, true)
	elseif e == "CHAT_MSG_LOOT" then
		Chat((...))
	elseif e == "TRADE_SHOW" then
		trade = { partner = UnitName("NPC") or UnitName("target") or "?", gave = "", got = "", moneyGave = 0, moneyGot = 0 }
	elseif e == "TRADE_ACCEPT_UPDATE" or e == "TRADE_PLAYER_ITEM_CHANGED" or e == "TRADE_TARGET_ITEM_CHANGED" or e == "TRADE_MONEY_CHANGED" then
		TradeRead()
	elseif e == "UI_INFO_MESSAGE" then
		local _, msg = ...
		if msg and (msg == ERR_TRADE_COMPLETE or msg:lower():find("trade complete", 1, true)) then TradeDone() end
	elseif e == "TRADE_CLOSED" then
		-- the completion message can land after the window closes
		C_Timer.After(2, function() trade = nil end)
	elseif e == "GUILD_ROSTER_UPDATE" or e == "PLAYER_GUILD_UPDATE" then
		SaveGuild()
	end
end)

------------------------------------------------------------------------------------------------
-- Overview tabs

local TABS = ns.TABS

local function Lines()
	return GoldScoutDB and GoldScoutDB.raid or {}
end

-- Raids and dungeon parties are shown apart: the filter picks which (GoldScoutDB.raidFilter)
local FILTERS = { { "raid", "Raids" }, { "party", "Dungeons" }, { "all", "Everything" } }
local function Filter()
	return GoldScoutDB and GoldScoutDB.raidFilter or "raid"
end
local function Pass(kind)
	local f = Filter()
	return f == "all" or kind == f
end

-- Every line with the kind of group it happened in (party or raid), from the group lines around it;
-- boss lines carry their own. fn(i, kind, t, by, type, a, b, c, d, e, g, h), newest first
local function Walk(fn)
	local lines = Lines()
	local kinds, kind = {}, "party"
	for i, line in ipairs(lines) do
		local _, _, k, a, b, _, _, _, _, h = strsplit("|", line)
		if k == "group" then
			if a == "start" or a == "convert" then kind = b
			elseif a == "end" then kinds[i] = kind kind = "party" end
		elseif k == "boss" and h and h ~= "" then
			kind = h
		end
		kinds[i] = kinds[i] or kind
	end
	for i = #lines, 1, -1 do
		fn(i, kinds[i], strsplit("|", lines[i]))
	end
end

local function Colored(name, class)
	local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	return color and ("|c" .. color.colorStr .. name .. "|r") or name
end

-- "Name:CLASS,Name:CLASS" -> sorted list of { name, class }
local function ParseMembers(s)
	local list = {}
	for part in (s or ""):gmatch("[^,]+") do
		local name, class = part:match("^([^:]+):?(.*)$")
		if name then list[#list + 1] = { name, class ~= "" and class or nil } end
	end
	table.sort(list, function(a, b) return a[1] < b[1] end)
	return list
end

local function MemberNames(list, plain)
	local parts = {}
	for _, m in ipairs(list) do parts[#parts + 1] = plain and m[1] or Colored(m[1], m[2]) end
	return table.concat(parts, plain and " " or ", ")
end

local function ItemList(s)
	local parts, plain = {}, {}
	for part in (s or ""):gmatch("[^,]+") do
		local id, n = part:match("(%d+):(%d+)")
		id, n = tonumber(id), tonumber(n) or 1
		if id then
			local label, name = ns.ItemName(id)
			parts[#parts + 1] = label .. (n > 1 and (" x" .. n) or "")
			plain[#plain + 1] = name
		end
	end
	return table.concat(parts, ", "), table.concat(plain, " ")
end

local function When(t) return date("%a %d %b %H:%M", tonumber(t) or 0) end
local function Short(who) return (who or ""):match("^[^-]+") or who end
local function Dur(s)
	s = tonumber(s) or 0
	if s < 60 then return s .. "s" end
	return math.floor(s / 60) .. "m " .. (s % 60) .. "s"
end

-- Classes seen for each name, from group lines, so names elsewhere can be colored
local classes
local function Classes()
	classes = {}
	for _, line in ipairs(Lines()) do
		local _, _, kind, a, b, c, _, _, members = strsplit("|", line)
		if kind == "group" and a == "start" then
			for _, m in ipairs(ParseMembers(c)) do classes[m[1]] = m[2] or classes[m[1]] end
		elseif kind == "group" and (a == "join" or a == "leave") then
			for _, m in ipairs(ParseMembers(b)) do classes[m[1]] = m[2] or classes[m[1]] end
		elseif kind == "boss" then
			for _, m in ipairs(ParseMembers(members)) do classes[m[1]] = m[2] or classes[m[1]] end
		end
	end
	for _, g in pairs(GoldScoutDB and GoldScoutDB.guilds or {}) do
		for name, m in pairs(g.members or {}) do classes[name] = classes[name] or m.class end
	end
	return classes
end
local function Name(n)
	n = Short(n)
	return Colored(n, classes and classes[n])
end

TABS.raid = {
	title = "Raid",
	tab = "Log",
	subs = { "raid", "bosses", "rolls", "handouts", "raiders", "guild" },
	-- a button at the right of the sub-tab row: which kind of group the views show
	filter = {
		label = function()
			for _, f in ipairs(FILTERS) do if f[1] == Filter() then return f[2] end end
			return FILTERS[1][2]
		end,
		click = function()
			for i, f in ipairs(FILTERS) do
				if f[1] == Filter() then
					GoldScoutDB.raidFilter = FILTERS[i % #FILTERS + 1][1]
					return
				end
			end
			GoldScoutDB.raidFilter = FILTERS[1][1]
		end,
	},
	cols = { { "When", 120 }, { "Recorded by", 100 }, { "Event", 920 } },
	build = function()
		Classes()
		local out = {}
		local lines = Lines()
		Walk(function(i, gkind, t, by, kind, a, b, c, d, e, g)
			if #out >= 2000 or not Pass(gkind) then return end
			local text, names = "", ""
			if kind == "group" then
				if a == "start" then
					local m = ParseMembers(c)
					text, names = "grouped (" .. (b or "?") .. "): " .. MemberNames(m), MemberNames(m, true)
				elseif a == "end" then text = "group over after " .. Dur(c)
				elseif a == "convert" then text = "the party became a raid"
				else
					local m = ParseMembers(b)
					text, names = (a == "join" and "|cff40ff40joined|r " or "|cffff8040left|r ") .. MemberNames(m), MemberNames(m, true)
				end
			elseif kind == "boss" then
				local m = ParseMembers(g)
				text = (a == "kill" and "|cff40ff40killed|r " or "|cffff4040wiped on|r ") .. (c or "?") .. " |cff808080" .. (d or "") .. ", " .. Dur(e) .. "|r with " .. MemberNames(m)
				names = (c or "") .. " " .. MemberNames(m, true)
			elseif kind == "roll" then
				local label, plain = ns.ItemName(tonumber(c) or 0)
				text, names = Name(a) .. " rolled " .. (b or "?") .. " on " .. label, (a or "") .. " " .. plain
			elseif kind == "rolled" then
				local label, plain = ns.ItemName(tonumber(c) or 0)
				text, names = Name(a) .. " rolled |cffffffff" .. (d or "?") .. "|r (" .. (b or "?") .. ") for " .. label, (a or "") .. " " .. plain
			elseif kind == "won" then
				local label, plain = ns.ItemName(tonumber(b) or 0)
				text, names = Name(a) .. " |cffffd200won|r " .. label .. ((c and c ~= "") and (" with " .. c) or ""), (a or "") .. " " .. plain
			elseif kind == "loot" then
				local label, plain = ns.ItemName(tonumber(b) or 0)
				text, names = Name(a) .. " received " .. label .. ((tonumber(c) or 1) > 1 and (" x" .. c) or ""), (a or "") .. " " .. plain
			elseif kind == "trade" then
				local gave, gp = ItemList(b)
				local got, rp = ItemList(c)
				local parts = {}
				if gave ~= "" or (tonumber(d) or 0) > 0 then parts[#parts + 1] = "gave " .. Name(a) .. " " .. gave .. ((tonumber(d) or 0) > 0 and (" " .. ns.Money(tonumber(d))) or "") end
				if got ~= "" or (tonumber(e) or 0) > 0 then parts[#parts + 1] = "got " .. got .. ((tonumber(e) or 0) > 0 and (" " .. ns.Money(tonumber(e))) or "") .. " from " .. Name(a) end
				text, names = "traded: " .. table.concat(parts, "; "), (a or "") .. " " .. gp .. " " .. rp
			else
				text = kind .. " " .. table.concat({ a or "", b or "", c or "" }, " ")
			end
			out[#out + 1] = {
				cols = { When(t), Short(by), text },
				search = (kind .. " " .. Short(by) .. " " .. names .. " " .. text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")):lower(),
			}
		end)
		return out, #lines .. " events recorded (newest 2000 shown, " .. Filter() .. "). Type a name in Search to see only what they were part of; the button at the right switches raids / dungeons"
	end,
}

TABS.bosses = {
	title = "Bosses",
	parent = "raid",
	cols = { { "When", 120 }, { "Boss", 180 }, { "Result", 60 }, { "Group", 60 }, { "Where", 150 }, { "Fight", 70 }, { "Size", 40 }, { "Who was there", 460 } },
	build = function()
		Classes()
		local out, kills, wipes = {}, 0, 0
		Walk(function(i, gkind, t, _, kind, a, _, c, d, e, g)
			if kind == "boss" and Pass(gkind) then
				local m = ParseMembers(g)
				if a == "kill" then kills = kills + 1 else wipes = wipes + 1 end
				out[#out + 1] = {
					cols = { When(t), c or "?", a == "kill" and "|cff40ff40kill|r" or "|cffff4040wipe|r", gkind, d or "", Dur(e), #m, MemberNames(m) },
					search = ((c or "") .. " " .. (a or "") .. " " .. gkind .. " " .. (d or "") .. " " .. MemberNames(m, true)):lower(),
				}
			end
		end)
		return out, kills .. " boss kills and " .. wipes .. " wipes recorded. Search a name to see the fights they were in"
	end,
}

-- One row per item rolled on: choices, dice and the winner, grouped by item within a few minutes
TABS.rolls = {
	title = "Rolls",
	parent = "raid",
	cols = { { "When", 120 }, { "Item", 220 }, { "Won by", 110 }, { "Need", 260 }, { "Greed / DE", 260 }, { "Passed", 170 } },
	build = function()
		Classes()
		local sessions, open = {}, {}
		local picked = {}
		Walk(function(i, gkind, t, _, kind, a, b, c, d)
			if Pass(gkind) and (kind == "roll" or kind == "rolled" or kind == "won") then picked[#picked + 1] = { tonumber(t) or 0, kind, a, b, c, d } end
		end)
		for j = #picked, 1, -1 do
			local t, kind, a, b, c, d = unpack(picked[j], 1, 6)
			local id
			if kind == "roll" or kind == "rolled" then id = tonumber(c) elseif kind == "won" then id = tonumber(b) end
			if id then
				local s = open[id]
				if s and (t - s.last > 300 or s.winner) then s = nil end
				if not s then
					s = { t = t, last = t, id = id, choice = {}, dice = {}, order = {} }
					open[id] = s
					sessions[#sessions + 1] = s
				end
				s.last = t
				if kind == "roll" then
					if not s.choice[a] then s.order[#s.order + 1] = a end
					s.choice[a] = b
				elseif kind == "rolled" then
					if not s.choice[a] then s.order[#s.order + 1] = a s.choice[a] = b end
					s.dice[a] = tonumber(d)
				else
					s.winner, s.winRoll = a, tonumber(c)
					if not s.choice[a] then s.order[#s.order + 1] = a s.choice[a] = "?" end
				end
			end
		end
		local out = {}
		for i = #sessions, 1, -1 do
			local s = sessions[i]
			local need, greed, pass = {}, {}, {}
			for _, who in ipairs(s.order) do
				local label = Name(who) .. (s.dice[who] and (" |cffffffff" .. s.dice[who] .. "|r") or "")
				local ch = s.choice[who]
				if ch == "need" then need[#need + 1] = label
				elseif ch == "greed" or ch == "disenchant" then greed[#greed + 1] = label .. (ch == "disenchant" and " |cff808080DE|r" or "")
				elseif ch == "pass" then pass[#pass + 1] = label end
			end
			local label, plain = ns.ItemName(s.id)
			out[#out + 1] = {
				cols = { When(s.t), label, s.winner and (Name(s.winner) .. (s.winRoll and (" |cffffffff" .. s.winRoll .. "|r") or "")) or "|cff808080-|r",
					table.concat(need, ", "), table.concat(greed, ", "), table.concat(pass, ", ") },
				item = s.id,
				search = (plain .. " " .. (s.winner or "") .. " " .. table.concat(s.order, " ")):lower(),
			}
		end
		return out, #sessions .. " items rolled on. Numbers are the dice; the roll choices come from chat, so only rolls made while you were there are known"
	end,
}

TABS.handouts = {
	title = "Loot given",
	parent = "raid",
	cols = { { "When", 120 }, { "From", 110 }, { "To", 110 }, { "What", 600 }, { "How", 200 } },
	build = function()
		Classes()
		local out = {}
		local lines = Lines()
		-- a win just before a receipt explains it
		local wonAt = {}
		for _, line in ipairs(lines) do
			local t, _, kind, a, b = strsplit("|", line)
			if kind == "won" then wonAt[(a or "") .. ":" .. (b or "")] = tonumber(t) end
		end
		Walk(function(i, gkind, t, by, kind, a, b, c, d, e)
			if not Pass(gkind) then return end
			if kind == "loot" then
				local label, plain = ns.ItemName(tonumber(b) or 0)
				local w = wonAt[(a or "") .. ":" .. (b or "")]
				local how = (w and math.abs((tonumber(t) or 0) - w) < 120) and "won the roll" or "handed out / looted"
				out[#out + 1] = {
					cols = { When(t), "|cff808080loot|r", Name(a), label .. ((tonumber(c) or 1) > 1 and (" x" .. c) or ""), how },
					item = tonumber(b), search = ((a or "") .. " " .. plain .. " " .. how):lower(),
				}
			elseif kind == "trade" then
				local gave, gp = ItemList(b)
				local got, rp = ItemList(c)
				local mg, mr = tonumber(d) or 0, tonumber(e) or 0
				if gave ~= "" or mg > 0 then
					out[#out + 1] = {
						cols = { When(t), Name(by), Name(a), gave .. (mg > 0 and ((gave ~= "" and ", " or "") .. ns.Money(mg)) or ""), "trade" },
						search = (Short(by) .. " " .. (a or "") .. " " .. gp .. " trade"):lower(),
					}
				end
				if got ~= "" or mr > 0 then
					out[#out + 1] = {
						cols = { When(t), Name(a), Name(by), got .. (mr > 0 and ((got ~= "" and ", " or "") .. ns.Money(mr)) or ""), "trade" },
						search = (Short(by) .. " " .. (a or "") .. " " .. rp .. " trade"):lower(),
					}
				end
			end
		end)
		return out, #out .. " hand-overs: loot received while grouped (chat says who got what, not who assigned it) and trades"
	end,
}

-- Everything per person, from every line they appear in
local function People()
	Classes()
	local people = {}
	local function P(name)
		name = Short(name)
		local p = people[name]
		if not p then
			p = { name = name, groups = 0, kills = 0, wipes = 0, won = 0, need = 0, greed = 0, pass = 0, received = 0, gaveMe = 0, gotMe = 0, last = 0, first = math.huge }
			people[name] = p
		end
		return p
	end
	local function Seen(p, t)
		if t > p.last then p.last = t end
		if t < p.first then p.first = t end
	end
	Walk(function(i, gkind, t, by, kind, a, b, c, d, e, g)
		if not Pass(gkind) then return end
		t = tonumber(t) or 0
		if kind == "group" and a == "start" then
			for _, m in ipairs(ParseMembers(c)) do local p = P(m[1]) p.groups = p.groups + 1 Seen(p, t) end
		elseif kind == "group" and a == "join" then
			for _, m in ipairs(ParseMembers(b)) do local p = P(m[1]) p.groups = p.groups + 1 Seen(p, t) end
		elseif kind == "boss" then
			for _, m in ipairs(ParseMembers(g)) do
				local p = P(m[1])
				if a == "kill" then p.kills = p.kills + 1 else p.wipes = p.wipes + 1 end
				Seen(p, t)
			end
		elseif kind == "roll" then
			local p = P(a)
			if b == "need" then p.need = p.need + 1 elseif b == "pass" then p.pass = p.pass + 1 else p.greed = p.greed + 1 end
			Seen(p, t)
		elseif kind == "won" then
			local p = P(a) p.won = p.won + 1 Seen(p, t)
		elseif kind == "loot" then
			local p = P(a) p.received = p.received + 1 Seen(p, t)
		elseif kind == "trade" then
			local p = P(a)
			if (b and b ~= "") or (tonumber(d) or 0) > 0 then p.gotMe = p.gotMe + 1 end
			if (c and c ~= "") or (tonumber(e) or 0) > 0 then p.gaveMe = p.gaveMe + 1 end
			Seen(p, t)
		end
	end)
	return people
end

local function Guildie(name)
	for guild, g in pairs(GoldScoutDB and GoldScoutDB.guilds or {}) do
		if g.members and g.members[name] then return guild, g.members[name] end
	end
end

TABS.raiders = {
	title = "Raiders",
	parent = "raid",
	sortable = true, sortCol = 3, sortDesc = true,
	cols = { { "Name", 120 }, { "Guild", 140 }, { "Groups", 60 }, { "Kills", 50 }, { "Wipes", 50 }, { "Won", 50 }, { "Need", 50 }, { "Greed", 50 }, { "Received", 70 }, { "Last seen", 100 } },
	build = function()
		local people = People()
		local out = {}
		for name, p in pairs(people) do
			local guild = Guildie(name)
			out[#out + 1] = {
				cols = { Name(name), guild or "", p.groups, p.kills, p.wipes, p.won, p.need, p.greed, p.received, ns.Ago(p.last > 0 and p.last or nil) },
				keys = { name:lower(), (guild or ""):lower(), p.groups, p.kills, p.wipes, p.won, p.need, p.greed, p.received, p.last },
				search = (name .. " " .. (guild or "")):lower(),
				click = function() if ns.SearchFor then ns.SearchFor(name, "raid") end end,
			}
		end
		return out, #out .. " people grouped with (" .. Filter() .. "). Click a column to sort, click a person to see their log"
	end,
}

TABS.guild = {
	title = "Guild",
	parent = "raid",
	sortable = true, sortCol = 3, sortDesc = true,
	cols = { { "Name", 120 }, { "Rank", 110 }, { "Level", 50 }, { "Last online", 90 }, { "Groups", 60 }, { "Kills", 50 }, { "Wipes", 50 }, { "Won", 50 }, { "Received", 70 }, { "Guild", 180 } },
	build = function()
		local people = People()
		local out, n = {}, 0
		for guild, g in pairs(GoldScoutDB and GoldScoutDB.guilds or {}) do
			for name, m in pairs(g.members or {}) do
				n = n + 1
				local p = people[name] or { groups = 0, kills = 0, wipes = 0, won = 0, received = 0 }
				out[#out + 1] = {
					cols = { Colored(name, m.class), m.rank or "", m.level or 0, ns.Ago(m.last), p.groups, p.kills, p.wipes, p.won, p.received, guild },
					keys = { name:lower(), (m.rank or ""):lower(), m.level or 0, m.last or 0, p.groups, p.kills, p.wipes, p.won, p.received, guild:lower() },
					search = (name .. " " .. (m.rank or "") .. " " .. guild):lower(),
					click = function() if ns.SearchFor then ns.SearchFor(name, "raid") end end,
				}
			end
		end
		if n == 0 then return out, "No guild roster saved yet: it is read when you log in while in a guild" end
		return out, n .. " guild members, with what they did in groups with you. Click a column to sort, click a member to see their log"
	end,
}
