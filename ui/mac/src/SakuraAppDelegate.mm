// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#import "SakuraAppDelegate.h"

#import "SakuraDocument.h"
#import "SakuraEditorView.h"
#import "SakuraRecoveryWriter.h"

namespace {

NSString* const kSakuraWindowsMenuMarker = @"SakuraWindowsMenuItem";

NSMenuItem* addMenuItem(NSMenu* menu, NSString* title, SEL action,
                        NSString* keyEquivalent) {
  NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title
                                               action:action
                                        keyEquivalent:keyEquivalent];
  item.representedObject = kSakuraWindowsMenuMarker;
  [menu addItem:item];
  return item;
}

void addMenuSeparator(NSMenu* menu) {
  NSMenuItem* separator = [NSMenuItem separatorItem];
  separator.representedObject = kSakuraWindowsMenuMarker;
  [menu addItem:separator];
}

NSMenuItem* addDisabledMenuItem(NSMenu* menu, NSString* title) {
  NSMenuItem* item = addMenuItem(menu, title, nil, @"");
  item.enabled = NO;
  return item;
}

void addDisabledItems(NSMenu* menu, NSArray<NSString*>* titles) {
  // These navigation handlers already exist in the editor. Wire both the
  // native and in-window menus instead of leaving keyboard-only operations grey.
  NSDictionary<NSString*, NSString*>* navigation = @{
    @"単語の左端に移動":@"moveWordLeft:", @"単語の右端に移動":@"moveWordRight:",
    @"１ページアップ":@"pageUp:", @"１ページダウン":@"pageDown:",
    @"行頭に移動(折り返し単位)":@"moveToBeginningOfLine:",
    @"行末に移動(折り返し単位)":@"moveToEndOfLine:",
    @"(選択)単語の左端に移動":@"moveWordLeftAndModifySelection:",
    @"(選択)単語の右端に移動":@"moveWordRightAndModifySelection:",
    @"(選択)１ページアップ":@"pageUpAndModifySelection:",
    @"(選択)１ページダウン":@"pageDownAndModifySelection:",
    @"(選択)行頭に移動(折り返し単位)":@"moveToBeginningOfLineAndModifySelection:",
    @"(選択)行末に移動(折り返し単位)":@"moveToEndOfLineAndModifySelection:",
    @"(選択)ファイルの先頭に移動":@"moveToBeginningOfDocumentAndModifySelection:",
    @"(選択)ファイルの最後に移動":@"moveToEndOfDocumentAndModifySelection:",
    @"日付挿入":@"insertDate:", @"時刻挿入":@"insertTime:",
    @"現在位置の単語選択":@"selectCurrentWord:", @"単語削除":@"deleteCurrentWord:",
    @"単語の左端まで削除":@"deleteWordToLeft:", @"単語の右端まで削除":@"deleteWordToRight:",
    @"行頭まで削除(改行単位)":@"deleteToLogicalLineStart:",
    @"行末まで削除(改行単位)":@"deleteToLogicalLineEnd:",
    @"このファイル名をコピー":@"copyFileName:", @"このファイルのパス名をコピー":@"copyFilePath:",
    @"このファイルのパス名とカーソル位置をコピー":@"copyFileLocation:",
    @"CRLF改行でコピー":@"copyWithCRLF:",
  };
  for (NSString* title in titles) {
    if ([title isEqualToString:@"-"]) {
      addMenuSeparator(menu);
    } else if (navigation[title]) {
      addMenuItem(menu, title, NSSelectorFromString(navigation[title]), @"");
    } else {
      addDisabledMenuItem(menu, title);
    }
  }
}

NSMenu* addSubmenu(NSMenu* parent, NSString* title) {
  NSMenuItem* root = addMenuItem(parent, title, nil, @"");
  NSMenu* submenu = [[NSMenu alloc] initWithTitle:title];
  root.submenu = submenu;
  return submenu;
}

void openURLs(NSDocumentController* controller, NSArray<NSURL*>* urls) {
  for (NSURL* url in urls) {
    [controller openDocumentWithContentsOfURL:url
                                     display:YES
                           completionHandler:^(NSDocument* document,
                                               BOOL documentWasAlreadyOpen,
                                               NSError* error) {
      (void)document;
      (void)documentWasAlreadyOpen;
      if (error != nil) {
        [NSApp presentError:error];
      }
    }];
  }
}

}  // namespace

@interface SakuraAppDelegate ()
@property(nonatomic, copy) NSArray<NSDocument*>* pendingSaveDocuments;
@property(nonatomic) NSUInteger pendingSaveIndex;
@property(nonatomic) BOOL savingAllDocuments;
@property(nonatomic, strong) NSApplication* pendingTerminationApplication;
@end

@implementation SakuraAppDelegate

- (NSArray<NSDocument*>*)documentsForSaveAll {
  return NSDocumentController.sharedDocumentController.documents;
}

