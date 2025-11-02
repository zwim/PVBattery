-- ==============================================================
-- forecast_solar_aggregator.lua
-- Aggregiert die stündliche PV-Prognose (kWh) von forecast.solar
-- für mehrere Flächen (Planes).
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

-- Wiederverwendete HTTP GET Funktion (aus deiner Vorlage)
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

------------------------------------------------------------
-- Konstruktor
------------------------------------------------------------

-- Konfiguriere die Flächen, die abgefragt werden sollen
-- Die Konfiguration muss alle Flächen enthalten, da die Klasse die Summe bildet.
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
    self.cache = {
        timestamp = 0,
        hourly_kwh = nil, -- Speichert die summierten { timestamp: kwh }
        error = nil
    }

    self.latitude = self.latitude or 47.51
    self.longitude = self.longitude or 12.09


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

-- API des ursprünglichen Codes: Ersetzt die item/id-Logik
function ForecastSolarAggregator:fetch()
    local now = os.time()
    local is_cached = false

    -- 1. Cache-Prüfung (Einfache Zeitprüfung)
    if self.cache.hourly_kwh and (now - self.cache.timestamp) < self.config.cachetime then
        is_cached = true
        return self.cache.hourly_kwh, nil, is_cached
    end

    print("TRUE FETCH: Starte Abruf und Aggregation von " .. #self.planes .. " Flächen.")

    local total_hourly_kwh = {} -- { timestamp_string: kwh_value }
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
            -- Wir brechen hier ab, da eine unvollständige Summe sinnlos ist
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
        for timestamp, watts in pairs(data.result.watts) do
            -- Umrechnung: Watt (W) zu Kilowattstunden (kWh)
            local kwh = watts / 1000
            total_hourly_kwh[timestamp] = (total_hourly_kwh[timestamp] or 0) + kwh
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
    -- Sortieren ist für die Ausgabe sinnvoll, aber nicht für die Speicherung/Logik
    local hourly_kwh_table = self.cache.hourly_kwh or {}
    local sorted_kwh = {}

    -- Konvertierung der Tabelle in ein Array für die Sortierung
    for ts, kwh in pairs(hourly_kwh_table) do
        table.insert(sorted_kwh, { timestamp = ts, kwh = kwh })
    end

    table.sort(sorted_kwh, function(a, b)
        return a.timestamp < b.timestamp -- Sortiere nach dem Zeitstempel-String
    end)

    return sorted_kwh
end


-- Hilfsfunktion für die Berechnung des restlichen Ertrags
function ForecastSolarAggregator:get_remaining_daily_forecast_yield()
    local now_epoch = os.time()
    local today_date = os.date("%Y-%m-%d", now_epoch)
    local remaining_kwh = 0

    local hourly_kwh_table = self.cache.hourly_kwh or {}

    for timestamp_str, kwh in pairs(hourly_kwh_table) do
        -- Prüfe, ob der Eintrag von heute ist und noch in der Zukunft liegt
        if timestamp_str:sub(1, 10) == today_date then
            -- Konvertiere den Zeitstempel-String in Epoch
            -- Muster: "YYYY-MM-DD HH:MM:SS"
            local year, month, day, hour, min, sec = timestamp_str:match("(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)")

            -- Erstelle eine Zeittabelle (UTC-basiert, da forecast.solar UTC-Strings liefert)
            local ts_table = {
                year = tonumber(year),
                month = tonumber(month),
                day = tonumber(day),
                hour = tonumber(hour),
                min = tonumber(min),
                sec = tonumber(sec)
            }

            -- WICHTIG: os.time() konvertiert die Zeittabelle in eine Epoch-Zahl.
            -- Verwenden Sie 'os.time(ts_table)' wenn Sie davon ausgehen, dass der UTC-String
            -- bereits die lokale Zeit Ihrer Maschine widerspiegelt (was die einfachste,
            -- aber technisch unsauberste Methode ist).
            -- Oder verwenden Sie eine benutzerdefinierte UTC-zu-Epoch-Funktion,
            -- wenn Ihre Lua-Umgebung UTC-Zeiten explizit unterstützt (z.B. os.time(ts_table)).

            -- Wir nutzen die lokale Konvertierung, da die Zeitverschiebung meist
            -- von der Umgebung automatisch gehandhabt wird:
            local ts_epoch = os.time(ts_table) -- <--- KORREKTUR HIER!
            -- Da forecast.solar stündliche Werte liefert (z.B. 15:00:00),
            -- zählt der Wert für die gesamte Stunde ab diesem Zeitpunkt.
            -- Wir prüfen, ob die Stunde begonnen hat.
            if ts_epoch >= now_epoch then
                 remaining_kwh = remaining_kwh + kwh
            end
        end
    end

    -- Wenn keine Daten vorhanden sind, ist es ratsam, einen sicheren Wert zurückzugeben.
    -- Math.huge ist eher für Routing. 0 ist hier sicherer, um keine unnötigen
    -- Verbraucher zu starten.
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
    print(string.format("Status: %s. Zuletzt aktualisiert: %s", source_status, os.date("%H:%M:%S", self.cache.timestamp)))
    print("----------------------------------------")

    for _, entry in ipairs(data_array) do
        print(string.format("%s: %.3f kWh (Aggregiert)", entry.timestamp, entry.kwh))
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
        -- Die Aggregator-Klasse fragt alle ab und summiert.
        -- 0° Süd, -90° Ost
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
            -- {
            --     name = "Gartenhaus-Süd",
            --     latitude = LAT, longitude = LON,
            --     declination = 15, azimuth = 180, kwp = 1.0
            -- }
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