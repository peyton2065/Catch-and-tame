-- ============================================================
--   CATCH & TAME  |  ADVANCED OPERATION SCRIPT
--   Version  : 1.1.2
--   Executor : Xeno (UNC compatible)
--   PlaceId  : 96645548064314
--   Author   : ENI
--   Load via : XenoScanner v4.2 Bootstrap (Gui.lua on GitHub)
-- ============================================================
-- CHANGELOG
--   v1.1.2  Definitive vararg fix — no closure wrapper at all
--     ! FIX: Replaced pcall(function() f(table.unpack(args)) end) with
--            pcall(f, remote, ...) — the canonical Lua pattern. '...' stays
--            in SafeFire/SafeInvoke's own vararg scope, never crosses a
--            function boundary. Zero ambiguity in any Luau version.
--     ! NOTE: If you see this error still, your GitHub Gui.lua is outdated.
--             Re-upload this file to peyton2065/Catch-and-tame/main/Gui.lua.
--   v1.1.1  Luau vararg compile fix (intermediate — superseded by 1.1.2)
--     ! FIX: loadstring compile error ":264: Cannot use '...' outside
--            of a vararg function"
--            Root cause: Luau (Lua 5.1) does not allow '...' to be
--            captured by a closure that didn't declare it. The anonymous
--            function() passed to pcall in SafeFire/SafeInvoke had no
--            vararg context of its own.
--            Fix: pack '...' into local args = {...} before the closure
--            boundary; table.unpack(args) re-expands inside the closure
--            where args is a normal upvalue, not a vararg.
--     ! FIX: REM.FeedPet:InvokeServer called directly (nil-unsafe).
--            Routed through SafeInvoke for consistent nil guard.
--   v1.1.0  Bootstrap compatibility + hook crash fix
--     ! FIX: "attempt to call a nil value" on Rayfield load
--            Root cause: __namecall hook installed before Rayfield,
--            ST.OldNamecall could be nil if hookmetamethod fails.
--            Fix 1 — nil guard added inside hook body.
--            Fix 2 — hook now installs AFTER Rayfield is loaded.
--            Fix 3 — Rayfield fetched via http_request/request
--                    (bypasses __namecall entirely, same as bootstrap).
--     + Bootstrap-compatible: fetched by XenoScanner v4.2 loader.
--   v1.0.0  Initial release
--     + Auto Farm  : TP → ThrowLasso → minigame bypass → place pet
--     + Auto Cash  : collectAllPetCash loop + offline cash drain
--     + Economy    : auto buy food, auto feed, login/index rewards
--     + Eggs       : instant hatch, auto breed loop
--     + Pet ESP    : live BillboardGui overlays, distance, highlight
--     + Utility    : speed, jump power, infinite jump, anti-AFK
--     + Tools      : code redeem, totem, trait machine, farm upgrade
--     + GUI        : Rayfield, 6 tabs, live status labels, keybind
--     + Config     : Rayfield save + Xeno.SetGlobal cross-session
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
if not cloneref       then cloneref       = function(o) return o end end
if not getnilinstances then getnilinstances = function() return {} end end
if not getinstances   then getinstances   = function() return {} end end
if not newcclosure    then newcclosure    = function(f) return f end end
if not checkcaller    then checkcaller    = function() return false end end

-- §3 ── CLEANUP PREVIOUS INSTANCE
do
    -- Kill any previous main-loop signal
    if getgenv then
        if getgenv().CAT_RUNNING ~= nil then
            getgenv().CAT_RUNNING = false
            task.wait(0.25)             -- brief pause for old loops to exit
        end
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
local Players          = cloneref(game:GetService("Players"))
local ReplicatedStorage = cloneref(game:GetService("ReplicatedStorage"))
local RunService       = cloneref(game:GetService("RunService"))
local TweenService     = cloneref(game:GetService("TweenService"))
local UserInputService = cloneref(game:GetService("UserInputService"))
local VirtualUser      = cloneref(game:GetService("VirtualUser"))
local CoreGui          = cloneref(game:GetService("CoreGui"))
local Workspace        = cloneref(game:GetService("Workspace"))

