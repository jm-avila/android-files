// Drives the mouse for functional drag tests (needs Accessibility for the app that runs it).
// Every click and drag first checks that the window under each point belongs to $MOUSE_OWNER_PID
// (or the pid given as MOUSE_ALLOW_PIDS, comma-separated), and refuses otherwise: never click another app by mistake.
// A Finder window under a point must be titled $MOUSE_FINDER_TITLE (the test folder).
//   swift tools/mouse.swift windows <owner>          print "id x y w h title" for the owner's windows
//   swift tools/mouse.swift drag x1 y1 x2 y2 [opt|cmd]  press at (x1,y1), drag to (x2,y2), release
//   swift tools/mouse.swift click x y [double|cmd|shift]
//   swift tools/mouse.swift move <pid> <index> x y [w h]  move (and size) the pid's window number <index> (0 = front)
//   swift tools/mouse.swift count <pid>               print how many windows the pid has
//   swift tools/mouse.swift key <pid> <keycode> [cmd|opt|shift...]   press a key in that app
import AppKit
import CoreGraphics

let args = CommandLine.arguments.dropFirst().map { $0 }
func post(_ type: CGEventType, _ p: CGPoint, flags: CGEventFlags = [], clicks: Int64 = 1) {
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)!
    e.flags = flags
    e.setIntegerValueField(.mouseEventClickState, value: clicks)
    e.post(tap: .cghidEventTap)
}
/// The pid and title of the frontmost normal window under `p` (CG coordinates, y down).
func window(at p: CGPoint) -> (pid: Int, name: String, title: String)? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
    for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
        let b = w[kCGWindowBounds as String] as! [String: CGFloat]
        if CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!).contains(p) {
            return (w[kCGWindowOwnerPID as String] as? Int ?? 0, w[kCGWindowOwnerName as String] as? String ?? "",
                    w[kCGWindowName as String] as? String ?? "")
        }
    }
    return nil
}

func owner(at p: CGPoint) -> Int? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
    for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
        let b = w[kCGWindowBounds as String] as! [String: CGFloat]
        if CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!).contains(p) {
            return w[kCGWindowOwnerPID as String] as? Int
        }
    }
    return nil
}

func guardPoints(_ points: [CGPoint]) {
    let env = ProcessInfo.processInfo.environment
    let allowed = Set((env["MOUSE_ALLOW_PIDS"] ?? env["MOUSE_OWNER_PID"] ?? "").split(separator: ",").compactMap { Int($0) })
    guard !allowed.isEmpty else { print("refused: set MOUSE_OWNER_PID"); exit(2) }
    for p in points {
        let who = owner(at: p)
        guard let who, allowed.contains(who) else { print("refused: \(p) is over pid \(who.map(String.init) ?? "none")"); exit(2) }
        // A Finder window may only be the test folder (MOUSE_FINDER_TITLE): never drop into real folders.
        if let w = window(at: p), w.name == "Finder", w.title != env["MOUSE_FINDER_TITLE"] {
            print("refused: Finder window under \(p) is “\(w.title)”, not the test folder"); exit(2)
        }
    }
}

switch args.first {
case "windows":
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
    for w in list where (w[kCGWindowOwnerName as String] as? String) == args[1] {
        let b = w[kCGWindowBounds as String] as! [String: CGFloat]
        print(w[kCGWindowNumber as String]!, Int(b["X"]!), Int(b["Y"]!), Int(b["Width"]!), Int(b["Height"]!),
              w[kCGWindowName as String] as? String ?? "")
    }
case "drag":
    let a = CGPoint(x: Double(args[1])!, y: Double(args[2])!), b = CGPoint(x: Double(args[3])!, y: Double(args[4])!)
    let flags: CGEventFlags = args.count > 5 ? (args[5] == "opt" ? .maskAlternate : .maskCommand) : []
    guardPoints([a, b])
    post(.mouseMoved, a); usleep(150_000)
    post(.leftMouseDown, a); usleep(250_000)
    // A real modifier key: down part way through the drag, up after the drop.
    let modifierKey: CGKeyCode = flags.contains(.maskCommand) ? 55 : 58
    func modifier(_ down: Bool) {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: modifierKey, keyDown: down)!
        e.type = .flagsChanged
        e.flags = down ? flags : []
        e.post(tap: .cghidEventTap)
    }
    // Start like a hand does: a few small moves first, so the drag begins on the pressed row.
    for i in 1...4 {
        post(.leftMouseDragged, CGPoint(x: a.x + Double(i) * 2, y: a.y), flags: [])
        usleep(30_000)
    }
    for i in 1...30 {
        let t = Double(i) / 30
        if i == 20 && !flags.isEmpty { modifier(true) }
        post(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), flags: i >= 20 ? flags : [])
        usleep(30_000)
    }
    usleep(400_000)
    if let shot = ProcessInfo.processInfo.environment["MOUSE_SHOT"] {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-R", "\(Int(min(a.x, b.x)) - 300),\(Int(min(a.y, b.y)) - 150),\(Int(abs(a.x - b.x)) + 600),\(Int(abs(a.y - b.y)) + 300)", shot]
        try? p.run(); p.waitUntilExit()
    }
    post(.leftMouseUp, b, flags: flags)
    if !flags.isEmpty { usleep(100_000); modifier(false) }
case "click":
    let p = CGPoint(x: Double(args[1])!, y: Double(args[2])!)
    let mode = args.count > 3 ? args[3] : ""
    let n: Int64 = mode == "double" ? 2 : 1
    let flags: CGEventFlags = mode == "cmd" ? .maskCommand : mode == "shift" ? .maskShift : []
    guardPoints([p])
    post(.mouseMoved, p); usleep(100_000)
    for c in 1...n {
        post(.leftMouseDown, p, flags: flags, clicks: c); usleep(50_000)
        post(.leftMouseUp, p, flags: flags, clicks: c); usleep(80_000)
    }
case "move":
    let app = AXUIElementCreateApplication(pid_t(args[1])!)
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
    let windows = (value as? [AXUIElement]) ?? []
    let index = Int(args[2])!
    guard index < windows.count else { print("no window \(index) of \(windows.count)"); exit(1) }
    var point = CGPoint(x: Double(args[3])!, y: Double(args[4])!)
    AXUIElementSetAttributeValue(windows[index], kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &point)!)
    if args.count > 6 {
        var size = CGSize(width: Double(args[5])!, height: Double(args[6])!)
        AXUIElementSetAttributeValue(windows[index], kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
    }
case "count":
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid_t(args[1])!), kAXWindowsAttribute as CFString, &value)
    print((value as? [AXUIElement])?.count ?? 0)
case "activate":
    NSRunningApplication(processIdentifier: pid_t(args[1])!)?.activate()
    usleep(400_000)
case "key":
    let pid = pid_t(args[1])!
    NSRunningApplication(processIdentifier: pid)?.activate()
    usleep(300_000)
    var flags: CGEventFlags = []
    for m in args.dropFirst(3) {
        flags.insert(m == "cmd" ? .maskCommand : m == "opt" ? .maskAlternate : m == "shift" ? .maskShift : [])
    }
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(args[2])!, keyDown: down)!
        e.flags = flags
        e.post(tap: .cghidEventTap)
        usleep(50_000)
    }
default:
    print("usage: mouse.swift windows <owner> | drag x1 y1 x2 y2 [opt|cmd] | click x y [double]")
}
