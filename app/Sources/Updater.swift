import Foundation
import UIKit

/// Checks GitHub Releases for a newer Kioku build and hands the ipa URL to
/// LiveContainer (`livecontainer://install?url=`) or Safari.
struct ReleaseInfo: Equatable {
    var tag: String            // "v0.2.3"
    var version: String        // "0.2.3"
    var ipaURL: URL
    var pageURL: URL
    var notes: String
}

enum Updater {
    static let repo = "k41-vibe/kioku"

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static func parse(_ v: String) -> [Int] {
        v.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0) ?? 0 }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = parse(a), y = parse(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0
            let q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    static func fetchLatest() async throws -> ReleaseInfo? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Kioku/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = json["assets"] as? [[String: Any]],
              let ipa = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".ipa") == true }),
              let ipaURL = (ipa["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let notes = json["body"] as? String ?? ""
        return ReleaseInfo(tag: tag, version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), ipaURL: ipaURL, pageURL: page, notes: notes)
    }

    /// Ask LiveContainer to download and install the ipa. Returns false if the
    /// scheme could not be opened (not running under LiveContainer, etc.).
    @MainActor
    static func installViaLiveContainer(_ info: ReleaseInfo) async -> Bool {
        guard let encoded = info.ipaURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "livecontainer://install?url=\(encoded)") else { return false }
        return await UIApplication.shared.open(url)
    }

    @MainActor
    static func openInSafari(_ info: ReleaseInfo) {
        UIApplication.shared.open(info.pageURL)
    }
}
