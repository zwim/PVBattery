------------------------------------------------------------
-- solarprognose.lua
-- Objektorientierter Zugriff auf solarprognose.de mit persistentem Cache
-- Abhängig von: LuaSocket, dkjson
------------------------------------------------------------

local http   = require("socket.http")
local ltn12  = require("ltn12")
local json   = require("dkjson")

------------------------------------------------------------
-- Prototyp / Basistabelle
------------------------------------------------------------
local Solar = {}
Solar.__index = Solar

local TEST_BODY = [[{"preferredNextApiRequestAt":{"secondOfHour":2927,"epochTimeUtc":1762022927},"status":0,"iLastPredictionGenerationEpochTime":1762020850,"weather_source_text":"Kurzfristig (3 Tage): Powered by <a href=\"https://www.weatherapi.com/\" title=\"Free Weather API\">WeatherAPI.com</a> und Langfristig (10 Tage): Powered by <a href=\"https://www.visualcrossing.com/weather-data\" target=\"_blank\">Visual Crossing Weather</a>","datalinename":"Austria > Kirchbichl","data":{"1762024800":[1762024800,0,0],"1762028400":[1762028400,0,0.0],"1762032000":[1762032000,0.205,0.205],"1762035600":[1762035600,1.298,1.503],"1762039200":[1762039200,2.738,4.241],"1762042800":[1762042800,3.977,8.218],"1762046400":[1762046400,4.898,13.116],"1762050000":[1762050000,5.487,18.603],"1762053600":[1762053600,5.377,23.98],"1762057200":[1762057200,4.436,28.416],"1762060800":[1762060800,2.418,30.834],"1762064400":[1762064400,0,30.834],"1762068000":[1762068000,0,0],"1762071600":[1762071600,0.106,0.106],"1762075200":[1762075200,1.127,1.233],"1762078800":[1762078800,2.286,3.519],"1762082400":[1762082400,2.328,5.847],"1762086000":[1762086000,3.878,9.725],"1762089600":[1762089600,2.174,11.899]}}]]


------------------------------------------------------------
-- Hilfsfunktionen
------------------------------------------------------------
local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

local function write_file(path, content)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(content)
    f:close()
    return true
end

local function http_get(url)
    local response = {}
    local res, code = http.request{
        url = url,
        sink = ltn12.sink.table(response),
        timeout = 10
    }
    if not res then
        return nil, "HTTP Fehler"
    end
    if code ~= 200 then
        return nil, "HTTP Code: " .. tostring(code)
    end
    return table.concat(response), nil
end

------------------------------------------------------------
-- Konstruktor
------------------------------------------------------------
function Solar.new(cfg)
    local self = setmetatable({}, Solar)

    self.config = {
        token     = cfg.token     or "",
        project   = cfg.project   or "",
        item      = cfg.item      or "",
        typ       = cfg.typ       or "hourly",
        id        = cfg.id        or "",
        cachetime = cfg.cachetime or 3600,
        cachefile = cfg.cachefile or "/var/cache/solarprognose.json"
    }

    self.cache = {
        timestamp = 0,
        data = nil,
        error = nil
    }

    self.__name = cfg.__name or ""

    self:_load_cache()

    return self
end

------------------------------------------------------------
-- Cache-Funktionen
------------------------------------------------------------
function Solar:_load_cache()
    local path = self.config.cachefile
    if not file_exists(path) then return end
    local content = read_file(path)
    if not content or #content == 0 then return end

    -- dkjson.decode erwartet den String als erstes Argument.

    local ok, result = pcall(json.decode, content)
    if not ok or not result or not result.data then
        local error_msg = result or "JSON-Struktur ungültig."
        print("JSON decode error:", error_msg)
        self.cache.error = error_msg
        return
    end

    if result.timestamp and result.data then
        self.cache = result
    end
end

function Solar:_save_cache()
    local content = json.encode(self.cache, { indent = false })
    write_file(self.config.cachefile, content)
end

------------------------------------------------------------
-- Datenverarbeitung: Erzeugt Array mit dezimalen Stunden
------------------------------------------------------------

-- Hilfsfunktion zur Ermittlung des Midnight-TimeStamps für den aktuellen Tag
function Solar:_get_midnight_epoch()
    local t_now = os.date("*t", os.time())
    -- Setze Stunde, Minute, Sekunde auf Null (Mitternacht)
    t_now.hour = 0
    t_now.min = 0
    t_now.sec = 0
    return os.time(t_now)
