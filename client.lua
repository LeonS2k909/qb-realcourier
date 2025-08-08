local QBCore = exports['qb-core']:GetCoreObject()

-- ====== STATE ======
local CourierVanNet = nil
local RouteBlip = nil
local NUI_OPEN = false
local activeDeliveryItem = nil  -- the item we're delivering (set on accept)

-- live courier count cache
local COURIER_COUNT = 0

-- ====== HELPERS ======
local function notify(msg, typ, time)
    QBCore.Functions.Notify(msg, typ or 'primary', time or 5000)
end

local function clearRouteBlip()
    if RouteBlip and DoesBlipExist(RouteBlip) then
        SetBlipRoute(RouteBlip, false)
        RemoveBlip(RouteBlip)
    end
    RouteBlip = nil
end

local function setRouteTo(coords)
    if not coords or not coords.x or not coords.y then return end
    clearRouteBlip()
    RouteBlip = AddBlipForCoord(coords.x + 0.0, coords.y + 0.0, (coords.z or 0.0) + 0.0)
    SetBlipSprite(RouteBlip, 514)
    SetBlipColour(RouteBlip, 5)
    SetBlipScale(RouteBlip, 0.8)
    SetBlipRoute(RouteBlip, true)
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentString("Delivery Target")
    EndTextCommandSetBlipName(RouteBlip)
    SetNewWaypoint(coords.x + 0.0, coords.y + 0.0)
end

RegisterCommand('clearroute', function()
    clearRouteBlip()
    notify('Route cleared.', 'success')
end, false)

-- Courier Hub helpers
local function MakeHubBlip()
    local b = AddBlipForCoord(Config.CourierHub.coords.x, Config.CourierHub.coords.y, Config.CourierHub.coords.z)
    SetBlipSprite(b, Config.CourierHub.blip.sprite or 477)
    SetBlipDisplay(b, 4)
    SetBlipScale(b, Config.CourierHub.blip.scale or 0.9)
    SetBlipColour(b, Config.CourierHub.blip.color or 5)
    SetBlipAsShortRange(b, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(Config.CourierHub.blip.label or 'Courier')
    EndTextCommandSetBlipName(b)
end

local function DrawText3D(x,y,z, text)
    SetDrawOrigin(x, y, z, 0)
    SetTextFont(4); SetTextScale(0.35, 0.35); SetTextColour(255,255,255,215)
    SetTextCentre(true); BeginTextCommandDisplayText('STRING'); AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayText(0.0, 0.0); ClearDrawOrigin()
end

local function IsNearHub()
    local p = GetEntityCoords(PlayerPedId())
    return #(p - Config.CourierHub.coords) <= (Config.CourierHub.radius or 25.0)
end

local function TryDeleteVehicle(veh)
    if not DoesEntityExist(veh) then return true end
    NetworkRequestControlOfEntity(veh)
    local tries = 0
    while not NetworkHasControlOfEntity(veh) and tries < 25 do
        Wait(50); tries = tries + 1
        NetworkRequestControlOfEntity(veh)
    end
    SetEntityAsMissionEntity(veh, true, true)
    DeleteVehicle(veh)
    return not DoesEntityExist(veh)
end

-- ====== NUI OPEN/CLOSE ======
local function pushCourierCountToNUI()
    SendNUIMessage({ action = 'courierCount', count = COURIER_COUNT })
end

local function refreshCourierCount()
    QBCore.Functions.TriggerCallback('qb-player-shop:server:getCourierCount', function(n)
        COURIER_COUNT = tonumber(n or 0) or 0
        if NUI_OPEN then pushCourierCountToNUI() end
    end)
end

local function openShopNUI()
    if NUI_OPEN then return end
    NUI_OPEN = true
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'open', maxQty = Config.MaxQuantity, perPage = Config.ItemsPerPage })
    refreshCourierCount()
end

local function closeShopNUI()
    NUI_OPEN = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })
end

RegisterNetEvent('qb-player-shop:client:openShop', function()
    openShopNUI()
end)

CreateThread(function()
    while true do
        if NUI_OPEN and IsControlJustPressed(0, 200) then -- ESC
            closeShopNUI()
        end
        Wait(0)
    end
end)

-- ====== NUI BRIDGE ======
RegisterNUICallback('shop:getCatalog', function(data, cb)
    QBCore.Functions.TriggerCallback('qb-player-shop:server:getCatalog', function(list)
        cb({ ok = true, items = list or {} })
    end, data and data.filter or '')
end)

RegisterNUICallback('shop:placeOrder', function(data, cb)
    local name = tostring(data.name or ''):lower()
    local amount = tonumber(data.amount or 0) or 0
    if name == '' or amount < 1 then cb({ ok = false, error = 'bad_args' }) return end
    local p = GetEntityCoords(PlayerPedId())
    TriggerServerEvent('qb-player-shop:server:placeOrder', name, amount, vector3(p.x, p.y, p.z))
    cb({ ok = true })
end)

RegisterNUICallback('shop:close', function(_, cb)
    closeShopNUI()
    cb({ ok = true })
end)

