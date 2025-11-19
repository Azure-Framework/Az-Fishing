local RES = GetCurrentResourceName()

-- =========================
-- SHARED CONFIG (from config.lua) + FALLBACKS
-- =========================
Config = Config or {}

Config.Difficulty   = Config.Difficulty   or "balanced"  -- "arcade" | "balanced" | "realistic"
Config.TickMs       = Config.TickMs       or 100
Config.Presets      = Config.Presets      or {
  arcade   = { basePulse = 9.5,  tensionPerPulse = 0.75, staminaDrainPerPulse = 0.7,  passiveTensionDecay = 1.5, passiveStaminaRecover = 1.25, spikeFreq = 5 },
  balanced = { basePulse = 6.5,  tensionPerPulse = 0.95, staminaDrainPerPulse = 1.0,  passiveTensionDecay = 1.6, passiveStaminaRecover = 0.85, spikeFreq = 4 },
  realistic= { basePulse = 3.8,  tensionPerPulse = 1.35, staminaDrainPerPulse = 1.35, passiveTensionDecay = 1.3, passiveStaminaRecover = 0.55, spikeFreq = 3 }
}
Config.HookWindowMs = Config.HookWindowMs or 1400

local isCasting, waitingHook, inFight, reelHeld, invOpen = false,false,false,false,false
local tension, stamina, progress = 0.0, 100.0, 0.0
local lineFtStart, lineFt = 0, 0
local currentFish, rod = nil, nil

local FishTable = {
  {name="Largemouth Bass",  valueMin=120, valueMax=240, strength=32, rarity="Common",  wMin=1.2, wMax=8.0,  lMin=10.0, lMax=23.0, stars=3},
  {name="Rainbow Trout",    valueMin=140, valueMax=260, strength=28, rarity="Common",  wMin=0.8, wMax=6.5,  lMin=9.0,  lMax=24.0, stars=3},
  {name="Salmon",           valueMin=200, valueMax=380, strength=40, rarity="Uncommon",wMin=3.0, wMax=15.0, lMin=18.0, lMax=34.0, stars=4},
  {name="Walleye",          valueMin=160, valueMax=320, strength=30, rarity="Uncommon",wMin=1.0, wMax=8.0,  lMin=12.0, lMax=28.0, stars=3},
  {name="Muskellunge",      valueMin=500, valueMax=900, strength=55, rarity="Rare",    wMin=8.0, wMax=38.0, lMin=24.0, lMax=50.0, stars=5},
  {name="Golden Koi",       valueMin=600, valueMax=1200,strength=42, rarity="Legendary",wMin=5.0, wMax=18.0, lMin=18.0, lMax=36.0, stars=5},
}

-- =========================
-- NOTIFICATION WRAPPER
-- =========================

local function notify(msg, nType)
  -- nType: "inform" | "success" | "error" (ox_lib style)
  if lib and type(lib.notify) == "function" then
    lib.notify({
      title       = 'Az-Fishing',
      description = msg,
      type        = nType or 'inform'
    })
  else
    SetNotificationTextEntry("STRING")
    AddTextComponentString(msg)
    DrawNotification(false,false)
  end
end

-- =========================
-- NUI HELPERS
-- =========================

local function NUI(action, data)
  data = data or {}
  data.action = action
  SendNUIMessage(data)
end

local function focus(on)
  SetNuiFocus(on, on)
end

-- =========================
-- ANIMS & ROD
-- =========================

local function loadAnimDict(dict,timeout)
  timeout = timeout or 2000
  if not HasAnimDictLoaded(dict) then RequestAnimDict(dict) end
  local t = GetGameTimer() + timeout
  while not HasAnimDictLoaded(dict) and GetGameTimer() < t do Wait(5) end
  return HasAnimDictLoaded(dict)
end

local function playAnim(ped)
  local d = "amb@world_human_stand_fishing@idle_a"
  if loadAnimDict(d) then
    TaskPlayAnim(ped, d, "idle_a", 8.0, 8.0, -1, 49, 0, false, false, false)
  end
end

local function spawnRod(ped)
  local model = GetHashKey("prop_fishing_rod_01")
  RequestModel(model)
  while not HasModelLoaded(model) do Wait(5) end
  local x,y,z = table.unpack(GetEntityCoords(ped))
  local obj = CreateObject(model, x, y, z+0.2, true, true, true)
  AttachEntityToEntity(obj, ped, GetPedBoneIndex(ped,57005), 0.12,0.02,-0.02, -20.0,0.0,0.0, true,true,false,true,1,true)
  SetModelAsNoLongerNeeded(model)
  return obj
