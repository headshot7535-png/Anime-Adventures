--[[
    ⚔️ Anime Adventures — Smart Farm v1.0  (NexusLib)

    One script for the lobby and every match place:
      • Lobby:  free rewards → spends with floors (gold shop Star Fruits, optional summons) → rank every
                mode in gems per minute → join a pad, lock the level, start
      • Match:  place each unit where enemies spend the most time in range, layering further down the road
                when enemies get past (a leak gets a unit in its way), buy the best damage per yen — or the
                farm unit while it still pays back and the defense holds — fire abilities, then replay /
                next act / back to the lobby by the same ranking
      • Simulator: plays each mode with your team first (the game's own HP, waves, wave pay and skip timing),
                calibrated by every real run; its odds go into the ranking and the team / evolution planner

    Every number comes from the game's own modules (Units, Waves, Levels, Attacks, Traits, UnitServiceCore
    formulas, the live unit stats that already include level, traits, stat rolls, curses and relics) and
    is corrected by what really happened (run times, wins, refused spots, measured damage per unit).
    Settings: AA_SmartFarm/settings.json · learning: AA_SmartFarm/brain.json · log: AA_SmartFarm/log.txt
]]

-- claim the "running" slot synchronously, before any yield, so two queued loaders can't both start
if _G.AA_SF and _G.AA_SF.alive then return end
local VERSION = "1.0"
-- what changed, newest first (Updates tab; a one-time notice when a player first runs a new version)
local CHANGELOG = {
    { v = "1.0", date = "Oct 30, 2026", title = "First version", items = {
        { "🗺️", "Picks the best mode", "Daily Challenge, the half-hour Challenge, first clears (Normal and Hard), raids, Fool's Hunt and farming, ranked by gems per minute from the game's own rewards and your real run times.", "NEW" },
        { "💰", "Farm unit or damage?", "Buys the farm unit and its upgrades only while they pay back before the match ends and enemies die early on the road; otherwise it buys damage.", "NEW" },
        { "⭐", "Traits, relics and elements", "Unit strength comes from the game's formula at full upgrade: level, trait (Unique, Golden...), stat rolls, curses, relic buffs and the mode's weak/strong elements.", "NEW" },
        { "📍", "Smart placement", "Each unit goes where it covers the most road. Spots the server refuses are remembered per map.", "NEW" },
        { "🛡️", "Defense in depth", "Tracks how far down the road your units reach. When enemies get to the end of that stretch, the next unit goes further down the road. If one slips past them all, a unit goes right in its way: one enemy at your base ends the run.", "NEW" },
        { "🎁", "Free rewards", "Daily login, finished quests, battle pass and first-clear milestones are claimed for you.", "NEW" },
        { "🧾", "Spend history", "Every gold, gem and coin spend has a floor, a stop rule and a line in the Spending tab.", "NEW" },
        { "🧪", "Battle simulator", "Plays a mode with your team before the farm spends a run on it: the game's own enemy HP, waves and yen, and the farm's own buying. It learns from every real match.", "NEW" },
        { "⏩", "Real wave timing", "The simulator plays waves the way the game does: each wave's yen ×2.6 (the world's money boost), the early skip vote (about 2 s + 2 s per enemy, at most 30 s) and an enemy at your base taking it down in seconds.", "NEW" },
        { "👥", "Best team finder", "Tries your other units against each mode's weak and strong elements and shows the team that does best (Battle tab). It only equips it if you switch that on.", "NEW" },
        { "🌟", "Evolution check", "Shows which evolutions your items already cover and what each one would change in the hardest mode you play.", "NEW" },
        { "🧬", "Smart evolve", "Evolves your best copy of a unit once it's ready and gets stronger, but only with items no bigger goal needs and only using up spare copies (never one on your team or with a trait). Every evolve shows in the log and the Spending tab. Switch it off in the Path tab.", "NEW" },
    } },
}
local SF = { alive = true, conns = {}, loadId = string.format("%06x", math.random(0, 0xFFFFFF)) }
_G.AA_SF = SF
if not game:IsLoaded() then game.Loaded:Wait() end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local Http = game:GetService("HttpService")
local LP = Players.LocalPlayer
while not LP do task.wait(0.25); LP = Players.LocalPlayer end

-- everything below lives in tables (the main chunk is capped at 200 locals)
local C = {}   -- game modules / constants
local CFG = {} -- settings
local B = {}   -- brain (persisted learning + mid-task state)
local ST = {}  -- status line per system
local LOG = { lines = {}, pending = {} }
local U = {}   -- utilities
local UNIT = {} -- unit maths
local MODE = {} -- mode ranking
local HUB = {} -- lobby systems
local MT = {}  -- match runtime
local SPEND = {} -- spend history
local REPORT = {} -- anonymous stats (hive)
local ECON = {} -- farm-or-damage decision (shared by the live match and the simulator)
local SIM = {}  -- battle simulator + planners (team picks, evolutions, challenge gating)
local ADV = {}  -- the path to stronger units: goals, where their items come from, what to farm
local GUI = { UI = {}, LIVE = {} }

C.FOLDER = "AA_SmartFarm"
C.SETTINGS = C.FOLDER .. "/settings.json"
C.BRAIN = C.FOLDER .. "/brain.json"
C.LOGFILE = C.FOLDER .. "/log.txt"
C.SELF = "AnimeAdventures_SmartFarm.lua"
-- public copy (people who run the script from a loadstring have no local file, so teleports re-load it from here)
C.SELF_URL = "https://raw.githubusercontent.com/headshot7535-png/Anime-Adventures/main/AnimeAdventures_SmartFarm.lua"
C.NEXUS_URL = "https://raw.githubusercontent.com/headshot7535-png/Nexuslib/main/Nexuslib"
-- the hive's Discord webhook for anonymous match stats + suggestions (empty = not connected yet)
C.WEBHOOK_URL = ""

-- ============================================================
--  DEFAULT SETTINGS
-- ============================================================
C.DEFAULTS = {
    master = true,
    -- lobby
    rewards = true,            -- daily login, quests, battle pass, first-clear milestones
    goldShop = true,           -- buy Star Fruits from the daily gold shop with spare gold
    goldFloor = 300000,        -- ... never below this much gold
    summonApril = false,       -- AprilCoins → April banner while a limited unit (Osaka, Dokuro, Rikka, Chihiro) is missing
    aprilFloor = 0,            -- ... keep at least this many AprilCoins
    summonGems = false,        -- gems → newest gem banner while a featured unit would make your team stronger
    gemFloor = 30000,          -- ... never below this many gems
    summonsPerVisit = 20,      -- ... at most this many summons per lobby visit (each banner)
    -- modes
    play = true, dailyChallenge = true, challenge = true, firstClears = true, raids = true, event = true, farm = true,
    unlockValue = 20,          -- gem value of opening the next act / world (on top of the first-clear gems)
    aprilValue = 0.35,         -- gems per AprilCoin (an April summon costs 150, a gem summon 50)
    exploreBonus = 0.2,        -- optimism for modes with few runs
    restAfterLosses = 2,       -- rest a mode for 6 h after this many losses in a row
    -- battle
    battle = true, place = true, upgrade = true, actives = true, autoStart = true,
    farmUnits = true,          -- buy farm units / farm upgrades while they pay back in time and the defense holds
    farmSpare = 2,             -- ... a farm buy must pay back with at least this many waves to spare
    safeReach = 0.45,          -- defense counts as safe while enemies die before this share of the road
    clearSec = 20,             -- ... and the team kills everything alive within this many seconds (enemy HP ÷ team damage)
    dangerReach = 0.7,         -- past this share: damage only, buy right away (no saving)
    abilityHold = 20,          -- a ready damage ability waits up to this many seconds for a boss or 3+ enemies
    smartTarget = true,        -- crowd control / area units target "first", heavy hitters "strongest" while a boss is alive
    saveRatio = 0.6,           -- buy an affordable option worth ≥ this share of the best one instead of saving
    -- simulator
    sim = true,                -- simulate a mode with your team before playing it (its odds go into the ranking)
    simTeams = true,           -- also work out the best team from all your units for the top modes (shown, not equipped)
    autoTeam = false,          -- equip the simulator's best team before a mode when it does better (your team is kept and put back)
    -- the path to stronger units
    goals = true,              -- items for the best evolution goals get a gem value, so the farm goes and gets them
    goalValue = 3000,          -- gem value of finishing the top goal (spread over the items it still needs)
    raidShopGoals = true,      -- buy a goal's item in the raid shop once enough raid items are in (they have no other use)
    smartEvolve = true,        -- evolve ready units that get stronger, using only spare items and spare copies (HUB.smartEvolve)
    -- misc
    antiAfk = true, logConsole = false, logLevel = 1,
    shareStats = true,         -- anonymous match stats for the hive (only sent once a webhook is connected)
    shareChosen = false, shareNoticed = false,
}

-- gem-equivalent values of items (game prices where the game has one: travelling merchant StarFruit 50 gems,
-- StarFruitEpic 300 gems; others estimated). An item already at its cap (GameplaySettings.ITEM_CAPS) is worth 0.
C.ITEM_VALUE = {
    StarFruit = 50, StarFruitGreen = 70, StarFruitRed = 70, StarFruitPink = 70, StarFruitBlue = 70,
    StarFruitEpic = 300, StarFruitCapsule = 120, star_remnant = 40, star_remnant_limited = 25,
    reroll_stat_all = 120, reroll_stat_specific = 250, divine_wish = 400, LuckPotion = 50,
}
C.ITEM_DEFAULT = 8
C.GOLD_VALUE = 0.02 -- gems per gold (key shop: 2000 gold = 200 gems, but gold is plentiful)

-- ============================================================
--  UTILITIES / FILES / LOG
-- ============================================================
function U.now() return os.clock() end
function U.json(t) local ok, j = pcall(Http.JSONEncode, Http, t); return ok and j or "{}" end
function U.unjson(s) local ok, t = pcall(Http.JSONDecode, Http, s); return ok and t or nil end
function U.readJson(path)
    local ok, src = pcall(function() return isfile(path) and readfile(path) or nil end)
    return ok and src and U.unjson(src) or nil
end
function U.writeJson(path, t)
    pcall(function() if not isfolder(C.FOLDER) then makefolder(C.FOLDER) end end)
    pcall(writefile, path, U.json(t))
end
function U.fmt(n)
    n = tonumber(n) or 0
    if n >= 1e6 then return string.format("%.2fM", n / 1e6) end
    if n >= 1e4 then return string.format("%.1fk", n / 1e3) end
    return tostring(math.floor(n + 0.5))
end
function U.clamp(x, a, b) return math.max(a, math.min(b, x)) end
function U.count(t) local n = 0; for _ in pairs(t or {}) do n = n + 1 end; return n end
function U.list(t)
    -- data tables come as {["1"]=..} or arrays: give an ordered array either way
    if type(t) ~= "table" then return {} end
    if #t > 0 then return t end
    local keys = {}
    for k in pairs(t) do table.insert(keys, k) end
    table.sort(keys, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)
    local out = {}
    for _, k in ipairs(keys) do table.insert(out, t[k]) end
    return out
end
function U.flat(v) return Vector3.new(v.X, 0, v.Z) end

function SF.log(level, sys, msg)
    if level > (CFG.logLevel or 1) then return end
    local line = string.format("[%s] %-7s %s", os.date("%H:%M:%S"), sys, tostring(msg))
    table.insert(LOG.lines, line)
    if #LOG.lines > 250 then table.remove(LOG.lines, 1) end
    table.insert(LOG.pending, line)
    local low = tostring(msg):lower()
    if low:find("refused") or low:find("error") or low:find("timeout") or sys == "FATAL" then
        LOG.problems = LOG.problems or {}
        table.insert(LOG.problems, line)
        if #LOG.problems > 30 then table.remove(LOG.problems, 1) end
    end
    if CFG.logConsole then print("[AA] " .. line) end
end
function SF.status(sys, msg) ST[sys] = msg end
function SF.flush()
    if #LOG.pending == 0 then return end
    local chunk = table.concat(LOG.pending, "\n") .. "\n"
    table.clear(LOG.pending)
    pcall(function()
        if not isfolder(C.FOLDER) then makefolder(C.FOLDER) end
        if appendfile and isfile(C.LOGFILE) then appendfile(C.LOGFILE, chunk) else writefile(C.LOGFILE, chunk) end
    end)
end
task.spawn(function() while SF.alive do task.wait(3); SF.flush() end end)

-- settings
do
    local saved = U.readJson(C.SETTINGS) or {}
    if saved.shareChosen ~= true then saved.shareStats = nil end
    for k, v in pairs(C.DEFAULTS) do
        if saved[k] ~= nil and type(saved[k]) == type(v) then CFG[k] = saved[k] else CFG[k] = v end
    end
    CFG.seenVersion = type(saved.seenVersion) == "string" and saved.seenVersion or nil
    CFG.cfgv = 1
end
function SF.saveSoon() SF.saveAt = U.now() + 1.5 end
function SF.saveNow() U.writeJson(C.SETTINGS, CFG); U.writeJson(C.BRAIN, B); SF.flush() end

