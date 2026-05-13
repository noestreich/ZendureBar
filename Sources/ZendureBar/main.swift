import AppKit
import Foundation
import CocoaMQTT
import CommonCrypto
import SQLite3

// MARK: - Modelle

// Gerät aus der /api/ha/deviceList Antwort
struct CloudDevice {
    var name:       String
    var productKey: String
    var deviceKey:  String
    var snNumber:   String
    var ip:         String
}

// MQTT-Zugangsdaten aus der API
struct MQTTCredentials {
    var broker:   String
    var username: String
    var password: String
    var clientId: String
}

struct BatteryPack {
    let socLevel:    Int
    let tempCelsius: Double
    let voltageV:    Double
    let state:       Int
}

struct DeviceData {
    let name:            String
    let solarPower:      Int
    let solarChannels:   [Int]
    let homeOutput:      Int
    let batteryLevel:    Int
    let batteryCharge:   Int
    let batteryDischarge:Int
    let gridInput:       Int
    let remainSeconds:   Int
    let deviceTempC:     Double
    let packs:           [BatteryPack]
    let rssi:            Int
}

struct ShellMeterData {
    let totalPower: Double
    let phaseA: Double; let phaseB: Double; let phaseC: Double
    let voltageA: Double; let voltageB: Double; let voltageC: Double
}

// MARK: - Persistente Daten (SQLite)

final class DataStore {
    static let shared = DataStore()

    private var db:         OpaquePointer?
    private var lastInsert: Date = .distantPast

    private init() {
        guard let support = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = support.appendingPathComponent("ZendureBar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("history.sqlite").path
        sqlite3_open(path, &db)
        exec("""
            CREATE TABLE IF NOT EXISTS readings (
                ts      INTEGER PRIMARY KEY,
                solar_w INTEGER NOT NULL DEFAULT 0,
                grid_w  INTEGER NOT NULL DEFAULT 0
            )
        """)
        // Einträge älter als 90 Tage automatisch löschen
        let cutoff = Int(Date().timeIntervalSince1970) - 90 * 86400
        exec("DELETE FROM readings WHERE ts < \(cutoff)")
        mqttLog("[DB] Geöffnet: \(path)")
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    /// Speichert einen Messpunkt – maximal 1× alle 10 Sekunden
    func insert(solar: Int, grid: Int) {
        guard Date().timeIntervalSince(lastInsert) >= 10 else { return }
        lastInsert = Date()
        let ts = Int(Date().timeIntervalSince1970)
        exec("INSERT OR REPLACE INTO readings(ts,solar_w,grid_w) VALUES(\(ts),\(solar),\(grid))")
    }

    /// Liest einen Zeitbereich, auf maxPoints heruntergesampelt
    func query(from: Date, to: Date, maxPoints: Int = 500)
        -> (solar: [(time: Date, watts: Int)], grid: [(time: Date, watts: Int)])
    {
        let sql = """
            SELECT ts,solar_w,grid_w FROM readings
            WHERE ts >= \(Int(from.timeIntervalSince1970))
              AND ts <= \(Int(to.timeIntervalSince1970))
            ORDER BY ts
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return ([], []) }
        defer { sqlite3_finalize(stmt) }
        var rows: [(ts: Int, s: Int, g: Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append((
                Int(sqlite3_column_int64(stmt, 0)),
                Int(sqlite3_column_int(stmt, 1)),
                Int(sqlite3_column_int(stmt, 2))
            ))
        }
        let step    = max(1, rows.count / maxPoints)
        let sampled = Swift.stride(from: 0, to: rows.count, by: step).map { rows[$0] }
        return (
            solar: sampled.map { (time: Date(timeIntervalSince1970: Double($0.ts)), watts: $0.s) },
            grid:  sampled.map { (time: Date(timeIntervalSince1970: Double($0.ts)), watts: $0.g) }
        )
    }

    /// Heutiger Tag von Mitternacht bis jetzt
    func todayData() -> (solar: [(time: Date, watts: Int)], grid: [(time: Date, watts: Int)]) {
        query(from: Calendar.current.startOfDay(for: Date()), to: Date())
    }

    /// Wattstunden-Summe für einen Zeitraum (jeder Eintrag ≈ 10 s Abtastintervall)
    func sumWh(from: Date, to: Date) -> (solarWh: Double, gridWh: Double) {
        let sql = """
            SELECT COALESCE(SUM(CAST(solar_w AS REAL)), 0.0),
                   COALESCE(SUM(CAST(grid_w  AS REAL)), 0.0)
            FROM readings
            WHERE ts >= \(Int(from.timeIntervalSince1970))
              AND ts <= \(Int(to.timeIntervalSince1970))
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0, 0) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_step(stmt)
        // Watt × 10 s / 3600 = Wh
        return (sqlite3_column_double(stmt, 0) * 10 / 3600,
                sqlite3_column_double(stmt, 1) * 10 / 3600)
    }

    /// Tagesweise Summen der letzten `days` Tage (neuester Tag zuletzt)
    func weeklyTotals(days: Int = 7) -> [(date: Date, solarWh: Double, gridWh: Double)] {
        let cal = Calendar.current
        return (0..<days).reversed().map { offset in
            let day    = cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: Date()))!
            let dayEnd = cal.date(byAdding: .day, value: 1, to: day)!
            let s      = sumWh(from: day, to: dayEnd)
            return (date: day, solarWh: s.solarWh, gridWh: s.gridWh)
        }
    }
}

// MARK: - UserDefaults

enum Prefs {
    static let meterIPKey  = "ShellyMeterIP"
    static let cloudKeyKey = "ZendureCloudKey"

    static func loadMeterIP() -> String  { UserDefaults.standard.string(forKey: meterIPKey)  ?? "" }
    static func save(meterIP: String)    { UserDefaults.standard.set(meterIP,  forKey: meterIPKey) }

    static func loadCloudKey() -> String { UserDefaults.standard.string(forKey: cloudKeyKey) ?? "" }
    static func save(cloudKey: String) {
        if cloudKey.isEmpty { UserDefaults.standard.removeObject(forKey: cloudKeyKey) }
        else                { UserDefaults.standard.set(cloudKey, forKey: cloudKeyKey) }
    }
}

// MARK: - Zendure Cloud API

enum ZendureAPI {
    private static let haKey = "C*dafwArEOXK"

