import SwiftUI

/// App-wide design tokens. Every view consumes `DS.*` instead of inline
/// numbers so the whole app stays visually coherent — change one constant
/// here and every screen re-aligns. If a value you need isn't on this enum,
/// add it here first; **don't reach for a literal at the call site**.
///
/// Why this exists: scattered magic numbers across views were producing
/// inconsistent spacing, three different corner radii (4 / 5 / 6), two
/// different icon-button sizes (22 / 26), and HStack rows that drifted
/// because each control imposed its own intrinsic metrics. The fix is one
/// shared source of truth.
enum DS {

    // MARK: - Spacing

    /// Spacing scale. Use as `.padding(DS.Space.md)` or
    /// `HStack(spacing: DS.Space.sm)`. Each step is roughly 1.4-1.5× the
    /// previous, so adjacent values read as different but related.
    enum Space {
        /// 2pt — micro gaps inside compound badges (icon + count, etc).
        static let xxs: CGFloat = 2
        /// 4pt — between an icon and its label.
        static let xs: CGFloat = 4
        /// 6pt — tight HStack default; row inner padding.
        static let sm: CGFloat = 6
        /// 8pt — default content spacing; control inner horizontal padding.
        static let md: CGFloat = 8
        /// 12pt — section spacing inside a panel.
        static let lg: CGFloat = 12
        /// 16pt — popover / card outer padding.
        static let xl: CGFloat = 16
        /// 20pt — empty-state padding.
        static let xxl: CGFloat = 20
        /// 32pt — full-window onboarding padding.
        static let xxxl: CGFloat = 32
    }

    // MARK: - Control heights

    /// Vertical "slot" heights. Pin every control in a header / toolbar HStack
    /// to one of these values so the row reads as a single rhythm regardless
    /// of which AppKit-backed widget is inside.
    enum Control {
        /// 12pt — micro badge inside a segment.
        static let micro: CGFloat = 12
        /// 16pt — count badges, status pills.
        static let badge: CGFloat = 16
        /// 18pt — toggle segments, square icon buttons.
        static let compact: CGFloat = 18
        /// 22pt — sidebar / list rows, small toolbar buttons.
        static let standard: CGFloat = 22
        /// 26pt — folder buttons, project icon tiles.
        static let large: CGFloat = 26
        /// 30pt — strip headers (inspector top, tab bar).
        static let header: CGFloat = 30
    }

    // MARK: - Corner radius

    /// Three-step corner-radius scale. Replaces the previous 4/5/6 sprawl
    /// where each component picked its own value.
    enum Radius {
        /// 4pt — selection pills inside a track (segmented toggle).
        static let sm: CGFloat = 4
        /// 5pt — list-row hover/selected pills.
        static let md: CGFloat = 5
        /// 6pt — cards, panels, popovers, project icon tiles.
        static let lg: CGFloat = 6
    }

    // MARK: - Icon glyph sizes

    /// Point sizes for SF Symbols / glyph imagery. Use on
    /// `.font(.system(size: DS.Icon.small))`.
    enum Icon {
        /// 9pt — chevrons, super-tight glyphs.
        static let micro: CGFloat = 9
        /// 11pt — toolbar icons, file glyphs.
        static let small: CGFloat = 11
        /// 22pt — empty-state hero.
        static let large: CGFloat = 22
        /// 28pt — section empty-state hero.
        static let display: CGFloat = 28
        /// 44pt — onboarding hero.
        static let onboarding: CGFloat = 44
        /// 48pt — welcome screen hero.
        static let welcome: CGFloat = 48
    }

    // MARK: - Typography

    /// Type scale. Pair each size with a default weight via the helpers below.
    enum FontSize {
        /// 9pt — micro badges, category caps tracking.
        static let micro: CGFloat = 9
        /// 10pt — diff stats (`+12 −3`), small numbers.
        static let caption: CGFloat = 10
        /// 10.5pt — diff hunk header monospace.
        static let captionMono: CGFloat = 10.5
        /// 11pt — control labels, secondary text.
        static let footnote: CGFloat = 11
        /// 11.5pt — code preview / diff body monospace.
        static let bodyMono: CGFloat = 11.5
        /// 12pt — row labels, body text.
        static let body: CGFloat = 12
    }

