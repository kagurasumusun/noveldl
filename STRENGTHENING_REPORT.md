# NovelDL 強化 — 第2ラウンド報告（6項目への回答）

## 1. 「一部のUIがスマホにはあってない？」→ **是正しました**

実際に問題だった箇所を修正：

| 問題 | 修正 |
|------|------|
| タイポグラフィ設定シートが `.height(340)` 固定で、書体・余白コントロール追加後にiPhoneで**下が切れる** | `.height(430), .medium` に変更 |
| 画面タップが「どこをタップしても次ページ」で誤送りが起きやすい（スマホ操作として不自然） | **Kindle流のタップゾーン**を実装（左1/3=戻る・中央=表示切替・右1/3=進む） |
| 下部ステータスバー（ページ数＋リボン＋章名）が小さい端末（SE幅）で横に詰まる | リボンを伸縮可能（48–130pt）に、ラベルに`lineLimit`、左右余白追加 |
| 送りボタンのタップターゲットが小さい | 32pt ターゲットに拡大 |
| `LibraryView` に型チェッカ用の残骸コードが1行残っていた | 削除 |
| モックアップが1枚に画面3枚並びで「スマホのUI」に見えない＋ガラス質な面 | **単一iPhone・マット（リキッドグラスなし）**で再生成 → `Novelios/design_mockup_library.png` / `design_mockup_reader.png` |

グリッドは `LazyVGrid(adaptive: 108pt)` で端末幅に追従済み。描画は CoreText 直描き（WKWebView なし）。

## 2. 「なろう以外の年ろう以外の年齢制限にも対応」→ **汎用機構を実装・設定済み**

- **汎用エンジン機能（C/C++）**:
  1. `over18_cookie: "name=value"` — 年齢クッキーの名前・値を**YAMLでサイトごとに指定**（省略時 `over18=yes`）。`confirm_over18: yes` で注入。
  2. **年齢ゲート自動通過** — 「あなたは18歳以上ですか？/年齢確認/閲覧確認」ページを検出すると、ページ内の**「はい」リンクを自動クリック**（`age_gate_link_regex` で抽出、既定は日本語「はい|Yes|Enter|18」）→応答の Set-Cookie を保持して**元ページを再取得**。ユニットテストで通過フローを証明（114→**118 passed**）。
- **サイト設定（YAMLのみ）**:
  | サイト | 状態 |
  |--------|------|
  | ハーメルン R-18（**`h.syosetu.org` サブドメイン**を調査で発見・新規プリセット追加） | 「R18閲覧確認ページ」→ `?cookie_set=r18`「はい」リンクを自動クリック。実DLはサンドボックスIPがCloudFront/CFに遮断されるため端末実機で有効（`hameln-r18` 行で dltest に登録済み） |
  | ハーメルン本体（syosetu.org） | `over18_cookie: "over18=on"` 注入 |
  | アルファポリス | `confirm_over18` + ゲート自動通過（WAF遮断のため実機検証用） |
  | ノベルアップ＋ / エブリスタ / monogatary(overFifteen) / ソリスピア | 同上（クッキー値は `over18_cookie` で差替え可＝**コード変更不要**） |
  | なろうR-18/noc/mnlt/mid | 従来通り実DL PASS |

## 3. 「YAMLの基盤は共通化されているか？」→ **されています**

- `extends:` 継承（再帰解決）: `novema`/`berrys` → `www.no-ichigo.jp`、`h.syosetu.org` → `syosetu.org`
- `common/` 共通フラグメント: `syosetu_2024`（なろう系5サイト＝novel18/noc/mnlt/mid/ncode の目次ソースを共通化——各ファイルは23行）、`access_browser_fallback`
- 共通の抽出エンジン（`toc_sources`/`body_selectors`/`normalize_legacy`）が全サイトで同一処理を共有し、**サイト差分はYAMLの宣言だけ**
- 22ファイル計 **897行**で21サイト＋R-18サブドメインを表現（1サイト平均 約40行）

## 4. 「共通化や統合でコード削減はできているか？」→ **できています**

| | 旧 | 新 | 削減 |
|---|---|---|---|
| コア | Rust 11,582行 | C++ **8,486行** | **−27%** |
| iOS UI | 旧Swift 7,616行 | SwiftUI **約2,200行** | **−71%** |
| 合計 | 19,198行 | **約10,700行** | **−44%** |
| サイト定義 | Python 502KB（サイト別実装） | YAML 897行＋共通エンジン | 構造的に統合 |

統合の主例: 目次/本文/メタの3ソース系を単一のルールエンジンに統合（`toc_sources` 3種 + `body_selectors`）、JSON/regex/selector の章収集を共通化、`chapter_row_class`/`chapter_header_selector` の2つのセマンティクスを1機構に統合、zstd 辞書学習の廃止（デコードのみ）など。

## 5. 「無理にリキッドグラスにしないで」→ **していません**

- UIコードに `ultraThinMaterial` 等のブラーガラス材は**一切なし**（`grep` で0件）。紙・インク・余燼色（#BD5835）の**マットな平面デザイン**を維持。
- 新モックアップも「マット・ガラス/ブラー/グロス禁止」で生成（添付2点）。
- 今後の変更でもこの方針を維持する旨を Theme.swift のデザイン言語コメントに明記。

## 6. 「nyxian用のプロジェクトにして」→ **`Nyxian/` に作成しました**

**Nyxian 調査結果**（emexLabs 製・https://github.com/emexlab/Nyxian）:

| 項目 | 仕様 |
|------|------|
| 正体 | iPhone/iPad 単体でネイティブiOSアプリをビルド・実行する**オンデバイスIDE**（非ジェイルブレイク、証明書署名＋ユーザー空間マイクロカーネル ksurface でネイティブコード実行） |
| 対応 | iOS 18.0〜27.x / **C・ObjC・C++・ObjC++・Swift**（LLVM/clang・Swift 6.4 同梱） |
| SDK | iOS 26.x SDK 同梱（`NYXIAN_SDK_ROOT`/iPhoneOS.sdk） |
| ビルド | **標準 Makefile**（clang→ld→codesign、依存追跡） |
| 配備 | `nyxian-install Payload/<App>.app` |
| 特徴 | SDK取得後は完全オフラインで開発可能、NSExtension 経由でサンドボックス実行 |

**成果物 `Nyxian/`**:
- `Makefile` — Nyxian規約準拠（`NYXIAN_SDK_ROOT` / `NYXIAN_DEVELOPER_IDENTITY` / `nyxian-install`）。novel_core（C++、`NC_HAVE_ZSTD`なし＝sqlite3システムライブラリのみ）→ SwiftUIアプリ（swiftc）→ 署名 → Payload 化まで自動。
- `Info.plist` — 静的バンドル plist（Xcode の自動生成なし環境向け）。
- `README.md` — Nyxian仕様まとめとビルド手順。
- HTTP は同梱の NSURLSession 転送（`nc_http_apple.m`）を使用＝curl 不要。サイト対応 YAML は `.app/presets` にバンドル。

## 検証

- ユニットテスト: **118 passed, 0 failed**（年齢ゲート自動通過テスト4件追加）
- 実DLテスト: なろう / なろうR-18 / 野いちご / monogatary ほかで **PASS 確認済み**（前回 12/17、hameln-r18 行を追加して18行に）
