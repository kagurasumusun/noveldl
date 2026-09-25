# Makefile — NovelDL for Nyxian (on-device iOS IDE by emexLabs)
#
# Nyxian のゲストアプリビルド規約に準拠:
#   SDK ルート   : $(NYXIAN_SDK_ROOT)/iPhoneOS.sdk   (Nyxian が配布する iOS SDK)
#   ターゲット   : arm64 / iphoneos / min iOS 18.0
#   ツールチェーン: clang / clang++ / swiftc / ld / codesign (すべて端末内)
#   署名       : $(NYXIAN_DEVELOPER_IDENTITY) (証明書ベース)
#   配備       : Payload/NovelDL.app を作って `nyxian-install` に渡す
#
# 使い方 (Nyxian のターミナル / Make 実行画面で):
#   cd Nyxian && make            # ビルド + 署名 + Payload 化
#   make install                 # nyxian-install でテスト環境へ
#   make clean
#
# 依存: novel_core (C++) と Novelios/NovelDLiOS (SwiftUI) を同一リポジトリから
# 相対パスで取り込む。zstd は使わず生バイト保存 (NC_HAVE_ZSTD 未定義)。
# HTTP は NSURLSession 転送 (novel_core/src/apple/nc_http_apple.m)。

CC      ?= clang
CXX     ?= clang++
SWIFTC  ?= swiftc
LD      ?= ld
CODESIGN ?= codesign

SDK_ROOT   ?= $(NYXIAN_SDK_ROOT)
SYSROOT    ?= $(SDK_ROOT)/iPhoneOS.sdk
ARCH       ?= arm64
MIN_IOS    ?= 18.0

APP_NAME   := NovelDL
BUNDLE_ID  := app.noveldl.NovelDL

CORE_DIR   := ../novel_core
UI_DIR     := ../Novelios/NovelDLiOS/NovelDLiOS

CFLAGS   := -arch $(ARCH) -isysroot $(SYSROOT) -mios-version-min=$(MIN_IOS) \
            -O2 -fobjc-arc -I$(CORE_DIR)/include -I$(CORE_DIR)/src
# novel_core (C++20) — 例外を使用するため例外は有効のまま
CXXFLAGS := -arch $(ARCH) -isysroot $(SYSROOT) -mios-version-min=$(MIN_IOS) \
            -O2 -I$(CORE_DIR)/include -I$(CORE_DIR)/src -std=c++20
SWIFTFLAGS := -sdk $(SYSROOT) -target $(ARCH)-apple-ios$(MIN_IOS) \
              -O -parse-as-library \
              -import-objc-header $(UI_DIR)/NovelDLiOS-Bridging-Header.h \
              -I $(CORE_DIR)/include -I $(CORE_DIR)/src/apple
LDFLAGS  := -arch $(ARCH) -isysroot $(SYSROOT) -mios-version-min=$(MIN_IOS) \
            -framework Foundation -framework UIKit -framework SwiftUI \
            -framework CoreText -framework CoreGraphics -framework CFNetwork \
            -lsqlite3 -lc++

CORE_SRC := $(wildcard $(CORE_DIR)/src/nc_*.cpp)
CORE_SRC := $(filter-out $(CORE_DIR)/src/nc_http_curl.cpp,$(CORE_SRC))
CORE_OBJ := $(patsubst $(CORE_DIR)/src/%.cpp,build/core/%.o,$(CORE_SRC))
APPLE_OBJ := build/core/nc_http_apple.o

SWIFT_SRC := $(shell find $(UI_DIR) -name '*.swift')

all: Payload/$(APP_NAME).app

build/core:
	mkdir -p build/core

build/core/%.o: $(CORE_DIR)/src/%.cpp | build/core
	$(CXX) $(CXXFLAGS) -c $< -o $@

build/core/nc_http_apple.o: $(CORE_DIR)/src/apple/nc_http_apple.m | build/core
	$(CC) $(CFLAGS) -c $< -o $@

build/libnovel_core_ios.a: $(CORE_OBJ) $(APPLE_OBJ)
	libtool -static $^ -o $@

build/$(APP_NAME): build/libnovel_core_ios.a $(SWIFT_SRC)
	$(SWIFTC) $(SWIFTFLAGS) $(SWIFT_SRC) build/libnovel_core_ios.a $(LDFLAGS) -o $@

Payload/$(APP_NAME).app: build/$(APP_NAME) Info.plist
	rm -rf Payload
	mkdir -p Payload/$(APP_NAME).app
	cp build/$(APP_NAME) Payload/$(APP_NAME).app/
	cp Info.plist Payload/$(APP_NAME).app/
	cp -R $(CORE_DIR)/presets Payload/$(APP_NAME).app/presets
	$(CODESIGN) -fs "$(NYXIAN_DEVELOPER_IDENTITY)" Payload/$(APP_NAME).app
	@echo "built: Payload/$(APP_NAME).app  (make install で端末内テスト環境へ)"

install: Payload/$(APP_NAME).app
	nyxian-install Payload/$(APP_NAME).app

clean:
	rm -rf build Payload

.PHONY: all install clean
