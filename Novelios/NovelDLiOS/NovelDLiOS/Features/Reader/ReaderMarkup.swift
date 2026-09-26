import UIKit
import CoreText

/// XHTML → NSAttributedString with CoreText ruby annotations.
/// Native only — no WKWebView anywhere in the reader.
/// 挿絵の読み込み元(実画像は ReaderView 側で非同期に差し替える)。
struct ImageRef: Equatable {
    let range: NSRange
    let src: String
}

struct ParseResult {
    let text: NSAttributedString
    let images: [ImageRef]
}

final class ReaderMarkup: @unchecked Sendable {
    private let rubyKey = NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)

    struct Style {
        var fontSize: CGFloat = 19
        var lineSpacing: CGFloat = 6
        var ink: UIColor = UIColor(red: 0.125, green: 0.118, blue: 0.102, alpha: 1)
        /// 夜テーマなど、地が暗く文字が明るいとき true。見出しの濃さに使う。
        var inkIsLight: Bool = false
        var maxWidth: CGFloat = 320
        /// "serif" (Mincho-like), "sans" (Gothic), "mono"
        var design: String = "serif"
        /// ルビ(振り仮名)を表示するか。
        var showRuby: Bool = true

        var bodyFont: UIFont {
            switch design {
            case "sans":
                return Self.jpSans(fontSize)
            case "rounded":
                return Self.jpRounded(fontSize)
            case "mono":
                return UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            default:
                return Self.jpSerif(fontSize)
            }
        }

        /// 日本語グリフを持つ明朝。UIFont の withDesign(.serif) は
        /// Times New Roman を指し日本語グリフが無いため、全文字が
        /// 異なるフォールバックに散って行間・字間がガタガタに見えていた。
        static func jpSerif(_ size: CGFloat) -> UIFont {
            for name in ["Hiragino Mincho ProN", "HiraMinProN-W3", "YuMincho", "YuMincho-Medium"] {
                if let f = UIFont(name: name, size: size) { return f }
            }
            let base = UIFont.systemFont(ofSize: size, weight: .regular)
            if let desc = base.fontDescriptor.withDesign(.serif) {
                return UIFont(descriptor: desc, size: size)
            }
            return base
        }

        /// 日本語グリフを持つゴシック。
        static func jpSans(_ size: CGFloat) -> UIFont {
            for name in ["Hiragino Sans", "HiraKakuProN-W3"] {
                if let f = UIFont(name: name, size: size) { return f }
            }
            return UIFont.systemFont(ofSize: size, weight: .regular)
        }

        /// 日本語グリフを持つ丸ゴシック。system の rounded は和文が無く、
        /// 未対応のまま明朝へ落ちていた。
        static func jpRounded(_ size: CGFloat) -> UIFont {
            for name in ["Hiragino Maru Gothic ProN", "HiraMaruProN-W4"] {
                if let f = UIFont(name: name, size: size) { return f }
            }
            return jpSans(size)
        }
    }

    func parse(_ xhtml: String, style: Style) -> ParseResult {
        var imageRefs: [ImageRef] = []
        let text = parseInner(xhtml, style: style, images: &imageRefs)
        return ParseResult(text: text, images: imageRefs)
    }

    /// 章タイトルの見出しブロック(本文の先頭に置く)。
    /// 中央寄せ・墨色を弱め・本文まで十分な余白(理想モックどおりの静かな見出し)。
    static func chapterHeading(title: String, style: Style) -> NSAttributedString {
        guard !title.isEmpty else { return NSAttributedString() }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineSpacing = 2
        para.paragraphSpacing = style.lineSpacing + 18
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Style.jpSerif(min(style.fontSize + 2, 26)),
            .foregroundColor: style.ink.withAlphaComponent(style.inkIsLight ? 0.92 : 0.72),
            .paragraphStyle: para,
        ]
        return NSAttributedString(string: title, attributes: attrs)
    }

    /// 前書き/本文/後書きの間に入る区切り(※ 印)。
    static func dividerBlock(style: Style) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = style.lineSpacing + 6
        return NSAttributedString(string: "\n※\n", attributes: [
            .font: Style.jpSerif(max(style.fontSize - 4, 12)),
            .foregroundColor: style.ink.withAlphaComponent(style.inkIsLight ? 0.62 : 0.45),
            .paragraphStyle: para,
        ])
    }

    /// XHTML から <img> タグだけを抜き出し、1枚1段落にして返す。
    /// (前書き/後書き非表示時の「挿絵のみ表示」用)
    static func imageOnlyXhtml(_ xhtml: String) -> String {
        guard xhtml.contains("<img") else { return "" }
        let ns = xhtml as NSString
        let re = try! NSRegularExpression(pattern: #"(?is)<img\s+[^>]*>"#)
        var out: [String] = []
        for mm in re.matches(in: xhtml, range: NSRange(location: 0, length: ns.length)) {
            out.append("<p>" + ns.substring(with: mm.range) + "</p>")
        }
        return out.joined()
    }

    private func parseInner(_ xhtml: String, style: Style, images: inout [ImageRef]) -> NSAttributedString {
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
                out.append(rubyAttributedString(
                    inner: ns.substring(with: m.range(at: 1)),
                    attributes: attrs,
                    showRuby: style.showRuby))
            } else if m.range(at: 2).location != NSNotFound {
                let src = ns.substring(with: m.range(at: 2))
                images.append(ImageRef(range: NSRange(location: out.length, length: 1), src: src))
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
        var decoded = decodeEntities(stripTags(raw))
        // タグ間の生テキストノードに含まれる改行・余白を整える。
        // そのまま append すると </p> と <p> の間のインデントや改行が空行として
        // 積み重なり、段落の間に巨大な隙間が空いて見えていた。
        // (全角空白 U+3000 の字下げは \s では潰さない — ASCII 余白のみ対象)
        decoded = decoded.replacingOccurrences(of: "[ \\t\\r]*\\n[ \\t\\r]*", with: "\n", options: .regularExpression)
        while decoded.contains("\n\n\n") {
            decoded = decoded.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        guard !decoded.isEmpty, decoded != "\n" || out.length > 0 else { return }
        out.append(NSAttributedString(string: decoded, attributes: attrs))
    }

    private func rubyAttributedString(
        inner: String,
        attributes attrs: [NSAttributedString.Key: Any],
        showRuby: Bool = true
    ) -> NSAttributedString {
        // なろう等は <ruby>漢字<rt>かんじ</rt></ruby> で <rb> が無い。
        // <rb> だけを基底にすると漢字が落ち、読みだけが本文に残る。
        let noRp = removingTag("rp", in: inner)
        if !showRuby {
            let cleaned = removingTag("rt", in: noRp)
            return NSAttributedString(string: decodeEntities(stripTags(cleaned)), attributes: attrs)
        }
        let ns = noRp as NSString
        guard let re = try? NSRegularExpression(
            pattern: #"(?is)<rt\b[^>]*>(.*?)</rt>"#) else {
            return NSAttributedString(string: decodeEntities(stripTags(noRp)), attributes: attrs)
        }
        let matches = re.matches(in: noRp, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else {
            return NSAttributedString(string: decodeEntities(stripTags(noRp)), attributes: attrs)
        }
        let out = NSMutableAttributedString()
        var cursor = 0
        for m in matches {
            let before = m.range.location > cursor
                ? ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                : ""
            let ruby = decodeEntities(stripTags(ns.substring(with: m.range(at: 1))))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            appendRubyGroup(before: before, ruby: ruby, to: out, attributes: attrs)
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            let tail = decodeEntities(stripTags(
                ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))))
            if !tail.isEmpty {
                out.append(NSAttributedString(string: tail, attributes: attrs))
            }
        }
        return out.length > 0
            ? out
            : NSAttributedString(string: decodeEntities(stripTags(noRp)), attributes: attrs)
    }

    /// `<rt>` の直前を基底にする。`<rb>` があればその中身、無ければタグを除いた文字。
    private func appendRubyGroup(
        before: String,
        ruby: String,
        to out: NSMutableAttributedString,
        attributes attrs: [NSAttributedString.Key: Any]
    ) {
        let ns = before as NSString
        if let rbRe = try? NSRegularExpression(pattern: #"(?is)<rb\b[^>]*>(.*?)</rb>"#),
           let m = rbRe.firstMatch(in: before, range: NSRange(location: 0, length: ns.length)) {
            let pre = decodeEntities(stripTags(ns.substring(with: NSRange(location: 0, length: m.range.location))))
            if !pre.isEmpty {
                out.append(NSAttributedString(string: pre, attributes: attrs))
            }
            let base = decodeEntities(stripTags(ns.substring(with: m.range(at: 1))))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            appendRubyBase(base, ruby: ruby, to: out, attributes: attrs)
            let postStart = m.range.location + m.range.length
            if postStart < ns.length {
                let post = decodeEntities(stripTags(
                    ns.substring(with: NSRange(location: postStart, length: ns.length - postStart))))
                if !post.isEmpty {
                    out.append(NSAttributedString(string: post, attributes: attrs))
                }
            }
            return
        }
        let base = decodeEntities(stripTags(before)).trimmingCharacters(in: .whitespacesAndNewlines)
        appendRubyBase(base, ruby: ruby, to: out, attributes: attrs)
    }

    private func appendRubyBase(
        _ base: String,
        ruby: String,
        to out: NSMutableAttributedString,
        attributes attrs: [NSAttributedString.Key: Any]
    ) {
        if !base.isEmpty, !ruby.isEmpty {
            out.append(rubyText(base: base, ruby: ruby, attributes: attrs))
        } else {
            let fallback = base.isEmpty ? ruby : base
            if !fallback.isEmpty {
                out.append(NSAttributedString(string: fallback, attributes: attrs))
            }
        }
    }

    private func removingTag(_ name: String, in input: String) -> String {
        let pattern = "<\(name)\\b[^>]*>.*?</\(name)>"
        guard let re = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return input }
        return re.stringByReplacingMatches(
            in: input,
            range: NSRange(location: 0, length: (input as NSString).length),
            withTemplate: "")
    }

    private func rubyText(base: String, ruby: String, attributes attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let baseFont = (attrs[.font] as? UIFont) ?? UIFont.systemFont(ofSize: 12)
        let rubyFont = UIFont(descriptor: baseFont.fontDescriptor, size: max(baseFont.pointSize * 0.45, 8))
        let rubyInk = (attrs[.foregroundColor] as? UIColor) ?? UIColor.label
        // 空の属性だとルビが黒のまま描かれ、夜テーマで消える。
        // CoreText は前景色を CGColor で読む。
        // NSColor / NSFont ではなく CT のキー。NS 側の名前だとルビ色は無視される。
        let annotationAttrs = NSMutableDictionary()
        annotationAttrs.setObject(rubyFont, forKey: kCTFontAttributeName as NSString)
        annotationAttrs.setObject(rubyInk.cgColor, forKey: kCTForegroundColorAttributeName as NSString)
        let annotation = CTRubyAnnotationCreateWithAttributes(
            .auto, .auto, .before,
            (ruby as CFString), annotationAttrs as CFDictionary)
        var baseAttrs = attrs
        baseAttrs[rubyKey] = annotation
        return NSAttributedString(string: base, attributes: baseAttrs)
    }

    /// 画像は描画を止めないため小さな罫に置き換える(同期取得=かくつきの原因)。
    /// 挿絵のプレースホルダ(実画像は後から非同期で差し替える)。
    static let placeholderImage = makePlaceholder(white: 0.82)
    static let placeholderImageNight = makePlaceholder(white: 0.16)

    private static func makePlaceholder(white: CGFloat) -> UIImage {
        let size = CGSize(width: 240, height: 180)
        let r = UIGraphicsImageRenderer(size: size)
        return r.image { ctx in
            UIColor(white: white, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func imageAttachment(src: String, style: Style) -> NSAttributedString {
        let att = NSTextAttachment()
        att.image = style.inkIsLight ? Self.placeholderImageNight : Self.placeholderImage
        let width = min(style.maxWidth, 280)
        att.bounds = CGRect(x: 0, y: -4, width: width, height: width * 0.75)
        let s = NSMutableAttributedString(attachment: att)
        s.addAttributes([.font: style.bodyFont], range: NSRange(location: 0, length: s.length))
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
        return s
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
