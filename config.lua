-- Configuration file for PVBattery.lua

-- Can be used to chain load another config file at startup.
-- But be aware, the last file is the one to be checked continually
-- during PVBattery run.

-- config_file_name = "config.lua"

log_file_name = "/var/log/PVBattery.log"

host = "battery-control.lan"
-- html_main = "/var/www/localhost/htdocs/index.html"
html_main = "/tmp/index.html"
--html_battery = "/var/www/localhost/htdocs/battery.html"
html_battery = "/tmp/battery.html"

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
exceed_factor = -0.15 -- shift the above values 10% down

bat_SOC_min = 12 -- Percent
bat_SOC_max = 95 -- Percent

deep_discharge_min = 4
deep_discharge_max = 8
deep_discharge_hysteresis = 4

bat_lowest_voltage = 2.89 -- lowest allowed voltage

load_full_time = 2.5 -- hour before sun set

sleep_time = 30 -- seconds to sleep per iteration

guard_time = 5 * 60 -- every 5 minutes
