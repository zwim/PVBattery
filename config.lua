-- Configuration file for PVBattery.lua

-- Can be used to chain load another config file at startup.
-- But be aware, the last file is the one to be checked continually
-- during PVBattery run.

-- config_file_name = "config.lua"

-- The globals here are locals after ``chunk, err = loadfile(file, "t", configuration)` so:
-- luacheck: ignore 111

-- Times are in seconds if no other extension is used (time_m, time_h ...)

log_file_name = "/var/log/PVBattery.log"

-- html_main = "/var/www/localhost/htdocs/index.html"
html_main = "/tmp/index.html"
--html_battery = "/var/www/localhost/htdocs/battery.html"
html_battery = "/tmp/battery.html"

MIDNIGHT_LAST = 1
DAWN_ASTRONOMICAL = 2
DAWN_NAUTICAL = 3
DAWN_CIVIL = 4
SUN_RISE = 5
NOON = 6
SUN_SET = 7
DUSK_CIVIL = 8
DUSK_NAUTICAL = 9
DUSK_ASTRONOMICAL = 10
MIDNIGHT = 11

position = {
    name = "Kirchbichl",
    latitude = 47.5109083,
    longitude = 12.0855866,
    altitude = 520,
    timezone = nil,
}

bat_SOC_min = 20 -- Percent
bat_SOC_full = 95
bat_SOC_max = 100 -- Percent
bat_SOC_min_rescue = 10 -- start rescue charge

bat_SOC_hysteresis = 3
bat_voltage_hysteresis = 0.100

bat_lowest_voltage = 2.850 -- lowest allowed voltage
bat_lowest_rescue = 2.800 -- start rescue charge
bat_highest_voltage = 3.550 -- highest allowed voltage
bat_high_voltage_hysteresis = 0.100 -- hysteresis on the high side
max_cell_diff = 0.150 -- maximum allowed cell diff
max_cell_diff_hysteresis = 0.020

min_cell_diff = 0.003 -- 0.003
min_cell_diff_base = 0.003 -- 0.003
cell_diff_hysteresis = 0.003
min_charge_power = 30
charge_finished_current = -0.3

load_full_time_h = 2.5 -- time before sun set, to load battery at maximum

sleep_time = 5 -- seconds to sleep per iteration

update_interval = 15 -- time to keep old data before an update

FRONIUS_ADR = "192.168.0.49"

mqtt_broker_uri = "battery-control.lan"
mqtt_client_id = "PVBattery"

-- db_url    = "http://localhost:8086"
-- db_token  = "ZWyI3Qh2E_LvX3EgifO_8cTbaBwyFktEfLwFxGiLffjX7HGQfDm7x4AzJuK7_1jp2Yfj6CzSat3Ozv4P8efLZQ=="
db_url    = "http://battery-control:8086"
db_token  = "Xeq_91oWUcNVCNwE4JsMYJ7-2qT3HybpO5HoqmI40ZEWxZ0Uo6f6GFwg0DamnCPIQBVEXeHcVIy5Or4SbkBkEw=="
db_org    = "PV"
db_bucket = "Daten"

Device = {
    { -- Device[1]
        name = "Battery Pack",
        BMS = "battery-bms.lan",
        charger_switches = {
            "battery-charger.lan",
            "battery-charger2.lan",
---            "battery-charger3.lan",
        },
        charger_max_power = {
            500,
            340,
--            200,
        },
        inverter_switch = "battery-inverter.lan",
        inverter_min_power = 150,
        inverter_time_controlled = nil,
    },
    { -- Device[2]
        name = "Garage Inverter",
        BMS = nil,
        charger_switches = {},
        inverter_switch = "garage-inverter.lan",
        inverter_time_controlled = "sunrise",
    },
    { -- Device[3]
        name = "Balkon Inverter",
        BMS = nil,
        charger_switches = {},
        inverter_switch = "balkon-inverter.lan",
        inverter_time_controlled = "sunrise",
    },
}

-- compressor = "bzip2 -6"
compressor = "zstd -8 --rm -T3"
