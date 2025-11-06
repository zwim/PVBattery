
-- ###############################################################
-- CONFIGURATION
-- ###############################################################
local VERSION = "V5.1.1"

local Profiler = nil
-- profiler from https://github.com/charlesmallah/lua-profiler
--local Profiler = require("suntime/profiler")
if Profiler then
    Profiler.start()
end

local GRID_THRESHOLD = 5
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
local Solarprognose = require("mid/solarprognose")
local Forecastsolar = require("mid/forecastsolar")

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

    -- Init all device configurations

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
    self.USPBattery = {}   -- a subset of smart batteries from all batteries

    self.Inverter = {}
    self.Smartmeter = {}

    for _, Device in ipairs(config.Device) do
        local typ = Device.typ:lower()
        local brand = Device.brand:lower()
        if typ == "battery" then
            if  brand == "custom" then
                local cBatt = CustomBattery:new{Device = Device}
                table.insert(self.Battery, cBatt)
                table.insert(self.USPBattery, cBatt)
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
                self.SolarprognoseModul = Solarprognose.new(Device.cfg)
            elseif brand == "forecast.solar" then
                self.ForecastsolarModul = Forecastsolar.new(Device.cfg)
            end
        end
    end

    -- Influx:init("http://battery-control:8086", "", "Photovoltaik", "Leistung")
    Influx:init(config.db_url, config.db_token, config.db_org, config.db_bucket)

    self:log(0, "Initialisation completed")
end

function PVBattery:getValues()
    -- Attention, this accesses self.SmartBattery and self.USPBattery as well
    self.free_capacity = 0
    for _, Battery in ipairs(self.Battery) do
        Battery.SOC = Battery:getSOC(true) or 0 -- force recalculation
        Battery.used_capacity = Battery.SOC/100 * Battery.Device.capacity
        Battery.free_capacity = Battery.Device.capacity - Battery.used_capacity
        self.free_capacity = self.free_capacity + Battery.free_capacity
        Battery.state = Battery:getState() or {}
    end
end

local P_exzess_old = 0
local doTheMagic_early_return = 0
function PVBattery:doTheMagic(_second_try)
    local battery_string = ""
    local SOC_string = ""

    self.P_Battery = 0
    for _, Battery in ipairs(self.Battery) do
        -- use schedule algorithm, if expected yield is more than the unused capacity
        Battery.use_schedule = self.expected_yield > self.free_capacity

        Battery.power = Battery:getPower() -- negative, if dischargeing
        self.P_Battery = self.P_Battery + Battery.power
        battery_string = battery_string .. string.format("%s: %5.0f   ", Battery.Device.name, Battery.power)
        SOC_string = SOC_string .. string.format("%s: %5.1f%%   ", Battery.Device.name, Battery.SOC)

    end
    self:log(3, "Battery ... ", battery_string)
    self:log(3, "Battery ... ", SOC_string)

    -- Workaround, as the TINETZ SmartMeter delivres data only every 5-10 sec.
