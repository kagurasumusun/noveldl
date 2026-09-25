# NovelDL for Nyxian

[Nyxian](https://github.com/emexlab/Nyxian)（emexLabs 製）— **iPhone/iPad 単体でネイティブ iOS アプリを
ビルド・実行できるオンデバイス IDE** — 向けのプロジェクトです。Mac / Xcode は不要で、
ネットワーク接続なし（SDK 取得後）でもビルドできます。

## Nyxian 仕様（調査結果の要点）

| 項目 | 内容 |
|------|------|
| 開発元 | emexLabs（旧 ProjectNyxian）— https://github.com/emexlab/Nyxian |
| 形態 | iOS アプリ内 IDE + ユーザー空間マイクロカーネル（ksurface）でネイティブコード実行 |
| 対応 OS | iOS 18.0 〜 27.x（非ジェイルブレイク、証明書署名方式） |
| 対応言語 | C / Objective-C / C++ / Objective-C++ / **Swift**（LLVM/clang・Swift 6.4 同梱） |
| SDK | iOS 26.x SDK をバンドル（`NYXIAN_SDK_ROOT` 配下の iPhoneOS.sdk） |
| ビルドシステム | **標準 Makefile**（clang/ld/codesign、依存追跡つき） |
| 実行モデル | コンパイル済みバイナリは NSExtension 経由でサンドボックス実行 |
| 署名 | `NYXIAN_DEVELOPER_IDENTITY`（開発者証明書）で codesign |
| 配備 | `nyxian-install Payload/<App>.app` |
| オフライン | SDK/リソース取得後は完全オフラインで開発可能 |

## このプロジェクトの構成

- `Makefile` — Nyxian の Makefile 規約に準拠（`NYXIAN_SDK_ROOT` / `NYXIAN_DEVELOPER_IDENTITY` /
  `nyxian-install`）。`../novel_core`（C++ コア）と `../Novelios/NovelDLiOS`（SwiftUI アプリ）を
  相対パスで取り込みます。
- `Info.plist` — アプリバンドル用（Nyxian は Xcode の Info.plist 自動生成がないため静的 plist）。
- 依存ライブラリは **システムの libsqlite3 のみ**。zstd は使わず生バイト保存
  （コアを `NC_HAVE_ZSTD` 未定義でコンパイル）。HTTP は同梱の **NSURLSession 転送**
  （`novel_core/src/apple/nc_http_apple.m`）— curl 不要。
- サイト対応 YAML（`novel_core/presets/`）は `.app/presets` にバンドルされ、
  C/C++ を触らずにサイト追加できます。

## ビルド手順（Nyxian 上で）

```sh
cd Nyxian
make            # コア(C++) → 静的 lib → SwiftUI アプリ → 署名 → Payload/NovelDL.app
make install    # nyxian-install でテスト環境に配備
```

## デバッグのヒント

- コンパイルエラーが出る場合: Nyxian の SDK バージョンと `MIN_IOS`（既定 18.0）を確認。
- Swift が使えない古い Nyxian の場合: `Novelios/` の SwiftUI ではなく、
  `novel_core/include/novel_core.h`（C ABI）から Objective-C++ で UI を組んでください。
  コアは C ABI の JSON エンベロープで完結しているため、UI 技術を問わず接続できます。
