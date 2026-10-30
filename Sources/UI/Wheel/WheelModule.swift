import SwiftUI
import AppKit

// MODULE wheel (owner: wheel engineer). Prefix for new top-level types: Wheel* / Drag* / Hotkey* / Browser*.
// Files: Sources/UI/Wheel/*.
// Spec: spec/wheel.md (the whole file: 0 TL;DR, 3 window, 4 geometry, 6 hub, 7 hover / keyboard, 8 animations, 9 drop / cancel, 11 which operations appear, 13 customisation,
//       18 macOS mapping, 19 acceptance, 20 state machines), spec/ux.md 1 (the wheel), 7 (haptics, motion), spec/platform.md 6 (drag detection), 7 (hotkey, Finder selection, Services),
//       spec/appfeatures.md 2.2 (gestures), 7.4 (hotkey), 7.6 (drop sources); the "ONE-KEYSTROKE DOWNLOAD FROM THE BROWSER" block of the project brief.
//
// THE WHEEL IS THE QUICK PATH. Everything it starts goes through `QuickRun.shared.run(...)` (files) or `QuickRun.shared.run(_, links:)` / `DownloadService` (links).
// Performance contract: the wheel appears <= 80 ms after drag detection, animates at the display refresh rate (cheap vector drawing, no stacked offscreen blurs, no per-frame
// allocations; benchmark harness `WheelBenchmark`), and costs ZERO at idle: global mouse monitors only arm a short-lived poll WHILE a mouse button is down.

enum WheelModule {
    #if !SC_SHIPPING
    /// Geometry acceptance (hit test for n in 1...13, sector 0 at 12 o'clock, placement clamping), hotkey policy usage, context switching, AppleScript generators,
    /// URL extraction from selected text, gesture state machine tables (taps, chords, Esc), wheel layout pages, link wheel contents, benchmark thresholds.
    static func registerSelfTests() { WheelTests.register() }
    #endif
}
