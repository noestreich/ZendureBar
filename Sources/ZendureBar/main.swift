import AppKit
import Foundation
import CocoaMQTT

// MARK: - Modelle

struct Device: Codable {
    var name: String
    var ip: String
}

struct MQTTConfig: Codable {
    var appKey:   String
    var appSecret: String
    var deviceID: String
    var broker:   String

    var isValid: Bool { !appKey.isEmpty && !appSecret.isEmpty && !deviceID.isEmpty && !broker.isEmpty }
    var stateTopic: String { "\(appKey)/\(deviceID)/state" }
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

// MARK: - UserDefaults

enum Prefs {
    static let devicesKey    = "ZendureDevices"
    static let meterIPKey    = "ShellyMeterIP"
    static let mqttConfigKey = "ZendureMQTTConfig"

    static func loadDevices() -> [Device] {
        guard let d = UserDefaults.standard.data(forKey: devicesKey),
              let v = try? JSONDecoder().decode([Device].self, from: d) else { return [] }
        return v
    }
    static func save(devices: [Device]) {
        if let d = try? JSONEncoder().encode(devices) { UserDefaults.standard.set(d, forKey: devicesKey) }
    }
    static func loadMeterIP() -> String { UserDefaults.standard.string(forKey: meterIPKey) ?? "" }
    static func save(meterIP: String) { UserDefaults.standard.set(meterIP, forKey: meterIPKey) }

    static func loadMQTTConfig() -> MQTTConfig? {
        guard let d = UserDefaults.standard.data(forKey: mqttConfigKey),
              let v = try? JSONDecoder().decode(MQTTConfig.self, from: d) else { return nil }
        return v
    }
    static func save(mqttConfig: MQTTConfig?) {
        if let cfg = mqttConfig, let d = try? JSONEncoder().encode(cfg) {
            UserDefaults.standard.set(d, forKey: mqttConfigKey)
        } else {
            UserDefaults.standard.removeObject(forKey: mqttConfigKey)
        }
    }
}

// MARK: - MQTT Manager (Hyper 2000)

final class HyperMQTTManager: CocoaMQTTDelegate {

    enum Status { case connecting, connected, disconnected, error(String) }

    var onData:   ((DeviceData) -> Void)?
    var onStatus: ((Status) -> Void)?

    private var client: CocoaMQTT?
    private let config: MQTTConfig

    init(config: MQTTConfig) {
        self.config = config
        connect()
    }

    private func connect() {
        onStatus?(.connecting)
        let id = "ZendureBar-\(UUID().uuidString.prefix(8))"
        let mqtt = CocoaMQTT(clientID: id, host: config.broker, port: 1883)
        mqtt.username      = config.appKey
        mqtt.password      = config.appSecret
        mqtt.keepAlive     = 60
        mqtt.autoReconnect = true
        mqtt.autoReconnectTimeInterval = 10
        mqtt.delegate = self
        _ = mqtt.connect()
        client = mqtt
    }

    func disconnect() { client?.disconnect(); client = nil }

    // MARK: CocoaMQTTDelegate

    func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        if ack == .accept {
            onStatus?(.connected)
            mqtt.subscribe(config.stateTopic, qos: .qos0)
        } else {
            onStatus?(.error("MQTT Auth fehlgeschlagen (\(ack))"))
        }
    }

