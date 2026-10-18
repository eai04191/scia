PROJECT := Scia.xcodeproj
SCHEME := Scia
DERIVED_DATA := DerivedData
SIM_DESTINATION ?= generic/platform=iOS Simulator

.PHONY: generate lint test-core build warnings test sim-keyboard check clean

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

## シミュレーター上でschemeのテストを実行する。SIM_DESTINATIONに具体的な端末を指定する
## 例: make test SIM_DESTINATION='platform=iOS Simulator,name=iPhone 17'
test: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(SIM_DESTINATION)' -derivedDataPath $(DERIVED_DATA) -collect-test-diagnostics never test

## シミュレーターのハードウェアキーボードを外してソフトウェアキーボードを出す（KEYBOARD=hardwareでつなぎ直す）
## 例: make sim-keyboard SIM='Scia 1'
KEYBOARD ?= software
sim-keyboard:
	swift Tools/sim-keyboard.swift '$(SIM)' $(KEYBOARD)

## 変更を報告する前に通すべき検証
check: lint test-core build warnings

clean:
	rm -rf $(DERIVED_DATA) $(PROJECT) Packages/SciaCore/.build
