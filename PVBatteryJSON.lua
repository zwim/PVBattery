-- luacheck: globals config
local json = require("dkjson")

return function(self, VERSION)
    local ChargerPowerCache = {}
    local InverterPowerCache = {}

    local sinks = 0
    for _, Battery in ipairs(self.USPBattery) do
        for _, Charger in ipairs(Battery.Charger) do
            Charger.power = Charger:getPower()
            table.insert(ChargerPowerCache, Charger.power)
            sinks = sinks + Charger.power
        end
    end
    for _, Battery in ipairs(self.SmartBattery) do
        sinks = sinks + math.max(-Battery.power, 0)
    end

    local sources =  self.P_PV
    for _, Inverter in ipairs(self.Inverter) do
        Inverter.power = math.abs(Inverter:getPower()) or 0
        table.insert(InverterPowerCache, Inverter.power)
        sources = sources + Inverter.power
    end
    for _, Battery in ipairs(self.SmartBattery) do
        sources = sources + math.max(Battery.power, 0)
    end

    local SOC_string = "<br>"
    for _, Battery in ipairs(self.Battery) do
        SOC_string = SOC_string .. Battery.Device.name .. " " .. Battery.SOC .."%<br>"
    end

    local data = {
        Vx_y_z = VERSION or "Vx.y.z",
        DATE = os.date(),
        SUNRISE = self.sunrise,
        SUNSET = self.sunset,
        STATE_OF_OPERATION = (self._state or "") .. " " .. SOC_string,
        FRONIUS_ADR = config.FRONIUS_ADR,
        P_GRID = self.P_Grid or "0.0",
        P_SELL_GRID = self.P_Grid < 0 and string.format("%5.1f", -self.P_Grid or 0) or "0.0",
        P_BUY_GRID = self.P_Grid > 0 and string.format("%5.1f", self.P_Grid or 0) or "0.0",
        P_LOAD = string.format("%5.1f", self.P_Load or 0),
        P_ROOF = string.format("%5.1f", self.P_PV or 0),
        BMS1_INFO = "http://" .. self.Battery[1].BMS.host .. "/show",
        BMS1_BALANCE_OFF = "http://" .. self.Battery[1].BMS.host .. "/balance.off",
        BMS1_BALANCE_ON = "http://" .. self.Battery[1].BMS.host .. "/balance.on",
        BMS1_BALANCE_TOGGLE = "http://" .. self.Battery[1].BMS.host .. "/balance.toggle",
        BATTERY_CHARGER1_POWER = string.format("%5.1f", ChargerPowerCache[1]),
        BATTERY_CHARGER1 = self.Battery[1].Charger[1].host,
        BATTERY_CHARGER2_POWER = string.format("%5.1f", ChargerPowerCache[2]),
        BATTERY_CHARGER2 = self.Battery[1].Charger[2].host,
        BATTERY_INVERTER_POWER = string.format("%5.1f", self.Battery[1].Inverter:getPower() or 0),
        BATTERY_INVERTER = self.Battery[1].Inverter.host,
        GARAGE_INVERTER_POWER = string.format("%5.1f", InverterPowerCache[3]),
        GARAGE_INVERTER = self.Inverter[3].Inverter.host,
        BALKON_INVERTER_POWER = string.format("%5.1f", InverterPowerCache[2]),
        BALKON_INVERTER = self.Inverter[2].Inverter.host,
        VENUS1_DISCHARGE_POWER = string.format("%5.1f", math.max(self.SmartBattery[1].power, 0)),
        VENUS1_CHARGE_POWER = string.format("%5.1f", math.max(-self.SmartBattery[1].power, 0)),
        VENUS2_DISCHARGE_POWER = string.format("%5.1f", math.max(self.SmartBattery[2].power, 0)),
        VENUS2_CHARGE_POWER = string.format("%5.1f", math.max(-self.SmartBattery[2].power, 0)),
        POWER_SINKS = string.format("%5.1f", sinks),
        POWER_SOURCES = string.format("%5.1f", sources),
        POWER_CONSUMED = string.format("%5.1f", self.P_Grid + sources - sinks),
    }

    local json_string = json.encode(data)

    -- Datei zum Schreiben öffnen ("w" = write, überschreibt bestehende Datei)
    local file, res = io.open(config.html_json, "w")
    if file then
        file:write(json_string)  -- String in die Datei schreiben
        file:close()      -- Datei schließen
    else
        self:log(0, "Fehler: JSON Datei '" .. config.html_json .."# konnte nicht geöffnet werden.", res)
    end

    -- JSON als String zurückgeben
    return json_string
end