    func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16) {
        guard let str  = message.string,
              let data = str.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        let solar    = json["solarInputPower"]   as? Int ?? 0
        let home     = json["outputHomePower"]   as? Int ?? 0
        let battery  = json["electricLevel"]     as? Int ?? 0
        let packIn   = json["packInputPower"]    as? Int ?? 0
        let packOut  = json["outputPackPower"]   as? Int ?? 0
        let gridIn   = json["gridInputPower"]    as? Int ?? 0
        let remOut   = json["remainOutTime"]     as? Int ?? 0
        let remIn    = json["remainInputTime"]   as? Int ?? 0

        // Temperatur: Hyper 2000 kann rohe Celsius (z.B. 29.5) oder Zendure-kodiert (z.B. 3031) liefern
        let rawTmp   = json["hyperTmp"] as? Double ?? 0
        let tempC    = rawTmp > 200 ? (rawTmp - 2731) / 10.0 : rawTmp

        let channels = (1...4).compactMap { i -> Int? in
            let w = json["solarPower\(i)"] as? Int ?? 0; return w > 0 ? w : nil
        }

        let result = DeviceData(
            name: "Hyper 2000",
            solarPower: solar, solarChannels: channels,
            homeOutput: home, batteryLevel: battery,
            batteryCharge: packIn, batteryDischarge: packOut, gridInput: gridIn,
            remainSeconds: packOut > 0 ? remOut : (packIn > 0 ? remIn : 0),
            deviceTempC: tempC, packs: [], rssi: 0
        )
        DispatchQueue.main.async { [weak self] in self?.onData?(result) }
    }

    func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: Error?) {
        onStatus?(.disconnected)
    }

    // Pflicht-Stubs
    func mqtt(_ mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {}
    func mqtt(_ mqtt: CocoaMQTT, didPublishAck id: UInt16) {}
    func mqtt(_ mqtt: CocoaMQTT, didSubscribeTopics success: NSDictionary, failed: [String]) {}
    func mqtt(_ mqtt: CocoaMQTT, didUnsubscribeTopics topics: [String]) {}
    func mqttDidPing(_ mqtt: CocoaMQTT) {}
    func mqttDidReceivePong(_ mqtt: CocoaMQTT) {}
}

// MARK: - Einstellungen-Fenster

final class SettingsWindowController: NSWindowController {

    private var rows: [(name: NSTextField, ip: NSTextField)] = []
    private let outerStack = NSStackView()

    // Smart Meter
    private var meterField = NSTextField()

    // MQTT
    private var mqttKeyField      = NSTextField()
    private var mqttSecretField   = NSTextField()
    private var mqttDeviceField   = NSTextField()
    private var mqttBrokerField   = NSTextField()

    var onSave: ([Device], String, MQTTConfig?) -> Void = { _, _, _ in }

