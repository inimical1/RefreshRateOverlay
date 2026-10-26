import Carbon.HIToolbox
import Cocoa
import QuartzCore
import UniformTypeIdentifiers

private let originKeyRefresh = "overlayOrigin"
private let originKeyFPS = "fpsOrigin"
private let visibleKeyRefresh = "overlayVisible"
private let visibleKeyFPS = "fpsVisible"
private let debugMode = ProcessInfo.processInfo.environment["RRO_DEBUG"] == "1"

private weak var appDelegateShared: AppDelegate?

extension Notification.Name {
    static let displayModeChanged = Notification.Name("rro.displayModeChanged")
}

// MARK: - Sparkline

final class SparklineView: NSView {
    var values: [Double] = [] {
        didSet { needsDisplay = true }
    }
    var maxValue: Double = 60 {
        didSet { needsDisplay = true }
    }
    private let maxSamples = 36

    override func draw(_ dirtyRect: NSRect) {
        guard !values.isEmpty, bounds.width > 0, bounds.height > 0 else { return }

        let barWidth = bounds.width / CGFloat(maxSamples)
        let ceiling = Swift.max(1.0, maxValue)
        let color = NSColor.systemGreen.withAlphaComponent(0.85)
        color.setFill()

        let shown = values.suffix(maxSamples)
        for (index, value) in shown.enumerated() {
            let fraction = CGFloat(Swift.min(value / ceiling, 1.0))
            let height = Swift.max(1, bounds.height * fraction)
            let x = bounds.width - CGFloat(shown.count - index) * barWidth
            let rect = NSRect(x: x, y: 0, width: Swift.max(1, barWidth - 1.5), height: height)
            rect.fill()
        }
    }
}

// MARK: - Base meter view

class MeterView: NSView {
    let effect = NSVisualEffectView()
    let valueLabel = NSTextField(labelWithString: "—")
    let detailLabel = NSTextField(labelWithString: "")
    private let stack = NSStackView()

    private var link: CADisplayLink?
    private var samples: [CFTimeInterval] = []
    private var lastRenderTime: CFTimeInterval = 0
    private var lastTickTime: CFTimeInterval = 0
    private var lastDebugTime: CFTimeInterval = 0
    private var lastSetRate = 0
    private var tickCount: UInt64 = 0
    private var dragWindowOrigin = NSPoint.zero
    private var dragMouseOrigin = NSPoint.zero

    private(set) var isRunning = false
    private(set) var currentValue: Double = 0

    var accessoryViews: [NSView] { [] }
    var displayName: String { "Meter" }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Called by subclasses once their own properties exist.
    func build() {
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        valueLabel.textColor = .labelColor
        valueLabel.alignment = .center

        detailLabel.font = .systemFont(ofSize: 10, weight: .medium)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(valueLabel)
        stack.addArrangedSubview(detailLabel)
        for view in accessoryViews {
            stack.addArrangedSubview(view)
        }
        stack.setCustomSpacing(6, after: detailLabel)
        effect.addSubview(stack)

        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),

