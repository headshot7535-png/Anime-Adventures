--[[
  RNG Heroes — NexusLib executor script
  Version: 1.3.4
  PlaceId: 108307565942574

  AUTO EXECUTE (Anime Squadron pattern):
    queue_on_teleport re-runs this script after teleports. Queue kept armed +
    re-armed on OnTeleport / BindToClose. Optional autoexec reconnect loader.
    Min arm interval gated in _G to avoid double-queue.
    Boot gate _G.RNGHeroes_TP_BOOT (compat: RNGH_TP_BOOT) — set immediately so
    multiple autoexec copies cannot race and load twice.

  AUTO REJOIN PRIVATE (client-safe):
    Never read PrivateServerId / PrivateServerOwnerId (server-only).
    Never call TeleportToPrivateServer (server-only).
    Paste roblox.com/share?code=…&type=Server (or raw code) into the share field.
    Resolve via apis.roblox.com/sharelinks/v1/resolve-link → placeId/linkCode/jobId,
    then TeleportToPlaceInstance and/or deep-link join. Saved JobId is fallback.
    Wrong-server detect uses saved JobId when set (Save JobId while in your PS).

  Remotes / paths traced from dump (108307565942574_RNG_Heroes_*_full_dump.txt):
  ---------------------------------------------------------------------------
  Network hub: ReplicatedStorage.Remotes.<Name>  (client.Network.Network)
  Auto Roll:     InvokeServer("Roll", columnCount) | FireServer("SetAutoRoll", bool)
                 GetAutoRollState (Invoke) — Rolling module L27556 / L27740
  Upgrades:      FireServer("PurchaseUpgrade", upgradeId)
                 InvokeServer("GetUpgrades") → { upgrades = { [id]=true } }
  Prestige tree: FireServer("PurchasePrestigeUpgrade", id) | GetPrestigeUpgrades
  Index:         InvokeServer("PurchaseIndexUpgrade", key)
                 InvokeServer("GetIndexUpgrades") → { Luck/RollSpeed/Gold/Damage = level }
  Prestige:      FireServer("PrestigeRequested") | InvokeServer("GetPrestige") → { current }
  Zones:         FireServer("RequestZoneUnlock", zoneId)
                 InvokeServer("GetZoneUnlockState") → { unlocked, kills }
                 FireServer("TeleportToZone", zoneId)
  Heroes:        FireServer("EquipHero", heroId, size)
                 FireServer("UnequipHero", heroId, size, instanceId)
                 InvokeServer("GetInventory") → Heroes / EquippedHeroes / MaxEquippedHeroes
  Currency:      InvokeServer("GetCurrencies") → { balances = { Gold, IndexGems, ... } }
  Level:         InvokeServer("GetLevel") → { level, xp, required }
  Loot:          OnClientEvent("LootDelta") only — NO Collect remote.
                 Server MagnetRange (StatKeys default 10); client visuals in Workspace.Loot
                 Config: AutoLootDelaySeconds=0.6, LootMagnetTweenSeconds=1, LootPickupScanHz=10
                 Server pickup: player near loot LandPos (NOT visual CFrame). LootDelta
                 kind "PickedUp" + pickerPos drives client animatePickup → HRP.
                 Auto pickup: TP or walk (WalkToLoot) to each LandPos within MagnetRange.
  Power Rolls:   PlayerGui.Main.Bottom.PowerRoll (ImageButton) — IsMax "MAX", ClickToUse
                 "(Click to Use)", Boost "xN.N"; FireServer("SetPowerArmed", bool)
                 InvokeServer("GetPowerState") → { charge, capacity, armed, uses }
                 OnClientEvent("PowerDelta", state); IsMax.Visible when charge >= capacity
  Click Attack:  FireServer("ReportClickAttack", zoneId, slotIndex, hitPos)
                 client.Combat.Click tryHitEnemy — gated by ClickAttackUnlocked /
                 HoldToAttackUnlocked (gold upgrade id "Click Attack" Cost=5000).
                 Args: zone from Enemies.GetCurrentZone(), slot from EnemyRender
                 model name suffix, pos = Enemies.GetPosition (no proximity arg).
                 Cooldown: ClickAttackMaxPerSec default 3 → ~0.333s; remote 15/1.
                 No attack GUI button — UserInputService mouse/touch/gamepad only.
  AFK:           ReplicatedStorage.client.Afk.Afk (ModuleScript) → FireServer("RequestAfkRejoin")
                 Config.AfkRejoin.IdleSeconds=1080 — NOT a PlayerScripts LocalScript
  Rate limits:   Config.RemoteRateLimits (count/windowSec):
                 Roll 5/1, PurchaseUpgrade 10/1, PurchaseIndexUpgrade 10/1,
                 PurchasePrestigeUpgrade 10/1, PrestigeRequested 5/1,
                 RequestZoneUnlock 5/1, Equip/Unequip 30/1,
                 ReportClickAttack 15/1,
                 GetCurrencies/Get*Upgrades/GetPrestige/GetZoneUnlockState 5/5
                 SetPowerArmed/GetPowerState → default {20,1}
                 Default {20,1}. Client auto-roll wait: 0.1 / RollSpeedMul
]]

local SCRIPT_VERSION = "1.3.4"

-- Raw URL this script is hosted at (auto-execute / queue_on_teleport)
local SCRIPT_URL = "https://raw.githubusercontent.com/headshot7535-png/RNG-Heroes/refs/heads/main/RNG%20Heroes"

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local VIM = game:GetService("VirtualInputManager")
local UserInputService = game:GetService("UserInputService")

local g = (getgenv and getgenv()) or {}

local LP = Players.LocalPlayer
for _ = 1, 60 do
	if LP and LP:FindFirstChildOfClass("PlayerGui") then break end
	task.wait(0.3)
	LP = Players.LocalPlayer
end
if not LP then return end

----------------------------------------------------------------
-- Cleanup / tracking
-- NexusLib names ScreenGui = "NexusLib_" .. title:gsub("%s","")
-- so "RNG Heroes | v1.3.x" → "NexusLib_RNGHeroes|v1.3.x" (NOT NexusLib_RNGHeroes).
-- Old cleanup looked for the wrong exact name → re-exec left prior version GUIs alive.
----------------------------------------------------------------
local _conns, _threads = {}, {}
local _remotes = {}
local _lastRemoteAt = {} -- [remoteName] = os.clock()
local _remoteCache = {} -- [remoteName] = { t = clock, v = lastInvokeResult }
local Win -- forward; set when NexusLib window is created
local _session = {
	boughtUpgrade = {}, -- [id] = os.clock() last fire
	boughtPrestige = {},
	unlockedZone = {}, -- [zoneId] = os.clock() or true once confirmed
	autoRollWant = nil, -- last SetAutoRoll value we sent
	lastTpZone = nil,
	lastTpAt = 0,
	powerArmedThisCycle = false, -- armed once for current MAX fill (Power Rolls)
	powerState = nil, -- last { charge, capacity, armed, uses } from PowerDelta/GetPowerState
	lootPicked = 0, -- LootDelta kind "PickedUp" this session
	lootVisited = {}, -- [lootKey] = skipUntil clock (dedup failed/stuck)
	lootLandCache = {}, -- [Model] = Vector3 LandPos from client.Loot entity map
	lootLandCacheAt = 0,
}
local _modified = {
	afkConfigEnabled = nil,
}

