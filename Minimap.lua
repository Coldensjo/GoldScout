-- Gold Scout minimap button: left-click opens the overview, right-click toggles debug messages,
-- drag to move it around the minimap. Position and visibility are kept in GoldScoutDB.minimap.

local _, ns = ...

local RADIUS_PAD = 5

local button

local function Money(c)
	return GetCoinTextureString and GetCoinTextureString(math.floor(c or 0)) or tostring(c)
end

local function Place()
	local db = GoldScoutDB.minimap
	local angle = math.rad(db.angle or 200)
	local r = Minimap:GetWidth() / 2 + RADIUS_PAD
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * r, math.sin(angle) * r)
end

local function Drag()
	local mx, my = Minimap:GetCenter()
	local scale = Minimap:GetEffectiveScale()
	local cx, cy = GetCursorPosition()
	GoldScoutDB.minimap.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
	Place()
end

local function Tooltip(self)
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	GameTooltip:AddLine("Gold Scout")
	local total, listed, pending, n = 0, 0, 0, 0
	for _, c in pairs(GoldScoutDB.chars or {}) do
		n = n + 1
		total = total + (c.money or 0) + (c.mailMoney or 0)
		for _, s in pairs(c.ah and c.ah.owned or {}) do
			local _, q, unit, status = strsplit(":", s)
			local v = (tonumber(q) or 0) * (tonumber(unit) or 0)
			if tonumber(status) == 1 then pending = pending + v else listed = listed + v end
		end
	end
	GameTooltip:AddDoubleLine("Gold on " .. n .. " characters", Money(total), 1, 1, 1, 1, 1, 1)
	if listed > 0 then GameTooltip:AddDoubleLine("Listed on the auction house", Money(listed), 1, 1, 1, 1, 1, 1) end
	if pending > 0 then GameTooltip:AddDoubleLine("Sold, money on its way", Money(pending), 1, 1, 1, 1, 1, 1) end
	local nodes = GoldScoutDB.gather and #GoldScoutDB.gather or 0
	local events = GoldScoutDB.journal and #GoldScoutDB.journal or 0
	GameTooltip:AddDoubleLine("Nodes / events recorded", nodes .. " / " .. events, 0.7, 0.7, 0.7, 0.7, 0.7, 0.7)
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("|cffffd200Left-click|r open the overview", 0.8, 0.8, 0.8)
	GameTooltip:AddLine("|cffffd200Right-click|r debug messages " .. (GoldScoutDB.debug and "|cff40ff40on|r" or "off"), 0.8, 0.8, 0.8)
	GameTooltip:AddLine("|cffffd200Drag|r to move, |cffffd200/gs minimap|r to hide", 0.8, 0.8, 0.8)
	GameTooltip:Show()
end

local function Create()
	button = CreateFrame("Button", "GoldScoutMinimapButton", Minimap)
	button:SetSize(31, 31)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:RegisterForDrag("LeftButton")
	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	local bg = button:CreateTexture(nil, "BACKGROUND")
	bg:SetSize(20, 20)
	bg:SetPoint("TOPLEFT", 7, -5)
	bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")

	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetSize(17, 17)
	icon:SetPoint("TOPLEFT", 7, -6)
	icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_02")
	icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)

	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetSize(53, 53)
	border:SetPoint("TOPLEFT")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

	button:SetScript("OnClick", function(self, which)
		if which == "RightButton" then
			GoldScoutDB.debug = not GoldScoutDB.debug
			print("|cffffd200Gold Scout|r debug " .. (GoldScoutDB.debug and "on" or "off"))
			Tooltip(self)
		elseif ns.Toggle then
			ns.Toggle()
		end
	end)
	button:SetScript("OnDragStart", function(self)
		self:LockHighlight()
		self:SetScript("OnUpdate", Drag)
		GameTooltip:Hide()
	end)
	button:SetScript("OnDragStop", function(self)
		self:UnlockHighlight()
		self:SetScript("OnUpdate", nil)
	end)
	button:SetScript("OnEnter", Tooltip)
	button:SetScript("OnLeave", GameTooltip_Hide)

	Place()
	button:SetShown(not GoldScoutDB.minimap.hide)
end

function ns.ToggleMinimap()
	GoldScoutDB.minimap.hide = not GoldScoutDB.minimap.hide
	if button then button:SetShown(not GoldScoutDB.minimap.hide) end
	print("|cffffd200Gold Scout|r minimap button " .. (GoldScoutDB.minimap.hide and "hidden (/gs minimap shows it)" or "shown"))
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
	GoldScoutDB = GoldScoutDB or {}
	GoldScoutDB.minimap = GoldScoutDB.minimap or {}
	Create()
end)
