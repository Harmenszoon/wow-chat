-- Chat: small in-place enhancements to Blizzard's chat frames.

-- Frames Blizzard keeps re-showing are moved under a parent that is never
-- shown. It sits under UIParent so they keep their scale, which keeps the
-- toasts anchored to the button column where they were.
local hidden = CreateFrame("Frame", nil, UIParent)
hidden:Hide()

local HISTORY_LINES = 1000 -- Blizzard keeps 128 per window

local EDIT_BOX_ART = { "Left", "Mid", "Right", "FocusLeft", "FocusMid", "FocusRight" }

-- How the sender's name leads the line, per chat event. Events not listed
-- keep Blizzard's own line.
local NAME_FORMAT = {
	CHAT_MSG_WHISPER_INFORM = CHAT_WHISPER_INFORM_GET, -- "To %s: "
	CHAT_MSG_RAID_WARNING = CHAT_RAID_WARNING_GET, -- "[Raid Warning] %s: "
}
for _, chatType in ipairs({
	"SAY", "YELL", "WHISPER", "CHANNEL", "GUILD", "OFFICER", "PARTY", "PARTY_LEADER",
	"RAID", "RAID_LEADER", "INSTANCE_CHAT", "INSTANCE_CHAT_LEADER",
}) do
	NAME_FORMAT["CHAT_MSG_" .. chatType] = "%s: "
end

-- Rewrites a player chat line as it enters a window's history:
--   [2. Trade - City] [Name]: hi   ->  [2] Name: hi
--   [Guild] [Name]: hi             ->  Name: hi
--   [Name] says: hi                ->  Name: hi
-- The line is built from the event's own arguments, never by editing
-- Blizzard's finished text. In dungeons, raids and PvP those arguments are
-- secret values: they may be joined, formatted and passed to the functions
-- used here, but not compared, measured or searched. Keeping to that makes
-- the result the same everywhere.
local function rewrite(_, entry)
	local extra = entry.extraData -- info id, access id, type id, event, event args
	local nameFormat = extra and NAME_FORMAT[extra[4]]
	if not nameFormat then
		return
	end
	local args = extra[5]
	local text, sender, lineID = args[1], args[2], args[11]
	if C_ChatInfo.IsChatLineCensored(lineID) then
		return
	end
	local group, target = ChatHistory_GetChatType(extra[2])

	local name = Ambiguate(sender, group == "GUILD" and "guild" or "none")
	local _, class = GetPlayerInfoByGUID(args[12])
	local color = class and C_ClassColor.GetClassColor(class)
	if color then
		name = color:WrapTextInColorCode(name)
	end

	local line = nameFormat:format(ChatFrameUtil.GetPFlag(args[6], args[7], args[8])
		.. ("|Hplayer:%s:%s:%s:%s|h%s|h"):format(sender, lineID, group, target or "", name))
		.. C_StringUtil.RemoveContiguousSpaces(C_ChatInfo.ReplaceIconAndGroupExpressions(
			text, args[17], not ChatFrameUtil.CanChatGroupPerformExpressionExpansion(group)), 4)
	if group == "CHANNEL" then
		line = ("|Hchannel:channel:%d|h[%d]|h "):format(args[8], args[8]) .. line
	end
	local timestamp = ChatFrameUtil.GetTimestampFormat()
	if timestamp then
		line = TimeUtil.BetterDate(timestamp, time()) .. line
	end
	entry.message = line
end

-- Blizzard scrolls three messages per wheel click.
local function scrollOneMessage(chatFrame, delta)
	chatFrame:ScrollByAmount(delta)
end

local function setup(chatFrame)
	local name = chatFrame:GetName()

	-- Button column (channel, menu, minimize) and scrollbar.
	chatFrame.buttonFrame:SetParent(hidden)
	chatFrame.ScrollBar:SetParent(hidden)

	-- Jump-to-bottom button. It stays shown but empty: Blizzard restarts its
	-- flash animation every frame while it is not playing, and an animation
	-- on a hidden region may never count as playing.
	local jump = chatFrame.ScrollToBottomButton
	jump:EnableMouse(false)
	jump:ClearNormalTexture()
	jump.Flash:SetTexture(nil)

	-- Border edges. Blizzard only fades the ones that are shown. Its
	-- background fill is kept: it darkens while the mouse is over the window.
	for _, suffix in ipairs(CHAT_FRAME_TEXTURES) do
		if suffix ~= "Background" then
			_G[name .. suffix]:Hide()
		end
	end

	-- Edit box border. Blizzard toggles the focus half, so clear the art.
	for _, suffix in ipairs(EDIT_BOX_ART) do
		_G[name .. "EditBox" .. suffix]:SetTexture(nil)
	end

	-- Blizzard insets the typed line 15px from the edit box's left edge and
	-- 13px from its right, for that border. Widen the box by the same amounts
	-- so the typed line starts and wraps exactly where the chat text does.
	-- The -2 is Blizzard's own gap below the chat frame.
	chatFrame.editBox:SetPoint("TOPLEFT", chatFrame, "BOTTOMLEFT", -15, -2)
	chatFrame.editBox:SetPoint("RIGHT", chatFrame, "RIGHT", 13, 0)

	chatFrame:SetMaxLines(HISTORY_LINES)
	chatFrame:SetScript("OnMouseWheel", scrollOneMessage)

	-- Text is laid out upward from the bottom and clipped at the top. Trim
	-- the clip region to a whole number of text rows, so the top row is never
	-- cut through. Blizzard redraws after every resize and font change.
	local trimmed
	chatFrame:AddOnDisplayRefreshedCallback(function()
		local _, fontHeight = chatFrame:GetFont()
		local spacing = chatFrame:GetSpacing()
		local trim = (chatFrame:GetHeight() + spacing) % (fontHeight + spacing)
		if trim ~= trimmed then
			trimmed = trim
			chatFrame.FontStringContainer:SetPoint("TOPLEFT", 0, -trim)
		end
	end)

	hooksecurefunc(chatFrame.historyBuffer, "PushFront", rewrite)
end

-- CHAT_FRAMES only grows, so each window is set up exactly once.
local seen = 0
local function setupNewFrames()
	for i = seen + 1, #CHAT_FRAMES do
		setup(_G[CHAT_FRAMES[i]])
	end
	seen = #CHAT_FRAMES
end

QuickJoinToastButton:SetParent(hidden)
setupNewFrames()
-- Whisper and pop-out windows are created on demand.
hooksecurefunc("FCF_OpenTemporaryWindow", setupNewFrames)

-- Edit Mode pads the main chat frame's selection box for the button column
-- and scrollbar, and clamps the frame to the screen by it. With those gone,
-- pull the sides in close to the text. The 60 and -32 are Blizzard's own
-- margins for the tabs and edit box; SetPoint replaces the whole anchor.
ChatFrame1.Selection:SetPoint("TOPLEFT", -5, 60)
ChatFrame1.Selection:SetPoint("BOTTOMRIGHT", 5, -32)
