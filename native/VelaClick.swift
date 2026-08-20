import Foundation
import CoreGraphics
import AppKit
import Darwin

// VelaClick v0.3.0
// Stateless, background, pixel-only mouse delivery for one macOS window.
// No daemon, socket, session, AX tree, DOM lookup, or physical cursor warp.

private let velaClickVersion = "0.3.0"

private typealias SLEventPostToPidFn = @convention(c) (pid_t, CGEvent) -> Void
private typealias CGEventSetWindowLocationFn = @convention(c) (CGEvent, Double, Double) -> Void
private typealias SLEventSetIntegerValueFieldFn = @convention(c) (CGEvent, UInt32, Int64) -> Void

private final class SkyLight {
    static let shared = SkyLight()

    private let handle: UnsafeMutableRawPointer?
    private let postToPidSPI: SLEventPostToPidFn?
    private let setWindowLocationSPI: CGEventSetWindowLocationFn?
    private let setIntegerFieldSPI: SLEventSetIntegerValueFieldFn?

    private init() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        let loaded = dlopen(path, RTLD_LAZY | RTLD_GLOBAL)
        handle = loaded

        func load<T>(_ name: String, as type: T.Type) -> T? {
            guard let loaded, let symbol = dlsym(loaded, name) else { return nil }
            return unsafeBitCast(symbol, to: type)
        }

        postToPidSPI = load("SLEventPostToPid", as: SLEventPostToPidFn.self)
        setWindowLocationSPI = load("CGEventSetWindowLocation", as: CGEventSetWindowLocationFn.self)
        setIntegerFieldSPI = load("SLEventSetIntegerValueField", as: SLEventSetIntegerValueFieldFn.self)
    }

    func post(
        _ event: CGEvent,
        pid: pid_t,
        windowID: UInt32,
        localPoint: CGPoint,
        clickGroupID: Int64,
        clickState: Int64,
        buttonNumber: Int64,
        subtype: Int64 = 3
    ) throws {
        guard let postToPidSPI,
              let setWindowLocationSPI,
              let setIntegerFieldSPI else {
            throw VelaClickError.skylightUnavailable
        }

        setWindowLocationSPI(event, localPoint.x, localPoint.y)
        setIntegerFieldSPI(event, 1, clickState)
        setIntegerFieldSPI(event, 3, buttonNumber)
        setIntegerFieldSPI(event, 7, subtype)
        setIntegerFieldSPI(event, 40, Int64(pid))
        setIntegerFieldSPI(event, 51, Int64(windowID))
        setIntegerFieldSPI(event, 58, clickGroupID)
        setIntegerFieldSPI(event, 91, Int64(windowID))
        setIntegerFieldSPI(event, 92, Int64(windowID))

        postToPidSPI(pid, event)
        event.postToPid(pid)
    }
}

private enum VelaClickError: Error, CustomStringConvertible {
    case badArguments
    case invalidPID
    case invalidWindowID
    case invalidAction
    case invalidButton
    case eventSourceFailed
    case eventCreationFailed(String)
    case skylightUnavailable

    var description: String {
        switch self {
        case .badArguments:
            return "usage: velaclick <click|down|up> <left|right|middle> <pid> <window_id> <screen_x> <screen_y> <local_x> <local_y>"
        case .invalidPID: return "invalid pid"
        case .invalidWindowID: return "invalid window_id"
        case .invalidAction: return "invalid action; expected click, down, or up"
        case .invalidButton: return "invalid button; expected left, right, or middle"
        case .eventSourceFailed: return "CGEventSource creation failed"
        case .eventCreationFailed(let kind): return "CGEvent creation failed: \(kind)"
        case .skylightUnavailable: return "required SkyLight mouse symbols are unavailable"
        }
    }
}

private enum MouseAction: String { case click, down, up }

private enum MouseButton: String {
    case left, right, middle

    var cgButton: CGMouseButton {
        switch self {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        }
    }

    var buttonNumber: Int64 {
        switch self {
        case .left: return 0
        case .right: return 1
        case .middle: return 2
        }
    }

    var downType: CGEventType {
        switch self {
        case .left: return .leftMouseDown
        case .right: return .rightMouseDown
        case .middle: return .otherMouseDown
        }
    }

    var upType: CGEventType {
        switch self {
        case .left: return .leftMouseUp
        case .right: return .rightMouseUp
        case .middle: return .otherMouseUp
        }
    }
}

private struct ClickTarget {
    let pid: pid_t
    let windowID: UInt32
    let screen: CGPoint
    let local: CGPoint
}

private func cursorLocation() -> CGPoint? {
    CGEvent(source: nil)?.location
}

private func makeMouseEvent(source: CGEventSource, type: CGEventType, point: CGPoint, button: MouseButton) throws -> CGEvent {
    guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button.cgButton) else {
        throw VelaClickError.eventCreationFailed(String(describing: type))
    }
    return event
}

private final class VelaClick {
    private let pid: pid_t
    private let windowID: UInt32
    private let windowOrigin: CGPoint
    private let source: CGEventSource
    private var pressedGroups: [MouseButton: Int64] = [:]

