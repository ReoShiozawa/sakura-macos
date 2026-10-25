# 非公式版の公開・リリース手順

文書・テストの整備は、権利者の許諾、GitHub公開、署名、公証を代行しません。
ソースの公開と、アプリのバイナリ配布は分けて確認します。

今回の方針: 所有者の指示でMac版β1.1を公開する。Windows版は引き続き保留する。
公開用ソースは`bash tools/export_macos_snapshot.sh`で新規ディレクトリへ抽出し、
Windows用素材・配布ZIP・旧installer・サブモジュール・上流全履歴は含めない。
公開用CMakeは`cmake/MacSnapshotRoot.txt`を使い、Win32ビルド経路を含めない。
元の作業ツリー・履歴・素材は削除しない。Mac版はDeveloper ID未署名・未公証で、
アドホック封印のみを行う実験版と明記する。配布DMGの最低OSはmacOS 26.0。

## 1. 公開者が確定する事項

- [ ] GitHub所有者・リポジトリ名を決め、「非公式macOS移植版」を説明欄にも表示する。
- [ ] 追加コードをzlibで提供する権限と著作権者表示を確認する。
      集合名は個人の権利確認・譲渡手続の代替ではない。
- [ ] NOTICE、LICENSE、LICENSE.macos、個別ライセンス、素材台帳を確認する。
- [ ] ソースツリー全体に残るWindows用画像・ヘルプ・配布ZIP・依存物の条件を確認する。
      macOSへの未同梱だけで、GitHub公開時の確認は免除されない。
- [ ] 本家の古いファイル別表示とルートLICENSEの関係で不明な点があれば確認する。
      元の表示を削除したり、法的確認済みと宣伝したりしない。
- [ ] 不明な素材は公開範囲から除外するか、許諾確認・代替を行う。
      除外のために元リポジトリや手元の証拠を破壊しない。

現在の資料には未確認項目が残る。すべてチェック済みとするには公開者の確認が必要。

## 2. 公開内容・秘密情報

- [ ] git diff、git status、git diff --cachedで公開対象を人が確認する。
- [ ] 既存の履歴も含め、トークン、鍵、メール、実文書、ユーザー名・絶対パス、
      クラッシュログ、復旧データ、テスト中のデータを確認する。
- [ ] .gitignoreは履歴や既に追跡中のファイルを消さないことを理解する。
- [ ] build/、dist/、.DS_Store、ローカルworkspace、署名・公証資格情報を含めない。
- [ ] 意図したリポジトリを指していることをgit remote -vで確認する。
      現在のoriginが本家を指していても、この手順は自動変更しない。
- [ ] 未検証のCIバッジや公式配布先を、この非公式版の実績として表示しない。

秘密情報を検出したら公開を止め、資格情報を失効する。
このプロジェクトのチェッカーは秘密情報・全履歴・法的条件を網羅検査しない。

## 3. ローカル検証

古いビルドディレクトリには、以前コピーされた公式アイコンやPNGが残ることがある。
初回配布検証は新しいビルドディレクトリで実施する。

```sh
cmake -S . -B build/release-check -DCMAKE_BUILD_TYPE=Release \
  -DSAKURA_BUILD_UNIVERSAL=ON -DBUILD_TESTING=ON
cmake --build build/release-check --parallel
ctest --test-dir build/release-check --output-on-failure
python3 tools/check_macos_publication.py --bundle build/release-check/ui/mac/SakuraEditor.app
lipo -info build/release-check/ui/mac/SakuraEditor.app/Contents/MacOS/SakuraEditor
```

- [ ] 実機で起動、About、ライセンス表示、日本語IME、文字コード保存、復旧、
      Grep置換の失敗・中止を確認する。重要ファイルを試験に使わない。
- [ ] arm64 / Intel、対象の最古OSを実機等で確認し、未検証の組合せを明記する。
- [ ] テスト結果とコミットを記録する。Universal生成だけでIntel動作確認済みとしない。

## 4. GitHubの設定

### β1.1のDMG候補をローカルで作る

