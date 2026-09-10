import SwiftUI
import WebKit
import UniformTypeIdentifiers

/// Serves files from the collection's media folder under
/// `kioku-media://media/<filename>` so notetype HTML can use plain `src="x.jpg"`.
final class MediaSchemeHandler: NSObject, WKURLSchemeHandler {
    let mediaFolder: URL

    init(mediaFolder: URL) {
        self.mediaFolder = mediaFolder
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        guard let fileURL = resolve(path: url.path), let data = try? Data(contentsOf: fileURL) else {
            let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"])!
            task.didReceive(resp)
            task.didFinish()
            return
        }
        let ext = fileURL.pathExtension.lowercased()
        let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)", "Access-Control-Allow-Origin": "*"])!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    /// Map a request path ("/<name>") to a file inside the media folder.
    /// Returns nil for empty names, subpaths, or traversal attempts.
    func resolve(path: String) -> URL? {
        let raw = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let name = raw.removingPercentEncoding ?? raw
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != "..", !name.hasPrefix("..") else { return nil }
        return mediaFolder.appendingPathComponent(name)
    }
}

/// Events coming out of the card web view.
enum CardWebEvent {
    case tap(typed: String)
    case showAnswer(typed: String)
    case play(side: String, index: Int)
    case swipe(UISwipeGestureRecognizer.Direction)
    case loaded
}

/// Bridge object owned by the session so it can poke the web view (read the
/// typed answer, scroll) without SwiftUI plumbing.
final class CardWebController {
    weak var webView: WKWebView?

    func readTypedAnswer() async -> String {
        guard let webView else { return "" }
        return await withCheckedContinuation { cont in
            webView.evaluateJavaScript("(function(){var e=document.getElementById('typeans');return e?e.value:'';})()") { result, _ in
                cont.resume(returning: result as? String ?? "")
            }
        }
    }
}

struct CardWebView: UIViewRepresentable {
    let html: String
    let mediaFolder: URL
    let controller: CardWebController
    let onEvent: (CardWebEvent) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEvent: onEvent) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(MediaSchemeHandler(mediaFolder: mediaFolder), forURLScheme: CardHTML.mediaScheme)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(context.coordinator, name: "kioku")
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false

        for dir: UISwipeGestureRecognizer.Direction in [.up, .down, .left, .right] {
            let swipe = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSwipe(_:)))
            swipe.direction = dir
            swipe.numberOfTouchesRequired = 1
            swipe.delegate = context.coordinator
            webView.addGestureRecognizer(swipe)
        }
        controller.webView = webView
        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: CardHTML.baseURL)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onEvent = onEvent
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            webView.loadHTMLString(html, baseURL: CardHTML.baseURL)
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "kioku")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, UIGestureRecognizerDelegate {
        var onEvent: (CardWebEvent) -> Void
        var lastHTML: String = ""

        init(onEvent: @escaping (CardWebEvent) -> Void) {
            self.onEvent = onEvent
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "tap":
                onEvent(.tap(typed: body["typed"] as? String ?? ""))
            case "showAnswer":
                onEvent(.showAnswer(typed: body["typed"] as? String ?? ""))
            case "play":
                let side = body["side"] as? String ?? "q"
                let idx = (body["idx"] as? NSNumber)?.intValue ?? 0
                onEvent(.play(side: side, index: idx))
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onEvent(.loaded)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Allow the initial document load and our media scheme; block everything else
            // (external links inside cards would otherwise navigate the card view away).
            if let url = navigationAction.request.url {
                if url.scheme == CardHTML.mediaScheme || url.scheme == "about" || url.absoluteString.hasSuffix("#") {
                    decisionHandler(.allow)
                    return
                }
                if navigationAction.navigationType == .linkActivated {
                    if url.scheme == "http" || url.scheme == "https" {
                        UIApplication.shared.open(url)
                    }
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }

        @objc func handleSwipe(_ g: UISwipeGestureRecognizer) {
            onEvent(.swipe(g.direction))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
