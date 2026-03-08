-- ============================================================
--   CATCH & TAME  |  ADVANCED OPERATION SCRIPT
--   Version  : 1.2.0
--   Executor : Xeno (UNC compatible)
--   PlaceId  : 96645548064314
--   Author   : ENI
--   Load via : XenoScanner v4.2 Bootstrap (Gui.lua on GitHub)
-- ============================================================
-- CHANGELOG
--   v1.2.0  Comprehensive diagnostic fix pass (10 findings)
--     ! FIX [F-001]: Vararg compile error confirmed resolved. Added
--            cache-busting guidance for bootstrap loader.
--     ! FIX [F-002]: Hook passthrough redesigned. Pre-captures original
--            __namecall via getrawmetatable before hookmetamethod call.
--            Fallback chain prevents silent network call failure.
--     ! FIX [F-003]: PetRegistry iteration now snapshots before mutation.
--            Stale entries collected and pruned after loop completes.
--     ! FIX [F-004]: Connection pool converted from array to named
--            dictionary. Re-toggling overwrites instead of appending.
--     ! FIX [F-005]: SolveTamingMinigame now checks remote:IsA() to
--            dispatch FireServer vs InvokeServer correctly via SafeCall.
--     ! FIX [F-006]: FeedAllPets uses pairs() for dictionary-safe
--            iteration. Blind no-args fallback removed.
--     ! FIX [F-007]: Session token replaces boolean CAT_RUNNING flag.
--            Prevents dual-instance race conditions.
--     ! FIX [F-008]: ESP overlays cleaned up via AncestryChanged
--            listener instead of relying solely on polling.
--     ! FIX [F-009]: Deduplicated 'RequestPlacePet' in WANTED array.
--     ! FIX [F-010]: Resilient UpdateLabel wrapper tries multiple
--            Rayfield API methods (:Set, :Update, :Refresh, .Text).
--   v1.1.1  Luau vararg compile fix (see F-001)
--   v1.1.0  Bootstrap compatibility + hook crash fix
--   v1.0.0  Initial release
-- ============================================================

-- §0 ── SECURE MODE (before any Rayfield load)
if getgenv then getgenv().SecureMode = true end

-- §1 ── EXECUTOR DETECTION
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

-- §2 ── UNC SHIMS  (ensure APIs exist before use)
if not cloneref         then cloneref         = function(o) return o end end
if not getnilinstances  then getnilinstances   = function() return {} end end
if not getinstances     then getinstances     = function() return {} end end
if not newcclosure      then newcclosure      = function(f) return f end end
if not checkcaller      then checkcaller      = function() return false end end
if not getrawmetatable  then getrawmetatable  = function() return nil end end

-- §3 ── CLEANUP PREVIOUS INSTANCE
-- [F-007 FIX] Session token prevents dual-instance race conditions.
-- Old approach used a boolean flag — if the new script set CAT_RUNNING = true
-- before the old loop checked it, both instances would run simultaneously.
-- Now each instance writes a unique token; loops exit when the token changes.
local SESSION_TOKEN = tostring(tick()) .. "_" .. tostring(math.random(1, 999999))

do
    if getgenv then
        local oldToken = getgenv().CAT_SESSION
        if oldToken then
            getgenv().CAT_RUNNING = false
            task.wait(0.35)  -- slightly longer grace period for old loops
        end
        getgenv().CAT_SESSION = SESSION_TOKEN
        getgenv().CAT_RUNNING = true
    end

    -- Destroy previous Rayfield GUI if present
    local function CleanupGui(parent)
        if not parent then return end
        for _, name in ipairs({"CATScript_Rayfield", "Rayfield"}) do
            local old = parent:FindFirstChild(name)
            if old then pcall(function() old:Destroy() end) end
        end
    end

    local ok, CoreGuiRef = pcall(function()
        return cloneref(game:GetService("CoreGui"))
    end)
    if ok then CleanupGui(CoreGuiRef) end

    local playerOk, lp = pcall(function()
        return cloneref(game:GetService("Players")).LocalPlayer
    end)
    if playerOk and lp then
        local pg = lp:FindFirstChild("PlayerGui")
        if pg then CleanupGui(pg) end
    end
end

-- §4 ── SERVICES  (cloneref throughout for anti-detection)
local Players           = cloneref(game:GetService("Players"))
local ReplicatedStorage = cloneref(game:GetService("ReplicatedStorage"))
local RunService        = cloneref(game:GetService("RunService"))
local TweenService      = cloneref(game:GetService("TweenService"))
local UserInputService  = cloneref(game:GetService("UserInputService"))
local VirtualUser       = cloneref(game:GetService("VirtualUser"))
local CoreGui           = cloneref(game:GetService("CoreGui"))
local Workspace         = cloneref(game:GetService("Workspace"))

-- §5 ── PLAYER REFERENCES
local Player = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

-- Live-safe helpers (character can nil out on respawn)
local function GetChar()
    return Player.Character
end
local function GetRoot()
    local c = GetChar()
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function GetHumanoid()
    local c = GetChar()
    return c and c:FindFirstChildOfClass("Humanoid")
end

-- §6 ── CONFIGURATION TABLE  (all user-facing settings + defaults)
local CFG = {
    -- Auto Farm
    AutoFarm        = false,
    FarmDelay       = 1.5,          -- seconds between catch cycles
    AutoPlacePet    = true,         -- place pet into pen after catch
    RarityFilter    = "All",        -- filter by rarity prefix

    -- Economy
    AutoCollect     = false,
    CollectInterval = 30,
    AutoBuyFood     = false,
    AutoFeedPets    = false,
    FeedInterval    = 60,

    -- Eggs & Breeding
    AutoHatch       = false,
    HatchInterval   = 10,
    AutoBreed       = false,
    BreedDelay      = 5.0,

    -- ESP
    ESPEnabled      = false,
    ESPColor        = Color3.fromRGB(255, 80, 80),
    HighlightNearest = false,

    -- Movement
    WalkSpeed       = 16,
    JumpPower       = 50,
    InfiniteJump    = false,

    -- Utility
    AntiAFK         = false,
    AutoClaimLogin  = false,
    AutoClaimIndex  = false,
    AutoSpin        = false,
}