end

local old_clean_timestamp = 0
function Solar:_clean_cache()
    local current_timestamp = os.time()
    if old_clean_timestamp + 3600 < current_timestamp then
        return
    end
    old_clean_timestamp = current_timestamp

    if self.cache.data then
        for t in pairs(self.cache.data) do
            -- Wichtig: Schlüssel (t) in Zahl umwandeln
            if tonumber(t) < current_timestamp then
                -- Entfernen alter (bereits vergangener) Einträge
                self.cache.data[t] = nil
            end
        end
    end
end

function Solar:_process_data()
    if not self.cache.data then
        return {}
    end

    local midnight_epoch = self:_get_midnight_epoch()
    local processed_data = {}

    for t_str, values in pairs(self.cache.data) do
        local t_epoch = tonumber(t_str)

        -- Sicherstellen, dass der Eintrag gültig ist (Timestamp und Array-Struktur)
        if t_epoch and type(values) == 'table' and #values >= 3 then

            -- Berechne die Differenz in Sekunden zur Mitternacht
            local diff_seconds = t_epoch - midnight_epoch

            -- Wandle Sekunden in dezimale Stunden um (3600 Sekunden pro Stunde)
            local hour_decimal = diff_seconds / 3600

            local entry = {
                -- Gewünschte Stundenangabe (z.B. 10.0, 10.5, 11.0)
                hour = hour_decimal,
                -- Leistung für diese Stunde (v[2])
                power_kw = values[2],
                -- Kumulierter Ertrag bis zu dieser Stunde (v[3])
                cumulative_kwh = values[3]
            }
            table.insert(processed_data, entry)
        end
    end

    -- Sortiere das Array nach der dezimalen Stunde
    table.sort(processed_data, function(a, b)
        return a.hour < b.hour
    end)

    return processed_data
end

function Solar:_clean_cache_and_process_data()
    self:_clean_cache()
    return self:_process_data()
end

------------------------------------------------------------
-- Hauptfunktion: fetch()
------------------------------------------------------------
function Solar:fetch()
    local now = os.time()
    local is_cached = false

    -- Cache noch gültig?
    if self.cache.data then
        -- call at least config.cachetime later and not before the next preferred request time
        if (now - self.cache.timestamp) < self.config.cachetime or
            now < self.cache.preferredNextApiRequestAt.epochTimeUtc + self.config.cachetime * 3600 then
            is_cached = true
            -- Rückgabe des *verarbeiteten* Caches
            return self:_clean_cache_and_process_data(), nil, is_cached
        end
    end

    local url = string.format(
        "https://www.solarprognose.de/web/solarprediction/api/v1?access-token=%s&item=module_field&id=%s&type=%s",
        self.config.token, self.config.id, self.config.typ
    )

    print("TRUE FETCH at API URL:", url)

    -- Aktivieren des echten HTTP-Aufrufs und Entfernen des Hardcodes
    local body, err = http_get(url)

    -- Debug-Fallback (Aktivieren Sie nur eine der beiden Zeilen)
    -- local body, err =  TEST_BODY, nil

    if not body then
        self.cache.error = err or "Unbekannter Fehler beim Abruf."
        -- Rückgabe des *verarbeiteten* alten Caches oder leeres Array bei Fehler
        print("postpone next fetch")
        self.cache.timestamp = now
        return self:_clean_cache_and_process_data(), err, is_cached
    end

    -- Safe JSON decode
    local ok, result = pcall(json.decode, body)
    if not ok or not result or not result.data then
        local error_msg = result or "JSON-Struktur ungültig."
        print("JSON decode error:", error_msg)
        self.cache.error = error_msg
        self:_save_cache()
        -- Rückgabe des *verarbeiteten* alten Caches
        return self:_process_data(), error_msg, is_cached
    end

    -- Cache aktualisieren
    self.cache = result
    self.cache.timestamp = now
    self.cache.error = nil

    self:_save_cache()

    -- Rückgabe des *verarbeiteten* neuen Datensatzes
    return self:_clean_cache_and_process_data(), nil, false
end

