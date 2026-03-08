-- ============================================================
--   CATCH & TAME  |  ADVANCED OPERATION SCRIPT v2.0
--   Version  : 2.0.0
--   Executor : Xeno (UNC compatible)
--   PlaceId  : 96645548064314
--   Author   : ENI
--   Load via : XenoScanner v4.2 Bootstrap
-- ============================================================
-- CHANGELOG
--   v2.0.0  Full rewrite -- see enhancement plan
--     + Weather monitor system with event detection and countdown
--     + Auto Fruit Collect (Volcanic / Cosmic fruits)
--     + Priority catch queue (ranked rarity, stops on first match)
--     + Mutation detection and filter (catch mutated only)
--     + Auto Sell pets and eggs by rarity threshold
--     + Smart Breed (recipe pair scanner, rarity match)
--     + Pet name blacklist and whitelist
--     + Session analytics (catches/hr, success rate, income/sec)
--     + ESP rarity color coding and mutation badges
--     + Lazy remote cache with DescendantAdded watcher
--     + Catch confirmation via inventory count delta
--     + Extended namecall hook captures ALL remote signatures
--     + Anti-detection: jitter on all timers, per-remote cooldown map
--     + Human Mode toggle for randomized action delays
--     + Lateral teleport approach vector (no hitbox clipping)
--     + Rarity filter actually connected to catch logic
--     + Minigame signature validates win before caching
--     + FeedAllPets skips non-table metadata keys
--     + Session stats track confirmed catches only
--     ! FIX: All characters are plain ASCII (no em dashes, Unicode, etc.)
-- ============================================================

print("[CAT] Catch & Tame v2.0.0 loading...")

-- ============================================================
-- S0  CONSTANTS
-- ============================================================

local VERSION       = "2.0.0"
local SCRIPT_NAME   = "Catch & Tame"
local PLACE_ID      = 96645548064314
local RAYFIELD_URL  = "https://sirius.menu/rayfield"

-- Rarity tier definitions (name match patterns -> tier value)
-- Higher tier = higher priority
local RARITY_TIERS = {
    ["Secret"]      = 8,
    ["Exclusive"]   = 7,
    ["Mythical"]    = 6,
    ["Legendary"]   = 5,
    ["Epic"]        = 4,
    ["Rare"]        = 3,
    ["Uncommon"]    = 2,
    ["Common"]      = 1,
}

-- Rarity tier -> ESP color (RGB)
local RARITY_COLORS = {
    [8] = Color3.fromRGB(255, 30,  30),   -- Secret      : red
    [7] = Color3.fromRGB(255, 140, 0),    -- Exclusive   : orange
    [6] = Color3.fromRGB(180, 0,   255),  -- Mythical    : purple
    [5] = Color3.fromRGB(255, 210, 0),    -- Legendary   : gold
    [4] = Color3.fromRGB(180, 60,  255),  -- Epic        : violet
    [3] = Color3.fromRGB(60,  120, 255),  -- Rare        : blue
    [2] = Color3.fromRGB(60,  200, 80),   -- Uncommon    : green
    [1] = Color3.fromRGB(200, 200, 200),  -- Common      : grey
}

-- Mutation keywords to detect in pet model
local MUTATION_KEYWORDS = {
    "Cosmic", "Volcanic", "Shocked", "Frozen",
    "Charged", "Toxic", "Shadow", "Radiant",
    "Crystal", "Infernal", "Spectral", "Gilded",
}

-- Weather states the game cycles through
local WEATHER_NAMES = {
    "Clear", "Rainy", "Thunderstorm", "Sandstorm",
    "Blizzard", "Snowy", "Cosmic", "Volcanic",
    "Foggy", "Windy",
}

-- Weather -> mythical pets that spawn in it
local WEATHER_PETS = {
    ["Thunderstorm"] = {"Lightning Dragon"},
    ["Sandstorm"]    = {"Griffin", "Basilisk"},
    ["Cosmic"]       = {"Cosmic Griffin"},
    ["Blizzard"]     = {"Frost Dragon", "Yeti"},
    ["Volcanic"]     = {"Lava Golem", "Phoenix"},
}

-- Skeleton event interval (seconds)
local SKELETON_INTERVAL = 3600  -- every 60 minutes
local SKELETON_DURATION = 1200  -- lasts 20 minutes

-- Per-remote fire cooldowns in seconds (mirrors known server limits)
local REMOTE_COOLDOWNS = {
    UpdateProgress     = 0.08,  -- minigame complete: FireServer(100) [RemoteEvent]
    minigameRequest    = 0.5,   -- legacy fallback [RemoteFunction]
    extendFence        = 1.0,
    getEggInventory    = 0.5,
    GetActiveWeather   = 2.0,
    CancelMinigame     = 0.5,
    ThrowLasso         = 0.4,
    collectAllPetCash  = 2.0,
    FeedPet            = 0.15,
    BuyFood            = 1.0,
    InstantHatch       = 1.0,
    breedRequest       = 2.0,
    ClaimLoginReward   = 1.0,
    UseSpin            = 0.5,
    UseTotem           = 1.0,
    sellPet            = 0.2,
    sellEgg            = 0.2,
    redeemCode         = 1.0,
}

-- ============================================================
-- S1  EXECUTOR DETECTION
-- ============================================================

local IS_XENO = false
do
    local name = ""
    if identifyexecutor then name = identifyexecutor():lower()
    elseif getexecutorname then name = getexecutorname():lower() end
    IS_XENO = name:find("xeno") ~= nil or (typeof(Xeno) == "table")
end
local EXECUTOR_NAME = (identifyexecutor and identifyexecutor())
                   or (getexecutorname and getexecutorname())
                   or "Unknown"

-- ============================================================
-- S2  UNC SHIMS
-- ============================================================

if not cloneref        then cloneref        = function(o) return o end end
if not getnilinstances then getnilinstances  = function() return {} end end
if not getinstances    then getinstances    = function() return {} end end
if not newcclosure     then newcclosure     = function(f) return f end end
if not checkcaller     then checkcaller     = function() return false end end
if not getrawmetatable then getrawmetatable = function() return nil end end
if not iscclosure      then iscclosure      = function() return false end end
if not getconnections  then getconnections  = function() return {} end end

-- ============================================================
-- S3  CLEANUP + SESSION TOKEN
-- ============================================================

if getgenv then getgenv().SecureMode = true end

local SESSION_TOKEN = tostring(tick()) .. "_" .. tostring(math.random(1, 999999))

do
    if getgenv then
        if getgenv().CAT_SESSION then
            getgenv().CAT_RUNNING = false
            task.wait(0.4)
        end
        getgenv().CAT_SESSION = SESSION_TOKEN
        getgenv().CAT_RUNNING = true
    end

    local function DestroyGui(parent)
        if not parent then return end
        for _, n in ipairs({"CATScript_Rayfield", "Rayfield"}) do
            local g = parent:FindFirstChild(n)
            if g then pcall(function() g:Destroy() end) end
        end
    end

    local cgOk, cg = pcall(function() return cloneref(game:GetService("CoreGui")) end)
    if cgOk then DestroyGui(cg) end

    local lpOk, lp = pcall(function()
        return cloneref(game:GetService("Players")).LocalPlayer
    end)
    if lpOk and lp then
        local pg = lp:FindFirstChild("PlayerGui")
        if pg then DestroyGui(pg) end
    end
end

-- ============================================================
-- S4  SERVICES
-- ============================================================

local Players           = cloneref(game:GetService("Players"))
local ReplicatedStorage = cloneref(game:GetService("ReplicatedStorage"))
local RunService        = cloneref(game:GetService("RunService"))
local TweenService      = cloneref(game:GetService("TweenService"))
local UserInputService  = cloneref(game:GetService("UserInputService"))
local VirtualUser       = cloneref(game:GetService("VirtualUser"))
local CoreGui           = cloneref(game:GetService("CoreGui"))
local Workspace         = cloneref(game:GetService("Workspace"))
local MarketplaceService = cloneref(game:GetService("MarketplaceService"))

-- ============================================================
-- S5  PLAYER REFERENCES
-- ============================================================

local Player = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local function GetChar()    return Player.Character end
local function GetRoot()    local c = GetChar(); return c and c:FindFirstChild("HumanoidRootPart") end
local function GetHumanoid() local c = GetChar(); return c and c:FindFirstChildOfClass("Humanoid") end

-- ============================================================
-- S6  CONFIGURATION TABLE
-- ============================================================

local CFG = {
    -- Auto Farm
    AutoFarm          = false,
    FarmDelay         = 1.5,
    AutoPlacePet      = true,
    TameAll           = false,     -- fire tame sequence at every pet in registry
    TameAllStagger    = 0.08,      -- seconds between each spawned tame thread
    TameAllDelay      = 5.0,       -- loop interval when TameAll toggle is on
    RarityFilter      = "All",       -- minimum rarity to catch
    PriorityOrder     = {            -- priority queue: highest-value first
        "Secret", "Exclusive", "Mythical", "Legendary",
        "Epic", "Rare", "Uncommon", "Common"
    },
    MutationOnly      = false,       -- catch only mutated pets
    MaxCatchPerMin    = 30,          -- anti-detection cap
    HumanMode         = false,       -- randomized action delays

    -- Blacklist / Whitelist
    Blacklist         = {},          -- pet names to skip
    Whitelist         = {},          -- pet names to always catch (overrides rarity filter)

    -- Economy
    AutoCollect       = false,
    CollectInterval   = 30,
    AutoBuyFood       = false,
    AutoFeedPets      = false,
    FeedInterval      = 60,
    AutoSellPets      = false,
    SellBelowRarity   = "Uncommon",  -- sell pets below this rarity
    AutoSellEggs      = false,
    SellEggThreshold  = 5,           -- sell if same egg type > this count

    -- Eggs & Breeding
    AutoHatch         = false,
    HatchInterval     = 10,
    AutoBreed         = false,
    BreedDelay        = 5.0,
    SmartBreed        = false,       -- scan pen for valid recipe pairs
    BreedRarityMatch  = false,       -- pair same-rarity pets

    -- Events & Weather
    AutoTotem         = false,       -- use totem when target weather not active
    TargetWeather     = "Thunderstorm",
    AutoFruitCollect  = false,       -- teleport to and grab fruits
    FruitTypes        = {"Volcanic", "Cosmic"},
    SkeletonAlert     = false,       -- notify when skeleton event is near

    -- ESP
    ESPEnabled        = false,
    ESPColor          = Color3.fromRGB(255, 80, 80),
    ESPRarityColors   = true,        -- override with per-rarity color
    HighlightNearest  = false,
    ShowMutationBadge = true,
    ESPMutationOnly   = false,       -- show only mutated pets in ESP

    -- Utility
    WalkSpeed         = 16,
    JumpPower         = 50,
    InfiniteJump      = false,
    AntiAFK           = false,

    -- Rewards
    AutoClaimLogin    = false,
    AutoClaimIndex    = false,
    AutoSpin          = false,
}

-- ============================================================
-- S7  STATE TABLE
-- ============================================================

local ST = {
    Running       = true,

    -- Connections (named dictionary)
    Connections   = {},

    -- ESP
    ESPObjects    = {},

    -- Pet registry: model -> { tier, mutation, name }
    PetRegistry   = {},

    -- Remote signature map (built by namecall hook)
    RemoteSigs    = {},

    -- Remote last-fire timestamps for cooldown enforcement
    RemoteLastFire = {},

    -- Minigame
    MinigameSig   = nil,
    MinigameSigValidated = false,

    -- Hook
    HookActive    = false,
    OldNamecall   = nil,

    -- Status labels (set after GUI builds)
    StatusLabels  = {},

    -- Session stats
    Stats = {
        CatchAttempts = 0,
        CatchConfirmed = 0,
        SessionStart  = tick(),
        LastBestPet   = "None",
        LastBestTier  = 0,
        IncomeLog     = {},    -- {time, amount} for income/sec calc
    },

    -- Weather
    Weather = {
        Current   = "Unknown",
        StartTime = 0,
        Duration  = 600,    -- seconds, default assumption
        EventActive = false,
    },

    -- Skeleton event
    Skeleton = {
        LastSeen   = 0,
        NextEst    = 0,
        IsActive   = false,
    },

    -- Fruit tracking
    FruitRegistry = {},

    -- Nearest pet cache
    NearestPet = nil,

    -- Catches this minute (anti-detection)
    CatchesThisMin  = 0,
    CatchMinReset   = tick(),

    -- Rayfield ref
    RayfieldReady = false,
    NotifyQueue   = {},
}

