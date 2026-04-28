import SwiftUI

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: DS.Space.lg) {
            Image(systemName: "terminal")
                .font(.system(size: DS.Icon.welcome, weight: .light))
                .foregroundStyle(.secondary)
            Text("Click Run Server, Claude, Codex, or +")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("to start a terminal in this project.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    EmptyStateView()
        .frame(width: DS.Layout.emptyStateSize.width,
               height: DS.Layout.emptyStateSize.height)
}
