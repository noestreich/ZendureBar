import AppKit
import Foundation

// MARK: - Modelle

struct Device: Codable {
    var name: String
    var ip: String
}

struct BatteryPack {
    let socLevel: Int
    let tempCelsius: Double
    let voltageV: Double
    let state: Int
}

struct DeviceData {
    let name: String
    let solarPower: Int
    let solarChannels: [Int]
    let homeOutput: Int
    let batteryLevel: Int
    let batteryCharge: Int
    let batteryDischarge: Int
    let gridInput: Int
    let remainSeconds: Int
    let deviceTempC: Double
    let packs: [BatteryPack]
    let rssi: Int
}

// MARK: - UserDefaults

enum Prefs {
    static let devicesKey = "ZendureDevices"

    static func loadDevices() -> [Device] {
        guard
            let data    = UserDefaults.standard.data(forKey: devicesKey),
            let devices = try? JSONDecoder().decode([Device].self, from: data)
        else { return [] }
        return devices
    }

    static func save(_ devices: [Device]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        UserDefaults.standard.set(data, forKey: devicesKey)
    }
}

// MARK: - Einstellungen-Fenster

final class SettingsWindowController: NSWindowController {

    // Jede Zeile als Tupel gespeichert – kein ScrollView, kein NSTableView
    private var rows: [(name: NSTextField, ip: NSTextField)] = []
    private let outerStack = NSStackView()   // vertikaler Haupt-Stack
    var onSave: ([Device]) -> Void = { _ in }

    init(devices: [Device]) {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Geräte konfigurieren"
        win.isReleasedWhenClosed = false
        super.init(window: win)
        buildUI(devices: devices)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI(devices: [Device]) {
        guard let cv = window?.contentView else { return }

        // Haupt-Stack: wächst nach unten mit jeder neuen Zeile
        outerStack.orientation  = .vertical
        outerStack.alignment    = .left
        outerStack.spacing      = 8
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(outerStack)

        // Spaltenköpfe
        outerStack.addArrangedSubview(headerRow())

        // Gerätezeilen
        for d in devices { appendRow(name: d.name, ip: d.ip) }

        // Untere Button-Leiste: fest am unteren Fensterrand
        let addBtn  = NSButton(title: "+ Gerät hinzufügen", target: self, action: #selector(addRowTapped))
        addBtn.bezelStyle = .rounded
        let saveBtn = NSButton(title: "Speichern", target: self, action: #selector(saveTapped))
        saveBtn.bezelStyle    = .rounded
        saveBtn.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let bottomBar = NSStackView(views: [addBtn, spacer, saveBtn])
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            // Haupt-Stack: oben links, volle Breite
            outerStack.topAnchor    .constraint(equalTo: cv.topAnchor,      constant:  20),
            outerStack.leadingAnchor.constraint(equalTo: cv.leadingAnchor,  constant:  20),
            outerStack.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),

            // Bottom-Bar: fest am Boden
            bottomBar.leadingAnchor .constraint(equalTo: cv.leadingAnchor,  constant:  20),
            bottomBar.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            bottomBar.bottomAnchor  .constraint(equalTo: cv.bottomAnchor,   constant: -16),
            bottomBar.heightAnchor  .constraint(equalToConstant: 28),

            // Stack darf die Bottom-Bar nicht überlappen
            outerStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomBar.topAnchor, constant: -12),
        ])

