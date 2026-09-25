# NovelDL — Nyxian プロジェクト

**Nyxian**（[emexlab/Nyxian](https://github.com/emexlab/Nyxian) — emexLabs 製）は、
**Mac 不要で iPhone/iPad 単体**に iOS アプリをビルド・実行できるオンデバイス IDE。
非ジェイルブレイク端末上で、同梱の iOS 26 SDK・LLVM/Clang/Swift ツールチェーン
（CoreCompiler/MDK）とカーネル仮想化レイヤ **ksurface**（NSExtension 実行）を使って
C / Objective-C / C++ / Objective-C++ / Swift のネイティブアプリをビルド・即実行する。
対応 iOS 18.0〜27.x・SDK 取得後は完全オフラインで開発可能。

## Nyxian のプロジェクト形式（重要: Makefile ではない）

Nyxian のビルドは **Makefile ではなく**、`NXProject` が読む独自の
**`Config/Project.plist`（AvisR2 形式 — `NXProjectFormat: NXAvixR2`）** と、
`LindChain/Builder` → `MDKPhaseEngine` による自動ビルドパイプラインで行われる。

| ファイル | 役割 |
|----------|------|
| `Config/Project.plist` | プロジェクト定義（形式 `NXAvixR2`）。`NXExecutable` / `NXDeploymentTarget` / `NXClangFlags` / `NXSwiftFlags` / `NXBundleInfo`（Info.plist 相当）など。`$(SRCROOT)` `$(SDKROOT)` `$(BSROOT)` `$(CACHEROOT)` 変数展開に対応 |
| `Config/Entitlements.plist` | ksurface 権限ブロブ（`com.nyxian.pe.*`）。本プロジェクトは jailed 既定セット |
| `Config/NovelDL-Bridging-Header.h` | Swift ↔ C ABI ブリッジ（`-import-objc-header` で指定） |
| `App/` `NovelCore/`（任意の場所） | ソースはプロジェクト配下から**自動収集**（`.swift` / `.c` / `.cpp` / `.m` / `.mm`）。`Config/` と `Resources/` はコンパイル対象外 |
| `Resources/` | リソース（サイト対応 YAML `presets/`）。アプリスキームのバンドルに同梱 |

ビルドはエディタの ▶（Build & Run）ひとつ。依存解析（`MDKDependencyScanner`）と
mtime 比較によるインクリメンタルビルド、zsign による署名、`Payload/<名>.app`
作成まで自動。リポジトリ内の Makefile は **Nyxian IDE 自体を Mac でビルドする
ためのもの**であり、ユーザー プロジェクトの形式とは無関係。

## このプロジェクトの中身

- **NovelCore/** — 小説取得・整形 C++ コア（C ABI `novel_core.h` を公開）。
  zstd なし（生バイト保存）・curl なし（`src/apple/nc_http_apple.m` の
  NSURLSession 転送を使用）・依存はシステム libsqlite3 のみ。
- **App/** — SwiftUI アプリ（Kindle/Kobo 風のマットな紙デザイン。Liquid Glass 不使用）。
  **iPhone 12 mini（375×812pt）** で詰まらないことを前提にレイアウト済み。
- **Resources/presets/** — サイト対応 YAML（22 サイト・`extends` 共通化）。
  C/C++ を触らずにサイト追加可能。コア組み込みプリセットから初回起動時に
  ライブラリへシードされる。

## 使い方

1. `NovelDL/` フォルダごと iPhone の Files 等で Nyxian のプロジェクト領域へ転送
   （AirDrop / ファイル共有）。
2. Nyxian でプロジェクトを開き ▶ をタップ → ビルド → ksurface 上で即実行。
3. プレビュー端末: **iPhone 12 mini**。

ソースをリポジトリ側で更新したら `python3 Nyxian/sync_project.py` で再同期。