            stack.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            stack.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: effect.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: effect.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(greaterThanOrEqualTo: effect.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: effect.bottomAnchor, constant: -6),
        ])
    }

    // MARK: Measuring

    func start() {
        stop()
        reset()
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 1, maximum: 240, preferred: 240)
        link.add(to: .main, forMode: .common)
        self.link = link
        isRunning = true
        lastSetRate = setRate()
        NSLog("%@: measuring (display max %d Hz)", displayName, lastSetRate)
        detailLabel.stringValue = detailText()
    }

    func stop() {
        link?.invalidate()
        link = nil
        isRunning = false
    }

    func reset() {
        samples.removeAll(keepingCapacity: true)
        currentValue = 0
        lastTickTime = 0
        tickCount = 0
    }

    /// Subclasses turn the sample buffer into a number.
    func computeValue(_ samples: [CFTimeInterval]) -> Double { 0 }

    /// Big text.
    func formatted(_ value: Double) -> String { String(format: "%.0f", value) }

    /// Small text.
    func detailText() -> String { "" }

    /// Called after every UI refresh.
    func afterRender(_ value: Double) {}

    @objc private func step(_ link: CADisplayLink) {
        samples.append(link.timestamp)
        lastTickTime = link.timestamp
        tickCount &+= 1

        // Sliding one-second window.
        while samples.count > 2, link.timestamp - samples[0] > 1.0 {
            samples.removeFirst()
        }

        currentValue = computeValue(samples)

        if link.timestamp - lastRenderTime > 0.1 {
            lastRenderTime = link.timestamp
            render()
        }

        if debugMode, link.timestamp - lastDebugTime > 1.0 {
            lastDebugTime = link.timestamp
            NSLog("%@: value %.2f (%@) frames=%llu", displayName, currentValue, formatted(currentValue), tickCount)
        }
    }

    private func render() {
        valueLabel.stringValue = formatted(currentValue)
        detailLabel.stringValue = detailText()
        afterRender(currentValue)
    }

    /// Keeps the meter alive across mode changes and display link hiccups.
    func checkHealth() {
        guard isRunning else { return }
        let now = CACurrentMediaTime()
        let stale = lastTickTime > 0 && now - lastTickTime > 1.0
        let modeChanged = setRate() != lastSetRate
        if stale || modeChanged {
            NSLog("%@: restarting (stale=%d, modeChanged=%d)", displayName, stale ? 1 : 0, modeChanged ? 1 : 0)
            start()
        }
    }

    func setRate() -> Int {
        window?.screen?.maximumFramesPerSecond
            ?? NSScreen.main?.maximumFramesPerSecond
            ?? 0
    }

    // MARK: Events

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragWindowOrigin = window.frame.origin
        dragMouseOrigin = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let now = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(
            x: dragWindowOrigin.x + (now.x - dragMouseOrigin.x),
            y: dragWindowOrigin.y + (now.y - dragMouseOrigin.y)
        ))
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()

        let fps = NSMenuItem(title: "FPS Meter", action: #selector(AppDelegate.toggleFPS), keyEquivalent: "")
        fps.target = appDelegateShared
        menu.addItem(fps)

        let refresh = NSMenuItem(title: "Refresh Rate", action: #selector(AppDelegate.toggleRefresh), keyEquivalent: "")
        refresh.target = appDelegateShared
        menu.addItem(refresh)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Refresh Rate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    deinit {
        stop()
    }
}

// MARK: - Refresh rate meter

final class RefreshMeterView: MeterView {
    private var smoothed: Double = 0
    override var displayName: String { "Refresh Rate" }

    override func reset() {
        super.reset()
        smoothed = 0
    }

    override func computeValue(_ samples: [CFTimeInterval]) -> Double {
        guard samples.count >= 2, let first = samples.first else { return smoothed }
        let elapsed = (samples.last ?? first) - first
        guard elapsed > 0 else { return smoothed }
        let instant = Double(samples.count - 1) / elapsed
        smoothed = smoothed == 0 ? instant : smoothed + (instant - smoothed) * 0.3
        return smoothed
    }

    override func formatted(_ value: Double) -> String {
        String(format: "%.1f Hz", value)
    }

    override func detailText() -> String {
        let configured = setRate()
        return configured > 0 ? "live · set \(configured) Hz" : "live"
    }
}

// MARK: - FPS meter

final class FPSMeterView: MeterView {
    let sparkline = SparklineView()
    private var history: [Double] = []

    override var displayName: String { "FPS Meter" }
    override var accessoryViews: [NSView] { [sparkline] }

    override func build() {
        super.build()
        NSLayoutConstraint.activate([
            sparkline.heightAnchor.constraint(equalToConstant: 14),
            sparkline.widthAnchor.constraint(equalTo: effect.widthAnchor, constant: -36),
        ])
    }

    override func reset() {
        super.reset()
        history.removeAll()
        sparkline.values = []
    }

    override func computeValue(_ samples: [CFTimeInterval]) -> Double {
        guard samples.count >= 2, let first = samples.first else { return currentValue }
        let elapsed = (samples.last ?? first) - first
        guard elapsed > 0 else { return currentValue }
        return Double(samples.count - 1) / elapsed
    }

    override func formatted(_ value: Double) -> String {
        String(format: "%.0f fps", value.rounded())
    }

    override func detailText() -> String {
        let configured = setRate()
        return configured > 0 ? "display \(configured) Hz" : "display"
    }

    override func afterRender(_ value: Double) {
        history.append(value)
        if history.count > 36 {
            history.removeFirst()
        }
        sparkline.maxValue = Double(Swift.max(1, setRate()))
        sparkline.values = history
    }
}

// MARK: - Panel

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var refreshView: RefreshMeterView!
    private var fpsView: FPSMeterView!
    private var refreshPanel: OverlayPanel!
    private var fpsPanel: OverlayPanel!
    private var statusItem: NSStatusItem!
    private var watchdog: Timer?
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var screenChangeWorkItem: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        appDelegateShared = self

        let refreshSize = NSSize(width: 160, height: 66)
        refreshView = RefreshMeterView(frame: NSRect(origin: .zero, size: refreshSize))
        refreshView.build()
        refreshPanel = makePanel(view: refreshView, size: refreshSize)
        place(refreshPanel, size: refreshSize, key: originKeyRefresh, yOffset: 0)

        let fpsSize = NSSize(width: 160, height: 86)
        fpsView = FPSMeterView(frame: NSRect(origin: .zero, size: fpsSize))
        fpsView.build()
        fpsPanel = makePanel(view: fpsView, size: fpsSize)
        place(fpsPanel, size: fpsSize, key: originKeyFPS, yOffset: 88)

        buildStatusItem()
        installHotKeys()

        if isVisible(visibleKeyRefresh) {
            refreshView.start()
            refreshPanel.orderFrontRegardless()
        }
        if isVisible(visibleKeyFPS) {
            fpsView.start()
            fpsPanel.orderFrontRegardless()
        }
        updateMenu()

        // Refresh-rate / mode changes.
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            let relevant: CGDisplayChangeSummaryFlags = [.setModeFlag, .addFlag, .removeFlag, .setMainFlag]
            guard !flags.intersection(relevant).isEmpty else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .displayModeChanged, object: nil)
            }
        }, nil)

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: NSWindow.didChangeScreenNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: .displayModeChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(spaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared)

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.watchdogTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    func applicationWillTerminate(_ notification: Notification) {
        watchdog?.invalidate()
        refreshView?.stop()
        fpsView?.stop()
    }

    // MARK: Setup

    private func makePanel(view: MeterView, size: NSSize) -> OverlayPanel {
        let panel = OverlayPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Use a higher window level so overlays appear above fullscreen apps/games
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .fullScreenPrimary, .stationary, .ignoresCycle]
        panel.delegate = self
        panel.contentView = view
        return panel
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "speedometer", accessibilityDescription: "FPS and refresh rate")
            button.image?.isTemplate = true
            button.toolTip = "FPS / Refresh Rate overlays"
        }
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
    }

    // MARK: Position

    private func defaultOrigin(size: NSSize, yOffset: CGFloat) -> NSPoint {
        guard let visible = NSScreen.main?.visibleFrame else { return NSPoint(x: 200, y: 200) }
        return NSPoint(
            x: visible.maxX - size.width - 20,
            y: visible.maxY - size.height - 20 - yOffset
        )
    }

    private func clamped(_ origin: NSPoint, size: NSSize) -> NSPoint {
        let target = NSScreen.screens.first { $0.frame.intersects(NSRect(origin: origin, size: size)) }
            ?? NSScreen.main
        guard let visible = target?.visibleFrame else { return origin }
        let margin: CGFloat = 4
        let x = min(max(origin.x, visible.minX + margin), visible.maxX - size.width - margin)
        let y = min(max(origin.y, visible.minY + margin), visible.maxY - size.height - margin)
        return NSPoint(x: x, y: y)
    }

    private func savedOrigin(_ key: String) -> NSPoint? {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return nil }
        let point = NSPointFromString(raw)
        return point == .zero ? nil : point
    }

    private func place(_ panel: OverlayPanel, size: NSSize, key: String, yOffset: CGFloat) {
        let origin = savedOrigin(key) ?? defaultOrigin(size: size, yOffset: yOffset)
        panel.setFrame(NSRect(origin: clamped(origin, size: size), size: size), display: false)
    }

    // MARK: Visibility

    private func isVisible(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    private func setVisible(_ visible: Bool, key: String, view: MeterView, panel: OverlayPanel) {
        UserDefaults.standard.set(visible, forKey: key)
        if visible {
            view.start()
            panel.orderFrontRegardless()
        } else {
            view.stop()
            panel.orderOut(nil)
        }
        updateMenu()
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateMenu()
    }

    private func updateMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let fpsItem = NSMenuItem(title: "FPS Meter", action: #selector(toggleFPS), keyEquivalent: "f")
        fpsItem.keyEquivalentModifierMask = [.command, .option]
        fpsItem.target = self
        fpsItem.state = isVisible(visibleKeyFPS) ? .on : .off
        menu.addItem(fpsItem)

        let refreshItem = NSMenuItem(title: "Refresh Rate", action: #selector(toggleRefresh), keyEquivalent: "r")
        refreshItem.keyEquivalentModifierMask = [.command, .option]
        refreshItem.target = self
        refreshItem.state = isVisible(visibleKeyRefresh) ? .on : .off
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        let reset = NSMenuItem(title: "Reset Positions", action: #selector(resetPositions), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)

        let hud = NSMenuItem(title: "Launch App with FPS HUD…", action: #selector(launchWithHUD), keyEquivalent: "")
        hud.target = self
        menu.addItem(hud)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Refresh Rate", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: Actions

    @objc func toggleFPS() {
        setVisible(!isVisible(visibleKeyFPS), key: visibleKeyFPS, view: fpsView, panel: fpsPanel)
    }

    @objc func toggleRefresh() {
        setVisible(!isVisible(visibleKeyRefresh), key: visibleKeyRefresh, view: refreshView, panel: refreshPanel)
    }

    @objc private func resetPositions() {
        refreshPanel.setFrameOrigin(defaultOrigin(size: refreshPanel.frame.size, yOffset: 0))
        fpsPanel.setFrameOrigin(defaultOrigin(size: fpsPanel.frame.size, yOffset: 88))
        setVisible(true, key: visibleKeyRefresh, view: refreshView, panel: refreshPanel)
        setVisible(true, key: visibleKeyFPS, view: fpsView, panel: fpsPanel)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func launchWithHUD() {
        let picker = NSOpenPanel()
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.allowedContentTypes = [.application]
        picker.directoryURL = URL(fileURLWithPath: "/Applications")
        picker.prompt = "Launch with HUD"
        picker.message = "Pick a Metal app. It relaunches with Apple's FPS HUD enabled (for per-app FPS)."

        NSApp.activate(ignoringOtherApps: true)
        guard picker.runModal() == .OK, let url = picker.url else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        var environment = ProcessInfo.processInfo.environment
        environment["MTL_HUD_ENABLED"] = "1"
        configuration.environment = environment
        configuration.activates = true

        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                NSLog("FPS Meter: HUD launch failed: %@", error.localizedDescription)
            }
        }
    }

    @objc private func screenChanged() {
        // Display mode changes fire several notifications; coalesce them so the
        // meters restart once, after the dust settles.
        screenChangeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.ensureVisible()
            self.clampOnScreen(self.refreshPanel)
            self.clampOnScreen(self.fpsPanel)
            if self.refreshView.isRunning { self.refreshView.start() }
            if self.fpsView.isRunning { self.fpsView.start() }
        }
        screenChangeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    @objc private func spaceChanged() {
        ensureVisible()
    }

    @objc private func applicationActivated() {
        ensureVisible()
    }

    private func ensureVisible() {
        if isVisible(visibleKeyRefresh) && refreshView.isRunning {
            refreshPanel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
            refreshPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .fullScreenPrimary, .stationary, .ignoresCycle]
            refreshPanel.orderFrontRegardless()
        }
        if isVisible(visibleKeyFPS) && fpsView.isRunning {
            fpsPanel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
            fpsPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .fullScreenPrimary, .stationary, .ignoresCycle]
            fpsPanel.orderFrontRegardless()
        }
    }

    private func clampOnScreen(_ panel: OverlayPanel) {
        let fixed = clamped(panel.frame.origin, size: panel.frame.size)
        if fixed != panel.frame.origin {
            panel.setFrameOrigin(fixed)
        }
    }

    private func watchdogTick() {
        if refreshView.isRunning { refreshView.checkHealth() }
        if fpsView.isRunning { fpsView.checkHealth() }
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === refreshPanel {
            UserDefaults.standard.set(NSStringFromPoint(window.frame.origin), forKey: originKeyRefresh)
        } else if window === fpsPanel {
            UserDefaults.standard.set(NSStringFromPoint(window.frame.origin), forKey: originKeyFPS)
        }
    }

    // MARK: Global hotkeys

    private func installHotKeys() {
        guard hotKeyRefs.isEmpty else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }

            let id = hotKeyID.id
            DispatchQueue.main.async {
                switch id {
                case 1: appDelegateShared?.toggleFPS()
                case 2: appDelegateShared?.toggleRefresh()
                default: break
                }
            }
            return noErr
        }, 1, &eventType, nil, nil)

        let signature = OSType(0x5252_4F48) // 'RROH'
        for (index, key) in [UInt32(kVK_ANSI_F), UInt32(kVK_ANSI_R)].enumerated() {
            var ref: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: signature, id: UInt32(index + 1))
            let status = RegisterEventHotKey(
                key,
                UInt32(cmdKey | optionKey),
                identifier,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status != noErr {
                NSLog("FPS Meter: hotkey %u registration failed (%d)", key, status)
            }
            hotKeyRefs.append(ref)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
