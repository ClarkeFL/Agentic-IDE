import SwiftUI

/// Header strip that sits at the top of the right-hand inspector. Owns its
/// own layout, alignment, and metrics so the inspector body doesn't have to
/// know about pixel-level details. Three slots, fixed height:
///
///   `[ mode toggle | count badge ]      [ refresh ]`
///
/// All three children share `DS.Control.compact` as their slot height,
/// which is the only reason the row reads as visually aligned. AppKit-backed
/// controls (`Picker.segmented`, `Button.borderless`) silently inject their
/// own padding and won't share a centre with raw `Text` / `Image`, so this
/// component avoids them entirely and rolls a SwiftUI-native toggle.
struct InspectorHeader: View {
    @Binding var mode: InspectorMode
    let changeCount: Int
    let isRefreshDisabled: Bool
    let onRefresh: () -> Void

    var body: some View {
        // Same shape as the sidebar `PaneHeader` and the workspace
        // `TabBarView`: fixed `DS.Control.header` height, regular-material
        // background, trailing divider. This is what makes the three column
        // tops draw as one continuous toolbar instead of three separate
        // strips at slightly different heights.
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: DS.Space.md) {
                InspectorModeToggle(mode: $mode, changeCount: changeCount)
                Spacer(minLength: 0)
                InspectorIconButton(
                    systemImage: "arrow.clockwise",
                    help: mode == .changes ? "Refresh git status" : "Reload file tree",
                    action: onRefresh
                )
                .disabled(isRefreshDisabled)
            }
            .padding(.leading, DS.Gutter.inspector)
            .padding(.trailing, DS.Gutter.inspectorTrailing)
            .frame(height: DS.Control.header)
            Divider()
        }
        .background(.regularMaterial)
    }
}

/// Two-segment pill toggle. Replaces the AppKit segmented `Picker` because
/// that control's internal margins can't be reasoned about — at `.mini`
/// control size with a `.frame(width:)`, the picker still draws its segments
/// at its own natural width, so the surrounding HStack drifts unpredictably.
/// Hand-rolling it gives one set of metrics that match the rest of the row.
struct InspectorModeToggle: View {
    @Binding var mode: InspectorMode
    let changeCount: Int

    var body: some View {
        HStack(spacing: DS.Space.xxs) {
            segment(.files, label: "Files")
            segment(.changes, label: "Changes", showsBadge: changeCount > 0)
        }
        .padding(DS.Space.xxs)
        .background(
            // Outer track sits one notch above the panel background so the
            // unselected segment reads as "in a track" without competing
            // with the file tree below.
            Color.primary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
        )
        .frame(height: DS.Control.compact + 4)
    }

    @ViewBuilder
    private func segment(_ value: InspectorMode,
                         label: String,
                         showsBadge: Bool = false) -> some View {
        let isOn = mode == value
        Button {
            // Light spring matches the macOS sidebar tab feel without
            // feeling laggy on rapid clicks.
            withAnimation(.snappy(duration: 0.18)) { mode = value }
        } label: {
            HStack(spacing: DS.Space.xs) {
                Text(label)
                    .font(DS.Font.control)
                    .foregroundStyle(isOn ? .primary : .secondary)
                if showsBadge {
                    Text("\(changeCount)")
                        .font(DS.Font.badge)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, DS.Space.xs)
                        .frame(height: DS.Control.micro)
                        .background(
                            Color.primary.opacity(isOn ? 0.10 : 0.16),
                            in: Capsule()
                        )
                }
            }
            .padding(.horizontal, DS.Space.md)
            .frame(height: DS.Control.compact)
            .background(
                // Subtle "raised tile" instead of an accent pill — matches
                // dark IDE chrome (Xcode, Cursor, Linear) where the
                // selected tab is lifted, not painted.
                isOn ? AnyShapeStyle(Color.primary.opacity(0.10))
                     : AnyShapeStyle(Color.clear),
                in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Square-hit-area icon button. Sized to match the toggle's *outer* height
/// (`DS.Control.compact + 4` = 22pt) — not just the inner segment height —
/// so the toggle pill and the icon button share the same top + bottom edge
/// inside the 30pt header strip. Without this, the icon sat 2pt lower than
/// the toggle because each control was self-centring at a different size.
struct InspectorIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    private var slot: CGFloat { DS.Control.compact + 4 }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: DS.Icon.small, weight: .medium))
                .foregroundStyle(isEnabled ? .secondary : .tertiary)
                .frame(width: slot, height: slot)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
