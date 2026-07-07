--[[
	Catalyst
	A lightweight command hub with a modern command-bar UI.
	Built from scratch — not a copy of any existing admin script.

	Commands:
		fpscap <n|none>      cap framerate
		antiafk              prevent AFK kick
		antikick             block client-side Kick calls
		gameid               copy game id
		placeid              copy place id
		rj                   rejoin server
		console              open developer console
		dex                  load DEX explorer
		sspy / cspy / hspy   load remote spies
		reset                reset character
		respawn              respawn character in place
		invis / vis          toggle invisibility
		god                  pseudo godmode
		noclip / unnoclip    walk through walls
		fly / unfly          fly (WASD + Q/E)
		swim                 swim through air
		touchinterests       fire all touch interests
		fireproximityprompts fire all proximity prompts
		datalimit <kbps>     limit outgoing bandwidth
]]

if _G.CATALYST_LOADED and not _G.CATALYST_DEBUG then return end
_G.CATALYST_LOADED = true

if not game:IsLoaded() then game.Loaded:Wait() end

--========================================================================
-- Config: getgenv().Catalyst
--   Set this BEFORE loading the script, e.g.:
--     getgenv().Catalyst = {
--         AutoExecuteCommand = { "dex", "fly", "speed 50" },
--         Prefix = ";",
--         KeepOnTeleport = true,   -- re-run the script after teleport/rejoin
--         LoaderUrl = "https://.../loader.lua", -- url used to re-load on teleport
--     }
--========================================================================
local genv = (typeof(getgenv) == "function") and getgenv() or _G
genv.Catalyst = genv.Catalyst or {}
local Config = genv.Catalyst
if type(Config.AutoExecuteCommand) ~= "table" then Config.AutoExecuteCommand = {} end
if Config.KeepOnTeleport == nil then Config.KeepOnTeleport = true end

--========================================================================
-- Executor capability shims
--========================================================================
local function pick(t, f, fallback)
	if type(f) == t then return f end
	return fallback
end

local cloneref          = pick("function", cloneref, function(...) return ... end)
local hookmetamethod    = pick("function", hookmetamethod)
local hookfunction      = pick("function", hookfunction)
local getnamecallmethod = pick("function", getnamecallmethod or get_namecall_method)
local getconnections    = pick("function", getconnections or get_signal_cons)
local setfpscap_fn      = pick("function", setfpscap)
local setclipboard_fn   = pick("function", setclipboard or toclipboard or set_clipboard or (Clipboard and Clipboard.set))
local fireproximityprompt = pick("function", fireproximityprompt)
local firetouchinterest = pick("function", firetouchinterest)
local gethui            = pick("function", gethui or get_hidden_gui)
local queueteleport     = pick("function", queue_on_teleport or (syn and syn.queue_on_teleport) or (fluxus and fluxus.queue_on_teleport))
local getgc_fn          = pick("function", getgc or get_gc_objects)
local getupvalues_fn    = pick("function", getupvalues or debug and debug.getupvalues)
local getconstants_fn   = pick("function", getconstants or debug and debug.getconstants)
local getprotos_fn      = pick("function", getprotos or debug and debug.getprotos)
local islclosure_fn     = pick("function", islclosure)
local iscclosure_fn     = pick("function", iscclosure)
local getsenv_fn        = pick("function", getsenv)
local debug_info        = (debug and debug.info) and debug.info or nil

-- File IO (for saving settings/themes)
local writefile_fn  = pick("function", writefile)
local readfile_fn   = pick("function", readfile)
local isfile_fn     = pick("function", isfile)
local makefolder_fn = pick("function", makefolder)
local isfolder_fn   = pick("function", isfolder)

--========================================================================
-- Services
--========================================================================
local Services = setmetatable({}, {
	__index = function(self, name)
		local ok, svc = pcall(function() return cloneref(game:GetService(name)) end)
		if ok then rawset(self, name, svc) return svc end
		error("Invalid Service: " .. tostring(name))
	end
})

local Players          = Services.Players
local UserInputService = Services.UserInputService
local RunService       = Services.RunService
local TweenService     = Services.TweenService
local TeleportService  = Services.TeleportService
local StarterGui       = Services.StarterGui
local Lighting         = Services.Lighting
local HttpService      = Services.HttpService
local CoreGui          = Services.CoreGui

local LocalPlayer = Players.LocalPlayer
local Camera      = workspace.CurrentCamera
local PlaceId, JobId = game.PlaceId, game.JobId

local IsOnMobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

--========================================================================
-- Generic helpers
--========================================================================
local function isNumber(s) return tonumber(s) ~= nil end

local function getRoot(char)
	if char and char:FindFirstChildOfClass("Humanoid") then
		return char:FindFirstChildOfClass("Humanoid").RootPart
	end
	return char and char:FindFirstChild("HumanoidRootPart")
end

local function getstring(from, args)
	return table.concat(args, " ", from)
end

local function httpGet(url)
	return game:HttpGet(url)
end

--========================================================================
-- Theme
--========================================================================
-- Color "roles" are looked up by key so the whole UI can be recolored live.
local Theme = {
	Bg       = Color3.fromRGB(20, 21, 26),
	Panel    = Color3.fromRGB(28, 30, 38),
	Panel2   = Color3.fromRGB(36, 38, 48),
	Stroke   = Color3.fromRGB(52, 55, 68),
	Accent   = Color3.fromRGB(120, 110, 255),
	Accent2  = Color3.fromRGB(90, 200, 250),
	Text     = Color3.fromRGB(235, 236, 245),
	SubText  = Color3.fromRGB(150, 153, 170),
	Good     = Color3.fromRGB(95, 220, 140),
	Bad      = Color3.fromRGB(245, 100, 110),
	Font     = Enum.Font.Gotham,
	FontBold = Enum.Font.GothamBold,
}

-- Preset palettes (only color roles; fonts stay constant)
local ThemePresets = {
	{
		name = "Nebula", -- default purple
		Bg = Color3.fromRGB(20, 21, 26), Panel = Color3.fromRGB(28, 30, 38),
		Panel2 = Color3.fromRGB(36, 38, 48), Stroke = Color3.fromRGB(52, 55, 68),
		Accent = Color3.fromRGB(120, 110, 255), Accent2 = Color3.fromRGB(90, 200, 250),
		Text = Color3.fromRGB(235, 236, 245), SubText = Color3.fromRGB(150, 153, 170),
		Good = Color3.fromRGB(95, 220, 140), Bad = Color3.fromRGB(245, 100, 110),
	},
	{
		name = "Ocean", -- blue/teal
		Bg = Color3.fromRGB(15, 23, 32), Panel = Color3.fromRGB(22, 33, 45),
		Panel2 = Color3.fromRGB(30, 44, 58), Stroke = Color3.fromRGB(45, 64, 82),
		Accent = Color3.fromRGB(64, 196, 255), Accent2 = Color3.fromRGB(120, 230, 210),
		Text = Color3.fromRGB(230, 240, 245), SubText = Color3.fromRGB(140, 160, 175),
		Good = Color3.fromRGB(90, 220, 160), Bad = Color3.fromRGB(255, 110, 120),
	},
	{
		name = "Crimson", -- deep red
		Bg = Color3.fromRGB(32, 10, 12), Panel = Color3.fromRGB(48, 16, 20),
		Panel2 = Color3.fromRGB(66, 22, 28), Stroke = Color3.fromRGB(110, 30, 38),
		Accent = Color3.fromRGB(255, 40, 50), Accent2 = Color3.fromRGB(255, 100, 70),
		Text = Color3.fromRGB(255, 230, 232), SubText = Color3.fromRGB(200, 140, 145),
		Good = Color3.fromRGB(120, 220, 140), Bad = Color3.fromRGB(255, 60, 60),
	},
	{
		name = "Forest", -- green
		Bg = Color3.fromRGB(17, 26, 20), Panel = Color3.fromRGB(24, 36, 28),
		Panel2 = Color3.fromRGB(32, 48, 38), Stroke = Color3.fromRGB(48, 68, 54),
		Accent = Color3.fromRGB(110, 220, 130), Accent2 = Color3.fromRGB(200, 230, 120),
		Text = Color3.fromRGB(234, 245, 236), SubText = Color3.fromRGB(150, 175, 156),
		Good = Color3.fromRGB(120, 230, 150), Bad = Color3.fromRGB(245, 120, 110),
	},
	{
		name = "Mono", -- neutral grayscale + white accent
		Bg = Color3.fromRGB(18, 18, 20), Panel = Color3.fromRGB(28, 28, 32),
		Panel2 = Color3.fromRGB(40, 40, 46), Stroke = Color3.fromRGB(60, 60, 68),
		Accent = Color3.fromRGB(235, 235, 240), Accent2 = Color3.fromRGB(180, 180, 190),
		Text = Color3.fromRGB(240, 240, 245), SubText = Color3.fromRGB(150, 150, 160),
		Good = Color3.fromRGB(150, 220, 160), Bad = Color3.fromRGB(240, 130, 130),
	},
	{
		name = "Light", -- bright theme
		Bg = Color3.fromRGB(238, 240, 245), Panel = Color3.fromRGB(252, 253, 255),
		Panel2 = Color3.fromRGB(232, 235, 242), Stroke = Color3.fromRGB(205, 210, 220),
		Accent = Color3.fromRGB(110, 95, 245), Accent2 = Color3.fromRGB(40, 170, 230),
		Text = Color3.fromRGB(28, 30, 40), SubText = Color3.fromRGB(110, 116, 130),
		Good = Color3.fromRGB(40, 170, 95), Bad = Color3.fromRGB(225, 70, 80),
	},
}
local currentThemeIndex = 1

