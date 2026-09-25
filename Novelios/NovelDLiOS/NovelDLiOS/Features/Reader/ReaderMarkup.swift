import UIKit
import CoreText

/// XHTML → NSAttributedString with CoreText ruby annotations.
/// Native only — no WKWebView anywhere in the reader.
final class ReaderMarkup: @unchecked Sendable {
    private let rubyKey = NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)

    struct Style {
        var fontSize: CGFloat = 19
        var lineSpacing: CGFloat = 6
        var ink: UIColor = UIColor(red: 0.125, green: 0.118, blue: 0.102, alpha: 1)
        var maxWidth: CGFloat = 320

        var bodyFont: UIFont {
            let base = UIFont.systemFont(ofSize: fontSize, weight: .regular)
            if let desc = base.fontDescriptor.withDesign(.serif) {
                return UIFont(descriptor: desc, size: fontSize)
            }
            return base
        }
    }

    func parse(_ xhtml: String, style: Style) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = style.lineSpacing
        para.alignment = .natural
        let attrs: [NSAttributedString.Key: Any] = [
            .font: style.bodyFont,
            .foregroundColor: style.ink,
            .paragraphStyle: para,
        ]

        let out = NSMutableAttributedString()
        let text = xhtml
        let pattern =
            #"(?is)<ruby\b[^>]*>(.*?)</ruby>|<img\s+[^>]*src\s*=\s*['\"]([^'\"]+)['\"][^>]*>|<br\s*/?>|</p>|<p[^>]*>|<[^>]+>"#
        guard let re = try? NSRegularExpression(pattern: pattern) else {
            return NSAttributedString(string: plain(xhtml), attributes: attrs)
        }
        let ns = text as NSString
        var cursor = 0
        for m in re.matches(in: text) {
            if m.range.location > cursor {
                appendText(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)), to: out, attributes: attrs)
            }
            let token = ns.substring(with: m.range)
            if token.lowercased().hasPrefix("<ruby") {
                out.append(rubyAttributedString(inner: ns.substring(with: m.range(at: 1)), attributes: attrs))
            } else if m.range(at: 2).location != NSNotFound {
                let src = ns.substring(with: m.range(at: 2))
                out.append(imageAttachment(src: src, style: style))
            } else if token.lowercased().hasPrefix("<br") {
                out.append(NSAttributedString(string: "\n", attributes: attrs))
            } else if token.lowercased() == "</p>" {
                out.append(NSAttributedString(string: "\n", attributes: attrs))
            } else if token.lowercased().hasPrefix("<p") {
                out.append(NSAttributedString(string: "\n", attributes: attrs))
            }
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            appendText(ns.substring(with: NSRange(location: cursor, length: ns.length - cursor)), to: out, attributes: attrs)
        }
        return out
    }

    private func appendText(_ raw: String, to out: NSMutableAttributedString, attributes attrs: [NSAttributedString.Key: Any]) {
        let decoded = decodeEntities(stripTags(raw))
        guard !decoded.isEmpty else { return }
        out.append(NSAttributedString(string: decoded, attributes: attrs))
    }

    private func rubyAttributedString(inner: String, attributes attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let ns = inner as NSString
        let re = try! NSRegularExpression(
            pattern: #"(?is)<rb[^>]*>(.*?)</rb>\s*<rt[^>]*>(.*?)</rt>|<rt[^>]*>(.*?)</rt>"#)
        guard let m = re.firstMatch(in: inner) else {
            return NSAttributedString(string: decodeEntities(stripTags(inner)), attributes: attrs)
        }
        var base = ""
        var ruby = ""
        if m.range(at: 1).location != NSNotFound {
            base = decodeEntities(stripTags(ns.substring(with: m.range(at: 1))))
            ruby = decodeEntities(stripTags(ns.substring(with: m.range(at: 2))))
        } else {
            ruby = decodeEntities(stripTags(ns.substring(with: m.range(at: 3))))
        }
        guard !base.isEmpty, !ruby.isEmpty else {
            return NSAttributedString(string: base.isEmpty ? ruby : base, attributes: attrs)
        }
        return rubyText(base: base, ruby: ruby, attributes: attrs)
    }

    private func rubyText(base: String, ruby: String, attributes attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let annotation = CTRubyAnnotationCreateWithAttributes(
            .auto, .auto, .before, .center,
            (ruby as CFString))
        var rubyAttrs = attrs
        rubyAttrs[rubyKey] = annotation
        return NSAttributedString(string: base, attributes: rubyAttrs)
    }

    private func imageAttachment(src: String, style: Style) -> NSAttributedString {
        let att = NSTextAttachment()
        if let url = URL(string: src), let data = fetchImageData(from: url),
            let img = UIImage(data: data) {
            let scale = style.maxWidth / max(img.size.width, 1)
            let size = scale < 1
                ? CGSize(width: img.size.width * scale, height: img.size.height * scale)
                : img.size
            att.image = img
            att.bounds = CGRect(origin: .zero, size: size)
        } else {
            att.bounds = CGRect(x: 0, y: 0, width: style.maxWidth, height: 8)
        }
        return NSAttributedString(attachment: att)
    }

    private func fetchImageData(from url: URL) -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            result = data
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 20)
        return result
    }

    private func stripTags(_ input: String) -> String {
        input.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private func decodeEntities(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var out = input
        let map = [
            "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&amp;": "&",
            "&nbsp;": " ", "&hellip;": "…", "&mdash;": "—",
        ]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        if out.contains("&#x") || out.contains("&#") {
            let re = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
            let ns = out as NSString
            var replaced = out
            re?.matches(in: out).reversed().forEach { m in
                let hex = ns.substring(with: m.range(at: 1)) == "x"
                let digits = ns.substring(with: m.range(at: 2))
                let value = UInt32(digits, radix: hex ? 16 : 10)
                if let value, let scalar = Unicode.Scalar(value) {
                    replaced = (replaced as NSString).replacingCharacters(
                        in: m.range, with: String(Character(scalar)))
                }
            }
            out = replaced
        }
        return out
    }

    private func plain(_ input: String) -> String {
        decodeEntities(stripTags(input))
    }
}
