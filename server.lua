local QBCore = exports['qb-core']:GetCoreObject()

-- ================== STATE ==================
local Orders, LastOrderId = {}, 1000
local CourierEnabled = {}  -- [src] = true/false

-- ================== COURIER COUNT HELPERS ==================
local function courierCount()
    local n = 0
    for _, enabled in pairs(CourierEnabled) do
        if enabled then n = n + 1 end
    end
    return n
end

local function broadcastCourierCount()
    TriggerClientEvent('qb-player-shop:client:updateCourierCount', -1, courierCount())
end

QBCore.Functions.CreateCallback('qb-player-shop:server:getCourierCount', function(src, cb)
    cb(courierCount())
end)

AddEventHandler('playerDropped', function()
    CourierEnabled[source] = nil
    broadcastCourierCount()
end)

-- ================== UTILS ==================
local function nextOrderId() LastOrderId = LastOrderId + 1 return LastOrderId end

local function notify(src, msg, typ, time)
    TriggerClientEvent('QBCore:Notify', src, msg, typ or 'primary', time or 5000)
end

local function getItemPrice(name)
    local item = QBCore.Shared.Items[name]
    if not item then return nil end
    if Config.Prices[name] then return Config.Prices[name] end
    if item.price and type(item.price) == 'number' and item.price > 0 then return item.price end
    return Config.HideNoPrice and nil or Config.DefaultPrice
end

-- Build catalog for NUI (filters out contraband and builds image path)
local function buildCatalog(filter)
    local out, f = {}, string.lower(tostring(filter or ''))

    for name, item in pairs(QBCore.Shared.Items) do
        if type(item) == 'table' and item.name then
            local lowerName = string.lower(name)

            -- filter out drugs and weapons
            if lowerName == 'cokebaggy'
            or lowerName == 'crack_baggy'
            or lowerName == 'xtcbaggy'
            or lowerName:find('^weed_')
            or lowerName:find('muzzle')
            or lowerName:find('^weapon_') then
                goto continue
            end

            local price = Config.Prices[name] or item.price or Config.DefaultPrice
            if price and price > 0 then
                local label = item.label or name
                local match = (f == '') or string.find(string.lower(name), f, 1, true) or string.find(string.lower(label), f, 1, true)
                if match then
                    local imageName = item.image
                    if not imageName or imageName == '' then
                        imageName = name .. '.png'
                    end
                    out[#out+1] = {
                        name  = name,
                        label = label,
                        price = price,
                        image = imageName
                    }
                end
            end
        end
        ::continue::
    end

    table.sort(out, function(a, b) return a.label < b.label end)
    return out
end

local function playerIsCourier(src) return CourierEnabled[src] == true end

local function broadcastToCouriers(event, payload)
    for src, enabled in pairs(CourierEnabled) do
        if enabled then
            local ply = QBCore.Functions.GetPlayer(src)
            if ply then TriggerClientEvent(event, src, payload) else CourierEnabled[src] = nil end
        end
    end
end

-- ================== NUI CALLBACK ==================
QBCore.Functions.CreateCallback('qb-player-shop:server:getCatalog', function(src, cb, filter)
    cb(buildCatalog(filter))
end)

-- ================== ORDERS ==================
local function createOrder(buyerSrc, itemName, amount, unitPrice, buyerCoords)
    local id = nextOrderId()
    Orders[id] = {
        id = id,
        item = itemName,
        amount = amount,
        unitPrice = unitPrice,
        total = unitPrice * amount,
        buyerSrc = buyerSrc,
        buyerCid = QBCore.Functions.GetPlayer(buyerSrc).PlayerData.citizenid,
        buyerCoords = buyerCoords,    -- vector3
        status = 'open',              -- open -> accepted -> delivered/cancelled
        courierSrc = nil,
        deliveryCoords = nil,         -- {x,y,z} (client sets in solo mode)
        createdAt = os.time()
    }
    return Orders[id]
end