    static func decode(cloudKey: String) -> (apiUrl: String, appKey: String)? {
        guard let data = Data(base64Encoded: cloudKey),
              let decoded = String(data: data, encoding: .utf8) else { return nil }
        let parts = decoded.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }
        return (parts.dropLast().joined(separator: "."), parts.last!)
    }

    static func fetchDeviceList(cloudKey: String,
                                completion: @escaping (MQTTCredentials?, [CloudDevice]) -> Void) {
        guard let (apiUrl, appKey) = decode(cloudKey: cloudKey),
              let url = URL(string: "\(apiUrl)/api/ha/deviceList") else {
            completion(nil, []); return
        }
        let timestamp = Int(Date().timeIntervalSince1970)
        let nonce     = String(Int.random(in: 10000...99999))
        let body      = ["appKey": appKey]
        let signParts = body.merging(["timestamp": String(timestamp), "nonce": nonce]) { $1 }
        let bodyStr   = signParts.sorted { $0.key < $1.key }.map { "\($0.key)\($0.value)" }.joined()
        let sha1      = "\(haKey)\(bodyStr)\(haKey)".data(using: .utf8)!.sha1().uppercased()

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(String(timestamp),  forHTTPHeaderField: "timestamp")
        req.setValue(nonce,              forHTTPHeaderField: "nonce")
        req.setValue("zenHa",            forHTTPHeaderField: "clientid")
        req.setValue(sha1,               forHTTPHeaderField: "sign")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data,
                  let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let resData = json["data"] as? [String: Any] else {
                mqttLog("[API] Ungültige Antwort")
                DispatchQueue.main.async { completion(nil, []) }; return
            }
            mqttLog("[API] Antwort: \(json)")
            var creds: MQTTCredentials?
            if let mqttInfo = resData["mqtt"] as? [String: Any],
               let brokerRaw = mqttInfo["url"] as? String, !brokerRaw.isEmpty {
                let broker = brokerRaw.components(separatedBy: ":").first ?? brokerRaw
                creds = MQTTCredentials(
                    broker:   broker,
                    username: mqttInfo["username"] as? String ?? "",
                    password: mqttInfo["password"] as? String ?? "",
                    clientId: mqttInfo["clientId"] as? String ?? appKey)
                mqttLog("[API] Broker: \(broker), User: \(creds!.username)")
            }
            let devList = (resData["deviceList"] as? [[String: Any]] ?? []).compactMap { d -> CloudDevice? in
                guard let pk = d["productKey"] as? String, !pk.isEmpty,
                      let dk = d["deviceKey"]  as? String, !dk.isEmpty else { return nil }
                return CloudDevice(
                    name:       d["deviceName"]  as? String ?? d["productModel"] as? String ?? "Zendure",
                    productKey: pk, deviceKey: dk,
                    snNumber:   d["snNumber"]    as? String ?? "",
                    ip:         d["ip"]          as? String ?? "")
            }
            mqttLog("[API] Geräte: \(devList.map { "\($0.name) (\($0.deviceKey))" })")
            DispatchQueue.main.async { completion(creds, devList) }
        }.resume()
    }
}

private extension Data {
    func sha1() -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        withUnsafeBytes { ptr in
            var ctx = CC_SHA1_CTX()
            CC_SHA1_Init(&ctx)
            CC_SHA1_Update(&ctx, ptr.baseAddress, CC_LONG(count))
            CC_SHA1_Final(&digest, &ctx)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - MQTT Debug Logger

private let mqttLogFile = "/tmp/zendurebar_mqtt.log"
private func mqttLog(_ msg: String) {
    let line = "\(Date()) \(msg)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: mqttLogFile) {
            if let fh = FileHandle(forWritingAtPath: mqttLogFile) {
                fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
            }
        } else { try? data.write(to: URL(fileURLWithPath: mqttLogFile)) }
    }
    print(msg)
}

// MARK: - MQTT Manager

final class ZendureMQTTManager: NSObject, CocoaMQTTDelegate {

    enum Status { case connecting, connected, disconnected, error(String) }

    var onData:   ((DeviceData) -> Void)?
    var onStatus: ((Status) -> Void)?

    private var client:  CocoaMQTT?
    private let creds:   MQTTCredentials
    private let devices: [CloudDevice]

    // Akkumulierter State je deviceKey (Zendure schickt partielle Updates)
    private var accProps: [String: [String: Any]]   = [:]
    private var accPacks: [String: [[String: Any]]] = [:]

    // Watchdog & periodischer getAll-Request
    private var getAllTimer:      Timer?
    private var watchdogTimer:    Timer?
    private var lastDataReceived: Date?
    private var connectedAt:      Date?
    private var isConnected = false

    init(credentials: MQTTCredentials, devices: [CloudDevice]) {
        self.creds   = credentials
        self.devices = devices
        super.init()
        mqttLog("[MQTT] Init – Broker: \(credentials.broker), Geräte: \(devices.map { $0.name })")
        connect()
        startWatchdog()
    }

    private func connect() {
        onStatus?(.connecting)
        let mqtt = CocoaMQTT(clientID: creds.clientId, host: creds.broker, port: 1883)
        mqtt.username      = creds.username
        mqtt.password      = creds.password
        mqtt.keepAlive     = 60
        mqtt.autoReconnect = true
        mqtt.autoReconnectTimeInterval = 15
        mqtt.delegate = self
        mqttLog("[MQTT] connect() → \(mqtt.connect())")
        client = mqtt
    }