-- §5 ── PLAYER REFERENCES
local Player  = Players.LocalPlayer
local Camera  = Workspace.CurrentCamera

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
local ST = {
    Running       = true,
    Connections   = {},             -- RBXScriptConnection pool
    ESPObjects    = {},             -- {model → {gui, distLabel}}
    PetRegistry   = {},             -- {model → true} event-driven
    NearestPet    = nil,
    CatchCount    = 0,
    MinigameSig   = nil,            -- cached minigame success args
    HookActive    = false,
    OldNamecall   = nil,
    StatusLabels  = {},             -- Rayfield label refs for live update
}

-- Write the global running flag so cleanup code can stop old instances
if getgenv then getgenv().CAT_RUNNING = true end

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

    -- Known remote names from structure analysis
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
        -- Farm / Pen
        "AttemptUpgradeFarm", "AttemptSwapPet",
        "GetFarmLevel", "GetPetInventoryData",
        "RequestPlacePet", "RequestWalkPet",
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
    -- (some games nest them inside data modules)
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

-- Safely fire a RemoteEvent.
-- Passes remote.FireServer and args directly into pcall — no closure wrapper.
-- pcall(f, ...) forwards the extra args to f, so '...' stays in SafeFire's
-- own vararg scope and never crosses a function boundary. This is the
-- canonical Lua pattern and avoids the Luau vararg-in-closure restriction.
local function SafeFire(remote, ...)
    if not remote then return false end
    return pcall(remote.FireServer, remote, ...)
end

-- Safely invoke a RemoteFunction, returns result or nil.
-- Same pattern: InvokeServer and args passed directly, no closure.
local function SafeInvoke(remote, ...)
    if not remote then return nil end
    local ok, result = pcall(remote.InvokeServer, remote, ...)
    return ok and result or nil
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

-- Find the nearest unregistered roaming pet model
local function FindNearestPet()
    local root = GetRoot()
    if not root then return nil, math.huge end
    local nearest, nearDist = nil, math.huge

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
            -- Stale entry — prune it
            ST.PetRegistry[model] = nil
        end
    end

    return nearest, nearDist
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
            -- CreateESP defined in §13 — called only after it's defined
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

    -- Keep registry live
    local addConn = PetsFolder.ChildAdded:Connect(function(child)
        task.wait(0.1)              -- let model fully load before reading parts
        RegisterPet(child)
    end)
    local removeConn = PetsFolder.ChildRemoved:Connect(function(child)
        UnregisterPet(child)
    end)
    table.insert(ST.Connections, addConn)
    table.insert(ST.Connections, removeConn)
end

-- §11 ── MINIGAME HOOK
-- Intercepts legitimate minigameRequest calls during normal play and caches
-- the exact success-state argument signature the server expects.
-- On auto-farm, we replay that signature rather than guessing.

-- NOTE: InstallMinigameHook() is defined here but intentionally NOT called yet.
-- It will be called in §14-POST, after Rayfield has fully loaded.
-- Reason: if hookmetamethod returns nil (broken hook from a prior session),
-- calling ST.OldNamecall() inside the hook body crashes with
-- "attempt to call a nil value" — which is exactly the error we're fixing.
-- Deferring the install means our hook never intercepts the Rayfield HttpGet.
local function InstallMinigameHook()
    if ST.HookActive then return end
    if not hookmetamethod then return end  -- executor doesn't support this API

    local candidate = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        local method = getnamecallmethod and getnamecallmethod() or ""

        if method == "InvokeServer"
        and self == REM.minigameRequest
        and not checkcaller()
        and not ST.MinigameSig then
            ST.MinigameSig = {...}
        end

        -- FIX: nil guard — if hookmetamethod returned nil, skip the passthrough
        -- rather than crashing. Luau's normal dispatch still handles the call.
        if ST.OldNamecall then
            return ST.OldNamecall(self, ...)
        end
    end))

    -- Only mark active if hookmetamethod gave us a valid original back
    if candidate ~= nil then
        ST.OldNamecall = candidate
        ST.HookActive  = true
    end
end

-- Hook NOT installed here — called after Rayfield loads (see §14-POST)

-- §12 ── CORE FEATURE FUNCTIONS

