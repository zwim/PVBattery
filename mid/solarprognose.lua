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
    local error_message = nil
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
        cachetime = 1 * 3600, -- in hours
    }

    local wr2 = Solar.new{
        __name = "balkon",
        token = "c2a2da7b09c3c2e2a20651a2223e7fa7",
        project = "7052",
        item = "module_field",
        id = "14337",
        typ = "hourly",
        cachefile = "/tmp/wr2.json",
        cachetime = 1*3600,
    }

    print("Starte Abruf für WR1 (Dach)...")
    -- d1 ist jetzt das Array von Objekten
    local d1, err1, cached1 = wr1:fetch()
    d1, err1, cached1 = wr1:fetch()
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

    local gesamt = {}
    for i, v in ipairs(d1) do
        gesamt[i] = {}
        gesamt[i].hour = v.hour
        gesamt[i].power_kw = v.power_kw + d2[i].power_kw
        gesamt[i].cumulative_kwh = v.cumulative_kwh + d2[i].cumulative_kwh
        print(string.format("Stunde %4.2f -> %6.3f, Kumulativ: %4.3f",
                v.hour, gesamt[i].power_kw, gesamt[i].cumulative_kwh))
    end

end

if arg[0]:find("solarprognose.lua") then
    example()
end

return Solar
