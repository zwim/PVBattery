return function(self, config, P_Grid, P_Load, P_PV)
    local ChargerPowerCache = {}
    local InverterPowerCache = {}

    local sinks = 0
    for i = 1, #self.Charger do
        ChargerPowerCache[i] = self.Charger[i]:getCurrentPower()
        sinks = sinks + (ChargerPowerCache[i] or 0)
    end

    local sources = P_PV
    for  i = 1, #self.Inverter do
        InverterPowerCache[i] = self.Inverter[i]:getCurrentPower()
        if sources then
            sources = sources + (InverterPowerCache[i] or 0)
        end
    end

    local SOC_string = "<br>SOC:"
    for  i = 1, #self.BMS do
        if self.BMS[i].v.SOC then
            SOC_string = SOC_string .. " " .. self.BMS[i].host .. " " .. self.BMS[i].v.SOC .. "%%<br>"
            SOC_string = SOC_string .. os.date("%c", self.BMS[i].timeOfLastFullBalancing) .. "<br>"
        end
    end

    local TEMPLATE_PARSER = {
        {"_$DATE$", os.date()},
        {"_$SUNRISE$", self.sunrise},
        {"_$SUNSET$", self.sunset},
        {"_$FRONIUS_ADR$", config.FRONIUS_ADR},
        {"_$STATE_OF_OPERATION$", self:getState() .. SOC_string},
        {"_$P_GRID$", string.format("%7.2f", P_Grid)},
        {"_$P_SELL_GRID$", P_Grid < 0 and string.format("%7.2f", P_Grid) or "0.00"},
        {"_$P_BUY_GRID$", P_Grid > 0 and string.format("%7.2f", P_Grid) or "0.00"},
        {"_$P_LOAD$", string.format("%7.2f", P_Load)},
        {"_$P_ROOF$", string.format("%7.2f", P_PV)},
        {"_$BMS1_INFO$", "http://" .. self.BMS[1].host .. "/show"},
        {"_$BMS1_BALANCE_OFF$", "http://" .. self.BMS[1].host .. "/balance.off"},
        {"_$BMS1_BALANCE_ON$", "http://" .. self.BMS[1].host .. "/balance.on"},
        {"_$BMS1_BALANCE_TOGGLE$", "http://" .. self.BMS[1].host .. "/balance.toggle"},

        {"_$BATTERY_CHARGER1_POWER$",
            string.format("%7.2f", ChargerPowerCache[1])},
        {"_$BATTERY_CHARGER1$", self.Charger[1].switch_host},
        {"_$BATTERY_CHARGER2_POWER$",
            string.format("%7.2f", ChargerPowerCache[2])},
        {"_$BATTERY_CHARGER2$", self.Charger[2].switch_host},
       {"_$BATTERY_CHARGER3_POWER$",
            string.format("%7.2f", ChargerPowerCache[3] or 0)},
--        {"_$BATTERY_CHARGER3$", self.Charger[3].switch_host},
        {"_$BATTERY_INVERTER_POWER$",
            string.format("%7.2f", InverterPowerCache[1])},
        {"_$BATTERY_INVERTER$", self.Inverter[1].host},
        {"_$GARAGE_INVERTER_POWER$",
            string.format("%7.2f", InverterPowerCache[2])},
        {"_$GARAGE_INVERTER$", self.Inverter[2].host},
 --       {"_$MOPED_CHARGER_POWER",
 --           string.format("%7.2f", ChargerPowerCache[3])},
 --       {"_$MOPED_CHARGER", self.Charger[3].switch_host},
 --       {"_$MOPED_INVERTER_POWER",
 --           string.format("%7.2f", InverterPowerCache[3])},
 --       {"_$MOPED_INVERTER", self.Inverter[3].host},
    }

    table.insert(TEMPLATE_PARSER, {"_$POWER_SINKS$",
            string.format("%7.2f", sinks)})

    table.insert(TEMPLATE_PARSER, {"_$POWER_SOURCES$",
            string.format("%7.2f", sources)})

    table.insert(TEMPLATE_PARSER, {"_$POWER_CONSUMED$",
            string.format("%7.2f", P_Grid + sources - sinks)})

    local date = os.date("*t")

    TEMPLATE_PARSER[1][2] = string.format("%d/%d/%d-%02d:%02d:%02d",
        date.year, date.month, date.day, date.hour, date.min, date.sec)

    local template_descriptor = io.open("./index_template.html", "r")
    if not template_descriptor then
        print("Error opening: ", config.html_main)
        return
    end

    local content = template_descriptor:read("*a")
    template_descriptor:close()

    for _, v in pairs(TEMPLATE_PARSER) do
        v[1] = v[1]:sub(1,-2) .. "%$"
        while content:find(v[1]) do
            content = content:gsub(v[1], v[2])
        end
    end

    content = content:gsub("_%$[a-zA-Z0-1_]*%$", "")

    local index_descriptor = io.open(config.html_main, "w")
    if not index_descriptor then
        print("Error opening: ", config.html_main)
        return
    end
    index_descriptor:write(content)
    index_descriptor:close()
end
