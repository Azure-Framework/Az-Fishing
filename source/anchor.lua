-- Boat anchor script using /anchor for the CLOSEST BOAT near the player.
-- Uses ox_lib: lib.getClosestVehicle(coords, maxDistance, includePlayerVehicle)
-- - You do NOT need to be in the driver seat (or even inside the boat)
-- - It finds the closest boat and anchors/unanchors that boat
-- - While anchored, boat CANNOT move forward/back/sideways
--   but WILL still move up/down with the waves (Z is NOT locked).

local anchorState = {
    isAnchored = false,
    isReeling  = false,
    boat       = nil,
    anchorX    = 0.0,
    anchorY    = 0.0
}

local DEBUG = false

-- =============== HELPERS ===============

local function debugPrint(msg)
    if DEBUG then
        print(("[ANCHOR] %s"):format(msg))
    end
end

local function sendChat(msg)
    TriggerEvent('chat:addMessage', {
        color = { 0, 200, 255 },
        multiline = true,
        args = { "^3Anchor", msg }
    })
end

local function isBoat(vehicle)
    if not vehicle or vehicle == 0 then return false end
    local class = GetVehicleClass(vehicle)
    -- 14 = Boats (includes jetskis, etc.)
    return class == 14
end

local function getDistanceEntityToEntity(ent1, ent2)
    local x1, y1, z1 = table.unpack(GetEntityCoords(ent1))
    local x2, y2, z2 = table.unpack(GetEntityCoords(ent2))
    local dx, dy, dz = x1 - x2, y1 - y2, z1 - z2
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Use ox_lib to get the closest boat to the player within maxDist
local function getClosestBoatToPlayer(ped, maxDist)
    maxDist = maxDist or 20.0

    local coords = GetEntityCoords(ped)
    -- lib.getClosestVehicle(coords, maxDistance?, includePlayerVehicle?)
    local vehicle, vehicleCoords = lib.getClosestVehicle(coords, maxDist, true)

    if vehicle and vehicle ~= 0 and DoesEntityExist(vehicle) and isBoat(vehicle) then
        debugPrint(("Closest boat id=%s at coords=%.2f,%.2f,%.2f"):format(
            vehicle,
            vehicleCoords and vehicleCoords.x or 0.0,
            vehicleCoords and vehicleCoords.y or 0.0,
            vehicleCoords and vehicleCoords.z or 0.0
        ))
        return vehicle
    end

    return nil
end

local function playReelAnim(ped, duration)
    -- Standing "working" style animation – works fine on deck/dock
    local dict = "amb@world_human_gardener_plant@male@base"
    local anim = "base"

    RequestAnimDict(dict)
    local tries = 0
    while not HasAnimDictLoaded(dict) and tries < 200 do
        Wait(0)
        tries = tries + 1
    end

    if HasAnimDictLoaded(dict) then
        TaskPlayAnim(ped, dict, anim, 8.0, -8.0, duration, 1, 0.0, false, false, false)
    end
end

-- =============== ANCHOR PHYSICS LOOP ===============
-- Lock boat X/Y to anchorState.anchorX/Y but let Z position & Z velocity move naturally.

local function startAnchorPhysicsLoop()
    CreateThread(function()
        debugPrint("Anchor physics loop started")
        while anchorState.isAnchored do
            local boat = anchorState.boat
            if not boat or not DoesEntityExist(boat) then
                debugPrint("Boat no longer exists; stopping anchor loop")
                anchorState.isAnchored = false
                anchorState.boat = nil
                break
            end

            -- Current coords and velocity from physics
            local bx, by, bz = table.unpack(GetEntityCoords(boat))
            local vx, vy, vz = table.unpack(GetEntityVelocity(boat))

            -- Force X/Y to the anchor point, keep current Z from physics
            SetEntityCoordsNoOffset(
                boat,
                anchorState.anchorX,
                anchorState.anchorY,
                bz,              -- DO NOT lock Z; use whatever the game gives
                false, false, false
            )

            -- Kill horizontal velocity, keep vertical (bobbing)
            SetEntityVelocity(boat, 0.0, 0.0, vz)

            Wait(0) -- every frame
        end
        debugPrint("Anchor physics loop ended")
    end)
end

-- =============== ANCHOR LOGIC ===============

