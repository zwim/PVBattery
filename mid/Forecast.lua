------------------------------------------------------------
-- Basisklasse für Solarprognosen (solarprognose.de + forecast.solar)
-- Vereinheitlicht: Cache, HTTP, JSON, Zeitstempel, Verarbeitung
------------------------------------------------------------

local http   = require("socket.http")
local ltn12  = require("ltn12")
local json   = require("dkjson")
local util   = require("base/util")

local Forecast = {
    __name = "Forecast",
    -- ###############################################################
    -- CONFIGURATION
    -- ###############################################################
    --levels: 0 = silent, 1 = info, 2 = debug, 3 = verbose, 4 = chatty
    __loglevel = 3,
    __log_signature = { "ERR", "INF", "DBG", "VERB", "CHAT" }
}

function Forecast:extend(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function Forecast:new(o)
    o = self:extend(o)
    if o.init then o:init() end
    return o
end

function Forecast:init()
    self.config = self.config or {}
    self.cache = {timestamp=0, data=nil, error=nil}

    if not self.config.cachetime  and self.config.planes then
        local t1 = self.config.planes[1] and self.config.planes[1].cachetime or 1800
        local t2 = self.config.planes[2] and self.config.planes[2].cachetime or 1800
        self.config.cachetime = math.min(t1, t2)
    end


    self:_load_cache()
    self:fetch()

    return self
end

function Forecast:log(level, ...)
    local loglevel = self.__loglevel or 3
    if config and config.loglevel then
        loglevel = math.min(loglevel, config.loglevel)
    end
    if level <= loglevel then
        print(os.date("%Y/%m/%d-%H:%M:%S "
                .. (self.__log_signature[level] or "" )
                .. " ["
                .. (getmetatable(self).__name or "???").."]"), ...)
    end
end

function Forecast:setLogLevel(new_level)
    if     new_level < 0 then new_level = 0
    elseif new_level > #Forecast.__log_signature then new_level = #Forecast.__log_signature
    end
    self.__logleve = new_level
end

------------------------------------------------------------
-- HTTP Wrapper
------------------------------------------------------------
function Forecast:http_get(url)
    local response = {}
    local res, code = http.request{
        url = url,
        sink = ltn12.sink.table(response),
        timeout = 10
    }
    if not res then
        return nil, "HTTP Transportfehler"
    end
    local body = table.concat(response)
    if code ~= 200 then
        return nil, "HTTP Code " .. code .. ": " .. body
    end
    return body, nil
end

------------------------------------------------------------
-- Cache laden/speichern
------------------------------------------------------------
function Forecast:_load_cache()
    local f = util.read_file(self.config.cachefile)
    if not f then return end

    local r = util.safe_json_decode(f)
    if r and r.data then
        self.cache = r
    end
end

function Forecast:_save_cache()
    local out = json.encode(self.cache, {indent = false})
    util.write_file(self.config.cachefile, out)
end

------------------------------------------------------------
-- Standard-Zeitverarbeitung für ALLE Quellen
------------------------------------------------------------
function Forecast:_process_data(data)
    data = data or self.cache.data

    local result = {}
    for t_local, v in pairs(data or {}) do
        local y,M,d,h,m,s = t_local:match("(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)")
        local hour = tonumber(h) + tonumber(m)/60 + tonumber(s)/3600

        result[#result+1] = {
            hour = hour,
            power_kw = v.power_kw,
            cumulative_kwh = v.cumulative_kwh,
            local_timestamp = t_local
        }
    end

    table.sort(result, function(a,b) return a.hour < b.hour end)
    return result
end

------------------------------------------------------------
-- Rest des täglichen Ertrags
------------------------------------------------------------
function Forecast:get_remaining_daily_forecast_yield(current_hour)
    if not self.cache or not self.cache.data then
        return math.huge
    end

    current_hour = current_hour or tonumber(os.date("%H"))
    local sum = 0
    for _,e in ipairs(self.cache.data) do
        if e.hour > current_hour and e.hour < 24 then
            sum = sum + e.power_kw
        end
        if e.hour >= 24 then
            break
        end
    end
    return sum
end

function Forecast:fetch(now)
    now = now or os.time()

    if now - self.cache.timestamp < self.config.cachetime then
        return
    end

    local plane_forecast = {}
    for i, plane in ipairs(self.config.planes) do
        local url = self:generateURL(plane)
        local body, err = self:http_get(url)

-- Example-Body for SolarPrognose; for testing
--        local body = "{\"preferredNextApiRequestAt\":{\"secondOfHour\":2927,\"epochTimeUtc\":1763279327},\"status\":0,\"iLastPredictionGenerationEpochTime\":1763276270,\"weather_source_text\":\"Kurzfristig (3 Tage): Powered by <a href=\\\"https://www.weatherapi.com/\\\" title=\\\"Free Weather API\\\">WeatherAPI.com</a> und Langfristig (10 Tage): Powered by <a href=\\\"https://www.visualcrossing.com/weather-data\\\" target=\\\"_blank\\\">Visual Crossing Weather</a>\",\"datalinename\":\"roof\",\"data\":{\"1763269200\":[1763269200,0,0],\"1763272800\":[1763272800,0.061,0.061],\"1763276400\":[1763276400,0.996,1.057],\"1763280000\":[1763280000,2.3,3.357],\"1763283600\":[1763283600,3.251,6.608],\"1763287200\":[1763287200,3.524,10.132],\"1763290800\":[1763290800,3.09,13.222],\"1763294400\":[1763294400,2.937,16.159],\"1763298000\":[1763298000,2.413,18.572],\"1763301600\":[1763301600,0.634,19.206],\"1763305200\":[1763305200,0,19.206],\"1763359200\":[1763359200,0,0],\"1763362800\":[1763362800,0.24,0.24],\"1763366400\":[1763366400,0.578,0.818],\"1763370000\":[1763370000,0.803,1.621],\"1763373600\":[1763373600,0.975,2.596],\"1763377200\":[1763377200,1.035,3.631],\"1763380800\":[1763380800,0.975,4.606],\"1763384400\":[1763384400,0.855,5.461],\"1763388000\":[1763388000,0.608,6.069],\"1763391600\":[1763391600,0,6.069]}}"

-- Example-Body for ForecastSolar; for testing
--        local body = "{\"result\":{\"watts\":{\"2025-11-16 07:18:18\":0,\"2025-11-16 08:00:00\":303,\"2025-11-16 09:00:00\":641,\"2025-11-16 10:00:00\":778,\"2025-11-16 11:00:00\":818,\"2025-11-16 12:00:00\":775,\"2025-11-16 13:00:00\":673,\"2025-11-16 14:00:00\":512,\"2025-11-16 15:00:00\":301,\"2025-11-16 16:00:00\":108,\"2025-11-16 16:34:36\":0,\"2025-11-17 07:19:45\":0,\"2025-11-17 08:00:00\":265,\"2025-11-17 09:00:00\":555,\"2025-11-17 10:00:00\":725,\"2025-11-17 11:00:00\":797,\"2025-11-17 12:00:00\":783,\"2025-11-17 13:00:00\":690,\"2025-11-17 14:00:00\":526,\"2025-11-17 15:00:00\":308,\"2025-11-17 16:00:00\":154,\"2025-11-17 16:33:32\":0},\"watt_hours_period\":{\"2025-11-16 07:18:18\":0,\"2025-11-16 08:00:00\":105,\"2025-11-16 09:00:00\":472,\"2025-11-16 10:00:00\":710,\"2025-11-16 11:00:00\":798,\"2025-11-16 12:00:00\":797,\"2025-11-16 13:00:00\":724,\"2025-11-16 14:00:00\":593,\"2025-11-16 15:00:00\":407,\"2025-11-16 16:00:00\":205,\"2025-11-16 16:34:36\":31,\"2025-11-17 07:19:45\":0,\"2025-11-17 08:00:00\":89,\"2025-11-17 09:00:00\":410,\"2025-11-17 10:00:00\":640,\"2025-11-17 11:00:00\":761,\"2025-11-17 12:00:00\":790,\"2025-11-17 13:00:00\":737,\"2025-11-17 14:00:00\":608,\"2025-11-17 15:00:00\":417,\"2025-11-17 16:00:00\":231,\"2025-11-17 16:33:32\":43},\"watt_hours\":{\"2025-11-16 07:18:18\":0,\"2025-11-16 08:00:00\":105,\"2025-11-16 09:00:00\":577,\"2025-11-16 10:00:00\":1287,\"2025-11-16 11:00:00\":2085,\"2025-11-16 12:00:00\":2882,\"2025-11-16 13:00:00\":3606,\"2025-11-16 14:00:00\":4199,\"2025-11-16 15:00:00\":4606,\"2025-11-16 16:00:00\":4811,\"2025-11-16 16:34:36\":4842,\"2025-11-17 07:19:45\":0,\"2025-11-17 08:00:00\":89,\"2025-11-17 09:00:00\":499,\"2025-11-17 10:00:00\":1139,\"2025-11-17 11:00:00\":1900,\"2025-11-17 12:00:00\":2690,\"2025-11-17 13:00:00\":3427,\"2025-11-17 14:00:00\":4035,\"2025-11-17 15:00:00\":4452,\"2025-11-17 16:00:00\":4683,\"2025-11-17 16:33:32\":4726},\"watt_hours_day\":{\"2025-11-16\":4842,\"2025-11-17\":4726}},\"message\":{\"code\":0,\"type\":\"success\",\"text\":\"\",\"pid\":\"979OrS5A\",\"info\":{\"latitude\":47.5112,\"longitude\":12.0859,\"distance\":0.04,\"place\":\"Tirolerstraße 25, 6322 Kirchbichl, Austria\",\"timezone\":\"Europe/Vienna\",\"time\":\"2025-11-16T09:19:19+01:00\",\"time_utc\":\"2025-11-16T08:19:19+00:00\"},\"ratelimit\":{\"zone\":\"IP 213.142.97.191\",\"period\":3600,\"limit\":12,\"remaining\":1}}}"

        if not body then return err end

        local raw = util.safe_json_decode(body)
        if not raw then
            return nil, "Invalid API data"
        end
        local data, e = self:normalize_data(raw)
        if not e then
            data = self:_process_data(data)
            table.insert(plane_forecast, data)
        end
        err = err or e
    end

    local data = util.merge_sort(plane_forecast[1], plane_forecast[2])

    for i = #data, 2, -1 do
        if data[i].hour == data[i-1].hour then
            data[i-1].power_kw = data[i-1].power_kw + data[i].power_kw
            table.remove(data, i)
        end
    end

    self.cache.data = data
    self.cache.error = nil
    self.cache.timestamp = now
    self:_save_cache()
end


------------------------------------------------------------
-- Debug
------------------------------------------------------------
function Forecast:print_latest()
    for _,e in ipairs(self.cache.data) do
        print(string.format("Stunde %.2f -> %.3f kW, kum %.3f",
            e.hour, e.power_kw, e.cumulative_kwh))
    end
end

return Forecast
