# Sakura macOS — 非公式移植版

サクラエディタの操作感をmacOSへ移植する、開発中のテキストエディタです。
C++20の編集コアと、AppKit / Core TextによるmacOS UIで構成しています。

**本プロジェクトは非公式の改変・移植版です。Sakura Editor Organizationが提供・承認・サポートする製品ではありません。**
Windows版の完全互換品、公式macOS版、安定版ではありません。
名称は移植元を説明するためのもので、ロゴ・名称等の権利を主張しません。

[English](README.en.md) · [開発資料](docs/macos-development.md) ·
[貢献方法](CONTRIBUTING.md) · [セキュリティ](SECURITY.md) ·
[権利表示](NOTICE.md) · [個別ライセンス](THIRD_PARTY_NOTICES.md)

## 移植元と現在の状態

移植元は [sakura-editor/sakura](https://github.com/sakura-editor/sakura)、
開発基準はコミット [b1eef8a24b341cd00299727057642d8581c8638b](https://github.com/sakura-editor/sakura/tree/b1eef8a24b341cd00299727057642d8581c8638b) です。
`core/`、`app/`、`platform/mac/`、`ui/mac/`へ段階的に実装しています。
今回の公開範囲はMac版のみです。Windows用画像・配布ZIP・旧インストーラー・
サブモジュールや上流の全履歴は、この公開用スナップショットへ含めません。
Windows版の配布は保留しています。本家の説明文は
[移植元README](https://github.com/sakura-editor/sakura/blob/b1eef8a24b341cd00299727057642d8581c8638b/README.md)を参照してください。

現在はソースからの開発ビルドを対象とします。Developer ID署名・公証済みの
配布アプリは、この文書では提供を保証していません。今回のリリース表記は「β1.0」、
タグは`v1.0.0-beta.1`です。安定版ではありません。
公開先は[ReoShiozawa/sakura-macos](https://github.com/ReoShiozawa/sakura-macos)です。

## インストール（β1.0）

[Releases](https://github.com/ReoShiozawa/sakura-macos/releases/tag/v1.0.0-beta.1)から
`Sakura-macOS-v1.0.0-beta.1-universal.dmg`を取得し、DMG内の
`SakuraEditor.app`を`Applications`へドラッグしてください。
削除する場合はアプリをゴミ箱へ移動します。設定・復旧データは自動削除しません。

このβ版は**Developer ID未署名・未公証**です。macOSが起動を拒否する場合があります。
出所とSHA-256を確認できないアプリは実行しないでください。Gatekeeperの一律無効化は推奨しません。
必要に応じて[Appleの起動時の安全性に関する説明](https://support.apple.com/ja-jp/102445)を確認するか、
下記手順でソースからビルドしてください。
Universal（arm64 / x86_64）を生成しますが、Intel実機の動作は未検証です。
今回の配布DMGは**macOS 26.0以降**が必要です（動作検証環境: macOS 26.4.1）。
アドホック署名でアプリのリソースを封印しますが、開発者の身元を証明する署名ではありません。

## 主な機能

- 複数文書、2ペイン分割、IME入力、矩形選択、Undo / Redo。
- UTF-8、UTF-16LE / BE、CP932、EUC-JP、ISO-2022-JPの読み書き。
  BOM・改行コードの維持と、文字コードを指定した再読込。
- 行番号、折返し、タブ幅、不可視文字、タイプ別の配色・画面設定。
- Unicodeのリテラル検索、ICU正規表現検索・置換、検索結果の強調表示。
- 非同期Grep、除外フォルダー、結果ジャンプ、候補確認後の複数ファイル置換。
- 軽量な構文色分け・アウトライン、外部変更の検知、未保存内容の復旧バックアップ。
- Windows版を参考にしたメニュー構成・既定配色・ツールバー配置。
  権利条件が未確定の抽出画像は同梱せず、独自アプリアイコンとOS標準シンボルを使います。

詳細と実装上の制約は[開発資料](docs/macos-development.md)に記載しています。

## 重要な制限とデータ保護

実データへ使う前に、必ず別の場所へバックアップしてください。

- 本家とUI・内部処理の完全な等価性はありません。未移植コマンドは無効表示です。
- Windowsの設定、マクロ、プラグイン、Bregonig / Onigmo正規表現の完全互換はありません。
- 文字コードの自動判定、禁則、双方向組版、大規模文書でのIME性能、
  VoiceOver対応は未完成です。
- Grep置換は複数ファイルを一括ロールバックするトランザクションではありません。
  中止しても保存済みの変更は戻りません。既定の`.bak`も独立したバックアップの代替ではありません。
- 復旧データは暗号化せず
  `~/Library/Application Support/SakuraEditor/Recovery/`へ保存します。
  本文や元パスが含まれ、容量・世代管理に制限があります。共有端末や機密文書の利用には注意してください。
- 非公式版のBundle IDを分離しました。古い開発ビルドのUserDefaults設定は自動移行しません。
  復旧データの保存場所は、既存バックアップを失わないよう従来のまま維持しています。

## ビルドと起動

必要なものはmacOS、Xcode Command Line ToolsまたはXcode、CMake 3.21以上、
C++20対応Apple Clangです。macOS SDKのAppKit / Core Text / libicucoreを利用します。
macOSビルドにWindows向けサブモジュールやvcpkgは不要です。
公開準備チェッカーにはPython 3.9以上を使います。CMakeがPythonを検出した場合は
関連チェックもCTestへ追加します。通常のアプリ本体はPythonへ依存しません。

このリポジトリをcloneしたディレクトリで実行します。

```sh
cmake -S . -B build/macos -DCMAKE_BUILD_TYPE=Debug -DBUILD_TESTING=ON
cmake --build build/macos --parallel
ctest --test-dir build/macos --output-on-failure
python3 tools/check_macos_publication.py --bundle build/macos/ui/mac/SakuraEditor.app
open build/macos/ui/mac/SakuraEditor.app
```

公開時の表示名は「Sakura macOS (Unofficial)」です。
ビルドターゲット・ファイル名の`SakuraEditor.app`は互換性のため維持しています。

Universal Binaryを生成する場合:

```sh
cmake -S . -B build/macos-universal -DCMAKE_BUILD_TYPE=Release \
  -DSAKURA_BUILD_UNIVERSAL=ON -DBUILD_TESTING=ON
cmake --build build/macos-universal --parallel
ctest --test-dir build/macos-universal --output-on-failure
```

コアだけを検証する場合は`-DSAKURA_BUILD_MAC_APP=OFF`を指定します。
開発時の確認環境はmacOS 26.4.1 / Apple Siliconです。
古いmacOSでの動作保証、Intel実機での動作検証は未完了です。
Universalの生成とIntel実機での試験は別の確認事項です。

開発用Bundle IDの既定値は`local.unofficial-sakura.macos`です。
署名して配布する場合は、公開者が管理する固有の値を
`-DSAKURA_MAC_BUNDLE_IDENTIFIER=your.reverse.dns.identifier`で指定してください。
本家の組織名・Bundle ID・署名を使用しないでください。

## テストとCI

CTestは編集コア、日本語文字コード、ファイル置換、画面設定、検索、Grep、
カーソル移動、描画を検証します。公開準備チェッカーは権利文書・帰属表示・
バンドル内素材を機械的に確認します。いずれも法的な権利審査や完全互換性の証明ではありません。

`.github/workflows/macos.yml`でDebug / Releaseのビルド・テストを定義しています。
GitHub上での実行結果は実際のActionsを確認してください。
公開用スナップショットにはMac用のワークフローだけを含めます。

## ライセンスと素材

上流の[LICENSE](LICENSE)は改変せず保持しています。
移植側の追加コード・新規文書・独自アイコン生成コードは
[LICENSE.macos](LICENSE.macos)のzlib Licenseで提供する方針です。
追加コードの著作権表示は「Unofficial Sakura macOS port contributors」とし、
本家組織へ新たな著作権が帰属するかのような表示はしません。

これはリポジトリ全体の全ファイルを一律にzlibへ変更するものではありません。
既存の著作者・ファイル別表示・第三者ライセンスが優先します。
[NOTICE](NOTICE.md)、[個別ライセンス一覧](THIRD_PARTY_NOTICES.md)、
[素材の出所と扱い](docs/ASSET_PROVENANCE.md)を必ず確認してください。
上流に含まれるWindows用配布アーカイブ等の全権利監査は未完了のため、公開対象から除外しています。

## 問い合わせ・貢献・公開

不具合・要望は**この非公式版リポジトリ**のIssues / Pull Requestsへお願いします。
公式Windows版の窓口へ、この移植版の不具合を持ち込まないでください。
脆弱性は[SECURITY.md](SECURITY.md)の手順で非公開報告してください。

公開者向けの[公開チェックリスト](docs/RELEASING.md)に、
著作権者確認、素材監査、秘密情報確認、GitHub設定、署名・公証の未完了事項をまとめています。
この文書の追加だけで公開承認・商標許諾・安全性が確定するものではありません。
