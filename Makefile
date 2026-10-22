PROJECT := Scia.xcodeproj
SCHEME := Scia
DERIVED_DATA := DerivedData
SIM_DESTINATION ?= generic/platform=iOS Simulator

.PHONY: generate lint test-core build warnings test sim-keyboard promo readme-icons update-known-servers check check-steps hooks clean

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
## 通ったら、確かめた作業ツリーの中身を覚える。make hooksを入れたcheckoutでは、make checkとmake testの両方が通った中身のcommitしかmainに入れられない
## 例: make test SIM='Scia 1'
TEST_TREE := $(DERIVED_DATA)/test-tree
test: generate
	@test -n '$(SIM)' || { echo "SIM='<端末の名前>'を指定する" >&2; exit 1; }
	@mkdir -p $(DERIVED_DATA) && Tools/check-stamp.sh tree > $(TEST_TREE)
	swift Tools/sim-keyboard.swift '$(SIM)' hardware
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=iOS Simulator,name=$(SIM)' -derivedDataPath $(DERIVED_DATA) -collect-test-diagnostics never test
	@Tools/check-stamp.sh record test "$$(cat $(TEST_TREE))"

## シミュレーターのハードウェアキーボードを外してソフトウェアキーボードを出す（KEYBOARD=hardwareでつなぎ直す）
## 例: make sim-keyboard SIM='Scia 1'
KEYBOARD ?= software
sim-keyboard:
	swift Tools/sim-keyboard.swift '$(SIM)' $(KEYBOARD)

## プロモーション動画の素材を、台本のUIテストを走らせながら撮る（docs/promo-video.md）。SIMにはシミュレーターか実機の名前を渡す
## 例: make promo SIM='Scia 1'
SCENARIO ?= StreamingDemoUITests/testStreamingDemo
OUT ?= $(DERIVED_DATA)/promo.mp4
promo: generate
	Tools/promo-record.sh '$(SIM)' $(SCENARIO) '$(OUT)'

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
## 通ったら、確かめた作業ツリーの中身を覚える。make hooksを入れたcheckoutでは、make checkとmake testの両方が通った中身のcommitしかmainに入れられない
## $(MAKE)を含む行はmake -nでも走るので、覚える処理はその行に入れない。入れると、何も確かめないmake -n checkで中身を覚えてしまう
## make -i checkは失敗を無視して最後まで進むので、通っていない中身も覚えてしまう。失敗の無視はわざと保証を外す操作で、ふだんの手順では使わないので止めない
CHECK_TREE := $(DERIVED_DATA)/check-tree
check:
	@mkdir -p $(DERIVED_DATA) && Tools/check-stamp.sh tree > $(CHECK_TREE)
	@$(MAKE) --no-print-directory check-steps
	@Tools/check-stamp.sh record check "$$(cat $(CHECK_TREE))"

check-steps: lint test-core build warnings

## ローカルのmainを、make checkとmake testの両方が通った中身のcommitにしか動かさないhookを入れる。worktreeにも効く
hooks:
	ln -sfn ../../Tools/git-hooks/reference-transaction "$$(git rev-parse --git-common-dir)/hooks/reference-transaction"

clean:
	rm -rf $(DERIVED_DATA) $(PROJECT) Packages/SciaCore/.build