-- ============================================================
-- S8  REMOTE CACHE (lazy + DescendantAdded watcher)
-- ============================================================

local REM = {}

local WANTED_REMOTES = {
    "ThrowLasso", "UpdateProgress", "minigameRequest", "pickupRequest",
    "RequestPlacePet", "RunPet", "MovePets",
    "collectAllPetCash", "collectPetCash", "BuyFood",
    "FeedPet", "getOfflineCash",
    "InstantHatch", "breedRequest", "placeEgg",
    "RequestEggHatch", "GetReadyToHatchEggs", "GetAllPenEggTimes",
    "getEggInventory",
    "extendFence", "getFenceStats",
    "ClaimFeepEgg", "CancelMinigame",
    "GetActiveWeather", "GetWeatherList",
    "RequestEggNurseryPlacement",
    "RequestEggNurseryRetrieval",
    "BuyLasso", "EquipLasso", "equipLassoVisual",
    "AttemptUpgradeFarm", "AttemptSwapPet",
    "GetFarmLevel", "GetPetInventoryData",
    "RequestWalkPet",
    "retrieveData", "getPetInventory", "getPetRev",
    "getPlayerIndex", "getSaveInfo",
    "ClaimLoginReward", "ClaimIndex", "ClaimExclusive",
    "UseSpin", "UseTotem", "superLuckSpins",
    "redeemCode", "processTraitMachine",
    "sellPet", "sellEgg", "toggleFavorite",
    "SendTradeRequest", "AcceptTradeRequest",
    "RequestSetOffer", "RequestAccept", "RequestUnaccept",
    "BuyMerchant", "RequestMerchant",
    "updateHotbarSlots", "ClientReady",
    -- weather / events
    "RequestWeather", "GetWeatherState", "RequestTotem",
    "CollectFruit", "PickupFruit",
    -- sell (scanner confirmed: only sellPet + sellEgg exist)
    -- breed
    "BreedPets", "GetBreedRecipes",
}

local WANTED_SET = {}
for _, n in ipairs(WANTED_REMOTES) do WANTED_SET[n] = true end

local function TryCacheObject(obj)
    if not obj then return end
    if obj:IsA("RemoteEvent") or obj:IsA("RemoteFunction") then
        if WANTED_SET[obj.Name] and not REM[obj.Name] then
            REM[obj.Name] = obj
        end
    end
end

local function CacheRemotes()
    for _, obj in ipairs(game:GetDescendants()) do
        TryCacheObject(obj)
    end
    for _, obj in ipairs(getnilinstances()) do
        TryCacheObject(obj)
    end
end

CacheRemotes()

-- Watcher: cache remotes as they appear after ClientReady
ST.Connections.RemoteWatcher = game.DescendantAdded:Connect(function(obj)
    task.defer(function() TryCacheObject(obj) end)
end)

-- ============================================================
-- S9  UTILITY FUNCTIONS
-- ============================================================

-- Jitter: returns delay with optional human-mode randomness
local function Jitter(base, factor)
    factor = factor or 0.15
    local j = base * factor * math.random()
    if CFG.HumanMode then
        j = j + 0.5 + math.random() * 1.5
    end
    return base + j
end

-- Per-remote cooldown gate
local function CanFire(remoteName)
    local cd = REMOTE_COOLDOWNS[remoteName]
    if not cd then return true end
    local last = ST.RemoteLastFire[remoteName] or 0
    return (tick() - last) >= cd
end

local function MarkFired(remoteName)
    ST.RemoteLastFire[remoteName] = tick()
end

-- Safe fire with cooldown and vararg packing
local function SafeFire(remote, ...)
    local args = {...}
    if not remote then return false end
    if not CanFire(remote.Name) then return false end
    MarkFired(remote.Name)
    local ok = pcall(function()
        remote:FireServer(table.unpack(args))
    end)
    return ok
end

local function SafeInvoke(remote, ...)
    local args = {...}
    if not remote then return nil end
    if not CanFire(remote.Name) then return nil end
    MarkFired(remote.Name)
    local ok, result = pcall(function()
        return remote:InvokeServer(table.unpack(args))
    end)
    return ok and result or nil
end

local function SafeCall(remote, ...)
    local args = {...}
    if not remote then return nil end
    if remote:IsA("RemoteFunction") then
        return SafeInvoke(remote, table.unpack(args))
    else
        return SafeFire(remote, table.unpack(args))
    end
end

local function GetDistance(a, b)
    if not a or not b then return math.huge end
    return (a - b).Magnitude
end

-- Lateral approach: 6 studs behind the target, not inside it
local function LateralApproachCFrame(targetPos)
    local root = GetRoot()
    if not root then
        return CFrame.new(targetPos + Vector3.new(0, 3, 6))
    end
    local dir = (root.Position - targetPos)
    if dir.Magnitude < 0.1 then
        dir = Vector3.new(0, 0, 1)
    end
    dir = dir.Unit
    local approach = targetPos + dir * 6 + Vector3.new(0, 3, 0)
    return CFrame.new(approach, targetPos + Vector3.new(0, 1.5, 0))
end

local function TeleportTo(position, offset)
    local root = GetRoot()
    if not root then return end
    root.CFrame = CFrame.new(position + (offset or Vector3.new(0, 3, 0)))
end

local function TeleportLateral(targetPos)
    local root = GetRoot()
    if not root then return end
    root.CFrame = LateralApproachCFrame(targetPos)
end

-- Returns tier integer for a rarity string, 0 if unknown
local function GetTierFromString(rarityStr)
    if not rarityStr then return 0 end
    for keyword, tier in pairs(RARITY_TIERS) do
        if rarityStr:lower():find(keyword:lower()) then
            return tier
        end
    end
    return 0
end

-- Extract rarity tier from a pet model
local function GetPetTier(model)
    -- Check attributes
    local attr = model:GetAttribute("Rarity")
            or model:GetAttribute("rarity")
            or model:GetAttribute("PetRarity")
    if attr then return GetTierFromString(tostring(attr)) end

    -- Check StringValues
    for _, child in ipairs(model:GetDescendants()) do
        if child:IsA("StringValue") then
            local n = child.Name:lower()
            if n == "rarity" or n == "petrarity" or n == "tier" then
                return GetTierFromString(child.Value)
            end
        end
    end

    -- Infer from model name
    return GetTierFromString(model.Name)
end

-- Extract mutation from a pet model, returns string or nil
local function GetPetMutation(model)
    -- Check attribute
    local attr = model:GetAttribute("Mutation")
            or model:GetAttribute("mutation")
            or model:GetAttribute("Trait")
    if attr and tostring(attr) ~= "" and tostring(attr) ~= "None" then
        return tostring(attr)
    end

    -- Check StringValues
    for _, child in ipairs(model:GetDescendants()) do
        if child:IsA("StringValue") then
            local n = child.Name:lower()
            if n == "mutation" or n == "trait" or n == "type" then
                if child.Value and child.Value ~= "" and child.Value ~= "None" then
                    return child.Value
                end
            end
        end
    end

    -- Infer from model name
    for _, kw in ipairs(MUTATION_KEYWORDS) do
        if model.Name:find(kw) then
            return kw
        end
    end

    return nil
end

-- Is pet name in blacklist?
local function IsBlacklisted(name)
    for _, n in ipairs(CFG.Blacklist) do
        if n:lower() == name:lower() then return true end
    end
    return false
end

-- Is pet name in whitelist?
local function IsWhitelisted(name)
    for _, n in ipairs(CFG.Whitelist) do
        if n:lower() == name:lower() then return true end
    end
    return false
end

-- Format seconds as mm:ss
local function FormatTime(secs)
    secs = math.max(0, math.floor(secs))
    return string.format("%d:%02d", math.floor(secs / 60), secs % 60)
end

-- Format a rate per-hour from a per-second rate
local function FormatRate(perSec)
    if perSec < 1 then
        return string.format("%.1f/min", perSec * 60)
    end
    return string.format("%.1f/hr", perSec * 3600)
end

-- Resilient label updater
local function UpdateLabel(label, text, icon)
    if not label then return end
    for _, m in ipairs({"Set", "Update", "Refresh"}) do
        if typeof(label[m]) == "function" then
            if pcall(label[m], label, text, icon) then return end
        end
    end
    pcall(function() label.Text = text end)
end

-- Notify helper (queues if Rayfield not ready)
local function Notify(title, content, duration, icon)
    local payload = {
        Title    = tostring(title),
        Content  = tostring(content),
        Duration = duration or 4,
        Image    = icon or "info",
    }
    if ST.RayfieldReady and _G.CATRayfield then
        pcall(function() _G.CATRayfield:Notify(payload) end)
    else
        table.insert(ST.NotifyQueue, payload)
    end
end

-- Get current inventory count (for catch confirmation)
local function GetInventoryCount()
    local inv = SafeInvoke(REM.getPetInventory)
    if type(inv) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(inv) do n = n + 1 end
    return n
end

-- ============================================================
-- S10  PET REGISTRY (event-driven, with rarity + mutation)
-- ============================================================

local function BuildPetEntry(model)
    local anchor = model:FindFirstChild("Root")
               or model:FindFirstChild("HumanoidRootPart")
               or model:FindFirstChild("PrimaryPart")
    if not anchor then return nil end

    return {
        model    = model,
        anchor   = anchor,
        name     = model.Name,
        tier     = GetPetTier(model),
        mutation = GetPetMutation(model),
    }
end

local function RegisterPet(model)
    if not model or not model:IsA("Model") then return end
    if ST.PetRegistry[model] then return end
    local entry = BuildPetEntry(model)
    if not entry then return end
    ST.PetRegistry[model] = entry

    if CFG.ESPEnabled then
        task.defer(function()
            if _G.CAT_CreateESP then _G.CAT_CreateESP(model) end
        end)
    end
end

local function UnregisterPet(model)
    local entry = ST.PetRegistry[model]
    ST.PetRegistry[model] = nil
    if entry then
        local obj = ST.ESPObjects[model]
        if obj then
            if obj.ancestryConn then pcall(function() obj.ancestryConn:Disconnect() end) end
            pcall(function() obj.gui:Destroy() end)
            ST.ESPObjects[model] = nil
        end
    end
end

local PetContainer = Workspace:WaitForChild("RoamingPets", 15)
local PetsFolder   = PetContainer and PetContainer:WaitForChild("Pets", 15)
local FruitsFolder = nil
pcall(function()
    FruitsFolder = Workspace:WaitForChild("Fruits", 5)
            or Workspace:WaitForChild("WorldItems", 5)
end)

if PetsFolder then
    for _, m in ipairs(PetsFolder:GetChildren()) do RegisterPet(m) end
    ST.Connections.PetAdded = PetsFolder.ChildAdded:Connect(function(child)
        task.wait(0.12)
        RegisterPet(child)
    end)
    ST.Connections.PetRemoved = PetsFolder.ChildRemoved:Connect(function(child)
        UnregisterPet(child)
    end)
end

-- ============================================================
-- S11  NAMECALL HOOK (captures ALL remote signatures)
-- ============================================================

