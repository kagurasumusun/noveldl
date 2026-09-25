// nc_builtin_presets.cpp — GENERATED from presets/parsers/*.yaml
// Site support is data driven: edit the YAML files (or user overlays),
// never C/C++, to add or fix sites.  Regenerate with tools/gen_presets.py.
#include "nc_config.h"

namespace nc {

const std::vector<BuiltinPreset>& builtin_presets() {
    static const std::vector<BuiltinPreset> presets = {
        {"parsers/common", "access_browser_fallback", R"NC(
# Common Nokogiri access fallback settings for CDN/WAF/JS challenge pages.
# Platform code (iOS WKWebView, desktop browser helper, etc.) supplies cookies
# and/or a browser fetch command; this preset only opts a site into that fallback.
access:
  browser_fallback: true
  fallback:
    on_challenge: browser_fetch_command
    reuse_browser_cookies: true
)NC"},
        {"parsers/common", "syosetu_2024", R"NC(
# 汎用: 小説家になろう系（2024年以降の p-eplist / p-novel 構造）
encoding: UTF-8
access:
  profile: safari_mobile

toc_sources:
  - source: selector
    selector: "div.p-eplist__sublist, .p-eplist__sublist"
    priority: 10
    extract: "list"
    description: "小説家になろう系エピソードリスト（2024年現在）"
    item_selectors:
      chapter: "div.p-eplist__chapter-title"
      subtitle: "a.p-eplist__subtitle"
      href: "a.p-eplist__subtitle::attr(href)"
      subupdate: "div.p-eplist__update"

  - source: page
    mode: all_links
    selector: ".c-pager a[href*='?p='], .c-pager a[href*='?page='], a.c-pager__item[href*='?p='], a.c-pager__item[href*='?page=']"
    href: ":self::attr(href)"
    href_pattern: "^(?:/n[a-z0-9]+/?)?\\?(?:p=[2-9]\\d*|.*page=[2-9]\\d*)|^/n[a-z0-9]+/?\\?(?:p=[2-9]\\d*|.*page=[2-9]\\d*)"
    description: "なろう系: ページャ上の全目次ページリンクをYAML定義で列挙"
  - source: page
    mode: next_link
    selector: ".c-pager__item--next a, a.c-pager__item--next"
    href: ":self::attr(href)"
    description: "フォールバック: 次ページリンクを順次辿る"
  - source: page
    mode: next_link
    selector: "a[href*='?p='], a[href*='?page=']"
    href: ":self::attr(href)"
    href_pattern: "^(?:/n[a-z0-9]+/?)?\\?(?:p=[2-9]\\d*|.*page=[2-9]\\d*)|^/n[a-z0-9]+/?\\?(?:p=[2-9]\\d*|.*page=[2-9]\\d*)"
    text_pattern: "(?i)^(次へ|next|>|＞)$"
    description: "フォールバック: ラベル付きクエリリンク"

body_selectors:
  - selector: ".p-novel__body"
    priority: 10
    extract: "inner_html"
    description: "小説家になろう系本文（現行デザイン）"
  - selector: "div.js-novel-text.p-novel__text, .js-novel-text.p-novel__text"
    priority: 9
    extract: "inner_html"
  - selector: "div.p-novel__text, .p-novel__text"
    priority: 8
    extract: "inner_html"
  - selector: "div#novel_honbun"
    priority: 5
    extract: "inner_html"

introduction_selectors:
  - selector: "div.js-novel-text.p-novel__text--preface, .p-novel__text--preface"
    priority: 10
    extract: "inner_html"

postscript_selectors:
  - selector: "div.js-novel-text.p-novel__text--afterword, .p-novel__text--afterword"
    priority: 10
    extract: "inner_html"
# ------------------------------------------------------------
# 横断検索メタ情報（小説家になろう系で共通）
append_title_to_folder_name: yes
title_strip_pattern: null
webnovels_site: narou
version: 2.2
)NC"},
        {"parsers", "kakuyomu.jp", R"NC(
name: カクヨム
domain: kakuyomu.jp
encoding: UTF-8
top_url: https://kakuyomu.jp
sitename: カクヨム

access:
  profile: safari_desktop

toc_url_pattern: "https://kakuyomu.jp/works/{ncode}"
toc_sources:
  - source: regex
    priority: 10
    pattern: '"__typename":"Episode","id":"([^"]+)","title":"([^"]+)"'
    id_group: 1
    title_group: 2
    href_template: "episodes/{id}"

  - source: selector
    selector: "a[href*='/episodes/']"
    priority: 5
    extract: "list"
    description: "フォールバック: エピソードURLアンカー直抽出"
    href_pattern: "^/works/\\d+/episodes/\\d+$"
    item_selectors:
      subtitle: ":self"
      href: ":self::attr(href)"

body_selectors:
  - selector: "div.widget-episodeBody.js-episode-body"
    priority: 10
    extract: "inner_html"

novel_info_selectors:
  title: "h1 a[href^='/works/']"
  author: ".partialGiftWidgetActivityName a, a[href^='/users/']"
# ------------------------------------------------------------
# 横断検索メタ情報
confirm_over18: no
append_title_to_folder_name: yes
title_strip_pattern: null
webnovels_site: kakuyomu
version: 2.2
)NC"},
        {"parsers", "mid.syosetu.com", R"NC(
extends: common/syosetu_2024
name: 小説家になろう（18禁）
domain: mid.syosetu.com
encoding: UTF-8
top_url: https://mid.syosetu.com
sitename: 小説家になろう（18禁）
access:
  profile: safari_mobile
  cookies:
    - over18=yes

# toc_sources は common/syosetu_2024 から継承し、サイト別YAMLで上書き可能。
toc_url_pattern: "https://mid.syosetu.com/{ncode}/"
novel_info_url_pattern: "https://mid.syosetu.com/novelview/infotop/ncode/{ncode}/"
novel_info_selectors:
  title: "h1.p-infotop-title a, title"
  author: "dd.p-infotop-data__value a, .p-novel__author a, .novel_writername a, .novel_writername"
  story: "dd.p-infotop-data__value"

last_successful_selectors: {}
# ------------------------------------------------------------
# 横断検索メタ情報
confirm_over18: yes
)NC"},
        {"parsers", "mnlt.syosetu.com", R"NC(
extends: common/syosetu_2024
name: 小説家になろう（18禁）
domain: mnlt.syosetu.com
encoding: UTF-8
top_url: https://mnlt.syosetu.com
sitename: 小説家になろう（18禁）
access:
  profile: safari_mobile
  cookies:
    - over18=yes

# toc_sources は common/syosetu_2024 から継承し、サイト別YAMLで上書き可能。
toc_url_pattern: "https://mnlt.syosetu.com/{ncode}/"
novel_info_url_pattern: "https://mnlt.syosetu.com/novelview/infotop/ncode/{ncode}/"
novel_info_selectors:
  title: "h1.p-infotop-title a, title"
  author: "dd.p-infotop-data__value a, .p-novel__author a, .novel_writername a, .novel_writername"
  story: "dd.p-infotop-data__value"

last_successful_selectors: {}
# ------------------------------------------------------------
# 横断検索メタ情報
confirm_over18: yes
)NC"},
        {"parsers", "ncode.syosetu.com", R"NC(
extends: common/syosetu_2024
name: 小説家になろう
domain: ncode.syosetu.com
encoding: UTF-8
top_url: https://ncode.syosetu.com
sitename: 小説家になろう
access:
  profile: safari_mobile

# toc_sources は common/syosetu_2024 から継承し、サイト別YAMLで上書き可能。
toc_url_pattern: "https://ncode.syosetu.com/{ncode}/"
novel_info_url_pattern: "https://ncode.syosetu.com/novelview/infotop/ncode/{ncode}/"
novel_info_selectors:
  title: "title"
  author: ".p-novel__author a, .novel_writername a, .novel_writername"
# ------------------------------------------------------------
# 横断検索メタ情報
confirm_over18: no
)NC"},
        {"parsers", "noc.syosetu.com", R"NC(
extends: common/syosetu_2024
name: 小説家になろう（18禁）
domain: noc.syosetu.com
encoding: UTF-8
top_url: https://noc.syosetu.com
sitename: 小説家になろう（18禁）
access:
  profile: safari_mobile
  cookies:
    - over18=yes

# toc_sources は common/syosetu_2024 から継承し、サイト別YAMLで上書き可能。
toc_url_pattern: "https://noc.syosetu.com/{ncode}/"
novel_info_url_pattern: "https://noc.syosetu.com/novelview/infotop/ncode/{ncode}/"
novel_info_selectors:
  title: "h1.p-infotop-title a, title"
  author: "dd.p-infotop-data__value a, .p-novel__author a, .novel_writername a, .novel_writername"
  story: "dd.p-infotop-data__value"

last_successful_selectors: {}
# ------------------------------------------------------------
# 横断検索メタ情報
confirm_over18: yes
)NC"},
        {"parsers", "novel18.syosetu.com", R"NC(
extends: common/syosetu_2024
name: 小説家になろう（18禁）
domain: novel18.syosetu.com
encoding: UTF-8
top_url: https://novel18.syosetu.com
sitename: 小説家になろう（18禁）
access:
  profile: safari_mobile
  cookies:
    - over18=yes

# toc_sources は common/syosetu_2024 から継承し、サイト別YAMLで上書き可能。
toc_url_pattern: "https://novel18.syosetu.com/{ncode}/"
novel_info_url_pattern: "https://novel18.syosetu.com/novelview/infotop/ncode/{ncode}/"
novel_info_selectors:
  title: "h1.p-infotop-title a, title"
  author: "dd.p-infotop-data__value a, .p-novel__author a, .novel_writername a, .novel_writername"
  story: "dd.p-infotop-data__value"

last_successful_selectors: {}
# ------------------------------------------------------------
# 横断検索メタ情報
confirm_over18: yes
)NC"},
        {"parsers", "novelup.plus", R"NC(
name: NovelUp+
domain: novelup.plus
encoding: UTF-8
top_url: https://novelup.plus
sitename: NovelUp+

access_extends: common/access_browser_fallback

access:
  # Keep Nokogiri access identical to the domain NovelUp+ route.
  profile: chrome_desktop
  referer: "https://novelup.plus/"
  headers:
    sec-fetch-site: same-origin

# 専用 NovelUpPlusParser と同等に story 一覧・Next.js JSON埋め込み・ページングを扱う。
toc_url_pattern: "https://novelup.plus/story/{id}"
toc_sources:
  - source: selector
    selector: "div.episodeList div.episodeListItem"
    priority: 10
    extract: "list"
    chapter_row_class: "chapter"
    description: "episodeListItemを順走査しchapter行を見出しとして保持"
    item_selectors:
      subtitle: "a.episodeTitle[href]"
      href: "a.episodeTitle[href]::attr(href)"

  - source: selector
    selector: "a[href^='/story/'], a[href*='novelup.plus/story/']"
    priority: 5
    extract: "list"
    href_pattern: "^/story/\\d+/\\d+$"
    description: "フォールバック: storyアンカー直抽出"
    item_selectors:
      subtitle: ":self"
      href: ":self::attr(href)"

  - source: json
    selector: "script#__NEXT_DATA__"
    href_pattern: "^/story/\\d+/\\d+$"
    path_key: "path"
    url_key: "url"
    title_key: "title"
    name_key: "name"
    path_only: true
    allowed_hosts:
      - novelup.plus
      - www.novelup.plus
  - source: json
    selector: "script[type='application/ld+json']"
    href_pattern: "^/story/\\d+/\\d+$"
    path_key: "path"
    url_key: "url"
    title_key: "title"
    name_key: "name"
    path_only: true
    allowed_hosts:
      - novelup.plus
      - www.novelup.plus

  - source: page
    mode: all_links
    selector: ".pager a[href*='?p='], .pager a[href*='?page='], .pagination a[href*='?p='], .pagination a[href*='?page='], a[href^='/story/'][href*='?p='], a[href^='/story/'][href*='?page=']"
    href: ":self::attr(href)"
    href_pattern: "^(?:/story/\\d+)?\\?(?:p=[2-9]\\d*|.*page=[2-9]\\d*)|^/story/\\d+\\?(?:p=[2-9]\\d*|.*page=[2-9]\\d*)"
    description: "NovelUp+: ページャ内の全目次ページリンクを列挙"
  - source: page
    mode: next_link
    selector: "link[rel='next'], a[rel='next'], .pager a.next, a.c-pager__item--next, .pagination .next a[href], li.next a[href], a.next[href], a[aria-label='Next'][href], a[aria-label='次へ'][href]"
    href: ":self::attr(href)"
    href_pattern: "^(?:/story/\\d+)?\\?(?:p=[2-9]\\d*|.*page=[2-9]\\d*)|^/story/\\d+\\?(?:p=[2-9]\\d*|.*page=[2-9]\\d*)"
    description: "フォールバック: 次ページリンクを順次辿る"
  - source: page
    mode: next_link
    selector: "a[href*='?p='], a[href*='?page=']"
    href: ":self::attr(href)"
    href_pattern: "^(?:/story/\\d+)?\\?(?:p=[2-9]\\d*|.*page=[2-9]\\d*)|^/story/\\d+\\?(?:p=[2-9]\\d*|.*page=[2-9]\\d*)"
    text_pattern: "(?i)^(次へ|next|>|＞)$"
    description: "フォールバック: ラベル付きクエリリンク"

body_selectors:
  - selector: "p#episode_content"
    priority: 10
    extract: "inner_html"
  - selector: "div#episode-content"
    priority: 9
    extract: "inner_html"
  - selector: "div.episode-content"
    priority: 8
    extract: "inner_html"
  - selector: "article"
    priority: 7
    extract: "inner_html"
  - selector: "main article"
    priority: 6
    extract: "inner_html"

introduction_selectors:
  - selector: "div.novel_foreword"
    priority: 10
    extract: "inner_html"

postscript_selectors:
  - selector: "div.novel_afterword"
    priority: 10
    extract: "inner_html"

novel_info_selectors:
  title: "meta[property='og:title']::attr(content)"
  author: "meta[name='author']::attr(content)"

novel_info_rules:
  source_selector: "meta[property='og:title']::attr(content)"
  title_split_delimiter: "（"
  author_from_source_regex: true
  author_regex: "^(.+?)（(.+?)）"
  author_capture_group: 2
# ------------------------------------------------------------
# 横断検索メタ情報
webnovels_site: novelup
append_title_to_folder_name: yes
)NC"},
        {"parsers", "syosetu.org", R"NC(
name: ハーメルン
domain: syosetu.org
encoding: UTF-8
top_url: https://syosetu.org
sitename: ハーメルン

# ドメイン単位のアクセス設定。novel ID は URL から都度解決するため、
# 特定作品に限定されない。
access:
  profile: chrome_desktop
  referer: toc_parent
  browser_fallback: true
  fallback:
    on_challenge: browser_fetch_command
  headers:
    sec-fetch-site: same-origin
    sec-fetch-mode: navigate
    sec-fetch-dest: document
    sec-fetch-user: "?1"
  cookies:
    - over18=off
    - _ga=1

# 専用 HamelnParser と同等に table tr を順走査して章見出し・改稿フラグを保持する。
toc_url_pattern: "https://syosetu.org/novel/{ncode}/"
toc_sources:
  - source: selector
    selector: "#maind table tr, table tr"
    priority: 10
    extract: "list"
    chapter_header_selector: "td[colspan] strong"
    index_from_href_regex: "(?:^|/)(\\d+)\\.html(?:$|[?#])"
    trim_html_tail: true
    hameln_dot_normalize: true
    subupdate_if_html_contains: "改稿"
    subupdate_value: "revised"
    description: "ハーメルン目次行"
    item_selectors:
      index: "span[id]::attr(id)"
      subtitle: "a[href]"
      href: "a[href]::attr(href)"

body_selectors:
  - selector: "div#honbun"
    priority: 10
    extract: "inner_html"
  - selector: "div#novel_honbun"
    priority: 8
    extract: "inner_html"
  - selector: "#main"
    priority: 6
    extract: "inner_html"
  - selector: ".honbun"
    priority: 5
    extract: "inner_html"

introduction_selectors:
  - selector: "div#maegaki, .maegaki"
    priority: 10
    extract: "inner_html"

postscript_selectors:
  - selector: "div#atogaki, .atogaki"
    priority: 10
    extract: "inner_html"

novel_info_selectors:
  title: "div#maind [itemprop='name'], [itemprop='name']"
  author: "div#maind [itemprop='author'], [itemprop='author'] a, [itemprop='author']"
  story: "div#maind div.ss:nth-of-type(2)"
# ------------------------------------------------------------
# 横断検索メタ情報
confirm_over18: no
append_title_to_folder_name: yes
title_strip_pattern: null
webnovels_site: hameln
version: 1.3
)NC"},
        {"parsers", "www.akatsuki-novels.com", R"NC(
name: 暁
domain: www.akatsuki-novels.com
encoding: UTF-8
top_url: https://www.akatsuki-novels.com
sitename: 暁

access:
  profile: chrome_desktop
  cookies:
    - CakeCookie[ALLOWED_ADULT_NOVEL]=on

# 現行の暁は目次を table.list 配下の行で返す。
toc_url_pattern: "https://www.akatsuki-novels.com/stories/index/novel_id~{ncode}"
toc_sources:
  - source: selector
    selector: "table.list tr"
    priority: 10
    index_from_href_regex: "/stories/view/(\\d+)/novel_id~\\d+"
    href_pattern: "^/stories/view/\\d+/novel_id~\\d+$"
    item_selectors:
      subtitle: "td:first-child a[href]"
      href: "td:first-child a[href]::attr(href)"
      chapter: "td[colspan] b"
      subupdate: "td.font-s"

body_selectors:
  - priority: 10
    pattern: |-
      </h2>(?:<div>&nbsp;</div><div><b>前書き</b></div><div class="body-novel">(?<introduction>.+?)&nbsp;</div><hr width="100%"><div>&nbsp;</div>)?<div class="body-novel">(?<body>.+?)&nbsp;</div>(?:<div>&nbsp;</div><hr width="100%"><div>&nbsp;</div><div><b>後書き</b></div><div class="body-novel">(?<postscript>.+?)&nbsp;</div>)?
    capture_name: body

introduction_selectors:
  - priority: 10
    pattern: |-
      </h2><div>&nbsp;</div><div><b>前書き</b></div><div class="body-novel">(?<introduction>.+?)&nbsp;</div><hr width="100%"><div>&nbsp;</div><div class="body-novel">(?<body>.+?)&nbsp;</div>
    capture_name: introduction

postscript_selectors:
  - priority: 10
    pattern: |-
      </h2>(?:<div>&nbsp;</div><div><b>前書き</b></div><div class="body-novel">(?<introduction>.+?)&nbsp;</div><hr width="100%"><div>&nbsp;</div>)?<div class="body-novel">(?<body>.+?)&nbsp;</div><div>&nbsp;</div><hr width="100%"><div>&nbsp;</div><div><b>後書き</b></div><div class="body-novel">(?<postscript>.+?)&nbsp;</div>
    capture_name: postscript

novel_info_selectors:
  title: "#LookNovel"
  author: "a[href^='/users/view/']"
  story: "div.body-x1 div"

# 横断検索メタ情報
confirm_over18: no
append_title_to_folder_name: yes
title_strip_pattern: null
webnovels_site: akatsuki
version: 2.0
)NC"},
        {"parsers", "www.mai-net.net", R"NC(
name: Arcadia
domain: www.mai-net.net
encoding: UTF-8
top_url: http://www.mai-net.net
sitename: Arcadia

access:
  profile: chrome_desktop

# Arcadia は現行でも古いHTMLだが、定義は現行 parser schema の toc_sources/body_selectors に統一する。
toc_url_pattern: "http://www.mai-net.net/bbs/sst/sst.php?act=dump&cate={category}&all={ncode}&n=0&count=1"
toc_sources:
  - source: regex
    priority: 10
    pattern: |-
      <td width="0%" style="font-size:60%">\[(?<index>\d+?)\]</td><td width="0%" style="font-size:60%"><b>\s*<a href="(?<href>.+?)#kiji">(?<subtitle>.+?)</a></b></td><td width="0%" style="font-size:60%">\[(.+?)\]</td><td width="0%" style="font-size:60%">\((?<subupdate>.+?)\)</td>
    href_template: "{href}#kiji"
    id_name: href
    title_name: subtitle
    index_name: index
    subupdate_name: subupdate

body_selectors:
  - priority: 10
    pattern: '<blockquote><div style="line-height:1.5">(?<body>.+?)</div></blockquote>'
    capture_name: body

novel_info_selectors:
  title: "font[size='4'][color='4444aa']"
  author: "tt"

novel_info_rules:
  source_selector: "tt"
  author_from_source_regex: true
  author_regex: "Name: (?:(.+?)◆.+|(.+?) )"
  author_capture_group: 1

# 横断検索メタ情報
confirm_over18: no
append_title_to_folder_name: yes
title_strip_pattern: "(【.+?】|\\(.+?\\)|（.+?）)"
webnovels_site: arcadia
version: 2.0
)NC"},
    };
    return presets;
}

} // namespace nc