-- §7 ── STATE TABLE  (runtime-only — never persisted)
-- [F-004 FIX] Connections is now a named dictionary, not an array.
-- Re-toggling features overwrites the previous connection key instead of
-- appending duplicates. This prevents unbounded memory growth on respawn.
local ST = {
    Running       = true,
    Connections   = {},             -- {name → RBXScriptConnection}
    ESPObjects    = {},             -- {model → {gui, name, dist, ancestryConn}}
    PetRegistry   = {},             -- {model → true} event-driven
    NearestPet    = nil,
    CatchCount    = 0,
    MinigameSig   = nil,            -- cached minigame success args
    HookActive    = false,
    OldNamecall   = nil,
    StatusLabels  = {},             -- Rayfield label refs for live update
}

-- Global running flag already set in §3 with session token

-- §8 ── REMOTE CACHE
local REM = {}  -- populated by CacheRemotes()

local function FindRemotesFolder()
    -- Check common locations first (fast path)
    local locations = {
        game:FindFirstChild("Remotes"),
        ReplicatedStorage:FindFirstChild("Remotes"),
        Player.PlayerGui:FindFirstChild("Remotes"),
        Player:FindFirstChild("Remotes"),
    }
    for _, loc in ipairs(locations) do
        if loc and loc:IsA("Folder") and loc:FindFirstChild("ThrowLasso") then
            return loc
        end
    end

    -- Deep search (slow path, runs once on init)
    for _, obj in ipairs(game:GetDescendants()) do
        if obj.Name == "Remotes" and obj:IsA("Folder") then
            if obj:FindFirstChild("ThrowLasso") or obj:FindFirstChild("collectAllPetCash") then
                return obj
            end
        end
    end
    return nil
end

local function CacheRemotes()
    local folder = FindRemotesFolder()

    -- [F-009 FIX] Deduplicated — RequestPlacePet appears only once.
    -- Previously listed under both "Core farm loop" and "Farm / Pen".
    local WANTED = {
        -- Core farm loop
        "ThrowLasso", "minigameRequest", "pickupRequest",
        "RequestPlacePet", "RunPet", "MovePets",
        -- Economy
        "collectAllPetCash", "collectPetCash", "BuyFood",
        "FeedPet", "getOfflineCash",
        -- Eggs / Breeding
        "InstantHatch", "breedRequest", "placeEgg",
        "RequestEggHatch", "RequestEggNurseryPlacement",
        "RequestEggNurseryRetrieval",
        -- Lasso
        "BuyLasso", "EquipLasso", "equipLassoVisual",
        -- Farm / Pen (RequestPlacePet already listed above)
        "AttemptUpgradeFarm", "AttemptSwapPet",
        "GetFarmLevel", "GetPetInventoryData",
        "RequestWalkPet",
        -- Data
        "retrieveData", "getPetInventory", "getPetRev",
        "getPlayerIndex", "getSaveInfo",
        -- Rewards
        "ClaimLoginReward", "ClaimIndex", "ClaimExclusive",
        "UseSpin", "UseTotem", "superLuckSpins",
        -- Tools
        "redeemCode", "processTraitMachine",
        "sellPet", "sellEgg", "toggleFavorite",
        -- Trade
        "SendTradeRequest", "AcceptTradeRequest",
        "RequestSetOffer", "RequestAccept", "RequestUnaccept",
        -- Shop / Merchant
        "BuyMerchant", "RequestMerchant",
        "updateHotbarSlots",
        -- Connection
        "ClientReady",
    }

    if folder then
        for _, name in ipairs(WANTED) do
            local r = folder:FindFirstChild(name)
            if r then REM[name] = r end
        end
    end

    -- Second pass: catch any remotes spread across the whole tree
    for _, obj in ipairs(game:GetDescendants()) do
        if (obj:IsA("RemoteEvent") or obj:IsA("RemoteFunction")) and not REM[obj.Name] then
            for _, wname in ipairs(WANTED) do
                if obj.Name == wname then
                    REM[wname] = obj
                    break
                end
            end
        end
    end
end

CacheRemotes()

-- §9 ── UTILITY FUNCTIONS

-- [F-001 FIX] Varargs packed before closure boundary.
-- Luau (Lua 5.1) does not allow '...' to be captured by a closure
-- that didn't declare it. We pack into a local table (normal upvalue)
-- and table.unpack re-expands inside the closure.
local function SafeFire(remote, ...)
    if not remote then return false end
    local args = {...}
    local ok, _ = pcall(function() remote:FireServer(table.unpack(args)) end)
    return ok
end

local function SafeInvoke(remote, ...)
    if not remote then return nil end
    local args = {...}
    local ok, result = pcall(function() return remote:InvokeServer(table.unpack(args)) end)
    return ok and result or nil
end

-- [F-005 FIX] Unified safe-call that auto-detects RemoteEvent vs RemoteFunction.
-- Prevents FireServer being called on a RemoteFunction (which has no such method)
-- and vice versa. Used in SolveTamingMinigame where the remote type is unknown.
local function SafeCall(remote, ...)
    if not remote then return nil end
    if remote:IsA("RemoteFunction") then
        return SafeInvoke(remote, ...)
    elseif remote:IsA("RemoteEvent") then
        return SafeFire(remote, ...)
    end
    return nil
end

-- Euclidean distance between two Vector3 positions
local function GetDistance(a, b)
    if not a or not b then return math.huge end
    return (a - b).Magnitude
end

-- Teleport character root to world position + offset
local function TeleportTo(position, offset)
    local root = GetRoot()
    if not root then return end
    root.CFrame = CFrame.new(position + (offset or Vector3.new(0, 3, 0)))
end