-- 12-A  Bypass the taming minigame
local function SolveTamingMinigame()
    -- Replay captured signature (most reliable — set after first natural catch)
    if ST.MinigameSig then
        return SafeInvoke(REM.minigameRequest, table.unpack(ST.MinigameSig))
    end

    -- Tiered discovery: try common success-state patterns
    -- We stop and cache the first pattern that returns a truthy result
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
        local result = SafeInvoke(REM.minigameRequest, table.unpack(args))
        task.wait(0.05)
        if result then
            ST.MinigameSig = args   -- remember winning pattern
            return result
        end
    end

    -- Last resort: fire without expecting a meaningful return value
    SafeFire(REM.minigameRequest, true)
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
--   TP → ThrowLasso → minigame → RequestPlacePet
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

    -- Update status label
    local labelText = "Caught: " .. ST.CatchCount
                   .. "  |  Last: " .. target.Name:sub(1, 12)
                   .. "  (" .. math.floor(dist) .. " studs)"
    if ST.StatusLabels.CatchCount then
        pcall(function() ST.StatusLabels.CatchCount:Set(labelText, "crosshair") end)
    end
end

-- 12-D  Collect all pen cash + offline income
local function CollectAllCash()
    SafeFire(REM.collectAllPetCash)

    -- Drain any queued offline income
    local offlineCash = SafeInvoke(REM.getOfflineCash)
    if type(offlineCash) == "number" and offlineCash > 0 then
        -- Server queues the amount; second collect drains it
        task.wait(0.1)
        SafeFire(REM.collectAllPetCash)
    end

    if ST.StatusLabels.CashStatus then
        pcall(function()
            ST.StatusLabels.CashStatus:Set("Last collect: " .. os.date("%H:%M:%S"), "clock")
        end)
    end
end

-- 12-E  Buy food from shop
local function BuyFood()
    SafeFire(REM.BuyFood)
end

-- 12-F  Feed all owned pets
local function FeedAllPets()
    local inventory = SafeInvoke(REM.getPetInventory)
    if type(inventory) == "table" then
        for _, petData in ipairs(inventory) do
            SafeInvoke(REM.FeedPet, petData)
            task.wait(0.08)
        end
    else
        -- No inventory data — fire blind, server handles target resolution
        SafeInvoke(REM.FeedPet)
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
    -- Try with no args first; game resolves pair from owned pets server-side
    local result = SafeInvoke(REM.breedRequest)
    if not result then
        -- Try with placeholder slot indices
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
    code = code:gsub("^%s+", ""):gsub("%s+$", "")   -- trim whitespace
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
local infJumpConn
local function SetInfiniteJump(enabled)
    if infJumpConn then
        infJumpConn:Disconnect()
        infJumpConn = nil
    end
    if enabled then
        infJumpConn = UserInputService.JumpRequest:Connect(function()
            local hum = GetHumanoid()
            if hum then
                hum:ChangeState(Enum.HumanoidStateType.Jumping)
            end
        end)
        table.insert(ST.Connections, infJumpConn)
    end
end

-- 12-O  Anti-AFK
local afkConn
local function SetAntiAFK(enabled)
    if afkConn then afkConn:Disconnect(); afkConn = nil end
    if enabled then
        afkConn = Player.Idled:Connect(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
        table.insert(ST.Connections, afkConn)
    end
end

-- §13 ── ESP SYSTEM

-- Create a BillboardGui overlay for a roaming pet model
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

    ST.ESPObjects[model] = { gui = bb, name = nameLabel, dist = distLabel }
end

-- Expose CreateESP globally so RegisterPet can call it before §13 is "reached"
_G.CreateESP_Fn = CreateESP

-- Destroy all active ESP overlays
local function DestroyAllESP()
    for model, obj in pairs(ST.ESPObjects) do
        pcall(function() obj.gui:Destroy() end)
        ST.ESPObjects[model] = nil
    end
end

-- Called every 0.5 s from main loop — updates distance labels + highlight
local function UpdateESP()
    local root = GetRoot()
    for model, obj in pairs(ST.ESPObjects) do
        if model and model.Parent and obj and obj.gui and obj.gui.Parent then
            local anchor = model:FindFirstChild("Root")
                        or model:FindFirstChild("HumanoidRootPart")
            if root and anchor then
                local dist = math.floor(GetDistance(root.Position, anchor.Position))
                pcall(function()
                    obj.dist.Text = dist .. " studs"
                    -- Gold highlight on the current nearest target
                    if CFG.HighlightNearest and ST.NearestPet == model then
                        obj.name.TextColor3 = Color3.fromRGB(255, 210, 0)
                    else
                        obj.name.TextColor3 = CFG.ESPColor
                    end
                end)
            end
        else
            -- Stale overlay — clean it
            pcall(function() if obj and obj.gui then obj.gui:Destroy() end end)
            ST.ESPObjects[model] = nil
        end
    end
end

-- §14 ── RAYFIELD GUI
-- FIX: Rayfield is fetched via executor HTTP globals (http_request / request),
-- NOT via game:HttpGet. game:HttpGet is a __namecall method on game — if our
-- hook (or a prior broken hook) is on __namecall, game:HttpGet crashes before
-- Rayfield's body even executes, producing "attempt to call a nil value" at
-- line 1 of the fetched chunk. http_request and request are C-level executor
-- globals that bypass Roblox's metatable entirely.

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

-- Attempt 3: game:HttpGet fallback — only safe when __namecall is clean
-- (i.e. no hook installed yet, which is guaranteed because we deferred
-- InstallMinigameHook() to §14-POST below)
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
-- Rayfield is already in memory; no more HttpGet calls go through __namecall.
InstallMinigameHook()

-- Flush any notifications that fired before Rayfield loaded
for _, payload in ipairs(NotifyQueue) do
    pcall(function() Rayfield:Notify(payload) end)
end
NotifyQueue = {}

local Window = Rayfield:CreateWindow({
    Name            = "Catch & Tame  v1.0",
    Icon            = "paw-print",
    LoadingTitle    = "Catch & Tame Script",
    LoadingSubtitle = "Xeno | v1.0.0 | by ENI",
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
            end()) .. " overlays created.", 4, "eye")
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
        -- Propagate color to all live overlays
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
    Callback       = function() end,    -- Rayfield ToggleUIKeybind handles this
})

