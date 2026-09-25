# NovelDL (Nyxian project)

Nyxian（オンデバイス iOS IDE）で開いてビルドするプロジェクト。

- `Config/Project.plist` — プロジェクト定義（**AvisR2 形式** `NXAvixR2`）。
  Makefile ではない。ビルドは Nyxian の ▶（LindChain Builder / MDKPhaseEngine）。
- `Config/Entitlements.plist` — ksurface 権限（jailed 既定）。
- `Config/NovelDL-Bridging-Header.h` — Swift ↔ C ABI ブリッジ。
- `App/` — SwiftUI アプリ（iPhone 12 mini 375×812pt 前提）。
- `NovelCore/` — C++ コア（C ABI・NSURLSession 転送・libsqlite3 のみ）。
- `Resources/presets/` — サイト対応 YAML（コンパイル対象外）。

このフォルダはリポジトリから `python3 Nyxian/sync_project.py` で生成・同期される
（Config/ と README は手書き）。詳細は `Nyxian/README.md` を参照。
