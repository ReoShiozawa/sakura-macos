# サクラエディタ macOS 移植 基本設計書

- 文書ID: SAKURA-MAC-ARCH-001
- 版: 0.1
- 状態: 基本設計案
- 対象: `sakura-editor/sakura` の現行 `master`
- 想定製品名: Sakura Editor for macOS（仮称）

## 1. 概要

本計画では、Windows版サクラエディタの機能・操作体系・設定資産を可能な限り継承しつつ、macOS上でネイティブに動作するテキストエディタを開発する。

移植方式は、Windows実行ファイルをWine等で動かす方式でも、全機能をSwiftで書き直す方式でもない。既存C++コードから文書モデル、レイアウト、編集、検索、文字コード、コマンド体系を移植可能なコアとして分離し、その上にAppKit製のmacOSフロントエンドを構築する。

採用する基本構成は次のとおりである。

1. 共通コア: C++20
2. macOS UI: Objective-C++ + AppKit
3. 描画: Core Text + Core Graphics
4. 日本語入力: `NSTextInputClient`
5. ビルド: CMakeを共通基盤とし、macOSアプリ生成と署名はXcodeを利用
6. 実行モデル: 単一アプリ・複数文書・複数ウィンドウ
7. 重い処理: 必要に応じてXPCワーカーへ分離
8. 配布: 初期段階はMac App Store外のDeveloper ID配布

## 2. 背景と現状分析

現行サクラエディタはC++20で実装されたWindows向けアプリケーションであり、主ビルド環境はMSVC、MinGW対応は実験的である。構成は、共有状態を管理する制御プロセスと、各編集ウィンドウに対応する編集プロセスからなる二プロセス方式である。[S1]

主要な文書機能は、`CEditDoc`の下に次の要素として集約されている。

- `CDocLineMgr`: 論理行の保持
- `CLayoutMgr`: 折り返し、タブ展開、表示行管理
- `CDocEditor`: 編集、Undo、Redo
- `CDocFile`: ファイル情報、文字コード情報
- `CDocFileOperation`: 読込、保存、クローズ
- `CDocType`: タイプ別設定
- `CViewCommander`: 機能コードに基づくコマンド実行

一方で、文書層にも`BOOL`、`LOGFONT`、`HBITMAP`、`WCHAR`等のWin32型が存在し、`CDocLineMgr`と`CLayoutMgr`も直接`Windows.h`を読み込んでいる。このため、画面だけをAppKitへ置き換えてビルドすることはできない。[S2][S3]

現行CMake定義も`WIN32`実行ファイルを前提としており、macOSアプリバンドルやObjective-C++ターゲットは存在しない。[S4]

さらに、Windowsでは`wchar_t`がUTF-16の16ビット単位として使われるのに対し、Appleプラットフォームの`wchar_t`は32ビットである。既存の`wchar_t`依存コードをそのまま移植すると、文字列長、位置、サロゲートペア、バイナリ互換性が変化するため、内部文字型の明示化が必須である。[S5]

## 3. 目的

### 3.1 機能目的

macOS版で次を実現する。

- 高速なテキスト編集
- 日本語IMEによる安定した入力
- UTF-8、UTF-16、Shift_JIS、EUC-JP、ISO-2022-JP等の読込・保存
- CRLF、LF、CRの維持と変換
- 検索、置換、正規表現、Grep
- タイプ別設定と色分け
- 矩形選択、複数選択、折り返し、タブ表示
- Undo、Redo、バックアップ、自動保存、外部変更検知
- サクラエディタ由来のコマンド体系とキーカスタマイズ
- Windows版設定の段階的インポート
- Apple SiliconおよびIntel Mac向けのUniversal Binary

### 3.2 開発目的

- Windows版とmacOS版で文書コアを共有する
- Windows版の既存挙動を自動テストで保護する
- OS依存コードを明確なインターフェース境界へ隔離する
- 将来のLinux対応も妨げない構造にする
- 上流へ段階的に提案可能な差分単位で開発する

## 4. 対象外

初期リリースでは次を対象外とする。

- Windows用DLLプラグインのバイナリ互換
- WSH、COM、ActiveXに依存するマクロの完全互換
- Windows版と同一ピクセル配置のUI
- Windowsレジストリ連携
- システムトレイ常駐
- Mac App Store配布
- Linux版UI
- 既存Windows版の廃止

