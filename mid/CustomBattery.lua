-- Home made battery

-- luacheck: globals config
local Battery = require("mid/Battery")

local AntBMS = require("base/antbms")
local ChargerClass = require("base/charger")
local InverterClass = require("base/inverter")

local mqtt_reader = require("base/mqtt_reader")

local internal_state = {
    fail = "fail", -- unknown state
    recalculate = "recalculate",
    idle = "idle",
    charge = "charge",
    balance = "balance", -- during charge or on the high side
    full = "full",
    discharge = "discharge",
    low_battery = "low_battery",
    low_cell = "low_cell", -- not needed as we do a rescue charge then
    high_cell = "high_cell",
    cell_diff_low = "cell_diff_low", -- cell diff and SOC > 50%
    cell_diff_high = "cell_diff_high", -- cell diff and SOC <=50%
    rescue_charge = "rescue_charge",
    force_discharge = "force_discharge",
    shutdown = "shutdown", -- shut down all charging and discharging ...
}

local CustomBattery = Battery:extend{
    __name = "CustomBattery",
    BMS = nil,
    Inverter = nil,
    Charger = {},
    internal_state = "",
}

function CustomBattery:init()
    -- 🚨 WICHTIG: Rufe zuerst die Init-Methode der Elternklasse (Battery) auf.
    -- Dies lädt self.last_full_timestamp aus /tmp/last_full_timestamp
    -- und setzt den Default-Wert, falls die Datei nicht existiert.
    if Battery.init then Battery.init(self) end

    local Device = self.Device
    self.min_SOC = self.Device.SOC_min or config.bat_SOC_min or 12
    self.max_SOC = self.Device.SOC_max or config.bat_SOC_max or 100
    self.power = 0
    if Device.BMS then
        self.BMS = AntBMS:new{
            host = Device.BMS,
            lastFullPeriod = config.lastFullPeriod,
            min_cell_diff = config.min_cell_diff,
            min_charge_power = config.min_charge_power,
            min_SOC = self.min_SOC,
            max_SOC = self.max_SOC,
        }
    end
    if Device.inverter_switch then
        self.Inverter = InverterClass:new{
            host = Device.inverter_switch,
            min_power = Device.inverter_min_power,
            max_power = Device.inverter_max_power,
        }
    end
    self.Charger = {}
    for i = 1, #Device.charger_switches do
        self.Charger[i] = ChargerClass:new{
            host = Device.charger_switches[i],
            max_power = Device.charger_max_power[i],
        }
    end

    self:log(3, "Initializing '" .. tostring(Device.name) .. "' and waiting for mqtt sync")
    self:log(3, "got messages#", mqtt_reader:sleepAndCallMQTT(5))
end

--------------------------------------------------------------------------

-- This returns the internal state of the custom battery: very detailed, too
-- detailed for the high level api
function CustomBattery:updateInternalState()
    if self.BMS:getData() then
        -- todo add chargin and discharging
        if self.BMS:isLowChargedOrNeedsRescue({fast = true}) or self.BMS.rescue_charge then
            return self:setInternalState(internal_state.rescue_charge)
        elseif self.BMS.v.SOC <= self.min_SOC then
            return self:setInternalState(internal_state.low_battery)
        elseif self.BMS.v.HighestVoltage >= config.bat_highest_voltage then
            return self:setInternalState(internal_state.high_cell)
        elseif self.BMS.v.CellDiff > config.max_cell_diff then
            if self.BMS.v.SOC > 50 then
                return self:setInternalState(internal_state.cell_diff_high)
            else
                return self:setInternalState(internal_state.cell_diff_low)
            end
        elseif self:getInternalState() == internal_state.cell_diff_high
        and self.BMS.v.CellDiff > config.max_cell_diff - config.max_cell_diff_hysteresis then
            return self:setInternalState(internal_state.cell_diff_high)
        elseif self:getInternalState() == internal_state.cell_diff_low
        and self.BMS.v.CellDiff > config.max_cell_diff - config.max_cell_diff_hysteresis then
            return self:setInternalState(internal_state.cell_diff_low)
        elseif self.BMS:isBatteryFull() then
            return self:setInternalState(internal_state.full)
        end
    else
        return self:setInternalState(internal_state.shutdown)
    end
    return self:setInternalState(internal_state.idle)
end

function CustomBattery:balanceIfNecessary()
    if self.BMS:needsBalancing() then
        self.BMS:enableDischarge()
        self.BMS:setAutoBalance(true)
    end
end

-- Returns the state and do some some battery care,
-- like disabling output if SOC is below threshold ...
function CustomBattery:getState()
    local result = {}

    local i_state = self:updateInternalState()
    if i_state == internal_state["idle"] then
        result.idle = true
        self:balanceIfNecessary()

    elseif i_state == internal_state["charge"] then
        result.take = true
        self:balanceIfNecessary()

    elseif i_state == internal_state["discharge"] then
        result.give = true
        self:balanceIfNecessary()

    elseif i_state == internal_state["low_battery"]
    or i_state == internal_state["low_cell"]
    or i_state == internal_state["rescue_charge"]
    or i_state == internal_state["cell_diff_low"] then

        result.can_take = true
        self:give(0) -- disables bsm output completely, but can be charged
        if i_state == internal_state["rescue_charge"] then
