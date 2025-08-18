return function(self, config, VERSION)
    local ChargerPowerCache = {}
    local InverterPowerCache = {}

    local sinks = 0
    for i = 1, #self.Charger do
        ChargerPowerCache[i] = self.Charger[i]:getPower()
        sinks = sinks + (ChargerPowerCache[i] or 0)
    end
    sinks = sinks + math.max(-self.P_VenusE, 0)

    local sources = self.P_PV or 0
    for  i = 1, #self.Inverter do
        InverterPowerCache[i] = self.Inverter[i]:getPower()
        sources = sources + (InverterPowerCache[i] or 0)
    end
    sources = sources + math.max(self.P_VenusE, 0)

    local SOC_string = "<br>SOC:"
    for  i = 1, #self.BMS do
        if self.BMS[i].v.SOC then
            SOC_string = SOC_string .. " " .. self.BMS[i].host .. " " .. self.BMS[i].v.SOC .. "%% "
            SOC_string = SOC_string .. os.date("%c", math.floor(self.BMS[i].timeOfLastFullBalancing)) .. "<br>"
        end
    end
    if self.VenusE_SOC then
        SOC_string = SOC_string .. "SOC: Marstek VenusE " .. self.VenusE_SOC .. "%%<br>"
    end

    local TEMPLATE_PARSER = {
        {"_$Vx.y.z$", VERSION or "Vx.y.z"},
        {"_$DATE$", os.date()},
        {"_$SUNRISE$", self.sunrise},
        {"_$SUNSET$", self.sunset},
        {"_$FRONIUS_ADR$", config.FRONIUS_ADR},
        {"_$STATE_OF_OPERATION$", (self._state or "") .. SOC_string},
        {"_$P_GRID$", string.format("%5.0f", self.P_Grid or 0)},
        {"_$P_SELL_GRID$", self.P_Grid < 0 and string.format("%5.0f", -self.P_Grid) or "0"},
        {"_$P_BUY_GRID$", self.P_Grid > 0 and string.format("%5.0f", self.P_Grid) or "0"},
        {"_$P_LOAD$", string.format("%5.0f", self.P_Load)},
        {"_$P_ROOF$", string.format("%5.0f", self.P_PV)},
        {"_$BMS1_INFO$", "http://" .. self.BMS[1].host .. "/show"},
        {"_$BMS1_BALANCE_OFF$", "http://" .. self.BMS[1].host .. "/balance.off"},
        {"_$BMS1_BALANCE_ON$", "http://" .. self.BMS[1].host .. "/balance.on"},
        {"_$BMS1_BALANCE_TOGGLE$", "http://" .. self.BMS[1].host .. "/balance.toggle"},

        {"_$BATTERY_CHARGER1_POWER$",
            string.format("%5.0f", ChargerPowerCache[1])},
        {"_$BATTERY_CHARGER1$", self.Charger[1].host},
        {"_$BATTERY_CHARGER2_POWER$",
            string.format("%5.0f", ChargerPowerCache[2])},
        {"_$BATTERY_CHARGER2$", self.Charger[2].host},
       {"_$BATTERY_CHARGER3_POWER$",
            string.format("%5.0f", ChargerPowerCache[3] or 0)},
--        {"_$BATTERY_CHARGER3$", self.Charger[3].host},
        {"_$BATTERY_INVERTER_POWER$",
            string.format("%5.0f", InverterPowerCache[1])},
        {"_$BATTERY_INVERTER$", self.Inverter[1].host},
        {"_$GARAGE_INVERTER_POWER$",
            string.format("%5.0f", InverterPowerCache[2])},
        {"_$GARAGE_INVERTER$", self.Inverter[2].host},
        {"_$VENUS_CHARGE_POWER$",
            string.format("%5.0f", math.max(-self.P_VenusE, 0))},
        {"_$VENUS_DISCHARGE_POWER$",
            string.format("%5.0f", math.max(self.P_VenusE, 0))},
 --       {"_$MOPED_CHARGER_POWER",
 --           string.format("%7.2f", ChargerPowerCache[3])},
 --       {"_$MOPED_CHARGER", self.Charger[3].switch_host},
 --       {"_$MOPED_INVERTER_POWER",
 --           string.format("%7.2f", InverterPowerCache[3])},
 --       {"_$MOPED_INVERTER", self.Inverter[3].host},
    }

    table.insert(TEMPLATE_PARSER, {"_$POWER_SINKS$",
            string.format("%5.0f", sinks)})

    table.insert(TEMPLATE_PARSER, {"_$POWER_SOURCES$",
            string.format("%5.0f", sources)})

    table.insert(TEMPLATE_PARSER, {"_$POWER_CONSUMED$",
            string.format("%5.0f", self.P_Grid + sources - sinks)})

--    local date = os.date("*t")
--    TEMPLATE_PARSER[1][2] = string.format("%d/%d/%d-%02d:%02d:%02d",
--        date.year, date.month, date.day, date.hour, date.min, date.sec)

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