    init(pid: pid_t, windowID: UInt32, windowOrigin: CGPoint) throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw VelaClickError.eventSourceFailed
        }
        self.pid = pid
        self.windowID = windowID
        self.windowOrigin = windowOrigin
        self.source = source
    }

    func mouse(_ action: MouseAction, _ button: MouseButton, x: Double, y: Double) throws {
        let target = ClickTarget(
            pid: pid,
            windowID: windowID,
            screen: CGPoint(x: windowOrigin.x + x, y: windowOrigin.y + y),
            local: CGPoint(x: x, y: y)
        )

        switch action {
        case .click:
            let group = newGroupID()
            try prime(target: target, group: group)
            usleep(12_000)
            try send(.down, button: button, target: target, group: group, clickState: 1)
            usleep(28_000)
            try send(.up, button: button, target: target, group: group, clickState: 1)

        case .down:
            let group = newGroupID()
            pressedGroups[button] = group
            try prime(target: target, group: group)
            usleep(12_000)
            try send(.down, button: button, target: target, group: group, clickState: 1)

        case .up:
            let group = pressedGroups.removeValue(forKey: button) ?? newGroupID()
            try send(.up, button: button, target: target, group: group, clickState: 1)
        }
    }

    private enum Edge { case down, up }

    private func prime(target: ClickTarget, group: Int64) throws {
        let move = try makeMouseEvent(source: source, type: .mouseMoved, point: target.screen, button: .left)
        try SkyLight.shared.post(
            move,
            pid: target.pid,
            windowID: target.windowID,
            localPoint: target.local,
            clickGroupID: group,
            clickState: 0,
            buttonNumber: 0
        )
    }

    private func send(_ edge: Edge, button: MouseButton, target: ClickTarget, group: Int64, clickState: Int64) throws {
        let type = edge == .down ? button.downType : button.upType
        let event = try makeMouseEvent(source: source, type: type, point: target.screen, button: button)
        try SkyLight.shared.post(
            event,
            pid: target.pid,
            windowID: target.windowID,
            localPoint: target.local,
            clickGroupID: group,
            clickState: clickState,
            buttonNumber: button.buttonNumber
        )
    }

    private func newGroupID() -> Int64 {
        let micros = Int64(Date().timeIntervalSince1970 * 1_000_000)
        return (micros ^ Int64(getpid())) & Int64.max
    }
}

private struct CLIRequest {
    let action: MouseAction
    let button: MouseButton
    let pid: pid_t
    let windowID: UInt32
    let screen: CGPoint
    let local: CGPoint
}

private func parseRequest() throws -> CLIRequest {
    guard CommandLine.arguments.count == 9 else { throw VelaClickError.badArguments }
    guard let action = MouseAction(rawValue: CommandLine.arguments[1]) else { throw VelaClickError.invalidAction }
    guard let button = MouseButton(rawValue: CommandLine.arguments[2]) else { throw VelaClickError.invalidButton }
    guard let pidValue = Int32(CommandLine.arguments[3]), pidValue > 0 else { throw VelaClickError.invalidPID }
    guard let windowValue = UInt32(CommandLine.arguments[4]), windowValue > 0 else { throw VelaClickError.invalidWindowID }
    guard let screenX = Double(CommandLine.arguments[5]),
          let screenY = Double(CommandLine.arguments[6]),
          let localX = Double(CommandLine.arguments[7]),
          let localY = Double(CommandLine.arguments[8]) else {
        throw VelaClickError.badArguments
    }
    return CLIRequest(
        action: action,
        button: button,
        pid: pidValue,
        windowID: windowValue,
        screen: CGPoint(x: screenX, y: screenY),
        local: CGPoint(x: localX, y: localY)
    )
}

@main
struct VelaClickCLI {
    static func main() {
        do {
            let request = try parseRequest()
            let origin = CGPoint(x: request.screen.x - request.local.x, y: request.screen.y - request.local.y)
            let clicker = try VelaClick(pid: request.pid, windowID: request.windowID, windowOrigin: origin)
            let before = cursorLocation()
            let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
            try clicker.mouse(request.action, request.button, x: request.local.x, y: request.local.y)
            let after = cursorLocation()
            let frontAfter = NSWorkspace.shared.frontmostApplication?.processIdentifier

            let dx = (before != nil && after != nil) ? after!.x - before!.x : 0
            let dy = (before != nil && after != nil) ? after!.y - before!.y : 0
            let cursorMoved = abs(dx) > 0.01 || abs(dy) > 0.01

            let result: [String: Any] = [
                "ok": true,
                "version": velaClickVersion,
                "action": request.action.rawValue,
                "button": request.button.rawValue,
                "pid": Int(request.pid),
                "window_id": Int(request.windowID),
                "screen_x": request.screen.x,
                "screen_y": request.screen.y,
                "local_x": request.local.x,
                "local_y": request.local.y,
                "post_event_access": CGPreflightPostEventAccess(),
                "physical_cursor_moved": cursorMoved,
                "cursor_dx": dx,
                "cursor_dy": dy,
                "front_pid_before": frontBefore.map(Int.init) as Any,
                "front_pid_after": frontAfter.map(Int.init) as Any,
                "front_app_changed": frontBefore != frontAfter,
                "route": "velaclick_skylight_xy"
            ]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0a]))
            exit(cursorMoved ? 2 : 0)
        } catch {
            FileHandle.standardError.write(Data("VelaClick error: \(error)\n".utf8))
            exit(1)
        }
    }
}
