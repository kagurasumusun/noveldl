// test_core.cpp — unit tests ported from the Rust implementation
// (nokogiri_compat tests, storage tests, search tests, xhtml tests).
#include "../src/nc_common.h"
#include "../src/nc_config.h"
#include "../src/nc_download.h"
#include "../src/nc_html.h"
#include "../src/nc_http.h"
#include "../src/nc_regex.h"
#include "../src/nc_rules.h"
#include "../src/nc_storage.h"
#include "../src/nc_value.h"

#include <cstdio>
#include <filesystem>
#include <functional>

namespace fs = std::filesystem;
using namespace nc;

static int g_failures = 0;
static int g_passed = 0;

#define CHECK(cond)                                                              \
    do {                                                                         \
        if (!(cond)) {                                                           \
            std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);          \
            ++g_failures;                                                        \
        } else {                                                                 \
            ++g_passed;                                                          \
        }                                                                        \
    } while (0)

#define CHECK_EQ(a, b)                                                           \
    do {                                                                         \
        auto va = (a);                                                           \
        auto vb = (b);                                                           \
        if (!(va == vb)) {                                                       \
            std::printf("FAIL %s:%d: %s == %s\n", __FILE__, __LINE__, #a, #b);   \
            ++g_failures;                                                        \
        } else {                                                                 \
            ++g_passed;                                                          \
        }                                                                        \
    } while (0)

static std::string yaml_text(const std::string& y) { return y; }

static Value preset_of(const std::string& yaml) {
    return RulesParser::normalize_legacy(yaml_parse(yaml));
}

// ── YAML ──────────────────────────────────────────────────────────────────
static void test_yaml() {
    Value v = yaml_parse("a: 1\nb: hello\nc:\n  - x\n  - y: 2\n    z: 3\nd: |\n  line1\n  line2\ne: |-\n  tail\ndone: yes\nnil: null\n");
    CHECK_EQ(v.get_int("a"), 1);
    CHECK_EQ(v.get_str("b"), std::string("hello"));
    CHECK_EQ(v.get("c")->size(), (size_t)2);
    CHECK_EQ(v.get("c")->arr[1].get_int("y"), 2);
    CHECK(v.get_str("d").find("line1\nline2") == 0);
    CHECK_EQ(v.get_str("e"), std::string("tail"));
    CHECK_EQ(v.get_bool("done"), true);
    CHECK(v.get("nil")->is_null());

    Value flow = yaml_parse("list: []\nmap: {}\ninline: {a: 1, b: two}\n");
    CHECK(flow.get("list")->is_array());
    CHECK_EQ(flow.get("list")->size(), (size_t)0);
    CHECK_EQ(flow.get("inline")->get_str("b"), std::string("two"));

    Value q = yaml_parse("k: \"va: lue\"\n'quoted key': 5\n");
    CHECK_EQ(q.get_str("k"), std::string("va: lue"));
    CHECK_EQ(q.get_int("quoted key"), 5);
}

// ── JSON ──────────────────────────────────────────────────────────────────
static void test_json() {
    Value v = json_parse(R"({"work":{"title":"API作品"},"episodes":[{"id":10,"url":"/e/10"}],"n":1.5,"b":true})");
    CHECK_EQ(v.get("work")->get_str("title"), std::string("API作品"));
    CHECK_EQ(json_path_string(v, "$.episodes[0].id").value_or(""), std::string("10"));
    CHECK_EQ(json_path_string(v, "episodes[0].url").value_or(""), std::string("/e/10"));
    CHECK(v.get_bool("b"));
    std::string dumped = json_dump(v);
    CHECK(dumped.find("API作品") != std::string::npos);
}

// ── regex ─────────────────────────────────────────────────────────────────
static void test_regex() {
    Regex re("Episode;(?<index>\\d+);(?<subupdate>[^;]+);(?<subtitle>.+?)$", true, false);
    auto m = re.search("Episode;42;updated;レガシー話");
    CHECK(m.has_value());
    CHECK_EQ(m->name_or("index", ""), std::string("42"));
    CHECK_EQ(m->name_or("subtitle", ""), std::string("レガシー話"));

    Regex ts("^(次へ|next|>|＞)$", false, true);
    CHECK(ts.is_match("次へ"));
    CHECK(ts.is_match("NEXT"));
    CHECK(!ts.is_match("前へ"));

    Regex dotall("(?s)<main>(?<body>.+?)</main>", false, false);
    auto m2 = dotall.search("<main><p>line1\nline2</p></main>");
    CHECK(m2.has_value());
    CHECK(m2->name_or("body", "").find("line1") != std::string::npos);

    Regex dollar("foo$", false, false);
    CHECK(dollar.is_match("foo"));
    CHECK(dollar.is_match("foo\nbar\nfoo"));
    CHECK(!dollar.is_match("foobar"));

    Regex backref("a(?<x>\\d+)b\\k<x>c", false, false);
    CHECK(backref.is_match("a12b12c"));
    CHECK(!backref.is_match("a12b13c"));

    Regex repl("(?<a>\\d+)", false, false);
    CHECK_EQ(repl.replace_all("x12y34", "${a}!"), std::string("x12!y34!"));
}

// ── HTML / CSS ────────────────────────────────────────────────────────────
static void test_html_select() {
    HtmlDoc doc = parse_html(
        "<div id='maind'><span itemprop='name'>作品名</span>"
        "<div class='ss'>skip</div><div class='ss'>あらすじ本文</div></div>"
        "<table><tr><td colspan='2'><strong>第一章</strong></td></tr>"
        "<tr class='bgcolor1'><td><span id='1'> </span><a href='.//1.html'>1話</a>改稿</td></tr></table>");
    CHECK_EQ(select_extract_doc(*doc, "[itemprop='name']", "text").value_or(""),
             std::string("作品名"));
    CHECK_EQ(select_extract_doc(*doc, "div.ss:nth-of-type(2)", "text").value_or(""),
             std::string("あらすじ本文"));
    auto rows = select_all(*doc, "table tr");
    CHECK_EQ(rows.size(), (size_t)2);
    CHECK_EQ(select_extract_on(*rows[1], "a[href]").value_or(""), std::string("1話"));
    CHECK_EQ(select_extract_on(*rows[1], "a[href]::attr(href)").value_or(""),
             std::string(".//1.html"));
    CHECK_EQ(select_extract_on(*rows[1], "span[id]::attr(id)").value_or(""), std::string("1"));
    std::string inner = html_inner(*rows[1]);
    CHECK(inner.find("改稿") != std::string::npos);

    HtmlDoc doc2 = parse_html("<meta property='og:title' content='作品（作者） | Site'>");
    CHECK_EQ(select_extract_doc(*doc2, "meta[property='og:title']::attr(content)", "text").value_or(""),
             std::string("作品（作者） | Site"));

    HtmlDoc doc3 = parse_html("<ul><li><a href='/1'>一</a></li><li><a href='/2'>二</a></li></ul>");
    auto items = select_all(*doc3, "li");
    CHECK_EQ(items.size(), (size_t)2);
    CHECK_EQ(select_extract_on(*items[0], ":self").value_or(""), std::string("一"));
    CHECK(!select_extract_on(*items[0], ":self::attr(class)").has_value());
}

// ── rules engine (ports of nokogiri_compat tests) ─────────────────────────
static void test_rules_injection() {
    Value preset = preset_of(R"YAML(
novel_info_selectors:
  title: "h1"
toc_sources:
  - source: selector
    selector: "li.episode"
    item_selectors:
      subtitle: "a"
      href: "a::attr(href)"
body_selectors:
  - selector: "article"
)YAML");
    RulesParser parser(preset);
    ParsedToc toc = parser.parse_toc("<h1>作品</h1><ul><li class='episode'><a href='/1'>一話</a></li></ul>");
    CHECK_EQ(toc.title.value_or(""), std::string("作品"));
    CHECK_EQ(toc.chapters.size(), (size_t)1);
    CHECK_EQ(toc.chapters[0].href, std::string("/1"));
    ParsedSection sec = parser.parse_section("<article><p>本文</p></article>");
    CHECK_EQ(sec.body, std::string("<p>本文</p>"));
}

static void test_rules_page_range() {
    Value preset = preset_of(R"YAML(
toc_sources:
  - source: page
    mode: range
    max_page_selector: "a.last::attr(href)"
    max_page_pattern: "p=(\\d+)"
    url_template: "?p={page}"
    start_page: 2
body_selectors:
  - selector: "article"
)YAML");
    RulesParser parser(preset);
    auto hrefs = parser.parse_toc_page_hrefs("<a class='last' href='?p=4'>最後</a>");
    CHECK_EQ(hrefs.size(), (size_t)3);
    CHECK_EQ(hrefs[0], std::string("?p=2"));
    CHECK_EQ(hrefs[2], std::string("?p=4"));
}

static void test_rules_custom_site_no_defaults() {
    RulesParser parser(preset_of("body_selectors:\n  - selector: article\n"));
    // コンテンツ抽出のルールは推測しない(既定なし)。
    auto sec = parser.parse_section("<article>ただの記事</article>");
    CHECK(sec.body.find("ただの記事") != std::string::npos);  // body_selectors がある分のみ動く
    // ページ送りリンクはルール無しでも汎用検出する(ページ分割された目次への対応)。
    CHECK_EQ(parser.parse_toc_page_hrefs("<nav><a href='?p=2'>次へ</a></nav>").size(), (size_t)1);
}

static void test_rules_api_json() {
    Value preset = preset_of(R"(
novel_info_selectors:
  title: "$.work.title"
  author: "$.work.author"
toc_sources:
  - source: json
    selector: "$"
    list_path: "$.episodes"
    href_path: "url"
    title_path: "title"
    index_path: "id"
    href_pattern: "^/api/episodes/"
body_selectors:
  - json_path: "$.episode.bodyHtml"
)");
    RulesParser parser(preset);
    std::string toc_json = R"({
      "work":{"title":"API作品","author":"API作者"},
      "episodes":[
        {"id":10,"url":"/api/episodes/10","title":"API第一話"},
        {"id":11,"url":"/api/episodes/11","title":"API第二話"}
      ]
    })";
    ParsedToc toc = parser.parse_toc(toc_json);
    CHECK_EQ(toc.title.value_or(""), std::string("API作品"));
    CHECK_EQ(toc.chapters.size(), (size_t)2);
    CHECK_EQ(toc.chapters[0].index, std::string("10"));
    CHECK_EQ(toc.chapters[1].subtitle, std::string("API第二話"));
    ParsedSection sec = parser.parse_section(R"({"episode":{"bodyHtml":"<p>JSON本文</p>"}})");
    CHECK_EQ(sec.body, std::string("<p>JSON本文</p>"));
}