-- initial count request from NUI (used on courier tab too)
RegisterNUICallback('courier:getCount', function(_, cb)
    QBCore.Functions.TriggerCallback('qb-player-shop:server:getCourierCount', function(n)
        COURIER_COUNT = tonumber(n or 0) or 0
        cb({ ok = true, count = COURIER_COUNT })
    end)
end)

-- server pushes count whenever it changes
RegisterNetEvent('qb-player-shop:client:updateCourierCount', function(n)
    COURIER_COUNT = tonumber(n or 0) or 0
    if NUI_OPEN then pushCourierCountToNUI() end
end)

-- ====== NEW ORDER PING ======
RegisterNetEvent('qb-player-shop:client:newOrder', function(data)
    notify(('New delivery: #%d | %s x%d | £%s (toggle with /courierjob)'):format(data.id, data.item, data.amount, data.total), 'primary', 8000)
end)

-- ====== ACCEPT → COMPUTE ROUTE (also captures item name) ======
RegisterNetEvent('qb-player-shop:client:computeDeliveryAhead', function(data)
    if not data or not data.id then return end

    -- remember which item we're delivering (server sends this)
    activeDeliveryItem = data.item or activeDeliveryItem

    local ped = PlayerPedId()
    local ahead
    if data.solo then
        local p = GetEntityCoords(ped)
        local f = GetEntityForwardVector(ped)
        ahead = { x = p.x + f.x * 10.0, y = p.y + f.y * 10.0, z = p.z }
    else
        ahead = data.buyerCoords
    end
    if ahead and ahead.x and ahead.y then
        setRouteTo(ahead)
        TriggerServerEvent('qb-player-shop:server:setDeliveryCoords', tonumber(data.id), ahead)
    end
end)

-- ====== DELIVERY COMPLETE (server confirms) ======
RegisterNetEvent('qb-player-shop:client:deliveryComplete', function(_)
    clearRouteBlip()
    activeDeliveryItem = nil
    notify('Delivery completed.', 'success')
end)

-- ====== INVENTORY WATCH: clear route the moment the item leaves your inventory ======
local function maybeClearRouteIfItemGone(pd)
    if not activeDeliveryItem then return end
    local has = false
    for _, v in pairs((pd and pd.items) or {}) do
        if v.name == activeDeliveryItem and (v.amount or 0) > 0 then
            has = true
            break
        end
    end
    if not has and RouteBlip then
        clearRouteBlip()
        activeDeliveryItem = nil
        notify('Delivery item left your inventory — route cleared.', 'success', 4500)
    end
end

RegisterNetEvent('QBCore:Player:SetPlayerData', function(pd)
    maybeClearRouteIfItemGone(pd)
end)

-- ====== COURIER BOARD (chat) ======
RegisterNetEvent('qb-player-shop:client:openCourier', function()
    QBCore.Functions.TriggerCallback('qb-player-shop:server:getOpenOrders', function(list)
        if not list or #list == 0 then
            TriggerEvent('chat:addMessage', { args = { '^3Courier', 'No open orders. (Toggle with /courierjob)' } })
            return
        end
        TriggerEvent('chat:addMessage', { args = { '^3Courier', 'Open orders:' } })
        for _, o in ipairs(list) do
            local label = (QBCore.Shared.Items[o.item] and QBCore.Shared.Items[o.item].label) or o.item
            TriggerEvent('chat:addMessage', { args = { '^3Courier', ('#%d • %s x%d • £%s'):format(o.id, label, o.amount, o.total) } })
        end
        TriggerEvent('chat:addMessage', { args = { '^3Courier', 'Use ^2/accept [orderId]^7 to take one.' } })
    end)
end)

RegisterNetEvent("qb-player-shop:client:openCourierMenu", function(orderList)
    NUI_OPEN = true
    SetNuiFocus(true, true)
    SendNUIMessage({
        action = "openCourierMenu",
        orders = orderList
    })
    refreshCourierCount()
end)

RegisterNUICallback("acceptCourierOrder", function(data, cb)
    TriggerServerEvent("qb-player-shop:server:acceptOrder", data.id)
    cb("ok")
end)

RegisterCommand('accept', function(_, args)
    local id = tonumber(args[1] or 0)
    if not id or id < 1 then notify('Usage: /accept [orderId]', 'error') return end
    TriggerServerEvent('qb-player-shop:server:acceptOrder', id)
end, false)

-- ====== HUB BLIP + PROMPT ======
CreateThread(function()
    MakeHubBlip()
end)