-- Registry: { instance, property, themeKey }
local themedItems = {}
local function reg(inst, prop, key)
	themedItems[#themedItems + 1] = {inst = inst, prop = prop, key = key}
	inst[prop] = Theme[key]
	return inst
end

local function applyTheme(preset)
	for k, v in pairs(preset) do
		if k ~= "name" then Theme[k] = v end
	end
	for i = #themedItems, 1, -1 do
		local item = themedItems[i]
		if item.inst and item.inst.Parent then
			pcall(function() item.inst[item.prop] = Theme[item.key] end)
		else
			table.remove(themedItems, i) -- prune dead instances
		end
	end
end

--========================================================================
-- Settings persistence (writefile / readfile)
--========================================================================
local FOLDER = "Catalyst"
local SETTINGS_PATH = FOLDER .. "/settings.json"
local hasFileIO = writefile_fn and readfile_fn and isfile_fn

local Settings = { theme = nil } -- theme = preset name OR table of {key={r,g,b}}

local THEME_KEYS = {"Bg","Panel","Panel2","Stroke","Accent","Accent2","Text","SubText","Good","Bad"}

local function arrToColor3(a) return Color3.fromRGB(a[1] or 0, a[2] or 0, a[3] or 0) end

local function saveSettings()
	if not hasFileIO then return end
	pcall(function()
		if makefolder_fn and isfolder_fn and not isfolder_fn(FOLDER) then makefolder_fn(FOLDER) end
		writefile_fn(SETTINGS_PATH, HttpService:JSONEncode(Settings))
	end)
end

local function loadSettings()
	if not hasFileIO then return end
	pcall(function()
		if isfile_fn(SETTINGS_PATH) then
			local data = HttpService:JSONDecode(readfile_fn(SETTINGS_PATH))
			if type(data) == "table" then Settings = data end
		end
	end)
end

local function savePresetTheme(name)
	Settings.theme = name
	saveSettings()
end

--========================================================================
-- Root ScreenGui (hidden where possible)
--========================================================================
local function randomName()
	local t = {}
	for i = 1, math.random(12, 20) do t[i] = string.char(math.random(65, 90)) end
	return table.concat(t)
end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = randomName()
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.DisplayOrder = 999999999

pcall(function()
	if gethui then
		ScreenGui.Parent = gethui()
	elseif syn and syn.protect_gui then
		syn.protect_gui(ScreenGui)
		ScreenGui.Parent = CoreGui
	else
		ScreenGui.Parent = CoreGui
	end
end)
if not ScreenGui.Parent then
	ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")
end

--========================================================================
-- Tiny UI builder
--========================================================================
local function make(class, props, children)
	local inst = Instance.new(class)
	for k, v in pairs(props or {}) do
		if k ~= "Parent" then inst[k] = v end
	end
	for _, c in ipairs(children or {}) do c.Parent = inst end
	if props and props.Parent then inst.Parent = props.Parent end
	return inst
end

local function corner(r) return make("UICorner", {CornerRadius = UDim.new(0, r or 8)}) end
local function stroke(c, t)
	return make("UIStroke", {Color = c or Theme.Stroke, Thickness = t or 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border})
end
local function pad(all)
	return make("UIPadding", {
		PaddingTop = UDim.new(0, all), PaddingBottom = UDim.new(0, all),
		PaddingLeft = UDim.new(0, all), PaddingRight = UDim.new(0, all),
	})
end

-- Draggable helper
local function draggable(frame, handle)
	handle = handle or frame
	local dragging, dragStart, startPos
	handle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = frame.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then dragging = false end
			end)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local d = input.Position - dragStart
			frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
end

--========================================================================
-- Command registry
--========================================================================
local Commands = {}   -- array of {name, aliases, desc, fn}
local Lookup = {}     -- name/alias -> command

local function addcmd(name, aliases, desc, fn)
	local cmd = {name = name, aliases = aliases or {}, desc = desc or "", fn = fn}
	table.insert(Commands, cmd)
	Lookup[name:lower()] = cmd
	for _, a in ipairs(aliases or {}) do Lookup[a:lower()] = cmd end
	return cmd
end

local Prefix = (type(Config.Prefix) == "string" and #Config.Prefix > 0) and Config.Prefix or ";"

local function runCommand(text)
	text = text:gsub("^%s+", ""):gsub("%s+$", "")
	if text == "" then return end
	if text:sub(1, #Prefix) == Prefix then text = text:sub(#Prefix + 1) end
	local parts = {}
	for w in text:gmatch("%S+") do parts[#parts + 1] = w end
	local name = table.remove(parts, 1)
	if not name then return end
	local cmd = Lookup[name:lower()]
	if not cmd then
		Notify("Catalyst", "Unknown command: " .. name, Theme.Bad)
		return
	end
	local ok, err = pcall(cmd.fn, parts, LocalPlayer)
	if not ok then
		Notify("Error in " .. cmd.name, tostring(err), Theme.Bad)
	end
end

--========================================================================
-- Notifications
--========================================================================
local NotifHolder = make("Frame", {
	Name = "Notifs",
	Parent = ScreenGui,
	AnchorPoint = Vector2.new(1, 1),
	Position = UDim2.new(1, -16, 1, -16),
	Size = UDim2.new(0, 300, 1, -32),
	BackgroundTransparency = 1,
}, {
	make("UIListLayout", {
		Padding = UDim.new(0, 8),
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		VerticalAlignment = Enum.VerticalAlignment.Bottom,
		SortOrder = Enum.SortOrder.LayoutOrder,
	})
})

function Notify(title, body, accent)
	accent = accent or Theme.Accent
	body = tostring(body or "")
	if body == "" then return end -- skip empty notifications

	local card = make("Frame", {
		Parent = NotifHolder,
		BackgroundColor3 = Theme.Panel,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	})
	corner(10).Parent = card
	local cardStroke = make("UIStroke", {
		Parent = card, Color = accent, Thickness = 1.5,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Transparency = 1,
	})
	make("UIPadding", {
		Parent = card,
		PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10),
		PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12),
	})
	make("UIListLayout", {
		Parent = card, Padding = UDim.new(0, 2),
		SortOrder = Enum.SortOrder.LayoutOrder,
	})

	local titleLbl = make("TextLabel", {
		Parent = card, Name = "Title", LayoutOrder = 1, BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 18), Font = Theme.FontBold, TextSize = 15,
		TextColor3 = Theme.Text, Text = tostring(title),
		TextXAlignment = Enum.TextXAlignment.Left, TextTransparency = 1,
	})
	local bodyLbl = make("TextLabel", {
		Parent = card, Name = "Body", LayoutOrder = 2, BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		Font = Theme.Font, TextSize = 13, TextColor3 = Theme.SubText,
		Text = body, TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left, TextTransparency = 1,
	})

	-- fade in everything together
	local ti = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(card, ti, {BackgroundTransparency = 0}):Play()
	TweenService:Create(cardStroke, ti, {Transparency = 0}):Play()
	TweenService:Create(titleLbl, ti, {TextTransparency = 0}):Play()
	TweenService:Create(bodyLbl, ti, {TextTransparency = 0}):Play()

	task.delay(4, function()
		if not card or not card.Parent then return end
		local fo = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(card, fo, {BackgroundTransparency = 1}):Play()
		TweenService:Create(cardStroke, fo, {Transparency = 1}):Play()
		TweenService:Create(titleLbl, fo, {TextTransparency = 1}):Play()
		TweenService:Create(bodyLbl, fo, {TextTransparency = 1}):Play()
		task.wait(0.28)
		card:Destroy()
	end)
end

--========================================================================
-- Main window
--========================================================================
local Window = make("Frame", {
	Name = "Main",
	Parent = ScreenGui,
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 60),
	Size = UDim2.new(0, 460, 0, 44),
	BackgroundColor3 = Theme.Bg,
	ClipsDescendants = true,
}, {
	corner(12),
})
reg(Window, "BackgroundColor3", "Bg")
local windowStroke = stroke(Theme.Stroke, 1)
windowStroke.Parent = Window
reg(windowStroke, "Color", "Stroke")

-- Top bar
local TopBar = make("Frame", {
	Name = "TopBar", Parent = Window,
	BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 44),
})

local Dot = make("Frame", {
	Name = "Dot", Parent = TopBar, BackgroundColor3 = Theme.Accent,
	Position = UDim2.new(0, 14, 0.5, -5), Size = UDim2.new(0, 10, 0, 10),
}, { corner(5) })
reg(Dot, "BackgroundColor3", "Accent")