static void test_rules_legacy_yaml() {
    Value preset = preset_of(R"(
name: legacy
subtitles: '(?s)Episode;(?<index>\d+);(?<subupdate>[^;]+);(?<subtitle>.+?)$'
href: '/episodes/\k<index>'
body_pattern: '(?s)<main>(?<body>.+?)</main>'
)");
    RulesParser parser(preset);
    ParsedToc toc = parser.parse_toc("Episode;42;updated;レガシー話");
    CHECK_EQ(toc.chapters.size(), (size_t)1);
    CHECK_EQ(toc.chapters[0].index, std::string("42"));
    CHECK_EQ(toc.chapters[0].href, std::string("/episodes/42"));
    CHECK_EQ(toc.chapters[0].subupdate.value_or(""), std::string("updated"));
    ParsedSection sec = parser.parse_section("<main><p>legacy body</p></main>");
    CHECK_EQ(sec.body, std::string("<p>legacy body</p>"));
}

static void test_rules_novelup_next_data() {
    config::seed_default_presets();
    Value preset = config::load_effective_preset("novelup.plus");
    RulesParser parser(preset);
    std::string html = R"(<html><head>
        <meta property="og:title" content="作品タイトル（作者名） | 小説投稿サイトノベルアップ＋">
        </head><body>
        <script id='__NEXT_DATA__' type='application/json'>
        {"props":{"pageProps":{"episodes":[
          {"path":"/story/982784058/292750332","title":"第一話"},
          {"url":"https://novelup.plus/story/982784058/292750333","name":"第二話"}
        ]}}}
        </script>
        <link rel='next' href='/story/982784058?p=2'>
        </body></html>)";
    ParsedToc toc = parser.parse_toc(html);
    CHECK_EQ(toc.title.value_or(""), std::string("作品タイトル"));
    CHECK_EQ(toc.author.value_or(""), std::string("作者名"));
    CHECK_EQ(toc.chapters.size(), (size_t)2);
    CHECK_EQ(toc.chapters[1].href, std::string("/story/982784058/292750333"));
    auto next = parser.parse_toc_page_hrefs(html);
    CHECK_EQ(next.size(), (size_t)1);
    CHECK_EQ(next[0], std::string("/story/982784058?p=2"));
}

