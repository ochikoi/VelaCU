import Foundation
import CoreGraphics
import AppKit

struct WindowInfo: Codable {
    let windowID: UInt32
    let pid: Int32
    let owner: String
    let title: String
    let bundleID: String?
    let bundlePath: String?
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let layer: Int
    let alpha: Double
}

struct ClickResult: Codable {
    let ok: Bool
    let windowID: UInt32
    let pid: Int32
    let x: Double
    let y: Double
    let globalX: Double
    let globalY: Double
    let cursorBeforeX: Double
    let cursorBeforeY: Double
    let cursorAfterX: Double
    let cursorAfterY: Double
}

struct KeyResult: Codable {
    let ok: Bool
    let key: String
}

struct TypeResult: Codable {
    let ok: Bool
    let characters: Int
}

func allWindows() -> [WindowInfo] {
    guard let raw = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        return []
    }

    var result: [WindowInfo] = []
    for item in raw {
        guard
            let number = item[kCGWindowNumber as String] as? NSNumber,
            let ownerPID = item[kCGWindowOwnerPID as String] as? NSNumber,
            let ownerName = item[kCGWindowOwnerName as String] as? String,
            let boundsDict = item[kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { continue }

        let layer = (item[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        let alpha = (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
        let title = (item[kCGWindowName as String] as? String) ?? ""

        guard layer == 0, alpha > 0.01, bounds.width >= 80, bounds.height >= 60 else { continue }

        let app = NSRunningApplication(processIdentifier: ownerPID.int32Value)
        result.append(WindowInfo(
            windowID: number.uint32Value,
            pid: ownerPID.int32Value,
            owner: ownerName,
            title: title,
            bundleID: app?.bundleIdentifier,
            bundlePath: app?.bundleURL?.path,
            x: bounds.origin.x,
            y: bounds.origin.y,
            width: bounds.size.width,
            height: bounds.size.height,
            layer: layer,
            alpha: alpha
        ))
    }

    return result.sorted { a, b in
        let aa = a.width * a.height
        let ba = b.width * b.height
        if aa == ba { return a.windowID < b.windowID }
        return aa > ba
    }
}

func windowByID(_ id: UInt32) -> WindowInfo? {
    allWindows().first { $0.windowID == id }
}

func emitJSON<T: Encodable>(_ value: T) throws {
    let data = try JSONEncoder().encode(value)
    guard let string = String(data: data, encoding: .utf8) else {
        throw NSError(domain: "VelaCU", code: 1, userInfo: [NSLocalizedDescriptionKey: "JSON encoding failed"])
    }
    print(string)
}

func cursorPosition() -> CGPoint {
    CGEvent(source: nil)?.location ?? .zero
}

func tagTargetWindow(_ event: CGEvent, windowID: UInt32, pid: Int32) {
    event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
    event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
    event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
}

func postGlobalMouse(window: WindowInfo, normalizedX: Double, normalizedY: Double) throws {
    let point = CGPoint(
        x: window.x + window.width * normalizedX / 10.0,
        y: window.y + window.height * normalizedY / 10.0
    )
    let source = CGEventSource(stateID: .combinedSessionState)
    guard
        let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
        let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
    else { throw NSError(domain: "VelaCU", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not create global mouse event"]) }
    down.setIntegerValueField(.mouseEventClickState, value: 1)
    up.setIntegerValueField(.mouseEventClickState, value: 1)
    tagTargetWindow(down, windowID: window.windowID, pid: window.pid)
    tagTargetWindow(up, windowID: window.windowID, pid: window.pid)
    down.post(tap: .cghidEventTap)
    usleep(25_000)
    up.post(tap: .cghidEventTap)
    usleep(45_000)
}

func focusClick(window: WindowInfo, normalizedX: Double, normalizedY: Double) throws -> [String: Double] {
    let before = cursorPosition()
    let previousPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1

    if previousPID != window.pid {
        if let target = NSRunningApplication(processIdentifier: pid_t(window.pid)) {
            _ = target.activate(options: [.activateAllWindows])
            usleep(90_000)
        }
    }

    try postGlobalMouse(window: window, normalizedX: normalizedX, normalizedY: normalizedY)
    CGWarpMouseCursorPosition(before)
    usleep(10_000)

    if previousPID > 0, previousPID != window.pid,
       let previous = NSRunningApplication(processIdentifier: previousPID) {
        _ = previous.activate(options: [.activateAllWindows])
    }

    let after = cursorPosition()
    return [
        "beforeX": before.x,
        "beforeY": before.y,
        "afterX": after.x,
        "afterY": after.y,
        "previousPID": Double(previousPID),
        "targetPID": Double(window.pid),
    ]
}

func postMouse(window: WindowInfo, normalizedX: Double, normalizedY: Double, buttonName: String, count: Int) throws {
    guard (0...10).contains(normalizedX), (0...10).contains(normalizedY) else {
        throw NSError(domain: "VelaCU", code: 2, userInfo: [NSLocalizedDescriptionKey: "x/y must be in 0...10"])
    }

    let point = CGPoint(
        x: window.x + window.width * normalizedX / 10.0,
        y: window.y + window.height * normalizedY / 10.0
    )

    let source = CGEventSource(stateID: .privateState)
    let isRight = buttonName.lowercased() == "right"
    let button: CGMouseButton = isRight ? .right : .left
    let downType: CGEventType = isRight ? .rightMouseDown : .leftMouseDown
    let upType: CGEventType = isRight ? .rightMouseUp : .leftMouseUp

    if let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: button) {
        tagTargetWindow(move, windowID: window.windowID, pid: window.pid)
        move.postToPid(pid_t(window.pid))
    }

    let clickCount = max(1, min(count, 3))
    for i in 1...clickCount {
        guard
            let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: point, mouseButton: button),
            let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: point, mouseButton: button)
        else {
            throw NSError(domain: "VelaCU", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not create mouse event"])
        }

        down.setIntegerValueField(.mouseEventClickState, value: Int64(i))
        up.setIntegerValueField(.mouseEventClickState, value: Int64(i))
        tagTargetWindow(down, windowID: window.windowID, pid: window.pid)
        tagTargetWindow(up, windowID: window.windowID, pid: window.pid)
        down.postToPid(pid_t(window.pid))
        usleep(25_000)
        up.postToPid(pid_t(window.pid))
        usleep(45_000)
    }
}

let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
    "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
    "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
    "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
    "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
    "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
    "n": 45, "m": 46, ".": 47, "`": 50,
    "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51,
    "backspace": 51, "escape": 53, "esc": 53, "forward_delete": 117,
    "left": 123, "right": 124, "down": 125, "up": 126, "home": 115,
    "end": 119, "pageup": 116, "pagedown": 121,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
    "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
]

func keySpec(_ raw: String) throws -> (CGKeyCode, CGEventFlags) {
    let pieces = raw
        .split(separator: "+", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    guard !pieces.isEmpty, pieces.allSatisfy({ !$0.isEmpty }) else {
        throw NSError(domain: "VelaCU", code: 20, userInfo: [NSLocalizedDescriptionKey: "key must not be empty"])
    }

    var flags = CGEventFlags(rawValue: 0)
    for modifier in pieces.dropLast() {
        switch modifier {
        case "cmd", "command": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "option", "alt", "alternate": flags.insert(.maskAlternate)
        case "ctrl", "control": flags.insert(.maskControl)
        default:
            throw NSError(domain: "VelaCU", code: 21, userInfo: [NSLocalizedDescriptionKey: "Unknown modifier: \(modifier)"])
        }
    }

    let finalKey = pieces[pieces.count - 1]
    guard let code = keyCodes[finalKey] else {
        throw NSError(domain: "VelaCU", code: 22, userInfo: [NSLocalizedDescriptionKey: "Unsupported key: \(finalKey)"])
    }
    return (code, flags)
}

func postKey(window: WindowInfo, rawKey: String) throws {
    let (code, flags) = try keySpec(rawKey)
    let source = CGEventSource(stateID: .privateState)
    guard
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
    else {
        throw NSError(domain: "VelaCU", code: 23, userInfo: [NSLocalizedDescriptionKey: "Could not create keyboard event"])
    }
    down.flags = flags
    up.flags = flags
    down.postToPid(pid_t(window.pid))
    usleep(3_000)
    up.postToPid(pid_t(window.pid))
    usleep(5_000)
}

func postUnicode(window: WindowInfo, text: String) throws {
    guard !text.isEmpty else { return }
    let source = CGEventSource(stateID: .privateState)
    let units = Array(text.utf16)
    var offset = 0
    while offset < units.count {
        let end = min(offset + 20, units.count)
        let chunk = Array(units[offset..<end])
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else {
            throw NSError(domain: "VelaCU", code: 24, userInfo: [NSLocalizedDescriptionKey: "Could not create Unicode keyboard event"])
        }
        chunk.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
        }
        down.postToPid(pid_t(window.pid))
        usleep(3_000)
        up.postToPid(pid_t(window.pid))
        usleep(5_000)
        offset = end
    }
}

let args = CommandLine.arguments

do {
    guard args.count >= 2 else {
        throw NSError(domain: "VelaCU", code: 10, userInfo: [NSLocalizedDescriptionKey: "Usage: VelaCUHelper list|get|click|key|type|cursor"])
    }

    switch args[1] {
    case "list":
        try emitJSON(allWindows())

    case "get":
        guard args.count >= 3, let id = UInt32(args[2]), let window = windowByID(id) else {
            throw NSError(domain: "VelaCU", code: 11, userInfo: [NSLocalizedDescriptionKey: "Window not found"])
        }
        try emitJSON(window)

    case "click":
        guard args.count >= 5,
              let id = UInt32(args[2]),
              let nx = Double(args[3]),
              let ny = Double(args[4]),
              let window = windowByID(id)
        else {
            throw NSError(domain: "VelaCU", code: 12, userInfo: [NSLocalizedDescriptionKey: "Usage: click WINDOW_ID X Y [left|right] [count]"])
        }

        let button = args.count >= 6 ? args[5] : "left"
        let count = args.count >= 7 ? (Int(args[6]) ?? 1) : 1
        let before = cursorPosition()
        try postMouse(window: window, normalizedX: nx, normalizedY: ny, buttonName: button, count: count)
        let after = cursorPosition()

        try emitJSON(ClickResult(
            ok: true,
            windowID: id,
            pid: window.pid,
            x: nx,
            y: ny,
            globalX: window.x + window.width * nx / 10.0,
            globalY: window.y + window.height * ny / 10.0,
            cursorBeforeX: before.x,
            cursorBeforeY: before.y,
            cursorAfterX: after.x,
            cursorAfterY: after.y
        ))

    case "key":
        guard args.count >= 4,
              let id = UInt32(args[2]),
              let window = windowByID(id)
        else {
            throw NSError(domain: "VelaCU", code: 25, userInfo: [NSLocalizedDescriptionKey: "Usage: key WINDOW_ID KEY"])
        }
        let key = args[3]
        try postKey(window: window, rawKey: key)
        try emitJSON(KeyResult(ok: true, key: key))

    case "type":
        guard args.count >= 4,
              let id = UInt32(args[2]),
              let window = windowByID(id)
        else {
            throw NSError(domain: "VelaCU", code: 26, userInfo: [NSLocalizedDescriptionKey: "Usage: type WINDOW_ID TEXT"])
        }
        let text = args[3]
        try postUnicode(window: window, text: text)
        try emitJSON(TypeResult(ok: true, characters: text.count))

    case "global-click":
        guard args.count >= 5,
              let id = UInt32(args[2]),
              let nx = Double(args[3]),
              let ny = Double(args[4]),
              let window = windowByID(id)
        else {
            throw NSError(domain: "VelaCU", code: 14, userInfo: [NSLocalizedDescriptionKey: "Usage: global-click WINDOW_ID X Y"])
        }
        let before = cursorPosition()
        try postGlobalMouse(window: window, normalizedX: nx, normalizedY: ny)
        let after = cursorPosition()
        try emitJSON(["beforeX": before.x, "beforeY": before.y, "afterX": after.x, "afterY": after.y])

    case "focus-click":
        guard args.count >= 5,
              let id = UInt32(args[2]),
              let nx = Double(args[3]),
              let ny = Double(args[4]),
              let window = windowByID(id)
        else {
            throw NSError(domain: "VelaCU", code: 15, userInfo: [NSLocalizedDescriptionKey: "Usage: focus-click WINDOW_ID X Y"])
        }
        try emitJSON(focusClick(window: window, normalizedX: nx, normalizedY: ny))

    case "cursor":
        let p = cursorPosition()
        try emitJSON(["x": p.x, "y": p.y])

    case "permissions":
        try emitJSON(["postEventAccess": CGPreflightPostEventAccess()])

    case "request-post-access":
        try emitJSON(["postEventAccess": CGRequestPostEventAccess()])

    default:
        throw NSError(domain: "VelaCU", code: 13, userInfo: [NSLocalizedDescriptionKey: "Unknown command"])
    }
} catch {
    FileHandle.standardError.write(("VelaCUHelper: \(error.localizedDescription)\n").data(using: .utf8)!)
    exit(1)
}
