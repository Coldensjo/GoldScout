-- Gold Scout auction tracking: what each character posts, what is listed, sold (money pending) and
-- paid out, what it bought, and what expired or was cancelled. Stored per character in
-- GoldScoutDB.chars[key].ah:
--   posts   { "time:itemID:qty:unitPrice:deposit" }
--   owned   { [auctionID] = "itemID:qty:unitPrice:status:secondsLeft:bid" } (last seen, status 1 = sold)
--   ownedAt time the owned list was read
--   sales   { "time|itemName|qty|gross|cut|deposit" } from "Auction successful" invoices
--   buys    { "time|itemName|qty|price" } from "Auction won" invoices
--   ended   { "time|itemName|kind" } kind = expired or cancelled

local AH = C_AuctionHouse
local MAX_LOG = 20000 -- the history is meant to outlive the beta, keep plenty
local MAIL_DAYS = 30

local ah

local function Log(list, entry)
	list[#list + 1] = entry
	if #list > MAX_LOG then table.remove(list, 1) end
end

local function Init()
	local name, realm = UnitFullName("player")
	local key = name .. "-" .. (realm or GetRealmName() or "")
	GoldScoutDB = GoldScoutDB or {}
	GoldScoutDB.chars = GoldScoutDB.chars or {}
	local char = GoldScoutDB.chars[key]
	if not char then
		char = {}
		GoldScoutDB.chars[key] = char
	end
	char.ah = char.ah or {}
	ah = char.ah
	for _, k in ipairs({ "posts", "owned", "sales", "buys", "ended", "seenMail" }) do
		ah[k] = ah[k] or {}
	end
	-- repair sales saved by the first version: double entries, and the count saved as the price
	if not ah.salesFixed then
		local kept, seen = {}, {}
		for _, line in ipairs(ah.sales) do
			local t, name, q, gross, cut, dep = strsplit("|", line)
			t, q, gross, cut = tonumber(t), tonumber(q) or 1, tonumber(gross) or 0, tonumber(cut) or 0
			local k = name .. "|" .. q .. "|" .. cut .. "|" .. (dep or "")
			if not (seen[k] and math.abs(seen[k] - t) < 3 * 3600) then
				seen[k] = t
				if gross <= q and cut > 0 then gross = math.floor(cut * 20 + 0.5) end
				kept[#kept + 1] = table.concat({ t, name, q, gross, cut, dep or 0 }, "|")
			end
		end
		ah.sales = kept
		ah.salesFixed = true
	end
end

------------------------------------------------------------------------------------------------
-- Posting. No hooks on the auction house functions: hooking them taints posting, which the
-- Blizzard UI must do securely. A post is an auction that shows up in the owned list with (almost)
-- a full duration left.

-- this client (classic) lists auctions for 2, 8 or 24 hours; retail's 12/24/48 never matched a post
local DURATIONS = { 2, 8, 24 }
local FRESH = 15 * 60

local function PostedHours(left)
	for i, h in ipairs(DURATIONS) do
		if left <= h * 3600 and left > h * 3600 - FRESH then return h, i end
	end
end

local function EstimateDeposit(id, qty, hours, index)
	if AH.CalculateCommodityDeposit then
		local ok, d = pcall(AH.CalculateCommodityDeposit, id, index, qty)
		if ok and d and d > 0 then return d end
	end
	local sell = select(11, C_Item.GetItemInfo(id)) or 0
	return math.floor(sell * qty * 0.15 * hours / 12)
end

------------------------------------------------------------------------------------------------
-- Owned auctions: active (status 0) and sold, waiting for the money (status 1)

local function ReadOwned()
	if not ah or not AH.GetNumOwnedAuctions then return end
	local owned = {}
	for i = 1, AH.GetNumOwnedAuctions() do
		local a = AH.GetOwnedAuctionInfo(i)
		if a and a.itemKey and a.itemKey.itemID then
			owned[a.auctionID] = table.concat({
				a.itemKey.itemID, a.quantity or 1, a.buyoutAmount or 0, a.status or 0, a.timeLeftSeconds or 0, a.bidAmount or 0,
			}, ":")
		end
	end
	if ah.ownedAt then
		for auctionID, line in pairs(owned) do
			if not ah.owned[auctionID] then
				local id, q, unit, status, left = strsplit(":", line)
				local hours, index = PostedHours(tonumber(left) or 0)
				if tonumber(status) == 0 and hours then
					id, q = tonumber(id), tonumber(q)
					Log(ah.posts, time() .. ":" .. id .. ":" .. q .. ":" .. unit .. ":" .. EstimateDeposit(id, q, hours, index))
				end
			end
		end
	end
	ah.owned = owned
	ah.ownedAt = time()
end

local function QueryOwned()
	if AH.QueryOwnedAuctions then pcall(AH.QueryOwnedAuctions, {}) end
end

------------------------------------------------------------------------------------------------
-- Mail: invoices are the exact record of sales and purchases

-- "Auction expired: %s" -> "^Auction expired: (.+)$"
local function SubjectPattern(fmt)
	if not fmt then return nil end
	return "^" .. fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%s", "(.+)") .. "$"
end
local EXPIRED = SubjectPattern(AUCTION_EXPIRED_MAIL_SUBJECT)
local CANCELLED = SubjectPattern(AUCTION_REMOVED_MAIL_SUBJECT)

-- A mail is recognised again on the next visit by its signature and its arrival time
-- (estimated from the days it has left, so allow some drift)
local function Seen(sig, arrived)
	local t = ah.seenMail[sig]
	if t and math.abs(t - arrived) < 3 * 3600 then return true end
	ah.seenMail[sig] = arrived
	return false
end

local function ReadMail()
	if not ah then return end
	local now = time()
	for i = 1, GetInboxNumItems() do
		local _, _, _, subject, money, _, daysLeft = GetInboxHeaderInfo(i)
		local arrived = math.floor(now - (MAIL_DAYS - (daysLeft or MAIL_DAYS)) * 86400)
		local kind, itemName, _, bid, buyout, deposit, cut, _, _, _, count = GetInboxInvoiceInfo(i)
		if kind == "seller" then
			-- In this client the bid/buyout fields of the invoice do not hold the price (they repeat the
			-- count), but the auction house cut does: it is 5% of the sale price.
			count = count or 1
			local gross = (buyout and buyout > count and buyout) or (bid and bid > count and bid) or math.floor((cut or 0) * 20 + 0.5)
			-- the mail's money is taken (e.g. by a mail addon) between reads, so it is not part of the key
			local sig = "s|" .. (itemName or "?") .. "|" .. count .. "|" .. (cut or 0) .. "|" .. (deposit or 0)
			if not Seen(sig, arrived) then
				Log(ah.sales, arrived .. "|" .. (itemName or "?") .. "|" .. count .. "|" .. gross .. "|" .. (cut or 0) .. "|" .. (deposit or 0))
			end
		elseif kind == "buyer" then
			local price = (buyout and buyout > 0 and buyout) or bid or 0
			local sig = "b|" .. (itemName or "?") .. "|" .. (count or 1) .. "|" .. price
			if not Seen(sig, arrived) then
				Log(ah.buys, arrived .. "|" .. (itemName or "?") .. "|" .. (count or 1) .. "|" .. price)
			end
		elseif subject then
			local name = EXPIRED and subject:match(EXPIRED)
			local how = "expired"
			if not name and CANCELLED then
				name = subject:match(CANCELLED)
				how = "cancelled"
			end
			if name and not Seen("e|" .. name .. "|" .. how, arrived) then
				Log(ah.ended, arrived .. "|" .. name .. "|" .. how)
			end
		end
	end
end

------------------------------------------------------------------------------------------------

local f = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "AUCTION_HOUSE_SHOW", "OWNED_AUCTIONS_UPDATED", "AUCTION_HOUSE_AUCTION_CREATED",
	"AUCTION_CANCELED", "AUCTION_HOUSE_NEW_BID_RECEIVED", "MAIL_INBOX_UPDATE" }) do
	pcall(f.RegisterEvent, f, e)
end
local queued
f:SetScript("OnEvent", function(_, e)
	if e == "PLAYER_LOGIN" then
		Init()
	elseif not ah then
		return
	elseif e == "OWNED_AUCTIONS_UPDATED" then
		ReadOwned()
	elseif e == "MAIL_INBOX_UPDATE" then
		pcall(ReadMail)
	elseif not queued then
		-- AH opened, posted, cancelled or bid on: refresh the owned list once things settle
		queued = true
		C_Timer.After(1, function() queued = false QueryOwned() end)
	end
end)