    init(devices: [Device], meterIP: String, mqttConfig: MQTTConfig?) {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Einstellungen"
        win.isReleasedWhenClosed = false
        super.init(window: win)
        buildUI(devices: devices, meterIP: meterIP, mqttConfig: mqttConfig)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI(devices: [Device], meterIP: String, mqttConfig: MQTTConfig?) {
        guard let cv = window?.contentView else { return }

        outerStack.orientation = .vertical
        outerStack.alignment   = .left
        outerStack.spacing     = 8
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(outerStack)

        // ── Zendure Geräte ───────────────────────────────────────────────
        outerStack.addArrangedSubview(sectionLabel("Zendure Geräte"))
        outerStack.addArrangedSubview(deviceHeaderRow())
        for d in devices { appendDeviceRow(name: d.name, ip: d.ip) }
        let addBtn = NSButton(title: "+ Gerät hinzufügen", target: self, action: #selector(addRowTapped))
        addBtn.bezelStyle = .rounded; addBtn.controlSize = .small
        outerStack.addArrangedSubview(addBtn)

        // ── Smart Meter ──────────────────────────────────────────────────
        outerStack.addArrangedSubview(divider())
        outerStack.addArrangedSubview(sectionLabel("Smart Meter (Shelly Pro 3EM)"))
        meterField = field(placeholder: "10.0.0.x  —  leer lassen wenn nicht vorhanden", value: meterIP)
        meterField.widthAnchor.constraint(equalToConstant: 360).isActive = true
        outerStack.addArrangedSubview(meterField)

        // ── MQTT / Hyper 2000 ────────────────────────────────────────────
        outerStack.addArrangedSubview(divider())
        outerStack.addArrangedSubview(sectionLabel("MQTT — Hyper 2000"))

        let hint = NSTextField(labelWithString: "App Key + Secret: zendure.com/developer → API beantragen")
        hint.font = NSFont.systemFont(ofSize: 10); hint.textColor = .tertiaryLabelColor
        outerStack.addArrangedSubview(hint)

        let mqttRows: [(String, NSTextField, String, String)] = [
            ("App Key",     mqttKeyField,    "appKey",            mqttConfig?.appKey    ?? ""),
            ("App Secret",  mqttSecretField, "appSecret",         mqttConfig?.appSecret ?? ""),
            ("Seriennummer",mqttDeviceField, "Hyper 2000 DeviceID", mqttConfig?.deviceID ?? ""),
            ("Broker",      mqttBrokerField, "mqtt-eu.zen-iot.com", mqttConfig?.broker  ?? "mqtt-eu.zen-iot.com"),
        ]
        for (labelText, textField, placeholder, value) in mqttRows {
            textField.stringValue      = value
            textField.placeholderString = placeholder
            let lbl = label(labelText)
            lbl.widthAnchor.constraint(equalToConstant: 100).isActive = true
            textField.widthAnchor.constraint(equalToConstant: 255).isActive = true
            let row = NSStackView(views: [lbl, textField]); row.spacing = 8
            outerStack.addArrangedSubview(row)
        }

        // ── Speichern ────────────────────────────────────────────────────
        let saveBtn = NSButton(title: "Speichern", target: self, action: #selector(saveTapped))
        saveBtn.bezelStyle = .rounded; saveBtn.keyEquivalent = "\r"
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottomBar = NSStackView(views: [spacer, saveBtn])
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            outerStack.topAnchor    .constraint(equalTo: cv.topAnchor,       constant:  20),
            outerStack.leadingAnchor.constraint(equalTo: cv.leadingAnchor,   constant:  20),
            outerStack.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            outerStack.bottomAnchor .constraint(lessThanOrEqualTo: bottomBar.topAnchor, constant: -12),
            bottomBar.leadingAnchor .constraint(equalTo: cv.leadingAnchor,   constant:  20),
            bottomBar.trailingAnchor.constraint(equalTo: cv.trailingAnchor,  constant: -20),
            bottomBar.bottomAnchor  .constraint(equalTo: cv.bottomAnchor,    constant: -16),
            bottomBar.heightAnchor  .constraint(equalToConstant: 28),
        ])

        updateWindowHeight()
    }

    private func deviceHeaderRow() -> NSStackView {
        let n = label("Name", bold: true); let i = label("IP-Adresse", bold: true)
        n.widthAnchor.constraint(equalToConstant: 180).isActive = true
        i.widthAnchor.constraint(equalToConstant: 140).isActive = true
        let ph = NSView(); ph.widthAnchor.constraint(equalToConstant: 28).isActive = true
        let s = NSStackView(views: [n, i, ph]); s.spacing = 8; return s
    }

    @objc private func addRowTapped() { appendDeviceRow(name: "", ip: ""); updateWindowHeight() }

    private func appendDeviceRow(name: String, ip: String) {
        let nf = field(placeholder: "Gerätename", value: name)
        let ipf = field(placeholder: "10.0.0.x", value: ip)
        nf.widthAnchor.constraint(equalToConstant: 180).isActive = true
        ipf.widthAnchor.constraint(equalToConstant: 140).isActive = true
        let del = NSButton(title: "−", target: self, action: #selector(deleteRow(_:)))
        del.bezelStyle = .rounded; del.widthAnchor.constraint(equalToConstant: 28).isActive = true
        let row = NSStackView(views: [nf, ipf, del]); row.spacing = 8; row.alignment = .centerY
        let insertIdx = 2 + rows.count
        outerStack.insertArrangedSubview(row, at: insertIdx)
        rows.append((name: nf, ip: ipf))
    }

    @objc private func deleteRow(_ sender: NSButton) {
        guard let row = sender.superview as? NSStackView else { return }
        rows.removeAll { row.arrangedSubviews.contains($0.name) }
        outerStack.removeArrangedSubview(row); row.removeFromSuperview()
        updateWindowHeight()
    }

    @objc private func saveTapped() {
        let devices = rows
            .map { Device(name: $0.name.stringValue.trimmingCharacters(in: .whitespaces),
                          ip:   $0.ip  .stringValue.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.name.isEmpty && !$0.ip.isEmpty }
        let ip = meterField.stringValue.trimmingCharacters(in: .whitespaces)

        let key    = mqttKeyField   .stringValue.trimmingCharacters(in: .whitespaces)
        let secret = mqttSecretField.stringValue.trimmingCharacters(in: .whitespaces)
        let devID  = mqttDeviceField.stringValue.trimmingCharacters(in: .whitespaces)
        let broker = mqttBrokerField.stringValue.trimmingCharacters(in: .whitespaces)
        let mqtt   = (!key.isEmpty && !secret.isEmpty && !devID.isEmpty)
            ? MQTTConfig(appKey: key, appSecret: secret, deviceID: devID,
                         broker: broker.isEmpty ? "mqtt-eu.zen-iot.com" : broker)
            : nil

        onSave(devices, ip, mqtt)
        window?.close()
    }

    private func updateWindowHeight() {
        guard let win = window else { return }
        let deviceRows = CGFloat(2 + rows.count + 1)   // header + rows + add-button
        let meterRows:  CGFloat = 2                    // label + field
        let mqttRows:   CGFloat = 6                    // label + hint + 4 fields
        let dividers:   CGFloat = 2
        let total = deviceRows + meterRows + mqttRows + dividers
        let rowH: CGFloat = 26; let sp: CGFloat = 8
        let newH = 20 + total * rowH + (total - 1) * sp + 12 + 28 + 16
        var f = win.frame; f.origin.y -= newH - f.height; f.size.height = newH
        win.setFrame(f, display: true, animate: false)
    }

    // Helpers
    private func divider() -> NSBox {
        let b = NSBox(); b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return b
    }
    private func sectionLabel(_ t: String) -> NSTextField {
        let f = NSTextField(labelWithString: t)
        f.font = NSFont.systemFont(ofSize: 11, weight: .semibold); f.textColor = .secondaryLabelColor; return f
    }
    private func field(placeholder: String, value: String) -> NSTextField {
        let f = NSTextField(string: value); f.placeholderString = placeholder; return f
    }
    private func label(_ t: String, bold: Bool = false) -> NSTextField {
        let f = NSTextField(labelWithString: t)
        f.font = NSFont.systemFont(ofSize: 12, weight: bold ? .semibold : .regular)
        f.textColor = .secondaryLabelColor; return f
    }
    func showCentered() {
        window?.center(); NSApp.activate(ignoringOtherApps: true); showWindow(nil)
    }
}

// MARK: - Solar-Graph

final class SolarGraphView: NSView {
    var history: [(time: Date, watts: Int)] = []
    private let accent = NSColor(red: 1.0, green: 0.55, blue: 0.0, alpha: 1.0)

    private func dyn(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()

        guard history.count >= 2 else {
            let s = "Sammle Daten…" as NSString
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
                                                    .foregroundColor: NSColor.tertiaryLabelColor]
            let sz = s.size(withAttributes: a)
            s.draw(at: CGPoint(x: (bounds.width-sz.width)/2, y: (bounds.height-sz.height)/2), withAttributes: a)
            return
        }

        let display: [(time: Date, watts: Int)] = history.count > 400
            ? stride(from: 0, to: history.count, by: max(history.count/400, 1)).map { history[$0] }
            : history

        let maxW = max(display.map { $0.watts }.max() ?? 1, 1)
        let top  = ((maxW / 50) + 1) * 50
        let ml: CGFloat = 36, mr: CGFloat = 8, mt: CGFloat = 20, mb: CGFloat = 18
        let plot = CGRect(x: ml, y: mb, width: bounds.width-ml-mr, height: bounds.height-mt-mb)
        let subtle = dyn(light: NSColor(white: 0.55, alpha: 1), dark: NSColor(white: 0.55, alpha: 1))

        for lv in [0, top/2, top] {
            let y = plot.minY + plot.height * CGFloat(lv) / CGFloat(top)
            let g = NSBezierPath(); g.move(to: CGPoint(x: plot.minX, y: y)); g.line(to: CGPoint(x: plot.maxX, y: y))
            NSColor.separatorColor.setStroke(); g.lineWidth = 0.5; g.stroke()
            let lbl = "\(lv) W" as NSString
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular), .foregroundColor: subtle]
            let sz = lbl.size(withAttributes: a)
            lbl.draw(at: CGPoint(x: plot.minX-sz.width-4, y: y-sz.height/2), withAttributes: a)
        }

        let n = display.count
        func pt(_ i: Int) -> CGPoint {
            CGPoint(x: plot.minX + plot.width*CGFloat(i)/CGFloat(n-1),
                    y: plot.minY + plot.height*CGFloat(display[i].watts)/CGFloat(top))
        }
        let fill = NSBezierPath()
        fill.move(to: CGPoint(x: pt(0).x, y: plot.minY)); fill.line(to: pt(0))
        for i in 1..<n { fill.line(to: pt(i)) }
        fill.line(to: CGPoint(x: pt(n-1).x, y: plot.minY)); fill.close()
        accent.withAlphaComponent(0.15).setFill(); fill.fill()

        let line = NSBezierPath()
        line.move(to: pt(0)); for i in 1..<n { line.line(to: pt(i)) }
        accent.setStroke(); line.lineWidth = 1.5; line.lineCapStyle = .round; line.lineJoinStyle = .round; line.stroke()

        ("\(display.last!.watts) W" as NSString).draw(
            at: CGPoint(x: ml, y: bounds.height-mt),
            withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                             .foregroundColor: dyn(light: .black, dark: .white)])