--            self:take("rescue")
        end

    elseif i_state == internal_state["full"]
    or i_state == internal_state["force_discharge"]
    or i_state == internal_state["high_cell"]
    or i_state == internal_state["cell_diff_high"] then

        result.can_give = true
        self:balanceIfNecessary()
    end

    if self.Inverter:getPowerState() == "on" then
        result.give = true
    end
    if self.Charger[1]:getPowerState() == "on" or self.Charger[2]:getPowerState() == "on" then
        result.take = true
    end

    return result
end


-- req_power < 0 push energy to the battery
-- req_power > 0 get power from the battery
-- req_power = 0 set battery to idle
function CustomBattery:setPower(req_power)
    if req_power == 0 then
        self.Charger[1]:safeStopCharge()
        self.Charger[2]:safeStopCharge()
        self.Inverter:safeStopDischarge()
        if self.BMS:needsBalancing() then
            self.BMS:setAutoBalance()
        else
            self.BMS:disableDischarge()
        end
    elseif req_power < 0 then -- charge
        self:take(-req_power)
    elseif req_power > 0 then -- discharge
        self:give(req_power)
    end
end

function CustomBattery:take(req_power)
    local p1 = self.Charger[1]:getMaxPower()
    local p2 = self.Charger[2]:getMaxPower()

    if req_power == "rescue" or self:updateInternalState() == internal_state["rescue_charge"] then
        self.Charger[1]:safeStartCharge()
        self.Charger[2]:safeStartCharge()
        return
    end

    if req_power == 0 or math.min(p1, p2) > req_power then
        self.Charger[1]:safeStopCharge()
        self.Charger[2]:safeStopCharge()
        return
    end

    if p1 + p2 <= req_power then
        self.Charger[1]:safeStartCharge()
        self.Charger[2]:safeStartCharge()
    elseif p1 >= p2 then
        if p1 <= req_power then
            self.Charger[1]:safeStartCharge()
            self.Charger[2]:safeStopCharge()
        else
            self.Charger[2]:safeStartCharge()
            self.Charger[1]:safeStopCharge()
        end
    elseif p2 > p1 then
        if p2 <= req_power then
            self.Charger[2]:safeStartCharge()
            self.Charger[1]:safeStopCharge()
        else
            self.Charger[1]:safeStartCharge()
            self.Charger[2]:safeStopCharge()
        end
    end
end

function CustomBattery:give(req_power)
    if req_power == 0 then
        self.Inverter:safeStopDischarge()
        return
    elseif req_power > self.Inverter.min_power then
        return self.Inverter:safeStartDischarge()
    end
end

function CustomBattery:getSOC(force)
    return self.BMS:getSOC(force)
end

function Battery:setInternalState(new_state)
    if internal_state[new_state] == new_state then
        self._internal_state = new_state
    else
        print("Error wrong state selected", new_state)
        self._internal_state = internal_state.fail
    end
    return self._internal_state
end

-- returns "give", "take", "idle", "can_take", "can_give"
function CustomBattery:getInternalState()
    return self._internal_state
end

-- returns positive if chargeing, negative if dischargeing
-- if internal is set, get internal power, else AC-power
function CustomBattery:getPower(internal)
    if internal then
        self.BMS:getParameters()
        local internal_power = self.BMS.v and self.BMS.v.CurrentPower
        return -internal_power
    else
        self.Inverter.power = self.Inverter:getPower()
        self.Charger[1].power = self.Charger[1]:getPower()
        self.Charger[2].power = self.Charger[2]:getPower()
        self.power = self.Inverter.power - self.Charger[1].power - self.Charger[2].power
        -- local poewr discharging_power - power1 - power2
        return self.power
    end
end

-- turns on balancing
function CustomBattery:balance()
    print("Todo: balancing not impl")
end

-- if internal is set, get internal Voltage, else AC-Voltage
function CustomBattery:getVoltage(internal)
    if internal then
        self.BMS:getParameters()
        return self.BMS.v and self.BMS.v.VoltageSum
    else
        print("Todo: voltage not impl. yet. 123!")
    end
end

-- returns positive if chargeing, negative if dischargeing
-- if internal is set, get internal current, else AC-current
function CustomBattery:getCurrent(internal)
    if internal then
        self.BMS:getParameters()
        return self.BMS.v and self.BMS.v.Current
    else
        print("Todo: current not impl. yet. 123!")
    end
end

-- always AC
function CustomBattery:getEnergyStored()
    self.BMS:getParameters()
    return self.BMS.v and self.BMS.v.PhysicalCapacity
end

-- always AC
-- returns true on success
function CustomBattery:setMaxDischargePower(max_power)
    return false
end

-- always AC
function CustomBattery:getMaxDischargePower()
    return self.Inverter:getMaxPower()
end

-- always AC
-- returns true on success
function CustomBattery:setMaxChargePower(max_power)
    return false
end

-- always AC
-- returns true on success
function CustomBattery:getMaxChargePower()
    local max_power = 0
    for _,v in pairs(self.Charger) do
        max_power = max_power + (v:getMaxPower() or 0)
    end
    return max_power
end

-- in percent
function CustomBattery:setChargeCutOff(percent)
    self.max_SOC = math.clamp(percent or self.max_SOC, 5, 50)
    self.BMS.max_SOC = self.max_SOC
    return self.max_SOC
end

-- in percent
function CustomBattery:getChargeCutOff()
    return self.max_SOC
end

-- in percent
function CustomBattery:setDischargeCutOff(percent)
    self.min_SOC = math.clamp(percent or self.min_SOC, 5, 50)
    self.BMS.min_SOC = self.min_SOC
    return self.min_SOC
end

-- in percent
-- returns true on success
function CustomBattery:getDischargeCutOff()
    return self.min_SOC
end

return CustomBattery
