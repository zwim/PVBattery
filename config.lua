-- Configuration file for PVBattery.lua

log_file_name = "/var/log/PVBattery.log"

position = {
    name = "Kirchbichl",
    latitude = 47.5109083,
    longitude = 12.0855866,
    altitude = 520,
    timezone = nil,
}

bat_max_feed_in = -350 -- Watt
bat_max_feed_in2 = -350 -- Watt
bat_max_take_out = 158 -- Watt
exceed_factor = -0.1 -- shift the above values 10% down

bat_SOC_min = 15 -- Percent
bat_SOC_max = 95 -- Percent

load_full_time = 2.5 -- hour before sun set

sleep_time = 30 -- seconds to sleep per iteration

guard_time = 5 * 60 -- every 5 minutes
