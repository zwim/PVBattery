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
    local response_headers = {} -- Tabelle zum Speichern der Server-Header

    -- Request senden und Header-Tabelle übergeben
    local res, code = http.request{
        url = url,
        sink = ltn12.sink.table(response),
        headers = response_headers, -- Header werden hier gespeichert
        timeout = 10
    }

    -- Standard-Rückgabe-Werte vorbereiten
    local body = table.concat(response)
    local retry_after_value = nil

    -- 1. Fehler auf Transportebene prüfen
    if not res then
        -- Syntax: nil, "Fehlermeldung", nil
        return nil, "HTTP Transport-Fehler", nil
    end

    -- 2. Statuscode prüfen (Nicht-200)
    if code ~= 200 then
        -- Bei jedem Fehler prüfen wir, ob Retry-After vorhanden ist
        -- (Header-Namen sind oft kleingeschrieben: "retry-after")
        local raw_retry = response_headers["retry-after"]
        if raw_retry then
            -- Versuch, den Wert in eine Zahl umzuwandeln. Bei Fehlschlag ist er nil.
            retry_after_value = tonumber(raw_retry)
        end

        -- Bei 429 geben wir einen spezifischen Fehler und den Retry-Wert zurück
        if code == 429 then
            -- Syntax: nil, "429 Too Many Requests", Wartezeit
            return nil, "429 Too Many Requests", retry_after_value
        else
            -- Bei anderen Fehlern (z.B. 404, 500) geben wir nur den Code zurück
            -- Syntax: nil, "HTTP Code: 500", nil
            return nil, "HTTP Code: " .. tostring(code), nil
        end
    end

    -- 3. Erfolg (Code 200)
    -- Syntax: body, nil, nil
    return body, nil, nil
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
    self:fetch()

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
        now < self.cache.preferredNextApiRequestAt.epochTimeUtc + self.config.cachetime then
            is_cached = true
            -- Rückgabe des *verarbeiteten* Caches
            return self:_process_data(), nil, is_cached
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
        self:_save_cache()

        return self:_process_data(), err, is_cached
    end

    -- Safe JSON decode
    local ok, result = pcall(json.decode, body)
    if not ok or not result or not result.data then
        local error_msg = result or "JSON-Struktur ungültig."
        print("JSON decode error:", error_msg)
        self.cache.error = error_msg
        -- Rückgabe des *verarbeiteten* alten Caches
        return self:_process_data(), error_msg, is_cached
    end

    -- Cache aktualisieren
    self.cache = result
    self.cache.timestamp = now
    self.cache.error = nil


    self:_clean_cache()
    self:_save_cache()
    -- Rückgabe des *verarbeiteten* neuen Datensatzes
    return self:_process_data(), nil, false
end

-- no forecast, returns math.huge
function Solar:get_remaining_daily_forecast_yield()
    local data_array = self:_process_data()

    if #data_array == 0 then
        print("[Solarprognose] Fehler: Keine gültigen Daten.")
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

local SolarAggregator = {}
SolarAggregator.__index = SolarAggregator

------------------------------------------------------------
-- Aggregator-Konstruktor
------------------------------------------------------------
-- Nimm eine Tabelle von Konfigurationsobjekten (eine für jede Fläche) entgegen
function SolarAggregator.new(cfg)
    local self = setmetatable({}, SolarAggregator)
    self.planes = {}
    self.config = {
        cachefile = cfg.cachefile,
        cachetime = 0,
    }

    self.cache = {
        timestamp = 0,
        aggregated_data = nil,
        error = nil
    }

    -- Erzeuge für jede Fläche eine eigene Solar-Instanz
    for i, cfg in ipairs(cfg.planes) do
        -- Der Cache-Pfad muss für jede Plane eindeutig sein
        if not cfg.cachefile then
            cfg.cachefile = string.format("/tmp/solarprognose_%s.json", cfg.id or i)
        end
        self.config.cachetime = math.max(self.config.cachetime, cfg.cachetime or 1800)
        local instance = Solar.new(cfg)
        table.insert(self.planes, instance)
    end

    -- Definiere den gemeinsamen Cache-Pfad für die aggregierten Daten (optional)
    self.config.cachefile = self.config.cachefile or "/tmp/solarprognose_agg_total.json"
    self.config.cachetime = self.config.cachetime or 1800

    self:_load_agg_cache()

    return self