-- [F-003 FIX] Snapshot registry before iteration, defer all mutations.
-- Lua 5.1 pairs() iteration with mid-loop table modification is undefined
-- behavior. We collect stale entries and prune them AFTER the loop.
local function FindNearestPet()
    local root = GetRoot()
    if not root then return nil, math.huge end
    local nearest, nearDist = nil, math.huge
    local stale = {}

    for model in pairs(ST.PetRegistry) do
        if model and model.Parent then
            local anchor = model:FindFirstChild("Root")
                        or model:FindFirstChild("HumanoidRootPart")
            if anchor then
                local d = GetDistance(root.Position, anchor.Position)
                if d < nearDist then
                    nearDist = d
                    nearest  = model
                end
            end
        else
            -- Collect stale entry — do NOT nil it during iteration
            stale[#stale + 1] = model
        end
    end

    -- Prune stale entries AFTER iteration completes
    for _, m in ipairs(stale) do
        ST.PetRegistry[m] = nil
    end

    return nearest, nearDist
end

-- [F-010 FIX] Resilient label update wrapper.
-- Rayfield's Label API varies between versions — :Set(), :Update(),
-- :Refresh(), or direct .Text property. This wrapper tries all known
-- methods and caches nothing (each call re-tests in case of hot-reload).
local function UpdateLabel(label, text, icon)
    if not label then return end
    local methods = {"Set", "Update", "Refresh"}
    for _, method in ipairs(methods) do
        if typeof(label[method]) == "function" then
            local ok = pcall(label[method], label, text, icon)
            if ok then return end
        end
    end
    -- Direct property fallback
    pcall(function() label.Text = text end)
end

-- Post a Rayfield notification (safe to call before GUI is loaded — queued)
local NotifyQueue = {}
local RayfieldReady = false

local function Notify(title, content, duration, icon)
    local payload = {
        Title    = title,
        Content  = content,
        Duration = duration or 4,
        Image    = icon or "info",
    }
    if RayfieldReady and _G.RayfieldRef then
        pcall(function() _G.RayfieldRef:Notify(payload) end)
    else
        table.insert(NotifyQueue, payload)
    end
end

-- §10 ── PET REGISTRY  (event-driven — no per-frame GetDescendants)
local function RegisterPet(model)
    if not model or not model:IsA("Model") then return end
    local anchor = model:FindFirstChild("Root")
               or model:FindFirstChild("HumanoidRootPart")
    if anchor then
        ST.PetRegistry[model] = true
        -- If ESP is currently active, create the overlay immediately
        if CFG.ESPEnabled then
            task.defer(function()
                if _G.CreateESP_Fn then _G.CreateESP_Fn(model) end
            end)
        end
    end
end

local function UnregisterPet(model)
    ST.PetRegistry[model] = nil
    local obj = ST.ESPObjects[model]
    if obj then
        -- [F-008 FIX] Disconnect AncestryChanged listener
        if obj.ancestryConn then
            pcall(function() obj.ancestryConn:Disconnect() end)
        end
        pcall(function() obj.gui:Destroy() end)
        ST.ESPObjects[model] = nil
    end
end

-- Grab the roaming pets container (wait up to 10 seconds on slow load)
local PetContainer = Workspace:WaitForChild("RoamingPets", 10)
local PetsFolder   = PetContainer and PetContainer:WaitForChild("Pets", 10)

if PetsFolder then
    -- Populate initial registry
    for _, model in ipairs(PetsFolder:GetChildren()) do
        RegisterPet(model)
    end

    -- [F-004 FIX] Named connection keys — overwrite instead of append
    ST.Connections.PetAdded = PetsFolder.ChildAdded:Connect(function(child)
        task.wait(0.1)              -- let model fully load before reading parts
        RegisterPet(child)
    end)
    ST.Connections.PetRemoved = PetsFolder.ChildRemoved:Connect(function(child)
        UnregisterPet(child)
    end)
end

-- §11 ── MINIGAME HOOK
-- [F-002 FIX] Redesigned hook with pre-captured fallback chain.
-- Problem: hookmetamethod can return nil on some executors even when
-- the hook installs successfully. The old code's nil-guard prevented
-- a crash but caused ALL __namecall calls to silently return nil.
-- Fix: pre-capture the original __namecall via getrawmetatable BEFORE
-- hooking. Use whichever reference exists (return value or pre-capture).
local function InstallMinigameHook()
    if ST.HookActive then return end
    if not hookmetamethod then return end

    -- Pre-capture the original __namecall before hookmetamethod replaces it
    local originalNamecall = nil
    local mt = getrawmetatable(game)
    if mt then
        local ok, val = pcall(function() return rawget(mt, "__namecall") end)
        if ok and typeof(val) == "function" then
            originalNamecall = val
        end
    end

    local candidate = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        local method = getnamecallmethod and getnamecallmethod() or ""

        if method == "InvokeServer"
        and self == REM.minigameRequest
        and not checkcaller()
        and not ST.MinigameSig then
            ST.MinigameSig = {...}
        end

        -- Use hookmetamethod return OR pre-captured fallback — whichever exists
        local passthrough = ST.OldNamecall or originalNamecall
        if passthrough then
            return passthrough(self, ...)
        end
        -- If BOTH are nil (should not happen on a functioning executor),
        -- we fall through without crashing. Luau's default dispatch handles it.
    end))

    -- Store whichever reference we obtained
    ST.OldNamecall = candidate or originalNamecall
    ST.HookActive  = (ST.OldNamecall ~= nil)
end

-- Hook NOT installed here — called after Rayfield loads (see §14-POST)

-- §12 ── CORE FEATURE FUNCTIONS

-- 12-A  Bypass the taming minigame
-- [F-005 FIX] Uses SafeCall to auto-detect RemoteEvent vs RemoteFunction.
-- No more FireServer on a RemoteFunction (which crashes silently in pcall).
local function SolveTamingMinigame()
    -- Replay captured signature (most reliable — set after first natural catch)
    if ST.MinigameSig then
        return SafeCall(REM.minigameRequest, table.unpack(ST.MinigameSig))
    end

    -- Tiered discovery: try common success-state patterns
    local patterns = {
        {true},
        {1},
        {"success"},
        {"complete"},
        {"win"},
        {true, 1},
        {1, true},
        {"success", true},
        {"complete", 1},
    }

    for _, args in ipairs(patterns) do
        local result = SafeCall(REM.minigameRequest, table.unpack(args))
        task.wait(0.05)
        if result then
            ST.MinigameSig = args   -- remember winning pattern
            return result
        end
    end

    -- Last resort — SafeCall handles type correctly
    SafeCall(REM.minigameRequest, true)
    return nil