## 5. 設計原則

### 5.1 上流互換を優先する

macOS専用フォークで既存クラスを大量改変するのではなく、先にWindows版でも有効なOS依存分離を行う。共通化できる変更は上流へ戻せる粒度に保つ。

### 5.2 文字位置の単位を明示する

ポータブル層では`wchar_t`を使用せず、次を標準とする。

```cpp
using SakuraChar = char16_t;
using SakuraString = std::u16string;
using TextOffset = std::uint64_t;
```

文書内の基本位置はUTF-16コード単位で保持する。macOSの`NSString`も長さと範囲をUTF-16コード単位で扱うため、AppKit境界との変換が単純になる。[S6]

ただし、カーソル移動、削除、単語選択では、コード単位とユーザーが知覚する文字を区別する。絵文字、異体字セレクタ、結合文字を途中で分断しないため、書記素クラスタ単位の移動APIを別に設ける。

### 5.3 コマンドをUIから独立させる

既存の`EFunctionCode`とコマンド分類を維持し、メニュー、キー入力、マクロ、ツールバーから同一の`CommandBus`を呼び出す。

### 5.4 macOS標準操作を尊重する

保存、復帰、Undo、ウィンドウ管理、フルスクリーン、アクセシビリティ、メニュー構造はmacOS標準へ合わせる。一方、サクラエディタ独自の操作を失わないよう、「macOS標準」と「サクラ互換」のキーマップを用意する。

### 5.5 重い処理をUIスレッドから分離する

Grep、巨大ファイル読込、文字コード判定、タグ生成、外部コマンド実行はキャンセル可能な非同期タスクとする。クラッシュ影響や権限分離が必要な処理はXPCワーカーへ移す。

## 6. 全体アーキテクチャ

```text
┌──────────────────────────────────────────────┐
│              Sakura Editor.app               │
├──────────────────────────────────────────────┤
│ macOS UI                                     │
│ AppDelegate / Document / WindowController    │
│ EditorView / Menu / Preferences / Dialog     │
├──────────────────────────────────────────────┤
│ Application Layer                            │
│ DocumentSession / CommandBus / AppState      │
│ Workspace / Recovery / RecentFiles           │
├──────────────────────────────────────────────┤
│ Portable Core (C++20)                        │
│ TextBuffer / LayoutEngine / EditEngine       │
│ Undo / Search / Encoding / TypeConfig        │
│ FunctionCode / Macro API / Settings Model    │
├──────────────────────────────────────────────┤
│ Platform Abstraction                         │
│ FileSystem / Clipboard / FileWatcher         │
│ Dispatcher / Dialog / Process / Print        │
├──────────────────────────────────────────────┤
│ macOS Adapter                                │
│ Foundation / AppKit / Core Text / XPC        │
└──────────────────────────────────────────────┘
             │                    │
             ├── GrepWorker.xpc   └── PluginHost.xpc
```

Windows版は同じPortable CoreとApplication Layerを利用し、既存Win32 UIとWindows Adapterを接続する。

## 7. レイヤー設計

### 7.1 Portable Core

Portable CoreはWin32型、AppKit型、GUIオブジェクトを参照しない。

#### TextBuffer

既存`CDocLineMgr`と`CDocLine`を基礎に、論理行と改行コードを保持する。

主な責務:

- 行挿入、削除、置換
- 任意位置アクセス
- 行番号と絶対オフセットの相互変換
- ブックマーク
- 編集シーケンス管理
- メモリリソース管理
- 巨大文書向け遅延読込拡張

初期実装では既存の行連結構造を維持し、移植完了後にPiece TableまたはRopeへの変更可否を別RFCで判断する。移植とデータ構造刷新を同時に行わない。

#### LayoutEngine

既存`CLayoutMgr`を基礎に次を処理する。

- 論理行から表示行への変換
- 折り返し
- タブ展開
- 禁則処理
- CSV、TSV表示
- 論理位置と表示位置の変換
- 色分け区間
- 描画対象行の差分計算

フォント計測、ピクセル幅、描画APIはCoreから除外し、`ITextMetrics`を介して取得する。

```cpp
class ITextMetrics {
public:
    virtual float advance(SakuraChar ch, const FontStyle&) const = 0;
    virtual float lineHeight(const FontStyle&) const = 0;
    virtual ~ITextMetrics() = default;
};
```