static void test_rules_narou_pages() {
    config::seed_default_presets();
    RulesParser parser(config::load_effective_preset("ncode.syosetu.com"));
    std::string html = R"(
            <div class="c-pager">
              <a href="/n4830bu/?p=2" class="c-pager__item c-pager__item--next">次へ</a>
            </div>)";
    auto next = parser.parse_toc_page_hrefs(html);
    CHECK_EQ(next.size(), (size_t)1);
    CHECK_EQ(next[0], std::string("/n4830bu/?p=2"));

    std::string query_only = R"(<html><body>
        <div class="c-pager">
          <a href="?p=1">1</a>
          <a href="?p=2">次へ</a>
        </div>
        </body></html>)";
    auto next2 = parser.parse_toc_page_hrefs(query_only);
    CHECK_EQ(next2.size(), (size_t)1);
    CHECK_EQ(next2[0], std::string("?p=2"));
}

static void test_rules_kakuyomu() {
    config::seed_default_presets();
    RulesParser parser(config::load_effective_preset("kakuyomu.jp"));
    std::string html = R"(
        <html><head><title>作品 - カクヨム</title></head><body>
        <a href="/works/16817139555994570519/episodes/16817330666680479196">2022年6月20日 12:00</a>
        <script>{"__typename":"Episode","id":"16817330666680479196","title":"第1話　名前"}</script>
        <script>{"__typename":"Episode","id":"16817330666680479197","title":"第2話　続き"}</script>
        <div class="widget-episodeBody js-episode-body"><p>body</p></div>
        </body></html>)";
    ParsedToc toc = parser.parse_toc(html);
    CHECK_EQ(toc.chapters.size(), (size_t)2);
    CHECK_EQ(toc.chapters[0].href, std::string("episodes/16817330666680479196"));
    CHECK_EQ(toc.chapters[0].subtitle, std::string("第1話　名前"));
    ParsedSection sec = parser.parse_section(html);
    CHECK_EQ(sec.body, std::string("<p>body</p>"));
}

