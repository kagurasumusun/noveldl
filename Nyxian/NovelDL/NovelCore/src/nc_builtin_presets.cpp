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
    href_pattern: "[?&](?:p|page)=[0-9]+"
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
    href_pattern: "[?&](?:p|page)=[0-9]+"
    text_pattern: "(?i)^(次へ|next|>|＞)$"
    description: "フォールバック: ラベル付きクエリリンク"

body_selectors:
  # 本文のみ。--preface / --afterword の修飾を持つ前書き・後書きを除外する
  # ( wrapper を取ると前書き/後書きが本文に混在し、二重保存になっていた)。
  - selector: "div.js-novel-text.p-novel__text:not(.p-novel__text--preface):not(.p-novel__text--afterword), .p-novel__text:not(.p-novel__text--preface):not(.p-novel__text--afterword)"
    priority: 12
    extract: "inner_html"
    description: "本文のみ(前書き/後書きを含まない)"
  - selector: ".p-novel__body"
    priority: 10
    extract: "inner_html"
    description: "フォールバック: 本文ラッパー(前書き/後書きが混入することがある)"
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
builtin_rev: 2
version: 2.3
)NC"},
        {"parsers", "estar.jp", R"NC(
name: エブリスタ
domain: estar.jp
encoding: UTF-8
top_url: https://estar.jp
sitename: エブリスタ

# Nuxt 3 + GraphQL。本文・話一覧は API 遅延取得のため通常の HTTP 取得では
# 403/チャレンジが返ることが多い。browser_fallback + browser_fetch_command
# （Playwright 等の HTML 出力コマンド）を併用する。
access:
  profile: chrome_desktop
  referer: toc_parent
  browser_fallback: true
  fallback:
    on_challenge: browser_fetch_command

toc_url_pattern: "https://estar.jp/novels/{ncode}"
toc_sources:
  - source: page
    mode: next_link
    selector: "a[href*='/viewer?page=']"
    priority: 10
    url_template: "/novels/{id}/viewer?page={page}"
    start_page: 1
    item_selectors:
      subtitle: ":self"
      href: ":self::attr(href)"
    description: "エブリスタ viewer ページ列"

body_selectors:
  - selector: "#novel-page-body, .novel-page-body"
    priority: 10
    extract: "inner_html"
  - selector: ".markdown-body"
    priority: 8
    extract: "inner_html"

novel_info_selectors:
  title: "h1"
  author: "meta[property='og:title']::attr(content)"
  story: "meta[name='description']::attr(content)"

append_title_to_folder_name: yes
# R-18(大人向け)作品対応
confirm_over18: yes
over18_cookie: "over_fifteen=yes"
# 年齢ゲート「はい」リンク抽出（既定の日本語パターンで可。必要なら上書き）
age_gate_link_regex: "href=\"([^\"]+)\"[^>]*>[^<]*(?:はい|Yes|Enter|18)"
version: 1.0
)NC"},
        {"parsers", "h.syosetu.org", R"NC(
# ハーメルン R-18（h.syosetu.org サブドメイン）
# 一般側(syosetu.org)と同じ目次構造を継承し、年齢ゲート自動通過だけを有効化。
extends: syosetu.org
name: ハーメルン(R-18)
domain: h.syosetu.org
top_url: https://h.syosetu.org
sitename: ハーメルン(R-18)

toc_url_pattern: "https://h.syosetu.org/novel/{ncode}/"

# 「R18閲覧確認ページ」の「はい」リンク(?cookie_set=r18)を自動クリック
confirm_over18: yes
age_gate_link_regex: "href=\"([^\"]*cookie_set[^\"]*)\""
)NC"},
        {"parsers", "kakuyomu.jp", R"NC(
builtin_rev: 3
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
  # 2025年以降の新レイアウト(CSSモジュール名)に対応
  story: "div[class*='CollapseTextWithKakuyomuLinks_collapseText']"
  status: "ul[class*='Meta_disc'] div:contains(連載中), ul[class*='Meta_disc'] div:contains(完結済)"

# 目次の予備経路: ページ埋め込み JSON(__NEXT_DATA__)から話リストを組み立てる。
# HTML セレクタが効かない将来のレイアウト変更でも取得を続けられる。
# (toc_api エンジン: href で重複除去されるので HTML 目次と併用可)
toc_api:
  from: script
  script_marker: "__NEXT_DATA__"
  data_path: "props.pageProps.__APOLLO_STATE__"
  key_prefix: "Episode:"
  fields:
    subtitle: "title"
    id: "id"
  href_template: "episodes/{id}"
  sort_by: "publishedAt"
# ------------------------------------------------------------
# 横断検索メタ情報
confirm_over18: no
append_title_to_folder_name: yes
title_strip_pattern: null
webnovels_site: kakuyomu
version: 2.2
)NC"},
        {"parsers", "mid.syosetu.com", R"NC(
builtin_rev: 3
metadata_api:
  url: "https://api.syosetu.com/novelapi/api/?out=json&ncode={ncode}"
  fields:
    title: "title"
    author: "writer"
    story: "story"
    updated: "general_lastup"
  status_field: "isstop"
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
  author: "dd.p-infotop-data__value a, .p-novel__author a, .novel_writername a, .novel_writername, .p-novel__author"
  story: "dd.p-infotop-data__value"

last_successful_selectors: {}
# ------------------------------------------------------------
# 横断検索メタ情報
confirm_over18: yes
)NC"},
        {"parsers", "mnlt.syosetu.com", R"NC(
builtin_rev: 3
metadata_api:
  url: "https://api.syosetu.com/novelapi/api/?out=json&ncode={ncode}"
  fields:
    title: "title"
    author: "writer"
    story: "story"
    updated: "general_lastup"
  status_field: "isstop"
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
  author: "dd.p-infotop-data__value a, .p-novel__author a, .novel_writername a, .novel_writername, .p-novel__author"
  story: "dd.p-infotop-data__value"

last_successful_selectors: {}
# ------------------------------------------------------------
# 横断検索メタ情報
confirm_over18: yes
)NC"},
        {"parsers", "monogatary.com", R"NC(
name: monogatary.com
domain: monogatary.com
encoding: UTF-8
top_url: https://monogatary.com
sitename: monogatary.com
access:
  profile: chrome_desktop

# サイトは JS シェルのみ。取得 URL を REST API に変換して JSON を解析する。
metadata:
  fetch_url_template: "https://monogatary.com/api/story/{id}"

toc_url_pattern: "https://monogatary.com/story/{ncode}"
toc_sources:
  - source: json
    priority: 10
    href_pattern: "api/episode/"
    list_path: "episodes"
    title_path: "episodeTitle"
    index_path: "episodeId"
    href_path: "episodeId"
    href_template: "https://monogatary.com/api/episode/{href}"
    description: "monogatary JSON API 一覧"

body_selectors:
  - json_path: "body"
    priority: 10
  - json_path: "episodeContents.episode"
    priority: 9
  - json_path: "episode_text"
    priority: 8

novel_info_selectors:
  title: "$.storyTitle"
  author: "$.user.nickname"
  story: "$.description"

append_title_to_folder_name: yes
# overFifteen 年齢制限作品対応
confirm_over18: yes
over18_cookie: "over_fifteen=yes"
version: 1.0
)NC"},
        {"parsers", "ncode.syosetu.com", R"NC(
builtin_rev: 3
metadata_api:
  url: "https://api.syosetu.com/novelapi/api/?out=json&ncode={ncode}"
  fields:
    title: "title"
    author: "writer"
    story: "story"
    updated: "general_lastup"
  status_field: "isstop"
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
  # 作者はリンク無し作品もある(「作者：名前」直テキスト)ため容器を最後に置く。
  author: ".p-novel__author a, .novel_writername a, .novel_writername, .p-novel__author"
  story: "#novel_ex, .p-novel__summary"
  updated: ".p-novel__date-published"
  next_update: ".p-novel__update, .novel_update"
# ------------------------------------------------------------
# 横断検索メタ情報
confirm_over18: no
)NC"},
        {"parsers", "noc.syosetu.com", R"NC(
builtin_rev: 3
metadata_api:
  url: "https://api.syosetu.com/novelapi/api/?out=json&ncode={ncode}"
  fields:
    title: "title"
    author: "writer"
    story: "story"
    updated: "general_lastup"
  status_field: "isstop"
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
  author: "dd.p-infotop-data__value a, .p-novel__author a, .novel_writername a, .novel_writername, .p-novel__author"
  story: "dd.p-infotop-data__value"

last_successful_selectors: {}
# ------------------------------------------------------------
# 横断検索メタ情報
confirm_over18: yes
)NC"},
        {"parsers", "novel.daysneo.com", R"NC(
name: NOVEL DAYS
domain: novel.daysneo.com
encoding: UTF-8
top_url: https://novel.daysneo.com
sitename: NOVEL DAYS
access:
  profile: chrome_desktop
  referer: toc_parent

toc_url_pattern: "https://novel.daysneo.com/works/{ncode}.html"
toc_sources:
  - source: selector
    selector: "div.contents a[href], div.contents h4"
    priority: 10
    chapter_header_selector: "h4"
    href_pattern: "/works/episode/[0-9a-f]{32}\\.html$"
    item_selectors:
      subtitle: ":self"
      href: ":self::attr(href)"
      subupdate: "span.date"
    description: "NOVEL DAYS 目次（h4 章見出し対応）"

body_selectors:
  - selector: "div.episode div.inner"
    priority: 10
    extract: "inner_html"

novel_info_selectors:
  title: "div.detail h2, h2"
  author: "div.author a span.f18px, div.author a"
  story: "p.readmore"

append_title_to_folder_name: yes
confirm_over18: no
version: 1.0
)NC"},
        {"parsers", "novel18.syosetu.com", R"NC(
builtin_rev: 3
metadata_api:
  url: "https://api.syosetu.com/novelapi/api/?out=json&ncode={ncode}"
  fields:
    title: "title"
    author: "writer"
    story: "story"
    updated: "general_lastup"
  status_field: "isstop"
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
  author: "dd.p-infotop-data__value a, .p-novel__author a, .novel_writername a, .novel_writername, .p-novel__author"
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
# R-18作品対応（年齢確認クッキー。必要なら over18_cookie で差替）
confirm_over18: yes
over18_cookie: "r18=1"
# 年齢ゲート「はい」リンク抽出（既定の日本語パターンで可。必要なら上書き）
age_gate_link_regex: "href=\"([^\"]+)\"[^>]*>[^<]*(?:はい|Yes|Enter|18)"
)NC"},
        {"parsers", "novema.jp", R"NC(
extends: www.no-ichigo.jp
name: ノベマ！
domain: novema.jp
encoding: UTF-8
top_url: https://novema.jp
sitename: ノベマ！
toc_url_pattern: "https://novema.jp/book/{ncode}"
confirm_over18: no
version: 1.0
)NC"},
        {"parsers", "solispia.com", R"NC(
name: ソリスピア
domain: solispia.com
encoding: UTF-8
top_url: https://solispia.com
sitename: 小説投稿サイトSolispia
access:
  profile: safari_mobile

# 章: details.chapter-group > summary（chapter_header_selector で章見出しを更新）
# 話: a.row-link（data-subtitle 属性と .textleft テキスト）
toc_url_pattern: "https://solispia.com/title/{ncode}"
toc_sources:
  - source: selector
    selector: "details.chapter-group summary, details.chapter-group a.row-link, a.row-link"
    priority: 10
    chapter_header_selector: "summary.chapter-summary, .chapter-summary"
    href_pattern: "/novel/\\d+$"
    index_from_href_regex: "/novel/(\\d+)$"
    index_capture_group: 1
    item_selectors:
      subtitle: ".textleft"
      href: ":self::attr(href)"
      subupdate: ".date"
    description: "ソリスピア目次（章グループ＋話リンク）"

body_selectors:
  - selector: "#novelBody, .novel-body"
    priority: 10
    extract: "inner_html"
  - selector: ".episode-body, .episode-content"
    priority: 8
    extract: "inner_html"
  - selector: "article"
    priority: 4
    extract: "inner_html"

novel_info_selectors:
  title: "h1"
  author: ".author a, [itemprop='author']"
  story: "meta[name='description']::attr(content)"

append_title_to_folder_name: yes
# R-18切替対応（レーティングクッキー）
confirm_over18: yes
over18_cookie: "over18=yes"
version: 1.0
)NC"},
        {"parsers", "sutekibungei.com", R"NC(
name: ステキブンゲイ
domain: sutekibungei.com
encoding: UTF-8
top_url: https://sutekibungei.com
sitename: ステキブンゲイ
access:
  profile: chrome_desktop

# Nuxt SSR。話一覧は a.v-list-item--link[href^=/novels/uuid/uuid]、
# 本文は div#episodeBody（SSR 出力）。
toc_url_pattern: "https://sutekibungei.com/novels/{ncode}"
toc_sources:
  - source: selector
    selector: "a.v-list-item--link"
    priority: 10
    href_pattern: "/novels/[0-9a-f-]{36}/[0-9a-f-]{36}$"
    item_selectors:
      subtitle: ".text-left"
      href: ":self::attr(href)"
      subupdate: ".v-list-item__subtitle"
    description: "ステキブンゲイ話一覧"

body_selectors:
  - selector: "#episodeBody"
    priority: 10
    extract: "inner_html"

novel_info_selectors:
  title: ".font-weight-bold.subtitle-1, h1"
  author: ".subtitle-2.wrap a, .subtitle-2.wrap"
  story: "meta[name='description']::attr(content)"

append_title_to_folder_name: yes
title_strip_pattern: " - ステキブンゲイ| -ステキブンゲイ"
confirm_over18: no
version: 1.0
)NC"},
        {"parsers", "syosetu.org", R"NC(
builtin_rev: 2
name: ハーメルン
domain: syosetu.org
encoding: UTF-8
top_url: https://syosetu.org
sitename: ハーメルン

# ドメイン単位のアクセス設定。novel ID は URL から都度解決するため、
# 特定作品に限定されない。
access:
  profile: safari_mobile
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
    - _ga=1

# 専用 HamelnParser と同等に table tr を順走査して章見出し・改稿フラグを保持する。
toc_url_pattern: "https://syosetu.org/novel/{ncode}/"
toc_sources:
  # 現行レイアウト（2024〜）: section.episode-list の li / 章見出し strong
  - source: selector
    selector: "section.episode-list li, section.episode-list strong, .episode-list__item"
    priority: 20
    chapter_row_class: episode-list__chapter
    chapter_header_selector: "strong, .episode-list__chapter-title"
    index_from_href_regex: "(?:^|/)(\\d+)\\.html(?:$|[?#])"
    trim_html_tail: true
    hameln_dot_normalize: true
    subupdate_if_html_contains: "改："
    subupdate_value: "revised"
    description: "ハーメルン目次行（現行 episode-list）"
    item_selectors:
      subtitle: "span[id], a[href]"
      href: "a[href]::attr(href)"
      subupdate: ".date"
  # 旧レイアウト: table tr を順走査して章見出し・改稿フラグを保持する。
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
  title: "#pagetitle [itemprop='name'], div#maind [itemprop='name'], [itemprop='name']"
  author: "[itemprop='author'] a, div#maind [itemprop='author'], [itemprop='author']"
  story: "div#maind div.ss:nth-of-type(2)"
# ------------------------------------------------------------
# 横断検索メタ情報
# R-18作品: confirm_over18 で年齢クッキーを注入（一般作品には無害）
confirm_over18: yes
over18_cookie: "over18=on"
append_title_to_folder_name: yes
title_strip_pattern: null
webnovels_site: hameln
version: 1.3
)NC"},
        {"parsers", "www.akatsuki-novels.com", R"NC(
builtin_rev: 2
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
  story: "div.body-x1 div.txt-c ~ div"

# 横断検索メタ情報
confirm_over18: no
append_title_to_folder_name: yes
title_strip_pattern: null
webnovels_site: akatsuki
version: 2.0
)NC"},
        {"parsers", "www.alphapolis.co.jp", R"NC(
name: アルファポリス
domain: www.alphapolis.co.jp
encoding: UTF-8
top_url: https://www.alphapolis.co.jp
sitename: アルファポリス

# AWS WAF (JavaScript チャレンジ) 保護下。ページ取得は通常の HTTP では
# チャレンジページが返るため、browser_fallback と browser_fetch_command を併用する。
access:
  profile: chrome_desktop
  referer: toc_parent
  browser_fallback: true
  fallback:
    on_challenge: browser_fetch_command

# 2026 レイアウト（p-content-info / /episode/ URL）→ 旧レイアウト順
toc_url_pattern: "https://www.alphapolis.co.jp/novel/{ncode}"
toc_sources:
  - source: selector
    selector: "a[href*='/episode/']"
    priority: 10
    item_selectors:
      subtitle: "span.title"
      href: ":self::attr(href)"
    description: "アルファポリス目次（2026）"
  - source: selector
    selector: ".table-of-contents .episode, .episodes .episode"
    priority: 5
    item_selectors:
      subtitle: ".title"
      href: "a::attr(href)"
    description: "旧レイアウト目次"

body_selectors:
  - selector: "#novelBody"
    priority: 10
    extract: "inner_html"
  - selector: "div.text"
    priority: 6
    extract: "inner_html"

introduction_selectors:
  - selector: "#novelBoby, .p-novel-episode__foreword"
    priority: 5
    extract: "inner_html"

novel_info_selectors:
  title: "h1.p-content-info__title, h1.title"
  author: "a.p-content-info__author, div.author a"
  story: "div.p-content-info__abstract, div.abstract"

append_title_to_folder_name: yes
# R-18(大人向け)作品対応。クッキー名はサイト側の年齢確認クッキーに合わせて
# over18_cookie: "name=value" で差し替え可能（C/C++変更不要）。
confirm_over18: yes
over18_cookie: "adult_check=1"
# 年齢ゲート「はい」リンク抽出（既定の日本語パターンで可。必要なら上書き）
age_gate_link_regex: "href=\"([^\"]+)\"[^>]*>[^<]*(?:はい|Yes|Enter|18)"
version: 1.0
)NC"},
        {"parsers", "www.aozora.gr.jp", R"NC(
name: 青空文庫
domain: www.aozora.gr.jp
encoding: UTF-8
top_url: https://www.aozora.gr.jp
sitename: 青空文庫
access:
  profile: chrome_desktop

# 作品カード → files/*.html（XHTML版）が唯一の「話」。
toc_url_pattern: "https://www.aozora.gr.jp/cards/{ncode}"
toc_sources:
  - source: selector
    selector: "a[href]"
    priority: 10
    href_pattern: "files/[0-9A-Za-z_]+\\.html$"
    item_selectors:
      subtitle: ":self"
      href: ":self::attr(href)"
    description: "XHTML版リンク"

body_selectors:
  - selector: "div.main_text"
    priority: 10
    extract: "inner_html"

novel_info_selectors:
  title: "span.title, .title"
  author: "span.author, .author"
  story: "meta[name='description']::attr(content)"

append_title_to_folder_name: yes
title_strip_pattern: "｜.*|- 青空文庫.*"
confirm_over18: no
version: 1.0
)NC"},
        {"parsers", "www.berrys-cafe.jp", R"NC(
extends: www.no-ichigo.jp
name: berry's cafe
domain: www.berrys-cafe.jp
encoding: UTF-8
top_url: https://www.berrys-cafe.jp
sitename: berry's cafe
toc_url_pattern: "https://www.berrys-cafe.jp/book/{ncode}"
confirm_over18: no
version: 1.0
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
        {"parsers", "www.neopage.com", R"NC(
name: ネオページ
domain: www.neopage.com
encoding: UTF-8
top_url: https://www.neopage.com
sitename: ネオページ
access:
  profile: chrome_desktop
  referer: toc_parent

# 章行: a[href*=/chapter/]/（m.neopage.com 絶対URLにも対応）
toc_url_pattern: "https://www.neopage.com/book/{ncode}"
toc_sources:
  - source: selector
    selector: "a[href*='/chapter/']"
    priority: 10
    href_pattern: "/chapter/\\d+/\\d+$"
    item_selectors:
      subtitle: ":self"
      href: ":self::attr(href)"
    description: "ネオページ章リスト"

metadata:
  chapter_fetch_url_template: "https://www.neopage.com/v1/book/content/{id}"

body_selectors:
  - json_path: "data.content"
    priority: 12
  - json_path: "content"
    priority: 11
  - selector: ".formate-manuscript"
    priority: 10
    extract: "inner_html"
  - selector: ".reading-content-wrap .content"
    priority: 8
    extract: "inner_html"

novel_info_selectors:
  title: ".header-title-wrap .title, h1 .title"
  author: ".author a, .author"
  story: "meta[name='description']::attr(content)"

append_title_to_folder_name: yes
confirm_over18: no
version: 1.0
)NC"},
        {"parsers", "www.no-ichigo.jp", R"NC(
name: 野いちご
domain: www.no-ichigo.jp
encoding: UTF-8
top_url: https://www.no-ichigo.jp
sitename: 野いちご
access:
  profile: safari_mobile
  referer: toc_parent

# スターズ出版系（野いちご・ノベマ！・berry's cafe は共通プラットフォーム）
# 目次: .bookChapterList に章 li → ページ ul の二段。全ページを平坦に取得する。
toc_url_pattern: "https://www.no-ichigo.jp/book/{ncode}"
toc_sources:
  - source: selector
    selector: ".bookChapterList a[href]"
    priority: 10
    href_pattern: "/book/[a-z0-9]+/\\d+$"
    index_from_href_regex: "(\\d+)$"
    index_capture_group: 1
    item_selectors:
      subtitle: ":self"
      href: ":self::attr(href)"
    description: "野いちご目次（章・ページ両対応）"

body_selectors:
  - selector: "article.bookText > div"
    priority: 10
    extract: "inner_html"
  - selector: "div.bookContent div.bookBody"
    priority: 10
    extract: "inner_html"
  - selector: "div.bookBody"
    priority: 9
    extract: "inner_html"

introduction_selectors:
  - selector: "div.chapterName"
    priority: 5
    extract: "text"

novel_info_selectors:
  title: ".title-wrap .title h2, .title-wrap .title"
  author: ".contributor a, .contributor"
  story: "meta[name='description']::attr(content)"

append_title_to_folder_name: yes
title_strip_pattern: "【書籍化原作】|【書籍化】"
confirm_over18: no
version: 1.0
)NC"},
    };
    return presets;
}

} // namespace nc