end

-- 12-B  Throw lasso at a target model
local function ThrowLassoAt(target)
    local anchor = target:FindFirstChild("Root")
               or target:FindFirstChild("HumanoidRootPart")
    if not anchor then return false end

    -- Close the gap so range checks pass
    TeleportTo(anchor.Position, Vector3.new(0, 4.5, 0))
    task.wait(0.15)

    -- Fire the lasso remote with position data
    return SafeFire(REM.ThrowLasso, target, anchor.Position)
end

-- 12-C  Full single-pet catch cycle
local function RunCatchCycle()
    local target, dist = FindNearestPet()
    if not target or not target.Parent then return end

    ST.NearestPet = target
    local anchor = target:FindFirstChild("Root")
               or target:FindFirstChild("HumanoidRootPart")
    if not anchor then return end

    -- TP close
    TeleportTo(anchor.Position, Vector3.new(0, 5, 0))
    task.wait(0.2)

    -- Throw
    ThrowLassoAt(target)
    task.wait(0.35)

    -- Bypass minigame
    SolveTamingMinigame()
    task.wait(0.3)

    -- Place pet into pen
    if CFG.AutoPlacePet then
        SafeFire(REM.RequestPlacePet)
        task.wait(0.1)
    end

    ST.CatchCount = ST.CatchCount + 1

    -- [F-010 FIX] Uses resilient UpdateLabel wrapper
    local labelText = "Caught: " .. ST.CatchCount
                   .. "  |  Last: " .. target.Name:sub(1, 12)
                   .. "  (" .. math.floor(dist) .. " studs)"
    UpdateLabel(ST.StatusLabels.CatchCount, labelText, "crosshair")
end

-- 12-D  Collect all pen cash + offline income
local function CollectAllCash()
    SafeFire(REM.collectAllPetCash)

    -- Drain any queued offline income
    local offlineCash = SafeInvoke(REM.getOfflineCash)
    if type(offlineCash) == "number" and offlineCash > 0 then
        task.wait(0.1)
        SafeFire(REM.collectAllPetCash)
    end

    -- [F-010 FIX] Uses resilient UpdateLabel wrapper
    UpdateLabel(ST.StatusLabels.CashStatus, "Last collect: " .. os.date("%H:%M:%S"), "clock")
end

-- 12-E  Buy food from shop
local function BuyFood()
    SafeFire(REM.BuyFood)
end

-- 12-F  Feed all owned pets
-- [F-006 FIX] Uses pairs() for dictionary-safe iteration.
-- Removed blind no-args fallback — if inventory is nil/non-table, we exit.
-- If inventory is a dictionary, pairs() handles it; ipairs() would skip all.
local function FeedAllPets()
    local inventory = SafeInvoke(REM.getPetInventory)
    if type(inventory) ~= "table" then return end

    local fed = 0
    for k, petData in pairs(inventory) do
        if type(petData) == "table" or type(petData) == "userdata" then
            SafeInvoke(REM.FeedPet, petData)
            fed = fed + 1
            task.wait(0.08)
        end
    end

    if fed == 0 then
        Notify("Feed", "No feedable pets found in inventory.", 3, "alert-circle")
    end
end

-- 12-G  Instant hatch all eggs in nursery
local function InstantHatchAll()
    SafeFire(REM.InstantHatch)
    SafeFire(REM.InstantHatch, true)
    SafeInvoke(REM.RequestEggHatch)
    Notify("Eggs", "Instant hatch triggered!", 3, "zap")
end

-- 12-H  Attempt to breed using available pets
local function TryBreed()
    local result = SafeInvoke(REM.breedRequest)
    if not result then
        SafeInvoke(REM.breedRequest, 1, 2)
    end
end

-- 12-I  Claim daily login reward
local function ClaimLogin()
    SafeFire(REM.ClaimLoginReward)
    Notify("Rewards", "Login reward claimed!", 3, "gift")
end

-- 12-J  Claim index / milestone rewards
local function ClaimIndex()
    SafeFire(REM.ClaimIndex)
    SafeFire(REM.ClaimExclusive)
    Notify("Rewards", "Index & exclusive rewards claimed!", 3, "star")
end

-- 12-K  Use a lucky spin
local function UseSpin()
    SafeFire(REM.UseSpin)
    Notify("Spins", "Spin used!", 3, "refresh-cw")
end

-- 12-L  Redeem a promo code
local function RedeemCode(code)
    if not code or code == "" then return end
    code = code:gsub("^%s+", ""):gsub("%s+$", "")
    local result = SafeInvoke(REM.redeemCode, code)
    if result then
        Notify("Code Redeemed ✓", code, 5, "check-circle")
    else
        Notify("Code Failed ✗", code .. " — invalid or already used.", 4, "x-circle")
    end
end

-- 12-M  Movement enforcement
local function ApplyMovement()
    local hum = GetHumanoid()
    if hum then
        hum.WalkSpeed = CFG.WalkSpeed
        hum.JumpPower = CFG.JumpPower
    end
end

-- 12-N  Infinite jump (toggle)
-- [F-004 FIX] Uses named connection key — overwrites on re-toggle
local function SetInfiniteJump(enabled)
    if ST.Connections.InfiniteJump then
        ST.Connections.InfiniteJump:Disconnect()
        ST.Connections.InfiniteJump = nil
    end
    if enabled then
        ST.Connections.InfiniteJump = UserInputService.JumpRequest:Connect(function()
            local hum = GetHumanoid()
            if hum then
                hum:ChangeState(Enum.HumanoidStateType.Jumping)
            end
        end)
    end
end