#### EditEngine

- 挿入、削除、置換
- 矩形編集
- インデント
- 大文字・小文字変換
- 行操作
- Undo、Redo
- 編集トランザクション
- 変更通知

#### SearchEngine

- 通常検索
- 単語検索
- 正規表現検索
- 前方・後方検索
- 複数ファイルGrep
- 置換プレビュー
- キャンセル
- 結果ストリーミング

正規表現は既存Onigmo系の意味を可能な限り維持する。Windows DLLラッパーへ直接依存せず、`IRegexEngine`の実装としてリンクする。

#### EncodingService

文字コード判定と変換を分離する。

```cpp
class IEncodingDetector {
public:
    virtual DetectionResult detect(std::span<const std::byte> data,
                                   Encoding preferred) = 0;
};

class ITextCodec {
public:
    virtual DecodeResult decode(std::span<const std::byte> data,
                                Encoding encoding) = 0;
    virtual EncodeResult encode(std::u16string_view text,
                                Encoding encoding,
                                BomPolicy bom) = 0;
};
```

判定順は次を基本とする。

1. BOM
2. 明示指定
3. ファイル履歴
4. 妥当なUTF-8
5. ユーザー既定文字コード
6. 日本語文字コードのヒューリスティック
7. フォールバック

自動判定には必ず誤判定の可能性があるため、判定結果、候補、信頼度をUIから確認できるようにする。現行でもUTF-8とShift_JISの判定が競合する事例が報告されているため、検出器と変換器を交換可能にしておく。[S7]

初期候補は、既存CESIロジックを移植し、Windows変換API部分をICU4C等のクロスプラットフォーム変換器へ置き換える方式とする。

### 7.2 Application Layer

#### DocumentSession

1文書につき1インスタンスを生成し、次を所有する。

- TextBuffer
- LayoutEngine
- EditEngine
- UndoManager
- FileMetadata
- EncodingState
- TypeConfiguration
- SelectionSet
- ViewState
- DirtyState

`NSDocument`や`CEditWnd`はDocumentSessionを所有するだけで、編集ロジックを持たない。

#### CommandBus

```cpp
struct CommandContext {
    DocumentSession* document;
    ViewSession* view;
    CommandSource source;
};

class ICommandHandler {
public:
    virtual CommandResult execute(CommandContext&, const CommandArgs&) = 0;
};
```

既存`EFunctionCode`は安定IDとして維持する。メニュー表示名やショートカットは設定層で管理する。

#### ApplicationState

現行の`CControlProcess`、`CShareData`、共有メモリが担う役割のうち、macOS版で必要なものをプロセス内サービスとして再構成する。

- 共通設定
- タイプ別設定
- 最近使ったファイル
- 開いている文書一覧
- ウィンドウ復元
- アプリ全体のコマンド
- CLIからのOpen Request

### 7.3 Platform Abstraction

次のインターフェースを定義する。

```text
IFileSystem
IClipboard
IFileWatcher
IDispatcher
IPlatformDialogs
IProcessLauncher
ISettingsStore
IRecentFileStore
IPrintService
IPathResolver
IApplicationIPC
```

Portable Coreでは`HWND`、`HANDLE`、`HBITMAP`、`LOGFONT`、`BOOL`、`DWORD`、`LPCWSTR`を使用しない。

### 7.4 macOS UI

#### SakuraDocument

`NSDocument`のサブクラスとして実装し、ファイル読込、保存、復帰、編集状態、ウィンドウ制御をmacOS文書アーキテクチャへ接続する。`NSDocument`は文書データの読書き、ウィンドウコントローラ、Undo、保存確認を扱う文書ベースアプリの基盤である。[S8]

責務:

- URLとDocumentSessionの関連付け
- 非同期読込・保存
- 編集済み状態通知
- 自動保存・復旧連携
- 外部変更時の競合処理
- 文字コード指定付き保存

#### SakuraWindowController

- タブまたは複数ウィンドウ
- 分割ビュー
- ツールバー
- ステータスバー
- アウトライン
- Grep結果
- ミニマップは将来拡張

#### SakuraEditorView

`NSView`を継承した独自テキストビューとする。既存レイアウトモデル、矩形選択、巨大文書性能、表示行単位描画を維持するため、全面的な`NSTextView`採用は行わない。