        updateWindowHeight()
    }

    // Spaltenköpfe als eigene Zeile
    private func headerRow() -> NSStackView {
        let n = label("Name",       bold: true)
        let i = label("IP-Adresse", bold: true)
        n.widthAnchor.constraint(equalToConstant: 180).isActive = true
        i.widthAnchor.constraint(equalToConstant: 140).isActive = true
        let ph = NSView()
        ph.widthAnchor.constraint(equalToConstant: 28).isActive = true
        let s = NSStackView(views: [n, i, ph])
        s.spacing = 8
        return s
    }

    @objc private func addRowTapped() {
        appendRow(name: "", ip: "")
        updateWindowHeight()
    }

    private func appendRow(name: String, ip: String) {
        let nameField = field(placeholder: "Gerätename", value: name)
        let ipField   = field(placeholder: "10.0.0.x",  value: ip)
        nameField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        ipField  .widthAnchor.constraint(equalToConstant: 140).isActive = true

        let delBtn = NSButton(title: "−", target: self, action: #selector(deleteRow(_:)))
        delBtn.bezelStyle  = .rounded
        delBtn.controlSize = .regular
        delBtn.widthAnchor.constraint(equalToConstant: 28).isActive = true

        let row = NSStackView(views: [nameField, ipField, delBtn])
        row.spacing   = 8
        row.alignment = .centerY

        rows.append((name: nameField, ip: ipField))
        outerStack.addArrangedSubview(row)
    }

    @objc private func deleteRow(_ sender: NSButton) {
        guard let row = sender.superview as? NSStackView else { return }
        // Passenden rows-Eintrag per Referenz finden
        rows.removeAll { outerStack.arrangedSubviews.contains(row) && row.arrangedSubviews.contains($0.name) }
        outerStack.removeArrangedSubview(row)
        row.removeFromSuperview()
        updateWindowHeight()
    }

    @objc private func saveTapped() {
        let devices = rows
            .map { Device(name: $0.name.stringValue.trimmingCharacters(in: .whitespaces),
                          ip:   $0.ip  .stringValue.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.name.isEmpty && !$0.ip.isEmpty }
        onSave(devices)
        window?.close()
    }

    /// Fensterhöhe dynamisch an Zeilenanzahl anpassen
    private func updateWindowHeight() {
        guard let win = window else { return }
        let rowCount  = CGFloat(rows.count + 1)   // +1 für Header
        let rowHeight: CGFloat = 28
        let spacing:   CGFloat = 8
        let topPad:    CGFloat = 20
        let bottomPad: CGFloat = 16 + 28 + 12     // Button-Bar + Abstand
        let newH = topPad + rowCount * rowHeight + (rowCount - 1) * spacing + bottomPad + 12
        var frame = win.frame
        let delta = newH - frame.height
        frame.origin.y -= delta
        frame.size.height = newH
        win.setFrame(frame, display: true, animate: false)
    }

    private func field(placeholder: String, value: String) -> NSTextField {
        let f = NSTextField(string: value)
        f.placeholderString = placeholder
        return f
    }

    private func label(_ text: String, bold: Bool = false) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = NSFont.systemFont(ofSize: 12, weight: bold ? .semibold : .regular)
        f.textColor = .secondaryLabelColor
        return f
    }

    func showCentered() {
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
    }
}

// MARK: - Solar-Graph

final class SolarGraphView: NSView {

    /// Alle Messpunkte seit App-Start – keine Begrenzung
    var history: [(time: Date, watts: Int)] = []

    private let accent = NSColor(red: 1.0, green: 0.55, blue: 0.0, alpha: 1.0)

    private func dynamicColor(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()

        guard history.count >= 2 else {
            let s = "Sammle Daten…" as NSString
            let a: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
            let sz = s.size(withAttributes: a)
            s.draw(at: CGPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2),
                   withAttributes: a)
            return
        }

        // Für Performance: auf max. 400 Punkte herunterskalieren
        let display: [(time: Date, watts: Int)]
        if history.count > 400 {
            let step = history.count / 400
            display = stride(from: 0, to: history.count, by: max(step, 1)).map { history[$0] }
        } else {
            display = history
        }

        let maxW   = max(display.map { $0.watts }.max() ?? 1, 1)
        let topVal = ((maxW / 50) + 1) * 50
        let ml: CGFloat = 36, mr: CGFloat = 8, mt: CGFloat = 20, mb: CGFloat = 18
        let plot = CGRect(x: ml, y: mb,
                          width: bounds.width - ml - mr,
                          height: bounds.height - mt - mb)

