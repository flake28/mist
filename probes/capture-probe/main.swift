// Mist — Phase 0, Test 1: selected-text capture probe.
//
// Select text in any app, press Ctrl+Option+M. The probe tries:
//   ax      Accessibility API as-is
//   ax_flag AX again after enabling AXManualAccessibility / AXEnhancedUserInterface
//           (only if plain AX failed; Electron/Chrome expose their tree lazily)
//   cmdc    Simulated Cmd+C, read pasteboard, restore previous clipboard
// Every trial appends rows to a CSV. Ctrl+Option+S prints the summary table.
//
// Usage:  ./mist-probe [results.csv]        run the probe
//         ./mist-probe summary [results.csv] print summary and exit

import AppKit
import ApplicationServices
import Carbon.HIToolbox

// MARK: - Config

let trialsPerApp = 10
let cmdCTimeoutMs = 500.0
let axFlagTimeoutMs = 300.0
let csvHeader = "time,app,bundle,method,ok,ms,chars,detail,restore_ok,window"

var csvPath = "results.csv"
var trialCounts: [String: Int] = [:]
var flaggedPids: Set<pid_t> = []
var lastCopiedTypes = ""

func nowMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

// MARK: - Accessibility capture

func axCopy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success ? value : nil
}

/// Returns (text, path) where path names the AX route that worked.
func axSelectedText(app: AXUIElement) -> (String, String)? {
    guard let focused = axCopy(app, kAXFocusedUIElementAttribute) else { return nil }
    var el = focused as! AXUIElement
    // Web content often reports the selection on an ancestor (the web area), so walk up a few levels.
    for depth in 0..<6 {
        if let s = axCopy(el, kAXSelectedTextAttribute) as? String, !s.isEmpty {
            return (s, "AXSelectedText@\(depth)")
        }
        if let range = axCopy(el, "AXSelectedTextMarkerRange") {
            var value: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(el, "AXStringForTextMarkerRange" as CFString, range, &value) == .success,
               let s = value as? String, !s.isEmpty {
                return (s, "AXTextMarkerRange@\(depth)")
            }
        }
        guard let parent = axCopy(el, kAXParentAttribute) else { break }
        el = parent as! AXUIElement
    }
    return nil
}

/// On failure, record what AX thinks is focused (role chain up to the window) to see where the selection is hidden.
func focusedRoles(app: AXUIElement) -> String {
    guard let focused = axCopy(app, kAXFocusedUIElementAttribute) else { return "focused=none" }
    var el = focused as! AXUIElement, roles: [String] = []
    for _ in 0..<6 {
        roles.append(axCopy(el, kAXRoleAttribute) as? String ?? "?")
        guard let parent = axCopy(el, kAXParentAttribute) else { break }
        el = parent as! AXUIElement
    }
    return "focused=" + roles.joined(separator: ">")
}

func enableAXTree(app: AXUIElement) {
    AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)   // Electron
    AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) // Chromium
}

// MARK: - Clipboard (Cmd+C fallback)

typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

func snapshot(_ pb: NSPasteboard) -> Snapshot {
    (pb.pasteboardItems ?? []).map { item in
        Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t, $0) } })
    }
}

func restore(_ pb: NSPasteboard, _ snap: Snapshot) {
    pb.clearContents()
    let items = snap.map { types -> NSPasteboardItem in
        let item = NSPasteboardItem()
        for (t, data) in types { item.setData(data, forType: t) }
        return item
    }
    if !items.isEmpty { pb.writeObjects(items) }
}

/// Returns (text, totalMs, waitMs, restoreOK). waitMs is nil on timeout.
func cmdCCapture() -> (String?, Double, Double?, Bool) {
    let pb = NSPasteboard.general
    let start = nowMs()
    let snap = snapshot(pb)
    let before = pb.changeCount

    let src = CGEventSource(stateID: .privateState)
    for keyDown in [true, false] {
        let ev = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: keyDown)!
        ev.flags = .maskCommand
        ev.post(tap: .cghidEventTap)
    }

    let sent = nowMs()
    var waitMs: Double?
    while nowMs() - sent < cmdCTimeoutMs {
        if pb.changeCount != before { waitMs = nowMs() - sent; break }
        usleep(2_000)
    }

    guard waitMs != nil else { return (nil, nowMs() - start, nil, snapshot(pb) == snap) }
    let text = pb.string(forType: .string)
    if text == nil { lastCopiedTypes = (pb.types ?? []).map(\.rawValue).joined(separator: " ") }
    restore(pb, snap)
    let total = nowMs() - start
    return (text, total, waitMs, snapshot(pb) == snap)
}

