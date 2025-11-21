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
    self.cachetime = self.cachetime or 3600

    self:_load_cache()
    self:fetch()
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
    local content = util.read_file(self.config.cachefile)
    if not content then return end

    local r = util.safe_json_decode(content)
    if r and r.data then
        self.cache = r
    else
        self.cache = {}
        self.cache.timestamp = 0
    end
end

function Forecast:_save_cache()
    local out = json.encode(self.cache, {indent = false})
    util.write_file(self.config.cachefile, out)
end

------------------------------------------------------------
-- Standard-Zeitverarbeitung für ALLE Quellen
------------------------------------------------------------
function Forecast:_process_data(data, kwp)
    data = data or self.cache.data

    -- these values are strings
    local current_day = os.date("%d")
    local current_month = os.date("%m")
    local current_year = os.date("%Y")

    local result = {}
    for t_local, v in pairs(data or {}) do
        local y, m, d, H, M, S = t_local:match("(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)")

        -- use only data of the current day
        if d == current_day and m == current_month and y == current_year then
            local hour = tonumber(H) + tonumber(M)/60 + tonumber(S)/3600

            result[#result+1] = {
                hour = hour,
                power_kw = math.min(v.power_kw, kwp),
                local_timestamp = t_local
            }
        end
    end

    -- sort result on the timestamp aka hour
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
    local current_minute = tonumber(os.date("%M"))
    local current_second = tonumber(os.date("%M"))
    current_hour = current_hour + current_minute/60 + current_second/3600

    local sum = 0

    for i = 1, #self.cache.data-1 do
        local h = self.cache.data[i].hour
        if  h > current_hour - 1 and h < 24 then
            if  h < current_hour then
                sum = sum + self.cache.data[i].power_kw * (current_hour - h) / (self.cache.data[i+1].hour - h)
            else
                sum = sum + self.cache.data[i].power_kw
            end
        end
        if h >= 24 then
            break
        end
    end
    return sum
end

function Forecast:shouldFetch(now)
    now = now or os.time()
    return now - self.cache.timestamp > self.config.cachetime
end

--luacheck: ignore raw
function Forecast:calculateNextFetchTime(raw)
    -- do nothing here, but maybe somwhere else
    return
end

function Forecast:fetch(now)
    now = now or os.time()

    if not self:shouldFetch(now) then
        return true
    end

    -- try at earliest in self.config.cachetime again, no matter if it fails
    self.cache.timestamp = now
    self:_save_cache()

    local plane_forecast = {}
    for _, plane in ipairs(self.config.planes) do
        local url = self:generateURL(plane)
        local body, err = self:http_get(url)

        if not body then
            return nil, err
        end

        local raw = util.safe_json_decode(body)
        if not raw then
            return nil, "Invalid API data"
        end
        self:calculateNextFetchTime(raw, now)

        local data, e = self:normalize_data(raw)
        if not e then
            data = self:_process_data(data, plane.kwp) -- and limit to the maximum kwp
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
    return true
end

------------------------------------------------------------
-- Debug
------------------------------------------------------------
function Forecast:print_latest()
    if not self.cache.data then return end
    local cumulative_kwh = 0
    for _,e in ipairs(self.cache.data) do
        cumulative_kwh = cumulative_kwh + e.power_kw
        print(string.format("Stunde %.2f -> %.3f kW, kum %.3f",
            e.hour, e.power_kw, cumulative_kwh))
    end
end

return Forecast
