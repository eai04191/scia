PROJECT := Scia.xcodeproj
SCHEME := Scia
DERIVED_DATA := DerivedData
SIM_DESTINATION ?= generic/platform=iOS Simulator
# 端末を決めないビルドは、既定ではシミュレーターの全アーキテクチャ（arm64とx86_64）を作る。このMacで動く分だけにして、コンパイルを半分にする
SIM_ARCH ?= $(shell uname -m)
# 同じDerivedDataを使うDebugのビルドには、すべてコンパイルキャッシュの設定を渡す（Config/Cache.xcconfig）。Tools/system-ui-check.shも同じものを渡す
CACHE_XCCONFIG := -xcconfig Config/Cache.xcconfig

.PHONY: generate app-info check-app-info lint test-lint test-core test-memory-cache build warnings test test-on-sim sim-keyboard scenario-build scenario-setup scenario-reset scenario-run archive testflight testflight-external promo readme-screenshots readme-icons update-known-servers check check-steps check-test hooks menu-editor clean

## project.ymlからXcodeプロジェクトを生成する
generate:
	xcodegen generate

## Config/app-info.jsonから、App/Sources/Settings/AppInfo.generated.swiftとREADME.mdの生成の節を書き出す
app-info:
	python3 Tools/generate-app-info.py

## 書き出したものがConfig/app-info.jsonと合っているかを調べる
check-app-info:
	python3 Tools/generate-app-info.py --check

## 実行時クラッシュにつながる書き方（強制アンラップ、try!、IUO）と、.swiftlint.ymlとTools/SciaLintの規則に反する書き方を検出する。swiftlintはbrew install swiftlintで入れる
## 設定を明示しないと、worktreeでは親のディレクトリにある元のcheckoutの.swiftlint.ymlも重ねて読み、そちらにない規則が外れる
## 呼び出しや文字列の補間の形で決まる規則（持ち主を通さない処理、目的を名乗らない処理、ログに公開扱いで出す値、テストで出し終えるのを待たない画面、テストで件数を==で待つ待ち、決め打ちの文字の大きさ、半透明の白い文字）は、構文木で調べるTools/SciaLintで検出する
lint:
	swiftlint lint --quiet --config .swiftlint.yml
	swift run --package-path Tools/SciaLint --quiet scia-lint .

## Tools/SciaLintの規則のテストを実行する
test-lint:
	swift test --package-path Tools/SciaLint --quiet

## SciaCoreのユニットテストをmacOS上で実行する（シミュレーター不要）
test-core:
	cd Packages/SciaCore && swift test

## Sciaに依存しないキャッシュのパッケージ（Packages/MemoryCache）のテストをmacOS上で実行する
test-memory-cache:
	swift test --package-path Packages/MemoryCache --quiet

## アプリをシミュレーター向けにビルドする
build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(SIM_DESTINATION)' -derivedDataPath $(DERIVED_DATA) $(CACHE_XCCONFIG) ARCHS=$(SIM_ARCH) build

## make buildのあとに残ったアプリのSwiftの警告を、差分ビルドで作り直さなかったファイルの分も含めて検出する
warnings: build
	Tools/check-warnings.sh $(DERIVED_DATA) $(SIM_ARCH)