版情報は`cmake/UnofficialVersion.cmake`を正とする。
表示は「β1.1」、タグは`v1.1.0-beta.1`、macOS内部版は`1.1.0` / `1.1.0b1`。
アプリと同梱README・ライセンスを、Applicationsへのリンク付きDMGへ格納する。

```sh
cmake -S . -B build/beta1.1-macos -DCMAKE_BUILD_TYPE=Release \
  -DSAKURA_BUILD_UNIVERSAL=ON -DBUILD_TESTING=ON -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
  -DSAKURA_MAC_BUNDLE_IDENTIFIER=io.github.reoshiozawa.sakura-macos
cmake --build build/beta1.1-macos --parallel
ctest --test-dir build/beta1.1-macos --output-on-failure
python3 tools/check_macos_publication.py --bundle build/beta1.1-macos/ui/mac/SakuraEditor.app
cpack --config build/beta1.1-macos/CPackConfig.cmake -B dist/beta1.1
hdiutil verify dist/beta1.1/Sakura-macOS-v1.1.0-beta.1-universal.dmg
```

このコマンドはDeveloper ID署名・公証・GitHub公開を行わない。
このIDは現在認証を確認した公開者向けの例で、別の公開者は自身のIDへ変える。
Windowsの既存installerは本家名義・URLを含むため、そのまま非公式βとして配布しない。

### リポジトリの設定

- [ ] この非公式版のIssuesとPull Requestsを有効にする。
- [ ] Private vulnerability reportingを有効化し、SECURITY.mdからの報告経路を確認する。
- [ ] デフォルトブランチ保護、レビュー、必要なCI、権限を設定する。
- [ ] macOS workflowが当該リポジトリで動作することを確認する。
- [ ] 上流から引き継いだWindows workflowは既定で非公式版では停止する。
      必要時のみリポジトリ変数ENABLE_LEGACY_WINDOWS_CI=trueを設定し、
      外部サービス、書込権限、ログ出力、依存物を監査してから使う。
- [ ] 自動Publish、リリース作成、サイト公開は別途レビューする。

## 5. バイナリを配布する場合の追加確認

- [ ] SAKURA_MAC_BUNDLE_IDENTIFIERに公開者が管理する固有IDを設定して再ビルドする。
- [ ] 同梱Resources/Licensesと生成アイコンを確認する。
- [ ] 公開者自身のDeveloper ID署名、適切なHardened Runtime設定、公証、
      stapleとGatekeeper検証を実施する。本家名義の署名を使わない。
- [ ] 最終配布物そのもののハッシュ、対応ソース、ビルド環境、変更点を記録する。
- [ ] リリース説明へ非公式・実験段階・既知の制限・データ保護上の注意を記載する。
- [ ] 使用した各依存物の条件に応じ、ライセンス全文・対応ソース等を添付する。

現状の開発ビルドは、この署名・公証済み配布物ではない。
利用者にGatekeeperの一律無効化を要求しない。

参考: https://developer.apple.com/developer-id/

## β1.0の公開記録（2026-10-24）

- 公開先: https://github.com/ReoShiozawa/sakura-macos
- プレリリース: https://github.com/ReoShiozawa/sakura-macos/releases/tag/v1.0.0-beta.1
- 対応ソース: c96a45d42949a71f668599a4cdb7baba8174f414
- 最終DMGはGitHub Actionsで作成し、同じコミットのDebug / Release CIが成功。
- 公開URLから認証なしでDMGとSHA256SUMS.txtを取得し、ハッシュとhdiutil検証を確認。
- 非公開の脆弱性報告を有効化。Windows版は利用者の指示により保留。
- 公開用Git checkoutは手元の`build/macos-public-source.Y8cDX2`。
  元の開発checkoutのoriginは本家のまま変更していない。
  今後の更新は公開用checkout、または公開先からcloneした作業ツリーで行い、
  元のWindows用素材・履歴を誤ってpushしないこと。

機械可読な検証記録は`docs/releases/v1.0.0-beta.1-verification.json`を参照。
この実施記録は手元の開発ツリーに保存し、公開済みタグやDMGを後から変更しない。