-- no forecast, returns math.huge
function Solar:get_remaining_daily_forecast_yield()
    local data_array = self:_process_data()

    if #data_array == 0 then
        print("Fehler: Keine gültigen Daten.")
        if self.cache.error then print("Letzter Fehler:", self.cache.error) end

        return math.huge
    end

    local current_hour = tonumber(os.date("%H"))
    local remaining_forecast_yield = 0
    for _, entry in ipairs(data_array) do
        if entry.hour > current_hour then
            remaining_forecast_yield = remaining_forecast_yield + entry.power_kw
        end
        if entry.hour >= 24.00 then
            break
        end
    end
    return remaining_forecast_yield
end

------------------------------------------------------------
-- Debug-Funktion (nutzt die verarbeiteten Daten)
------------------------------------------------------------
function Solar:print_latest()
    local data_array = self:_process_data()
    local source_status = (self.cache.timestamp > 0 and (os.time() - self.cache.timestamp) < self.config.cachetime) and "(Cache)" or "(Neu)"

    if #data_array == 0 then
        print("Fehler: Keine gültigen Daten.")
        if self.cache.error then print("Letzter Fehler:", self.cache.error) end
        return
    end

    print(source_status, self.config.item, " (Ort: " .. (self.cache.datalinename or "Unbekannt") .. ")")
    local timestamp = self.cache.preferredNextApiRequestAt.epochTimeUtc
    local preferred_sec = self.cache.preferredNextApiRequestAt.secondOfHour
    print("Nächster fetch um " .. os.date("%Y-%m-%d %H:%M:%S", timestamp))
    print("Gewünschte Zeitpunkt des Refreshs " .. math.floor(preferred_sec/60) .. ":" .. math.floor(preferred_sec%60))
    print(string.format("Startzeitpunkt für Stundenberechnung: %s", os.date("%Y-%m-%d 00:00:00", self:_get_midnight_epoch())))
    print("----------------------------------------")

    for _, entry in ipairs(data_array) do
        -- Umrechnung der dezimalen Stunde zurück in eine lesbare UTC-Zeit für die Ausgabe (optional)
        local total_seconds = entry.hour * 3600
        local t_epoch = self:_get_midnight_epoch() + total_seconds
        local timeStamp_utc = os.date("%Y-%m-%d %H:%M:%S", t_epoch)

        print(string.format("Stunde %.2f (UTC: %s) -> %.3f kW, Kumulativ: %.3f kWh",
            entry.hour,
            timeStamp_utc,
            entry.power_kw,
            entry.cumulative_kwh
        ))
    end
    print("----------------------------------------")
end

------------------------------------------------------------

local function example()

    local wr1 = Solar.new{
        __name = "roof",
        token = "c2a2da7b09c3c2e2a20651a2223e7fa7",
        project = "7052",
        item = "module_filed",
        id = "14336",
        typ = "hourly",
        cachefile = "/tmp/wr1.json",
   		cachetime = 3, -- in hours
    }

    local wr2 = Solar.new{
        __name = "balkon",
        token = "c2a2da7b09c3c2e2a20651a2223e7fa7",
        project = "7052",
        item = "module_field",
        id = "14337",
        typ = "hourly",
        cachefile = "/tmp/wr2.json",
   		cachetime = 3, -- in hours
    }

    print("Starte Abruf für WR1 (Dach)...")
    -- d1 ist jetzt das Array von Objekten
    local d1, err1, cached1 = wr1:fetch()
    if d1 and #d1 > 0 then
        wr1:print_latest()
        -- Beispielzugriff auf das erste Element des Array:
        -- print(string.format("Erster Eintrag (Stunde %.2f): %.3f kW", d1[1].hour, d1[1].power_kw))
        print("Erwarteter heutiger ertrag:", wr1:get_remaining_daily_forecast_yield(), "kWh")
    else
        print("Fehler beim Abruf WR1:", err1, "kWh")
    end

    print("Starte Abruf für WR2 (Balkon)...")
    -- d1 ist jetzt das Array von Objekten
    local d2, err2, cached2 = wr2:fetch()
    if d2 and #d2 > 0 then
        wr2:print_latest()
        -- Beispielzugriff auf das erste Element des Array:
        -- print(string.format("Erster Eintrag (Stunde %.2f): %.3f kW", d1[1].hour, d1[1].power_kw))
        print("Erwarteter heutiger ertrag:", wr2:get_remaining_daily_forecast_yield(), "kWh")
    else
        print("Fehler beim Abruf WR2:", err2, "kWh")
    end
end

if arg[0]:find("solarprognose.lua") then
    example()
end

return Solar