## シミュレーター上でschemeのテストを実行する。SIMを省くと、このworktreeが借りている端末（Tools/sim.sh acquire）で走らせる
## 貸し借りする端末（Scia 1〜）をSIMで指定するときは、このworktreeが借りている端末だけを受け付ける（Tools/sim.sh leased）
## 端末のiOSの版で初めて走らせたときは、UIKitの公開されていない作りに頼る部分のUIテスト（SciaSystemUITests）も走らせる（Tools/system-ui-check.sh）
## 通ったら、確かめた作業ツリーの中身を覚える
## ONLYにテストの識別子（空白区切りで複数）を渡すと、それだけを走らせる。全部は走らせていないので、SciaSystemUITestsも走らせず、通っても中身を覚えない
## 失敗時の診断の収集は止める。集めると、simctl diagnoseが応答を待って600秒のタイムアウトまで止まるため
## 例: make test
## 例: make test ONLY='SciaTests/LinkLabelTests SciaTests/TimelineNoticeTests/progressGainingDigitWidensWithAnimation()'
## 例: make test SIM='iPhone 16 Pro'
TEST_TREE := $(DERIVED_DATA)/test-tree
TEST_ARGS = -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=iOS Simulator,name=$(SIM)' -derivedDataPath $(DERIVED_DATA) $(CACHE_XCCONFIG) -collect-test-diagnostics never
## 決めた端末をSIMに入れて呼び直す。テストの間ずっと、処理の引数に端末の名前が残り、Tools/sim.sh busyが使っている処理として見つけられるようにするため
test: generate
	@sim=$$(Tools/sim.sh leased '$(SIM)') && $(MAKE) --no-print-directory test-on-sim SIM="$$sim"

## make testから、走らせる端末を決めたあとに呼ぶ。直接は走らせない
test-on-sim:
	@mkdir -p $(DERIVED_DATA) && Tools/check-stamp.sh tree > $(TEST_TREE)
	@# アクセシビリティの要素を作る設定（Tools/sim.sh dumpが入れる）を切る。アプリは起動時にこの設定を読むので、端末の前の状態でテストの結果が変わらないよう、テストのアプリを起動する前に揃える
	xcrun simctl spawn '$(SIM)' defaults write com.apple.Accessibility ApplicationAccessibilityEnabled -bool false
ifneq ($(strip $(ONLY)),)
	xcodebuild $(TEST_ARGS) test $(foreach t,$(ONLY),'-only-testing:$(t)')
else
	xcodebuild $(TEST_ARGS) build-for-testing
	@# SciaCoreTestsとTextKit2LabelTestsはアプリの中で走らないので、まとめてSciaTestsと同じ端末で同時に走らせる。SciaTestsがアプリを入れて起動する15秒ほどの間に、ほぼ走り終える。
	@# SciaTestsでは、アプリのログを出力に流さない。キーボードの描画のログ（UIKBRenderingLog）が10万行ほど出て、出さないと投稿欄とビューアのsuiteが49秒から44秒になったため。ONLYで走らせるときは、調べる手がかりとして流す
	@# 止められたら、どちらのxcodebuildも止めて終わるのを待つ。前で走らせると、シェルはそれが終わるまで止める合図を扱わないので、どちらも後ろで走らせて待つ
	@# Tools/watch-tests.shが、負荷と、なかなか終わらないSciaCoreのテストのスタックをtest-logs/watch-<時刻>に残す。Xcodeの結果のファイルは古いものから消えるので、落ちた回の分はtest-logs/failed-<時刻>にコピーする
	@# 結果のファイルの名前は始めた秒で決まり、同時に始めると重なるので、SciaCoreTestsの分は名前を決めて書く。出力は混ざらないよう、ファイルに書いて落ちたときだけ出す
	@stamp=$$(date +%Y.%m.%d_%H-%M-%S); mkdir -p $(DERIVED_DATA)/test-logs; core_log=$(DERIVED_DATA)/test-logs/SciaCore-$$stamp.log; \
	stop() { kill $$core $$app $$watch 2>/dev/null; wait; echo "SciaCoreTestsとTextKit2LabelTestsの出力は$$core_log"; exit $$1; }; \
	trap 'stop 129' HUP; trap 'stop 130' INT; trap 'stop 143' TERM; \
	xcodebuild $(TEST_ARGS) -resultBundlePath "$(DERIVED_DATA)/Logs/Test/SciaCore-$$stamp.xcresult" -only-testing:SciaCoreTests -only-testing:TextKit2LabelTests test-without-building > "$$core_log" 2>&1 & core=$$!; \
	Tools/watch-tests.sh "$$core_log" "$(DERIVED_DATA)/test-logs/watch-$$stamp" '$(SIM)' & watch=$$!; \
	TEST_RUNNER_OS_ACTIVITY_MODE=disable xcodebuild $(TEST_ARGS) -resultBundlePath "$(DERIVED_DATA)/Logs/Test/Scia-$$stamp.xcresult" -only-testing:SciaTests test-without-building & app=$$!; \
	wait $$app; app=$$?; wait $$core; core_status=$$?; \
	kill $$watch 2>/dev/null; \
	if [ $$app -ne 0 ] || [ $$core_status -ne 0 ]; then failed=$(DERIVED_DATA)/test-logs/failed-$$stamp; mkdir -p "$$failed"; cp -R "$(DERIVED_DATA)/Logs/Test/SciaCore-$$stamp.xcresult" "$(DERIVED_DATA)/Logs/Test/Scia-$$stamp.xcresult" "$$failed/" 2>/dev/null; echo "失敗した回のxcresultは$$failedに残しました"; fi; \
	if [ $$core_status -ne 0 ]; then grep -aE '✘|error:' "$$core_log" | tail -40; echo "SciaCoreTestsかTextKit2LabelTestsが落ちました。出力は$$core_log"; else grep -a 'Test run with' "$$core_log"; fi; \
	[ $$app -eq 0 ] && [ $$core_status -eq 0 ]
	Tools/system-ui-check.sh '$(SIM)' $(DERIVED_DATA)
	@Tools/check-stamp.sh record test "$$(cat $(TEST_TREE))"
