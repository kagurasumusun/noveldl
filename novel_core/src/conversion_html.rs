use regex::Regex;

pub struct HtmlConverter {
    text: String,
    strip_decoration_tag: bool,
}

impl HtmlConverter {
    pub fn new(input: impl Into<String>) -> Self {
        Self {
            text: input.into(),
            strip_decoration_tag: false,
        }
    }

    pub fn strip_decoration_tag(mut self, enabled: bool) -> Self {
        self.strip_decoration_tag = enabled;
        self
    }

    pub fn to_aozora(mut self, pre_html: bool) -> String {
        if !pre_html {
            self.text = br_to_aozora(&self.text);
        }
        self.text = p_to_aozora(&self.text);
        self.text = ruby_to_aozora(&self.text);
        if !self.strip_decoration_tag {
            self.text = decorate_tags(&self.text);
        }
        self.text = img_to_aozora(&self.text);
        self.text = em_to_sesame(&self.text);
        delete_tag(&self.text)
    }
}

fn br_to_aozora(s: &str) -> String {
    Regex::new(r"(?i)<br[^>]*>")
        .unwrap()
        .replace_all(&s.replace(['\r', '\n'], ""), "\n")
        .to_string()
}
fn p_to_aozora(s: &str) -> String {
    Regex::new(r"(?i)\n?</p>")
        .unwrap()
        .replace_all(s, "\n")
        .to_string()
}
fn img_to_aozora(s: &str) -> String {
    Regex::new(r#"(?is)<img.+?src=\"(?P<src>.+?)\".*?>"#)
        .unwrap()
        .replace_all(s, "［＃挿絵（$src）入る］")
        .to_string()
}
fn em_to_sesame(s: &str) -> String {
    Regex::new(r#"(?is)<em class=\"emphasisDots\">(.+?)</em>"#)
        .unwrap()
        .replace_all(s, "［＃傍点］$1［＃傍点終わり］")
        .to_string()
}

fn ruby_to_aozora(s: &str) -> String {
    let re = Regex::new(r"(?is)<ruby>(.+?)</ruby>").unwrap();
    re.replace_all(
        &s.replace('《', "≪").replace('》', "≫"),
        |caps: &regex::Captures| {
            let inner = caps.get(1).map(|m| m.as_str()).unwrap_or_default();
            let parts: Vec<&str> = Regex::new("(?i)<rt>").unwrap().split(inner).collect();
            if parts.len() < 2 {
                return delete_tag(parts[0]);
            }
            let rb = Regex::new("(?i)<rp>")
                .unwrap()
                .split(parts[0])
                .next()
                .unwrap_or_default();
            let rt = Regex::new("(?i)<rp>")
                .unwrap()
                .split(parts[1])
                .next()
                .unwrap_or_default();
            format!("｜{}《{}》", delete_tag(rb), delete_tag(rt))
        },
    )
    .to_string()
}

fn decorate_tags(s: &str) -> String {
    Regex::new("(?i)<b>")
        .unwrap()
        .replace_all(s, "［＃太字］")
        .to_string()
        .replace("</b>", "［＃太字終わり］")
        .replace("<i>", "［＃斜体］")
        .replace("</i>", "［＃斜体終わり］")
        .replace("<s>", "［＃取消線］")
        .replace("</s>", "［＃取消線終わり］")
}

fn delete_tag(s: &str) -> String {
    let re = Regex::new(r"(?is)<[^>]+>").unwrap();
    let mut current = s.to_string();
    loop {
        let next = re.replace_all(&current, "").to_string();
        if next == current {
            return next;
        }
        current = next;
    }
}
