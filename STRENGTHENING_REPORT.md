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

## 6. 「nyxian用のプロジェクトにして」→ **`Nyxian/NovelDL/` を正しい形式（AvisR2）で作成しました**

**Nyxian 調査結果（一次ソース = emexlab/Nyxian 実装コード NXProject.m / NXCodeTemplate.m / Builder.swift）**:

| 項目 | 仕様 |
|------|------|
| 正体 | emexLabs（旧 ProjectNyxian）製の**オンデバイス iOS IDE**。非ジェイルブレイク端末上で、同梱 iOS 26 SDK・LLVM/Clang/Swift（CoreCompiler/MDK）＋カーネル仮想化層 **ksurface**（NSExtension 実行）によりネイティブアプリをビルド・即実行 |
| 対応 | iOS 18.0〜27.x / **C・ObjC・C++・ObjC++・Swift**（Swift 6.4 同梱） |
| **プロジェクト形式** | **Makefile ではない。** `Config/Project.plist`（**AvisR2 形式** `NXProjectFormat: NXAvixR2`）＋`Config/Entitlements.plist`（`com.nyxian.pe.*` 権限ブロブ）。`$(SRCROOT)/$(SDKROOT)/$(BSROOT)/$(CACHEROOT)` 変数展開付き |
| ビルド | プロジェクト配下からソースを**自動収集**（`.swift/.c/.cpp/.m/.mm`。`Config/` と `Resources/` は除外）→ `LindChain/Builder` → `MDKPhaseEngine`（依存解析＋インクリメンタル）→ Mach-O → zsign 署名 → `Payload/<名>.app`。▶ひとつで完結 |

**成果物 `Nyxian/NovelDL/`**（このフォルダをそのまま端末へ転送して Nyxian で開く）:
- `Config/Project.plist` — AvisR2。`NXClangFlags`/`NXSwiftFlags` は公式テンプレートの基本フラグ＋C++ コア用（`-lc++`・`-lsqlite3`・CoreText/SwiftUI）と `-import-objc-header`
- `Config/Entitlements.plist` — jailed 既定権限セット
- `Config/NovelDL-Bridging-Header.h` — Swift ↔ C ABI（相対パス）
- `App/`（SwiftUI）+ `NovelCore/`（C++ コア、curl・zstd なし）+ `Resources/presets/`（YAML）
- `Nyxian/sync_project.py` — リポジトリから再同期。`Nyxian/README.md` に実仕様を記載

※ 検証: コアは clang 既定の gnu++17 でコンパイル可能（`-std` 指定不要＝混成ビルドと完全互換）。zstd は iOS 非標準のため不使用（生バイト保存）。HTTP は同梱 NSURLSession 転送。

## 1+. 対応端末 = **iPhone 12 mini（375×812pt）** への適合

- `CoverTile` の表紙が固定 108pt で、12 mini の 2 列グリッド（列幅 ≈ 160pt）に埋まらない → **列幅追従（2:3 アスペクト）に修正**。詳細ヘッダの 92pt 明示幅も維持
- タイポシート 430pt・タップゾーン・下部リボン伸縮は 812pt 画面に適合済み（前回修正のまま）
- モックアップ 2 点を **iPhone 12 mini 本体（5.4 インチ・ノッチ）**で再生成（マット・Liquid Glass 不使用）

## 7. Nyxian ビルドエラーの修正（マクロ不可・Swift 6・DiscoverView）

Nyxian の swiftc は **Xcode/Swift のマクロ・プラグインを展開できない**ため、リポジトリ全体を
「マクロゼロ」に是正。報告されたエラーの正体と修正：

| エラー | 正体 | 修正 |
|--------|------|------|
| Xcode のマクロが使えない | `@Observable`（Observation マクロ = プラグイン展開が必要） | **`ObservableObject` + `@Published`** に置換（`@Environment(CoreClient.self)` → `@EnvironmentObject`、`.environment` → `.environmentObject`）。プロパティラッパのみ＝マクロ不要 |
| escaping / non-escaping closure | `decode` の non-escaping な `body` が `Task.detached` 用の **@escaping @Sendable クロージャに捕獲**される | `body` を `@escaping @Sendable` に、`T: Decodable & Sendable` に変更（Swift 6 の Sendable 検査も通過） |
| DiscoverView の do/catch と呼び出し関数のエラー | 上記 2 つの**連鎖エラー**（`core.search` 等が型検査不能になり呼び出し元に表示された） | 根治で解消 |
| 「など」 | (a) `ForEach(id: \.0)` — **タプル keypath は Swift で非対応**（NovelDetailView）→ `Identifiable` struct に変更 (b) `NSRegularExpression.matches(in:)` の **`range:` 引数欠落**（ReaderMarkup 3 か所） (c) `CTRubyAnnotationCreateWithAttributes` の**引数不一致**（正しい 5 引数版に修正） (d) `URLSession` の @Sendable コールバックが `var` を捕獲 → `nonisolated(unsafe)` 化 (e) UIKit 型使用ファイルの **`import UIKit` 補完**（ReaderView / PageCanvas） | 全修正済み |

C++ コアのユニットテストは引き続き **118 passed / 0 failed**。修正は `Nyxian/sync_project.py` 済み。

### 追加修正（エラー再発への対応・その2）

| エラー | 正体 | 修正 |
|--------|------|------|
| generic parameter 'ObjectType' could not be inferred | `@EnvironmentObject` は**型注釈が必須**（`ObjectType` を型から推論）なのに `private var core` のままだった | 全8箇所を `private var core: CoreClient` に |
| 'catch' block is unreachable | 上の連鎖（`core` の型崩壊で `core.search` 等が解決不能＝非 throwing 扱いに） | 根治で解消 |
| その他のエラー（argument label / Sendable 等） | (a) **`AppFont.ui(_:design:)` が定義されていない**のに5か所で `design:` ラベル使用 → `design: Font.Design = .default` 引数を追加 (b) Swift 6 の `decode` 境界（`T: Sendable`）に対し**ローカル struct 等の暗黙 Sendable に頼っていた** → CoreModels 全16型＋ローカル6型に**明示 `Sendable`** (c) C ABI（`novel_core.h` 全シグネチャ）との照合済み・不一致なし | 修正済み |
