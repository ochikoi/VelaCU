import AppKit
import Darwin

struct SessionState: Codable {
    let active: Bool
    let serverPID: Int32
    let targetPID: Int32
    let bundleID: String
    let bundlePath: String
    let owner: String
    let title: String
    let sessionID: String
    let updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case active
        case serverPID = "server_pid"
        case targetPID = "target_pid"
        case bundleID = "bundle_id"
        case bundlePath = "bundle_path"
        case owner
        case title
        case sessionID = "session_id"
        case updatedAt = "updated_at"
    }
}

final class PassThroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

final class StatusController: NSObject, NSApplicationDelegate {
    private static let projectRoot: URL = {
        // Bundle layout: <project>/bin/VelaCU Status.app. Keeping runtime
        // relative to the bundle makes source checkouts and ~/.local installs
        // work without embedding a developer-specific absolute path.
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
    }()
    private let root = StatusController.projectRoot
        .appendingPathComponent("runtime", isDirectory: true)
        .appendingPathComponent("status", isDirectory: true)
    private lazy var sessionsURL = root.appendingPathComponent("sessions", isDirectory: true)
    private lazy var commandsURL = root.appendingPathComponent("commands", isDirectory: true)
    private lazy var pidURL = root.appendingPathComponent("status-app.pid")
    private lazy var lockURL = root.appendingPathComponent("status-app.lock")
    private var lockFD: Int32 = -1
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var stateItem: NSMenuItem?
    private var windowItem: NSMenuItem?
    private var releaseItem: NSMenuItem?
    private weak var animationContainer: NSView?
    private weak var animationAppView: PassThroughImageView?
    private var animationAppLayer: CALayer?
    private weak var animationPointerView: PassThroughImageView?
    private var animationSerial = 0
    private var isExitAnimating = false
    private var timer: Timer?
    private var currentState: SessionState?
    private var currentBundleID: String?
    private var currentSessionID: String?
    private var composedCache: [String: NSImage] = [:]
    private let compositeCanvasSize = NSSize(width: 22, height: 22)
    // One source of truth for the App icon geometry.  The animation pivot
    // reuses this exact composite-image coordinate; the pointer has its own
    // vertical offset so it can remain fully inside the canvas.
    private let appIconCenter = NSPoint(x: 11, y: 11)
    private let appIconSize: CGFloat = 17
    private let pointerYOffset: CGFloat = 2.5
    private let startupGrace: TimeInterval = 0.8
    private var launchedAt = Date()
    private lazy var referencePointerImage: NSImage? = {
        // Use the system cursor at runtime instead of shipping a screenshot or
        // copied cursor artwork. This keeps the public source tree self-contained
        // and lets macOS provide the appropriate native pointer asset.
        let image = (NSCursor.arrow.image.copy() as? NSImage) ?? NSCursor.arrow.image
        image.isTemplate = false
        return image
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !acquireSingleton() {
            NSApp.terminate(nil)
            return
        }
        try? FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: commandsURL, withIntermediateDirectories: true)
        NSApp.setActivationPolicy(.accessory)