    func disconnect() {
        getAllTimer?.invalidate();   getAllTimer   = nil
        watchdogTimer?.invalidate(); watchdogTimer = nil
        client?.disconnect(); client = nil
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.watchdogTick()
        }
    }

    private func watchdogTick() {
        guard isConnected else { return }

        // Wie lange verbunden?
        let connAge = connectedAt.map { -$0.timeIntervalSinceNow } ?? 0
        // Wie lange keine Daten?
        let dataAge: Double
        if let last = lastDataReceived { dataAge = -last.timeIntervalSinceNow }
        else { dataAge = connAge }   // noch nie Daten → Alter = Verbindungsalter
        mqttLog("[Watchdog] Verbunden \(Int(connAge)) s, letzte Daten vor \(Int(dataAge)) s")

        // Erst nach 5 Minuten ohne Daten reconnecten – so haben langsam startende
        // Geräte genug Zeit um sich beim Broker einzuloggen
        if dataAge > 300 {
            mqttLog("[Watchdog] 5 min keine Daten – Reconnect")
            getAllTimer?.invalidate(); getAllTimer = nil
            isConnected = false
            connectedAt = nil
            client?.disconnect()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.connect()
            }
        }
    }

    // MARK: - getAll Hilfsfunktion

    private func sendGetAll() {
        guard let mqtt = client, isConnected else { return }
        let payload = #"{"properties":["getAll"]}"#
        for dev in devices {
            let readTopic = "/\(dev.productKey)/\(dev.deviceKey)/properties/read"
            mqtt.publish(CocoaMQTTMessage(topic: readTopic, string: payload, qos: .qos0))
            mqttLog("[MQTT] getAll → \(readTopic)")
        }
    }

    // MARK: CocoaMQTTDelegate

    func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        mqttLog("[MQTT] ConnAck: \(ack.rawValue)")
        guard ack == .accept else {
            let msg: String
            switch ack {
            case .badUsernameOrPassword: msg = "Falscher Nutzer / Passwort"
            case .notAuthorized:         msg = "Nicht autorisiert"
            case .serverUnavailable:     msg = "Server nicht verfügbar"
            default:                     msg = "Code \(ack.rawValue)"
            }
            mqttLog("[MQTT] Abgelehnt: \(msg)"); onStatus?(.error(msg)); return
        }
        isConnected = true
        connectedAt = Date()
        onStatus?(.connected)

        // Topic-Format: /{productKey}/{deviceKey}/# (führender Slash!)
        for dev in devices {
            let t = "/\(dev.productKey)/\(dev.deviceKey)/#"
            mqtt.subscribe(t, qos: .qos0)
            mqttLog("[MQTT] Subscribe: \(t)")
        }

        // Ersten getAll nach kurzer Pause senden, dann alle 60 s wiederholen.
        // Das stellt sicher, dass Geräte die nach dem Mac-Start langsam online kamen
        // trotzdem innerhalb einer Minute antworten.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.sendGetAll()
            self?.getAllTimer?.invalidate()
            self?.getAllTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                self?.sendGetAll()
            }
        }
    }

    func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16) {
        guard let str = message.string else { return }
        let topic = message.topic
        mqttLog("[MQTT] \(topic): \(str)")

        guard topic.hasSuffix("properties/report"),
              let data = str.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        // deviceKey aus Topic: /{productKey}/{deviceKey}/...
        let parts = topic.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return }
        let deviceKey = String(parts[1])
        guard let cloudDev = devices.first(where: { $0.deviceKey == deviceKey }) else { return }

        // Zendure schickt Werte flat im Payload (kein "properties"-Wrapper) –
        // aber manchmal auch gewrappt; beide Varianten unterstützen
        let incoming: [String: Any]
        if let wrapped = json["properties"] as? [String: Any] {
            incoming = wrapped
        } else {
            incoming = json.filter { $0.key != "packData" }
        }
        if !incoming.isEmpty {
            // WICHTIG: explizite Kopie nötig – Swift Dicts sind Value Types.
            // accProps[key]![subkey] = v würde eine Kopie modifizieren, nicht das Original.
            var current = accProps[deviceKey] ?? [:]
            for (k, v) in incoming { current[k] = v }
            accProps[deviceKey] = current
        }
        if let packs = json["packData"] as? [[String: Any]], !packs.isEmpty {
            // Vollständige Daten (socLevel/maxTemp) bevorzugen; minimale Daten nur als Fallback
            let hasFullData = packs.first.flatMap { $0["socLevel"] } != nil
            if hasFullData || accPacks[deviceKey] == nil {
                accPacks[deviceKey] = packs
            }
        }

        let props = accProps[deviceKey] ?? [:]
        let packs = accPacks[deviceKey] ?? []

        let solar   = props["solarInputPower"]  as? Int ?? 0
        let battery = props["electricLevel"]    as? Int ?? 0
        let packIn  = props["packInputPower"]   as? Int ?? 0
        let packOut = props["outputPackPower"]  as? Int ?? 0
        guard solar > 0 || battery > 0 || packIn > 0 || packOut > 0 || !packs.isEmpty else { return }

        let home   = props["outputHomePower"]  as? Int ?? 0
        let gridIn = props["gridInputPower"]   as? Int ?? 0
        let remOut = props["remainOutTime"]    as? Int ?? 0
        let remIn  = props["remainInputTime"]  as? Int ?? 0

        // Temperatur: Zendure-Kodierung → (rawValue − 2731) / 10 = °C
        let rawTmp = (props["hyperTmp"] as? Double) ?? Double(props["hyperTmp"] as? Int ?? 0)
        let tempC  = rawTmp > 200 ? (rawTmp - 2731) / 10.0 : rawTmp

        let channels = (1...4).compactMap { i -> Int? in
            let w = props["solarPower\(i)"] as? Int ?? 0; return w > 0 ? w : nil
        }
        let battPacks: [BatteryPack] = packs.map { p in
            let rawT = (p["maxTemp"] as? Double) ?? Double(p["maxTemp"] as? Int ?? 0)
            let tmp  = rawT > 200 ? (rawT - 2731) / 10.0 : rawT
            let rawV = p["totalVol"] as? Int ?? 0
            return BatteryPack(
                socLevel:    p["socLevel"] as? Int ?? 0,
                tempCelsius: tmp,
                voltageV:    Double(rawV) / 100.0,
                state:       p["state"]   as? Int ?? 0)
        }

        let result = DeviceData(
            name: cloudDev.name, solarPower: solar, solarChannels: channels,
            homeOutput: home, batteryLevel: battery, batteryCharge: packIn,
            batteryDischarge: packOut, gridInput: gridIn,
            remainSeconds: packOut > 0 ? remOut : (packIn > 0 ? remIn : 0),
            deviceTempC: tempC, packs: battPacks, rssi: props["rssi"] as? Int ?? 0)
        lastDataReceived = Date()
        DispatchQueue.main.async { [weak self] in self?.onData?(result) }
    }

    func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: Error?) {
        mqttLog("[MQTT] Disconnect: \(err?.localizedDescription ?? "–")")
        isConnected = false
        getAllTimer?.invalidate(); getAllTimer = nil
        onStatus?(.disconnected)
    }

    func mqtt(_ mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {}
    func mqtt(_ mqtt: CocoaMQTT, didPublishAck id: UInt16) {}
    func mqtt(_ mqtt: CocoaMQTT, didSubscribeTopics success: NSDictionary, failed: [String]) {
        mqttLog("[MQTT] Subscribe OK: \(success.allKeys), failed: \(failed)")
    }
    func mqtt(_ mqtt: CocoaMQTT, didUnsubscribeTopics topics: [String]) {}
    func mqttDidPing(_ mqtt: CocoaMQTT) {}
    func mqttDidReceivePong(_ mqtt: CocoaMQTT) {}
}

// MARK: - Einstellungen-Fenster

final class SettingsWindowController: NSWindowController {

    private let outerStack = NSStackView()
    private var meterField    = NSTextField()
    private var cloudKeyField = NSTextField()

    var onSave: (String, String) -> Void = { _, _ in }

    init(meterIP: String, cloudKey: String) {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        win.title = "Einstellungen"
        win.isReleasedWhenClosed = false
        super.init(window: win)
        buildUI(meterIP: meterIP, cloudKey: cloudKey)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI(meterIP: String, cloudKey: String) {
        guard let cv = window?.contentView else { return }

        outerStack.orientation = .vertical
        outerStack.alignment   = .left
        outerStack.spacing     = 10
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(outerStack)

        // ── Zendure Cloud Key ────────────────────────────────────────────
        outerStack.addArrangedSubview(sectionLabel("Zendure Cloud Key"))
        let hint = NSTextField(labelWithString: "Zendure App → Profil → API → Cloud Key")
        hint.font = NSFont.systemFont(ofSize: 10); hint.textColor = .tertiaryLabelColor
        outerStack.addArrangedSubview(hint)
        cloudKeyField = field(placeholder: "aHR0cH…  (base64-Token aus der App)", value: cloudKey)
        cloudKeyField.widthAnchor.constraint(equalToConstant: 400).isActive = true
        outerStack.addArrangedSubview(cloudKeyField)

        // ── Smart Meter ──────────────────────────────────────────────────
        outerStack.addArrangedSubview(divider())
        outerStack.addArrangedSubview(sectionLabel("Smart Meter (Shelly Pro 3EM)"))
        meterField = field(placeholder: "10.0.0.x  —  leer lassen wenn nicht vorhanden", value: meterIP)
        meterField.widthAnchor.constraint(equalToConstant: 400).isActive = true
        outerStack.addArrangedSubview(meterField)

        // ── Speichern ────────────────────────────────────────────────────
        let saveBtn = NSButton(title: "Speichern", target: self, action: #selector(saveTapped))
        saveBtn.bezelStyle = .rounded; saveBtn.keyEquivalent = "\r"
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottomBar = NSStackView(views: [spacer, saveBtn])
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            outerStack.topAnchor    .constraint(equalTo: cv.topAnchor,      constant:  20),
            outerStack.leadingAnchor.constraint(equalTo: cv.leadingAnchor,  constant:  20),
            outerStack.trailingAnchor.constraint(equalTo: cv.trailingAnchor,constant: -20),
            outerStack.bottomAnchor .constraint(lessThanOrEqualTo: bottomBar.topAnchor, constant: -12),
            bottomBar.leadingAnchor .constraint(equalTo: cv.leadingAnchor,  constant:  20),
            bottomBar.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            bottomBar.bottomAnchor  .constraint(equalTo: cv.bottomAnchor,   constant: -16),
            bottomBar.heightAnchor  .constraint(equalToConstant: 28),
        ])

        // Fensterhöhe: 3 Labels + 2 Felder + 1 Divider + Padding + Save-Button
        let rowH: CGFloat = 24; let sp: CGFloat = 10
        let rows: CGFloat = 6
        let newH = 20 + rows * rowH + (rows - 1) * sp + 12 + 28 + 16
        if let w = window { var f = w.frame; f.size.height = newH; w.setFrame(f, display: false) }
    }