local function InstallHook()
    if ST.HookActive then return end
    if not hookmetamethod then return end
    if not getrawmetatable then return end

    local mt = getrawmetatable(game)
    if not mt then return end

    local originalNC
    local ok, val = pcall(rawget, mt, "__namecall")
    if ok and typeof(val) == "function" then
        originalNC = val
    end

    local candidate = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        local args   = {...}
        local method = (getnamecallmethod and getnamecallmethod()) or ""

        -- Capture minigame signature
        if method == "InvokeServer"
        and (self == REM.minigameRequest or self == REM.UpdateProgress)
        and not checkcaller()
        and not ST.MinigameSigValidated then
            ST.MinigameSig = args
            -- Validated flag set after we confirm a catch works
        end

        -- Passive signature map for all remotes
        if (method == "FireServer" or method == "InvokeServer")
        and not checkcaller() then
            local rname = pcall(function() return self.Name end) and self.Name or nil
            if rname and WANTED_SET[rname] and not ST.RemoteSigs[rname] then
                ST.RemoteSigs[rname] = args
            end
        end

        local passthrough = ST.OldNamecall or originalNC
        if passthrough then
            return passthrough(self, table.unpack(args))
        end
    end))

    ST.OldNamecall = candidate or originalNC
    ST.HookActive  = (ST.OldNamecall ~= nil)
end

-- ============================================================
-- S12  WEATHER SYSTEM
-- ============================================================

local function DetectWeather()
    -- Try attribute on Workspace or a dedicated WeatherModule
    local attr = Workspace:GetAttribute("Weather")
            or Workspace:GetAttribute("CurrentWeather")
            or Workspace:GetAttribute("WeatherState")
    if attr then
        ST.Weather.Current = tostring(attr)
        return
    end

    -- Try a value object commonly named WeatherState or CurrentWeather
    local vo = Workspace:FindFirstChild("WeatherState")
           or Workspace:FindFirstChild("CurrentWeather")
           or ReplicatedStorage:FindFirstChild("WeatherState")
    if vo and (vo:IsA("StringValue") or vo:IsA("IntValue")) then
        ST.Weather.Current = tostring(vo.Value)
        return
    end

    -- GetActiveWeather is the confirmed remote (scanner-verified)
    local weatherResult = SafeInvoke(REM.GetActiveWeather)
                       or SafeInvoke(REM.GetWeatherState)
    if type(weatherResult) == "string" then
        ST.Weather.Current = weatherResult
        return
    end
    if type(weatherResult) == "table" then
        ST.Weather.Current = weatherResult.weather
                          or weatherResult.name
                          or weatherResult.current
                          or (type(weatherResult[1]) == "string" and weatherResult[1])
                          or "Unknown"
        return
    end
end

local function GetWeatherPetsForCurrent()
    return WEATHER_PETS[ST.Weather.Current] or {}
end

local function UseWeatherTotem()
    if not CFG.AutoTotem then return end
    if ST.Weather.Current == CFG.TargetWeather then return end
    SafeFire(REM.UseTotem, CFG.TargetWeather)
    task.wait(0.3)
    SafeFire(REM.RequestTotem, CFG.TargetWeather)
    Notify("Weather", "Totem fired for: " .. CFG.TargetWeather, 4, "cloud-lightning")
end

-- ============================================================
-- S13  PRIORITY CATCH LOGIC
-- ============================================================

-- Returns the priority tier of a rarity filter string
local function FilterTier()
    return RARITY_TIERS[CFG.RarityFilter] or 0
end

-- Score a pet entry: returns a sort score (higher = higher priority)
local function ScorePetEntry(entry)
    if not entry then return -1 end

    -- Blacklist check
    if IsBlacklisted(entry.name) then return -1 end

    -- Mutation-only filter
    if CFG.MutationOnly and not entry.mutation then return -1 end

    -- Whitelist overrides rarity filter but not blacklist
    if IsWhitelisted(entry.name) then return 1000 + entry.tier end

    -- Rarity filter gate
    if entry.tier < FilterTier() then return -1 end

    -- Priority score = tier * 100 + mutation bonus
    local score = entry.tier * 100
    if entry.mutation then score = score + 50 end

    return score
end