        launchedAt = Date()
        writePID()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        if let ownPID = try? String(contentsOf: pidURL, encoding: .utf8), ownPID.trimmingCharacters(in: .whitespacesAndNewlines) == String(getpid()) {
            try? FileManager.default.removeItem(at: pidURL)
        }
        if lockFD >= 0 {
            close(lockFD)
            lockFD = -1
        }
    }

    private func acquireSingleton() -> Bool {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        lockFD = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockFD >= 0 else { return false }
        return flock(lockFD, LOCK_EX | LOCK_NB) == 0
    }

    private func writePID() {
        try? String(getpid()).data(using: .utf8)?.write(to: pidURL, options: .atomic)
    }

    private func readStates() -> [SessionState] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: nil) else { return [] }
        var states: [SessionState] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let state = try? JSONDecoder().decode(SessionState.self, from: data) else { continue }
            if !processIsAlive(state.serverPID) || !processIsAlive(state.targetPID) {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            states.append(state)
        }
        return states.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func processIsAlive(_ pid: Int32) -> Bool {
        pid > 0 && kill(pid, 0) == 0
    }

    private func refresh() {
        let next = readStates().first
        guard let next else {
            if statusItem != nil, currentState != nil {
                if !isExitAnimating {
                    animateExitAndTerminate()
                }
                return
            }
            if Date().timeIntervalSince(launchedAt) >= startupGrace {
                NSApp.terminate(nil)
            }
            return
        }

        if isExitAnimating {
            cancelAnimationOverlay()
            isExitAnimating = false
        }

        let isFirstAppearance = statusItem == nil
        let appChanged = currentBundleID != next.bundleID
        ensureStatusItem()
        if appChanged {
            currentBundleID = next.bundleID
            let image = composedCache[next.bundleID] ?? composeActiveImage(for: next)
            composedCache[next.bundleID] = image
            statusItem?.button?.image = image
        }
        currentSessionID = next.sessionID
        stateItem?.title = "Controlling\n\(next.owner.isEmpty ? next.bundleID : next.owner)"
        windowItem?.title = next.title.isEmpty ? "Window: Untitled" : "Window: \(next.title)"
        releaseItem?.isHidden = false
        currentState = next
        if isFirstAppearance {
            animateAppPop(pointerFadeIn: true, reason: "startup-bind")
        } else if appChanged {
            // Switching apps animates only the App icon. The pointer stays
            // visually fixed and fully opaque.
            animateAppPop(pointerFadeIn: false, reason: "app-switch")
        }
    }

    private func ensureStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.imageScaling = .scaleProportionallyDown
        statusItem = item

        let newMenu = NSMenu()
        let title = NSMenuItem(title: "VelaCU", action: nil, keyEquivalent: "")
        title.isEnabled = false
        let state = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        state.isEnabled = false
        let window = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        window.isEnabled = false
        let release = NSMenuItem(title: "Release Control", action: #selector(releaseControl), keyEquivalent: "")
        release.target = self
        newMenu.addItem(title)
        newMenu.addItem(state)
        newMenu.addItem(window)
        newMenu.addItem(.separator())
        newMenu.addItem(release)
        newMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit VelaCU Status", action: #selector(quitStatus), keyEquivalent: "q")
        quit.target = self
        newMenu.addItem(quit)
        stateItem = state
        windowItem = window
        releaseItem = release
        menu = newMenu
        item.menu = newMenu
    }

    private func removeStatusItem() {
        animationSerial += 1
        animationContainer?.removeFromSuperview()
        animationContainer = nil
        animationAppView = nil
        animationAppLayer = nil
        animationPointerView = nil
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        menu = nil
        stateItem = nil
        windowItem = nil
        releaseItem = nil
    }

    private func cancelAnimationOverlay() {
        animationSerial += 1
        animationContainer?.layer?.removeAllAnimations()
        animationAppView?.layer?.removeAllAnimations()
        animationAppLayer?.removeAllAnimations()
        animationPointerView?.layer?.removeAllAnimations()
        animationContainer?.removeFromSuperview()
        animationContainer = nil
        animationAppView = nil
        animationAppLayer = nil
        animationPointerView = nil
        if let state = currentState {
            statusItem?.button?.image = composedCache[state.bundleID] ?? composeActiveImage(for: state)
        }
    }

    private func makeAnimationViews(on button: NSStatusBarButton, state: SessionState) -> (NSView, PassThroughImageView, CALayer, PassThroughImageView)? {
        button.layoutSubtreeIfNeeded()
        guard button.bounds.width > 0, button.bounds.height > 0 else { return nil }

        let container = NSView(frame: button.bounds)
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.masksToBounds = false

        // Keep the App host view permanently centered in the menu-bar capsule.
        // Never animate this NSView or its frame: AppKit-managed backing layers
        // can use a bottom-left anchor, which was the cause of the previous drift.
        let appFrame = NSRect(
            x: button.bounds.midX - appIconSize / 2,
            y: button.bounds.midY - appIconSize / 2,
            width: appIconSize,
            height: appIconSize
        )
        let appView = PassThroughImageView(frame: appFrame)
        appView.wantsLayer = true
        appView.layer?.masksToBounds = false
        container.addSubview(appView)

        // Animate a standalone CALayer that VelaCU owns instead of AppKit's
        // backing layer. Its position is fixed at the host view's exact center
        // and anchorPoint is explicitly 0.5/0.5, so transform.scale can only
        // expand equally in all four directions around the App icon center.
        let iconLayer = CALayer()
        iconLayer.bounds = CGRect(x: 0, y: 0, width: appIconSize, height: appIconSize)
        iconLayer.position = CGPoint(x: appView.bounds.midX, y: appView.bounds.midY)
        iconLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        iconLayer.contentsGravity = .resizeAspect
        iconLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let iconImage = appOnlyImage(for: state)
        if let cgImage = iconImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            iconLayer.contents = cgImage
        }
        appView.layer?.addSublayer(iconLayer)

        // Pointer is a completely separate view. It never inherits App-icon
        // scaling and only participates in startup/exit opacity animation.
        let compositeOrigin = NSPoint(
            x: button.bounds.midX - compositeCanvasSize.width / 2,
            y: button.bounds.midY - compositeCanvasSize.height / 2
        )
        let pointerWidth: CGFloat = 11
        let pointerHeight: CGFloat = 13
        let pointerTop = compositeOrigin.y + appIconCenter.y + pointerYOffset
        let pointerSlot = NSRect(
            x: compositeOrigin.x + appIconCenter.x,
            y: pointerTop - pointerHeight,
            width: pointerWidth,
            height: pointerHeight
        )
        // Match drawCursor(in:) exactly. The resting composite pins the actual
        // pointer bitmap to pointerSlot.minX (not horizontally centered inside
        // the 11pt slot). NSImageView's .alignCenter previously added ~0.7pt of
        // right offset during animation, then jumped left when the resting image
        // returned. Give the animation view the bitmap's exact aspect-fit frame
        // so both states use identical geometry.
        var pointerFrame = pointerSlot
        if let pointer = referencePointerImage, pointer.size.width > 0, pointer.size.height > 0 {
            let scale = min(pointerSlot.width / pointer.size.width, pointerSlot.height / pointer.size.height)
            let drawSize = NSSize(width: pointer.size.width * scale, height: pointer.size.height * scale)
            pointerFrame = NSRect(
                x: pointerSlot.minX,
                y: pointerSlot.maxY - drawSize.height,
                width: drawSize.width,
                height: drawSize.height
            )
        }
        let pointerView = PassThroughImageView(frame: pointerFrame)
        pointerView.image = referencePointerImage
        pointerView.imageScaling = .scaleProportionallyDown
        pointerView.imageAlignment = .alignCenter
        pointerView.wantsLayer = true
        pointerView.layer?.masksToBounds = false

        container.addSubview(pointerView)
        button.addSubview(container, positioned: .above, relativeTo: nil)
        return (container, appView, iconLayer, pointerView)
    }

    private func animateAppPop(pointerFadeIn: Bool, reason: String) {
        guard let item = statusItem, let button = item.button, let state = currentState else { return }
        button.layoutSubtreeIfNeeded()
        guard button.bounds.width > 0, button.bounds.height > 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.animateAppPop(pointerFadeIn: pointerFadeIn, reason: reason)
            }
            return
        }

        let resting = composedCache[state.bundleID] ?? composeActiveImage(for: state)
        composedCache[state.bundleID] = resting
        cancelAnimationOverlay()
        animationSerial += 1
        let serial = animationSerial
        button.image = nil
        guard let (container, appView, appLayer, pointerView) = makeAnimationViews(on: button, state: state) else {
            button.image = resting
            return
        }
        animationContainer = container
        animationAppView = appView
        animationAppLayer = appLayer
        animationPointerView = pointerView

        // Q-pop only the App icon: 0.5 -> 1.5 -> 1.0. Do not animate a
        // transform at all: animate only the standalone layer's bounds.size
        // while its position remains fixed at the exact icon center. This makes
        // center drift geometrically impossible, independent of AppKit anchors.
        let animation = CAKeyframeAnimation(keyPath: "bounds.size")
        animation.values = [
            NSValue(size: NSSize(width: appIconSize * 0.5, height: appIconSize * 0.5)),
            NSValue(size: NSSize(width: appIconSize * 1.5, height: appIconSize * 1.5)),
            NSValue(size: NSSize(width: appIconSize, height: appIconSize)),
        ]
        animation.keyTimes = [0.0, 0.56, 1.0]
        animation.duration = 0.34
        animation.timingFunctions = [
            CAMediaTimingFunction(controlPoints: 0.20, 0.80, 0.25, 1.0),
            CAMediaTimingFunction(controlPoints: 0.25, 0.10, 0.25, 1.0)
        ]
        animation.isRemovedOnCompletion = true
        appLayer.add(animation, forKey: "velacu.app-pop")

        if pointerFadeIn {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.0
            fade.toValue = 1.0
            fade.duration = 0.22
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pointerView.layer?.opacity = 1.0
            pointerView.layer?.add(fade, forKey: "velacu.pointer-fade-in")
        }

        let log = root.appendingPathComponent("animation.log")
        let line = "\(Date().timeIntervalSince1970) app-pop 0.5->1.5->1.0 340ms center=button.mid pointerFadeIn=\(pointerFadeIn) reason=\(reason)\n"
        if let data = line.data(using: .utf8), let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { [weak self, weak container] in
            guard let self, self.animationSerial == serial else { return }
            container?.removeFromSuperview()
            self.animationContainer = nil
            self.animationAppView = nil
            self.animationAppLayer = nil
            self.animationPointerView = nil
            self.statusItem?.button?.image = resting
        }
    }

    private func animateExitAndTerminate() {
        guard !isExitAnimating,
              let item = statusItem,
              let button = item.button,
              let state = currentState else {
            removeStatusItem()
            NSApp.terminate(nil)
            return
        }

        isExitAnimating = true
        cancelAnimationOverlay()
        isExitAnimating = true
        animationSerial += 1
        let serial = animationSerial
        button.image = nil
        guard let (container, appView, appLayer, pointerView) = makeAnimationViews(on: button, state: state) else {
            removeStatusItem()
            NSApp.terminate(nil)
            return
        }
        animationContainer = container
        animationAppView = appView
        animationAppLayer = appLayer
        animationPointerView = pointerView

        // On real exit both parts animate, but independently: App icon stays
        // centered while retracting; pointer only fades out and never scales.
        let appExit = CAKeyframeAnimation(keyPath: "bounds.size")
        appExit.values = [
            NSValue(size: NSSize(width: appIconSize, height: appIconSize)),
            NSValue(size: NSSize(width: appIconSize * 1.22, height: appIconSize * 1.22)),
            NSValue(size: NSSize(width: appIconSize * 0.5, height: appIconSize * 0.5)),
        ]
        appExit.keyTimes = [0.0, 0.38, 1.0]
        appExit.duration = 0.28
        appExit.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeIn)
        ]
        appExit.isRemovedOnCompletion = false
        appExit.fillMode = .forwards
        appLayer.add(appExit, forKey: "velacu.app-exit")

        let pointerExit = CABasicAnimation(keyPath: "opacity")
        pointerExit.fromValue = 1.0
        pointerExit.toValue = 0.0
        pointerExit.duration = 0.22
        pointerExit.timingFunction = CAMediaTimingFunction(name: .easeIn)
        pointerExit.isRemovedOnCompletion = false
        pointerExit.fillMode = .forwards
        pointerView.layer?.add(pointerExit, forKey: "velacu.pointer-fade-out")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
            guard let self, self.animationSerial == serial else { return }
            self.removeStatusItem()
            self.currentBundleID = nil
            self.currentSessionID = nil
            self.currentState = nil
            self.isExitAnimating = false
            NSApp.terminate(nil)
        }
    }

    @objc private func releaseControl() {
        guard let state = currentState else { return }
        let command = commandsURL.appendingPathComponent("\(state.sessionID).release")
        let temp = commandsURL.appendingPathComponent(".\(state.sessionID).\(getpid()).tmp")
        try? Data("release\n".utf8).write(to: temp, options: .atomic)
        try? FileManager.default.moveItem(at: temp, to: command)
    }

    @objc private func quitStatus() {
        if statusItem != nil, currentState != nil {
            animateExitAndTerminate()
        } else {
            NSApp.terminate(nil)
        }
    }

    private func appIcon(for state: SessionState) -> NSImage? {
        // Prefer the bundle path: Safari's live process can expose a Cryptex
        // bundle URL while NSRunningApplication.icon is nil during activation.
        if !state.bundlePath.isEmpty, FileManager.default.fileExists(atPath: state.bundlePath) {
            let icon = NSWorkspace.shared.icon(forFile: state.bundlePath)
            icon.isTemplate = false
            return icon
        }
        if let icon = NSRunningApplication(processIdentifier: state.targetPID)?.icon {
            icon.isTemplate = false
            return icon
        }
        if !state.bundleID.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: state.bundleID) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.isTemplate = false
            return icon
        }
        return nil
    }

    private func appOnlyImage(for state: SessionState) -> NSImage {
        let image = NSImage(size: NSSize(width: appIconSize, height: appIconSize))
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: image.size)
        if let icon = appIcon(for: state) {
            let appCopy = (icon.copy() as? NSImage) ?? icon
            appCopy.isTemplate = false
            appCopy.draw(in: rect, from: NSRect(origin: .zero, size: appCopy.size), operation: .sourceOver, fraction: 1.0)
        } else {
            let fallback = makeVelaImage()
            fallback.draw(in: rect, from: NSRect(origin: .zero, size: fallback.size), operation: .sourceOver, fraction: 1.0)
        }
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func composeActiveImage(for state: SessionState) -> NSImage {
        let image = NSImage(size: compositeCanvasSize)
        let iconRect = NSRect(
            x: appIconCenter.x - appIconSize / 2,
            y: appIconCenter.y - appIconSize / 2,
            width: appIconSize,
            height: appIconSize
        )
        image.lockFocus()
        let app = appOnlyImage(for: state)
        app.draw(in: iconRect, from: NSRect(origin: .zero, size: app.size), operation: .sourceOver, fraction: 1.0)

        // Resting composite matches the animation layout: App icon centered;
        // pointer offset independently and never used as a scaling anchor.
        let pointerWidth: CGFloat = 11
        let pointerHeight: CGFloat = 13
        let pointerTop = appIconCenter.y + pointerYOffset
        drawCursor(in: NSRect(x: appIconCenter.x, y: pointerTop - pointerHeight, width: pointerWidth, height: pointerHeight))
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func makeVelaImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 17, height: 17))
        image.lockFocus()
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 17, height: 17)).fill()
        NSColor.white.setStroke()
        let mark = NSBezierPath()
        mark.move(to: NSPoint(x: 4, y: 11)); mark.line(to: NSPoint(x: 8.5, y: 4)); mark.line(to: NSPoint(x: 13, y: 11))
        mark.lineWidth = 1.8; mark.stroke()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func drawCursor(in rect: NSRect) {
        // Draw the native macOS arrow supplied by NSCursor. The App icon and
        // pointer remain separate animation layers, so App switching never moves
        // or scales the pointer.
        guard let pointer = referencePointerImage else { return }
        let natural = pointer.size
        guard natural.width > 0, natural.height > 0 else { return }
        let scale = min(rect.width / natural.width, rect.height / natural.height)
        let drawSize = NSSize(width: natural.width * scale, height: natural.height * scale)
        let drawRect = NSRect(x: rect.minX, y: rect.maxY - drawSize.height, width: drawSize.width, height: drawSize.height)
        pointer.draw(in: drawRect, from: NSRect(origin: .zero, size: natural), operation: .sourceOver, fraction: 1.0)
    }
}

let app = NSApplication.shared
let delegate = StatusController()
app.delegate = delegate
app.run()