        let fmt = DateFormatter()
        let span = display.last!.time.timeIntervalSince(display.first!.time)
        fmt.dateFormat = span > 72000 ? "dd. HH:mm" : "HH:mm"
        let xPts: [(CGFloat, String)] = [
            (plot.minX,                  fmt.string(from: display.first!.time)),
            (plot.minX + plot.width/2,   fmt.string(from: display[n/2].time)),
            (plot.maxX,                  "jetzt")]
        let xa: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular), .foregroundColor: subtle]
        for (x, t) in xPts { let s = t as NSString; let sz = s.size(withAttributes: xa)
            s.draw(at: CGPoint(x: x-sz.width/2, y: 1), withAttributes: xa) }
    }
}

// MARK: - Menüleisten-Controller

final class ZendureBarController: NSObject {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var timer: Timer?

    // HTTP-Daten (SolarFlow-Geräte)
    private var devices:   [Device] = []
    private var meterIP:   String   = ""
    private var meterData: ShellMeterData?
    private var solarHistory: [(time: Date, watts: Int)] = []

    // MQTT-Daten (Hyper 2000)
    private var mqttConfig:  MQTTConfig?
    private var mqttManager: HyperMQTTManager?
    private var hyperData:   DeviceData?
    private var mqttStatus   = "disconnected"

