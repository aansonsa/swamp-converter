import SwiftUI

/// A picker that is a segmented control while its labels fit and becomes a pop-up menu when they do not. Russian labels run 30 to 40 percent longer than English
/// ones, and a segmented control never wraps or truncates gracefully, so the choice is made by the layout, not by the language: `ViewThatFits` offers the
/// segmented control first and falls back to the menu when it cannot get its natural width. The same value and the same accessibility label either way.
///
///     AdaptivePicker(L("Mode", "Режим"), selection: $mode, options: [(.bestForApple, L("Best for Apple", "Лучше для Apple")), ...])
struct AdaptivePicker<Value: Hashable>: View {
    var title: String
    @Binding var selection: Value
    var options: [(value: Value, label: String)]
    /// Show the title above the control (forms usually draw it on the left themselves, so the default is hidden).
    var showsTitle = false

    init(_ title: String, selection: Binding<Value>, options: [(value: Value, label: String)], showsTitle: Bool = false) {
        self.title = title; self._selection = selection; self.options = options; self.showsTitle = showsTitle
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Picker(title, selection: $selection) {
                ForEach(options.indices, id: \.self) { Text(options[$0].label).tag(options[$0].value) }
            }
            .pickerStyle(.segmented)
            .labelsHidden(!showsTitle)
            .fixedSize(horizontal: true, vertical: false)

            Picker(title, selection: $selection) {
                ForEach(options.indices, id: \.self) { Text(options[$0].label).tag(options[$0].value) }
            }
            .pickerStyle(.menu)
            .labelsHidden(!showsTitle)
        }
        .accessibilityLabel(Text(title))
    }
}

private extension View {
    /// `labelsHidden()` only when asked (a conditional modifier without changing the view's type).
    @ViewBuilder func labelsHidden(_ hidden: Bool) -> some View { if hidden { labelsHidden() } else { self } }
}