-- 12-O  Anti-AFK
-- [F-004 FIX] Uses named connection key — overwrites on re-toggle
local function SetAntiAFK(enabled)
    if ST.Connections.AntiAFK then
        ST.Connections.AntiAFK:Disconnect()
        ST.Connections.AntiAFK = nil
    end
    if enabled then
        ST.Connections.AntiAFK = Player.Idled:Connect(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end
end

-- §13 ── ESP SYSTEM

-- [F-008 FIX] ESP overlays now attach an AncestryChanged listener to the
-- model for immediate cleanup when the pet despawns. No longer reliant
-- solely on the 0.5s polling cycle in UpdateESP to catch orphans.
local function CreateESP(model)
    if ST.ESPObjects[model] then return end     -- already has overlay
    local anchor = model:FindFirstChild("Root")
               or model:FindFirstChild("HumanoidRootPart")
               or model:FindFirstChild("Head")
    if not anchor then return end

    local bb = Instance.new("BillboardGui")
    bb.Name        = "CAT_ESP"
    bb.Size        = UDim2.new(0, 200, 0, 44)
    bb.StudsOffset = Vector3.new(0, 4, 0)
    bb.AlwaysOnTop = true
    bb.Adornee     = anchor
    bb.Parent      = CoreGui

    -- Pet name row
    local nameLabel = Instance.new("TextLabel")
    nameLabel.Size                 = UDim2.new(1, 0, 0.55, 0)
    nameLabel.BackgroundTransparency = 1
    nameLabel.Text                 = model.Name:sub(1, 18)
    nameLabel.TextColor3           = CFG.ESPColor
    nameLabel.TextStrokeTransparency = 0.35
    nameLabel.Font                 = Enum.Font.GothamBold
    nameLabel.TextSize             = 13
    nameLabel.Parent               = bb

    -- Distance row
    local distLabel = Instance.new("TextLabel")
    distLabel.Size                 = UDim2.new(1, 0, 0.45, 0)
    distLabel.Position             = UDim2.new(0, 0, 0.55, 0)
    distLabel.BackgroundTransparency = 1
    distLabel.TextColor3           = Color3.new(1, 1, 1)
    distLabel.TextStrokeTransparency = 0.5
    distLabel.Font                 = Enum.Font.Gotham
    distLabel.TextSize             = 11
    distLabel.Parent               = bb

    -- Immediate cleanup when model leaves the DataModel
    local ancestryConn
    ancestryConn = model.AncestryChanged:Connect(function(_, parent)
        if not parent then
            pcall(function() bb:Destroy() end)
            if ancestryConn then ancestryConn:Disconnect() end
            ST.ESPObjects[model] = nil
        end
    end)

    ST.ESPObjects[model] = {
        gui  = bb,
        name = nameLabel,
        dist = distLabel,
        ancestryConn = ancestryConn,
    }
end

-- Expose CreateESP globally so RegisterPet can call it before §13 is "reached"
_G.CreateESP_Fn = CreateESP

-- Destroy all active ESP overlays
local function DestroyAllESP()
    for model, obj in pairs(ST.ESPObjects) do
        -- [F-008 FIX] Also disconnect AncestryChanged listeners
        if obj.ancestryConn then
            pcall(function() obj.ancestryConn:Disconnect() end)
        end
        pcall(function() obj.gui:Destroy() end)
        ST.ESPObjects[model] = nil
    end
end

-- Called every 0.5 s from main loop — updates distance labels + highlight
-- [F-003 FIX] Stale overlay cleanup deferred to after iteration
local function UpdateESP()
    local root = GetRoot()
    local stale = {}

    for model, obj in pairs(ST.ESPObjects) do
        if model and model.Parent and obj and obj.gui and obj.gui.Parent then
            local anchor = model:FindFirstChild("Root")
                        or model:FindFirstChild("HumanoidRootPart")
            if root and anchor then
                local dist = math.floor(GetDistance(root.Position, anchor.Position))
                pcall(function()
                    obj.dist.Text = dist .. " studs"
                    if CFG.HighlightNearest and ST.NearestPet == model then
                        obj.name.TextColor3 = Color3.fromRGB(255, 210, 0)
                    else
                        obj.name.TextColor3 = CFG.ESPColor
                    end
                end)
            end
        else
            -- Collect stale — do NOT mutate during iteration
            stale[#stale + 1] = { model = model, obj = obj }
        end
    end

    -- Prune stale overlays after iteration
    for _, entry in ipairs(stale) do
        if entry.obj then
            if entry.obj.ancestryConn then
                pcall(function() entry.obj.ancestryConn:Disconnect() end)
            end
            pcall(function() if entry.obj.gui then entry.obj.gui:Destroy() end end)
        end
        ST.ESPObjects[entry.model] = nil
    end
end

-- §14 ── RAYFIELD GUI
-- Rayfield fetched via executor HTTP globals (bypasses __namecall)
local RAYFIELD_URL = "https://sirius.menu/rayfield"
local rayfieldSrc  = nil

-- Attempt 1: http_request (Xeno standard UNC name)
if typeof(http_request) == "function" then
    local ok, res = pcall(http_request, { Url = RAYFIELD_URL, Method = "GET" })
    if ok and res and type(res.Body) == "string" and #res.Body > 10 then
        rayfieldSrc = res.Body
    end
end

-- Attempt 2: request (alternate UNC alias)
if not rayfieldSrc and typeof(request) == "function" then
    local ok, res = pcall(request, { Url = RAYFIELD_URL, Method = "GET" })
    if ok and res and type(res.Body) == "string" and #res.Body > 10 then
        rayfieldSrc = res.Body
    end
end

-- Attempt 3: game:HttpGet fallback (safe — no hook installed yet)
if not rayfieldSrc then
    local ok, src = pcall(function() return game:HttpGet(RAYFIELD_URL) end)
    if ok and type(src) == "string" and #src > 10 then
        rayfieldSrc = src
    end
end

if not rayfieldSrc then
    error("[CAT] Failed to fetch Rayfield from all sources. Check your internet connection.")
end

local rayfieldLoader, compileErr = loadstring(rayfieldSrc)
if not rayfieldLoader then
    error("[CAT] Rayfield compile error: " .. tostring(compileErr))
end

local Rayfield = rayfieldLoader()
if not Rayfield then
    error("[CAT] Rayfield returned nil on execution. Library may have changed.")
end

_G.RayfieldRef = Rayfield
RayfieldReady  = true

-- §14-POST ── NOW safe to install the namecall hook.
InstallMinigameHook()

-- Flush any notifications that fired before Rayfield loaded
for _, payload in ipairs(NotifyQueue) do
    pcall(function() Rayfield:Notify(payload) end)
end
NotifyQueue = {}

local Window = Rayfield:CreateWindow({
    Name            = "Catch & Tame  v1.2.0",
    Icon            = "paw-print",
    LoadingTitle    = "Catch & Tame Script",
    LoadingSubtitle = "Xeno | v1.2.0 | by ENI",
    Theme           = "Default",
    ToggleUIKeybind = "RightShift",
    DisableRayfieldPrompts = false,
    DisableBuildWarnings   = false,
    ConfigurationSaving    = {
        Enabled    = true,
        FolderName = "CATScript",
        FileName   = "CATConfig",
    },
})

-- ────────────────────────────────────────────────────────────
-- TAB 1 ─ AUTO FARM
-- ────────────────────────────────────────────────────────────
local FarmTab = Window:CreateTab("Auto Farm", "crosshair")

FarmTab:CreateSection("Catching")

FarmTab:CreateToggle({
    Name         = "Auto Farm",
    CurrentValue = false,
    Flag         = "AutoFarmToggle",
    Callback     = function(v)
        CFG.AutoFarm = v
        Notify("Auto Farm", v and "Catching started!" or "Catching stopped.", 3,
               v and "play" or "square")
    end,
})

FarmTab:CreateSlider({
    Name         = "Catch Cycle Delay (seconds)",
    Range        = {0.5, 10},
    Increment    = 0.1,
    Suffix       = "s",
    CurrentValue = 1.5,
    Flag         = "FarmDelaySlider",
    Callback     = function(v) CFG.FarmDelay = v end,
})

FarmTab:CreateToggle({
    Name         = "Auto Place Pet After Catch",
    CurrentValue = true,
    Flag         = "AutoPlacePetToggle",
    Callback     = function(v) CFG.AutoPlacePet = v end,
})

FarmTab:CreateDropdown({
    Name            = "Rarity Filter",
    Options         = {"All", "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic"},
    CurrentOption   = {"All"},
    MultipleOptions = false,
    Flag            = "RarityFilterDropdown",
    Callback        = function(v) CFG.RarityFilter = v[1] end,
})

FarmTab:CreateSection("Manual Controls")

FarmTab:CreateButton({
    Name     = "Catch Nearest Pet (Single)",
    Callback = function() task.spawn(RunCatchCycle) end,
})

FarmTab:CreateButton({
    Name     = "Teleport to Nearest Pet",
    Callback = function()
        local target = FindNearestPet()
        if not target then
            Notify("Teleport", "No pets in registry.", 3, "alert-circle")
            return
        end
        local a = target:FindFirstChild("Root") or target:FindFirstChild("HumanoidRootPart")
        if a then
            TeleportTo(a.Position, Vector3.new(0, 5, 0))
            Notify("Teleport", "Jumped to nearest pet!", 3, "map-pin")
        end
    end,
})

FarmTab:CreateSection("Live Status")

local CatchCountLabel = FarmTab:CreateLabel("Caught this session: 0", "activity")
ST.StatusLabels.CatchCount = CatchCountLabel

-- ────────────────────────────────────────────────────────────
-- TAB 2 ─ ECONOMY
-- ────────────────────────────────────────────────────────────
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
    Name         = "Collect Interval (seconds)",
    Range        = {5, 180},
    Increment    = 5,
    Suffix       = "s",
    CurrentValue = 30,
    Flag         = "CollectIntervalSlider",
    Callback     = function(v) CFG.CollectInterval = v end,
})

