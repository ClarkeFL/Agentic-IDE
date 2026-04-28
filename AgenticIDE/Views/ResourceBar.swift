import SwiftUI

/// Compact two-section row showing system-wide CPU% and memory used.
/// Lives in the sidebar footer just above the action buttons. Reads
/// from the shared `ResourceMonitor` (sampled at 2 Hz). Hover shows
/// the memory total for context.
struct ResourceBar: View {
    @Environment(ResourceMonitor.self) private var monitor

    var body: some View {
        HStack(spacing: 0) {
            metric(systemImage: "cpu",
                   label: "CPU",
                   value: formattedCPU,
                   tint: cpuColor)
            Spacer(minLength: 8)
            metric(systemImage: "memorychip",
                   label: "MEM",
                   value: formattedMemoryUsed,
                   tint: memoryColor)
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .monospacedDigit()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .help("System-wide CPU and memory. Memory total: \(formattedMemoryTotal). Updated 2×/sec.")
    }

    @ViewBuilder
    private func metric(systemImage: String,
                        label: String,
                        value: String,
                        tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(label)
                .foregroundStyle(.tertiary)
            Text(value)
                .foregroundStyle(tint)
        }
    }

    private var formattedCPU: String {
        // Integer percent — the 2 Hz delta sample is already steady
        // enough that decimals just flicker without adding signal.
        String(format: "%2d%%", Int(monitor.cpuPercent.rounded()))
    }

    private var formattedMemoryUsed: String {
        Self.byteFormatter.string(fromByteCount: Int64(monitor.memoryUsedBytes))
    }

    private var formattedMemoryTotal: String {
        Self.byteFormatter.string(fromByteCount: Int64(monitor.memoryTotalBytes))
    }

    /// Colour escalation for system-wide CPU. Most desktops idle at
    /// well under 25%; 50% means something is genuinely working; 80%+
    /// is "your fans are about to spin up."
    private var cpuColor: Color {
        switch monitor.cpuPercent {
        case ..<50: return .secondary
        case ..<80: return Color(red: 0.95, green: 0.75, blue: 0.20)
        default: return Color(red: 0.92, green: 0.36, blue: 0.36)
        }
    }

    /// Memory pressure escalation. macOS's own pressure model would be
    /// more accurate but requires sampling the compressor pressure
    /// counter; this used/total ratio is a reasonable proxy and matches
    /// what users intuit from Activity Monitor's bar.
    private var memoryColor: Color {
        guard monitor.memoryTotalBytes > 0 else { return .secondary }
        let ratio = Double(monitor.memoryUsedBytes) / Double(monitor.memoryTotalBytes)
        switch ratio {
        case ..<0.70: return .secondary
        case ..<0.90: return Color(red: 0.95, green: 0.75, blue: 0.20)
        default: return Color(red: 0.92, green: 0.36, blue: 0.36)
        }
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        f.allowedUnits = [.useGB, .useMB]
        return f
    }()
}