日本語IMEとの連携には`NSTextInputClient`を実装する。AppKitは、独自テキストビューを作る場合に`NSView`へ同プロトコルを実装する方式を提供している。[S9]

必要メソッド:

- marked textの設定と解除
- marked range
- selected range
- attributed substring
- first rect for character range
- character index for point
- insert text
- command selector処理

IME変換中の文字列は確定テキストと分けて保持し、Undo履歴へは確定時に一操作として登録する。

#### RenderEngineMac

- Core Textでグリフ生成と文字幅計測
- Core Graphicsで背景、選択、罫線、不可視文字を描画
- 可視行だけを描画
- 行キャッシュとグリフキャッシュ
- Retinaスケール対応
- ダークモード
- アクセシビリティ属性提供

初期段階ではMetalを使用しない。Core Text描画で性能不足が確認された場合のみ、描画バックエンドを追加する。

## 8. プロセスとIPC

macOS版は原則として単一アプリプロセスで複数文書を管理する。

```text
Sakura Editor.app
 ├── Document A
 ├── Document B
 ├── Window 1
 ├── Window 2
 └── ApplicationState
```

現行の「1編集ウィンドウ1プロセス」は採用しない。macOSの文書・ウィンドウ・メニュー・復元機構と自然に統合し、共有メモリ依存を除くためである。

次は別プロセス化を検討する。

- `GrepWorker.xpc`: 複数ファイル検索
- `PluginHost.xpc`: 外部プラグイン
- `IndexWorker.xpc`: タグ、アウトライン、インデックス
- `CrashRecoveryService`: 必要性を検証後に判断

CLI用の`SakuraCLI`は`IApplicationIPC`を介し、起動済みアプリへ次を送信する。

```json
{
  "command": "open",
  "path": "/path/to/file",
  "line": 120,
  "column": 8,
  "encoding": "auto"
}
```

## 9. ファイルI/O

### 9.1 読込

```text
URL取得
→ 権限確認
→ バイト列読込
→ BOM検査
→ 文字コード判定
→ UTF-16へ変換
→ 改行解析
→ TextBuffer構築
→ タイプ別設定決定
→ 初回レイアウト
→ 表示
```

巨大ファイルでは、全体読込を避けるため、将来はメモリマップと部分デコードを導入できる構造にする。ただしMVPでは既存挙動を優先し、通常読込を実装する。

### 9.2 保存

```text
DocumentSessionスナップショット
→ 改行コード適用
→ 指定文字コードへ変換
→ 変換不能文字検査
→ 一時ファイルへ書込
→ fsync相当処理
→ 原子的置換
→ メタデータ更新
```

変換不能文字がある場合は、黙って`?`へ置換しない。対象位置を示し、次から選択させる。

- 保存中止
- UTF-8へ変更
- 代替文字へ置換
- 該当箇所を確認

### 9.3 外部変更

ファイル監視により、外部変更、削除、移動を検出する。

- 未編集なら自動再読込を選択可能
- 編集済みなら差分比較
- 同一内容なら通知を抑制
- 保存競合時は上書き、別名保存、再読込を選択

## 10. UI仕様

### 10.1 メニュー

macOS標準順に配置する。

```text
Sakura Editor
File
Edit
Selection
Search
Convert
Tools
Window
Help
```

既存サクラエディタの機能は、名称を維持しつつmacOS標準カテゴリへ再配置する。

### 10.2 キー割当

初回起動時に次のプリセットを選択可能にする。

- macOS標準
- サクラエディタ互換
- VS Code風
- カスタム

`Command`はアプリ操作、`Option`は単語移動、`Control`は互換操作を基本とする。キー割当は物理キーコードではなく、修飾キーと論理キーの組み合わせとして保存する。

### 10.3 タブとウィンドウ

- macOSネイティブタブを基本とする
- 1文書1ウィンドウを許可
- ウィンドウ間移動を許可
- 分割表示は同一DocumentSessionを複数ViewSessionで参照
- 各ViewSessionは独立したスクロール、カーソル、選択を持つ

### 10.4 ステータスバー

- 行、桁
- 選択文字数
- 文字コード
- 改行コード
- 挿入・上書き
- タブ幅
- タイプ別設定
- ズーム
- 文字コード判定状態

## 11. 設定と互換性

### 11.1 保存場所