local TitleLabel = make("TextLabel", {
	Parent = TopBar, BackgroundTransparency = 1,
	Position = UDim2.new(0, 34, 0, 0), Size = UDim2.new(0, 120, 1, 0),
	Font = Theme.FontBold, TextSize = 16, TextColor3 = Theme.Text,
	Text = "Catalyst", TextXAlignment = Enum.TextXAlignment.Left,
})
reg(TitleLabel, "TextColor3", "Text")

-- Command bar
local CmdBar = make("TextBox", {
	Name = "CmdBar", Parent = TopBar,
	BackgroundColor3 = Theme.Panel,
	Position = UDim2.new(0, 130, 0.5, -14), Size = UDim2.new(1, -240, 0, 28),
	Font = Theme.Font, TextSize = 14, TextColor3 = Theme.Text,
	PlaceholderText = "Type a command...", PlaceholderColor3 = Theme.SubText,
	Text = "", ClearTextOnFocus = false,
	TextXAlignment = Enum.TextXAlignment.Left,
}, { corner(8), pad(8) })
reg(CmdBar, "BackgroundColor3", "Panel")
reg(CmdBar, "TextColor3", "Text")
reg(CmdBar, "PlaceholderColor3", "SubText")
local cmdStroke = stroke(Theme.Stroke, 1) cmdStroke.Parent = CmdBar
reg(cmdStroke, "Color", "Stroke")

-- Theme switch button
local ThemeBtn = make("TextButton", {
	Name = "ThemeBtn", Parent = TopBar, BackgroundColor3 = Theme.Panel,
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, -50, 0.5, 0), Size = UDim2.new(0, 32, 0, 28),
	Font = Theme.FontBold, TextSize = 15, TextColor3 = Theme.Text, Text = "🎨",
}, { corner(8) })
reg(ThemeBtn, "BackgroundColor3", "Panel")
reg(ThemeBtn, "TextColor3", "Text")
local themeBtnStroke = stroke(Theme.Stroke, 1) themeBtnStroke.Parent = ThemeBtn
reg(themeBtnStroke, "Color", "Stroke")

-- Expand / list toggle
local ToggleBtn = make("TextButton", {
	Name = "Toggle", Parent = TopBar, BackgroundColor3 = Theme.Panel,
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, -12, 0.5, 0), Size = UDim2.new(0, 32, 0, 28),
	Font = Theme.FontBold, TextSize = 16, TextColor3 = Theme.Text, Text = "v",
}, { corner(8) })
reg(ToggleBtn, "BackgroundColor3", "Panel")
reg(ToggleBtn, "TextColor3", "Text")
local toggleStroke = stroke(Theme.Stroke, 1) toggleStroke.Parent = ToggleBtn
reg(toggleStroke, "Color", "Stroke")

-- Suggestion / command list
local ListFrame = make("ScrollingFrame", {
	Name = "List", Parent = Window,
	BackgroundTransparency = 1, Visible = false,
	Position = UDim2.new(0, 8, 0, 48), Size = UDim2.new(1, -16, 1, -56),
	ScrollBarThickness = 4, ScrollBarImageColor3 = Theme.Accent,
	CanvasSize = UDim2.new(0, 0, 0, 0), BorderSizePixel = 0,
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, {
	make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
})
reg(ListFrame, "ScrollBarImageColor3", "Accent")

draggable(Window, TopBar)

local EXPANDED_H = 300
local expanded = false
local autoCloseToken = 0 -- invalidates pending auto-close timers

local function setExpanded(state)
	expanded = state
	ToggleBtn.Text = expanded and "^" or "v"
	autoCloseToken = autoCloseToken + 1 -- cancel any pending auto-close
	local h = expanded and EXPANDED_H or 44
	if expanded then
		ListFrame.Visible = true
	end
	local tween = TweenService:Create(Window, TweenInfo.new(0.25, Enum.EasingStyle.Quart), {
		Size = UDim2.new(0, 460, 0, h)
	})
	tween:Play()
	if not expanded then
		-- hide & reset the list only after the collapse animation finishes,
		-- so the shrinking window never shows scrolled-through rows
		local myToken = autoCloseToken
		tween.Completed:Connect(function()
			if myToken == autoCloseToken and not expanded then
				ListFrame.Visible = false
				ListFrame.CanvasPosition = Vector2.new(0, 0)
			end
		end)
	end
end
ToggleBtn.MouseButton1Click:Connect(function() setExpanded(not expanded) end)

-- Theme application
local rebuildRows -- forward decl (assigned after buildRows is defined)
local openThemePanel -- forward decl (assigned after the panel is built)

local function refreshThemedRows()
	if expanded and rebuildRows then rebuildRows() end
end

local function applyPresetByIndex(index, save)
	currentThemeIndex = ((index - 1) % #ThemePresets) + 1
	applyTheme(ThemePresets[currentThemeIndex])
	refreshThemedRows()
	if save then savePresetTheme(ThemePresets[currentThemeIndex].name) end
end

local function applyCustomPalette(palette)
	-- only used to restore a custom palette saved by older versions
	applyTheme(palette)
	refreshThemedRows()
end

ThemeBtn.MouseButton1Click:Connect(function()
	if openThemePanel then openThemePanel() end
end)

--========================================================================
-- Auto-close: collapse the list if the cursor leaves the window for 3s
--========================================================================
local hoverInside = false
local function scheduleAutoClose()
	if not expanded then return end
	autoCloseToken = autoCloseToken + 1
	local myToken = autoCloseToken
	task.delay(3, function()
		if myToken == autoCloseToken and expanded and not hoverInside and not CmdBar:IsFocused() then
			setExpanded(false)
		end
	end)
end

Window.MouseEnter:Connect(function()
	hoverInside = true
	autoCloseToken = autoCloseToken + 1 -- cancel pending close while hovering
end)
Window.MouseLeave:Connect(function()
	hoverInside = false
	scheduleAutoClose()
end)

-- Build / filter the command rows
local function buildRows(filter)
	for _, c in ipairs(ListFrame:GetChildren()) do
		if c:IsA("TextButton") then c:Destroy() end
	end
	filter = (filter or ""):lower()
	local order = 0
	for _, cmd in ipairs(Commands) do
		local hay = (cmd.name .. " " .. table.concat(cmd.aliases, " ")):lower()
		if filter == "" or hay:find(filter, 1, true) then
			order = order + 1
			local row = make("TextButton", {
				Parent = ListFrame, BackgroundColor3 = Theme.Panel,
				Size = UDim2.new(1, 0, 0, 40), LayoutOrder = order,
				Text = "", AutoButtonColor = false,
			}, {
				corner(8),
				make("TextLabel", {
					BackgroundTransparency = 1, Position = UDim2.new(0, 10, 0, 4),
					Size = UDim2.new(1, -20, 0, 18), Font = Theme.FontBold, TextSize = 14,
					TextColor3 = Theme.Text, Text = cmd.name,
					TextXAlignment = Enum.TextXAlignment.Left,
				}),
				make("TextLabel", {
					BackgroundTransparency = 1, Position = UDim2.new(0, 10, 0, 20),
					Size = UDim2.new(1, -20, 0, 16), Font = Theme.Font, TextSize = 12,
					TextColor3 = Theme.SubText, Text = cmd.desc,
					TextXAlignment = Enum.TextXAlignment.Left,
				}),
			})
			row.MouseEnter:Connect(function() row.BackgroundColor3 = Theme.Panel2 end)
			row.MouseLeave:Connect(function() row.BackgroundColor3 = Theme.Panel end)
			row.MouseButton1Click:Connect(function()
				CmdBar.Text = cmd.name .. " "
				CmdBar:CaptureFocus()
			end)
		end
	end
end

-- allow theme switching to recolor visible rows
rebuildRows = function() buildRows(CmdBar.Text) end

CmdBar:GetPropertyChangedSignal("Text"):Connect(function()
	if not expanded then setExpanded(true) end
	buildRows(CmdBar.Text)
end)

CmdBar.FocusLost:Connect(function(enter)
	if enter then
		runCommand(CmdBar.Text)
		CmdBar.Text = ""
	end
	-- start the 3s auto-close once focus is gone and cursor isn't inside
	if not hoverInside then scheduleAutoClose() end
end)

-- Keybind: RightShift toggles the bar focus / window
UserInputService.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.KeyCode == Enum.KeyCode.RightShift or input.KeyCode == Enum.KeyCode.Insert then
		setExpanded(not expanded)
		if expanded then CmdBar:CaptureFocus() end
	end
end)

--========================================================================
-- Theme panel: presets only
--========================================================================
do
	local COLS = 2
	local CARD_W, CARD_H, GAP = 180, 70, 12
	local panelW = 32 + COLS * CARD_W + (COLS - 1) * GAP
	local rows = math.ceil(#ThemePresets / COLS)
	local panelH = 60 + rows * (CARD_H + GAP) + 8

	local panel = make("Frame", {
		Name = "ThemePanel", Parent = ScreenGui, Visible = false,
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, 0),
		Size = UDim2.new(0, panelW, 0, panelH), BackgroundColor3 = Theme.Bg,
	})
	corner(12).Parent = panel
	reg(panel, "BackgroundColor3", "Bg")
	local pStroke = stroke(Theme.Stroke, 1) pStroke.Parent = panel
	reg(pStroke, "Color", "Stroke")

	-- header
	local pHead = make("Frame", { Parent = panel, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 44) })
	local pTitle = make("TextLabel", {
		Parent = pHead, BackgroundTransparency = 1,
		Position = UDim2.new(0, 16, 0, 0), Size = UDim2.new(1, -60, 1, 0),
		Font = Theme.FontBold, TextSize = 17, TextColor3 = Theme.Text,
		Text = "Themes", TextXAlignment = Enum.TextXAlignment.Left,
	})
	reg(pTitle, "TextColor3", "Text")
	local pClose = make("TextButton", {
		Parent = pHead, BackgroundColor3 = Theme.Panel, AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0), Size = UDim2.new(0, 30, 0, 28),
		Font = Theme.FontBold, TextSize = 16, TextColor3 = Theme.Text, Text = "X",
	}, { corner(8) })
	reg(pClose, "BackgroundColor3", "Panel")
	reg(pClose, "TextColor3", "Text")
	pClose.MouseButton1Click:Connect(function() panel.Visible = false end)
	draggable(panel, pHead)

	-- preset grid
	local grid = make("Frame", {
		Parent = panel, BackgroundTransparency = 1,
		Position = UDim2.new(0, 16, 0, 52), Size = UDim2.new(1, -32, 1, -60),
	}, {
		make("UIGridLayout", {
			CellSize = UDim2.new(0, CARD_W, 0, CARD_H),
			CellPadding = UDim2.new(0, GAP, 0, GAP),
			SortOrder = Enum.SortOrder.LayoutOrder,
		})
	})

	local cards = {}
	local function highlight(activeIndex)
		for i, c in pairs(cards) do
			local on = (i == activeIndex)
			c.stroke.Color = on and ThemePresets[i].Accent or ThemePresets[i].Stroke
			c.stroke.Thickness = on and 2 or 1
			c.check.Visible = on
		end
	end

	for i, preset in ipairs(ThemePresets) do
		local card = make("TextButton", {
			Parent = grid, BackgroundColor3 = preset.Panel,
			Text = "", AutoButtonColor = false, LayoutOrder = i,
		}, { corner(10) })
		local cStroke = stroke(preset.Stroke, 1) cStroke.Parent = card

		-- accent + accent2 dots
		make("Frame", {
			Parent = card, BackgroundColor3 = preset.Accent,
			Position = UDim2.new(0, 12, 0, 12), Size = UDim2.new(0, 22, 0, 22),
		}, { corner(11) })
		make("Frame", {
			Parent = card, BackgroundColor3 = preset.Accent2,
			Position = UDim2.new(0, 30, 0, 12), Size = UDim2.new(0, 22, 0, 22),
		}, { corner(11) })
		-- bg preview chip
		make("Frame", {
			Parent = card, BackgroundColor3 = preset.Bg,
			Position = UDim2.new(0, 58, 0, 14), Size = UDim2.new(0, 18, 0, 18),
		}, { corner(5), stroke(preset.Stroke, 1) })

		-- name
		make("TextLabel", {
			Parent = card, BackgroundTransparency = 1,
			Position = UDim2.new(0, 12, 1, -26), Size = UDim2.new(1, -24, 0, 18),
			Font = Theme.FontBold, TextSize = 14, TextColor3 = preset.Text,
			Text = preset.name, TextXAlignment = Enum.TextXAlignment.Left,
		})

		-- selected check mark
		local check = make("TextLabel", {
			Parent = card, BackgroundTransparency = 1, Visible = false,
			AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 8),
			Size = UDim2.new(0, 20, 0, 20), Font = Theme.FontBold, TextSize = 16,
			TextColor3 = preset.Accent, Text = "✓",
		})

		cards[i] = { btn = card, stroke = cStroke, check = check }

		card.MouseEnter:Connect(function()
			if cStroke.Thickness < 2 then cStroke.Color = preset.Accent end
		end)
		card.MouseLeave:Connect(function()
			if cStroke.Thickness < 2 then cStroke.Color = preset.Stroke end
		end)
		card.MouseButton1Click:Connect(function()
			applyPresetByIndex(i, true)
			highlight(i)
			Notify("Theme", "Applied " .. preset.name, Theme.Accent)
		end)
	end

	openThemePanel = function()
		panel.Visible = true
		highlight(currentThemeIndex)
	end
