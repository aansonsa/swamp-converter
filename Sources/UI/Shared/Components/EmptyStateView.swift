import SwiftUI

/// Empty state with a next step: symbol, a short title, one calm sentence, optional actions. The tiny wordmark ornament is optional
/// (use it on the first screens a person meets, not on every list).
struct EmptyStateView<Actions: View>: View {
    var symbol: String
    var title: String
    var message: String?
    var showsWordmark = false
    @ViewBuilder var actions: () -> Actions

    init(symbol: String, title: String, message: String? = nil, showsWordmark: Bool = false, @ViewBuilder actions: @escaping () -> Actions) {
        self.symbol = symbol; self.title = title; self.message = message; self.showsWordmark = showsWordmark; self.actions = actions
    }

    var body: some View {
        VStack(spacing: DS.Space.md) {
            if showsWordmark { Brand.wordmark(size: 22, color: Brand.pinkInk).padding(.bottom, DS.Space.xs) }
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(.secondary)
            Text(title).font(DS.Typo.title).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if let message {
                Text(message).font(DS.Typo.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 360)
            }
            actions().padding(.top, DS.Space.xs)
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(symbol: String, title: String, message: String? = nil, showsWordmark: Bool = false) {
        self.init(symbol: symbol, title: title, message: message, showsWordmark: showsWordmark) { EmptyView() }
    }
}