--    local value, is_data_old = self.Smartmeter[1]:getPower()
--    if is_data_old then
--        self:log(1, "P1Meter: no new data")
--        return
--    end
--    self.P_Grid = value

    self.P_Grid_slow, self.P_Load, self.P_PV, self.P_AC  = self.Fronius:getAllPower()
    self.P_Grid = self.Fronius:getPower() -- this a fast modbus call

    -- P_exzess is the power we could
    --     store in our batteries if negative
    --     reclaim from our batteries if positive
    local P_exzess = self.P_Grid + self.P_Battery
    self:log(1, string.format("P_Grid: %5.1f, P_exzess: %5.1f, P_exzess_old: %5.1f", self.P_Grid, P_exzess, P_exzess_old))

    if doTheMagic_early_return < 10 then
        doTheMagic_early_return = 0
        if math.abs(self.P_Grid) < GRID_THRESHOLD then
            return
        end
    else
        doTheMagic_early_return = doTheMagic_early_return + 1
    end

    -- if at least one battery does not, what is expected, turn it of and retrun early
    -- we get here soon again ;)
    local clear_any_battery
    if P_exzess > MIN_DISCHARGE_POWER then -- discharge batteries
        for _, Battery in ipairs(self.Battery) do
            if Battery.state.take then
                Battery:take(0)
                P_exzess = P_exzess - Battery.power
                clear_any_battery = "taken"
            end
        end
    elseif P_exzess < -MIN_CHARGE_POWER then -- charge batteries
        for _, Battery in ipairs(self.Battery) do
            if Battery.state.give then
                Battery:give(0)
                clear_any_battery = "given"
            end
        end
    end
    if clear_any_battery then
        self:log(3, clear_any_battery)
        if _second_try then
            return
        else
            return self:doTheMagic(true) -- call again and leave after that
        end
    end

    if doTheMagic_early_return < 10 then
        doTheMagic_early_return = 0
        if math.abs(P_exzess - P_exzess_old) < 10 then
            return
        end
    else
        doTheMagic_early_return = doTheMagic_early_return + 1
    end

    P_exzess_old = P_exzess

    if P_exzess > MIN_DISCHARGE_POWER then -- discharge batteries
        for _, Battery in ipairs(self.USPBattery) do
            local max_discharge_power_power = -Battery.Inverter:getMaxPower() -- negative, maximal discharge of the USP
            if P_exzess + max_discharge_power_power > 0 then
                local state = Battery.state
                if state.idle or state.can_give then
                    Battery:give(math.abs(P_exzess))
                    mqtt_reader:sleepAndCallMQTT(2)
                    Battery.power = Battery:getPower() -- negative, if dischargeing
                    self:log(2, "GIVE", Battery.Device.name, Battery.power)
                    P_exzess = P_exzess - Battery.power
                end
            else
                P_exzess = P_exzess + Battery.power -- because we stop battery soon
                Battery:give(0)
                Battery.power = 0
                self:log(2, "GIVE", Battery.Device.name, 0)
            end
        end

        local sum_remaining_SOC = 0
        for _, Battery in ipairs(self.SmartBattery) do
            sum_remaining_SOC = sum_remaining_SOC + (math.max(0, Battery.SOC - Battery.Device.SOC_min))^2
            Battery.batt_req_power = 0
        end
        if sum_remaining_SOC > 1 then
            local nb_batteries = #self.SmartBattery
            local not_distributed_power = P_exzess -- positive
            -- first distribute power depending on SOC
            for _, Battery in ipairs(self.SmartBattery) do
                local p = 0
                if Battery.SOC >= Battery.Device.SOC_min then
                    p = P_exzess * (Battery.SOC - Battery.Device.SOC_min)^2 / sum_remaining_SOC -- proportional share
                    if p > Battery.Device.discharge_max_power then
                        p = Battery.Device.discharge_max_power
                        nb_batteries = nb_batteries - 1
                    end
                    if p < MIN_CHARGE_POWER then
                        p = 0 -- no power for now
                    end
                end
                Battery.batt_req_power = p -- is positive or zero
                not_distributed_power = not_distributed_power - p -- should be and stay positive
            end

            -- if there is not_distributed_power and
            while not_distributed_power > MIN_DISCHARGE_POWER and nb_batteries > 0 do
                local remaining_power = not_distributed_power / nb_batteries
                if remaining_power < MIN_DISCHARGE_POWER then
                    remaining_power = not_distributed_power -- give it all to one
                end
                for _, Battery in ipairs(self.SmartBattery) do
                    if Battery.Device.charge_max_power > Battery.batt_req_power then -- may get some power too
                        local power_to_add = remaining_power
                        if Battery.Device.discharge_max_power < Battery.batt_req_power + power_to_add   then
                            power_to_add = Battery.batt_req_power + power_to_add - Battery.Device.discharge_max_power
                        end
                        Battery.batt_req_power = Battery.batt_req_power + power_to_add
                        not_distributed_power = not_distributed_power - power_to_add
                        nb_batteries = nb_batteries - 1
                        if not_distributed_power <= 0 or nb_batteries < 1 then
                            break
                        end
                    end
                end
            end
        end -- sum_remaining_SOC

        for _, Battery in ipairs(self.SmartBattery) do
            Battery.batt_req_power = math.min(Battery.batt_req_power, Battery.Device.discharge_max_power)
            Battery:give(math.floor(Battery.batt_req_power))
            self:log(2, "GIVE", Battery.Device.name, Battery.batt_req_power)
            Battery.power = Battery.batt_req_power
        end

    elseif P_exzess < -MIN_CHARGE_POWER then -- charge batteries

        for _, Battery in ipairs(self.USPBattery) do
            local max_charger_power = math.min(Battery.Charger[1]:getMaxPower(),Battery.Charger[2]:getMaxPower())
            if   P_exzess + max_charger_power < 0 then
                local state = Battery.state
                if state.idle or state.can_take then
                    Battery:take(math.abs(P_exzess))
                    mqtt_reader:sleepAndCallMQTT(2)
                    Battery.power = Battery:getPower() -- negative if dischargeing
                    self:log(2, "TAKE", Battery.Device.name, Battery.power)
                    P_exzess = P_exzess - Battery.power
                end
            else
                P_exzess = P_exzess + Battery.power
                Battery:take(0)
                Battery.power = 0
                self:log(2, "TAKE", Battery.Device.name, 0)
            end
        end

        local sum_missing_SOC = 0
        for _, Battery in ipairs(self.SmartBattery) do
            sum_missing_SOC = sum_missing_SOC + (math.max(0, Battery:getDesiredMaxSOC() - Battery.SOC))^2
            Battery.batt_req_power = 0
        end
        if sum_missing_SOC >= 1 then
            local nb_batteries = #self.SmartBattery
            local not_distributed_power = P_exzess --negative
            -- first distribute power depending on SOC
            for _, Battery in ipairs(self.SmartBattery) do
                local p = 0
                if Battery.SOC <= Battery:getDesiredMaxSOC() then
                    p = (P_exzess * (Battery:getDesiredMaxSOC() - Battery.SOC)^2 / sum_missing_SOC) -- proportional share
                    if p < -Battery.Device.charge_max_power then
                        p = -Battery.Device.charge_max_power
                        nb_batteries = nb_batteries - 1
                    end
                    if p > -MIN_CHARGE_POWER then
                        p = 0 -- no power for now
                    end
                end
                Battery.batt_req_power = p -- is negative
                not_distributed_power = not_distributed_power - p -- should be and stay negative
            end

            -- if there is not_distributed_power and
            while not_distributed_power < -MIN_CHARGE_POWER and nb_batteries > 0 do
                self:log(3, "distributing Power: " .. not_distributed_power)
                local remaining_power = not_distributed_power / nb_batteries
                if remaining_power > -MIN_CHARGE_POWER then
                    remaining_power = not_distributed_power
                end
                for _, Battery in ipairs(self.SmartBattery) do
                    if -Battery.Device.charge_max_power < Battery.batt_req_power then -- may get some power too
                        local power_to_add = remaining_power
                        if Battery:getDesiredMaxSOC() <= Battery.SOC then
                            power_to_add = 0
                        elseif -Battery.Device.charge_max_power > Battery.batt_req_power + power_to_add then
                            power_to_add = Battery.batt_req_power + power_to_add - Battery.Device.charge_max_power
                        end
                        Battery.batt_req_power = Battery.batt_req_power + power_to_add
                        not_distributed_power = not_distributed_power - power_to_add
                        nb_batteries = nb_batteries - 1
                        if not_distributed_power >= 0 or nb_batteries < 1 then
                            break
                        end
                    end
                end
            end
            self:log(3, "Not distributed power", not_distributed_power)
        end -- sum_missing_SOC

        for _, Battery in ipairs(self.SmartBattery) do
            Battery.batt_req_power = math.min(Battery.batt_req_power, Battery.Device.discharge_max_power)
            Battery:take(math.floor(math.max(0, -Battery.batt_req_power)))
            self:log(2, "TAKE", Battery.Device.name, Battery.batt_req_power)
            Battery.power = Battery.batt_req_power
        end
    end