SettingsTab:CreateSection("Script Info")

do
    local remCount = 0
    for _ in pairs(REM) do remCount = remCount + 1 end
    local petCount = 0
    for _ in pairs(ST.PetRegistry) do petCount = petCount + 1 end

    SettingsTab:CreateParagraph({
        Title   = "Catch & Tame  v1.0.0",
        Content = "Executor: " .. EXECUTOR_NAME
               .. "\nRemotes cached: " .. remCount
               .. "\nPets in registry: " .. petCount
               .. "\n\nAuto Farm | Economy | Eggs | ESP | Utility"
               .. "\n\nTip: play one catch manually first to train the"
               .. "\nminigame bypass with your game's exact signature.",
    })
end

-- §15 ── MAIN CONSOLIDATED LOOP
-- Single task.spawn with timer-based dispatch — minimal thread count.
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

    while ST.Running and (not getgenv or getgenv().CAT_RUNNING ~= false) do
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

        -- Auto Buy Food + Feed (share same interval counter)
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

        -- Pet count label (every 2 s)
        if now - timers.petcount > 2 then
            if ST.StatusLabels.PetCount then
                local n = 0
                for _ in pairs(ST.PetRegistry) do n = n + 1 end
                pcall(function()
                    ST.StatusLabels.PetCount:Set(
                        "Roaming pets in registry: " .. n, "map-pin")
                end)
            end
            timers.petcount = now
        end

        task.wait(0.1)
    end
end)

-- §16 ── AUTO FARM LOOP  (separate thread — has awaits inside cycle)
task.spawn(function()
    while ST.Running and (not getgenv or getgenv().CAT_RUNNING ~= false) do
        if CFG.AutoFarm then
            task.spawn(RunCatchCycle)
            task.wait(math.max(0.5, CFG.FarmDelay))
        else
            task.wait(0.5)
        end
    end
end)

-- §17 ── CHARACTER RESPAWN HANDLER
Player.CharacterAdded:Connect(function()
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

    -- Load Rayfield configuration (applies saved flags to all elements)
    Rayfield:LoadConfiguration()

    -- Restore Xeno cross-session config on top of Rayfield config
    -- (Xeno persists across server hops; Rayfield config persists across sessions)
    if IS_XENO and Xeno and Xeno.GetGlobal then
        pcall(function()
            local saved = Xeno.GetGlobal("CATConfig_v100")
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
        "Catch & Tame  v1.0  ✓",
        remCount .. " remotes  |  " .. petCount .. " pets found\nRightShift to toggle GUI",
        7,
        "paw-print"
    )
end

-- Xeno config auto-save (every 30 s)
if IS_XENO and Xeno and Xeno.SetGlobal then
    task.spawn(function()
        while ST.Running do
            task.wait(30)
            pcall(function() Xeno.SetGlobal("CATConfig_v100", CFG) end)
        end
    end)
end

-- ============================================================
-- END OF SCRIPT
-- ============================================================
