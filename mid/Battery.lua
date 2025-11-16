-- Masterclass for Batteries

local PowerDevice = require("mid/PowerDevice")
local SunTime     = require("suntime/suntime")
local util        = require("base/util")

local FILENAME = "/tmp/last_full_timestamp"

-- Hilfsfunktion zum Lesen des letzten Zeitstempels aus der Datei
local function read_timestamp()
    local content, err = util.read_file(FILENAME)
    if not content then
        print("Error: could not read timestamp from" .. FILENAME)
        return nil, err
    end
    return tonumber(content)
end

-- Hilfsfunktion zum Schreiben des aktuellen Zeitstempels in die Datei
local function write_timestamp(timestamp)
    if not util.write_file(FILENAME, tostring(timestamp)) then
        print("Error: could not write timestamp to" .. FILENAME)
        os.execute("date")
        return false
    end
    return true
end

local Battery = PowerDevice:extend{
    __name = "Battery",
    internal_state = "",

    use_schedule = true,
    OFFSET_TO_HIGH_NOON = -1/4, -- in hours
    OFFSET_TO_SUNSET = -3.25, -- in hours
    FIRST_MAX_SOC_LEVEL = 60, -- Percent
    SECOND_MAX_SOC_LEVEL = 80, -- Percent

    full_charge_interval_d = 10, -- charge full at least every 10 days (for balancing)
    full_charge_duration_s = 120, -- at least 2 minutes
    last_full_timestamp = nil,
    last_full_start_timestamp = nil,
}

function Battery:new(o)
    o = self:extend(o)
    if o.host then
        o.host = o.host:lower()
    end
    if o.init then
        o:init()
    end
    return o
end

function Battery:init()
    if PowerDevice.init then PowerDevice.init(self) end
    if not self.max_power then
        self.max_power = 0
    end
    self.use_scheduled = true

    -- Lade den letzten Zeitstempel aus der Datei
    local saved_timestamp = read_timestamp()
    if saved_timestamp then
        self.last_full_timestamp = saved_timestamp
    end

    -- Initialisierung/Default, falls die Datei leer oder nicht vorhanden ist
    if not self.last_full_timestamp then
        self.last_full_timestamp = os.time() - (self.full_charge_interval_d * (24*3600) + 1)
    end
end

--------------------------------------------------------------------------
-- req_power < 0 push energy to the battery
-- req_power > 0 get power from the battery
-- req_power = 0 set battery to idle
function Battery:setPower(req_power)
end

function Battery:setMode(modus)
    if modus.auto then
        print("Auto Mode enabled, not implemented yet")
    elseif modus.manual then
        print("Manual Mode enabled, not implemented yet")
    end
end

function Battery:take(req_power)
end

-- An absolutely straightforward battery charging optimization strategy:
-- The maximum allowed SOC (state of charge) is adjusted to the time (depending of the sun position)
--
-- 1. From sunrise until shortly after the solar zenith (peak sun), change the maximum SOC to 60%.
-- 2. Starting from the end of step 1, up to 2.5 hours before sunset, the maximum SOC
--    is linearly increased to 80%.
-- 3. From that point on, change the maximum SOC to 100%.
--
-- There you have it. Optimizing your battery's life, with strategic percentage at a time.
--
-- ajustable parameters:
--self.OFFSET_TO_HIGH_NOON = -1/4 -- in hours
--self.OFFSET_TO_SUNSET = -2.5 -- in hours
--self.FIRST_MAX_SOC_LEVEL = 60 -- Percent
--self.SECOND_MAX_SOC_LEVEL = 80 -- Percent
function Battery:getDesiredMaxSOC_scheduled(current_time_h)

    current_time_h = current_time_h or SunTime:getTimeInHours()

    local time_1_h = SunTime.noon + self.OFFSET_TO_HIGH_NOON
    if current_time_h < time_1_h then
        return math.min(self.FIRST_MAX_SOC_LEVEL, self.Device.SOC_max)
    end

    local time_2_h = SunTime.set + self.OFFSET_TO_SUNSET
    if time_2_h < time_1_h then
        time_2_h = time_1_h + 0.5
    end
    if current_time_h > time_2_h then
        return self.Device.SOC_max
    end

    local y = self.SECOND_MAX_SOC_LEVEL - self.FIRST_MAX_SOC_LEVEL
    local x = time_2_h - time_1_h
    local k = y / x

    local t = current_time_h - time_1_h

    local max_SOC = self.FIRST_MAX_SOC_LEVEL + t * k
    return max_SOC