endif

## シミュレーターのハードウェアキーボードを外してソフトウェアキーボードを出す（KEYBOARD=hardwareでつなぎ直す）
## SIMを省くと、このworktreeが借りている端末で行う。端末の選び方はmake testと同じ
## 例: make sim-keyboard
KEYBOARD ?= software
sim-keyboard:
	@sim=$$(Tools/sim.sh leased '$(SIM)') && swift Tools/sim-keyboard.swift "$$sim" $(KEYBOARD)

## シナリオの端末に入れるSciaを、Release構成でビルドする。デバッグ版はホームにデバッグメニューのボタンを出し、使う人が触らない画面に入れてしまうため
SCENARIO_APP := $(DERIVED_DATA)/Build/Products/Release-iphonesimulator/Scia.app
scenario-build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -destination '$(SIM_DESTINATION)' -derivedDataPath $(DERIVED_DATA) ARCHS=$(SIM_ARCH) build

## 初めて使う人として触るエージェントのための、外へ出ないMastodonと専用の端末（Scia Scenario）を用意する。何度走らせても同じ状態になる
## Mastodonのデータは毎回、流し込んでyouでログインした直後のスナップショットに戻す。DockerとAXe（brew install cameroncooke/axe/axe）が要る
scenario-setup: scenario-build
	Tools/scenario/setup.sh '$(SCENARIO_APP)'

## 1人分を始める前に、Mastodonのデータをスナップショットに戻し、専用の端末のSciaを入れ直す。Keychainは残すので、youでログインした状態から始まる
scenario-reset: scenario-build
	Tools/scenario/reset.sh '$(SCENARIO_APP)'

## 1人分を走らせる。リセットしてから、何も知らないエージェントをPERSONAの役で初めて使う人として触らせ、報告を~/scia-scenario/runs/に残す
## 役はTools/scenario/personas/にある（literal、impatient、breaker）。claude -pを使うので、利用枠を使う
## 例: make scenario-run PERSONA=literal
scenario-run: scenario-build
	Tools/scenario/run.sh '$(SCENARIO_APP)' '$(PERSONA)'