/// Where two captures first diverge, as code points only, so no captured text is stored.
func firstDiff(_ ax: String, _ cmdc: String) -> String {
    let a = Array(ax.unicodeScalars), c = Array(cmdc.unicodeScalars)
    var i = 0
    while i < min(a.count, c.count) && a[i] == c[i] { i += 1 }
    func codes(_ s: [Unicode.Scalar]) -> String {
        i < s.count ? s[i..<min(i + 3, s.count)].map { String(format: "U+%04X", $0.value) }.joined(separator: "+") : "end"
    }
    return "diff@\(i) ax=\(codes(a)) cmdc=\(codes(c)) scalars=\(a.count)/\(c.count)"
}

// MARK: - Trial

func csvField(_ s: String) -> String {
    s.contains(",") || s.contains("\"") ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" : s
}

func appendRow(_ fields: [String]) {
    let line = fields.map(csvField).joined(separator: ",") + "\n"
    if !FileManager.default.fileExists(atPath: csvPath) {
        FileManager.default.createFile(atPath: csvPath, contents: (csvHeader + "\n").data(using: .utf8))
    }
    let h = FileHandle(forWritingAtPath: csvPath)!
    h.seekToEndOfFile()
    h.write(line.data(using: .utf8)!)
    h.closeFile()
}

func waitForModifierRelease() {
    // The hotkey's Ctrl/Option would otherwise leak into the synthetic Cmd+C.
    let deadline = nowMs() + 2_000
    while nowMs() < deadline {
        let f = CGEventSource.flagsState(.hidSystemState)
        if !f.contains(.maskControl) && !f.contains(.maskAlternate) { return }
        usleep(5_000)
    }
}