end

------------------------------------------------------------
-- Cache-Funktionen (Für Aggregierte Daten)
------------------------------------------------------------
function SolarAggregator:_load_agg_cache()
    local content = read_file(self.config.cachefile)
    if not content or #content == 0 then return end

    local ok, result = pcall(json.decode, content)
    if ok and result and result.aggregated_data then
        self.cache = result
    end
end

function SolarAggregator:_save_agg_cache()
    local content = json.encode(self.cache, { indent = false })
    write_file(self.config.cachefile, content)
end

------------------------------------------------------------
-- Hauptlogik: Abruf & Aggregation
------------------------------------------------------------

-- Führt fetch() für jede Plane durch und aggregiert die Ergebnisse
function SolarAggregator:fetch()
    local now = os.time()

    -- Aggregierten Cache prüfen (optional, hier deaktiviert, um immer aktuelle Daten zu liefern)
    -- Da jede Plane ihren eigenen Cache verwaltet, holen wir die aktuellsten Daten (entweder Cache oder API)

    print("Starte Abruf/Cache-Lade-Prozess für " .. #self.planes .. " Flächen.")

    local all_plane_data = {}
    local last_error = nil

    -- 1. Hole Daten für jede einzelne Plane (nutzt Cache oder API)
    for _, plane in ipairs(self.planes) do
        -- Jeder Aufruf nutzt den spezifischen Cache oder triggert einen API-Fetch
        local data_array, err = plane:fetch()

        if err then
            last_error = "Fehler bei Plane " .. (plane.__name or plane.config.id) .. ": " .. err
            -- Wir brechen NICHT ab, sondern versuchen, die Daten der anderen Planes zu aggregieren.
            print(last_error)
        end

        -- Wir speichern die Daten, auch wenn sie leer sind (leeres Array wird korrekt aggregiert)
        table.insert(all_plane_data, data_array or {})
    end

    -- 2. Aggregation der Daten
    local aggregated_data = {}

    -- Gehe davon aus, dass alle Array-Längen gleich sind (gleicher Zeitbereich von der API)
    -- Wir nutzen die Länge des ersten Datensatzes als Referenz
    local reference_data = all_plane_data[1]

    if not reference_data or #reference_data == 0 then
        self.cache.timestamp = now
        self.cache.error = last_error or "Keine Daten von irgendeiner Plane verfügbar."
        self:_save_agg_cache()
        return aggregated_data, self.cache.error, false
    end

    for i, entry_ref in ipairs(reference_data) do
        local total_power_kw = 0
        local total_cumulative_kwh = 0

        -- Aggregiere über alle Planes für diesen spezifischen Zeitschritt (i)
        for _, plane_data in ipairs(all_plane_data) do
            local entry = plane_data[i]
            if entry then
                total_power_kw = total_power_kw + (entry.power_kw or 0)
                total_cumulative_kwh = total_cumulative_kwh + (entry.cumulative_kwh or 0)
            end
        end

        -- Erstelle den aggregierten Eintrag
        local agg_entry = {
            hour = entry_ref.hour,
            power_kw = total_power_kw,
            cumulative_kwh = total_cumulative_kwh,
            -- Hier könnten weitere nützliche Felder hinzugefügt werden (z.B. lokale Zeit)
        }
        table.insert(aggregated_data, agg_entry)
    end

    -- 3. Cache aktualisieren und speichern
    self.cache.aggregated_data = aggregated_data
    self.cache.timestamp = now
    self.cache.error = last_error
    self:_save_agg_cache()

    return aggregated_data, last_error, false
end

-- Gibt die aggregierten Daten zurück
function SolarAggregator:get_aggregated_forecast()
    return self.cache.aggregated_data or {}
end

-- Berechnet den Rest-Ertrag basierend auf den aggregierten Daten
function SolarAggregator:get_remaining_daily_forecast_yield()
    local data_array = self.cache.aggregated_data

    if not data_array or #data_array == 0 then
        print("[SolarAggregator] Fehler: Keine gültigen aggregierten Daten.")
        return math.huge
    end

    local midnight_epoch = self.planes[1]:_get_midnight_epoch()

    -- Konvertiere die aktuelle Zeit in die dezimale Stunde des Tages
    local current_hour_decimal = (os.time() - midnight_epoch) / 3600

    local remaining_forecast_yield = 0
    for _, entry in ipairs(data_array) do
        -- Prüfe, ob die Prognosestunde noch nicht begonnen hat
        if entry.hour >= current_hour_decimal then
            remaining_forecast_yield = remaining_forecast_yield + entry.power_kw
        end
        if entry.hour >= 24.00 then
            break
        end
    end
    return remaining_forecast_yield
end

------------------------------------------------------------
-- Debug-Funktion (nutzt die aggregierten Daten)
------------------------------------------------------------
function SolarAggregator:print_latest()
    local data_array = self:get_aggregated_forecast()

    if #data_array == 0 then
        print("Fehler: Keine gültigen aggregierten Daten.")
        if self.cache.error then print("Letzter Aggregationsfehler:", self.cache.error) end
        return
    end

    print("\n--- Aggregierter Solarprognose Ertrag ---")
    print(string.format("Status: Zuletzt aggregiert (Lokal): %s", os.date("%Y-%m-%d %H:%M:%S", self.cache.timestamp)))
    print("----------------------------------------")

    -- Für die Debug-Ausgabe brauchen wir den Midnight-Epoch-Wert von einer Plane
    local midnight_epoch = self.planes[1]:_get_midnight_epoch()

    for _, entry in ipairs(data_array) do
        local total_seconds = entry.hour * 3600
        local t_epoch = midnight_epoch + total_seconds
        local timeStamp_local = os.date("%Y-%m-%d %H:%M:%S", t_epoch)

        print(string.format("Stunde %.2f (lokal: %s) -> %.3f kW (Gesamt), Kumulativ: %.3f kWh (Gesamt)",
                entry.hour,
                timeStamp_local,
                entry.power_kw,
                entry.cumulative_kwh
            ))
    end
    print("----------------------------------------")
    print(string.format("Heutiger Rest-Ertrag (ab jetzt): %.2f kWh (Aggregiert)",
            self:get_remaining_daily_forecast_yield()))
end


------------------------------------------------------------
-- Beispielverwendung (Ersetzt die alte example-Funktion)
------------------------------------------------------------

local function example()
    local cfg = {
        planes = {
            {
                __name = "Dach (WR1)",
                token = "c2a2da7b09c3c2e2a20651a2223e7fa7",
                id = "14336",
                typ = "hourly",
                cachetime = 1 * 3600,
            },
            {
                __name = "Balkon (WR2)",
                token = "c2a2da7b09c3c2e2a20651a2223e7fa7",
                id = "14337",
                typ = "hourly",
                cachetime = 1*3600,
            },
        },
        cachefile = "/tmp/solarprognose_agg_total.json",
        -- cachetime = 1 * 3600, -- Aggregation Cache, -- use the maximum of the above or 1800 sec
    }

    -- Erstelle den Aggregator und seine internen Solar-Instanzen
    local pv_aggregator = SolarAggregator.new(cfg)

    print("Starte Aggregator Fetch (holt Daten für beide Planes)...")

    -- Fetch-Aufruf, der BEIDE API-Abrufe (oder Cache-Lesungen) ausführt und aggregiert
    local aggregated_data, err = pv_aggregator:fetch()

    if not aggregated_data or err then
        print("Kritischer Fehler bei Aggregation:", err)
        return
    end

    pv_aggregator:print_latest()

end

-- Führe die Beispiel-Funktion aus, wenn das Skript direkt gestartet wird
if arg[0]:find("solarprognose.lua") then
    example()
end

-- Gebe beide Klassen zurück, falls das Skript als Modul verwendet wird
return SolarAggregator