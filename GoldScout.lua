-- Gold Scout: records what each character has and can do, for offline gold planning.
-- Everything is written to GoldScoutDB on /reload, logout or exit.

local Container = C_Container or {}
local GetNumSlots = Container.GetContainerNumSlots or GetContainerNumSlots
local GetItemInfoC = Container.GetContainerItemInfo
local GetItemLinkC = Container.GetContainerItemLink or GetContainerItemLink

local key, char
local announced = {}

local function ID(link)
	return link and tonumber(link:match("item:(%d+)"))
end

-- The recipe list is rescanned on every update event; only mention it when the count changes
local function Announce(prof, n)
	if announced[prof] == n then return end
	announced[prof] = n
	print("|cffffd200Gold Scout|r saved " .. n .. " " .. prof .. " recipes")
end

local function Init()
	GoldScoutDB = GoldScoutDB or {}
	GoldScoutDB.chars = GoldScoutDB.chars or {}
	GoldScoutDB.vendors = GoldScoutDB.vendors or {}
	GoldScoutDB.trainers = GoldScoutDB.trainers or {}
	local name, realm = UnitFullName("player")
	key = name .. "-" .. (realm or GetRealmName() or "")
	char = GoldScoutDB.chars[key] or {}
	GoldScoutDB.chars[key] = char
	char.recipes = char.recipes or {}
end

local function Basics()
	char.name = UnitName("player")
	char.realm = GetRealmName()
	char.level = UnitLevel("player")
	char.class = select(2, UnitClass("player"))
	char.race = select(2, UnitRace("player"))
	char.faction = UnitFactionGroup("player")
	char.money = GetMoney()
	char.zone = GetZoneText()
	char.seen = time()
	local skills = {}
	if GetNumSkillLines then
		for i = 1, GetNumSkillLines() do
			local name, header, _, rank, _, _, max = GetSkillLineInfo(i)
			if name and not header then skills[name] = { rank, max } end
		end
	elseif GetProfessions then
		-- modern API: primary 1, primary 2, archaeology, fishing, cooking, first aid
		for _, idx in pairs({ GetProfessions() }) do
			local name, _, rank, max = GetProfessionInfo(idx)
			if name then skills[name] = { rank, max } end
		end
	end
	if next(skills) then char.skills = skills end
end

local function ReadBags(first, last)
	local items = {}
	for bag = first, last do
		for slot = 1, (GetNumSlots(bag) or 0) do
			local id, count
			if GetItemInfoC then
				local info = GetItemInfoC(bag, slot)
				if info then id, count = info.itemID, info.stackCount end
			else
				local link = GetItemLinkC(bag, slot)
				id, count = ID(link), select(2, GetContainerItemInfo(bag, slot))
			end
			if id then items[id] = (items[id] or 0) + (count or 1) end
		end
	end
	return items
end

local function Bags()
	char.bags = ReadBags(0, 4)
end

local function Bank()
	local bank = ReadBags(5, 11)
	for id, n in pairs(ReadBags(-1, -1)) do bank[id] = (bank[id] or 0) + n end
	char.bank = bank
	char.bankSeen = time()
end

local function Mail()
	local mail = {}
	local money = 0
	for i = 1, GetInboxNumItems() do
		local _, _, _, _, m = GetInboxHeaderInfo(i)
		money = money + (m or 0)
		for a = 1, (ATTACHMENTS_MAX_RECEIVE or 16) do
			local _, id, _, count = GetInboxItem(i, a)
			if id then mail[id] = (mail[id] or 0) + (count or 1) end
		end
	end
	char.mail = mail
	char.mailMoney = money
end