end

--========================================================================
-- Character helpers (respawn / refresh / invis state)
--========================================================================
local invisRunning = false
local TurnVisible -- forward declaration

local function respawnChar(plr)
	if invisRunning and TurnVisible then TurnVisible() end
	local char = plr.Character
	if not char then return end
	local hum = char:FindFirstChildWhichIsA("Humanoid")
	if hum then hum:ChangeState(Enum.HumanoidStateType.Dead) end
	char:ClearAllChildren()
	local newChar = Instance.new("Model")
	newChar.Parent = workspace
	plr.Character = newChar
	task.wait()
	plr.Character = char
	newChar:Destroy()
end

local function refreshChar(plr)
	local root = getRoot(plr.Character)
	if not root then return end
	local pos = root.CFrame
	local camCF = Camera.CFrame
	respawnChar(plr)
	task.spawn(function()
		local char = plr.CharacterAdded:Wait()
		local humanoid = char:FindFirstChildOfClass("Humanoid")
		while not humanoid do task.wait() humanoid = char:FindFirstChildOfClass("Humanoid") end
		humanoid.RootPart.CFrame, Camera.CFrame = pos, task.wait() and camCF
	end)
end

--========================================================================
-- Noclip
--========================================================================
local Clip = true
local NoclipConn
addcmd("noclip", {}, "Walk through walls", function()
	Clip = false
	task.wait(0.1)
	if NoclipConn then NoclipConn:Disconnect() end
	NoclipConn = RunService.Stepped:Connect(function()
		if not Clip and LocalPlayer.Character then
			for _, p in ipairs(LocalPlayer.Character:GetDescendants()) do
				if p:IsA("BasePart") and p.CanCollide then p.CanCollide = false end
			end
		end
	end)
	Notify("Noclip", "Enabled", Theme.Good)
end)

addcmd("unnoclip", {"clip"}, "Restore collisions", function()
	if NoclipConn then NoclipConn:Disconnect() NoclipConn = nil end
	Clip = true
	Notify("Noclip", "Disabled", Theme.Bad)
end)

--========================================================================
-- Fly
--========================================================================
local FLYING = false
local flyKeyDown, flyKeyUp
local flySpeed = 1

local function startFly()
	local char = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
	local humanoid = char:FindFirstChildOfClass("Humanoid")
	repeat task.wait() until humanoid
	if flyKeyDown then flyKeyDown:Disconnect() end
	if flyKeyUp then flyKeyUp:Disconnect() end

	local T = getRoot(char)
	local CONTROL = {F = 0, B = 0, L = 0, R = 0, Q = 0, E = 0}
	local lCONTROL = {F = 0, B = 0, L = 0, R = 0}
	local SPEED = 0

	FLYING = true
	local BG = Instance.new("BodyGyro")
	local BV = Instance.new("BodyVelocity")
	BG.P = 9e4
	BG.Parent = T
	BV.Parent = T
	BG.MaxTorque = Vector3.new(9e9, 9e9, 9e9)
	BG.CFrame = T.CFrame
	BV.Velocity = Vector3.zero
	BV.MaxForce = Vector3.new(9e9, 9e9, 9e9)

	task.spawn(function()
		repeat task.wait()
			local cam = workspace.CurrentCamera
			if humanoid then humanoid.PlatformStand = true end
			if CONTROL.L + CONTROL.R ~= 0 or CONTROL.F + CONTROL.B ~= 0 or CONTROL.Q + CONTROL.E ~= 0 then
				SPEED = 50
			elseif SPEED ~= 0 then
				SPEED = 0
			end
			if (CONTROL.L + CONTROL.R) ~= 0 or (CONTROL.F + CONTROL.B) ~= 0 or (CONTROL.Q + CONTROL.E) ~= 0 then
				BV.Velocity = ((cam.CFrame.LookVector * (CONTROL.F + CONTROL.B)) + ((cam.CFrame * CFrame.new(CONTROL.L + CONTROL.R, (CONTROL.F + CONTROL.B + CONTROL.Q + CONTROL.E) * 0.2, 0).p) - cam.CFrame.p)) * SPEED
				lCONTROL = {F = CONTROL.F, B = CONTROL.B, L = CONTROL.L, R = CONTROL.R}
			elseif SPEED ~= 0 then
				BV.Velocity = ((cam.CFrame.LookVector * (lCONTROL.F + lCONTROL.B)) + ((cam.CFrame * CFrame.new(lCONTROL.L + lCONTROL.R, (lCONTROL.F + lCONTROL.B) * 0.2, 0).p) - cam.CFrame.p)) * SPEED
			else
				BV.Velocity = Vector3.zero
			end
			BG.CFrame = cam.CFrame
		until not FLYING
		BG:Destroy()
		BV:Destroy()
		if humanoid then humanoid.PlatformStand = false end
	end)

	flyKeyDown = UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end
		local k = input.KeyCode
		if k == Enum.KeyCode.W then CONTROL.F = flySpeed
		elseif k == Enum.KeyCode.S then CONTROL.B = -flySpeed
		elseif k == Enum.KeyCode.A then CONTROL.L = -flySpeed
		elseif k == Enum.KeyCode.D then CONTROL.R = flySpeed
		elseif k == Enum.KeyCode.E then CONTROL.Q = flySpeed * 2
		elseif k == Enum.KeyCode.Q then CONTROL.E = -flySpeed * 2 end
	end)
	flyKeyUp = UserInputService.InputEnded:Connect(function(input, processed)
		if processed then return end
		local k = input.KeyCode
		if k == Enum.KeyCode.W then CONTROL.F = 0
		elseif k == Enum.KeyCode.S then CONTROL.B = 0
		elseif k == Enum.KeyCode.A then CONTROL.L = 0
		elseif k == Enum.KeyCode.D then CONTROL.R = 0
		elseif k == Enum.KeyCode.E then CONTROL.Q = 0
		elseif k == Enum.KeyCode.Q then CONTROL.E = 0 end
	end)