- (void)saveAllDocuments:(id)sender {
  (void)sender;
  if (self.savingAllDocuments) return;
  self.savingAllDocuments = YES;
  self.pendingSaveDocuments = [[self documentsForSaveAll] copy];
  self.pendingSaveIndex = 0;
  [self saveNextDocument];
}

- (void)saveNextDocument {
  while (self.pendingSaveIndex < self.pendingSaveDocuments.count) {
    NSDocument* document = self.pendingSaveDocuments[self.pendingSaveIndex++];
    if (![[self documentsForSaveAll] containsObject:document]) continue;
    if ([document isKindOfClass:SakuraDocument.class])
      [(SakuraDocument*)document commitPendingInput];
    if (!document.isDocumentEdited) continue;
    [document saveDocumentWithDelegate:self
                      didSaveSelector:@selector(saveAllDocument:didSave:contextInfo:)
                          contextInfo:nullptr];
    return;
  }
  self.pendingSaveDocuments = nil;
  self.savingAllDocuments = NO;
}

- (void)saveAllDocument:(NSDocument*)document didSave:(BOOL)didSave contextInfo:(void*)context {
  (void)context;
  if (!didSave || document.isDocumentEdited) {
    // Cancellation, failure, or edits after the save snapshot stop the queue.
    // Already saved documents are not rolled back.
    self.pendingSaveDocuments = nil;
    self.savingAllDocuments = NO;
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{ [self saveNextDocument]; });
}

- (NSArray<NSURL*>*)recentDocumentURLs {
  return NSDocumentController.sharedDocumentController.recentDocumentURLs;
}

- (void)menuNeedsUpdate:(NSMenu*)menu {
  BOOL folders = [menu.title isEqualToString:@"最近使ったフォルダー"];
  if (!folders && ![menu.title isEqualToString:@"最近使ったファイル"]) return;
  [menu removeAllItems];
  NSMutableSet<NSString*>* seen = [NSMutableSet set];
  for (NSURL* recent in [self recentDocumentURLs]) {
    if (!recent.isFileURL) continue;
    NSURL* url = folders ? recent.URLByDeletingLastPathComponent : recent;
    if ([seen containsObject:url.path]) continue;
    [seen addObject:url.path];
    NSMenuItem* item = addMenuItem(menu, url.path.stringByAbbreviatingWithTildeInPath,
        folders ? @selector(openRecentFolder:) : @selector(openRecentDocument:), @"");
    item.target = self;
    item.representedObject = url;
    item.toolTip = url.path;
    if (seen.count >= 20) break;
  }
  if (!seen.count) addDisabledMenuItem(menu, @"（履歴なし）");
  addMenuSeparator(menu);
  addMenuItem(menu, @"履歴を消去", @selector(clearRecentHistory:), @"").target = self;
}

- (void)openRecentDocument:(NSMenuItem*)sender {
  NSURL* url = [sender.representedObject isKindOfClass:NSURL.class] ? sender.representedObject : nil;
  if (!url.isFileURL) { NSBeep(); return; }
  openURLs(NSDocumentController.sharedDocumentController, @[url]);
}

- (void)openRecentFolder:(NSMenuItem*)sender {
  NSURL* url = [sender.representedObject isKindOfClass:NSURL.class] ? sender.representedObject : nil;
  if (!url.isFileURL) { NSBeep(); return; }
  NSOpenPanel* panel = NSOpenPanel.openPanel;
  panel.directoryURL = url;
  panel.allowsMultipleSelection = YES;
  panel.canChooseDirectories = NO;
  panel.canChooseFiles = YES;
  [panel beginWithCompletionHandler:^(NSModalResponse response) {
    if (response == NSModalResponseOK)
      openURLs(NSDocumentController.sharedDocumentController, panel.URLs);
  }];
}

- (void)clearRecentHistory:(id)sender {
  [NSDocumentController.sharedDocumentController clearRecentDocuments:sender];
}