static void test_rules_hameln() {
    config::seed_default_presets();
    RulesParser parser(config::load_effective_preset("syosetu.org"));
    std::string html = R"(<html><body>
        <div id="maind">
          <span itemprop="name">作品名</span>
          <span itemprop="author">作者名</span>
          <div class="ss">skip</div>
          <div class="ss">あらすじ本文</div>
        </div>
        <table>
          <tr><td colspan="2"><strong>第一章</strong></td></tr>
          <tr class="bgcolor1"><td><span id="1"> </span><a href=".//1.html">1話</a>改稿</td></tr>
        </table>
        </body></html>)";
    ParsedToc toc = parser.parse_toc(html);
    CHECK_EQ(toc.title.value_or(""), std::string("作品名"));
    CHECK_EQ(toc.author.value_or(""), std::string("作者名"));
    CHECK_EQ(toc.story.value_or(""), std::string("あらすじ本文"));
    CHECK_EQ(toc.chapters.size(), (size_t)1);
    CHECK_EQ(toc.chapters[0].chapter.value_or(""), std::string("第一章"));
    CHECK_EQ(toc.chapters[0].subupdate.value_or(""), std::string("revised"));
}

static void test_rules_narou_full_toc() {
    config::seed_default_presets();
    RulesParser parser(config::load_effective_preset("ncode.syosetu.com"));
    std::string html = R"(<html><head><title>なろう作品</title></head><body>
        <div class="p-eplist__sublist">
          <div class="p-eplist__chapter-title">第一章</div>
          <a class="p-eplist__subtitle" href="/n4830bu/1/">はじまり</a>
          <div class="p-eplist__update">2024/01/01</div>
        </div>
        <div class="p-eplist__sublist">
          <a class="p-eplist__subtitle" href="/n4830bu/2/">つづき</a>
        </div>
        <div class="c-pager"><a class="c-pager__item c-pager__item--next" href="/n4830bu/?p=2">次へ</a></div>
        </body></html>)";
    ParsedToc toc = parser.parse_toc(html);
    CHECK_EQ(toc.chapters.size(), (size_t)2);
    CHECK_EQ(toc.chapters[0].chapter.value_or(""), std::string("第一章"));
    CHECK_EQ(toc.chapters[0].subtitle, std::string("はじまり"));
    CHECK_EQ(toc.chapters[1].chapter.value_or(""), std::string("第一章"));
}