end

local function removeRod(obj)
  if obj and DoesEntityExist(obj) then
    DetachEntity(obj, true, true)
    DeleteEntity(obj)
  end
end

-- =========================
-- WATER CHECK
-- =========================

local function isNearWater(x,y,z)
  local offs = {
    {0,0},{5,0},{-5,0},{0,5},{0,-5},{8,8},{-8,-8},{10,0},{0,10}
  }
  for i=1,#offs do
    local ox = x+offs[i][1]
    local oy = y+offs[i][2]
    local ok,wz = GetWaterHeight(ox,oy,z+50.0)
    if ok and wz and math.abs(wz-z) < 12.0 then
      return true, vector3(ox,oy,wz)
    end
  end
  if IsEntityInWater(PlayerPedId()) then
    return true, GetEntityCoords(PlayerPedId())
  end
  return false,nil
end

-- =========================
-- KVP STORAGE
-- =========================

local function saveCaught(list)
  SetResourceKvp("az_fishing_caught", json.encode(list or {}))
end

local function getCaught()
  local s = GetResourceKvpString("az_fishing_caught") or "[]"
  local ok,t = pcall(json.decode, s)
  return ok and t or {}
end

local function addCaught(f)
  local L = getCaught()
  L[#L+1] = f
  saveCaught(L)
end

-- =========================
-- SELLERS / FISH BUYERS
-- =========================

local sellerDrawDist, sellerInteractDist = 25.0, 2.0
local sellerPeds = {}

local function draw3DText(x, y, z, text)
  local onScreen,_x,_y = World3dToScreen2d(x, y, z)
  if not onScreen then return end
  SetTextScale(0.35, 0.35)
  SetTextFont(4)
  SetTextProportional(1)
  SetTextColour(255,255,255,215)
  SetTextEntry("STRING")
  SetTextCentre(1)
  AddTextComponentString(text)
  DrawText(_x, _y)
end

local function createSellerBlips()
  if not Config.Sellers or #Config.Sellers == 0 then return end
  for _, s in ipairs(Config.Sellers) do
    local c = s.coords
    if c then
      local blip = AddBlipForCoord(c.x, c.y, c.z)
      SetBlipSprite(blip, (s.blip and s.blip.sprite) or 356)
      SetBlipDisplay(blip, 4)
      SetBlipScale(blip, (s.blip and s.blip.scale) or 0.8)
      SetBlipColour(blip, (s.blip and s.blip.color) or 38)
      SetBlipAsShortRange(blip, true)
      BeginTextCommandSetBlipName("STRING")
      AddTextComponentString(s.name or "Fish Buyer")
      EndTextCommandSetBlipName(blip)
    end
  end
end

local function spawnSellerPeds()
  if not Config.Sellers or #Config.Sellers == 0 then return end

  for i, s in ipairs(Config.Sellers) do
    local c = s.coords
    if c then
      local modelName = s.pedModel or "cs_floyd"
      local model = GetHashKey(modelName)

      RequestModel(model)
      while not HasModelLoaded(model) do Wait(5) end

      local ped = CreatePed(
        4, model,
        c.x, c.y, c.z - 1.0,
        s.heading or 0.0,
        false, true
      )

      SetBlockingOfNonTemporaryEvents(ped, true)
      SetEntityInvincible(ped, true)
      FreezeEntityPosition(ped, true)

      -- optional ambient idle
      TaskStartScenarioInPlace(ped, "WORLD_HUMAN_STAND_IMPATIENT", 0, true)

      sellerPeds[i] = ped
      SetModelAsNoLongerNeeded(model)
    end
  end
end

CreateThread(function()
  createSellerBlips()
  spawnSellerPeds()
end)

CreateThread(function()
  while true do
    local sleep = 1000
    if Config.Sellers and #Config.Sellers > 0 then
      local ped = PlayerPedId()
      local pcoords = GetEntityCoords(ped)

      for _, s in ipairs(Config.Sellers) do
        local c = s.coords
        if c then
          local dist = #(pcoords - c)
          if dist < sellerDrawDist then
            sleep = 0

            -- draw marker only if on foot (to reduce spam for vehicles driving by)
            if IsPedOnFoot(ped) then
              DrawMarker(
                1, c.x, c.y, c.z - 1.0,
                0.0,0.0,0.0, 0.0,0.0,0.0,
                1.5,1.5,0.8,
                0,150,255,160,
                false,true,2,false,nil,nil,false
              )
            end

            if dist < sellerInteractDist and IsPedOnFoot(ped) and not IsEntityInWater(ped) then
              draw3DText(c.x, c.y, c.z + 0.8, ("~b~[G]~s~ Sell fish to %s"):format(s.name or "Fish Buyer"))

              -- Use G (47) so it doesn't collide with E fishing scripts
              if IsControlJustPressed(0, 47) then -- INPUT_DETONATE (G)
                local list = getCaught()
                if #list == 0 then
                  notify("You don't have any fish to sell.", "error")
                else
                  local total = 0
                  for _, f in ipairs(list) do
                    if f.value and type(f.value) == "number" then
                      total = total + f.value
                    end
                  end

                  if total <= 0 then
                    notify("Your fish aren't worth anything right now.", "error")
                  else
                    TriggerServerEvent("az_fishing:sellFish", total)
                    saveCaught({})
                    notify(("You sold your fish for $%d."):format(total), "success")
                  end
                end
              end
            end
          end
        end
      end
    end
    Wait(sleep)
  end
end)

-- =========================
-- FISH PICKING / CLEANUP
-- =========================

local function pickFish()
  local b = FishTable[math.random(1,#FishTable)]
  return {
    name       = b.name,
    rarity     = b.rarity,
    strength   = b.strength,
    stars      = b.stars,
    value      = math.random(b.valueMin, b.valueMax),
    weight_lbs = math.random()*(b.wMax-b.wMin)+b.wMin,
    length_in  = math.random()*(b.lMax-b.lMin)+b.lMin
  }
end

local function cleanupAll()
  NUI("closeAll")
  focus(false)
  local ped = PlayerPedId()
  ClearPedTasks(ped)
  removeRod(rod)
  rod = nil

  isCasting   = false
  inFight     = false
  waitingHook = false
  reelHeld    = false
  invOpen     = false

  tension, stamina, progress = 0.0, 100.0, 0.0
  lineFtStart, lineFt        = 0, 0
  currentFish = nil
end

-- =========================
-- CASTING
-- =========================

local function startCasting()
  if isCasting or inFight then
    notify("You are already fishing.", "error")
    return
  end

  local ped = PlayerPedId()
  local pos = GetEntityCoords(ped)
  local near = isNearWater(pos.x,pos.y,pos.z)
  if not near then

    return
  end

  rod = spawnRod(ped)
  playAnim(ped)
  isCasting   = true
  waitingHook = false
  focus(true)
  NUI("openCast")
end

local function scheduleBite(accuracy, power)
  local delay = math.max(900, 2600 - (accuracy*10) - (power*3))
  currentFish = pickFish()

  if accuracy >= 80 then
    currentFish.strength = math.max(10, currentFish.strength - 8)
  end

  CreateThread(function()
    Wait(delay)
    if not isCasting then return end

    waitingHook = true
    NUI("event", { type = "bite" })

    local deadline = GetGameTimer() + Config.HookWindowMs
    while waitingHook and GetGameTimer() < deadline do
      Wait(0)
    end

    if waitingHook then
      waitingHook = false
      isCasting   = false
      cleanupAll()
      notify("The fish nibbled and got away…", "inform")
    end
  end)
end

-- =========================
-- REEL HUD & FIGHT
-- =========================

local function openReelHUD()
  NUI("openReel", {
    tension = tension,
    stamina = stamina,
    progress= progress,
    lineFt  = lineFt
  })
end

local function startFight()
  if inFight then return end

  tension, stamina, progress = 0.0, 100.0, 0.0
  openReelHUD()
  inFight = true

  CreateThread(function()
    local p = Config.Presets[Config.Difficulty] or Config.Presets.balanced
    while inFight do
      Wait(Config.TickMs)

      local str = (currentFish and currentFish.strength or 30)

      if reelHeld then
        tension = math.min(100.0, tension + 0.18)
      else
        local bleed = p.passiveTensionDecay + (str*0.015)
        tension = math.max(0.0, tension - bleed)
        stamina = math.min(100.0, stamina + p.passiveStaminaRecover)
      end

      local spikeChance = reelHeld
        and (8 + math.floor(str*(0.30 + (p.spikeFreq*0.02))))
        or (2 + math.floor(str*0.06))

      if math.random(1,100) <= spikeChance then
        local spike = reelHeld and math.random(2,4) or (0.6 + math.random()*0.6)
        tension = math.min(100.0, tension + spike)
        if reelHeld then
          NUI("event", { type = "spike" })
        end
      end

      lineFt = math.max(0, math.floor(lineFtStart * (1.0 - progress/100.0)))

      if tension >= 100.0 or stamina <= 0.0 then
        inFight = false
        NUI("event", { type = "snap" })
      elseif progress >= 100.0 then
        inFight = false
        NUI("event", { type = "win" })
      end

      NUI("update", {
        tension = tension,
        stamina = stamina,
        progress= progress,
        lineFt  = lineFt
      })
    end

    if progress >= 100.0 then
      NUI("showResult", { fish = currentFish })
    else
      notify("The line snapped…", "error")
      cleanupAll()
    end
  end)
end

-- =========================
-- COMMANDS
-- =========================

RegisterCommand("fish", function()
  startCasting()
end, false)

local function openFishMenu()
  local list = getCaught()
  invOpen = true
  focus(true)
  NUI("openFishMenu", { fish = list })
end

RegisterCommand("fishmenu", function()
  openFishMenu()
end, false)

CreateThread(function()
  if RegisterKeyMapping then
    TriggerEvent('chat:addSuggestion','/fish','Start fishing')
    TriggerEvent('chat:addSuggestion','/fishmenu','Open your caught fish inventory')
  end
end)

-- =========================
-- NUI CALLBACKS
-- =========================

RegisterNUICallback("castRelease", function(data, cb)
  cb("ok")
  if not isCasting then return end

  local power = tonumber(data.power) or 0
  local acc   = tonumber(data.accuracy) or 0

  lineFtStart = math.floor(20 + power*1.5 + acc*0.6)
  lineFt      = lineFtStart

  CreateThread(function()
    Wait(500 + math.floor(power*2))
    scheduleBite(acc, power)
  end)
end)

RegisterNUICallback("hookNow", function(_, cb)
  cb("ok")
  if waitingHook and isCasting then
    waitingHook = false
    startFight()
  end
end)

RegisterNUICallback("reelDown", function(_, cb)
  cb("ok")
  reelHeld = true
end)

RegisterNUICallback("reelUp", function(_, cb)
  cb("ok")
  reelHeld = false
end)

RegisterNUICallback("reelPulse",function(_, cb)
  cb("ok")
  if not inFight then return end
  local p   = Config.Presets[Config.Difficulty] or Config.Presets.balanced
  local str = (currentFish and currentFish.strength or 30)

  local gain   = (p.basePulse*0.58) * (100.0/(100.0+str*1.35))
  local tAdd   = p.tensionPerPulse * (0.85 + (str/120.0))
  local sDrain = p.staminaDrainPerPulse * (0.9 + (str/120.0))

  progress = math.min(100.0, progress + gain)
  tension  = math.min(100.0, tension  + tAdd)
  stamina  = math.max(0.0,  stamina  - sDrain)
end)

RegisterNUICallback("keepFish", function(_, cb)
  cb("ok")
  if currentFish then
    addCaught(currentFish)
    notify(("You kept a %s (%.3f lb, %.3f in)."):format(
      currentFish.name,
      currentFish.weight_lbs,
      currentFish.length_in
    ), "success")
  end
  cleanupAll()
end)

RegisterNUICallback("releaseFish", function(_, cb)
  cb("ok")
  if currentFish then
    notify(("You released the %s."):format(currentFish.name), "inform")
  end
  cleanupAll()
end)

RegisterNUICallback("eatFish", function(data, cb)
  cb("ok")
  local idx = tonumber(data.index)
  if not idx then return end

  local list = getCaught()
  if list[idx] then
    local name = list[idx].name or "Fish"
    table.remove(list, idx)
    saveCaught(list)
    notify(("You ate %s."):format(name), "inform")
  end

  if invOpen then
    NUI("openFishMenu", { fish = getCaught() })
  end
end)

RegisterNUICallback("requestFishMenu", function(_, cb)
  cb("ok")
  if invOpen then
    NUI("openFishMenu", { fish = getCaught() })
  end
end)

RegisterNUICallback("closeFishMenu", function(_, cb)
  cb("ok")
  invOpen = false
  NUI("closeFishMenu")
  focus(false)
end)

RegisterNUICallback("escape", function(_, cb)
  cb("ok")
  cleanupAll()
end)

AddEventHandler("onClientResourceStop", function(r)
  if r ~= RES then return end
  SetNuiFocus(false,false)
end)
