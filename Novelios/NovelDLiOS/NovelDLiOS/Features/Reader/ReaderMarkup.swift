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
        /// "serif" (Mincho-like), "sans" (Gothic), "mono"
        var design: String = "serif"

        var bodyFont: UIFont {
            switch design {
            case "sans":
                return UIFont.systemFont(ofSize: fontSize, weight: .regular)
            case "mono":
                return UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            default:
                let base = UIFont.systemFont(ofSize: fontSize, weight: .regular)
                if let desc = base.fontDescriptor.withDesign(.serif) {
                    return UIFont(descriptor: desc, size: fontSize)
                }
                return base
            }
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
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
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
        guard let m = re.firstMatch(in: inner, range: NSRange(location: 0, length: ns.length)) else {
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
        // Nyxian の SDK では attributes 引数は非 optional の CFDictionary として
        // インポートされる（nil 不可）— 空の NSDictionary をブリッジして渡す。
        let noAttrs = NSDictionary() as CFDictionary
        let annotation = CTRubyAnnotationCreateWithAttributes(
            .auto, .auto, .before,
            (ruby as CFString), noAttrs)
        var rubyAttrs = attrs
        rubyAttrs[rubyKey] = annotation
        return NSAttributedString(string: base, attributes: rubyAttrs)
    }

    /// 画像は描画を止めないため小さな罫に置き換える(同期取得=かくつきの原因)。
    private func imageAttachment(src: String, style: Style) -> NSAttributedString {
        let att = NSTextAttachment()
        att.bounds = CGRect(x: 0, y: 0, width: min(style.maxWidth, 160), height: 6)
        return NSAttributedString(attachment: att)
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
            re?.matches(in: out, range: NSRange(location: 0, length: (out as NSString).length))
                .reversed().forEach { m in
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
