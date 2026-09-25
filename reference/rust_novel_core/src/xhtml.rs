use regex::Regex;

/// Very small XHTML subset normalizer for chapter fragments.
/// Keeps parser site definitions untouched and only reshapes fetched HTML.
pub struct XhtmlSubsetNormalizer;

impl XhtmlSubsetNormalizer {
    pub fn normalize_fragment(fragment: &str) -> String {
        let mut s = fragment.replace("\r\n", "\n").replace('\r', "\n");
        let br_re = Regex::new(r"(?i)<br\s*/?>").expect("valid br regex");
        s = br_re.replace_all(&s, "<br/>").into_owned();

        let p_open_re = Regex::new(r"(?i)<p(\s[^>]*)?>").expect("valid p open regex");
        s = p_open_re
            .replace_all(&s, |caps: &regex::Captures| {
                let attrs = caps.get(1).map(|m| m.as_str()).unwrap_or("");
                format!("<p{}>", attrs)
            })
            .into_owned();

        let hr_re = Regex::new(r"(?i)<hr\s*/?>").expect("valid hr regex");
        s = hr_re.replace_all(&s, "<hr/>").into_owned();

        s = Self::aozora_ruby_to_xhtml(&s);
        s.trim().to_string()
    }

    fn aozora_ruby_to_xhtml(input: &str) -> String {
        let marked = Regex::new(r"｜([^《<>]+?)《([^》<>]+?)》").expect("valid marked ruby regex");
        let s = marked
            .replace_all(
                input,
                "<ruby><rb>$1</rb><rp>（</rp><rt>$2</rt><rp>）</rp></ruby>",
            )
            .into_owned();

        let kanji = Regex::new(r"([一-龯々〆ヶ]+)《([^》<>]+?)》").expect("valid kanji ruby regex");
        kanji
            .replace_all(
                &s,
                "<ruby><rb>$1</rb><rp>（</rp><rt>$2</rt><rp>）</rp></ruby>",
            )
            .into_owned()
    }

    pub fn normalize_section(
        intro: Option<String>,
        body: String,
        post: Option<String>,
    ) -> NormalizedSection {
        NormalizedSection {
            introduction_xhtml: intro.map(|v| Self::normalize_fragment(&v)),
            body_xhtml: Self::normalize_fragment(&body),
            postscript_xhtml: post.map(|v| Self::normalize_fragment(&v)),
        }
    }
}

#[derive(Debug, Clone)]
pub struct NormalizedSection {
    pub introduction_xhtml: Option<String>,
    pub body_xhtml: String,
    pub postscript_xhtml: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::XhtmlSubsetNormalizer;

    #[test]
    fn normalize_fragment_preserves_html_ruby() {
        let input = "<p><ruby><rb>漢字</rb><rp>（</rp><rt>かんじ</rt><rp>）</rp></ruby></p>";
        let normalized = XhtmlSubsetNormalizer::normalize_fragment(input);
        assert!(normalized.contains("<ruby>"));
        assert!(normalized.contains("<rt>かんじ</rt>"));
    }

    #[test]
    fn normalize_fragment_converts_aozora_ruby() {
        let normalized = XhtmlSubsetNormalizer::normalize_fragment("これは｜漢字《かんじ》です");
        assert!(normalized.contains("<ruby><rb>漢字</rb>"));
        assert!(normalized.contains("<rt>かんじ</rt>"));
    }
}