end

local function stopFly()
	FLYING = false
	if flyKeyDown then flyKeyDown:Disconnect() end
	if flyKeyUp then flyKeyUp:Disconnect() end
	local char = LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then hum.PlatformStand = false end
end

addcmd("fly", {}, "Fly (WASD + Q/E)", function(args)
	stopFly()
	task.wait()
	if args[1] and isNumber(args[1]) then flySpeed = tonumber(args[1]) end
	startFly()
	Notify("Fly", "Enabled (WASD + Q/E)", Theme.Good)
end)

addcmd("unfly", {"nofly"}, "Disable fly", function()
	stopFly()
	Notify("Fly", "Disabled", Theme.Bad)
end)

--========================================================================
-- Swim
--========================================================================
local swimming = false
local swimBeat, gravReset
local savedGravity = workspace.Gravity
addcmd("swim", {}, "Swim through the air", function(_, speaker)
	local char = speaker.Character
	local hum = char and char:FindFirstChildWhichIsA("Humanoid")
	if swimming or not hum then return end
	savedGravity = workspace.Gravity
	workspace.Gravity = 0
	gravReset = hum.Died:Connect(function()
		workspace.Gravity = savedGravity
		swimming = false
	end)
	for _, s in ipairs(Enum.HumanoidStateType:GetEnumItems()) do
		if s ~= Enum.HumanoidStateType.None then hum:SetStateEnabled(s, false) end
	end
	hum:ChangeState(Enum.HumanoidStateType.Swimming)
	swimBeat = RunService.Heartbeat:Connect(function()
		pcall(function()
			local root = getRoot(char)
			root.Velocity = ((hum.MoveDirection ~= Vector3.zero or UserInputService:IsKeyDown(Enum.KeyCode.Space)) and root.Velocity or Vector3.zero)
		end)
	end)
	swimming = true
	Notify("Swim", "Enabled", Theme.Good)
end)

addcmd("unswim", {"noswim"}, "Disable swim", function(_, speaker)
	local char = speaker.Character
	local hum = char and char:FindFirstChildWhichIsA("Humanoid")
	workspace.Gravity = savedGravity
	swimming = false
	if gravReset then gravReset:Disconnect() end
	if swimBeat then swimBeat:Disconnect() swimBeat = nil end
	if hum then
		for _, s in ipairs(Enum.HumanoidStateType:GetEnumItems()) do
			if s ~= Enum.HumanoidStateType.None then hum:SetStateEnabled(s, true) end
		end
	end
	Notify("Swim", "Disabled", Theme.Bad)
end)

--========================================================================
-- Invisible / Visible
--========================================================================
addcmd("invisible", {"invis"}, "Become invisible to others", function(_, speaker)
	if invisRunning then return end
	invisRunning = true
	-- technique: swap your character for an animated clone (credit: AmokahFox)
	local Player = speaker
	repeat task.wait(0.1) until Player.Character
	local Character = Player.Character
	Character.Archivable = true
	local IsInvis = false
	local InvisibleCharacter = Character:Clone()
	InvisibleCharacter.Parent = Lighting
	local Void = workspace.FallenPartsDestroyHeight
	InvisibleCharacter.Name = ""

	local invisFix
	invisFix = RunService.Stepped:Connect(function()
		pcall(function()
			local root = Player.Character and getRoot(Player.Character)
			if not root then return end
			local Y = root.Position.Y
			local negative = tostring(Void):find("-") ~= nil
			if (negative and Y <= Void) or (not negative and Y >= Void) then
				Respawn()
			end
		end)
	end)

	for _, v in ipairs(InvisibleCharacter:GetDescendants()) do
		if v:IsA("BasePart") then
			v.Transparency = (v.Name == "HumanoidRootPart") and 1 or 0.5
		end
	end

	function Respawn()
		pcall(function()
			Player.Character = Character
			task.wait()
			Character.Parent = workspace
			local h = Character:FindFirstChildWhichIsA("Humanoid")
			if h then h:Destroy() end
			if IsInvis then
				IsInvis = false
				InvisibleCharacter.Parent = nil
				invisRunning = false
			else
				TurnVisible()
			end
		end)
	end

	local invisDied
	invisDied = InvisibleCharacter:FindFirstChildOfClass("Humanoid").Died:Connect(function()
		Respawn()
		invisDied:Disconnect()
	end)

	IsInvis = true
	local CF_1 = getRoot(Player.Character).CFrame
	Character:MoveTo(Vector3.new(0, math.pi * 1000000, 0))
	workspace.CurrentCamera.CameraType = Enum.CameraType.Scriptable
	task.wait(0.2)
	workspace.CurrentCamera.CameraType = Enum.CameraType.Custom
	Character.Parent = Lighting
	InvisibleCharacter.Parent = workspace
	InvisibleCharacter:FindFirstChild("HumanoidRootPart").CFrame = CF_1
	Player.Character = InvisibleCharacter
	pcall(function() workspace.CurrentCamera.CameraSubject = InvisibleCharacter:FindFirstChildOfClass("Humanoid") end)
	if InvisibleCharacter:FindFirstChild("Animate") then
		InvisibleCharacter.Animate.Disabled = true
		InvisibleCharacter.Animate.Disabled = false
	end

	function TurnVisible()
		if not IsInvis then return end
		invisFix:Disconnect()
		if invisDied then invisDied:Disconnect() end
		local cf = getRoot(Player.Character).CFrame
		Character:FindFirstChild("HumanoidRootPart").CFrame = cf
		InvisibleCharacter:Destroy()
		Player.Character = Character
		Character.Parent = workspace
		IsInvis = false
		if Character:FindFirstChild("Animate") then
			Character.Animate.Disabled = true
			Character.Animate.Disabled = false
		end
		invisRunning = false
	end

	Notify("Invisible", "You now appear invisible to others", Theme.Good)
end)

addcmd("visible", {"vis", "uninvisible"}, "Become visible again", function()
	if TurnVisible then TurnVisible() end
	Notify("Visible", "You are visible again", Theme.Good)
end)

--========================================================================
-- God
--========================================================================
addcmd("god", {}, "Pseudo godmode (humanoid swap)", function(_, speaker)
	local Cam = workspace.CurrentCamera
	local Char = speaker.Character
	if not Char then return end
	local pos = Cam.CFrame
	local Human = Char:FindFirstChildWhichIsA("Humanoid")
	if not Human then return end
	local nHuman = Human:Clone()
	nHuman.Parent = Char
	speaker.Character = nil
	nHuman:SetStateEnabled(15, false)
	nHuman:SetStateEnabled(1, false)
	nHuman:SetStateEnabled(0, false)
	nHuman.BreakJointsOnDeath = true
	Human:Destroy()
	speaker.Character = Char
	Cam.CameraSubject = nHuman
	Cam.CFrame = task.wait() and pos
	nHuman.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	local anim = Char:FindFirstChild("Animate")
	if anim then anim.Disabled = true task.wait() anim.Disabled = false end
	nHuman.Health = nHuman.MaxHealth
	Notify("God", "Godmode applied", Theme.Good)
end)

--========================================================================
-- Reset / Respawn
--========================================================================
addcmd("reset", {}, "Reset your character", function(_, speaker)
	local hum = speaker.Character and speaker.Character:FindFirstChildWhichIsA("Humanoid")
	if hum then hum.Health = 0 end
end)

addcmd("respawn", {}, "Respawn in place", function(_, speaker)
	respawnChar(speaker)
end)

addcmd("refresh", {"re"}, "Respawn keeping your position", function(_, speaker)
	refreshChar(speaker)
end)