    @objc private func saveTapped() {
        onSave(
            meterField   .stringValue.trimmingCharacters(in: .whitespaces),
            cloudKeyField.stringValue.trimmingCharacters(in: .whitespaces)
        )
        window?.close()
    }

    private func divider() -> NSBox {
        let b = NSBox(); b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 1).isActive = true; return b
    }
    private func sectionLabel(_ t: String) -> NSTextField {
        let f = NSTextField(labelWithString: t)
        f.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        f.textColor = .secondaryLabelColor; return f
    }
    private func field(placeholder: String, value: String) -> NSTextField {
        let f = NSTextField(string: value); f.placeholderString = placeholder; return f
    }
    func showCentered() {
        window?.center(); NSApp.activate(ignoringOtherApps: true); showWindow(nil)
    }
}

// MARK: - Verlauf-Fenster

final class HistoryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    private var selectedDate  = Calendar.current.startOfDay(for: Date())
    private var rangeHours    = 24
    private var lastScrollEvt = Date.distantPast

    // Graph-Views
    private let solarGraph = SolarGraphView(frame: .zero)
    private let gridGraph  = SolarGraphView(frame: .zero)

    // Toolbar
    private let dateLabel  = NSTextField(labelWithString: "")
    private let rangeCtrl  = NSSegmentedControl()

    // Zusammenfassung (kWh)
    private let summaryLabel = NSTextField(labelWithString: "")

    // Wochentabelle (nur in 7T-Ansicht sichtbar)
    private let tableScroll = NSScrollView()
    private let tableView   = NSTableView()
    private var weekRows: [(date: Date, solarWh: Double, gridWh: Double)] = []
    private var tableHeightConstraint: NSLayoutConstraint!

    private var refreshTimer: Timer?

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 580),
            styleMask:   [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = "ZendureBar – Verlauf"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 520, height: 420)
        super.init(window: win)
        buildUI()
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: UI

    private func buildUI() {
        guard let cv = window?.contentView else { return }

        // ── Toolbar ───────────────────────────────────────────────────────────
        let prevBtn = NSButton(title: "◀", target: self, action: #selector(prevDay))
        prevBtn.bezelStyle = .rounded
        let nextBtn = NSButton(title: "▶", target: self, action: #selector(nextDay))
        nextBtn.bezelStyle = .rounded

        dateLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        dateLabel.alignment = .center

        rangeCtrl.segmentCount = 4
        rangeCtrl.setLabel("1 h",  forSegment: 0)
        rangeCtrl.setLabel("6 h",  forSegment: 1)
        rangeCtrl.setLabel("24 h", forSegment: 2)
        rangeCtrl.setLabel("7 T",  forSegment: 3)
        rangeCtrl.selectedSegment = 2
        rangeCtrl.target = self; rangeCtrl.action = #selector(rangeChanged)

        // ── Zusammenfassung ───────────────────────────────────────────────────
        summaryLabel.font      = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.alignment = .right

        // ── Graph-Labels ──────────────────────────────────────────────────────
        let solarLbl = histLabel("☀︎  Solar")
        let gridLbl  = histLabel("⚡  Netzbezug")

        solarGraph.accent = NSColor(red: 1.0, green: 0.55, blue: 0.0, alpha: 1.0)
        gridGraph.accent  = NSColor(red: 0.2, green: 0.75, blue: 0.3, alpha: 1.0)

        // Scroll-Zoom: Mausrad wechselt Zeitbereich
        let scrollZoom: (CGFloat) -> Void = { [weak self] delta in
            guard let self, Date().timeIntervalSince(self.lastScrollEvt) > 0.4 else { return }
            self.lastScrollEvt = Date()
            let steps = [1, 6, 24, 168]
            let idx   = steps.firstIndex(of: self.rangeHours) ?? 2
            let newIdx = delta > 0 ? max(0, idx-1) : min(steps.count-1, idx+1)
            guard newIdx != idx else { return }
            self.rangeHours = steps[newIdx]
            self.rangeCtrl.selectedSegment = newIdx
            self.reload()
        }
        solarGraph.onScroll = scrollZoom
        gridGraph.onScroll  = scrollZoom

        // ── Wochentabelle ─────────────────────────────────────────────────────
        for col in [("Datum", 120), ("☀︎  Solar", 110), ("⚡  Netzbezug", 110), ("Σ  Gesamt", 110)] as [(String, Int)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.0))
            c.title = col.0; c.width = CGFloat(col.1); c.resizingMask = .autoresizingMask
            tableView.addTableColumn(c)
        }
        tableView.dataSource = self; tableView.delegate = self
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight  = 22
        tableView.gridStyleMask = .solidHorizontalGridLineMask
        tableScroll.documentView     = tableView
        tableScroll.hasVerticalScroller = false
        tableScroll.borderType = .noBorder

        // ── Layout ────────────────────────────────────────────────────────────
        let m: CGFloat = 16
        for v in [prevBtn, dateLabel, nextBtn, rangeCtrl,
                  summaryLabel, solarLbl, solarGraph, gridLbl, gridGraph,
                  tableScroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cv.addSubview(v)
        }

        tableHeightConstraint = tableScroll.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            // Toolbar
            prevBtn.topAnchor    .constraint(equalTo: cv.topAnchor,     constant: m),
            prevBtn.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: m),
            rangeCtrl.centerYAnchor .constraint(equalTo: prevBtn.centerYAnchor),
            rangeCtrl.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -m),
            nextBtn.centerYAnchor .constraint(equalTo: prevBtn.centerYAnchor),
            nextBtn.trailingAnchor.constraint(equalTo: rangeCtrl.leadingAnchor, constant: -12),
            dateLabel.centerYAnchor .constraint(equalTo: prevBtn.centerYAnchor),
            dateLabel.leadingAnchor .constraint(equalTo: prevBtn.trailingAnchor, constant: 8),
            dateLabel.trailingAnchor.constraint(equalTo: nextBtn.leadingAnchor,  constant: -8),

            // Zusammenfassung (rechts unter Toolbar)
            summaryLabel.topAnchor     .constraint(equalTo: prevBtn.bottomAnchor, constant: 8),
            summaryLabel.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -m),
            summaryLabel.leadingAnchor .constraint(equalTo: cv.leadingAnchor,  constant: m),

            // Solar-Graph
            solarLbl.topAnchor    .constraint(equalTo: summaryLabel.bottomAnchor, constant: 6),
            solarLbl.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: m),
            solarGraph.topAnchor     .constraint(equalTo: solarLbl.bottomAnchor, constant: 4),
            solarGraph.leadingAnchor .constraint(equalTo: cv.leadingAnchor,  constant: m),
            solarGraph.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -m),
            solarGraph.heightAnchor  .constraint(greaterThanOrEqualToConstant: 110),

            // Grid-Graph
            gridLbl.topAnchor    .constraint(equalTo: solarGraph.bottomAnchor, constant: 12),
            gridLbl.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: m),
            gridGraph.topAnchor     .constraint(equalTo: gridLbl.bottomAnchor, constant: 4),
            gridGraph.leadingAnchor .constraint(equalTo: cv.leadingAnchor,  constant: m),
            gridGraph.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -m),
            solarGraph.heightAnchor.constraint(equalTo: gridGraph.heightAnchor),

            // Wochentabelle (Höhe = 0 wenn ausgeblendet)
            tableScroll.topAnchor     .constraint(equalTo: gridGraph.bottomAnchor, constant: 12),
            tableScroll.leadingAnchor .constraint(equalTo: cv.leadingAnchor,  constant: m),
            tableScroll.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -m),
            tableScroll.bottomAnchor  .constraint(equalTo: cv.bottomAnchor,   constant: -m),
            tableHeightConstraint,
        ])
    }

    // MARK: Navigation & Reload

    @objc private func prevDay() {
        selectedDate = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate)!
        reload()
    }
    @objc private func nextDay() {
        let next = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate)!
        guard Calendar.current.startOfDay(for: next) <= Calendar.current.startOfDay(for: Date()) else { return }
        selectedDate = next; reload()
    }
    @objc private func rangeChanged() {
        rangeHours = [1, 6, 24, 168][rangeCtrl.selectedSegment]; reload()
    }

    private func reload() {
        let cal      = Calendar.current
        let dayStart = selectedDate
        let dayEnd   = cal.date(byAdding: .day, value: 1, to: dayStart)!
        let now      = Date()
        let to       = min(dayEnd, now)
        let from: Date
        switch rangeHours {
        case 1:   from = cal.date(byAdding: .hour, value:  -1, to: to)!
        case 6:   from = cal.date(byAdding: .hour, value:  -6, to: to)!
        case 168: from = cal.date(byAdding: .day,  value:  -6, to: dayStart)!
        default:  from = dayStart   // 24h = kompletter Tag
        }

        // Datums-Label
        let fmt = DateFormatter(); fmt.locale = Locale(identifier: "de_DE")
        if rangeHours == 168 {
            fmt.dateFormat = "dd. MMM"
            let toDay = cal.date(byAdding: .day, value: -1, to: dayEnd)!
            dateLabel.stringValue = "\(fmt.string(from: from)) – \(fmt.string(from: toDay))"
        } else {
            fmt.dateStyle = .full; fmt.timeStyle = .none
            dateLabel.stringValue = fmt.string(from: selectedDate)
        }

        // Graphen
        let data = DataStore.shared.query(from: from, to: to)
        solarGraph.history = data.solar
        gridGraph.history  = data.grid
        solarGraph.needsDisplay = true
        gridGraph.needsDisplay  = true

        // kWh-Zusammenfassung
        let sum  = DataStore.shared.sumWh(from: from, to: to)
        let sKWh = sum.solarWh >= 1000 ? String(format: "%.1f kWh", sum.solarWh/1000)
                                        : String(format: "%.0f Wh",  sum.solarWh)
        let gKWh = sum.gridWh  >= 1000 ? String(format: "%.1f kWh", sum.gridWh/1000)
                                        : String(format: "%.0f Wh",  sum.gridWh)
        summaryLabel.stringValue = "☀︎ \(sKWh) Ertrag  ·  ⚡ \(gKWh) Netzbezug"

        // Wochentabelle ein-/ausblenden
        let showTable = (rangeHours == 168)
        if showTable {
            weekRows = DataStore.shared.weeklyTotals(days: 7)
            tableView.reloadData()
            let rowH    = tableView.rowHeight + tableView.intercellSpacing.height
            let hdrH    = tableView.headerView?.frame.height ?? 22
            tableHeightConstraint.constant = hdrH + rowH * CGFloat(weekRows.count) + 4
        } else {
            tableHeightConstraint.constant = 0
        }
        tableScroll.isHidden = !showTable
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { weekRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = weekRows[row]
        let fmt = DateFormatter(); fmt.locale = Locale(identifier: "de_DE"); fmt.dateFormat = "E, dd. MMM"
        let wh2str: (Double) -> String = { wh in
            wh >= 1000 ? String(format: "%.2f kWh", wh/1000) : String(format: "%.0f Wh", wh)
        }
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "Datum":        text = fmt.string(from: r.date)
        case "☀︎  Solar":    text = wh2str(r.solarWh)
        case "⚡  Netzbezug": text = wh2str(r.gridWh)
        case "Σ  Gesamt":   text = wh2str(r.solarWh + r.gridWh)
        default: return nil
        }
        let cell = NSTextField(labelWithString: text)
        cell.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        return cell
    }

    // MARK: Helpers

    private func histLabel(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        f.textColor = .secondaryLabelColor; return f
    }

    func showCentered() {
        if refreshTimer == nil {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                guard let self, self.window?.isVisible == true,
                      Calendar.current.isDateInToday(self.selectedDate) else { return }
                self.reload()
            }
        }
        window?.center(); NSApp.activate(ignoringOtherApps: true); showWindow(nil)
    }
}

