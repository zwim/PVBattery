
-- ###############################################################
-- CONFIGURATION
-- ###############################################################
local VERSION = "V5.2.0"

local Profiler = nil
-- profiler from https://github.com/charlesmallah/lua-profiler
--local Profiler = require("suntime/profiler")
if Profiler then
    Profiler.start()
end

--local GRID_THRESHOLD = 5
local MIN_CHARGE_POWER = 15
local MIN_DISCHARGE_POWER = 15

------------------------------------------------------------------

-- luacheck: globals config
config = require("configuration") -- this one is global

local mqtt_reader = require("base/mqtt_reader")
local util = require("base/util")

local SunTime = require("suntime/suntime")

local Influx = require("base/influx")

local BaseClass = require("mid/BaseClass")
local CustomBattery = require("mid/CustomBattery")
local MarstekBattery = require("mid/MarstekBattery")
local EnvertechInverter = require("mid/EnvertechInverter")
local FroniusInverter = require("mid/FroniusInverter")
local Homewizard = require("mid/Homewizard")
local SolarPrognose = require("mid/SolarPrognose")
local ForecastSolar = require("mid/ForecastSolar")

local PVBattery = BaseClass:extend{
    __name = "PVBattery",
    __loglevel = 3,

    -- very coarse default sunrise and sunset
    sunrise = 6,
    sunset = 18,

    P_Grid = 0,
    P_Load = 0,
    P_PV = 0,

    expected_yield = math.huge, -- hWh
    free_capacity = 0, -- kWh
}

-------------------- extend functions from this file
PVBattery.generateJSON = require("PVBatteryJSON")
PVBattery.serverCommands = require("servercommands")
--------------------

-- Helper to format solar times
local function formatSunEvent(label, hourVal)
    local h, m, s = util.hourToTime(hourVal)
    local str = string.format("%02d:%02d:%02d", h, m, s)
    util:log(label .. " at " .. str)
    return str
end

function PVBattery:init()
    BaseClass.init(self)

--    config:read()
    util:setLog(config.log_file_name or "PVBattery.log")
    util:setCompressor(config.compressor)

    util:log("\n#############################################")
    util:log("PV-Control started.")
    util:log("#############################################")

    -- Uhhhohhh we need correct ephemerides ;-)
    local position = config.position
    SunTime:setPosition(position.name, position.latitude, position.longitude, position.timezone, position.height, true)

    SunTime:setDate()
    SunTime:calculateTimes()

    self.sunrise = formatSunEvent("Sun rise", SunTime.rise)
    self.sunset  = formatSunEvent("Sun set", SunTime.set)

    -- IMPORTANT: Our authorative power meter, which shows if we produce or consume energy
--    self.P1meter = P1meter:new{host = "HW-p1meter.lan"}

    mqtt_reader:init(config.mqtt_broker_uri, config.mqtt_client_id)

    local ok, err = mqtt_reader:connect()
    if not ok then
        -- Wenn der initiale Connect fehlschlägt, ist das Test-Setup ungültig.
        self:log(0, "Initial connection failed: " .. tostring(err))
        return
    end

    mqtt_reader:processMessages()

    self.Battery = {}      -- all batteries
    self.SmartBattery = {} -- a subset of stupid custom batteries from all batteries
    self.UPSBattery = {}   -- a subset of smart batteries from all batteries

    self.Inverter = {}
    self.Smartmeter = {}

    for _, Device in ipairs(config.Device) do
        local typ = Device.typ:lower()
        local brand = Device.brand:lower()
        if typ == "battery" then
            if  brand == "custom" then
                local cBatt = CustomBattery:new{Device = Device}
                table.insert(self.Battery, cBatt)
                table.insert(self.UPSBattery, cBatt)
            elseif brand == "marstek" then
                local mBatt = MarstekBattery:new{Device = Device}
                table.insert(self.Battery, mBatt)
                table.insert(self.SmartBattery, mBatt)
            else
                assert(false, "Wrong configuration, battery brand not known")
            end
        elseif typ == "inverter" then
            if brand == "envertech" then
                local eInv = EnvertechInverter:new{Device = Device}
                table.insert(self.Inverter, eInv)
            elseif brand == "fronius" then
                self.Fronius = FroniusInverter:new{Device = Device}
                table.insert(self.Inverter, self.Fronius)
            else
                assert(false, "Wrong configuration, inverter brand not known")
            end
        elseif typ == "smartmeter" then
            table.insert(self.Smartmeter, Homewizard:new{Device = Device})
        elseif typ == "prognose" then
            if brand == "solarprognose" then
                self.SolarprognoseModul = SolarPrognose:new{config = Device.cfg}
            elseif brand == "forecast.solar" then
                self.ForecastsolarModul = ForecastSolar:new{config = Device.cfg}
            end
        end
    end

    -- Influx:init("http://battery-control:8086", "", "Photovoltaik", "Leistung")
    Influx:init(config.db_url, config.db_token, config.db_org, config.db_bucket)

    self:log(0, "Initialisation completed")