--========================================================================
-- Performance / network
--========================================================================
local fpsLoop
addcmd("fpscap", {"setfpscap", "maxfps"}, "Cap framerate (<n|none>)", function(args)
	if fpsLoop then task.cancel(fpsLoop) fpsLoop = nil end
	if args[1] == "none" then Notify("FPS Cap", "Removed", Theme.Good) return end
	local num = tonumber(args[1]) or 60
	if num <= 0 then return Notify("FPS Cap", "Provide a number above 0 or 'none'", Theme.Bad) end
	if setfpscap_fn then
		setfpscap_fn(num)
	else
		fpsLoop = task.spawn(function()
			local timer = os.clock()
			while true do
				if os.clock() >= timer + 1 / num then timer = os.clock() task.wait() end
			end
		end)
	end
	Notify("FPS Cap", "Set to " .. num, Theme.Good)
end)

addcmd("datalimit", {}, "Limit outgoing bandwidth (kbps)", function(args)
	local kbps = tonumber(args[1])
	if not kbps then return Notify("Data Limit", "Provide a kbps number", Theme.Bad) end
	pcall(function() Services.NetworkClient:SetOutgoingKBPSLimit(kbps) end)
	Notify("Data Limit", "Outgoing limit: " .. kbps .. " kbps", Theme.Good)
end)

--========================================================================
-- Anti
--========================================================================
addcmd("antiafk", {"antiidle"}, "Prevent AFK kick", function(args, speaker)
	if getconnections then
		for _, c in ipairs(getconnections(speaker.Idled)) do
			if c.Disable then c:Disable() elseif c.Disconnect then c:Disconnect() end
		end
	else
		speaker.Idled:Connect(function()
			local vu = Services.VirtualUser
			vu:CaptureController()
			vu:ClickButton2(Vector2.new())
		end)
	end
	Notify("Anti AFK", "Enabled", Theme.Good)
end)

addcmd("antikick", {"clientantikick"}, "Block client-side Kick calls", function()
	if not hookmetamethod then
		return Notify("Incompatible", "Missing hookmetamethod", Theme.Bad)
	end
	local oldIndex, oldNamecall
	if hookfunction then pcall(function() hookfunction(LocalPlayer.Kick, function() end) end) end
	oldIndex = hookmetamethod(game, "__index", function(self, method)
		if self == LocalPlayer and tostring(method):lower() == "kick" then
			return error("Expected ':' not '.' calling member function Kick", 2)
		end
		return oldIndex(self, method)
	end)
	oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
		if self == LocalPlayer and getnamecallmethod():lower() == "kick" then return end
		return oldNamecall(self, ...)
	end)
	Notify("Anti Kick", "Active (localscript kicks only)", Theme.Good)
end)

--========================================================================
-- Server / ids
--========================================================================
local function copy(v)
	if setclipboard_fn then
		setclipboard_fn(tostring(v))
		Notify("Clipboard", "Copied", Theme.Good)
	else
		Notify("Clipboard", "Executor has no clipboard support", Theme.Bad)
	end
end

--========================================================================
-- Queue-on-teleport: re-run Catalyst (with same config) after teleport
--========================================================================
-- Detect the loader URL: explicit config wins, otherwise fall back to the
-- public Catalyst loader. Set Config.LoaderUrl if you use a custom host.
local DEFAULT_LOADER = "https://raw.githubusercontent.com/Hikkosalatik/Catalyst/refs/heads/main/Main.lua"

