import AppKit
import CoreGraphics
import Darwin
import Foundation

private typealias WindowListCreateImageFn = @convention(c) (
    CGRect,
    CGWindowListOption,
    CGWindowID,
    CGWindowImageOption
) -> Unmanaged<CGImage>?

private let windowListCreateImage: WindowListCreateImageFn? = {
    guard let handle = dlopen(
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
        RTLD_LAZY | RTLD_LOCAL
    ), let symbol = dlsym(handle, "CGWindowListCreateImage") else {
        return nil
    }
    return unsafeBitCast(symbol, to: WindowListCreateImageFn.self)
}()

private struct PointerCommand: Decodable {
    let action: String
    let window_id: Int?
    let screen_x: Double?
    let screen_y: Double?
    let local_x: Double?
    let local_y: Double?
    let image_path: String?
    let pulse: Bool?
    let request_id: String?
}

private struct TargetWindowInfo {
    let pid: Int32
    let layer: Int
    let isForemostNormalOnScreen: Bool
}

private final class PointerWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PointerCanvasView: NSView {
    override var isFlipped: Bool { true }
}

private final class PointerController: NSObject, NSApplicationDelegate {
    private enum VisibilityTransition {
        case minimizing
        case restoring
    }

    private let initialImagePath: String
    private let maxPulseScale: CGFloat = 1.25
    private let moveTick: TimeInterval = 1.0 / 120.0
    private let pulseTick: TimeInterval = 1.0 / 120.0
    private let followTick: TimeInterval = 1.0 / 30.0
    private let visualTick: TimeInterval = 1.0 / 30.0
    private let movingContrastSampleInterval: TimeInterval = 1.0 / 24.0
    private let idleContrastSampleInterval: TimeInterval = 0.18
    private let visibilityTick: TimeInterval = 1.0 / 120.0
    private let visibilityDuration: TimeInterval = 0.24
    private let followSpring: CGFloat = 90.0
    private let followDamping: CGFloat = 9.0
    private let followMaxSpeed: CGFloat = 2600.0
    private let idleFloatSpring: CGFloat = 6.0
    private let idleFloatDamping: CGFloat = 4.2
    private let idleFloatRadiusX: CGFloat = 5.2
    private let idleFloatRadiusY: CGFloat = 4.2

    private var window: PointerWindow?
    private var canvasView: PointerCanvasView?
    private var imageView: NSImageView?
    private var imageSize: NSSize = .zero
    private var hotspot = NSPoint(x: 0, y: 1)
    private var canvasHotspot = NSPoint.zero

    private var targetWindowID: Int?
    private var targetLocalPoint: CGPoint?
    private var currentScreenPoint: CGPoint?
    private var destinationScreenPoint: CGPoint?
    private var followVelocity = CGVector.zero
    private var followTimer: Timer?
    private var followLastTime: TimeInterval = 0
    private var moveTimer: Timer?
    private var pulseTimer: Timer?
    private var moveStartedAt: TimeInterval = 0
    private var moveDuration: TimeInterval = 0
    private var moveStartPoint = CGPoint.zero
    private var moveEndPoint = CGPoint.zero
    private var pendingPulse = false
    private var pendingArrivalRequestID: String?
    private var pulseStartedAt: TimeInterval = 0
    private var targetWasOnScreen: Bool?
    private var offScreenSamples = 0
    private var hiddenByMinimize = false
    private var visibilityTransition: VisibilityTransition?
    private var visibilityTimer: Timer?
    private var visibilityStartedAt: TimeInterval = 0
    private var visibilityStartPoint = CGPoint.zero
    private var visibilityEndPoint = CGPoint.zero

    // Purely visual state. None of these values feed back into VelaCU's logical
    // click point, window binding or VelaClick delivery path.
    private var visualTimer: Timer?
    private var visualLastTime: TimeInterval = 0
    private var visualLastLogicalPoint: CGPoint?
    private var visualLastMotionTime: TimeInterval = 0
    private var idleFloatOffset = CGVector.zero
    private var idleFloatVelocity = CGVector.zero
    private var idleFloatTarget = CGVector.zero
    private var idleFloatBlend: CGFloat = 0
    private var nextIdleFloatTargetAt: TimeInterval = 0
    private var currentPulseScale: CGFloat = 1.0
    private var lastContrastSampleAt: TimeInterval = 0
    private var contrastSampleInFlight = false
    private var adaptiveBrightness: CGFloat = 0.08
    private var adaptiveTargetBrightness: CGFloat = 0.08
    private var prefersLightPointer = false

