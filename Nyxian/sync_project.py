#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Nyxian プロジェクト NovelDL/ のソース類をリポジトリから同期する。

    python3 Nyxian/sync_project.py

Config/（Project.plist・Entitlements.plist・ブリッジヘッダ）と README は
手書きの成果物なので触らない。App/・NovelCore/・Resources/ のみ再生成。

Nyxian のビルドは Makefile ではなく NXProject（Config/Project.plist = AvisR2
形式）＋LindChain Builder による自動ビルド。ソースは Config/ と Resources/ を
除くプロジェクト配下から自動収集される（LDEFilesFinder）。
"""
import os
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # .../noveldl
DST = os.path.join(ROOT, "Nyxian", "NovelDL")

def clean():
    for sub in ("App", "NovelCore", "Resources"):
        p = os.path.join(DST, sub)
        if os.path.isdir(p):
            shutil.rmtree(p)

def copy_filtered(src, dst, ignore_names=(), exts=None):
    os.makedirs(dst, exist_ok=True)
    for entry in sorted(os.listdir(src)):
        if entry in ignore_names:
            continue
        s = os.path.join(src, entry)
        if os.path.isdir(s):
            copy_filtered(s, os.path.join(dst, entry), ignore_names, exts)
        else:
            if exts and not any(entry.endswith(e) for e in exts):
                continue
            shutil.copy2(s, os.path.join(dst, entry))

def main():
    clean()

    # --- App: SwiftUI ソースのみ（Xcode 側ブリッジヘッダは Config/ のを使う）
    app_src = os.path.join(ROOT, "Novelios", "NovelDLiOS", "NovelDLiOS")
    copy_filtered(app_src, os.path.join(DST, "App"),
                  ignore_names={"NovelDLiOS-Bridging-Header.h"},
                  exts=(".swift",))

    # --- NovelCore: C++ コア（curl 転送・ツール・テストは除外、zstd なし）
    core_src = os.path.join(ROOT, "novel_core")
    os.makedirs(os.path.join(DST, "NovelCore"), exist_ok=True)
    shutil.copytree(os.path.join(core_src, "include"),
                    os.path.join(DST, "NovelCore", "include"))
    os.makedirs(os.path.join(DST, "NovelCore", "src"), exist_ok=True)
    for entry in sorted(os.listdir(os.path.join(core_src, "src"))):
        s = os.path.join(core_src, "src", entry)
        if os.path.isdir(s):                      # apple/ 転送
            copy_filtered(s, os.path.join(DST, "NovelCore", "src", entry),
                          exts=(".c", ".cpp", ".m", ".mm", ".h"))
        elif entry == "nc_http_curl.cpp":
            continue                              # iOS では NSURLSession 転送を使う
        elif entry.endswith((".cpp", ".h")):
            shutil.copy2(s, os.path.join(DST, "NovelCore", "src", entry))

    # --- Resources/presets: サイト対応 YAML（コンパイル対象外ディレクトリ）
    copy_filtered(os.path.join(core_src, "presets"),
                  os.path.join(DST, "Resources", "presets"))

    n = sum(len(files) for _, _, files in os.walk(DST))
    print(f"synced: {DST} ({n} files)")

if __name__ == "__main__":
    sys.exit(main())