end

function PVBattery:close()
    util.log(0, "Closing everything")
    for _, Battery in ipairs(self.Battery) do
        Battery:setPower(0)
    end
    self.SmartBattery[1]:setMode({auto = true})
    mqtt_reader:close()
end

function PVBattery:getValues()
    -- Attention, this accesses self.SmartBattery and self.UPSBattery as well
    self.free_capacity = 0
    for _, Battery in ipairs(self.Battery) do
        Battery.SOC = Battery:getSOC(true) or 0 -- force recalculation
        Battery.used_capacity = Battery.SOC/100 * Battery.Device.capacity
        Battery.free_capacity = Battery.Device.capacity - Battery.used_capacity
        self.free_capacity = self.free_capacity + Battery.free_capacity
        Battery.state = Battery:getState() or {}
    end
end

-- Ersetze die ganze doTheMagic-Funktion mit dieser Version
-- luacheck: ignore _second_try
function PVBattery:doTheMagic(_second_try)
    local battery_string = ""
    local SOC_string = ""

    -- Recalculate battery powers and SOCs
    self.P_Battery = 0
    for _, Battery in ipairs(self.Battery) do
        -- use schedule algorithm, if expected yield is more than the unused capacity
        Battery.use_schedule = (self.expected_yield or 0) > (self.free_capacity or 0)

        pcall(function() return Battery:getPower() end)
        self.P_Battery = self.P_Battery + Battery.power

        battery_string = battery_string .. string.format("%s: %5.0f   ", Battery.Device and Battery.Device.name or "unknown", Battery.power)
        SOC_string = SOC_string .. string.format("%s: %5.1f%%   ", Battery.Device and Battery.Device.name or "unknown", Battery.SOC or 0)
    end
    self:log(3, "Battery ... ", battery_string)
    self:log(3, "Battery ... ", SOC_string)

    -- get grid / pv / load readings (defensive)
    local ok_all, v1, v2, v3, v4 = pcall(function() return self.Fronius:getAllPower() end)
    if ok_all and type(v1) == "number" then
        self.P_Grid_slow, self.P_Load, self.P_PV, self.P_AC = v1, v2, v3, v4
    else
        -- fallback to keep previous or zero
        self:log(1, "Warning: Fronius:getAllPower failed")
    end
    local ok_pgrid, pg = pcall(function() return self.Fronius:getPower() end)
    if ok_pgrid and type(pg) == "number" then
        self.P_Grid = pg
    else
        self:log(1, "Warning: Fronius:getPower failed")
    end

    -- P_excess interpretation: positive -> we can discharge to grid (need to supply), negative -> we can charge batteries
    local P_excess = (self.P_Grid or 0) + (self.P_Battery or 0)
    self:log(1, string.format("P_Grid: %5.1f, P_excess: %5.1f", self.P_Grid or 0, P_excess))

    -- quick sanity: if device lists missing, bail safely
    local smart_count = #self.SmartBattery
    if smart_count == 0 then
        self:log(2, "No SmartBattery configured")
    end

    -- Check for manual overrides: if some battery reports state that needs clearing, do it and retry once
    local clear_any_battery
    if P_excess > MIN_DISCHARGE_POWER then
        for _, Battery in ipairs(self.Battery) do
            if Battery.state and Battery.state.take then
                pcall(function() Battery:take(0) end)
                P_excess = P_excess - (Battery.power or 0)
                clear_any_battery = "taken"
            end
        end
    elseif P_excess < -MIN_CHARGE_POWER then
        for _, Battery in ipairs(self.Battery) do
            if Battery.state and Battery.state.give then
                pcall(function() Battery:give(0) end)
                clear_any_battery = "given"
            end
        end
    end
    if clear_any_battery then
        self:log(3, "cleared:", clear_any_battery)
        if _second_try then
            return
        else
            self:doTheMagic(true)
            return
        end
    end

    -------------------------------------------------------
    -- DISCHARGE PATH (P_excess > 0)  -- positive numbers
    -------------------------------------------------------
    if P_excess > MIN_DISCHARGE_POWER and smart_count > 0 then
        -- First: try to use UPS batteries (UPSBattery) to supply bulk if available
        for _, Battery in ipairs(self.UPSBattery) do
            -- defensive max power read
            local ok, maxp = pcall(function() return Battery.Inverter:getMaxPower() end)
            local max_discharge = ok and type(maxp) == "number" and -maxp or 0
            if max_discharge == 0 then max_discharge = -math.huge end

            if P_excess + max_discharge > 0 then
                local state = Battery.state or {}
                if state.idle or state.can_give then
                    pcall(function() Battery:give(math.abs(P_excess)) end)
                    mqtt_reader:sleepAndCallMQTT(2)
                    pcall(function() Battery:getPower() end)
                    self:log(2, "GIVE", Battery.Device and Battery.Device.name or "usp", math.floor(Battery.power*10)/10)
                    P_excess = P_excess - Battery.power
                end
            else
                -- stop battery providing if insufficient
                P_excess = P_excess + (Battery.power or 0)
                pcall(function() Battery:give(0) end)
                Battery.power = 0
                self:log(2, "GIVE", Battery.Device and Battery.Device.name or "usp", 0)
            end
        end

        -- Compute demand metric: how much each smart battery *can* still discharge (based on SOC)
        local sum_remaining_SOC = 0
        for _, Battery in ipairs(self.SmartBattery) do
            local delta = math.max(0, (Battery.SOC or 0) - (Battery.Device and Battery.Device.SOC_min or 0))
            sum_remaining_SOC = sum_remaining_SOC + (delta * delta)
            Battery.batt_req_power = 0
        end

        if sum_remaining_SOC > 0 then
            -- proportional initial allocation
            local nb_avail = smart_count
            local not_distributed = P_excess -- positive
            for _, Battery in ipairs(self.SmartBattery) do
                local p = 0
                local soc_min = Battery.Device and Battery.Device.SOC_min or 0
                if (Battery.SOC or 0) > soc_min then
                    p = P_excess * (math.max(0, (Battery.SOC or 0) - soc_min)^2) / sum_remaining_SOC
                    local maxd = Battery.Device and Battery.Device.discharge_max_power or math.huge
                    if p > maxd then
                        p = maxd
                        nb_avail = nb_avail - 1
                    end
                    if p < MIN_DISCHARGE_POWER then
                        p = 0
                    end
                end
                Battery.batt_req_power = p
                not_distributed = not_distributed - p
            end

            -- distribute remainder while respecting per-battery discharge_max_power
            while not_distributed > MIN_DISCHARGE_POWER and nb_avail > 0 do
                local remaining_share = not_distributed / nb_avail
                if remaining_share < MIN_DISCHARGE_POWER then remaining_share = not_distributed end

                for _, Battery in ipairs(self.SmartBattery) do
                    local maxd = Battery.Device and Battery.Device.discharge_max_power or math.huge
                    if Battery.batt_req_power < maxd then
                        local add = remaining_share
                        -- if battery at or below min SOC, skip
                        if (Battery.SOC or 0) <= (Battery.Device and Battery.Device.SOC_min or 0) then
                            add = 0
                        else
                            local allowed = maxd - Battery.batt_req_power
                            if add > allowed then add = allowed end
                        end
                        Battery.batt_req_power = Battery.batt_req_power + add
                        not_distributed = not_distributed - add
                        nb_avail = nb_avail - 1
                        if not_distributed <= 0 or nb_avail < 1 then break end
                    end
                end
            end
            self:log(3, "Not distributed discharge power", math.floor(not_distributed*10)/10)
        end

        -- final clamp & apply: ensure we don't exceed per-battery limits and call give()
        for _, Battery in ipairs(self.SmartBattery) do
            local maxd = Battery.Device and Battery.Device.discharge_max_power or math.huge
            if Battery.batt_req_power > maxd then Battery.batt_req_power = maxd end

            local give_watts = math.floor(math.max(0, Battery.batt_req_power))
            if give_watts > 0 then
                local ok, err = pcall(function() Battery:give(give_watts) end)
                if not ok then
                    util:log(0, "Error on Battery:give for "..tostring(Battery.Device and Battery.Device.name)..": "..tostring(err))
                end
            else
                pcall(function() Battery:give(0) end)
            end
            self:log(2, "GIVE", Battery.Device and Battery.Device.name or "unknown", math.floor(Battery.batt_req_power*10/10))
            Battery.power = Battery.batt_req_power -- positive = discharging
        end
    end -- end discharge path

    -------------------------------------------------------
    -- CHARGE PATH (P_excess < 0)  -- negative numbers
    -------------------------------------------------------
    if P_excess < -MIN_CHARGE_POWER and smart_count > 0 then
        -- First: try to use UPS chargers to absorb bulk if available
        for _, Battery in ipairs(self.UPSBattery) do
            local max_charger = math.huge
            local ok1, m1 = pcall(function() return Battery.Charger[1]:getMaxPower() end)
            local ok2, m2 = pcall(function() return Battery.Charger[2]:getMaxPower() end)
            if ok1 and ok2 and type(m1) == "number" and type(m2) == "number" then
                max_charger = math.min(m1, m2)
            end

            if P_excess + max_charger < 0 then
                local state = Battery.state or {}
                if state.idle or state.can_take then
                    pcall(function() Battery:take(math.abs(P_excess)) end)
                    mqtt_reader:sleepAndCallMQTT(2)
                    pcall(function() Battery:getPower() end)
                    self:log(2, "TAKE", Battery.Device and Battery.Device.name or "usp", math.floor(Battery.power*10)/10)
                    P_excess = P_excess - Battery.power
                end
            else
                P_excess = P_excess + (Battery.power or 0)
                pcall(function() Battery:take(0) end)
                Battery.power = 0
                self:log(2, "TAKE", Battery.Device and Battery.Device.name or "usp", 0)
            end
        end

        -- compute how much each smart battery wants to charge (desiredMax - SOC)
        local sum_missing_SOC = 0
        for _, Battery in ipairs(self.SmartBattery) do
            local desired = 0
            local okd, d = pcall(function() return Battery:getDesiredMaxSOC() end)
            if okd and type(d) == "number" then desired = d end
            local delta = math.max(0, desired - (Battery.SOC or 0))
            sum_missing_SOC = sum_missing_SOC + (delta * delta)
            Battery.batt_req_power = 0
        end

        if sum_missing_SOC > 0 then
            local nb_avail = smart_count
            local not_distributed = P_excess -- negative

            -- proportional initial allocation (negative values)
            for _, Battery in ipairs(self.SmartBattery) do
                local p = 0
                local okd, desired = pcall(function() return Battery:getDesiredMaxSOC() end)
                desired = (okd and type(desired) == "number") and desired or (Battery.Device and Battery.Device.SOC_max or 100)
                if (Battery.SOC or 0) < desired then
                    p = (P_excess * (math.max(0, desired - (Battery.SOC or 0))^2)) / sum_missing_SOC
                    -- clamp to negative charge_max
                    local maxc = -(Battery.Device and Battery.Device.charge_max_power or math.huge)
                    if p < maxc then
                        p = maxc
                        nb_avail = nb_avail - 1
                    end
                    if p > -MIN_CHARGE_POWER then
                        p = 0
                    end
                end
                Battery.batt_req_power = p
                not_distributed = not_distributed - p
            end

            -- distribute remainder (still negative) respecting per-battery charge_max (negative)
            while not_distributed < -MIN_CHARGE_POWER and nb_avail > 0 do
                self:log(3, "distributing Charge: remaining", not_distributed, "batteries", nb_avail)
                local remaining_share = not_distributed / nb_avail
                if remaining_share > -MIN_CHARGE_POWER then remaining_share = not_distributed end

                for _, Battery in ipairs(self.SmartBattery) do
                    local maxc = -(Battery.Device and Battery.Device.charge_max_power or math.huge) -- negative
                    if Battery.batt_req_power > maxc then
                        local add = remaining_share -- negative
                        local okd, desired = pcall(function() return Battery:getDesiredMaxSOC() end)
                        desired = (okd and type(desired) == "number") and desired or (Battery.Device and Battery.Device.SOC_max or 100)

                        if desired <= (Battery.SOC or 0) then
                            add = 0
                        else
                            local allowed = maxc - Battery.batt_req_power -- negative or zero
                            if add < allowed then add = allowed end
                        end

                        Battery.batt_req_power = Battery.batt_req_power + add
                        not_distributed = not_distributed - add
                        nb_avail = nb_avail - 1
                        if not_distributed >= 0 or nb_avail < 1 then break end
                    end
                end
            end

            self:log(3, "Not distributed charge power", math.floor(not_distributed*10)/10)
        end

        -- final clamp & apply: ensure we don't exceed charger capabilities and call take()
        for _, Battery in ipairs(self.SmartBattery) do
            local maxc_pos = Battery.Device and Battery.Device.charge_max_power or math.huge
            local maxc = -maxc_pos
            if Battery.batt_req_power < maxc then Battery.batt_req_power = maxc end

            local take_watts = math.floor(math.max(0, -Battery.batt_req_power)) -- pass positive watts to take()
            if take_watts > 0 then
                local ok, err = pcall(function() Battery:take(take_watts) end)
                if not ok then
                    util:log(0, "Error on Battery:take for "..tostring(Battery.Device and Battery.Device.name)
                        ..": "..tostring(err))
                end
            else
                pcall(function() Battery:take(0) end)
            end

            self:log(2, "TAKE", Battery.Device and Battery.Device.name or "unknown", math.floor(Battery.batt_req_power*10/10))
            Battery.power = Battery.batt_req_power -- negative = charging
        end
    end -- end charge path