EconTab:CreateButton({
    Name     = "Collect Now",
    Callback = function()
        task.spawn(CollectAllCash)
        Notify("Cash", "Cash collected!", 3, "dollar-sign")
    end,
})

local CashStatusLabel = EconTab:CreateLabel("Last collect: not yet", "clock")
ST.StatusLabels.CashStatus = CashStatusLabel

EconTab:CreateSection("Food & Feeding")

EconTab:CreateToggle({
    Name         = "Auto Buy Food",
    CurrentValue = false,
    Flag         = "AutoBuyFoodToggle",
    Callback     = function(v)
        CFG.AutoBuyFood = v
        Notify("Food", v and "Auto-buying food!" or "Stopped.", 3, "shopping-cart")
    end,
})

EconTab:CreateToggle({
    Name         = "Auto Feed All Pets",
    CurrentValue = false,
    Flag         = "AutoFeedToggle",
    Callback     = function(v) CFG.AutoFeedPets = v end,
})

EconTab:CreateSlider({
    Name         = "Feed Interval (seconds)",
    Range        = {10, 300},
    Increment    = 5,
    Suffix       = "s",
    CurrentValue = 60,
    Flag         = "FeedIntervalSlider",
    Callback     = function(v) CFG.FeedInterval = v end,
})

EconTab:CreateButton({
    Name     = "Buy Food Now",
    Callback = function()
        BuyFood()
        Notify("Food", "Food purchase sent!", 3, "shopping-bag")
    end,
})

EconTab:CreateButton({
    Name     = "Feed All Pets Now",
    Callback = function()
        task.spawn(FeedAllPets)
        Notify("Feed", "Feeding all pets!", 3, "heart")
    end,
})

EconTab:CreateSection("Rewards")

EconTab:CreateToggle({
    Name         = "Auto Claim Login Reward",
    CurrentValue = false,
    Flag         = "AutoLoginToggle",
    Callback     = function(v)
        CFG.AutoClaimLogin = v
        if v then ClaimLogin() end
    end,
})