static void test_legacy_next_toc() {
    Value preset = preset_of(R"YAML(
domain: ncode.syosetu.com
subtitles: '<a href="(?<href>/n0001aa/(?<index>\d+)/)">(?<subtitle>.+?)</a>'
href: '\k<href>'
next_toc: '<a href="/(?<next_page>n0001aa/\?p=2)" class="c-pager__item c-pager__item--next">'
next_url: 'https://\k<domain>/\k<next_page>'
body_pattern: '(?s)<main>(?<body>.+?)</main>'
)YAML");
    RulesParser parser(preset);
    auto hrefs = parser.parse_toc_page_hrefs(
        R"HTML(<a href="/n0001aa/?p=2" class="c-pager__item c-pager__item--next">次へ</a>)HTML");
    CHECK_EQ(hrefs.size(), (size_t)1);
    if (!hrefs.empty())
        CHECK_EQ(hrefs[0], std::string("https://ncode.syosetu.com/n0001aa/?p=2"));
}

// ── xhtml ─────────────────────────────────────────────────────────────────
static void test_xhtml() {
    std::string n1 = xhtml_normalize_fragment(
        "<p><ruby><rb>漢字</rb><rp>（</rp><rt>かんじ</rt><rp>）</rp></ruby></p>");
    CHECK(n1.find("<ruby>") != std::string::npos);
    CHECK(n1.find("<rt>かんじ</rt>") != std::string::npos);
    std::string n2 = xhtml_normalize_fragment("これは｜漢字《かんじ》です");
    CHECK(n2.find("<ruby><rb>漢字</rb>") != std::string::npos);
    CHECK(n2.find("<rt>かんじ</rt>") != std::string::npos);
    std::string az = html_to_aozora("<p><ruby><rb>漢字</rb><rt>かんじ</rt></ruby>です</p>", false, false);
    CHECK(az.find("｜漢字《かんじ》") != std::string::npos);
}

// ── storage ───────────────────────────────────────────────────────────────
static std::string temp_dir(const std::string& name) {
    static int counter = 0;
    std::string dir = (fs::temp_directory_path() /
                       ("nc_test_" + name + "_" + std::to_string(++counter))).string();
    fs::create_directories(dir);
    return dir;
}