local function getOpenOrders()
    local list = {}
    for _, o in pairs(Orders) do if o.status == 'open' then list[#list+1] = o end end
    table.sort(list, function(a,b) return a.id < b.id end)
    return list
end

local function findOrder(id) return Orders[tonumber(id)] end

-- ================== PURCHASE ==================
RegisterNetEvent('qb-player-shop:server:placeOrder', function(itemName, amount, buyerCoords)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src); if not Player then return end

    itemName = tostring(itemName or ''):lower()
    amount = tonumber(amount or 0) or 0

    local item = QBCore.Shared.Items[itemName]
    if not item then notify(src, ('Item "%s" does not exist.'):format(itemName), 'error') return end
    if amount < 1 or amount > Config.MaxQuantity then notify(src, ('Invalid amount (1-%d).'):format(Config.MaxQuantity), 'error') return end

    local unitPrice = getItemPrice(itemName)
    if not unitPrice or unitPrice <= 0 then notify(src, 'This item cannot be purchased right now.', 'error') return end

    local total = unitPrice * amount
    if not Player.Functions.RemoveMoney(Config.PayFrom, total, 'player-shop-order') then
        notify(src, ('Not enough %s for this order (£%s).'):format(Config.PayFrom, total), 'error') return
    end

    local order = createOrder(src, itemName, amount, unitPrice, buyerCoords)
    notify(src, ('Order #%d placed. A courier will deliver your %s x%d.'):format(order.id, item.label, amount), 'success', 7000)

    broadcastToCouriers('qb-player-shop:client:newOrder', {
        id = order.id,
        item = itemName,
        amount = amount,
        total = total,
        buyerCoords = order.buyerCoords and { x = order.buyerCoords.x+0.0, y = order.buyerCoords.y+0.0, z = order.buyerCoords.z+0.0 } or nil
    })
end)

-- ================== OPEN ORDERS (COURIER) ==================
QBCore.Functions.CreateCallback('qb-player-shop:server:getOpenOrders', function(src, cb)
    if not playerIsCourier(src) then cb({}) return end
    cb(getOpenOrders())
end)

-- ================== ACCEPT ==================
RegisterNetEvent('qb-player-shop:server:acceptOrder', function(orderId)
    local src = source
    if not playerIsCourier(src) then notify(src, 'Enable courier mode with /courierjob first.', 'error') return end

    local order = findOrder(orderId)
    if not order or order.status ~= 'open' then notify(src, 'This order is no longer available.', 'error') return end

    order.status = 'accepted'; order.courierSrc = src

    if Config.TestSoloMode then
        local Courier = QBCore.Functions.GetPlayer(src)
        if Courier then
            if not Courier.Functions.AddItem(order.item, order.amount, false, {}) then
                notify(src, 'Your inventory is full! Make space before accepting.', 'error')
                order.status = 'open'; order.courierSrc = nil
                return
            end
            TriggerClientEvent('inventory:client:ItemBox', src, QBCore.Shared.Items[order.item], 'add', order.amount)
            notify(src, ('Received %s x%d to deliver.'):format(QBCore.Shared.Items[order.item].label, order.amount), 'primary', 6500)
        end
    end

    local buyer = QBCore.Functions.GetPlayer(order.buyerSrc)
    if buyer then notify(buyer.PlayerData.source, ('A courier has accepted your order #%d.'):format(order.id), 'primary') end

    notify(src, ('You accepted order #%d. Calculating route...'):format(order.id), 'success')
    TriggerClientEvent('qb-player-shop:client:computeDeliveryAhead', src, {
        id = order.id,
        buyerCoords = order.buyerCoords and { x = order.buyerCoords.x+0.0, y = order.buyerCoords.y+0.0, z = order.buyerCoords.z+0.0 } or nil,
        solo = Config.TestSoloMode == true,
        item = order.item
    })
end)