end

function PVBattery:outputTheLog(date_string)
    local log_string
    log_string = string.format("%s  P_Grid=%5.0fW, P_Load=%5.0fW, Battery=%5.0fW, P_VenusE1=%5.0fW, P_VenusE2=%5.0fW",
        date_string, self.P_Grid or 0, self.P_Load or 0,
        (self.UPSBattery[1] and self.UPSBattery[1].power) or 0,
        (self.SmartBattery[1] and self.SmartBattery[1].power) or 0,
        (self.SmartBattery[2] and self.SmartBattery[2].power) or 0)

    util:log(log_string)
end

--Influx.writeLine = function(...)
--    print("INFLUX:", ...)
--end
function PVBattery:writeToDatabase()
    local datum = "Leistung"
    Influx:writeLine("garage-inverter", datum, self.Inverter[3].power)
    Influx:writeLine("balkon-inverter", datum, self.Inverter[2].power)
    Influx:writeLine("battery-inverter", datum, self.UPSBattery[1].Inverter.power)

    Influx:writeLine("battery-charger",  datum, self.UPSBattery[1].Charger[1].power)
    Influx:writeLine("battery-charger2", datum, self.UPSBattery[1].Charger[2].power)

    Influx:writeLine("P_PV", datum, self.P_PV)
    Influx:writeLine("P_Grid", datum, self.P_Grid)
    Influx:writeLine("P_Load", datum, self.P_Load)

    Influx:writeLine("P_VenusE", datum, self.SmartBattery[1].power)
    Influx:writeLine("P_VenusE2", datum, self.SmartBattery[2].power)

    datum = "Energie"
    Influx:writeLine("garage-inverter", datum, self.Inverter[2]:getEnergyTotal())
    Influx:writeLine("balkon-inverter", datum, self.Inverter[3]:getEnergyTotal())

    Influx:writeLine("battery-inverter", datum, self.UPSBattery[1].Inverter:getEnergyTotal())
    Influx:writeLine("battery-charger", datum, self.UPSBattery[1].Charger[1]:getEnergyTotal())
    Influx:writeLine("battery-charger2", datum, self.UPSBattery[1].Charger[2]:getEnergyTotal())

    datum = "Storage"

    Influx:writeLine("SOC_battery", datum, self.UPSBattery[1].SOC)
    Influx:writeLine("SOC_VenusE", datum, self.SmartBattery[1].SOC)
    Influx:writeLine("SOC_VenusE2", datum, self.SmartBattery[2].SOC)

    Influx:writeLine("battery_used_capacity", datum, self.UPSBattery[1].used_capacity)
    Influx:writeLine("VenusE_used_capacity", datum, self.SmartBattery[1].used_capacity)
    Influx:writeLine("VenusE2_used_capacity", datum, self.SmartBattery[2].used_capacity)

    Influx:writeLine("free_capacity", datum, self.free_capacity)
    Influx:writeLine("expected_yield", datum, self.expected_yield)