## 実機向けのReleaseビルドをアーカイブする。署名のチームはConfig/Local.xcconfigのDEVELOPMENT_TEAMから読む
## App Store Connectは、同じバージョンで前に上げたものより大きいビルド番号しか受け付けないため、ビルド番号をアーカイブしたUTCの日時（例: 20261103.124500）にする
## App Store Connectは区切りごとの数を整数として出す（20261104.025903は20261104.25903になる）ので、設定の「情報」に出す値と同じ表記になるよう、時刻の先頭の0を落としてから渡す
## APPLE_AUTHには、Xcodeにサインインしていない環境（GitHub Actions）で、App Store ConnectのAPIキーを渡すxcodebuildの引数を入れる（.github/workflows/testflight.yml）
ARCHIVE := $(DERIVED_DATA)/Scia.xcarchive
APPLE_AUTH ?=
archive: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -destination 'generic/platform=iOS' -derivedDataPath $(DERIVED_DATA) -archivePath $(ARCHIVE) -allowProvisioningUpdates $(APPLE_AUTH) CURRENT_PROJECT_VERSION=$$(date -u +%Y%m%d.%H%M%S | sed -E 's/\.0+([0-9])/.\1/') archive

## アーカイブしてApp Store Connectへ上げる。処理が終わるとTestFlightに出る
testflight: archive
	xcodebuild -exportArchive -archivePath $(ARCHIVE) -exportOptionsPlist Config/ExportOptions.plist -exportPath $(DERIVED_DATA)/export -allowProvisioningUpdates $(APPLE_AUTH)

## make testflightで上げたビルドを、処理が終わるのを待って外部テストのグループに足し、TestFlight App Reviewに出す（Tools/testflight-external.swift）
## 外部グループの名前、What to Testを書いたファイル、APIキーは、環境変数（TESTFLIGHT_EXTERNAL_GROUP、WHAT_TO_TEST_PATH、APP_STORE_CONNECT_KEY_PATH、APP_STORE_CONNECT_KEY_ID、APP_STORE_CONNECT_ISSUER_ID）で渡す
testflight-external:
	swift Tools/testflight-external.swift $(ARCHIVE)

## プロモーション動画の素材を、シナリオのUIテストを走らせながら撮る（docs/promo-video.md）。SIMにはシミュレーターか実機の名前を渡す
## 例: make promo SIM='Scia 1'
SCENARIO ?= StreamingDemoUITests/testStreamingDemo
OUT ?= $(DERIVED_DATA)/promo.mp4
promo: generate
	Tools/promo-record.sh '$(SIM)' $(SCENARIO) '$(OUT)'

## READMEのスクリーンショットを、シナリオのUIテストを走らせて撮り、docs/imagesに書き出す（docs/promo-video.md）。撮り直したらcommitする
## 例: make readme-screenshots SIM='Scia 1'
readme-screenshots: generate
	Tools/readme-screenshots.sh '$(SIM)'

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

## ログイン画面の補完に使うサーバーのリストを、FediDBのデータセットから作り直す。GitHub Actionsが週1回走らせてPRにする
update-known-servers:
	Tools/update-known-servers.sh

## 変更を報告する前に通すべき検証
## 通ったら、確かめた作業ツリーの中身を覚える
## $(MAKE)を含む行はmake -nでも走るので、覚える処理はその行に入れない。入れると、何も確かめないmake -n checkで中身を覚えてしまう
## make -i checkは失敗を無視して最後まで進むので、通っていない中身も覚えてしまう。失敗の無視はわざと保証を外す操作で、ふだんの手順では使わないので止めない
CHECK_TREE := $(DERIVED_DATA)/check-tree
check:
	@mkdir -p $(DERIVED_DATA) && Tools/check-stamp.sh tree > $(CHECK_TREE)
	@$(MAKE) --no-print-directory check-steps
	@Tools/check-stamp.sh record check "$$(cat $(CHECK_TREE))"

## SciaCoreのテスト、キャッシュのパッケージのテスト、lintの規則のテスト、アプリのビルドは互いを待たないので、並べて走らせる。出力が混ざるので、失敗はmakeが最後に出すターゲット名から追う
CHECK_TESTS := test-core test-memory-cache test-lint check-app-info
check-steps: lint
	@$(MAKE) --no-print-directory -j4 $(CHECK_TESTS) warnings

