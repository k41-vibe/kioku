import Security
import SwiftUI
import WebKit

/// A short video played as a break every N answers.
///
/// YouTube's Data API has no endpoint for the personalised recommendation feed,
/// so the pool is the region's trending list (`videos.list?chart=mostPopular`,
/// 1 quota unit per call) narrowed to Shorts length. The list is fetched once
/// per study session and a video is drawn from it at random.
enum ShortsBreak {
    static let everyKey = "shortsEvery"
    static let apiKeyKey = "youtubeAPIKey"
    static let regionKey = "shortsRegion"

    /// 0 turns the break off.
    static var every: Int { UserDefaults.standard.object(forKey: everyKey) as? Int ?? 3 }
    static var apiKey: String { UserDefaults.standard.string(forKey: apiKeyKey) ?? "" }
    static var region: String { UserDefaults.standard.string(forKey: regionKey) ?? "JP" }

    /// Seconds in an ISO 8601 duration such as "PT1M2S". nil when the string is
    /// not a plain time-only duration, or ends mid-number.
    static func durationSeconds(_ iso: String) -> Int? {
        guard iso.hasPrefix("PT") else { return nil }
        var total = 0
        var number = 0
        var pendingDigits = false
        for ch in iso.dropFirst(2) {
            if ch.isNumber, let d = ch.wholeNumberValue {
                number = number * 10 + d
                pendingDigits = true
            } else {
                guard pendingDigits else { return nil }
                switch ch {
                case "H": total += number * 3600
                case "M": total += number * 60
                case "S": total += number
                default: return nil
                }
                number = 0
                pendingDigits = false
            }
        }
        return pendingDigits ? nil : total
    }

