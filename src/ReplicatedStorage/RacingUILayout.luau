-- One safe rectangle and one set of reserved regions for every racing overlay.
local UIS = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local Layout = {}
local function rect(x, y, w, h)
	return {x = math.floor(x + 0.5), y = math.floor(y + 0.5), w = math.floor(w + 0.5), h = math.floor(h + 0.5)}
end

function Layout.mount(gui)
	gui.IgnoreGuiInset = false
	gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	gui.SafeAreaCompatibility = Enum.SafeAreaCompatibility.None
	gui.ClipToDeviceSafeArea = true
	local root = Instance.new("Frame")
	root.Name = "SafeHUD"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Active = false
	root.Parent = gui
	return root
end

function Layout.apply(object, bounds)
	object.AnchorPoint = Vector2.zero
	object.Position = UDim2.fromOffset(bounds.x, bounds.y)
	object.Size = UDim2.fromOffset(bounds.w, bounds.h)
end

function Layout.measure(root)
	local size = root.AbsoluteSize
	if size.X < 1 or size.Y < 1 then
		local camera = Workspace.CurrentCamera
		size = camera and camera.ViewportSize or Vector2.new(1280, 720)
	end
	local w, h = size.X, size.Y
	local touch = UIS.TouchEnabled
	local compact = w < 1000 or h < 600
	local portrait, narrow = w < h, w < 560
	local m = {touch = touch, compact = compact, portrait = portrait, width = w, height = h}
	if compact then
		local leftW = math.min(160, math.floor(w * 0.32))
		local rightW = math.min(190, math.floor(w * 0.34))
		local infoW = math.min(110, math.floor(w * 0.28))
		local coinW = math.clamp(w * 0.30, 96, 130)
		local actionW, actionH, driftW = 80, 88, 72
		local speedW, speedH = narrow and 120 or 126, 46
		local speedY = h - (narrow and 180 or (8 + speedH))
		m.info = rect(8, 8, infoW, 70)
		m.boardRows = narrow and 4 or 3
		m.board = rect(8, 86, leftW, 12 + m.boardRows * 18)
		m.coin = rect((w - coinW) / 2, 8, coinW, 38)
		m.coinPlus = rect((w - 112) / 2, 48, 112, 22)
		m.reset = rect(w - 96, 8, 88, 44)
		m.horn = rect(w - 152, 8, 48, 44)
		m.driftKing = rect((w - 210) / 2, 88, 210, 46)
		m.slot = rect(w - actionW - 8, h - actionH - 8, actionW, actionH)
		m.drift = rect(w - actionW - driftW - 16, h - driftW - 8, driftW, driftW)
		-- touch screens: hold-to-brake/reverse button right above the item slot (KartController)
		m.brake = rect(m.slot.x, m.slot.y - 58, actionW, 50)
		m.shield = rect(w - 56, m.brake.y - 60, 48, 52)
		if not narrow and w >= 620 then
			m.shield = rect(m.drift.x - 60, h - 60, 48, 52)
		end
		m.speed = rect((w - speedW) / 2, speedY, speedW, speedH)
		m.draft = rect((w - speedW) / 2, speedY - 34, speedW, 24)
		m.draftFlash = rect((w - 190) / 2, speedY - 68, 190, 26)
		local challengeH = narrow and math.min(164, h * 0.25) or math.min(150, math.max(40, math.min(m.shield.y, m.brake.y) - 68))
		m.challenges = rect(w - rightW - 8, 60, rightW, challengeH)
		local statusW = narrow and math.min(w - 24, 340) or math.clamp(w - leftW - rightW - 48, 160, 360)
		m.status = rect((w - statusW) / 2, narrow and h * 0.40 or 98, statusW, 42)
	else
		m.info = rect(16, 14, 190, 118)
		m.boardRows = 8
		m.board = rect(16, 142, 220, 208)
		m.coin = rect((w - 170) / 2, 70, 170, 52)
		m.coinPlus = rect(w / 2 + 95, 81, 120, 30)
		m.reset = rect(w - 136, 14, 120, 44)
		m.horn = rect(w - 196, 14, 52, 44)
		m.driftKing = rect((w - 300) / 2, 130, 300, 70)
		m.slot = rect(w - 144, h - 152, 124, 132)
		m.brake = rect(w - 134, h - 222, 104, 60)
		m.drift = rect(w - 264, h - 132, 104, 104)
		m.shield = rect(w - (touch and 364 or 238), h - 116, 84, 96)
		m.speed = rect((w - 230) / 2, h - 88, 230, 70)
		m.draft = rect((w - 230) / 2, h - 152, 230, 40)
		m.draftFlash = rect((w - 320) / 2, h - 196, 320, 38)
		m.challenges = rect(w - 286, h * 0.46 - 89, 270, 178)
		m.status = rect((w - 420) / 2, h * 0.32, 420, 42)
	end
	if touch and not compact then
		-- Large touchscreens retain generous controls and a clear lane beside the item.
		m.drift = rect(w - 248, h - 108, 88, 88)
	end
	local centerWidth = compact and not portrait and math.max(120, w - m.board.w - m.challenges.w - 48) or math.min(440, w - 24)
	m.banner = rect((w - centerWidth) / 2, compact and (portrait and h * 0.32 or 54) or 14, centerWidth, compact and 30 or 46)
	m.countdown = rect((w - math.min(300, w / 1.8)) / 2, h * 0.34 - 50, math.min(300, w / 1.8), 100)
	local toastWidth = compact and not portrait and centerWidth or math.min(560, w - 24)
	m.toast = rect((w - toastWidth) / 2, compact and (portrait and h * 0.45 or m.draftFlash.y - 48) or h * 0.58, toastWidth, compact and 42 or 48)
	m.challengePop = rect((w - math.min(460, w - 24)) / 2, h * 0.26, math.min(460, w - 24), compact and 42 or 50)
	-- Time Attack gets the first row; coins sit beneath it instead of above it.
	-- Keep the stack inside the same safe area as the rest of the racing HUD.
	m.timeAttack = rect(m.driftKing.x, compact and 8 or 14, m.driftKing.w, compact and 46 or 52)
	local player = Players.LocalPlayer
	local state = RS:GetAttribute("State")
	local timeAttack = RS:GetAttribute("RaceType") == "TimeAttack" and player and player:GetAttribute("Racing") == true
		and (state == "Racing" or state == "Countdown")
	if timeAttack then
		local coinY = m.timeAttack.y + m.timeAttack.h + 8
		local shift = coinY - m.coin.y
		m.coin.y = coinY
		m.coinPlus.y += shift
		m.banner.y = m.coin.y + m.coin.h + 8
		m.countdown.y = math.max(m.countdown.y, m.banner.y + m.banner.h + 12)
		m.status.y = math.max(m.status.y, m.coin.y + m.coin.h + 8)
	end
	-- Split/record messages are temporary, and must clear both the counter and +coin popup.
	m.timeAttackFlash = rect(m.timeAttack.x - 40, math.max(m.coin.y + m.coin.h, m.coinPlus.y + m.coinPlus.h) + 6,
		m.timeAttack.w + 80, compact and 30 or 44)
	return m
end

function Layout.observe(root, callback)
	local connections = {}
	local function refresh() if root.Parent then callback(Layout.measure(root)) end end
	table.insert(connections, root:GetPropertyChangedSignal("AbsoluteSize"):Connect(refresh))
	table.insert(connections, UIS:GetPropertyChangedSignal("TouchEnabled"):Connect(refresh))
	-- Mode and race transitions move the coin counter without needing a screen resize.
	for _, attribute in {"RaceType", "State"} do
		table.insert(connections, RS:GetAttributeChangedSignal(attribute):Connect(refresh))
	end
	local player = Players.LocalPlayer
	if player then table.insert(connections, player:GetAttributeChangedSignal("Racing"):Connect(refresh)) end
	root.Destroying:Connect(function() for _, connection in connections do connection:Disconnect() end end)
	refresh()
	task.defer(refresh)
end

return Layout
