# 素材の出所・処理記録

確認日: 2026-10-24。基準上流コミット:
`b1eef8a24b341cd00299727057642d8581c8638b`。

## 現在macOSへ同梱するもの

- アプリアイコン: `ui/mac/resources/GenerateAppIcon.mm`に記述した独自の幾何図形。
  紺・紫の角丸タイルと折り目付き文書を描く。本家の桜ロゴ・抽出ピクセル・
  スクリーンショット・フォント字形・SF Symbolsの書き出し画像を使わない。
  ビルド時にiconsetとUnofficialSakura.icnsを生成する。LICENSE.macosを適用する。
- ツールバー: AppKitのシステムシンボルを実行時に取得する。
  OSの図案を本プロジェクトの著作物として表示せず、画像ファイルを同梱しない。
- フォント: OSまたは利用者の環境にあるものを参照する。フォントファイルを同梱しない。
- 権利表示: LICENSE、LICENSE.macos、NOTICE.md、THIRD_PARTY_NOTICES.md、
  この文書をアプリのResources/Licensesへコピーする。

## 以前の開発ビルドで使っていた派生コピー

以前のtoolbar PNGは上流`src/main/resources/images/my_icons.bmp`由来、
SakuraEditor.icnsは本家アイコン由来の変換コピーとして扱う。
厳密な抽出・変換手順と個別の再配布許諾は確定できていない。
公開準備に伴い、これらの**追加コピー**はビルド・ソース公開対象から外し、
ローカルの無視対象build/以下へ退避した。元のWindows用素材は変更していない。

これは侵害であるとの断定でも、原本が無条件で再配布可能との判断でもない。
本家の[アイコンの注意事項](https://sakura-editor.github.io/help/HLP000010.html)は
カスタム画像の権利確認を促している。ルートのzlibだけから、別由来の素材まで
自動的に許諾されたと推定しない。

退避前のパスとSHA-256（画像データそのものはこの文書に含めない）:

```text
f57bc00d4c8d2c6c440bc1afc949dfaa02ca33b639133d0b42a8fb260de410a4  ui/mac/resources/SakuraEditor.icns
f6e2dbcdfab2d7b67963947dde05118d1bd04ddf806a983a74ad591bc6e14a8b  ui/mac/resources/toolbar/clear_search.png
5538817c582bc46ddc0504a3126e5b655324d25c947af823f3b8d30341ce4682  ui/mac/resources/toolbar/command_list.png
d71523e3377d444e41ddac698baf2527c6bf73b9dd7c0f9872a5a58d49f46192  ui/mac/resources/toolbar/common_settings.png
240f3387eaf3a14346318d83776aee056087b5ffb440a611a6f37d86de85ca30  ui/mac/resources/toolbar/find.png
6e8abe770b1b235455fd451965b714f4314b74d963acfe1ac1b15939e8e7aa43  ui/mac/resources/toolbar/find_next.png
95de1d38c7f609fa5238e2df8889128314699f46916b10be00a7cd4e7fb2c5eb  ui/mac/resources/toolbar/find_previous.png
4c0a5a89ff29cbaa9b9bd04efc9b87c82903ecfadf0f19f025143a863e91a454  ui/mac/resources/toolbar/grep.png
7778707de8cc1e887560c4931bbdb2a92de33d1808d171991af13ca31743dbba  ui/mac/resources/toolbar/history_back.png
340db6f01e92f51f6a54161e20edc866e769e8b2d917a13aed0550ae04f344f6  ui/mac/resources/toolbar/history_forward.png
83fa5b76c508255a20cdda288e9500ba91f4ebbaff69fbb33c3832be78234278  ui/mac/resources/toolbar/new.png
bf1cdbf52eb0001934e52d846f8a3ffb428e1e75636824d6f2e3d58aa8b1fc24  ui/mac/resources/toolbar/open.png
c144b8a5e33cd7b4d96243ce36ba4988ee3dbc6ec5d180d6d1434696f7615381  ui/mac/resources/toolbar/outline.png
161de8993aac08cf54eb861ece7fdd845f935d43c1afeff8460eef916979e34b  ui/mac/resources/toolbar/redo.png
1072c54a47e8fc83639a5264ff25ac940e11674c194db750abe3b6cc75ba6872  ui/mac/resources/toolbar/replace.png
13814f8d29ff6e8d73daa9d903c4259343915767aa55c8831018ce6efeedeef8  ui/mac/resources/toolbar/save.png
9cb4906742bdb7905e073abcf885d8004859a255d21a14ba4740e14d0c05fc9f  ui/mac/resources/toolbar/save_as.png
834c468fdf81d15249b1e0cfc6cb62632a889796fd0e67d68d86b9382a70e24d  ui/mac/resources/toolbar/split.png
ff67fe06d36db4599218e34743ecb512f627cf8995b887fb904b03589491bab7  ui/mac/resources/toolbar/type_list.png
a40e88d741cc9bd9dc6e542118822ae59f1e30c87c169061424dd60134d81e8f  ui/mac/resources/toolbar/type_settings.png
b5611c156b747e2502bc3fda8c3a6ba3de7b95ae88dbdf5a579b71f413ced15b  ui/mac/resources/toolbar/undo.png
```

既存のbuild/内の古いappにもコピーが残り得るため、配布検査は新しい
ビルドディレクトリで行う。公開準備チェッカーは予期しないバンドル内素材を検出する。

## ソースツリーに残る上流の素材とアーカイブ

`src/main/resources/images/`のWindows画像・カーソル、
ヘルプ、次のZIPは上流からの継承物であり、今回の新規アイコンとは別物である。
元の開発用ツリーには保持するが、Mac版先行公開用のソーススナップショットと
アプリには含めない。将来Windows版を公開する場合には確認対象となる。
出所は各ディレクトリのREADME、.gitmodules、上流履歴を参照する。
LocaleEmulatorの該当版の取得元・全依存条件は未確定。
個別条件と未確認項目は[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)を参照。

```text
808ff584426d52cc775ad6406da00622f454be95bd4c8fbca42eef4b7235ad5c  externals/LocaleEmulator/locale-emulator.zip
1aa0e7eb388e68a4b0abea213a74291f17c605a69dac4f51b46f8463f0f7f39b  externals/cmigemo-dict/cmigemo-dict-cp932.zip
969515a4043043c25b8ce5d86642880c5902180039e8c9a7a538787da1a30c6c  externals/cmigemo-dict/cmigemo-dict-utf-8.zip
6d64ee291c9b49a2841dbccea9795140802ff6b73fd2f4848635bbc974dc5a9c  externals/diffutils/diffutils-2.8.7-1-bin.zip
9b64b20aa9e0b5be1045b4bdbd182e1f47b2136a55985083df0eaac3673b91a1  externals/diffutils/diffutils-2.8.7-1-dep.zip
15f58dd292aa6fc8fd592fa97a75d58b5680ddf7aa66ba10a2dd5c9f0ee159c1  installer/externals/bregonig/bron420.zip
ed1bdabe977980db2f5bd8f0a0fa11963f14604b5af92f31db26875bf342efd8  installer/externals/universal-ctags/ctags-v6.1.0-x64.zip
3d95b1fe689be7c414d506bb95400dd9d0e10fef7975ded01c92036c361db974  installer/externals/universal-ctags/ctags-v6.1.0-x86.zip
```

ハッシュは手元のファイルを識別するもので、原著作者・許諾・無害性を証明しない。
署名・許諾確認・秘密情報監査の完了は、この台帳だけから主張しない。
