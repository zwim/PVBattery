return function(self, config, P_Grid, P_Load, P_PV)
    local TEMPLATE_PARSER = {
        {"_$DATE", ""},
        {"_$SUNRISE", self.sunrise},
        {"_$SUNSET", self.sunset},
        {"_$FRONIUS_ADR", config.FRONIUS_ADR},
        {"_$STATE_OF_OPERATION", self:getState()},
        {"_$P_GRID", string.format("%7.2f", P_Grid)},
        {"_$P_SELL_GRID", P_Grid < 0 and string.format("%7.2f", P_Grid) or "0.00"},
        {"_$P_BUY_GRID", P_Grid > 0 and string.format("%7.2f", P_Grid) or "0.00"},
        {"_$P_LOAD", string.format("%7.2f", P_Load)},
        {"_$P_ROOF", string.format("%7.2f", P_PV)},
        {"_$BMS1_INFO", "http://" .. self.BMS[1].host .. "/show"},
        {"_$BMS1_BALANCE", "http://" .. self.BMS[1].host .. "/balance.toggle"},

        {"_$BATTERY_CHARGER1_POWER",
            string.format("%7.2f", self.Charger[1]:getCurrentPower())},
        {"_$BATTERY_CHARGER1", self.Charger[1].switch_host},
        {"_$BATTERY_CHARGER2_POWER",
            string.format("%7.2f", self.Charger[2]:getCurrentPower())},
        {"_$BATTERY_CHARGER2", self.Charger[2].switch_host},
        {"_$BATTERY_INVERTER_POWER",
            string.format("%7.2f", self.Inverter[1]:getCurrentPower())},
        {"_$BATTERY_INVERTER", self.Inverter[1].host},
        {"_$GARAGE_INVERTER_POWER",
            string.format("%7.2f", self.Inverter[2]:getCurrentPower())},
        {"_$GARAGE_INVERTER", self.Inverter[2].host},
        {"_$MOPED_CHARGER_POWER",
            string.format("%7.2f", self.Charger[3]:getCurrentPower())},
        {"_$MOPED_CHARGER", self.Charger[3].switch_host},
        {"_$MOPED_INVERTER_POWER",
            string.format("%7.2f", self.Inverter[3]:getCurrentPower())},
        {"_$MOPED_INVERTER", self.Inverter[3].host},
    }

    local sinks = 0
    for _,chg in pairs(self.Charger) do
        local x = chg:getCurrentPower()
        sinks = sinks + (x or 0)
    end
    table.insert(TEMPLATE_PARSER, {"_$POWER_SINKS",
            string.format("%7.2f", sinks)})

    local sources = P_PV
    for _,inv in pairs(self.Inverter) do
        local x = inv:getCurrentPower()
        sources = sources + (x or 0)
    end
    table.insert(TEMPLATE_PARSER, {"_$POWER_SOURCES",
            string.format("%7.2f", sources)})

    table.insert(TEMPLATE_PARSER, {"_$POWER_CONSUMED",
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
        while content:find(v[1]) do
            content = content:gsub(v[1], v[2])
        end
    end

    local index_descriptor = io.open(config.html_main, "w")
    if not index_descriptor then
        print("Error opening: ", config.html_main)
        return
    end
    index_descriptor:write(content)
    index_descriptor:close()
end

