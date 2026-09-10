import SwiftUI
import UIKit

/// White-based monochrome palette. Dark mode inverts to a calm near-black.
enum Theme {
    static let paper = dynamic(light: 0xFFFFFF, dark: 0x111111)
    static let paper2 = dynamic(light: 0xF6F6F6, dark: 0x1B1B1B)
    static let ink = dynamic(light: 0x1A1A1A, dark: 0xECECEC)
    static let gray1 = dynamic(light: 0x6B6B6B, dark: 0xA0A0A0)
    static let gray2 = dynamic(light: 0xB8B8B8, dark: 0x6E6E6E)
    static let gray3 = dynamic(light: 0xEDEDED, dark: 0x2A2A2A)

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }

    /// CSS injected before the notetype's own stylesheet.
    static let baseCardCSS = """
    html, body { margin: 0; padding: 0; -webkit-text-size-adjust: 100%; }
    body { background: #ffffff; color: #1a1a1a; font-family: -apple-system, "Hiragino Sans", "Helvetica Neue", sans-serif; }
    body.nightMode { background: #111111; color: #ececec; }
    #qa { padding: 28px 20px 140px 20px; min-height: 60vh; word-wrap: break-word; }
    img { max-width: 100%; height: auto; }
    hr#answer { border: 0; border-top: 1px solid #d9d9d9; margin: 24px 0; }
    body.nightMode hr#answer { border-top-color: #333; }
    .kioku-replay { display: inline-flex; align-items: center; justify-content: center; width: 40px; height: 40px; margin: 4px;
      border: 1px solid #b8b8b8; border-radius: 50%; color: inherit; text-decoration: none; vertical-align: middle; font-size: 16px; }
    .kioku-replay:active { background: #ededed; }
    body.nightMode .kioku-replay { border-color: #555; }
    #typeans { font-size: 20px; padding: 10px 12px; border: 1px solid #b8b8b8; border-radius: 10px; width: 86%; max-width: 480px;
      text-align: center; background: transparent; color: inherit; outline: none; margin-top: 12px; }
    code#typeans { display: inline-block; border: 0; font-family: -apple-system, monospace; font-size: 22px; }
    .typeGood { background: #ececec; border-radius: 3px; padding: 0 2px; }
    body.nightMode .typeGood { background: #2e2e2e; }
    .typeBad { text-decoration: line-through; color: #8a8a8a; }
    .typeMissed { border-bottom: 2px dotted currentColor; }
    #typearrow { color: #8a8a8a; }
    """

    /// Appended after the notetype CSS when "アプリの見た目を優先" is on.
    static let monochromeOverrideCSS = """
    .card { background: #ffffff !important; color: #1a1a1a !important;
      font-family: -apple-system, "Hiragino Sans", "Helvetica Neue", sans-serif !important; }
    body.nightMode .card { background: #111111 !important; color: #ececec !important; }
    .card * { color: inherit !important; background-color: transparent !important; }
    .card img { background-color: initial !important; }
    .cloze { font-weight: 700 !important; text-decoration: underline; text-decoration-color: #8a8a8a; }
    b, strong { font-weight: 700; }
    """
}

enum AppInfo {
    static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
    static var footer: String {
        "Kioku \(version) · anki 26.08.1 · bridge \(AnkiBackend.bridgeVersion)"
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

struct CountLabel: View {
    let label: String
    let value: UInt32
    let emphasized: Bool

    var body: some View {
        HStack(spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(Theme.gray1)
            Text("\(value)")
                .font(.footnote.monospacedDigit().weight(emphasized && value > 0 ? .semibold : .regular))
                .foregroundStyle(value > 0 ? Theme.ink : Theme.gray2)
        }
    }
}