    private var settingsController: SettingsWindowController?

    private let primaryColor = NSColor(name: nil) { app in
        app.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 1) : NSColor(white: 0, alpha: 1)
    }

    override init() {
        super.init()
        devices    = Prefs.loadDevices()
        meterIP    = Prefs.loadMeterIP()
        mqttConfig = Prefs.loadMQTTConfig()

        statusItem.button?.title = "— W"
        statusItem.button?.font  = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        buildMenu(zendure: [])
        setupMQTT()

        if devices.isEmpty && mqttConfig == nil { openSettings() } else { startPolling() }
    }

    // MARK: - MQTT

    private func setupMQTT() {
        mqttManager?.disconnect()
        mqttManager = nil
        guard let cfg = mqttConfig, cfg.isValid else { return }

        let manager = HyperMQTTManager(config: cfg)
        manager.onStatus = { [weak self] status in
            DispatchQueue.main.async {
                switch status {
                case .connected:    self?.mqttStatus = "connected"
                case .connecting:   self?.mqttStatus = "connecting"
                case .disconnected: self?.mqttStatus = "disconnected"
                case .error(let e): self?.mqttStatus = "error: \(e)"
                }
                self?.buildMenu(zendure: [])
            }
        }
        manager.onData = { [weak self] data in
            self?.hyperData = data
            // Menü nur neu bauen wenn auch Zendure-Daten schon vorhanden
            self?.buildMenu(zendure: self?.lastZendureResults ?? [])
        }
        mqttManager = manager
    }

    private var lastZendureResults: [DeviceData] = []

    // MARK: - Polling (HTTP)

    private func startPolling() {
        timer?.invalidate()
        fetchAll()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.fetchAll()
        }
    }

    private func fetchAll() {
        let group = DispatchGroup()
        var collected: [DeviceData] = []
        var newMeter:  ShellMeterData?
        let lock = NSLock()

        for device in devices {
            guard let url = URL(string: "http://\(device.ip)/properties/report") else { continue }
            group.enter()
            URLSession.shared.dataTask(with: url) { data, _, error in
                defer { group.leave() }
                guard error == nil, let data,
                      let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let props = json["properties"] as? [String: Any] else { return }

                let solar    = props["solarInputPower"]  as? Int ?? 0
                let home     = props["outputHomePower"]  as? Int ?? 0
                let battery  = props["electricLevel"]    as? Int ?? 0
                let packIn   = props["packInputPower"]   as? Int ?? 0
                let packOut  = props["outputPackPower"]  as? Int ?? 0
                let gridIn   = props["gridInputPower"]   as? Int ?? 0
                let remOut   = props["remainOutTime"]    as? Int ?? 0
                let remIn    = props["remainInputTime"]  as? Int ?? 0
                let hyperTmp = props["hyperTmp"]         as? Int ?? 0
                let rssi     = props["rssi"]             as? Int ?? 0

                let channels = (1...4).compactMap { i -> Int? in
                    let w = props["solarPower\(i)"] as? Int ?? 0; return w > 0 ? w : nil
                }
                var packs: [BatteryPack] = []
                if let arr = json["packData"] as? [[String: Any]] {
                    for p in arr {
                        let rawT = p["maxTemp"]  as? Int ?? 0; let rawV = p["totalVol"] as? Int ?? 0
                        packs.append(BatteryPack(socLevel: p["socLevel"] as? Int ?? 0,
                            tempCelsius: rawT > 2731 ? Double(rawT-2731)/10 : 0,
                            voltageV: Double(rawV)/100, state: p["state"] as? Int ?? 0))
                    }
                }
                let result = DeviceData(
                    name: device.name, solarPower: solar, solarChannels: channels,
                    homeOutput: home, batteryLevel: battery, batteryCharge: packIn,
                    batteryDischarge: packOut, gridInput: gridIn,
                    remainSeconds: packOut > 0 ? remOut : (packIn > 0 ? remIn : 0),
                    deviceTempC: hyperTmp > 2731 ? Double(hyperTmp-2731)/10 : 0,
                    packs: packs, rssi: rssi)
                lock.lock(); collected.append(result); lock.unlock()
            }.resume()
        }

        if !meterIP.isEmpty, let url = URL(string: "http://\(meterIP)/rpc/EM.GetStatus?id=0") {
            group.enter()
            URLSession.shared.dataTask(with: url) { data, _, error in
                defer { group.leave() }
                guard error == nil, let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                let m = ShellMeterData(
                    totalPower: json["total_act_power"] as? Double ?? 0,
                    phaseA: json["a_act_power"] as? Double ?? 0, phaseB: json["b_act_power"] as? Double ?? 0,
                    phaseC: json["c_act_power"] as? Double ?? 0, voltageA: json["a_voltage"] as? Double ?? 0,
                    voltageB: json["b_voltage"] as? Double ?? 0, voltageC: json["c_voltage"] as? Double ?? 0)
                lock.lock(); newMeter = m; lock.unlock()
            }.resume()
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let ordered = self.devices.compactMap { d in collected.first { $0.name == d.name } }
            if let m = newMeter { self.meterData = m }
            let total = ordered.reduce(0) { $0 + $1.solarPower }
            self.solarHistory.append((time: Date(), watts: total))
            self.lastZendureResults = ordered
            self.updateStatusButton(zendure: ordered)
            self.buildMenu(zendure: ordered)
        }
    }

    private func updateStatusButton(zendure: [DeviceData]) {
        let zTotal = zendure.reduce(0) { $0 + $1.solarPower }
        let hTotal = hyperData?.solarPower ?? 0
        let total  = zTotal + hTotal
        statusItem.button?.title = total > 0 ? "\(total) W" : "— W"
    }

    // MARK: - Menü aufbauen

    private func buildMenu(zendure: [DeviceData]) {
        let menu = NSMenu()
        let allDevices = zendure + (hyperData.map { [$0] } ?? [])

        if allDevices.isEmpty && mqttStatus != "connected" {
            menu.addItem(row("antenna.radiowaves.left.and.right",
                mqttConfig != nil ? "MQTT: \(mqttStatus)" : "Keine Geräte konfiguriert", ""))
        } else {
            // ── Gesamt ──────────────────────────────────────────────────
            let totalSolar = allDevices.reduce(0) { $0 + $1.solarPower }
            let totalBattD = allDevices.reduce(0) { $0 + $1.batteryDischarge }
            let totalBattC = allDevices.reduce(0) { $0 + $1.batteryCharge }

            menu.addItem(section("Gesamt"))
            menu.addItem(row("sun.max.fill", "Solar", watts(totalSolar)))

            if let m = meterData {
                let grid = m.totalPower
                let consumption = Double(totalSolar + totalBattD - totalBattC) + max(0, grid)
                menu.addItem(row("house.fill", "Hausverbrauch", watts(Int(consumption.rounded()))))
                if grid >= 0 { menu.addItem(row("powerplug.fill",   "Netzbezug",  wattsDbl(grid))) }
                else         { menu.addItem(row("arrow.up.to.line", "Einspeisung", wattsDbl(-grid))) }
            } else {
                let totalHome = allDevices.reduce(0) { $0 + $1.homeOutput }
                menu.addItem(row("house.fill", "Hausverbrauch", watts(totalHome)))
            }
            menu.addItem(.separator())

            // ── Je HTTP-Gerät (SolarFlow) ────────────────────────────────
            for d in zendure { deviceItems(d).forEach { menu.addItem($0) }; menu.addItem(.separator()) }

            // ── Hyper 2000 (MQTT) ────────────────────────────────────────
            if let h = hyperData {
                menu.addItem(section("Zendure \(h.name)"))
                if h.solarChannels.count > 1 {
                    menu.addItem(row("sun.max.fill", "Solar gesamt", watts(h.solarPower)))
                    for (i, ch) in h.solarChannels.enumerated() { menu.addItem(row("sun.min", "Kanal \(i+1)", watts(ch))) }
                } else {
                    menu.addItem(row("sun.max.fill", "Solar", watts(h.solarPower)))
                }
                if h.homeOutput > 0 { menu.addItem(row("house.fill", "Hausverbrauch", watts(h.homeOutput))) }
                if h.gridInput  > 0 { menu.addItem(row("powerplug.fill", "Netzbezug", watts(h.gridInput))) }
                let (batSym, batDetail) = batteryRow(h)
                menu.addItem(row(batSym, "Batterie", batDetail))
                if h.remainSeconds > 0 && h.remainSeconds < 50_000 {
                    let hh = h.remainSeconds/3600, mm = (h.remainSeconds%3600)/60
                    menu.addItem(row("clock", h.batteryCharge > 0 ? "Voll in" : "Leer in",
                        String(format: "%d h %02d min", hh, mm)))
                }
                if h.deviceTempC > 0 {
                    menu.addItem(row("thermometer.medium", "Temperatur", String(format: "%.1f °C", h.deviceTempC)))
                }
                let mqttIndicator = mqttStatus == "connected" ? "MQTT ●" : "MQTT ○"
                menu.addItem(row("dot.radiowaves.left.and.right", "Verbindung", mqttIndicator))
                menu.addItem(graphMenuItem())
                menu.addItem(.separator())
            } else if mqttConfig != nil {
                menu.addItem(section("Zendure Hyper 2000"))
                menu.addItem(row("dot.radiowaves.left.and.right", "MQTT", mqttStatus))
                menu.addItem(.separator())
            }

            // ── Smart Meter ───────────────────────────────────────────────
            if let m = meterData {
                menu.addItem(section("Smart Meter"))
                let lbl = m.totalPower >= 0 ? "Netzbezug" : "Einspeisung"
                menu.addItem(row("bolt.horizontal", lbl, wattsDbl(abs(m.totalPower))))
                for (name, pwr, volt) in [("Phase A", m.phaseA, m.voltageA),
                                           ("Phase B", m.phaseB, m.voltageB),
                                           ("Phase C", m.phaseC, m.voltageC)] where volt > 10 {
                    menu.addItem(row("circle.dotted", name, "\(wattsDbl(pwr))  ·  \(String(format: "%.0f V", volt))"))
                }
                menu.addItem(.separator())
            }
        }

        let s = NSMenuItem(title: "Einstellungen…", action: #selector(openSettings), keyEquivalent: ",")
        s.target = self; menu.addItem(s)
        menu.addItem(NSMenuItem(title: "Beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func deviceItems(_ d: DeviceData) -> [NSMenuItem] {
        var items = [NSMenuItem]()
        items.append(section("Zendure \(d.name)"))
        if d.solarChannels.count > 1 {
            items.append(row("sun.max.fill", "Solar gesamt", watts(d.solarPower)))
            for (i, ch) in d.solarChannels.enumerated() { items.append(row("sun.min", "Kanal \(i+1)", watts(ch))) }
        } else { items.append(row("sun.max.fill", "Solar", watts(d.solarPower))) }
        items.append(row("house.fill", "Hausverbrauch", watts(d.homeOutput)))
        if d.gridInput > 0 { items.append(row("powerplug.fill", "Netzbezug", watts(d.gridInput))) }
        let (batSym, batDetail) = batteryRow(d)
        items.append(row(batSym, "Batterie", batDetail))
        if d.remainSeconds > 0 && d.remainSeconds < 50_000 {
            let h = d.remainSeconds/3600, m = (d.remainSeconds%3600)/60
            items.append(row("clock", d.batteryCharge > 0 ? "Voll in" : "Leer in",
                String(format: "%d h %02d min", h, m)))
        }
        if d.packs.count > 1 {
            for (i, p) in d.packs.enumerated() {
                let s = p.state == 1 ? "↑" : p.state == 2 ? "↓" : "·"
                items.append(row("square.stack", "Pack \(i+1)",
                    "\(p.socLevel) %  \(String(format: "%.1f V", p.voltageV))  \(String(format: "%.0f °C", p.tempCelsius))  \(s)"))
            }
        }
        if d.deviceTempC > 0 { items.append(row("thermometer.medium", "Temperatur", String(format: "%.1f °C", d.deviceTempC))) }
        if d.rssi != 0 { items.append(row("wifi", "WLAN", "\(d.rssi) dBm")) }
        items.append(graphMenuItem())
        return items
    }

    private func batteryRow(_ d: DeviceData) -> (String, String) {
        if d.batteryCharge    > 0 { return ("battery.100percent.bolt", "\(d.batteryLevel) %  ·  Laden \(watts(d.batteryCharge))") }
        if d.batteryDischarge > 0 { return ("battery.50percent",       "\(d.batteryLevel) %  ·  Entladen \(watts(d.batteryDischarge))") }
        return ("battery.100percent", "\(d.batteryLevel) %  ·  Standby")
    }

    private func graphMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let view = SolarGraphView(frame: NSRect(x: 0, y: 0, width: 280, height: 114))
        view.autoresizingMask = [.width]; view.history = solarHistory
        item.view = view; return item
    }

    // MARK: - Einstellungen

    @objc func openSettings() {
        let ctrl = SettingsWindowController(devices: devices, meterIP: meterIP, mqttConfig: mqttConfig)
        ctrl.onSave = { [weak self] newDevices, newMeter, newMQTT in
            guard let self else { return }
            Prefs.save(devices: newDevices); Prefs.save(meterIP: newMeter); Prefs.save(mqttConfig: newMQTT)
            self.devices = newDevices; self.meterIP = newMeter; self.mqttConfig = newMQTT
            self.meterData = nil; self.hyperData = nil; self.solarHistory = []
            self.statusItem.button?.title = "— W"
            self.setupMQTT()
            self.buildMenu(zendure: [])
            self.startPolling()
        }
        ctrl.showCentered(); settingsController = ctrl
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
            item.image = img.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
        }
        item.attributedTitle = NSAttributedString(
            string: "\(label.padding(toLength: 16, withPad: " ", startingAt: 0))\(value)",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
                         .foregroundColor: primaryColor]); return item
    }
    private func watts(_ w: Int) -> String { w >= 1000 ? String(format: "%.2f kW", Double(w)/1000) : "\(w) W" }
    private func wattsDbl(_ w: Double) -> String { w >= 1000 ? String(format: "%.2f kW", w/1000) : String(format: "%.0f W", w) }
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
