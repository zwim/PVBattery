-- ==============================================================
-- forecast_solar_aggregator.lua
-- Aggregiert die stündliche PV-Prognose (kWh) von forecast.solar
-- für mehrere Flächen (Planes) und konvertiert Zeitstempel in
-- die LOKALE ZEITZONE der Maschine.
-- Abhängig von: LuaSocket, dkjson
-- ==============================================================

local http   = require("socket.http")
local ltn12  = require("ltn12")
local json   = require("dkjson")

------------------------------------------------------------
-- Prototyp / Basistabelle (Hauptklasse für die Aggregation)
------------------------------------------------------------
local ForecastSolarAggregator = {}
ForecastSolarAggregator.__index = ForecastSolarAggregator

-- Basis-URL der forecast.solar Public API (kostenlos)
local BASE_URL = "https://api.forecast.solar/estimate/"

------------------------------------------------------------
-- Hilfsfunktionen
------------------------------------------------------------

-- Wiederverwendete HTTP GET Funktion
local function http_get(url)
    local response = {}
    local response_headers = {}

    local res, code = http.request{
        url = url,
        sink = ltn12.sink.table(response),
        headers = response_headers,
        timeout = 10
    }

    local body = table.concat(response)

    if not res then
        return nil, "HTTP Transport-Fehler"
    end

    if code ~= 200 then
        -- forecast.solar nutzt den Body für Fehlermeldungen (z.B. bei Rate-Limit)
        return nil, "HTTP Code: " .. tostring(code) .. " Body: " .. body
    end

    return body, nil
end

-- Hilfsfunktion für Cache (aus deiner Vorlage)
local function write_file(path, content)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(content)
    f:close()
    return true
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

-- NEUE HILFSFUNKTION: Konvertiert UTC-String zu lokalem Zeit-String
function ForecastSolarAggregator:_utc_to_local_string(utc_str)
    -- Muster: "YYYY-MM-DD HH:MM:SS"
    local year, month, day, hour, min, sec = utc_str:match("(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)")

    if not year then return nil end

    -- 1. Erstelle eine UTC-Zeittabelle
    local utc_table = {
        year = tonumber(year),
        month = tonumber(month),
        day = tonumber(day),
        hour = tonumber(hour),
        min = tonumber(min),
        sec = tonumber(sec)
    }

    -- 2. Konvertiere UTC-Tabelle in UTC-Epoch-Zeitstempel
    -- Das '!' in os.time erzeugt den Epoch-Wert basierend auf der Annahme,
    -- dass die Tabelle eine UTC-Zeit repräsentiert.
    local utc_epoch = os.time(utc_table)

    -- 3. Formatiere den UTC-Epoch-Zeitstempel in die lokale Zeit des Systems.
    -- Wenn das Format-String kein '!' enthält, verwendet os.date die lokale Zeitzone (CET/CEST).
    local local_str = os.date("%Y-%m-%d %H:%M:%S", utc_epoch)

    return local_str, utc_epoch
end

------------------------------------------------------------
-- Konstruktor
------------------------------------------------------------

-- Konfiguriere die Flächen, die abgefragt werden sollen
function ForecastSolarAggregator.new(cfg)
    local self = setmetatable({}, ForecastSolarAggregator)

    -- 'planes' ist eine Tabelle von Flächen-Definitionen
    self.planes = cfg.planes or {}

    -- Cache-Einstellungen
    self.config = {
        cachetime = cfg.cachetime or 3600, -- 1 Stunde Cache
        cachefile = cfg.cachefile or "/var/cache/forecast_solar_agg.json"
    }

    -- Cache-Struktur: Speichert die aggregierten Ergebnisse
    -- Die Schlüssel von hourly_kwh sind jetzt LOKALE ZEIT-STRINGS
    self.cache = {
        timestamp = 0,
        hourly_kwh = nil, -- Speichert die summierten { local_timestamp: kwh }
        error = nil
    }

    self:_load_cache()

    return self
end

------------------------------------------------------------
-- Cache-Funktionen (vereinfacht)
------------------------------------------------------------

function ForecastSolarAggregator:_load_cache()
    local content = read_file(self.config.cachefile)
    if not content or #content == 0 then return end

    local ok, result = pcall(json.decode, content)
    if ok and result and result.hourly_kwh then
        self.cache = result
    end