    init(imagePath: String) {
        self.initialImagePath = imagePath
        super.init()
        hotspot = NSPoint(
            x: Self.environmentCGFloat("VELACU_POINTER_HOTSPOT_X", fallback: 0),
            y: Self.environmentCGFloat("VELACU_POINTER_HOTSPOT_Y", fallback: 1)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        loadImage(at: initialImagePath)

        // Pointer and target remain independent WindowServer layers. A low-rate
        // physics tick both re-pins z-order and lets the cursor trail a moving
        // target window with spring/damping inertia.
        followLastTime = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: followTick, repeats: true) { [weak self] _ in
            self?.stepWindowFollow()
        }
        followTimer = timer
        RunLoop.main.add(timer, forMode: .common)

        visualLastTime = ProcessInfo.processInfo.systemUptime
        visualLastMotionTime = visualLastTime
        let visual = Timer(timeInterval: visualTick, repeats: true) { [weak self] _ in
            self?.stepVisualEffects()
        }
        visualTimer = visual
        RunLoop.main.add(visual, forMode: .common)

        Thread.detachNewThread { [weak self] in
            self?.readCommands()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        followTimer?.invalidate()
        moveTimer?.invalidate()
        pulseTimer?.invalidate()
        visibilityTimer?.invalidate()
        visualTimer?.invalidate()
    }

    private static func environmentCGFloat(_ key: String, fallback: CGFloat) -> CGFloat {
        guard let raw = ProcessInfo.processInfo.environment[key],
              let value = Double(raw), value.isFinite else { return fallback }
        return CGFloat(value)
    }

    private func loadImage(at path: String) {
        guard let image = NSImage(contentsOfFile: path), image.size.width > 0, image.size.height > 0 else {
            FileHandle.standardError.write(Data("VelaPointer: cannot load image at \(path)\n".utf8))
            return
        }

        image.isTemplate = true
        imageSize = image.size
        hotspot.x = min(max(0, hotspot.x), imageSize.width)
        hotspot.y = min(max(0, hotspot.y), imageSize.height)

        // Leave enough transparent canvas for the 1.25x click bounce while
        // keeping the hotspot fixed at the exact target coordinate. Extra room
        // also prevents the visual-only idle float and halo from clipping.
        let margin: CGFloat = 9
        canvasHotspot = NSPoint(
            x: ceil(margin + hotspot.x * maxPulseScale),
            y: ceil(margin + hotspot.y * maxPulseScale)
        )
        let canvasWidth = ceil(canvasHotspot.x + (imageSize.width - hotspot.x) * maxPulseScale + margin)
        let canvasHeight = ceil(canvasHotspot.y + (imageSize.height - hotspot.y) * maxPulseScale + margin)
        let canvasSize = NSSize(width: canvasWidth, height: canvasHeight)

        if window == nil {
            let win = PointerWindow(
                contentRect: NSRect(origin: .zero, size: canvasSize),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            win.isOpaque = false
            win.backgroundColor = .clear
            win.hasShadow = false
            win.ignoresMouseEvents = true
            win.level = .normal
            win.hidesOnDeactivate = false
            win.isReleasedWhenClosed = false
            win.collectionBehavior = [.fullScreenAuxiliary, .stationary]

            let canvas = PointerCanvasView(frame: NSRect(origin: .zero, size: canvasSize))
            canvas.wantsLayer = true
            canvas.layer?.backgroundColor = NSColor.clear.cgColor
            canvas.layer?.masksToBounds = true

            let view = NSImageView(frame: .zero)
            view.imageScaling = .scaleAxesIndependently
            view.imageAlignment = .alignTopLeft
            view.wantsLayer = true
            view.layer?.masksToBounds = false
            view.layer?.shadowOffset = .zero
            view.layer?.shadowRadius = 1.15
            view.layer?.shadowOpacity = 0.82
            view.layer?.shouldRasterize = true
            view.layer?.rasterizationScale = NSScreen.main?.backingScaleFactor ?? 2.0
            canvas.addSubview(view)
            win.contentView = canvas

            window = win
            canvasView = canvas
            imageView = view
        } else {
            window?.setContentSize(canvasSize)
            canvasView?.frame = NSRect(origin: .zero, size: canvasSize)
        }

        imageView?.image = image
        applyAdaptiveMaterial()
        applyImageScale(1.0)

        if let point = currentScreenPoint {
            setWindowHotspot(to: point)
        }
    }

    private func readCommands() {
        let decoder = JSONDecoder()
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)

        while true {
            let count = chunk.withUnsafeMutableBytes { rawBuffer -> Int in
                Darwin.read(STDIN_FILENO, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                break
            }

            buffer.append(contentsOf: chunk.prefix(count))
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !line.isEmpty,
                      let command = try? decoder.decode(PointerCommand.self, from: line) else {
                    continue
                }
                DispatchQueue.main.async { [weak self] in
                    self?.handle(command)
                }
            }
        }

        if !buffer.isEmpty,
           let command = try? decoder.decode(PointerCommand.self, from: buffer) {
            DispatchQueue.main.async { [weak self] in
                self?.handle(command)
            }
        }

        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    private func handle(_ command: PointerCommand) {
        switch command.action {
        case "move":
            guard let windowID = command.window_id,
                  let screenX = command.screen_x,
                  let screenY = command.screen_y else { return }
            targetWindowID = windowID
            let visibility = targetWindowVisibility(windowID)
            targetWasOnScreen = visibility.exists ? visibility.onScreen : true
            offScreenSamples = 0
            hiddenByMinimize = false
            if let localX = command.local_x, let localY = command.local_y {
                targetLocalPoint = CGPoint(x: localX, y: localY)
            } else if let bounds = currentTargetWindowBounds(windowID) {
                targetLocalPoint = CGPoint(x: screenX - bounds.origin.x, y: screenY - bounds.origin.y)
            }
            followVelocity = .zero
            animateMove(
                to: CGPoint(x: screenX, y: screenY),
                pulseAfter: command.pulse ?? false,
                arrivalRequestID: command.request_id
            )
            pinAboveTarget()

        case "pulse":
            startPulse()

        case "image":
            if let path = command.image_path {
                loadImage(at: path)
            }

        case "hide":
            cancelAnimations()
            cancelVisibilityTransition()
            window?.orderOut(nil)
            targetWindowID = nil
            targetLocalPoint = nil
            currentScreenPoint = nil
            destinationScreenPoint = nil
            followVelocity = .zero
            targetWasOnScreen = nil
            offScreenSamples = 0
            hiddenByMinimize = false

        case "quit":
            NSApp.terminate(nil)

        default:
            break
        }
    }

    private func animateMove(to point: CGPoint, pulseAfter: Bool, arrivalRequestID: String?) {
        pulseTimer?.invalidate()
        pulseTimer = nil
        applyImageScale(1.0)

        // If a new command arrives mid-flight, continue from the currently
        // rendered position instead of jumping back to the previous endpoint.
        moveTimer?.invalidate()
        moveTimer = nil
        destinationScreenPoint = point
        pendingPulse = pulseAfter
        pendingArrivalRequestID = arrivalRequestID

        guard let start = currentScreenPoint else {
            currentScreenPoint = point
            setWindowHotspot(to: point)
            pinAboveTarget()
            signalArrivalIfNeeded()
            if pulseAfter { startPulse() }
            return
        }

        let distance = hypot(point.x - start.x, point.y - start.y)
        if distance < 0.5 {
            currentScreenPoint = point
            setWindowHotspot(to: point)
            signalArrivalIfNeeded()
            if pulseAfter { startPulse() }
            return
        }

        moveStartPoint = start
        moveEndPoint = point
        moveStartedAt = ProcessInfo.processInfo.systemUptime
        // Long moves remain visibly traceable without making VelaCU feel slow.
        moveDuration = min(0.24, max(0.11, 0.10 + Double(distance) / 5000.0))

        let timer = Timer(timeInterval: moveTick, repeats: true) { [weak self] timer in
            self?.stepMove(timer)
        }
        moveTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stepMove(_ timer: Timer) {
        let elapsed = ProcessInfo.processInfo.systemUptime - moveStartedAt
        let rawT = moveDuration > 0 ? min(1.0, elapsed / moveDuration) : 1.0
        let t = smoothstep(rawT)
        let point = CGPoint(
            x: moveStartPoint.x + (moveEndPoint.x - moveStartPoint.x) * t,
            y: moveStartPoint.y + (moveEndPoint.y - moveStartPoint.y) * t
        )
        currentScreenPoint = point
        setWindowHotspot(to: point)
        pinAboveTarget()

        if rawT >= 1.0 {
            timer.invalidate()
            moveTimer = nil
            currentScreenPoint = moveEndPoint
            setWindowHotspot(to: moveEndPoint)
            signalArrivalIfNeeded()
            if pendingPulse {
                pendingPulse = false
                startPulse()
            }
        }
    }

    private func signalArrivalIfNeeded() {
        guard let requestID = pendingArrivalRequestID else { return }
        pendingArrivalRequestID = nil
        let payload: [String: String] = [
            "event": "arrived",
            "request_id": requestID,
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    private func startPulse() {
        pulseTimer?.invalidate()
        pulseStartedAt = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: pulseTick, repeats: true) { [weak self] timer in
            self?.stepPulse(timer)
        }
        pulseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stepPulse(_ timer: Timer) {
        let total: TimeInterval = 0.32
        let t = min(1.0, (ProcessInfo.processInfo.systemUptime - pulseStartedAt) / total)
        let scale: CGFloat

        // Exact key scales requested by the UI contract:
        // 1.0 -> 0.5 -> 1.25 -> 1.0
        if t <= 0.24 {
            scale = interpolateScale(from: 1.0, to: 0.5, localT: t / 0.24)
        } else if t <= 0.62 {
            scale = interpolateScale(from: 0.5, to: 1.25, localT: (t - 0.24) / 0.38)
        } else {
            scale = interpolateScale(from: 1.25, to: 1.0, localT: (t - 0.62) / 0.38)
        }
        applyImageScale(scale)

        if t >= 1.0 {
            timer.invalidate()
            pulseTimer = nil
            applyImageScale(1.0)
        }
    }

    private func interpolateScale(from: CGFloat, to: CGFloat, localT: Double) -> CGFloat {
        let eased = smoothstep(min(1.0, max(0.0, localT)))
        return from + (to - from) * CGFloat(eased)
    }

    private func smoothstep(_ value: Double) -> Double {
        let t = min(1.0, max(0.0, value))
        return t * t * (3.0 - 2.0 * t)
    }

    private func applyImageScale(_ scale: CGFloat) {
        currentPulseScale = scale
        renderPointerVisual()
    }

    private func renderPointerVisual() {
        guard let imageView else { return }
        let scale = currentPulseScale
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        let floatX = idleFloatOffset.dx * idleFloatBlend
        let floatY = idleFloatOffset.dy * idleFloatBlend
        // The logical hotspot stays untouched. Only the image inside the
        // transparent Pointer window receives the idle visual offset.
        let origin = NSPoint(
            x: canvasHotspot.x - hotspot.x * scale + floatX,
            y: canvasHotspot.y - hotspot.y * scale + floatY
        )
        imageView.frame = NSRect(origin: origin, size: NSSize(width: width, height: height))
    }

    private func stepVisualEffects() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = visualLastTime > 0 ? now - visualLastTime : visualTick
        visualLastTime = now
        let dt = CGFloat(min(0.05, max(1.0 / 240.0, elapsed)))

        if let logical = currentScreenPoint {
            if let previous = visualLastLogicalPoint {
                if hypot(logical.x - previous.x, logical.y - previous.y) > 0.12 {
                    visualLastMotionTime = now
                }
            } else {
                visualLastMotionTime = now
            }
            visualLastLogicalPoint = logical
        } else {
            visualLastLogicalPoint = nil
        }

        let idleEligible = currentScreenPoint != nil &&
            moveTimer == nil &&
            visibilityTransition == nil &&
            !hiddenByMinimize &&
            now - visualLastMotionTime >= 0.20

        let blendTarget: CGFloat = idleEligible ? 1.0 : 0.0
        let blendRate: CGFloat = idleEligible ? 2.8 : 11.0
        idleFloatBlend += (blendTarget - idleFloatBlend) * (1.0 - exp(-blendRate * dt))

        if idleEligible && now >= nextIdleFloatTargetAt {
            idleFloatTarget = randomIdleFloatTarget()
            nextIdleFloatTargetAt = now + Double.random(in: 0.55...1.05)
        } else if !idleEligible {
            idleFloatTarget = .zero
            nextIdleFloatTargetAt = now + 0.25
        }

        let accelerationX = idleFloatSpring * (idleFloatTarget.dx - idleFloatOffset.dx) - idleFloatDamping * idleFloatVelocity.dx
        let accelerationY = idleFloatSpring * (idleFloatTarget.dy - idleFloatOffset.dy) - idleFloatDamping * idleFloatVelocity.dy
        idleFloatVelocity.dx += accelerationX * dt
        idleFloatVelocity.dy += accelerationY * dt
        idleFloatOffset.dx += idleFloatVelocity.dx * dt
        idleFloatOffset.dy += idleFloatVelocity.dy * dt

        if !idleEligible,
           hypot(idleFloatOffset.dx, idleFloatOffset.dy) < 0.03,
           hypot(idleFloatVelocity.dx, idleFloatVelocity.dy) < 0.08 {
            idleFloatOffset = .zero
            idleFloatVelocity = .zero
        }

        renderPointerVisual()

        let recentlyMoving = moveTimer != nil || now - visualLastMotionTime < 0.30
        let contrastInterval = recentlyMoving ? movingContrastSampleInterval : idleContrastSampleInterval
        if now - lastContrastSampleAt >= contrastInterval,
           !contrastSampleInFlight,
           let logical = currentScreenPoint,
           visibilityTransition == nil,
           !hiddenByMinimize,
           let pointerWindow = window,
           pointerWindow.isVisible,
           pointerWindow.windowNumber > 0 {
            lastContrastSampleAt = now
            contrastSampleInFlight = true
            let windowNumber = pointerWindow.windowNumber
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let luminance = Self.sampleBackgroundLuminance(
                    at: logical,
                    excludingWindowNumber: windowNumber
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.contrastSampleInFlight = false
                    if let luminance {
                        self.updateContrastTarget(for: luminance)
                    }
                }
            }
        }

        // Short continuous transition instead of a hard black/white snap. Once
        // settled, stop touching the image tint so idle rendering stays cheap.
        let materialRate: CGFloat = 10.0
        let previousBrightness = adaptiveBrightness
        adaptiveBrightness += (adaptiveTargetBrightness - adaptiveBrightness) * (1.0 - exp(-materialRate * dt))
        if abs(adaptiveTargetBrightness - adaptiveBrightness) < 0.001 {
            adaptiveBrightness = adaptiveTargetBrightness
        }
        if abs(adaptiveBrightness - previousBrightness) > 0.0005 {
            applyAdaptiveMaterial()
        }
    }

    private func randomIdleFloatTarget() -> CGVector {
        // Random points inside an ellipse produce a slow, water-like meander
        // rather than a repeating keyframe loop.
        let minimumDistance: CGFloat = 2.0
        for _ in 0..<8 {
            let angle = CGFloat.random(in: 0...(2.0 * .pi))
            let radius = sqrt(CGFloat.random(in: 0...1))
            let candidate = CGVector(
                dx: cos(angle) * idleFloatRadiusX * radius,
                dy: sin(angle) * idleFloatRadiusY * radius
            )
            if hypot(candidate.dx - idleFloatOffset.dx, candidate.dy - idleFloatOffset.dy) >= minimumDistance {
                return candidate
            }
        }

        // A bounded fallback keeps the pointer moving even when random samples
        // cluster near the current point.  Aim away from the current offset at
        // the ellipse boundary; when centered, use a full-radius random heading.
        let currentDistance = hypot(idleFloatOffset.dx, idleFloatOffset.dy)
        let angle: CGFloat
        if currentDistance > 0.01 {
            angle = atan2(-idleFloatOffset.dy, -idleFloatOffset.dx)
        } else {
            angle = CGFloat.random(in: 0...(2.0 * .pi))
        }
        let radius = max(CGFloat(0.55), CGFloat(1.0))
        return CGVector(
            dx: cos(angle) * idleFloatRadiusX * radius,
            dy: sin(angle) * idleFloatRadiusY * radius
        )
    }

    private func updateContrastTarget(for backgroundLuminance: CGFloat) {
        // Hysteresis avoids rapid black/white chatter on noisy mid-gray content.
        if backgroundLuminance <= 0.43 {
            prefersLightPointer = true
        } else if backgroundLuminance >= 0.57 {
            prefersLightPointer = false
        }
        adaptiveTargetBrightness = prefersLightPointer ? 0.95 : 0.07
    }

    private func applyAdaptiveMaterial() {
        guard let imageView else { return }
        let brightness = min(1.0, max(0.0, adaptiveBrightness))
        imageView.contentTintColor = NSColor(
            srgbRed: brightness,
            green: brightness,
            blue: brightness,
            alpha: 0.96
        )

        let edgeBrightness = 1.0 - brightness
        imageView.layer?.shadowColor = NSColor(
            srgbRed: edgeBrightness,
            green: edgeBrightness,
            blue: edgeBrightness,
            alpha: 1.0
        ).cgColor
    }

    private static func sampleBackgroundLuminance(
        at point: CGPoint,
        excludingWindowNumber windowNumber: Int
    ) -> CGFloat? {
        guard windowNumber > 0 else { return nil }

        let sampleRadius: CGFloat = 3.0
        let sampleRect = CGRect(
            x: point.x - sampleRadius,
            y: point.y - sampleRadius,
            width: sampleRadius * 2.0,
            height: sampleRadius * 2.0
        )

        // Capture only windows below the Pointer overlay so the material never
        // samples its own current tint and feeds back into itself.
        guard let createImage = windowListCreateImage,
              let retained = createImage(
                sampleRect,
                .optionOnScreenBelowWindow,
                CGWindowID(windowNumber),
                [.boundsIgnoreFraming, .bestResolution]
              ) else { return nil }
        let source = retained.takeRetainedValue()

        let width = 10
        let height = 10
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let drewImage = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                  ) else { return false }
            context.interpolationQuality = .low
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drewImage else { return nil }

        var total: CGFloat = 0
        var count: CGFloat = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = CGFloat(pixels[index + 3]) / 255.0
            if alpha < 0.05 { continue }
            let r = CGFloat(pixels[index]) / 255.0
            let g = CGFloat(pixels[index + 1]) / 255.0
            let b = CGFloat(pixels[index + 2]) / 255.0
            total += 0.2126 * r + 0.7152 * g + 0.0722 * b
            count += 1.0
        }
        return count > 0 ? total / count : nil
    }

    private func setWindowHotspot(to point: CGPoint) {
        guard let win = window else { return }
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        let size = win.frame.size
        let screenTopLeft = CGPoint(
            x: point.x - canvasHotspot.x,
            y: point.y - canvasHotspot.y
        )
        let appKitOrigin = NSPoint(
            x: screenTopLeft.x,
            y: mainHeight - screenTopLeft.y - size.height
        )
        win.setFrameOrigin(appKitOrigin)
    }

    private func currentTargetWindowBounds(_ windowID: Int) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            CGWindowID(windowID)
        ) as? [[String: Any]],
        let info = list.first,
        let dictionary = info[kCGWindowBounds as String] as? NSDictionary else {
            return nil
        }
        var bounds = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(dictionary, &bounds) else { return nil }
        return bounds
    }

    private func targetWindowVisibility(_ windowID: Int) -> (exists: Bool, onScreen: Bool) {
        guard let allWindows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
              let onScreenWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            // Fail open: a WindowServer query failure must never hide a healthy pointer.
            return (true, true)
        }

        let matchesID: ([String: Any]) -> Bool = { item in
            (item[kCGWindowNumber as String] as? NSNumber)?.intValue == windowID
        }
        let exists = allWindows.contains(where: matchesID)
        let onScreen = onScreenWindows.contains(where: matchesID)
        return (exists, onScreen)
    }

    private func rightEdgePoint(for point: CGPoint) -> CGPoint {
        let display = CGDisplayBounds(CGMainDisplayID())
        let extra = max(imageSize.width * maxPulseScale + 16.0, 48.0)
        return CGPoint(x: display.maxX + extra, y: point.y)
    }

    private func beginMinimizeTransition() {
        guard let current = currentScreenPoint else { return }

        moveTimer?.invalidate()
        moveTimer = nil
        pulseTimer?.invalidate()
        pulseTimer = nil
        pendingPulse = false
        applyImageScale(1.0)
        followVelocity = .zero

        // Minimize is now a purely visual fade at the current pointer position.
        // The logical point and click executor remain completely untouched.
        startVisibilityTransition(.minimizing, from: current, to: current)
    }

    private func beginRestoreTransition(windowID: Int) {
        guard let local = targetLocalPoint,
              let bounds = currentTargetWindowBounds(windowID) else { return }

        let target = CGPoint(
            x: bounds.origin.x + local.x,
            y: bounds.origin.y + local.y
        )

        moveTimer?.invalidate()
        moveTimer = nil
        pulseTimer?.invalidate()
        pulseTimer = nil
        pendingPulse = false
        applyImageScale(1.0)
        followVelocity = .zero

        currentScreenPoint = target
        destinationScreenPoint = target
        setWindowHotspot(to: target)
        window?.alphaValue = 0.0
        hiddenByMinimize = false
        pinAboveTarget()
        startVisibilityTransition(.restoring, from: target, to: target)
    }

    private func startVisibilityTransition(
        _ transition: VisibilityTransition,
        from start: CGPoint,
        to end: CGPoint
    ) {
        visibilityTimer?.invalidate()
        visibilityTransition = transition
        visibilityStartPoint = start
        visibilityEndPoint = end
        visibilityStartedAt = ProcessInfo.processInfo.systemUptime

        let timer = Timer(timeInterval: visibilityTick, repeats: true) { [weak self] timer in
            self?.stepVisibilityTransition(timer)
        }
        visibilityTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stepVisibilityTransition(_ timer: Timer) {
        guard let transition = visibilityTransition else {
            timer.invalidate()
            visibilityTimer = nil
            return
        }

        let elapsed = ProcessInfo.processInfo.systemUptime - visibilityStartedAt
        let rawT = min(1.0, elapsed / visibilityDuration)
        let t = smoothstep(rawT)
        let point = CGPoint(
            x: visibilityStartPoint.x + (visibilityEndPoint.x - visibilityStartPoint.x) * t,
            y: visibilityStartPoint.y + (visibilityEndPoint.y - visibilityStartPoint.y) * t
        )
        currentScreenPoint = point
        setWindowHotspot(to: point)

        switch transition {
        case .restoring:
            window?.alphaValue = CGFloat(t)
            pinAboveTarget()
        case .minimizing:
            window?.alphaValue = 1.0 - CGFloat(t)
        }

        if rawT >= 1.0 {
            timer.invalidate()
            visibilityTimer = nil
            visibilityTransition = nil
            currentScreenPoint = visibilityEndPoint

            switch transition {
            case .minimizing:
                window?.alphaValue = 0.0
                window?.orderOut(nil)
                hiddenByMinimize = true
            case .restoring:
                window?.alphaValue = 1.0
                setWindowHotspot(to: visibilityEndPoint)
                pinAboveTarget()
                hiddenByMinimize = false
            }
        }
    }

    private func cancelVisibilityTransition() {
        visibilityTimer?.invalidate()
        visibilityTimer = nil
        visibilityTransition = nil
    }

    private func stepWindowFollow() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = followLastTime > 0 ? now - followLastTime : followTick
        followLastTime = now

        guard let windowID = targetWindowID else { return }
        let visibility = targetWindowVisibility(windowID)

        if visibility.exists {
            if visibility.onScreen {
                offScreenSamples = 0
                if targetWasOnScreen == false {
                    targetWasOnScreen = true
                    beginRestoreTransition(windowID: windowID)
                    return
                }
                targetWasOnScreen = true
            } else {
                offScreenSamples += 1
                // Require two consecutive 30 Hz samples so one-frame WindowServer
                // bookkeeping gaps never trigger the minimize transition.
                if targetWasOnScreen != false && offScreenSamples >= 2 {
                    targetWasOnScreen = false
                    beginMinimizeTransition()
                }
                return
            }
        } else {
            // A destroyed/closed target must never leave an orphan pointer on the desktop.
            // This is not a minimize transition, so hide immediately without animation.
            cancelAnimations()
            cancelVisibilityTransition()
            window?.orderOut(nil)
            targetWindowID = nil
            targetLocalPoint = nil
            currentScreenPoint = nil
            destinationScreenPoint = nil
            followVelocity = .zero
            targetWasOnScreen = nil
            offScreenSamples = 0
            hiddenByMinimize = false
            return
        }

        if visibilityTransition != nil || hiddenByMinimize {
            return
        }

        pinAboveTarget()

        // Direct model-driven pointer travel owns the position until it reaches
        // the new click target. Window-follow inertia resumes immediately after.
        guard moveTimer == nil,
              let local = targetLocalPoint,
              let current = currentScreenPoint,
              let bounds = currentTargetWindowBounds(windowID) else {
            return
        }

        let target = CGPoint(
            x: bounds.origin.x + local.x,
            y: bounds.origin.y + local.y
        )
        let dt = CGFloat(min(0.08, max(1.0 / 120.0, elapsed)))
        let errorX = target.x - current.x
        let errorY = target.y - current.y

        let accelerationX = followSpring * errorX - followDamping * followVelocity.dx
        let accelerationY = followSpring * errorY - followDamping * followVelocity.dy
        followVelocity.dx += accelerationX * dt
        followVelocity.dy += accelerationY * dt

        let speed = hypot(followVelocity.dx, followVelocity.dy)
        if speed > followMaxSpeed {
            let scale = followMaxSpeed / speed
            followVelocity.dx *= scale
            followVelocity.dy *= scale
        }

        var next = CGPoint(
            x: current.x + followVelocity.dx * dt,
            y: current.y + followVelocity.dy * dt
        )

        // Once both position and velocity are tiny, settle exactly onto the
        // window-local anchor instead of leaving sub-pixel drift forever.
        if hypot(target.x - next.x, target.y - next.y) < 0.20,
           hypot(followVelocity.dx, followVelocity.dy) < 3.0 {
            next = target
            followVelocity = .zero
        }

        currentScreenPoint = next
        destinationScreenPoint = target
        setWindowHotspot(to: next)
    }

    private func currentTargetWindowInfo(_ windowID: Int) -> TargetWindowInfo? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        guard let target = windows.first(where: {
            ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == windowID
        }),
        let pidNumber = target[kCGWindowOwnerPID as String] as? NSNumber,
        let layerNumber = target[kCGWindowLayer as String] as? NSNumber else {
            return nil
        }

        let pid = pidNumber.int32Value
        let layer = layerNumber.intValue
        let foremostWindowID = windows.first(where: { item in
            (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid &&
            (item[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
        }).flatMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue }
        let foremost = layer == 0 && foremostWindowID == windowID
        return TargetWindowInfo(pid: pid, layer: layer, isForemostNormalOnScreen: foremost)
    }

    private func shouldUseProtectedLevel(_ info: TargetWindowInfo) -> Bool {
        guard info.layer == 0, info.isForemostNormalOnScreen else { return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == info.pid
    }

    private func pinAboveTarget() {
        guard let win = window, let target = targetWindowID else { return }
        if let info = currentTargetWindowInfo(target), shouldUseProtectedLevel(info) {
            // Keep the pointer one WindowServer layer above the foreground
            // target's normal layer, without becoming a global topmost window.
            let protectedLevel = NSWindow.Level(rawValue: info.layer + 1)
            if win.level.rawValue != protectedLevel.rawValue {
                win.level = protectedLevel
            }
            win.orderFrontRegardless()
            return
        }

        if win.level.rawValue != NSWindow.Level.normal.rawValue {
            win.level = .normal
        }
        win.order(.above, relativeTo: target)
    }

    private func cancelAnimations() {
        moveTimer?.invalidate()
        moveTimer = nil
        pulseTimer?.invalidate()
        pulseTimer = nil
        pendingPulse = false
        applyImageScale(1.0)
    }
}

let imagePath = CommandLine.arguments.dropFirst().first ?? ""
if imagePath.isEmpty {
    FileHandle.standardError.write(Data("usage: VelaPointer <pointer-image-path>\n".utf8))
    exit(64)
}

let app = NSApplication.shared
private let delegate = PointerController(imagePath: imagePath)
app.delegate = delegate
app.run()