// MARK: - Solar-Graph

final class SolarGraphView: NSView {
    var history:  [(time: Date, watts: Int)] = []
    var accent:   NSColor = NSColor(red: 1.0, green: 0.55, blue: 0.0, alpha: 1.0)
    /// Callback für Scroll-Zoom im Verlauf-Fenster (deltaY: pos = rein, neg = raus)
    var onScroll: ((CGFloat) -> Void)?

    private func dyn(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    override func scrollWheel(with event: NSEvent) {
        if let cb = onScroll { cb(event.scrollingDeltaY) }
        else { super.scrollWheel(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()

        guard history.count >= 2 else {
            let s = "Sammle Daten…" as NSString
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
                                                    .foregroundColor: NSColor.tertiaryLabelColor]
            let sz = s.size(withAttributes: a)
            s.draw(at: CGPoint(x: (bounds.width-sz.width)/2,
                               y: (bounds.height-sz.height)/2), withAttributes: a)
            return
        }

        let display: [(time: Date, watts: Int)] = history.count > 600
            ? stride(from: 0, to: history.count, by: max(history.count/600, 1)).map { history[$0] }
            : history

        let maxW = max(display.map { $0.watts }.max() ?? 1, 1)
        let top  = ((maxW / 50) + 1) * 50
        let ml: CGFloat = 38, mr: CGFloat = 8, mt: CGFloat = 20, mb: CGFloat = 22
        let plot = CGRect(x: ml, y: mb, width: bounds.width-ml-mr, height: bounds.height-mt-mb)
        let subtle = dyn(light: NSColor(white: 0.55, alpha: 1), dark: NSColor(white: 0.55, alpha: 1))
        let xa: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
            .foregroundColor: subtle]

        // ── Y-Achse ──────────────────────────────────────────────────────────
        for lv in [0, top/2, top] {
            let y = plot.minY + plot.height * CGFloat(lv) / CGFloat(top)
            let g = NSBezierPath()
            g.move(to: CGPoint(x: plot.minX, y: y)); g.line(to: CGPoint(x: plot.maxX, y: y))
            NSColor.separatorColor.setStroke(); g.lineWidth = 0.5; g.stroke()
            let lbl = lv >= 1000 ? String(format: "%.0fk", Double(lv)/1000) : "\(lv)W"
            let sz = (lbl as NSString).size(withAttributes: xa)
            (lbl as NSString).draw(at: CGPoint(x: plot.minX-sz.width-4, y: y-sz.height/2),
                                   withAttributes: xa)
        }

        // ── Kurve ────────────────────────────────────────────────────────────
        let n = display.count
        func pt(_ i: Int) -> CGPoint {
            CGPoint(x: plot.minX + plot.width * CGFloat(i) / CGFloat(n-1),
                    y: plot.minY + plot.height * CGFloat(display[i].watts) / CGFloat(top))
        }
        let fill = NSBezierPath()
        fill.move(to: CGPoint(x: pt(0).x, y: plot.minY)); fill.line(to: pt(0))
        for i in 1..<n { fill.line(to: pt(i)) }
        fill.line(to: CGPoint(x: pt(n-1).x, y: plot.minY)); fill.close()
        accent.withAlphaComponent(0.15).setFill(); fill.fill()

        let line = NSBezierPath()
        line.move(to: pt(0)); for i in 1..<n { line.line(to: pt(i)) }
        accent.setStroke(); line.lineWidth = 1.5
        line.lineCapStyle = .round; line.lineJoinStyle = .round; line.stroke()

        // ── Aktueller Wert (oben links) ──────────────────────────────────────
        let curW   = display.last!.watts
        let curLbl = curW >= 1000 ? String(format: "%.2f kW", Double(curW)/1000) : "\(curW) W"
        (curLbl as NSString).draw(
            at: CGPoint(x: ml, y: bounds.height-mt),
            withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                             .foregroundColor: dyn(light: .black, dark: .white)])

        // ── X-Achse: zeitausgerichtete Ticks ─────────────────────────────────
        let first = display.first!.time
        let last  = display.last!.time
        let span  = max(last.timeIntervalSince(first), 1)
        let cal   = Calendar.current

        struct XTick { var date: Date; var label: String }
        var ticks: [XTick] = []

        if span >= 86400 * 2 {
            // Mehrtägig → tägliche Ticks an lokalem Mitternacht, Label = Wochentag
            let fmt = DateFormatter(); fmt.locale = Locale(identifier: "de_DE")
            fmt.dateFormat = "E"
            var t = cal.startOfDay(for: first)
            if t <= first { t = cal.date(byAdding: .day, value: 1, to: t)! }
            while t <= last {
                ticks.append(XTick(date: t, label: fmt.string(from: t)))
                t = cal.date(byAdding: .day, value: 1, to: t)!
            }
        } else {
            // Stunden/Minuten-Ticks (UTC-Rundung, für Stunden ausreichend genau)
            let (tickSecs, fmtStr): (TimeInterval, String)
            switch span {
            case ..<3_600:   (tickSecs, fmtStr) = (600,   "HH:mm")  // < 1 h : alle 10 min
            case ..<7_200:   (tickSecs, fmtStr) = (900,   "HH:mm")  // < 2 h : alle 15 min
            case ..<21_600:  (tickSecs, fmtStr) = (3_600, "HH:mm")  // < 6 h : stündlich
            default:         (tickSecs, fmtStr) = (7_200, "HH:mm")  // ≥ 6 h : alle 2 h
            }
            let fmt = DateFormatter(); fmt.locale = Locale(identifier: "de_DE")
            fmt.dateFormat = fmtStr
            var t = Date(timeIntervalSince1970:
                         ceil(first.timeIntervalSince1970 / tickSecs) * tickSecs)
            while t <= last {
                ticks.append(XTick(date: t, label: fmt.string(from: t)))
                t = Date(timeIntervalSince1970: t.timeIntervalSince1970 + tickSecs)
            }
        }

        // "jetzt" nur wenn letzter Datenpunkt < 5 min alt
        let showJetzt = -last.timeIntervalSinceNow < 300

        for tick in ticks {
            let frac = CGFloat(tick.date.timeIntervalSince(first) / span)
            let x = plot.minX + frac * plot.width
            let s  = tick.label as NSString
            let sz = s.size(withAttributes: xa)
            let rightClear: CGFloat = showJetzt ? 32 : 4
            guard x > plot.minX + sz.width/2 + 4,
                  x < plot.maxX - rightClear else { continue }
            // Tick-Strich
            let tp = NSBezierPath()
            tp.move(to: CGPoint(x: x, y: plot.minY))
            tp.line(to: CGPoint(x: x, y: plot.minY - 3))
            NSColor.separatorColor.setStroke(); tp.lineWidth = 0.5; tp.stroke()
            s.draw(at: CGPoint(x: x - sz.width/2, y: 1), withAttributes: xa)
        }
        if showJetzt {
            let s  = "jetzt" as NSString
            let sz = s.size(withAttributes: xa)
            s.draw(at: CGPoint(x: plot.maxX - sz.width/2, y: 1), withAttributes: xa)
        }
    }
}

