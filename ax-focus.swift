// ax-focus: raise the window of an app whose accessibility tree contains a
// marker string. Used to focus the exact VS Code window hosting a terminal
// whose tab title was just set to the marker.
//
// usage: ax-focus <bundle-id> <needle>
// exit:  0 matched+raised, 1 no match, 2 bad args, 3 app not running

import ApplicationServices
import AppKit

let args = CommandLine.arguments

// @check: report (and prompt for) accessibility trust of this process.
if args.count >= 2 && args[1] == "@check" {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    let trusted = AXIsProcessTrustedWithOptions(opts)
    print(trusted ? "trusted" : "untrusted")
    exit(trusted ? 0 : 1)
}

guard args.count >= 3 else {
    FileHandle.standardError.write("usage: ax-focus @check | <bundle-id> <@activate|needle>\n".data(using: .utf8)!)
    exit(2)
}
let bundleId = args[1]
let needle = args[2]

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
    print("app-not-running")
    exit(3)
}

// Activation-only mode: needs no accessibility permission, and unlike
// `open -b` it works from a detached background process.
if needle == "@activate" {
    app.activate(options: [.activateIgnoringOtherApps])
    print("activated")
    exit(0)
}

let axApp = AXUIElementCreateApplication(app.processIdentifier)

// Electron exposes its accessibility tree lazily; this flips it on.
AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}

func children(_ el: AXUIElement) -> [AXUIElement] {
    (attr(el, "AXChildren") as? [AXUIElement]) ?? []
}

func matches(_ el: AXUIElement) -> Bool {
    for key in ["AXTitle", "AXDescription", "AXValue"] {
        if let s = attr(el, key) as? String, s.contains(needle) { return true }
    }
    return false
}

func find(_ el: AXUIElement, depth: Int) -> AXUIElement? {
    if depth > 60 { return nil }
    if matches(el) { return el }
    for c in children(el) {
        if let hit = find(c, depth: depth + 1) { return hit }
    }
    return nil
}

func parent(_ el: AXUIElement) -> AXUIElement? {
    guard let p = attr(el, "AXParent") else { return nil }
    guard CFGetTypeID(p) == AXUIElementGetTypeID() else { return nil }
    return (p as! AXUIElement)
}

let windows = (attr(axApp, "AXWindows") as? [AXUIElement]) ?? []
for w in windows {
    if let hit = find(w, depth: 0) {
        AXUIElementPerformAction(w, "AXRaise" as CFString)
        app.activate(options: [])

        // Select the terminal tab itself, not just the window — otherwise
        // VS Code leaves whichever terminal was last active in front.
        // AXPress the matched element, climbing to the nearest pressable
        // ancestor (the tab row) if the text element itself isn't pressable.
        var target: AXUIElement? = hit
        var pressed = false
        for _ in 0..<6 {
            guard let t = target else { break }
            if AXUIElementPerformAction(t, "AXPress" as CFString) == .success {
                pressed = true
                break
            }
            target = parent(t)
        }

        let title = (attr(w, "AXTitle") as? String) ?? "?"
        print("matched:\(title):tab-pressed=\(pressed)")
        exit(0)
    }
}
print("no-match")
exit(1)
