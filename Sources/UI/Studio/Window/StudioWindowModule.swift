import SwiftUI

// MODULE studio-window (owner: studio-window engineer). Prefix for new top-level types: StudioWindow* / Studio* (window views) / Preview* / Queue*.
// Files: Sources/UI/Studio/Window/*.
// Spec: spec/handbrake.md 6 (layout 6.1, presets 6.3, preview 6.4, summary bar 6.5, queue 6.7, keyboard 6.8, clutter checklist 6.9), spec/ux.md 4, spec/appfeatures.md 11, spec/platform.md 1 (glass, snapshots), 8 (QL, share).
//
// The window around `StudioSession` (studio-core): NavigationSplitView with sidebar (Sources, Queue, Presets), centre (source strip, preview, timeline), trailing inspector (OptionFormView),
// toolbar (Add Files, preset pop-up, Preview, Add to Queue, one prominent Start / Start Queue), drag-and-drop in (anywhere adds sources; onto a preset applies it), the embedded queue panel
// (reorder, per-item overrides, progress, ETA, log) built from `JobRowView` (jobs module), opened from the wheel's "Customise...", the menu bar, the Dock and links ("Download" target).
// Window state (frame, inspector page, queue visibility) is remembered in `settings.studio`. Quit-with-queue confirmation is the app module's.

enum StudioWindowModule {
    #if !SC_SHIPPING
    @MainActor
    static func registerSnapshots() { StudioWindowSnapshots.register() }
    #endif
    #if !SC_SHIPPING
    static func registerSelfTests() { StudioWindowTests.register() }
    #endif
}