local function addConn(c)
	if typeof(c) == "RBXScriptConnection" then
		_conns[#_conns + 1] = c
	end
	return c
end

local function addThread(t)
	if t then _threads[#_threads + 1] = t end
	return t
end

-- Destroy every RNG Heroes / NexusLib window from prior runs (any version).
local function destroyRngHeroesGuis()
	pcall(function()
		local w = _G.RNGHeroes_Win
		if w and type(w.Destroy) == "function" then
			w:Destroy()
		end
	end)
	_G.RNGHeroes_Win = nil
	pcall(function()
		local gui = _G.RNGHeroes_Gui
		if gui and gui.Parent then
			gui:Destroy()
		end
	end)
	_G.RNGHeroes_Gui = nil
	pcall(function()
		if Win and type(Win.Destroy) == "function" then
			Win:Destroy()
		end
	end)
	Win = nil
	pcall(function()
		local pg = LP:FindFirstChildOfClass("PlayerGui")
		if not pg then return end
		for _, c in ipairs(pg:GetChildren()) do
			if c:IsA("ScreenGui") then
				local n = c.Name
				-- Exact legacy name + versioned NexusLib titles (spaces stripped)
				if n == "NexusLib_RNGHeroes"
					or n:sub(1, #"NexusLib_RNGHeroes") == "NexusLib_RNGHeroes"
					or n:find("RNGHeroes", 1, true)
				then
					pcall(function() c:Destroy() end)
				end
			end
		end
	end)
end

local function cleanupAll()
	for _, c in ipairs(_conns) do
		pcall(function() c:Disconnect() end)
	end
	table.clear(_conns)
	for _, t in ipairs(_threads) do
		pcall(function() task.cancel(t) end)
	end
	table.clear(_threads)
	table.clear(_remotes)
	if _lastRemoteAt then table.clear(_lastRemoteAt) end
	if _remoteCache then table.clear(_remoteCache) end
	if _session then
		table.clear(_session.boughtUpgrade)
		table.clear(_session.boughtPrestige)
		table.clear(_session.unlockedZone)
		_session.autoRollWant = nil
		_session.lastTpZone = nil
		_session.lastTpAt = 0
		_session.powerArmedThisCycle = false
		_session.powerState = nil
		_session.lootPicked = 0
		if _session.lootVisited then table.clear(_session.lootVisited) end
		if _session.lootLandCache then table.clear(_session.lootLandCache) end
		_session.lootLandCacheAt = 0
	end

	if _modified.afkConfigEnabled ~= nil then
		pcall(function()
			local Shared = require(RS.shared.Shared)
			if Shared and Shared.Config and Shared.Config.AfkRejoin then
				Shared.Config.AfkRejoin.Enabled = _modified.afkConfigEnabled
			end
		end)
		_modified.afkConfigEnabled = nil
	end

	pcall(function()
		RunService:UnbindFromRenderStep("RNGHeroes_LootMagnet")
	end)

	-- Clear status before tearing down Win (best-effort)
	pcall(function()
		if Win and Win.Status then
			Win:Status("")
		end
	end)

	destroyRngHeroesGuis()
end

-- Kill previous instance FIRST (before gen bump / new UI)
if _G.RNGHeroesCleanup then
	pcall(_G.RNGHeroesCleanup)
end
destroyRngHeroesGuis()
pcall(function()
	RunService:UnbindFromRenderStep("RNGHeroes_LootMagnet")
end)

-- Unified kill token (stable key + legacy ScriptGen so older loops also die)
local GEN = math.max(tonumber(_G.RNGHeroes_Gen) or 0, tonumber(_G.ScriptGen) or 0) + 1
_G.RNGHeroes_Gen = GEN
_G.ScriptGen = GEN

_G.RNGHeroesCleanup = cleanupAll

local function alive()
	return _G.RNGHeroes_Gen == GEN and _G.ScriptGen == GEN
end

----------------------------------------------------------------
-- Settings (JSON, debounced)
----------------------------------------------------------------
local SETTINGS_FILE = "RNG_Heroes_Nexus.json"
local DiscordInvite = "https://discord.gg/" -- edit if you have a community invite

local Defaults = {
	AutoRoll = false,
	AntiAFK = true,
	AutoUpgrades = false,
	AutoNextArea = false,
	AutoEquipBest = false,
	AutoPickup = false,
	WalkToLoot = false, -- when AutoPickup: Humanoid:MoveTo LandPos instead of CFrame TP
	WalkToNextArea = false, -- when AutoNextArea: walk to zone Spawn instead of TeleportToZone+CF
	AutoPrestige = false,
	AutoPrestigeUpgrades = false,
	AutoIndexUpgrade = false,
	AutoUseMax = false, -- Power Rolls: arm at MAX (SetPowerArmed)
	AutoClickAttack = false, -- Kill Aura: ReportClickAttack (needs "Click Attack" upgrade)
	IndexLuck = true,
	IndexRollSpeed = true,
	IndexGold = true,
	IndexDamage = true,
	RollDelay = 0.2, -- dump Roll rate 5/1 → ≥0.2s; also 0.1/RollSpeedMul
	UpgradeDelay = 0.5,
	AreaDelay = 1.5,
	EquipDelay = 1.0,
	PickupDelay = 0.15, -- wait at LandPos for server LootPickupScanHz (~10Hz)
	PrestigeDelay = 2.0,
	PrestigeUpgradeDelay = 0.5,
	IndexDelay = 0.5,
	PowerUseDelay = 0.5, -- between SetPowerArmed attempts
	AfkClickSec = 60,
	Verbose = false,
	-- Teleport persistence (Anime Squadron pattern)
	AutoExecute = true,
	AutoexecInstall = false,
	ScriptUrl = SCRIPT_URL,
	-- Private server rejoin (share link primary, JobId fallback — client-safe)
	AutoRejoinPrivate = true,
	PrivateServerCode = "", -- share URL or raw code (roblox.com/share?code=…&type=Server)
	PrivateJobId = "", -- JobId saved while in your private server (fallback + wrong-server detect)
	PrivateServerIdSaved = "", -- legacy (unused; never read game.PrivateServerId)
}

local S = {}
for k, v in pairs(Defaults) do S[k] = v end

local function sanitizeBool(v, d)
	if v == true then return true end
	if v == false then return false end
	return d == true
end

local function sanitizeNum(v, d, lo, hi)
	local n = tonumber(v)
	if not n then return d end
	if lo then n = math.max(lo, n) end
	if hi then n = math.min(hi, n) end
	return n
end

local function loadSettings()
	local ok, raw = pcall(function()
		if isfile and isfile(SETTINGS_FILE) then
			return readfile(SETTINGS_FILE)
		end
		return nil
	end)
	if not ok or type(raw) ~= "string" or raw == "" then return end
	local ok2, data = pcall(function()
		return HttpService:JSONDecode(raw)
	end)
	if not ok2 or type(data) ~= "table" then return end
	S.AutoRoll = sanitizeBool(data.AutoRoll, Defaults.AutoRoll)
	S.AntiAFK = sanitizeBool(data.AntiAFK, Defaults.AntiAFK)
	S.AutoUpgrades = sanitizeBool(data.AutoUpgrades, Defaults.AutoUpgrades)
	S.AutoNextArea = sanitizeBool(data.AutoNextArea, Defaults.AutoNextArea)
	S.AutoEquipBest = sanitizeBool(data.AutoEquipBest, Defaults.AutoEquipBest)
	S.AutoPickup = sanitizeBool(data.AutoPickup, Defaults.AutoPickup)
	S.WalkToLoot = sanitizeBool(data.WalkToLoot, Defaults.WalkToLoot)
	S.WalkToNextArea = sanitizeBool(data.WalkToNextArea, Defaults.WalkToNextArea)
	S.AutoPrestige = sanitizeBool(data.AutoPrestige, Defaults.AutoPrestige)
	S.AutoPrestigeUpgrades = sanitizeBool(data.AutoPrestigeUpgrades, Defaults.AutoPrestigeUpgrades)
	S.AutoIndexUpgrade = sanitizeBool(data.AutoIndexUpgrade, Defaults.AutoIndexUpgrade)
	S.AutoUseMax = sanitizeBool(data.AutoUseMax, Defaults.AutoUseMax)
	S.AutoClickAttack = sanitizeBool(data.AutoClickAttack, Defaults.AutoClickAttack)
	S.IndexLuck = sanitizeBool(data.IndexLuck, Defaults.IndexLuck)
	S.IndexRollSpeed = sanitizeBool(data.IndexRollSpeed, Defaults.IndexRollSpeed)
	S.IndexGold = sanitizeBool(data.IndexGold, Defaults.IndexGold)
	S.IndexDamage = sanitizeBool(data.IndexDamage, Defaults.IndexDamage)
	S.RollDelay = sanitizeNum(data.RollDelay, Defaults.RollDelay, 0.05, 5)
	S.UpgradeDelay = sanitizeNum(data.UpgradeDelay, Defaults.UpgradeDelay, 0.05, 5)
	S.AreaDelay = sanitizeNum(data.AreaDelay, Defaults.AreaDelay, 0.2, 10)
	S.EquipDelay = sanitizeNum(data.EquipDelay, Defaults.EquipDelay, 0.1, 10)
	S.PickupDelay = sanitizeNum(data.PickupDelay, Defaults.PickupDelay, 0.05, 5)
	S.PrestigeDelay = sanitizeNum(data.PrestigeDelay, Defaults.PrestigeDelay, 0.5, 30)
	S.PrestigeUpgradeDelay = sanitizeNum(data.PrestigeUpgradeDelay, Defaults.PrestigeUpgradeDelay, 0.05, 5)
	S.IndexDelay = sanitizeNum(data.IndexDelay, Defaults.IndexDelay, 0.05, 5)
	S.PowerUseDelay = sanitizeNum(data.PowerUseDelay, Defaults.PowerUseDelay, 0.2, 5)
	S.AfkClickSec = sanitizeNum(data.AfkClickSec, Defaults.AfkClickSec, 10, 300)
	S.Verbose = sanitizeBool(data.Verbose, Defaults.Verbose)
	-- Teleport / private server
	S.AutoExecute = sanitizeBool(data.AutoExecute, Defaults.AutoExecute)
	S.AutoexecInstall = sanitizeBool(data.AutoexecInstall, Defaults.AutoexecInstall)
	if type(data.ScriptUrl) == "string" and data.ScriptUrl ~= "" then
		S.ScriptUrl = data.ScriptUrl
	else
		S.ScriptUrl = Defaults.ScriptUrl
	end
	S.AutoRejoinPrivate = sanitizeBool(data.AutoRejoinPrivate, Defaults.AutoRejoinPrivate)
	if type(data.PrivateServerCode) == "string" then
		S.PrivateServerCode = data.PrivateServerCode
	else
		S.PrivateServerCode = Defaults.PrivateServerCode
	end
	if type(data.PrivateJobId) == "string" then
		S.PrivateJobId = data.PrivateJobId
	else
		S.PrivateJobId = Defaults.PrivateJobId
	end
	if type(data.PrivateServerIdSaved) == "string" then
		S.PrivateServerIdSaved = data.PrivateServerIdSaved
	else
		S.PrivateServerIdSaved = Defaults.PrivateServerIdSaved
	end
end

local _savePending = false
local function saveSettingsNow()
	_savePending = false
	local payload = HttpService:JSONEncode(S)
	pcall(function()
		if writefile then writefile(SETTINGS_FILE, payload) end
	end)
end

local function saveSettingsDebounced()
	if _savePending then return end
	_savePending = true
	addThread(task.delay(0.75, function()
		if not alive() then return end
		saveSettingsNow()
	end))
end

loadSettings()

-- getgenv overrides (Anime Squadron style) + restore re-exec / private flags from _G
do
	if g.RNGHeroesAutoExecute ~= nil then
		S.AutoExecute = g.RNGHeroesAutoExecute ~= false
	elseif _G.RNGHeroes_AutoExecute ~= nil then
		S.AutoExecute = _G.RNGHeroes_AutoExecute == true
	end
	if type(g.RNGHeroesScriptURL) == "string" and g.RNGHeroesScriptURL ~= "" then
		S.ScriptUrl = g.RNGHeroesScriptURL
	end
	if g.RNGHeroesAutoexecInstall == true then
		S.AutoexecInstall = true
	end
	if g.RNGHeroesAutoRejoinPrivate ~= nil then
		S.AutoRejoinPrivate = g.RNGHeroesAutoRejoinPrivate == true
	elseif _G.RNGHeroes_AutoRejoinPrivate ~= nil then
		S.AutoRejoinPrivate = _G.RNGHeroes_AutoRejoinPrivate == true
	end
	if type(_G.RNGHeroes_PrivateJobId) == "string" and _G.RNGHeroes_PrivateJobId ~= "" then
		if S.PrivateJobId == "" then
			S.PrivateJobId = _G.RNGHeroes_PrivateJobId
		end
	end
	if type(_G.RNGHeroes_PrivateServerCode) == "string" and _G.RNGHeroes_PrivateServerCode ~= "" then
		if S.PrivateServerCode == "" then
			S.PrivateServerCode = _G.RNGHeroes_PrivateServerCode
		end
	end
	_G.RNGHeroes_AutoExecute = S.AutoExecute == true
	_G.RNGHeroes_AutoRejoinPrivate = S.AutoRejoinPrivate == true
	if S.PrivateJobId ~= "" then
		_G.RNGHeroes_PrivateJobId = S.PrivateJobId
	end
	if S.PrivateServerCode ~= "" then
		_G.RNGHeroes_PrivateServerCode = S.PrivateServerCode
	end
end

----------------------------------------------------------------
-- Shared modules (dump-backed; required live, not guessed)
----------------------------------------------------------------
local Shared, UpgradesMod, PrestigeUpgradesMod, ZonesMod, HeroesMod, SizesMod, PrestigeMod, IndexRewardsMod, EnemiesMod
do
	local ok, mod = pcall(function() return require(RS:WaitForChild("shared"):WaitForChild("Shared")) end)
	if ok then Shared = mod end
	ok, mod = pcall(function() return require(RS.shared.Upgrades.Upgrades) end)
	if ok then UpgradesMod = mod end
	ok, mod = pcall(function() return require(RS.shared.Upgrades.PrestigeUpgrades) end)
	if ok then PrestigeUpgradesMod = mod end
	ok, mod = pcall(function() return require(RS.shared.Zones.Zones) end)
	if ok then ZonesMod = mod end
	ok, mod = pcall(function() return require(RS.shared.Heroes.Heroes) end)
	if ok then HeroesMod = mod end
	ok, mod = pcall(function() return require(RS.shared.Sizes.Sizes) end)
	if ok then SizesMod = mod end
	ok, mod = pcall(function() return require(RS.shared.Prestige.Prestige) end)
	if ok then PrestigeMod = mod end
	ok, mod = pcall(function() return require(RS.shared.IndexRewards.IndexRewards) end)
	if ok then IndexRewardsMod = mod end
	-- client.Enemies.Enemies — Click.lua target API (GetCurrentZone / IterateZoneSlots / IsAlive / GetPosition)
	ok, mod = pcall(function() return require(RS.client.Enemies.Enemies) end)
	if ok then EnemiesMod = mod end
end

-- Gold upgrade that sets ClickAttackUnlocked (UpgradeData key / PurchaseUpgrade id)
local CLICK_ATTACK_UPGRADE_ID = "Click Attack"
local HOLD_TO_ATTACK_UPGRADE_ID = "Hold to Attack"

-- Index key → settings toggle (dump IndexRewards.Order: Luck/RollSpeed/Gold/Damage)
local INDEX_TOGGLE_KEY = {
	Luck = "IndexLuck",
	RollSpeed = "IndexRollSpeed",
	Gold = "IndexGold",
	Damage = "IndexDamage",
}

-- Fallback zone table from ZoneData dump if require fails
local ZONE_ORDER = (ZonesMod and ZonesMod.Order) or {
	"Starter", "Meadows", "Forest", "Beach", "Sea", "Arctic", "Jungle", "Badlands", "Shadowgrove"
}
local ZONE_COSTS = {
	Starter = 0, Meadows = 300, Forest = 6000, Beach = 100000, Sea = 2500000,
	Arctic = 50000000, Jungle = 750000000, Badlands = 5000000000, Shadowgrove = 75000000000,
}
local INDEX_ORDER = (IndexRewardsMod and IndexRewardsMod.Order) or { "Luck", "RollSpeed", "Gold", "Damage" }
local SIZE_ORDER = (SizesMod and SizesMod.Order) or { "Normal", "Huge", "Giant", "Colossal" }
local SIZE_MUL = { Normal = 1, Huge = 2, Giant = 3.5, Colossal = 5 }

----------------------------------------------------------------
-- Remote helpers + throttle (dump Config.RemoteRateLimits)
----------------------------------------------------------------
-- Never fire the same remote more than once per ~0.1s without checking game limits.
-- Gaps derived from {maxCalls, windowSec} → window/max (reads 5/5 → ~1s).
local MIN_SAME_REMOTE = 0.1
local REMOTE_MIN_GAP = {
	Roll = 0.2, -- 5/1
	SetAutoRoll = 0.5,
	PurchaseUpgrade = 0.12, -- 10/1 (feature also uses UpgradeDelay)
	PurchaseIndexUpgrade = 0.12,
	PurchasePrestigeUpgrade = 0.12,
	PrestigeRequested = 0.25, -- 5/1
	RequestZoneUnlock = 0.25, -- 5/1
	TeleportToZone = 0.5,
	EquipHero = 0.1, -- 30/1
	UnequipHero = 0.1,
	GetCurrencies = 1.05, -- 5/5
	GetIndexUpgrades = 1.05,
	GetPrestigeUpgrades = 1.05,
	GetPrestige = 1.05,
	GetZoneUnlockState = 1.05,
	GetUpgrades = 1.05,
	GetInventory = 1.0,
	GetLevel = 1.05,
	GetAutoRollState = 1.05,
	GetPowerState = 1.05, -- default {20,1} but read rarely
	SetPowerArmed = 0.1, -- default {20,1}; keep ≥ MIN_SAME_REMOTE
	ReportClickAttack = 1 / 15, -- Config.RemoteRateLimits 15/1; feature also uses ClickAttackMaxPerSec
}

local RemotesFolder = RS:WaitForChild("Remotes", 30)

local function remoteGap(name)
	local g = REMOTE_MIN_GAP[name]
	if g then return math.max(g, MIN_SAME_REMOTE) end
	return MIN_SAME_REMOTE
end

local function remoteReady(name, extraGap)
	local gap = math.max(remoteGap(name), extraGap or 0)
	local last = _lastRemoteAt[name] or 0
	return (os.clock() - last) >= gap
end

local function markRemote(name)
	_lastRemoteAt[name] = os.clock()
end

local function invalidateCache(name)
	_remoteCache[name] = nil
end

local function getRemote(name)
	local cached = _remotes[name]
	if cached and cached.Parent then return cached end
	if not RemotesFolder then
		RemotesFolder = RS:FindFirstChild("Remotes")
	end
	if not RemotesFolder then return nil end
	local r = RemotesFolder:FindFirstChild(name)
	if not r then
		local ok, waited = pcall(function()
			return RemotesFolder:WaitForChild(name, 5)
		end)
		if ok then r = waited end
	end
	_remotes[name] = r
	return r
end

-- fireR: returns ok, err; skips if throttled (ok=false, err="throttled")
local function fireR(name, ...)
	if not remoteReady(name) then
		return false, "throttled"
	end
	local r = getRemote(name)
	if not r then return false, "missing remote " .. tostring(name) end
	local ok, err = pcall(function(...)
		r:FireServer(...)
	end, ...)
	if ok then markRemote(name) end
	return ok, err
end

-- invokeR: returns result or cached/nil; skips network if throttled (uses cache when present)
local function invokeR(name, ...)
	local cached = _remoteCache[name]
	if not remoteReady(name) then
		if cached then return cached.v end
		return nil
	end
	local r = getRemote(name)
	if not r then return nil end
	local pack = table.pack(pcall(function(...)
		return r:InvokeServer(...)
	end, ...))
	if not pack[1] then return nil end
	markRemote(name)
	local v = pack[2]
	_remoteCache[name] = { t = os.clock(), v = v }
	return v
end

local function invokeR2(name, ...)
	local cached = _remoteCache[name]
	if not remoteReady(name) then
		if cached then return true, cached.v end
		return false, "throttled"
	end
	local r = getRemote(name)
	if not r then return false end
	local pack = table.pack(pcall(function(...)
		return r:InvokeServer(...)
	end, ...))
	if pack[1] then
		markRemote(name)
		_remoteCache[name] = { t = os.clock(), v = pack[2] }
	end
	return table.unpack(pack, 1, pack.n)
end

-- Only FireServer SetAutoRoll when desired state changes
local function ensureAutoRoll(want)
	want = want == true
	if _session.autoRollWant == want then
		return true
	end
	local ok = fireR("SetAutoRoll", want)
	if ok then
		_session.autoRollWant = want
	end
	return ok
end

local function getCurrentZoneId()
	local z = LP:GetAttribute("CurrentZone")
	if type(z) == "string" and z ~= "" then return z end
	return nil
end

-- dump Rolling wait: task.wait(0.1 / getRollSpeedMul()); rate limit Roll 5/1
local function getRollInterval()
	local mul = 1
	pcall(function()
		local ownedSnap = _remoteCache.GetUpgrades and _remoteCache.GetUpgrades.v
		local owned = {}
		if type(ownedSnap) == "table" then
			owned = ownedSnap.upgrades or ownedSnap or {}
		end
		local prestigeOwned = {}
		local pSnap = _remoteCache.GetPrestigeUpgrades and _remoteCache.GetPrestigeUpgrades.v
		if type(pSnap) == "table" then
			prestigeOwned = pSnap.upgrades or pSnap or {}
		end
		if Shared and Shared.GetStat then
			mul = Shared.GetStat("RollSpeed", owned, prestigeOwned, 1) or 1
		end
		mul = mul
			* (tonumber(LP:GetAttribute("IndexRollSpeedMul")) or 1)
			* (tonumber(LP:GetAttribute("GamepassRollSpeedMul")) or 1)
			* (tonumber(LP:GetAttribute("EventRollSpeedMul")) or 1)
			* (tonumber(LP:GetAttribute("PotionRollSpeedMul")) or 1)
	end)
	local gameWait = 0.1 / math.max(mul, 0.05)
	return math.max(0.2, S.RollDelay, gameWait)
end

local function adjustCachedBalance(currency, delta)
	local c = _remoteCache.GetCurrencies
	if c and type(c.v) == "table" and type(c.v.balances) == "table" then
		local b = c.v.balances
		b[currency] = math.max(0, (tonumber(b[currency]) or 0) + delta)
	end
end

----------------------------------------------------------------
-- Status / Win ref (filled after GUI)
----------------------------------------------------------------
local function status(msg)
	if Win and Win.Status then
		pcall(function() Win:Status(msg) end)
	end
end

local function notify(title, msg, t, kind)
	if Win and Win.Notify then
		pcall(function() Win:Notify(title, msg, t or 3, kind or "info") end)
	end
end

local function dbg(...)
	if S.Verbose then
		print("[RNG Heroes]", ...)
	end
end

----------------------------------------------------------------
-- Currency / snapshot helpers
----------------------------------------------------------------
local function getBalances()
	local snap = invokeR("GetCurrencies")
	if type(snap) == "table" and type(snap.balances) == "table" then
		return snap.balances
	end
	return {}
end

local function getGold()
	local b = getBalances()
	return tonumber(b.Gold) or 0
end

local function getIndexGems()
	local b = getBalances()
	return tonumber(b.IndexGems) or 0
end

local function getPrestigeTokens()
	local b = getBalances()
	return tonumber(b.PrestigeTokens) or 0
end

local function getLevel()
	local snap = invokeR("GetLevel")
	if type(snap) == "table" then
		return tonumber(snap.level) or 1
	end
	return 1
end

local function getPrestigeCurrent()
	local attr = LP:GetAttribute("CurrentPrestige")
	if type(attr) == "string" and attr ~= "" then return attr end
	local snap = invokeR("GetPrestige")
	if type(snap) == "table" and type(snap.current) == "string" then
		return snap.current
	end
	if PrestigeMod and PrestigeMod.GetStarting then
		local start = select(1, PrestigeMod.GetStarting())
		return start
	end
	return nil
end

local function getRollColumns()
	-- dump Rolling.autoRollLoop L27708
	local v = (tonumber(LP:GetAttribute("GamepassRollColumns")) or 1)
		+ (tonumber(LP:GetAttribute("EventExtraColumns")) or 0)
	return math.clamp(math.floor(v), 1, 5)
end

----------------------------------------------------------------
-- Power Rolls (dump: client.PowerRolls.PowerRolls)
-- GUI: PlayerGui.Main.Bottom.PowerRoll
-- MAX: IsMax.Visible when charge >= capacity (paint); Text == "MAX"
-- Click: FireServer("SetPowerArmed", not armed) — we send true when MAX
----------------------------------------------------------------
local function getPowerRollBtn()
	local pg = LP:FindFirstChildOfClass("PlayerGui")
	if not pg then return nil end
	local main = pg:FindFirstChild("Main")
	local bottom = main and main:FindFirstChild("Bottom")
	local btn = bottom and bottom:FindFirstChild("PowerRoll")
	if btn and btn:IsA("GuiButton") then return btn end
	return nil
end

local function applyPowerState(snap)
	if type(snap) ~= "table" then return end
	local charge = tonumber(snap.charge) or 0
	local capacity = tonumber(snap.capacity) or 0
	local armed = snap.armed == true
	local uses = tonumber(snap.uses) or 0
	_session.powerState = {
		charge = charge,
		capacity = capacity,
		armed = armed,
		uses = uses,
	}
	-- New charge cycle once bar leaves MAX / is consumed
	local atMax = capacity > 0 and charge >= (capacity - 1e-6)
	if not atMax or (not armed and charge <= 0) then
		_session.powerArmedThisCycle = false
	end
	if armed then
		_session.powerArmedThisCycle = true
	end
end

local function isPowerMaxFromGui()
	local btn = getPowerRollBtn()
	if not btn or not btn.Visible then return false end
	local isMax = btn:FindFirstChild("IsMax")
	if not isMax or not isMax:IsA("TextLabel") then return false end
	-- dump paint: u20.Visible = u5 >= u6 - 1e-6
	if isMax.Visible and (isMax.Text == "MAX" or tostring(isMax.Text):upper():find("MAX", 1, true)) then
		return true
	end
	return false
end

local function isPowerMax()
	local st = _session.powerState
	if st and type(st.capacity) == "number" and st.capacity > 0 then
		return (tonumber(st.charge) or 0) >= ((tonumber(st.capacity) or 0) - 1e-6)
	end
	return isPowerMaxFromGui()
end

local function isPowerArmed()
	local st = _session.powerState
	if st then return st.armed == true end
	return false
end

local function clickPowerRollFallback()
	local btn = getPowerRollBtn()
	if not btn then return false end
	-- Prefer Activated (dump PowerRolls connects Activated), then MouseButton1Click
	local ok = pcall(function()
		if firesignal then
			firesignal(btn.Activated)
			return
		end
		error("no firesignal")
	end)
	if ok then return true end
	ok = pcall(function()
		if firesignal then
			firesignal(btn.MouseButton1Click)
			return
		end
		error("no firesignal")
	end)
	if ok then return true end
	ok = pcall(function()
		if not getconnections then error("no getconnections") end
		for _, sigName in ipairs({ "Activated", "MouseButton1Click" }) do
			local sig = btn[sigName]
			if sig then
				for _, c in ipairs(getconnections(sig)) do
					if c.Function then
						pcall(c.Function)
					end
				end
			end
		end
	end)
	return ok
end

-- Arm Power Rolls at MAX (dump: Network.FireServer("SetPowerArmed", not u7))
local function tryArmPowerMax()
	if isPowerArmed() or _session.powerArmedThisCycle then
		return true, "already armed"
	end
	if not isPowerMax() then
		return false, "not max"
	end
	local ok, err = fireR("SetPowerArmed", true)
	if ok then
		_session.powerArmedThisCycle = true
		if _session.powerState then
			_session.powerState.armed = true
		end
		return true, "remote"
	end
	if err == "throttled" then
		return false, "throttled"
	end
	-- Fallback: click GUI (toggles armed — only when we know not armed)
	if clickPowerRollFallback() then
		_session.powerArmedThisCycle = true
		return true, "click"
	end
	return false, err or "failed"
end

local function setupPowerDeltaListener()
	local r = getRemote("PowerDelta")
	if not r then return end
	addConn(r.OnClientEvent:Connect(function(snap)
		if not alive() then return end
		applyPowerState(snap)
	end))
	-- Initial snapshot (dump PowerRolls.Start invokes GetPowerState)
	addThread(task.spawn(function()
		task.wait(0.5)
		if not alive() then return end
		local snap = invokeR("GetPowerState")
		applyPowerState(snap)
	end))
end

local function getSizeMul(size)
	if SizesMod and SizesMod.GetStatMul then
		return SizesMod.GetStatMul(size) or 1
	end
	return SIZE_MUL[size] or 1
end

local function heroBucketDps(heroId, size, bestOwnedDps)
	if not HeroesMod then return 0 end
	local mul = getSizeMul(size)
	if HeroesMod.IsPercentOfBest and HeroesMod.IsPercentOfBest(heroId) then
		return (HeroesMod.GetEffectiveBaseDps(heroId, bestOwnedDps) or 0) * mul
	end
	return (HeroesMod.GetBaseDps(heroId) or 0) * mul
end

----------------------------------------------------------------
-- Feature loops
----------------------------------------------------------------
local function stopAllLoops()
	S.AutoRoll = false
	S.AutoUpgrades = false
	S.AutoNextArea = false
	S.AutoEquipBest = false
	S.AutoPickup = false
	S.AutoPrestige = false
	S.AutoPrestigeUpgrades = false
	S.AutoIndexUpgrade = false
	S.AutoUseMax = false
	S.AutoClickAttack = false
	ensureAutoRoll(false)
	saveSettingsDebounced()
	status("All loops stopped")
	notify("Stopped", "All feature loops disabled", 3, "warn")
end

-- Auto Use Max / Power Rolls (dump: SetPowerArmed when IsMax / charge >= capacity)
local function loopAutoUseMax()
	addThread(task.spawn(function()
		local lastPoll = 0
		while alive() do
			if S.AutoUseMax then
				-- Refresh state occasionally if PowerDelta missed / no snapshot yet
				local now = os.clock()
				if not _session.powerState or (now - lastPoll) >= 2.5 then
					if remoteReady("GetPowerState") then
						local snap = invokeR("GetPowerState")
						applyPowerState(snap)
						lastPoll = now
					end
				end
				-- If remote state missing, GUI IsMax still works
				if isPowerMax() then
					if isPowerArmed() or _session.powerArmedThisCycle then
						status("Power Rolls: armed (MAX)")
					else
						local ok, how = tryArmPowerMax()
						if ok and how ~= "already armed" then
							status("Power Rolls: used at MAX (" .. tostring(how) .. ")")
							dbg("SetPowerArmed via", how)
						elseif not ok and how ~= "not max" and how ~= "throttled" then
							status("Power Rolls: arm failed")
							dbg("arm failed", how)
						end
					end
				else
					_session.powerArmedThisCycle = false
				end
				task.wait(S.PowerUseDelay)
			else
				task.wait(0.4)
			end
		end
	end))
end

-- Owned upgrade snapshot helper (GetUpgrades → { upgrades = { [id]=true } })
local function getOwnedUpgradesMap()
	local ownedSnap = invokeR("GetUpgrades")
	local owned = {}
	if type(ownedSnap) == "table" then
		owned = ownedSnap.upgrades or ownedSnap or {}
	end
	return owned
end

local function getPrestigeOwnedMap()
	local snap = _remoteCache.GetPrestigeUpgrades and _remoteCache.GetPrestigeUpgrades.v
	if type(snap) ~= "table" then
		snap = invokeR("GetPrestigeUpgrades")
	end
	local owned = {}
	if type(snap) == "table" then
		owned = snap.upgrades or snap or {}
	end
	return owned
end

-- Click.lua: ClickAttackUnlocked / HoldToAttackUnlocked via Shared.GetStat
local function hasClickAttackUnlocked(owned, prestigeOwned)
	owned = owned or {}
	prestigeOwned = prestigeOwned or {}
	if Shared and Shared.GetStat then
		local clickOk = Shared.GetStat("ClickAttackUnlocked", owned, prestigeOwned, false) and true or false
		local holdOk = Shared.GetStat("HoldToAttackUnlocked", owned, prestigeOwned, false) and true or false
		return clickOk or holdOk
	end
	return (owned[CLICK_ATTACK_UPGRADE_ID] or owned[HOLD_TO_ATTACK_UPGRADE_ID]) and true or false
end

-- Click.lua getMinClickInterval: 1 / max(ClickAttackMaxPerSec, 0.001); StatKeys default 3
local function getClickAttackInterval(owned, prestigeOwned)
	local maxPerSec = 3
	pcall(function()
		if Shared and Shared.GetStat then
			maxPerSec = Shared.GetStat("ClickAttackMaxPerSec", owned or {}, prestigeOwned or {}, 3) or 3
		end
	end)
	local interval = 1 / math.max(tonumber(maxPerSec) or 3, 0.001)
	-- Never faster than remote throttle (15/1 → ~0.067; MIN_SAME_REMOTE 0.1)
	return math.max(interval, remoteGap("ReportClickAttack"))
end

-- Try PurchaseUpgrade("Click Attack") once when Affordable; returns "bought" | "need" | "owned" | "wait"
local function tryBuyClickAttackUpgrade(owned)
	owned = owned or getOwnedUpgradesMap()
	if owned[CLICK_ATTACK_UPGRADE_ID] then
		return "owned"
	end
	local last = _session.boughtUpgrade[CLICK_ATTACK_UPGRADE_ID]
	if last and (os.clock() - last) < 4 then
		return "wait"
	end
	if not UpgradesMod or not UpgradesMod.GetState then
		return "need"
	end
	local gold = getGold()
	local def = UpgradesMod.Get and UpgradesMod.Get(CLICK_ATTACK_UPGRADE_ID)
	local branch = (def and def.Branch) or "Root"
	local state = UpgradesMod.GetState(CLICK_ATTACK_UPGRADE_ID, owned, gold, branch)
	if state == "Affordable" then
		local ok = fireR("PurchaseUpgrade", CLICK_ATTACK_UPGRADE_ID)
		if ok then
			_session.boughtUpgrade[CLICK_ATTACK_UPGRADE_ID] = os.clock()
			local cost = def and tonumber(def.Cost) or 0
			if cost > 0 then adjustCachedBalance("Gold", -cost) end
			invalidateCache("GetUpgrades")
			dbg("Purchased Click Attack upgrade")
			return "bought"
		end
		return "wait"
	end
	return "need"
end

-- Prefer Enemies module; fallback Workspace.EnemyRender model name suffix (Click.lua resolveEnemyFromPart)
local function findNearestClickTarget()
	local char = LP.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local origin = root and root.Position
	if not origin then
		return nil
	end

	if EnemiesMod and EnemiesMod.GetCurrentZone and EnemiesMod.IterateZoneSlots then
		local zone = EnemiesMod.GetCurrentZone()
		if not zone then
			zone = getCurrentZoneId()
		end
		if zone then
			local bestSlot, bestPos, bestDist = nil, nil, math.huge
			for slot in EnemiesMod.IterateZoneSlots(zone) do
				if EnemiesMod.IsAlive(zone, slot) then
					local pos = EnemiesMod.GetPosition(zone, slot)
					if pos then
						local d = (pos - origin).Magnitude
						if d < bestDist then
							bestDist = d
							bestSlot = slot
							bestPos = pos
						end
					end
				end
			end
			if bestSlot and bestPos then
				return zone, bestSlot, bestPos
			end
		end
	end

	-- Fallback: EnemyRender children named "..._<slot>"
	local render = Workspace:FindFirstChild("EnemyRender")
	if not render then
		return nil
	end
	local zone = getCurrentZoneId()
	if not zone then
		return nil
	end
	local bestSlot, bestPos, bestDist = nil, nil, math.huge
	for _, model in ipairs(render:GetChildren()) do
		if model:IsA("Model") then
			local at = string.find(model.Name, "_[^_]*$")
			local slot = at and tonumber(string.sub(model.Name, at + 1))
			local pp = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
			if slot and pp and pp.Parent then
				local pos = pp.Position
				local d = (pos - origin).Magnitude
				if d < bestDist then
					bestDist = d
					bestSlot = slot
					bestPos = pos
				end
			end
		end
	end
	if bestSlot and bestPos then
		return zone, bestSlot, bestPos
	end
	return nil
end

-- Auto Click Attack / Kill Aura (dump: FireServer("ReportClickAttack", zone, slot, pos))
local function loopAutoClickAttack()
	addThread(task.spawn(function()
		local lastBuyTry = 0
		while alive() do
			if S.AutoClickAttack then
				local owned = getOwnedUpgradesMap()
				local prestigeOwned = getPrestigeOwnedMap()
				if not hasClickAttackUnlocked(owned, prestigeOwned) then
					local now = os.clock()
					if (now - lastBuyTry) >= 2.5 then
						lastBuyTry = now
						local result = tryBuyClickAttackUpgrade(owned)
						if result == "bought" then
							status("Click Attack: bought upgrade")
							notify("Click Attack", "Purchased Click Attack upgrade", 3, "success")
						elseif result == "wait" then
							status("Click Attack: unlocking…")
						elseif result == "need" then
							status("need Click Attack upgrade")
						end
					else
						status("need Click Attack upgrade")
					end
					task.wait(0.6)
				else
					local zone, slot, pos = findNearestClickTarget()
					if not (zone and slot and pos) then
						status("Click Attack: no targets")
						task.wait(0.35)
					elseif remoteReady("ReportClickAttack") then
						local ok, err = fireR("ReportClickAttack", zone, slot, pos)
						if ok then
							status("Click Attack: attacking")
							dbg("ReportClickAttack", zone, slot)
						elseif err ~= "throttled" then
							status("Click Attack: fire failed")
							dbg("ReportClickAttack failed", err)
						end
						task.wait(getClickAttackInterval(owned, prestigeOwned))
					else
						task.wait(0.05)
					end
				end
			else
				task.wait(0.4)
			end
		end
	end))
end

-- Auto Roll (dump: Network.InvokeServer("Roll", columns) + SetAutoRoll)
local function loopAutoRoll()
	addThread(task.spawn(function()
		while alive() do
			if S.AutoRoll then
				status("Auto Roll…")
				ensureAutoRoll(true)
				if remoteReady("Roll") then
					local cols = getRollColumns()
					local result = invokeR("Roll", cols)
					if type(result) ~= "table" then
						dbg("Roll returned", result)
					end
				end
				task.wait(getRollInterval())
			else
				-- do not spam SetAutoRoll(false) every tick — only once when leaving ON
				task.wait(0.35)
			end
		end
	end))
end

-- Anti-AFK (dump: client.Afk.Afk → RequestAfkRejoin after IdleSeconds)
local function setupAntiAFK()
	-- No AFK LocalScript under PlayerScripts in dump; only ModuleScript Afk.
	-- Soft-disable Config + VirtualInputManager keepalive.
	addThread(task.spawn(function()
		while alive() do
			if S.AntiAFK then
				pcall(function()
					if Shared and Shared.Config and Shared.Config.AfkRejoin then
						if _modified.afkConfigEnabled == nil then
							_modified.afkConfigEnabled = Shared.Config.AfkRejoin.Enabled
						end
						Shared.Config.AfkRejoin.Enabled = false
					end
				end)
				-- Disable any PlayerScripts child with AFK in the name (defensive)
				pcall(function()
					local ps = LP:FindFirstChild("PlayerScripts")
					if ps then
						for _, c in ipairs(ps:GetDescendants()) do
							if c:IsA("LocalScript") and string.find(string.lower(c.Name), "afk", 1, true) then
								c.Disabled = true
							end
						end
					end
				end)
				-- Backup: VirtualInputManager click (user-rule pattern)
				pcall(function()
					VIM:SendMouseButtonEvent(0, 0, 0, true, game, 1)
					VIM:SendMouseButtonEvent(0, 0, 0, false, game, 1)
				end)
				status("Anti-AFK active")
				task.wait(S.AfkClickSec)
			else
				task.wait(1)
			end
		end
	end))

	-- Also poke on Roblox Idled signal
	addConn(LP.Idled:Connect(function()
		if not alive() or not S.AntiAFK then return end
		pcall(function()
			VIM:SendMouseButtonEvent(0, 0, 0, true, game, 1)
			VIM:SendMouseButtonEvent(0, 0, 0, false, game, 1)
		end)
	end))
end

-- Auto Upgrades (dump: FireServer("PurchaseUpgrade", id) when GetState == "Affordable")
local function loopAutoUpgrades()
	addThread(task.spawn(function()
		while alive() do
			if S.AutoUpgrades then
				if not UpgradesMod then
					status("Auto Upgrades: Upgrades module not found in dump path")
					task.wait(3)
				else
					local ownedSnap = invokeR("GetUpgrades")
					local owned = {}
					if type(ownedSnap) == "table" then
						owned = ownedSnap.upgrades or ownedSnap or {}
					end
					-- sync session dedup with server owned
					for id, v in pairs(owned) do
						if v then _session.boughtUpgrade[id] = nil end -- confirmed owned; no need to track
					end
					local gold = getGold()
					local bought = 0
					for _, id in ipairs(UpgradesMod.Order()) do
						if not alive() or not S.AutoUpgrades then break end
						if owned[id] then
							-- already bought
						elseif _session.boughtUpgrade[id] and (os.clock() - _session.boughtUpgrade[id]) < 3 then
							-- recently fired; wait for ownership state change
						else
							local def = UpgradesMod.Get(id)
							local branch = def and def.Branch or "Root"
							local state = UpgradesMod.GetState(id, owned, gold, branch)
							if state == "Affordable" then
								status("Buying upgrade: " .. tostring(id))
								local ok = fireR("PurchaseUpgrade", id)
								if ok then
									_session.boughtUpgrade[id] = os.clock()
									owned[id] = true
									bought = bought + 1
									local cost = def and tonumber(def.Cost) or 0
									if cost > 0 then adjustCachedBalance("Gold", -cost) end
									gold = getGold()
									invalidateCache("GetUpgrades")
								end
								task.wait(S.UpgradeDelay)
							end
						end
					end
					if bought == 0 then
						status("Auto Upgrades: nothing affordable")
						task.wait(1.25)
					end
				end
			else
				task.wait(0.4)
			end
		end
	end))
end

-- Auto Next Area (dump: RequestZoneUnlock then TeleportToZone + local Spawn CF)
-- Zone ids are Order keys (Beach), display names are ZoneData.DisplayName ("The Beach").
local function zoneDisplayName(zoneId)
	zoneId = tostring(zoneId)
	if ZonesMod and ZonesMod.Get then
		local z = ZonesMod.Get(zoneId)
		if type(z) == "table" and type(z.DisplayName) == "string" then
			return z.DisplayName
		end
	end
	return zoneId
end

local function getZoneSpawnPart(zoneId)
	local zonesFolder = workspace:FindFirstChild("Zones")
	local zoneModel = zonesFolder and zonesFolder:FindFirstChild(tostring(zoneId))
	if not zoneModel then return nil end
	local spawn = zoneModel:FindFirstChild("Spawn")
	if spawn and spawn:IsA("BasePart") then return spawn end
	spawn = zoneModel:FindFirstChild("Spawn", true)
	if spawn and spawn:IsA("BasePart") then return spawn end
	return nil
end

local function isZoneUnlockedMap(zoneId, unlocked)
	if ZonesMod and ZonesMod.IsUnlockedByDefault and ZonesMod.IsUnlockedByDefault(zoneId) then
		return true
	end
	if type(unlocked) == "table" and unlocked[zoneId] == true then
		return true
	end
	if _session.unlockedZone[zoneId] == true then
		return true
	end
	return false
end

local function getHighestUnlockedZone(unlocked)
	local best = "Starter"
	for _, zoneId in ipairs(ZONE_ORDER) do
		if isZoneUnlockedMap(zoneId, unlocked) then
			best = zoneId
		else
			break
		end
	end
	return best
end

----------------------------------------------------------------
-- Walk helpers (Humanoid:MoveTo — open maps; timeout then skip / TP fallback)
----------------------------------------------------------------
local WALK_REISSUE_SEC = 1.0
local WALK_TIMEOUT_LOOT = 14
local WALK_TIMEOUT_ZONE = 40

local function getCharRootHum()
	local char = LP.Character
	if not char then return nil, nil, nil end
	local root = char:FindFirstChild("HumanoidRootPart")
	local hum = char:FindFirstChildOfClass("Humanoid")
	return char, root, hum
end

-- Walk to world position. Returns true on arrive, false on timeout/cancel/no char.
-- cancelFn() → true aborts early. Does not leave MoveTo stuck forever (timeout).
local function walkToPosition(targetPos, opts)
	opts = opts or {}
	local timeout = opts.timeout or 20
	local arriveDist = opts.arriveDist or 5
	local label = opts.label
	local cancelFn = opts.cancelFn
	local start = os.clock()
	local lastIssue = -1e9

	while alive() do
		if cancelFn and cancelFn() then
			return false
		end
		local _, root, hum = getCharRootHum()
		if not root or not hum or hum.Health <= 0 then
			return false
		end
		local dist = (Vector3.new(root.Position.X, 0, root.Position.Z) - Vector3.new(targetPos.X, 0, targetPos.Z)).Magnitude
		if dist <= arriveDist then
			pcall(function()
				hum:MoveTo(root.Position)
			end)
			return true
		end
		if (os.clock() - start) >= timeout then
			return false
		end
		if (os.clock() - lastIssue) >= WALK_REISSUE_SEC then
			if label then
				status(label)
			end
			pcall(function()
				hum:MoveTo(Vector3.new(targetPos.X, root.Position.Y, targetPos.Z))
			end)
			lastIssue = os.clock()
		end
		task.wait(0.12)
	end
	return false
end

local function teleportToZoneLocal(zoneId, force)
	-- dump client.Zones.tpToZone: FireServer("TeleportToZone") then HRP → Zones[id].Spawn
	zoneId = tostring(zoneId)
	local cur = getCurrentZoneId()
	if not force and cur == zoneId then
		dbg("TeleportToZone skip — already in", zoneId)
		return false
	end

	-- Rate-limit the remote only; always allow local Spawn CF so movement isn't blocked
	local remoteGapOk = remoteReady("TeleportToZone")
	local recentSame = _session.lastTpZone == zoneId and (os.clock() - (_session.lastTpAt or 0)) < 1.25
	if remoteGapOk and not recentSame then
		local ok = fireR("TeleportToZone", zoneId)
		if ok then
			_session.lastTpZone = zoneId
			_session.lastTpAt = os.clock()
		end
	elseif recentSame then
		dbg("TeleportToZone remote skip — recent tp to", zoneId)
	end

	local didLocal = false
	pcall(function()
		local spawn = getZoneSpawnPart(zoneId)
		local root = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
		if spawn and root then
			-- dump teleportLocalCharacterTo / IrisWipe callback
			root.CFrame = spawn.CFrame * CFrame.new(0, spawn.Size.Y / 2 + 3, 0)
			didLocal = true
		end
	end)
	if not didLocal then
		dbg("TeleportToZone local Spawn missing for", zoneId)
	end
	return didLocal
end

-- Travel to zone: walk to Spawn when WalkToNextArea, else TeleportToZone + CF.
-- On walk timeout (far island / blocked), fall back to TP with status message.
local function travelToZone(zoneId, force)
	zoneId = tostring(zoneId)
	local label = zoneDisplayName(zoneId)
	local cur = getCurrentZoneId()
	if not force and cur == zoneId then
		return true
	end

	if not S.WalkToNextArea then
		status("TeleportToZone: " .. label)
		return teleportToZoneLocal(zoneId, true)
	end

	local spawn = getZoneSpawnPart(zoneId)
	if not spawn then
		status("Walk to " .. label .. " — Spawn missing, TPing")
		return teleportToZoneLocal(zoneId, true)
	end

	local target = spawn.Position + Vector3.new(0, 0, 0)
	status("walking to " .. label)
	local arrived = walkToPosition(target, {
		timeout = WALK_TIMEOUT_ZONE,
		arriveDist = 8,
		label = "walking to " .. label,
		cancelFn = function()
			return not alive() or not S.AutoNextArea
		end,
	})
	if arrived then
		-- Soft-sync zone with server after walking onto Spawn (rate-limited)
		if remoteReady("TeleportToZone") then
			fireR("TeleportToZone", zoneId)
			_session.lastTpZone = zoneId
			_session.lastTpAt = os.clock()
		end
		return true
	end

	status("Walk to " .. label .. " timed out — falling back to TP")
	return teleportToZoneLocal(zoneId, true)
end

local function loopAutoNextArea()
	addThread(task.spawn(function()
		while alive() do
			if S.AutoNextArea then
				local state = invokeR("GetZoneUnlockState")
				if type(state) ~= "table" then
					status("Auto Area: waiting zone state…")
					task.wait(1.2)
				else
					local unlocked = state.unlocked or {}
					local kills = state.kills or {}
					-- Sync confirmed unlocks; clear stale pending timestamps once server agrees
					for zid, v in pairs(unlocked) do
						if v == true then
							_session.unlockedZone[zid] = true
						end
					end
					if ZonesMod and ZonesMod.IsUnlockedByDefault then
						for _, zid in ipairs(ZONE_ORDER) do
							if ZonesMod.IsUnlockedByDefault(zid) then
								_session.unlockedZone[zid] = true
							end
						end
					else
						_session.unlockedZone.Starter = true
					end

					local gold = getGold()
					local highest = getHighestUnlockedZone(unlocked)
					local nextLocked = nil
					local waitReason = nil

					for _, zoneId in ipairs(ZONE_ORDER) do
						local gated = true
						if ZonesMod and ZonesMod.IsGated then
							gated = ZonesMod.IsGated(zoneId)
						else
							gated = (ZONE_COSTS[zoneId] or 0) > 0
						end
						if gated and not isZoneUnlockedMap(zoneId, unlocked) then
							local sess = _session.unlockedZone[zoneId]
							local recentlyTried = type(sess) == "number" and (os.clock() - sess) < 4
							local cost, currency = 0, "Gold"
							if ZonesMod and ZonesMod.GetUnlockCost then
								cost, currency = ZonesMod.GetUnlockCost(zoneId)
							else
								cost = ZONE_COSTS[zoneId] or 0
							end
							currency = currency or "Gold"
							local reqOk = true
							if ZonesMod and ZonesMod.EvaluateRequirements then
								reqOk = select(1, ZonesMod.EvaluateRequirements(zoneId, kills)) == true
							end
							local bal = currency == "Gold" and gold or (tonumber(getBalances()[currency]) or 0)
							local label = zoneDisplayName(zoneId)
							if recentlyTried then
								waitReason = string.format("Auto Area: unlock pending %s…", label)
							elseif not reqOk then
								waitReason = string.format("Auto Area: %s needs kill reqs", label)
							elseif cost > 0 and bal < cost then
								waitReason = string.format(
									"Auto Area: %s needs %s %s (have %s)",
									label,
									tostring(cost),
									currency,
									tostring(bal)
								)
							else
								nextLocked = zoneId
							end
							break -- next gated zone only (sequential unlock)
						end
					end

					if nextLocked then
						local label = zoneDisplayName(nextLocked)
						status("Unlocking area: " .. label)
						local ok = fireR("RequestZoneUnlock", nextLocked)
						if ok then
							-- pending lockout only — do NOT mark true until GetZoneUnlockState confirms
							_session.unlockedZone[nextLocked] = os.clock()
							invalidateCache("GetZoneUnlockState")
							task.wait(0.55)
							invalidateCache("GetZoneUnlockState")
							local state2 = invokeR("GetZoneUnlockState")
							if type(state2) == "table" and type(state2.unlocked) == "table" and state2.unlocked[nextLocked] == true then
								_session.unlockedZone[nextLocked] = true
							end
							travelToZone(nextLocked, true)
							-- retry once after attribute/replication lag
							task.wait(0.35)
							if getCurrentZoneId() ~= nextLocked then
								travelToZone(nextLocked, true)
							end
							local mode = S.WalkToNextArea and "walked" or "teleported"
							notify("Area", "Unlocked + " .. mode .. ": " .. label, 3, "success")
						else
							_session.unlockedZone[nextLocked] = os.clock()
							status("Auto Area: unlock throttled, retry…")
						end
						task.wait(S.AreaDelay)
					else
						-- Nothing affordable to unlock → move to latest unlocked if not there
						local cur = getCurrentZoneId()
						if cur ~= highest then
							local label = zoneDisplayName(highest)
							status("Moving to " .. label .. (waitReason and (" | " .. waitReason) or ""))
							travelToZone(highest, true)
							task.wait(math.max(0.8, S.AreaDelay))
						else
							status(waitReason or ("Auto Area: at " .. zoneDisplayName(highest)))
							task.wait(1.5)
						end
					end
				end
			else
				task.wait(0.5)
			end
		end
	end))
end

-- Auto Equip Best (dump: EquipHero / UnequipHero + inventory DPS sort)
local function loopAutoEquipBest()
	addThread(task.spawn(function()
		while alive() do
			if S.AutoEquipBest then
				local inv = invokeR("GetInventory")
				if type(inv) ~= "table" then
					status("Auto Equip: GetInventory failed")
					task.wait(2)
				else
					local heroes = inv.Heroes or {}
					local equipped = inv.EquippedHeroes or {}
					local maxEq = tonumber(inv.MaxEquippedHeroes) or 1

					local bestOwned = 0
					if HeroesMod and HeroesMod.GetBestOwnedDpsFromMap then
						bestOwned = HeroesMod.GetBestOwnedDpsFromMap(heroes) or 0
					end

					local equippedCount = {}
					for _, e in ipairs(equipped) do
						local key = tostring(e.HeroId) .. "/" .. tostring(e.Size or "Normal")
						equippedCount[key] = (equippedCount[key] or 0) + 1
					end

					local candidates = {}
					for heroId, hdata in pairs(heroes) do
						if type(hdata) == "table" and type(hdata.Sizes) == "table" then
							for size, sdata in pairs(hdata.Sizes) do
								local copies = tonumber(sdata.Copies) or 0
								local key = tostring(heroId) .. "/" .. tostring(size)
								local avail = copies -- include equipped copies for ranking; equip remote handles
								if avail > 0 then
									candidates[#candidates + 1] = {
										heroId = heroId,
										size = size,
										dps = heroBucketDps(heroId, size, bestOwned),
										avail = avail,
										equippedN = equippedCount[key] or 0,
									}
								end
							end
						end
					end

					table.sort(candidates, function(a, b)
						if a.dps == b.dps then
							return tostring(a.heroId) < tostring(b.heroId)
						end
						return a.dps > b.dps
					end)

					-- Desired: top maxEq by taking one slot per candidate until full
					local desired = {} -- list of {heroId,size}
					local used = {}
					for _, c in ipairs(candidates) do
						if #desired >= maxEq then break end
						local take = math.min(c.avail, maxEq - #desired)
						for _ = 1, take do
							desired[#desired + 1] = { heroId = c.heroId, size = c.size, dps = c.dps }
						end
					end

					-- Score currently equipped
					local eqScored = {}
					for i, e in ipairs(equipped) do
						eqScored[i] = {
							HeroId = e.HeroId,
							Size = e.Size or "Normal",
							InstanceId = e.InstanceId,
							dps = heroBucketDps(e.HeroId, e.Size or "Normal", bestOwned),
						}
					end
					table.sort(eqScored, function(a, b) return a.dps < b.dps end) -- worst first

					-- If we have a better candidate than worst equipped (or empty slot), swap
					local changed = false
					local desiredKeys = {}
					for _, d in ipairs(desired) do
						local k = d.heroId .. "/" .. d.size
						desiredKeys[k] = (desiredKeys[k] or 0) + 1
					end
					local haveKeys = {}
					for _, e in ipairs(equipped) do
						local k = tostring(e.HeroId) .. "/" .. tostring(e.Size or "Normal")
						haveKeys[k] = (haveKeys[k] or 0) + 1
					end

					-- Unequip extras not needed
					for _, e in ipairs(eqScored) do
						local k = tostring(e.HeroId) .. "/" .. tostring(e.Size)
						local need = desiredKeys[k] or 0
						local have = haveKeys[k] or 0
						if have > need then
							status("Unequip " .. k)
							local ok = fireR("UnequipHero", e.HeroId, e.Size, e.InstanceId)
							if ok then
								haveKeys[k] = have - 1
								changed = true
								invalidateCache("GetInventory")
							end
							task.wait(math.max(0.1, S.EquipDelay * 0.15))
						end
					end

					-- Equip missing
					for _, d in ipairs(desired) do
						local k = d.heroId .. "/" .. d.size
						local need = desiredKeys[k] or 0
						local have = haveKeys[k] or 0
						if have < need then
							status("Equip " .. k)
							local ok = fireR("EquipHero", d.heroId, d.size)
							if ok then
								haveKeys[k] = have + 1
								changed = true
								invalidateCache("GetInventory")
							end
							task.wait(math.max(0.1, S.EquipDelay * 0.15))
						end
					end

					if not changed then
						status("Auto Equip: already best")
						task.wait(S.EquipDelay)
					else
						task.wait(S.EquipDelay)
					end
				end
			else
				task.wait(0.5)
			end
		end
	end))
end

-- Auto Pickup (dump: no Collect remote — server magnet only)
-- Client Workspace.Loot models bob at LandPos (BobConn). Moving visuals to HRP does NOT
-- grant loot — server checks player vs LandPos within MagnetRange (StatKeys default 10),
-- then fires LootDelta kind "PickedUp". We TP or walk (WalkToLoot) to each LandPos and wait a scan tick.
local MAGNET_RANGE_DEFAULT = 10
local LOOT_SCAN_WAIT = 0.15 -- LootPickupScanHz=10 → ≥0.1s; small buffer

local function getMagnetRange()
	local base = MAGNET_RANGE_DEFAULT
	pcall(function()
		if Shared and Shared.Config and type(Shared.Config.MagnetRange) == "number" then
			base = Shared.Config.MagnetRange
		end
	end)
	-- StatKeys MagnetRange DefaultBase=10 (Add). Prefer live player attribute if present.
	local attr = LP:GetAttribute("MagnetRange")
	if type(attr) == "number" and attr > 0 then
		return attr
	end
	return base
end

-- Read client.Loot entity LandPos (u7 map) via LootDelta OnClientEvent upvalues
local function refreshLootLandCache()
	local now = os.clock()
	if (now - (_session.lootLandCacheAt or 0)) < 0.4 then
		return _session.lootLandCache
	end
	_session.lootLandCacheAt = now
	local cache = {}
	pcall(function()
		local getconnections = rawget(getfenv(), "getconnections") or rawget(_G, "getconnections")
		local getupvalue = (debug and debug.getupvalue) or rawget(_G, "getupvalue")
		if typeof(getconnections) ~= "function" or typeof(getupvalue) ~= "function" then
			return
		end
		local remote = RemotesFolder and RemotesFolder:FindFirstChild("LootDelta")
		if not remote then return end
		local conns = getconnections(remote.OnClientEvent)
		if type(conns) ~= "table" then return end

		local function ingest(map)
			if type(map) ~= "table" then return end
			for _, ent in pairs(map) do
				if type(ent) == "table" and ent.Model and typeof(ent.LandPos) == "Vector3" then
					cache[ent.Model] = ent.LandPos
					if ent.EntityId ~= nil then
						cache["id:" .. tostring(ent.EntityId)] = ent.LandPos
					end
				end
			end
		end

		for _, conn in ipairs(conns) do
			local fn = conn.Function or conn.func
			if type(fn) == "function" then
				for i = 1, 40 do
					local okU, a, b = pcall(getupvalue, fn, i)
					if not okU then break end
					if type(a) == "table" then ingest(a)
					elseif type(b) == "table" then ingest(b) end
				end
			end
		end
	end)
	_session.lootLandCache = cache
	return cache
end

local function lootWorldPos(inst)
	local ok, pos = pcall(function()
		if inst:IsA("Model") then
			return inst:GetPivot().Position
		elseif inst:IsA("BasePart") then
			return inst.Position
		end
		local pp = inst:FindFirstChildWhichIsA("BasePart", true)
		return pp and pp.Position or nil
	end)
	if ok then return pos end
	return nil
end

local function resolveLootLandPos(inst, landCache)
	if not inst then return nil end
	local attr = inst:GetAttribute("LandPos")
	if typeof(attr) == "Vector3" then
		return attr
	end
	if landCache then
		local fromMap = landCache[inst]
		if typeof(fromMap) == "Vector3" then
			return fromMap
		end
	end
	-- Fallback: visual world pos ≈ LandPos (+ bob ≤0.18). Safe if we never PivotTo'd to head.
	return lootWorldPos(inst)
end

local function lootKey(inst)
	return tostring(inst) -- unique userdata string per Instance
end

local function listLootTargets(lootFolder, rootPos, magnetRange)
	local landCache = refreshLootLandCache()
	local visited = _session.lootVisited or {}
	local now = os.clock()
	local out = {}
	local children = lootFolder:GetChildren()
	if #children == 0 then
		for _, d in ipairs(lootFolder:GetDescendants()) do
			if d:IsA("Model") and d.PrimaryPart then
				children[#children + 1] = d
			elseif d:IsA("BasePart") and d.Parent == lootFolder then
				children[#children + 1] = d
			end
		end
	end

	for _, m in ipairs(children) do
		if m:IsA("Model") or m:IsA("BasePart") then
			local key = lootKey(m)
			local skipUntil = visited[key]
			if not (type(skipUntil) == "number" and now < skipUntil) then
				local land = resolveLootLandPos(m, landCache)
				if land then
					local dist = (rootPos - land).Magnitude
					out[#out + 1] = {
						inst = m,
						key = key,
						land = land,
						dist = dist,
						inRange = dist <= magnetRange,
					}
				end
			end
		end
	end

	table.sort(out, function(a, b)
		return a.dist < b.dist
	end)
	return out
end

local function setupLootPickupSignals()
	local remote = RemotesFolder and RemotesFolder:FindFirstChild("LootDelta")
	if remote and remote:IsA("RemoteEvent") then
		addConn(remote.OnClientEvent:Connect(function(delta)
			if not alive() then return end
			if type(delta) ~= "table" or type(delta.kind) ~= "string" then return end
			if delta.kind == "PickedUp" then
				_session.lootPicked = (_session.lootPicked or 0) + 1
				_session.lastLootPickAt = os.clock()
				if delta.entityId ~= nil and _session.lootVisited then
					_session.lootVisited["eid:" .. tostring(delta.entityId)] = nil
				end
			end
		end))
	end
	pcall(function()
		if Shared and Shared.GetSignal then
			local sig = Shared.GetSignal("LootCollected")
			if sig and sig.Connect then
				addConn(sig:Connect(function(lootDef, amount, _pos)
					if not alive() or not S.AutoPickup then return end
					local name = "?"
					if type(lootDef) == "table" then
						name = tostring(lootDef.DisplayName or lootDef.Id or "?")
					end
					local amt = amount
					if type(amt) == "number" then
						status(string.format("Loot +%s %s (picked %d)", tostring(amt), name, _session.lootPicked or 0))
					else
						status(string.format("Loot collected: %s (picked %d)", name, _session.lootPicked or 0))
					end
				end))
			end
		end
	end)
end

local function loopAutoPickup()
	setupLootPickupSignals()
	_session.lootVisited = _session.lootVisited or {}

	addThread(task.spawn(function()
		while alive() do
			if not S.AutoPickup then
				task.wait(0.35)
			else
				local root = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
				local lootFolder = workspace:FindFirstChild("Loot")
				if not (root and lootFolder) then
					task.wait(0.25)
				else
					local magnetRange = getMagnetRange()
					local targets = listLootTargets(lootFolder, root.Position, magnetRange)
					if #targets == 0 then
						task.wait(0.2)
					else
						local waitAtLoot = math.max(LOOT_SCAN_WAIT, sanitizeNum(S.PickupDelay, Defaults.PickupDelay, 0.05, 5))
						local pickedBefore = _session.lootPicked or 0
						local didTravel = false

						for i, t in ipairs(targets) do
							if not alive() or not S.AutoPickup then break end
							root = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
							if not root then break end
							if not (t.inst and t.inst.Parent) then
								-- already despawned (server pickup / merge)
							else
								-- Re-resolve LandPos (entity cache preferred over visual)
								local land = resolveLootLandPos(t.inst, refreshLootLandCache()) or t.land
								local dist = (root.Position - land).Magnitude
								if dist > magnetRange * 0.85 then
									local arrived = false
									if S.WalkToLoot then
										status(string.format("walking to loot %d/%d", i, #targets))
										arrived = walkToPosition(land, {
											timeout = WALK_TIMEOUT_LOOT,
											arriveDist = math.max(3, magnetRange * 0.8),
											label = string.format("walking to loot %d/%d", i, #targets),
											cancelFn = function()
												return not alive() or not S.AutoPickup
													or not (t.inst and t.inst.Parent)
											end,
										})
										if not arrived then
											-- timeout / cancel — skip briefly, try next loot
											_session.lootVisited[t.key] = os.clock() + 2.5
											status(string.format("walk loot timeout — skip %d/%d", i, #targets))
										else
											didTravel = true
											task.wait(waitAtLoot)
										end
									else
										status(string.format("picking loot %d/%d", i, #targets))
										local savedCF = root.CFrame
										local okTp = pcall(function()
											root.CFrame = CFrame.new(land + Vector3.new(0, 3, 0))
										end)
										if not okTp then
											pcall(function() root.CFrame = savedCF end)
											_session.lootVisited[t.key] = os.clock() + 2
										else
											arrived = true
											didTravel = true
											task.wait(waitAtLoot)
										end
									end
								else
									-- Already inside MagnetRange — let server scan tick
									status(string.format("in range loot %d/%d — waiting scan", i, #targets))
									task.wait(waitAtLoot)
								end

								-- Still present after wait → skip briefly (stuck / not ours yet)
								if t.inst and t.inst.Parent then
									_session.lootVisited[t.key] = os.clock() + 2.5
								else
									_session.lootVisited[t.key] = nil
								end
							end
						end

						local pickedNow = (_session.lootPicked or 0) - pickedBefore
						if pickedNow > 0 then
							status(string.format("picked %d loot (total %d)", pickedNow, _session.lootPicked or 0))
						elseif not didTravel then
							task.wait(0.15)
						end
					end
				end
			end
		end
	end))
end

-- Auto Prestige (dump: FireServer("PrestigeRequested") when IsEligibleForNext)
local function loopAutoPrestige()
	addThread(task.spawn(function()
		while alive() do
			if S.AutoPrestige then
				local current = getPrestigeCurrent()
				local level = getLevel()
				local okElig = false
				if PrestigeMod and PrestigeMod.IsEligibleForNext and current then
					-- dump Prestige.IsEligibleForNext → ok, nextRank, reason
					okElig = select(1, PrestigeMod.IsEligibleForNext(current, level)) == true
				else
					-- dump: PrestigeUnlockLevel = 10 for first prestige gate
					local unlock = 10
					if Shared and Shared.Config and Shared.Config.PrestigeUnlockLevel then
						unlock = Shared.Config.PrestigeUnlockLevel
					end
					okElig = level >= unlock
				end
				if okElig then
					status("Prestiging…")
					local ok = fireR("PrestigeRequested")
					if ok then
						notify("Prestige", "PrestigeRequested fired", 3, "success")
						invalidateCache("GetPrestige")
						invalidateCache("GetLevel")
						-- prestige resets upgrade ownership — clear session buy marks
						table.clear(_session.boughtUpgrade)
						table.clear(_session.boughtPrestige)
						invalidateCache("GetUpgrades")
						invalidateCache("GetPrestigeUpgrades")
					end
					task.wait(S.PrestigeDelay)
				else
					status("Auto Prestige: not eligible (lv " .. tostring(level) .. ")")
					task.wait(2)
				end
			else
				task.wait(0.5)
			end
		end
	end))
end

-- Auto Prestige Upgrades (dump: FireServer("PurchasePrestigeUpgrade", id)
-- GetPrestigeUpgrades → { upgrades }; currency PrestigeTokens; accessor PrestigeUpgrades)
local function loopAutoPrestigeUpgrades()
	addThread(task.spawn(function()
		while alive() do
			if S.AutoPrestigeUpgrades then
				if not PrestigeUpgradesMod then
					status("Prestige Upgrades: module not found")
					task.wait(3)
				else
					local ownedSnap = invokeR("GetPrestigeUpgrades")
					local owned = {}
					if type(ownedSnap) == "table" then
						owned = ownedSnap.upgrades or ownedSnap or {}
					end
					for id, v in pairs(owned) do
						if v then _session.boughtPrestige[id] = nil end
					end
					local tokens = getPrestigeTokens()
					local bought = 0
					local order = PrestigeUpgradesMod.Order and PrestigeUpgradesMod.Order() or {}
					for _, id in ipairs(order) do
						if not alive() or not S.AutoPrestigeUpgrades then break end
						if owned[id] then
							-- skip owned
						elseif _session.boughtPrestige[id] and (os.clock() - _session.boughtPrestige[id]) < 3 then
							-- recently fired
						else
							local def = PrestigeUpgradesMod.Get and PrestigeUpgradesMod.Get(id)
							local branch = def and def.Branch or "Root"
							local state = PrestigeUpgradesMod.GetState(id, owned, tokens, branch)
							if state == "Affordable" then
								status("Prestige upgrade: " .. tostring(id))
								local ok = fireR("PurchasePrestigeUpgrade", id)
								if ok then
									_session.boughtPrestige[id] = os.clock()
									owned[id] = true
									bought = bought + 1
									local cost = def and tonumber(def.Cost) or 0
									if cost > 0 then adjustCachedBalance("PrestigeTokens", -cost) end
									tokens = getPrestigeTokens()
									invalidateCache("GetPrestigeUpgrades")
								end
								task.wait(S.PrestigeUpgradeDelay)
							end
						end
					end
					if bought == 0 then
						status("Prestige Upgrades: nothing affordable")
						task.wait(1.25)
					end
				end
			else
				task.wait(0.5)
			end
		end
	end))
end

-- Auto Upgrade Hero Index (dump: PurchaseIndexUpgrade keys Luck/RollSpeed/Gold/Damage)
local function loopAutoIndex()
	addThread(task.spawn(function()
		while alive() do
			if S.AutoIndexUpgrade then
				local levels = invokeR("GetIndexUpgrades")
				if type(levels) ~= "table" then
					status("Index: GetIndexUpgrades failed")
					task.wait(2)
				else
					local gems = getIndexGems()
					local bought = 0
					local maxLevel = (IndexRewardsMod and IndexRewardsMod.MaxLevel) or 20
					for _, key in ipairs(INDEX_ORDER) do
						if not alive() or not S.AutoIndexUpgrade then break end
						local toggleKey = INDEX_TOGGLE_KEY[key]
						if toggleKey and S[toggleKey] ~= true then
							-- skip disabled index type
						else
							local cur = 0
							if IndexRewardsMod and IndexRewardsMod.ClampLevel then
								cur = IndexRewardsMod.ClampLevel(levels[key])
							else
								cur = math.floor(tonumber(levels[key]) or 0)
							end
							if cur >= maxLevel then
								-- already max
							else
								local cost
								if IndexRewardsMod and IndexRewardsMod.NextCost then
									cost = IndexRewardsMod.NextCost(cur)
								else
									-- dump: CostForLevel(level) returns level number (1..MaxLevel)
									cost = (cur + 1 <= maxLevel) and (cur + 1) or nil
								end
								if cost and gems >= cost then
									status("Index upgrade: " .. key)
									local okInv, res = invokeR2("PurchaseIndexUpgrade", key)
									if okInv and type(res) == "table" and type(res.level) == "number" then
										levels[res.key or key] = res.level
										bought = bought + 1
										adjustCachedBalance("IndexGems", -cost)
										gems = getIndexGems()
										invalidateCache("GetIndexUpgrades")
										-- keep GetIndexUpgrades cache in sync locally
										_remoteCache.GetIndexUpgrades = { t = os.clock(), v = levels }
									elseif not okInv then
										dbg("PurchaseIndexUpgrade skipped", res)
									end
									task.wait(S.IndexDelay)
								end
							end
						end
					end
					if bought == 0 then
						status("Index: nothing affordable / enabled")
						task.wait(1.5)
					end
				end
			else
				task.wait(0.5)
			end
		end
	end))
end

----------------------------------------------------------------
-- Auto Execute (Anime Squadron pattern) + Auto Rejoin Private
----------------------------------------------------------------
local QUEUE_ARM_FILE = "RNGHeroes_queue_arm.json"
local QUEUE_ARM_MIN_SEC = 1.5 -- gate queue_on_teleport in _G to avoid double-exec

local LOCAL_LOAD_SNIPPET = [[
	local function loadLocalScript()
		local names = { "RNG_Heroes_Script.lua", "RNG Heroes", "RNG_Heroes.lua" }
		if readfile and isfile then
			for _, name in ipairs(names) do
				if isfile(name) then
					local ok, loc = pcall(readfile, name)
					if ok and loc and #loc > 1000 then return loc end
				end
			end
		end
	end
]]

local function getQueueFn()
	return (syn and syn.queue_on_teleport)
		or (fluxus and fluxus.queue_on_teleport)
		or queue_on_teleport
		or queueonteleport
		or (getgenv and (getgenv().queue_on_teleport or getgenv().queueonteleport))
		or (potassium and potassium.queue_on_teleport)
end

local function shouldInstallReconnect()
	return S.AutoExecute == true or S.AutoexecInstall == true
end

local function syncReexecFlags()
	_G.RNGHeroes_AutoExecute = S.AutoExecute == true
	_G.RNGHeroes_AutoRejoinPrivate = S.AutoRejoinPrivate == true
	if type(S.PrivateJobId) == "string" and S.PrivateJobId ~= "" then
		_G.RNGHeroes_PrivateJobId = S.PrivateJobId
	end
	if type(S.PrivateServerCode) == "string" and S.PrivateServerCode ~= "" then
		_G.RNGHeroes_PrivateServerCode = S.PrivateServerCode
	end
end

local function markQueueArmed()
	pcall(function()
		if writefile then
			writefile(QUEUE_ARM_FILE, HttpService:JSONEncode({
				ts = os.time(),
				job = game.JobId,
				place = game.PlaceId,
			}))
		end
	end)
end

local function buildQueuePayload(url)
	return ([[
-- RNG Heroes teleport loader
if _G.RNGHeroes_TP_BOOT and (tick() - _G.RNGHeroes_TP_BOOT) < 8 then return end
if _G.RNGH_TP_BOOT and (tick() - _G.RNGH_TP_BOOT) < 8 then return end
_G.RNGHeroes_TP_BOOT = tick()
_G.RNGH_TP_BOOT = _G.RNGHeroes_TP_BOOT
local _u = %q
local function rnghGet(u)
	local ok, s = pcall(function() return game:HttpGet(u) end)
	if ok and s and #s > 500 then return s end
	local req = (syn and syn.request) or request or http_request or (http and http.request)
	if req then
		local ok2, r = pcall(function() return req({Url=u, Method="GET"}).Body end)
		if ok2 and r and #r > 500 then return r end
	end
end
%s
task.defer(function()
	if not game:IsLoaded() then pcall(function() game.Loaded:Wait() end) end
	task.wait(0.6)
	-- Prefer local OR URL (never both)
	local src = loadLocalScript()
	if not src then src = rnghGet(_u) end
	if src then pcall(function() loadstring(src)() end) end
end)
]]):format(url, LOCAL_LOAD_SNIPPET)
end

local function buildReconnectLoader(url)
	local gid = tostring(game.GameId)
	return ([[
-- RNG Heroes reconnect loader (auto-generated)
if tostring(game.GameId) ~= %q then return end
-- Claim boot token immediately so sibling autoexec copies cannot race-load
if _G.RNGHeroes_TP_BOOT and (tick() - _G.RNGHeroes_TP_BOOT) < 8 then return end
if _G.RNGH_TP_BOOT and (tick() - _G.RNGH_TP_BOOT) < 8 then return end
_G.RNGHeroes_TP_BOOT = tick()
_G.RNGH_TP_BOOT = _G.RNGHeroes_TP_BOOT
local _u = %q
local function rnghGet(u)
	local ok, s = pcall(function() return game:HttpGet(u) end)
	if ok and s and #s > 500 then return s end
	local req = (syn and syn.request) or request or http_request or (http and http.request)
	if req then
		local ok2, r = pcall(function() return req({Url=u, Method="GET"}).Body end)
		if ok2 and r and #r > 500 then return r end
	end
end
%s
task.defer(function()
	if not game:IsLoaded() then pcall(function() game.Loaded:Wait() end) end
	task.wait(0.8)
	if _G.RNGH_BootAt and (tick() - _G.RNGH_BootAt) < 5 then return end
	local HS = game:GetService("HttpService")
	if readfile and isfile and isfile("RNGHeroes_queue_arm.json") then
		local ok, r = pcall(readfile, "RNGHeroes_queue_arm.json")
		if ok and r and r ~= "" then
			local ok2, d = pcall(function() return HS:JSONDecode(r) end)
			if ok2 and d and d.job == game.JobId and os.time() - (tonumber(d.ts) or 0) < 20 then
				return
			end
		end
	end
	-- Prefer local OR URL (never both)
	local src = loadLocalScript()
	if not src then src = rnghGet(_u) end
	if src then pcall(function() loadstring(src)() end) end
end)
]]):format(gid, url, LOCAL_LOAD_SNIPPET)
end

local _autoexecPaths = {
	"autoexec/RNG_Heroes.lua",
	"autoexec/RNGHeroes.lua",
	"../autoexec/RNG_Heroes.lua",
	"../autoexec/RNGHeroes.lua",
	"auto_exec/RNG_Heroes.lua",
	"Autoexec/RNG_Heroes.lua",
}

local function installReconnectLoader()
	if not shouldInstallReconnect() then return false end
	local url = S.ScriptUrl
	if type(url) ~= "string" or url == "" then return false end
	if type(writefile) ~= "function" then return false end
	local loader = buildReconnectLoader(url)
	local wrotePath = nil
	for _, path in ipairs(_autoexecPaths) do
		local ok = pcall(function()
			if type(makefolder) == "function" then
				local dir = path:match("^(.*)/")
				if dir and type(isfolder) == "function" and not isfolder(dir) then
					pcall(makefolder, dir)
				end
			end
			writefile(path, loader)
		end)
		if ok then
			wrotePath = path
			break -- one file only — multiple copies race on executor autoexec
		end
	end
	-- Remove duplicate autoexec copies so only one boot path exists
	if wrotePath and type(delfile) == "function" then
		for _, path in ipairs(_autoexecPaths) do
			if path ~= wrotePath then
				pcall(function()
					if type(isfile) == "function" and isfile(path) then
						delfile(path)
					end
				end)
			end
		end
	end
	return wrotePath ~= nil
end

local function uninstallReconnectLoader()
	if type(delfile) ~= "function" then return false end
	local any = false
	for _, path in ipairs(_autoexecPaths) do
		pcall(function()
			if type(isfile) == "function" and isfile(path) then
				delfile(path)
				any = true
			end
		end)
	end
	return any
end

local function armReexec()
	if not S.AutoExecute then return false end
	syncReexecFlags()
	local url = S.ScriptUrl
	if type(url) ~= "string" or url == "" then return false end
	local q = getQueueFn()
	if not q then
		if not _G.RNGHeroes_QueueWarned then
			_G.RNGHeroes_QueueWarned = true
			warn("[RNG Heroes] queue_on_teleport missing — enable reconnect loader or Utility > Re-arm")
		end
		return false
	end
	local now = tick()
	local last = tonumber(_G.RNGHeroes_LastQueueAt) or 0
	if (now - last) < QUEUE_ARM_MIN_SEC then
		return true
	end
	_G.RNGHeroes_LastQueueAt = now
	markQueueArmed()
	pcall(q, buildQueuePayload(url))
	return true
end

-- Anime Squadron: re-arm on any OnTeleport (not gated to RequestedByServer)
addConn(LP.OnTeleport:Connect(function(_)
	if S.AutoExecute then
		pcall(armReexec)
	end
end))

pcall(function()
	game:BindToClose(function()
		if S.AutoExecute then pcall(armReexec) end
		if shouldInstallReconnect() then pcall(installReconnectLoader) end
	end)
end)

-- Private server helpers (client-safe: share link resolve + JobId fallback)
-- Never read game.PrivateServerId / PrivateServerOwnerId (server-only warnings).
-- Never call TeleportToPrivateServer (server-only).
local PRIVATE_REJOIN_CD = 20 -- seconds between rejoin attempts (hard throttle)

local function currentJobId()
	return tostring(game.JobId or "")
end

local function getSavedPrivateJobId()
	local job = S.PrivateJobId
	if (not job or job == "") and type(_G.RNGHeroes_PrivateJobId) == "string" then
		job = _G.RNGHeroes_PrivateJobId
	end
	return tostring(job or "")
end

local function getSavedPrivateServerCode()
	local code = S.PrivateServerCode
	if (not code or code == "") and type(_G.RNGHeroes_PrivateServerCode) == "string" then
		code = _G.RNGHeroes_PrivateServerCode
	end
	return tostring(code or "")
end

local function isOnSavedPrivateJob()
	local saved = getSavedPrivateJobId()
	if saved == "" then return false end
	return currentJobId() == saved
end

local function saveCurrentJobId(forceSave)
	local job = currentJobId()
	if job == "" then return false end
	local changed = job ~= S.PrivateJobId
	S.PrivateJobId = job
	syncReexecFlags()
	if changed or forceSave then
		saveSettingsDebounced()
	end
	return true
end

-- Parse share URL, old VIP link, or raw 32-hex share code / linkCode
local function parsePrivateServerInput(raw)
	local s = tostring(raw or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if s == "" then
		return nil
	end
	local out = { raw = s, shareCode = nil, linkCode = nil, placeId = nil, linkType = "Server" }

	local share = s:match("[?&]code=([%w%-_]+)")
	local typ = s:match("[?&]type=([%w]+)")
	if share then
		out.shareCode = share
		if typ and typ ~= "" then
			out.linkType = typ
		end
	end

	local oldLink = s:match("[?&]privateServerLinkCode=([%w%-_]+)")
		or s:match("[?&]linkCode=([%w%-_]+)")
	if oldLink then
		out.linkCode = oldLink
	end

	local pid = s:match("roblox%.com/games/(%d+)") or s:match("[?&]placeId=(%d+)") or s:match("[?&]placeid=(%d+)")
	if pid then
		out.placeId = tonumber(pid)
	end

	-- Raw share / VIP code (no URL)
	if not out.shareCode and not out.linkCode then
		local hex = s:match("^([0-9a-fA-F]+)$")
		if hex and #hex >= 16 and #hex <= 64 then
			-- New share codes are 32 hex; treat as share code
			if #hex == 32 or s:lower():find("share", 1, true) then
				out.shareCode = hex
			else
				out.linkCode = hex
			end
		elseif s:match("^[%w%-_]+$") and #s >= 16 and #s <= 128 then
			out.shareCode = s
		end
	end

	if not out.shareCode and not out.linkCode then
		return nil
	end
	return out
end

local function httpRequest(opts)
	local req = (syn and syn.request) or request or http_request or (http and http.request)
	if not req then
		return nil, "no request function"
	end
	local ok, res = pcall(req, opts)
	if not ok then
		return nil, tostring(res)
	end
	return res, nil
end

local function headerGet(headers, key)
	if type(headers) ~= "table" then return nil end
	local want = string.lower(key)
	for k, v in pairs(headers) do
		if type(k) == "string" and string.lower(k) == want then
			return v
		end
	end
	return nil
end

local function getRobloxCsrf()
	local res = httpRequest({
		Url = "https://auth.roblox.com/v2/logout",
		Method = "POST",
		Headers = { ["Content-Type"] = "application/json" },
	})
	if not res then return nil end
	return headerGet(res.Headers, "x-csrf-token") or headerGet(res.Headers, "X-CSRF-TOKEN")
end

local function digField(t, names)
	if type(t) ~= "table" then return nil end
	for _, n in ipairs(names) do
		local v = t[n]
		if v ~= nil and v ~= "" then
			return v
		end
	end
	for _, child in pairs(t) do
		if type(child) == "table" then
			local v = digField(child, names)
			if v ~= nil then return v end
		end
	end
	return nil
end

local function resolveShareLink(shareCode, linkType)
	linkType = linkType or "Server"
	local csrf = getRobloxCsrf()
	local body = HttpService:JSONEncode({
		linkId = tostring(shareCode),
		linkType = tostring(linkType),
	})
	local headers = {
		["Content-Type"] = "application/json",
		["Accept"] = "application/json",
	}
	if csrf then
		headers["X-CSRF-TOKEN"] = csrf
	end
	local res, err = httpRequest({
		Url = "https://apis.roblox.com/sharelinks/v1/resolve-link",
		Method = "POST",
		Headers = headers,
		Body = body,
	})
	if not res then
		return nil, err or "resolve request failed"
	end
	-- Retry once on CSRF reject
	local status = tonumber(res.StatusCode) or 0
	if status == 403 then
		local again = headerGet(res.Headers, "x-csrf-token") or headerGet(res.Headers, "X-CSRF-TOKEN")
		if again then
			headers["X-CSRF-TOKEN"] = again
			res, err = httpRequest({
				Url = "https://apis.roblox.com/sharelinks/v1/resolve-link",
				Method = "POST",
				Headers = headers,
				Body = body,
			})
			if not res then
				return nil, err or "resolve retry failed"
			end
			status = tonumber(res.StatusCode) or 0
		end
	end
	local rawBody = res.Body
	if type(rawBody) ~= "string" or rawBody == "" then
		return nil, "empty resolve body (HTTP " .. tostring(status) .. ")"
	end
	local okDecode, data = pcall(function()
		return HttpService:JSONDecode(rawBody)
	end)
	if not okDecode or type(data) ~= "table" then
		return nil, "resolve JSON failed"
	end
	if data.errors or data.Error then
		local msg = data.Error
		if type(data.errors) == "table" and data.errors[1] then
			msg = data.errors[1].message or msg
		end
		return nil, tostring(msg or "resolve API error")
	end

	local placeId = tonumber(digField(data, { "placeId", "PlaceId", "placeID" }))
	local linkCode = digField(data, { "linkCode", "privateServerLinkCode", "LinkCode" })
	local instanceId = digField(data, { "instanceId", "jobId", "gameInstanceId", "JobId" })
	local universeId = tonumber(digField(data, { "universeId", "UniverseId" }))

	if type(linkCode) == "string" then
		linkCode = linkCode
	else
		linkCode = nil
	end
	if type(instanceId) == "string" and instanceId ~= "" then
		instanceId = instanceId
	else
		instanceId = nil
	end

	if not placeId and not linkCode and not instanceId then
		return nil, "resolve returned no placeId/linkCode/jobId"
	end
	return {
		placeId = placeId,
		linkCode = linkCode and tostring(linkCode) or nil,
		instanceId = instanceId,
		universeId = universeId,
		raw = data,
	}, nil
end

local function teleportToJob(placeId, jobId)
	placeId = tonumber(placeId) or game.PlaceId
	jobId = tostring(jobId or "")
	if jobId == "" then
		return false, "empty jobId"
	end
	local ok, err = pcall(function()
		TeleportService:TeleportToPlaceInstance(placeId, jobId, LP)
	end)
	if ok then
		return true, "TeleportToPlaceInstance"
	end
	return false, tostring(err or "TeleportToPlaceInstance failed")
end

-- Ask gamejoin for the VIP instance JobId (client/executor HTTP; cookies via request)
local function joinPrivateViaGameJoin(placeId, linkCode)
	placeId = tonumber(placeId) or game.PlaceId
	linkCode = tostring(linkCode or "")
	if linkCode == "" then
		return nil, "no linkCode"
	end
	local csrf = getRobloxCsrf()
	local payload = HttpService:JSONEncode({
		placeId = placeId,
		linkCode = linkCode,
	})
	local headers = {
		["Content-Type"] = "application/json",
		["Accept"] = "application/json",
	}
	if csrf then
		headers["X-CSRF-TOKEN"] = csrf
	end
	local res, err = httpRequest({
		Url = "https://gamejoin.roblox.com/v1/join-private-game",
		Method = "POST",
		Headers = headers,
		Body = payload,
	})
	if not res then
		return nil, err or "gamejoin failed"
	end
	local status = tonumber(res.StatusCode) or 0
	if status == 403 then
		local again = headerGet(res.Headers, "x-csrf-token") or headerGet(res.Headers, "X-CSRF-TOKEN")
		if again then
			headers["X-CSRF-TOKEN"] = again
			res, err = httpRequest({
				Url = "https://gamejoin.roblox.com/v1/join-private-game",
				Method = "POST",
				Headers = headers,
				Body = payload,
			})
			if not res then
				return nil, err or "gamejoin retry failed"
			end
		end
	end
	local rawBody = res.Body
	if type(rawBody) ~= "string" or rawBody == "" then
		return nil, "empty gamejoin body"
	end
	local okDecode, data = pcall(function()
		return HttpService:JSONDecode(rawBody)
	end)
	if not okDecode or type(data) ~= "table" then
		return nil, "gamejoin JSON failed"
	end
	local jobId = digField(data, { "jobId", "JobId", "gameInstanceId", "instanceId" })
	if type(jobId) == "string" and jobId ~= "" then
		return tostring(jobId), nil
	end
	-- Sometimes nested under joinScript / data
	local js = data.joinScript or data.JoinScript
	if type(js) == "string" then
		local fromJs = js:match('"jobId"%s*:%s*"([^"]+)"') or js:match("jobId%s*=%s*'([^']+)'")
		if fromJs and fromJs ~= "" then
			return fromJs, nil
		end
	end
	return nil, "gamejoin returned no jobId (status=" .. tostring(data.status or data.Status or "?") .. ")"
end

local function openDeepLink(url)
	url = tostring(url or "")
	if url == "" then return false end
	local opened = false
	if typeof(open_url) == "function" then
		opened = pcall(open_url, url)
	end
	if not opened and syn and type(syn.open_url) == "function" then
		opened = pcall(syn.open_url, url)
	end
	if not opened then
		local ok = pcall(function()
			local gs = game:GetService("GuiService")
			if gs and gs.OpenBrowserWindow then
				gs:OpenBrowserWindow(url)
			else
				error("no OpenBrowserWindow")
			end
		end)
		opened = ok
	end
	if not opened then
		-- Last resort: protocol via request (some executors route roblox://)
		local res = httpRequest({ Url = url, Method = "GET" })
		opened = res ~= nil
	end
	return opened
end

local function tryJoinViaShareParsed(parsed)
	if not parsed then
		return false, "invalid share link/code"
	end

	local placeId = parsed.placeId or game.PlaceId
	local linkCode = parsed.linkCode
	local instanceId = nil

	if parsed.shareCode then
		status("Resolving share link…")
		local resolved, err = resolveShareLink(parsed.shareCode, parsed.linkType or "Server")
		if not resolved then
			-- Deep-link fallback without resolve (client leaves current session)
			local deeplink = ("roblox://navigation/share_links?code=%s&type=%s"):format(
				tostring(parsed.shareCode),
				tostring(parsed.linkType or "Server")
			)
			if openDeepLink(deeplink) then
				return true, "deep-link share_links"
			end
			return false, err or "share resolve failed"
		end
		placeId = resolved.placeId or placeId
		linkCode = resolved.linkCode or linkCode
		instanceId = resolved.instanceId
	end

	-- Prefer JobId/instance from resolve
	if instanceId and instanceId ~= "" then
		if instanceId == currentJobId() then
			-- Already on that instance — remember JobId for auto detect
			if getSavedPrivateJobId() == "" then
				saveCurrentJobId(true)
			end
			return false, "already on share instance"
		end
		local ok, how = teleportToJob(placeId, instanceId)
		if ok then
			return true, how .. " (share instanceId)"
		end
	end

	-- VIP linkCode → gamejoin → TeleportToPlaceInstance
	if linkCode and linkCode ~= "" then
		status("Joining VIP via linkCode…")
		local jobId, gjErr = joinPrivateViaGameJoin(placeId, linkCode)
		if jobId then
			if jobId == currentJobId() then
				if getSavedPrivateJobId() == "" then
					saveCurrentJobId(true)
				end
				return false, "already on VIP JobId"
			end
			local ok, how = teleportToJob(placeId, jobId)
			if ok then
				return true, how .. " (share→gamejoin)"
			end
			dbg("teleport after gamejoin failed", how)
		else
			dbg("gamejoin", gjErr)
		end
		-- Protocol deep link with placeId + linkCode
		local startLink = ("roblox://experiences/start?placeId=%s&linkCode=%s"):format(
			tostring(placeId),
			tostring(linkCode)
		)
		if openDeepLink(startLink) then
			return true, "deep-link placeId+linkCode"
		end
		local webStart = ("https://www.roblox.com/games/start?placeId=%s&linkCode=%s"):format(
			tostring(placeId),
			tostring(linkCode)
		)
		if openDeepLink(webStart) then
			return true, "browser games/start linkCode"
		end
		return false, gjErr or "linkCode join failed"
	end

	-- Share code only — protocol navigation (Roblox resolves server-side)
	if parsed.shareCode then
		local deeplink = ("roblox://navigation/share_links?code=%s&type=%s"):format(
			tostring(parsed.shareCode),
			tostring(parsed.linkType or "Server")
		)
		if openDeepLink(deeplink) then
			return true, "deep-link share_links"
		end
	end

	return false, "could not join via share link"
end

local _privateRejoinAt = 0
local function tryRejoinPrivateServer()
	if isOnSavedPrivateJob() then
		return false, "already on saved JobId"
	end
	local now = os.clock()
	if (now - _privateRejoinAt) < PRIVATE_REJOIN_CD then
		return false, "cooldown"
	end

	local codeRaw = getSavedPrivateServerCode()
	local parsed = parsePrivateServerInput(codeRaw)
	local savedJob = getSavedPrivateJobId()

	if not parsed and savedJob == "" then
		return false, "paste share link/code or save JobId"
	end

	_privateRejoinAt = now

	-- Primary: share URL / code
	if parsed then
		local ok, how = tryJoinViaShareParsed(parsed)
		if ok then
			return true, how
		end
		if how == "already on share instance" or how == "already on VIP JobId" then
			return false, how
		end
		dbg("share join failed, trying JobId fallback", how)
		-- fall through to JobId if share path failed
	end

	-- Secondary: saved JobId → TeleportToPlaceInstance
	if savedJob ~= "" and savedJob ~= currentJobId() then
		local ok, how = teleportToJob(game.PlaceId, savedJob)
		if ok then
			return true, how .. " (saved JobId)"
		end
		return false, how
	end

	if parsed then
		return false, "share join failed (no JobId fallback)"
	end
	return false, "no share code or JobId"
end

local function needsPrivateRejoin()
	local saved = getSavedPrivateJobId()
	local code = getSavedPrivateServerCode()
	if saved ~= "" then
		return not isOnSavedPrivateJob()
	end
	-- Share-only: cannot detect wrong server without JobId — prompt save
	return false, (code ~= "")
end

local function setupAutoExecuteAndPrivateRejoin()
	syncReexecFlags()
	pcall(armReexec)
	if shouldInstallReconnect() then
		pcall(installReconnectLoader)
	end
	addThread(task.spawn(function()
		local lastInstall = 0
		while alive() do
			task.wait(3)
			if S.AutoExecute then
				pcall(armReexec)
			end
			if shouldInstallReconnect() and (tick() - lastInstall) > 60 then
				lastInstall = tick()
				pcall(installReconnectLoader)
			end
		end
	end))
	addThread(task.spawn(function()
		while alive() do
			if not S.AutoRejoinPrivate then
				task.wait(2)
			else
				local saved = getSavedPrivateJobId()
				local code = getSavedPrivateServerCode()
				local wrong = needsPrivateRejoin()
				if saved == "" and code == "" then
					status("Private rejoin — paste share link or save JobId")
					task.wait(5)
				elseif saved == "" and code ~= "" then
					status("Share link saved — Save JobId in PS for auto wrong-server detect")
					task.wait(5)
				elseif isOnSavedPrivateJob() then
					task.wait(3)
				elseif wrong then
					status("Wrong server — rejoining via share link / JobId…")
					local ok, how = tryRejoinPrivateServer()
					if ok then
						status("Rejoin private via " .. tostring(how))
						notify("Private Server", "Rejoining via " .. tostring(how), 4, "info")
						if S.AutoExecute then pcall(armReexec) end
					elseif how ~= "cooldown" and how ~= "already on share instance" and how ~= "already on VIP JobId" then
						status("Private rejoin: " .. tostring(how))
						dbg("private rejoin", how)
					end
					task.wait(PRIVATE_REJOIN_CD)
				else
					task.wait(3)
				end
			end
		end
	end))
end

----------------------------------------------------------------
-- NexusLib load
----------------------------------------------------------------
local function loadNexus()
	local lib
	local ok = pcall(function()
		if isfile and isfile("NexusLib.lua") then
			lib = loadstring(readfile("NexusLib.lua"))()
		elseif isfile and isfile("Nexuslib.lua") then
			lib = loadstring(readfile("Nexuslib.lua"))()
		end
	end)
	if not ok or not lib then
		local url = "https://raw.githubusercontent.com/headshot7535-png/Nexuslib/refs/heads/main/Nexuslib"
		local ok2, res = pcall(function()
			return game:HttpGet(url)
		end)
		if ok2 and type(res) == "string" then
			lib = loadstring(res)()
		end
	end
	return lib
end

local NexusLib = loadNexus()
if not NexusLib or not NexusLib.Window then
	warn("[RNG Heroes] Failed to load NexusLib")
	return
end

Win = NexusLib:Window({ title = "RNG Heroes | v" .. SCRIPT_VERSION, width = 820, height = 560 })
_G.RNGHeroes_Win = Win
_G.RNGHeroes_Gui = Win and Win._screen

-- NexusLib minimize toggle is local `Icon` (ImageButton, mid-left by default).
-- No Window cfg for its Position — pin top-left below the Roblox top bar.
local MINIMIZE_ICON_POS = UDim2.new(0, 12, 0, 72)
local function pinMinimizeIconTopLeft()
	pcall(function()
		local screen = Win and Win._screen
		if not screen or not screen.Parent then return end
		local icon
		for _, c in ipairs(screen:GetChildren()) do
			if c:IsA("ImageButton") then
				local lbl = c:FindFirstChildOfClass("TextLabel")
				if lbl and lbl.Text == "☰" then
					icon = c
					break
				end
			end
		end
		if not icon then return end
		icon.AnchorPoint = Vector2.new(0, 0)
		icon.Position = MINIMIZE_ICON_POS
	end)
end
pinMinimizeIconTopLeft()
pcall(function()
	if Win._screen then
		addConn(Win._screen:GetPropertyChangedSignal("AbsoluteSize"):Connect(pinMinimizeIconTopLeft))
	end
end)

local TabMain = Win:Tab("⚔️", "Main")
local TabFarm = Win:Tab("🌀", "Farm")
local TabUtil = Win:Tab("⚙️", "Utility")

----------------------------------------------------------------
-- Main tab
----------------------------------------------------------------
TabMain:Section("Automation")
TabMain:Toggle("Auto Roll", "Fire SetAutoRoll + keep rolling", S.AutoRoll, function(on)
	S.AutoRoll = on == true
	if on then
		ensureAutoRoll(true)
		status("Auto Roll ON")
	else
		ensureAutoRoll(false)
		status("Auto Roll OFF")
	end
	saveSettingsDebounced()
end)

TabMain:Toggle("Auto Use Max", "Arm Power Rolls at MAX (SetPowerArmed)", S.AutoUseMax, function(on)
	S.AutoUseMax = on == true
	if on then
		_session.powerArmedThisCycle = false
		status("Auto Use Max ON")
	else
		status("Auto Use Max OFF")
	end
	saveSettingsDebounced()
end)

TabMain:Toggle(
	"Auto Click Attack",
	"Kill Aura via ReportClickAttack — may need Click Attack gold upgrade (auto-buys if Affordable)",
	S.AutoClickAttack,
	function(on)
		S.AutoClickAttack = on == true
		status(on and "Auto Click Attack ON" or "Auto Click Attack OFF")
		saveSettingsDebounced()
	end
)

TabMain:Toggle("Anti-AFK", "Keep session alive / block idle kick", S.AntiAFK, function(on)
	S.AntiAFK = on == true
	status(on and "Anti-AFK ON" or "Anti-AFK OFF")
	saveSettingsDebounced()
end)

TabMain:Toggle("Auto Upgrades", "Buy upgrades when affordable", S.AutoUpgrades, function(on)
	S.AutoUpgrades = on == true
	status(on and "Auto Upgrades ON" or "Auto Upgrades OFF")
	saveSettingsDebounced()
end)

TabMain:Toggle("Auto Next Area", "Unlock / move to next zone", S.AutoNextArea, function(on)
	S.AutoNextArea = on == true
	status(on and "Auto Next Area ON" or "Auto Next Area OFF")
	saveSettingsDebounced()
end)

TabMain:Toggle(
	"Walk To Next Area",
	"When Auto Next Area moves zones: walk to Spawn (TP fallback on timeout). Off = TeleportToZone + CF",
	S.WalkToNextArea,
	function(on)
		S.WalkToNextArea = on == true
		status(on and "Walk To Next Area ON" or "Walk To Next Area OFF (teleport)")
		saveSettingsDebounced()
	end
)

TabMain:Toggle("Auto Equip Best Heroes", "Equip strongest heroes each cycle", S.AutoEquipBest, function(on)
	S.AutoEquipBest = on == true
	status(on and "Auto Equip Best ON" or "Auto Equip Best OFF")
	saveSettingsDebounced()
end)

TabMain:Toggle(
	"Auto Pick Up Loot",
	"Move to each loot LandPos so server MagnetRange collects it (see Walk To Loot)",
	S.AutoPickup,
	function(on)
		S.AutoPickup = on == true
		local mode = S.WalkToLoot and "walk" or "TP"
		status(on and ("Auto Pickup ON (" .. mode .. "→LandPos)") or "Auto Pickup OFF")
		saveSettingsDebounced()
	end
)

TabMain:Toggle(
	"Walk To Loot",
	"When Auto Pickup is on: Humanoid walk to LandPos. Off = CFrame teleport (faster)",
	S.WalkToLoot,
	function(on)
		S.WalkToLoot = on == true
		status(on and "Walk To Loot ON" or "Walk To Loot OFF (teleport)")
		saveSettingsDebounced()
	end
)

TabMain:Toggle("Auto Prestige", "Prestige when ready", S.AutoPrestige, function(on)
	S.AutoPrestige = on == true
	status(on and "Auto Prestige ON" or "Auto Prestige OFF")
	saveSettingsDebounced()
end)

TabMain:Toggle("Auto Prestige Upgrades", "Buy prestige tree with PrestigeTokens", S.AutoPrestigeUpgrades, function(on)
	S.AutoPrestigeUpgrades = on == true
	status(on and "Auto Prestige Upgrades ON" or "Auto Prestige Upgrades OFF")
	saveSettingsDebounced()
end)

TabMain:Toggle("Auto Upgrade Hero Index", "Purchase enabled index upgrades", S.AutoIndexUpgrade, function(on)
	S.AutoIndexUpgrade = on == true
	status(on and "Auto Index ON" or "Auto Index OFF")
	saveSettingsDebounced()
end)

TabMain:Section("Index upgrade types")
TabMain:Toggle("Index: Luck", "Buy Luck when Auto Index is on", S.IndexLuck, function(on)
	S.IndexLuck = on == true
	saveSettingsDebounced()
end)
TabMain:Toggle("Index: Roll Speed", "Buy RollSpeed when Auto Index is on", S.IndexRollSpeed, function(on)
	S.IndexRollSpeed = on == true
	saveSettingsDebounced()
end)
TabMain:Toggle("Index: Gold", "Buy Gold when Auto Index is on", S.IndexGold, function(on)
	S.IndexGold = on == true
	saveSettingsDebounced()
end)
TabMain:Toggle("Index: Damage", "Buy Damage when Auto Index is on", S.IndexDamage, function(on)
	S.IndexDamage = on == true
	saveSettingsDebounced()
end)

TabMain:Separator()
TabMain:Button("🛑", "Stop All Loops", "Disable every automation toggle", Color3.fromRGB(248, 113, 113), function()
	stopAllLoops()
end)

TabMain:Button("💾", "Save Settings", "Force-write JSON now", Color3.fromRGB(74, 222, 128), function()
	saveSettingsNow()
	notify("Settings", "Saved to " .. SETTINGS_FILE, 3, "success")
end)

TabMain:Button("💬", "Discord", "Copy invite link", Color3.fromRGB(129, 140, 248), function()
	pcall(function()
		if setclipboard then setclipboard(DiscordInvite) end
	end)
	notify("Discord", "Invite copied to clipboard", 3, "info")
end)

----------------------------------------------------------------
-- Farm / timing
----------------------------------------------------------------
TabFarm:Section("Delays (seconds)")
TabFarm:Slider("Roll Delay", "Min wait between Rolls (also ≥0.2s rate limit / game speed)", { min = 0.05, max = 2, default = S.RollDelay }, function(v)
	S.RollDelay = sanitizeNum(v, Defaults.RollDelay, 0.05, 5)
	saveSettingsDebounced()
end)
TabFarm:Slider("Upgrade Delay", "Between PurchaseUpgrade (Affordable only)", { min = 0.05, max = 2, default = S.UpgradeDelay }, function(v)
	S.UpgradeDelay = sanitizeNum(v, Defaults.UpgradeDelay, 0.05, 5)
	saveSettingsDebounced()
end)
TabFarm:Slider("Area Delay", "After zone unlock", { min = 0.2, max = 5, default = S.AreaDelay }, function(v)
	S.AreaDelay = sanitizeNum(v, Defaults.AreaDelay, 0.2, 10)
	saveSettingsDebounced()
end)
TabFarm:Slider("Equip Delay", "Equip best cycle", { min = 0.2, max = 5, default = S.EquipDelay }, function(v)
	S.EquipDelay = sanitizeNum(v, Defaults.EquipDelay, 0.1, 10)
	saveSettingsDebounced()
end)
TabFarm:Slider("Pickup Delay", "Wait at each loot for server magnet scan", { min = 0.05, max = 1, default = S.PickupDelay }, function(v)
	S.PickupDelay = sanitizeNum(v, Defaults.PickupDelay, 0.05, 5)
	saveSettingsDebounced()
end)
TabFarm:Slider("Index Delay", "Between index purchases", { min = 0.05, max = 2, default = S.IndexDelay }, function(v)
	S.IndexDelay = sanitizeNum(v, Defaults.IndexDelay, 0.05, 5)
	saveSettingsDebounced()
end)
TabFarm:Slider("Prestige Upgrade Delay", "Between PurchasePrestigeUpgrade", { min = 0.05, max = 2, default = S.PrestigeUpgradeDelay }, function(v)
	S.PrestigeUpgradeDelay = sanitizeNum(v, Defaults.PrestigeUpgradeDelay, 0.05, 5)
	saveSettingsDebounced()
end)
TabFarm:Slider("Power Use Delay", "Between SetPowerArmed attempts at MAX", { min = 0.2, max = 3, default = S.PowerUseDelay }, function(v)
	S.PowerUseDelay = sanitizeNum(v, Defaults.PowerUseDelay, 0.2, 5)
	saveSettingsDebounced()
end)

----------------------------------------------------------------
-- Utility / status
----------------------------------------------------------------
TabUtil:Section("Info")
TabUtil:Paragraph(
	"Remotes live under ReplicatedStorage.Remotes (Network module). "
		.. "Loot: no Collect remote — Auto Pickup TPs or walks (Walk To Loot) to each LandPos (server MagnetRange). "
		.. "Walk To Next Area: walk to zone Spawn instead of TeleportToZone (TP fallback on timeout). "
		.. "Power Rolls: Main.Bottom.PowerRoll → SetPowerArmed; MAX = IsMax.Visible / charge>=capacity. "
		.. "Click Attack: ReportClickAttack(zone, slot, pos); upgrade id \"Click Attack\" (ClickAttackUnlocked). "
		.. "Prestige tree: PurchasePrestigeUpgrade / GetPrestigeUpgrades (PrestigeTokens). "
		.. "AFK is client.Afk.Afk ModuleScript (RequestAfkRejoin), not a PlayerScripts LocalScript."
)
TabUtil:Toggle("Verbose prints", "Extra debug output to console", S.Verbose, function(on)
	S.Verbose = on == true
	saveSettingsDebounced()
end)
TabUtil:Button("🔄", "Refresh Status", "Show gold / level / zone", Color3.fromRGB(129, 140, 248), function()
	local gld = getGold()
	local lv = getLevel()
	local zone = tostring(LP:GetAttribute("CurrentZone") or "?")
	local saved = getSavedPrivateJobId()
	local code = getSavedPrivateServerCode()
	local srv
	if saved ~= "" then
		srv = isOnSavedPrivateJob() and "on saved JobId" or "wrong JobId"
	elseif code ~= "" then
		srv = "share link set"
	else
		srv = "no share/JobId"
	end
	local msg = string.format("Gold=%s | Lv=%s | Zone=%s | Server=%s", tostring(gld), tostring(lv), zone, srv)
	status(msg)
	notify("Status", msg, 4, "info")
end)

TabUtil:Section("Teleport persistence")
TabUtil:Toggle(
	"Auto Execute (on teleport)",
	"Re-run after teleports via queue_on_teleport + optional reconnect loader",
	S.AutoExecute,
	function(on)
		S.AutoExecute = on == true
		syncReexecFlags()
		saveSettingsDebounced()
		if on then
			armReexec()
			local ok = installReconnectLoader()
			notify(
				"Auto Execute",
				ok and "Armed queue + reconnect loader installed." or "Queue armed (reconnect file install failed).",
				3,
				ok and "success" or "info"
			)
		elseif not S.AutoexecInstall then
			uninstallReconnectLoader()
		end
	end
)
TabUtil:Label(
	(getQueueFn() ~= nil)
			and "Teleport re-exec: supported ✓ (queue kept armed + OnTeleport)"
		or "Teleport re-exec: NOT supported (queue_on_teleport missing) ✗"
)
TabUtil:Toggle(
	"Auto-exec on rejoin (autoexec file)",
	"Keep reconnect loader even if teleport Auto Execute is off",
	S.AutoexecInstall,
	function(on)
		S.AutoexecInstall = on == true
		saveSettingsDebounced()
		if on then
			local ok = installReconnectLoader()
			notify(
				"Auto-exec",
				ok and "Reconnect loader installed." or "Install failed (no writefile).",
				3,
				ok and "success" or "error"
			)
		elseif not S.AutoExecute then
			uninstallReconnectLoader()
			notify("Auto-exec", "Removed reconnect loader.", 3, "info")
		end
	end
)
TabUtil:Input(
	"Script URL",
	"Raw URL of this script (for queue_on_teleport)",
	"https://...",
	S.ScriptUrl,
	function(txt)
		S.ScriptUrl = (type(txt) == "string" and txt ~= "") and txt or SCRIPT_URL
		saveSettingsDebounced()
	end
)
TabUtil:Button("🔁", "Re-arm teleport persist", "queue_on_teleport + reconnect loader", Color3.fromRGB(129, 140, 248), function()
	local q = armReexec()
	local f = installReconnectLoader()
	notify(
		"Persist",
		(q and "Queue armed. " or "Queue failed. ") .. (f and "Reconnect loader OK." or "Reconnect loader failed."),
		3,
		(q or f) and "success" or "error"
	)
end)

TabUtil:Section("Private server")
TabUtil:Toggle(
	"Auto Rejoin Private Server",
	"Wrong JobId → rejoin via share link first, then saved JobId (client-safe)",
	S.AutoRejoinPrivate,
	function(on)
		S.AutoRejoinPrivate = on == true
		syncReexecFlags()
		saveSettingsDebounced()
		status(on and "Auto Rejoin Private ON" or "Auto Rejoin Private OFF")
	end
)
TabUtil:Input(
	"Private Server Code / link",
	"Paste roblox.com/share?code=…&type=Server (or raw code). Persists; used for rejoin.",
	"paste share link or code…",
	S.PrivateServerCode,
	function(txt)
		S.PrivateServerCode = type(txt) == "string" and txt or ""
		syncReexecFlags()
		saveSettingsDebounced()
		local parsed = parsePrivateServerInput(S.PrivateServerCode)
		if S.PrivateServerCode ~= "" and not parsed then
			status("Share link/code not recognized — check paste")
		elseif parsed and parsed.shareCode then
			status("Share code saved (" .. tostring(parsed.shareCode):sub(1, 8) .. "…)")
		elseif parsed and parsed.linkCode then
			status("VIP linkCode saved")
		end
	end
)
TabUtil:Label(
	(function()
		local saved = getSavedPrivateJobId()
		local code = getSavedPrivateServerCode()
		local bits = {}
		if code ~= "" then
			local p = parsePrivateServerInput(code)
			table.insert(bits, p and p.shareCode and ("share✓ " .. tostring(p.shareCode):sub(1, 8) .. "…") or "share set")
		else
			table.insert(bits, "no share link")
		end
		if saved == "" then
			table.insert(bits, "JobId unset — Save while in PS")
		elseif isOnSavedPrivateJob() then
			table.insert(bits, "on JobId ✓ " .. tostring(S.PrivateJobId):sub(1, 12) .. "…")
		else
			table.insert(bits, "wrong JobId — will rejoin")
		end
		return table.concat(bits, " | ")
	end)()
)
TabUtil:Button("📌", "Save current JobId", "Save game.JobId from this server (use while in your PS)", Color3.fromRGB(74, 222, 128), function()
	if saveCurrentJobId(true) then
		notify("Private Server", "Saved JobId=" .. tostring(S.PrivateJobId):sub(1, 12) .. "…", 3, "success")
		status("Saved private JobId")
	else
		notify("Private Server", "JobId empty — try again in a live server.", 3, "warn")
	end
end)
TabUtil:Button("🚪", "Rejoin Private Now", "Share link resolve → TeleportToPlaceInstance / deep-link (JobId fallback)", Color3.fromRGB(251, 191, 36), function()
	if isOnSavedPrivateJob() then
		notify("Private Server", "Already on saved JobId.", 3, "info")
		return
	end
	local code = getSavedPrivateServerCode()
	local job = getSavedPrivateJobId()
	if code == "" and job == "" then
		notify("Private Server", "Paste a share link/code or save JobId first.", 4, "warn")
		return
	end
	if S.AutoExecute then pcall(armReexec) end
	local ok, how = tryRejoinPrivateServer()
	notify("Private Server", ok and ("Teleporting via " .. tostring(how)) or ("Failed: " .. tostring(how)), 4, ok and "success" or "error")
end)

----------------------------------------------------------------
-- Boot loops
----------------------------------------------------------------
task.defer(function()
	if not alive() then return end
	_G.RNGH_BootAt = tick()
	setupPowerDeltaListener()
	setupAutoExecuteAndPrivateRejoin()
	loopAutoRoll()
	loopAutoUseMax()
	loopAutoClickAttack()
	setupAntiAFK()
	loopAutoUpgrades()
	loopAutoNextArea()
	loopAutoEquipBest()
	loopAutoPickup()
	loopAutoPrestige()
	loopAutoPrestigeUpgrades()
	loopAutoIndex()
	status("RNG Heroes | v" .. SCRIPT_VERSION .. " ready")
	notify("RNG Heroes", "v" .. SCRIPT_VERSION .. " loaded (dump-traced remotes)", 4, "success")
end)

-- Re-exec cleanup if gen changes
addThread(task.spawn(function()
	while alive() do
		task.wait(1)
	end
	cleanupAll()
end))