標準設定はApplication Support配下に保存する。

```text
~/Library/Application Support/SakuraEditor/
├── settings.json
├── keybindings.json
├── types/
├── themes/
├── macros/
├── plugins/
├── backups/
└── recovery/
```

`UserDefaults`は小規模なUI状態に限定し、主要設定は差分管理しやすいUTF-8 JSONとする。

### 11.2 Windows設定インポート

インポート対象:

- 共通設定
- タイプ別設定
- キー割当
- 色設定
- 強調キーワード
- マクロ登録
- Grep除外設定

変換不能項目は無視せず、インポート結果レポートへ記録する。

Windows固有パスは次の順で解決する。

1. 同名ファイルをインポート元周辺から探索
2. ユーザーに再指定を依頼
3. 無効設定として保持

### 11.3 テーマ

既存`.col`形式の読込を提供し、内部ではOS非依存のテーマモデルへ変換する。ライト、ダーク双方の色を持てるよう拡張する。

## 12. マクロとプラグイン

### 12.1 マクロ

段階的に実装する。

MVP:

- キーボードマクロ
- コマンド記録・再生
- コマンドID呼出し
- 選択範囲・カーソル・文書文字列API

次段階:

- JavaScriptCoreを用いたJavaScriptマクロ
- 既存`.js`マクロの互換レイヤー
- 非同期処理
- ファイルアクセス権限制御

非対応:

- ActiveXObject
- COMオートメーション
- WSH固有オブジェクト
- Windows DLL呼出し

### 12.2 プラグイン

Windows DLLプラグインをmacOSで直接読み込まない。

新プラグインAPIは次を満たす。

- バージョン付きAPI
- コマンド登録
- メニュー登録
- 文書変更通知
- 選択範囲取得・更新
- 設定スキーマ
- タイムアウト
- クラッシュ分離
- 権限宣言

初期案は、PluginHostプロセスとJSON-RPCで通信する方式とする。これにより、Swift、JavaScript、Python、Rust等から実装しやすくする。

## 13. ビルド構成

### 13.1 ディレクトリ案

```text
sakura/
├── CMakeLists.txt
├── core/
│   ├── text/
│   ├── layout/
│   ├── edit/
│   ├── search/
│   ├── encoding/
│   ├── command/
│   └── settings/
├── app/
│   ├── document/
│   ├── workspace/
│   └── recovery/
├── platform/
│   ├── common/
│   ├── win/
│   └── mac/
├── ui/
│   ├── win/
│   └── mac/
├── workers/
│   ├── grep/
│   └── plugin/
└── tests/
```

既存ディレクトリを一度に移動せず、最初は新ターゲット側から既存ソースを選択的に参照し、移植完了後に整理する。

### 13.2 CMakeターゲット

```text
sakura_core
sakura_app
sakura_platform_common
sakura_platform_win
sakura_platform_mac
sakura_ui_win
sakura_ui_mac
sakura_grep_worker
sakura_tests
```

macOSターゲットでは`CXX`と`OBJCXX`を有効にし、`MACOSX_BUNDLE`でアプリを生成する。XcodeプロジェクトはCMakeから生成し、署名、Entitlements、アーカイブはXcode設定へ接続する。

### 13.3 アーキテクチャ

Releaseは`arm64`と`x86_64`を含むUniversal Binaryとする。アプリ本体だけでなく、XPCサービス、プラグインホスト、外部ライブラリも両アーキテクチャで構築する必要がある。[S10]

## 14. セキュリティと配布

初期配布はDeveloper ID署名済みアプリをDMGまたはZIPで提供する。

必須項目:

- Hardened Runtime
- コード署名
- 署名済みXPCサービス
- 署名済み外部ライブラリ
- Notarization
- Stapling
- 更新物の署名検証
- クラッシュログから文書内容を除外
- マクロ・プラグインの権限表示

Appleの公証では、Developer ID署名、Hardened Runtime、適切なタイムスタンプ等が要求される。[S11]

Mac App Store対応は後段とする。任意ファイルへのアクセス、外部コマンド、マクロ、プラグインとの整合性を確認した後、Sandbox版を別配布するか判断する。

## 15. テスト設計

### 15.1 単体テスト