-- brain: every field has a load line here (a field that is only written is silently lost on the next load)
do
    local b = U.readJson(C.BRAIN) or {}
    local function tbl(x) return type(x) == "table" and x or nil end
    B.v = 1
    B.loads = (tonumber(b.loads) or 0) + 1
    B.modes = tbl(b.modes) or {}         -- [modeKey] = {runs, wins, sec, gems, coins, streak, restUntil, last}
    B.blocked = tbl(b.blocked) or {}     -- [map] = {["x,z"] = runs that refused a unit there}
    B.caps = tbl(b.caps) or {}           -- [unitUuid] = placements the server allowed (learned limit)
    B.learn = tbl(b.learn) or {}         -- [unitId] = {eff, n}: measured / predicted damage share
    B.spend = tbl(b.spend) or {}         -- spend history {at, what, cost, cur, why}
    B.totals = tbl(b.totals) or { wins = 0, losses = 0, gems = 0, coins = 0, matches = 0 }
    B.pending = tbl(b.pending)           -- mode the farm launched (the match reads it)
    B.live = tbl(b.live) or {}           -- lobby-only info the match needs: challenge / daily / event
    B.lastResult = tbl(b.lastResult)
    B.history = tbl(b.history) or {}     -- last 30 runs
    B.lastMatch = tbl(b.lastMatch)       -- yen spent in the last match (Spending tab)
    B.claims = tbl(b.claims) or {}       -- [questUuid / milestone] = time claimed (no double claims)
    B.cleared = tbl(b.cleared) or {}     -- ["level:diff"] = time won (the match's copy of the profile lags)
    B.simCal = tbl(b.simCal) or {}       -- [modeKey] = what matches measured: wave length, walk speed, HP vs formula, yen, base, HP alive per wave
    B.maps = tbl(b.maps) or {}           -- [map] = road coverage of the best spot per range (sim placement)
    -- sim results made by an older simulator model are dropped (the model changed, they would mislead)
    local simV = 3
    local fresh = tonumber(b.simVer) == simV
    B.simVer = simV
    B.simRes = fresh and tbl(b.simRes) or {}       -- [modeKey] = last sim of your team {won, wave, p, sig, at}
    B.simTeam = fresh and tbl(b.simTeam) or {}     -- [modeKey] = best team the planner found {uuids, wave, won, cur, at}
    B.simEvo = fresh and tbl(b.simEvo) or {}       -- evolutions with their simulated gain
    B.savedTeam = tbl(b.savedTeam)       -- your own team, kept while a planned team is equipped
    B.goals = tbl(b.goals) or {}         -- the path: evolution goals ranked {from, to, gain, plan, runs, ...}
    B.goalItems = tbl(b.goalItems) or {} -- [itemId] = gem value it has because a top goal needs it
    B.goalNeed = tbl(b.goalNeed) or {}   -- [itemId] = how many of it those goals still need
    B.raidShop = tbl(b.raidShop) or {}   -- [key] = {id, costItem, cost, stock} (lobby raid shop, cached)
    B.lb = tbl(b.lb)                     -- limit break requirement from the server {requirement, allowed}
    B.lastSuggest = tonumber(b.lastSuggest) or 0
    B.anonId = type(b.anonId) == "string" and b.anonId or Http:GenerateGUID(false):gsub("-", ""):sub(1, 10):lower()
    B.hiveQueue = tbl(b.hiveQueue) or {}
end
task.spawn(function()
    while SF.alive do
        task.wait(1)
        if SF.saveAt and U.now() >= SF.saveAt then SF.saveAt = nil; SF.saveNow() end
    end
end)

-- ============================================================
--  GAME MODULES (the game's own client modules, by their real names)
-- ============================================================
do
    local src = RS:WaitForChild("src", 60)
    C.Loader = require(src:WaitForChild("Loader"))
    C.Util = require(src:WaitForChild("Util"))
    -- the game's main script must finish its init first (the Loader renames + destroys modules as it goes)
    local t0 = U.now()
    while SF.alive and U.now() - t0 < 90 do
        local ok, g = pcall(C.Loader.load_client_service, nil, "GUIService")
        if ok and type(g) == "table" and g.session and g.session._initialized then break end
        task.wait(0.5)
    end
end
function C.svc(name) local ok, m = pcall(C.Loader.load_client_service, nil, name); return ok and m or nil end
function C.core(name) local ok, m = pcall(C.Loader.load_core_service, nil, name); return ok and m or nil end
function C.data(name) local ok, m = pcall(C.Loader.load_data, nil, name); return ok and m or nil end
C.EP = C.svc("EndpointsClient")
C.GUIS = C.svc("GUIService")
C.USC = C.core("UnitServiceCore")
C.PSC = C.core("ProgressionServiceCore")
C.QCC = C.core("QuestClassesCore")
C.PC = C.core("PlacementCore")
C.PATH = C.core("PathService")
C.LU = C.core("LevelUtil")
C.CAR = C.data("ChallengeAndRewards") or {}
C.Units = C.data("Units") or {}
C.Levels = C.data("Levels") or {}
C.Worlds = C.data("Worlds") or {}
C.Waves = C.data("Waves") or {}
C.Attacks = C.data("Attacks") or {}
C.Items = C.data("Items") or {}
C.GS = C.data("GameplaySettings") or {}
C.WLO = C.data("WorldLevelOrder") or {}
C.Banners = C.data("Banners") or {}
function C.session() return C.GUIS and C.GUIS.session end
function C.prof() local s = C.session(); return s and s.profile_data end
SF.where = (workspace:FindFirstChild("_MAP_CONFIG") and workspace._MAP_CONFIG:FindFirstChild("IsLobby") and workspace._MAP_CONFIG.IsLobby.Value) and "lobby" or "match"

-- ============================================================
--  REQUEST LAYER (one wrapper for every remote: timeout · budget · backoff · log)
-- ============================================================
SF.req = { back = {}, fails = {}, calls = {} }
SF.BUDGET = { upg = 30, place = 15 } -- calls per 10 s per key (default 8)
-- returns ok (the call ran), a, b. A RemoteFunction with no handler on this server never answers, so
-- every call has a timeout and a lobby-only remote is never used in a match.
function SF.request(key, name, ...)
    local r = SF.req
    local t = U.now()
    if r.back[key] and t < r.back[key] then return false, "waiting" end
    local q = r.calls[key] or {}
    r.calls[key] = q
    while q[1] and t - q[1] > 10 do table.remove(q, 1) end
    if #q >= (SF.BUDGET[key] or 8) then r.back[key] = t + 3; return false, "slowing down" end
    table.insert(q, t)
    if not (RS:FindFirstChild("endpoints") and RS.endpoints.client_to_server:FindFirstChild(name)) then return false, "no remote " .. name end
    local args = table.pack(...)
    local done, ok, a, b = false, false, nil, nil
    task.spawn(function()
        ok, a, b = pcall(function() return C.EP.invoke_server(name, table.unpack(args, 1, args.n)) end)
        done = true
    end)
    local t1 = U.now()
    while not done and U.now() - t1 < 15 do task.wait(0.05) end
    if not done then
        r.fails[key] = (r.fails[key] or 0) + 1
        r.back[key] = U.now() + 30
        SF.log(1, "NET", name .. " timeout (no answer in 15s)")
        return false, "timeout"
    end
    if not ok then
        r.fails[key] = (r.fails[key] or 0) + 1
        r.back[key] = U.now() + math.min(60, 2 ^ r.fails[key])
        SF.log(1, "NET", name .. " error: " .. tostring(a))
        return false, tostring(a)
    end
    r.fails[key] = 0
    return true, a, b
end
function SF.backoff(key, sec) SF.req.back[key] = U.now() + sec end

-- ============================================================
--  SPEND HISTORY ("where did my gold go?")
-- ============================================================
function SPEND.add(what, cost, cur, why)
    table.insert(B.spend, 1, { at = os.time(), what = what, cost = cost, cur = cur, why = why })
    while #B.spend > 60 do table.remove(B.spend) end
    SF.log(1, "SPEND", string.format("%s for %s %s — %s", what, U.fmt(cost), cur, why))
    SF.saveSoon()
end
function SPEND.text()
    if #B.spend == 0 then return "nothing spent yet" end
    local rows = {}
    for i = 1, math.min(15, #B.spend) do
        local e = B.spend[i]
        table.insert(rows, string.format("%s  %s — %s %s (%s)", os.date("%b %d %H:%M", e.at), e.what, U.fmt(e.cost), e.cur, e.why or ""))
    end
    return table.concat(rows, "\n")
end

-- ============================================================
--  UNITS: the game's formulas at full growth
-- ============================================================
UNIT._rows, UNIT._mult = {}, {}
-- every upgrade level as a full row (an upgrade only lists what changes)
function UNIT.rows(id)
    if UNIT._rows[id] then return UNIT._rows[id] end
    local d = C.Units[id]
    if type(d) ~= "table" then return nil end
    local cur = { cost = d.cost or 0, damage = d.damage or 0, cd = d.attack_cooldown or 0, range = d.range or 0,
        farm = d.farm_amount or 0, atk = d.primary_attack_no_upgrades or d.primary_attack, active = d.active_attack }
    local rows = { [0] = table.clone(cur) }
    local ups = d.upgrade or {}
    for i, up in ipairs(ups) do
        cur = table.clone(cur)
        cur.cost = up.cost or 0
        if up.damage then cur.damage = up.damage end
        if up.attack_cooldown then cur.cd = up.attack_cooldown end
        if up.range then cur.range = up.range end
        if up.farm_amount then cur.farm = up.farm_amount end
        if up.primary_attack then cur.atk = up.primary_attack end
        if up.active_attack then cur.active = up.active_attack end
        rows[i] = cur
    end
    rows.max = #ups
    UNIT._rows[id] = rows
    return rows
end
function UNIT.isFarm(id) return C.USC and C.USC.unit_static_is_farm(id) or false end
-- everything one attack does, from Data.Attacks: how many enemies it hits (area shapes: single 1, circle by
-- radius, cone by angle, line by length, whole range 3; `aoe_dot` beams count every tick), damage over time
-- (fire / bleed / decay: damage_rate × seconds, as a share of the hit), crowd control seconds (slow × its %,
-- stun / freeze / knockback), damage-taken debuffs (cursed, hexed, dismember) and buffs for your own units
UNIT._atk = {}
UNIT.CC_COOLDOWN = { slow = 3, stun = 8, freeze = 10, haki_stun = 15, knockback = 30, walk_back = 10 } -- Data.Buffs buff_cooldown
function UNIT.attackInfo(atkId, range)
    local key = tostring(atkId) .. ":" .. tostring(range and math.floor(range) or "")
    if UNIT._atk[key] then return UNIT._atk[key] end
    local info = { n = 1, dot = 0, slow = 0, stun = 0, amp = 0, ampPersist = false }
    local a = atkId and C.Attacks[atkId]
    if type(a) ~= "table" then UNIT._atk[key] = info; return info end
    local f = 0
    local function hit(e, ticks)
        if type(e) ~= "table" then return end
        local t = type(e.aoe_type) == "table" and e.aoe_type or {}
        local h = type(e.hit) == "table" and e.hit or {}
        local share = tonumber(h.damage) or 1
        local n = 1
        if t.type == "target_aoe_circ" or t.type == "circle" or t.type == "circ" then n = 1 + (tonumber(t.radius) or 4) / 5
        elseif t.type == "cone" then n = 1 + (tonumber(t.angle) or 45) / 60
        elseif t.type == "full_aoe" or t.type == "full" then n = 3
        elseif t.type == "straight" or t.type == "line" then n = 1 + (tonumber(t.length) or tonumber(range) or 10) / 15 end
        if not e.hit_allies then f = f + share * ticks * math.min(n, 4) end
        for _, b in pairs(h.buffs or {}) do
            if type(b) == "table" and type(b.name) == "string" then
                local p = type(b.params) == "table" and b.params or {}
                local time = tonumber(b.time) or 0
                if e.hit_allies then
                    if b.name:find("^damage_buff__") and type(p.damage_types) == "table" then
                        local kinds = {}
                        for k, v in pairs(p.damage_types) do kinds[k] = type(v) == "table" and tonumber(v.rate) or 0 end
                        info.ally = { types = kinds, time = time }
                    elseif b.name == "attack_cooldown_buff" then info.allyCd = { reduce = tonumber(p.attack_cooldown_reduce) or 0, time = time }
                    elseif b.name == "range_buff" then info.allyRange = { add = tonumber(p.range_add) or 0, time = time } end
                else
                    if tonumber(p.damage_rate) then info.dot = info.dot + tonumber(p.damage_rate) * math.max(1, time) end
                    if b.name == "slow" then info.slow = math.max(info.slow, (tonumber(p.slow_percent) or 0.3) * time)
                    elseif b.name == "stun" or b.name == "freeze" or b.name == "haki_stun" then info.stun = math.max(info.stun, time)
                    elseif b.name == "knockback" or b.name == "walk_back" then info.stun = math.max(info.stun, time * 0.5)
                    elseif tonumber(p.amplification) then
                        info.amp = math.max(info.amp, tonumber(p.amplification))
                        if p.persistent then info.ampPersist = true end
                    end
                    if UNIT.CC_COOLDOWN[b.name] then info.ccCd = math.max(info.ccCd or 0, UNIT.CC_COOLDOWN[b.name]) end
                end
            end
        end
    end
    for _, e in pairs(type(a.aoe) == "table" and a.aoe or {}) do hit(e, 1) end
    for _, d in pairs(type(a.aoe_dot) == "table" and a.aoe_dot or {}) do
        if type(d) == "table" and type(d.aoe) == "table" then
            hit(d.aoe, (tonumber(d.time) or 1) / math.max(0.1, tonumber(d.interval) or 1))
        end
    end
    info.n = math.max(0.3, f > 0 and f or (info.ally and 0.3 or 1))
    info.dot = math.min(1.5, info.dot)
    UNIT._atk[key] = info
    return info
end
-- damage share an attack deals across enemies: targets hit × (1 + damage over time)
function UNIT.aoe(atkId, range)
    local i = UNIT.attackInfo(atkId, range)
    return i.n * (1 + i.dot)
end
-- crowd control and debuffs as a multiplier on the whole team's damage: slowed / stunned enemies stay in range
-- longer, cursed ones take more damage. Uptime = effect seconds ÷ max(attack cooldown, the enemy's immunity time)
function UNIT.teamEffect(atkId, range, cd)
    local i = UNIT.attackInfo(atkId, range)
    local spacing = math.max(cd or 1, i.ccCd or 0, 0.5)
    local reach = math.min(1, i.n / 4)
    local cc = math.min(1, (i.slow + i.stun) / spacing) * reach
    local amp = i.amp * (i.ampPersist and 1 or math.min(1, 5 / spacing)) * reach
    return cc * 0.5 + amp
end
-- a unit's buff for your other units (its active ability): {types = {magic = 0.3}, uptime, cd, id} or nil
function UNIT.allyBuff(id)
    local d = C.Units[id]
    if type(d) ~= "table" or not d.active_attack then return nil end
    local i = UNIT.attackInfo(d.active_attack)
    if not i.ally then return nil end
    local cd = tonumber(d.active_attack_stats and d.active_attack_stats.attack_cooldown) or 60
    return { types = i.ally.types, time = i.ally.time, cd = cd, uptime = math.min(1, (i.ally.time or 0) / math.max(1, cd)), attack = d.active_attack }
end
-- the game's own stat multiplier: level, trait, stat rolls, limit breaks, curses, level modifiers
function UNIT.mult(u, stat)
    local key = tostring(u.uuid) .. stat
    local c = UNIT._mult[key]
    if c and U.now() - c.t < 60 then return c.v end
    local ok, v = pcall(C.USC.calculate_static_stat_multiplier, u, u.xp, stat, C.session())
    v = ok and tonumber(v) or 1
    UNIT._mult[key] = { v = v, t = U.now() }
    return v
end
function UNIT.types(id)
    local d = C.Units[id] or {}
    local t = { [d._base_damage_type or "physical"] = true }
    for k in pairs(d._secondary_damage_types or {}) do t[k] = true end
    return t, d._base_damage_type or "physical"
end
-- the mode's weak / strong elements: weak ×amplification (×1.5 when the game gives none), strong ×0.5
function UNIT.elem(id, mod)
    if not mod then return 1 end
    local types, base = UNIT.types(id)
    local f = 1
    for t in pairs(types) do if mod.weak[t] then f = math.max(f, mod.weak[t]) end end
    if mod.strong[base] then f = f * 0.5 end
    return f
end
-- relic damage-type buffs for the unit's own damage types (crit / special effects are inside the live stats)
function UNIT.relic(u)
    local s = C.session()
    if not (s and u._equipped_relic) then return 1 end
    local ok, it = pcall(function() return s.inventory:get_item_by_uuid(u._equipped_relic) end)
    local rd = ok and it and it._unique_item_data and it._unique_item_data._unique_relic_data
    if not (rd and rd._core_damage_type_buffs) then return 1 end
    local types = UNIT.types(u.unit_id)
    local f = 1
    for _, b in pairs(rd._core_damage_type_buffs) do
        if type(b) == "table" and types[b.damage_type] and tonumber(b.mul) then f = f + b.mul end
    end
    return f
end
function UNIT.relicName(u)
    local s = C.session()
    if not (s and u._equipped_relic) then return nil end
    local ok, it = pcall(function() return s.inventory:get_item_by_uuid(u._equipped_relic) end)
    local d = ok and it and C.Items[it.item_id]
    return d and d.name or (ok and it and it.item_id) or nil
end
-- measured damage vs predicted, as a capped nudge (×0.8–×1.35)
function UNIT.nudge(id)
    local l = B.learn[id]
    if not (l and l.n and l.n >= 3) then return 1 end
    return U.clamp(math.sqrt(l.eff or 1), 0.8, 1.35)
end
function UNIT.trait(u)
    for _, t in pairs(u.traits or {}) do if type(t) == "table" then return t.trait, t.tier end end
    return nil
end
-- how many copies may be on the field: the unit's spawn cap, 1 for the Unique trait ("There can only be
-- one"), lowered further by what the server really allowed
function UNIT.cap(u)
    local d = C.Units[u.unit_id] or {}
    local cap = tonumber(d.spawn_cap) or 1
    if UNIT.trait(u) == "unique" then cap = 1 end
    local learned = tonumber(B.caps[u.uuid])
    if learned then cap = math.min(cap, learned) end
    return math.max(1, cap)
end
-- damage per second at an upgrade level (stat multipliers + area + element + relic + measured nudge)
function UNIT.dps(u, lvl, mod)
    local rows = UNIT.rows(u.unit_id)
    local r = rows and rows[math.min(lvl, rows.max)]
    if not r or (r.cd or 0) <= 0 then return 0 end
    return r.damage * UNIT.mult(u, "damage") / (r.cd * math.max(0.1, UNIT.mult(u, "attack_cooldown")))
        * UNIT.aoe(r.atk, r.range) * UNIT.elem(u.unit_id, mod) * UNIT.relic(u) * UNIT.nudge(u.unit_id)
end
function UNIT.range(u, lvl)
    local rows = UNIT.rows(u.unit_id)
    local r = rows and rows[math.min(lvl, rows.max)]
    return (r and r.range or 10) * UNIT.mult(u, "range")
end
function UNIT.farm(u, lvl)
    local rows = UNIT.rows(u.unit_id)
    local r = rows and rows[math.min(lvl, rows.max)]
    return (r and r.farm or 0) * UNIT.mult(u, "farm_amount")
end
-- the unit score: damage at full upgrade × √range × √copies (money limits how many copies get far)
function UNIT.score(u, mod)
    local rows = UNIT.rows(u.unit_id)
    if not rows then return 0 end
    local top = rows.max
    return UNIT.dps(u, top, mod) * math.sqrt(math.max(1, UNIT.range(u, top)) / 20) * math.sqrt(UNIT.cap(u))
end
function UNIT.name(id) local d = C.Units[id]; return d and d.name or tostring(id) end
function UNIT.equipped()
    local s = C.session()
    local out = {}
    if not s then return out end
    for slot, uuid in pairs(s.profile_data.collection.equipped_units or {}) do
        local u = s.collection:get_unit_by_uuid(uuid)
        if u and C.Units[u.unit_id] then table.insert(out, { slot = tonumber(slot) or 0, uuid = uuid, u = u, id = u.unit_id, data = C.Units[u.unit_id] }) end
    end
    table.sort(out, function(a, b) return a.slot < b.slot end)
    return out
end
function UNIT.owns(id)
    local s = C.session()
    if not s then return false end
    for _, u in pairs(s.profile_data.collection.owned_units or {}) do
        if u.unit_id == id or (C.Units[u.unit_id] and C.Units[u.unit_id].evolved and C.Units[u.unit_id].evolved.from == id) then return true end
    end
    return false
end

-- ============================================================
--  MODES: one ranking in gems per minute
-- ============================================================
MODE.PRIOR_MIN = { story = 4.5, challenge = 5, daily = 10, event = 11, raid = 6 }
MODE.PRIOR_WIN = { story = 0.9, hard = 0.8, new = 0.65, challenge = 0.75, daily = 0.7, event = 0.75, raid = 0.6 }
MODE.OVERHEAD = 0.7 -- minutes of lobby + teleport per run (less on a replay)
function MODE.rec(key)
    local r = B.modes[key]
    if not r then r = { runs = 0, wins = 0, sec = 0, gems = 0, coins = 0, streak = 0 }; B.modes[key] = r end
    return r
end
function MODE.itemValue(id, amount)
    -- an item a top goal still needs is worth its share of that goal (the path to stronger units) — only up to
    -- what the goal still needs: the rest of a big drop is worth what the item is normally worth
    if B.goalItems[id] then
        local a = amount or 1
        local inGoal = math.min(a, tonumber(B.goalNeed[id]) or a)
        return B.goalItems[id] * inGoal + (C.ITEM_VALUE[id] or C.ITEM_DEFAULT) * math.max(0, a - inGoal)
    end
    local cap = C.GS.ITEM_CAPS and C.GS.ITEM_CAPS[id]
    local s = C.session()
    local have = 0
    pcall(function() have = s.inventory:get_number_of_owned_item(id) end)
    if cap and have >= cap then return 0 end
    return (C.ITEM_VALUE[id] or C.ITEM_DEFAULT) * (amount or 1)
end
-- expected gem value of a challenge reward table (`_rewards`: gems + items, `_item_multichoice` = you get m of n)
function MODE.rewardValue(rw)
    local total = 0
    for _, r in pairs((rw and rw._rewards) or {}) do
        if type(r) == "table" then
            total = total + (tonumber(r.gem_reward) or 0) + (tonumber(r.gold_reward) or 0) * C.GOLD_VALUE
            local items = U.list(r.item)
            local share = 1
            if r._item_multichoice and #items > 0 then share = math.min(1, (tonumber(r._item_multichoice.min) or #items) / #items) end
            for _, it in ipairs(items) do
                local amt = tonumber(it.amount) or ((tonumber(it.min_amount) or 1) + (tonumber(it.max_amount) or tonumber(it.min_amount) or 1)) / 2
                local p = (tonumber(it.chance) or 1) * (1 - (tonumber(it._zero_chance) or 0))
                total = total + MODE.itemValue(it.item_id, amt) * p * share
            end
        end
    end
    return total
end
function MODE.done(ld, id, diff)
    if B.cleared[id .. ":" .. tostring(diff or "Normal")] then return true end
    local d = ld.completed_story_levels and ld.completed_story_levels[id]
    if not d then return false end
    if diff and d.difficulty_completed_data then
        local x = d.difficulty_completed_data[diff]
        return x and (x.times_completed or 0) > 0 or false
    end
    return (d.times_completed or 0) > 0
end
function MODE.levelName(id)
    local lv = C.Levels[id]
    if not lv then return tostring(id) end
    local w = lv.world and C.Worlds[lv.world]
    return (w and w.name and (w.name .. " ") or "") .. (lv.name or id)
end
-- every mode that can be played right now, with its value per run (gems) and its odds
function MODE.list()
    local p = C.prof()
    if not p then return {} end
    local ld = p.level_data
    local out = {}
    local now = os.time()
    local function add(m)
        m.rec = MODE.rec(m.key)
        if (m.rec.restUntil or 0) > now then return end
        table.insert(out, m)
    end
    -- daily challenge (once a day) and the half-hour challenge (once per rotation)
    local live = B.live or {}
    if CFG.dailyChallenge and live.daily and live.daily.uuid and live.daily.uuid ~= p.last_completed_daily_challenge_uuid
        and live.daily.uuid ~= live.daily.doneUuid and (live.daily.lost or 0) < 2 then
        add({ key = "dc", kind = "daily", level = "__DAILY_CHALLENGE", diff = "Hard", value = live.daily.value or 300,
            label = "Daily Challenge", why = string.format("daily reward ≈%s gems of gems + items", U.fmt(live.daily.value or 0)), mod = live.daily.mod })
    end
    if CFG.challenge and live.normal and live.normal.uuid and live.normal.uuid ~= p.last_completed_challenge_uuid
        and live.normal.uuid ~= live.normal.doneUuid and (live.normal.expires or 0) > now + 360 and (live.normal.lost or 0) < 2 then
        add({ key = "ch", kind = "challenge", level = live.normal.level, diff = "Hard", value = live.normal.value or 100,
            label = "Challenge · " .. MODE.levelName(live.normal.level), why = "new challenge every 30 min", challenge = live.normal.challenge })
    end
    -- story: first clears (Normal, then Hard on the same act) and farm runs on cleared acts
    local order = U.list(C.WLO.WORLD_ORDER)
    for rank, w in ipairs(order) do
        local wd = C.Worlds[w]
        if wd and not wd.legend_stage and not wd.raid_world then
            local acts = U.list(wd.levels)
            for n, a in ipairs(acts) do
                local id = a.id
                local okU, unlocked = pcall(C.PSC.check_if_unlocked_level, ld, id)
                if okU and unlocked then
                    for _, diff in ipairs({ "Normal", "Hard" }) do
                        local okD, dOk = pcall(C.PSC.check_if_unlocked_difficulty, ld, id, diff)
                        if okD and dOk and not MODE.done(ld, id, diff) and CFG.firstClears then
                            local newWorld = rank >= 16
                            add({ key = "st:" .. id .. ":" .. diff, kind = "story", first = true, level = id, diff = diff, rank = rank,
                                value = (C.GS.GEM_REWARD_STORY_FIRST or 60) + CFG.unlockValue,
                                p0 = newWorld and MODE.PRIOR_WIN.new or (diff == "Hard" and MODE.PRIOR_WIN.hard or MODE.PRIOR_WIN.story),
                                label = MODE.levelName(id) .. " (" .. diff .. ")", why = "first clear: " .. (C.GS.GEM_REWARD_STORY_FIRST or 60) .. " gems + unlocks the next act" })
                            break -- Hard needs Normal first
                        end
                    end
                    if CFG.farm and rank <= 3 and MODE.done(ld, id, "Normal") then
                        add({ key = "st:" .. id .. ":Normal", kind = "story", level = id, diff = "Normal", rank = rank,
                            value = (C.GS.GEM_REWARD_STORY or 20), p0 = MODE.PRIOR_WIN.story,
                            label = MODE.levelName(id) .. " (farm)", why = (C.GS.GEM_REWARD_STORY or 20) .. " gems a clear" })
                    end
                end
            end
        end
    end
    -- raids: tries left today, gems + raid items
    if CFG.raids then
        for _, w in ipairs(U.list(C.WLO.RAID_WORLD_ORDER)) do
            local wd = C.Worlds[w]
            for _, a in ipairs(U.list(wd and wd.levels)) do
                local lv = C.Levels[a.id]
                local okU, unlocked = pcall(C.PSC.check_if_unlocked_level, ld, a.id)
                if lv and okU and unlocked then
                    local tries = tonumber(lv._raid_daily_tries)
                    local used = (p.raid_tries and p.raid_tries.levels and tonumber(p.raid_tries.levels[a.id])) or 0
                    if not tries or used < tries then
                        local items, goalTxt = 0, nil
                        for _, x in ipairs(ADV.levelItems(lv)) do
                            items = items + MODE.itemValue(x.item, x.per)
                            if B.goalItems[x.item] then goalTxt = string.format("≈%.0f %s a run toward your goal", x.per, (C.Items[x.item] or {}).name or x.item) end
                        end
                        local first = not MODE.done(ld, a.id)
                        local gems = tonumber(lv._override_gem_reward) or (C.GS.GEM_REWARD_RAID or 75)
                        add({ key = "rd:" .. a.id, kind = "raid", level = a.id, diff = "Hard", first = first,
                            value = gems + items + (first and CFG.unlockValue or 0), p0 = MODE.PRIOR_WIN.raid,
                            label = MODE.levelName(a.id), why = (goalTxt and (goalTxt .. " · ") or "") .. string.format("raid: %d gems + items%s", gems, tries and string.format(" · %d/%d tries left", tries - used, tries) or "") })
                    end
                end
            end
        end
    end
    -- legend stages, when they drop an item one of your goals needs
    if CFG.goals and next(B.goalItems) then
        for _, w in ipairs(U.list(C.WLO.LEGEND_WORLD_ORDER)) do
            local wd = C.Worlds[w]
            for _, a in ipairs(U.list(wd and wd.levels)) do
                local lv = C.Levels[a.id]
                local okU, unlocked = pcall(C.PSC.check_if_unlocked_level, ld, a.id)
                if lv and okU and unlocked then
                    local items, goalTxt = 0, nil
                    for _, x in ipairs(ADV.levelItems(lv)) do
                        if B.goalItems[x.item] then
                            items = items + MODE.itemValue(x.item, x.per)
                            goalTxt = string.format("≈%.1f %s a run toward your goal", x.per, (C.Items[x.item] or {}).name or x.item)
                        end
                    end
                    if items > 0 then
                        local first = not MODE.done(ld, a.id, "Hard")
                        add({ key = "st:" .. a.id .. ":Hard", kind = "story", level = a.id, diff = "Hard", first = first,
                            value = items + (first and ((C.GS.GEM_REWARD_STORY_FIRST or 60) + CFG.unlockValue) or 0), p0 = MODE.PRIOR_WIN.hard,
                            label = MODE.levelName(a.id), why = goalTxt })
                    end
                end
            end
        end
    end
    -- the current event: Fool's Hunt pays AprilCoins per wave
    if CFG.event and live.event and live.event.level then
        local r = MODE.rec("ev:" .. live.event.level)
        local coins = r.runs > 0 and (r.coins / r.runs) or 400
        add({ key = "ev:" .. live.event.level, kind = "event", level = live.event.level, diff = "Hard",
            value = coins * CFG.aprilValue, coins = coins, p0 = MODE.PRIOR_WIN.event,
            label = live.event.name or "Event", why = string.format("≈%d AprilCoins a run (×%.2f gems each)", math.floor(coins), CFG.aprilValue) })
    end
    return out
end
function MODE.teamSig()
    if MODE._sigAt and U.now() - MODE._sigAt < 20 then return MODE._sig end
    local units = {}
    for _, e in ipairs(UNIT.equipped()) do table.insert(units, e.u) end
    MODE._sig, MODE._sigAt = SIM.sig(units), U.now()
    return MODE._sig
end
-- a simulation of this mode with the team you have equipped now (nil when there is none or it's stale)
function MODE.sim(m)
    local sr = CFG.sim and B.simRes[m.key]
    if sr and sr.p and sr.sig == MODE.teamSig() and os.time() - (sr.at or 0) < 6 * 3600 then return sr end
    return nil
end
function MODE.winP(m)
    local r = m.rec
    local p0 = m.p0 or MODE.PRIOR_WIN[m.kind] or 0.7
    local sr = MODE.sim(m)
    -- the sim's weight is earned per mode: 1.5 runs of evidence before the mode has any real run (the prior
    -- still counts, so one calibration run can happen), 3 once calibrated, 6 once it matched real runs with
    -- this team — and none where it failed that check (real runs decide there)
    if sr and not (sr.trust and not sr.trust.ok) then
        local calibrated = sr.calibrated or r.runs > 0
        local w = (sr.trust and sr.trust.ok) and 6 or (calibrated and 3 or 1.5)
        local pw = calibrated and 0 or 2
        return (r.wins + p0 * pw + sr.p * w) / (r.runs + pw + w)
    end
    return (r.wins + p0 * 2) / (r.runs + 2)
end
function MODE.minutes(m)
    local r = m.rec
    local timed = tonumber(r.timed) or 0
    local mins = (timed > 0 and r.sec > 0) and (r.sec / timed / 60) or MODE.PRIOR_MIN[m.kind] or 6
    return mins + MODE.OVERHEAD
end
function MODE.score(m)
    local s = MODE.winP(m) * m.value / MODE.minutes(m)
    if m.rec.runs < 2 then s = s * (1 + CFG.exploreBonus) end
    return s
end
function MODE.pick()
    local list = MODE.list()
    for _, m in ipairs(list) do
        m.score = MODE.score(m); m.p = MODE.winP(m)
        local sr = MODE.sim(m)
        if sr and not tostring(m.why):find("sim:") then
            local untrusted = sr.trust and not sr.trust.ok
            m.why = (m.why or "") .. " · sim: " .. (untrusted and string.format("not trusted here (off ×%.1f vs real runs)", sr.trust.ratio) or tostring(sr.margin))
        end
    end
    table.sort(list, function(a, b) return a.score > b.score end)
    MODE.lastScored = list
    return list[1]
end
-- the mode being played in this match, as a key the ranking uses
function MODE.fromLevelData(ld)
    if not ld then return nil end
    local id = ld.id
    if id == "__DAILY_CHALLENGE" then return "dc", "daily" end
    if ld._challenge then return "ch", "challenge" end
    if ld._gamemode == "raid" and B.live.event and B.live.event.level == id then return "ev:" .. id, "event" end
    if ld._gamemode == "raid" or (C.Levels[id] and C.Levels[id].is_raid) then return "rd:" .. id, "raid" end
    if ld._gamemode == "story" then return "st:" .. id .. ":" .. tostring(ld._difficulty or "Normal"), "story" end
    return tostring(ld._gamemode) .. ":" .. tostring(id), tostring(ld._gamemode)
end

-- ============================================================
--  THE PATH TO STRONGER UNITS (goals → items → where to farm them)
-- ============================================================
-- what a level pays in items per run: {item, per} from its reward table (amount × chance; a "pick m of n"
-- group counts m/n of each), else 1 of each item it shows
function ADV.levelItems(lv)
    local out = {}
    if type(lv) ~= "table" then return out end
    local groups = lv.rewards
    if type(groups) == "table" and groups.item then groups = { groups } end
    local any = false
    for _, g in pairs(type(groups) == "table" and groups or {}) do
        if type(g) == "table" then
            local items = U.list(g.item)
            local share = 1
            if g._item_multichoice and #items > 0 then share = math.min(1, (tonumber(g._item_multichoice.min) or #items) / #items) end
            for _, x in ipairs(items) do
                if type(x) == "table" and x.item_id then
                    local amt = tonumber(x.amount) or ((tonumber(x.min_amount) or 1) + (tonumber(x.max_amount) or tonumber(x.min_amount) or 1)) / 2
                    table.insert(out, { item = x.item_id, per = amt * (tonumber(x.chance) or 1) * share })
                    any = true
                end
            end
        end
    end
    if not any then
        for _, r in pairs(type(lv._show_rewards) == "table" and lv._show_rewards or {}) do
            if type(r) == "table" and r.type == "item" and r.params and r.params.item_id then table.insert(out, { item = r.params.item_id, per = 1 }) end
        end
    end
    return out
end
function ADV.sources()
    if ADV._src then return ADV._src end
    local src = {}
    for id, lv in pairs(C.Levels) do
        for _, x in ipairs(ADV.levelItems(lv)) do
            src[x.item] = src[x.item] or {}
            table.insert(src[x.item], { level = id, per = x.per })
        end
    end
    for _, l in pairs(src) do table.sort(l, function(a, b) return a.per > b.per end) end
    ADV._src = src
    return src
end
function ADV.have(id) local s = C.session(); local n = 0; pcall(function() n = s.inventory:get_number_of_owned_item(id) end); return n end
-- kills / takedowns the unit still needs for its evolution (the game: _kill_requirement vs total_kills,
-- _takedown_requirement vs total_takedowns — Tamiki needs 5,000 takedowns); nil when it has them
function ADV.killsShort(u, req)
    if not req then return nil end
    local tk = tonumber(req._takedown_requirement)
    if tk and (tonumber(u.total_takedowns) or 0) < tk then return { what = "takedowns", have = tonumber(u.total_takedowns) or 0, need = tk } end
    local kl = tonumber(req._kill_requirement)
    if kl and (tonumber(u.total_kills) or 0) < kl then return { what = "kills", have = tonumber(u.total_kills) or 0, need = kl } end
    return nil
end
-- your copies of a unit an evolution could use up: unlocked (the game never takes a locked unit), shiny if it
-- must be, and not the unit being evolved
function ADV.copies(id, shiny, exclude)
    local s = C.session()
    local list = {}
    for _, o in pairs(s and s.profile_data.collection.owned_units or {}) do
        if o.unit_id == id and o.uuid ~= exclude and not o._locked and (not shiny or o.shiny) then table.insert(list, o) end
    end
    return list
end
-- where to farm an item: the most of it per minute, counting your win chance there (a big drop in a mode you
-- lose pays nothing) — from the farm's own ranking; levels it can't play now count at half odds and 10 min
function ADV.bestSource(levels)
    if not (MODE.lastScored and MODE.lastScored[1]) then pcall(MODE.pick) end
    local scored = {}
    for _, m in ipairs(MODE.lastScored or {}) do if m.level then scored[m.level] = m end end
    local best, bv
    for _, l in ipairs(levels or {}) do
        local m = scored[l.level]
        local okM, mins = pcall(function() return m and MODE.minutes(m) or 10 end)
        local v = l.per * (m and (m.p or 0.5) or 0.5) / math.max(1, okM and mins or 10)
        if not bv or v > bv then best, bv = l, v end
    end
    return best
end
-- how to get `need` of an item: drop it, or buy it in the raid shop with another item that drops
function ADV.planItem(id, need)
    local have = ADV.have(id)
    if have >= need then return { item = id, done = true } end
    local src = ADV.sources()[id]
    if src and src[1] then
        return { item = id, need = need, have = have, farm = id, farmNeed = need - have, levels = src }
    end
    for key, s in pairs(B.raidShop) do
        if s.id == id and s.costItem and (s.stock == "inf" or (tonumber(s.stock) or 0) > 0) then
            local cs = ADV.sources()[s.costItem]
            local costNeed = s.cost * (need - have)
            local costHave = ADV.have(s.costItem)
            return { item = id, need = need, have = have, shopKey = key, costItem = s.costItem, cost = s.cost,
                farm = s.costItem, farmNeed = math.max(0, costNeed - costHave), levels = cs or {} }
        end
    end
    return { item = id, need = need, have = have, unknown = true }
end
-- every evolution you're close to: what it gives (the game's formula at full upgrade) and how to finish it
function ADV.goals()
    local s = C.session()
    if not s then return {} end
    local team = UNIT.equipped()
    -- "joins your team" = beats your weakest damage dealer (farm units and buffers are valued for their role)
    local weakest = math.huge
    for _, e in ipairs(team) do
        if not UNIT.isFarm(e.id) and not UNIT.allyBuff(e.id) then local ok, sc = pcall(UNIT.score, e.u); if ok then weakest = math.min(weakest, sc) end end
    end
    -- the copy to evolve: your best one of each unit (score at full upgrade; the equipped one on a tie)
    local onTeam = {}
    for _, e in ipairs(team) do onTeam[e.uuid] = true end
    local bestCopy = {}
    for _, u0 in pairs(s.profile_data.collection.owned_units) do
        local d = C.Units[u0.unit_id]
        if d and d.evolve and d.evolve.evolve_unit and not d.evolve.hide_from_ui and C.Units[d.evolve.evolve_unit] then
            local okS, sc = pcall(UNIT.score, s.collection:get_unit_by_uuid(u0.uuid) or u0)
            sc = (okS and sc or 0) + (onTeam[u0.uuid] and 0.5 or 0)
            if not bestCopy[u0.unit_id] or sc > bestCopy[u0.unit_id].sc then bestCopy[u0.unit_id] = { u0 = u0, sc = sc } end
        end
    end
    local out = {}
    for _, bc in pairs(bestCopy) do
        local u0 = bc.u0
        local d = C.Units[u0.unit_id]
        do
            local req = u0.shiny and d.evolve.shiny or d.evolve.normal
            -- other copies it uses up, counted like the game's evolve window: your unlocked copies, not this one
            -- (the unit itself counts as one of a requirement for its own kind)
            local unitsOk, eats = true, {}
            for _, ur in pairs(req and req.unit_requirement or {}) do
                local want = (tonumber(ur.amount) or 1) - (ur.unit_id == u0.unit_id and 1 or 0)
                if want > 0 then
                    if #ADV.copies(ur.unit_id, ur.shiny, u0.uuid) < want then unitsOk = false end
                    table.insert(eats, { id = ur.unit_id, amount = want, shiny = ur.shiny and true or nil })
                end
            end
            local items = {}
            for _, it in pairs(req and req.item_requirement or {}) do table.insert(items, { id = it.item_id, amount = tonumber(it.amount) or 1 }) end
            if req and unitsOk then
                local u = s.collection:get_unit_by_uuid(u0.uuid) or u0
                local evolved = { unit_id = d.evolve.evolve_unit, uuid = "evo:" .. tostring(u.uuid), xp = u.xp, traits = u.traits, trait_stats = u.trait_stats, further_modifiers = u.further_modifiers }
                local okA, a = pcall(UNIT.score, u)
                local okB, b = pcall(UNIT.score, evolved)
                a, b = okA and a or 0, okB and b or 0
                local plans, runs, unknown, ready = {}, 0, false, true
                -- kills / takedowns come from playing the unit, not from farming items
                local short = ADV.killsShort(u, req)
                if short then ready = false; table.insert(plans, { takedown = true, what = short.what, have = short.have, need = short.need }) end
                for _, it in pairs(req.item_requirement or {}) do
                    local p = ADV.planItem(it.item_id, it.amount or 1)
                    if not p.done then
                        ready = false
                        table.insert(plans, p)
                        if p.unknown then unknown = true
                        elseif p.farmNeed > 0 then
                            p.best = ADV.bestSource(p.levels)
                            runs = runs + p.farmNeed / math.max(0.1, p.best and p.best.per or 1)
                        end
                    end
                end
                if b > a then
                    table.insert(out, { uuid = u0.uuid, from = u0.unit_id, to = d.evolve.evolve_unit, scoreFrom = a, scoreTo = b, gain = b - a,
                        intoTeam = b > weakest, ready = ready, unknown = unknown, plans = plans, runs = runs, items = items, eats = eats })
                end
            end
        end
    end
    -- best first: ready ones, then what joins your team, by strength gained per run of farming
    table.sort(out, function(x, y)
        if x.ready ~= y.ready then return x.ready end
        if x.unknown ~= y.unknown then return not x.unknown end
        if x.intoTeam ~= y.intoTeam then return x.intoTeam end
        return x.gain / math.max(1, x.runs) > y.gain / math.max(1, y.runs)
    end)
    return out
end
-- a goal in plain words: "Shinobi (Hood) → Shinobi (Storm) · 35k → 96k · 84 more Storm Hideout items (≈6 runs)"
function ADV.text(g)
    local parts = {}
    for _, p in ipairs(g.plans) do
        local name = (C.Items[p.item] or {}).name or p.item
        if p.takedown then table.insert(parts, string.format("%s %s/%s (it earns them on your team)", p.what, U.fmt(p.have), U.fmt(p.need)))
        elseif p.unknown then table.insert(parts, name .. ": source unknown (event/portal)")
        elseif p.shopKey then
            table.insert(parts, string.format("%s from the raid shop: %d/%d %s", name, ADV.have(p.costItem), p.cost * (p.need - p.have), (C.Items[p.costItem] or {}).name or p.costItem))
        else table.insert(parts, string.format("%s %d/%d", name, p.have, p.need)) end
    end
    local where = ""
    local p1
    for _, p in ipairs(g.plans) do if p.levels and p.levels[1] then p1 = p; break end end
    local src = p1 and (p1.best or p1.levels[1])
    if src then where = string.format(" · farm %s (≈%.0f a run, ≈%d runs)", MODE.levelName(src.level), src.per, math.ceil(g.runs)) end
    return string.format("%s → %s · score %s → %s%s · %s%s", UNIT.name(g.from), UNIT.name(g.to), U.fmt(g.scoreFrom), U.fmt(g.scoreTo),
        g.intoTeam and " (joins your team)" or "", g.ready and "ready to evolve" or table.concat(parts, "; "), g.ready and "" or where)
end
-- refresh the goals, and give the items of the top goals their value (they're what makes you stronger)
function ADV.refresh()
    local goals = ADV.goals()
    B.goals = {}
    table.clear(B.goalItems)
    table.clear(B.goalNeed)
    local valued = 0
    for _, g in ipairs(goals) do
        table.insert(B.goals, { uuid = g.uuid, from = g.from, to = g.to, ready = g.ready, intoTeam = g.intoTeam, unknown = g.unknown, text = ADV.text(g),
            gain = g.gain, runs = g.runs, plans = g.plans, items = g.items, eats = g.eats, scoreFrom = g.scoreFrom, scoreTo = g.scoreTo })
        if CFG.goals and not g.ready and not g.unknown and (g.intoTeam or valued == 0) and valued < 2 then
            valued = valued + 1
            for _, p in ipairs(g.plans) do
                if p.farm and p.farmNeed > 0 then
                    local v = CFG.goalValue * (g.intoTeam and 1 or 0.4) / (valued == 1 and 1 or 2) / math.max(1, p.farmNeed)
                    B.goalItems[p.farm] = math.max(B.goalItems[p.farm] or 0, v)
                    B.goalNeed[p.farm] = math.max(B.goalNeed[p.farm] or 0, p.farmNeed)
                end
            end
        end
        if #B.goals >= 12 then break end
    end
    SF.saveSoon()
    return goals
end
-- spend: a goal's item from the raid shop, once the raid items are in (raid items buy nothing else you need)
function ADV.buyShopGoals()
    if not CFG.raidShopGoals then return end
    for _, g in ipairs(B.goals) do
        for _, p in ipairs(g.plans or {}) do
            if p.shopKey and p.costItem and ADV.have(p.item) < p.need and ADV.have(p.costItem) >= p.cost then
                local before = ADV.have(p.costItem)
                local ok, r = SF.request("rshop", "buy_raidshop_shop_item", p.shopKey, "1")
                local t1 = U.now()
                while U.now() - t1 < 3 and ADV.have(p.costItem) >= before do task.wait(0.2) end
                if ok and ADV.have(p.costItem) < before then
                    SPEND.add((C.Items[p.item] or {}).name or p.item, p.cost, (C.Items[p.costItem] or {}).name or p.costItem, "for " .. UNIT.name(g.to))
                    if SF.notify then SF.notify("Path", string.format("Bought %s for %s (Path tab)", (C.Items[p.item] or {}).name or p.item, UNIT.name(g.from)), "success") end
                    return true
                else
                    SF.log(1, "SHOP", "raid shop refused " .. tostring(p.shopKey) .. " (" .. tostring(r) .. ")")
                    SF.backoff("rshop", 900)
                end
                return
            end
        end
    end
end

-- limit break in plain words: once per unit (level cap 100 → 110, and +5% damage for the whole team while
-- it's on the field), needs a Divine Wish + Mythic/Secret units destroyed as fuel (evolved ones count 2)
function ADV.lbText()
    local s = C.session()
    if not s then return "…" end
    local lb = B.lb
    local wish = ADV.have("divine_wish")
    local eq = {}
    for _, e in ipairs(UNIT.equipped()) do eq[e.uuid] = true end
    local fuel, locked = 0, 0
    for uuid, u in pairs(s.profile_data.collection.owned_units) do
        local d = C.Units[u.unit_id]
        if d and (d.rarity == "Mythic" or d.rarity == "Secret") and not d._event_unit and not eq[uuid] then
            local ok, good, pts = pcall(C.USC.is_unit_good_for_fusion, { uuid = "x" }, u)
            pts = (ok and good) and (tonumber(pts) or 1) or 0
            if u._locked then locked = locked + pts else fuel = fuel + pts end
        end
    end
    local best, bs
    for _, e in ipairs(UNIT.equipped()) do
        local cur = e.u.further_modifiers and e.u.further_modifiers.limit_break and e.u.further_modifiers.limit_break.current_limit_break or 0
        if cur < 1 and not UNIT.isFarm(e.id) then local ok, sc = pcall(UNIT.score, e.u); if ok and (not bs or sc > bs) then best, bs = e, sc end end
    end
    local need = lb and tonumber(lb.requirement) or 12
    return string.format("Best target: %s (your strongest unit; level cap 100 → 110 ≈ +20%% damage after levelling, and +5%% damage for your whole team). "
        .. "Needs %d fuel points: you have %d in unlocked Mythic/Secret units (+%d in locked ones) and %d Divine Wish. "
        .. "It destroys the fuel units, so the farm never does it — the Unit Fusion NPC does it when you choose.",
        best and UNIT.name(best.id) or "—", need, fuel, locked, wish)
end
function ADV.traitText()
    local p = C.prof()
    if not p then return "…" end
    -- odds per roll from the game's own trait weights
    local traits = C.data("Traits") or {}
    local total, rows = 0, {}
    for _, t in pairs(traits) do if type(t) == "table" then total = total + (tonumber(t.weight) or 0) end end
    for _, t in pairs(traits) do
        if type(t) == "table" and (t.rarity == "Mythic" or t.id == "godspeed") and total > 0 then
            table.insert(rows, { name = t.name or t.id, p = (tonumber(t.weight) or 0) / total })
        end
    end
    table.sort(rows, function(a, b) return a.p < b.p end)
    local odds = {}
    for _, r in ipairs(rows) do table.insert(odds, string.format("%s %.2f%%", r.name, r.p * 100)) end
    local mythic = 0
    for _, r in ipairs(rows) do if r.name ~= "Godspeed" then mythic = mythic + r.p end end
    return string.format("You have %d Star Remnant, %d Star Remnant (Limited), %d Trait Reroll (Legacy) (only units from before Holidays 2024) and %d trait tokens. "
        .. "Limited remnants come 10–50 at a time from the Daily Challenge (played when the simulator says your team wins). "
        .. "Odds per roll: %s. Any Mythic trait is about %.1f%% a roll (≈%d rolls for a 50%% chance), so single remnants aren't worth a chase.",
        ADV.have("star_remnant"), ADV.have("star_remnant_limited"), ADV.have("trait_reroll_legacy"), tonumber(p.trait_reroll_tokens) or 0,
        table.concat(odds, " · "), mythic * 100, mythic > 0 and math.ceil(math.log(0.5) / math.log(1 - mythic)) or 0)
end

-- ============================================================
--  LOBBY
-- ============================================================
HUB.last = {}
-- evolve a ready goal (only when you press the Path button twice): checks it really happened
function HUB.evolve(g, why)
    local s = C.session()
    local before = s.collection:get_unit_by_uuid(g.uuid)
    if not before then return false, "unit not found" end
    local had = 0
    for _, u in pairs(s.profile_data.collection.owned_units) do if u.unit_id == g.to then had = had + 1 end end
    local ok, r = SF.request("evolve", "evolve_unit", g.uuid)
    task.wait(2)
    local after = s.collection:get_unit_by_uuid(g.uuid)
    local now = 0
    for _, u in pairs(s.profile_data.collection.owned_units) do if u.unit_id == g.to then now = now + 1 end end
    if now > had then
        local used = {}
        for _, it in ipairs(g.items or {}) do table.insert(used, string.format("%s ×%d", (C.Items[it.id] or {}).name or it.id, it.amount)) end
        for _, e in ipairs(g.eats or {}) do table.insert(used, string.format("%d× %s", e.amount, UNIT.name(e.id))) end
        local text = string.format("%s → %s (score %s → %s)", UNIT.name(g.from), UNIT.name(g.to), U.fmt(g.scoreFrom or 0), U.fmt(g.scoreTo or 0))
        SPEND.add("evolved " .. text, 1, "evolution", (why or "your choice (Path tab)") .. (#used > 0 and (" · used " .. table.concat(used, ", ")) or ""))
        SF.log(1, "EVOLVE", text .. " — " .. (why or "your choice") .. (#used > 0 and (" · used " .. table.concat(used, ", ")) or ""))
        MODE._sigAt = nil
        pcall(ADV.refresh)
        return true, UNIT.name(g.to) .. " is yours!"
    end
    SF.log(1, "EVOLVE", "evolve refused for " .. UNIT.name(g.from) .. " (" .. tostring(r) .. "), unit now " .. tostring(after and after.unit_id))
    return false, "the game said no (" .. tostring(r) .. ")"
end
-- smart evolve (lobby): evolves a ready unit when
--   · the game's own requirements are met and it's your best copy of that unit,
--   · the evolved form scores higher at full upgrade (the game's formulas: level, trait, rolls carry over),
--   · every item it uses still leaves enough for the bigger evolution goals that need the same item,
--   · the other copies it would use up are all spare: not on your team, no trait, weaker than the one evolving
--     (the game picks which unlocked copies go — lock a copy in the game to keep it out)
-- biggest gain first, at most 2 a lobby visit; each one goes in the log and the Spending tab
HUB.evoBlocked = {}
function HUB.smartEvolve()
    if not CFG.smartEvolve then return SF.status("Evolve", "smart evolve is off (Path tab)") end
    local s = C.session()
    if not s then return end
    local goals = {}
    for _, g in ipairs(B.goals or {}) do table.insert(goals, g) end
    table.sort(goals, function(a, b) return (a.gain or 0) > (b.gain or 0) end)
    local onTeam = {}
    for _, e in ipairs(UNIT.equipped()) do onTeam[e.uuid] = true end
    local reserved, done, notes = {}, 0, {}
    for _, g in ipairs(goals) do
        local why, evolved
        if g.ready and done < 2 and (HUB.evoBlocked[g.uuid] or 0) < os.time() then
            for _, it in ipairs(g.items or {}) do
                if ADV.have(it.id) - it.amount < (reserved[it.id] or 0) then
                    why = string.format("keeps %s for a bigger evolution", (C.Items[it.id] or {}).name or it.id)
                    break
                end
            end
            local mine = s.collection:get_unit_by_uuid(g.uuid)
            local okM, myScore = pcall(UNIT.score, mine)
            for _, e in ipairs(g.eats or {}) do
                if why then break end
                for _, o in ipairs(ADV.copies(e.id, e.shiny, g.uuid)) do
                    local u = s.collection:get_unit_by_uuid(o.uuid) or o
                    local okS, sc = pcall(UNIT.score, u)
                    if onTeam[o.uuid] or UNIT.trait(u) or (okM and okS and sc >= myScore) then
                        why = string.format("would use up a %s you may want (on your team, a trait, or stronger) — lock it in the game to keep it", UNIT.name(e.id))
                        break
                    end
                end
            end
            if not why then
                local ok, msg = HUB.evolve(g, "smart evolve: ready, stronger at full upgrade, uses only spare items" .. (#(g.eats or {}) > 0 and " and spare copies" or ""))
                if ok then
                    done, evolved = done + 1, true
                    table.insert(notes, "evolved " .. UNIT.name(g.from) .. " → " .. UNIT.name(g.to))
                else
                    HUB.evoBlocked[g.uuid] = os.time() + 3600
                    why = msg
                end
            end
            if why then table.insert(notes, UNIT.name(g.from) .. ": " .. why) end
        end
        -- a goal still waiting keeps its items for itself (one that just evolved already used them up)
        if not evolved then
            for _, it in ipairs(g.items or {}) do reserved[it.id] = (reserved[it.id] or 0) + it.amount end
        end
    end
    SF.status("Evolve", #notes > 0 and table.concat(notes, " · ") or "nothing ready to evolve")
end
function HUB.every(name, sec)
    local t = U.now()
    if HUB.last[name] and t - HUB.last[name] < sec then return false end
    HUB.last[name] = t
    return true
end
-- lobby-only info the match also needs (challenge rotation, daily challenge, event) is cached in the brain
function HUB.refreshLive()
    local live = B.live
    local ok, n = SF.request("live_n", "get_normal_challenge")
    if ok and type(n) == "table" and n.current_uuid then
        local prevLost = (live.normal and live.normal.uuid == n.current_uuid) and live.normal.lost or 0
        local prevDoneN = (live.normal and live.normal.uuid == n.current_uuid) and live.normal.doneUuid or nil
        local remaining = C.GS.CHALLENGE_DURATION or 1800
        -- the rotation is every 30 min on the clock (the pads show the time left)
        local ends = (math.floor(os.time() / remaining) + 1) * remaining
        live.normal = { uuid = n.current_uuid, level = n.current_level_id, challenge = n.current_challenge,
            value = MODE.rewardValue(n.current_reward), expires = ends, lost = prevLost, doneUuid = prevDoneN }
    end
    local ok2, d = SF.request("live_d", "get_daily_challenge")
    if ok2 and type(d) == "table" and d.current_uuid then
        local mod = { weak = {}, strong = {} }
        for _, t in pairs(d.weak_against or {}) do mod.weak[t] = 1.5 end
        for _, t in pairs(d.strong_against or {}) do mod.strong[t] = true end
        local prevLost = (live.daily and live.daily.uuid == d.current_uuid) and live.daily.lost or 0
        local prevDone = (live.daily and live.daily.uuid == d.current_uuid) and live.daily.doneUuid or nil
        local dld = type(d.current_level) == "table" and SIM.slim(d.current_level) or nil
        if dld then dld._challenge = d.current_challenge end
        live.daily = { uuid = d.current_uuid, value = MODE.rewardValue(d.current_reward), challenge = d.current_challenge, mod = mod, lost = prevLost, doneUuid = prevDone, ld = dld }
    end
    local ok3, e = SF.request("live_e", "get_event_challenges")
    if ok3 and type(e) == "table" then
        for id, v in pairs(e) do
            local lv = type(v) == "table" and v.current_level_data
            if lv then live.event = { level = lv.id or id, name = lv.name, pad = C.GS.ACTIVE_EVENT_CHALLENGES and C.GS.ACTIVE_EVENT_CHALLENGES[id] } end
        end
    end
    live.at = os.time()
    SF.saveSoon()
end

-- free rewards: daily login, finished quests, battle pass, first-clear milestones
function HUB.rewards()
    if not CFG.rewards then return SF.status("Rewards", "off") end
    local s = C.session()
    local p = C.prof()
    if not (s and p) then return end
    local got = {}
    if (os.time() - (tonumber(p.last_daily_reward_claimed_time) or 0)) >= (C.GS.DAILY_REWARD_WAIT or 82800) then
        local ok, r = SF.request("daily", "claim_daily_reward")
        if ok and r then table.insert(got, "daily login") end
    end
    for uuid, q in pairs(s.quest_handler.quest_profile_data.quests or {}) do
        local okC, done = pcall(C.QCC.is_quest_complete, s, q)
        if okC and done and not B.claims[uuid] then
            local ok, r = SF.request("quest", "redeem_quest", uuid)
            if ok and r then
                B.claims[uuid] = os.time()
                table.insert(got, "quest " .. tostring(q.quest_info and (q.quest_info.name or q.quest_info.id) or ""))
            else
                B.claims[uuid] = os.time() - 259200 + 3600 -- not claimable right now: try again in an hour
            end
            task.wait(0.3)
        end
    end
    if HUB.every("bp", 600) then SF.request("bp", "claim_battlepass_rewards") end
    -- first-clear milestones (Levels[id].clear_rewards[diff] = {clears, _id})
    if HUB.every("clr", 300) then
        for id, d in pairs(p.level_data.completed_story_levels or {}) do
            local lv = C.Levels[id]
            if lv and lv.clear_rewards and d.difficulty_completed_data then
                for diff, list in pairs(lv.clear_rewards) do
                    local n = d.difficulty_completed_data[diff] and d.difficulty_completed_data[diff].times_completed or 0
                    for _, rw in pairs(list) do
                        local claimed = p.clear_rewards[id] and p.clear_rewards[id][diff] and p.clear_rewards[id][diff][rw._id]
                        local ck = id .. diff .. tostring(rw._id)
                        if not claimed and n >= (rw.clears or 1e9) and not B.claims[ck] then
                            local ok, r = SF.request("clr", "claim_first_clear_rewards", id, diff, rw._id)
                            B.claims[ck] = os.time()
                            if ok and r then table.insert(got, "milestone " .. MODE.levelName(id)) end
                        end
                    end
                end
            end
        end
    end
    -- forget claim marks older than 3 days (quest uuids are not reused)
    for k, t in pairs(B.claims) do if os.time() - t > 259200 then B.claims[k] = nil end end
    if #got > 0 then SF.log(1, "REWARD", "claimed " .. table.concat(got, ", ")) end
    SF.status("Rewards", #got > 0 and ("claimed " .. table.concat(got, ", ")) or "nothing waiting")
end

-- spend: Star Fruits from the daily gold shop with spare gold (floor, item cap, stock)
function HUB.goldShop()
    if not CFG.goldShop then return SF.status("Gold Shop", "off") end
    local p = C.prof()
    local s = C.session()
    if not (p and s) then return end
    local ok, shop = SF.request("gshop", "request_current_gold_shop")
    if not (ok and type(shop) == "table") then return SF.status("Gold Shop", "shop not answering") end
    local bought = 0
    -- what's left of an item = its stock minus what you already bought this rotation (like the shop window shows)
    local done = (type(p.gold_shop_data) == "table" and type(p.gold_shop_data.bought_items) == "table") and p.gold_shop_data.bought_items or {}
    local function left(key, it)
        if it.stock == "inf" then return math.huge end
        return math.max(0, (tonumber(it.stock) or 0) - (tonumber(done[key]) or 0))
    end
    for key, it in pairs(shop) do
        if type(it) == "table" and tostring(it.id or key):find("^StarFruit") and left(key, it) > 0 then
            local cap = C.GS.ITEM_CAPS and C.GS.ITEM_CAPS[it.id] or 1e9
            local have = 0
            pcall(function() have = s.inventory:get_number_of_owned_item(it.id) end)
            local cost = tonumber(it.gold_cost) or 1e12
            local stock = left(key, it)
            while stock > 0 and have < cap and (tonumber(p.gold_amount) or 0) - cost >= CFG.goldFloor and bought < 10 do
                local before = tonumber(p.gold_amount) or 0
                local okB, r = SF.request("gbuy", "buy_gold_shop_item", key, "1")
                local t1 = U.now()
                while U.now() - t1 < 3 and (tonumber(p.gold_amount) or 0) >= before do task.wait(0.2) end
                if not okB or (tonumber(p.gold_amount) or 0) >= before then
                    SF.log(1, "SHOP", "gold shop refused " .. tostring(key) .. " (" .. tostring(r) .. ")")
                    SF.backoff("gbuy", 600)
                    break
                end
                bought = bought + 1
                stock = stock - 1
                have = have + 1
                SPEND.add((C.Items[it.id] and C.Items[it.id].name or it.id), cost, "gold", string.format("evolve material, %d/%d held · gold floor %s", have, cap, U.fmt(CFG.goldFloor)))
            end
        end
    end
    SF.status("Gold Shop", bought > 0 and ("bought " .. bought .. " Star Fruit(s)") or string.format("nothing to buy (gold %s, floor %s)", U.fmt(p.gold_amount), U.fmt(CFG.goldFloor)))
end

-- spend: summons — only while the banner can give a unit you don't have (April) or one that beats your team (gems)
function HUB.summon()
    local p = C.prof()
    if not p then return end
    local msgs = {}
    local function pull(banner, cur, have, floor, unitCost, why, curName)
        local n = 0
        while n < CFG.summonsPerVisit and have() - unitCost * 10 >= floor do
            local before = have()
            local ok, r = SF.request("summon", "buy_from_banner", banner, "gems10")
            local t1 = U.now()
            while U.now() - t1 < 4 and have() >= before do task.wait(0.25) end
            if not ok or have() >= before then
                SF.log(1, "SUMMON", banner .. " refused (" .. tostring(r) .. ")")
                SF.backoff("summon", 600)
                break
            end
            n = n + 10
            SPEND.add("10 summons on " .. banner, before - have(), curName, why)
        end
        return n
    end
    if CFG.summonApril and C.Banners.April2025 then
        local want = {}
        for _, id in ipairs({ "osaka", "dokuro", "rikka", "chihiro" }) do if not UNIT.owns(id) then table.insert(want, UNIT.name(id)) end end
        local coins = function() return tonumber(p.resources and p.resources.AprilCoins) or 0 end
        if #want == 0 then table.insert(msgs, "April banner: all limited units owned ✓")
        else
            local n = pull("April2025", "AprilCoins", coins, CFG.aprilFloor, 150, "missing " .. table.concat(want, ", "), "AprilCoins")
            table.insert(msgs, string.format("April banner: %s (%d coins)", n > 0 and (n .. " summons") or "saving", coins()))
        end
    end
    if CFG.summonGems then
        -- the gem banner's featured units vs your team at full growth
        local team = UNIT.equipped()
        local weakest = math.huge
        for _, e in ipairs(team) do if not UNIT.isFarm(e.id) then weakest = math.min(weakest, UNIT.score(e.u)) end end
        local ok, setup = SF.request("hatch", "get_hatch_setup_data")
        local better = {}
        if ok and type(setup) == "table" and setup.EventClover and setup.EventClover.rateup_units then
            for _, id in pairs(setup.EventClover.rateup_units) do
                if C.Units[id] and not UNIT.owns(id) then
                    -- a level-1, traitless copy at full upgrade (what a fresh pull would be)
                    local fake = { unit_id = id, uuid = "sim:" .. id, xp = 0, traits = {}, trait_stats = { potency_stat = 1, speed_stat = 1, range_stat = 1 } }
                    local okS, sc = pcall(UNIT.score, fake)
                    if okS and sc > weakest then table.insert(better, UNIT.name(id)) end
                end
            end
        end
        if #better == 0 then table.insert(msgs, "gem banner: nothing that beats your team")
        else
            local gems = function() return tonumber(p.gem_amount) or 0 end
            local n = pull("EventClover", "gems", gems, CFG.gemFloor, 50, "would beat your weakest unit: " .. table.concat(better, ", "), "gems")
            table.insert(msgs, string.format("gem banner: %s", n > 0 and (n .. " summons") or "saving"))
        end
    end
    SF.status("Summon", #msgs > 0 and table.concat(msgs, " · ") or "off (Spending tab)")
end

-- the pads: Story / Raid (owner pads), Challenges, Daily Challenge, Event (shared pads)
function HUB.pad(kind, m)
    local function free(folder)
        for _, p in ipairs(folder:GetChildren()) do
            local o = p:FindFirstChild("Owner")
            local a = p:FindFirstChild("Active")
            if o and o.Value == nil and not (a and a.Value) then return p end
        end
    end
    if kind == "story" then return free(workspace._LOBBIES.Story) end
    if kind == "raid" then return free(workspace._RAID.Raid) end
    if kind == "challenge" then return workspace._CHALLENGES.Challenges:GetChildren()[1] end
    if kind == "daily" then return workspace._CHALLENGES.DailyChallenge:GetChildren()[1] end
    if kind == "event" then
        local name = B.live.event and B.live.event.pad
        return name and workspace._EVENT_CHALLENGES.Lobbies:FindFirstChild(name) or nil
    end
end
function HUB.launch(m)
    local pad = HUB.pad(m.kind, m)
    if not pad then SF.log(1, "MODE", "no free pad for " .. m.label); SF.backoff("launch", 20); return false end
    B.pending = { key = m.key, kind = m.kind, level = m.level, diff = m.diff, label = m.label, at = os.time(), value = m.value }
    SF.log(1, "MODE", string.format("launching %s on %s — %s (≈%.0f gems/min)", m.label, pad.Name, m.why or "", m.score or 0))
    SF.saveNow() -- the teleport kills this script: the match reads what we launched from the brain (and the log is flushed)
    SF.status("Mode", "starting " .. m.label)
    local ok, r = SF.request("join", "request_join_lobby", pad.Name)
    if not (ok and r) then
        SF.log(1, "MODE", "join refused on " .. pad.Name .. " (" .. tostring(r) .. ")")
        B.pending = nil
        SF.backoff("launch", 15)
        return false
    end
    if m.kind == "story" or m.kind == "raid" then
        local okL, rl = SF.request("lock", "request_lock_level", pad.Name, m.level, false, m.diff)
        if not (okL and rl) then
            SF.log(1, "MODE", "lock refused for " .. m.label .. " (" .. tostring(rl) .. ")")
            SF.request("leave", "request_leave_lobby", pad.Name)
            local rec = MODE.rec(m.key)
            rec.restUntil = os.time() + 1800
            B.pending = nil
            SF.backoff("launch", 10)
            return false
        end
    end
    task.wait(0.5)
    SF.request("start", "request_start_game", pad.Name)
    -- teleport within ~40 s, else give the pad back and try something else
    local t0 = U.now()
    while SF.alive and U.now() - t0 < 45 do task.wait(1) end
    if SF.alive then
        SF.log(1, "MODE", "no teleport after 45s for " .. m.label .. " — leaving the pad")
        SF.request("leave", "request_leave_lobby", pad.Name)
        local rec = MODE.rec(m.key)
        rec.restUntil = os.time() + 900
        B.pending = nil
        SF.backoff("launch", 10)
    end
    return false
end
-- a simulation exists for this mode with the team equipped now (or the mode can't be simulated)
function HUB.simFresh(m)
    local sr = B.simRes[m.key]
    return sr and sr.sig == MODE.teamSig() and os.time() - (sr.at or 0) < 6 * 3600 or false
end
-- equip a team (by unit uuid); your own team is saved first and can be put back
function HUB.equipTeam(uuids, why)
    local cur = {}
    for _, e in ipairs(UNIT.equipped()) do cur[e.uuid] = true end
    if not B.savedTeam then
        local l = {}
        for _, e in ipairs(UNIT.equipped()) do table.insert(l, e.uuid) end
        B.savedTeam = l
    end
    local want = {}
    for _, u in ipairs(uuids) do want[u] = true end
    for uuid in pairs(cur) do if not want[uuid] then SF.request("uneq", "unequip_unit", uuid); task.wait(0.35) end end
    for _, uuid in ipairs(uuids) do if not cur[uuid] then SF.request("eq", "equip_unit", uuid); task.wait(0.35) end end
    MODE._sigAt = nil
    SF.log(1, "TEAM", "equipped " .. #uuids .. " units — " .. tostring(why))
    SF.saveSoon()
end
function HUB.restoreTeam()
    if not B.savedTeam then return false end
    local saved = B.savedTeam
    B.savedTeam = nil
    HUB.equipTeam(saved, "your own team back")
    B.savedTeam = nil
    SF.saveSoon()
    return true
end
-- auto team (Settings → Battle): the planner's best team for this mode when it does better, else your own team
function HUB.teamFor(m)
    local plan = B.simTeam[m.key]
    if plan and plan.better and type(plan.uuids) == "table" and #plan.uuids > 0 then
        local same = true
        local cur = {}
        for _, e in ipairs(UNIT.equipped()) do cur[e.uuid] = true end
        for _, u in ipairs(plan.uuids) do if not cur[u] then same = false end end
        if not same then HUB.equipTeam(plan.uuids, "the simulator's best team for " .. m.label) end
    elseif B.savedTeam then
        HUB.restoreTeam()
    end
end
function HUB.run()
    SF.status("Mode", "in the lobby")
    local arrived = U.now()
    while SF.alive do
        if CFG.master then
            if HUB.every("live", 60) then pcall(HUB.refreshLive) end
            if HUB.every("rewards", 45) then local ok, e = pcall(HUB.rewards); if not ok then SF.log(1, "ERROR", "rewards: " .. tostring(e)) end end
            if HUB.every("gold", 600) then local ok, e = pcall(HUB.goldShop); if not ok then SF.log(1, "ERROR", "gold shop: " .. tostring(e)) end end
            if HUB.every("summon", 120) then local ok, e = pcall(HUB.summon); if not ok then SF.log(1, "ERROR", "summon: " .. tostring(e)) end end
            -- the path: raid shop prices, goals and their item values, buying a goal's shop item
            if HUB.every("rshopCache", 1800) then
                local okS, shop = SF.request("rshopList", "request_current_raidshop_shop")
                if okS and type(shop) == "table" then
                    table.clear(B.raidShop)
                    for key, v in pairs(shop) do
                        if type(v) == "table" and v.id and v.item_cost then
                            B.raidShop[key] = { id = v.id, costItem = v.item_cost.item_id, cost = tonumber(v.item_cost.amount) or 0, stock = v.stock }
                        end
                    end
                end
            end
            if HUB.every("lbInfo", 1800) then
                local t = UNIT.equipped()[1]
                if t then
                    local okL, info = SF.request("lbInfo", "request_fusion_information", t.uuid)
                    if okL and type(info) == "table" then B.lb = { requirement = info.requirement, allowed = info.allowed } end
                end
            end
            if HUB.every("goals", 300) then
                local ok, e = pcall(ADV.refresh)
                if not ok then SF.log(1, "ERROR", "goals: " .. tostring(e)) else
                    -- a goal item just bought can make its evolution ready right now
                    local okS, bought = pcall(ADV.buyShopGoals)
                    if okS and bought then pcall(ADV.refresh) end
                    local okE, eE = pcall(HUB.smartEvolve)
                    if not okE then SF.log(1, "ERROR", "smart evolve: " .. tostring(eE)) end
                end
                MODE.lastScored = nil
            end
            local top = MODE.lastScored and MODE.lastScored[1]
            if HUB.every("pick", 5) or not top then
                local okP, t = pcall(MODE.pick)
                if not okP then SF.log(1, "ERROR", "ranking: " .. tostring(t)); t = nil end
                top = t
            end
            -- background planner: best team + evolutions for the most valuable non-farm modes (one per 10 min)
            if CFG.sim and CFG.simTeams and HUB.every("simTeam", 600) then
                task.spawn(function()
                    for _, m in ipairs(MODE.lastScored or {}) do
                        if m.kind == "daily" or m.kind == "challenge" or m.first then
                            local ok, e = pcall(SIM.plan, m, true)
                            if not ok then SF.log(1, "ERROR", "planner: " .. tostring(e)) end
                            break
                        end
                    end
                end)
            end
            -- gate: simulate the mode with your team before spending a run on it
            if CFG.play and CFG.sim and top and not HUB.simFresh(top) and top.kind ~= "event" then
                SF.status("Mode", "simulating " .. top.label .. " with your team…")
                local ok, e = pcall(SIM.plan, top, false)
                if not ok then SF.log(1, "ERROR", "sim: " .. tostring(e)) end
                if not (ok and e) then B.simRes[top.key] = { none = true, sig = MODE.teamSig(), at = os.time() } end
                MODE.lastScored = nil
                top = nil
            end
            if CFG.play and top and U.now() - arrived > 8 and not (SF.req.back.launch and U.now() < SF.req.back.launch) then
                local inLobby = LP:FindFirstChild("AlreadyInLobby")
                if CFG.autoTeam then pcall(HUB.teamFor, top) end
                if not (inLobby and inLobby.Value) then pcall(HUB.launch, top) end
            elseif not CFG.play then
                SF.status("Mode", "Auto Play is off")
            elseif not top then
                SF.status("Mode", "nothing to play (all modes off or resting)")
            end
        else
            SF.status("Mode", "paused")
        end
        task.wait(2)
    end
end

-- ============================================================
--  ECONOMY DECISION (one function for the live match and the simulator: the sim plays like the farm)
-- ============================================================
-- damage gained by the next upgrade of a unit dealing `live` damage/s at `lvl` (one level of lookahead: a weak
-- step before a big one counts half of the next; more range counts too)
function ECON.upgradeGain(live, rows, lvl, cost, upMult, fallback)
    local cur, nxt = rows[lvl], rows[lvl + 1]
    local ratioNow = (cur.cd > 0 and cur.damage / cur.cd or 0)
    local ratioNext = (nxt.cd > 0 and nxt.damage / nxt.cd or 0) * UNIT.aoe(nxt.atk, nxt.range) / math.max(0.3, UNIT.aoe(cur.atk, cur.range))
    local gain = ratioNow > 0 and live * (ratioNext / ratioNow - 1) or (fallback or 0)
    local nn = rows[lvl + 2]
    if nn and lvl + 1 < rows.max and nn.cd > 0 and nxt.cd > 0 and ratioNow > 0 then
        local g2 = live * ((nn.damage / nn.cd) / ratioNow - 1)
        local c2 = cost + nn.cost * upMult
        if g2 / c2 > gain / cost then gain = gain + (g2 / c2 * cost - gain) * 0.5 end
    end
    local rangeGain = (nxt.range or 0) > (cur.range or 0) and (1 + ((nxt.range - cur.range) / math.max(1, cur.range))) or 1
    return math.max(0, gain) * rangeGain
end
-- opts: {cost, gain, farm?, place?, what}; ctx: {money, left, attackers, pressure, piling, clearSec, enemies, future, wantLeft}
-- 1) opening: an attacker first, so the first waves never leak
-- 2) farm while it pays back with waves to spare, the defense holds (enemies die early, nothing piles up,
--    everything alive dies within clearSec) and the yen is still needed
-- 3) otherwise the best damage per yen (save for it unless a nearly-as-good buy is affordable)
-- returns choice, why — or nil, nil, "saving …"
-- damage you could buy with `yen` right now: the attack options best-first (each unit's next step), then
-- 70% of the last ratio for anything beyond (deeper upgrades get dearer)
function ECON.dpsFor(opts, yen)
    if yen <= 0 then return 0 end
    local list = {}
    for _, o in ipairs(opts) do if not o.farm and o.gain > 0 then table.insert(list, o) end end
    table.sort(list, function(a, b) return a.gain / a.cost > b.gain / b.cost end)
    local d, last = 0, 0
    for _, o in ipairs(list) do
        if yen <= 0 then break end
        last = o.gain / o.cost
        local take = math.min(1, yen / o.cost)
        d = d + o.gain * take
        yen = yen - o.cost * take
    end
    return d + math.max(0, yen) * last * 0.7
end
-- can the defense keep up over the coming waves if we spend `cost` on something that adds `addDps` / `addFarm`?
-- A backlog model: each wave adds its HP (formula, calibrated), the team removes damage/s × wave length; what's
-- left over must be killable before the oldest of it walks out of your units' reach (road time × the share of
-- the road they cover). Yen arriving each wave (reward + farm) buys the best damage per yen. Returns ok, the
-- first wave that falls short, the ratio.
function ECON.keepsUp(ctx, opts, cost, addDps, addFarm)
    local waves = ctx.coming
    if not (waves and #waves > 0 and ctx.waveSec) then return true end
    local eff = ctx.eff or 1
    local money = ctx.money - cost
    local dps = (ctx.teamDps or 0) + (addDps or 0) * eff + ECON.dpsFor(opts, math.max(0, money)) * eff
    local farm = (ctx.farmNow or 0) + (addFarm or 0)
    local road = (ctx.roadSec or 130) * U.clamp(ctx.cover or 0.6, 0.1, 1)
    local backlog = ctx.hpAlive or 0
    for k, w in ipairs(waves) do
        backlog = math.max(0, backlog + w.hp - dps * ctx.waveSec)
        local canClear = dps * road
        if backlog > canClear then return false, k, canClear / math.max(1, backlog) end
        if k < #waves then dps = dps + ECON.dpsFor(opts, (w.reward or 0) + farm) * eff * (0.85 ^ k) end
    end
    return true
end
function ECON.decide(opts, ctx)
    -- the backlog forecast (ECON.keepsUp) is the judge; these quick checks only catch what it can't see yet.
    -- cover: the share of the road your units reach (enemies past it can't be hit any more)
    -- "slow" = what's alive takes longer to kill than 70% of the walk through the covered road (or the Safe Kill Time)
    local cover = U.clamp(ctx.cover or 0.6, 0.1, 1)
    local slowLimit = math.max(CFG.clearSec, 0.7 * (ctx.roadSec or 50) * cover)
    local slow = (ctx.clearSec or 0) > slowLimit
    -- a crowd only counts as piling up when the team couldn't kill it in time either
    ctx.piling = ctx.piling and slow
    -- safe / danger: how far enemies get, against the end of your coverage (or the settings, if those are lower)
    local safe = ctx.attackers > 0 and ctx.pressure < math.min(CFG.safeReach, cover * 0.75) and not ctx.piling and not slow
    local danger = ctx.pressure >= math.min(CFG.dangerReach, cover * 0.9) or (ctx.piling and ctx.enemies >= 18)
    local bestFarm, bestAtk
    for _, o in ipairs(opts) do
        if o.farm then
            if CFG.farmUnits and o.gain > 0 then
                o.payback = o.cost / o.gain
                if ctx.left - 1 >= o.payback + CFG.farmSpare and (not bestFarm or o.payback < bestFarm.payback) then bestFarm = o end
            end
        else
            o.ratio = o.gain / math.max(1, o.cost)
            if not bestAtk or o.ratio > bestAtk.ratio then bestAtk = o end
        end
    end
    -- a leak: an enemy walked past every unit's range and nothing can hit it before the base — only a new unit
    -- placed in its way can (an upgrade of a unit it already passed can't); the strongest one affordable
    if ctx.leak and ctx.attackers > 0 then
        local pick
        for _, o in ipairs(opts) do
            if o.place and not o.farm and o.cost <= ctx.money and not (o.e and UNIT.allyBuff(o.e.id)) and (not pick or o.gain > pick.gain) then pick = o end
        end
        if pick then return pick, string.format("an enemy got past all your units (%d%% of the road): a unit in its way", math.floor(ctx.leak * 100)) end
    end
    local needYen = ctx.future < ctx.wantLeft * 1.1
    -- the forecast: would the defense keep up over the next waves if the farm buy happened now?
    local farmOk, shortK, shortR = true, nil, nil
    if bestFarm then farmOk, shortK, shortR = ECON.keepsUp(ctx, opts, bestFarm.cost, 0, bestFarm.gain) end
    -- and even spending everything on damage now — if not, nothing gets saved for later
    local behind = ctx.coming and not ECON.keepsUp(ctx, opts, 0, 0, 0)
    if behind and ctx.attackers > 0 then danger = true end
    -- the time value of damage: over a horizon, buying B now and A later vs waiting for A — whichever deals more
    -- damage (yen arrives at the measured income rate). Horizon: 2 waves near the base, 4 at the start, else 6
    local rate = math.max(1, ctx.incomeRate or 20)
    local wsec = ctx.waveSec or 20
    local function planDmg(first, second, H)
        local t1 = math.max(0, (first.cost - ctx.money) / rate)
        local d = first.gain * math.max(0, H - t1)
        if second then
            local left = math.max(0, ctx.money - first.cost) -- yen left right after the first buy
            local t2 = t1 + math.max(0, (second.cost - left) / rate)
            d = d + second.gain * math.max(0, H - t2)
        end
        return d
    end
    local choice, why
    if ctx.attackers == 0 and bestAtk then
        -- opening: the attacker that deals the most damage over the next 4 waves, counting the wait for its price
        local H = 4 * wsec
        local pick, pv
        for _, o in ipairs(opts) do
            if o.place and not o.farm then
                local v = planDmg(o, nil, H)
                if not pv or v > pv then pick, pv = o, v end
            end
        end
        choice, why = pick or bestAtk, "opening: the unit that does the most damage over the first waves"
    elseif bestFarm and safe and needYen and not danger and farmOk then
        choice = bestFarm
        why = string.format("farm pays back in %.1f waves (%d left) and the defense still keeps up with the next %d waves", bestFarm.payback, ctx.left, ctx.coming and #ctx.coming or 0)
    elseif bestAtk then
        choice = bestAtk
        if behind then why = string.format("the next waves bring more HP than your units can kill: damage now")
        elseif danger then why = string.format("enemies reach %d%% of the road (your units cover %d%%): damage now", math.floor(ctx.pressure * 100), math.floor(cover * 100))
        elseif bestFarm and not farmOk then why = string.format("defense first: after that farm buy, wave +%d would only be %d%% covered", shortK or 1, math.floor((shortR or 0) * 100))
        elseif bestFarm and slow then why = string.format("defense first: killing what's alive takes %ds (farm only under %ds)", math.min(999, math.floor(ctx.clearSec)), math.floor(slowLimit))
        elseif bestFarm and ctx.piling then why = string.format("defense first: %d enemies piling up", ctx.enemies)
        elseif bestFarm and not safe then why = "defense first (enemies get too far to farm)"
        elseif bestFarm and not needYen then why = "farm not needed: coming yen already covers every upgrade"
        else why = "most damage per yen" end
    end
    if not choice then return nil end
    if choice.cost > ctx.money then
        local alt
        if not choice.farm then
            local H = (danger and 2 or 6) * wsec
            local altV
            for _, o in ipairs(opts) do
                if not o.farm and o ~= choice and o.cost <= ctx.money then
                    local now = planDmg(o, choice, H)      -- buy it now, the best one after
                    local later = planDmg(choice, o, H)    -- save for the best one, this one after
                    if now > later and (not altV or now > altV) then alt, altV = o, now end
                end
            end
        end
        if not alt then
            return nil, nil, string.format("saving ¥%s for: %s (≈%ds at ¥%d/s) — %s", U.fmt(choice.cost), choice.what or "?",
                math.ceil((choice.cost - ctx.money) / rate), math.floor(rate), why)
        end
        choice, why = alt, why .. " (worth buying while saving)"
    end
    return choice, why
end

-- ============================================================
--  SIMULATOR (the game's own enemy formulas + the farm's own buy rules; earns trust per mode)
-- ============================================================
SIM.DT = 1
SIM.BINS = 20
-- priors until a mode has real runs (walk: share of the road per second at speed 1 — the daily challenge's
-- front enemy took ~135 s to cross; base: HP lost per second per enemy at the base, a guess until measured)
-- eff: share of a unit's listed damage that really lands (overkill, range gaps, targeting) — measured per mode
-- waves: enemies come out spawnGap seconds apart (raid: 1.04 s), the wave's timer is measured per wave (the level's
-- wave_max_time until then; big raid waves run longer: 56 enemies → 89 s), skipDelay: cleared wave → next wave (5.2 s)
-- base: an enemy at the base takes baseRel × its max HP off the base every second (measured 0.1–0.5: a leak loses)
-- skip vote (auto-skip on), whatever is still alive: opens voteBase + votePer × the wave's enemy count seconds into
-- the wave, at most voteAt (raid: half its 60 s timer). Measured: 2 enemies → 5.8 s, 4 → 11 s, 11 → 21 s, 22+ → 30 s
SIM.PRIOR = { waveSec = 20, walk = 0.0075, spawnGap = 1, baseHp = 100, baseRel = 0.3, start = 600, eff = 0.7, waveTimer = 60, skipDelay = 5,
    voteAt = 30, voteBase = 2, votePer = 1.9 }
-- the player's own "Auto-Skip Waves" setting: the game votes the skip as soon as a wave is cleared
function SIM.autoskip()
    local ok, v = pcall(function() return LP._settings.autoskip_waves.Value end)
    if ok and type(v) == "boolean" then return v end
    return true
end
function SIM.cal(key) local c = B.simCal[key]; if not c then c = {}; B.simCal[key] = c end; return c end
-- hit efficiency for a mode: its own measurement, leaning on the average of all measured runs while it has few
-- (one run's reading swings ×3 on the same map with the same team)
function SIM.effFor(cal)
    local sw, sn = 0, 0
    for _, c in pairs(B.simCal) do
        local e, n = tonumber(c.eff), tonumber(c.n) or 0
        if e and n > 0 then sw = sw + e * n; sn = sn + n end
    end
    local g = sn > 0 and sw / sn or SIM.PRIOR.eff
    local e, n = tonumber(cal and cal.eff), tonumber(cal and cal.n) or 0
    if not e then return g end
    return (e * n + g * 3) / (n + 3)
end
-- the level fields the sim needs, kept in the brain so the lobby can plan modes it isn't in
SIM.LD_FIELDS = { "id", "map", "waves", "world", "story_world_rank", "story_level_rank", "_gamemode", "_OVERRIDE_GAMEMODE", "_difficulty",
    "_challenge", "infinite", "_use_max", "_override_infinite_bound_waves", "_override_infinite_boss_interval", "_override_multiplayer_diff_scale",
    "_no_multiplayer_scale", "_raid_multiplayer_scale", "portal_group" }
function SIM.slim(ld)
    local o = {}
    for _, k in ipairs(SIM.LD_FIELDS) do local v = ld[k]; if type(v) ~= "table" and type(v) ~= "function" then o[k] = v end end
    if type(ld._override_waves) == "table" then o._override_waves = { infinite = ld._override_waves.infinite, template = ld._override_waves.template } end
    if type(ld._override_infinite_final_boss_wave) == "table" then
        o._final = { wave = ld._override_infinite_final_boss_wave.wave, cfg = ld._override_infinite_final_boss_wave.final_boss_config_id }
    end
    if type(ld._override_infinite_boss_interval__skip_waves) == "table" then
        o._skip = {}
        for k in pairs(ld._override_infinite_boss_interval__skip_waves) do o._skip[tostring(k)] = true end
    end
    return o
end
local function simCall(f, ...) local ok, v = pcall(f, ...); return ok and tonumber(v) or nil end
-- everything about a mode: enemy HP scale (world × act × players × difficulty × challenge), waves, timing
function SIM.info(ld, key, chId, mod)
    local cal = B.simCal[key] or {}
    local gm = ld._OVERRIDE_GAMEMODE or ld._gamemode or (ld.infinite and "infinite") or "story"
    local daily = ld.id == "__DAILY_CHALLENGE"
    local event = (B.live.event and ld.id == B.live.event.level) and true or false
    local probe = { _is_daily_challenge = daily or nil, _is_event_challenge = event or nil, _use_max = ld._use_max, world = ld.world, id = ld.id,
        _override_multiplayer_diff_scale = ld._override_multiplayer_diff_scale, _no_multiplayer_scale = ld._no_multiplayer_scale,
        portal_group = ld.portal_group, _raid_multiplayer_scale = ld._raid_multiplayer_scale }
    local rank = tonumber(ld.story_world_rank) or #U.list(C.WLO.WORLD_ORDER)
    local gmW = (gm == "infinite") and "challenge" or gm
    local ws = simCall(C.LU.calculate_world_diff_scale, rank, gmW, nil, ld.map, probe) or 1
    local ls = simCall(C.LU.calculate_level_diff_scale, tonumber(ld.story_level_rank) or 6, (gm == "infinite" or gm == "raid") and gm or (gm == "challenge" and "challenge" or "story"), probe) or 1
    local ms = simCall(C.LU.calculate_multiplayer_diff_scale, gm, 1, probe) or 1
    local ow = ld._override_waves
    local wdef = C.Waves[(ow and ow.template) or ld.waves or ld.id]
    local base = wdef
    if wdef and wdef.template and C.Waves[wdef.template] then base = C.Waves[wdef.template] end
    local infinite = (ow and ow.infinite) or ld.infinite or (wdef and wdef.infinite) or false
    local configs = (wdef and wdef.initial_unit_configs) or (base and base.initial_unit_configs) or {}
    local list = U.list((wdef and (wdef.override_waves or wdef.waves)) or (base and base.waves))
    local ch = C.CAR.challenges and C.CAR.challenges[chId or ld._challenge or ""] or nil
    local red, regen = 0, 0
    for _, bf in pairs(ch and ch.enemy_buffs or {}) do
        if type(bf) == "table" and bf.name == "damage_reduction" then red = red + (tonumber(bf.params and bf.params.reduction) or 0) end
        if type(bf) == "table" and bf.name == "healing" then regen = regen + (tonumber(bf.params and bf.params.percent) or 0) end
    end
    local diff = (not infinite) and (C.GS.DIFFICULTY_HEALTH_SCALES and C.GS.DIFFICULTY_HEALTH_SCALES[ld._difficulty or "Normal"]) or 1
    local hpRaw = ws * ls * ms * diff * (ch and tonumber(ch.enemy_health_scale) or 1)
    -- the world's money scale: kill bounties AND the wave's listed yen are both paid × this (measured ×2.61 in a raid)
    local res = simCall(C.LU.calculate_world_resource_scale, rank, gmW) or 2.6
    local maxT = (wdef and tonumber(wdef.wave_max_time)) or (base and tonumber(base.wave_max_time)) or SIM.PRIOR.waveTimer
    local info = {
        key = key, ld = ld, map = ld.map, infinite = infinite and true or false, list = list, configs = configs, gm = gm,
        total = tonumber(ld._override_infinite_bound_waves) or ((not infinite and #list > 0) and #list) or 30,
        hpRaw = hpRaw, hpScale = hpRaw * (tonumber(cal.hpCal) or 1),
        speedScale = ch and tonumber(ch.enemy_speed_scale) or 1, costScale = ch and tonumber(ch.player_cost_scale) or 1,
        rangeScale = ch and tonumber(ch.player_range_scale) or 1, red = math.min(0.75, red), regen = regen,
        bounty = res * (tonumber(cal.bountyCal) or 1), payBase = res, pay = res * (tonumber(cal.yenCal) or 1),
        waveSec = tonumber(cal.waveSec) or SIM.PRIOR.waveSec, walk = tonumber(cal.walk) or SIM.PRIOR.walk,
        waveTimer = maxT, skipDelay = tonumber(cal.skipDelay) or SIM.PRIOR.skipDelay, autoskip = SIM.autoskip(),
        voteAt = tonumber(cal.voteAt) or maxT / 2, votePer = tonumber(cal.votePer) or SIM.PRIOR.votePer, eff = SIM.effFor(cal),
        spawnGap = tonumber(cal.spawnGap) or SIM.PRIOR.spawnGap,
        baseHp = tonumber(cal.baseHp) or (wdef and tonumber(wdef.base_health)) or (base and tonumber(base.base_health)) or SIM.PRIOR.baseHp,
        baseRel = tonumber(cal.baseRel) or SIM.PRIOR.baseRel, timerAt = type(cal.timerAt) == "table" and cal.timerAt or {},
        start = tonumber(cal.start) or (wdef and tonumber(wdef.initial_resource)) or (base and tonumber(base.initial_resource)) or SIM.PRIOR.start,
        mod = mod, cal = cal,
        bossEvery = tonumber(ld._override_infinite_boss_interval) or 10, final = ld._final, skip = ld._skip or {},
    }
    info.cfgById = {}
    for k, cfg in pairs(configs) do if type(cfg) == "table" and cfg.unit_id then info.cfgById[cfg.unit_id] = k end end
    return info
end
-- the yen a wave pays when it ends: its listed wave_reward × the world's money scale (the farm units pay on top)
function SIM.waveYen(info, w, scale)
    local raw
    if info.infinite then raw = (C.LU.Infinite and C.LU.Infinite.initial_wave_template and C.LU.Infinite.initial_wave_template.wave_reward) or 1000
    else raw = info.list[w] and tonumber(info.list[w].wave_reward) or 0 end
    return raw * (scale or info.pay or 1)
end
function SIM.waveScale(info, w, waveDef)
    if info.infinite then return simCall(C.LU.Infinite.infinite_diff_scale, w, info.ld.id) or 1 end
    return waveDef and tonumber(waveDef.wave_diff_scale) or 1
end
function SIM.baseStats(info, cfgKey)
    local cfg = info.configs[cfgKey]
    if type(cfg) ~= "table" then return nil end
    local os1 = cfg.override_stats and (cfg.override_stats[1] or cfg.override_stats["1"]) or {}
    return tonumber(os1.health) or 20, tonumber(os1.speed) or 1, tonumber(os1.resource_reward) or 30
end
function SIM.enemy(info, cfgKey, w, waveDef)
    local hp, sp, bounty = SIM.baseStats(info, cfgKey)
    if not hp then return nil end
    hp = hp * info.hpScale * SIM.waveScale(info, w, waveDef)
    return { hp = hp, max = hp, speed = sp * info.speedScale, bounty = bounty * info.bounty, boss = tostring(cfgKey):find("boss") ~= nil, p = 0 }
end
-- the enemies of wave w: the level's own list, or the infinite curves (count, mix by spawn tier, a boss every N waves)
function SIM.wave(info, w, raw)
    local out = {}
    if not info.infinite then
        local wd = info.list[w]
        if not wd then return out, 0 end
        for _, g in ipairs(U.list(wd.wave)) do
            for _ = 1, tonumber(g.amount) or 1 do
                local e = SIM.enemy(info, g.unit, w, wd)
                if e then table.insert(out, e) end
            end
        end
    else
        local n = simCall(C.LU.Infinite.infinite_amt_scale, w, info.ld) or 10
        local weights, tot = {}, 0
        for k, cfg in pairs(info.configs) do
            if type(cfg) == "table" and cfg.spawn_tier_normal then
                local c = simCall(C.LU.Infinite.infinite_get_normal_unit_chance, cfg, w) or 0
                if c > 0 then table.insert(weights, { k = k, c = c }); tot = tot + c end
            end
        end
        table.sort(weights, function(a, b) return a.k < b.k end)
        local want, made = math.floor(n + 0.5), 0
        for i, wt in ipairs(weights) do
            local cnt = (i == #weights) and math.max(0, want - made) or math.floor(want * wt.c / tot + 0.5)
            for _ = 1, cnt do local e = SIM.enemy(info, wt.k, w); if e then table.insert(out, e) end end
            made = made + cnt
        end
        if w % info.bossEvery == 0 and not info.skip[tostring(w)] then
            local tier = math.max(1, math.min(6, math.floor(w / info.bossEvery)))
            for k, cfg in pairs(info.configs) do
                if type(cfg) == "table" and tonumber(cfg.spawn_tier_boss) == tier then
                    local e = SIM.enemy(info, k, w); if e then e.boss = true; table.insert(out, e) end
                    break
                end
            end
        end
        if info.final and tonumber(info.final.wave) == w and info.final.cfg then
            local e = SIM.enemy(info, info.final.cfg, w); if e then e.boss = true; table.insert(out, e) end
        end
    end
    -- measured enemies-per-wave correction (real count / formula count), applied by copying enemies
    local cc = tonumber(info.cal and info.cal.countCal)
    if cc and not raw and math.abs(cc - 1) > 0.05 and #out > 0 then
        local want = math.max(1, math.floor(#out * cc + 0.5))
        local n0 = #out
        if want > n0 then
            for i = 1, want - n0 do local src = out[((i - 1) % n0) + 1]; table.insert(out, table.clone(src)) end
        else
            for _ = 1, n0 - want do table.remove(out) end
        end
    end
    return out, SIM.waveYen(info, w)
end
-- which part of the road the best spot covers at a range (measured per map; a generic guess until then)
SIM._masks = {}
function SIM.mask(map, range)
    local rb = math.max(5, math.min(60, math.floor((range or 10) / 5 + 0.5) * 5))
    local key = tostring(map) .. ":" .. rb
    if SIM._masks[key] then return SIM._masks[key] end
    local m = B.maps[map]
    local s = m and m.bins and m.bins[tostring(rb)]
    local mask = {}
    if type(s) == "string" and #s == SIM.BINS then
        for i = 1, SIM.BINS do mask[i] = s:sub(i, i) == "1" end
    else
        local f = math.min(0.7, rb / 70)
        for i = 1, SIM.BINS do local p = (i - 0.5) / SIM.BINS; mask[i] = p >= 0.1 and p <= 0.1 + f end
    end
    SIM._masks[key] = mask
    return mask
end
function SIM.teamFrom(units, map)
    local team = {}
    local hillOk = not (B.maps[map] and B.maps[map].hill == false)
    for _, u in ipairs(units) do
        local d = C.Units[u.unit_id]
        local rows = d and UNIT.rows(u.unit_id)
        if rows then
            table.insert(team, { u = u, id = u.unit_id, data = d, rows = rows, cap = UNIT.cap(u), farm = UNIT.isFarm(u.unit_id),
                placeable = (not d.hill_unit) or hillOk })
        end
    end
    return team
end
function SIM.sig(units)
    local ids = {}
    for _, u in ipairs(units) do table.insert(ids, tostring(u.unit_id)) end
    table.sort(ids)
    return table.concat(ids, ",")
end
-- one simulated run: a wave ends on its timer or (auto-skip) once cleared, enemies walk the road, each unit hits
-- the furthest enemy on the part of the road it covers (area attacks spill onto the next ones), yen from waves
-- (× the world's money scale), kills and farm units, buys made by ECON.decide like the live farm.
-- Returns {won, wave, t, aliveAt, dpsAt, spentAt, money}
function SIM.run(info, team, opt)
    opt = opt or {}
    local hpMul = opt.hpMul or 1
    local dt = SIM.DT
    local money, t, wave, nextWave = info.start, 0, 0, 3
    local queue, alive, copies, hist, aliveAt, maxProg, incomeLog = {}, {}, {}, {}, {}, {}, {}
    local dpsAt, spentAt = {}, {}
    local baseHp = info.baseHp
    local rewards = {}
    for i = 1, info.total do rewards[i] = SIM.waveYen(info, i) end
    local paid = true -- the current wave already paid (wave 0 pays nothing)
    local function unitDps(e, lvl) return UNIT.dps(e.u, lvl, info.mod) * (1 - info.red) end
    local eff = info.eff or SIM.PRIOR.eff
    local waveHp = {}
    local function hpOf(w)
        if w > info.total then return nil end
        if not waveHp[w] then
            local h = 0
            for _, e in ipairs((SIM.wave(info, w))) do h = h + e.hp end
            waveHp[w] = h * hpMul
        end
        return waveHp[w]
    end
    local function refresh(c)
        c.dps = c.e.farm and 0 or unitDps(c.e, c.lvl)
        c.mask = SIM.mask(info.map, UNIT.range(c.e.u, c.lvl) * info.rangeScale)
        local r = c.e.rows[math.min(c.lvl, c.e.rows.max)]
        c.aoe = UNIT.aoe(r.atk, r.range)
        local _, base = UNIT.types(c.e.id)
        c.base = base
        c.buff = UNIT.allyBuff(c.e.id)
        c.fx = c.e.farm and 0 or UNIT.teamEffect(r.atk, r.range, r.cd)
    end
    -- the team's buffs (by damage type) and its crowd control / debuffs, from what's on the field
    local typeMult, teamMult, cover = {}, 1, nil
    local function teamFx()
        table.clear(typeMult)
        local fx, last = 0, 0
        for _, c in ipairs(copies) do
            if c.buff then
                for k, rate in pairs(c.buff.types) do typeMult[k] = math.max(typeMult[k] or 0, rate * c.buff.uptime) end
            end
            fx = fx + (c.fx or 0)
            -- the furthest part of the road any attacker reaches
            if c.dps > 0 then for i = SIM.BINS, last + 1, -1 do if c.mask[i] then last = i; break end end end
        end
        teamMult = 1 + math.min(0.6, fx)
        cover = last > 0 and last / SIM.BINS or nil
    end
    local function realDps(c) return c.dps * teamMult * (1 + (typeMult[c.base] or 0)) end
    local function buffGain(e)
        local b = UNIT.allyBuff(e.id)
        if not b then return 0 end
        for _, c in ipairs(copies) do if c.buff and c.buff.attack == b.attack then return 0 end end
        local g = 0
        for _, c in ipairs(copies) do if b.types[c.base] then g = g + c.dps * b.types[c.base] * b.uptime end end
        return g
    end
    -- a wave pays its yen and the farm units when it ends: cleared (auto-skip → the next wave a few seconds
    -- later) or out of time
    local function pay()
        if paid then return end
        paid = true
        local got = rewards[wave] or 0
        for _, c in ipairs(copies) do if c.e.farm then got = got + UNIT.farm(c.e.u, c.lvl) end end
        money = money + got
        table.insert(incomeLog, { t = t, y = got })
    end
    local steps, voteT = 0, math.huge
    while t < 3600 do
        -- the wave ends early: cleared, or (auto-skip) the skip vote passes
        if not paid and wave > 0 and ((#queue == 0 and #alive == 0) or (info.autoskip and t >= voteT)) then
            pay()
            nextWave = math.min(nextWave, t + info.skipDelay)
        end
        if wave < info.total and t >= nextWave then
            pay()
            wave = wave + 1
            local a = 0
            for _, e in ipairs(alive) do a = a + e.hp end
            aliveAt[wave] = a
            local d = 0
            for _, c in ipairs(copies) do d = d + realDps(c) end
            dpsAt[wave] = d
            local list = SIM.wave(info, wave)
            -- enemies come out one after another; the wave's timer runs its spawning time + the level's wave time
            for i, e in ipairs(list) do
                e.hp = e.hp * hpMul; e.max = e.hp
                e.at = t + (i - 1) * info.spawnGap
                table.insert(queue, e)
            end
            paid = false
            nextWave = t + math.max(tonumber(info.timerAt[tostring(wave)]) or info.waveTimer, #list * info.spawnGap + 5)
            voteT = t + math.min(info.voteAt, SIM.PRIOR.voteBase + info.votePer * #list)
        end
        for i = #queue, 1, -1 do if queue[i].at <= t then table.insert(alive, table.remove(queue, i)) end end
        local front = 0
        for _, e in ipairs(alive) do
            if e.p < 1 then e.p = math.min(1, e.p + info.walk * e.speed * dt) else baseHp = baseHp - info.baseRel * e.max * dt end
            if info.regen > 0 then e.hp = math.min(e.max, e.hp + e.max * info.regen * dt) end
            if e.p > front then front = e.p end
        end
        maxProg[wave] = math.max(maxProg[wave] or 0, front)
        table.sort(alive, function(a, b) return a.p > b.p end)
        for _, c in ipairs(copies) do
            if c.dps > 0 then
                local d = realDps(c)
                local one = d * eff * dt / c.aoe
                local spill = d * eff * dt - one
                local hit = 0
                for _, e in ipairs(alive) do
                    if e.hp > 0 and c.mask[math.min(SIM.BINS, math.floor(e.p * SIM.BINS) + 1)] then
                        if hit == 0 then e.hp = e.hp - one
                        else local d = math.min(one, spill); e.hp = e.hp - d; spill = spill - d end
                        hit = hit + 1
                        if hit > math.ceil(c.aoe) or (hit > 1 and spill <= 0) then break end
                    end
                end
            end
        end
        for i = #alive, 1, -1 do
            local e = alive[i]
            if e.hp <= 0 then money = money + e.bounty; table.insert(incomeLog, { t = t, y = e.bounty }); table.remove(alive, i) end
        end
        while incomeLog[1] and t - incomeLog[1].t > 30 do table.remove(incomeLog, 1) end
        local inc = 0
        for _, x in ipairs(incomeLog) do inc = inc + x.y end
        local incomeRate = t >= 8 and inc / math.min(30, t) or ((rewards[wave + 1] or rewards[wave] or 500) / info.waveSec)
        if baseHp <= 0 then return { won = false, wave = wave, t = t, aliveAt = aliveAt, dpsAt = dpsAt, spentAt = spentAt, money = money } end
        if wave >= info.total and #queue == 0 and #alive == 0 then return { won = true, wave = wave, t = t, aliveAt = aliveAt, dpsAt = dpsAt, spentAt = spentAt, money = money } end
        -- the farm's own buy rules, up to 3 buys a second (the live loop runs every 0.3 s)
        local hpAll, dpsAll = 0, 0
        for _, e in ipairs(alive) do hpAll = hpAll + e.hp end
        for _, c in ipairs(copies) do dpsAll = dpsAll + realDps(c) end
        table.insert(hist, #alive)
        local old = hist[#hist - math.floor(12 / dt)]
        local piling = (#alive >= 8 and old and #alive > old + 1) or #alive >= 18
        local pressure = math.max(maxProg[wave] or 0, maxProg[wave - 1] or 0)
        for _ = 1, 3 do
            local opts, wantLeft, farmNow, kinds = {}, 0, 0, 0
            for _, e in ipairs(team) do
                local mine = {}
                for _, c in ipairs(copies) do if c.e == e then table.insert(mine, c) end end
                if not e.farm and #mine > 0 then kinds = kinds + 1 end
                for _, c in ipairs(mine) do
                    if e.farm then farmNow = farmNow + UNIT.farm(e.u, c.lvl) end
                    local nxt = e.rows[c.lvl + 1]
                    if nxt and c.lvl < e.rows.max then
                        local cost = nxt.cost * info.costScale
                        if e.farm then
                            table.insert(opts, { farm = true, cost = cost, gain = UNIT.farm(e.u, c.lvl + 1) - UNIT.farm(e.u, c.lvl), c = c })
                        else
                            table.insert(opts, { cost = cost, gain = ECON.upgradeGain(c.dps, e.rows, c.lvl, cost, info.costScale, unitDps(e, c.lvl + 1)), c = c })
                            for l = c.lvl + 1, e.rows.max do wantLeft = wantLeft + e.rows[l].cost * info.costScale end
                        end
                    end
                end
                if #mine < e.cap and e.placeable then
                    local cost = (e.data.cost or 0) * info.costScale
                    if e.farm then table.insert(opts, { farm = true, place = true, cost = cost, gain = UNIT.farm(e.u, 0), e = e })
                    else
                        local bonus = (#mine == 0 and 2.5 or 1) * (kinds < 3 and 1.3 or 1)
                        table.insert(opts, { place = true, cost = cost, gain = unitDps(e, 0) * bonus + buffGain(e), e = e })
                        for l = 0, e.rows.max do wantLeft = wantLeft + e.rows[l].cost * info.costScale end
                    end
                end
            end
            if #opts == 0 then break end
            local left = math.max(0, info.total - wave)
            local future = money + farmNow * left
            for i = wave + 1, info.total do future = future + (rewards[i] or 0) end
            local coming = {}
            for k = 1, 5 do
                local h = hpOf(wave + k)
                if not h then break end
                table.insert(coming, { hp = h, reward = rewards[wave + k] or 0 })
            end
            local choice = ECON.decide(opts, { money = money, left = left, attackers = kinds, pressure = pressure, piling = piling,
                clearSec = hpAll > 0 and (dpsAll > 0 and hpAll / (dpsAll * eff) or math.huge) or 0, enemies = #alive, future = future, wantLeft = wantLeft,
                coming = coming, waveSec = info.waveSec, eff = eff, teamDps = dpsAll * eff, farmNow = farmNow, hpAlive = hpAll, incomeRate = incomeRate,
                roadSec = 1 / math.max(0.001, info.walk), cover = cover })
            if not choice or choice.cost > money then break end
            money = money - choice.cost
            spentAt[wave] = (spentAt[wave] or 0) + choice.cost
            if choice.place then
                local c = { e = choice.e, lvl = 0 }
                refresh(c)
                table.insert(copies, c)
            else
                choice.c.lvl = choice.c.lvl + 1
                refresh(choice.c)
            end
            teamFx()
            dpsAll = 0
            for _, c in ipairs(copies) do dpsAll = dpsAll + realDps(c) end
        end
        t = t + dt
        steps = steps + 1
        if steps % 120 == 0 then task.wait() end
    end
    return { won = false, wave = wave, t = t, aliveAt = aliveAt, dpsAt = dpsAt, spentAt = spentAt, money = money, timeout = true }
end
-- win chance from the sim: wins with 30% tougher enemies → 0.92 · wins → 0.7 · wins only vs 25% weaker → 0.25 · else 0.05
function SIM.evaluate(info, team)
    local r1 = SIM.run(info, team, { hpMul = 1 })
    local res = { won = r1.won, wave = r1.wave, minutes = r1.t / 60, aliveAt = r1.aliveAt, total = info.total, at = os.time() }
    if r1.won then
        local r2 = SIM.run(info, team, { hpMul = 1.3 })
        res.p = r2.won and 0.92 or 0.7
        res.margin = r2.won and "wins with room to spare" or "wins, but only just"
    else
        local r3 = SIM.run(info, team, { hpMul = 0.75 })
        res.p = r3.won and 0.25 or 0.05
        res.margin = r3.won and string.format("loses at wave %d (would win vs 25%% weaker enemies)", r1.wave) or string.format("loses at wave %d of %d", r1.wave, info.total)
    end
    return res
end
-- how well the sim matched real runs with the same team: HP alive at each wave start (waves 3+), real / sim
function SIM.trust(info, team)
    local cal = info.cal or {}
    if type(cal.alive) ~= "table" or cal.teamSig ~= SIM.sig((function() local l = {} for _, e in ipairs(team) do table.insert(l, e.u) end return l end)()) then return nil end
    -- real runs on another map (the half-hour challenge rotates) say nothing about this one
    if info.key == "ch" and not cal.aliveLvl then return nil end
    if cal.aliveLvl and info.ld and info.ld.id and cal.aliveLvl ~= tostring(info.ld.id) then return nil end
    local r = SIM.run(info, team, { hpMul = 1 })
    local sumR, sumS, n = 0, 0, 0
    for w = 3, math.min(r.wave, tonumber(cal.lastWave) or 99) do
        local real = tonumber(cal.alive[tostring(w)])
        local sim = r.aliveAt[w]
        if real and sim and real > 0 then sumR = sumR + real; sumS = sumS + sim; n = n + 1 end
    end
    if n < 2 or sumS <= 0 then return nil end
    local ratio = sumR / sumS
    return { ratio = ratio, ok = ratio >= 0.75 and ratio <= 1.33, waves = n }
end
-- the planner: your team vs the mode, the best team from your units, and what ready evolutions would change
function SIM.pool(mod)
    local s = C.session()
    local best, farms = {}, {}
    for _, u0 in pairs(s.profile_data.collection.owned_units) do
        local u = s.collection:get_unit_by_uuid(u0.uuid) or u0
        if C.Units[u.unit_id] and UNIT.rows(u.unit_id) then
            local farm = UNIT.isFarm(u.unit_id)
            local okS, sc = pcall(farm and function() return UNIT.farm(u, UNIT.rows(u.unit_id).max) end or UNIT.score, u, mod)
            sc = okS and sc or 0
            local bucket = farm and farms or best
            if not bucket[u.unit_id] or sc > bucket[u.unit_id].sc then bucket[u.unit_id] = { u = u, sc = sc } end
        end
    end
    local list, flist = {}, {}
    for _, v in pairs(best) do table.insert(list, v) end
    for _, v in pairs(farms) do table.insert(flist, v) end
    table.sort(list, function(a, b) return a.sc > b.sc end)
    table.sort(flist, function(a, b) return a.sc > b.sc end)
    local pool = {}
    for i = 1, math.min(10, #list) do table.insert(pool, list[i].u) end
    if flist[1] then table.insert(pool, flist[1].u) end
    return pool
end
function SIM.objective(r) return (r.won and 1000 or 0) + r.wave * 10 - (r.won and r.t / 60 or 0) end
function SIM.bestTeam(info, current, pool)
    local team = table.clone(current)
    local bestR = SIM.run(info, SIM.teamFrom(team, info.map), { hpMul = 1 })
    local bestO = SIM.objective(bestR)
    for _ = 1, 2 do
        local improved = false
        for slot = 1, 6 do
            for _, cand in ipairs(pool) do
                local dup = false
                for _, u in ipairs(team) do if u.unit_id == cand.unit_id then dup = true end end
                if not dup then
                    local trial = table.clone(team)
                    trial[slot] = cand
                    local r = SIM.run(info, SIM.teamFrom(trial, info.map), { hpMul = 1 })
                    local o = SIM.objective(r)
                    if o > bestO + 1 then team, bestO, bestR, improved = trial, o, r, true end
                end
            end
        end
        if not improved then break end
    end
    return team, bestR
end
-- evolutions the inventory already covers (and the ones missing a few items)
function SIM.evolutions()
    local s = C.session()
    local out, seen = {}, {}
    local inv = s.inventory
    local function have(id) local n = 0; pcall(function() n = inv:get_number_of_owned_item(id) end); return n end
    for _, u0 in pairs(s.profile_data.collection.owned_units) do
        local d = C.Units[u0.unit_id]
        if d and d.evolve and d.evolve.evolve_unit and not d.evolve.hide_from_ui and not seen[u0.unit_id] and C.Units[d.evolve.evolve_unit] then
            seen[u0.unit_id] = true
            local req = u0.shiny and d.evolve.shiny or d.evolve.normal
            if req then
                local missing = {}
                for _, it in pairs(req.item_requirement or {}) do
                    if have(it.item_id) < (it.amount or 1) then table.insert(missing, string.format("%s %d/%d", (C.Items[it.item_id] or {}).name or it.item_id, have(it.item_id), it.amount)) end
                end
                for _, ur in pairs(req.unit_requirement or {}) do
                    local n = 0
                    for _, o in pairs(s.profile_data.collection.owned_units) do if o.unit_id == ur.unit_id and (not ur.shiny or o.shiny) then n = n + 1 end end
                    if n < (ur.amount or 1) then table.insert(missing, string.format("%s %d/%d", UNIT.name(ur.unit_id), n, ur.amount)) end
                end
                local short = ADV.killsShort(s.collection:get_unit_by_uuid(u0.uuid) or u0, req)
                if short then table.insert(missing, string.format("%s %s/%s", short.what, U.fmt(short.have), U.fmt(short.need))) end
                if #missing <= 1 then
                    local u = s.collection:get_unit_by_uuid(u0.uuid) or u0
                    table.insert(out, { u = u, from = u0.unit_id, to = d.evolve.evolve_unit, missing = missing,
                        evolved = { unit_id = d.evolve.evolve_unit, uuid = "evo:" .. tostring(u.uuid), xp = u.xp, traits = u.traits, trait_stats = u.trait_stats, further_modifiers = u.further_modifiers } })
                end
            end
        end
    end
    return out
end
-- a mode's level data the sim can use: from the match (Loader.LevelData, saved per mode) or the lobby's tables
function SIM.levelFor(m)
    local cal = B.simCal[m.key]
    -- the daily and the half-hour challenge change map: the saved level only counts while it's the same one
    if m.kind == "daily" and B.live.daily and B.live.daily.ld then return B.live.daily.ld, B.live.daily.challenge end
    local same = m.kind ~= "challenge" or (cal and type(cal.ld) == "table" and cal.ld.id == m.level and cal.ch == m.challenge)
    if cal and type(cal.ld) == "table" and same then return cal.ld, cal.ch end
    if m.kind == "challenge" and C.Levels[m.level] then
        local ld = SIM.slim(C.Levels[m.level]); ld._difficulty = "Hard"; ld._gamemode = "challenge"; ld._challenge = m.challenge
        return ld, m.challenge
    end
    if C.Levels[m.level] then
        local ld = SIM.slim(C.Levels[m.level]); ld._difficulty = m.diff
        ld._gamemode = ld._OVERRIDE_GAMEMODE or (m.kind == "raid" and "raid") or (ld.infinite and "infinite") or "story"
        return ld, nil
    end
end
function SIM.plan(m, withTeam)
    local ld, ch = SIM.levelFor(m)
    if not ld then return nil end
    local mod = m.mod or (m.kind == "daily" and B.live.daily and B.live.daily.mod) or nil
    local info = SIM.info(ld, m.key, ch, mod)
    local units = {}
    for _, e in ipairs(UNIT.equipped()) do table.insert(units, e.u) end
    local team = SIM.teamFrom(units, info.map)
    local res = SIM.evaluate(info, team)
    res.sig = SIM.sig(units)
    res.trust = SIM.trust(info, team)
    res.label = m.label
    res.calibrated = (tonumber(info.cal.n) or 0) > 0
    B.simRes[m.key] = res
    res.aliveAt = nil
    SF.log(1, "SIM", string.format("%s: your team %s (%s, %s)", m.label, res.margin, res.calibrated and "calibrated on real runs" or "not calibrated yet",
        res.trust and string.format("real/sim HP %.2f", res.trust.ratio) or "no same-team run to compare"))
    if CFG.simTeams and withTeam then
        local okB, bestUnits, br = pcall(SIM.bestTeam, info, units, SIM.pool(mod))
        if okB and bestUnits then
            local better = SIM.objective(br) > SIM.objective(SIM.run(info, team, { hpMul = 1 })) + 1
            local uuids, names = {}, {}
            for _, u in ipairs(bestUnits) do table.insert(uuids, u.uuid); table.insert(names, UNIT.name(u.unit_id)) end
            B.simTeam[m.key] = { uuids = uuids, names = names, won = br.won, wave = br.wave, better = better, cur = { won = res.won, wave = res.wave }, at = os.time(), label = m.label }
            SF.log(1, "SIM", string.format("%s: best team from your units %s (%s)", m.label, br.won and "wins" or ("reaches wave " .. br.wave), table.concat(names, ", ")))
            -- ready evolutions: what each one does to that best team here
            local evo = {}
            for _, ev in ipairs(SIM.evolutions()) do
                local trial = table.clone(bestUnits)
                local swapped = false
                for i, u in ipairs(trial) do if u.unit_id == ev.from then trial[i] = ev.evolved; swapped = true end end
                if not swapped then
                    -- not in the team: would the evolved unit replace the weakest attacker?
                    local wi, ws = nil, math.huge
                    for i, u in ipairs(trial) do
                        if not UNIT.isFarm(u.unit_id) then local okS, sc = pcall(UNIT.score, u, mod); if okS and sc < ws then wi, ws = i, sc end end
                    end
                    if wi then trial[wi] = ev.evolved end
                end
                local r = SIM.run(info, SIM.teamFrom(trial, info.map), { hpMul = 1 })
                local gain
                if r.won and not br.won then gain = "turns " .. m.label .. " into a win"
                elseif r.wave > br.wave then gain = string.format("%s: reaches wave %d instead of %d", m.label, r.wave, br.wave)
                elseif r.won and br.won and r.t < br.t - 6 then gain = string.format("clears %s %.1f min faster", m.label, (br.t - r.t) / 60)
                else gain = br.won and ("no difference in " .. m.label .. " (already a win)") or ("doesn't help in " .. m.label) end
                table.insert(evo, { from = UNIT.name(ev.from), to = UNIT.name(ev.to), ready = #ev.missing == 0, missing = ev.missing[1], gain = gain, mode = m.label })
            end
            B.simEvo = evo
        end
    end
    SF.saveSoon()
    return res
end

-- ============================================================
--  MATCH
-- ============================================================
MT.refused, MT.spent, MT.actions = {}, 0, {}
MT.waveMax = {}
function MT.mapKey() return tostring(MT.ld and MT.ld.map or "?") end
function MT.money() local s = LP:FindFirstChild("_stats"); return s and s.resource.Value or 0 end
function MT.wave() return workspace:FindFirstChild("_wave_num") and workspace._wave_num.Value or 0 end
-- road samples every 2 studs on every lane, with how far along the road they are (0 = spawn, 1 = base)
function MT.buildPath()
    MT.samples = {}
    local cache = C.PATH and C.PATH.PATH_CACHE and C.PATH.PATH_CACHE[workspace._BASES.pve]
    if not cache then return end
    for lane, v in pairs(cache) do
        if not (C.PATH.HIDDEN_MOCK_LANES and C.PATH.HIDDEN_MOCK_LANES[lane.Name]) then
            local pts = {}
            for _, p in ipairs(v.points or {}) do table.insert(pts, p.part.Position) end
            local total = 0
            for i = 2, #pts do total = total + (pts[i] - pts[i - 1]).Magnitude end
            local walked = 0
            for i = 2, #pts do
                local a, b = pts[i - 1], pts[i]
                local len = (b - a).Magnitude
                local steps = math.max(1, math.floor(len / 2))
                for k = 0, steps - 1 do
                    local pos = a:Lerp(b, k / steps)
                    table.insert(MT.samples, { pos = pos, prog = (walked + len * k / steps) / math.max(1, total), lane = lane.Name })
                end
                walked = walked + len
            end
            if pts[#pts] then table.insert(MT.samples, { pos = pts[#pts], prog = 1, lane = lane.Name }) end
        end
    end
end
-- the waves of this level (Data.Waves, following templates / overrides)
function MT.buildWaves()
    local ld = MT.ld
    local w = ld and C.Waves[ld.waves or ld.id]
    local list
    if type(w) == "table" then
        list = w.override_waves or w.waves
        if not list and w.template and C.Waves[w.template] then list = C.Waves[w.template].waves or C.Waves[w.template].override_waves end
    end
    MT.waveList = U.list(list)
    MT.total = tonumber(ld and ld._override_infinite_bound_waves) or (#MT.waveList > 0 and #MT.waveList) or 15
end
-- the yen wave i pays when it ends (listed reward × the world's money scale)
function MT.waveReward(i)
    if MT.info then return SIM.waveYen(MT.info, i) end
    local w = MT.waveList and MT.waveList[i]
    return (w and tonumber(w.wave_reward) or 0) * 2.6
end
function MT.progressAt(pos)
    local best, bd = 0, math.huge
    local fp = U.flat(pos)
    for _, s in ipairs(MT.samples) do
        local d = (U.flat(s.pos) - fp).Magnitude
        if d < bd then bd, best = d, s.prog end
    end
    return best, bd
end
function MT.scan()
    local list, mine = {}, {}
    for _, folder in ipairs({ workspace._UNITS }) do
        for _, m in ipairs(folder:GetChildren()) do
            local st = m:FindFirstChild("_stats")
            if st and st:FindFirstChild("player") then
                -- summons (Metal Knight's drones…) have a parent unit and no stats of their own: not your units
                local pu = st:FindFirstChild("parent_unit")
                local summon = (pu and pu.Value ~= nil) or not st:FindFirstChild("attack_cooldown") or not st:FindFirstChild("upgrade")
                if st.player.Value == LP then
                    if not summon then table.insert(mine, m) end
                elseif st.player.Value == nil and m:FindFirstChild("HumanoidRootPart") then
                    local prog = MT.progressAt(m.HumanoidRootPart.Position)
                    local hum = m:FindFirstChildOfClass("Humanoid")
                    local hp = hum and hum.Health or (st:FindFirstChild("health") and st.health.Value) or 0
                    local red = st:FindFirstChild("damage_reduction") and tonumber(st.damage_reduction.Value) or 0
                    local ck = MT.info and MT.info.cfgById[st.id.Value]
                    table.insert(list, { m = m, pos = m.HumanoidRootPart.Position, prog = prog, hp = hp, red = red, boss = ck and tostring(ck):find("boss") ~= nil or false })
                end
            end
        end
    end
    MT.enemies, MT.mine = list, mine
    local w = MT.wave()
    local mx = 0
    -- seconds the team needs to kill everything alive: enemy HP (after their damage reduction) ÷ live damage
    local hp, dps, raw = 0, 0, 0
    for _, e in ipairs(list) do mx = math.max(mx, e.prog); hp = hp + e.hp / math.max(0.1, 1 - e.red); raw = raw + e.hp end
    MT.hpAliveRaw = raw
    for _, m in ipairs(mine) do
        local id = m._stats.id.Value
        if not UNIT.isFarm(id) and m._stats:FindFirstChild("damage") then
            local ok, v = pcall(MT.liveDps, m, id)
            if ok and v then dps = dps + v end
        end
    end
    MT.hpAlive, MT.teamDps = hp, dps
    MT.clearSec = hp > 0 and (dps > 0 and hp / dps or math.huge) or 0
    MT.waveMax[w] = math.max(MT.waveMax[w] or 0, mx)
    MT.front = mx
    MT.pressure = math.max(MT.waveMax[w] or 0, MT.waveMax[w - 1] or 0)
    MT.depth = MT.coverage(mine, list)
    -- enemies piling up: more alive than 12 s ago and a crowd on the road (tanky waves that don't walk far
    -- but don't die either: waves and farm yen only pay when they end)
    local t = U.now()
    MT.aliveHist = MT.aliveHist or {}
    table.insert(MT.aliveHist, { t = t, n = #list })
    while MT.aliveHist[1] and t - MT.aliveHist[1].t > 12 do table.remove(MT.aliveHist, 1) end
    local old = MT.aliveHist[1]
    MT.piling = #list >= 8 and old and t - old.t >= 8 and #list > old.n + 1 or false
    if #list >= 18 then MT.piling = true end
end
-- --- placement -------------------------------------------------
function MT.setupChecks()
    MT.probe = Instance.new("Part")
    MT.probe.Name = "_aa_probe"; MT.probe.Anchored = true; MT.probe.CanCollide = false
    MT.probe.CanTouch = false; MT.probe.CanQuery = false; MT.probe.Transparency = 1
    MT.probe.Parent = workspace:FindFirstChild("ignore") or workspace
    -- the map's no-place volumes (the game parents them into the world only while you place by hand)
    local src = RS:FindFirstChild("_bounds")
    MT.bounds = Instance.new("Folder")
    MT.bounds.Name = "_aa_bounds"
    if src then
        for _, d in ipairs(src:GetDescendants()) do
            if d:IsA("BasePart") then
                local c = d:Clone()
                for _, ch in ipairs(c:GetChildren()) do ch:Destroy() end
                c.Anchored = true; c.CanCollide = false; c.CanTouch = false; c.CanQuery = true; c.Transparency = 1
                c.CFrame = d.CFrame
                c.Parent = MT.bounds
            end
        end
    end
    MT.bounds.Parent = workspace:FindFirstChild("ignore") or workspace
    MT.overlap = OverlapParams.new()
    MT.overlap.FilterType = Enum.RaycastFilterType.Include
    MT.overlap.FilterDescendantsInstances = { workspace._road, MT.bounds }
end
function MT.spotKey(p) return string.format("%d,%d", math.floor(p.X + 0.5), math.floor(p.Z + 0.5)) end
function MT.blockedSpot(p)
    local k = MT.spotKey(p)
    if MT.refused[k] then return true end
    local mb = B.blocked[MT.mapKey()]
    return mb and (tonumber(mb[k]) or 0) >= 2
end
-- the same checks the game's placement preview makes: ground (or hill) under the spot, not "_donotplace",
-- the unit's footprint clear of the road, the map's no-place volumes and your other units
function MT.valid(pos, data)
    local hit = C.PC.raycast(pos + Vector3.new(0, 40, 0), Vector3.new(0, -120, 0))
    if not hit then return nil end
    if not C.PC.is_valid_raycast_hit(hit.Instance, data) then return nil end
    local p = hit.Position
    if MT.blockedSpot(p) then return nil end
    local r = (tonumber(data.override_hitbox_radius) or 1.5) + 0.25
    MT.probe.Size = Vector3.new(r * 2, 2.5, r * 2)
    MT.probe.CFrame = CFrame.new(p + Vector3.new(0, 1.35, 0))
    if #workspace:GetPartsInPart(MT.probe, MT.overlap) > 0 then return nil end
    for _, m in ipairs(MT.mine or {}) do
        local hb = m:FindFirstChild("_hitbox")
        local q = hb and hb.Position or m:GetPivot().Position
        local rr = hb and math.max(hb.Size.X, hb.Size.Z) / 2 or 1.5
        if (U.flat(p) - U.flat(q)).Magnitude < r + rr then return nil end
    end
    return p
end
-- candidate spots: both sides of the road at several distances, every 6 studs along it
function MT.buildCandidates()
    MT.cands = {}
    local seen = {}
    for i = 1, #MT.samples, 3 do
        local s = MT.samples[i]
        local nxt = MT.samples[math.min(#MT.samples, i + 1)]
        local dir = U.flat(nxt.pos - s.pos)
        if dir.Magnitude < 0.01 then dir = Vector3.new(1, 0, 0) end
        dir = dir.Unit
        local side = Vector3.new(-dir.Z, 0, dir.X)
        for _, d in ipairs({ 3, 4.5, 6, 8, 10.5, 13.5, 17 }) do
            for _, sgn in ipairs({ 1, -1 }) do
                local pos = s.pos + side * d * sgn
                local k = string.format("%d,%d", math.floor(pos.X / 1.5), math.floor(pos.Z / 1.5))
                if not seen[k] then seen[k] = true; table.insert(MT.cands, pos) end
            end
        end
    end
end
-- defense in depth: how far along the road your attackers reach, and the furthest enemy already past all of
-- them (a leak: nothing can hit it any more before the base, and one leaked enemy takes the base down)
function MT.coverage(mine, enemies)
    local units = {}
    for _, m in ipairs(mine) do
        local st = m._stats
        if not UNIT.isFarm(st.id.Value) and st:FindFirstChild("range") then table.insert(units, { p = U.flat(m:GetPivot().Position), r = st.range.Value }) end
    end
    local covEnd = 0
    if #units > 0 then
        for _, s in ipairs(MT.samples) do
            if s.prog > covEnd then
                local fp = U.flat(s.pos)
                for _, u in ipairs(units) do if (fp - u.p).Magnitude <= u.r then covEnd = s.prog; break end end
            end
        end
    end
    local leak
    if #units > 0 then
        for _, e in ipairs(enemies) do if e.hp > 0 and e.prog > covEnd + 0.02 then leak = math.max(leak or 0, e.prog) end end
    end
    -- enemies already reach the end of the covered road: the next unit should extend it
    local push = #units > 0 and (MT.pressure or 0) >= covEnd - 0.08
    return { covEnd = covEnd, leak = leak, push = push, units = #units }
end
-- road samples within range of a spot; weighted: each sample counts by how much time enemies really spend
-- there on this map (measured; 0.15 floor so a quiet stretch still counts a little). depth: road past your
-- coverage counts extra once enemies get there, and the road ahead of a leaked enemy counts most
function MT.cover(pos, range, weighted, depth)
    local n = 0
    local fp = U.flat(pos)
    local dens = weighted and B.maps[MT.mapKey()] and B.maps[MT.mapKey()].dens
    for _, s in ipairs(MT.samples) do
        if (U.flat(s.pos) - fp).Magnitude <= range then
            local w = 1
            if dens then w = 0.15 + 0.85 * (tonumber(dens[math.min(SIM.BINS, math.floor(s.prog * SIM.BINS) + 1)]) or 0) end
            if depth then
                if depth.leak and s.prog >= depth.leak - 0.01 then w = w + 3
                elseif depth.push and s.prog > depth.covEnd then w = w + 0.6 end
            end
            n = n + w
        end
    end
    return n
end
-- synergy: buffers on the field (pos, range, what they buff) and your units' damage by position
function MT.fieldBuffers()
    local list = {}
    for _, m in ipairs(MT.mine or {}) do
        local b = UNIT.allyBuff(m._stats.id.Value)
        if b then table.insert(list, { pos = m:GetPivot().Position, range = m._stats.range.Value, b = b }) end
    end
    return list
end
function MT.bestSpot(e, wantLow)
    local data = e.data
    local depth = MT.depth
    -- against a leak the unit's range right now counts (it has to hit that enemy before it gets upgraded)
    local range = UNIT.range(e.u, (depth and depth.leak) and 0 or math.min(3, UNIT.rows(e.id).max))
    local myBuff = UNIT.allyBuff(e.id)
    local _, myBase = UNIT.types(e.id)
    local buffers = myBuff and {} or MT.fieldBuffers()
    -- for a buffer: the units it would buff, with their live damage
    local allies, allyTotal = {}, 0
    if myBuff then
        for _, m in ipairs(MT.mine or {}) do
            local id = m._stats.id.Value
            local _, base = UNIT.types(id)
            if not UNIT.isFarm(id) and myBuff.types[base] then
                local okD, v = pcall(MT.liveDps, m, id)
                v = okD and v or 0
                table.insert(allies, { pos = m:GetPivot().Position, dps = v })
                allyTotal = allyTotal + v
            end
        end
    end
    local best, bestScore, bestN
    local checked = 0
    local measured = B.maps[MT.mapKey()] and B.maps[MT.mapKey()].dens
    for _, pos in ipairs(MT.cands) do
        local p = MT.valid(pos, data)
        checked = checked + 1
        if checked % 40 == 0 then task.wait() end
        if p then
            local sc
            if wantLow then
                sc = -MT.cover(p, range)
            elseif myBuff and allyTotal > 0 then
                -- a buffer stands where its range holds the most damage of the units it buffs (the road still counts a bit)
                local inRange = 0
                for _, a in ipairs(allies) do if (U.flat(a.pos) - U.flat(p)).Magnitude <= range then inRange = inRange + a.dps end end
                sc = inRange / allyTotal * 100 + MT.cover(p, range, true) * 0.05
            else
                local n = MT.cover(p, range, true, depth)
                sc = n + (measured and 0 or (1 - MT.progressAt(p)) * 0.5)
                -- inside a buffer's range that buffs this unit: worth the buff × its uptime
                for _, bf in ipairs(buffers) do
                    local rate = bf.b.types[myBase]
                    if rate and (U.flat(bf.pos) - U.flat(p)).Magnitude <= bf.range then sc = sc * (1 + rate * bf.b.uptime); break end
                end
            end
            if not bestScore or sc > bestScore then best, bestScore, bestN = p, sc, MT.cover(p, range) end
        end
    end
    return best, bestN or 0
end
function MT.lookAt(p)
    local bd, target = math.huge, nil
    for _, s in ipairs(MT.samples) do
        local d = (U.flat(s.pos) - U.flat(p)).Magnitude
        if d < bd then bd, target = d, s.pos end
    end
    local dir = target and U.flat(target - p) or Vector3.new(0, 0, -1)
    return dir.Magnitude > 0.01 and dir.Unit or Vector3.new(0, 0, -1)
end
function MT.place(e, why)
    local farm = UNIT.isFarm(e.id)
    local p, n = MT.bestSpot(e, farm)
    if not p then
        MT.noSpot[e.uuid] = (MT.noSpot[e.uuid] or 0) + 1
        SF.status("Placement", "no free spot for " .. UNIT.name(e.id))
        return false
    end
    local before = MT.money()
    local ok, r = SF.request("place", "spawn_unit", e.uuid, C.Util.CFramePLV(p, MT.lookAt(p)))
    if ok and r then
        MT.spent = MT.spent + (e.data.cost or 0)
        table.insert(MT.actions, string.format("placed %s", UNIT.name(e.id)))
        SF.log(1, "PLACE", string.format("%s at %s (covers %d road samples) — %s", UNIT.name(e.id), MT.spotKey(p), n, why))
        SF.status("Placement", string.format("placed %s — %s", UNIT.name(e.id), why))
        MT.placedAt = MT.placedAt or {}
        MT.placedAt[e.uuid] = (MT.placedAt[e.uuid] or 0) + 1
        return true
    end
    -- refused: remember the spot (2 refusals in separate runs = skipped on this map for good)
    if before >= (e.data.cost or 0) then
        local k = MT.spotKey(p)
        MT.refused[k] = true
        local mk = MT.mapKey()
        B.blocked[mk] = B.blocked[mk] or {}
        if not MT.refusedRun[k] then B.blocked[mk][k] = (tonumber(B.blocked[mk][k]) or 0) + 1; MT.refusedRun[k] = true end
        MT.refusals = (MT.refusals or 0) + 1
        MT.unitRefusals[e.uuid] = (MT.unitRefusals[e.uuid] or 0) + 1
        -- 3 refusals for one unit on different good spots with the money in hand: it's at its limit
        if MT.unitRefusals[e.uuid] >= 3 then
            B.caps[e.uuid] = math.max(1, MT.count(e.uuid))
            SF.log(1, "PLACE", string.format("%s: the server allows %d on the field (learned)", UNIT.name(e.id), B.caps[e.uuid]))
        end
        SF.log(2, "PLACE", "refused spot " .. k .. " for " .. UNIT.name(e.id))
        SF.saveSoon()
    end
    return false
end
function MT.count(uuid)
    local n = 0
    for _, folder in ipairs({ workspace._UNITS, workspace:FindFirstChild("_DEAD_UNITS") }) do
        if folder then
            for _, m in ipairs(folder:GetChildren()) do
                local st = m:FindFirstChild("_stats")
                if st and st:FindFirstChild("uuid") and st.player.Value == LP and st.uuid.Value == uuid then n = n + 1 end
            end
        end
    end
    return n
end
-- --- what the simulator learns from every match ------------------
function MT.measure()
    local cal, info = MT.calRun, MT.info
    if not (cal and info) then return end
    local t = U.now()
    local w = MT.wave()
    local money = MT.money()
    if not cal.start and money > 0 and #MT.mine == 0 then cal.start = money end
    -- wave length, and the yen paid as a wave starts (minus what the farm units pay)
    if w ~= cal.lastW then
        if cal.lastW and cal.lastW > 0 and cal.lastWT then table.insert(cal.waveSec, t - cal.lastWT) end
        -- wave paid (cleared) → next wave: the auto-skip's wait
        if cal.paidT and w > 0 and t - cal.paidT < 15 then table.insert(cal.skip, t - cal.paidT) end
        cal.paidT = nil
        if w > 0 then cal.alive[tostring(w)] = MT.hpAliveRaw or 0 end
        cal.lastW, cal.lastWT = w, t
    end
    -- the wave's timer: the longest value seen during the wave
    local wt = workspace:FindFirstChild("_wave_time")
    if wt and w > 0 then cal.timer[tostring(w)] = math.max(cal.timer[tostring(w)] or 0, tonumber(wt.Value) or 0) end
    -- yen income per second over the last 30 s (waves, kills, farm) — what saving for a buy costs in time
    local dm = money - (MT.lastMoneyR or money)
    MT.lastMoneyR = money
    MT.incomeLog = MT.incomeLog or {}
    if dm > 0 then table.insert(MT.incomeLog, { t = t, y = dm }) end
    while MT.incomeLog[1] and t - MT.incomeLog[1].t > 30 do table.remove(MT.incomeLog, 1) end
    local sum = 0
    for _, x in ipairs(MT.incomeLog) do sum = sum + x.y end
    local span = math.min(30, t - (MT.startT or t))
    MT.incomeRate = span >= 8 and sum / span or nil
    -- enemies: real HP vs the formula, walking speed
    for _, e in ipairs(MT.enemies) do
        local m = e.m
        local tr = MT.track[m]
        if not tr then
            local st = m._stats
            local hum = m:FindFirstChildOfClass("Humanoid")
            local key = info.cfgById[st.id.Value]
            local base = key and SIM.baseStats(info, key)
            if hum and base and w > 0 then
                local pred = base * info.hpRaw * SIM.waveScale(info, w, info.list[w])
                if pred > 0 and hum.MaxHealth > 0 then table.insert(cal.hp, hum.MaxHealth / pred) end
            end
            MT.track[m] = { t = t, p = e.prog, sp = (st:FindFirstChild("speed") and tonumber(st.speed.Value)) or 1 }
            if w > 0 then
                cal.spawn[tostring(w)] = (cal.spawn[tostring(w)] or 0) + 1
                cal.spawnLast[tostring(w)] = t - (cal.lastWT or t) -- the wave's last enemy so far came out this long after it started
            end
        elseif not tr.done and t - tr.t >= 4 then
            tr.done = true
            local rate = (e.prog - tr.p) / (t - tr.t) / math.max(0.1, tr.sp)
            if rate > 0.001 and e.prog < 0.95 then table.insert(cal.walk, rate) end
        end
    end
    -- kill efficiency: damage that really landed (units' total_damage) ÷ the listed damage of units that had a
    -- target, over 5-second windows; and team damage at each wave start (to compare the sim's buying)
    local dealt = 0
    for _, m in ipairs(MT.mine) do
        local td = m._stats:FindFirstChild("total_damage")
        if td then dealt = dealt + td.Value end
    end
    cal.potSum = cal.potSum or 0
    if cal.lastDealtT then
        local dt = t - cal.lastDealtT
        local pot = 0
        for _, m in ipairs(MT.mine) do
            local st = m._stats
            local id = st.id.Value
            if not UNIT.isFarm(id) and st:FindFirstChild("target") and st.target.Value ~= nil then
                local okD, v = pcall(MT.liveDps, m, id)
                if okD and v then pot = pot + v * dt end
            end
        end
        cal.potWin = (cal.potWin or 0) + pot
        if t - (cal.winT or t) >= 5 then
            local d = dealt - (cal.winDealt or dealt)
            if cal.potWin > 0 and d >= 0 then cal.dealtSum = (cal.dealtSum or 0) + d; cal.potSum = cal.potSum + cal.potWin end
            cal.winT, cal.winDealt, cal.potWin = t, dealt, 0
        end
    end
    if not cal.winT then cal.winT, cal.winDealt = t, dealt end
    cal.lastDealtT = t
    if w ~= cal.dpsW and w > 0 then cal.dpsAt[tostring(w)] = MT.teamDps or 0; cal.dpsW = w end
    -- where enemies spend their time on the road (20 bins): placement weights the road by it
    local dt2 = math.min(1, t - (cal.densT or t))
    cal.densT = t
    for _, e in ipairs(MT.enemies) do
        local b = math.min(SIM.BINS, math.floor(e.prog * SIM.BINS) + 1)
        cal.dens[b] = (cal.dens[b] or 0) + dt2
    end
    -- base: HP lost per second ÷ the max HP of the enemies standing at the end of the road
    local base = workspace._BASES.player:FindFirstChild("base")
    local fu = base and base:FindFirstChild("fake_unit")
    local hum = fu and fu:FindFirstChildOfClass("Humanoid")
    if hum then
        cal.baseHp = math.max(cal.baseHp or 0, hum.MaxHealth)
        local atEnd = 0
        for _, e in ipairs(MT.enemies) do
            if e.prog >= 0.97 then
                local eh = e.m:FindFirstChildOfClass("Humanoid")
                atEnd = atEnd + (eh and eh.MaxHealth or e.hp)
            end
        end
        if cal.lastBase and hum.Health < cal.lastBase and atEnd > 0 and cal.lastBaseT then
            table.insert(cal.baseRel, (cal.lastBase - hum.Health) / math.max(0.1, t - cal.lastBaseT) / atEnd)
        end
        cal.lastBase, cal.lastBaseT = hum.Health, t
    end
end
-- the road coverage of the best spot at each range on this map (the simulator's placement)
function MT.recordMap()
    local map = MT.mapKey()
    local old = B.maps[map]
    -- re-record while the enemy-density data is still new (the best spot moves to where enemies really are)
    if old and old.v == 1 and (old.densN or 0) == (old.binsDensN or 0) then return end
    if old and old.v == 1 and (old.densN or 0) > 5 and (old.binsDensN or 0) >= 5 then return end
    local ground = { override_hitbox_radius = 1.75 }
    local hill = { hill_unit = true, override_hitbox_radius = 1.75 }
    local spots, hillOk = {}, false
    for i, pos in ipairs(MT.cands) do
        local p = MT.valid(pos, ground)
        if p then table.insert(spots, p) end
        if not hillOk and MT.valid(pos, hill) then hillOk = true end
        if i % 30 == 0 then task.wait() end
    end
    local bins = {}
    for rb = 5, 60, 5 do
        local best, bestN
        for _, p in ipairs(spots) do local n = MT.cover(p, rb, true); if not bestN or n > bestN then best, bestN = p, n end end
        if best then
            local mask = {}
            for i = 1, SIM.BINS do mask[i] = "0" end
            local fp = U.flat(best)
            for _, s in ipairs(MT.samples) do
                if (U.flat(s.pos) - fp).Magnitude <= rb then mask[math.min(SIM.BINS, math.floor(s.prog * SIM.BINS) + 1)] = "1" end
            end
            bins[tostring(rb)] = table.concat(mask)
        end
        task.wait()
    end
    local keep = B.maps[map] or {}
    B.maps[map] = { v = 1, bins = bins, hill = hillOk, spots = #spots, dens = keep.dens, densN = keep.densN, binsDensN = keep.densN or 0 }
    SIM._masks = {}
    SF.log(1, "SIM", string.format("mapped %s: %d free spots%s", map, #spots, hillOk and ", hill spots too" or ", no hill spots"))
    SF.saveSoon()
end
-- after a run: fold what was measured into the mode's calibration (rate slows as runs add up)
function MT.calMerge(won)
    local r = MT.calRun
    if not (r and MT.key) then return end
    local cal = SIM.cal(MT.key)
    cal.n = (tonumber(cal.n) or 0) + 1
    local rate = math.max(0.2, 1 / cal.n)
    local function med(list) if #list == 0 then return nil end table.sort(list) return list[math.ceil(#list / 2)] end
    local function blend(name, v) if v then cal[name] = cal[name] and (cal[name] + (v - cal[name]) * rate) or v end end
    blend("hpCal", med(r.hp))
    blend("walk", med(r.walk))
    if (r.potSum or 0) > 0 and (r.dealtSum or 0) > 0 then blend("eff", U.clamp(r.dealtSum / r.potSum, 0.1, 2)) end
    -- road density per map (EMA, scaled so the busiest bin is 1)
    local mk = MT.mapKey()
    local mx = 0
    for _, v in pairs(r.dens) do mx = math.max(mx, v) end
    if mx > 0 then
        B.maps[mk] = B.maps[mk] or {}
        local dens = type(B.maps[mk].dens) == "table" and B.maps[mk].dens or {}
        local dn = (tonumber(B.maps[mk].densN) or 0) + 1
        for b = 1, SIM.BINS do
            local v = (r.dens[b] or 0) / mx
            local o = tonumber(dens[b])
            dens[b] = o and (o + (v - o) * math.max(0.2, 1 / dn)) or v
        end
        B.maps[mk].dens, B.maps[mk].densN = dens, dn
    end
    -- wave pay vs listed yen × money scale (1 = the formula is right)
    if #r.pay >= 2 then blend("yenCal", U.clamp(med(r.pay), 0.5, 2)) end
    if not MT.joinedMid then
        blend("waveSec", med(r.waveSec))
        blend("baseRel", med(r.baseRel))
        cal.baseDps = nil -- old absolute reading (base damage scales with the enemy's HP)
        blend("skipDelay", med(r.skip))
        -- the gap between enemies coming out: the wave's last enemy ÷ its count (waves fully seen)
        local gp = {}
        for w = 2, MT.wave() - 1 do
            local n, last = tonumber(r.spawn[tostring(w)]), tonumber(r.spawnLast[tostring(w)])
            if n and last and n >= 3 then table.insert(gp, last / (n - 1)) end
        end
        if #gp >= 3 then blend("spawnGap", U.clamp(med(gp), 0.05, 5)) end
        -- the skip vote: its cap (waves big enough to reach it) and the seconds it adds per enemy in smaller waves
        local cap = tonumber(cal.voteAt) or (MT.info and MT.info.voteAt) or SIM.PRIOR.voteAt
        local vt, vp = {}, {}
        for _, v in ipairs(r.votes) do
            local n = tonumber(v.n) or 0
            if n > 0 and SIM.PRIOR.voteBase + SIM.PRIOR.votePer * n >= cap + 3 then table.insert(vt, v.t)
            elseif n > 0 and v.t < cap - 2 then table.insert(vp, (v.t - SIM.PRIOR.voteBase) / n) end
        end
        blend("voteAt", med(vt))
        blend("votePer", vp[1] and U.clamp(med(vp), 0.2, 6) or nil)
        -- each wave's timer (the longest value seen + the second it had already ticked)
        cal.timerAt = type(cal.timerAt) == "table" and cal.timerAt or {}
        for k, v in pairs(r.timer) do
            if v > 5 then local o = tonumber(cal.timerAt[k]); cal.timerAt[k] = o and (o + (v + 1 - o) * rate) or (v + 1) end
        end
        if r.start then cal.start = r.start end
        if r.baseHp then cal.baseHp = r.baseHp end
        cal.yen = nil -- old per-wave yen readings (taken at the wrong moment)
        -- enemies per wave: real count vs the sim's count (waves fully seen: not the last one)
        if MT.info then
            local real, sim = 0, 0
            for w = 2, MT.wave() - 1 do
                local n = tonumber(r.spawn[tostring(w)])
                if n then real = real + n; sim = sim + #(SIM.wave(MT.info, w, true)) end
            end
            if real > 0 and sim > 0 then blend("countCal", U.clamp(real / sim, 0.25, 6)) end
        end
        -- HP alive per wave, kept per team (the trust check compares the same team only)
        local units = {}
        for _, e in ipairs(MT.team or {}) do table.insert(units, e.u) end
        local sig = SIM.sig(units)
        -- (and per level: the half-hour challenge shares one key across different maps)
        local lvl = tostring(MT.ld.id or "?")
        if cal.teamSig ~= sig or cal.aliveLvl ~= lvl then cal.alive = {}; cal.teamSig = sig; cal.aliveLvl = lvl; cal.aliveN = 0; cal.lastWave = 0; cal.dpsAt = {} end
        cal.aliveN = (tonumber(cal.aliveN) or 0) + 1
        local ar = 1 / cal.aliveN
        cal.alive = type(cal.alive) == "table" and cal.alive or {}
        for w, v in pairs(r.alive) do local o = tonumber(cal.alive[w]); cal.alive[w] = o and (o + (v - o) * ar) or v end
        cal.lastWave = math.max(tonumber(cal.lastWave) or 0, MT.wave())
        cal.dpsAt = type(cal.dpsAt) == "table" and cal.dpsAt or {}
        for w, v in pairs(r.dpsAt) do local o = tonumber(cal.dpsAt[w]); cal.dpsAt[w] = o and (o + (v - o) * ar) or v end
    end
    cal.ld = SIM.slim(MT.ld)
    cal.ch = MT.ld._challenge
    -- the calibration changed: this mode's old simulation is stale, the lobby re-simulates it
    B.simRes[MT.key] = nil
    SIM._masks = {}
    -- predicted vs real (rule: every planned run logs both)
    if MT.pred then
        SF.log(1, "SIM", string.format("predicted %s at wave %d · real %s at wave %d", MT.pred.won and "a win" or "a loss", MT.pred.wave, won and "a win" or "a loss", MT.wave()))
        cal.lastPred = { won = MT.pred.won, wave = MT.pred.wave, realWon = won, realWave = MT.wave(), at = os.time() }
    end
end
-- what placing a buffer adds: its buff × uptime × the damage of your units it buffs (0 if one already runs it)
function MT.buffGain(e)
    local b = UNIT.allyBuff(e.id)
    if not b then return 0 end
    -- the buff only reaches units inside the buffer's range: count the ones no copy on the field covers yet
    local same = {}
    for _, bf in ipairs(MT.fieldBuffers()) do if bf.b.attack == b.attack then table.insert(same, bf) end end
    local g = 0
    for _, m in ipairs(MT.mine) do
        local id = m._stats.id.Value
        if not UNIT.isFarm(id) then
            local _, base = UNIT.types(id)
            local rate = b.types[base]
            local covered = false
            local mp = m:GetPivot().Position
            for _, bf in ipairs(same) do if (U.flat(bf.pos) - U.flat(mp)).Magnitude <= bf.range then covered = true; break end end
            if rate and not covered then local ok, v = pcall(MT.liveDps, m, id); if ok and v then g = g + v * rate * b.uptime * 0.7 end end
        end
    end
    return g
end
-- --- economy: farm or damage? ----------------------------------
-- live damage of a placed unit (the game's own stats: level, trait, rolls, curse, relic crit already in)
function MT.liveDps(m, id)
    local st = m:FindFirstChild("_stats")
    if not (st and st:FindFirstChild("attack_cooldown") and st:FindFirstChild("damage") and st:FindFirstChild("range")) then return 0 end
    local cd = math.max(0.1, st.attack_cooldown.Value)
    local atk = st:FindFirstChild("primary_attack") and st.primary_attack.Value or nil
    local crit = 0
    for _, n in ipairs({ "physical_crit_chance", "magic_crit_chance" }) do
        local v = st:FindFirstChild(n)
        if v then crit = math.max(crit, tonumber(v.Value) or 0) end
    end
    return st.damage.Value / cd * UNIT.aoe(atk, st.range.Value) * (1 + crit) * UNIT.elem(id, MT.mod) * UNIT.nudge(id)
end
function MT.econ()
    local money = MT.money()
    local wave = MT.wave()
    local left = math.max(0, MT.total - wave)
    local team = MT.team
    local upMult = 1
    local spawnMult = 1
    pcall(function() spawnMult = C.USC.calculate_spawn_cost_multiplier(C.session()) end)
    local opts = {}
    local attackers, farmNow, wantLeft = 0, 0, 0
    local byUuid = {}
    for _, m in ipairs(MT.mine) do
        local st = m._stats
        local uuid = st:FindFirstChild("uuid") and st.uuid.Value
        if uuid then byUuid[uuid] = byUuid[uuid] or {}; table.insert(byUuid[uuid], m) end
    end
    for _, e in ipairs(team) do
        local rows = UNIT.rows(e.id)
        local farm = UNIT.isFarm(e.id)
        local placed = byUuid[e.uuid] or {}
        if not farm and #placed > 0 then attackers = attackers + 1 end
        -- upgrades of placed copies
        for _, m in ipairs(placed) do
            local lvl = m._stats.upgrade.Value
            if farm then farmNow = farmNow + (tonumber(m._stats.farm_amount and m._stats.farm_amount.Value) or UNIT.farm(e.u, lvl)) end
            local nxt = rows[lvl + 1]
            if nxt and lvl < rows.max then
                pcall(function() upMult = C.USC.calculate_upgrade_cost_multiplier(m, C.session()) end)
                local cost = nxt.cost * upMult
                if farm then
                    local gain = UNIT.farm(e.u, lvl + 1) - UNIT.farm(e.u, lvl)
                    table.insert(opts, { farm = true, cost = cost, gain = gain, m = m, e = e, what = string.format("upgrade %s to level %d", UNIT.name(e.id), lvl + 1) })
                else
                    local gain = ECON.upgradeGain(MT.liveDps(m, e.id), rows, lvl, cost, upMult, UNIT.dps(e.u, lvl + 1, MT.mod))
                    table.insert(opts, { cost = cost, gain = gain, m = m, e = e, what = string.format("upgrade %s to level %d", UNIT.name(e.id), lvl + 1) })
                    for l = lvl + 1, rows.max do wantLeft = wantLeft + rows[l].cost * upMult end
                end
            end
        end
        -- a new copy
        local cap = UNIT.cap(e.u)
        if #placed < cap and (MT.noSpot[e.uuid] or 0) < 3 then
            local cost = (e.data.cost or 0) * spawnMult
            if farm then
                table.insert(opts, { farm = true, place = true, cost = cost, gain = UNIT.farm(e.u, 0), e = e, what = "place " .. UNIT.name(e.id) })
            else
                local bonus = #placed == 0 and 2.5 or 1
                if attackers < 3 then bonus = bonus * 1.3 end
                table.insert(opts, { place = true, cost = cost, gain = UNIT.dps(e.u, 0, MT.mod) * bonus + MT.buffGain(e), e = e, what = "place " .. UNIT.name(e.id) })
                for l = 0, rows.max do wantLeft = wantLeft + rows[l].cost * (l == 0 and spawnMult or upMult) end
            end
        end
    end
    if #opts == 0 then return SF.status("Economy", "everything is placed and fully upgraded ✓") end
    -- future yen: wave rewards still to come + what the farm units pay every wave
    local future = money + farmNow * left
    for i = wave + 1, MT.total do future = future + MT.waveReward(i) end
    MT.farmNow, MT.future, MT.wantLeft = farmNow, future, wantLeft
    -- the next 3 waves' HP from the game's formula (this mode's simulator description, calibrated by real runs);
    -- enemy damage reduction counts as extra HP, like the live HP alive
    if MT.info and MT.comingW ~= wave then
        local coming = {}
        local red = math.min(0.9, MT.info.red or 0)
        for k = 1, 5 do
            local w2 = wave + k
            if w2 > MT.total then break end
            local okW, list, rew = pcall(SIM.wave, MT.info, w2)
            local h = 0
            for _, e in ipairs(okW and list or {}) do h = h + e.hp end
            table.insert(coming, { hp = h / (1 - red), reward = (okW and tonumber(rew)) or MT.waveReward(w2) })
        end
        MT.comingW, MT.coming = wave, coming
    end
    local eff = MT.info and MT.info.eff or SIM.PRIOR.eff
    local choice, why, waitMsg = ECON.decide(opts, { money = money, left = left, attackers = attackers, pressure = MT.pressure or 0,
        piling = MT.piling, clearSec = MT.clearSec or 0, enemies = #MT.enemies, future = future, wantLeft = wantLeft,
        coming = MT.coming, waveSec = MT.info and MT.info.waveSec, eff = eff, teamDps = (MT.teamDps or 0) * eff,
        farmNow = farmNow, hpAlive = MT.hpAlive or 0, roadSec = 1 / math.max(0.001, (MT.info and MT.info.walk) or SIM.PRIOR.walk),
        leak = MT.depth and MT.depth.leak, cover = MT.depth and MT.depth.units > 0 and MT.depth.covEnd or nil,
        incomeRate = MT.incomeRate or (((MT.coming and MT.coming[1] and MT.coming[1].reward) or 500) + farmNow) / ((MT.info and MT.info.waveSec) or 20) })
    if waitMsg then return SF.status("Economy", waitMsg) end
    if not choice then return end
    if not CFG.upgrade and not choice.place then return end
    if not CFG.place and choice.place then return end
    SF.status("Economy", string.format("%s — %s", choice.what, why))
    if choice.place then
        MT.place(choice.e, why)
    else
        local before = money
        local ok, r = SF.request("upg", "upgrade_unit_ingame", choice.m)
        if ok and r then
            MT.spent = MT.spent + choice.cost
            table.insert(MT.actions, choice.what)
            SF.log(2, "UPGRADE", choice.what .. " for ¥" .. U.fmt(choice.cost) .. " — " .. why)
            SF.status("Upgrade", choice.what)
        elseif ok then
            -- the server answered no: wait a moment (a call skipped by a running backoff must not re-arm it)
            SF.backoff("upg", 1.5)
            if before >= choice.cost then SF.log(2, "UPGRADE", "refused: " .. choice.what) end
        end
    end
end
-- --- abilities -------------------------------------------------
-- abilities: buffs (Wendy's +30% magic damage for 30 s) go up as soon as the units they help are fighting and
-- never overlap; damage abilities wait for a boss in range or a crowd of 3+, and fire anyway after abilityHold
MT.readySince, MT.buffUntil = setmetatable({}, { __mode = "k" }), {}
function MT.actives()
    if not CFG.actives or MT.activeBusy then return end
    local t = tick()
    local now = U.now()
    for _, m in ipairs(MT.mine) do
        local st = m._stats
        local act, cdv, last = st:FindFirstChild("active_attack"), st:FindFirstChild("active_attack_cooldown"), st:FindFirstChild("last_active_cast")
        if act and cdv and last and act.Value ~= "nil" and act.Value ~= "" then
            if cdv.Value - (t - last.Value) > 0 then
                MT.readySince[m] = nil
            else
                MT.readySince[m] = MT.readySince[m] or now
                local info = UNIT.attackInfo(act.Value)
                local pos = m:GetPivot().Position
                local range = st.range.Value
                local fire, why
                if info.ally or info.allyCd or info.allyRange then
                    local bt = (info.ally and info.ally.time) or (info.allyCd and info.allyCd.time) or (info.allyRange and info.allyRange.time) or 30
                    if (MT.buffUntil[act.Value] or 0) < now then
                        local helped = 0
                        for _, o in ipairs(MT.mine) do
                            local os_ = o._stats
                            if o ~= m and not UNIT.isFarm(os_.id.Value) and (U.flat(o:GetPivot().Position) - U.flat(pos)).Magnitude <= range then
                                local _, base = UNIT.types(os_.id.Value)
                                if (not info.ally or info.ally.types[base]) and os_:FindFirstChild("target") and os_.target.Value ~= nil then helped = helped + 1 end
                            end
                        end
                        if helped > 0 then
                            fire, why = true, string.format("buffs %d of your units that are fighting", helped)
                            MT.buffUntil[act.Value] = now + bt
                        end
                    end
                else
                    local near, boss = 0, false
                    for _, e in ipairs(MT.enemies) do
                        if (U.flat(e.pos) - U.flat(pos)).Magnitude <= range then
                            near = near + 1
                            if e.boss then boss = true end
                        end
                    end
                    local held = now - MT.readySince[m]
                    -- a long cooldown is worth waiting longer for: hold scales with it (6-min cooldown → up to ~2 min)
                    local hold = math.min(CFG.abilityHold * math.max(1, cdv.Value / 60), cdv.Value * 0.3)
                    local crowd = math.max(3, math.floor(#MT.enemies * 0.3))
                    if near > 0 and boss then fire, why = true, "a boss is in range"
                    elseif near >= crowd then fire, why = true, near .. " enemies in range"
                    elseif near >= 3 and held >= hold * 0.5 then fire, why = true, string.format("%d enemies in range after %ds", near, math.floor(held))
                    elseif near >= 1 and held >= hold then fire, why = true, string.format("held %ds for a crowd, firing on %d", math.floor(held), near) end
                end
                if fire then
                    -- in its own thread: a slow answer must never hold up buying
                    MT.activeBusy = true
                    MT.readySince[m] = nil
                    task.spawn(function()
                        local ok = SF.request("active", "use_active_attack", m)
                        if ok then
                            SF.status("Abilities", string.format("%s used its ability — %s", UNIT.name(st.id.Value), why))
                            SF.log(2, "ABILITY", UNIT.name(st.id.Value) .. ": " .. why)
                        end
                        MT.activeBusy = false
                    end)
                    return
                end
            end
        end
    end
end
-- --- targeting by role ----------------------------------------------
-- crowd control (slow / stun / freeze / knockback) and area attackers hold the front ("first"), where the
-- whole team can hit; heavy single-target hitters take the boss ("strongest") while one is alive
MT.prioAt = setmetatable({}, { __mode = "k" })
function MT.targeting()
    if not CFG.smartTarget then return end
    local bossAlive = false
    for _, e in ipairs(MT.enemies) do if e.boss then bossAlive = true; break end end
    for _, m in ipairs(MT.mine) do
        local st = m._stats
        local id = st.id.Value
        local pr = st:FindFirstChild("priority")
        if pr and not UNIT.isFarm(id) and not UNIT.allyBuff(id) then
            local atk = st:FindFirstChild("primary_attack") and st.primary_attack.Value or nil
            local info = UNIT.attackInfo(atk, st.range.Value)
            local heavy = info.n <= 1.4 and info.slow == 0 and info.stun == 0
            local want = (heavy and bossAlive) and "strongest" or "first"
            if pr.Value ~= want and U.now() - (MT.prioAt[m] or 0) > 8 then
                local okV, valid = pcall(C.USC.get_valid_priorities, m)
                if okV and type(valid) == "table" and valid[want] then
                    MT.prioAt[m] = U.now()
                    local ok = SF.request("prio", "change_priority", m, want)
                    if ok then
                        SF.status("Targeting", string.format("%s → %s (%s)", UNIT.name(id), want, want == "strongest" and "boss on the road" or (heavy and "no boss now" or "holds the front")))
                        SF.log(2, "TARGET", UNIT.name(id) .. " → " .. want)
                    end
                    return
                end
            end
        end
    end
end
-- --- roguelike picks (Fool's Hunt) -------------------------------
function MT.pickRogue()
    local opts = MT.rogueOptions
    if not opts then
        local ok = SF.request("rogue", "select_roguelike_option", 1)
        return ok
    end
    local WM = C.svc("WaveModifiersServiceClient")
    local best, bestScore
    for i, o in pairs(opts) do
        local sc = 0
        for _, ef in pairs(type(o) == "table" and o.effects or {}) do
            if ef.type == "candy_multiplier" then sc = sc + 2 * math.abs(tonumber(ef.amount) or 1) * ((MT.pressure or 0) < CFG.safeReach and 1 or 0.3)
            elseif ef.type == "secret_drop" then sc = sc + 1
            else
                local okB, buff = pcall(function() return WM and WM.is_effect_buff(ef) end)
                sc = sc + ((okB and buff) and 1 or -1) * ((MT.pressure or 0) >= CFG.safeReach and 1.5 or 1)
            end
        end
        if not bestScore or sc > bestScore then best, bestScore = i, sc end
    end
    MT.rogueOptions = nil
    local ok = SF.request("rogue", "select_roguelike_option", best)
    SF.log(1, "ROGUE", string.format("picked option %s (score %.1f)", tostring(best), bestScore or 0))
    return ok
end
-- --- end of a run ------------------------------------------------
function MT.learn()
    -- measured damage share vs the share the formula predicts, per unit kind: capped nudge, rate decays
    local dealt, pred = {}, {}
    local sumD, sumP = 0, 0
    for _, m in ipairs(MT.mine) do
        local st = m._stats
        local id = st.id.Value
        local d = st:FindFirstChild("total_damage") and st.total_damage.Value or 0
        if not UNIT.isFarm(id) then
            dealt[id] = (dealt[id] or 0) + d
            pred[id] = (pred[id] or 0) + MT.liveDps(m, id) / math.max(0.5, UNIT.nudge(id))
            sumD = sumD + d
        end
    end
    for _, v in pairs(pred) do sumP = sumP + v end
    if sumD <= 0 or sumP <= 0 then return end
    for id, d in pairs(dealt) do
        local share, pshare = d / sumD, pred[id] / sumP
        if pshare > 0.02 then
            local l = B.learn[id] or { eff = 1, n = 0 }
            local rate = math.max(0.02, 0.25 * math.sqrt(30 / (30 + l.n)))
            local obs = U.clamp(share / pshare, 0.3, 3)
            l.eff = l.eff + (obs - l.eff) * rate
            l.n = l.n + 1
            B.learn[id] = l
        end
    end
end
function MT.finish()
    if MT.finished then return end
    MT.finished = true
    -- the game's own result (settings shown on the results screen)
    local res
    local t0 = U.now()
    while U.now() - t0 < 8 do
        res = MT.result or (C.GUIS.results_ui and C.GUIS.results_ui.settings)
        if res then break end
        task.wait(0.25)
    end
    local won = res and res.victory or false
    local key = MT.key
    local rec = MODE.rec(key)
    local sec = res and res.stats and tonumber(res.stats.time_taken) or (os.clock() - (MT.startClock or os.clock()))
    local gems = res and ((tonumber(res.gem_reward) or 0) + (tonumber(res.first_completion_gems) or 0)) or 0
    local coins = res and res.resource_reward and tonumber(res.resource_reward.AprilCoins) or 0
    -- a run the script joined mid-way is a bad sample (no placement from the start): logged, not counted
    if not MT.joinedMid then
        rec.runs = rec.runs + 1
        if won then rec.wins = rec.wins + 1; rec.streak = 0 else rec.streak = (rec.streak or 0) + 1 end
        rec.sec = rec.sec + sec
        rec.timed = (tonumber(rec.timed) or 0) + 1
    end
    if won then
        if MT.ld._gamemode == "story" or MT.kind == "raid" then B.cleared[MT.ld.id .. ":" .. tostring(MT.ld._difficulty or "Normal")] = os.time() end
        if key == "ch" and B.live.normal then B.live.normal.doneUuid = B.live.normal.uuid end
        if key == "dc" and B.live.daily then B.live.daily.doneUuid = B.live.daily.uuid end
    end
    for k, t in pairs(B.cleared) do if os.time() - t > 86400 then B.cleared[k] = nil end end
    rec.gems = rec.gems + gems
    rec.coins = rec.coins + coins
    rec.last = os.time()
    if (rec.streak or 0) >= CFG.restAfterLosses then
        rec.restUntil = os.time() + 6 * 3600
        SF.log(1, "MODE", MODE.levelName(MT.ld.id) .. ": lost " .. rec.streak .. " in a row — resting it for 6 h")
    end
    if not won and (key == "ch" or key == "dc") then
        local x = key == "ch" and B.live.normal or B.live.daily
        if x then x.lost = (x.lost or 0) + 1 end
    end
    B.totals.matches = (B.totals.matches or 0) + 1
    if not MT.joinedMid then
        if won then B.totals.wins = B.totals.wins + 1 else B.totals.losses = B.totals.losses + 1 end
    end
    B.totals.gems = (B.totals.gems or 0) + gems
    B.totals.coins = (B.totals.coins or 0) + coins
    local items = {}
    for _, it in pairs(res and res.new_items or {}) do
        local id = type(it) == "table" and (it.item_id or it.id) or tostring(it)
        items[id] = (items[id] or 0) + (type(it) == "table" and tonumber(it.amount) or 1)
    end
    local label = MODE.levelName(MT.ld.id) .. (MT.ld._difficulty and (" (" .. MT.ld._difficulty .. ")") or "")
    B.lastResult = { won = won, text = string.format("%s · %s · wave %s · %dm%02ds", label, won and "won" or "lost", tostring(res and res.stats and res.stats.waves_completed or MT.wave()), math.floor(sec / 60), math.floor(sec % 60)),
        gems = gems, coins = coins, items = items, at = os.time() }
    table.insert(B.history, 1, { key = key, won = won, sec = sec, gems = gems, coins = coins, at = os.time() })
    while #B.history > 30 do table.remove(B.history) end
    B.lastMatch = { label = label, spent = MT.spent, actions = #MT.actions, refusals = MT.refusals or 0, at = os.time() }
    pcall(MT.learn)
    local okC, eC = pcall(MT.calMerge, won)
    if not okC then SF.log(1, "ERROR", "sim calibration: " .. tostring(eC)) end
    REPORT.record({ mode = key, won = won, sec = math.floor(sec), wave = MT.wave(), gems = gems, coins = coins, mid = MT.joinedMid or nil })
    SF.log(1, "RESULT", string.format("%s — %s, +%d gems%s, ¥%s spent, %d refused spots", label, won and "WON" or "LOST", gems, coins > 0 and (", +" .. coins .. " AprilCoins") or "", U.fmt(MT.spent), MT.refusals or 0))
    -- what next: the same ranking the lobby uses
    local top = nil
    pcall(function() top = MODE.pick() end)
    local vote, why = "lobby", "back to the lobby"
    local replayable = (MT.ld._gamemode == "story" or MT.ld._gamemode == "infinite" or (MT.kind == "event" and MT.ld._OVERRIDE_CAN_REPLAY)) and won
    if not CFG.play or not CFG.master then vote, why = "stay", "Auto Play is off"
    elseif top and top.key == key and replayable then vote, why = "replay", "replaying: still the best mode"
    elseif top and top.kind == "story" and MT.ld._is_actual_storymode and won then
        local okN, nxt = pcall(C.PSC.get_next_story_level, MT.ld.id)
        if okN and nxt == top.level and top.diff == MT.ld._difficulty then vote, why = "next_story", "next act: " .. top.label end
    end
    if vote ~= "replay" and vote ~= "next_story" and top then why = "lobby for: " .. top.label end
    B.pending = (vote == "replay" or vote == "next_story") and { key = top.key, kind = top.kind, level = top.level, diff = top.diff, label = top.label, at = os.time() } or nil
    SF.saveNow()
    SF.status("Match", why)
    SF.log(1, "MODE", why)
    if vote == "stay" then return end
    task.wait(2.5)
    if vote == "replay" or vote == "next_story" then
        SF.request("vote", "set_game_finished_vote", vote)
        local t1 = U.now()
        while SF.alive and U.now() - t1 < 30 do task.wait(1) end
    end
    if SF.alive then SF.request("lobby", "teleport_back_to_lobby") end
end
function MT.run()
    SF.status("Match", "loading the map")
    local t0 = U.now()
    while SF.alive and not (C.Loader.LevelData and workspace:FindFirstChild("_MAP_CONFIG") and workspace._MAP_CONFIG:FindFirstChild("MapLoaded") and workspace._MAP_CONFIG.MapLoaded.Value) do
        if U.now() - t0 > 60 then break end
        task.wait(0.5)
    end
    MT.ld = C.Loader.LevelData or {}
    MT.key, MT.kind = MODE.fromLevelData(MT.ld)
    MT.key = MT.key or "?"
    MT.noSpot, MT.refusedRun, MT.unitRefusals = {}, {}, {}
    MT.refusals = 0
    MT.startClock = os.clock()
    MT.startT = U.now()
    MT.joinedMid = (workspace._DATA.GameStarted.Value and MT.wave() > 2) or workspace._DATA.GameFinished.Value
    -- the mode's weak / strong elements (daily challenge, contracts, level data)
    local mod = { weak = {}, strong = {} }
    for _, w in pairs(MT.ld._weak_against or MT.ld.weak_against or {}) do
        if type(w) == "table" then mod.weak[w.damage_type] = tonumber(w.amplification) or 1.5 else mod.weak[w] = 1.5 end
    end
    for _, s in pairs(MT.ld._strong_against or MT.ld.strong_against or {}) do mod.strong[type(s) == "table" and s.damage_type or s] = true end
    if MT.key == "dc" and B.live.daily and B.live.daily.mod then mod = B.live.daily.mod end
    MT.mod = (next(mod.weak) or next(mod.strong)) and mod or nil
    MT.buildPath()
    MT.buildWaves()
    MT.setupChecks()
    MT.buildCandidates()
    MT.team = UNIT.equipped()
    -- simulator: this mode's description, what to measure, the map's coverage, and a prediction to check later
    local chId = MT.ld._challenge or (MT.key == "dc" and B.live.daily and B.live.daily.challenge) or nil
    MT.calRun = { waveSec = {}, walk = {}, hp = {}, baseRel = {}, alive = {}, spawn = {}, spawnLast = {}, dpsAt = {}, dens = {},
        pay = {}, skip = {}, timer = {}, votes = {} }
    MT.track = setmetatable({}, { __mode = "k" })
    local okI, info = pcall(SIM.info, SIM.slim(MT.ld), MT.key, chId, MT.mod)
    MT.info = okI and info or nil
    if not okI then SF.log(1, "ERROR", "sim info: " .. tostring(info)) end
    -- wave pay, the moment a wave ends: real yen ÷ (listed yen × money scale), the farm units' pay taken out
    MT.lastRes = MT.money()
    table.insert(SF.conns, LP._stats.resource.Changed:Connect(function(v)
        v = tonumber(v) or 0
        local d = v - (MT.lastRes or v)
        MT.lastRes = v
        local r = MT.calRun
        if d <= 0 or not (r and MT.info) then return end
        local raw = SIM.waveYen(MT.info, MT.wave(), MT.info.payBase)
        local farm = MT.farmNow or 0
        if raw > 0 and d >= 0.5 * (raw + farm) then
            table.insert(r.pay, (d - farm) / raw)
            r.paidT = U.now()
        end
    end))
    task.spawn(function() local ok, e = pcall(MT.recordMap); if not ok then SF.log(1, "ERROR", "map record: " .. tostring(e)) end end)
    if MT.info and not MT.joinedMid then
        task.spawn(function()
            task.wait(5)
            local units = {}
            for _, e in ipairs(MT.team) do table.insert(units, e.u) end
            local ok, r = pcall(SIM.run, MT.info, SIM.teamFrom(units, MT.info.map), { hpMul = 1 })
            if ok then MT.pred = r; SF.log(1, "SIM", string.format("prediction for this run: %s at wave %d", r.won and "win" or "loss", r.wave)) end
        end)
    end
    -- server events: the result, roguelike options
    local s2c = RS.endpoints.server_to_client
    table.insert(SF.conns, s2c.game_finished.OnClientEvent:Connect(function(settings) MT.result = settings end))
    table.insert(SF.conns, s2c.show_roguelike_options.OnClientEvent:Connect(function(_, opts) MT.rogueOptions = opts end))
    -- the skip vote opening: seconds into the wave, enemies alive, the wave all out yet (the sim's wave timing)
    if s2c:FindFirstChild("start_vote_wave_skip") then
        table.insert(SF.conns, s2c.start_vote_wave_skip.OnClientEvent:Connect(function()
            local r = MT.calRun
            if not (r and r.lastWT and MT.info) then return end
            local w = MT.wave()
            local n = #(SIM.wave(MT.info, w))
            table.insert(r.votes, { t = U.now() - r.lastWT, n = n, alive = #(MT.enemies or {}), out = (tonumber(r.spawn[tostring(w)]) or 0) >= n })
        end))
    end
    local label = MODE.levelName(MT.ld.id or "?") .. (MT.ld._difficulty and (" (" .. MT.ld._difficulty .. ")") or "")
    SF.log(1, "MATCH", string.format("%s · %d waves · %d road samples · %d spots to try%s", label, MT.total, #MT.samples, #MT.cands, MT.joinedMid and " · joined mid-way" or ""))
    SF.status("Match", label .. (B.pending and B.pending.key == MT.key and "" or " (not launched by the farm)"))
    local voted, lastWave, lastWaveAt = false, -1, U.now()
    while SF.alive do
        if CFG.master and CFG.battle then
            local ok, e = pcall(function()
                MT.scan()
                local okM, eM = pcall(MT.measure)
                if not okM and HUB.every("measErr", 30) then SF.log(1, "ERROR", "measure: " .. tostring(eM)) end
                if workspace._DATA.GameFinished.Value then MT.finish(); return end
                if CFG.autoStart and not voted and not workspace._DATA.GameStarted.Value and (#MT.mine > 0 or U.now() - t0 > 6) then
                    voted = true
                    SF.request("vstart", "vote_start")
                end
                local rg = workspace._DATA:FindFirstChild("Roguelike")
                if rg and rg:FindFirstChild("WaitingForRoguelikeChoice") and rg.WaitingForRoguelikeChoice.Value and HUB.every("rogue", 3) then MT.pickRogue() end
                MT.econ()
                if HUB.every("act", 0.5) then MT.actives() end
                if HUB.every("prio", 2) then local okT, eT = pcall(MT.targeting); if not okT and HUB.every("prioErr", 30) then SF.log(1, "ERROR", "targeting: " .. tostring(eT)) end end
                -- watchdog: no wave change for 6 min → leave
                local w = MT.wave()
                if w ~= lastWave then lastWave, lastWaveAt = w, U.now() end
                if workspace._DATA.GameStarted.Value and U.now() - lastWaveAt > 360 then
                    SF.log(1, "MATCH", "no progress for 6 min — back to the lobby")
                    lastWaveAt = U.now()
                    SF.request("lobby", "teleport_back_to_lobby")
                end
            end)
            if not ok then SF.log(1, "ERROR", "match loop: " .. tostring(e)) task.wait(1) end
        end
        if MT.finished then break end
        task.wait(0.3)
    end
end

-- ============================================================
--  ANONYMOUS STATS (hive) — queued; sent only once a webhook is connected
-- ============================================================
function REPORT.record(r)
    r.v = VERSION
    r.at = os.time()
    table.insert(B.hiveQueue, r)
    while #B.hiveQueue > 50 do table.remove(B.hiveQueue, 1) end
    if CFG.shareStats and C.WEBHOOK_URL ~= "" and #B.hiveQueue >= 5 then pcall(REPORT.flush) end
end
function REPORT.post(content)
    local req = (syn and syn.request) or (http and http.request) or http_request or request
    if not req then return false, "no http" end
    local ok, res = pcall(req, { Url = C.WEBHOOK_URL, Method = "POST", Headers = { ["Content-Type"] = "application/json" },
        Body = U.json({ content = content, allowed_mentions = { parse = {} } }) })
    return ok and res and (res.StatusCode == 200 or res.StatusCode == 204), res
end
function REPORT.flush()
    if C.WEBHOOK_URL == "" or not CFG.shareStats or #B.hiveQueue == 0 then return false, "not connected" end
    local ok = REPORT.post("📊 AA " .. U.json({ id = B.anonId, v = VERSION, runs = B.hiveQueue }))
    if ok then table.clear(B.hiveQueue); SF.saveSoon() end
    return ok
end
function REPORT.suggest(text)
    text = tostring(text or ""):sub(1, 500):gsub("https?://%S+", "[link]"):gsub("@", "(at)")
    if text:gsub("%s", "") == "" then return false, "empty" end
    if C.WEBHOOK_URL == "" then return false, "suggestions aren't connected yet" end
    if os.time() - (B.lastSuggest or 0) < 600 then return false, "one suggestion per 10 minutes" end
    local ok = REPORT.post("💡 AA " .. U.json({ id = B.anonId, v = VERSION, text = text }))
    if ok then B.lastSuggest = os.time() end
    return ok, ok and nil or "send failed"
end

-- ============================================================
--  GUI (NexusLib)
-- ============================================================
function GUI.load()
    local function try(src, from)
        if type(src) ~= "string" or #src == 0 then return nil end
        local fn, err = loadstring(src)
        if not fn then warn("[AA] NexusLib (" .. from .. ") compile error: " .. tostring(err)) return nil end
        local ok, lib = pcall(fn)
        if ok and type(lib) == "table" and type(lib.Window) == "function" then return lib end
        return nil
    end
    local okR, src = pcall(function() return isfile("NexusLib.lua") and readfile("NexusLib.lua") or nil end)
    local lib = okR and try(src, "file")
    if lib then return lib end
    local ok, s = pcall(function() return game:HttpGet(C.NEXUS_URL) end)
    return ok and try(s, "url") or nil
end
GUI.SYSTEMS = { "Mode", "Match", "Economy", "Placement", "Upgrade", "Abilities", "Targeting", "Rewards", "Gold Shop", "Summon", "Evolve" }
function GUI.build()
    local Lib = GUI.load()
    if not Lib then warn("[AA] NexusLib failed to load — running without a window") return end
    local title = "⚔️ Anime Adventures"
    local Win = Lib:Window({ title = title, subtitle = "Smart Farm v" .. VERSION, width = 820, height = 560 })
    GUI.Win = Win
    local UI, LIVE = GUI.UI, GUI.LIVE
    GUI.COL = Lib.Colors or {}
    local function setCfg(k, v) CFG[k] = v; SF.saveSoon() end
    local function tog(T, label, desc, key) UI[key] = T:Toggle(label, desc, CFG[key], function(on) setCfg(key, on) end) end
    local function sld(T, label, desc, key, o) o.default = CFG[key]; UI[key] = T:Slider(label, desc, o, function(v) setCfg(key, v) end) end
    local function int(v) return tostring(math.floor(v + 0.5)) end
    local function big(v) return U.fmt(v) end
    local pct = function(v) return string.format("%d%%", math.floor(v * 100 + 0.5)) end
    local function notify(t, m, k) pcall(function() Win:Notify(t, m, 4, k or "default") end) end

    local T = Win:Tab("🏠", "Main")
    UI.master = T:Toggle("Smart Farm", "Master switch for everything (lobby + matches)", CFG.master, function(on)
        setCfg("master", on); Win:Status(on and "▶ Farming" or "⏸ Paused")
    end)
    T:Section("Now")
    GUI.nowCard = T:StatusCard({ icon = "⏳", title = "Starting…", text = "", sub = "" })
    GUI.nextCard = T:StatusCard({ icon = "⏭", title = "Up next", text = "", sub = "" })
    T:Section("At a glance")
    GUI.goals = T:StatGrid({ "Gems", "Daily Challenge", "Challenge", "First Clears Left", "AprilCoins", "Record" }, 3)
    T:Section("Systems")
    GUI.systems = T:KeyValue(GUI.SYSTEMS, 84)
    T:Section("Controls")
    T:Button("⏹", "Stop All", "Pause every system", Color3.fromRGB(239, 68, 68), function()
        CFG.master = false; pcall(function() UI.master.Set(false, true) end); SF.saveNow(); notify("Stopped", "Smart Farm paused", "warning")
    end)
    T:Button("❌", "Unload", "Stop and remove the window", Color3.fromRGB(239, 68, 68), function() SF.unload() end)

    T = Win:Tab("🗺️", "Modes")
    T:Section("Ranking · what it plays next (gems per minute)")
    GUI.rank = T:KeyValue({ "#1", "#2", "#3", "#4", "#5", "#6" }, 26)
    T:Section("Run records")
    GUI.records = T:KeyValue({ "1", "2", "3", "4", "5", "6", "7", "8" }, 190)
    T:Section("Play")
    tog(T, "Auto Play", "Start the best mode and chain runs", "play")
    tog(T, "Daily Challenge", "Once a day: big gem reward + Divine Wish, Star Remnants, Stat Cubes", "dailyChallenge")
    tog(T, "Challenges", "New every 30 min: gems + Star Fruits", "challenge")
    tog(T, "First Clears", "Every act on Normal, then Hard: 60 gems each the first time", "firstClears")
    tog(T, "Raids", "While tries are left today: gems + raid items", "raids")
    tog(T, "Event (Fool's Hunt)", "AprilCoins every wave, for the April banner", "event")
    tog(T, "Farm Runs", "Replay cleared acts when nothing better is open", "farm")
    T:Section("Values")
    sld(T, "AprilCoin Value", "Gems one AprilCoin is worth to you (an April summon costs 150)", "aprilValue", { min = 0, max = 1, step = 0.05, format = function(v) return string.format("%.2f gems", v) end })
    sld(T, "Unlock Value", "Gem value of opening the next act, on top of the 60 first-clear gems", "unlockValue", { min = 0, max = 200, step = 5, format = int })
    sld(T, "Rest After Losses", "Rest a mode for 6 hours after this many losses in a row", "restAfterLosses", { min = 1, max = 5, step = 1, format = int })
    T:Button("🧮", "Reset Mode Stats", "Forget win rates and run times", function()
        table.clear(B.modes); SF.saveNow(); notify("Modes", "stats reset", "success")
    end)

    T = Win:Tab("⚔️", "Battle")
    T:Section("Your team at full upgrade (the game's own formulas)")
    GUI.team = T:KeyValue({ "1", "2", "3", "4", "5", "6" }, 150)
    T:Section("Simulator")
    GUI.sim = T:KeyValue({ "Next mode", "Your team", "Best team", "Evolutions", "Accuracy" }, 90)
    tog(T, "Use The Simulator", "Simulate each mode with your team before playing it; its odds go into the ranking", "sim")
    tog(T, "Plan Best Teams", "Work out the best team from all your units for the top modes (shown above)", "simTeams")
    tog(T, "Auto-Equip Best Team", "Before a mode, equip the simulator's best team when it does better (your own team is saved and put back)", "autoTeam")
    T:Button("🧪", "Simulate Now", "Re-run the simulator and the team planner for the top modes (in the lobby)", function()
        if SF.where ~= "lobby" then return notify("Simulator", "works in the lobby", "warning") end
        table.clear(B.simRes)
        HUB.last.simTeam = nil
        notify("Simulator", "re-planning — results show here in a minute", "success")
    end)
    T:Button("👥", "Equip Best Team", "Equip the team the simulator found (your own team is saved)", function()
        if SF.where ~= "lobby" then return notify("Team", "works in the lobby", "warning") end
        local best
        for _, v in pairs(B.simTeam) do if v.better and (not best or (v.at or 0) > (best.at or 0)) then best = v end end
        if not best then return notify("Team", "no better team found yet", "warning") end
        task.spawn(function() HUB.equipTeam(best.uuids, "best team for " .. tostring(best.label) .. " (button)"); notify("Team", "equipped: " .. table.concat(best.names or {}, ", "), "success") end)
    end)
    T:Button("↩️", "Restore My Team", "Put your own team back", function()
        if SF.where ~= "lobby" then return notify("Team", "works in the lobby", "warning") end
        task.spawn(function() notify("Team", HUB.restoreTeam() and "your team is back" or "your own team is already equipped", "success") end)
    end)
    T:Section("Farm or damage")
    GUI.econCard = T:StatusCard({ icon = "💰", title = "Economy", text = "shows during a match", sub = "" })
    tog(T, "Farm Units", "Buy the farm unit and its upgrades while they pay back before the match ends and the defense holds", "farmUnits")
    sld(T, "Farm Waves To Spare", "A farm buy must pay back with at least this many waves left over", "farmSpare", { min = 0, max = 6, step = 1, format = int })
    sld(T, "Safe Road", "Farming is allowed while enemies die before this share of the road (or ¾ of the stretch your units reach, if that's shorter)", "safeReach", { min = 0.15, max = 0.8, step = 0.05, format = pct })
    sld(T, "Safe Kill Time", "... and while your units would kill everything alive within this many seconds", "clearSec", { min = 5, max = 60, step = 5, format = function(v) return math.floor(v) .. "s" end })
    sld(T, "Danger Road", "Past this share of the road (or 90% of the stretch your units reach, if that's shorter): damage only, buy right away", "dangerReach", { min = 0.4, max = 0.95, step = 0.05, format = pct })
    sld(T, "Save Threshold", "Buy an affordable option worth at least this share of the best one instead of saving", "saveRatio", { min = 0, max = 1, step = 0.05, format = pct })
    T:Section("Core")
    tog(T, "Battle AI", "Run placement and upgrades in matches", "battle")
    tog(T, "Auto Place", "Place units where enemies spend the most time in range, further down the road when enemies get past your units", "place")
    tog(T, "Auto Upgrade", "Buy the most damage per yen", "upgrade")
    tog(T, "Auto Abilities", "Buffs (like Windsong's) when the units they buff are fighting; damage abilities for a boss or a crowd", "actives")
    sld(T, "Ability Hold", "A ready damage ability waits up to this long for a boss or a crowd (longer for abilities with a long cooldown)", "abilityHold", { min = 0, max = 60, step = 5, format = function(v) return math.floor(v) .. "s" end })
    tog(T, "Auto Start", "Vote to start once the first unit is down", "autoStart")
    tog(T, "Smart Targeting", "Crowd control and area units hold the front; heavy hitters take the boss while one is alive", "smartTarget")
    T:Button("🧮", "Reset Unit Learning", "Forget measured unit damage", function() table.clear(B.learn); SF.saveNow(); notify("Battle", "learning reset", "success") end)

    T = Win:Tab("🧭", "Path")
    T:Section("Your path to stronger units (best first)")
    GUI.path = T:KeyValue({ "1", "2", "3", "4", "5", "6", "7", "8" }, 150)
    T:Section("Ready now (evolving can't be undone)")
    GUI.readyLabel = T:Label("…")
    tog(T, "Smart Evolve", "Evolve your best copy when it gets stronger, the items it uses aren't needed by a bigger goal, and any copies it uses up are spare (lock a unit in the game to keep it safe)", "smartEvolve")
    local armed = {}
    T:Button("🌟", "Evolve The Top Ready Unit", "Click twice within 5 seconds to confirm", Color3.fromRGB(167, 139, 250), function()
        if SF.where ~= "lobby" then return notify("Evolve", "works in the lobby", "warning") end
        local g
        for _, x in ipairs(B.goals) do if x.ready then g = x; break end end
        if not g then return notify("Evolve", "nothing is ready to evolve", "warning") end
        if not armed[g.uuid] or os.clock() - armed[g.uuid] > 5 then
            armed[g.uuid] = os.clock()
            return notify("Evolve", "click again to evolve " .. UNIT.name(g.from) .. " → " .. UNIT.name(g.to), "warning")
        end
        armed[g.uuid] = nil
        task.spawn(function() local ok, msg = HUB.evolve(g); notify("Evolve", msg, ok and "success" or "error") end)
    end)
    T:Section("Limit break")
    LIVE.lb = T:Paragraph("checked in the lobby…")
    T:Section("Trait rerolls")
    LIVE.traits = T:Paragraph("…")
    T:Section("Settings")
    tog(T, "Farm Toward Goals", "Items your best evolution goals need get a gem value, so the farm goes and gets them", "goals")
    sld(T, "Goal Value", "Gem value of finishing the top goal (spread over the items it still needs)", "goalValue", { min = 0, max = 10000, step = 250, format = int })
    tog(T, "Raid Shop For Goals", "Buy a goal's item in the raid shop once enough raid items are in", "raidShopGoals")

    T = Win:Tab("🧾", "Spending")
    T:Section("Spend history (where your gold, gems and coins went)")
    LIVE.spend = T:Paragraph("…")
    LIVE.lastMatch = T:Label("…")
    T:Section("Free rewards")
    tog(T, "Auto Rewards", "Daily login, finished quests, battle pass, first-clear milestones", "rewards")
    T:Section("Gold shop")
    tog(T, "Star Fruits For Gold", "Buy Star Fruits (evolve material) from the daily gold shop, up to each fruit's cap", "goldShop")
    sld(T, "Gold Floor", "Never spend gold below this", "goldFloor", { min = 0, max = 2000000, step = 50000, format = big })
    T:Section("Summons (off until you switch them on)")
    tog(T, "April Banner (AprilCoins)", "10-pulls while a limited unit is missing (Osaka, Dokuro, Rikka, Chihiro) · Mythic pity 200", "summonApril")
    sld(T, "AprilCoin Floor", "Keep at least this many AprilCoins", "aprilFloor", { min = 0, max = 30000, step = 500, format = big })
    tog(T, "Gem Banner", "10-pulls only while a featured unit would beat your weakest team unit at full upgrade", "summonGems")
    sld(T, "Gem Floor", "Never summon below this many gems", "gemFloor", { min = 0, max = 100000, step = 5000, format = big })
    sld(T, "Summons Per Visit", "At most this many summons per banner per lobby visit", "summonsPerVisit", { min = 10, max = 200, step = 10, format = int })

    T = Win:Tab("📜", "Log")
    tog(T, "Print To Console", "Mirror log lines to the executor console", "logConsole")
    UI.logLevel = T:Dropdown("Log Level", "Quiet · Normal · Verbose", { "Quiet", "Normal", "Verbose" }, (CFG.logLevel or 1) + 1, function(_, _, i) setCfg("logLevel", math.clamp((tonumber(i) or 2) - 1, 0, 2)) end)
    LIVE.log = T:Paragraph("...")
    LIVE.totals = T:Label("...")

    T = Win:Tab("📰", "Updates")
    -- the suggestion box only shows once the script has somewhere to send it
    if C.WEBHOOK_URL ~= "" then
        T:Section("💡 Suggest something for the farm")
        local idea = ""
        local ideaBox = T:Input("Your idea", "Sent anonymously (no Roblox name) · one every 10 min · 500 characters", "e.g. farm the Cursed Womb with my keys…", "", function(text) idea = tostring(text or "") end)
        T:Button("📨", "Send Suggestion", "Goes straight to the script author", function()
            local okG, got = pcall(function() return ideaBox._isProxy and ideaBox:Get() or ideaBox.Get() end)
            if okG and type(got) == "string" and got ~= "" then idea = got end
            task.spawn(function()
                local ok, err = REPORT.suggest(idea)
                notify("Suggestion", ok and "sent — thank you!" or ("not sent: " .. tostring(err)), ok and "success" or "warning")
            end)
        end)
    end
    local TAG_COLOR = { NEW = Color3.fromRGB(74, 222, 128), IMPROVED = Color3.fromRGB(96, 165, 250), FIX = Color3.fromRGB(251, 191, 36) }
    for _, e in ipairs(CHANGELOG) do
        T:Section(string.format("v%s · %s · %s", e.v, e.title, e.date))
        for _, it in ipairs(e.items) do
            T:StatusCard({ icon = it[1], title = it[2], text = it[3], tag = it[4], tagColor = TAG_COLOR[it[4]], color = TAG_COLOR[it[4]] })
        end
    end

    T = Win:Tab("⚙️", "Settings")
    tog(T, "Anti-AFK", "Send an input when Roblox flags you idle", "antiAfk")
    T:Section("Help improve the script")
    if C.WEBHOOK_URL ~= "" then
        UI.shareStats = T:Toggle("Share anonymous stats", "Send match stats so unit scores and mode times improve for everyone (on by default — switch off any time)", CFG.shareStats, function(on)
            if on ~= CFG.shareStats then CFG.shareChosen = true end
            setCfg("shareStats", on)
        end)
        T:Paragraph("What is sent: a random id made on this PC (not your name or user id), the script version, and per match the mode, "
            .. "win or loss, wave and run time, gems and coins earned. Nothing else.")
    else
        T:Paragraph("This version sends nothing anywhere: no stats, no suggestions. Everything it learns stays in the AA_SmartFarm folder on your PC.")
    end
    T:Button("💾", "Save Settings", "Write " .. C.SETTINGS, function() SF.saveNow(); notify("Saved", "settings written", "success") end)
    Win:Status(CFG.master and "▶ Farming" or "⏸ Paused")
    if CFG.seenVersion ~= VERSION then
        local first = CFG.seenVersion == nil
        CFG.seenVersion = VERSION
        SF.saveSoon()
        task.delay(first and 8 or 5, function()
            pcall(function() Win:Notify("Updated to v" .. VERSION, CHANGELOG[1].title .. " — see the 📰 Updates tab for what's new.", 10, "default") end)
        end)
    end
end
GUI.ICONS = { daily = "📅", challenge = "🏆", story = "⚔️", raid = "👹", event = "🃏" }
-- a brain key ("dc", "ch", "st:<level>:<diff>", "rd:<level>", "ev:<level>") as a readable name
function GUI.keyName(key)
    if key == "dc" then return "📅 Daily Challenge" end
    if key == "ch" then return "🏆 Challenge" end
    local kind, id, diff = tostring(key):match("^(%a+):([^:]+):?(%a*)$")
    if not id then return tostring(key) end
    return (({ st = "⚔️ ", rd = "👹 ", ev = "🃏 " })[kind] or "") .. MODE.levelName(id) .. ((diff and diff ~= "") and (" " .. diff) or "")
end
function GUI.plainMode(m)
    return string.format("%s · %.0f%% win · ≈%.0f gems/min", m.label, (m.p or 0) * 100, m.score or 0)
end
function GUI.update()
    local COL = GUI.COL or {}
    local p = C.prof() or {}
    -- Now
    if GUI.nowCard then
        local o
        if not CFG.master then
            o = { icon = "⏸", title = "Paused", text = "Turn Smart Farm on to resume", sub = "", tag = "", progress = false, color = COL.sub }
        elseif SF.where == "match" and MT.ld then
            local label = MODE.levelName(MT.ld.id or "?") .. (MT.ld._difficulty and (" (" .. MT.ld._difficulty .. ")") or "")
            local pr = MT.pressure or 0
            local why = (B.pending and B.pending.key == MT.key and B.pending.label) and "launched by the farm" or "playing this match"
            -- safe / danger against how far your units reach (the same rule the buying uses)
            local d = MT.depth or {}
            local cov = (d.units or 0) > 0 and U.clamp(d.covEnd or 0.6, 0.1, 1) or 0.6
            local danger = d.leak or pr >= math.min(CFG.dangerReach, cov * 0.9)
            local pressured = pr >= math.min(CFG.safeReach, cov * 0.75)
            o = { icon = GUI.ICONS[MT.kind or ""] or "⚔️", title = label, text = tostring(ST.Economy or why),
                sub = string.format("Wave %d/%d · ¥%s · %d enemies · front at %d%% of the road, your units reach %d%% · kills all in %s", MT.wave(), MT.total or 0, U.fmt(MT.money()),
                    #(MT.enemies or {}), math.floor(pr * 100), math.floor(((d.units or 0) > 0 and d.covEnd or 0) * 100),
                    (MT.clearSec or 0) >= 999 and "never" or (math.floor(MT.clearSec or 0) .. "s")),
                tag = d.leak and "LEAK" or (danger and "DANGER" or (pressured and "PRESSURE" or "SAFE")),
                tagColor = danger and COL.red or (pressured and COL.orange or COL.green),
                progress = (MT.total or 0) > 0 and MT.wave() / MT.total or false, color = COL.accent }
        else
            o = { icon = "🏰", title = "In the lobby", text = tostring(ST.Mode or "planning the next run"), sub = tostring(ST.Rewards or ""), tag = "", progress = false, color = COL.accent }
        end
        pcall(GUI.nowCard.Set, o)
        pcall(function() GUI.Win:Status((o.icon or "") .. " " .. tostring(o.title), o.tagColor or o.color) end)
    end
    if GUI.nextCard then
        local top = MODE.lastScored and MODE.lastScored[1]
        if not top and U.now() - (GUI.pickAt or 0) > 15 then GUI.pickAt = U.now(); pcall(MODE.pick); top = MODE.lastScored and MODE.lastScored[1] end
        local lr = B.lastResult
        local got = {}
        if lr then
            if (lr.gems or 0) > 0 then table.insert(got, lr.gems .. " gems") end
            if (lr.coins or 0) > 0 then table.insert(got, lr.coins .. " AprilCoins") end
            for k, n in pairs(lr.items or {}) do table.insert(got, string.format("%s×%s", (C.Items[k] and C.Items[k].name) or k, tostring(n))) end
        end
        pcall(GUI.nextCard.Set, { icon = "⏭", title = "Up next: " .. (top and GUI.plainMode(top) or "deciding…"), text = top and (top.why or "") or "",
            sub = lr and ("Last run: " .. lr.text .. (#got > 0 and (" · " .. table.concat(got, ", ")) or "")) or "",
            tag = lr and (lr.won and "WON" or "LOST") or "", tagColor = lr and (lr.won and COL.green or COL.red) or nil })
    end
    if GUI.goals then
        local g = GUI.goals
        pcall(g.Set, "Gems", U.fmt(p.gem_amount), string.format("gold %s", U.fmt(p.gold_amount)), nil, nil)
        local d = B.live.daily
        local dDone = d and d.uuid and (d.uuid == p.last_completed_daily_challenge_uuid or d.uuid == d.doneUuid)
        pcall(g.Set, "Daily Challenge", dDone and "done ✓" or (d and "ready" or "…"), d and string.format("worth ≈%s gems", U.fmt(d.value or 0)) or "", dDone and COL.green or COL.gold, nil)
        local n = B.live.normal
        local nDone = n and n.uuid and (n.uuid == p.last_completed_challenge_uuid or n.uuid == n.doneUuid)
        local mins = n and n.expires and math.max(0, math.floor((n.expires - os.time()) / 60)) or 0
        pcall(g.Set, "Challenge", nDone and "done ✓" or (n and "open" or "…"), n and string.format("new one in %d min", mins) or "", nDone and COL.green or COL.gold, nil)
        local firsts = 0
        for _, m in ipairs(MODE.lastScored or {}) do if m.first then firsts = firsts + 1 end end
        pcall(g.Set, "First Clears Left", tostring(firsts), "acts you can clear for 60 gems now", firsts > 0 and COL.purple or COL.green, nil)
        pcall(g.Set, "AprilCoins", U.fmt(p.resources and p.resources.AprilCoins or 0), "April banner: 150 a summon", nil, nil)
        pcall(g.Set, "Record", string.format("%d W · %d L", B.totals.wins or 0, B.totals.losses or 0), string.format("+%s gems by the farm", U.fmt(B.totals.gems or 0)), nil, nil)
    end
    if GUI.systems then
        for _, k in ipairs(GUI.SYSTEMS) do
            local v = ST[k]
            local s = tostring(v or "—")
            pcall(GUI.systems.Set, k, s, (s:find("refused") or s:find("error")) and COL.red or (v and COL.text or COL.sub))
        end
    end
    if GUI.rank then
        local list = MODE.lastScored or {}
        for i = 1, 6 do
            local m = list[i]
            if m then pcall(GUI.rank.Set, "#" .. i, GUI.plainMode(m) .. "\n" .. (m.why or ""), i == 1 and COL.green or COL.text)
            else pcall(GUI.rank.Set, "#" .. i, i == 1 and "no ranking yet" or "", COL.sub, i == 1 and "#1" or "") end
        end
    end
    if GUI.records then
        local rows = {}
        for key, r in pairs(B.modes) do if r.runs > 0 then table.insert(rows, { key = key, r = r }) end end
        table.sort(rows, function(a, b) return (a.r.last or 0) > (b.r.last or 0) end)
        for i = 1, 8 do
            local e = rows[i]
            if e then
                local name = e.key == "dc" and "📅 Daily Challenge" or e.key == "ch" and "🏆 Challenge" or MODE.levelName((e.key:match("^%a+:([^:]+)") or e.key)) .. (e.key:match(":(%a+)$") and (" " .. e.key:match(":(%a+)$")) or "")
                pcall(GUI.records.Set, tostring(i), string.format("%d/%d won · %.1f min avg · %d gems", e.r.wins, e.r.runs, e.r.sec / math.max(1, e.r.runs) / 60, e.r.gems), nil, name)
            else
                pcall(GUI.records.Set, tostring(i), "", nil, i == 1 and "no runs yet" or "")
            end
        end
    end
    if GUI.team then
        local team = UNIT.equipped()
        for i = 1, 6 do
            local e = team[i]
            if e then
                local tr, tier = UNIT.trait(e.u)
                local trName = tr and ((C.data("Traits") or {})[tr] or {}).name or "no trait"
                local relic = UNIT.relicName(e.u)
                local txt
                if UNIT.isFarm(e.id) then
                    txt = string.format("farm unit · ¥%s a wave at full upgrade · %s%s", U.fmt(UNIT.farm(e.u, UNIT.rows(e.id).max)), trName, tier and tier ~= "1" and (" " .. tier) or "")
                else
                    local types, base = UNIT.types(e.id)
                    local el = {}
                    for t in pairs(types) do if t ~= base then table.insert(el, (t:gsub("_damage", ""))) end end
                    txt = string.format("score %s · %s · up to %d on the field · %s%s%s", U.fmt(UNIT.score(e.u, MT.mod)), trName .. (tier and tier ~= "1" and (" " .. tier) or ""),
                        UNIT.cap(e.u), base, #el > 0 and ("+" .. table.concat(el, "/")) or "", relic and (" · relic: " .. relic) or "")
                end
                pcall(GUI.team.Set, tostring(i), txt, nil, UNIT.name(e.id))
            else
                pcall(GUI.team.Set, tostring(i), "", nil, "")
            end
        end
    end
    if GUI.sim then
        local top = MODE.lastScored and MODE.lastScored[1]
        local sr = top and B.simRes[top.key]
        pcall(GUI.sim.Set, "Next mode", top and (top.label .. ": " .. (sr and sr.margin or (sr and sr.none and "can't simulate this one yet") or "not simulated yet")) or "—")
        local key, plan
        for k, v in pairs(B.simTeam) do if not plan or (v.at or 0) > (plan.at or 0) then key, plan = k, v end end
        local yr = plan and B.simRes[key]
        pcall(GUI.sim.Set, "Your team", plan and string.format("%s: %s", plan.label or key, yr and yr.margin or (plan.cur.won and "wins" or ("reaches wave " .. tostring(plan.cur.wave)))) or "the planner runs in the lobby")
        pcall(GUI.sim.Set, "Best team", plan and (table.concat(plan.names or {}, ", ") .. (plan.better and (" → " .. (plan.won and "wins" or ("reaches wave " .. tostring(plan.wave)))) or " (your team is already the best the sim found)")) or "—")
        local evo = {}
        for _, e in ipairs(B.simEvo or {}) do
            table.insert(evo, string.format("%s → %s: %s%s", e.from, e.to, e.gain, e.ready and " · ready" or (e.missing and (" · needs " .. e.missing) or "")))
        end
        pcall(GUI.sim.Set, "Evolutions", #evo > 0 and table.concat(evo, "\n") or "none ready (planner runs in the lobby)")
        local acc = {}
        for k, c in pairs(B.simCal) do
            local lp = c.lastPred
            if lp then table.insert(acc, string.format("%s: predicted %s (wave %d) · real %s (wave %d)", GUI.keyName(k), lp.won and "win" or "loss", lp.wave or 0, lp.realWon and "win" or "loss", lp.realWave or 0)) end
        end
        pcall(GUI.sim.Set, "Accuracy", #acc > 0 and table.concat(acc, "\n") or "no predicted run yet")
    end
    if GUI.path then
        for i = 1, 8 do
            local g = B.goals[i]
            if g then
                pcall(GUI.path.Set, tostring(i), g.text, g.ready and COL.green or (g.intoTeam and COL.purple or (g.unknown and COL.sub or COL.text)), UNIT.name(g.to))
            else
                pcall(GUI.path.Set, tostring(i), i == 1 and "goals are worked out in the lobby" or "", COL.sub, i == 1 and "—" or "")
            end
        end
        local ready = {}
        for _, g in ipairs(B.goals) do if g.ready then table.insert(ready, UNIT.name(g.from) .. " → " .. UNIT.name(g.to)) end end
        if GUI.readyLabel then pcall(GUI.readyLabel.Set, #ready > 0 and ("Ready: " .. table.concat(ready, " · ")) or "Nothing ready yet — the farm is collecting the items") end
    end
    local LIVEp = GUI.LIVE
    if LIVEp.lb then pcall(LIVEp.lb.Set, ADV.lbText()) end
    if LIVEp.traits then pcall(LIVEp.traits.Set, ADV.traitText()) end
    if GUI.econCard and SF.where == "match" then
        pcall(GUI.econCard.Set, { icon = "💰", title = string.format("¥%s now · farm ¥%s a wave", U.fmt(MT.money()), U.fmt(MT.farmNow or 0)),
            text = tostring(ST.Economy or ""), sub = string.format("coming yen ≈%s · still to buy ≈%s", U.fmt(MT.future or 0), U.fmt(MT.wantLeft or 0)) })
    end
    local LIVE = GUI.LIVE
    if LIVE.spend then pcall(LIVE.spend.Set, SPEND.text()) end
    if LIVE.lastMatch then
        local lm = B.lastMatch
        pcall(LIVE.lastMatch.Set, lm and string.format("Last match (%s): ¥%s spent on %d buys · %d refused spots", lm.label, U.fmt(lm.spent), lm.actions or 0, lm.refusals or 0) or "no match yet")
    end
    if LIVE.log then pcall(LIVE.log.Set, table.concat({ table.unpack(LOG.lines, math.max(1, #LOG.lines - 14)) }, "\n")) end
    if LIVE.totals then pcall(LIVE.totals.Set, string.format("matches %d · wins %d · losses %d · gems %s · AprilCoins %s", B.totals.matches or 0, B.totals.wins or 0, B.totals.losses or 0, U.fmt(B.totals.gems or 0), U.fmt(B.totals.coins or 0))) end
end
function GUI.loop()
    while SF.alive do
        pcall(GUI.update)
        task.wait(1)
    end
end

-- ============================================================
--  START / UNLOAD / HOT RELOAD
-- ============================================================
table.insert(SF.conns, LP.Idled:Connect(function()
    if not CFG.antiAfk then return end
    pcall(function()
        local vu = game:GetService("VirtualUser")
        vu:CaptureController(); vu:ClickButton2(Vector2.new())
    end)
end))
function SF.cleanup()
    for _, c in ipairs(SF.conns) do pcall(function() c:Disconnect() end) end
    pcall(function() GUI.Win:Destroy() end)
    pcall(function() if MT.probe then MT.probe:Destroy() end end)
    pcall(function() if MT.bounds then MT.bounds:Destroy() end end)
end
function SF.unload()
    SF.alive = false
    SF.saveNow()
    SF.cleanup()
    _G.AA_SF = nil
end
-- an older copy (e.g. from a hot reload) stops itself as soon as a newer one owns _G.AA_SF
task.spawn(function()
    while SF.alive do
        task.wait(1)
        if _G.AA_SF ~= SF then SF.alive = false; SF.cleanup() end
    end
end)
-- keep running across lobby <-> match teleports: local copy first (your own edits), else the public repo
pcall(function()
    if queue_on_teleport and not _G.AA_SF_QUEUED then
        _G.AA_SF_QUEUED = true
        queue_on_teleport("task.wait(0.5) local s if isfile and isfile('" .. C.SELF .. "') then s=readfile('" .. C.SELF .. "') end "
            .. "if not s then local ok,r=pcall(game.HttpGet,game,'" .. C.SELF_URL .. "') if ok then s=r end end "
            .. "if s then loadstring(s,'=AA_SmartFarm')() end")
    end
end)

SF.C, SF.B, SF.CFG, SF.MT, SF.HUB, SF.ST, SF.UNIT, SF.MODE = C, B, CFG, MT, HUB, ST, UNIT, MODE -- for live inspection
SF.SIM, SF.ECON, SF.GUI = SIM, ECON, GUI
SF.version = VERSION
task.spawn(GUI.build)
task.spawn(function() task.wait(2); GUI.loop() end)
SF.log(1, "INFO", "Smart Farm v" .. VERSION .. " started in the " .. SF.where .. " (copy " .. SF.loadId .. ")")
print("[AA SF] v" .. VERSION .. " loaded in the " .. SF.where .. " · copy " .. SF.loadId)
SF.status("Mode", "starting in the " .. SF.where)
task.spawn(function()
    local ok, e = pcall(SF.where == "match" and MT.run or HUB.run)
    if not ok then SF.log(0, "FATAL", tostring(e)); warn("[AA] " .. tostring(e)) end
end)