-- Recipes: "id:made=reagentID:n,reagentID:n" with the skill colour (difficulty)
local function SaveProfession(prof, n, info, link, numReagents, reagent, reagentLink)
	if not prof or n == 0 then return end
	local list = {}
	for i = 1, n do
		local name, kind = info(i)
		if kind ~= "header" and name then
			local r = {}
			for j = 1, numReagents(i) do
				local _, _, count = reagent(i, j)
				local rid = ID(reagentLink(i, j))
				if rid then r[#r + 1] = rid .. ":" .. (count or 1) end
			end
			local l = link(i)
			list[#list + 1] = (ID(l) or ("e:" .. (l and l:match("enchant:(%d+)") or name))) .. "|" .. name .. "|" .. (kind or "") .. "|" .. table.concat(r, ",")
		end
	end
	char.recipes[prof] = list
	Announce(prof, #list)
end

-- Modern (Dragonflight style) profession API, in case this client uses it
local function TradeSkillModern()
	local T = C_TradeSkillUI
	if not (T and T.GetAllRecipeIDs and T.GetBaseProfessionInfo) then return end
	local base = T.GetBaseProfessionInfo()
	local prof = base and base.professionName
	local ids = T.GetAllRecipeIDs()
	if not prof or not ids or #ids == 0 then return end
	local list = {}
	for _, rid in ipairs(ids) do
		local info = T.GetRecipeInfo(rid)
		if info and info.learned then
			local s = T.GetRecipeSchematic(rid, false)
			local r = {}
			for _, slot in ipairs(s and s.reagentSlotSchematics or {}) do
				local rr = slot.reagents and slot.reagents[1]
				if rr and rr.itemID then r[#r + 1] = rr.itemID .. ":" .. (slot.quantityRequired or 1) end
			end
			local made = s and s.outputItemID
			list[#list + 1] = (made or ("s:" .. rid)) .. "|" .. (info.name or "") .. "|" .. (info.relativeDifficulty or "") .. "|" .. table.concat(r, ",") .. "|" .. (s and s.quantityMin or 1)
		end
	end
	char.recipes[prof] = list
	char.profSkill = char.profSkill or {}
	char.profSkill[prof] = { base.skillLevel, base.maxSkillLevel }
	Announce(prof, #list)
end

local function TradeSkill()
	if not GetNumTradeSkills or GetNumTradeSkills() == 0 then return TradeSkillModern() end
	local prof = GetTradeSkillLine and GetTradeSkillLine()
	SaveProfession(prof, GetNumTradeSkills(), GetTradeSkillInfo, GetTradeSkillItemLink,
		GetTradeSkillNumReagents, GetTradeSkillReagentInfo, GetTradeSkillReagentItemLink)
end

local function Craft()
	if not GetNumCrafts then return end
	local prof = GetCraftDisplaySkillLine and GetCraftDisplaySkillLine() or (GetCraftName and GetCraftName())
	SaveProfession(prof, GetNumCrafts(), function(i)
		local name, _, kind = GetCraftInfo(i)
		return name, kind
	end, GetCraftItemLink, GetCraftNumReagents, GetCraftReagentInfo, GetCraftReagentItemLink)
end

local function Merchant()
	local npc = UnitName("npc") or "?"
	local v = { zone = GetZoneText(), sub = GetSubZoneText(), t = time(), faction = char.faction, items = {} }
	for i = 1, GetMerchantNumItems() do
		local price, qty, avail, extended
		if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
			local info = C_MerchantFrame.GetItemInfo(i)
			if info then price, qty, avail, extended = info.price, info.stackCount, info.numAvailable, info.hasExtendedCost end
		elseif GetMerchantItemInfo then
			local _
			_, _, price, qty, avail, _, _, extended = GetMerchantItemInfo(i)
		end
		local id = GetMerchantItemID and GetMerchantItemID(i) or ID(GetMerchantItemLink(i))
		if id then
			v.items[#v.items + 1] = id .. ":" .. (price or 0) .. ":" .. (qty or 1) .. ":" .. (avail or -1) .. (extended and ":x" or "")
		end
	end
	GoldScoutDB.vendors[npc .. "@" .. v.zone] = v
end

local function Trainer()
	if not GetNumTrainerServices then return end
	local npc = UnitName("npc") or "?"
	local list = {}
	for i = 1, GetNumTrainerServices() do
		local name, sub, kind = GetTrainerServiceInfo(i)
		if kind ~= "header" and name then
			local cost = GetTrainerServiceCost and GetTrainerServiceCost(i) or 0
			local skill, rank = GetTrainerServiceSkillReq and GetTrainerServiceSkillReq(i)
			local lvl = GetTrainerServiceLevelReq and GetTrainerServiceLevelReq(i)
			local made = GetTrainerServiceItemLink and ID(GetTrainerServiceItemLink(i))
			list[#list + 1] = name .. "|" .. (sub or "") .. "|" .. kind .. "|" .. (cost or 0) .. "|" .. (skill or "") .. ":" .. (rank or "") .. "|" .. (lvl or "") .. "|" .. (made or "")
		end
	end
	GoldScoutDB.trainers[npc .. "@" .. GetZoneText()] = { t = time(), by = key, list = list }
end

local f = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_MONEY", "BAG_UPDATE_DELAYED", "SKILL_LINES_CHANGED", "PLAYER_LEVEL_UP",
	"BANKFRAME_OPENED", "PLAYERBANKSLOTS_CHANGED", "MAIL_INBOX_UPDATE", "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE",
	"CRAFT_SHOW", "CRAFT_UPDATE", "TRADE_SKILL_LIST_UPDATE", "MERCHANT_SHOW", "TRAINER_SHOW" }) do
	pcall(f.RegisterEvent, f, e)
end
local bankOpen
f:SetScript("OnEvent", function(_, e)
	if e == "PLAYER_LOGIN" then Init() end
	if not char then return end
	if e == "BANKFRAME_OPENED" then bankOpen = true end
	if e == "BANKFRAME_OPENED" or (e == "PLAYERBANKSLOTS_CHANGED" and bankOpen) then Bank() end
	if e == "BAG_UPDATE_DELAYED" and bankOpen then Bank() end
	if e == "MAIL_INBOX_UPDATE" then Mail() end
	if e == "TRADE_SKILL_SHOW" or e == "TRADE_SKILL_UPDATE" or e == "TRADE_SKILL_LIST_UPDATE" then pcall(TradeSkill) end
	if e == "CRAFT_SHOW" or e == "CRAFT_UPDATE" then Craft() end
	if e == "MERCHANT_SHOW" then C_Timer.After(0.5, function() pcall(Merchant) end) end
	if e == "TRAINER_SHOW" then C_Timer.After(0.5, function() pcall(Trainer) end) end
	Basics()
	Bags()
end)
local close = CreateFrame("Frame")
close:RegisterEvent("BANKFRAME_CLOSED")
close:SetScript("OnEvent", function() bankOpen = false end)

-- If the game ever blocks something GoldScout did, say exactly what, instead of only the popup
local blocked = CreateFrame("Frame")
blocked:RegisterEvent("ADDON_ACTION_BLOCKED")
blocked:RegisterEvent("ADDON_ACTION_FORBIDDEN")
blocked:SetScript("OnEvent", function(_, e, addon, func)
	if addon ~= "GoldScout" then return end
	GoldScoutDB.blocked = GoldScoutDB.blocked or {}
	table.insert(GoldScoutDB.blocked, date("%Y-%m-%d %H:%M:%S") .. " " .. e .. " " .. tostring(func) .. " | " .. debugstack(2, 8, 0))
	print("|cffffd200Gold Scout|r was blocked from " .. tostring(func) .. ". Tell Claude; details are saved.")
end)

-- The overview window (Overview.lua) owns /goldscout and /gs