## make checkとmake testを両方走らせる。アプリのビルドと警告の検査を済ませてから、checkの残り（lintとmacOSのテスト）をmake testと同時に走らせる。
## 同時に走らせるとmake testは1割ほど遅くなるが、checkの残りの40〜50秒がmake testの裏に隠れるので、続けて走らせるより30秒ほど早く終わる。
## 端末の選び方はmake testと同じ。通ったものだけ、確かめた作業ツリーの中身を覚える（make testの分はmake testが覚える）。
## checkの残りの出力は、make testの出力と混ざらないようファイルに書き、落ちたときだけ、指摘と失敗の行を出す。同時に走るテストの経過の後ろに埋もれるので、末尾ではなく行を選んで出す。
## 止められたら、どちらも止めて終わるのを待つ。前で走らせると、シェルはそれが終わるまで止める合図を扱わないので、どちらも後ろで走らせて待つ。
## makeは止める合図を子に回さないので、どちらもset -mで別のプロセスグループにして起動し、グループごと止める。子のmakeだけを止めると、その先のmake test-on-simやxcodebuildが残る
CHECK_REST_LOG := $(DERIVED_DATA)/check-rest.log
CHECK_REST_STATUS := $(DERIVED_DATA)/check-rest-status
TEST_STATUS := $(DERIVED_DATA)/test-status
check-test: generate
	@mkdir -p $(DERIVED_DATA) && Tools/check-stamp.sh tree > $(CHECK_TREE)
	@$(MAKE) --no-print-directory warnings
	@rm -f $(CHECK_REST_STATUS) $(TEST_STATUS); \
	stop() { kill -TERM -- -$$rest -$$tests 2>/dev/null; wait; exit $$1; }; \
	trap 'stop 129' HUP; trap 'stop 130' INT; trap 'stop 143' TERM; \
	set -m; \
	$(MAKE) --no-print-directory -j4 lint $(CHECK_TESTS) > $(CHECK_REST_LOG) 2>&1 & rest=$$!; \
	$(MAKE) --no-print-directory test SIM='$(SIM)' & tests=$$!; \
	set +m; \
	wait $$tests; echo $$? > $(TEST_STATUS); wait $$rest; echo $$? > $(CHECK_REST_STATUS)
	@if [ "$$(cat $(CHECK_REST_STATUS))" = 0 ]; then Tools/check-stamp.sh record check "$$(cat $(CHECK_TREE))"; else grep -aE ': error: |\*\*\*|recorded an issue|failed after' $(CHECK_REST_LOG) | tail -40; echo "make checkのlintかmacOSのテストが落ちました。出力は$(CHECK_REST_LOG)"; fi
	@[ "$$(cat $(CHECK_REST_STATUS))" = 0 ] && [ "$$(cat $(TEST_STATUS))" = 0 ]

## ローカルのmainを、make checkとmake testの両方が通った中身のcommitにしか動かさないhookを入れる。worktreeにも効く
hooks:
	ln -sfn ../../Tools/git-hooks/reference-transaction "$$(git rev-parse --git-common-dir)/hooks/reference-transaction"

## メニューの既定の並びを編集するページを、今の項目の名前と既定の並びを入れてDerivedData/menu-editor.htmlに書き出す。書き出したJSONはPackages/SciaCore/Sources/SciaCore/Settings/Resources/menu-defaults.jsonに置く
menu-editor:
	swift run --package-path Tools/MenuEditor --quiet menu-editor Tools/MenuEditor/editor.html $(DERIVED_DATA)/menu-editor.html

clean:
	rm -rf $(DERIVED_DATA) $(PROJECT) Packages/SciaCore/.build Packages/MemoryCache/.build Packages/TextKit2Label/.build Tools/SciaLint/.build Tools/MenuEditor/.build