-- Finds the highest-priority pet in range
local function FindBestPet()
    local root = GetRoot()
    if not root then return nil, math.huge end

    local bestEntry, bestScore, bestDist = nil, -1, math.huge
    local stale = {}

    for model, entry in pairs(ST.PetRegistry) do
        if model and model.Parent then
            local anchor = entry.anchor
            if anchor and anchor.Parent then
                local score = ScorePetEntry(entry)
                if score >= 0 then
                    local d = GetDistance(root.Position, anchor.Position)
                    -- Compare by score first, then distance as tiebreak
                    if score > bestScore
                    or (score == bestScore and d < bestDist) then
                        bestEntry = entry
                        bestScore = score
                        bestDist  = d
                    end
                end
            end
        else
            stale[#stale + 1] = model
        end
    end

    for _, m in ipairs(stale) do ST.PetRegistry[m] = nil end

    return bestEntry, bestDist
end

-- ============================================================
-- S14  FRUIT COLLECTION
-- ============================================================

local function ScanFruits()
    ST.FruitRegistry = {}
    local scanTargets = {Workspace}
    if FruitsFolder then table.insert(scanTargets, FruitsFolder) end

    for _, container in ipairs(scanTargets) do
        for _, obj in ipairs(container:GetDescendants()) do
            local isFruit = false
            for _, ft in ipairs(CFG.FruitTypes) do
                if obj.Name:find(ft) then
                    isFruit = true
                    break
                end
            end
            if isFruit and (obj:IsA("Model") or obj:IsA("Part") or obj:IsA("MeshPart")) then
                local pos = obj:IsA("Model")
                    and (obj.PrimaryPart or obj:FindFirstChild("Handle") or obj:FindFirstChild("Root"))
                    or obj
                if pos then
                    table.insert(ST.FruitRegistry, { obj = obj, part = pos })
                end
            end
        end
    end
end

local function CollectFruits()
    ScanFruits()
    if #ST.FruitRegistry == 0 then
        Notify("Fruits", "No target fruits found in world.", 3, "search")
        return
    end

    local collected = 0
    for _, entry in ipairs(ST.FruitRegistry) do
        if entry.part and entry.part.Parent then
            local pos = entry.part:IsA("BasePart")
                and entry.part.Position
                or entry.part.CFrame.Position
            TeleportLateral(pos)
            task.wait(0.1)

            -- Try remote first
            if REM.CollectFruit then
                SafeCall(REM.CollectFruit, entry.obj)
                task.wait(0.2)
            elseif REM.PickupFruit then
                SafeCall(REM.PickupFruit, entry.obj)
                task.wait(0.2)
            end

            -- Try ClickDetector
            local click = entry.obj:FindFirstChildWhichIsA("ClickDetector", true)
            if click then
                pcall(fireclickdetector, click)
                task.wait(0.1)
            end

            -- Try ProximityPrompt
            local prompt = entry.obj:FindFirstChildWhichIsA("ProximityPrompt", true)
            if prompt then
                pcall(fireproximityprompt, prompt)
                task.wait(0.1)
            end

            collected = collected + 1
            task.wait(Jitter(0.3))
        end
    end

    if collected > 0 then
        Notify("Fruits", collected .. " fruits collected!", 4, "star")
    end
end

-- ============================================================
-- S14-B  TAME ALL PETS
-- ============================================================
-- Fires the full tame sequence (ThrowLasso -> minigameRequest ->
-- RequestPlacePet) at every pet currently in the registry.
-- Each pet gets its own task.spawn so all tames run concurrently.
-- TameAllStagger staggers thread launch to avoid a wall of
-- simultaneous remote fires that could trigger rate-limit detection.
-- Returns the number of tame sequences dispatched.

local function TameSinglePet(entry)
    if not entry or not entry.model or not entry.model.Parent then return false end
    local anchor = entry.anchor
    if not anchor or not anchor.Parent then return false end

    -- Override per-remote cooldown tracking for this pet specifically
    -- so concurrent threads don't block each other
    local remoteCD = REMOTE_COOLDOWNS.minigameRequest or 0.5

    -- Throw lasso (no teleport -- server validates position server-side
    -- when ThrowLasso is fired directly with the target's position)
    pcall(function()
        if REM.ThrowLasso then
            REM.ThrowLasso:FireServer(entry.model, anchor.Position)
        end
    end)
    task.wait(0.2)

    -- Solve minigame: fire UpdateProgress(100) as primary.
    -- GUI watcher runs as backup for any UI elements that may still appear.
    task.spawn(function()
        WatchAndClickMinigameGUI(2.0)
    end)
    pcall(function()
        if REM.UpdateProgress then
            REM.UpdateProgress:FireServer(100)
        elseif REM.minigameRequest then
            REM.minigameRequest:InvokeServer(true)
        end
    end)

    task.wait(0.15)

    -- Place pet in pen if enabled
    if CFG.AutoPlacePet then
        pcall(function()
            if REM.RequestPlacePet then
                REM.RequestPlacePet:FireServer()
            end
        end)
    end

    return true
end

local TameAllActive = false  -- guard against overlapping runs

local function TameAllPets()
    if TameAllActive then return 0 end
    TameAllActive = true

    -- Snapshot registry now (pairs iterator is not safe across yields)
    local snapshot = {}
    for model, entry in pairs(ST.PetRegistry) do
        if model and model.Parent and entry.anchor and entry.anchor.Parent then
            -- Apply same rarity/blacklist/whitelist filters as normal farm
            if ScorePetEntry(entry) >= 0 then
                table.insert(snapshot, entry)
            end
        end
    end

    if #snapshot == 0 then
        TameAllActive = false
        Notify("Tame All", "No valid pets in registry.", 3, "alert-circle")
        return 0
    end

    local dispatched = 0
    local startTime  = tick()

    for i, entry in ipairs(snapshot) do
        -- Stagger: launch each thread TameAllStagger seconds apart
        if i > 1 and CFG.TameAllStagger > 0 then
            task.wait(CFG.TameAllStagger)
        end

        -- Don't keep running if the registry pet despawned during stagger
        if entry.model and entry.model.Parent then
            task.spawn(TameSinglePet, entry)
            dispatched = dispatched + 1
        end
    end

    -- Brief wait for threads to finish before allowing next run
    task.wait(math.max(0.5, CFG.TameAllStagger * #snapshot + 0.5))
    TameAllActive = false

    local elapsed = string.format("%.1f", tick() - startTime)
    UpdateLabel(ST.StatusLabels.TameAllStatus,
        "Last run: " .. dispatched .. " pets in " .. elapsed .. "s", "zap")

    return dispatched
end

-- ============================================================
-- S15  AUTO SELL
-- ============================================================

local function SellPets()
    local inventory = SafeInvoke(REM.getPetInventory)
    if type(inventory) ~= "table" then return end

    local threshold = RARITY_TIERS[CFG.SellBelowRarity] or 2
    local sold = 0

    for _, petData in pairs(inventory) do
        if type(petData) == "table" then
            -- Try to determine rarity from petData fields
            local rarStr = petData.rarity or petData.Rarity
                        or petData.tier   or petData.Tier or ""
            local tier = GetTierFromString(tostring(rarStr))

            if tier < threshold and tier > 0 then
                -- sellPet is a RemoteFunction (scanner confirmed). SellPets does not exist.
                SafeInvoke(REM.sellPet, petData)
                sold = sold + 1
                task.wait(Jitter(0.25))
            end
        end
    end

    if sold > 0 then
        Notify("Sell", "Sold " .. sold .. " pets.", 4, "dollar-sign")
    end
end

local function SellEggs()
    -- sellEgg is a RemoteFunction; getEggInventory gets the list first
    local inventory = SafeInvoke(REM.getEggInventory)
    if type(inventory) ~= "table" then
        SafeInvoke(REM.sellEgg)
        Notify("Sell", "Egg sell sent (blind).", 3, "package")
        return
    end
    local sold = 0
    for _, eggData in pairs(inventory) do
        if type(eggData) == "table" then
            SafeInvoke(REM.sellEgg, eggData)
            sold = sold + 1
            task.wait(Jitter(0.15))
        end
    end
    if sold > 0 then
        Notify("Sell", "Sold " .. sold .. " eggs.", 4, "package")
    end
end

-- ============================================================
-- S16  SMART BREED
-- ============================================================

local function SmartBreedCycle()
    local inventory = SafeInvoke(REM.getPetInventory)
    if type(inventory) ~= "table" then
        SafeInvoke(REM.breedRequest)
        return
    end

    if CFG.BreedRarityMatch then
        -- Build rarity buckets
        local buckets = {}
        for _, petData in pairs(inventory) do
            if type(petData) == "table" then
                local rarStr = petData.rarity or petData.Rarity or ""
                local tier = GetTierFromString(tostring(rarStr))
                if tier > 0 then
                    if not buckets[tier] then buckets[tier] = {} end
                    table.insert(buckets[tier], petData)
                end
            end
        end

        -- Breed pairs within same tier
        for tier, pets in pairs(buckets) do
            for i = 1, #pets - 1, 2 do
                SafeInvoke(REM.breedRequest, pets[i], pets[i + 1])
                task.wait(Jitter(CFG.BreedDelay))
            end
        end
    else
        -- Simple breed: fire request, let server decide
        SafeInvoke(REM.breedRequest)
    end
end

-- ============================================================
-- S17  MINIGAME + CORE CATCH CYCLE
-- ============================================================

-- Keywords that identify the confirm/success button in the minigame GUI.
-- The watcher checks button names and text against these strings.
local MINIGAME_BUTTON_KEYWORDS = {
    "catch", "tame", "confirm", "success", "win",
    "click", "press", "submit", "complete", "done",
    "ok", "yes", "grab", "lasso", "capture",
}

-- Fire every connection on a signal (MouseButton1Click / Activated).
-- Falls back to :Fire() if getconnections is unavailable.
local function FireButtonConnections(button)
    -- Method 1: getconnections (preferred -- calls the actual handler functions)
    local conns = getconnections(button.MouseButton1Click)
    if conns and #conns > 0 then
        for _, conn in ipairs(conns) do
            pcall(function() conn:Fire() end)
        end
        return true
    end

    -- Method 2: Activated signal
    conns = getconnections(button.Activated)
    if conns and #conns > 0 then
        for _, conn in ipairs(conns) do
            pcall(function() conn:Fire() end)
        end
        return true
    end

    -- Method 3: Direct Fire on the signal (works on some executors)
    pcall(function() button.MouseButton1Click:Fire() end)
    pcall(function() button.Activated:Fire() end)
    return false
end

-- Returns true if a button name or text matches known minigame keywords.
local function IsMinigameButton(button)
    local name = button.Name:lower()
    local text = ""
    pcall(function() text = button.Text:lower() end)

    for _, kw in ipairs(MINIGAME_BUTTON_KEYWORDS) do
        if name:find(kw) or text:find(kw) then return true end
    end
    return false
end

-- Recursively collect all TextButton / ImageButton descendants.
local function CollectButtons(parent, out)
    out = out or {}
    for _, child in ipairs(parent:GetDescendants()) do
        if child:IsA("TextButton") or child:IsA("ImageButton") then
            table.insert(out, child)
        end
    end
    return out
end

-- Try to click any actionable element inside a GUI container.
-- Returns true if at least one click was fired.
local function ClickGuiContents(guiObj)
    local clicked = false

    -- ProximityPrompts inside the GUI (rare but possible)
    for _, prompt in ipairs(guiObj:GetDescendants()) do
        if prompt:IsA("ProximityPrompt") then
            pcall(fireproximityprompt, prompt)
            clicked = true
        end
    end

    local buttons = CollectButtons(guiObj)
    if #buttons == 0 then return clicked end

    -- Pass 1: look for a button that matches minigame keywords
    for _, btn in ipairs(buttons) do
        if IsMinigameButton(btn) and btn.Visible then
            FireButtonConnections(btn)
            clicked = true
        end
    end

    -- Pass 2: if no keyword match, click the first visible button
    -- (the minigame may only have one button, so this is safe)
    if not clicked then
        for _, btn in ipairs(buttons) do
            if btn.Visible then
                FireButtonConnections(btn)
                clicked = true
                break
            end
        end
    end

    return clicked
end

-- Core watcher. Called after ThrowLasso fires.
-- Monitors PlayerGui (and CoreGui) for the minigame screen for up to
-- `timeout` seconds, clicks whatever it finds, and also fires the
-- minigameRequest remote in parallel so both paths are covered.
local function WatchAndClickMinigameGUI(timeout)
    timeout = timeout or 4
    local deadline = tick() + timeout
    local clicked  = false

    -- Snapshot existing GUIs so we only react to NEW ones
    local knownGUIs = {}
    local pg = Player:FindFirstChild("PlayerGui")
    if pg then
        for _, g in ipairs(pg:GetChildren()) do knownGUIs[g] = true end
    end
    for _, g in ipairs(CoreGui:GetChildren()) do knownGUIs[g] = true end

    -- Also try clicking in any GUI that already exists and looks like a minigame
    -- (handles GUIs that were added before we started watching)
    local function ScanExisting()
        if pg then
            for _, g in ipairs(pg:GetChildren()) do
                if not knownGUIs[g] then
                    if ClickGuiContents(g) then clicked = true end
                end
            end
        end
    end

    -- Poll loop
    while tick() < deadline and not clicked do
        -- Check PlayerGui for new ScreenGuis
        if pg then
            for _, g in ipairs(pg:GetChildren()) do
                if not knownGUIs[g] then
                    -- New GUI appeared -- try clicking it immediately
                    task.wait(0.05)  -- tiny wait for GUI to finish populating
                    if ClickGuiContents(g) then
                        clicked = true
                        break
                    end
                    knownGUIs[g] = true  -- mark so we don't retry
                end
            end
        end

        -- Check CoreGui for new elements
        if not clicked then
            for _, g in ipairs(CoreGui:GetChildren()) do
                if not knownGUIs[g] then
                    task.wait(0.05)
                    if ClickGuiContents(g) then
                        clicked = true
                        break
                    end
                    knownGUIs[g] = true
                end
            end
        end

        -- Also check ProximityPrompts on the pet itself each tick
        -- (some games use a world-space prompt instead of a ScreenGui)
        if not clicked and ST.NearestPet and ST.NearestPet.Parent then
            for _, prompt in ipairs(ST.NearestPet:GetDescendants()) do
                if prompt:IsA("ProximityPrompt") then
                    pcall(fireproximityprompt, prompt)
                    clicked = true
                    break
                end
            end
            -- ClickDetectors on the pet
            if not clicked then
                for _, cd in ipairs(ST.NearestPet:GetDescendants()) do
                    if cd:IsA("ClickDetector") then
                        pcall(fireclickdetector, cd)
                        clicked = true
                        break
                    end
                end
            end
        end

        if not clicked then task.wait(0.08) end
    end

    return clicked
end

-- Solves the taming minigame by firing UpdateProgress:FireServer(100).
-- Community research confirms this is the actual minigame completion remote:
--   ReplicatedStorage.Remotes.UpdateProgress:FireServer(100)
-- Passing 100 tells the server the progress bar is full -> instant catch.
-- minigameRequest is kept as a secondary fallback for future game changes.
local function SolveTamingMinigame()
    -- Primary: UpdateProgress(100) -- confirmed working across all public scripts
    if REM.UpdateProgress then
        pcall(function()
            REM.UpdateProgress:FireServer(100)
        end)
        return true
    end

    -- Secondary: minigameRequest (legacy / fallback)
    if ST.MinigameSig and ST.MinigameSigValidated then
        return SafeCall(REM.minigameRequest, table.unpack(ST.MinigameSig))
    end

    if REM.minigameRequest then
        SafeCall(REM.minigameRequest, true)
    end

    return false
end

local function ThrowLassoAt(target, anchor)
    TeleportLateral(anchor.Position)
    task.wait(Jitter(0.15))
    return SafeFire(REM.ThrowLasso, target, anchor.Position)
end

local function RunCatchCycle()
    -- Anti-detection: cap catches per minute
    local now = tick()
    if now - ST.CatchMinReset >= 60 then
        ST.CatchesThisMin = 0
        ST.CatchMinReset  = now
    end
    if ST.CatchesThisMin >= CFG.MaxCatchPerMin then
        task.wait(1)
        return
    end

    local entry, dist = FindBestPet()
    if not entry or not entry.model or not entry.model.Parent then return end

    ST.NearestPet = entry.model

    local anchor = entry.anchor
    if not anchor or not anchor.Parent then return end

    -- Snapshot inventory before catch attempt
    local invBefore = GetInventoryCount()

    -- Teleport lateral (behind target)
    TeleportLateral(anchor.Position)
    task.wait(Jitter(0.18))

    -- Throw lasso
    ST.Stats.CatchAttempts = ST.Stats.CatchAttempts + 1
    local thrown = ThrowLassoAt(entry.model, anchor)
    task.wait(Jitter(0.25))

    -- Solve minigame via UpdateProgress:FireServer(100) (confirmed remote).
    -- GUI watcher runs in parallel as backup for any screen UI that appears.
    task.spawn(function()
        WatchAndClickMinigameGUI(2.0)
    end)
    SolveTamingMinigame()
    task.wait(Jitter(0.3))

    -- Place pet in pen
    if CFG.AutoPlacePet then
        SafeFire(REM.RequestPlacePet)
        task.wait(0.15)
    end

    -- Confirm catch via inventory delta
    local invAfter = GetInventoryCount()
    local confirmed = invAfter > invBefore

    if confirmed then
        ST.Stats.CatchConfirmed = ST.Stats.CatchConfirmed + 1
        ST.CatchesThisMin = ST.CatchesThisMin + 1

        -- Track best pet this session
        if entry.tier > ST.Stats.LastBestTier then
            ST.Stats.LastBestTier = entry.tier
            ST.Stats.LastBestPet  = entry.name
            if entry.tier >= 5 then
                Notify(
                    "High-Value Catch!",
                    entry.name .. (entry.mutation and (" [" .. entry.mutation .. "]") or ""),
                    7,
                    "star"
                )
            end
        end

        -- Update catch status label
        local tierName = "Unknown"
        for k, v in pairs(RARITY_TIERS) do if v == entry.tier then tierName = k end end
        UpdateLabel(
            ST.StatusLabels.CatchStatus,
            "Confirmed: " .. ST.Stats.CatchConfirmed
            .. "  |  " .. entry.name:sub(1, 14)
            .. " [" .. tierName .. "]"
            .. (entry.mutation and " +" .. entry.mutation or "")
            .. "  (" .. math.floor(dist) .. " st)",
            "crosshair"
        )
    end
end

-- ============================================================
-- S18  ECONOMY FUNCTIONS
-- ============================================================

local function CollectAllCash()
    SafeFire(REM.collectAllPetCash)
    task.wait(0.2)
    local offline = SafeInvoke(REM.getOfflineCash)
    if type(offline) == "number" and offline > 0 then
        SafeFire(REM.collectAllPetCash)
    end
    UpdateLabel(ST.StatusLabels.CashStatus,
        "Last collect: " .. os.date("%H:%M:%S"), "clock")
end

local function BuyFood()    SafeFire(REM.BuyFood) end

local function FeedAllPets()
    local inventory = SafeInvoke(REM.getPetInventory)
    if type(inventory) ~= "table" then return end
    local fed = 0
    for _, petData in pairs(inventory) do
        if type(petData) == "table"
        and (petData.id or petData.Id or petData.petId or petData.name) then
            local feedOk = SafeInvoke(REM.FeedPet, petData)
            -- Fallback: FeedPrompt ProximityPrompts on pen models
            -- (structure scan confirmed FeedPrompt [ProximityPrompt] on pen pets)
            if feedOk == nil or feedOk == false then
                local penFolder = Workspace:FindFirstChild("Pens")
                             or Workspace:FindFirstChild("PlayerPens")
                if penFolder then
                    for _, d in ipairs(penFolder:GetDescendants()) do
                        if d:IsA("ProximityPrompt")
                        and d.Name:lower():find("feed") then
                            pcall(fireproximityprompt, d)
                        end
                    end
                end
            end
            fed = fed + 1
            task.wait(Jitter(0.09))
        end
    end
    if fed == 0 then
        Notify("Feed", "No feedable pets found.", 3, "alert-circle")
    end
end

local function ClaimLogin()
    SafeFire(REM.ClaimLoginReward)
    Notify("Rewards", "Login reward claimed!", 3, "gift")
end

local function ClaimIndex()
    SafeFire(REM.ClaimIndex)
    SafeFire(REM.ClaimExclusive)
    SafeFire(REM.ClaimFeepEgg)  -- confirmed RemoteEvent (scanner-verified)
    Notify("Rewards", "Index, exclusive, and Feep egg claimed!", 3, "star")
end

local function UseSpin()
    SafeFire(REM.UseSpin)
    Notify("Spins", "Spin used!", 3, "refresh-cw")
end

local function RedeemCode(code)
    if not code or code == "" then return end
    code = code:gsub("^%s+", ""):gsub("%s+$", "")
    local result = SafeInvoke(REM.redeemCode, code)
    if result then
        Notify("Code Redeemed", code, 5, "check-circle")
    else
        Notify("Code Failed", code .. " -- invalid or already used.", 4, "x-circle")
    end
end

local function InstantHatchAll()
    -- GetReadyToHatchEggs returns which eggs are done (scanner-verified RemoteFunction)
    local readyEggs = SafeInvoke(REM.GetReadyToHatchEggs)
    if type(readyEggs) == "table" and #readyEggs > 0 then
        for _, egg in ipairs(readyEggs) do
            SafeInvoke(REM.RequestEggHatch, egg)
            task.wait(Jitter(0.1))
        end
        Notify("Eggs", "Hatched " .. #readyEggs .. " ready eggs.", 4, "egg")
        return
    end
    -- Fallback: blind InstantHatch for all eggs
    SafeFire(REM.InstantHatch)
    SafeFire(REM.InstantHatch, true)
    SafeInvoke(REM.RequestEggHatch)
    Notify("Eggs", "Instant hatch sent.", 3, "zap")
end

-- ============================================================
-- S19  MOVEMENT & UTILITY
-- ============================================================

local function ApplyMovement()
    local hum = GetHumanoid()
    if hum then
        hum.WalkSpeed = CFG.WalkSpeed
        hum.JumpPower = CFG.JumpPower
    end
end

local function SetInfiniteJump(on)
    if ST.Connections.InfiniteJump then
        ST.Connections.InfiniteJump:Disconnect()
        ST.Connections.InfiniteJump = nil
    end
    if on then
        ST.Connections.InfiniteJump = UserInputService.JumpRequest:Connect(function()
            local hum = GetHumanoid()
            if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
        end)
    end
end

local function SetAntiAFK(on)
    if ST.Connections.AntiAFK then
        ST.Connections.AntiAFK:Disconnect()
        ST.Connections.AntiAFK = nil
    end
    if on then
        ST.Connections.AntiAFK = Player.Idled:Connect(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end
end

-- ============================================================
-- S20  ESP SYSTEM
-- ============================================================

local function GetESPColor(entry)
    if CFG.ESPRarityColors and entry.tier > 0 then
        return RARITY_COLORS[entry.tier] or CFG.ESPColor
    end
    return CFG.ESPColor
end

local function CreateESP(model)
    if ST.ESPObjects[model] then return end
    local entry = ST.PetRegistry[model]
    if not entry then return end

    -- Mutation-only filter
    if CFG.ESPMutationOnly and not entry.mutation then return end

    local anchor = entry.anchor
    if not anchor or not anchor.Parent then return end

    local bb = Instance.new("BillboardGui")
    bb.Name         = "CAT_ESP"
    bb.Size         = UDim2.new(0, 220, 0, 54)
    bb.StudsOffset  = Vector3.new(0, 4.5, 0)
    bb.AlwaysOnTop  = true
    bb.Adornee      = anchor
    bb.Parent       = CoreGui

    local nameLabel = Instance.new("TextLabel")
    nameLabel.Size                   = UDim2.new(1, 0, 0.45, 0)
    nameLabel.BackgroundTransparency = 1
    nameLabel.Text                   = entry.name:sub(1, 20)
    nameLabel.TextColor3             = GetESPColor(entry)
    nameLabel.TextStrokeTransparency = 0.3
    nameLabel.Font                   = Enum.Font.GothamBold
    nameLabel.TextSize               = 13
    nameLabel.Parent                 = bb

    local mutLabel = Instance.new("TextLabel")
    mutLabel.Size                   = UDim2.new(1, 0, 0.3, 0)
    mutLabel.Position               = UDim2.new(0, 0, 0.45, 0)
    mutLabel.BackgroundTransparency = 1
    mutLabel.Text                   = entry.mutation
                                      and ("[" .. entry.mutation .. "]")
                                      or ""
    mutLabel.TextColor3             = Color3.fromRGB(255, 220, 80)
    mutLabel.TextStrokeTransparency = 0.4
    mutLabel.Font                   = Enum.Font.GothamBold
    mutLabel.TextSize               = 11
    mutLabel.Parent                 = bb

    local distLabel = Instance.new("TextLabel")
    distLabel.Size                   = UDim2.new(1, 0, 0.25, 0)
    distLabel.Position               = UDim2.new(0, 0, 0.75, 0)
    distLabel.BackgroundTransparency = 1
    distLabel.TextColor3             = Color3.new(0.85, 0.85, 0.85)
    distLabel.TextStrokeTransparency = 0.5
    distLabel.Font                   = Enum.Font.Gotham
    distLabel.TextSize               = 10
    distLabel.Parent                 = bb

    -- Rarity tier bar (thin colored underline)
    local tierBar = Instance.new("Frame")
    tierBar.Size            = UDim2.new(entry.tier / 8, 0, 0, 2)
    tierBar.Position        = UDim2.new(0, 0, 1, -2)
    tierBar.BackgroundColor3 = GetESPColor(entry)
    tierBar.BorderSizePixel = 0
    tierBar.Parent          = bb

    local ancestryConn
    ancestryConn = model.AncestryChanged:Connect(function(_, parent)
        if not parent then
            pcall(function() bb:Destroy() end)
            pcall(function() ancestryConn:Disconnect() end)
            ST.ESPObjects[model] = nil
        end
    end)

    ST.ESPObjects[model] = {
        gui          = bb,
        name         = nameLabel,
        mut          = mutLabel,
        dist         = distLabel,
        tierBar      = tierBar,
        ancestryConn = ancestryConn,
        entry        = entry,
    }
end

_G.CAT_CreateESP = CreateESP

local function DestroyAllESP()
    for model, obj in pairs(ST.ESPObjects) do
        if obj.ancestryConn then pcall(function() obj.ancestryConn:Disconnect() end) end
        pcall(function() obj.gui:Destroy() end)
        ST.ESPObjects[model] = nil
    end
end

local function UpdateESP()
    local root  = GetRoot()
    local stale = {}

    for model, obj in pairs(ST.ESPObjects) do
        if model and model.Parent and obj.gui and obj.gui.Parent then
            local entry = ST.PetRegistry[model]
            if entry then
                local anchor = entry.anchor
                if root and anchor and anchor.Parent then
                    local dist = math.floor(GetDistance(root.Position, anchor.Position))
                    pcall(function()
                        obj.dist.Text = dist .. " st"
                        local color = GetESPColor(entry)
                        if CFG.HighlightNearest and ST.NearestPet == model then
                            obj.name.TextColor3 = Color3.fromRGB(255, 255, 80)
                        else
                            obj.name.TextColor3 = color
                        end
                    end)
                end
            else
                stale[#stale + 1] = {m = model, o = obj}
            end
        else
            stale[#stale + 1] = {m = model, o = obj}
        end
    end

    for _, e in ipairs(stale) do
        if e.o then
            if e.o.ancestryConn then pcall(function() e.o.ancestryConn:Disconnect() end) end
            pcall(function() if e.o.gui then e.o.gui:Destroy() end end)
        end
        ST.ESPObjects[e.m] = nil
    end
end

-- ============================================================
-- S21  SESSION ANALYTICS
-- ============================================================

local function CalcCatchRate()
    local elapsed = tick() - ST.Stats.SessionStart
    if elapsed < 1 then return 0 end
    return ST.Stats.CatchConfirmed / elapsed * 3600  -- catches per hour
end

local function CalcSuccessRate()
    if ST.Stats.CatchAttempts == 0 then return 0 end
    return math.floor(ST.Stats.CatchConfirmed / ST.Stats.CatchAttempts * 100)
end

local function FormatSessionTime()
    return FormatTime(tick() - ST.Stats.SessionStart)
end

local function UpdateStatsDisplay()
    local sl = ST.StatusLabels
    UpdateLabel(sl.StatsRate,
        "Catch rate: " .. string.format("%.1f", CalcCatchRate()) .. "/hr", "trending-up")
    UpdateLabel(sl.StatsSuccess,
        "Success rate: " .. CalcSuccessRate() .. "%  |  Attempts: " .. ST.Stats.CatchAttempts,
        "percent")
    UpdateLabel(sl.StatsSession,
        "Session: " .. FormatSessionTime() .. "  |  Best: " .. ST.Stats.LastBestPet,
        "clock")
end

-- ============================================================
-- S22  RAYFIELD GUI
-- ============================================================

-- Fetch Rayfield before installing hook
local rayfieldSrc = nil

if typeof(http_request) == "function" then
    local ok, res = pcall(http_request, {Url = RAYFIELD_URL, Method = "GET"})
    if ok and res and type(res.Body) == "string" and #res.Body > 10 then
        rayfieldSrc = res.Body
    end
end

if not rayfieldSrc and typeof(request) == "function" then
    local ok, res = pcall(request, {Url = RAYFIELD_URL, Method = "GET"})
    if ok and res and type(res.Body) == "string" and #res.Body > 10 then
        rayfieldSrc = res.Body
    end
end

if not rayfieldSrc then
    local ok, src = pcall(function() return game:HttpGet(RAYFIELD_URL) end)
    if ok and type(src) == "string" and #src > 10 then rayfieldSrc = src end
end

if not rayfieldSrc then
    error("[CAT] Rayfield fetch failed. Check internet connection.")
end

local rfLoader, rfErr = loadstring(rayfieldSrc)
if not rfLoader then error("[CAT] Rayfield compile error: " .. tostring(rfErr)) end

local Rayfield = rfLoader()
if not Rayfield then error("[CAT] Rayfield returned nil.") end

_G.CATRayfield   = Rayfield
ST.RayfieldReady = true

-- POST-LOAD: install hook now (Rayfield is in memory, hook won't intercept it)
InstallHook()

-- Flush queued notifications
for _, p in ipairs(ST.NotifyQueue) do
    pcall(function() Rayfield:Notify(p) end)
end
ST.NotifyQueue = {}

-- Build Window
-- FIX: ToggleUIKeybind must be Enum.KeyCode, not a string
local Window = Rayfield:CreateWindow({
    Name                   = SCRIPT_NAME .. "  v" .. VERSION,
    Icon                   = "paw-print",
    LoadingTitle           = SCRIPT_NAME .. " Script",
    LoadingSubtitle        = "Xeno | v" .. VERSION .. " | by ENI",
    Theme                  = "Default",
    ToggleUIKeybind        = Enum.KeyCode.RightShift,
    DisableRayfieldPrompts = false,
    DisableBuildWarnings   = false,
    ConfigurationSaving    = {
        Enabled    = true,
        FolderName = "CATScript",
        FileName   = "CATv2Config",
    },
})

-- ------------------------------------------------------------
-- TAB 1: AUTO FARM
-- ------------------------------------------------------------
local FarmTab = Window:CreateTab("Auto Farm", "crosshair")

FarmTab:CreateSection("Catching")

FarmTab:CreateToggle({
    Name         = "Auto Farm",
    CurrentValue = false,
    Flag         = "AutoFarmToggle",
    Callback     = function(v)
        CFG.AutoFarm = v
        Notify("Auto Farm", v and "Catching started!" or "Stopped.", 3,
               v and "play" or "square")
    end,
})

FarmTab:CreateSlider({
    Name         = "Catch Cycle Delay (s)",
    Range        = {0.5, 15},
    Increment    = 0.1,
    Suffix       = "s",
    CurrentValue = 1.5,
    Flag         = "FarmDelaySlider",
    Callback     = function(v) CFG.FarmDelay = v end,
})

FarmTab:CreateSlider({
    Name         = "Max Catches Per Minute",
    Range        = {5, 60},
    Increment    = 1,
    Suffix       = " /min",
    CurrentValue = 30,
    Flag         = "MaxCatchPerMinSlider",
    Callback     = function(v) CFG.MaxCatchPerMin = v end,
})

FarmTab:CreateToggle({
    Name         = "Auto Place Pet After Catch",
    CurrentValue = true,
    Flag         = "AutoPlacePetToggle",
    Callback     = function(v) CFG.AutoPlacePet = v end,
})

FarmTab:CreateToggle({
    Name         = "Human Mode (randomized delays)",
    CurrentValue = false,
    Flag         = "HumanModeToggle",
    Callback     = function(v)
        CFG.HumanMode = v
        Notify("Human Mode", v and "Enabled -- delays randomized." or "Disabled.", 3,
               v and "user-check" or "user")
    end,
})

FarmTab:CreateSection("Priority Filter")

FarmTab:CreateDropdown({
    Name            = "Minimum Rarity to Catch",
    Options         = {"All", "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythical", "Exclusive", "Secret"},
    CurrentOption   = {"All"},
    MultipleOptions = false,
    Flag            = "RarityFilterDropdown",
    Callback        = function(v)
        local sel = v[1]
        if sel == "All" then
            CFG.RarityFilter = "Common"
        else
            CFG.RarityFilter = sel
        end
    end,
})

FarmTab:CreateToggle({
    Name         = "Mutation Only (catch mutated pets only)",
    CurrentValue = false,
    Flag         = "MutationOnlyToggle",
    Callback     = function(v) CFG.MutationOnly = v end,
})

FarmTab:CreateSection("Blacklist / Whitelist")

FarmTab:CreateInput({
    Name                     = "Add to Blacklist",
    CurrentValue             = "",
    PlaceholderText          = "Pet name to skip...",
    RemoveTextAfterFocusLost = true,
    Flag                     = "BlacklistInput",
    Callback                 = function(t)
        if t and t ~= "" then
            table.insert(CFG.Blacklist, t)
            Notify("Blacklist", "Added: " .. t, 3, "slash")
        end
    end,
})

FarmTab:CreateInput({
    Name                     = "Add to Whitelist",
    CurrentValue             = "",
    PlaceholderText          = "Pet name to always catch...",
    RemoveTextAfterFocusLost = true,
    Flag                     = "WhitelistInput",
    Callback                 = function(t)
        if t and t ~= "" then
            table.insert(CFG.Whitelist, t)
            Notify("Whitelist", "Added: " .. t, 3, "check")
        end
    end,
})

FarmTab:CreateButton({
    Name     = "Clear Blacklist",
    Callback = function()
        CFG.Blacklist = {}
        Notify("Blacklist", "Cleared.", 3, "trash")
    end,
})

FarmTab:CreateButton({
    Name     = "Clear Whitelist",
    Callback = function()
        CFG.Whitelist = {}
        Notify("Whitelist", "Cleared.", 3, "trash")
    end,
})

FarmTab:CreateSection("Manual Controls")

FarmTab:CreateButton({
    Name     = "Catch Best Pet Now",
    Callback = function() task.spawn(RunCatchCycle) end,
})

FarmTab:CreateButton({
    Name     = "Complete Current Minigame",
    Callback = function()
        -- Fires UpdateProgress:FireServer(100) directly.
        -- Use this while the taming minigame is on screen to instantly
        -- complete it without waiting for the auto-farm loop.
        if REM.UpdateProgress then
            pcall(function() REM.UpdateProgress:FireServer(100) end)
            Notify("Minigame", "Progress set to 100 -- minigame complete!", 4, "check-circle")
        else
            -- UpdateProgress not cached yet; trigger a remote refresh first
            CacheRemotes()
            if REM.UpdateProgress then
                pcall(function() REM.UpdateProgress:FireServer(100) end)
                Notify("Minigame", "Remote found and fired!", 4, "check-circle")
            else
                Notify("Minigame", "UpdateProgress not found. Try re-caching.", 4, "alert-circle")
            end
        end
    end,
})

FarmTab:CreateButton({
    Name     = "Cancel Stuck Minigame",
    Callback = function()
        -- CancelMinigame resets a stuck minigame server-side (scanner-confirmed)
        SafeFire(REM.CancelMinigame)
        Notify("Minigame", "Cancel sent.", 3, "x-circle")
    end,
})

FarmTab:CreateButton({
    Name     = "Teleport to Best Pet",
    Callback = function()
        local entry = FindBestPet()
        if not entry then
            Notify("Teleport", "No valid pets in registry.", 3, "alert-circle")
            return
        end
        TeleportLateral(entry.anchor.Position)
        Notify("Teleport", "Jumped to " .. entry.name, 3, "map-pin")
    end,
})

FarmTab:CreateSection("Tame All Pets")

FarmTab:CreateParagraph({
    Title   = "How Tame All works",
    Content = "Fires ThrowLasso + UpdateProgress(100) at every pet in the"
           .. " registry simultaneously. No teleporting required -- the"
           .. " server receives the lasso fire with the pets position."
           .. " UpdateProgress:FireServer(100) is the confirmed instant-catch"
           .. " remote used by all public scripts."
           .. " Respects your rarity filter, blacklist, and whitelist.",
})

FarmTab:CreateToggle({
    Name         = "Auto Tame All (loop)",
    CurrentValue = false,
    Flag         = "TameAllToggle",
    Callback     = function(v)
        CFG.TameAll = v
        Notify("Tame All", v and "Looping tame-all active!" or "Stopped.", 4,
               v and "zap" or "square")
    end,
})

FarmTab:CreateSlider({
    Name         = "Tame All Loop Interval (s)",
    Range        = {2, 60},
    Increment    = 0.5,
    Suffix       = "s",
    CurrentValue = 5,
    Flag         = "TameAllDelaySlider",
    Callback     = function(v) CFG.TameAllDelay = v end,
})

FarmTab:CreateSlider({
    Name         = "Inter-pet Stagger (s)",
    Range        = {0, 0.5},
    Increment    = 0.01,
    Suffix       = "s",
    CurrentValue = 0.08,
    Flag         = "TameAllStaggerSlider",
    Callback     = function(v) CFG.TameAllStagger = v end,
})

FarmTab:CreateButton({
    Name     = "Tame All Now (single run)",
    Callback = function()
        local n = 0
        for _ in pairs(ST.PetRegistry) do n = n + 1 end
        Notify("Tame All", "Dispatching tame sequences for " .. n .. " pets...", 4, "zap")
        task.spawn(function()
            local tamed = TameAllPets()
            Notify("Tame All", "Done! " .. tamed .. " sequences fired.", 5, "check-circle")
        end)
    end,
})

FarmTab:CreateSection("Live Status")

local CatchStatusLabel = FarmTab:CreateLabel("Confirmed catches: 0", "activity")
ST.StatusLabels.CatchStatus = CatchStatusLabel

local TameAllStatusLabel = FarmTab:CreateLabel("Tame All: not run yet", "zap")
ST.StatusLabels.TameAllStatus = TameAllStatusLabel

-- ------------------------------------------------------------
-- TAB 2: ECONOMY
-- ------------------------------------------------------------
local EconTab = Window:CreateTab("Economy", "coins")

EconTab:CreateSection("Cash")

EconTab:CreateToggle({
    Name         = "Auto Collect Cash",
    CurrentValue = false,
    Flag         = "AutoCollectToggle",
    Callback     = function(v)
        CFG.AutoCollect = v
        if v then task.spawn(CollectAllCash) end
        Notify("Cash", v and "Auto-collect active!" or "Stopped.", 3,
               v and "trending-up" or "pause")
    end,
})

EconTab:CreateSlider({
    Name         = "Collect Interval (s)",
    Range        = {5, 300},
    Increment    = 5,
    Suffix       = "s",
    CurrentValue = 30,
    Flag         = "CollectIntervalSlider",
    Callback     = function(v) CFG.CollectInterval = v end,
})

EconTab:CreateButton({
    Name     = "Collect Now",
    Callback = function() task.spawn(CollectAllCash); Notify("Cash", "Collected!", 3, "dollar-sign") end,
})

local CashStatusLabel = EconTab:CreateLabel("Last collect: not yet", "clock")
ST.StatusLabels.CashStatus = CashStatusLabel

EconTab:CreateSection("Food and Feeding")

EconTab:CreateToggle({
    Name         = "Auto Buy Food",
    CurrentValue = false,
    Flag         = "AutoBuyFoodToggle",
    Callback     = function(v) CFG.AutoBuyFood = v end,
})

EconTab:CreateToggle({
    Name         = "Auto Feed All Pets",
    CurrentValue = false,
    Flag         = "AutoFeedToggle",
    Callback     = function(v) CFG.AutoFeedPets = v end,
})

EconTab:CreateSlider({
    Name         = "Feed Interval (s)",
    Range        = {10, 300},
    Increment    = 5,
    Suffix       = "s",
    CurrentValue = 60,
    Flag         = "FeedIntervalSlider",
    Callback     = function(v) CFG.FeedInterval = v end,
})

EconTab:CreateButton({
    Name     = "Buy Food Now",
    Callback = function() BuyFood(); Notify("Food", "Purchase sent!", 3, "shopping-bag") end,
})

EconTab:CreateButton({
    Name     = "Feed All Pets Now",
    Callback = function() task.spawn(FeedAllPets) end,
})

EconTab:CreateSection("Auto Sell")

EconTab:CreateToggle({
    Name         = "Auto Sell Pets",
    CurrentValue = false,
    Flag         = "AutoSellPetsToggle",
    Callback     = function(v)
        CFG.AutoSellPets = v
        Notify("Sell", v and "Auto-sell pets active." or "Stopped.", 3,
               v and "trash" or "pause")
    end,
})

EconTab:CreateDropdown({
    Name            = "Sell Pets Below Rarity",
    Options         = {"Common", "Uncommon", "Rare", "Epic", "Legendary"},
    CurrentOption   = {"Uncommon"},
    MultipleOptions = false,
    Flag            = "SellBelowRarityDropdown",
    Callback        = function(v) CFG.SellBelowRarity = v[1] end,
})

EconTab:CreateToggle({
    Name         = "Auto Sell Eggs",
    CurrentValue = false,
    Flag         = "AutoSellEggsToggle",
    Callback     = function(v) CFG.AutoSellEggs = v end,
})

EconTab:CreateButton({
    Name     = "Sell Pets Now",
    Callback = function() task.spawn(SellPets) end,
})

EconTab:CreateButton({
    Name     = "Sell Eggs Now",
    Callback = function() task.spawn(SellEggs) end,
})

EconTab:CreateSection("Rewards")

EconTab:CreateToggle({
    Name         = "Auto Claim Login Reward",
    CurrentValue = false,
    Flag         = "AutoLoginToggle",
    Callback     = function(v) CFG.AutoClaimLogin = v; if v then ClaimLogin() end end,
})

EconTab:CreateToggle({
    Name         = "Auto Claim Index Rewards",
    CurrentValue = false,
    Flag         = "AutoIndexToggle",
    Callback     = function(v) CFG.AutoClaimIndex = v; if v then ClaimIndex() end end,
})

EconTab:CreateToggle({
    Name         = "Auto Use Spins",
    CurrentValue = false,
    Flag         = "AutoSpinToggle",
    Callback     = function(v) CFG.AutoSpin = v end,
})

EconTab:CreateButton({ Name = "Claim Login Reward", Callback = ClaimLogin })
EconTab:CreateButton({ Name = "Claim Index Rewards", Callback = ClaimIndex })
EconTab:CreateButton({ Name = "Use Spin",            Callback = UseSpin    })

-- ------------------------------------------------------------
-- TAB 3: EGGS AND BREEDING
-- ------------------------------------------------------------
local EggTab = Window:CreateTab("Eggs & Breeding", "star")

EggTab:CreateSection("Hatching")

EggTab:CreateToggle({
    Name         = "Auto Instant Hatch",
    CurrentValue = false,
    Flag         = "AutoHatchToggle",
    Callback     = function(v)
        CFG.AutoHatch = v
        Notify("Eggs", v and "Auto hatch enabled!" or "Stopped.", 3, v and "zap" or "pause")
    end,
})

EggTab:CreateSlider({
    Name         = "Hatch Check Interval (s)",
    Range        = {5, 120},
    Increment    = 1,
    Suffix       = "s",
    CurrentValue = 10,
    Flag         = "HatchIntervalSlider",
    Callback     = function(v) CFG.HatchInterval = v end,
})

EggTab:CreateButton({
    Name     = "Instant Hatch All Now",
    Callback = InstantHatchAll,
})

EggTab:CreateSection("Breeding")

EggTab:CreateToggle({
    Name         = "Auto Breed",
    CurrentValue = false,
    Flag         = "AutoBreedToggle",
    Callback     = function(v)
        CFG.AutoBreed = v
        Notify("Breeding", v and "Auto breed started!" or "Stopped.", 3,
               v and "git-merge" or "pause")
    end,
})

EggTab:CreateToggle({
    Name         = "Smart Breed (pair same-rarity pets)",
    CurrentValue = false,
    Flag         = "SmartBreedToggle",
    Callback     = function(v)
        CFG.SmartBreed = v
        CFG.BreedRarityMatch = v
    end,
})

EggTab:CreateSlider({
    Name         = "Breed Cycle Delay (s)",
    Range        = {2, 120},
    Increment    = 0.5,
    Suffix       = "s",
    CurrentValue = 5,
    Flag         = "BreedDelaySlider",
    Callback     = function(v) CFG.BreedDelay = v end,
})

EggTab:CreateButton({
    Name     = "Breed Now",
    Callback = function()
        task.spawn(SmartBreedCycle)
        Notify("Breeding", "Breed cycle fired!", 3, "git-merge")
    end,
})

-- ------------------------------------------------------------
-- TAB 4: EVENTS AND WEATHER
-- ------------------------------------------------------------
local EventsTab = Window:CreateTab("Events", "cloud-lightning")

EventsTab:CreateSection("Weather Monitor")

local WeatherLabel = EventsTab:CreateLabel("Weather: Detecting...", "cloud")
ST.StatusLabels.Weather = WeatherLabel

local WeatherPetsLabel = EventsTab:CreateLabel("Active spawns: --", "paw-print")
ST.StatusLabels.WeatherPets = WeatherPetsLabel

EventsTab:CreateToggle({
    Name         = "Auto Totem (force target weather)",
    CurrentValue = false,
    Flag         = "AutoTotemToggle",
    Callback     = function(v)
        CFG.AutoTotem = v
        Notify("Totem", v and "Auto-totem active." or "Stopped.", 3, "cloud-lightning")
    end,
})

EventsTab:CreateDropdown({
    Name            = "Target Weather",
    Options         = {"Thunderstorm", "Sandstorm", "Cosmic", "Blizzard", "Volcanic",
                       "Rainy", "Snowy", "Foggy", "Windy", "Clear"},
    CurrentOption   = {"Thunderstorm"},
    MultipleOptions = false,
    Flag            = "TargetWeatherDropdown",
    Callback        = function(v) CFG.TargetWeather = v[1] end,
})

EventsTab:CreateButton({
    Name     = "Use Weather Totem Now",
    Callback = function()
        UseWeatherTotem()
    end,
})

EventsTab:CreateSection("Fruit Collection")

EventsTab:CreateToggle({
    Name         = "Auto Collect Fruits",
    CurrentValue = false,
    Flag         = "AutoFruitToggle",
    Callback     = function(v)
        CFG.AutoFruitCollect = v
        Notify("Fruits", v and "Auto-collect fruits active." or "Stopped.", 3,
               v and "sun" or "pause")
    end,
})

EventsTab:CreateDropdown({
    Name            = "Fruit Types to Collect",
    Options         = {"Volcanic", "Cosmic", "Both"},
    CurrentOption   = {"Both"},
    MultipleOptions = false,
    Flag            = "FruitTypeDropdown",
    Callback        = function(v)
        local sel = v[1]
        if sel == "Both" then
            CFG.FruitTypes = {"Volcanic", "Cosmic"}
        else
            CFG.FruitTypes = {sel}
        end
    end,
})

EventsTab:CreateButton({
    Name     = "Collect Fruits Now",
    Callback = function() task.spawn(CollectFruits) end,
})

EventsTab:CreateSection("Skeleton Event")

local SkeletonLabel = EventsTab:CreateLabel("Skeleton event: --", "skull")
ST.StatusLabels.Skeleton = SkeletonLabel

EventsTab:CreateToggle({
    Name         = "Skeleton Event Alert",
    CurrentValue = false,
    Flag         = "SkeletonAlertToggle",
    Callback     = function(v) CFG.SkeletonAlert = v end,
})

-- ------------------------------------------------------------
-- TAB 5: PET ESP
-- ------------------------------------------------------------
local ESPTab = Window:CreateTab("Pet ESP", "eye")

ESPTab:CreateSection("Overlay Settings")

ESPTab:CreateToggle({
    Name         = "Enable Pet ESP",
    CurrentValue = false,
    Flag         = "ESPToggle",
    Callback     = function(v)
        CFG.ESPEnabled = v
        if v then
            for model in pairs(ST.PetRegistry) do CreateESP(model) end
            local n = 0
            for _ in pairs(ST.ESPObjects) do n = n + 1 end
            Notify("ESP", "Active. " .. n .. " overlays.", 4, "eye")
        else
            DestroyAllESP()
            Notify("ESP", "Disabled.", 3, "eye-off")
        end
    end,
})

ESPTab:CreateToggle({
    Name         = "Rarity Color Coding",
    CurrentValue = true,
    Flag         = "ESPRarityColorsToggle",
    Callback     = function(v) CFG.ESPRarityColors = v end,
})

ESPTab:CreateColorPicker({
    Name     = "Default ESP Color",
    Color    = Color3.fromRGB(255, 80, 80),
    Flag     = "ESPColorPicker",
    Callback = function(v)
        CFG.ESPColor = v
        for _, obj in pairs(ST.ESPObjects) do
            if not CFG.ESPRarityColors then
                pcall(function() obj.name.TextColor3 = v end)
            end
        end
    end,
})

ESPTab:CreateToggle({
    Name         = "Show Mutation Badge",
    CurrentValue = true,
    Flag         = "ShowMutationBadgeToggle",
    Callback     = function(v)
        CFG.ShowMutationBadge = v
        for _, obj in pairs(ST.ESPObjects) do
            pcall(function()
                obj.mut.Visible = v
            end)
        end
    end,
})

ESPTab:CreateToggle({
    Name         = "Show Mutated Pets Only in ESP",
    CurrentValue = false,
    Flag         = "ESPMutationOnlyToggle",
    Callback     = function(v)
        CFG.ESPMutationOnly = v
        DestroyAllESP()
        if CFG.ESPEnabled then
            for model in pairs(ST.PetRegistry) do CreateESP(model) end
        end
    end,
})

ESPTab:CreateToggle({
    Name         = "Gold Highlight on Best Target",
    CurrentValue = false,
    Flag         = "HighlightNearestToggle",
    Callback     = function(v) CFG.HighlightNearest = v end,
})

ESPTab:CreateSection("Registry")

local PetCountLabel = ESPTab:CreateLabel("Roaming pets in registry: 0", "map-pin")
ST.StatusLabels.PetCount = PetCountLabel

ESPTab:CreateButton({
    Name     = "Refresh Pet Registry",
    Callback = function()
        ST.PetRegistry = {}
        DestroyAllESP()
        if PetsFolder then
            for _, m in ipairs(PetsFolder:GetChildren()) do RegisterPet(m) end
        end
        local n = 0
        for _ in pairs(ST.PetRegistry) do n = n + 1 end
        if CFG.ESPEnabled then
            for model in pairs(ST.PetRegistry) do CreateESP(model) end
        end
        Notify("Registry", "Refreshed. " .. n .. " pets.", 4, "refresh-cw")
    end,
})

-- ------------------------------------------------------------
-- TAB 6: UTILITY
-- ------------------------------------------------------------
local UtilTab = Window:CreateTab("Utility", "wrench")

UtilTab:CreateSection("Movement")

UtilTab:CreateSlider({
    Name         = "Walk Speed",
    Range        = {16, 150},
    Increment    = 1,
    Suffix       = " WS",
    CurrentValue = 16,
    Flag         = "WalkSpeedSlider",
    Callback     = function(v) CFG.WalkSpeed = v; ApplyMovement() end,
})

UtilTab:CreateSlider({
    Name         = "Jump Power",
    Range        = {50, 500},
    Increment    = 5,
    Suffix       = " JP",
    CurrentValue = 50,
    Flag         = "JumpPowerSlider",
    Callback     = function(v) CFG.JumpPower = v; ApplyMovement() end,
})

UtilTab:CreateToggle({
    Name         = "Infinite Jump",
    CurrentValue = false,
    Flag         = "InfiniteJumpToggle",
    Callback     = function(v) CFG.InfiniteJump = v; SetInfiniteJump(v) end,
})

UtilTab:CreateToggle({
    Name         = "Anti-AFK",
    CurrentValue = false,
    Flag         = "AntiAFKToggle",
    Callback     = function(v)
        CFG.AntiAFK = v
        SetAntiAFK(v)
        Notify("Anti-AFK", v and "Enabled." or "Disabled.", 3,
               v and "shield" or "shield-off")
    end,
})

UtilTab:CreateSection("Tools")

UtilTab:CreateInput({
    Name                     = "Redeem Promo Code",
    CurrentValue             = "",
    PlaceholderText          = "Enter code...",
    RemoveTextAfterFocusLost = false,
    Flag                     = "RedeemCodeInput",
    Callback                 = function(t)
        if t and t ~= "" then RedeemCode(t) end
    end,
})

UtilTab:CreateButton({
    Name     = "Upgrade Farm / Extend Fence",
    Callback = function()
        -- extendFence is the confirmed fence-upgrade remote (RemoteFunction)
        SafeInvoke(REM.extendFence)
        SafeFire(REM.AttemptUpgradeFarm)
        Notify("Farm", "Fence extend + farm upgrade sent.", 3, "arrow-up-circle")
    end,
})

UtilTab:CreateButton({
    Name     = "Claim Free Feep Egg",
    Callback = function()
        SafeFire(REM.ClaimFeepEgg)
        Notify("Eggs", "Feep egg claim sent!", 3, "gift")
    end,
})

UtilTab:CreateButton({
    Name     = "Process Trait Machine",
    Callback = function()
        local r = SafeInvoke(REM.processTraitMachine)
        Notify("Traits", r and "Fired!" or "Sent.", 3, "shuffle")
    end,
})

UtilTab:CreateButton({
    Name     = "Buy and Equip Best Lasso",
    Callback = function()
        SafeFire(REM.BuyLasso)
        task.wait(0.2)
        SafeFire(REM.EquipLasso)
        Notify("Lasso", "Purchased and equipped!", 3, "anchor")
    end,
})

UtilTab:CreateButton({
    Name     = "Re-cache All Remotes",
    Callback = function()
        CacheRemotes()
        local n = 0
        for _ in pairs(REM) do n = n + 1 end
        Notify("Remotes", "Cache refreshed. " .. n .. " found.", 4, "refresh-cw")
    end,
})

-- ------------------------------------------------------------
-- TAB 7: SESSION STATS
-- ------------------------------------------------------------
local StatsTab = Window:CreateTab("Stats", "bar-chart")

StatsTab:CreateSection("Session Analytics")

local StatsRateLabel    = StatsTab:CreateLabel("Catch rate: --", "trending-up")
local StatsSuccessLabel = StatsTab:CreateLabel("Success rate: --", "percent")
local StatsSessionLabel = StatsTab:CreateLabel("Session: 00:00  |  Best: None", "clock")

ST.StatusLabels.StatsRate    = StatsRateLabel
ST.StatusLabels.StatsSuccess = StatsSuccessLabel
ST.StatusLabels.StatsSession = StatsSessionLabel

StatsTab:CreateSection("Signature Map")

local SigCountLabel = StatsTab:CreateLabel("Captured remote sigs: 0", "radio")
ST.StatusLabels.SigCount = SigCountLabel

StatsTab:CreateButton({
    Name     = "Print Captured Signatures",
    Callback = function()
        local count = 0
        for k, v in pairs(ST.RemoteSigs) do
            count = count + 1
            local argStr = ""
            for i, a in ipairs(v) do
                argStr = argStr .. tostring(a)
                if i < #v then argStr = argStr .. ", " end
            end
            print(string.format("[CAT-SIG] %s(%s)", k, argStr))
        end
        Notify("Sigs", count .. " signatures printed to console.", 4, "terminal")
    end,
})

StatsTab:CreateButton({
    Name     = "Reset Session Stats",
    Callback = function()
        ST.Stats.CatchAttempts  = 0
        ST.Stats.CatchConfirmed = 0
        ST.Stats.SessionStart   = tick()
        ST.Stats.LastBestPet    = "None"
        ST.Stats.LastBestTier   = 0
        Notify("Stats", "Session stats reset.", 3, "rotate-ccw")
    end,
})

-- ------------------------------------------------------------
-- TAB 8: SETTINGS
-- ------------------------------------------------------------
local SettingsTab = Window:CreateTab("Settings", "settings")

SettingsTab:CreateSection("Appearance")

SettingsTab:CreateDropdown({
    Name            = "UI Theme",
    Options         = {"Default", "Amethyst", "Aqua", "Bloom",
                       "DarkBlue", "Serenity", "Ocean", "Green"},
    CurrentOption   = {"Default"},
    MultipleOptions = false,
    Flag            = "ThemeDropdown",
    Callback        = function(v)
        pcall(function() Window:ModifyTheme(v[1]) end)
    end,
})

SettingsTab:CreateSection("Keybinds")

-- NOTE: CreateKeybind CurrentKeybind accepts a string (different from ToggleUIKeybind)
SettingsTab:CreateKeybind({
    Name           = "Toggle GUI",
    CurrentKeybind = "RightShift",
    HoldToInteract = false,
    Flag           = "ToggleGUIKeybind",
    Callback       = function() end,
})

SettingsTab:CreateSection("Script Info")

do
    local remCount = 0
    local petCount = 0
    for _ in pairs(REM) do remCount = remCount + 1 end
    for _ in pairs(ST.PetRegistry) do petCount = petCount + 1 end

    SettingsTab:CreateParagraph({
        Title   = SCRIPT_NAME .. " v" .. VERSION,
        Content = "Executor: " .. EXECUTOR_NAME
               .. "\nRemotes cached: " .. remCount
               .. "\nPets in registry: " .. petCount
               .. "\nHook active: " .. tostring(ST.HookActive)
               .. "\n\nTabs: Auto Farm / Economy / Eggs / Events / ESP / Utility / Stats"
               .. "\n\nTip: Play one catch manually to train the minigame"
               .. "\nsignature validator before enabling Auto Farm.",
    })
end

-- ============================================================
-- S23  MAIN CONSOLIDATED LOOP
-- ============================================================

task.spawn(function()
    local timers = {
        collect   = 0, feed    = 0, breed  = 0,
        hatch     = 0, spin    = 0, esp    = 0,
        petcount  = 0, stats   = 0, move   = 0,
        weather   = 0, sell    = 0, fruits = 0,
        skeleton  = 0,
    }

    while ST.Running
    and (not getgenv or (getgenv().CAT_RUNNING ~= false
         and getgenv().CAT_SESSION == SESSION_TOKEN)) do
        local now = tick()

        -- Movement enforcement
        if now - timers.move > 1 then
            if CFG.WalkSpeed ~= 16 or CFG.JumpPower ~= 50 then ApplyMovement() end
            timers.move = now
        end

        -- Auto collect
        if CFG.AutoCollect and now - timers.collect > CFG.CollectInterval then
            task.spawn(CollectAllCash)
            timers.collect = now
        end

        -- Feed / food
        if now - timers.feed > CFG.FeedInterval then
            if CFG.AutoBuyFood  then task.spawn(BuyFood) end
            if CFG.AutoFeedPets then task.spawn(FeedAllPets) end
            timers.feed = now
        end

        -- Auto breed
        if CFG.AutoBreed and now - timers.breed > CFG.BreedDelay then
            task.spawn(SmartBreedCycle)
            timers.breed = now
        end

        -- Auto hatch
        if CFG.AutoHatch and now - timers.hatch > CFG.HatchInterval then
            task.spawn(InstantHatchAll)
            timers.hatch = now
        end

        -- Auto spin
        if CFG.AutoSpin and now - timers.spin > 60 then
            task.spawn(UseSpin)
            timers.spin = now
        end

        -- ESP update
        if CFG.ESPEnabled and now - timers.esp > 0.5 then
            UpdateESP()
            timers.esp = now
        end

        -- Pet count label
        if now - timers.petcount > 2.5 then
            local n = 0
            for _ in pairs(ST.PetRegistry) do n = n + 1 end
            UpdateLabel(ST.StatusLabels.PetCount, "Roaming pets in registry: " .. n, "map-pin")
            timers.petcount = now
        end

        -- Session stats
        if now - timers.stats > 3 then
            UpdateStatsDisplay()
            local sigCount = 0
            for _ in pairs(ST.RemoteSigs) do sigCount = sigCount + 1 end
            UpdateLabel(ST.StatusLabels.SigCount, "Captured remote sigs: " .. sigCount, "radio")
            timers.stats = now
        end

        -- Weather detection
        if now - timers.weather > 10 then
            task.spawn(function()
                DetectWeather()
                local wpets = GetWeatherPetsForCurrent()
                local wpStr = #wpets > 0
                    and table.concat(wpets, ", ")
                    or "None special"
                UpdateLabel(ST.StatusLabels.Weather,
                    "Weather: " .. ST.Weather.Current, "cloud")
                UpdateLabel(ST.StatusLabels.WeatherPets,
                    "Active spawns: " .. wpStr, "paw-print")

                if CFG.AutoTotem and ST.Weather.Current ~= CFG.TargetWeather then
                    UseWeatherTotem()
                end
            end)
            timers.weather = now
        end

        -- Auto sell
        if now - timers.sell > 45 then
            if CFG.AutoSellPets then task.spawn(SellPets) end
            if CFG.AutoSellEggs then task.spawn(SellEggs) end
            timers.sell = now
        end

        -- Auto fruit collect
        if CFG.AutoFruitCollect and now - timers.fruits > 20 then
            task.spawn(CollectFruits)
            timers.fruits = now
        end

        -- Skeleton event countdown
        if now - timers.skeleton > 5 then
            local sinceLastSeen = now - (ST.Skeleton.LastSeen > 0 and ST.Skeleton.LastSeen or now)
            local timeToNext = SKELETON_INTERVAL - (sinceLastSeen % SKELETON_INTERVAL)
            UpdateLabel(ST.StatusLabels.Skeleton,
                "Skeleton event: ~" .. FormatTime(timeToNext) .. " to next", "skull")

            if CFG.SkeletonAlert and timeToNext < 120 and timeToNext > 90 then
                Notify("Skeleton Event", "Starting in ~" .. math.floor(timeToNext) .. "s!", 8, "alert-triangle")
            end
            timers.skeleton = now
        end

        task.wait(0.1)
    end
end)

-- ============================================================
-- S24  AUTO FARM LOOP
-- ============================================================

task.spawn(function()
    while ST.Running
    and (not getgenv or (getgenv().CAT_RUNNING ~= false
         and getgenv().CAT_SESSION == SESSION_TOKEN)) do
        if CFG.AutoFarm then
            task.spawn(RunCatchCycle)
            task.wait(Jitter(math.max(0.5, CFG.FarmDelay)))
        else
            task.wait(0.5)
        end
    end
end)

-- Tame All loop runs on its own thread, separate from single-catch farm
task.spawn(function()
    local tameTimer = 0
    while ST.Running
    and (not getgenv or (getgenv().CAT_RUNNING ~= false
         and getgenv().CAT_SESSION == SESSION_TOKEN)) do
        local now = tick()
        if CFG.TameAll and now - tameTimer >= CFG.TameAllDelay then
            tameTimer = now
            task.spawn(TameAllPets)
        end
        task.wait(0.25)
    end
end)

-- ============================================================
-- S25  RESPAWN HANDLER
-- ============================================================

ST.Connections.CharacterAdded = Player.CharacterAdded:Connect(function()
    task.wait(1.5)
    ApplyMovement()
    if CFG.InfiniteJump  then SetInfiniteJump(true) end
    if CFG.AntiAFK       then SetAntiAFK(true) end
    task.wait(0.5)
    SafeFire(REM.ClientReady)
    Notify("Character", "Respawned. Systems restored.", 3, "user")
end)

-- ============================================================
-- S26  INITIALIZATION
-- ============================================================

do
    task.wait(0.5)
    SafeFire(REM.ClientReady)
    Rayfield:LoadConfiguration()

    -- Restore Xeno persisted config
    if IS_XENO and Xeno and Xeno.GetGlobal then
        pcall(function()
            local saved = Xeno.GetGlobal("CATConfig_v200")
            if type(saved) == "table" then
                for k, v in pairs(saved) do
                    if CFG[k] ~= nil and type(CFG[k]) == type(v) then
                        CFG[k] = v
                    end
                end
            end
        end)
    end

    -- Initial weather detection
    task.defer(DetectWeather)

    local remCount, petCount = 0, 0
    for _ in pairs(REM)           do remCount  = remCount  + 1 end
    for _ in pairs(ST.PetRegistry) do petCount = petCount + 1 end

    Notify(
        SCRIPT_NAME .. " v" .. VERSION,
        remCount .. " remotes  |  " .. petCount .. " pets found\n"
        .. "RightShift to toggle GUI\n"
        .. "Play one catch to train signature.",
        8,
        "paw-print"
    )
    print(string.format("[CAT] v%s init: %d remotes, %d pets, hook=%s",
        VERSION, remCount, petCount, tostring(ST.HookActive)))
end

-- Xeno config auto-save every 30s
if IS_XENO and Xeno and Xeno.SetGlobal then
    task.spawn(function()
        while ST.Running
        and (not getgenv or (getgenv().CAT_RUNNING ~= false
             and getgenv().CAT_SESSION == SESSION_TOKEN)) do
            task.wait(30)
            pcall(function() Xeno.SetGlobal("CATConfig_v200", CFG) end)
        end
    end)
end

-- ============================================================
-- END OF SCRIPT  v2.0.0
-- ============================================================
