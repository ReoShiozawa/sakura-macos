# 個別ライセンス・依存物一覧

この一覧は2026-10-25時点のローカルビルド構成と上流由来ファイルを整理したものです。
リポジトリ全体のライセンスを一律にzlibへ変更するものではありません。
元ファイル内の著作権・ライセンス・同梱条件を優先してください。

## macOSアプリの構成

| 対象 | 使用・同梱方法 | 権利表示・条件 |
| --- | --- | --- |
| Sakura Editor由来の設計・改変箇所 | メニュー順、既定色、動作等の移植 | 本家LICENSEと元ファイルの表示を保持。NOTICE.md参照 |
| CESI::GuessEucOrSjis / charset/codechecker.h由来の判定 | MacEncodingService.mmへ改変移植 | Copyright (C) 2006, 2007, 2018-2022, Sakura Editor Organization。zlib。原実装ではないことをソース・NOTICEへ明記 |
| 移植側の追加コード・文書 | ソースからビルド | LICENSE.macos（zlib）。各権利者に著作権が残る |
| 新しいアプリアイコン | GenerateAppIcon.mmから生成 | 独自の幾何図形。生成コード・出力の提供条件はLICENSE.macos |
| ツールバーのシンボル | AppKitのAPIで実行時取得 | AppleのOS提供素材。画像データを同梱・zlibで再許諾しない |
| AppKit / Foundation / Core Foundation / Core Text / Core Graphics | macOSのシステムフレームワークへ動的リンク | AppleのSDK・OSの条件。フレームワーク本体は同梱しない |
| ICU（libicucore） | macOSのシステムライブラリへ動的リンク | OSが提供するICUを使用。独自ビルドのICUは同梱しない。下記公式ライセンス参照 |
| フォント | 実行環境のフォントを利用 | フォントファイルを同梱しない。利用者が導入するフォントは各条件による |

macOSアプリのビルドでは、以下のWindows向けサブモジュールや配布ZIP、
CHMヘルプ、Windows画像・カーソル・DLLはリンク・同梱しません。
将来依存関係や配布内容を変える場合は、この一覧と必要なライセンス全文を更新してください。
システムライブラリを別の配布物へコピーする許諾を意味しません。

ICUのライセンス資料: https://github.com/unicode-org/icu/blob/main/LICENSE
Appleのシンボル資料: https://developer.apple.com/sf-symbols/
OS内の実際の版はOSごとに異なります。最新ICUの条件を過去のOSへ自動的に適用するものではありません。

## 上流から引き継いだWindows用の資料・配布物

これらは元の開発用ソースツリーに残していますが、Mac版先行公開の方針により
今回の公開用スナップショット・macOSバンドル・リリースには含めません。
以下は除外した継承物の記録であり、権利処理済みという認定ではありません。
今後Windows版を公開する場合に改めて確認します。

| 対象 | ローカルで確認できた表示・同梱文書 | 公開・再配布時の扱い |
| --- | --- | --- |
| src/main/resources/images/ | 上流の画像・アイコン・カーソル | 原本の表示を保持。個々の権利と派生画像の配布条件は別途確認 |
| CHMヘルプ | 上流WikiはGFDLと説明 | ヘルプを同梱する場合は該当版の全文・不変部分等を確認。macOSへ未同梱 |
| externals/diffutils/ | READMEはGPL。bin ZIP内にCOPYING、dep ZIPはDLLとmanifestのみ | diff.exeと依存DLLを一括で「zlib」と扱わない。版別条件・対応ソースの提供義務等を確認 |
| externals/cmigemo-dict/ | READMEはGPL。辞書ZIP内には独立したライセンス全文を確認できず | 辞書の出所・原著者・該当版ライセンス・ソース提供方法の確認が必要 |
| externals/LocaleEmulator/locale-emulator.zip | 上流由来Windowsバイナリ。ライセンス全文はこのZIP内で未確認 | 該当版の出所・依存物・再配布条件を確認するまで独自の配布パッケージへ追加しない |
| installer/externals/bregonig/bron420.zip | bsd_license.txt、perl_license.txt、perl_license_jp.txt、src.7z | ZIP内の各全文と適用範囲を保持。READMEの原著者サイトを参照 |
| installer/externals/universal-ctags/ | READMEはGPL2。ZIP内license/にCOPYING、MinGW runtime、libxml2、PCRE2、jansson、libyamlの文書 | 個別全文と対応ソースの義務を含めて確認。READMEの版付き取得元を保持 |

出所とSHA-256は[素材台帳](docs/ASSET_PROVENANCE.md)を参照してください。
READMEが示す短いライセンス名だけでは再配布条件の履行確認にはなりません。

## 未取得のサブモジュール

元の開発環境で以下は未初期化です。公開用スナップショットにはgitlinkや
`.gitmodules`を含めません。下表は元の固定リビジョンの記録であり、
この文書で未取得ソースのライセンス監査が済んだとは扱いません。

| パス | プロジェクト | 固定コミット |
| --- | --- | --- |
| externals/Onigmo | https://github.com/k-takata/Onigmo | 1d7ee878b3e4a9e41bf9825c937ae6cf0a9cd68c |
| externals/bregonig | https://github.com/k-takata/bregonig | 670b229063a33910e717a9f220d89ce8ab46d790 |
| externals/cmigemo | https://github.com/koron/cmigemo | e0f6145f61e0b7058c3006f344e58571d9fdd83a |
| externals/ctags | https://github.com/universal-ctags/ctags | 5437fa6249e95ec55a5f4944dac28f4f6e46c195 |
| externals/darkmodelib | https://github.com/ozone10/darkmodelib | f7847b514a67f3bf051beda58bcf7d05b3ace564 |
| externals/miniz-cpp | https://github.com/tfussell/miniz-cpp | 052335e4f7773368df07b26d2baedb0e6d4dbd38 |
| tools/vcpkg | https://github.com/microsoft/vcpkg | a0b1c8d3a477c1cb4813d8e127a56961707ca42b |

## 確認資料

- 本家ライセンス案内: https://github.com/sakura-editor/sakura/wiki/License
- アイコンに関する本家の注意: https://sakura-editor.github.io/help/HLP000010.html
- 上流原文のLICENSE: このリポジトリのLICENSE

素材の権利者・該当版・再配布条件が不明な場合は、無断で別ライセンスを付けず、
公開対象を絞るか、権利者に確認するか、権利の明確な実装・素材へ置き換えてください。