end


function PVBattery:main(profiling_runs)
    local last_date, date
    -- optain a date in the past
    date = os.date("*t")
    date.year = date.year - 1

    while type(profiling_runs) ~= "number" or profiling_runs > 0 do
        self:log(0, "-----------------------")
        if type(profiling_runs) == "number" then
            profiling_runs = profiling_runs - 1
        end

        local _start_time = util.getCurrentTime()

        -- if config has changed, reload it
        if config:needUpdate() then
            config:read(true)
        end

        last_date = date
        date = os.date("*t")
        util:log("\n#############################################")

        local date_string = string.format("%d/%d/%d-%02d:%02d:%02d",
            last_date.year, last_date.month, last_date.day,
            last_date.hour, last_date.min, last_date.sec)

        util:log(date_string)
        -- Do the sun set and rise calculations if necessary
        if last_date.day ~= date.day or last_date.isdst ~= date.isdst then
            SunTime:setDate()
            SunTime:calculateTimes()
            util:cleanLogs()
            local h, m, s
            h, m, s = util.hourToTime(SunTime.rise)
            self.sunrise = string.format("%02d:%02d:%02d", h, m, s)
            util:log("Sun rise at " .. self.sunrise)
            h, m, s = util.hourToTime(SunTime.set)
            self.sunset = string.format("%02d:%02d:%02d", h, m, s)
            util:log("Sun set at " .. self.sunset)
        end

        util:log("\n-------- Total Overview:")
        util:log(string.format("Grid %8f W (%s)", self.P_Grid, self.P_Grid > 0 and "optaining" or "selling"))
        util:log(string.format("Load %8f W", self.P_Load))
        util:log(string.format("Roof %8f W", self.P_PV))
        util:log(string.format("VenusE1 %8f W", self.SmartBattery[1].power))
        util:log(string.format("VenusE2 %8f W", self.SmartBattery[2].power))

        self.expected_yield = 0
        if SunTime:isDayTime() then
            local now = os.time()
            local solarprognose_expected_yield = math.huge
            local forecastsolar_expected_yield = math.huge
            if self.SolarprognoseModul then
                self.SolarprognoseModul:fetch(now)
                solarprognose_expected_yield = self.SolarprognoseModul:get_remaining_daily_forecast_yield()
            end
            if self.ForecastsolarModul then
                self.ForecastsolarModul:fetch(now)
                forecastsolar_expected_yield = self.ForecastsolarModul:get_remaining_daily_forecast_yield()
            end
            self.expected_yield = math.min(solarprognose_expected_yield, forecastsolar_expected_yield)
        end

        self:log(3, "expected yield", self.expected_yield, "kWh; unused capacity", self.free_capacity, "kWh")

        self:getValues()

        -- update state, as the battery may have changed or the user could have changed something manually
        self:outputTheLog(date_string)

        self:log(2, "dothemagic")
        self:doTheMagic()

        self:log(3, "desired SOC", self.SmartBattery[1]:getDesiredMaxSOC())

        self:log(2, "generate JSON")

        local ok, result
        ok, result = pcall(self.generateJSON, self, VERSION)
        if not ok then
            print("Error on generateJSON", result)
        end
        self:log(3, "JSON done ...")
        ok, result = pcall(self.writeToDatabase, self)
        if not ok then
            print("Error on write to database", result)
        end
        self:log(3, "write to database done ...")

        self:serverCommands()

        util:log("\n. . . . . . . . . sleep . . . . . . . . . . . .")

        mqtt_reader:sleepAndCallMQTT(0.1)  -- leep at least 1/10 second
        mqtt_reader:sleepAndCallMQTT(config.sleep_time, _start_time) -- and at least config.sleep_time from start of loop
    end -- end of inner loop