end

function PVBattery:outputTheLog(date_string)
    local log_string
    log_string = string.format("%s  P_Grid=%5.0fW, P_Load=%5.0fW, Battery=%5.0fW, P_VenusE1=%5.0fW, P_VenusE1=%5.0fW",
        date_string, self.P_Grid or 0, self.P_Load or 0,
        self.Battery[1].power or 0,
        self.Battery[2].power or 0,
        self.Battery[2].power or 0) --xxxxxxxxxx

    util:log(log_string)
end

--Influx.writeLine = function(...)
--    print("INFLUX:", ...)
--end
function PVBattery:writeToDatabase()
    local datum = "Leistung"
    Influx:writeLine("garage-inverter", datum, self.Inverter[3].power)
    Influx:writeLine("balkon-inverter", datum, self.Inverter[2].power)
    Influx:writeLine("battery-inverter", datum, self.USPBattery[1].Inverter.power)

    Influx:writeLine("battery-charger",  datum, self.USPBattery[1].Charger[1].power)
    Influx:writeLine("battery-charger2", datum, self.USPBattery[1].Charger[2].power)

    Influx:writeLine("P_PV", datum, self.P_PV)
    Influx:writeLine("P_Grid", datum, self.P_Grid)
    Influx:writeLine("P_Load", datum, self.P_Load)

    Influx:writeLine("P_VenusE", datum, self.SmartBattery[1].power)
    Influx:writeLine("P_VenusE2", datum, self.SmartBattery[2].power)

    datum = "Energie"
    Influx:writeLine("garage-inverter", datum, self.Inverter[2]:getEnergyTotal())
    Influx:writeLine("balkon-inverter", datum, self.Inverter[3]:getEnergyTotal())

    Influx:writeLine("battery-inverter", datum, self.USPBattery[1].Inverter:getEnergyTotal())
    Influx:writeLine("battery-charger", datum, self.USPBattery[1].Charger[1]:getEnergyTotal())
    Influx:writeLine("battery-charger2", datum, self.USPBattery[1].Charger[2]:getEnergyTotal())

    datum = "Storage"

    Influx:writeLine("SOC_battery", datum, self.USPBattery[1].SOC)
    Influx:writeLine("SOC_VenusE", datum, self.SmartBattery[1].SOC)
    Influx:writeLine("SOC_VenusE2", datum, self.SmartBattery[2].SOC)

    Influx:writeLine("battery_used_capacity", datum, self.USPBattery[1].used_capacity)
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


        self:getValues()

        self.expected_yield = 0
        if SunTime:isDayTime() then
            if self.SolarprognoseModul then
                self.SolarprognoseModul:fetch()
                local solarprognose_expecte_yield = self.SolarprognoseModul:get_remaining_daily_forecast_yield()
                self.expected_yield = solarprognose_expecte_yield
            end
            if self.ForecastsolarModul then
                self.ForecastsolarModul:fetch()
                local forecastsolar_expected_yield = self.ForecastsolarModul:get_remaining_daily_forecast_yield()
                self.expected_yield = math.min(self.expected_yield, forecastsolar_expected_yield)
            end
        end

        self:log(3, "expected yield", self.expected_yield, "kWh; unused capacity", self.free_capacity, "kWh")

        -- update state, as the battery may have changed or the user could have changed something manually
        self:outputTheLog(date_string)

        self:log(2, "dothemagic")
        self:doTheMagic()

        self:log(3, "desired SOC", self.SmartBattery[1]:getDesiredMaxSOC())

        self:log(2, "generate JSON")
        self:getValues() -- for the json
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

local function protected_start()
    util.deleteRunningInstances("PVBattery") -- only necessary on first start

    local MyBatteries = PVBattery:new{}
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
    local ok, result = xpcall(protected_start, util.crashHandler)

    if ok then
        PVBattery:log(0, "main() returned true. This should never happen .......")
    else
        if tostring(result):match("interrupted") then
            PVBattery:log(0, "Ctrl+C (SIGINT)")
            -- todo: set mode to auto
            os.exit(0)
        else
            PVBattery:log(0, "error in main():", result, "restart main() loop in 5 seconds")
            util.sleepTime(5)
        end
    end
end