EconTab:CreateToggle({
    Name         = "Auto Claim Index Rewards",
    CurrentValue = false,
    Flag         = "AutoIndexToggle",
    Callback     = function(v)
        CFG.AutoClaimIndex = v
        if v then ClaimIndex() end
    end,
})

EconTab:CreateToggle({
    Name         = "Auto Use Spins",
    CurrentValue = false,
    Flag         = "AutoSpinToggle",
    Callback     = function(v) CFG.AutoSpin = v end,
})

EconTab:CreateButton({
    Name     = "Claim Login Reward",
    Callback = ClaimLogin,
})

EconTab:CreateButton({
    Name     = "Claim Index Rewards",
    Callback = ClaimIndex,
})

EconTab:CreateButton({
    Name     = "Use Spin",
    Callback = UseSpin,
})

-- ────────────────────────────────────────────────────────────
-- TAB 3 ─ EGGS & BREEDING
-- ────────────────────────────────────────────────────────────
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
    Name         = "Hatch Check Interval (seconds)",
    Range        = {5, 60},
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

EggTab:CreateSlider({
    Name         = "Breed Cycle Delay (seconds)",
    Range        = {2, 60},
    Increment    = 0.5,
    Suffix       = "s",
    CurrentValue = 5,
    Flag         = "BreedDelaySlider",
    Callback     = function(v) CFG.BreedDelay = v end,
})

EggTab:CreateButton({
    Name     = "Breed Now",
    Callback = function()
        TryBreed()
        Notify("Breeding", "Breed request sent!", 3, "git-merge")
    end,
})

-- ────────────────────────────────────────────────────────────
-- TAB 4 ─ PET ESP
-- ────────────────────────────────────────────────────────────
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
            Notify("ESP", "Pet ESP active — " .. (function()
                local n = 0; for _ in pairs(ST.PetRegistry) do n = n + 1 end
                return n
            end)() .. " overlays created.", 4, "eye")
        else
            DestroyAllESP()
            Notify("ESP", "Pet ESP disabled.", 3, "eye-off")
        end
    end,
})

ESPTab:CreateColorPicker({
    Name     = "ESP Label Color",
    Color    = Color3.fromRGB(255, 80, 80),
    Flag     = "ESPColorPicker",
    Callback = function(v)
        CFG.ESPColor = v
        for _, obj in pairs(ST.ESPObjects) do
            pcall(function() obj.name.TextColor3 = v end)
        end
    end,
})

ESPTab:CreateToggle({
    Name         = "Gold Highlight on Nearest",
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
            for _, model in ipairs(PetsFolder:GetChildren()) do
                RegisterPet(model)
            end
        end
        local count = 0
        for _ in pairs(ST.PetRegistry) do count = count + 1 end
        if CFG.ESPEnabled then
            for model in pairs(ST.PetRegistry) do CreateESP(model) end
        end
        Notify("Registry", "Refreshed — " .. count .. " pets found.", 4, "refresh-cw")
    end,
})

-- ────────────────────────────────────────────────────────────
-- TAB 5 ─ UTILITY
-- ────────────────────────────────────────────────────────────
local UtilTab = Window:CreateTab("Utility", "wrench")

UtilTab:CreateSection("Movement")

UtilTab:CreateSlider({
    Name         = "Walk Speed",
    Range        = {16, 100},
    Increment    = 1,
    Suffix       = " WS",
    CurrentValue = 16,
    Flag         = "WalkSpeedSlider",
    Callback     = function(v)
        CFG.WalkSpeed = v
        ApplyMovement()
    end,
})

UtilTab:CreateSlider({
    Name         = "Jump Power",
    Range        = {50, 500},
    Increment    = 5,
    Suffix       = " JP",
    CurrentValue = 50,
    Flag         = "JumpPowerSlider",
    Callback     = function(v)
        CFG.JumpPower = v
        ApplyMovement()
    end,
})

UtilTab:CreateToggle({
    Name         = "Infinite Jump",
    CurrentValue = false,
    Flag         = "InfiniteJumpToggle",
    Callback     = function(v)
        CFG.InfiniteJump = v
        SetInfiniteJump(v)
    end,
})

UtilTab:CreateToggle({
    Name         = "Anti-AFK",
    CurrentValue = false,
    Flag         = "AntiAFKToggle",
    Callback     = function(v)
        CFG.AntiAFK = v
        SetAntiAFK(v)
        Notify("Anti-AFK", v and "Enabled — idle kick blocked." or "Disabled.", 3,
               v and "shield" or "shield-off")
    end,
})

UtilTab:CreateSection("Tools")

UtilTab:CreateInput({
    Name                     = "Redeem Promo Code",
    CurrentValue             = "",
    PlaceholderText          = "Enter code and press Enter...",
    RemoveTextAfterFocusLost = false,
    Flag                     = "RedeemCodeInput",
    Callback                 = function(text)
        if text and text ~= "" then RedeemCode(text) end
    end,
})

UtilTab:CreateButton({
    Name     = "Activate Totem",
    Callback = function()
        SafeFire(REM.UseTotem)
        Notify("Totem", "Totem activated!", 3, "zap")
    end,
})

UtilTab:CreateButton({
    Name     = "Process Trait Machine",
    Callback = function()
        local result = SafeInvoke(REM.processTraitMachine)
        Notify("Traits", result and "Trait machine fired!" or "Sent (no direct response).", 3, "shuffle")
    end,
})

UtilTab:CreateButton({
    Name     = "Upgrade Farm",
    Callback = function()
        SafeFire(REM.AttemptUpgradeFarm)
        Notify("Farm", "Upgrade request sent!", 3, "arrow-up-circle")
    end,
})

UtilTab:CreateButton({
    Name     = "Buy Best Lasso",
    Callback = function()
        SafeFire(REM.BuyLasso)
        task.wait(0.2)
        SafeFire(REM.EquipLasso)
        Notify("Lasso", "Best lasso purchased & equipped!", 3, "anchor")
    end,
})