        let subtleColor = dynamicColor(light: NSColor(white: 0.55, alpha: 1),
                                       dark:  NSColor(white: 0.55, alpha: 1))

        // Gitterlinien + Y-Achse
        for level in [0, topVal / 2, topVal] {
            let y = plot.minY + plot.height * CGFloat(level) / CGFloat(topVal)
            let grid = NSBezierPath()
            grid.move(to: CGPoint(x: plot.minX, y: y))
            grid.line(to: CGPoint(x: plot.maxX, y: y))
            NSColor.separatorColor.setStroke()
            grid.lineWidth = 0.5
            grid.stroke()

            let lbl = "\(level) W" as NSString
            let a: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
                .foregroundColor: subtleColor
            ]
            let sz = lbl.size(withAttributes: a)
            lbl.draw(at: CGPoint(x: plot.minX - sz.width - 4, y: y - sz.height / 2), withAttributes: a)
        }

        // Koordinaten
        let n = display.count
        func pt(_ i: Int) -> CGPoint {
            CGPoint(
                x: plot.minX + plot.width  * CGFloat(i) / CGFloat(n - 1),
                y: plot.minY + plot.height * CGFloat(display[i].watts) / CGFloat(topVal)
            )
        }

        // Gefüllte Fläche
        let fill = NSBezierPath()
        fill.move(to: CGPoint(x: pt(0).x, y: plot.minY))
        fill.line(to: pt(0))
        for i in 1 ..< n { fill.line(to: pt(i)) }
        fill.line(to: CGPoint(x: pt(n - 1).x, y: plot.minY))
        fill.close()
        accent.withAlphaComponent(0.15).setFill()
        fill.fill()

        // Linie
        let line = NSBezierPath()
        line.move(to: pt(0))
        for i in 1 ..< n { line.line(to: pt(i)) }
        accent.setStroke()
        line.lineWidth = 1.5
        line.lineCapStyle  = .round
        line.lineJoinStyle = .round
        line.stroke()

        // Aktueller Wert oben links
        let labelColor = dynamicColor(light: .black, dark: .white)
        let cur = "\(display.last!.watts) W" as NSString
        cur.draw(at: CGPoint(x: ml, y: bounds.height - mt),
                 withAttributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: labelColor
                 ])

        // X-Achse: Start / Mitte / Jetzt
        let fmt = DateFormatter()
        // Format je nach Zeitspanne
        let span = display.last!.time.timeIntervalSince(display.first!.time)
        fmt.dateFormat = span > 3600 * 20 ? "dd. HH:mm" : "HH:mm"

        let xPoints: [(CGFloat, String)] = [
            (plot.minX,                     fmt.string(from: display.first!.time)),
            (plot.minX + plot.width / 2,    fmt.string(from: display[n / 2].time)),
            (plot.maxX,                     "jetzt"),
        ]
        let xAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
            .foregroundColor: subtleColor
        ]
        for (x, text) in xPoints {
            let s = text as NSString
            let sz = s.size(withAttributes: xAttrs)
            s.draw(at: CGPoint(x: x - sz.width / 2, y: 1), withAttributes: xAttrs)
        }
    }
}

// MARK: - Menüleisten-Controller

final class ZendureBarController: NSObject {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var timer: Timer?
    private var devices: [Device] = []

    /// Unbegrenzte History seit App-Start
    private var solarHistory: [(time: Date, watts: Int)] = []

    private var settingsController: SettingsWindowController?

