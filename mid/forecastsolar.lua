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
local util   = require("base/util")

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
    self:fetch()

    return self
end

------------------------------------------------------------
-- Cache-Funktionen
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

function ForecastSolarAggregator:_process_data()
    local processed_data = {}

    for local_timestamp, v in pairs(self.cache.hourly_kwh) do
        local _, _, _, hour, min, sec = local_timestamp:match("(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)")
        local hour_decimal = hour + min/60 + sec/3600

        local entry = {
            -- Gewünschte Stundenangabe (z.B. 10.0, 10.5, 11.0)
            hour = hour_decimal,
            -- Leistung für diese Stunde (v[2])
            power_kw = v,
            -- Kumulierter Ertrag bis zu dieser Stunde (v[3])
            cumulative_kwh = nil,
        }

       table.insert(processed_data, entry)
    end

    table.sort(processed_data, function(a, b)
        return a.hour < b.hour
    end)

    for i = #processed_data, 2, -1 do
        if processed_data[i].hour == processed_data[i-1].hour then
            processed_data[i-1].power_kw = processed_data[i-1].power_kw + processed_data[i].power_kw
            table.remove(processed_data, i)
        end
    end

    local cumulative_kwh = 0
    for _, v in ipairs(processed_data) do
        cumulative_kwh = cumulative_kwh + v.power_kw
        v.cumulative_kwh = cumulative_kwh
    end

    return processed_data
end


function ForecastSolarAggregator:fetch(now)
    now = now or os.time()
    local is_cached = false

    -- 1. Cache-Prüfung (Einfache Zeitprüfung)
    if self.cache.hourly_kwh and (now - self.cache.timestamp) < self.config.cachetime then
        is_cached = true
        -- WICHTIG: Rückgabe der LOKAL-KEY-Aggregation
        return nil, is_cached
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
            return last_error, false
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

-- Hilfsfunktion für die Berechnung des restlichen Ertrags
function ForecastSolarAggregator:get_remaining_daily_forecast_yield(current_hour)
    current_hour = current_hour or tonumber(os.date("%H"))
    local data_array = self:_process_data()

    if #data_array == 0 then
        print("[Solarprognose] Fehler: Keine gültigen Daten.")
        if self.cache.error then print("Letzter Fehler:", self.cache.error) end

        return math.huge
    end

    local remaining_forecast_yield = 0
    for _, entry in ipairs(data_array) do
        if entry.hour > current_hour and entry.hour < 24 then
            remaining_forecast_yield = remaining_forecast_yield + entry.power_kw
        end
        if entry.hour >= 24 then
            break
        end
    end
    return remaining_forecast_yield
end

------------------------------------------------------------
-- Debug-Funktion
------------------------------------------------------------
function ForecastSolarAggregator:print_latest()
    local data_array = self:_process_data()
    local source_status = (self.cache.timestamp > 0 and (os.time() - self.cache.timestamp) < self.config.cachetime) and "(Cache)" or "(Neu)"

    if #data_array == 0 then
        print("Fehler: Keine gültigen Daten.")
        if self.cache.error then print("Letzter Fehler:", self.cache.error) end
        return
    end

    print(source_status, self.config.item, " (Ort: " .. (self.cache.datalinename or "Unbekannt") .. ")")
    print(string.format("Startzeitpunkt für Stundenberechnung: %s", os.date("%Y-%m-%d 00:00:00", util.get_midnight_epoch())))
    print("----------------------------------------")

    for _, entry in ipairs(data_array) do
        -- Umrechnung der dezimalen Stunde zurück in eine lesbare UTC-Zeit für die Ausgabe (optional)
        local total_seconds = entry.hour * 3600
        local t_epoch = util.get_midnight_epoch() + total_seconds
        local timeStamp_local = os.date("%Y-%m-%d %H:%M:%S", t_epoch)

        print(string.format("Stunde %.2f (lokal: %s) -> %.3f kW, Kumulativ: %.3f kWh",
                entry.hour,
                timeStamp_local,
                entry.power_kw,
                entry.cumulative_kwh
            ))
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
    local err = pv_aggregator:fetch()

    if err then
        print("Kritischer Fehler beim ersten Fetch:", err)
        return
    end

    pv_aggregator:print_latest()

    print("\n--- Zusammenfassende Werte ---")
    print(string.format("Heutiger Rest-Ertrag (ab jetzt): %.2f kWh",
            pv_aggregator:get_remaining_daily_forecast_yield()))

    -- Zweiter Abruf (sollte aus dem Cache kommen)
    local _, cached2 = pv_aggregator:fetch()
    print("\nZweiter fetch (erwartet Cache): cached=" .. tostring(cached2))
--    pv_aggregator:print_latest()
end

-- Führe die Beispiel-Funktion aus, wenn das Skript direkt gestartet wird
if arg[0]:find("forecastsolar.lua") then
    example()
end

return ForecastSolarAggregator