- TextBuffer
- 改行処理
- UTF-16位置変換
- サロゲートペア
- 結合文字
- レイアウト
- タブ
- 禁則
- Undo、Redo
- 検索、置換
- 正規表現
- 文字コード変換
- 設定変換

### 15.2 差分テスト

Windows版と共通コアへ同一入力を与え、次を比較する。

- 編集後テキスト
- カーソル位置
- 選択範囲
- Undo結果
- 検索結果
- レイアウト行数
- 文字コード判定
- 保存バイト列

### 15.3 macOS統合テスト

- 日本語IME
- ライブ変換
- 絵文字入力
- コピー・貼付
- ドラッグ＆ドロップ
- ファイル移動
- 外部変更
- ウィンドウ復元
- 分割表示
- フルスクリーン
- ダークモード
- VoiceOver
- キーボードのみの操作

### 15.4 ファジング

- 文字コード検出
- 不正UTF-8
- 壊れたUTF-16
- 正規表現入力
- 巨大な1行
- 極端に多い行数
- 設定ファイル読込
- プラグインメッセージ

## 16. 非機能要件

### 16.1 安定性

- 保存時に原子的置換を使用する
- クラッシュ後に未保存文書を復元できる
- 変換不能文字を黙って破棄しない
- 外部変更との競合を検出する
- ワーカー停止が編集画面を終了させない

### 16.2 性能

暫定評価条件:

- 100MB級テキストを開いて編集可能
- 100万行級文書でスクロール可能
- 通常入力時にUIスレッドを長時間占有しない
- 可視範囲外を毎フレーム再レイアウトしない
- Grep結果を全件完了前から表示する
- 取消操作を受け付ける

数値目標は性能ベースライン取得後に確定する。

### 16.3 アクセシビリティ

- VoiceOverで本文、選択、行番号を取得可能
- メニュー項目にアクセシビリティ名を設定
- 色だけに依存しない状態表示
- コントラスト設定
- キーボードだけで主要機能を操作可能

## 17. 移植マイルストーン

### M0: 法務・基準確定

完了条件:

- ルートライセンスと個別ファイルヘッダーを確認
- プロジェクト名、アイコン、商標の扱いを上流へ確認
- Windows版の基準テストを保存
- 対応機能一覧を確定

### M1: ポータビリティ基盤

完了条件:

- `SakuraChar`と`SakuraString`を導入
- Portable Coreから`Windows.h`を排除
- Win32型ラッパーを削減
- Windows CIが継続成功
- macOSでheadless coreがコンパイル可能

### M2: 文書コア

完了条件:

- 読込
- 表示用レイアウト
- 挿入・削除
- Undo・Redo
- 保存
- 文字コード
- 改行維持
- headlessテスト

### M3: macOS最小エディタ

完了条件:

- `.app`起動
- 複数文書
- `NSDocument`
- 独自EditorView
- IME
- メニュー
- コピー・貼付
- FinderからOpen

### M4: 主要機能

完了条件:

- 検索・置換
- Grep
- タイプ別設定
- 色分け
- 矩形選択
- 分割表示
- 外部変更検知
- バックアップ・復元

### M5: 互換機能

完了条件:

- Windows設定インポート
- テーマインポート
- キーボードマクロ
- JavaScriptマクロ基盤
- CLI
- PluginHost試験実装

### M6: 配布品質

完了条件:

- Universal Binary
- Developer ID署名
- Hardened Runtime
- Notarization
- 自動テスト
- アクセシビリティ確認
- クラッシュ復旧
- リリース文書

## 18. 主なリスク

### 18.1 個別ソースのライセンス表記

ルートはzlib Licenseだが、一部の古いソースには別の注意書きが残っている。移植開始前に、対象ファイルの利用条件、再配布、名称利用を上流へ確認する。[S12]

対策:

- ファイル単位のライセンス一覧を生成
- SPDX表記の有無を確認
- 不明ファイルは書き直すか、許諾確認まで利用しない
- 製品内に原著作者表示とライセンスを同梱

### 18.2 `wchar_t`依存

対策:

- `char16_t`へ明示的に移行
- サイズ依存コードを静的解析
- オフセット変換テスト
- API境界だけでNSString、WCHARへ変換

### 18.3 レイアウトとWin32描画の密結合

対策:

- `ITextMetrics`導入
- 描画命令とレイアウト計算を分離
- Windows描画結果をゴールデンテスト化
- Core Textとの差異を許容範囲として定義