    private let primaryColor = NSColor(name: nil) { app in
        app.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 1) : NSColor(white: 0, alpha: 1)
    }

    override init() {
        super.init()
        devices = Prefs.loadDevices()

        statusItem.button?.title = "— W"
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.systemFontSize, weight: .regular)

        buildMenu(results: [])

        if devices.isEmpty {
            openSettings()
        } else {
            startPolling()
        }
    }

    // MARK: - Polling

    private func startPolling() {
        timer?.invalidate()
        fetchAll()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.fetchAll()
        }
    }

    private func fetchAll() {
        guard !devices.isEmpty else { return }
        let group = DispatchGroup()
        var collected: [DeviceData] = []
        let lock = NSLock()

        for device in devices {
            guard let url = URL(string: "http://\(device.ip)/properties/report") else { continue }
            group.enter()

            URLSession.shared.dataTask(with: url) { data, _, error in
                defer { group.leave() }
                guard error == nil,
                      let data,
                      let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let props = json["properties"] as? [String: Any]
                else { return }

                let solar     = props["solarInputPower"]  as? Int ?? 0
                let home      = props["outputHomePower"]  as? Int ?? 0
                let battery   = props["electricLevel"]    as? Int ?? 0
                let packIn    = props["packInputPower"]   as? Int ?? 0
                let packOut   = props["outputPackPower"]  as? Int ?? 0
                let gridIn    = props["gridInputPower"]   as? Int ?? 0
                let remainOut = props["remainOutTime"]    as? Int ?? 0
                let remainIn  = props["remainInputTime"]  as? Int ?? 0
                let hyperTmp  = props["hyperTmp"]         as? Int ?? 0
                let rssi      = props["rssi"]             as? Int ?? 0

                let channels = (1...4).compactMap { i -> Int? in
                    let w = props["solarPower\(i)"] as? Int ?? 0; return w > 0 ? w : nil
                }
                var packs: [BatteryPack] = []
                if let arr = json["packData"] as? [[String: Any]] {
                    for p in arr {
                        let rawT = p["maxTemp"]  as? Int ?? 0
                        let rawV = p["totalVol"] as? Int ?? 0
                        packs.append(BatteryPack(
                            socLevel:    p["socLevel"] as? Int ?? 0,
                            tempCelsius: rawT > 2731 ? Double(rawT - 2731) / 10.0 : 0,
                            voltageV:    Double(rawV) / 100.0,
                            state:       p["state"] as? Int ?? 0
                        ))
                    }
                }
                let result = DeviceData(
                    name: device.name, solarPower: solar, solarChannels: channels,
                    homeOutput: home, batteryLevel: battery, batteryCharge: packIn,
                    batteryDischarge: packOut, gridInput: gridIn,
                    remainSeconds: packOut > 0 ? remainOut : (packIn > 0 ? remainIn : 0),
                    deviceTempC: hyperTmp > 2731 ? Double(hyperTmp - 2731) / 10.0 : 0,
                    packs: packs, rssi: rssi
                )
                lock.lock(); collected.append(result); lock.unlock()
            }.resume()
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let ordered = self.devices.compactMap { d in collected.first { $0.name == d.name } }
            let total   = ordered.reduce(0) { $0 + $1.solarPower }

            // History unbegrenzt anwachsen lassen
            self.solarHistory.append((time: Date(), watts: total))

            self.statusItem.button?.title = total > 0 ? "\(total) W" : "— W"
            self.buildMenu(results: ordered)
        }
    }

    // MARK: - Menü

    private func buildMenu(results: [DeviceData]) {
        let menu = NSMenu()

        if devices.isEmpty {
            menu.addItem(row("antenna.radiowaves.left.and.right", "Keine Geräte konfiguriert", ""))
        } else if results.isEmpty {
            menu.addItem(row("antenna.radiowaves.left.and.right", "Verbinde…", ""))
        } else {
            let total     = results.reduce(0) { $0 + $1.solarPower }
            let totalHome = results.reduce(0) { $0 + $1.homeOutput }
            let totalGrid = results.reduce(0) { $0 + $1.gridInput }

            menu.addItem(section("Gesamt"))
            menu.addItem(row("sun.max.fill",  "Solar",          watts(total)))
            menu.addItem(row("house.fill",    "Hausverbrauch",  watts(totalHome)))
            if totalGrid > 0 {
                menu.addItem(row("powerplug.fill", "Netzbezug", watts(totalGrid)))
            }
            menu.addItem(.separator())

            for d in results {
                menu.addItem(section("Zendure \(d.name)"))

                if d.solarChannels.count > 1 {
                    menu.addItem(row("sun.max.fill", "Solar gesamt", watts(d.solarPower)))
                    for (i, ch) in d.solarChannels.enumerated() {
                        menu.addItem(row("sun.min", "Kanal \(i + 1)", watts(ch)))
                    }
                } else {
                    menu.addItem(row("sun.max.fill", "Solar", watts(d.solarPower)))
                }
                menu.addItem(row("house.fill", "Hausverbrauch", watts(d.homeOutput)))
                if d.gridInput > 0 {
                    menu.addItem(row("powerplug.fill", "Netzbezug", watts(d.gridInput)))
                }

                let (batSymbol, batDetail): (String, String) = {
                    if d.batteryCharge > 0 {
                        return ("battery.100percent.bolt",
                                "\(d.batteryLevel) %  ·  Laden \(watts(d.batteryCharge))")
                    } else if d.batteryDischarge > 0 {
                        return ("battery.50percent",
                                "\(d.batteryLevel) %  ·  Entladen \(watts(d.batteryDischarge))")
                    }
                    return ("battery.100percent", "\(d.batteryLevel) %  ·  Standby")
                }()
                menu.addItem(row(batSymbol, "Batterie", batDetail))

                if d.remainSeconds > 0 && d.remainSeconds < 50_000 {
                    let h = d.remainSeconds / 3600, m = (d.remainSeconds % 3600) / 60
                    menu.addItem(row("clock",
                        d.batteryCharge > 0 ? "Voll in" : "Leer in",
                        String(format: "%d h %02d min", h, m)))
                }
                if d.packs.count > 1 {
                    for (i, p) in d.packs.enumerated() {
                        let s = p.state == 1 ? "↑" : p.state == 2 ? "↓" : "·"
                        menu.addItem(row("square.stack", "Pack \(i + 1)",
                            "\(p.socLevel) %  \(String(format: "%.1f V", p.voltageV))  \(String(format: "%.0f °C", p.tempCelsius))  \(s)"))
                    }
                }
                if d.deviceTempC > 0 {
                    menu.addItem(row("thermometer.medium", "Temperatur",
                        String(format: "%.1f °C", d.deviceTempC)))
                }
                if d.rssi != 0 {
                    menu.addItem(row("wifi", "WLAN", "\(d.rssi) dBm"))
                }

                menu.addItem(graphMenuItem())
                menu.addItem(.separator())
            }
        }

        let settingsItem = NSMenuItem(title: "Einstellungen…",
                                      action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem(title: "Beenden",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
    }

    // MARK: - Graph

    private func graphMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let view = SolarGraphView(frame: NSRect(x: 0, y: 0, width: 280, height: 114))
        view.autoresizingMask = [.width]
        view.history = solarHistory
        item.view = view
        return item
    }

    // MARK: - Einstellungen

    @objc func openSettings() {
        let controller = SettingsWindowController(devices: devices)
        controller.onSave = { [weak self] newDevices in
            guard let self else { return }
            Prefs.save(newDevices)
            self.devices = newDevices
            self.solarHistory = []          // History zurücksetzen nach Geräteänderung
            self.statusItem.button?.title = "— W"
            self.buildMenu(results: [])
            self.startPolling()
        }
        controller.showCentered()
        settingsController = controller
    }

    // MARK: - Hilfsfunktionen

    private func section(_ title: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        return item
    }

    private func row(_ symbol: String, _ label: String, _ value: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            item.image = img.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
        }
        let padded = label.padding(toLength: 16, withPad: " ", startingAt: 0)
        item.attributedTitle = NSAttributedString(
            string: "\(padded)\(value)",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: primaryColor
            ])
        return item
    }

    private func watts(_ w: Int) -> String {
        w >= 1000 ? String(format: "%.2f kW", Double(w) / 1000.0) : "\(w) W"
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