func runTrial() {
    waitForModifierRelease()
    guard let front = NSWorkspace.shared.frontmostApplication else { return }
    let name = front.localizedName ?? "?"
    let bundle = front.bundleIdentifier ?? "?"
    let stamp = ISO8601DateFormatter().string(from: Date())
    let app = AXUIElementCreateApplication(front.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 0.5)

    // Window title tells surfaces apart (e.g. Notion vs a PDF in the same browser).
    let window = axCopy(app, kAXFocusedWindowAttribute).flatMap { axCopy($0 as! AXUIElement, kAXTitleAttribute) as? String } ?? ""

    func row(_ method: String, _ ok: Bool, _ ms: Double, _ chars: Int, _ detail: String, _ restore: String = "") {
        appendRow([stamp, name, bundle, method, ok ? "1" : "0", String(format: "%.1f", ms), "\(chars)", detail, restore, String(window.prefix(60))])
        print(String(format: "  %-8@ %@  %7.1f ms  %5d chars  %@", method as NSString, ok ? "OK  " : "FAIL", ms, chars, detail))
    }

    let n = (trialCounts[name] ?? 0) + 1
    trialCounts[name] = n
    print("\n\(name) (\(bundle)) — trial \(n)/\(trialsPerApp)")

    // 1. Plain AX
    var t = nowMs()
    let ax = axSelectedText(app: app)
    let flagNote = flaggedPids.contains(front.processIdentifier) ? "flag_already_set" : ""
    row("ax", ax != nil, nowMs() - t, ax?.0.count ?? 0, [ax?.1 ?? focusedRoles(app: app), flagNote].filter { !$0.isEmpty }.joined(separator: " "))

    // 2. AX after enabling the lazy tree (only if plain AX failed)
    var axText = ax?.0
    if ax == nil {
        t = nowMs()
        enableAXTree(app: app)
        flaggedPids.insert(front.processIdentifier)
        var flagged: (String, String)?
        while nowMs() - t < axFlagTimeoutMs {
            if let r = axSelectedText(app: app) { flagged = r; break }
            usleep(10_000)
        }
        row("ax_flag", flagged != nil, nowMs() - t, flagged?.0.count ?? 0, flagged?.1 ?? "timeout")
        axText = flagged?.0
    }

    // 3. Cmd+C (always run, for comparison)
    let (text, total, wait, restoreOK) = cmdCCapture()
    var detail = wait.map { String(format: "wait=%.1fms", $0) } ?? "timeout"
    if let text, let axText {
        // "ws" = same text once whitespace/line breaks are collapsed, i.e. only formatting differs.
        let squash = { (s: String) in s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        detail += text == axText ? " match_ax=yes" : squash(text) == squash(axText) ? " match_ax=ws" : " match_ax=no " + firstDiff(axText, text)
    }
    if text == nil && wait != nil { detail += " types=" + lastCopiedTypes }
    row("cmdc", text?.isEmpty == false, total, text?.count ?? 0, detail, restoreOK ? "1" : "0")

    if n == trialsPerApp { print("  ✓ \(trialsPerApp) trials done for \(name)") }
}

// MARK: - Summary

func median(_ xs: [Double]) -> Double {
    guard !xs.isEmpty else { return .nan }
    let s = xs.sorted(), m = s.count / 2
    return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
}

func parseCSVLine(_ line: String) -> [String] {
    var fields: [String] = [], cur = "", inQuotes = false
    var chars = Array(line), i = 0
    while i < chars.count {
        let c = chars[i]
        if inQuotes {
            if c == "\"" && i + 1 < chars.count && chars[i + 1] == "\"" { cur.append("\""); i += 1 }
            else if c == "\"" { inQuotes = false }
            else { cur.append(c) }
        } else if c == "\"" { inQuotes = true }
        else if c == "," { fields.append(cur); cur = "" }
        else { cur.append(c) }
        i += 1
    }
    fields.append(cur)
    chars.removeAll()
    return fields
}

func printSummary() {
    guard let data = try? String(contentsOfFile: csvPath, encoding: .utf8) else {
        print("No results at \(csvPath)"); return
    }
    struct Agg { var n = 0, ok = 0, restoreFail = 0, mismatch = 0; var ms: [Double] = [] }
    var groups: [String: Agg] = [:], order: [String] = []
    for line in data.split(separator: "\n").dropFirst() {
        let f = parseCSVLine(String(line))
        guard f.count >= 9 else { continue }
        let key = "\(f[1])|\(f[3])"
        if groups[key] == nil { order.append(key) }
        var a = groups[key] ?? Agg()
        a.n += 1
        if f[4] == "1" { a.ok += 1; a.ms.append(Double(f[5]) ?? .nan) }
        if f[3] == "cmdc" && f[8] == "0" { a.restoreFail += 1 }
        if f[7].contains("match_ax=no") { a.mismatch += 1 }
        groups[key] = a
    }
    print("\n" + "app".padding(toLength: 22, withPad: " ", startingAt: 0)
          + "method    success   median_ms  restore_fail  ax_mismatch")
    for key in order.sorted() {
        let parts = key.split(separator: "|").map(String.init), a = groups[key]!
        let rate = "\(a.ok)/\(a.n)".padding(toLength: 9, withPad: " ", startingAt: 0)
        print(parts[0].padding(toLength: 22, withPad: " ", startingAt: 0)
              + parts[1].padding(toLength: 10, withPad: " ", startingAt: 0)
              + rate + String(format: " %9.1f  %12d  %11d", median(a.ms), a.restoreFail, a.mismatch))
    }
}

// MARK: - Hotkeys + main

func registerHotKey(_ key: Int, id: UInt32) {
    var ref: EventHotKeyRef?
    let hkID = EventHotKeyID(signature: OSType(0x4D495354), id: id) // 'MIST'
    RegisterEventHotKey(UInt32(key), UInt32(controlKey | optionKey), hkID, GetApplicationEventTarget(), 0, &ref)
}

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "summary" {
    if args.count > 1 { csvPath = args[1] }
    printSummary()
    exit(0)
}
if let p = args.first { csvPath = p }

let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
if !trusted {
    print("Grant Accessibility permission to your terminal app (System Settings → Privacy & Security → Accessibility), then re-run.")
    exit(1)
}

let nsApp = NSApplication.shared
nsApp.setActivationPolicy(.accessory) // never becomes frontmost, so the target app keeps focus

var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
    var hkID = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                      nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
    if hkID.id == 1 { runTrial() } else { printSummary() }
    return noErr
}, 1, &spec, nil, nil)

registerHotKey(kVK_ANSI_M, id: 1)
registerHotKey(kVK_ANSI_S, id: 2)

print("Mist capture probe — writing to \(csvPath)")
print("Select text, press Ctrl+Option+M. Ctrl+Option+S = summary. Ctrl+C here to quit.")
nsApp.run()
