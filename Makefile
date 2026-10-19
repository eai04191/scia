PROJECT := Scia.xcodeproj
SCHEME := Scia
DERIVED_DATA := DerivedData
SIM_DESTINATION ?= generic/platform=iOS Simulator

.PHONY: generate lint test-core build warnings test sim-keyboard readme-icons update-known-servers check clean

## project.ymlからXcodeプロジェクトを生成する
generate:
	xcodegen generate

## 実行時クラッシュにつながる書き方（強制アンラップ、try!、IUO）を検出する。swiftlintはbrew install swiftlintで入れる
lint:
	swiftlint lint --quiet

## SciaCoreのユニットテストをmacOS上で実行する（シミュレーター不要）
test-core:
	cd Packages/SciaCore && swift test

## アプリをシミュレーター向けにビルドする
build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(SIM_DESTINATION)' -derivedDataPath $(DERIVED_DATA) build

## make buildのあとに残ったアプリのSwiftの警告を、差分ビルドで作り直さなかったファイルの分も含めて検出する
warnings: build
	Tools/check-warnings.sh $(DERIVED_DATA)

## シミュレーター上でschemeのテストを実行する。SIMに端末の名前を指定する
## テストはハードウェアキーボードがつながった状態を前提にしているので、先につなぐ。sim-keyboardで外したままだと、投稿欄のテストが落ちる
## 例: make test SIM='Scia 1'
test: generate
	@test -n '$(SIM)' || { echo "SIM='<端末の名前>'を指定する" >&2; exit 1; }
	swift Tools/sim-keyboard.swift '$(SIM)' hardware
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=iOS Simulator,name=$(SIM)' -derivedDataPath $(DERIVED_DATA) -collect-test-diagnostics never test

## シミュレーターのハードウェアキーボードを外してソフトウェアキーボードを出す（KEYBOARD=hardwareでつなぎ直す）
## 例: make sim-keyboard SIM='Scia 1'
KEYBOARD ?= software
sim-keyboard:
	swift Tools/sim-keyboard.swift '$(SIM)' $(KEYBOARD)

## READMEに載せるアイコンの絵を、.iconから描き出す。アイコンを変えたら描き出し直してcommitする
## ライトはふだんの見た目、ダークはホーム画面のダークモードと同じ見た目にする。128ptで出すので、App Storeのアイコンと同じ1024pxで描き出し、劣化なしのWebPにする
## cwebpはbrew install webpで入れる
ICTOOL = $(shell xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool
readme-icons:
	mkdir -p docs/images
	tmp=$$(mktemp -d) && \
	'$(ICTOOL)' App/Resources/AppIcon.icon --export-image --output-file $$tmp/light.png --platform iOS --rendition Default --width 1024 --height 1024 --scale 1 >/dev/null && \
	'$(ICTOOL)' App/Resources/AppIcon.icon --export-image --output-file $$tmp/dark.png --platform iOS --rendition Dark --width 1024 --height 1024 --scale 1 >/dev/null && \
	cwebp -quiet -lossless -z 9 $$tmp/light.png -o docs/images/icon-light.webp && \
	cwebp -quiet -lossless -z 9 $$tmp/dark.png -o docs/images/icon-dark.webp && \
	rm -r $$tmp

## ログイン画面の補完に使うサーバーの一覧を、FediDBのデータセットから作り直す。GitHub Actionsが週1回走らせてPRにする
update-known-servers:
	Tools/update-known-servers.sh

## 変更を報告する前に通すべき検証
check: lint test-core build warnings

clean:
	rm -rf $(DERIVED_DATA) $(PROJECT) Packages/SciaCore/.build