    /// Common font compositions. Built from `FontSize` so the scale stays
    /// consistent. Reach for these first; only call `.font(.system(size:))`
    /// inline if your case is genuinely one-off.
    enum Font {
        /// 12pt regular — default body / row label.
        static let body = SwiftUI.Font.system(size: FontSize.body)
        /// 12pt medium — emphasised row label.
        static let bodyMedium = SwiftUI.Font.system(size: FontSize.body, weight: .medium)
        /// 12pt semibold — strong row label.
        static let bodySemibold = SwiftUI.Font.system(size: FontSize.body, weight: .semibold)
        /// 11pt medium — control label, segment text.
        static let control = SwiftUI.Font.system(size: FontSize.footnote, weight: .medium)
        /// 11pt — file leaf / sidebar tertiary.
        static let footnote = SwiftUI.Font.system(size: FontSize.footnote)
        /// 10pt monospaced semibold — diff stat numbers.
        static let stats = SwiftUI.Font.system(size: FontSize.caption,
                                              weight: .semibold,
                                              design: .monospaced).monospacedDigit()
        /// 9pt semibold — count badges (monospaced digits).
        static let badge = SwiftUI.Font.system(size: FontSize.micro,
                                              weight: .semibold).monospacedDigit()
        /// 11pt semibold — directory section caps ("LIB/COMPONENTS").
        static let sectionCaps = SwiftUI.Font.system(size: FontSize.footnote, weight: .semibold)
        /// 11.5pt monospaced — file preview body.
        static let codeBody = SwiftUI.Font.system(size: FontSize.bodyMono, design: .monospaced)
        /// 10.5pt monospaced semibold — diff hunk header.
        static let codeHeader = SwiftUI.Font.system(size: FontSize.captionMono,
                                                   weight: .semibold,
                                                   design: .monospaced)
    }

    // MARK: - Tree / outline metrics

    /// Per-depth indentation for outline lists. Same constants used by both
    /// the changes tree and the project file tree so they look identical.
    enum Tree {
        /// 10pt per depth level.
        static let indentStep: CGFloat = 10
        /// 12pt reserved for the chevron glyph + its trailing gap.
        static let chevronColumn: CGFloat = 12
        /// 16pt reserved for the file/folder icon.
        static let iconColumn: CGFloat = 16
    }

    // MARK: - Per-pane gutters

    /// Horizontal insets per panel. Use these instead of inline numbers so
    /// header / row / body content all line up to one gutter.
    ///
    /// The inspector deliberately uses **asymmetric** insets: a tight 4pt
    /// leading edge so chevrons and folder rows sit close to the panel
    /// border (no wasted thumb-strip of empty space), and a generous 14pt
    /// trailing edge so the stat numbers (+12 −3) and refresh icon don't
    /// look visually cropped against the right edge.
    enum Gutter {
        /// 4pt — inspector pane LEFT edge. Applies to the header toggle's
        /// leading edge AND every list row's leading inset, so a depth-0
        /// chevron lines up with the toggle pill's left edge.
        static let inspector: CGFloat = 4
        /// 14pt — inspector pane RIGHT edge. Stat numbers, refresh icon,
        /// and diff body trailing inset all consume this.
        static let inspectorTrailing: CGFloat = 14
        /// 6pt — project sidebar (left column).
        static let sidebar: CGFloat = 6
    }

    // MARK: - Sized layout constants

    /// One-off layout dimensions for fixed-size windows / panels.
    enum Layout {
        /// 360pt — Run-server popover.
        static let runServerPopoverWidth: CGFloat = 360
        /// 420pt — onboarding body text wrap.
        static let onboardingTextWidth: CGFloat = 420
        /// 480pt — onboarding window width.
        static let onboardingWindowWidth: CGFloat = 480
        /// 520pt — settings window width.
        static let settingsWindowWidth: CGFloat = 520
        /// 360pt — settings window height.
        static let settingsWindowHeight: CGFloat = 360
        /// 600pt × 400pt — empty-state placeholder.
        static let emptyStateSize = CGSize(width: 600, height: 400)
    }
}