RegisterNetEvent('qb-player-shop:server:setDeliveryCoords', function(orderId, coords)
    local src = source
    local order = findOrder(orderId); if not order then return end
    if order.courierSrc ~= src or order.status ~= 'accepted' then return end
    if coords and coords.x and coords.y then
        order.deliveryCoords = { x = coords.x+0.0, y = coords.y+0.0, z = (coords.z or 0.0)+0.0 }
        notify(src, ('Route saved for order #%d.'):format(order.id), 'primary', 2500)
    end
end)

-- ================== DELIVER ==================
RegisterNetEvent('qb-player-shop:server:deliverOrder', function(orderId)
    local src = source
    local order = findOrder(orderId)
    if not order then notify(src, 'Order not found.', 'error') return end
    if order.status ~= 'accepted' then notify(src, 'This order is not in a deliverable state.', 'error') return end
    if order.courierSrc ~= src then notify(src, 'You are not assigned to this order.', 'error') return end

    local courierPed = GetPlayerPed(src); if not courierPed or courierPed == 0 then notify(src, 'Courier not available.', 'error') return end

    local targetCoords
    if Config.TestSoloMode and order.deliveryCoords then
        targetCoords = vector3(order.deliveryCoords.x, order.deliveryCoords.y, order.deliveryCoords.z)
    else
        local buyerPed = GetPlayerPed(order.buyerSrc or 0)
        if not buyerPed or buyerPed == 0 then notify(src, 'Buyer is no longer available.', 'error') return end
        targetCoords = GetEntityCoords(buyerPed)
    end

    local dist = #(GetEntityCoords(courierPed) - targetCoords)
    if dist > (Config.DeliveryDistance or 6.0) then
        notify(src, ('Too far from delivery location (%.1fm).'):format(dist), 'error') return
    end

    local Courier = QBCore.Functions.GetPlayer(src); if not Courier then notify(src, 'Courier not found.', 'error') return end
    local has = Courier.Functions.GetItemByName(order.item)
    if not has or (has.amount or 0) < order.amount then notify(src, ('You do not have %s x%d to deliver.'):format(order.item, order.amount), 'error') return end

    if not Courier.Functions.RemoveItem(order.item, order.amount) then notify(src, 'Failed to remove items.', 'error') return end
    TriggerClientEvent('inventory:client:ItemBox', src, QBCore.Shared.Items[order.item], 'remove', order.amount)

    local Buyer = QBCore.Functions.GetPlayer(order.buyerSrc)
    if not Buyer then
        Courier.Functions.AddItem(order.item, order.amount)
        TriggerClientEvent('inventory:client:ItemBox', src, QBCore.Shared.Items[order.item], 'add', order.amount)
        notify(src, 'Buyer offline; delivery aborted.', 'error') return
    end
    if not Buyer.Functions.AddItem(order.item, order.amount, false, {}) then
        Courier.Functions.AddItem(order.item, order.amount)
        TriggerClientEvent('inventory:client:ItemBox', src, QBCore.Shared.Items[order.item], 'add', order.amount)
        notify(src, 'Buyer inventory full.', 'error') return
    end
    TriggerClientEvent('inventory:client:ItemBox', Buyer.PlayerData.source, QBCore.Shared.Items[order.item], 'add', order.amount)

    Courier.Functions.AddMoney('bank', math.floor(order.total * Config.CourierCut), ('courier pay order %d'):format(order.id))
    order.status = 'delivered'

    notify(src, ('Delivered order #%d.'):format(order.id), 'success', 6500)
    TriggerClientEvent('qb-player-shop:client:clearRoute', src)
    notify(Buyer.PlayerData.source, ('Your order #%d has been delivered.'):format(order.id), 'success', 6500)
    TriggerClientEvent('qb-player-shop:client:clearRoute', src)
end)

