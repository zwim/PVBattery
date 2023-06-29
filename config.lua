-- Configuration file for PVBattery.lua

position = {
    name = "Kirchbichl",
    latitude = 47.5109083,
    longitude = 12.0855866,
    altitude = 520,
    timezone = nil,
}

bat_max_feed_in = -350 -- Watt
bat_max_take_out = 158 -- Watt
exceed_factor = 100 -- 5%

bat_soc_min = 20 -- Percent
bat_soc_max = 90 -- Percent

load_full_time = 1 -- hour before sun set

sleep_time = 10 -- seconds to sleep per iteration