static void test_storage() {
    std::string root = temp_dir("storage");
    std::string master = root + "/master.db";
    {
        SectionStorage storage(master);
        storage.upsert_novel("example.com:/works/1", "Example", "Author",
                             "https://example.com/works/1", "example.com", root, 2,
                             "2026-05-28T00:00:00Z");
        std::vector<StoredTocChapter> chapters = {
            {"1", "chapter-1", "Chapter 1"},
            {"2", "chapter-2", "Chapter 2"},
        };
        storage.upsert_section_placeholders("example.com:/works/1", chapters,
                                            "2026-05-28T00:00:00Z");
        CHECK_EQ(storage.cached_toc_chapters("example.com:/works/1").size(), (size_t)2);

        SectionUpsert up;
        up.novel_id = "example.com:/works/1";
        up.chapter_index = "1";
        up.subtitle = "Chapter 1";
        up.source_url = "chapter-1";
        up.intro_xhtml = std::string("<p>intro</p>");
        up.body_xhtml = "<p>body</p>";
        up.post_xhtml = std::nullopt;
        up.source_signature = "sig-a";
        up.updated_at = "2026-05-28T00:00:01Z";
        storage.upsert_sections({up});

        auto state = storage.section_download_state("example.com:/works/1", "1");
        CHECK(state.has_value());
        CHECK_EQ(state->first, std::string("sig-a"));
        CHECK_EQ(state->second, true);
        auto state2 = storage.section_download_state("example.com:/works/1", "2");
        CHECK(state2.has_value());
        CHECK_EQ(state2->second, false);

        auto sec = storage.get_section("example.com:/works/1", "1");
        CHECK(sec.has_value());
        CHECK_EQ(sec->body_xhtml, std::string("<p>body</p>"));
        CHECK_EQ(sec->intro_xhtml, std::string("<p>intro</p>"));
    }
    // reopen + list
    SectionStorage storage2(master);
    auto items = storage2.list_novels();
    CHECK_EQ(items.size(), (size_t)1);
    CHECK_EQ(items[0].title, std::string("Example"));
    auto discovered = discover_downloaded_novels(root);
    CHECK_EQ(discovered.size(), (size_t)1);
    fs::remove_all(root);
}

static void test_storage_zstd() {
    std::string blob = compress_zstd_str("圧縮テスト");
    CHECK_EQ(decompress_zstd_str(blob), std::string("圧縮テスト"));
}

static void test_novel_id() {
    CHECK_EQ(novel_id_from_toc_url("https://ncode.syosetu.com/n1234ab/"),
             std::string("ncode.syosetu.com:/n1234ab"));
    CHECK_EQ(novel_id_from_toc_url("https://www.kakuyomu.jp/works/123"),
             std::string("kakuyomu.jp:/works/123"));
}

static void test_section_sort_key() {
    CHECK_EQ(section_sort_key("12"), 12.0);
    CHECK(section_sort_key("extra") >= 0);
}

// ── URL helpers ───────────────────────────────────────────────────────────
static void test_toc_next_page_detection() {
    // 明示ルール無しでも「次へ」リンク / rel="next" から複数ページ目の目次を辿れる。
    RulesParser empty(Value::map_());
    std::string html =
        "<div class=\"index\"><a href=\"/novel/1/1.html\">1話</a></div>"
        "<nav><a href=\"/novel/1/?p=2\">次へ</a></nav>";
    auto hrefs = empty.parse_toc_page_hrefs(html);
    CHECK(hrefs.size() == 1 && hrefs[0] == "/novel/1/?p=2");

    std::string html2 =
        "<a rel=\"next\" href=\"https://x.y/list?page=3\">次</a>"
        "<a href=\"/home\">ホーム</a>";
    auto hrefs2 = empty.parse_toc_page_hrefs(html2);
    CHECK(hrefs2.size() == 1 && hrefs2[0] == "https://x.y/list?page=3");

    // 送りリンクが無ければ空のまま(誤検出しない)。
    std::string html3 = "<a href=\"/home\">ホーム</a><a href=\"/about\">このサイトについて</a>";
    auto hrefs3 = empty.parse_toc_page_hrefs(html3);
    CHECK(hrefs3.empty());
}

static void test_image_srcs() {
    // 既定: <img src=...> を抽出(data: は除外)。
    RulesParser empty(Value::map_());
    auto srcs = empty.parse_image_srcs(
        "<p>あ</p><img src=\"/a/b.png\" alt><img data:x src='https://e/f.jpg'>"
        "<img src=\"data:image/png;base64,xx\">");
    CHECK(srcs.size() == 2 && srcs[0] == "/a/b.png" && srcs[1] == "https://e/f.jpg");

    // image_pattern で抽出ルールを上書きできる(サイトごとの対応)。
    Value preset = preset_of("image_pattern: \"cdn[.]example/([a-z0-9]+[.]png)\"");
    RulesParser custom(preset);
    auto srcs2 = custom.parse_image_srcs("<img src=\"cdn.example/abc123.png\">");
    CHECK(srcs2.size() == 1 && srcs2[0] == "abc123.png");
}

