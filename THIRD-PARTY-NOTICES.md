# Third-party notices

## KeyboardShortcuts (sindresorhus/KeyboardShortcuts)
- URL: https://github.com/sindresorhus/KeyboardShortcuts, tag 3.1.0
- Licence: MIT, Copyright (c) Sindre Sorhus (full text: `Sources/UI/Settings/ThirdParty/KeyboardShortcuts/LICENSE`)
- Used in: `Sources/UI/Settings/ThirdParty/KeyboardShortcuts/KeyCaptureField.swift` (Settings > Shortcuts recorder)
- Adapted from `RecorderCocoa.swift` and `Shortcut.swift`: the search-field recorder, local key monitor, Escape/Delete/Tab and Shift-alone rules, no-initial-focus handling, keyboard-layout key names (UCKeyTranslate).
- Changed: removed name/UserDefaults storage, global registration (HotkeyManager registers), menu/system alerts and Bundle.module strings; model is the app's HotkeyCombo; strings via L(); no notifications.