local function buildTeleportPayload()
	-- serialize the runtime config so the next session restores it
	local cfg = {
		AutoExecuteCommand = Config.AutoExecuteCommand,
		Prefix = Prefix,
		KeepOnTeleport = Config.KeepOnTeleport,
		LoaderUrl = Config.LoaderUrl,
	}
	local okJson, json = pcall(function() return HttpService:JSONEncode(cfg) end)
	if not okJson then json = "{}" end
	local url = (type(Config.LoaderUrl) == "string" and #Config.LoaderUrl > 0) and Config.LoaderUrl or DEFAULT_LOADER
	-- script that runs in the next server
	return ([[
local ok, cfg = pcall(function() return game:GetService("HttpService"):JSONDecode(%q) end)
getgenv().Catalyst = (ok and type(cfg) == "table") and cfg or {}
loadstring(game:HttpGet(%q))()
]]):format(json, url)
end

local teleportQueued = false
local function queueCatalystOnTeleport()
	if not queueteleport then return false end
	if teleportQueued then return true end
	local ok = pcall(function() queueteleport(buildTeleportPayload()) end)
	if ok then teleportQueued = true end
	return ok
end

-- auto-queue on ANY teleport (serverhop, gametp, game-initiated, etc.)
if Config.KeepOnTeleport and queueteleport then
	pcall(function()
		LocalPlayer.OnTeleport:Connect(function(state)
			if state == Enum.TeleportState.Started or state == Enum.TeleportState.RequestedFromServer then
				queueCatalystOnTeleport()
			end
		end)
	end)
end

addcmd("placeid", {"copyplaceid"}, "Copy the place id", function() copy(PlaceId) end)
addcmd("gameid", {"copygameid"}, "Copy the game (universe) id", function() copy(game.GameId) end)

addcmd("rj", {"rejoin"}, "Rejoin the current server", function()
	if Config.KeepOnTeleport then queueCatalystOnTeleport() end
	if #Players:GetPlayers() <= 1 then
		LocalPlayer:Kick("\nRejoining...")
		task.wait()
		TeleportService:Teleport(PlaceId, LocalPlayer)
	else
		TeleportService:TeleportToPlaceInstance(PlaceId, JobId, LocalPlayer)
	end
end)

--========================================================================
-- Developer tools
--========================================================================
addcmd("console", {}, "Open the developer console", function()
	StarterGui:SetCore("DevConsoleVisible", true)
end)

addcmd("dex", {"explorer"}, "Load the DEX explorer", function()
	Notify("Loading", "DEX explorer...", Theme.Accent2)
	loadstring(game:HttpGet("https://api.luarmor.net/files/v4/loaders/b042c96f2a52417173570ae403a3b723.lua"))()
end)

addcmd("sspy", {"simplespy"}, "Load SimpleSpy remote spy", function()
	Notify("Loading", "SimpleSpy...", Theme.Accent2)
	loadstring(httpGet("https://raw.githubusercontent.com/infyiff/backup/main/SimpleSpyV3/main.lua"))()
end)

addcmd("cspy", {}, "Load remote spy (rspy)", function()
	Notify("Loading", "Remote spy...", Theme.Accent2)
	loadstring(httpGet("https://raw.githubusercontent.com/Hikkosalatik/decomp/refs/heads/main/rspy.lua"))()
end)

addcmd("hspy", {"hydroxide"}, "Load Hydroxide remote spy", function()
	Notify("Loading", "Hydroxide...", Theme.Accent2)
	loadstring(httpGet("https://raw.githubusercontent.com/Upbolt/Hydroxide/revision/init.lua"))()
end)

--========================================================================
-- World interaction
--========================================================================
addcmd("touchinterests", {"touchinterest", "firetouchinterests", "firetouchinterest"}, "Fire all touch interests", function(args, speaker)
	local Root = getRoot(speaker.Character) or (speaker.Character and speaker.Character:FindFirstChildWhichIsA("BasePart"))
	if not firetouchinterest then
		return Notify("Incompatible", "Missing firetouchinterest", Theme.Bad)
	end
	if not Root then return end
	local function touch(t)
		local part = t:FindFirstAncestorWhichIsA("Part") or t.Parent
		if part and part:IsA("BasePart") then
			task.spawn(function()
				firetouchinterest(part, Root, 1)
				task.wait()
				firetouchinterest(part, Root, 0)
			end)
		end
	end
	local nameFilter = args[1] and getstring(1, args):lower() or nil
	for _, v in ipairs(workspace:GetDescendants()) do
		if v:IsA("TouchTransmitter") then
			if not nameFilter or v.Name:lower() == nameFilter or v.Parent.Name:lower() == nameFilter then
				touch(v)
			end
		end
	end
	Notify("Touch Interests", "Fired", Theme.Good)
end)

addcmd("fireproximityprompts", {"firepp"}, "Fire all proximity prompts", function(args)
	if not fireproximityprompt then
		return Notify("Incompatible", "Missing fireproximityprompt", Theme.Bad)
	end
	local nameFilter = args[1] and getstring(1, args) or nil
	for _, v in ipairs(workspace:GetDescendants()) do
		if v:IsA("ProximityPrompt") then
			if not nameFilter or v.Name == nameFilter or v.Parent.Name == nameFilter then
				fireproximityprompt(v)
			end
		end
	end
	Notify("Proximity Prompts", "Fired", Theme.Good)
end)

--========================================================================
-- Keep noclip alive across respawns; reset fly on respawn
--========================================================================
LocalPlayer.CharacterAdded:Connect(function()
	stopFly()
	if not Clip and NoclipConn then
		-- noclip loop already references LocalPlayer.Character, nothing to rebind
	end
end)

--========================================================================
-- Boot
--========================================================================
buildRows("")

--========================================================================
-- FuncFinder : fuzzy search remotes / modules / functions across the game
--========================================================================
local FuncFinder = {}
do
	local UI

	-- format helpers ---------------------------------------------------
	local function classIcon(class)
		local map = {
			RemoteEvent = "RE", RemoteFunction = "RF",
			BindableEvent = "BE", BindableFunction = "BF",
			ModuleScript = "MOD", LocalScript = "LS", Script = "SCR",
			Function = "fn", Table = "{}", Instance = "inst",
		}
		return map[class] or "?"
	end

	local function iconColor(class)
		if class == "RemoteEvent" or class == "RemoteFunction" then return Theme.Accent end
		if class == "ModuleScript" then return Theme.Accent2 end
		if class == "Function" then return Theme.Good end
		if class == "BindableEvent" or class == "BindableFunction" then return Color3.fromRGB(230, 180, 90) end
		return Theme.SubText
	end

	-- describe a raw lua function via debug.info -----------------------
	local function describeFunction(fn)
		local lines = {}
		if debug_info then
			local ok, src = pcall(debug_info, fn, "s")
			local ok2, line = pcall(debug_info, fn, "l")
			local ok3, name = pcall(debug_info, fn, "n")
			local ok4, nparams, isvararg = pcall(debug_info, fn, "a")
			if ok3 and name and name ~= "" then lines[#lines+1] = "name: " .. tostring(name) end
			if ok and src then lines[#lines+1] = "source: " .. tostring(src) end
			if ok2 and line then lines[#lines+1] = "line: " .. tostring(line) end
			if ok4 and nparams then
				lines[#lines+1] = "params: " .. tostring(nparams) .. (isvararg and " (+vararg)" or "")
			end
		end
		if islclosure_fn then
			lines[#lines+1] = (islclosure_fn(fn) and "type: Lua closure" or "type: C closure")
		end
		-- constants (often reveal remote names / keys)
		if getconstants_fn then
			local ok, consts = pcall(getconstants_fn, fn)
			if ok and type(consts) == "table" then
				local strs = {}
				for _, c in ipairs(consts) do
					if type(c) == "string" and #c > 0 and #c < 40 then
						strs[#strs+1] = c
						if #strs >= 12 then break end
					end
				end
				if #strs > 0 then lines[#lines+1] = "constants: " .. table.concat(strs, ", ") end
			end
		end
		-- upvalues
		if getupvalues_fn then
			local ok, ups = pcall(getupvalues_fn, fn)
			if ok and type(ups) == "table" then
				local n = 0
				for _ in pairs(ups) do n = n + 1 end
				if n > 0 then lines[#lines+1] = "upvalues: " .. n end
			end
		end
		return table.concat(lines, "\n")
	end

	-- search routines --------------------------------------------------
	-- returns array of { name, class, path, detail, ref }
	local function search(query)
		query = query:lower()
		local results = {}
		local seen = {}

		local function add(entry)
			-- de-dup by name+class+path
			local key = (entry.name or "") .. "|" .. (entry.class or "") .. "|" .. (entry.path or "")
			if seen[key] then return end
			seen[key] = true
			results[#results+1] = entry
		end

		-- 1) Instances: remotes, bindables, modules, scripts
		local ok = pcall(function()
			for _, inst in ipairs(game:GetDescendants()) do
				local cls = inst.ClassName
				if cls == "RemoteEvent" or cls == "RemoteFunction"
					or cls == "BindableEvent" or cls == "BindableFunction"
					or cls == "ModuleScript" or cls == "LocalScript" or cls == "Script" then
					if inst.Name:lower():find(query, 1, true) then
						local detail = {}
						local okPath, full = pcall(function() return inst:GetFullName() end)
						detail[#detail+1] = "class: " .. cls
						if okPath then detail[#detail+1] = "path: " .. full end

						-- for modules, try to require & introspect
						if cls == "ModuleScript" then
							local okReq, mod = pcall(require, inst)
							if okReq then
								detail[#detail+1] = "require: ok (" .. type(mod) .. ")"
								if type(mod) == "table" then
									local fns, keys = {}, {}
									for k, v in pairs(mod) do
										if type(k) == "string" then
											keys[#keys+1] = k .. " = " .. type(v)
											if type(v) == "function" then fns[#fns+1] = k end
										end
										if #keys >= 25 then break end
									end
									if #fns > 0 then detail[#detail+1] = "functions: " .. table.concat(fns, ", ") end
									if #keys > 0 then detail[#detail+1] = "members:\n  " .. table.concat(keys, "\n  ") end
								end
							else
								detail[#detail+1] = "require: failed"
							end
						end

						-- for local/server scripts, try to read their running environment
						if (cls == "LocalScript" or cls == "Script") and getsenv_fn then
							local okEnv, env = pcall(getsenv_fn, inst)
							if okEnv and type(env) == "table" then
								detail[#detail+1] = "getsenv: ok"
								local fns, keys = {}, {}
								local okIter = pcall(function()
									for k, v in pairs(env) do
										if type(k) == "string" then
											-- skip the standard roblox globals to reduce noise
											if not (k == "game" or k == "workspace" or k == "script"
												or k == "_G" or k == "shared" or k == "Enum") then
												keys[#keys+1] = k .. " = " .. type(v)
												if type(v) == "function" then fns[#fns+1] = k end
											end
										end
										if #keys >= 30 then break end
									end
								end)
								if #fns > 0 then detail[#detail+1] = "script functions: " .. table.concat(fns, ", ") end
								if #keys > 0 then detail[#detail+1] = "script globals:\n  " .. table.concat(keys, "\n  ") end
							else
								detail[#detail+1] = "getsenv: failed (script may not be running)"
							end
						end

						add({
							name = inst.Name, class = cls,
							path = okPath and full or "",
							detail = table.concat(detail, "\n"),
							ref = inst,
						})
					end
				end
			end
		end)

		-- 2) GC: loose functions and tables whose name matches
		if getgc_fn then
			pcall(function()
				local gc = getgc_fn(true) -- include tables
				for _, obj in ipairs(gc) do
					local t = type(obj)
					if t == "function" then
						-- match against debug name / source
						local nm = ""
						if debug_info then
							local okn, n = pcall(debug_info, obj, "n")
							if okn and n then nm = n end
						end
						if nm ~= "" and nm:lower():find(query, 1, true) then
							add({
								name = nm, class = "Function", path = "(gc)",
								detail = describeFunction(obj), ref = obj,
							})
						end
					elseif t == "table" then
						-- look for matching keys that hold functions
						local okIter = pcall(function()
							for k, v in pairs(obj) do
								if type(k) == "string" and k:lower():find(query, 1, true) and type(v) == "function" then
									add({
										name = k, class = "Function", path = "(gc table)",
										detail = describeFunction(v), ref = v,
									})
								end
							end
						end)
					end
				end
			end)
		end

		-- 3) Global environment scan
		pcall(function()
			local env = getgenv and getgenv() or _G
			for k, v in pairs(env) do
				if type(k) == "string" and k:lower():find(query, 1, true) then
					if type(v) == "function" then
						add({ name = k, class = "Function", path = "(getgenv)", detail = describeFunction(v), ref = v })
					elseif type(v) == "table" then
						add({ name = k, class = "Table", path = "(getgenv)", detail = "type: table", ref = v })
					end
				end
			end
		end)

		-- 4) Deep scan inside running script environments (getsenv)
		--    finds matching globals/functions defined inside LocalScripts/Scripts
		--    even when the script's own name doesn't match the query.
		if getsenv_fn then
			pcall(function()
				local scanned = 0
				for _, inst in ipairs(game:GetDescendants()) do
					if scanned >= 150 then break end -- cap to avoid huge scans
					local cls = inst.ClassName
					if cls == "LocalScript" or cls == "Script" then
						local okEnv, env = pcall(getsenv_fn, inst)
						if okEnv and type(env) == "table" then
							scanned = scanned + 1
							local okPath, full = pcall(function() return inst:GetFullName() end)
							local base = okPath and full or inst.Name
							pcall(function()
								for k, v in pairs(env) do
									if type(k) == "string" and k:lower():find(query, 1, true) then
										if k == "game" or k == "workspace" or k == "script"
											or k == "_G" or k == "shared" or k == "Enum" then
											-- skip standard globals
										elseif type(v) == "function" then
											add({
												name = k, class = "Function",
												path = base .. " (senv)",
												detail = "from script: " .. base .. "\n" .. describeFunction(v),
												ref = v,
											})
										elseif type(v) == "table" then
											add({
												name = k, class = "Table",
												path = base .. " (senv)",
												detail = "from script: " .. base .. "\ntype: table",
												ref = v,
											})
										end
									end
								end
							end)
						end
					end
				end
			end)
		end

		return results
	end

	-- UI ---------------------------------------------------------------
	local function buildUI()
		if UI then return UI end

		local root = make("Frame", {
			Name = "FuncFinder", Parent = ScreenGui,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0.5, 0),
			Size = UDim2.new(0, 720, 0, 460),
			BackgroundColor3 = Theme.Bg, Visible = false,
		})
		corner(12).Parent = root
		stroke(Theme.Stroke, 1).Parent = root

		-- header
		local header = make("Frame", {
			Parent = root, BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 46),
		})
		make("Frame", {
			Parent = header, BackgroundColor3 = Theme.Accent,
			Position = UDim2.new(0, 16, 0.5, -6), Size = UDim2.new(0, 12, 0, 12),
		}, { corner(3) })
		make("TextLabel", {
			Parent = header, BackgroundTransparency = 1,
			Position = UDim2.new(0, 38, 0, 0), Size = UDim2.new(0, 220, 1, 0),
			Font = Theme.FontBold, TextSize = 17, TextColor3 = Theme.Text,
			Text = "Function Finder", TextXAlignment = Enum.TextXAlignment.Left,
		})
		local closeBtn = make("TextButton", {
			Parent = header, BackgroundColor3 = Theme.Panel,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -12, 0.5, 0), Size = UDim2.new(0, 30, 0, 28),
			Font = Theme.FontBold, TextSize = 16, TextColor3 = Theme.Text, Text = "X",
		}, { corner(8), stroke(Theme.Stroke, 1) })

		-- search box
		local box = make("TextBox", {
			Parent = root, Name = "Search", BackgroundColor3 = Theme.Panel,
			Position = UDim2.new(0, 16, 0, 52), Size = UDim2.new(1, -32, 0, 34),
			Font = Theme.Font, TextSize = 15, TextColor3 = Theme.Text,
			PlaceholderText = "Search (e.g. Pet, Buy, Remote, GetData)...",
			PlaceholderColor3 = Theme.SubText, Text = "", ClearTextOnFocus = false,
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		corner(8).Parent = box
		stroke(Theme.Stroke, 1).Parent = box
		make("UIPadding", { Parent = box, PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) })

		local statusLbl = make("TextLabel", {
			Parent = root, BackgroundTransparency = 1,
			Position = UDim2.new(0, 16, 0, 92), Size = UDim2.new(1, -32, 0, 16),
			Font = Theme.Font, TextSize = 12, TextColor3 = Theme.SubText,
			Text = "Type a query and press Enter.", TextXAlignment = Enum.TextXAlignment.Left,
		})

		-- results list
		local list = make("ScrollingFrame", {
			Parent = root, BackgroundTransparency = 1,
			Position = UDim2.new(0, 16, 0, 114), Size = UDim2.new(1, -32, 1, -126),
			ScrollBarThickness = 5, ScrollBarImageColor3 = Theme.Accent,
			CanvasSize = UDim2.new(0, 0, 0, 0), BorderSizePixel = 0,
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
		})
		make("UIListLayout", { Parent = list, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder })

		draggable(root, header)

		closeBtn.MouseButton1Click:Connect(function() root.Visible = false end)

		-- render a single result row (expandable)
		local function addRow(entry, order)
			local expanded = false
			local row = make("Frame", {
				Parent = list, BackgroundColor3 = Theme.Panel,
				Size = UDim2.new(1, 0, 0, 44), LayoutOrder = order,
				ClipsDescendants = true, AutomaticSize = Enum.AutomaticSize.Y,
			})
			corner(8).Parent = row

			local headRow = make("TextButton", {
				Parent = row, BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, 44), Text = "", AutoButtonColor = false,
			})
			-- icon badge
			local badge = make("TextLabel", {
				Parent = headRow, BackgroundColor3 = iconColor(entry.class),
				Position = UDim2.new(0, 10, 0, 9), Size = UDim2.new(0, 40, 0, 26),
				Font = Theme.FontBold, TextSize = 11, TextColor3 = Color3.new(1,1,1),
				Text = classIcon(entry.class),
			})
			corner(6).Parent = badge
			make("TextLabel", {
				Parent = headRow, BackgroundTransparency = 1,
				Position = UDim2.new(0, 60, 0, 5), Size = UDim2.new(1, -120, 0, 18),
				Font = Theme.FontBold, TextSize = 14, TextColor3 = Theme.Text,
				Text = entry.name, TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
			})
			make("TextLabel", {
				Parent = headRow, BackgroundTransparency = 1,
				Position = UDim2.new(0, 60, 0, 22), Size = UDim2.new(1, -120, 0, 16),
				Font = Theme.Font, TextSize = 12, TextColor3 = Theme.SubText,
				Text = entry.path ~= "" and entry.path or entry.class,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
			})
			local copyBtn = make("TextButton", {
				Parent = headRow, BackgroundColor3 = Theme.Panel2,
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -10, 0.5, 0), Size = UDim2.new(0, 50, 0, 26),
				Font = Theme.Font, TextSize = 12, TextColor3 = Theme.Text, Text = "copy",
			}, { corner(6) })

			-- detail panel (hidden until expand)
			local detail = make("TextLabel", {
				Parent = row, BackgroundTransparency = 1, Visible = false,
				Position = UDim2.new(0, 60, 0, 44), Size = UDim2.new(1, -70, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y, Font = Enum.Font.Code, TextSize = 12,
				TextColor3 = Theme.SubText, Text = entry.detail ~= "" and entry.detail or "(no extra info)",
				TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
				TextWrapped = true,
			})
			make("UIPadding", { Parent = detail, PaddingBottom = UDim.new(0, 10) })

			headRow.MouseEnter:Connect(function() row.BackgroundColor3 = Theme.Panel2 end)
			headRow.MouseLeave:Connect(function() row.BackgroundColor3 = Theme.Panel end)
			headRow.MouseButton1Click:Connect(function()
				expanded = not expanded
				detail.Visible = expanded
			end)

			copyBtn.MouseButton1Click:Connect(function()
				local payload
				if entry.path ~= "" and entry.path ~= "(gc)" and entry.path ~= "(gc table)"
					and entry.path ~= "(getgenv)" then
					payload = entry.path
				else
					payload = entry.name
				end
				if setclipboard_fn then
					setclipboard_fn(tostring(payload))
					copyBtn.Text = "ok!"
					task.delay(1, function() if copyBtn then copyBtn.Text = "copy" end end)
				end
			end)
		end

		local function doSearch()
			for _, c in ipairs(list:GetChildren()) do
				if c:IsA("Frame") then c:Destroy() end
			end
			local q = box.Text:gsub("^%s+", ""):gsub("%s+$", "")
			if #q < 2 then
				statusLbl.Text = "Enter at least 2 characters."
				return
			end
			statusLbl.Text = "Searching..."
			task.wait()
			local results = search(q)
			-- sort: instances first, then by name
			table.sort(results, function(a, b)
				if a.class ~= b.class then return a.class < b.class end
				return a.name:lower() < b.name:lower()
			end)
			for i, entry in ipairs(results) do
				if i > 300 then break end -- cap render
				addRow(entry, i)
			end
			statusLbl.Text = ("%d result(s)%s for \"%s\""):format(
				#results, #results > 300 and " (showing 300)" or "", q)
		end

		box.FocusLost:Connect(function(enter)
			if enter then doSearch() end
		end)

		UI = {
			root = root, box = box,
			open = function(prefill)
				root.Visible = true
				if prefill and prefill ~= "" then
					box.Text = prefill
					doSearch()
				end
				box:CaptureFocus()
			end,
		}
		return UI
	end

	function FuncFinder.open(query)
		local ui = buildUI()
		ui.open(query)
	end
end

addcmd("funcfinder", {"ff", "findfunc"}, "Search remotes / modules / functions in the game", function(args)
	local q = args[1] and getstring(1, args) or ""
	FuncFinder.open(q)
	if not (getgc_fn) then
		Notify("FuncFinder", "Note: getgc unavailable — loose function search limited", Theme.Bad)
	end
end)

--========================================================================
-- Boot notice
--========================================================================
-- Load & apply saved theme (preset name or custom palette)
loadSettings()
if Settings.theme then
	if type(Settings.theme) == "string" then
		for i, preset in ipairs(ThemePresets) do
			if preset.name == Settings.theme then
				applyPresetByIndex(i, false)
				break
			end
		end
	elseif type(Settings.theme) == "table" then
		local palette = {}
		for _, key in ipairs(THEME_KEYS) do
			if Settings.theme[key] then palette[key] = arrToColor3(Settings.theme[key]) end
		end
		applyCustomPalette(palette, false)
	end
end

Notify("Catalyst", "Loaded " .. #Commands .. " commands. Prefix: " .. Prefix .. "  (Insert / RightShift to toggle)", Theme.Accent)

--========================================================================
-- Auto-execute commands from getgenv().Catalyst.AutoExecuteCommand
--========================================================================
if #Config.AutoExecuteCommand > 0 then
	task.spawn(function()
		task.wait(0.5) -- let the game/UI settle first
		for _, entry in ipairs(Config.AutoExecuteCommand) do
			if type(entry) == "string" and entry ~= "" then
				local ok, err = pcall(runCommand, entry)
				if not ok then
					Notify("AutoExec error", tostring(err), Theme.Bad)
				end
				task.wait(0.3) -- small gap between commands
			end
		end
	end)
end