    /// Video ids from a `videos.list` response, keeping only Shorts-length clips.
    static func shortIDs(_ data: Data, maxSeconds: Int = 60) throws -> [String] {
        struct Response: Decodable {
            struct Item: Decodable {
                struct Details: Decodable { let duration: String }
                let id: String
                let contentDetails: Details?
            }
            let items: [Item]
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.items.compactMap { item in
            guard let iso = item.contentDetails?.duration,
                  let secs = durationSeconds(iso), secs > 0, secs <= maxSeconds else { return nil }
            return item.id
        }
    }

    static func trendingURL(apiKey: String, region: String) -> URL? {
        guard !apiKey.isEmpty, !region.isEmpty else { return nil }
        var comps = URLComponents(string: "https://www.googleapis.com/youtube/v3/videos")
        comps?.queryItems = [
            URLQueryItem(name: "part", value: "contentDetails"),
            URLQueryItem(name: "chart", value: "mostPopular"),
            URLQueryItem(name: "regionCode", value: region),
            URLQueryItem(name: "maxResults", value: "50"),
            URLQueryItem(name: "key", value: apiKey),
        ]
        return comps?.url
    }

    static func embedURL(_ videoID: String) -> URL? {
        URL(string: "https://www.youtube.com/embed/\(videoID)?playsinline=1&autoplay=1&rel=0")
    }

    /// The player refuses a request with no identifiable origin (error 153), and
    /// WKWebView sends none when it loads the embed URL itself. Wrapping the
    /// iframe in a document loaded from our own pages domain gives it one.
    static let embedBaseURL = URL(string: "https://k41-vibe.github.io/kioku/")!

    static func embedHTML(_ videoID: String) -> String {
        let src = embedURL(videoID)?.absoluteString ?? ""
        return """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}
        iframe{border:0;width:100%;height:100%;display:block}</style>
        </head><body>
        <iframe src="\(src)" referrerpolicy="strict-origin-when-cross-origin"
                allow="autoplay; encrypted-media; picture-in-picture" allowfullscreen></iframe>
        </body></html>
        """
    }

    /// Trending Shorts ids, or an empty list when no key is set or the call fails.
    static func fetchIDs() async -> [String] {
        guard let url = trendingURL(apiKey: apiKey, region: region) else { return [] }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return (try? shortIDs(data)) ?? []
    }

    // MARK: - Signed-in feed

    /// Video ids in the order youtube.com/shorts returned them. The page embeds
    /// its data as `ytInitialData` in the HTML, so the ids are readable without
    /// running the page's JavaScript.
    ///
    /// ponytail: regex over the served HTML. If YouTube stops embedding
    /// ytInitialData, read the ids from a WKWebView instead.
    static func feedIDs(inHTML html: String, limit: Int = 20) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #""videoId":"([A-Za-z0-9_-]{11})""#) else { return [] }
        let ns = html as NSString
        var seen = Set<String>()
        var out: [String] = []
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: m.range(at: 1))
            if seen.insert(id).inserted {
                out.append(id)
                if out.count >= limit { break }
            }
        }
        return out
    }

    /// Ids from `incoming` that are not in `existing`, appended in order.
    static func merged(_ existing: [String], _ incoming: [String]) -> [String] {
        var seen = Set(existing)
        var out = existing
        for id in incoming where seen.insert(id).inserted { out.append(id) }
        return out
    }

    /// Shorts the signed-in account is offered. One request returns a single
    /// video, so ask repeatedly and keep what is new until there is enough to
    /// rotate through.
    ///
    /// ponytail: repeated page loads. The reel sequence endpoint would return a
    /// list in one call, but it is an internal API with its own client context.
    static func fetchPersonalIDs(rounds: Int = 8, want: Int = 12) async -> [String] {
        var out: [String] = []
        for _ in 0..<max(rounds, 1) {
            let page = await fetchPersonalPage()
            if page.isEmpty { break }
            out = merged(out, page)
            if out.count >= want { break }
        }
        return out
    }

    /// One request to the signed-in Shorts page.
    private static func fetchPersonalPage() async -> [String] {
        let cookie = CookieStore.load()
        guard !cookie.isEmpty, let url = URL(string: "https://www.youtube.com/shorts") else { return [] }

        // Our Cookie header must survive, so the session keeps no cookie jar of
        // its own. A desktop agent string gets the full page instead of a shell.
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        var request = URLRequest(url: url)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("ja,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let session = URLSession(configuration: config)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { return [] }
        return feedIDs(inHTML: html)
    }

    /// The signed-in feed when a cookie is stored, otherwise the trending list.
    static func fetchBreakIDs() async -> [String] {
        let personal = await fetchPersonalIDs()
        return personal.isEmpty ? await fetchIDs() : personal
    }
}

/// The YouTube cookie grants access to a Google account, so it is held in the
/// keychain rather than UserDefaults.
enum CookieStore {
    private static let service = "dev.k41.kioku.youtube"
    private static let account = "cookie"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func save(_ value: String) {
        SecItemDelete(baseQuery as CFDictionary)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load() -> String {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }
}

/// Wrapper so a video id can drive `fullScreenCover(item:)`.
struct ShortVideo: Identifiable, Equatable { let id: String }

/// Full-screen break. The close control sits in its own bar above the player:
/// YouTube's terms forbid drawing anything in front of any part of it.
struct ShortsBreakView: View {
    let videoID: String
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("学習に戻る", action: onClose)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            WebPage(html: ShortsBreak.embedHTML(videoID), baseURL: ShortsBreak.embedBaseURL)
        }
        .background(Color.black.ignoresSafeArea())
    }
}

/// Minimal WKWebView for one HTML document. The card renderer's web view carries
/// a custom scheme handler and message handlers it does not need here.
struct WebPage: UIViewRepresentable {
    let html: String
    let baseURL: URL

    final class Coordinator { var loaded: String? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: config)
        web.backgroundColor = .black
        web.isOpaque = false
        web.scrollView.isScrollEnabled = false
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        web.loadHTMLString(html, baseURL: baseURL)
    }
}