- (void)applicationWillFinishLaunching:(NSNotification*)notification {
  (void)notification;

  [[NSUserDefaults standardUserDefaults] registerDefaults:@{
    @"SakuraEditorFontSize" : @13.0,
    @"SakuraEditorTabWidth" : @4,
    @"SakuraEditorColorTheme" : @"windows-classic",
    @"SakuraToolbarVisible" : @YES,
    @"SakuraToolbarFlat" : @NO,
    @"SakuraToolbarItems" : @[
      @"new", @"open", @"save", @"save_as", @"separator",
      @"undo", @"redo", @"separator",
      @"history_back", @"history_forward", @"separator",
      @"find", @"find_next", @"find_previous", @"replace",
      @"clear_search", @"grep", @"separator", @"outline",
      @"separator", @"type_list", @"type_settings",
      @"common_settings", @"separator", @"command_list",
    ],
  }];

  // Force the NSDocument subclass out of the static UI library before
  // NSDocumentController resolves its class name from Info.plist.
  (void)[SakuraDocument class];
  [self installMainMenu];
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
  (void)notification;
  [SakuraDocument offerRecoveryIfNeeded];
  NSDocumentController* controller = [NSDocumentController sharedDocumentController];
  if (controller.documents.count == 0) {
    [controller newDocument:nil];
  }
  [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldOpenUntitledFile:(NSApplication*)sender {
  (void)sender;
  // applicationDidFinishLaunching creates exactly one initial document.  This
  // avoids a second untitled document when Launch Services also asks.
  return NO;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
  (void)sender;
  return NO;
}

- (NSDocumentController*)documentControllerForTermination {
  return NSDocumentController.sharedDocumentController;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)sender {
  if (self.pendingTerminationApplication) return NSTerminateLater;
  self.pendingTerminationApplication = sender;
  // NSApplication.terminate: asks NSDocumentController to review unsaved
  // changes BEFORE invoking this delegate. Remaining documents were approved
  // for discard (or are clean). Close them without asking twice. Do this
  // synchronously so an intervening user event cannot modify reviewed text.
  for (NSDocument* document in [self documentControllerForTermination].documents)
    [document close];
  // The drain callback is always asynchronous, including an empty group.
  [self awaitRecoveryForTermination];
  return NSTerminateLater;
}

- (void)closeDocumentsForTermination {
  [[self documentControllerForTermination] closeAllDocumentsWithDelegate:self
      didCloseAllSelector:@selector(documentController:didCloseForTermination:contextInfo:)
      contextInfo:nullptr];
}

- (void)documentController:(NSDocumentController*)controller
    didCloseForTermination:(BOOL)didClose contextInfo:(void*)context {
  (void)controller;
  (void)context;
  if (!self.pendingTerminationApplication) return;
  if (!didClose) {
    NSApplication* application = self.pendingTerminationApplication;
    self.pendingTerminationApplication = nil;
    [application replyToApplicationShouldTerminate:NO];
    return;
  }
  [self awaitRecoveryForTermination];
}

- (void)awaitRecoveryForTermination {
  SakuraRecoveryWhenIdle(^{
    if (!self.pendingTerminationApplication) return;
    // A user can still open a document while slow I/O drains. That document
    // must get the same close/save review, not be silently lost on exit.
    if ([self documentControllerForTermination].documents.count != 0) {
      [self closeDocumentsForTermination];
      return;
    }
    NSApplication* application = self.pendingTerminationApplication;
    self.pendingTerminationApplication = nil;
    [application replyToApplicationShouldTerminate:YES];
  });
}

- (void)application:(NSApplication*)sender openFiles:(NSArray<NSString*>*)filenames {
  NSDocumentController* controller = [NSDocumentController sharedDocumentController];
  NSMutableArray<NSURL*>* urls = [NSMutableArray arrayWithCapacity:filenames.count];
  for (NSString* filename in filenames) {
    [urls addObject:[NSURL fileURLWithPath:filename]];
  }
  openURLs(controller, urls);
  [sender replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
}

- (void)newDocument:(id)sender {
  [[NSDocumentController sharedDocumentController] newDocument:sender];
}

- (void)openDocument:(id)sender {
  (void)sender;
  NSOpenPanel* panel = [NSOpenPanel openPanel];
  panel.allowsMultipleSelection = YES;
  panel.canChooseDirectories = NO;
  panel.canChooseFiles = YES;
  [panel beginWithCompletionHandler:^(NSModalResponse result) {
    if (result == NSModalResponseOK) {
      openURLs([NSDocumentController sharedDocumentController], panel.URLs);
    }
  }];
}

- (void)showUnofficialAbout:(id)sender {
  (void)sender;
  NSDictionary* info = NSBundle.mainBundle.infoDictionary;
  NSString* version = info[@"SakuraReleaseDisplayVersion"];
  if (version == nil) version = info[@"CFBundleShortVersionString"];
  if (version == nil) version = @"development";
  [NSApp orderFrontStandardAboutPanelWithOptions:@{
    NSAboutPanelOptionApplicationName : @"Sakura macOS (Unofficial)",
    NSAboutPanelOptionApplicationVersion : version,
    NSAboutPanelOptionVersion : @"Experimental / 非公式改変・移植版",
    @"Copyright" : @"© 2026 Unofficial Sakura macOS port contributors",
    NSAboutPanelOptionCredits : [[NSAttributedString alloc] initWithString:
      @"Based on Sakura Editor — © 2018-2022 Sakura Editor Organization\n"
       "本家が提供・承認・サポートする製品ではありません。\n"
       "zlib License / 個別の第三者ライセンスあり。\n"
       "「ライセンスと素材の出所…」で同梱文書を確認できます。"],
  }];
}

- (void)showBundledLicenses:(id)sender {
  (void)sender;
  NSURL* url = [NSBundle.mainBundle.resourceURL
      URLByAppendingPathComponent:@"Licenses" isDirectory:YES];
  if (url != nil && ![NSWorkspace.sharedWorkspace openURL:url]) {
    NSBeep();
  }
}

- (void)installMainMenu {
  NSMenu* mainMenu = [[NSMenu alloc] initWithTitle:@"Main Menu"];
  NSApp.mainMenu = mainMenu;

  NSMenuItem* applicationRoot = [[NSMenuItem alloc] initWithTitle:@""
                                                           action:nil
                                                    keyEquivalent:@""];
  [mainMenu addItem:applicationRoot];
  NSMenu* applicationMenu = [[NSMenu alloc] initWithTitle:@"Sakura macOS (Unofficial)"];
  applicationRoot.submenu = applicationMenu;

  addMenuItem(applicationMenu, @"Sakura macOS (非公式版) について", @selector(showUnofficialAbout:), @"").target = self;
  addMenuItem(applicationMenu, @"ライセンスと素材の出所…", @selector(showBundledLicenses:), @"").target = self;
  addMenuSeparator(applicationMenu);
  addMenuItem(applicationMenu, @"Sakura macOS (非公式版) を隠す", @selector(hide:), @"h");
  NSMenuItem* hideOthers = addMenuItem(applicationMenu, @"ほかを隠す", @selector(hideOtherApplications:), @"h");
  hideOthers.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
  addMenuItem(applicationMenu, @"すべてを表示", @selector(unhideAllApplications:), @"");
  addMenuSeparator(applicationMenu);
  addMenuItem(applicationMenu, @"Sakura macOS (非公式版) を終了", @selector(terminate:), @"q");

  NSMenuItem* fileRoot = [[NSMenuItem alloc] initWithTitle:@"ファイル"
                                                    action:nil
                                             keyEquivalent:@""];
  [mainMenu addItem:fileRoot];
  NSMenu* fileMenu = [[NSMenu alloc] initWithTitle:@"ファイル"];
  fileRoot.submenu = fileMenu;

  NSMenuItem* newItem = addMenuItem(fileMenu, @"新規作成", @selector(newDocument:), @"n");
  newItem.target = self;
  NSMenuItem* newWindow = addMenuItem(fileMenu, @"新規ウインドウを開く",
                                      @selector(newDocument:), @"");
  newWindow.target = self;
  NSMenuItem* openItem = addMenuItem(fileMenu, @"開く...", @selector(openDocument:), @"o");
  openItem.target = self;
  addMenuItem(fileMenu, @"上書き保存", @selector(saveDocument:), @"s");
  NSMenuItem* saveAs = addMenuItem(fileMenu, @"名前を付けて保存...", @selector(saveDocumentAs:), @"S");
  saveAs.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
  addMenuItem(fileMenu, @"すべて上書き保存", @selector(saveAllDocuments:), @"").target = self;
  addMenuSeparator(fileMenu);
  addMenuItem(fileMenu, @"保存して閉じる", @selector(saveAndClose:), @"");
  addMenuItem(fileMenu, @"閉じる", @selector(performClose:), @"w");
  addDisabledMenuItem(fileMenu, @"閉じて(無題)");
  addDisabledMenuItem(fileMenu, @"閉じて開く...");
  NSMenu* reopenMenu = addSubmenu(fileMenu, @"開き直す");
  addMenuItem(reopenMenu, @"文字コードを指定して開き直す...",
              @selector(showEncodingPanel:), @"");
  addDisabledItems(fileMenu, @[
    @"-", @"印刷...", @"印刷プレビュー", @"印刷ページ設定...", @"-",
    @"ファイルのプロパティ", @"ブラウズ", @"-"
  ]);
  NSMenu* recentFileMenu = addSubmenu(fileMenu, @"最近使ったファイル");
  recentFileMenu.delegate = self;
  addDisabledMenuItem(recentFileMenu, @"（履歴なし）");
  NSMenu* recentFolderMenu = addSubmenu(fileMenu, @"最近使ったフォルダー");
  recentFolderMenu.delegate = self;
  addDisabledMenuItem(recentFolderMenu, @"（履歴なし）");
  addDisabledItems(fileMenu, @[@"-", @"グループを閉じる", @"編集の全終了"]);
  addMenuItem(fileMenu, @"サクラエディタの全終了", @selector(terminate:), @"");

  NSMenuItem* editRoot = [[NSMenuItem alloc] initWithTitle:@"編集"
                                                    action:nil
                                             keyEquivalent:@""];
  [mainMenu addItem:editRoot];
  NSMenu* editMenu = [[NSMenu alloc] initWithTitle:@"編集"];
  editRoot.submenu = editMenu;

  addMenuItem(editMenu, @"元に戻す", @selector(undo:), @"z");
  NSMenuItem* redo = addMenuItem(editMenu, @"やり直し", @selector(redo:), @"Z");
  redo.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
  addMenuSeparator(editMenu);
  addMenuItem(editMenu, @"切り取り", @selector(cut:), @"x");
  addMenuItem(editMenu, @"コピー", @selector(copy:), @"c");
  addMenuItem(editMenu, @"貼り付け", @selector(paste:), @"v");
  addMenuItem(editMenu, @"削除", @selector(deleteForward:), @"");
  addMenuItem(editMenu, @"すべて選択", @selector(selectAll:), @"a");
  addDisabledItems(editMenu, @[
    @"-", @"再変換", @"-", @"CRLF改行でコピー",
    @"折り返し位置に改行をつけてコピー", @"矩形貼り付け", @"カーソル前を削除", @"-"
  ]);
  NSMenu* insertMenu = addSubmenu(editMenu, @"挿入");
  addDisabledItems(insertMenu, @[
    @"日付挿入", @"時刻挿入", @"コントロールコード入力...",
    @"最近使ったファイル挿入", @"最近使ったフォルダー挿入"
  ]);
  NSMenu* advancedMenu = addSubmenu(editMenu, @"高度な操作");
  addDisabledItems(advancedMenu, @[
    @"単語の左端まで削除", @"単語の右端まで削除", @"-",
    @"現在位置の単語選択", @"単語切り取り", @"単語削除", @"-",
    @"行頭まで切り取り(改行単位)", @"行末まで切り取り(改行単位)", @"-",
    @"行頭まで削除(改行単位)", @"行末まで削除(改行単位)", @"-",
    @"行切り取り(折り返し単位)", @"行削除(折り返し単位)", @"-",
    @"選択範囲内全行コピー", @"選択範囲内全行引用符付きコピー",
    @"選択範囲内全行行番号付きコピー", @"選択範囲内色付きHTMLコピー",
    @"選択範囲内行番号色付きHTMLコピー", @"-", @"このファイル名をコピー",
    @"このファイルのパス名をコピー", @"このファイルのパス名とカーソル位置をコピー"
  ]);
  addMenuItem(advancedMenu, @"行の二重化(改行単位)", @selector(duplicateLogicalLines:), @"");
  addMenuItem(advancedMenu, @"行削除(改行単位)", @selector(deleteLogicalLines:), @"");
  addMenuItem(advancedMenu, @"TABインデント", @selector(indentWithTab:), @"");
  addMenuItem(advancedMenu, @"逆TABインデント", @selector(unindentWithTab:), @"");
  addMenuItem(advancedMenu, @"SPACEインデント", @selector(indentWithSpaces:), @"");
  addMenuItem(advancedMenu, @"逆SPACEインデント", @selector(unindentWithSpaces:), @"");
  NSMenu* moveMenu = addSubmenu(editMenu, @"移動");
  addDisabledItems(moveMenu, @[
    @"カーソル上移動(２行ごと)", @"カーソル下移動(２行ごと)",
    @"単語の左端に移動", @"単語の右端に移動", @"前の段落へ移動",
    @"次の段落へ移動", @"行頭に移動(折り返し単位)",
    @"行末に移動(折り返し単位)", @"-", @"１ページアップ",
    @"１ページダウン"
  ]);
  addMenuItem(moveMenu, @"ファイルの先頭に移動",
              @selector(moveToBeginningOfDocument:), @"");
  addMenuItem(moveMenu, @"ファイルの最後に移動",
              @selector(moveToEndOfDocument:), @"");
  addDisabledItems(moveMenu, @[
    @"-", @"カーソル行をウィンドウ中央へ", @"-",
    @"検索開始位置へ戻る", @"-"
  ]);
  addMenuItem(moveMenu, @"指定行へジャンプ...", @selector(showLineJump:), @"l");
  addMenuItem(moveMenu, @"移動履歴: 前へ",
              @selector(goBackInNavigationHistory:), @"");
  addMenuItem(moveMenu, @"移動履歴: 次へ",
              @selector(goForwardInNavigationHistory:), @"");
  addMenuItem(moveMenu, @"現在位置を移動履歴に登録",
              @selector(registerCurrentNavigationPosition:), @"");
  addDisabledItems(moveMenu, @[
    @"-", @"次の関数リストマーク",
    @"前の関数リストマーク", @"次の変更行へ", @"前の変更行へ"
  ]);
  NSMenu* selectionMenu = addSubmenu(editMenu, @"選択");
  addMenuItem(selectionMenu, @"現在位置の単語選択", @selector(selectCurrentWord:), @"");
  addMenuItem(selectionMenu, @"すべて選択", @selector(selectAll:), @"");
  addDisabledItems(selectionMenu, @[
    @"範囲選択開始", @"-",
    @"(選択)カーソル上移動(２行ごと)", @"(選択)カーソル下移動(２行ごと)",
    @"(選択)単語の左端に移動", @"(選択)単語の右端に移動",
    @"(選択)前の段落へ移動", @"(選択)次の段落へ移動",
    @"(選択)行頭に移動(折り返し単位)", @"(選択)行末に移動(折り返し単位)",
    @"-", @"(選択)１ページアップ", @"(選択)１ページダウン",
    @"(選択)ファイルの先頭に移動", @"(選択)ファイルの最後に移動",
    @"-", @"(選択)次の変更行へ", @"(選択)前の変更行へ"
  ]);
  NSMenu* boxSelectionMenu = addSubmenu(editMenu, @"矩形選択");
  addMenuItem(boxSelectionMenu, @"矩形範囲選択開始／解除",
              @selector(toggleRectangularSelection:), @"");
  addMenuSeparator(boxSelectionMenu);
  addDisabledItems(boxSelectionMenu, @[
    @"(矩形選択)カーソル上移動(２行ごと)",
    @"(矩形選択)カーソル下移動(２行ごと)", @"(矩形選択)単語の左端に移動",
    @"(矩形選択)単語の右端に移動", @"(矩形選択)行頭に移動(改行単位)",
    @"(矩形選択)行頭に移動(折り返し単位)", @"(矩形選択)行末に移動(折り返し単位)",
    @"-", @"(矩形選択)１ページアップ", @"(矩形選択)１ページダウン",
    @"(矩形選択)ファイルの先頭に移動", @"(矩形選択)ファイルの最後に移動"
  ]);
  NSMenu* formatMenu = addSubmenu(editMenu, @"整形");
  addMenuItem(formatMenu, @"左(先頭)の空白を削除", @selector(trimLeadingWhitespace:), @"");
  addMenuItem(formatMenu, @"右(末尾)の空白を削除", @selector(trimTrailingWhitespace:), @"");
  addMenuSeparator(formatMenu);
  addMenuItem(formatMenu, @"選択行の昇順ソート", @selector(sortLinesAscending:), @"");
  addMenuItem(formatMenu, @"選択行の降順ソート", @selector(sortLinesDescending:), @"");
  addMenuSeparator(formatMenu);
  addMenuItem(formatMenu, @"連続した重複行の削除(uniq)", @selector(uniqueConsecutiveLines:), @"");

  NSMenuItem* convertRoot = [[NSMenuItem alloc] initWithTitle:@"変換"
                                                       action:nil
                                                keyEquivalent:@""];
  [mainMenu addItem:convertRoot];
  NSMenu* convertMenu = [[NSMenu alloc] initWithTitle:@"変換"];
  convertRoot.submenu = convertMenu;
  addMenuItem(convertMenu, @"小文字", @selector(convertSelectionToLowercase:), @"");
  addMenuItem(convertMenu, @"大文字", @selector(convertSelectionToUppercase:), @"");
  addDisabledItems(convertMenu, @[
    @"-", @"全角英数→半角英数",
    @"半角英数→全角英数", @"全角カタカナ→半角カタカナ",
    @"半角カタカナ→全角カタカナ", @"半角カタカナ→全角ひらがな",
    @"-"
  ]);
  addMenuItem(convertMenu, @"全角→半角", @selector(convertToHalfwidth:), @"");
  addMenuItem(convertMenu, @"半角＋全ひら→全角・カタカナ", @selector(convertToFullwidthKatakana:), @"");
  addMenuItem(convertMenu, @"半角＋全カタ→全角・ひらがな", @selector(convertToFullwidthHiragana:), @"");
  addMenuItem(convertMenu, @"TAB→空白", @selector(tabsToSpaces:), @"");
  addMenuItem(convertMenu, @"空白→TAB", @selector(spacesToTabs:), @"");
  NSMenu* encodingConvertMenu = addSubmenu(convertMenu, @"文字コード変換");
  addDisabledItems(encodingConvertMenu, @[
    @"自動判別→SJISコード変換", @"E-Mail(JIS→SJIS)コード変換",
    @"EUC→SJISコード変換", @"UTF-16→SJISコード変換",
    @"UTF-16BE→SJISコード変換", @"UTF-8→SJISコード変換",
    @"UTF-7→SJISコード変換", @"-", @"SJIS→JISコード変換",
    @"SJIS→EUCコード変換", @"SJIS→UTF-8コード変換",
    @"SJIS→UTF-7コード変換", @"-", @"Base64デコードして保存",
    @"uudecodeして保存"
  ]);

  NSMenuItem* searchRoot = [[NSMenuItem alloc] initWithTitle:@"検索"
                                                      action:nil
                                               keyEquivalent:@""];
  [mainMenu addItem:searchRoot];
  NSMenu* searchMenu = [[NSMenu alloc] initWithTitle:@"検索"];
  searchRoot.submenu = searchMenu;
  addMenuItem(searchMenu, @"検索...", @selector(showFindPanel:), @"f");
  addMenuItem(searchMenu, @"選択文字列を検索に使用", @selector(useSelectionForFind:), @"e");
  addMenuItem(searchMenu, @"一致件数を数える", @selector(countSearchMatches:), @"");
  addMenuItem(searchMenu, @"検索処理を中止", @selector(cancelSearchOperations:), @".");
  addMenuItem(searchMenu, @"次を検索", @selector(findNext:), @"g");
  NSMenuItem* previous = addMenuItem(searchMenu, @"前を検索",
                                     @selector(findPrevious:), @"G");
  previous.keyEquivalentModifierMask = NSEventModifierFlagCommand |
                                       NSEventModifierFlagShift;
  NSMenuItem* replace = addMenuItem(searchMenu, @"置換...",
                                    @selector(replaceSearchSelection:), @"r");
  replace.keyEquivalentModifierMask = NSEventModifierFlagCommand |
                                     NSEventModifierFlagOption;
  addMenuItem(searchMenu, @"検索マークの切替え",
              @selector(clearSearchMarks:), @"");
  addDisabledMenuItem(searchMenu, @"検索開始位置へ戻る");
  NSMenu* incrementalMenu = addSubmenu(searchMenu, @"インクリメンタルサーチ");
  addDisabledItems(incrementalMenu, @[
    @"前方インクリメンタルサーチ", @"後方インクリメンタルサーチ",
    @"正規表現前方インクリメンタルサーチ", @"正規表現後方インクリメンタルサーチ",
    @"MIGEMO前方インクリメンタルサーチ", @"MIGEMO後方インクリメンタルサーチ"
  ]);
  addMenuSeparator(searchMenu);
  NSMenu* bookmarkMenu = addSubmenu(searchMenu, @"ブックマーク");
  addMenuItem(bookmarkMenu, @"ブックマーク設定・解除", @selector(toggleBookmark:), @"");
  addMenuItem(bookmarkMenu, @"次のブックマークへ", @selector(nextBookmark:), @"");
  addMenuItem(bookmarkMenu, @"前のブックマークへ", @selector(previousBookmark:), @"");
  addMenuItem(bookmarkMenu, @"ブックマークの全解除", @selector(clearBookmarks:), @"");
  addMenuItem(bookmarkMenu, @"ブックマークの一覧...", @selector(showBookmarks:), @"");
  addMenuItem(searchMenu, @"Grep...", @selector(showGrepPanel:), @"");
  addMenuItem(searchMenu, @"Grep置換...",
              @selector(showGrepReplacePanel:), @"");
  addDisabledMenuItem(searchMenu, @"指定行へジャンプ...");
  addMenuItem(searchMenu, @"アウトライン解析...",
              @selector(showOutlinePanel:), @"");
  addDisabledItems(searchMenu, @[
    @"ファイルツリー", @"タグジャンプ", @"タグジャンプバック",
    @"タグファイルの作成...", @"ダイレクトタグジャンプ",
    @"キーワードを指定してタグジャンプ...", @"同名のC/C++ヘッダー(ソース)を開く",
    @"-", @"ファイル内容比較...", @"DIFF差分表示...", @"次の差分へ",
    @"前の差分へ", @"差分表示の全解除", @"-"
  ]);
  // The Windows Ctrl+] command maps to Command+] on macOS.
  addMenuItem(searchMenu, @"対括弧の検索", @selector(jumpToMatchingBracket:), @"]");

  NSMenuItem* viewRoot = [[NSMenuItem alloc] initWithTitle:@"ツール"
                                                    action:nil
                                             keyEquivalent:@""];
  [mainMenu addItem:viewRoot];
  NSMenu* viewMenu = [[NSMenu alloc] initWithTitle:@"ツール"];
  viewRoot.submenu = viewMenu;
  addDisabledItems(viewMenu, @[
    @"キーマクロの記録開始／終了", @"キーマクロの保存", @"キーマクロの読み込み",
    @"キーマクロの実行"
  ]);
  NSMenu* registeredMacros = addSubmenu(viewMenu, @"登録済みマクロ");
  addDisabledMenuItem(registeredMacros, @"（登録なし）");
  addDisabledItems(viewMenu, @[
    @"名前を指定してマクロ実行...", @"-", @"外部コマンド実行...",
    @"SQL*Plusをアクティブ表示", @"SQL*Plusで実行", @"-", @"入力補完", @"-",
    @"プラグインコマンド", @"-"
  ]);
  NSMenu* customMenu = addSubmenu(viewMenu, @"カスタムメニュー");
  addDisabledMenuItem(customMenu, @"（登録なし）");

  NSMenuItem* optionRoot = [[NSMenuItem alloc] initWithTitle:@"設定"
                                                      action:nil
                                               keyEquivalent:@""];
  [mainMenu addItem:optionRoot];
  NSMenu* optionMenu = [[NSMenu alloc] initWithTitle:@"設定"];
  optionRoot.submenu = optionMenu;
  addMenuItem(optionMenu, @"ツールバーの表示／非表示",
              @selector(toggleToolbar:), @"");
  addDisabledMenuItem(optionMenu, @"ファンクションキーの表示／非表示");
  addDisabledMenuItem(optionMenu, @"タブバーの表示／非表示");
  addMenuItem(optionMenu, @"ステータスバーの表示／非表示",
              @selector(toggleStatusBar:), @"");
  addDisabledMenuItem(optionMenu, @"ミニマップの表示／非表示");
  addMenuSeparator(optionMenu);
  addMenuItem(optionMenu, @"タイプ別設定一覧...",
              @selector(showTypeSettingsList:), @"");
  addMenuItem(optionMenu, @"タイプ別設定...",
              @selector(showTypeSettings:), @"");
  addMenuItem(optionMenu, @"共通設定...",
              @selector(showCommonSettings:), @"");
  addDisabledItems(optionMenu, @[@"フォント設定...", @"履歴の管理...", @"-"]);
  NSMenu* wrapMenu = addSubmenu(optionMenu, @"折り返し方法");
  addDisabledItems(wrapMenu, @[
    @"折り返さない", @"指定桁で折り返す", @"右端で折り返す"
  ]);
  addDisabledItems(optionMenu, @[
    @"折り返し桁数", @"文字カウント方法", @"-", @"挿入／上書きモード切り替え",
    @"ビューモード", @"キーワードヘルプ自動表示"
  ]);
  addMenuItem(optionMenu, @"文字コードセット指定...",
              @selector(showEncodingPanel:), @"");
  NSMenu* eolMenu = addSubmenu(optionMenu, @"入力改行コード指定");
  addMenuItem(eolMenu, @"入力改行コード指定(CRLF)",
              @selector(setInputLineEndingCRLF:), @"");
  addMenuItem(eolMenu, @"入力改行コード指定(LF)",
              @selector(setInputLineEndingLF:), @"");
  addMenuItem(eolMenu, @"入力改行コード指定(CR)",
              @selector(setInputLineEndingCR:), @"");

  NSMenuItem* windowRoot = [[NSMenuItem alloc] initWithTitle:@"ウィンドウ"
                                                      action:nil
                                               keyEquivalent:@""];
  [mainMenu addItem:windowRoot];
  NSMenu* windowMenu = [[NSMenu alloc] initWithTitle:@"ウィンドウ"];
  windowRoot.submenu = windowMenu;
  addDisabledMenuItem(windowMenu, @"上下に分割／分割解除");
  NSMenuItem* split = addMenuItem(windowMenu, @"左右に分割／分割解除",
                                   @selector(toggleSplitEditor:), @"\\");
  split.keyEquivalentModifierMask = NSEventModifierFlagCommand |
                                    NSEventModifierFlagOption;
  addDisabledMenuItem(windowMenu, @"縦横に分割／分割解除");
  addMenuSeparator(windowMenu);
  addMenuItem(windowMenu, @"閉じる", @selector(performClose:), @"w");
  addDisabledItems(windowMenu, @[
    @"すべて閉じる", @"このタブ／ウィンドウ以外を閉じる",
    @"次のウィンドウ", @"前のウィンドウ", @"ウィンドウ一覧...", @"-",
    @"重ねて表示", @"上下に並べて表示", @"左右に並べて表示", @"常に手前に表示"
  ]);
  NSMenu* tabMenu = addSubmenu(windowMenu, @"タブの操作");
  addDisabledItems(tabMenu, @[
    @"グループ化", @"グループを閉じる", @"左をすべて閉じる",
    @"右をすべて閉じる", @"次のグループ", @"前のグループ",
    @"タブを右に移動", @"タブを左に移動", @"新規グループ",
    @"次のグループに移動", @"前のグループに移動"
  ]);
  addDisabledItems(windowMenu, @[
    @"-", @"縦方向に最大化", @"横方向に最大化", @"すべて最小化", @"-", @"再描画",
    @"-", @"アウトプット", @"ウィンドウ一覧表示...", @"-"
  ]);
  NSMenu* windowList = addSubmenu(windowMenu, @"ウィンドウ一覧");
  addDisabledMenuItem(windowList, @"（ウィンドウ一覧）");
  addMenuSeparator(windowMenu);
  addMenuItem(windowMenu, @"しまう", @selector(performMiniaturize:), @"m");
  addMenuItem(windowMenu, @"拡大／縮小", @selector(performZoom:), @"");
  addMenuItem(windowMenu, @"すべてを手前に移動", @selector(arrangeInFront:), @"");
  NSApp.windowsMenu = windowMenu;

  NSMenuItem* helpRoot = [[NSMenuItem alloc] initWithTitle:@"ヘルプ"
                                                    action:nil
                                             keyEquivalent:@""];
  [mainMenu addItem:helpRoot];
  NSMenu* helpMenu = [[NSMenu alloc] initWithTitle:@"ヘルプ"];
  helpRoot.submenu = helpMenu;
  addDisabledItems(helpMenu, @[
    @"ヘルプ目次", @"ヘルプキーワード検索", @"-"
  ]);
  addMenuItem(helpMenu, @"コマンド一覧", @selector(showCommandList:), @"");
  addDisabledItems(helpMenu, @[
    @"キー割り当て一覧をコピー", @"外部ヘルプ１", @"外部HTMLヘルプ", @"-"
  ]);
  addMenuItem(helpMenu, @"バージョン情報",
              @selector(showUnofficialAbout:), @"").target = self;
  addMenuItem(helpMenu, @"ライセンスと素材の出所…",
              @selector(showBundledLicenses:), @"").target = self;
  NSApp.helpMenu = helpMenu;
}

@end
