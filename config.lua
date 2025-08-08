Config = {}

-- =========================
--  General / Shop settings
-- =========================

-- Solo testing: courier gets items, waypoint ~10m ahead, distance checks use saved coords
Config.TestSoloMode = true

-- Money flow
Config.CourierCut = 0.45         -- 45% of order total goes to courier
Config.PayFrom    = 'bank'       -- 'bank' or 'cash'

-- Pricing
Config.DefaultPrice = 250
Config.Prices = {
    -- water = 10,
    -- sandwich = 25,
}

-- Catalog options (used by the NUI catalog)
Config.ItemsPerPage   = 12        -- how many item tiles per page in the NUI
Config.HideNoPrice    = false     -- true = skip items with no price and no default
Config.BlacklistItems = {         -- explicit names to hide from the shop
    -- 'weapon_pistol', 'id_card'
}
-- If set, ONLY items present here (as keys with true) will be shown
-- Example: Config.WhitelistItems = { water = true, sandwich = true }
Config.WhitelistItems = nil

-- Limits / distances
Config.MaxQuantity      = 50
Config.DeliveryDistance = 6.0

-- Fallback command (still works even with NUI)
Config.EnableDirectBuyCommand = true


-- ==================================================
--  Courier Hub: blip on map + van spawn / return area
-- ==================================================
Config.CourierHub = {
    coords  = vector3(72.09, 121.06, 79.18),  -- hub location
    heading = 160.0,                           -- spawn heading for vehicle
    radius  = 8.0,                            -- how close you must be to spawn/return
    vehicle = 'speedo',                        -- van model ('speedo','boxville','pony', etc.)
    platePrefix = 'COU',                       -- plate prefix for spawned vans
    blip = {
        sprite = 477,                          -- blip icon
        color  = 5,                            -- blip color
        scale  = 0.9,                          -- blip size
        label  = 'Courier'                     -- blip name
    }
}

--[[ Optional note:
We also filter out these from the shop in server.lua:
- cokebaggy, crack_baggy, xtcbaggy
- anything starting with weed_
- anything starting with weapon_
- anything containing "muzzle"
If you want to change that later, poke me and I’ll move it into Config as a pattern list.
]]