// MARK: - Menüleisten-Controller

final class ZendureBarController: NSObject {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    // MQTT-Daten (alle Zendure-Geräte via Cloud Key)
    private var cloudKey:        String = ""
    private var meterIP:         String = ""
    private var mqttManager:     ZendureMQTTManager?
    private var deviceData:      [String: DeviceData] = [:]   // name → letzter Stand
    private var mqttStatus       = "disconnected"
    private var meterData:       ShellMeterData?
    private var solarHistory:       [(time: Date, watts: Int)] = []
    private var consumptionHistory: [(time: Date, watts: Int)] = []
    private var gridHistory:        [(time: Date, watts: Int)] = []
    private var meterTimer:      Timer?

    private var settingsController: SettingsWindowController?
    private var historyController:  HistoryWindowController?

    // Menüleisten-Anzeige: 0 = aktuelles Solar-W, 1 = Tagesertrag kWh, 2 = Tages-Netzbezug kWh
    private var statusMode = 0

    private let primaryColor = NSColor(name: nil) { app in
        app.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 1) : NSColor(white: 0, alpha: 1)
    }

    override init() {
        super.init()
        cloudKey = Prefs.loadCloudKey()
        meterIP  = Prefs.loadMeterIP()

        // Heutigen Tag aus der Datenbank vorladen – Graphen sind sofort gefüllt
        let stored = DataStore.shared.todayData()
        solarHistory = stored.solar
        gridHistory  = stored.grid

        statusItem.button?.title = "— W"
        statusItem.button?.font  = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        buildMenu()
        setupMQTT()
        startMeterPolling()

        if cloudKey.isEmpty { openSettings() }
    }

    // MARK: - MQTT

    private func setupMQTT() {
        mqttManager?.disconnect()
        mqttManager = nil
        deviceData  = [:]
        guard !cloudKey.isEmpty else { return }

        mqttStatus = "connecting"
        buildMenu()

        ZendureAPI.fetchDeviceList(cloudKey: cloudKey) { [weak self] creds, cloudDevices in
            guard let self else { return }
            guard let creds else {
                self.mqttStatus = "API-Fehler"; self.buildMenu()
                mqttLog("[Setup] API-Fehler"); return
            }
            mqttLog("[Setup] \(cloudDevices.count) Gerät(e), starte MQTT")
            let manager = ZendureMQTTManager(credentials: creds, devices: cloudDevices)
            manager.onStatus = { [weak self] status in
                DispatchQueue.main.async {
                    switch status {
                    case .connected:    self?.mqttStatus = "connected"
                    case .connecting:   self?.mqttStatus = "connecting"
                    case .disconnected: self?.mqttStatus = "disconnected"
                    case .error(let e): self?.mqttStatus = "error: \(e)"
                    }
                    self?.buildMenu()
                }
            }
            manager.onData = { [weak self] data in
                guard let self else { return }
                let isNew = self.deviceData[data.name] == nil
                self.deviceData[data.name] = data
                // Solar-History bei jedem Update aktualisieren
                let total = self.deviceData.values.reduce(0) { $0 + $1.solarPower }
                self.solarHistory.append((time: Date(), watts: total))
                if self.solarHistory.count > 2000 { self.solarHistory.removeFirst() }
                self.updateStatusButton()
                self.buildMenu()
                _ = isNew  // suppress warning
            }
            self.mqttManager = manager
        }
    }

    // MARK: - Smart Meter Polling (Shelly – bleibt HTTP)

    private func startMeterPolling() {
        meterTimer?.invalidate()
        guard !meterIP.isEmpty else { return }
        fetchMeter()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.fetchMeter()
        }
    }

    private func fetchMeter() {
        guard !meterIP.isEmpty, let url = URL(string: "http://\(meterIP)/rpc/EM.GetStatus?id=0") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard error == nil, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let m = ShellMeterData(
                totalPower: json["total_act_power"] as? Double ?? 0,
                phaseA:    json["a_act_power"] as? Double ?? 0,
                phaseB:    json["b_act_power"] as? Double ?? 0,
                phaseC:    json["c_act_power"] as? Double ?? 0,
                voltageA:  json["a_voltage"]   as? Double ?? 0,
                voltageB:  json["b_voltage"]   as? Double ?? 0,
                voltageC:  json["c_voltage"]   as? Double ?? 0)
            DispatchQueue.main.async {
                guard let self else { return }
                self.meterData = m
                // Verbrauch = was Geräte ins Hausnetz liefern + Netzbezug (immer ≥ 0)
                let homeFromDevices = self.deviceData.values.reduce(0) { $0 + $1.homeOutput }
                let gridImport      = max(0, m.totalPower)
                let consumption     = max(0, homeFromDevices + Int(gridImport.rounded()))
                self.consumptionHistory.append((time: Date(), watts: consumption))
                if self.consumptionHistory.count > 2000 { self.consumptionHistory.removeFirst() }
                let gridW = Int(gridImport.rounded())
                self.gridHistory.append((time: Date(), watts: gridW))
                if self.gridHistory.count > 2000 { self.gridHistory.removeFirst() }
                // In SQLite persistieren (throttled auf 1× / 10 s)
                let totalSolar = self.deviceData.values.reduce(0) { $0 + $1.solarPower }
                DataStore.shared.insert(solar: totalSolar, grid: gridW)
                self.buildMenu()
            }
        }.resume()
    }

    private func updateStatusButton() {
        switch statusMode {
        case 1:
            let s = DataStore.shared.sumWh(from: Calendar.current.startOfDay(for: Date()), to: Date())
            let wh = s.solarWh
            statusItem.button?.title = wh >= 1000
                ? String(format: "☀︎ %.1f kWh", wh/1000)
                : String(format: "☀︎ %.0f Wh",  wh)
        case 2:
            let s = DataStore.shared.sumWh(from: Calendar.current.startOfDay(for: Date()), to: Date())
            let wh = s.gridWh
            statusItem.button?.title = wh >= 1000
                ? String(format: "⚡ %.1f kWh", wh/1000)
                : String(format: "⚡ %.0f Wh",  wh)
        default:
            let total = deviceData.values.reduce(0) { $0 + $1.solarPower }
            statusItem.button?.title = total > 0 ? "\(total) W" : "— W"
        }
    }

    // MARK: - Menü

    private func buildMenu() {
        let menu  = NSMenu()
        let devs  = Array(deviceData.values)
            .sorted { $0.name < $1.name }   // konsistente Reihenfolge

        if devs.isEmpty {
            let txt = cloudKey.isEmpty ? "Kein Cloud Key konfiguriert" : "MQTT: \(mqttStatus)"
            menu.addItem(row("antenna.radiowaves.left.and.right", txt, ""))
        } else {
            // ── Gesamt ──────────────────────────────────────────────────
            let totalSolar = devs.reduce(0) { $0 + $1.solarPower }
            let totalBattD = devs.reduce(0) { $0 + $1.batteryDischarge }
            let totalBattC = devs.reduce(0) { $0 + $1.batteryCharge }
            menu.addItem(section("Gesamt"))
            menu.addItem(row("sun.max.fill", "Solar", watts(totalSolar)))

            if let m = meterData {
                let grid = m.totalPower
                let cons = Double(totalSolar + totalBattD - totalBattC) + max(0, grid)
                menu.addItem(row("house.fill", "Hausverbrauch", watts(Int(cons.rounded()))))
                if grid >= 0 { menu.addItem(row("powerplug.fill",   "Netzbezug",   wattsDbl(grid))) }
                else         { menu.addItem(row("arrow.up.to.line", "Einspeisung", wattsDbl(-grid))) }
            } else {
                let totalHome = devs.reduce(0) { $0 + $1.homeOutput }
                menu.addItem(row("house.fill", "Hausverbrauch", watts(totalHome)))
            }
            // ── Solar-Graph direkt unter den Gesamtwerten ────────────────
            menu.addItem(graphMenuItem(history: solarHistory))
            menu.addItem(.separator())

            // ── Je Gerät ─────────────────────────────────────────────────
            for d in devs {
                deviceItems(d).forEach { menu.addItem($0) }
                menu.addItem(.separator())
            }

            // ── MQTT-Status ───────────────────────────────────────────────
            let dot = mqttStatus == "connected" ? "●" : "○"
            menu.addItem(row("dot.radiowaves.left.and.right", "MQTT", "\(dot) \(mqttStatus)"))
            menu.addItem(.separator())

            // ── Smart Meter ───────────────────────────────────────────────
            if let m = meterData {
                menu.addItem(section("Smart Meter"))
                let lbl = m.totalPower >= 0 ? "Netzbezug" : "Einspeisung"
                menu.addItem(row("bolt.horizontal", lbl, wattsDbl(abs(m.totalPower))))
                for (name, pwr, volt) in [("Phase A", m.phaseA, m.voltageA),
                                           ("Phase B", m.phaseB, m.voltageB),
                                           ("Phase C", m.phaseC, m.voltageC)] where volt > 10 {
                    menu.addItem(row("circle.dotted", name,
                        "\(wattsDbl(pwr))  ·  \(String(format: "%.0f V", volt))"))
                }
                // Netzbezug-Graph in Grün
                menu.addItem(graphMenuItem(
                    history: gridHistory,
                    color: NSColor(red: 0.2, green: 0.75, blue: 0.3, alpha: 1.0)))
                menu.addItem(.separator())
            }
        }

        // Anzeige-Toggle (Menüleiste)
        let modeLabels = ["Aktuelles Solar (W)", "Tagesertrag Solar (kWh)", "Tages-Netzbezug (kWh)"]
        let nextMode   = (statusMode + 1) % 3
        let tm = NSMenuItem(title: "Anzeige: \(modeLabels[statusMode])",
                            action: #selector(cycleStatusMode), keyEquivalent: "")
        tm.target = self; menu.addItem(tm)
        menu.addItem(.separator())

        let h = NSMenuItem(title: "Verlauf…", action: #selector(openHistory), keyEquivalent: "h")
        h.target = self; menu.addItem(h)
        _ = nextMode
        let s = NSMenuItem(title: "Einstellungen…", action: #selector(openSettings), keyEquivalent: ",")
        s.target = self; menu.addItem(s)
        menu.addItem(NSMenuItem(title: "Beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func deviceItems(_ d: DeviceData) -> [NSMenuItem] {
        var items = [NSMenuItem]()
        items.append(section("Zendure \(d.name)"))

        // Solar
        if d.solarChannels.count > 1 {
            items.append(row("sun.max.fill", "Solar gesamt", watts(d.solarPower)))
            for (i, ch) in d.solarChannels.enumerated() {
                items.append(row("sun.min", "Kanal \(i+1)", watts(ch)))
            }
        } else {
            items.append(row("sun.max.fill", "Solar", watts(d.solarPower)))
        }

        // Hausverbrauch
        items.append(row("house.fill", "Hausverbrauch", watts(d.homeOutput)))

        // Netzbezug (nur wenn vorhanden)
        if d.gridInput > 0 {
            items.append(row("powerplug.fill", "Netzbezug", watts(d.gridInput)))
        }

        // Batterie
        let (batSym, batDetail) = batteryRow(d)
        items.append(row(batSym, "Batterie", batDetail))

        // Restzeit
        if d.remainSeconds > 0 && d.remainSeconds < 50_000 {
            let h = d.remainSeconds / 3600; let m = (d.remainSeconds % 3600) / 60
            items.append(row("clock", d.batteryCharge > 0 ? "Voll in" : "Leer in",
                String(format: "%d h %02d min", h, m)))
        }

        // Packs
        if !d.packs.isEmpty {
            for (i, p) in d.packs.enumerated() {
                let arrow  = p.state == 1 ? "↑" : p.state == 2 ? "↓" : "·"
                let label  = d.packs.count > 1 ? "Pack \(i+1)" : "Pack"
                let socStr = p.socLevel > 0   ? "\(p.socLevel) %" : "–"
                let tmpStr = p.tempCelsius > 0 ? String(format: "%.0f °C", p.tempCelsius) : "–"
                let volStr = p.voltageV > 0   ? String(format: "%.1f V", p.voltageV) : "–"
                items.append(row("square.stack", label, "\(socStr)  \(volStr)  \(tmpStr)  \(arrow)"))
            }
        }

        // Gerätetemperatur
        if d.deviceTempC > 0 {
            items.append(row("thermometer.medium", "Temperatur", String(format: "%.1f °C", d.deviceTempC)))
        }

        // WLAN-Signal
        if d.rssi != 0 {
            items.append(row("wifi", "WLAN", "\(d.rssi) dBm"))
        }

        return items
    }

    private func batteryRow(_ d: DeviceData) -> (String, String) {
        let soc = d.batteryLevel > 0 ? "\(d.batteryLevel) %" : "– %"
        if d.batteryCharge    > 0 { return ("battery.100percent.bolt", "\(soc)  ·  Laden \(watts(d.batteryCharge))") }
        if d.batteryDischarge > 0 { return ("battery.50percent",       "\(soc)  ·  Entladen \(watts(d.batteryDischarge))") }
        return ("battery.100percent", "\(soc)  ·  Standby")
    }

    private func graphMenuItem(history: [(time: Date, watts: Int)],
                               color: NSColor = NSColor(red: 1.0, green: 0.55, blue: 0.0, alpha: 1.0)) -> NSMenuItem {
        let item = NSMenuItem()
        let margin: CGFloat = 17   // fluchtet mit der Icon-Spalte der Menü-Zeilen
        let graphH: CGFloat = 110
        let totalH = graphH + 8    // 4 px Luft oben + unten

        let graph = SolarGraphView(frame: NSRect(x: margin, y: 4, width: 280, height: graphH))
        graph.autoresizingMask = [.width]
        graph.history = history
        graph.accent  = color

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: totalH))
        container.autoresizingMask = [.width]
        container.addSubview(graph)

        // rechten Rand symmetrisch halten wenn Fenster breiter wird
        graph.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            graph.leadingAnchor .constraint(equalTo: container.leadingAnchor,  constant:  margin),
            graph.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),
            graph.topAnchor     .constraint(equalTo: container.topAnchor,      constant: 4),
            graph.bottomAnchor  .constraint(equalTo: container.bottomAnchor,   constant: -4),
        ])

        item.view = container
        return item
    }

    // MARK: - Einstellungen

    @objc func openSettings() {
        let ctrl = SettingsWindowController(meterIP: meterIP, cloudKey: cloudKey)
        ctrl.onSave = { [weak self] newMeter, newKey in
            guard let self else { return }
            Prefs.save(meterIP: newMeter)
            Prefs.save(cloudKey: newKey)
            let keyChanged = self.cloudKey != newKey
            self.meterIP  = newMeter
            self.cloudKey = newKey
            self.meterData = nil
            self.statusItem.button?.title = "— W"
            if keyChanged { self.setupMQTT() }
            self.startMeterPolling()
            self.buildMenu()
        }
        ctrl.showCentered(); settingsController = ctrl
    }

    @objc func cycleStatusMode() {
        statusMode = (statusMode + 1) % 3
        updateStatusButton()
        buildMenu()
    }

    @objc func openHistory() {
        if historyController == nil { historyController = HistoryWindowController() }
        historyController?.showCentered()
    }

    // MARK: - Hilfsfunktionen

    private func section(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(); item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor]); return item
    }
    private func row(_ symbol: String, _ label: String, _ value: String) -> NSMenuItem {
        let item = NSMenuItem(); item.isEnabled = false
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            item.image = img.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
        }
        item.attributedTitle = NSAttributedString(
            string: "\(label.padding(toLength: 16, withPad: " ", startingAt: 0))\(value)",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
                         .foregroundColor: primaryColor]); return item
    }
    private func watts(_ w: Int) -> String {
        w >= 1000 ? String(format: "%.2f kW", Double(w)/1000) : "\(w) W"
    }
    private func wattsDbl(_ w: Double) -> String {
        w >= 1000 ? String(format: "%.2f kW", w/1000) : String(format: "%.0f W", w)
    }
}

// MARK: - App-Einstiegspunkt

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: ZendureBarController?
    func applicationDidFinishLaunching(_ n: Notification) { controller = ZendureBarController() }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