### 18.4 日本語IME

対策:

- 最初期から`NSTextInputClient`を実装
- marked textを独立状態として管理
- ライブ変換を含むテストケースを作成
- IME確定前に文書モデルへ恒久反映しない

### 18.5 文字コード判定差

対策:

- 検出と変換を別インターフェース化
- 実ファイルコーパスを作成
- Windows版との比較テスト
- 判定候補と信頼度を表示
- ユーザー既定を明示的に反映

### 18.6 プラグイン互換

対策:

- Windows DLL互換を約束しない
- コマンドAPIの意味互換を優先
- プラグインを別プロセス化
- APIバージョンと権限モデルを定義

### 18.7 上流追従

対策:

- 大規模フォルダ移動を後回しにする
- 変更を小さなPR単位に分ける
- Windows版挙動を変えない抽象化から始める
- macOS専用コードを別ディレクトリへ隔離

## 19. 採用判断

| 項目 | 採用 | 理由 |
|---|---|---|
| UI | AppKit | macOS標準操作、IME、文書管理との統合 |
| 言語 | C++20 + Objective-C++ | 既存資産再利用とAppKit接続の両立 |
| Swift全面移植 | 不採用 | コア再利用が困難で機能差分が拡大する |
| Qt全面移植 | 不採用 | 移植速度は高いがmacOS標準挙動と上流統合で不利 |
| Wineラッパー | 不採用 | ネイティブ操作、IME、配布品質を満たしにくい |
| 内部文字列 | UTF-16 `char16_t` | Windows資産とAppKit範囲表現の接続が容易 |
| プロセス | 単一アプリ + XPC | macOS文書モデルと障害分離を両立 |
| 初期配布 | Developer ID | マクロ、外部コマンド、任意ファイル操作を維持 |
| Release | Universal Binary | Apple SiliconとIntelの双方でネイティブ動作 |

## 20. 最初に実装すべき変更

1. `portable-core`ブランチを作成する。
2. `wchar_t`、`WCHAR`、`LPCWSTR`の利用箇所を分類する。
3. `SakuraChar`、`SakuraString`、`TextOffset`を追加する。
4. `BOOL`等のWin32基本型をPortable Coreから排除する。
5. `CDocLineMgr`をmacOS上で単体ビルドする。
6. `CLayoutMgr`からフォント計測とWin32関数を分離する。
7. `CommandBus`の最小実装を作る。
8. UTF-8文書の読込・編集・保存をheadlessテストで通す。
9. `NSDocument`と空の`SakuraEditorView`を持つmacOSアプリを作る。
10. `NSTextInputClient`による日本語入力を接続する。

## 21. 完成判定

macOS版0.1は、次を満たした時点で成立とする。

- FinderまたはCLIからファイルを開ける
- 日本語IMEで入力・変換・確定できる
- UTF-8、Shift_JIS、EUC-JP、UTF-16を読書きできる
- 改行コードとBOMを維持できる
- 検索、置換、Undo、Redoが動作する
- タイプ別色分けが動作する
- 外部変更を検知できる
- 未保存文書を復元できる
- Windows版の主要コアテストを壊さない
- arm64、x86_64の両方で起動する
- 署名と公証を通過する

## 参考資料

- [S1] サクラエディタ現行リポジトリ `CLAUDE.md`: ビルド条件、二プロセス構成、主要クラス、外部依存
- [S2] `sakura_core/doc/CEditDoc.h`: 文書サブシステムとWin32型
- [S3] `CDocLineMgr.h`、`CLayoutMgr.h`: `Windows.h`への直接依存
- [S4] ルート`CMakeLists.txt`: Windows実行ファイルを前提とした現行ターゲット
- [S5] Microsoft LearnおよびApple Developer Documentation: WindowsとAppleプラットフォームにおける`wchar_t`
- [S6] Apple Developer Documentation: `NSString`のUTF-16コード単位
- [S7] サクラエディタ Issue #487およびDiscussion #1916: 文字コード判定
- [S8] Apple Developer Documentation: `NSDocument`
- [S9] Apple Developer Documentation: `NSTextInputClient`
- [S10] Apple Developer Documentation: Universal macOS Binary
- [S11] Apple Developer Documentation: macOS Software Notarization
- [S12] ルート`LICENSE`と個別ソースヘッダー
