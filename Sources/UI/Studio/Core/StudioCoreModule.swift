import SwiftUI

// MODULE studio-core (owner: studio-core engineer). Prefix for new top-level types: Studio* (models) / Option* (views) / Preset* (views) / Track*.
// Files: Sources/UI/Studio/Core/*.
// Spec: spec/handbrake.md (THE spec: 0.5 decisions, 1 information architecture, 2.0 OptionSchema grammar, 6.1-6.9 UX, 6.6 validation messages, 4 presets), spec/ux.md 4,
//       spec/appfeatures.md 11 (Quick and Studio share one engine).
//
// The Studio is the HandBrake-class advanced window, beautifully native. THIS module is the engine room: the session model (state machine behind the window) and the generic
// renderer that turns ANY `OptionSchema` into native tabbed pages (Form .grouped, sliders with live values, track-list editors, conditional enabling, "needs ffmpeg" hints, search,
// Simple / Advanced density). The window, sidebar, toolbar, preview and queue are the studio-window module.
// The renderer is also used by the Settings parameter sheet (`OptionFieldView`) and by the quick-recipe editor.
//
// Hard rules: every control comes from the schema (no per-operation views); a disabled control shows WHY (info glyph + reason on hover / focus); colour never carries meaning alone;
// no fixed-width labels; the quality slider shows the native value secondary and the unified "Smaller file <-> Better quality" first; all heavy work (probe, estimate, preview) is
// off the main thread, cancellable, and keyed by an options hash.

enum StudioCoreModule {
    #if !SC_SHIPPING
    @MainActor
    static func registerSnapshots() { StudioCoreSnapshots.register() }
    #endif

    #if !SC_SHIPPING
    /// Renderer tests over a fixture schema containing every `FieldKind` (defaults shown, conditions toggle enabled state, tracks add / remove / reorder, search finds both languages,
    /// density hides expert fields), `StudioSession` flows with fake operations (select target, apply preset, Modified badge, revert, undo, recipe building, enqueue).
    static func registerSelfTests() { StudioCoreTests.register() }
    #endif
}