local function dropAnchor(ped, boat)
    if anchorState.isReeling then return end
    if not DoesEntityExist(boat) then
        sendChat("^1Error:^7 boat no longer exists.")
        return
    end

    anchorState.isReeling = true
    anchorState.boat = boat

    sendChat("^2Dropping anchor...^7 please wait.")
    debugPrint("Dropping anchor")

    CreateThread(function()
        -- Turn toward the boat, then play reel animation
        TaskTurnPedToFaceEntity(ped, boat, 1000)
        Wait(1000)

        local reelTime = 6000 -- ms
        playReelAnim(ped, reelTime)
        local endTime = GetGameTimer() + reelTime

        while GetGameTimer() < endTime do
            -- If they walk too far away from the boat, cancel
            if getDistanceEntityToEntity(ped, boat) > 10.0 then
                sendChat("^1Canceled:^7 you moved too far from the boat.")
                ClearPedTasks(ped)
                anchorState.isReeling = false
                return
            end
            Wait(0)
        end

        ClearPedTasks(ped)

        if not DoesEntityExist(boat) then
            sendChat("^1Failed:^7 boat no longer exists.")
            anchorState.isReeling = false
            return
        end

        -- Save anchor X/Y from current boat position
        local bx, by, bz = table.unpack(GetEntityCoords(boat))
        anchorState.anchorX = bx
        anchorState.anchorY = by

        -- Kill immediate motion; engine off for "anchor down" feel
        SetVehicleEngineOn(boat, false, true, false)
        SetVehicleForwardSpeed(boat, 0.0)
        SetEntityVelocity(boat, 0.0, 0.0, 0.0)

        anchorState.isAnchored = true
        anchorState.isReeling = false

        -- Start the physics loop that keeps X/Y locked but lets Z move
        startAnchorPhysicsLoop()

        sendChat("Anchor ^2set^7. Boat will stay in place but still rock with the waves.")
        debugPrint(("Anchor set at X=%.2f Y=%.2f"):format(anchorState.anchorX, anchorState.anchorY))
    end)
end

local function raiseAnchor(ped, boat)
    if anchorState.isReeling then return end
    if not DoesEntityExist(boat) then
        sendChat("^1Error:^7 boat no longer exists.")
        return
    end

    anchorState.isReeling = true
    anchorState.boat = boat

    sendChat("^2Raising anchor...^7 please wait.")
    debugPrint("Raising anchor")

    CreateThread(function()
        TaskTurnPedToFaceEntity(ped, boat, 1000)
        Wait(1000)

        local reelTime = 6000 -- ms
        playReelAnim(ped, reelTime)
        local endTime = GetGameTimer() + reelTime

        while GetGameTimer() < endTime do
            if getDistanceEntityToEntity(ped, boat) > 10.0 then
                sendChat("^1Canceled:^7 you moved too far from the boat.")
                ClearPedTasks(ped)
                anchorState.isReeling = false
                return
            end
            Wait(0)
        end

        ClearPedTasks(ped)

        if not DoesEntityExist(boat) then
            sendChat("^1Failed:^7 boat no longer exists.")
            anchorState.isReeling = false
            return
        end

        -- Stop anchoring; physics loop will auto-exit on next tick
        anchorState.isAnchored = false
        anchorState.isReeling = false

        sendChat("Anchor ^1raised^7. You can move the boat again.")
        debugPrint("Anchor released for boat " .. tostring(boat))
    end)
end

-- =============== COMMAND ===============

RegisterCommand("anchor", function()
    if anchorState.isReeling then
        sendChat("^1Hold up:^7 you're already adjusting an anchor.")
        return
    end

    local ped = PlayerPedId()

    -- If our tracked anchored boat vanished, reset state
    if anchorState.isAnchored and (not anchorState.boat or not DoesEntityExist(anchorState.boat)) then
        anchorState.isAnchored = false
        anchorState.boat = nil
    end

    local boat = getClosestBoatToPlayer(ped, 20.0)
    if not boat then
        sendChat("^1Error:^7 no boat found nearby. Stand on/near your boat and try again.")
        return
    end

    -- Toggle anchor for THIS boat
    if anchorState.isAnchored and anchorState.boat == boat then
        -- This boat is currently anchored -> raise anchor
        raiseAnchor(ped, boat)
    else
        -- Either no anchor yet, or you're on a different boat -> drop anchor for this one
        dropAnchor(ped, boat)
    end
end, false)

