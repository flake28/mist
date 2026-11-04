// Mist — prototype shell.
// Select text → cloud icon → click → OCR of the selection → ask.
// Ctrl+Option+X: screenshot a region → ask.  Ctrl+Option+Space: general question.

import AppKit

let nsApp = NSApplication.shared
nsApp.setActivationPolicy(.accessory) // never becomes the frontmost app, so the reading app keeps focus

if !AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) {
    print("Mist needs Accessibility permission for your terminal app")
    print("(System Settings → Privacy & Security → Accessibility). Grant it and re-run.")
    exit(1)
}
if !CGPreflightScreenCaptureAccess() {
    CGRequestScreenCaptureAccess()
    print("Mist needs Screen Recording permission for your terminal app")
    print("(System Settings → Privacy & Security → Screen & System Audio Recording).")
    print("Grant it, then QUIT and reopen the terminal app, and re-run.")
    exit(1)
}

let model = GeminiAdapter.fromEnvironment()
if model == nil {
    print("⚠️  No Gemini API key found. Put it in ~/.config/mist/gemini_key (or set GEMINI_API_KEY).")
}

let mist = Mist(model: model)
mist.start()

// The first Vision call loads its models (~220–300 ms vs ~70 ms warm); pay that at launch, not on the first click.
Task.detached {
    let ctx = CGContext(data: nil, width: 64, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
    _ = try? Capture.recognize(ctx.makeImage()!, in: CGRect(x: 0, y: 0, width: 64, height: 16))
}

print("Mist is running.")
print("  Select text → click the cloud icon")
print("  Ctrl+Option+X      screenshot a region and ask")
print("  Ctrl+Option+Space  general question")
print("  Esc closes the panel · Ctrl+C here quits")
nsApp.run()
