import SwiftUI
import AppKit

// MARK: - Prompt data

struct PromptSnippet: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

struct PromptCategory: Identifiable {
    let id = UUID()
    let name: String
    let prompts: [PromptSnippet]
}

/// Built-in prompt library shown in the workspace header dropdown. Each
/// snippet is a short, reusable instruction for an AI coding agent —
/// designed to be pasted into a terminal session instead of retyped.
enum PromptLibrary {

    static let categories: [PromptCategory] = [
        PromptCategory(name: "Plan & Scope", prompts: [
            PromptSnippet(
                title: "Scope it first",
                text: "Before writing any code, give me a one-line scope assessment: files touched, rough LOC, and risks. Then a 5-bullet plan. Wait for my OK before coding."
            ),
            PromptSnippet(
                title: "Three tiered options",
                text: "Give me 3 approaches: the smallest version that ships value, a sensible middle, and the full version. Recommend one and tell me if the others are overkill."
            ),
            PromptSnippet(
                title: "Break it down small",
                text: "I'm staring at this task and can't start. Break it into ridiculously small steps of under 5 minutes each, then give me just the first step."
            ),
        ]),
        PromptCategory(name: "Build", prompts: [
            PromptSnippet(
                title: "Smallest possible diff",
                text: "Make the smallest change that solves this. No refactors, no renames, no drive-by cleanups — if you spot something worth fixing, list it at the end instead of touching it."
            ),
            PromptSnippet(
                title: "Match the codebase",
                text: "Before implementing, find 2-3 existing examples of similar code in this repo and follow their patterns, naming, and error handling exactly."
            ),
        ]),
        PromptCategory(name: "Debug", prompts: [
            PromptSnippet(
                title: "Root cause, not symptom",
                text: "Don't patch the symptom. Trace this bug to its root cause, explain the mechanism in one paragraph, then propose the minimal fix."
            ),
            PromptSnippet(
                title: "Reproduce it first",
                text: "Before fixing anything, reproduce the bug and show me the failing output. Then fix it and show the same check passing."
            ),
        ]),
        PromptCategory(name: "Review & Verify", prompts: [
            PromptSnippet(
                title: "Review my diff",
                text: "Review the current git diff for real bugs, missed edge cases, and simpler alternatives. Rank findings by severity and skip style nits."
            ),
            PromptSnippet(
                title: "Prove it works",
                text: "Don't tell me it's done — prove it. Build, run the relevant tests or the app, and paste the actual output. If anything fails, fix it first."
            ),
        ]),
        PromptCategory(name: "Understand", prompts: [
            PromptSnippet(
                title: "Explain before I edit",
                text: "Explain what this code does, why it's likely written this way, and what could break if I change it. Don't change anything yet."
            ),
            PromptSnippet(
                title: "Codebase tour",
                text: "Give me a quick tour of this codebase: entry points, key directories, how data flows, and where you'd start to add a new feature."
            ),
            PromptSnippet(
                title: "Ask me questions",
                text: "I'm stuck on a decision. Ask me questions one at a time — max 5 — to help me figure out what I actually need. Don't propose solutions until I've answered."
            ),
        ]),
        PromptCategory(name: "Wrap Up", prompts: [
            PromptSnippet(
                title: "Commit message",
                text: "Write a commit message for the staged changes: imperative subject under 50 characters, then a short body explaining why, not what."
            ),
            PromptSnippet(
                title: "Session handoff",
                text: "Summarise this session for a handoff: what changed, what's verified, what's still open, and the exact next step. Keep it under 10 lines."
            ),
        ]),
    ]
}

// MARK: - Dropdown menu

/// Header dropdown that lists the prompt library grouped by category.
/// Selecting an item copies the prompt to the clipboard; the icon flashes
/// to a checkmark as feedback since the menu closes itself on selection.
struct PromptLibraryMenu: View {
    @State private var isHovered = false
    @State private var justCopied = false

    var body: some View {
        Menu {
            ForEach(PromptLibrary.categories) { category in
                Section(category.name) {
                    ForEach(category.prompts) { prompt in
                        Button(prompt.title) { copy(prompt.text) }
                    }
                }
            }
        } label: {
            Image(systemName: justCopied ? "checkmark" : "text.badge.star")
                .font(DS.Font.bodySemibold)
                .foregroundStyle(justCopied ? Color.green : Color.primary)
                .frame(width: DS.Control.standard, height: DS.Control.standard)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                        .fill(Color.primary.opacity(isHovered ? 0.08 : 0.0))
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovered = $0 }
        .help(justCopied ? "Copied!" : "Copy a prompt to the clipboard")
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        withAnimation(.easeIn(duration: 0.1)) { justCopied = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            withAnimation(.easeOut(duration: 0.2)) { justCopied = false }
        }
    }
}