end

function ForecastSolarAggregator:_save_cache()
    local content = json.encode(self.cache, { indent = false })
    write_file(self.config.cachefile, content)
end


------------------------------------------------------------
-- Hauptlogik: Abruf & Aggregation
------------------------------------------------------------

function ForecastSolarAggregator:fetch()
    local now = os.time()
    local is_cached = false

    -- 1. Cache-Prüfung (Einfache Zeitprüfung)
    if self.cache.hourly_kwh and (now - self.cache.timestamp) < self.config.cachetime then
        is_cached = true
        -- WICHTIG: Rückgabe der LOKAL-KEY-Aggregation
        return self.cache.hourly_kwh, nil, is_cached
    end

    print("TRUE FETCH: Starte Abruf und Aggregation von " .. #self.planes .. " Flächen.")

    local total_hourly_kwh = {} -- { local_timestamp_string: kwh_value }
    local last_error = nil

    -- 2. Iteriere über alle Flächen und frage sie einzeln ab (Aggregate-Logik)
    for i, plane in ipairs(self.planes) do
        local url = string.format("%s%f/%f/%d/%d/%f",
            BASE_URL,
            plane.latitude,
            plane.longitude,
            plane.declination,
            plane.azimuth,
            plane.kwp
        )

        local body, err = http_get(url)

        if err then
            print("Fehler bei Fläche " .. i .. ": " .. err)
            last_error = err
            -- Im Fehlerfall alte Daten zurückgeben, falls vorhanden
            self.cache.timestamp = now
            self.cache.error = err
            self:_save_cache()
            return self.cache.hourly_kwh, err, false
        end

        local ok, data = pcall(json.decode, body)
        if not ok or not data or not data.result or not data.result.watts then
            last_error = "JSON-Datenstruktur ungültig für Fläche " .. i
            print("Fehler: " .. last_error)
            self.cache.timestamp = now
            self.cache.error = last_error
            self:_save_cache()
            return self.cache.hourly_kwh, last_error, false
        end

        -- Aggregation der stündlichen Watt-Werte
        for utc_timestamp, watts in pairs(data.result.watts) do

            -- NEUE LOGIK: Konvertiere den UTC-String in den lokalen Zeit-String
            local local_timestamp = self:_utc_to_local_string(utc_timestamp)

            if local_timestamp then
                -- Umrechnung: Watt (W) zu Kilowattstunden (kWh)
                local kwh = watts / 1000
                -- Speichere unter dem LOKALEN Zeitstempel
                total_hourly_kwh[local_timestamp] = (total_hourly_kwh[local_timestamp] or 0) + kwh
            end
        end
    end

    -- 3. Cache aktualisieren und speichern
    self.cache.hourly_kwh = total_hourly_kwh
    self.cache.timestamp = now
    self.cache.error = nil
    self:_save_cache()

    return total_hourly_kwh, nil, false
end

-- Gibt die verarbeiteten Daten zurück (die Aggregationstabelle)
function ForecastSolarAggregator:get_hourly_forecast()
    local hourly_kwh_table = self.cache.hourly_kwh or {}
    local sorted_kwh = {}

    -- Konvertierung der Tabelle in ein Array für die Sortierung
    for ts, kwh in pairs(hourly_kwh_table) do
        table.insert(sorted_kwh, { timestamp = ts, kwh = kwh })
    end

    -- Sortiere nach dem lokalen Zeitstempel-String (der jetzt der Schlüssel ist)
    table.sort(sorted_kwh, function(a, b)
        return a.timestamp < b.timestamp
    end)

    return sorted_kwh
end


-- Hilfsfunktion für die Berechnung des restlichen Ertrags
function ForecastSolarAggregator:get_remaining_daily_forecast_yield()
    local now_epoch = os.time()

    -- Der Tag wird jetzt basierend auf der LOKALEN Zeit bestimmt
    local today_date_local = os.date("%Y-%m-%d", now_epoch)
    local remaining_kwh = 0

    local hourly_kwh_table = self.cache.hourly_kwh or {}

    if #hourly_kwh_table == 0 then
        print("[Forecastsolar] Fehler: Keine gültigen Daten.")
        return math.huge
    end

    for local_timestamp_str, kwh in pairs(hourly_kwh_table) do
        -- 1. Prüfe, ob der Eintrag von heute ist (lokal vs. lokal)
        if local_timestamp_str:sub(1, 10) == today_date_local then

            -- 2. Konvertiere den lokalen Zeitstempel-String in Epoch
            -- Hier nutzen wir die String-zu-Epoch-Umwandlung, da der Schlüssel jetzt LOKAL ist.
            local year, month, day, hour, min, sec = local_timestamp_str:match("(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)")

            -- Erstelle eine Zeittabelle (Lokale Zeit)
            local ts_table_local = {
                year = tonumber(year),
                month = tonumber(month),
                day = tonumber(day),
                hour = tonumber(hour),
                min = tonumber(min),
                sec = tonumber(sec)
            }
            -- os.time() konvertiert die LOKALE Zeittabelle in eine Epoch-Zahl
            local ts_epoch = os.time(ts_table_local)

            -- 3. Prüfe, ob die Stunde begonnen hat.
            if ts_epoch and ts_epoch >= now_epoch then
                 remaining_kwh = remaining_kwh + kwh
            end
        end
    end

    return remaining_kwh > 0 and remaining_kwh or 0
end

------------------------------------------------------------
-- Debug-Funktion
------------------------------------------------------------
function ForecastSolarAggregator:print_latest()
    local data_array = self:get_hourly_forecast()
    local now = os.time()
    local is_cached = (self.cache.timestamp > 0 and (now - self.cache.timestamp) < self.config.cachetime)
    local source_status = is_cached and "(Cache)" or "(Neu)"

    if #data_array == 0 then
        print("Fehler: Keine gültigen Daten.")
        if self.cache.error then print("Letzter Fehler:", self.cache.error) end
        return
    end

    print("\n--- Aggregierter Forecast.Solar Ertrag ---")
    print(string.format("Status: %s. Zuletzt aktualisiert (Lokal): %s", source_status, os.date("%Y-%m-%d %H:%M:%S", self.cache.timestamp)))
    print("----------------------------------------")

    for _, entry in ipairs(data_array) do
        -- Der Schlüssel entry.timestamp ist jetzt der LOKALE Zeitstempel-String
        print(string.format("%s (Lokal): %.3f kWh (Aggregiert)", entry.timestamp, entry.kwh))
    end
    print("----------------------------------------")
end

------------------------------------------------------------
-- Beispielverwendung
------------------------------------------------------------

local function example()
    -- Annahme: Dein Standort (Kirchbichl)
    local LAT = 47.5758 -- Beispiel Breitengrad
    local LON = 12.1153 -- Beispiel Längengrad

    local cfg = {
        -- Hier definierst du ALLE deine PV-Flächen.
        planes = {
            {
                name = "Dach",
                latitude = LAT,
                longitude = LON,
                declination = 30,
                azimuth = -45,
                kwp = 4.5
            },
            {
                name = "Balkon",
                latitude = LAT,
                longitude = LON,
                declination = 85,
                azimuth = 90,
                kwp = 6.9
            },
            -- Optional: Mehr Flächen hinzufügen
        },
        cachefile = "/tmp/forecast_solar_agg.json",
        cachetime = 1 * 3600, -- 1 Stunde
    }

    local pv_aggregator = ForecastSolarAggregator.new(cfg)

    -- Erster Abruf (echter Fetch)
    local hourly_kwh_data, err, cached = pv_aggregator:fetch()

    if not hourly_kwh_data or err then
        print("Kritischer Fehler beim ersten Fetch:", err)
        return
    end

    pv_aggregator:print_latest()

    print("\n--- Zusammenfassende Werte ---")
    print(string.format("Heutiger Rest-Ertrag (ab jetzt): %.2f kWh", pv_aggregator:get_remaining_daily_forecast_yield()))

    -- Zweiter Abruf (sollte aus dem Cache kommen)
    local d2, err2, cached2 = pv_aggregator:fetch()
    print("\nZweiter fetch (erwartet Cache): cached=" .. tostring(cached2))
    pv_aggregator:print_latest()
end

-- Führe die Beispiel-Funktion aus, wenn das Skript direkt gestartet wird
if arg[0]:find("forecastsolar.lua") then
    example()
end

return ForecastSolarAggregator
