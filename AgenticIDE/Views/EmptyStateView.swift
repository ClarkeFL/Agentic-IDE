import SwiftUI

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 48, weight: .light))
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
        .frame(width: 600, height: 400)
}