-- ================== COMMANDS ==================
QBCore.Commands.Add('courierjob', 'Toggle courier accept mode (testing).', {
    { name = 'mode', help = 'on/off (optional, toggles if omitted)' }
}, false, function(src, args)
    local mode = args[1] and tostring(args[1]):lower() or nil
    if mode == 'on' then CourierEnabled[src] = true
    elseif mode == 'off' then CourierEnabled[src] = false
    else CourierEnabled[src] = not CourierEnabled[src] end

    local state = CourierEnabled[src] and 'ENABLED' or 'DISABLED'
    notify(src, ('Courier mode %s.'):format(state), CourierEnabled[src] and 'success' or 'error', 6000)

    -- push live count to everyone
    broadcastCourierCount()

    if CourierEnabled[src] then
        local open = getOpenOrders()
        if #open > 0 then notify(src, ('%d open orders. Use /courier.'):format(#open), 'primary', 6000) end
    end
end, 'user')

if Config.EnableDirectBuyCommand then
    QBCore.Commands.Add('buy', 'Buy an item directly (fallback)', {
        {name='item', help='Item name'}, {name='amount', help='Quantity'}
    }, false, function(src, args)
        local itemName = tostring(args[1] or ''):lower()
        local qty = tonumber(args[2] or 0) or 0
        if itemName == '' or qty < 1 then notify(src, 'Usage: /buy [item] [amount]', 'error') return end
        local pos = GetEntityCoords(GetPlayerPed(src))
        TriggerEvent('qb-player-shop:server:placeOrder', itemName, qty, vector3(pos.x, pos.y, pos.z))
    end, 'user')
end

QBCore.Commands.Add('shop', 'Open the player shop (NUI)', {}, false, function(src)
    TriggerClientEvent('qb-player-shop:client:openShop', src)
end, 'user')

RegisterCommand("courier", function(source)
    local list = {}
    for id, order in pairs(Orders) do
        if order.status == "open" then
            table.insert(list, {
                id = id,
                buyerName = order.buyerName or "Unknown",
                items = {{ name = order.item, amount = order.amount }},
                total = order.total
            })
        end
    end
    TriggerClientEvent("qb-player-shop:client:openCourierMenu", source, list)
end)

QBCore.Commands.Add('deliver', 'Deliver an accepted order (fallback).', {
    {name='orderId', help='Order ID'}
}, false, function(src, args)
    local id = tonumber(args[1] or 0)
    if not id or id < 1 then notify(src, 'Usage: /deliver [orderId]', 'error'); return end
    TriggerEvent('qb-player-shop:server:deliverOrder', id)
end, 'user')

QBCore.Commands.Add('cancelorder', 'Cancel your open order (fallback).', {
    {name='orderId', help='Order ID'}
}, false, function(src, args)
    local id = tonumber(args[1] or 0)
    if not id or id < 1 then notify(src, 'Usage: /cancelorder [orderId]', 'error'); return end
    TriggerEvent('qb-player-shop:server:cancelMyOrder', id)
end, 'user')

RegisterNetEvent('qb-player-shop:server:cancelMyOrder', function(orderId)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src); if not Player then return end
    local order = findOrder(orderId)
    if not order then notify(src, 'Order not found.', 'error') return end
    if order.buyerSrc ~= src then notify(src, 'That is not your order.', 'error') return end
    if order.status ~= 'open' then notify(src, 'Only unaccepted orders can be cancelled.', 'error') return end
    order.status = 'cancelled'
    Player.Functions.AddMoney(Config.PayFrom, order.total, ('refund order %d'):format(order.id))
    notify(src, ('Order #%d cancelled. £%s refunded.'):format(order.id, order.total), 'success')
end)

-- cancel route + order if courier loses the item
AddEventHandler('QBCore:Server:OnRemoveItem', function(src, itemName, amount)
    local order
    for _, o in pairs(Orders) do
        if o.courierSrc == src and o.status == 'accepted' and o.item == itemName then
            order = o
            break
        end
    end
    if order then
        TriggerClientEvent('qb-player-shop:client:clearRoute', src)
        order.status = 'cancelled'
        notify(src, ('Delivery item removed — order #%d cancelled.'):format(order.id), 'error', 5000)
    end
end)
