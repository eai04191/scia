# 投稿行の描画性能の計測

現行のPostContentBuilderを使い、投稿行の構成処理と、ビュー適用・高さ計算・レイアウトを含む処理を測る手動実行用のツール。
過去の実装や特定のcommitには依存せず、通常のビルドとテストには含めない。

## 計測条件

[prepare.py](prepare.py)が[RenderSettingsBenchmarkTests.swift](RenderSettingsBenchmarkTests.swift)をAppTestsへ配置する。
アプリ本体のPostContentBuilderとPostRenderSettingsを直接使い、ソースの複製や画像の生成は行わない。

通信しない画像ストアと、日本語・英語・リンクを含む24投稿を使う。
各モード100行でウォームアップ後、500行を9回測定する。
BodyTextPreparerの事前生成は使わない。
設定キャッシュが計測中に再生成されないことを検査し、時間は合否に使わない。
設定変更やショートカットの反映は通常のPostRenderSettingsTestsとHeldSettingsChangeTestsが検査する。

[summarize.py](summarize.py)は各モードの中央値と範囲を出力する。
テスト失敗・中断、計測テストの成功記録なし、計測の重複・不足・行数違いは集計しない。
[test_summary.py](test_summary.py)はコード内で作る固定の入力を使い、実測ログには依存しない。

## 保存方針

ログと集計JSONはGit管理外の`DerivedData/RenderSettingsBenchmark/results/`へ固定名で上書きする。
回ごとのファイルやフォルダーは追加しない。
共有が必要な結果はリポジトリ外へ渡す。

## 実行手順

リポジトリ直下で計測用テストを配置し、シミュレーターを借りる。
端末がclaimedなら、借りた端末を`Tools/sim.sh reset '<端末>'`で初期化する。

```sh
python3 Tools/RenderSettingsBenchmark/prepare.py
make generate
Tools/sim.sh acquire
mkdir -p DerivedData/RenderSettingsBenchmark/results
```

以下の`Scia 1`は借りた端末に置き換える。
Debug構成を最適化して測るため、Releaseそのものや実機の結果とは区別する。
AppIntentsの明示リンクは、最適化時に既存のPresetIntentsTestsが参照するシンボルを解決するために必要だった。
失敗した回に前の集計が残らないよう、実行前に集計JSONを削除する。

```sh
rm -f DerivedData/RenderSettingsBenchmark/results/summary.json
xcodebuild -project Scia.xcodeproj -scheme Scia -configuration Debug -destination 'platform=iOS Simulator,name=Scia 1' -derivedDataPath DerivedData/RenderSettingsBenchmark -collect-test-diagnostics never SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule 'OTHER_LDFLAGS=$(inherited) -framework AppIntents' -only-testing:SciaTests/RenderSettingsBenchmarkTests test > DerivedData/RenderSettingsBenchmark/results/run.log 2>&1 && python3 Tools/RenderSettingsBenchmark/summarize.py DerivedData/RenderSettingsBenchmark/results/run.log > DerivedData/RenderSettingsBenchmark/results/summary.json
```

同じビルドで再計測するときは`test`を`test-without-building`に変える。
成否にかかわらず、計測を終えたら配置したテストを削除して端末を返す。

```sh
python3 Tools/RenderSettingsBenchmark/prepare.py clean
make generate
Tools/sim.sh release
```

集計処理のテストだけならシミュレーターは不要。

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tools/RenderSettingsBenchmark -p 'test_*.py'
```