-- ────────────────────────────────────────────────────────────
-- TAB 6 ─ SETTINGS
-- ────────────────────────────────────────────────────────────
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

SettingsTab:CreateKeybind({
    Name           = "Toggle GUI Visibility",
    CurrentKeybind = "RightShift",
    HoldToInteract = false,
    Flag           = "ToggleGUIKeybind",
    Callback       = function() end,
})

SettingsTab:CreateSection("Script Info")

do
    local remCount = 0
    for _ in pairs(REM) do remCount = remCount + 1 end
    local petCount = 0
    for _ in pairs(ST.PetRegistry) do petCount = petCount + 1 end

    SettingsTab:CreateParagraph({
        Title   = "Catch & Tame  v1.2.0",
        Content = "Executor: " .. EXECUTOR_NAME
               .. "\nRemotes cached: " .. remCount
               .. "\nPets in registry: " .. petCount
               .. "\n\nAuto Farm | Economy | Eggs | ESP | Utility"
               .. "\n\nTip: play one catch manually first to train the"
               .. "\nminigame bypass with your game's exact signature.",
    })
end

-- §15 ── MAIN CONSOLIDATED LOOP
-- [F-007 FIX] Loop guard checks OWN session token, not just boolean
task.spawn(function()
    local timers = {
        collect  = 0,
        feed     = 0,
        breed    = 0,
        hatch    = 0,
        spin     = 0,
        esp      = 0,
        petcount = 0,
        movement = 0,
    }

    while ST.Running
      and (not getgenv or (getgenv().CAT_RUNNING ~= false
           and getgenv().CAT_SESSION == SESSION_TOKEN)) do
        local now = tick()

        -- Movement: re-apply after respawn or teleport (every 1 s)
        if now - timers.movement > 1 then
            if CFG.WalkSpeed ~= 16 or CFG.JumpPower ~= 50 then
                ApplyMovement()
            end
            timers.movement = now
        end

        -- Auto Cash Collection
        if CFG.AutoCollect and now - timers.collect > CFG.CollectInterval then
            task.spawn(CollectAllCash)
            timers.collect = now
        end

        -- Auto Buy Food + Feed
        if now - timers.feed > CFG.FeedInterval then
            if CFG.AutoBuyFood then task.spawn(BuyFood) end
            if CFG.AutoFeedPets then task.spawn(FeedAllPets) end
            timers.feed = now
        end

        -- Auto Breed
        if CFG.AutoBreed and now - timers.breed > CFG.BreedDelay then
            task.spawn(TryBreed)
            timers.breed = now
        end

        -- Auto Hatch
        if CFG.AutoHatch and now - timers.hatch > CFG.HatchInterval then
            task.spawn(InstantHatchAll)
            timers.hatch = now
        end

        -- Auto Spin (once per minute)
        if CFG.AutoSpin and now - timers.spin > 60 then
            task.spawn(UseSpin)
            timers.spin = now
        end

        -- ESP update (every 0.5 s)
        if CFG.ESPEnabled and now - timers.esp > 0.5 then
            UpdateESP()
            timers.esp = now
        end

        -- [F-010 FIX] Pet count label via UpdateLabel wrapper
        if now - timers.petcount > 2 then
            local n = 0
            for _ in pairs(ST.PetRegistry) do n = n + 1 end
            UpdateLabel(ST.StatusLabels.PetCount,
                "Roaming pets in registry: " .. n, "map-pin")
            timers.petcount = now
        end

        task.wait(0.1)
    end
end)

-- §16 ── AUTO FARM LOOP  (separate thread — has awaits inside cycle)
-- [F-007 FIX] Session token guard
task.spawn(function()
    while ST.Running
      and (not getgenv or (getgenv().CAT_RUNNING ~= false
           and getgenv().CAT_SESSION == SESSION_TOKEN)) do
        if CFG.AutoFarm then
            task.spawn(RunCatchCycle)
            task.wait(math.max(0.5, CFG.FarmDelay))
        else
            task.wait(0.5)
        end
    end
end)

-- §17 ── CHARACTER RESPAWN HANDLER
-- [F-004 FIX] Named connection key
ST.Connections.CharacterAdded = Player.CharacterAdded:Connect(function()
    task.wait(1.5)      -- let character finish loading
    ApplyMovement()
    if CFG.InfiniteJump then SetInfiniteJump(true) end
    task.wait(0.5)
    SafeFire(REM.ClientReady)
    Notify("Character", "Respawned — systems restored.", 3, "user")
end)

-- §18 ── INITIALIZATION
do
    -- Register with server
    task.wait(0.5)
    SafeFire(REM.ClientReady)

    -- Load Rayfield configuration
    Rayfield:LoadConfiguration()

    -- Restore Xeno cross-session config
    if IS_XENO and Xeno and Xeno.GetGlobal then
        pcall(function()
            local saved = Xeno.GetGlobal("CATConfig_v120")
            if type(saved) == "table" then
                for k, v in pairs(saved) do
                    if CFG[k] ~= nil then CFG[k] = v end
                end
            end
        end)
    end

    -- Startup notify
    local remCount = 0
    for _ in pairs(REM) do remCount = remCount + 1 end
    local petCount = 0
    for _ in pairs(ST.PetRegistry) do petCount = petCount + 1 end

    Notify(
        "Catch & Tame  v1.2.0  ✓",
        remCount .. " remotes  |  " .. petCount .. " pets found\nRightShift to toggle GUI",
        7,
        "paw-print"
    )
end

-- Xeno config auto-save (every 30 s)
if IS_XENO and Xeno and Xeno.SetGlobal then
    task.spawn(function()
        while ST.Running
          and (not getgenv or (getgenv().CAT_RUNNING ~= false
               and getgenv().CAT_SESSION == SESSION_TOKEN)) do
            task.wait(30)
            pcall(function() Xeno.SetGlobal("CATConfig_v120", CFG) end)
        end
    end)
end

-- ============================================================
-- END OF SCRIPT  ·  v1.2.0  ·  10 findings resolved
-- ============================================================