--        return SECOND_MAX_SOC_LEVEL
end

function Battery:getDesiredMaxSOC(current_time_h)
    local current_timestamp = os.time()
    local interval_s = self.full_charge_interval_d * (24 * 3600) -- Intervall in Sekunden

    -- *** Start der Balancing-Logik ***
    local should_start_full_charge = false
    local is_full_charge_active = false
    local full_charge_needed_duration_s = self.full_charge_duration_s

    -- 1. Prüfen, ob eine Vollladung ausgelöst werden muss
    if self.last_full_timestamp and current_timestamp - self.last_full_timestamp >= interval_s then
        -- Wenn seit dem letzten Mal mehr als das Intervall vergangen ist
        should_start_full_charge = true
    end

    -- 2. Prüfen, ob eine Vollladung aktuell aktiv ist und ob die Dauer erreicht ist
    if self.last_full_start_timestamp then
        local active_duration = current_timestamp - self.last_full_start_timestamp
        if active_duration < full_charge_needed_duration_s then
            -- Vollladung ist aktiv, aber die Mindestdauer ist noch nicht erreicht
            is_full_charge_active = true
        else
            -- Mindestdauer erreicht: Vollladung abschließen und Zeitstempel aktualisieren
            self.last_full_timestamp = current_timestamp
            write_timestamp(current_timestamp)
            self.last_full_start_timestamp = nil -- Beende den aktiven Zeitraum
        end
    end

    -- 3. Max_SOC setzen
    if should_start_full_charge and not is_full_charge_active then
        -- Beginne Vollladung: Max_SOC auf 100 setzen und Start-Zeitstempel speichern
        self.last_full_start_timestamp = current_timestamp
        is_full_charge_active = true -- Setze auf aktiv für den aktuellen Durchlauf
    end

    if is_full_charge_active then
        -- Vollladung läuft
        return 100
    end
    -- *** Ende der Balancing-Logik ***

    if self.use_schedule then
        return self:getDesiredMaxSOC_scheduled(current_time_h)
    else
        return self.Device.SOC_max
    end
end

function Battery:give(req_power)
end

function Battery:getSOC()
end

-- returns "give", "take", "idle", "chargeable", "can_give", "can_take"
function Battery:getState()
end

-- returns positive if chargeing, negative if dischargeing
-- if internal is set, get internal power, else AC-power
function Battery:getPower(internal)
end

-- turns on balancing
function Battery:balance()
end

-- if internal is set, get internal Voltage, else AC-Voltage
function Battery:getVoltage(internal)
end

-- returns positive if chargeing, negative if dischargeing
-- if internal is set, get internal current, else AC-current
function Battery:getCurrent(internal)
end

-- always AC
function Battery:getEnergyTotal()
    error("not impl")
end

-- always AC
function Battery:setMaxDischargePower(max_power)
end

-- always AC
function Battery:getMaxDischargePower()
end

-- always AC
function Battery:setMaxChargePower(max_power)
end

-- always AC
function Battery:getMaxChargePower()
end

-- in percent
function Battery:setChargeCutOff(percent)
end

-- in percent
function Battery:getChargeCutOff()
end

-- in percent
function Battery:setDischargeCutOff(percent)
end

-- in percent
function Battery:getDischargeCutOff()
end

local function example()
    print("No example yet")
end

if arg[0]:find("Battery.lua") then
--    example()
end


return Battery
