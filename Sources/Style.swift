//
//  Style.swift — Testudo
//
//  The type scale, black-and-white palette and byline every protowaldganger
//  app shares, in the spirit of searchbrowser.app. Same copy in each app.
//

import AppKit
import SwiftUI

// The visual language shared by every protowaldganger app: black and white
// chrome in the system typeface, one grey that slides to what you pick, and
// colour only where it carries meaning (Apple HIG, Color): system colours, so
// light, dark and Increase Contrast adapt for free; each colour means one
// thing in every app; and colour is never the only signal.
enum Style {
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let raised = Color(nsColor: .controlBackgroundColor)
    static let well = Color.primary.opacity(0.04)
    static let track = Color.primary.opacity(0.08)
    static let hairline = Color.primary.opacity(0.08)
    static let ink = Color.primary.opacity(0.62)
    static let slide = Animation.spring(response: 0.3, dampingFraction: 0.86)

    /// Switches, selections and default buttons: black in light mode, a quiet
    /// grey in dark mode so white knobs and labels stay readable.
    static let accent = Color(nsColor: NSColor(name: "protowaldganger.accent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.56, alpha: 1) : NSColor(white: 0.08, alpha: 1)
    })

    // Status: the same three meanings in every app.
    /// On, done, smaller, added.
    static let positive = Color(nsColor: .systemGreen)
    /// Needs you, skipped, not finished setting up.
    static let caution = Color(nsColor: .systemOrange)
    /// Failed, removed, destructive.
    static let negative = Color(nsColor: .systemRed)

    /// Kinds of things (categories, chart series), in one fixed order so the
    /// first kind is blue in every app. Green and red come last, so they only
    /// appear as a kind once the others run out and never compete with status.
    static let seriesColors: [NSColor] = [.systemBlue, .systemOrange, .systemPurple, .systemTeal, .systemPink,
                                          .systemYellow, .systemIndigo, .systemBrown, .systemGray, .systemMint, .systemCyan,
                                          .systemGreen, .systemRed]
    static func series(_ index: Int) -> Color { Color(nsColor: seriesColors[index % seriesColors.count]) }

    static let title = Font.system(size: 24, weight: .semibold)
    static let body = Font.system(size: 13)
    static let detail = Font.system(size: 11)
    static let footer = Font.system(size: 11)
}

/// A small status dot. Its shape repeats the colour's meaning, so it reads
/// without colour too: filled when on, a ring when off, and filled with a
/// ring around it when something needs you.
struct StatusDot: View {
    enum Tone { case on, caution, off }
    var tone: Tone
    var size: CGFloat = 8

    var body: some View {
        ZStack {
            switch tone {
            case .on:
                Circle().fill(Style.positive)
            case .caution:
                Circle().fill(Style.caution)
                Circle().strokeBorder(Style.caution.opacity(0.35), lineWidth: 1).padding(-2.5)
            case .off:
                Circle().strokeBorder(Color.primary.opacity(0.45), lineWidth: 1.2)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// "Name • by protowaldganger", with the version beside it, quiet.
struct Byline: View {
    let name: String

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("\(name) • by protowaldganger")
            Text(version).foregroundStyle(.tertiary)
        }
        .font(Style.footer)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}
