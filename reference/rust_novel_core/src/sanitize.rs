use regex::Regex;

pub fn fragment(html: &str) -> String {
    if html.is_empty() {
        return String::new();
    }

    let re_script = Regex::new(r"(?is)<script[^>]*>.*?</script>").expect("valid regex");
    let re_style = Regex::new(r"(?is)<style[^>]*>.*?</style>").expect("valid regex");
    let re_comment = Regex::new(r"(?is)<!--.*?-->").expect("valid regex");
    let re_tag = Regex::new(r"(?is)<[^>]+>").expect("valid regex");
    let re_ws = Regex::new(r"\s+").expect("valid regex");

    let mut s = re_script.replace_all(html, " ").to_string();
    s = re_style.replace_all(&s, " ").to_string();
    s = re_comment.replace_all(&s, " ").to_string();
    s = re_tag.replace_all(&s, " ").to_string();
    s = s
        .replace("&nbsp;", " ")
        .replace("&#160;", " ")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'");

    re_ws.replace_all(s.trim(), " ").to_string()
}