static void test_urls() {
    CHECK_EQ(url_absolute("https://a.example/works/1", "/e/2"), std::string("https://a.example/e/2"));
    CHECK_EQ(url_absolute("https://a.example/works/1", "2.html"),
             std::string("https://a.example/works/2.html"));
    CHECK_EQ(url_absolute("https://a.example/works/1/", "?p=2"),
             std::string("https://a.example/works/1/?p=2"));
    CHECK_EQ(url_host("https://www.Example.COM/x"), std::string("www.example.com"));
    CHECK_EQ(url_path_query("https://a.example/x?y=1#z"), std::string("/x?y=1"));
}


// ── 年齢ゲート自動通過 (confirm_over18 + 「はい」リンク自動クリック) ──────────
static void test_age_gate_flow() {
    static int novel_hits = 0;
    static bool gate_clicked = false;
    static bool sent_r18_cookie = false;
    novel_hits = 0;
    gate_clicked = false;
    sent_r18_cookie = false;

    const std::string kGate =
        "<html><head><title>R18\351\226\262\350\246\247\347\242\272\350\252\215\343\203\232\343\203\274\343\202\270</title></head><body>"
        "<div>\343\201\202\343\201\252\343\201\237\343\201\25718\346\255\263\344\273\245\344\270\212\343\201\247\343\201\231\343\201\213\357\274\237</div>"
        "<a href=\"https://example.test/?cookie_set=r18\">\343\201\257\343\201\204</a>"
        "</body></html>";
    const std::string kContent =
        "<html><body><div class=\"honbun\">\346\234\254\346\226\207\343\203\206\343\202\271\343\203\210</div></body></html>";

    set_transport([&](const std::string& url,
                      const std::vector<std::pair<std::string, std::string>>& headers,
                      int) -> HttpResponse {
        HttpResponse r;
        if (url.find("cookie_set") != std::string::npos) {
            gate_clicked = true;
            r.status = 200;
            r.body = "ok";
            r.set_cookies = "r18=ok; path=/";
            return r;
        }
        ++novel_hits;
        bool has = false;
        for (auto& kv : headers)
            if (kv.first == "Cookie" && kv.second.find("r18=ok") != std::string::npos) has = true;
        if (has && gate_clicked) {
            sent_r18_cookie = has;
            r.status = 200;
            r.body = kContent;
        } else {
            r.status = 200;
            r.body = kGate;
        }
        return r;
    });

    AccessSettings access;
    access.confirm_over18 = true;
    HttpClient http;
    std::string body =
        http.fetch("https://example.test/novel/1/", access, std::nullopt);
    CHECK(gate_clicked);          // 「はい」リンクが自動クリックされた
    CHECK(sent_r18_cookie);       // ゲート応答のクッキーが再送された
    CHECK(novel_hits >= 2);       // 再取得が走った
    CHECK(body.find("\346\234\254\346\226\207") != std::string::npos);  // 本文が取れた
    set_transport(nullptr);
}

int main() {
#define RUN(f) do { std::printf("[run] %s\n", #f); std::fflush(stdout); f(); } while(0)
    RUN(test_yaml);
    RUN(test_json);
    RUN(test_regex);
    RUN(test_html_select);
    RUN(test_image_srcs);
    RUN(test_toc_next_page_detection);
    RUN(test_rules_injection);
    RUN(test_rules_page_range);
    RUN(test_rules_custom_site_no_defaults);
    RUN(test_rules_api_json);
    RUN(test_rules_legacy_yaml);
    RUN(test_rules_novelup_next_data);
    RUN(test_rules_narou_pages);
    RUN(test_rules_kakuyomu);
    RUN(test_rules_hameln);
    RUN(test_rules_narou_full_toc);
    RUN(test_legacy_next_toc);
    RUN(test_xhtml);
    RUN(test_storage);
    RUN(test_storage_zstd);
    RUN(test_novel_id);
    RUN(test_section_sort_key);
    RUN(test_urls);

    test_age_gate_flow();
    std::printf("%d passed, %d failed\n", g_passed, g_failures);
    return g_failures == 0 ? 0 : 1;
}
