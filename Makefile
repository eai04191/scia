PROJECT := Scia.xcodeproj
SCHEME := Scia
DERIVED_DATA := DerivedData
SIM_DESTINATION ?= generic/platform=iOS Simulator

.PHONY: generate test-core build test check clean

## project.ymlからXcodeプロジェクトを生成する
generate:
	xcodegen generate

## SciaCoreのユニットテストをmacOS上で実行する（シミュレーター不要）
test-core:
	cd Packages/SciaCore && swift test

## アプリをシミュレーター向けにビルドする
build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(SIM_DESTINATION)' -derivedDataPath $(DERIVED_DATA) build

## シミュレーター上でschemeのテストを実行する。SIM_DESTINATIONに具体的な端末を指定する
## 例: make test SIM_DESTINATION='platform=iOS Simulator,name=iPhone 17'
test: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(SIM_DESTINATION)' -derivedDataPath $(DERIVED_DATA) -collect-test-diagnostics never test

## 変更を報告する前に通すべき検証
check: test-core build

clean:
	rm -rf $(DERIVED_DATA) $(PROJECT) Packages/SciaCore/.build
