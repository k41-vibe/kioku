import Foundation

/// Builds the HTML document shown in the card web view, following Anki's
/// reviewer conventions: `<body class="card cardN [nightMode night_mode]">`
/// and `<div id="qa">` holding the rendered side.
enum CardHTML {
    static let mediaScheme = "kioku-media"
    static let baseURL = URL(string: "\(mediaScheme)://media/")!

    struct Side {
        var html: String
        var avTags: [Anki_CardRendering_AVTag]
        var typeAnswerField: String?    // field name found in [[type:...]]
        var typeIsCloze: Bool
    }

    /// Concatenate rslib's rendered nodes into plain HTML.
    static func join(_ nodes: [Anki_CardRendering_RenderedTemplateNode]) -> String {
        var out = ""
        for node in nodes {
            switch node.value {
            case .text(let t): out += t
            case .replacement(let r): out += r.currentText
            case .none: break
            }
        }
        return out
    }

    static let typeAnsPattern = try! NSRegularExpression(pattern: #"\[\[type:(.+?)\]\]"#)
    static let playPattern = try! NSRegularExpression(pattern: #"\[anki:play:(q|a):(\d+)\]"#)

    /// Replace `[anki:play:q:N]` placeholders with tappable replay buttons.
    static func replacePlayTags(_ html: String) -> String {
        let ns = html as NSString
        var result = ""
        var last = 0
        for m in playPattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let side = ns.substring(with: m.range(at: 1))
            let idx = ns.substring(with: m.range(at: 2))
            result += "<a class=\"kioku-replay\" href=\"#\" onclick=\"window.kiokuPlay('\(side)',\(idx));return false;\">&#9654;</a>"
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    /// Find `[[type:Field]]` / `[[type:cloze:Field]]` on the question side.
    static func typeAnswerField(in html: String) -> (field: String, cloze: Bool)? {
        let ns = html as NSString
        guard let m = typeAnsPattern.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var fld = ns.substring(with: m.range(at: 1))
        var cloze = false
        if fld.hasPrefix("cloze:") {
            cloze = true
            fld = String(fld.dropFirst("cloze:".count))
        }
        if fld.hasPrefix("nc:") {
            fld = String(fld.dropFirst("nc:".count))
        }
        return (fld, cloze)
    }

    /// Question side: swap the type marker for an input box (or remove it).
    static func injectTypeInput(_ html: String, hasField: Bool) -> String {
        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)
        let replacement = hasField
            ? "<center><input type=\"text\" id=\"typeans\" autocapitalize=\"off\" autocorrect=\"off\" autocomplete=\"off\" spellcheck=\"false\" placeholder=\"綴りを入力\" onkeydown=\"if(event.key==='Enter'){window.kiokuShowAnswer();return false;}\"></center>"
            : ""
        return typeAnsPattern.stringByReplacingMatches(in: html, range: range, withTemplate: replacement)
    }

    /// Answer side: replace the marker with the comparison HTML from rslib,
    /// keeping `<hr id=answer>` in front of it like Anki does.
    static func injectTypeComparison(_ html: String, comparison: String?) -> String {
        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let comparison else {
            return typeAnsPattern.stringByReplacingMatches(in: html, range: range, withTemplate: "")
        }
        var body = html
        let hadHR = body.contains("<hr id=answer>")
        if hadHR { body = body.replacingOccurrences(of: "<hr id=answer>", with: "") }
        var block = "<div style=\"margin-top:12px\">\(comparison)</div>"
        if hadHR { block = "<hr id=answer>" + block }
        let escaped = NSRegularExpression.escapedTemplate(for: block)
        let bodyNS = body as NSString
        return typeAnsPattern.stringByReplacingMatches(in: body, range: NSRange(location: 0, length: bodyNS.length), withTemplate: escaped)
    }

    static let memoFieldName = "メモ"

    /// Field names referenced by a template (`{{Field}}`, `{{hint:Field}}`, `{{#Field}}`…).
    static func referencedFields(in templates: [String]) -> Set<String> {
        var out = Set<String>()
        let re = try! NSRegularExpression(pattern: #"\{\{([^}]+)\}\}"#)
        for t in templates {
            let ns = t as NSString
            for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                var inner = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                if inner.hasPrefix("#") || inner.hasPrefix("^") || inner.hasPrefix("/") { inner.removeFirst() }
                let name = inner.split(separator: ":").last.map(String.init) ?? inner
                out.insert(name.trimmingCharacters(in: .whitespaces))
            }
        }
        return out
    }

    /// HTML block listing fields the template never shows (例文 etc.).
    static func extraFieldsHTML(_ pairs: [(String, String)]) -> String {
        guard !pairs.isEmpty else { return "" }
        var s = "<div class=\"kioku-extra\">"
        for (name, value) in pairs {
            let escaped = name.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            s += "<div class=\"kioku-extra-row\"><div class=\"kioku-extra-name\">\(escaped)</div><div class=\"kioku-extra-value\">\(value)</div></div>"
        }
        s += "</div>"
        return s
    }

    static func document(body: String, notetypeCSS: String, cardOrdinal: UInt32, night: Bool, forceMonochrome: Bool) -> String {
        var classes = "card card\(cardOrdinal + 1)"
        if night { classes += " nightMode night_mode" }
        let override = forceMonochrome ? "<style>\(Theme.monochromeOverrideCSS)</style>" : ""
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <base href="\(baseURL.absoluteString)">
        <style>\(Theme.baseCardCSS)</style>
        <style>\(notetypeCSS)</style>
        \(override)
        <script>
        window.kiokuPlay = function(side, idx) { window.webkit.messageHandlers.kioku.postMessage({type: 'play', side: side, idx: idx}); };
        window.kiokuShowAnswer = function() {
          var el = document.getElementById('typeans');
          window.webkit.messageHandlers.kioku.postMessage({type: 'showAnswer', typed: el ? el.value : ''});
        };
        document.addEventListener('click', function(e) {
          if (e.target.closest('a, button, input, textarea, select, video, audio, .kioku-replay')) { return; }
          var el = document.getElementById('typeans');
          window.webkit.messageHandlers.kioku.postMessage({type: 'tap', typed: el ? el.value : ''});
        }, false);
        window.addEventListener('load', function() {
          var a = document.getElementById('answer');
          if (a) { a.scrollIntoView(); }
        });
        </script>
        </head>
        <body class="\(classes)"><div id="qa">\(body)</div></body>
        </html>
        """
    }
}