CreateThread(function()
    local hub = Config.CourierHub
    while true do
        local wait = 1000
        local ped = PlayerPedId()
        local dist = #(GetEntityCoords(ped) - hub.coords)

        if dist < (hub.radius or 2.5) then
            wait = 0
            DrawMarker(2, hub.coords.x, hub.coords.y, hub.coords.z + 0.15, 0, 0, 0, 0, 0, 0,
                       0.4, 0.4, 0.4, 255, 150, 50, 155, false, true, 2, false, nil, nil, false)

            if CourierVanNet then
                DrawText3D(hub.coords.x, hub.coords.y, hub.coords.z + 0.5,
                    "~y~Courier Hub~s~\n~w~Press ~y~E~w~ to return your van")
            else
                DrawText3D(hub.coords.x, hub.coords.y, hub.coords.z + 0.5,
                    "~y~Courier Hub~s~\n~w~Press ~y~E~w~ to spawn van")
            end

            if IsControlJustPressed(0, 38) then -- E
                if CourierVanNet then
                    -- Try to return van
                    local myVan = NetworkGetEntityFromNetworkId(CourierVanNet)
                    if DoesEntityExist(myVan) then
                        if #(GetEntityCoords(ped) - hub.coords) < (hub.radius or 2.5) then
                            if TryDeleteVehicle(myVan) then
                                CourierVanNet = nil
                                ExecuteCommand("courierjob off")
                                QBCore.Functions.Notify('Courier van returned. Thank you!', 'success')
                            else
                                QBCore.Functions.Notify('Could not delete vehicle. Try again.', 'error')
                            end
                        else
                            QBCore.Functions.Notify('You must be at the Courier Hub to return the van.', 'error')
                        end
                    else
                        CourierVanNet = nil
                        QBCore.Functions.Notify('Your courier van is no longer around.', 'error')
                    end
                else
                    -- Spawn van
                    ExecuteCommand('couriervan')
                end
            end
        end

        Wait(wait)
    end
end)

-- ====== VAN COMMANDS ======
RegisterCommand('couriervan', function()
    if CourierVanNet then
        notify('You already have a courier van out. Use /returnvan at the hub.', 'error', 6000)
        return
    end
    if not IsNearHub() then
        notify('You need to be at the Courier Hub to spawn your van.', 'error', 5000)
        return
    end

    local model = Config.CourierHub.vehicle or 'speedo'
    local plate = (Config.CourierHub.platePrefix or 'COU') .. tostring(math.random(100, 999))

    QBCore.Functions.SpawnVehicle(model, function(veh)
        if not veh or not DoesEntityExist(veh) then
            notify('Failed to spawn vehicle.', 'error')
            return
        end
        SetEntityHeading(veh, Config.CourierHub.heading or 0.0)
        SetVehicleOnGroundProperly(veh)
        SetVehicleNumberPlateText(veh, plate)
        SetEntityAsMissionEntity(veh, true, true)
        TaskWarpPedIntoVehicle(PlayerPedId(), veh, -1)
        if GetResourceState('qb-vehiclekeys') == 'started' then
            TriggerEvent('vehiclekeys:client:SetOwner', plate)
        end
        if GetResourceState('LegacyFuel') == 'started' then
            exports['LegacyFuel']:SetFuel(veh, 95.0)
        end
        CourierVanNet = NetworkGetNetworkIdFromEntity(veh)
        ExecuteCommand("courierjob on")
        notify('Courier van spawned. Drive safe!', 'success', 5000)
    end, Config.CourierHub.coords, true)
end, false)

RegisterCommand('returnvan', function()
    if not CourierVanNet then
        notify('You don\'t have a courier van out.', 'error')
        return
    end
    if not IsNearHub() then
        notify('Return the van at the Courier Hub.', 'error')
        return
    end

    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    local myVan = NetworkGetEntityFromNetworkId(CourierVanNet)

    if veh ~= myVan then
        notify('Get into your courier van to return it.', 'error')
        return
    end
    if GetPedInVehicleSeat(veh, -1) ~= ped then
        notify('You must be the driver to return the van.', 'error')
        return
    end

    if TryDeleteVehicle(myVan) then
        CourierVanNet = nil
        ExecuteCommand("courierjob off")
        notify('Courier van returned. Thank you!', 'success')
    else
        notify('Could not delete vehicle. Try again.', 'error')
    end
end, false)

RegisterNetEvent('qb-player-shop:client:clearRoute', function()
    if RouteBlip then
        RemoveBlip(RouteBlip)
        RouteBlip = nil
    end
    activeDeliveryItem = nil
end)

-- Get open orders for NUI courier panel
RegisterNUICallback('courier:getOrders', function(_, cb)
    QBCore.Functions.TriggerCallback('qb-player-shop:server:getOpenOrders', function(list)
        for _, o in ipairs(list or {}) do
            local it = QBCore.Shared.Items[o.item]
            if it then o.label = it.label end
        end
        cb({ ok = true, orders = list or {} })
    end)
end)

-- Accept from NUI courier panel
RegisterNUICallback('courier:acceptOrder', function(data, cb)
    if data and data.id then
        TriggerServerEvent('qb-player-shop:server:acceptOrder', tonumber(data.id))
        cb({ ok = true })
    else
        cb({ ok = false })
    end
end)

-- Open courier menu command (optional convenience)
RegisterCommand('courierui', function()
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'openCourierMenu' })
    refreshCourierCount()
end, false)

-- keep single registration name unique
RegisterNetEvent('qb-player-shop:client:openCourierPanel', function()
    NUI_OPEN = true
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'openCourierMenu' })
    refreshCourierCount()
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then
        SetNuiFocus(false, false)
    end
end)