end

-------------------------------------------------------------------------------

if #arg > 2 then
    if arg[1] and arg[1] == "-c" then
        if arg[2] then
            config.config_file_name = arg[2]
        end
    end
end

local MyBatteries = nil

local function protected_start()
    util.deleteRunningInstances("PVBattery") -- only necessary on first start

    if MyBatteries then
        MyBatteries:close()
    end

    MyBatteries = PVBattery:new{}
    MyBatteries:log(0, "Instantiation done")

    if not Profiler then
        -- this is the outer loop, a safety-net if the inner loop is broken with `break`
        while true do
            util:cleanLogs()
            MyBatteries:main()
        end
    else -- if Profiler
        MyBatteries:main(1)
        Profiler.stop()
        Profiler.report("test-profiler.log")
    end
end

while true do

    os.execute("cp battery.html /tmp/index.html")

    local ok, result = xpcall(protected_start, util.crashHandler)

    if ok then
        PVBattery:log(0, "main() returned true. This should never happen .......")
    else
        if tostring(result):match("interrupted") then
            PVBattery:log(0, "Ctrl+C (SIGINT)")
            MyBatteries:close() -- set everything to a safe state

            os.exit(0)
        else
            PVBattery:log(0, "error in main():", result, "restart main() loop in 5 seconds")
            util.sleepTime(5)
        end
    end
end
