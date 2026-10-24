// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#import "SakuraWindowController.h"

#import "SakuraDocument.h"
#import "SakuraColorTheme.h"
#import "SakuraEditorView.h"
#import "SakuraEditorSettings.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <exception>
#include <filesystem>
#include <memory>
#include <string_view>

#include "sakura/core/encoding/EncodingService.h"
#include "sakura/core/encoding/Utf8Codec.h"
#include "sakura/platform/mac/MacEncodingService.h"
#include "sakura/platform/mac/GrepFileTransaction.h"
#include "sakura/platform/mac/StringBridge.h"

namespace {

NSString* const kSakuraWindowsMenuMarker = @"SakuraWindowsMenuItem";

constexpr CGFloat kToolbarButtonSize = 22.0;
constexpr CGFloat kToolbarRowPadding = 2.0;
constexpr CGFloat kWindowsMenuBarHeight = 24.0;
constexpr CGFloat kStatusBarHeight = 22.0;

struct GrepReplacementCandidate {
  sakura::platform::mac::GrepFileSnapshot original;
  std::vector<std::byte> output;
  std::size_t replacements{};
};

constexpr std::size_t kGrepPreviewMemoryLimit = 128ULL * 1024ULL * 1024ULL;

NSString* stringFromUtf8(std::string_view value) {
  NSString* string = [[NSString alloc] initWithBytes:value.data()
                                               length:value.size()
                                             encoding:NSUTF8StringEncoding];
  return string != nil ? string : @"";
}

NSArray<NSString*>* grepPatternsFromString(NSString* value) {
  NSCharacterSet* separators = [NSCharacterSet
      characterSetWithCharactersInString:@";,\n"];
  NSMutableArray<NSString*>* patterns = [NSMutableArray array];
  for (NSString* component in [value componentsSeparatedByCharactersInSet:separators]) {
    NSString* pattern = [component
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (pattern.length != 0) [patterns addObject:pattern];
  }
  if (patterns.count == 0) [patterns addObject:@"*"];
  return patterns;
}

BOOL grepFileNameMatches(NSString* name, NSArray<NSString*>* patterns) {
  for (NSString* pattern in patterns) {
    NSPredicate* predicate = [NSPredicate predicateWithFormat:@"SELF LIKE[c] %@",
                                                        pattern];
    if ([predicate evaluateWithObject:name]) return YES;
  }
  return NO;
}

// A single component applies at every depth. A path is rooted at the selected
// search folder; only its final component may contain the Windows * / ? globs.
// Reject unsupported path syntax instead of silently broadening the search.
NSArray<NSDictionary*>* grepFolderExclusionsFromString(NSString* value,
                                                       NSString** error) {
  NSMutableArray<NSDictionary*>* exclusions = [NSMutableArray array];
  if (value.length > 16384) {
    *error = @"除外フォルダーの指定が長すぎます。";
    return nil;
  }
  NSCharacterSet* separators = [NSCharacterSet
      characterSetWithCharactersInString:@";,\n"];
  NSCharacterSet* unsupported = [NSCharacterSet
      characterSetWithCharactersInString:@":\""];
  for (NSString* component in [value componentsSeparatedByCharactersInSet:separators]) {
    NSString* pattern = [[component
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    if (pattern.length == 0) continue;
    if (exclusions.count == 256 || pattern.length > 4096 ||
        [pattern hasPrefix:@"/"] || [pattern hasPrefix:@"~"] ||
        [pattern rangeOfCharacterFromSet:unsupported].location != NSNotFound ||
        [pattern rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location
            != NSNotFound) {
      *error = @"除外フォルダーは名前または検索フォルダーからの相対パスで指定してください。";
      return nil;
    }
    // A trailing separator is a directory marker, not an empty path component.
    if ([pattern hasSuffix:@"/"]) {
      pattern = [pattern substringToIndex:pattern.length - 1];
    }
    NSArray<NSString*>* parts = [pattern componentsSeparatedByString:@"/"];
    for (NSUInteger index = 0; index < parts.count; ++index) {
      NSString* part = parts[index];
      if (part.length == 0 || [part isEqualToString:@"."] ||
          [part isEqualToString:@".."] ||
          (index + 1 < parts.count &&
           [part rangeOfCharacterFromSet:[NSCharacterSet
               characterSetWithCharactersInString:@"*?"]].location != NSNotFound)) {
        *error = @"除外フォルダーの .・..・空の階層や途中階層の * ? は使えません。";
        return nil;
      }
    }
    NSString* parent = parts.count == 1 ? nil :
        [[parts subarrayWithRange:NSMakeRange(0, parts.count - 1)]
            componentsJoinedByString:@"/"];
    NSPredicate* predicate = [NSPredicate predicateWithFormat:@"SELF LIKE[c] %@",
                                                         parts.lastObject];
    [exclusions addObject:@{@"parent": parent ?: NSNull.null,
                            @"name": predicate}];
  }
  return [exclusions copy];
}

BOOL grepDirectoryIsExcluded(const std::filesystem::path& path,
                             const std::filesystem::path& root,
                             NSArray<NSDictionary*>* exclusions) {
  if (exclusions.count == 0) return NO;
  const auto relative = path.lexically_relative(root);
  // Never compare a root's ancestors or a path outside the selected root.
  if (relative.empty() || relative.is_absolute()) return NO;
  for (const auto& part : relative) {
    if (part == "..") return NO;
  }
  NSFileManager* manager = NSFileManager.defaultManager;
  const auto parentPath = relative.parent_path();
  NSString* parent = [manager stringWithFileSystemRepresentation:parentPath.c_str()
                                                         length:parentPath.native().size()];
  const auto namePath = relative.filename();
  NSString* name = [manager stringWithFileSystemRepresentation:namePath.c_str()
                                                       length:namePath.native().size()];
  if (name == nil || parent == nil) return NO;
  for (NSDictionary* exclusion in exclusions) {
    id expectedParent = exclusion[@"parent"];
    if (expectedParent != NSNull.null &&
        [expectedParent caseInsensitiveCompare:parent] != NSOrderedSame) continue;
    if ([exclusion[@"name"] evaluateWithObject:name]) return YES;
  }
  return NO;
}

BOOL grepDataLooksBinary(NSData* data) {
  const auto* bytes = static_cast<const std::uint8_t*>(data.bytes);
  if (data.length >= 2 &&
      ((bytes[0] == 0xff && bytes[1] == 0xfe) ||
       (bytes[0] == 0xfe && bytes[1] == 0xff))) {
    return NO;
  }
  const NSUInteger sample = std::min<NSUInteger>(data.length, 4096);
  for (NSUInteger index = 0; index < sample; ++index) {
    if (bytes[index] == 0) return YES;
  }
  return NO;
}

template <typename Callback>
void enumerateGrepFiles(NSString* folder, bool recursive, NSProgress* progress,
                        NSArray<NSDictionary*>* folderExclusions,
                        const Callback& callback) {
  namespace fs = std::filesystem;
  std::error_code error;
  const fs::path root(folder.fileSystemRepresentation);
  fs::recursive_directory_iterator iterator(
      root,
      fs::directory_options::skip_permission_denied, error);
  const fs::recursive_directory_iterator end;
  while (iterator != end) {
    if (progress.cancelled) break;
    if (error) {
      error.clear();
      iterator.increment(error);
      continue;
    }
    const fs::directory_entry entry = *iterator;
    const fs::path path = entry.path();
    const std::string name = path.filename().string();
    const bool hidden = !name.empty() && name.front() == '.';
    const bool package = path.extension() == ".app" ||
                         path.extension() == ".bundle" ||
                         path.extension() == ".framework" ||
                         path.extension() == ".pkg";
    const auto status = entry.symlink_status(error);
    if (error) {
      error.clear();
      iterator.increment(error);
      continue;
    }
    if (fs::is_directory(status)) {
      if (!recursive || hidden || package ||
          grepDirectoryIsExcluded(path, root, folderExclusions)) {
        iterator.disable_recursion_pending();
      }
    } else if (!hidden && fs::is_regular_file(status)) {
      NSString* filePath = [[NSFileManager defaultManager]
          stringWithFileSystemRepresentation:path.c_str()
                                      length:path.native().size()];
      if (filePath != nil &&
          !callback([NSURL fileURLWithPath:filePath isDirectory:NO])) {
        break;
      }
    }
    iterator.increment(error);
  }
}

NSBox* separator() {
  NSBox* box = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, 1, 24)];
  box.boxType = NSBoxSeparator;
  return box;
}

NSView* toolbarSeparator() {
  NSView* space = [[NSView alloc]
      initWithFrame:NSMakeRect(0, 0, 8.0, kToolbarButtonSize)];
  [space.widthAnchor constraintEqualToConstant:8.0].active = YES;
  [space.heightAnchor constraintEqualToConstant:kToolbarButtonSize].active = YES;
  NSBox* line = [[NSBox alloc]
      initWithFrame:NSMakeRect(3.0, 3.0, 1.0, kToolbarButtonSize - 6.0)];
  line.boxType = NSBoxSeparator;
  line.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin |
                          NSViewMinYMargin | NSViewMaxYMargin;
  [space addSubview:line];
  return space;
}

}  // namespace

@interface SakuraWindowController () <NSTableViewDataSource, NSTableViewDelegate,
                                       NSWindowDelegate>
@property(nonatomic, strong, readwrite) SakuraEditorView* editorView;
@property(nonatomic, strong) NSView* rootView;
@property(nonatomic, strong) NSView* windowsMenuBarView;
@property(nonatomic, strong) NSView* toolbarView;
@property(nonatomic, strong) NSView* statusBarView;
@property(nonatomic, strong) NSView* editorHostView;
@property(nonatomic, strong) NSScrollView* primaryScrollView;
@property(nonatomic, strong, nullable) SakuraEditorView* secondaryEditorView;
@property(nonatomic, strong, nullable) NSScrollView* secondaryScrollView;
@property(nonatomic, strong, nullable) NSSplitView* editorSplitView;
@property(nonatomic, strong) NSSearchField* toolbarSearchField;
@property(nonatomic, strong) NSTextField* statusMessage;
@property(nonatomic, strong) NSTextField* statusPosition;
@property(nonatomic, strong) NSTextField* statusEol;
@property(nonatomic, strong) NSTextField* statusCharCode;
@property(nonatomic, strong) NSTextField* statusEncoding;
@property(nonatomic, strong) NSTextField* statusRecord;
@property(nonatomic, strong) NSTextField* statusMode;
@property(nonatomic, strong) NSTextField* statusZoom;
@property(nonatomic, strong, nullable) NSPanel* outlinePanel;
@property(nonatomic, strong, nullable) NSTableView* outlineTableView;
@property(nonatomic, strong, nullable) NSTextField* outlineStatusLabel;
@property(nonatomic, copy) NSArray<NSDictionary*>* outlineEntries;
@property(nonatomic, strong, nullable) NSPanel* commandPanel;
@property(nonatomic, strong, nullable) NSTableView* commandTableView;
@property(nonatomic, strong, nullable) NSTextField* commandStatusLabel;
@property(nonatomic, copy) NSArray<NSDictionary*>* commandEntries;
@property(nonatomic, strong, nullable) NSPanel* typeSettingsListPanel;
@property(nonatomic, strong, nullable) NSPanel* typeSettingsPanel;
@property(nonatomic, strong, nullable) NSTableView* typeColorTableView;
@property(nonatomic, strong, nullable) NSColorWell* typeForegroundColorWell;
@property(nonatomic, strong, nullable) NSColorWell* typeBackgroundColorWell;
@property(nonatomic, strong, nullable) NSButton* typeColorDisplayCheckbox;
@property(nonatomic, strong, nullable) NSButton* typeColorBoldCheckbox;
@property(nonatomic, strong, nullable) NSButton* typeColorUnderlineCheckbox;
@property(nonatomic, strong, nullable) NSTextField* typeColorPreview;
@property(nonatomic, copy) NSArray<NSDictionary*>* typeColorEntries;
@property(nonatomic, copy) NSString* typeColorIdentifier;
@property(nonatomic, strong, nullable) SakuraSettingsPreviewTransaction* typeColorTransaction;
@property(nonatomic, strong, nullable) NSPopUpButton* typeWrapModePopup;
@property(nonatomic, strong, nullable) NSTextField* typeWrapColumnField;
@property(nonatomic, strong, nullable) NSTextField* typeTabWidthField;
@property(nonatomic, strong, nullable) NSButton* typeLineNumbersCheckbox;
@property(nonatomic, strong, nullable) NSPopUpButton* typeFontPopup;
@property(nonatomic, strong, nullable) NSTextField* typeFontSizeField;
@property(nonatomic, strong, nullable) NSTextField* typeLineSpacingField;
@property(nonatomic, strong, nullable) NSTextField* typeCharacterSpacingField;
@property(nonatomic, strong, nullable) NSTextField* typeFontPreview;
@property(nonatomic, strong, nullable) NSTextField* typeDisplayResetStatus;
@property(nonatomic, copy, nullable) NSDictionary<NSString*, id>* typeDisplayBaselineValues;
@property(nonatomic) BOOL typeDisplayResetPending;
@property(nonatomic, strong, nullable) NSPanel* commonSettingsPanel;
@property(nonatomic, strong, nullable) NSTextField* commonFontSizeField;
@property(nonatomic, strong, nullable) NSTextField* commonTabWidthField;
@property(nonatomic, strong, nullable) NSPopUpButton* commonThemePopup;
@property(nonatomic, strong, nullable) NSPanel* encodingPanel;
@property(nonatomic, strong, nullable) NSPopUpButton* encodingPopup;
@property(nonatomic, strong, nullable) NSButton* encodingBomCheckbox;
@property(nonatomic, strong, nullable) NSPopUpButton* encodingEolPopup;
@property(nonatomic, strong, nullable) NSPanel* grepPanel;
@property(nonatomic, strong, nullable) NSSearchField* grepQueryField;
@property(nonatomic, strong, nullable) NSTextField* grepReplacementLabel;
@property(nonatomic, strong, nullable) NSTextField* grepReplacementField;
@property(nonatomic, strong, nullable) NSTextField* grepFolderField;
@property(nonatomic, strong, nullable) NSTextField* grepPatternField;
@property(nonatomic, strong, nullable) NSTextField* grepExcludedFolderField;
@property(nonatomic, strong, nullable) NSButton* grepCaseSensitiveButton;
@property(nonatomic, strong, nullable) NSButton* grepRegexButton;
@property(nonatomic, strong, nullable) NSButton* grepRecursiveButton;
@property(nonatomic, strong, nullable) NSTableView* grepTableView;
@property(nonatomic, strong, nullable) NSTextField* grepStatusLabel;
@property(nonatomic, strong, nullable) NSButton* grepRunButton;
@property(nonatomic, strong, nullable) NSButton* grepReplaceButton;
@property(nonatomic, strong, nullable) NSButton* grepBackupButton;
@property(nonatomic, strong) NSMutableArray<NSDictionary*>* grepResults;
@property(nonatomic, strong, nullable) NSProgress* grepProgress;
@property(nonatomic) BOOL grepReplaceMode;
@property(nonatomic, copy, nullable) NSString* grepPreviewSignature;
@property(nonatomic, copy, nullable) NSString* grepAuthorizedFolderPath;
@property(nonatomic) BOOL grepPreviewReady;
@property(nonatomic) BOOL grepReplacing;
@property(nonatomic, strong) NSMutableArray<NSNumber*>* navigationHistory;
@property(nonatomic) NSInteger navigationHistoryIndex;
@property(nonatomic) BOOL navigatingHistory;
@property(nonatomic, strong, nullable) NSPopUpButton* toolbarCategoryPopup;
@property(nonatomic, strong, nullable) NSButton* toolbarFlatCheckbox;
@property(nonatomic, strong, nullable) NSButton* toolbarVisibleCheckbox;
@property(nonatomic, strong, nullable) NSTableView* toolbarAvailableTable;
@property(nonatomic, strong, nullable) NSTableView* toolbarCurrentTable;
@property(nonatomic, copy) NSArray<NSDictionary*>* toolbarAvailableEntries;
@property(nonatomic, strong) NSMutableArray<NSString*>* toolbarDraftItems;
@end

@implementation SakuraWindowController {
  std::shared_ptr<std::vector<GrepReplacementCandidate>> _grepReplacementCandidates;
}

- (NSScrollView*)scrollViewForEditor:(SakuraEditorView*)editor
                                frame:(NSRect)frame {
  NSScrollView* scrollView = [[NSScrollView alloc] initWithFrame:frame];
  scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  scrollView.hasVerticalScroller = YES;
  scrollView.hasHorizontalScroller = YES;
  scrollView.autohidesScrollers = YES;
  scrollView.borderType = NSNoBorder;
  scrollView.drawsBackground = YES;
  scrollView.backgroundColor = SakuraEditorBackground(editor.effectiveAppearance);
  editor.autoresizingMask = NSViewWidthSizable;
  scrollView.documentView = editor;
  return scrollView;
}

- (NSArray<NSDictionary*>*)toolbarDescriptors {
  return @[
    @{ @"id": @"new", @"title": @"新規作成", @"category": @"ファイル",
       @"image": @"new", @"symbol": @"doc.badge.plus", @"action": @"newDocument:", @"enabled": @YES },
    @{ @"id": @"open", @"title": @"ファイルを開く", @"category": @"ファイル",
       @"image": @"open", @"symbol": @"folder", @"action": @"openDocument:",
       @"enabled": @YES, @"dropdown": @YES },
    @{ @"id": @"save", @"title": @"上書き保存", @"category": @"ファイル",
       @"image": @"save", @"symbol": @"square.and.arrow.down", @"action": @"saveDocument:", @"enabled": @YES },
    @{ @"id": @"save_as", @"title": @"名前を付けて保存", @"category": @"ファイル",
       @"image": @"save_as", @"symbol": @"doc.badge.ellipsis", @"action": @"saveDocumentAs:", @"enabled": @YES },
    @{ @"id": @"undo", @"title": @"元に戻す", @"category": @"編集",
       @"image": @"undo", @"symbol": @"arrow.uturn.backward", @"action": @"undo:", @"enabled": @YES },
    @{ @"id": @"redo", @"title": @"やり直し", @"category": @"編集",
       @"image": @"redo", @"symbol": @"arrow.uturn.forward", @"action": @"redo:", @"enabled": @YES },
    @{ @"id": @"history_back", @"title": @"移動履歴: 前へ", @"category": @"移動",
       @"image": @"history_back", @"symbol": @"arrow.left", @"action": @"goBackInNavigationHistory:", @"enabled": @YES },
    @{ @"id": @"history_forward", @"title": @"移動履歴: 次へ", @"category": @"移動",
       @"image": @"history_forward", @"symbol": @"arrow.right", @"action": @"goForwardInNavigationHistory:", @"enabled": @YES },
    @{ @"id": @"find", @"title": @"検索", @"category": @"検索",
       @"image": @"find", @"symbol": @"magnifyingglass", @"action": @"showFindPanel:", @"enabled": @YES },
    @{ @"id": @"find_next", @"title": @"次を検索", @"category": @"検索",
       @"image": @"find_next", @"symbol": @"chevron.down", @"action": @"findNext:", @"enabled": @YES },
    @{ @"id": @"find_previous", @"title": @"前を検索", @"category": @"検索",
       @"image": @"find_previous", @"symbol": @"chevron.up", @"action": @"findPrevious:", @"enabled": @YES },
    @{ @"id": @"replace", @"title": @"置換", @"category": @"検索",
       @"image": @"replace", @"symbol": @"arrow.left.arrow.right", @"action": @"replaceSearchSelection:", @"enabled": @YES },
    @{ @"id": @"clear_search", @"title": @"検索マークのクリア", @"category": @"検索",
       @"image": @"clear_search", @"symbol": @"xmark.circle", @"action": @"clearSearchMarks:", @"enabled": @YES },
    @{ @"id": @"grep", @"title": @"Grep", @"category": @"検索",
       @"image": @"grep", @"symbol": @"doc.text.magnifyingglass", @"action": @"showGrepPanel:", @"enabled": @YES },
    @{ @"id": @"outline", @"title": @"アウトライン解析", @"category": @"ツール",
       @"image": @"outline", @"symbol": @"list.bullet.indent", @"action": @"showOutlinePanel:", @"enabled": @YES },
    @{ @"id": @"type_list", @"title": @"タイプ別設定一覧", @"category": @"設定",
       @"image": @"type_list", @"symbol": @"list.bullet.rectangle", @"action": @"showTypeSettingsList:", @"enabled": @YES },
    @{ @"id": @"type_settings", @"title": @"タイプ別設定", @"category": @"設定",
       @"image": @"type_settings", @"symbol": @"doc.badge.gearshape", @"action": @"showTypeSettings:", @"enabled": @YES },
    @{ @"id": @"common_settings", @"title": @"共通設定", @"category": @"設定",
       @"image": @"common_settings", @"symbol": @"gearshape", @"action": @"showCommonSettings:", @"enabled": @YES },
    @{ @"id": @"command_list", @"title": @"コマンド一覧", @"category": @"ツール",
       @"image": @"command_list", @"symbol": @"list.clipboard", @"action": @"showCommandList:", @"enabled": @YES },
  ];
}

- (NSDictionary*)toolbarDescriptorForIdentifier:(NSString*)identifier {
  for (NSDictionary* descriptor in [self toolbarDescriptors]) {
    if ([descriptor[@"id"] isEqualToString:identifier]) {
      return descriptor;
    }
  }
  return nil;
}

- (NSArray<NSString*>*)configuredToolbarItems {
  NSArray* stored = [[NSUserDefaults standardUserDefaults]
      arrayForKey:@"SakuraToolbarItems"];
  NSMutableArray<NSString*>* valid = [NSMutableArray array];
  for (id value in stored) {
    if (![value isKindOfClass:[NSString class]]) {
      continue;
    }
    NSString* identifier = (NSString*)value;
    if ([identifier isEqualToString:@"separator"] ||
        [identifier isEqualToString:@"wrap"] ||
        [self toolbarDescriptorForIdentifier:identifier] != nil) {
      [valid addObject:identifier];
    }
  }
  return valid;
}

- (NSUInteger)toolbarRowCount {
  NSUInteger rows = 1;
  for (NSString* identifier in [self configuredToolbarItems]) {
    if ([identifier isEqualToString:@"wrap"]) {
      ++rows;
    }
  }
  return rows;
}

- (CGFloat)toolbarHeight {
  return kToolbarRowPadding +
      kToolbarButtonSize * static_cast<CGFloat>([self toolbarRowCount]);
}

- (NSImage*)toolbarImageNamed:(NSString*)name fallbackSymbol:(NSString*)symbol {
  // OS-provided symbols are not copied into or relicensed with this bundle.
  return [NSImage imageWithSystemSymbolName:symbol
                 accessibilityDescription:name];
}

- (NSView*)toolbarButtonForDescriptor:(NSDictionary*)descriptor {
  NSImage* image = [self toolbarImageNamed:descriptor[@"image"]
                            fallbackSymbol:descriptor[@"symbol"]];
  NSString* actionName = descriptor[@"action"];
  SEL action = actionName.length != 0 ? NSSelectorFromString(actionName) : nil;
  NSButton* button = [NSButton buttonWithImage:image
                                         target:self
                                         action:action];
  const BOOL flat = [[NSUserDefaults standardUserDefaults]
      boolForKey:@"SakuraToolbarFlat"];
  button.bezelStyle = flat ? NSBezelStyleShadowlessSquare
                           : NSBezelStyleSmallSquare;
  button.bordered = YES;
  button.controlSize = NSControlSizeSmall;
  button.imageScaling = NSImageScaleNone;
  button.toolTip = [descriptor[@"enabled"] boolValue]
      ? descriptor[@"title"]
      : [descriptor[@"title"] stringByAppendingString:@"（未実装）"];
  button.enabled = [descriptor[@"enabled"] boolValue];
  [button.widthAnchor constraintEqualToConstant:kToolbarButtonSize].active = YES;
  [button.heightAnchor constraintEqualToConstant:kToolbarButtonSize].active = YES;
  if (![descriptor[@"dropdown"] boolValue]) {
    return button;
  }
  constexpr CGFloat arrowWidth = 12.0;
  NSView* group = [[NSView alloc]
      initWithFrame:NSMakeRect(0, 0, kToolbarButtonSize + arrowWidth,
                               kToolbarButtonSize)];
  [group.widthAnchor constraintEqualToConstant:kToolbarButtonSize + arrowWidth].active = YES;
  [group.heightAnchor constraintEqualToConstant:kToolbarButtonSize].active = YES;
  button.frame = NSMakeRect(0, 0, kToolbarButtonSize, kToolbarButtonSize);
  button.autoresizingMask = NSViewMaxXMargin;
  [group addSubview:button];
  NSImage* arrowImage = [[NSImage imageWithSystemSymbolName:@"chevron.down"
                                   accessibilityDescription:@"最近使ったファイル"]
      imageWithSymbolConfiguration:[NSImageSymbolConfiguration
          configurationWithPointSize:7.0 weight:NSFontWeightMedium]];
  NSButton* arrow = [NSButton buttonWithImage:arrowImage
                                      target:self
                                      action:@selector(showOpenHistoryMenu:)];
  arrow.frame = NSMakeRect(kToolbarButtonSize, 0, arrowWidth,
                           kToolbarButtonSize);
  arrow.bezelStyle = flat ? NSBezelStyleShadowlessSquare
                          : NSBezelStyleSmallSquare;
  arrow.bordered = YES;
  arrow.imageScaling = NSImageScaleProportionallyDown;
  arrow.toolTip = @"最近使ったファイル";
  arrow.autoresizingMask = NSViewMinXMargin;
  [group addSubview:arrow];
  return group;
}

- (NSStackView*)newToolbarRow {
  NSStackView* row = [[NSStackView alloc] initWithFrame:NSZeroRect];
  row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  row.alignment = NSLayoutAttributeCenterY;
  row.spacing = 0.0;
  [row.heightAnchor constraintEqualToConstant:kToolbarButtonSize].active = YES;
  return row;
}

- (NSView*)makeToolbarWithFrame:(NSRect)frame {
  NSView* background = [[NSView alloc] initWithFrame:frame];
  background.wantsLayer = YES;
  background.layer.backgroundColor = SakuraChromeBackground(
      background.effectiveAppearance).CGColor;
  background.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;

  NSStackView* rows = [[NSStackView alloc]
      initWithFrame:NSInsetRect(background.bounds, 2.0, 1.0)];
  rows.orientation = NSUserInterfaceLayoutOrientationVertical;
  rows.alignment = NSLayoutAttributeLeading;
  rows.spacing = 0.0;
  rows.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  NSStackView* row = [self newToolbarRow];
  [rows addArrangedSubview:row];
  BOOL previousWasSeparator = NO;
  for (NSString* identifier in [self configuredToolbarItems]) {
    if ([identifier isEqualToString:@"wrap"]) {
      row = [self newToolbarRow];
      [rows addArrangedSubview:row];
      previousWasSeparator = NO;
      continue;
    }
    if ([identifier isEqualToString:@"separator"]) {
      if (row.arrangedSubviews.count != 0 && !previousWasSeparator) {
        [row addArrangedSubview:toolbarSeparator()];
        previousWasSeparator = YES;
      }
      continue;
    }
    NSDictionary* descriptor = [self toolbarDescriptorForIdentifier:identifier];
    if (descriptor != nil) {
      [row addArrangedSubview:[self toolbarButtonForDescriptor:descriptor]];
      previousWasSeparator = NO;
    }
  }
  for (NSStackView* toolbarRow in rows.arrangedSubviews) {
    NSView* flexible = [[NSView alloc] initWithFrame:NSZeroRect];
    [flexible setContentHuggingPriority:NSLayoutPriorityDefaultLow
                         forOrientation:NSLayoutConstraintOrientationHorizontal];
    [toolbarRow addArrangedSubview:flexible];
    [toolbarRow.widthAnchor constraintEqualToAnchor:rows.widthAnchor].active = YES;
  }
  [background addSubview:rows];

  NSBox* bottom = [[NSBox alloc]
      initWithFrame:NSMakeRect(0, 0, NSWidth(frame), 1)];
  bottom.boxType = NSBoxSeparator;
  bottom.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
  [background addSubview:bottom];
  return background;
}

- (NSPopUpButton*)windowsMenuButtonWithTitle:(NSString*)title {
  NSPopUpButton* button = [[NSPopUpButton alloc] initWithFrame:NSZeroRect
                                                     pullsDown:YES];
  button.bordered = NO;
  button.font = [NSFont systemFontOfSize:13.0];
  [(NSPopUpButtonCell*)button.cell setArrowPosition:NSPopUpNoArrow];
  NSMenu* pullDownMenu = [[NSMenu alloc] initWithTitle:title];
  [pullDownMenu addItemWithTitle:title action:nil keyEquivalent:@""];
  NSMenu* source = [NSApp.mainMenu itemWithTitle:title].submenu;
  for (NSMenuItem* item in source.itemArray) {
    if ([item.representedObject isEqual:kSakuraWindowsMenuMarker]) {
      [pullDownMenu addItem:[item copy]];
    }
  }
  button.menu = pullDownMenu;
  const CGFloat width = std::ceil(
      [title sizeWithAttributes:@{NSFontAttributeName : button.font}].width) + 18.0;
  [button.widthAnchor constraintEqualToConstant:width].active = YES;
  return button;
}

- (NSView*)makeWindowsMenuBarWithFrame:(NSRect)frame {
  NSView* background = [[NSView alloc] initWithFrame:frame];
  background.wantsLayer = YES;
  background.layer.backgroundColor = SakuraChromeBackground(
      background.effectiveAppearance).CGColor;
  background.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;

  NSStackView* stack = [[NSStackView alloc]
      initWithFrame:NSInsetRect(background.bounds, 4.0, 0.0)];
  stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  stack.alignment = NSLayoutAttributeCenterY;
  stack.spacing = 0.0;
  stack.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  for (NSString* title in @[
         @"ファイル", @"編集", @"変換", @"検索",
         @"ツール", @"設定", @"ウィンドウ", @"ヘルプ"
       ]) {
    [stack addArrangedSubview:[self windowsMenuButtonWithTitle:title]];
  }
  NSView* flexible = [[NSView alloc] initWithFrame:NSZeroRect];
  [flexible setContentHuggingPriority:NSLayoutPriorityDefaultLow
                       forOrientation:NSLayoutConstraintOrientationHorizontal];
  [stack addArrangedSubview:flexible];
  [background addSubview:stack];

  NSBox* bottom = [[NSBox alloc]
      initWithFrame:NSMakeRect(0, 0, NSWidth(frame), 1)];
  bottom.boxType = NSBoxSeparator;
  bottom.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
  [background addSubview:bottom];
  return background;
}

- (NSTextField*)statusLabel:(NSString*)value width:(CGFloat)width {
  NSTextField* label = [NSTextField labelWithString:value];
  label.font = [NSFont systemFontOfSize:11.0];
  label.lineBreakMode = NSLineBreakByTruncatingTail;
  label.alignment = NSTextAlignmentCenter;
  if (width > 0.0) {
    [label.widthAnchor constraintEqualToConstant:width].active = YES;
  } else {
    [label setContentHuggingPriority:NSLayoutPriorityDefaultLow
                      forOrientation:NSLayoutConstraintOrientationHorizontal];
  }
  return label;
}

- (NSView*)makeStatusBarWithFrame:(NSRect)frame {
  NSView* background = [[NSView alloc] initWithFrame:frame];
  background.wantsLayer = YES;
  background.layer.backgroundColor = SakuraChromeBackground(
      background.effectiveAppearance).CGColor;
  background.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;

  NSStackView* stack = [[NSStackView alloc]
      initWithFrame:NSInsetRect(background.bounds, 4.0, 2.0)];
  stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  stack.alignment = NSLayoutAttributeCenterY;
  stack.spacing = 5.0;
  stack.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  self.statusMessage = [self statusLabel:@"" width:0.0];
  self.statusMessage.alignment = NSTextAlignmentLeft;
  self.statusPosition = [self statusLabel:@"1 行 1 桁" width:108.0];
  self.statusEol = [self statusLabel:@"なし" width:48.0];
  self.statusCharCode = [self statusLabel:@"" width:78.0];
  self.statusEncoding = [self statusLabel:@"UTF-8" width:86.0];
  self.statusRecord = [self statusLabel:@"" width:34.0];
  self.statusMode = [self statusLabel:@"挿入" width:44.0];
  self.statusZoom = [self statusLabel:@"100 %" width:52.0];
  for (NSTextField* label in @[ self.statusMessage, self.statusPosition,
                                self.statusEol, self.statusCharCode,
                                self.statusEncoding, self.statusRecord,
                                self.statusMode, self.statusZoom ]) {
    if (stack.arrangedSubviews.count != 0) {
      [stack addArrangedSubview:separator()];
    }
    [stack addArrangedSubview:label];
  }
  [background addSubview:stack];
  NSBox* top = [[NSBox alloc]
      initWithFrame:NSMakeRect(0, NSHeight(frame) - 1, NSWidth(frame), 1)];
  top.boxType = NSBoxSeparator;
  top.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
  [background addSubview:top];
  return background;
}

- (instancetype)initWithDocument:(SakuraDocument*)document {
  NSRect contentRect = NSMakeRect(0, 0, 900, 660);
  NSWindowStyleMask style = NSWindowStyleMaskTitled |
                            NSWindowStyleMaskClosable |
                            NSWindowStyleMaskMiniaturizable |
                            NSWindowStyleMaskResizable;
  NSWindow* window = [[NSWindow alloc] initWithContentRect:contentRect
                                                 styleMask:style
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
  window.minSize = NSMakeSize(480, 300);
  window.releasedWhenClosed = NO;

  self = [super initWithWindow:window];
  if (self != nil) {
    // NSWindowController/NSDocument retain their existing delegate ownership.
    // Observe actual closure as well as -close: the titlebar can close the
    // window directly while its controller remains retained by a document.
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(editorWindowWillClose:)
        name:NSWindowWillCloseNotification object:window];
    _grepResults = [NSMutableArray array];
    _navigationHistory = [NSMutableArray array];
    _navigationHistoryIndex = -1;
    NSView* root = [[NSView alloc] initWithFrame:contentRect];
    root.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.rootView = root;
    self.windowsMenuBarView = [self makeWindowsMenuBarWithFrame:NSMakeRect(
        0, NSHeight(contentRect) - kWindowsMenuBarHeight, NSWidth(contentRect),
        kWindowsMenuBarHeight)];
    const CGFloat toolbarHeight = [self toolbarHeight];
    self.toolbarView = [self makeToolbarWithFrame:NSMakeRect(
        0, NSHeight(contentRect) - kWindowsMenuBarHeight - toolbarHeight,
        NSWidth(contentRect),
        toolbarHeight)];
    self.toolbarView.hidden = ![[NSUserDefaults standardUserDefaults]
        boolForKey:@"SakuraToolbarVisible"];
    self.statusBarView = [self makeStatusBarWithFrame:NSMakeRect(
        0, 0, NSWidth(contentRect), kStatusBarHeight)];
    [root addSubview:self.windowsMenuBarView];
    [root addSubview:self.toolbarView];
    [root addSubview:self.statusBarView];

    _editorHostView = [[NSView alloc] initWithFrame:NSMakeRect(
        0, kStatusBarHeight, NSWidth(contentRect),
        NSHeight(contentRect) - kWindowsMenuBarHeight -
            (self.toolbarView.hidden ? 0.0 : toolbarHeight) - kStatusBarHeight)];
    _editorHostView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [root addSubview:_editorHostView];

    _editorView = [[SakuraEditorView alloc]
        initWithFrame:_editorHostView.bounds document:document];
    _primaryScrollView = [self scrollViewForEditor:_editorView
                                              frame:_editorHostView.bounds];
    [_editorHostView addSubview:_primaryScrollView];
    window.contentView = root;
    window.initialFirstResponder = _editorView;
    [self applyColorTheme];
    [self updateStatusForEditor:_editorView];
  }
  return self;
}

- (void)finishTypeSettingsForOwnerClose {
  const BOOL hadTransaction = self.typeColorTransaction != nil;
  [self.typeColorTransaction cancel];
  self.typeColorTransaction = nil;
  [self.typeSettingsPanel orderOut:self];
  if (hadTransaction) [self redrawEditorsForTypeColorChange];
}

- (void)editorWindowWillClose:(NSNotification*)notification {
  (void)notification;
  [self finishTypeSettingsForOwnerClose];
}

- (void)close {
  [self finishTypeSettingsForOwnerClose];
  [super close];
}

- (void)applyChromeTextColorInView:(NSView*)view {
  NSColor* textColor = SakuraChromeText(view.effectiveAppearance);
  if ([view isKindOfClass:[NSTextField class]]) {
    ((NSTextField*)view).textColor = textColor;
  } else if ([view isKindOfClass:[NSButton class]]) {
    ((NSButton*)view).contentTintColor = textColor;
  }
  for (NSView* child in view.subviews) {
    [self applyChromeTextColorInView:child];
  }
}

- (void)applyColorTheme {
  NSString* mode = [[NSUserDefaults standardUserDefaults]
      stringForKey:SakuraEditorColorThemeKey];
  if ([mode isEqualToString:SakuraEditorColorThemeDark]) {
    self.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
  } else if ([mode isEqualToString:SakuraEditorColorThemeSystem]) {
    self.window.appearance = nil;
  } else {
    self.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
  }

  NSColor* chrome = SakuraChromeBackground(self.rootView.effectiveAppearance);
  for (NSView* view in @[
         self.windowsMenuBarView, self.toolbarView, self.statusBarView
       ]) {
    view.layer.backgroundColor = chrome.CGColor;
    [self applyChromeTextColorInView:view];
    [view setNeedsDisplay:YES];
  }
  for (NSScrollView* scrollView in self.secondaryScrollView != nil
           ? @[ self.primaryScrollView, self.secondaryScrollView ]
           : @[ self.primaryScrollView ]) {
    scrollView.backgroundColor = SakuraEditorBackground(
        scrollView.effectiveAppearance);
  }
  for (SakuraEditorView* editor in self.editorViews) {
    [editor setNeedsDisplay:YES];
  }
  self.commonSettingsPanel.appearance = self.window.appearance;
  self.typeSettingsPanel.appearance = self.window.appearance;
  self.typeSettingsListPanel.appearance = self.window.appearance;
  self.outlinePanel.appearance = self.window.appearance;
  self.commandPanel.appearance = self.window.appearance;
  self.grepPanel.appearance = self.window.appearance;
}

- (void)relayoutChrome {
  const NSRect bounds = self.rootView.bounds;
  const CGFloat toolbarHeight = [self toolbarHeight];
  const CGFloat top = kWindowsMenuBarHeight +
                      (self.toolbarView.hidden ? 0.0 : toolbarHeight);
  const CGFloat bottom = self.statusBarView.hidden ? 0.0 : kStatusBarHeight;
  self.windowsMenuBarView.frame = NSMakeRect(
      0, NSHeight(bounds) - kWindowsMenuBarHeight, NSWidth(bounds),
      kWindowsMenuBarHeight);
  self.toolbarView.frame = NSMakeRect(
      0, NSHeight(bounds) - kWindowsMenuBarHeight - toolbarHeight,
      NSWidth(bounds), toolbarHeight);
  self.statusBarView.frame = NSMakeRect(0, 0, NSWidth(bounds), kStatusBarHeight);
  self.editorHostView.frame = NSMakeRect(0, bottom, NSWidth(bounds),
                                         std::max<CGFloat>(0.0,
                                             NSHeight(bounds) - top - bottom));
}

- (void)rebuildToolbar {
  const BOOL hidden = ![[NSUserDefaults standardUserDefaults]
      boolForKey:@"SakuraToolbarVisible"];
  const NSRect previousFrame = self.toolbarView.frame;
  [self.toolbarView removeFromSuperview];
  self.toolbarView = [self makeToolbarWithFrame:previousFrame];
  self.toolbarView.hidden = hidden;
  [self.rootView addSubview:self.toolbarView];
  [self relayoutChrome];
  [self applyColorTheme];
}

- (void)toggleToolbar:(id)sender {
  (void)sender;
  self.toolbarView.hidden = !self.toolbarView.hidden;
  [[NSUserDefaults standardUserDefaults]
      setBool:!self.toolbarView.hidden forKey:@"SakuraToolbarVisible"];
  self.toolbarVisibleCheckbox.state = self.toolbarView.hidden
      ? NSControlStateValueOff : NSControlStateValueOn;
  [self relayoutChrome];
}

- (void)toggleStatusBar:(id)sender {
  (void)sender;
  self.statusBarView.hidden = !self.statusBarView.hidden;
  [self relayoutChrome];
}

- (NSArray<SakuraEditorView*>*)editorViews {
  return self.secondaryEditorView != nil
             ? @[ self.editorView, self.secondaryEditorView ]
             : @[ self.editorView ];
}

- (void)newDocument:(id)sender {
  [[NSDocumentController sharedDocumentController] newDocument:sender];
}

- (void)openDocument:(id)sender {
  if ([NSApp.delegate respondsToSelector:@selector(openDocument:)]) {
    [NSApp.delegate performSelector:@selector(openDocument:) withObject:sender];
  }
}

- (void)showOpenHistoryMenu:(NSButton*)sender {
  NSMenu* menu = [[NSMenu alloc] initWithTitle:@"最近使ったファイル"];
  NSMenuItem* open = [[NSMenuItem alloc] initWithTitle:@"ファイルを開く..."
                                                  action:@selector(openDocument:)
                                           keyEquivalent:@""];
  open.target = self;
  [menu addItem:open];
  NSArray<NSURL*>* recent = [NSDocumentController sharedDocumentController]
      .recentDocumentURLs;
  if (recent.count != 0) {
    [menu addItem:[NSMenuItem separatorItem]];
  }
  const NSUInteger limit = std::min<NSUInteger>(recent.count, 10);
  for (NSUInteger index = 0; index < limit; ++index) {
    NSURL* url = recent[index];
    NSMenuItem* item = [[NSMenuItem alloc]
        initWithTitle:url.lastPathComponent
               action:@selector(openRecentDocumentFromToolbar:)
        keyEquivalent:@""];
    item.target = self;
    item.representedObject = url;
    item.toolTip = url.path;
    [menu addItem:item];
  }
  [menu popUpMenuPositioningItem:nil
                      atLocation:NSMakePoint(0.0, 0.0)
                          inView:sender];
}

- (void)openRecentDocumentFromToolbar:(NSMenuItem*)sender {
  NSURL* url = [sender.representedObject isKindOfClass:[NSURL class]]
      ? (NSURL*)sender.representedObject : nil;
  if (url == nil) {
    NSBeep();
    return;
  }
  [[NSDocumentController sharedDocumentController]
      openDocumentWithContentsOfURL:url
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

- (void)saveDocument:(id)sender {
  [self.document saveDocument:sender];
}

- (void)saveDocumentAs:(id)sender {
  [self.document saveDocumentAs:sender];
}

- (SakuraEditorView*)activeEditor {
  return [self.window.firstResponder isKindOfClass:[SakuraEditorView class]]
             ? (SakuraEditorView*)self.window.firstResponder
             : self.editorView;
}

- (void)noteNavigationFromOffset:(NSUInteger)fromOffset
                        toOffset:(NSUInteger)toOffset {
  if (self.navigatingHistory || fromOffset == toOffset) return;
  while (self.navigationHistory.count >
         static_cast<NSUInteger>(self.navigationHistoryIndex + 1)) {
    [self.navigationHistory removeLastObject];
  }
  if (self.navigationHistory.count == 0 ||
      self.navigationHistory.lastObject.unsignedIntegerValue != fromOffset) {
    [self.navigationHistory addObject:@(fromOffset)];
  }
  if (self.navigationHistory.lastObject.unsignedIntegerValue != toOffset) {
    [self.navigationHistory addObject:@(toOffset)];
  }
  while (self.navigationHistory.count > 256) {
    [self.navigationHistory removeObjectAtIndex:0];
  }
  self.navigationHistoryIndex =
      static_cast<NSInteger>(self.navigationHistory.count) - 1;
}

- (void)registerCurrentNavigationPosition:(id)sender {
  (void)sender;
  const NSUInteger offset = [self.activeEditor currentDocumentOffset];
  while (self.navigationHistory.count >
         static_cast<NSUInteger>(self.navigationHistoryIndex + 1)) {
    [self.navigationHistory removeLastObject];
  }
  if (self.navigationHistory.count == 0 ||
      self.navigationHistory.lastObject.unsignedIntegerValue != offset) {
    [self.navigationHistory addObject:@(offset)];
  }
  self.navigationHistoryIndex =
      static_cast<NSInteger>(self.navigationHistory.count) - 1;
}

- (void)goBackInNavigationHistory:(id)sender {
  (void)sender;
  if (self.navigationHistoryIndex <= 0) {
    NSBeep();
    return;
  }
  self.navigatingHistory = YES;
  --self.navigationHistoryIndex;
  [self.activeEditor jumpToDocumentOffset:
      self.navigationHistory[static_cast<NSUInteger>(
          self.navigationHistoryIndex)].unsignedIntegerValue];
  self.navigatingHistory = NO;
}

- (void)goForwardInNavigationHistory:(id)sender {
  (void)sender;
  if (self.navigationHistoryIndex < 0 ||
      self.navigationHistoryIndex + 1 >=
          static_cast<NSInteger>(self.navigationHistory.count)) {
    NSBeep();
    return;
  }
  self.navigatingHistory = YES;
  ++self.navigationHistoryIndex;
  [self.activeEditor jumpToDocumentOffset:
      self.navigationHistory[static_cast<NSUInteger>(
          self.navigationHistoryIndex)].unsignedIntegerValue];
  self.navigatingHistory = NO;
}

- (void)undo:(id)sender {
  [NSApp sendAction:@selector(undo:) to:[self activeEditor] from:sender];
}

- (void)redo:(id)sender {
  [NSApp sendAction:@selector(redo:) to:[self activeEditor] from:sender];
}

- (void)showFindPanel:(id)sender {
  [NSApp sendAction:@selector(showFindPanel:) to:[self activeEditor] from:sender];
}

- (void)findNext:(id)sender {
  [NSApp sendAction:@selector(findNext:) to:[self activeEditor] from:sender];
}

- (void)findPrevious:(id)sender {
  [NSApp sendAction:@selector(findPrevious:) to:[self activeEditor] from:sender];
}

- (void)clearSearchMarks:(id)sender {
  [NSApp sendAction:@selector(clearSearchMarks:)
                  to:[self activeEditor]
                from:sender];
}

- (NSUserDefaults*)grepDefaults {
  return NSUserDefaults.standardUserDefaults;
}

- (NSString*)grepSearchSignature {
  NSArray* values = @[
      self.grepQueryField.stringValue ?: @"",
      [self.grepFolderField.stringValue stringByStandardizingPath] ?: @"",
      self.grepPatternField.stringValue ?: @"",
      self.grepExcludedFolderField.stringValue ?: @"",
      self.grepReplaceMode ? (self.grepReplacementField.stringValue ?: @"") : @"",
      @(self.grepCaseSensitiveButton.state == NSControlStateValueOn),
      @(self.grepRegexButton.state == NSControlStateValueOn),
      @(self.grepRecursiveButton.state == NSControlStateValueOn)];
  NSData* serialized = [NSJSONSerialization dataWithJSONObject:values options:0 error:nil];
  return [[NSString alloc] initWithData:serialized encoding:NSUTF8StringEncoding];
}

- (void)configureGrepPanelForReplaceMode:(BOOL)replaceMode {
  self.grepReplaceMode = replaceMode;
  self.grepPanel.title = replaceMode ? @"Grep置換" : @"Grep";
  self.grepReplacementLabel.hidden = !replaceMode;
  self.grepReplacementField.hidden = !replaceMode;
  self.grepReplaceButton.hidden = !replaceMode;
  self.grepBackupButton.hidden = !replaceMode;
  self.grepRunButton.title = replaceMode ? @"候補を検索" : @"検索";
  self.grepReplaceButton.enabled = replaceMode &&
      self.grepPreviewReady && !self.grepReplacing &&
      [self.grepPreviewSignature isEqualToString:[self grepSearchSignature]];
}

- (void)setGrepControlsEnabled:(BOOL)enabled {
  for (NSControl* control in @[
      self.grepQueryField, self.grepReplacementField, self.grepFolderField,
      self.grepPatternField, self.grepExcludedFolderField,
      self.grepCaseSensitiveButton, self.grepRegexButton,
      self.grepRecursiveButton, self.grepBackupButton, self.grepRunButton]) {
    control.enabled = enabled;
  }
}

- (BOOL)isGrepFileOpen:(const std::filesystem::path&)path {
  for (NSDocument* document in
       NSDocumentController.sharedDocumentController.documents) {
    NSString* documentPath = document.fileURL.path;
    if (documentPath.length == 0) continue;
    std::error_code error;
    if (std::filesystem::equivalent(
        path, std::filesystem::path(documentPath.fileSystemRepresentation),
        error)) return YES;
  }
  return NO;
}

- (void)chooseGrepFolder:(id)sender {
  (void)sender;
  if (self.grepReplacing) return;
  NSOpenPanel* panel = [NSOpenPanel openPanel];
  panel.canChooseDirectories = YES;
  panel.canChooseFiles = NO;
  panel.allowsMultipleSelection = NO;
  if (self.grepFolderField.stringValue.length != 0) {
    panel.directoryURL = [NSURL fileURLWithPath:self.grepFolderField.stringValue
                                    isDirectory:YES];
  }
  [panel beginSheetModalForWindow:self.grepPanel
                completionHandler:^(NSModalResponse response) {
    if (response == NSModalResponseOK) {
      self.grepFolderField.stringValue = panel.URL.path;
      self.grepAuthorizedFolderPath = panel.URL.path.stringByStandardizingPath;
    }
  }];
}

- (void)cancelGrep:(id)sender {
  (void)sender;
  [self.grepProgress cancel];
  self.grepPreviewReady = NO;
  self.grepReplaceButton.enabled = NO;
  self.grepStatusLabel.stringValue = @"キャンセルしています…";
}

- (void)appendGrepResults:(NSArray<NSDictionary*>*)results
                 progress:(NSProgress*)progress {
  if (self.grepProgress != progress || progress.cancelled) return;
  [self.grepResults addObjectsFromArray:results];
  [self.grepTableView reloadData];
  self.grepStatusLabel.stringValue = [NSString
      stringWithFormat:@"検索中… %lu 件", (unsigned long)self.grepResults.count];
}

- (void)startGrep:(id)sender {
  (void)sender;
  if (self.grepReplacing) return;
  NSString* query = self.grepQueryField.stringValue;
  NSString* folder = [self.grepFolderField.stringValue
      stringByStandardizingPath];
  BOOL isDirectory = NO;
  NSArray<NSString*>* protectedFolders = @[
    [NSHomeDirectory() stringByAppendingPathComponent:@"Desktop"],
    [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"],
    [NSHomeDirectory() stringByAppendingPathComponent:@"Downloads"],
    [NSHomeDirectory() stringByAppendingPathComponent:@"Movies"],
    [NSHomeDirectory() stringByAppendingPathComponent:@"Music"],
    [NSHomeDirectory() stringByAppendingPathComponent:@"Pictures"],
  ];
  BOOL needsFolderAuthorization = NO;
  for (NSString* protectedFolder in protectedFolders) {
    if ([folder isEqualToString:protectedFolder] ||
        [folder hasPrefix:[protectedFolder stringByAppendingString:@"/"]]) {
      needsFolderAuthorization =
          ![self.grepAuthorizedFolderPath isEqualToString:folder];
      break;
    }
  }
  if (needsFolderAuthorization) {
    self.grepStatusLabel.stringValue =
        @"macOS保護フォルダーは「参照…」から選択してください。";
    NSBeep();
    return;
  }
  if (query.length == 0 ||
      ![[NSFileManager defaultManager] fileExistsAtPath:folder
                                            isDirectory:&isDirectory] ||
      !isDirectory) {
    self.grepStatusLabel.stringValue = query.length == 0
        ? @"検索文字列を入力してください。" : @"検索フォルダーが見つかりません。";
    NSBeep();
    return;
  }

  NSArray<NSString*>* patterns = grepPatternsFromString(
      self.grepPatternField.stringValue);
  NSString* excludedFolderText = [self.grepExcludedFolderField.stringValue copy] ?: @"";
  NSString* exclusionError = nil;
  NSArray<NSDictionary*>* folderExclusions = grepFolderExclusionsFromString(
      excludedFolderText, &exclusionError);
  if (folderExclusions == nil) {
    [self.grepProgress cancel];
    self.grepProgress = nil;
    self.grepPreviewReady = NO;
    _grepReplacementCandidates.reset();
    self.grepReplaceButton.enabled = NO;
    self.grepStatusLabel.stringValue = exclusionError;
    NSBeep();
    return;
  }
  const BOOL caseSensitive = self.grepCaseSensitiveButton.state ==
                             NSControlStateValueOn;
  const BOOL regularExpression = self.grepRegexButton.state ==
                                 NSControlStateValueOn;
  const BOOL recursive = self.grepRecursiveButton.state ==
                         NSControlStateValueOn;
  const auto needle = sakura::platform::mac::sakuraStringFromString(query);
  const sakura::core::SearchOptions searchOptions{
      .caseSensitive = static_cast<bool>(caseSensitive),
      .wholeWord = false, .wrap = false,
      .regularExpression = static_cast<bool>(regularExpression)};
  if (!sakura::core::SearchEngine{}.isValidPattern(needle, searchOptions)) {
    self.grepStatusLabel.stringValue = @"正規表現が正しくありません。";
    NSBeep();
    return;
  }
  [[self grepDefaults] setObject:excludedFolderText forKey:@"SakuraGrepExcludedFolders"];
  const BOOL replaceMode = self.grepReplaceMode;
  const auto replacement = sakura::platform::mac::sakuraStringFromString(
      self.grepReplacementField.stringValue);

  [self.grepProgress cancel];
  NSProgress* progress = [NSProgress progressWithTotalUnitCount:0];
  self.grepProgress = progress;
  self.grepPreviewReady = NO;
  auto candidates = std::make_shared<std::vector<GrepReplacementCandidate>>();
  _grepReplacementCandidates = candidates;
  [self.grepResults removeAllObjects];
  [self.grepTableView reloadData];
  self.grepStatusLabel.stringValue = [NSString stringWithFormat:
      @"検索中… %@", folder.lastPathComponent.length != 0
          ? folder.lastPathComponent : folder];
  self.grepReplaceButton.enabled = NO;
  self.grepPreviewSignature = [self grepSearchSignature];
  __weak SakuraWindowController* weakSelf = self;

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @autoreleasepool {
      NSFileManager* manager = [[NSFileManager alloc] init];
      NSMutableArray<NSDictionary*>* batch = [NSMutableArray array];
      NSUInteger filesScanned = 0;
      NSUInteger resultCount = 0;
      NSUInteger errors = 0;
      std::size_t retainedBytes = 0;
      BOOL limitReached = NO;
      BOOL memoryLimitReached = NO;
      auto cancellableOptions = searchOptions;
      cancellableOptions.maxMatches = 20001;
      cancellableOptions.cancelled = [progress]() {
        return static_cast<bool>(progress.cancelled);
      };
      try {
        enumerateGrepFiles(folder, recursive, progress, folderExclusions, [&](NSURL* url) {
        if (progress.cancelled) return false;
        const std::filesystem::path path(url.path.fileSystemRepresentation);
        if (replaceMode && sakura::platform::mac::isGrepBackupPath(path)) {
          return true;
        }
        NSDictionary* attributes = [manager attributesOfItemAtPath:url.path
                                                              error:nil];
        if (![attributes[NSFileType] isEqual:NSFileTypeRegular]) return true;
        if (!grepFileNameMatches(url.lastPathComponent, patterns)) return true;
        const unsigned long long fileSize = [attributes[NSFileSize]
            unsignedLongLongValue];
        if (fileSize > 32ULL * 1024ULL * 1024ULL) return true;
        ++filesScanned;
        auto read = sakura::platform::mac::readGrepFileSnapshot(
            path, 32ULL * 1024ULL * 1024ULL);
        if (!read.snapshot.has_value()) { ++errors; return true; }
        const auto& bytes = read.snapshot->bytes;
        NSData* data = [NSData dataWithBytes:bytes.data() length:bytes.size()];
        if (grepDataLooksBinary(data)) return true;
        sakura::app::DocumentSession session(
            sakura::platform::mac::macEncodingService());
        if (!session.load(bytes).ok()) { ++errors; return true; }
        const auto& buffer = session.buffer();
        cancellableOptions.maxMatches = 20001 - resultCount;
        const auto matches = session.findAll(needle, cancellableOptions);
        for (const auto& match : matches) {
          if (progress.cancelled) break;
          const auto position = buffer.positionAt(match.range.location);
          const auto& lineContent = buffer.line(position.line).content;
          std::size_t previewLength = std::min<std::size_t>(180, lineContent.size());
          if (previewLength < lineContent.size() && previewLength != 0 &&
              lineContent[previewLength - 1] >= 0xD800 &&
              lineContent[previewLength - 1] <= 0xDBFF) --previewLength;
          NSString* preview = sakura::platform::mac::stringFromSakuraString(
              sakura::core::SakuraStringView(lineContent).substr(0, previewLength));
          preview = [preview stringByReplacingOccurrencesOfString:@"\t"
                                                        withString:@"    "];
          if (preview.length > 180 || previewLength < lineContent.size()) {
            const NSUInteger end = std::min<NSUInteger>(179, preview.length);
            const NSRange finalCharacter = end < preview.length
                ? [preview rangeOfComposedCharacterSequenceAtIndex:end]
                : NSMakeRange(end, 0);
            preview = [[preview substringToIndex:finalCharacter.location]
                stringByAppendingString:@"…"];
          }
          NSString* relativePath = url.path;
          if ([relativePath hasPrefix:folder] &&
              relativePath.length > folder.length + 1) {
            relativePath = [relativePath substringFromIndex:folder.length + 1];
          }
          NSString* title = [NSString stringWithFormat:@"%@:%zu:%llu: %@",
              relativePath, position.line + 1,
              static_cast<unsigned long long>(position.column + 1), preview];
          [batch addObject:@{
            @"title" : title,
            @"url" : url,
            @"offset" : @(static_cast<unsigned long long>(match.range.location)),
          }];
          ++resultCount;
          if (batch.count >= 100) {
            NSArray<NSDictionary*>* delivered = [batch copy];
            [batch removeAllObjects];
            dispatch_async(dispatch_get_main_queue(), ^{
              [weakSelf appendGrepResults:delivered progress:progress];
            });
          }
          if (resultCount >= 20000) {
            limitReached = YES;
            break;
          }
        }
        if (replaceMode && !matches.empty() && !limitReached &&
            !progress.cancelled) {
          const std::size_t remaining = kGrepPreviewMemoryLimit - retainedBytes;
          if (bytes.size() >= remaining) {
            memoryLimitReached = YES;
            return false;
          }
          // Bound expansion before allocating it, including $` / $' copies.
          // Reserve headroom for UTF-16 working storage and encoded output.
          cancellableOptions.maxReplacementCodeUnits =
              (remaining - bytes.size()) / 8;
          if (cancellableOptions.maxReplacementCodeUnits == 0) {
            memoryLimitReached = YES;
            return false;
          }
          const auto replaced = session.replaceAll(needle, replacement,
                                                     cancellableOptions);
          if (!replaced.valid || replaced.replacements != matches.size()) {
            ++errors;
            return true;
          }
          auto saved = session.makeSaveSnapshot();
          if (!saved.encoded.ok()) { ++errors; return true; }
          const std::size_t cost = bytes.size() + saved.encoded.bytes.size();
          if (cost > kGrepPreviewMemoryLimit - retainedBytes) {
            memoryLimitReached = YES;
            return false;
          }
          retainedBytes += cost;
          candidates->push_back({std::move(*read.snapshot),
              std::move(saved.encoded.bytes), replaced.replacements});
        }
        return !limitReached && !progress.cancelled;
        });
      } catch (const std::length_error&) {
        memoryLimitReached = YES;
      } catch (const std::exception&) {
        ++errors;
      }
      if (batch.count != 0 && !progress.cancelled) {
        NSArray<NSDictionary*>* delivered = [batch copy];
        dispatch_async(dispatch_get_main_queue(), ^{
          [weakSelf appendGrepResults:delivered progress:progress];
        });
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        SakuraWindowController* controller = weakSelf;
        if (controller == nil || controller.grepProgress != progress) return;
        if (memoryLimitReached) {
          controller.grepStatusLabel.stringValue =
              @"候補保持の上限に達しました。検索範囲を絞ってください。";
        } else if (limitReached) {
          controller.grepStatusLabel.stringValue =
              @"20,000件に達したため検索を終了しました。";
        } else if (progress.cancelled) {
          controller.grepStatusLabel.stringValue = [NSString
              stringWithFormat:@"キャンセルしました（%luファイル、%lu件）",
                  (unsigned long)filesScanned,
                  (unsigned long)controller.grepResults.count];
        } else {
          controller.grepStatusLabel.stringValue = [NSString
              stringWithFormat:@"%luファイル、%lu件／読込・変換エラー%lu",
                  (unsigned long)filesScanned,
                  (unsigned long)controller.grepResults.count,
                  (unsigned long)errors];
        }
        controller.grepPreviewReady = replaceMode && !limitReached &&
            !memoryLimitReached && !progress.cancelled && errors == 0 &&
            !candidates->empty();
        if (!controller.grepPreviewReady) {
          candidates->clear();
          controller->_grepReplacementCandidates.reset();
        }
        controller.grepReplaceButton.enabled =
            controller.grepPreviewReady && controller.grepReplaceMode &&
            [controller.grepPreviewSignature
                isEqualToString:[controller grepSearchSignature]];
      });
    }
  });
}

- (void)executeGrepReplace:(id)sender {
  (void)sender;
  if (!self.grepReplaceMode || !self.grepPreviewReady || self.grepReplacing ||
      !_grepReplacementCandidates || _grepReplacementCandidates->empty()) {
    NSBeep();
    return;
  }
  if (![self.grepPreviewSignature isEqualToString:[self grepSearchSignature]]) {
    self.grepReplaceButton.enabled = NO;
    self.grepStatusLabel.stringValue =
        @"条件が変更されました。候補を再検索してください。";
    NSBeep();
    return;
  }

  const NSUInteger previewCount = self.grepResults.count;
  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = [NSString stringWithFormat:
      @"%lu件の候補をファイル上で置換しますか？",
      (unsigned long)previewCount];
  alert.informativeText =
      @"開いている文書は競合防止のためスキップします。"
       @"処理は元の文字コードとBOMを維持します。";
  [alert addButtonWithTitle:@"置換実行"];
  [alert addButtonWithTitle:@"キャンセル"];
  const auto candidates = _grepReplacementCandidates;
  NSString* signature = self.grepPreviewSignature;
  const BOOL createsBackup = self.grepBackupButton.state ==
                             NSControlStateValueOn;
  self.grepReplacing = YES;
  [self setGrepControlsEnabled:NO];
  self.grepReplaceButton.enabled = NO;
  __weak SakuraWindowController* weakSelf = self;
  [alert beginSheetModalForWindow:self.grepPanel
               completionHandler:^(NSModalResponse response) {
    SakuraWindowController* controller = weakSelf;
    if (controller == nil) return;
    if (response != NSAlertFirstButtonReturn) {
      controller.grepReplacing = NO;
      [controller setGrepControlsEnabled:YES];
      [controller configureGrepPanelForReplaceMode:controller.grepReplaceMode];
      return;
    }
    if (!controller.grepPreviewReady ||
        ![signature isEqualToString:[controller grepSearchSignature]]) {
      controller.grepReplacing = NO;
      [controller setGrepControlsEnabled:YES];
      controller.grepPreviewReady = NO;
      controller.grepStatusLabel.stringValue = @"候補を再検索してください。";
      return;
    }

    [controller.grepProgress cancel];
    NSProgress* progress = [NSProgress progressWithTotalUnitCount:0];
    controller.grepProgress = progress;
    controller.grepReplaceButton.enabled = NO;
    controller.grepRunButton.enabled = NO;
    controller.grepPreviewReady = NO;
    controller.grepStatusLabel.stringValue = @"置換中…";

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      @autoreleasepool {
        NSUInteger filesChanged = 0;
        NSUInteger replacementsMade = 0;
        NSUInteger filesSkipped = 0;
        NSUInteger conflicts = 0;
        NSUInteger errors = 0;
        NSMutableArray<NSDictionary*>* outcomes = [NSMutableArray array];
        for (const auto& candidate : *candidates) {
          if (progress.cancelled) break;
          const auto path = candidate.original.path;
          const auto isOpen = [&]() {
            __block BOOL open = YES;
            dispatch_sync(dispatch_get_main_queue(), ^{
              SakuraWindowController* live = weakSelf;
              open = live == nil || [live isGrepFileOpen:path];
            });
            return static_cast<bool>(open);
          };
          if (isOpen()) {
            ++filesSkipped;
            NSURL* url = [NSURL fileURLWithFileSystemRepresentation:path.c_str()
                isDirectory:NO relativeToURL:nil];
            [outcomes addObject:@{@"title": [@"編集中のためスキップ: "
                stringByAppendingString:url.path], @"url": url, @"offset": @0}];
            continue;
          }
          const auto result = sakura::platform::mac::commitGrepReplacement(
              candidate.original, candidate.output,
              {.createBackup = static_cast<bool>(createsBackup),
               .cancelled = [progress]() { return progress.cancelled; },
               .beforeCommit = [&]() {
                 return !progress.cancelled && !isOpen();
               }});
          NSString* outcome = @"";
          switch (result.status) {
            case sakura::platform::mac::GrepCommitStatus::written:
              ++filesChanged;
              replacementsMade += candidate.replacements;
              outcome = @"置換完了";
              break;
            case sakura::platform::mac::GrepCommitStatus::conflict:
              ++conflicts;
              outcome = @"変更競合のためスキップ";
              break;
            case sakura::platform::mac::GrepCommitStatus::cancelled:
              outcome = @"保存前に中止";
              break;
            case sakura::platform::mac::GrepCommitStatus::error:
              ++errors;
              outcome = @"保存エラー";
              break;
          }
          NSURL* url = [NSURL fileURLWithFileSystemRepresentation:path.c_str()
              isDirectory:NO relativeToURL:nil];
          NSString* detail = stringFromUtf8(result.error);
          NSString* title = [NSString stringWithFormat:@"%@: %@%@%@", outcome,
              url.path, detail.length ? @" — " : @"", detail];
          [outcomes addObject:@{@"title": title, @"url": url, @"offset": @0}];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
          SakuraWindowController* finished = weakSelf;
          if (finished == nil || finished.grepProgress != progress) return;
          finished.grepReplacing = NO;
          [finished setGrepControlsEnabled:YES];
          finished->_grepReplacementCandidates.reset();
          [finished.grepResults removeAllObjects];
          [finished.grepResults addObjectsFromArray:outcomes];
          [finished.grepTableView reloadData];
          finished.grepPreviewSignature = nil;
          if (progress.cancelled) {
            finished.grepStatusLabel.stringValue = [NSString
                stringWithFormat:@"中止（%luファイル、%lu件置換）",
                    (unsigned long)filesChanged,
                    (unsigned long)replacementsMade];
          } else {
            finished.grepStatusLabel.stringValue = [NSString stringWithFormat:
                @"%luファイル、%lu件置換／編集中%lu／変更競合%lu／エラー%lu",
                (unsigned long)filesChanged,
                (unsigned long)replacementsMade,
                (unsigned long)filesSkipped, (unsigned long)conflicts,
                (unsigned long)errors];
          }
          finished.grepStatusLabel.toolTip = finished.grepStatusLabel.stringValue;
        });
      }
    });
  }];
}

- (void)grepSelectionActivated:(id)sender {
  (void)sender;
  const NSInteger row = self.grepTableView.selectedRow;
  if (row < 0 || static_cast<NSUInteger>(row) >= self.grepResults.count) {
    NSBeep();
    return;
  }
  NSDictionary* result = self.grepResults[static_cast<NSUInteger>(row)];
  NSURL* url = result[@"url"];
  const NSUInteger offset = [result[@"offset"] unsignedIntegerValue];
  [[NSDocumentController sharedDocumentController]
      openDocumentWithContentsOfURL:url
                            display:YES
                  completionHandler:^(NSDocument* document,
                                      BOOL documentWasAlreadyOpen,
                                      NSError* error) {
    (void)documentWasAlreadyOpen;
    if (error != nil) {
      [NSApp presentError:error];
      return;
    }
    SakuraWindowController* controller = (SakuraWindowController*)
        document.windowControllers.firstObject;
    [controller.editorView jumpToDocumentOffset:offset];
  }];
}

- (void)prepareGrepPanel {
  if (self.grepPanel == nil) {
    NSPanel* panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 780, 620)
                  styleMask:NSWindowStyleMaskTitled |
                            NSWindowStyleMaskClosable |
                            NSWindowStyleMaskResizable |
                            NSWindowStyleMaskUtilityWindow
                    backing:NSBackingStoreBuffered defer:NO];
    panel.title = @"Grep";
    panel.hidesOnDeactivate = NO;
    panel.floatingPanel = YES;
    panel.minSize = NSMakeSize(560, 380);
    NSView* content = panel.contentView;

    NSTextField* queryLabel = [NSTextField labelWithString:@"検索文字列:"];
    queryLabel.frame = NSMakeRect(12, 578, 86, 22);
    [content addSubview:queryLabel];
    NSSearchField* query = [[NSSearchField alloc]
        initWithFrame:NSMakeRect(100, 574, 668, 28)];
    query.autoresizingMask = NSViewWidthSizable;
    [content addSubview:query];

    NSTextField* replacementLabel =
        [NSTextField labelWithString:@"置換文字列:"];
    replacementLabel.frame = NSMakeRect(12, 542, 86, 22);
    [content addSubview:replacementLabel];
    NSTextField* replacement = [[NSTextField alloc]
        initWithFrame:NSMakeRect(100, 538, 668, 28)];
    replacement.autoresizingMask = NSViewWidthSizable;
    [content addSubview:replacement];

    NSTextField* folderLabel = [NSTextField labelWithString:@"フォルダー:"];
    folderLabel.frame = NSMakeRect(12, 506, 86, 22);
    [content addSubview:folderLabel];
    NSTextField* folderField = [[NSTextField alloc]
        initWithFrame:NSMakeRect(100, 502, 568, 28)];
    folderField.autoresizingMask = NSViewWidthSizable;
    [content addSubview:folderField];
    NSButton* browse = [NSButton buttonWithTitle:@"参照…" target:self
                                          action:@selector(chooseGrepFolder:)];
    browse.frame = NSMakeRect(676, 502, 92, 28);
    browse.autoresizingMask = NSViewMinXMargin;
    [content addSubview:browse];

    NSTextField* patternLabel = [NSTextField labelWithString:@"ファイル:"];
    patternLabel.frame = NSMakeRect(12, 470, 86, 22);
    [content addSubview:patternLabel];
    NSTextField* pattern = [[NSTextField alloc]
        initWithFrame:NSMakeRect(100, 466, 250, 28)];
    pattern.stringValue = @"*";
    [content addSubview:pattern];
    NSButton* caseSensitive = [NSButton checkboxWithTitle:@"大文字小文字を区別"
                                                    target:nil action:nil];
    caseSensitive.frame = NSMakeRect(366, 468, 148, 24);
    [content addSubview:caseSensitive];
    NSButton* regex = [NSButton checkboxWithTitle:@"正規表現"
                                           target:nil action:nil];
    regex.frame = NSMakeRect(516, 468, 92, 24);
    [content addSubview:regex];
    NSButton* recursive = [NSButton checkboxWithTitle:@"サブフォルダー"
                                               target:nil action:nil];
    recursive.frame = NSMakeRect(614, 468, 132, 24);
    recursive.state = NSControlStateValueOn;
    recursive.autoresizingMask = NSViewMinXMargin;
    [content addSubview:recursive];

    NSTextField* excludedFolderLabel =
        [NSTextField labelWithString:@"除外フォルダ:"];
    excludedFolderLabel.font = [NSFont systemFontOfSize:12];
    excludedFolderLabel.frame = NSMakeRect(12, 434, 86, 22);
    [content addSubview:excludedFolderLabel];
    NSTextField* excludedFolder = [[NSTextField alloc]
        initWithFrame:NSMakeRect(100, 430, 668, 28)];
    excludedFolder.autoresizingMask = NSViewWidthSizable;
    excludedFolder.placeholderString = @"例: build; node_modules; vendor/generated*";
    excludedFolder.toolTip = @"; または , 区切り。名前は全階層、パスは検索フォルダー相対。"
        @" * ? は最後の名前だけに使用でき、大文字小文字は区別しません。絶対パスと .. は指定できません。";
    id savedExclusions = [[self grepDefaults] objectForKey:@"SakuraGrepExcludedFolders"];
    excludedFolder.stringValue = [savedExclusions isKindOfClass:NSString.class]
        ? savedExclusions : @"";
    [content addSubview:excludedFolder];
    for (NSView* topControl in @[
        queryLabel, query, replacementLabel, replacement, folderLabel, folderField,
        browse, patternLabel, pattern, caseSensitive, regex, recursive,
        excludedFolderLabel, excludedFolder]) {
      topControl.autoresizingMask |= NSViewMinYMargin;
    }

    NSScrollView* scroll = [[NSScrollView alloc]
        initWithFrame:NSMakeRect(12, 52, 756, 368)];
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = YES;
    scroll.borderType = NSBezelBorder;
    NSTableView* table = [[NSTableView alloc] initWithFrame:scroll.bounds];
    NSTableColumn* column = [[NSTableColumn alloc] initWithIdentifier:@"grep"];
    column.title = @"ファイル:行:桁: 内容";
    column.width = 740;
    [table addTableColumn:column];
    table.rowHeight = 22.0;
    table.dataSource = self;
    table.delegate = self;
    table.target = self;
    table.doubleAction = @selector(grepSelectionActivated:);
    scroll.documentView = table;
    [content addSubview:scroll];

    NSButton* run = [NSButton buttonWithTitle:@"検索" target:self
                                       action:@selector(startGrep:)];
    run.frame = NSMakeRect(12, 12, 88, 28);
    run.keyEquivalent = @"\r";
    [content addSubview:run];
    NSButton* cancel = [NSButton buttonWithTitle:@"中止" target:self
                                          action:@selector(cancelGrep:)];
    cancel.frame = NSMakeRect(212, 12, 88, 28);
    [content addSubview:cancel];
    NSButton* replaceFiles = [NSButton buttonWithTitle:@"置換実行"
        target:self action:@selector(executeGrepReplace:)];
    replaceFiles.frame = NSMakeRect(108, 12, 96, 28);
    replaceFiles.enabled = NO;
    [content addSubview:replaceFiles];
    NSButton* backup = [NSButton checkboxWithTitle:@"バックアップ(.bak)"
        target:nil action:nil];
    backup.frame = NSMakeRect(310, 14, 150, 24);
    backup.state = NSControlStateValueOn;
    [content addSubview:backup];
    NSTextField* status = [NSTextField labelWithString:@""];
    status.alignment = NSTextAlignmentRight;
    status.frame = NSMakeRect(466, 17, 302, 18);
    status.autoresizingMask = NSViewWidthSizable | NSViewMinXMargin |
                              NSViewMaxYMargin;
    [content addSubview:status];

    self.grepPanel = panel;
    self.grepQueryField = query;
    self.grepReplacementLabel = replacementLabel;
    self.grepReplacementField = replacement;
    self.grepFolderField = folderField;
    self.grepPatternField = pattern;
    self.grepExcludedFolderField = excludedFolder;
    self.grepCaseSensitiveButton = caseSensitive;
    self.grepRegexButton = regex;
    self.grepRecursiveButton = recursive;
    self.grepTableView = table;
    self.grepStatusLabel = status;
    self.grepRunButton = run;
    self.grepReplaceButton = replaceFiles;
    self.grepBackupButton = backup;
  }
}

- (void)showGrepPanelWithReplaceMode:(BOOL)replaceMode {
  if (self.grepReplacing) {
    [self.grepPanel makeKeyAndOrderFront:self];
    return;
  }
  [self prepareGrepPanel];
  if (self.grepFolderField.stringValue.length == 0) {
    NSString* folder = ((SakuraDocument*)self.document).fileURL.URLByDeletingLastPathComponent.path;
    self.grepFolderField.stringValue = folder.length != 0 ? folder : NSHomeDirectory();
    if (folder.length != 0) {
      self.grepAuthorizedFolderPath = folder.stringByStandardizingPath;
    }
  }
  if (self.grepQueryField.stringValue.length == 0 &&
      self.toolbarSearchField.stringValue.length != 0) {
    self.grepQueryField.stringValue = self.toolbarSearchField.stringValue;
  }
  [self configureGrepPanelForReplaceMode:replaceMode];
  self.grepPanel.appearance = self.window.appearance;
  [self.grepPanel makeKeyAndOrderFront:self];
  [self.grepPanel makeFirstResponder:self.grepQueryField];
}

- (void)showGrepPanel:(id)sender {
  (void)sender;
  [self showGrepPanelWithReplaceMode:NO];
}

- (void)showGrepReplacePanel:(id)sender {
  (void)sender;
  [self showGrepPanelWithReplaceMode:YES];
}

- (NSArray<NSDictionary*>*)buildOutlineEntries {
  SakuraDocument* document = (SakuraDocument*)self.document;
  if (document == nil) {
    return @[];
  }
  const auto& buffer = document.documentSession.buffer();
  NSMutableArray<NSDictionary*>* entries = [NSMutableArray array];
  NSCharacterSet* whitespace = [NSCharacterSet whitespaceCharacterSet];
  NSString* extension = document.fileURL.pathExtension.lowercaseString;
  const BOOL isMarkdown = [@[@"md", @"markdown", @"mdown", @"mkd"]
      containsObject:extension != nil ? extension : @""];
  NSArray<NSString*>* declarationPrefixes = @[
    @"class ", @"struct ", @"enum ", @"namespace ", @"protocol ",
    @"interface ", @"extension ", @"func ", @"actor "
  ];
  NSArray<NSString*>* controlPrefixes = @[
    @"if ", @"if(", @"for ", @"for(", @"while ", @"while(",
    @"switch ", @"switch(", @"catch ", @"catch("
  ];

  for (std::size_t lineIndex = 0; lineIndex < buffer.lineCount(); ++lineIndex) {
    NSString* line = sakura::platform::mac::stringFromSakuraString(
        buffer.line(lineIndex).content);
    NSString* trimmed = [line stringByTrimmingCharactersInSet:whitespace];
    if (trimmed.length == 0) {
      continue;
    }

    BOOL isEntry = (isMarkdown && [trimmed hasPrefix:@"#"]) ||
                   [trimmed hasPrefix:@"- ("] ||
                   [trimmed hasPrefix:@"+ ("];
    for (NSString* prefix in declarationPrefixes) {
      if ([trimmed hasPrefix:prefix]) {
        isEntry = YES;
        break;
      }
    }
    if (!isEntry && [trimmed containsString:@"("] &&
        [trimmed containsString:@")"] && ![trimmed hasSuffix:@";"]) {
      BOOL isControl = NO;
      for (NSString* prefix in controlPrefixes) {
        if ([trimmed hasPrefix:prefix]) {
          isControl = YES;
          break;
        }
      }
      isEntry = !isControl;
    }
    if (!isEntry) {
      continue;
    }

    NSString* summary = trimmed.length > 96
                            ? [[trimmed substringToIndex:95]
                                  stringByAppendingString:@"…"]
                            : trimmed;
    [entries addObject:@{
      @"title" : [NSString stringWithFormat:@"%5zu  %@", lineIndex + 1,
                                                   summary],
      @"offset" : @(static_cast<unsigned long long>(
          buffer.lineStartOffset(lineIndex))),
    }];
  }
  return entries;
}

- (void)refreshOutlinePanel:(id)sender {
  (void)sender;
  self.outlineEntries = [self buildOutlineEntries];
  [self.outlineTableView reloadData];
  self.outlineStatusLabel.stringValue = [NSString
      stringWithFormat:@"%lu 件", (unsigned long)self.outlineEntries.count];
  if (self.outlineEntries.count != 0) {
    [self.outlineTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                      byExtendingSelection:NO];
  }
}

- (void)outlineSelectionActivated:(id)sender {
  (void)sender;
  const NSInteger row = self.outlineTableView.selectedRow;
  if (row < 0 || static_cast<NSUInteger>(row) >= self.outlineEntries.count) {
    NSBeep();
    return;
  }
  NSNumber* offset = self.outlineEntries[static_cast<NSUInteger>(row)][@"offset"];
  [[self activeEditor] jumpToDocumentOffset:offset.unsignedIntegerValue];
}

- (void)showOutlinePanel:(id)sender {
  (void)sender;
  if (self.outlinePanel == nil) {
    NSPanel* panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 460, 520)
                  styleMask:NSWindowStyleMaskTitled |
                            NSWindowStyleMaskClosable |
                            NSWindowStyleMaskResizable |
                            NSWindowStyleMaskUtilityWindow
                    backing:NSBackingStoreBuffered
                      defer:NO];
    panel.title = @"アウトライン解析";
    panel.hidesOnDeactivate = NO;
    panel.floatingPanel = YES;
    panel.minSize = NSMakeSize(320, 240);

    NSView* content = panel.contentView;
    NSScrollView* scroll = [[NSScrollView alloc]
        initWithFrame:NSMakeRect(12, 48, 436, 460)];
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    NSTableView* table = [[NSTableView alloc] initWithFrame:scroll.bounds];
    NSTableColumn* column = [[NSTableColumn alloc] initWithIdentifier:@"outline"];
    column.width = 430;
    [table addTableColumn:column];
    table.headerView = nil;
    table.rowHeight = 22.0;
    table.dataSource = self;
    table.delegate = self;
    table.target = self;
    table.doubleAction = @selector(outlineSelectionActivated:);
    scroll.documentView = table;
    [content addSubview:scroll];

    NSButton* jump = [NSButton buttonWithTitle:@"ジャンプ"
                                          target:self
                                          action:@selector(outlineSelectionActivated:)];
    jump.frame = NSMakeRect(12, 12, 88, 28);
    jump.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [content addSubview:jump];
    NSButton* refresh = [NSButton buttonWithTitle:@"再解析"
                                             target:self
                                             action:@selector(refreshOutlinePanel:)];
    refresh.frame = NSMakeRect(108, 12, 88, 28);
    refresh.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [content addSubview:refresh];
    NSTextField* status = [NSTextField labelWithString:@""];
    status.alignment = NSTextAlignmentRight;
    status.frame = NSMakeRect(330, 17, 118, 18);
    status.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [content addSubview:status];

    self.outlinePanel = panel;
    self.outlineTableView = table;
    self.outlineStatusLabel = status;
  }
  [self refreshOutlinePanel:self];
  [self.outlinePanel makeKeyAndOrderFront:self];
}

- (NSString*)shortcutDescriptionForMenuItem:(NSMenuItem*)item {
  if (item.keyEquivalent.length == 0) {
    return @"";
  }
  NSMutableString* shortcut = [NSMutableString string];
  const NSEventModifierFlags modifiers = item.keyEquivalentModifierMask;
  if ((modifiers & NSEventModifierFlagControl) != 0) {
    [shortcut appendString:@"⌃"];
  }
  if ((modifiers & NSEventModifierFlagOption) != 0) {
    [shortcut appendString:@"⌥"];
  }
  if ((modifiers & NSEventModifierFlagShift) != 0) {
    [shortcut appendString:@"⇧"];
  }
  if ((modifiers & NSEventModifierFlagCommand) != 0) {
    [shortcut appendString:@"⌘"];
  }
  [shortcut appendString:item.keyEquivalent.uppercaseString];
  return shortcut;
}

- (NSSet<NSString*>*)supportedCommandActions {
  static NSSet<NSString*>* actions;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    actions = [NSSet setWithArray:@[
      NSStringFromSelector(@selector(orderFrontStandardAboutPanel:)),
      NSStringFromSelector(@selector(newDocument:)),
      NSStringFromSelector(@selector(openDocument:)),
      NSStringFromSelector(@selector(performClose:)),
      NSStringFromSelector(@selector(saveDocument:)),
      NSStringFromSelector(@selector(saveDocumentAs:)),
      NSStringFromSelector(@selector(undo:)),
      NSStringFromSelector(@selector(redo:)),
      NSStringFromSelector(@selector(cut:)),
      NSStringFromSelector(@selector(copy:)),
      NSStringFromSelector(@selector(paste:)),
      NSStringFromSelector(@selector(selectAll:)),
      NSStringFromSelector(@selector(convertSelectionToUppercase:)),
      NSStringFromSelector(@selector(convertSelectionToLowercase:)),
      NSStringFromSelector(@selector(showFindPanel:)),
      NSStringFromSelector(@selector(findNext:)),
      NSStringFromSelector(@selector(findPrevious:)),
      NSStringFromSelector(@selector(clearSearchMarks:)),
      NSStringFromSelector(@selector(replaceSearchSelection:)),
      NSStringFromSelector(@selector(replaceAll:)),
      NSStringFromSelector(@selector(showOutlinePanel:)),
      NSStringFromSelector(@selector(showGrepPanel:)),
      NSStringFromSelector(@selector(showGrepReplacePanel:)),
      NSStringFromSelector(@selector(goBackInNavigationHistory:)),
      NSStringFromSelector(@selector(goForwardInNavigationHistory:)),
      NSStringFromSelector(@selector(registerCurrentNavigationPosition:)),
      NSStringFromSelector(@selector(toggleRectangularSelection:)),
      NSStringFromSelector(@selector(showCommandList:)),
      NSStringFromSelector(@selector(showTypeSettingsList:)),
      NSStringFromSelector(@selector(showTypeSettings:)),
      NSStringFromSelector(@selector(showCommonSettings:)),
      NSStringFromSelector(@selector(showEncodingPanel:)),
      NSStringFromSelector(@selector(toggleSplitEditor:)),
      NSStringFromSelector(@selector(toggleToolbar:)),
      NSStringFromSelector(@selector(toggleStatusBar:)),
      NSStringFromSelector(@selector(performMiniaturize:)),
      NSStringFromSelector(@selector(performZoom:)),
      NSStringFromSelector(@selector(arrangeInFront:)),
    ]];
  });
  return actions;
}

- (void)appendCommandsFromMenu:(NSMenu*)menu
                        prefix:(NSString*)prefix
                            to:(NSMutableArray<NSDictionary*>*)entries {
  for (NSMenuItem* item in menu.itemArray) {
    if (item.isSeparatorItem || item.hidden) {
      continue;
    }
    NSString* title = item.title.length != 0 ? item.title : item.submenu.title;
    NSString* path = prefix.length != 0
                         ? [NSString stringWithFormat:@"%@ › %@", prefix, title]
                         : title;
    if (item.submenu != nil) {
      [self appendCommandsFromMenu:item.submenu prefix:path to:entries];
      continue;
    }
    if (item.action == nil || !item.enabled ||
        ![[self supportedCommandActions]
            containsObject:NSStringFromSelector(item.action)]) {
      continue;
    }
    NSString* shortcut = [self shortcutDescriptionForMenuItem:item];
    NSString* display = shortcut.length == 0
                            ? path
                            : [NSString stringWithFormat:@"%@    %@", path, shortcut];
    [entries addObject:@{
      @"title" : display,
      @"action" : NSStringFromSelector(item.action),
      @"target" : item.target != nil ? item.target : NSNull.null,
    }];
  }
}

- (void)refreshCommandList:(id)sender {
  (void)sender;
  NSMutableArray<NSDictionary*>* entries = [NSMutableArray array];
  [self appendCommandsFromMenu:NSApp.mainMenu prefix:@"" to:entries];
  self.commandEntries = entries;
  [self.commandTableView reloadData];
  self.commandStatusLabel.stringValue = [NSString
      stringWithFormat:@"%lu コマンド", (unsigned long)entries.count];
  if (entries.count != 0) {
    [self.commandTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                      byExtendingSelection:NO];
  }
}

- (void)commandSelectionActivated:(id)sender {
  (void)sender;
  const NSInteger row = self.commandTableView.selectedRow;
  if (row < 0 || static_cast<NSUInteger>(row) >= self.commandEntries.count) {
    NSBeep();
    return;
  }
  NSDictionary* entry = self.commandEntries[static_cast<NSUInteger>(row)];
  const SEL action = NSSelectorFromString(entry[@"action"]);
  id target = entry[@"target"] == NSNull.null ? nil : entry[@"target"];
  [self.commandPanel orderOut:self];
  [self.window makeKeyAndOrderFront:self];
  [self.window makeFirstResponder:[self activeEditor]];
  if (![NSApp sendAction:action to:target from:self]) {
    NSBeep();
  }
}

- (void)showCommandList:(id)sender {
  (void)sender;
  if (self.commandPanel == nil) {
    NSPanel* panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 560, 540)
                  styleMask:NSWindowStyleMaskTitled |
                            NSWindowStyleMaskClosable |
                            NSWindowStyleMaskResizable |
                            NSWindowStyleMaskUtilityWindow
                    backing:NSBackingStoreBuffered
                      defer:NO];
    panel.title = @"コマンド一覧";
    panel.hidesOnDeactivate = NO;
    panel.floatingPanel = YES;
    panel.minSize = NSMakeSize(360, 260);

    NSView* content = panel.contentView;
    NSScrollView* scroll = [[NSScrollView alloc]
        initWithFrame:NSMakeRect(12, 48, 536, 480)];
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    NSTableView* table = [[NSTableView alloc] initWithFrame:scroll.bounds];
    NSTableColumn* column = [[NSTableColumn alloc] initWithIdentifier:@"command"];
    column.width = 530;
    [table addTableColumn:column];
    table.headerView = nil;
    table.rowHeight = 22.0;
    table.dataSource = self;
    table.delegate = self;
    table.target = self;
    table.doubleAction = @selector(commandSelectionActivated:);
    scroll.documentView = table;
    [content addSubview:scroll];

    NSButton* run = [NSButton buttonWithTitle:@"実行"
                                         target:self
                                         action:@selector(commandSelectionActivated:)];
    run.frame = NSMakeRect(12, 12, 88, 28);
    run.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [content addSubview:run];
    NSTextField* status = [NSTextField labelWithString:@""];
    status.alignment = NSTextAlignmentRight;
    status.frame = NSMakeRect(406, 17, 142, 18);
    status.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [content addSubview:status];

    self.commandPanel = panel;
    self.commandTableView = table;
    self.commandStatusLabel = status;
  }
  [self refreshCommandList:self];
  [self.commandPanel makeKeyAndOrderFront:self];
}

- (NSString*)currentTypeName {
  NSString* extension =
      ((SakuraDocument*)self.document).fileURL.pathExtension.lowercaseString;
  if (extension == nil) {
    extension = @"";
  }
  if ([@[@"c", @"cc", @"cpp", @"cxx", @"h", @"hh", @"hpp", @"hxx",
         @"m", @"mm"] containsObject:extension]) {
    return @"C/C++";
  }
  if ([@[@"htm", @"html", @"xhtml", @"xml"] containsObject:extension]) {
    return @"HTML";
  }
  if ([extension isEqualToString:@"java"]) {
    return @"Java";
  }
  if ([extension isEqualToString:@"swift"]) {
    return @"Swift";
  }
  if ([@[@"md", @"markdown"] containsObject:extension]) {
    return @"Markdown";
  }
  return extension.length == 0 ? @"基本" : @"テキスト";
}

- (NSString*)currentTypeIdentifier {
  return SakuraTypeIdentifierForExtension(
      ((SakuraDocument*)self.document).fileURL.pathExtension);
}

- (void)showTypeSettingsList:(id)sender {
  (void)sender;
  if (self.typeSettingsListPanel == nil) {
    NSPanel* panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 470, 430)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                            NSWindowStyleMaskUtilityWindow
                    backing:NSBackingStoreBuffered
                      defer:NO];
    panel.title = @"タイプ別設定一覧";
    panel.hidesOnDeactivate = NO;
    panel.floatingPanel = YES;

    NSBox* listBox = [[NSBox alloc] initWithFrame:NSMakeRect(16, 58, 438, 356)];
    listBox.title = @"設定タイプ";
    NSStackView* rows = [[NSStackView alloc]
        initWithFrame:NSInsetRect(listBox.bounds, 14.0, 24.0)];
    rows.orientation = NSUserInterfaceLayoutOrientationVertical;
    rows.alignment = NSLayoutAttributeLeading;
    rows.spacing = 5.0;
    for (NSString* type in @[
           @"基本", @"テキスト", @"C/C++", @"HTML", @"PL/SQL", @"COBOL",
           @"Java", @"アセンブラ", @"Perl", @"Visual Basic", @"Swift", @"Markdown"
         ]) {
      NSString* mark = [type isEqualToString:[self currentTypeName]] ? @"▶" : @" ";
      NSTextField* row = [NSTextField
          labelWithString:[NSString stringWithFormat:@"%@  %@", mark, type]];
      row.font = [NSFont systemFontOfSize:13.0];
      [rows addArrangedSubview:row];
    }
    [listBox.contentView addSubview:rows];
    [panel.contentView addSubview:listBox];
    NSButton* configure = [NSButton buttonWithTitle:@"設定変更..."
                                               target:self
                                               action:@selector(showTypeSettings:)];
    configure.frame = NSMakeRect(16, 18, 104, 28);
    [panel.contentView addSubview:configure];
    NSButton* close = [NSButton buttonWithTitle:@"閉じる"
                                           target:panel
                                           action:@selector(orderOut:)];
    close.frame = NSMakeRect(366, 18, 88, 28);
    [panel.contentView addSubview:close];
    self.typeSettingsListPanel = panel;
  }
  [self.typeSettingsListPanel makeKeyAndOrderFront:self];
}

- (void)addSettingsTab:(NSString*)title
                  lines:(NSArray<NSString*>*)lines
                     to:(NSTabView*)tabView {
  NSTabViewItem* item = [[NSTabViewItem alloc] initWithIdentifier:title];
  item.label = title;
  NSView* view = [[NSView alloc] initWithFrame:tabView.contentRect];
  CGFloat y = NSHeight(view.bounds) - 44.0;
  for (NSString* line in lines) {
    NSTextField* label = [NSTextField labelWithString:line];
    label.frame = NSMakeRect(24, y, NSWidth(view.bounds) - 48.0, 22.0);
    label.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [view addSubview:label];
    y -= 34.0;
  }
  item.view = view;
  [tabView addTabViewItem:item];
}

- (NSArray<NSDictionary*>*)defaultTypeColorEntries {
  return @[
    @{ @"title" : @"テキスト", @"foreground" : @"text",
       @"background" : @"background", @"style" : @"text",
       @"display" : @NO, @"font" : @YES },
    @{ @"title" : @"行番号", @"foreground" : @"gutter",
       @"background" : @"gutterBackground", @"style" : @"gutter",
       @"display" : @YES, @"font" : @YES },
    @{ @"title" : @"選択範囲", @"foreground" : @"selection",
       @"background" : @"selectionBackground", @"style" : @"selection",
       @"display" : @NO, @"font" : @YES },
    @{ @"title" : @"検索文字列", @"foreground" : @"search",
       @"background" : @"searchBackground", @"style" : @"search",
       @"display" : @YES, @"font" : @YES },
    @{ @"title" : @"カーソル行アンダーライン", @"foreground" : @"caretLine",
       @"background" : NSNull.null, @"style" : @"caretLine",
       @"display" : @YES, @"font" : @NO },
    @{ @"title" : @"TAB記号", @"foreground" : @"tabMarker",
       @"background" : @"tabMarkerBackground", @"style" : @"tabMarker",
       @"display" : @YES, @"font" : @YES },
    @{ @"title" : @"半角空白", @"foreground" : @"halfSpaceMarker",
       @"background" : @"halfSpaceMarkerBackground", @"style" : @"halfSpaceMarker",
       @"display" : @YES, @"font" : @YES, @"defaultDisplay" : @NO },
    @{ @"title" : @"全角空白", @"foreground" : @"fullSpaceMarker",
       @"background" : @"fullSpaceMarkerBackground", @"style" : @"fullSpaceMarker",
       @"display" : @YES, @"font" : @YES },
    @{ @"title" : @"改行記号", @"foreground" : @"eolMarker",
       @"background" : @"eolMarkerBackground", @"style" : @"eolMarker",
       @"display" : @YES, @"font" : @YES },
    @{ @"title" : @"折返し記号", @"foreground" : @"wrapMarker",
       @"background" : @"wrapMarkerBackground", @"style" : @"wrapMarker",
       @"display" : @YES, @"font" : @YES },
    @{ @"title" : @"EOF記号", @"foreground" : @"eofMarker",
       @"background" : @"eofMarkerBackground", @"style" : @"eofMarker",
       @"display" : @YES, @"font" : @YES },
    @{ @"title" : @"コメント", @"foreground" : @"comment",
       @"background" : @"commentBackground", @"style" : @"comment",
       @"display" : @YES, @"font" : @YES },
    @{ @"title" : @"シングル／ダブルクォーテーション文字列",
       @"foreground" : @"string", @"background" : @"stringBackground",
       @"style" : @"string", @"display" : @YES, @"font" : @YES },
    @{ @"title" : @"キーワード1", @"foreground" : @"keyword",
       @"background" : @"keywordBackground", @"style" : @"keyword",
       @"display" : @YES, @"font" : @YES },
    @{ @"title" : @"半角数値", @"foreground" : @"number",
       @"background" : @"numberBackground", @"style" : @"number",
       @"display" : @YES, @"font" : @YES },
    @{ @"title" : @"プリプロセッサ", @"foreground" : @"preprocessor",
       @"background" : @"preprocessorBackground", @"style" : @"preprocessor",
       @"display" : @YES, @"font" : @YES },
  ];
}

- (NSDictionary*)selectedTypeColorEntry {
  NSInteger row = self.typeColorTableView.selectedRow;
  if (row < 0 || static_cast<NSUInteger>(row) >= self.typeColorEntries.count) {
    return nil;
  }
  return self.typeColorEntries[static_cast<NSUInteger>(row)];
}

- (NSColor*)defaultTypeColorForRole:(NSString*)role {
  NSAppearance* appearance = self.typeSettingsPanel.effectiveAppearance != nil
      ? self.typeSettingsPanel.effectiveAppearance : self.window.effectiveAppearance;
  if ([role isEqualToString:@"text"]) return SakuraEditorText(appearance);
  if ([role isEqualToString:@"background"]) return SakuraEditorBackground(appearance);
  if ([role isEqualToString:@"gutter"]) return SakuraGutterText(appearance);
  if ([role isEqualToString:@"gutterBackground"]) return SakuraGutterBackground(appearance);
  if ([role isEqualToString:@"selection"]) return SakuraSelectionText(appearance);
  if ([role isEqualToString:@"selectionBackground"]) return SakuraSelectionBackground(appearance);
  if ([role isEqualToString:@"search"]) return SakuraSearchText(appearance);
  if ([role isEqualToString:@"searchBackground"]) return SakuraSearchBackground(appearance);
  if ([role isEqualToString:@"caretLine"]) return SakuraCaretLine(appearance);
  if ([role isEqualToString:@"comment"]) return SakuraCommentText(appearance);
  if ([role isEqualToString:@"string"]) return SakuraStringText(appearance);
  if ([role isEqualToString:@"keyword"]) return SakuraKeywordText(appearance);
  if ([role isEqualToString:@"number"]) return SakuraNumberText(appearance);
  if ([role isEqualToString:@"preprocessor"]) return SakuraPreprocessorText(appearance);
  if ([role isEqualToString:@"tabMarker"]) return SakuraTabMarkerText(appearance);
  if ([role isEqualToString:@"halfSpaceMarker"] ||
      [role isEqualToString:@"fullSpaceMarker"]) return SakuraSpaceMarkerText(appearance);
  if ([role isEqualToString:@"eolMarker"]) return SakuraEolMarkerText(appearance);
  if ([role isEqualToString:@"wrapMarker"]) return SakuraWrapMarkerText(appearance);
  if ([role isEqualToString:@"eofMarker"]) return SakuraEofMarkerText(appearance);
  if ([role isEqualToString:@"eofMarkerBackground"]) {
    return SakuraEofMarkerBackground(appearance);
  }
  return SakuraEditorBackground(appearance);
}

- (NSColor*)effectiveTypeColorForRole:(NSString*)role {
  NSString* value = [[self typeSettingsDefaults] stringForKey:
      SakuraTypeColorPreferenceKey(self.typeColorIdentifier, role,
                                  self.typeSettingsPanel.effectiveAppearance)];
  return SakuraColorFromHexString(value) ?: [self defaultTypeColorForRole:role];
}

- (NSUserDefaults*)typeSettingsDefaults {
  return NSUserDefaults.standardUserDefaults;
}

- (BOOL)typeStyleBoolForRole:(NSString*)role attribute:(NSString*)attribute
                   fallback:(BOOL)fallback {
  NSUserDefaults* defaults = [self typeSettingsDefaults];
  NSString* key = SakuraTypeStylePreferenceKey(self.typeColorIdentifier, role,
                                              attribute);
  return [defaults objectForKey:key] != nil ? [defaults boolForKey:key] : fallback;
}

- (void)refreshTypeColorControls {
  NSDictionary* entry = [self selectedTypeColorEntry];
  if (entry == nil) {
    return;
  }
  NSString* foregroundRole = entry[@"foreground"];
  id backgroundValue = entry[@"background"];
  NSString* backgroundRole = backgroundValue == NSNull.null ? nil : backgroundValue;
  NSString* styleRole = entry[@"style"];
  self.typeForegroundColorWell.color = [self effectiveTypeColorForRole:foregroundRole];
  self.typeBackgroundColorWell.enabled = backgroundRole != nil;
  self.typeBackgroundColorWell.color = backgroundRole != nil
      ? [self effectiveTypeColorForRole:backgroundRole]
      : [self defaultTypeColorForRole:@"background"];
  self.typeColorDisplayCheckbox.enabled = [entry[@"display"] boolValue];
  self.typeColorBoldCheckbox.enabled = [entry[@"font"] boolValue];
  self.typeColorUnderlineCheckbox.enabled = [entry[@"font"] boolValue];
  const BOOL defaultDisplay = entry[@"defaultDisplay"] != nil
      ? [entry[@"defaultDisplay"] boolValue] : YES;
  self.typeColorDisplayCheckbox.state = [self typeStyleBoolForRole:styleRole
      attribute:@"display" fallback:defaultDisplay]
      ? NSControlStateValueOn : NSControlStateValueOff;
  self.typeColorBoldCheckbox.state = [self typeStyleBoolForRole:styleRole
      attribute:@"bold" fallback:NO]
      ? NSControlStateValueOn : NSControlStateValueOff;
  self.typeColorUnderlineCheckbox.state = [self typeStyleBoolForRole:styleRole
      attribute:@"underline" fallback:NO]
      ? NSControlStateValueOn : NSControlStateValueOff;

  NSMutableDictionary<NSAttributedStringKey, id>* previewAttributes =
      [@{
        NSFontAttributeName : [NSFont monospacedSystemFontOfSize:13.0
                                                       weight:NSFontWeightRegular],
        NSForegroundColorAttributeName : self.typeForegroundColorWell.color,
        NSBackgroundColorAttributeName : self.typeBackgroundColorWell.enabled
            ? self.typeBackgroundColorWell.color
            : [self defaultTypeColorForRole:@"background"],
      } mutableCopy];
  if (self.typeColorBoldCheckbox.state == NSControlStateValueOn) {
    previewAttributes[NSFontAttributeName] = [[NSFontManager sharedFontManager]
        convertFont:previewAttributes[NSFontAttributeName]
        toHaveTrait:NSBoldFontMask];
  }
  if (self.typeColorUnderlineCheckbox.state == NSControlStateValueOn) {
    previewAttributes[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
  }
  self.typeColorPreview.attributedStringValue = [[NSAttributedString alloc]
      initWithString:@"Aa あア 0123  サクラエディタ"
          attributes:previewAttributes];
  // Reload cells, not table structure: a full reload inside the selection
  // notification can clear NSTableView's selection before a color action.
  [self.typeColorTableView reloadDataForRowIndexes:
      [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, self.typeColorEntries.count)]
      columnIndexes:[NSIndexSet indexSetWithIndexesInRange:
          NSMakeRange(0, self.typeColorTableView.numberOfColumns)]];
}

- (void)redrawEditorsForTypeColorChange {
  for (NSWindow* window in NSApp.windows) {
    if (![window.windowController isKindOfClass:[SakuraWindowController class]]) {
      continue;
    }
    SakuraWindowController* controller =
        (SakuraWindowController*)window.windowController;
    if (controller.typeSettingsPanel.visible &&
        [controller.typeColorIdentifier isEqualToString:self.typeColorIdentifier]) {
      [controller refreshTypeColorControls];
    }
    NSString* controllerType = [controller currentTypeIdentifier];
    if (![controllerType isEqualToString:self.typeColorIdentifier]) continue;
    for (NSScrollView* scrollView in controller.secondaryScrollView != nil
             ? @[ controller.primaryScrollView, controller.secondaryScrollView ]
             : @[ controller.primaryScrollView ]) {
      scrollView.backgroundColor = SakuraTypeColor(
          controllerType, @"background", scrollView.effectiveAppearance,
          SakuraEditorBackground(scrollView.effectiveAppearance));
    }
    for (SakuraEditorView* editor in controller.editorViews) {
      [editor displaySettingsDidChange];
    }
  }
}

- (void)applyTypeColorSettings:(id)sender {
  NSDictionary* entry = [self selectedTypeColorEntry];
  if (entry == nil) return;
  if (self.typeColorTransaction == nil) [self captureTypeColorSnapshot];
  NSAppearance* appearance = self.typeSettingsPanel.effectiveAppearance;
  NSString* foregroundRole = entry[@"foreground"];
  id backgroundValue = entry[@"background"];
  NSString* backgroundRole = backgroundValue == NSNull.null ? nil : backgroundValue;
  // A stale panel must not re-publish its other controls when only one changes.
  if (sender == nil || sender == self.typeForegroundColorWell) {
    [self.typeColorTransaction setObject:
        SakuraHexStringFromColor(self.typeForegroundColorWell.color)
               forKey:SakuraTypeColorPreferenceKey(
                   self.typeColorIdentifier, foregroundRole, appearance)];
  }
  if (backgroundRole != nil &&
      (sender == nil || sender == self.typeBackgroundColorWell)) {
    [self.typeColorTransaction setObject:
        SakuraHexStringFromColor(self.typeBackgroundColorWell.color)
                 forKey:SakuraTypeColorPreferenceKey(
                     self.typeColorIdentifier, backgroundRole, appearance)];
  }
  NSString* styleRole = entry[@"style"];
  if (sender == nil || sender == self.typeColorDisplayCheckbox) {
    [self.typeColorTransaction setObject:
        @(self.typeColorDisplayCheckbox.state == NSControlStateValueOn)
             forKey:SakuraTypeStylePreferenceKey(
                 self.typeColorIdentifier, styleRole, @"display")];
  }
  if (sender == nil || sender == self.typeColorBoldCheckbox) {
    [self.typeColorTransaction setObject:
        @(self.typeColorBoldCheckbox.state == NSControlStateValueOn)
             forKey:SakuraTypeStylePreferenceKey(
                 self.typeColorIdentifier, styleRole, @"bold")];
  }
  if (sender == nil || sender == self.typeColorUnderlineCheckbox) {
    [self.typeColorTransaction setObject:
        @(self.typeColorUnderlineCheckbox.state == NSControlStateValueOn)
             forKey:SakuraTypeStylePreferenceKey(
                 self.typeColorIdentifier, styleRole, @"underline")];
  }
  [self refreshTypeColorControls];
  [self redrawEditorsForTypeColorChange];
}

- (void)resetSelectedTypeColor:(id)sender {
  (void)sender;
  NSDictionary* entry = [self selectedTypeColorEntry];
  if (entry == nil) return;
  if (self.typeColorTransaction == nil) [self captureTypeColorSnapshot];
  NSAppearance* appearance = self.typeSettingsPanel.effectiveAppearance;
  for (id value in @[ entry[@"foreground"], entry[@"background"] ]) {
    if (value != NSNull.null) {
      [self.typeColorTransaction setObject:nil forKey:SakuraTypeColorPreferenceKey(
          self.typeColorIdentifier, value, appearance)];
    }
  }
  for (NSString* attribute in @[ @"display", @"bold", @"underline" ]) {
    [self.typeColorTransaction setObject:nil forKey:SakuraTypeStylePreferenceKey(
        self.typeColorIdentifier, entry[@"style"], attribute)];
  }
  [self refreshTypeColorControls];
  [self redrawEditorsForTypeColorChange];
}

- (void)captureTypeColorSnapshot {
  [self.typeColorTransaction cancel];
  self.typeColorTransaction = [[SakuraSettingsPreviewTransaction alloc]
      initWithDefaults:[self typeSettingsDefaults]];
}

- (BOOL)windowShouldClose:(NSWindow*)sender {
  if (sender == self.typeSettingsPanel) {
    [self cancelTypeSettings:sender];
    return NO;
  }
  return YES;
}

- (void)cancelTypeSettings:(id)sender {
  (void)sender;
  self.typeDisplayResetPending = NO;
  self.typeDisplayBaselineValues = nil;
  [self.typeColorTransaction cancel];
  self.typeColorTransaction = nil;
  [self redrawEditorsForTypeColorChange];
  [self.typeSettingsPanel orderOut:self];
}

- (NSView*)makeTypeColorSettingsViewWithFrame:(NSRect)frame {
  NSView* view = [[NSView alloc] initWithFrame:frame];
  NSTableView* table = [[NSTableView alloc] initWithFrame:NSZeroRect];
  table.identifier = @"SakuraTypeColorTable";
  table.rowHeight = 23.0;
  table.allowsEmptySelection = NO;
  table.dataSource = self;
  table.delegate = self;
  for (NSArray<NSString*>* columnInfo in @[
         @[ @"item", @"色指定", @"215" ],
         @[ @"foreground", @"文字色", @"60" ],
         @[ @"background", @"背景色", @"60" ],
       ]) {
    NSTableColumn* column = [[NSTableColumn alloc]
        initWithIdentifier:columnInfo[0]];
    column.title = columnInfo[1];
    column.width = columnInfo[2].doubleValue;
    [table addTableColumn:column];
  }
  NSScrollView* scroll = [[NSScrollView alloc]
      initWithFrame:NSMakeRect(12, 12, 350, NSHeight(frame) - 24)];
  scroll.autoresizingMask = NSViewHeightSizable;
  scroll.borderType = NSBezelBorder;
  scroll.hasVerticalScroller = YES;
  scroll.documentView = table;
  [view addSubview:scroll];

  CGFloat detailX = 386.0;
  CGFloat top = NSHeight(frame) - 54.0;
  NSTextField* foregroundLabel = [NSTextField labelWithString:@"文字色:"];
  foregroundLabel.frame = NSMakeRect(detailX, top, 80, 22);
  [view addSubview:foregroundLabel];
  NSColorWell* foreground = [[NSColorWell alloc]
      initWithFrame:NSMakeRect(detailX + 88, top - 4, 84, 28)];
  foreground.target = self;
  foreground.action = @selector(applyTypeColorSettings:);
  [view addSubview:foreground];
  NSTextField* backgroundLabel = [NSTextField labelWithString:@"背景色:"];
  backgroundLabel.frame = NSMakeRect(detailX, top - 42, 80, 22);
  [view addSubview:backgroundLabel];
  NSColorWell* background = [[NSColorWell alloc]
      initWithFrame:NSMakeRect(detailX + 88, top - 46, 84, 28)];
  background.target = self;
  background.action = @selector(applyTypeColorSettings:);
  [view addSubview:background];
  NSButton* display = [NSButton checkboxWithTitle:@"色分け／表示(&D)"
                                            target:self
                                            action:@selector(applyTypeColorSettings:)];
  display.frame = NSMakeRect(detailX, top - 92, 190, 24);
  [view addSubview:display];
  NSButton* bold = [NSButton checkboxWithTitle:@"太字(&B)"
                                         target:self
                                         action:@selector(applyTypeColorSettings:)];
  bold.frame = NSMakeRect(detailX, top - 124, 110, 24);
  [view addSubview:bold];
  NSButton* underline = [NSButton checkboxWithTitle:@"下線(&U)"
                                              target:self
                                              action:@selector(applyTypeColorSettings:)];
  underline.frame = NSMakeRect(detailX + 112, top - 124, 110, 24);
  [view addSubview:underline];
  NSTextField* previewLabel = [NSTextField labelWithString:@"プレビュー:"];
  previewLabel.frame = NSMakeRect(detailX, top - 174, 120, 22);
  [view addSubview:previewLabel];
  NSTextField* preview = [[NSTextField alloc]
      initWithFrame:NSMakeRect(detailX, top - 222, NSWidth(frame) - detailX - 14,
                               42)];
  preview.editable = NO;
  preview.selectable = NO;
  preview.bordered = YES;
  preview.alignment = NSTextAlignmentCenter;
  [view addSubview:preview];
  NSButton* reset = [NSButton buttonWithTitle:@"この項目を既定色に戻す"
                                         target:self
                                         action:@selector(resetSelectedTypeColor:)];
  reset.frame = NSMakeRect(detailX, top - 270, 190, 28);
  [view addSubview:reset];

  self.typeColorTableView = table;
  self.typeForegroundColorWell = foreground;
  self.typeBackgroundColorWell = background;
  self.typeColorDisplayCheckbox = display;
  self.typeColorBoldCheckbox = bold;
  self.typeColorUnderlineCheckbox = underline;
  self.typeColorPreview = preview;
  return view;
}

- (NSTextField*)typeSettingNumberField:(NSString*)identifier
                                 value:(CGFloat)value
                                 frame:(NSRect)frame
                                inView:(NSView*)view {
  NSTextField* field = [[NSTextField alloc] initWithFrame:frame];
  field.identifier = identifier;
  field.doubleValue = value;
  field.target = self;
  field.action = @selector(typeDisplayDraftChanged:);
  field.autoresizingMask = NSViewMinYMargin;
  [view addSubview:field];
  return field;
}

- (void)addTypeSettingLabel:(NSString*)title
                     frame:(NSRect)frame
                    inView:(NSView*)view {
  NSTextField* label = [NSTextField labelWithString:title];
  label.frame = frame;
  label.autoresizingMask = NSViewMinYMargin;
  [view addSubview:label];
}

- (NSView*)makeTypeScreenSettingsViewWithFrame:(NSRect)frame {
  NSView* view = [[NSView alloc] initWithFrame:frame];
  const CGFloat top = NSHeight(frame) - 48;
  [self addTypeSettingLabel:@"折り返し方法:" frame:NSMakeRect(24, top, 130, 22)
                     inView:view];
  NSPopUpButton* wrap = [[NSPopUpButton alloc]
      initWithFrame:NSMakeRect(164, top - 4, 246, 28) pullsDown:NO];
  wrap.identifier = @"SakuraTypeWrapMode";
  [wrap addItemsWithTitles:@[ @"折り返さない", @"ウィンドウ幅で折り返す",
                              @"指定桁で折り返す" ]];
  wrap.target = self;
  wrap.action = @selector(typeDisplayDraftChanged:);
  wrap.autoresizingMask = NSViewMinYMargin;
  [view addSubview:wrap];
  self.typeWrapModePopup = wrap;
  [self addTypeSettingLabel:@"折り返し桁数:" frame:NSMakeRect(24, top - 48, 130, 22)
                     inView:view];
  self.typeWrapColumnField = [self typeSettingNumberField:@"SakuraTypeWrapColumn"
      value:120 frame:NSMakeRect(166, top - 48, 82, 24) inView:view];
  [self addTypeSettingLabel:@"桁（10〜10000）"
                     frame:NSMakeRect(260, top - 48, 180, 22) inView:view];
  [self addTypeSettingLabel:@"TAB幅:" frame:NSMakeRect(24, top - 96, 130, 22)
                     inView:view];
  self.typeTabWidthField = [self typeSettingNumberField:@"SakuraTypeTabWidth"
      value:4 frame:NSMakeRect(166, top - 96, 82, 24) inView:view];
  [self addTypeSettingLabel:@"桁（1〜16）"
                     frame:NSMakeRect(260, top - 96, 180, 22) inView:view];
  NSButton* lineNumbers = [NSButton checkboxWithTitle:@"行番号を表示する"
      target:nil action:nil];
  lineNumbers.identifier = @"SakuraTypeLineNumbers";
  lineNumbers.frame = NSMakeRect(24, top - 144, 240, 24);
  lineNumbers.autoresizingMask = NSViewMinYMargin;
  [view addSubview:lineNumbers];
  self.typeLineNumbersCheckbox = lineNumbers;
  NSButton* reset = [NSButton buttonWithTitle:@"画面設定を既定に戻す"
      target:self action:@selector(resetTypeEditorSettings:)];
  reset.identifier = @"SakuraTypeDisplayReset";
  reset.frame = NSMakeRect(NSWidth(frame) - 242, top - 146, 218, 28);
  reset.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
  [view addSubview:reset];
  NSTextField* status = [NSTextField labelWithString:@""];
  status.identifier = @"SakuraTypeDisplayResetStatus";
  status.frame = NSMakeRect(24, top - 214, NSWidth(frame) - 48, 64);
  status.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
  status.lineBreakMode = NSLineBreakByWordWrapping;
  status.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
  [view addSubview:status];
  self.typeDisplayResetStatus = status;
  return view;
}

- (NSView*)makeTypeWindowSettingsViewWithFrame:(NSRect)frame {
  NSView* view = [[NSView alloc] initWithFrame:frame];
  const CGFloat top = NSHeight(frame) - 48;
  [self addTypeSettingLabel:@"フォント:" frame:NSMakeRect(24, top, 130, 22)
                     inView:view];
  NSPopUpButton* font = [[NSPopUpButton alloc]
      initWithFrame:NSMakeRect(164, top - 4, NSWidth(frame) - 190, 28)
          pullsDown:NO];
  font.identifier = @"SakuraTypeFont";
  [font addItemWithTitle:@"標準の等幅フォント"];
  font.lastItem.representedObject = @"";
  for (NSString* name in [NSFontManager.sharedFontManager.availableFonts
            sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]) {
    NSFont* candidate = [NSFont fontWithName:name size:13];
    [font addItemWithTitle:candidate.displayName ?: name];
    font.lastItem.representedObject = name;
  }
  font.target = self;
  font.action = @selector(typeDisplayDraftChanged:);
  font.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
  [view addSubview:font];
  self.typeFontPopup = font;
  [self addTypeSettingLabel:@"サイズ:" frame:NSMakeRect(24, top - 48, 130, 22)
                     inView:view];
  self.typeFontSizeField = [self typeSettingNumberField:@"SakuraTypeFontSize"
      value:13 frame:NSMakeRect(166, top - 48, 82, 24) inView:view];
  [self addTypeSettingLabel:@"pt（8〜36）"
                     frame:NSMakeRect(260, top - 48, 180, 22) inView:view];
  [self addTypeSettingLabel:@"行間:" frame:NSMakeRect(24, top - 96, 130, 22)
                     inView:view];
  self.typeLineSpacingField = [self typeSettingNumberField:@"SakuraTypeLineSpacing"
      value:3 frame:NSMakeRect(166, top - 96, 82, 24) inView:view];
  [self addTypeSettingLabel:@"pt（0〜30）"
                     frame:NSMakeRect(260, top - 96, 180, 22) inView:view];
  [self addTypeSettingLabel:@"文字間隔:" frame:NSMakeRect(24, top - 144, 130, 22)
                     inView:view];
  self.typeCharacterSpacingField = [self
      typeSettingNumberField:@"SakuraTypeCharacterSpacing"
      value:0 frame:NSMakeRect(166, top - 144, 82, 24) inView:view];
  [self addTypeSettingLabel:@"pt（0〜10）"
                     frame:NSMakeRect(260, top - 144, 180, 22) inView:view];
  NSTextField* preview = [[NSTextField alloc]
      initWithFrame:NSMakeRect(24, top - 242, NSWidth(frame) - 48, 62)];
  preview.identifier = @"SakuraTypeFontPreview";
  preview.editable = NO;
  preview.selectable = NO;
  preview.alignment = NSTextAlignmentCenter;
  preview.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
  [view addSubview:preview];
  self.typeFontPreview = preview;
  return view;
}

- (SakuraEditorSettings*)typeEditorSettingsFromControls {
  SakuraEditorSettings* settings = [[SakuraEditorSettings alloc] init];
  settings.wrapMode = static_cast<SakuraEditorWrapMode>(
      self.typeWrapModePopup.indexOfSelectedItem);
  settings.wrapColumn = self.typeWrapColumnField.integerValue;
  settings.tabWidth = self.typeTabWidthField.integerValue;
  settings.showsLineNumbers =
      self.typeLineNumbersCheckbox.state == NSControlStateValueOn;
  settings.fontName = self.typeFontPopup.selectedItem.representedObject ?: @"";
  settings.fontSize = self.typeFontSizeField.doubleValue;
  settings.lineSpacing = self.typeLineSpacingField.doubleValue;
  settings.characterSpacing = self.typeCharacterSpacingField.doubleValue;
  return settings;
}

- (void)typeDisplayDraftChanged:(id)sender {
  (void)sender;
  self.typeWrapColumnField.enabled = self.typeWrapModePopup.indexOfSelectedItem ==
      SakuraEditorWrapModeColumn;
  SakuraEditorSettings* settings = [self typeEditorSettingsFromControls];
  // A numeric field can briefly be empty while editing. Keep the preview valid.
  settings.fontSize = std::clamp<CGFloat>(settings.fontSize, 8, 36);
  settings.characterSpacing = std::clamp<CGFloat>(settings.characterSpacing, 0, 10);
  self.typeFontPreview.attributedStringValue = [[NSAttributedString alloc]
      initWithString:@"Aa あア 0123  サクラエディタ"
          attributes:@{ NSFontAttributeName : settings.editorFont,
                        NSKernAttributeName : @(settings.characterSpacing) }];
}

- (void)populateTypeEditorSettingsControls:(SakuraEditorSettings*)settings {
  self.typeDisplayBaselineValues = settings.preferenceValues;
  [self.typeWrapModePopup selectItemAtIndex:settings.wrapMode];
  self.typeWrapColumnField.integerValue = settings.wrapColumn;
  self.typeTabWidthField.integerValue = settings.tabWidth;
  self.typeLineNumbersCheckbox.state = settings.showsLineNumbers
      ? NSControlStateValueOn : NSControlStateValueOff;
  [self.typeFontPopup selectItemAtIndex:0];
  BOOL foundFont = settings.fontName.length == 0;
  for (NSMenuItem* item in self.typeFontPopup.itemArray) {
    if ([item.representedObject isEqual:settings.fontName]) {
      [self.typeFontPopup selectItem:item];
      foundFont = YES;
      break;
    }
  }
  if (!foundFont) {
    [self.typeFontPopup addItemWithTitle:[NSString
        stringWithFormat:@"%@（未インストール）", settings.fontName]];
    self.typeFontPopup.lastItem.representedObject = settings.fontName;
    [self.typeFontPopup selectItem:self.typeFontPopup.lastItem];
  }
  self.typeFontSizeField.doubleValue = settings.fontSize;
  self.typeLineSpacingField.doubleValue = settings.lineSpacing;
  self.typeCharacterSpacingField.doubleValue = settings.characterSpacing;
  [self typeDisplayDraftChanged:nil];
}

- (void)refreshTypeEditorSettingsControls {
  self.typeDisplayResetPending = NO;
  [self populateTypeEditorSettingsControls:[SakuraEditorSettings
      settingsForTypeIdentifier:self.typeColorIdentifier
                      defaults:[self typeSettingsDefaults]]];
  self.typeDisplayResetStatus.stringValue =
      @"指定桁は半角文字幅を基準にします。\n既定に戻す対象はスクリーン／ウィンドウ設定です。サイズ・TAB幅は共通設定から継承します。";
}

- (void)resetTypeEditorSettings:(id)sender {
  (void)sender;
  [self.typeSettingsPanel makeFirstResponder:nil];
  [self populateTypeEditorSettingsControls:[SakuraEditorSettings
      inheritedSettingsWithDefaults:[self typeSettingsDefaults]]];
  self.typeDisplayResetPending = YES;
  self.typeDisplayResetStatus.stringValue =
      @"指定桁は半角文字幅を基準にします。\n既定へ戻す変更は適用／OKで保存します。その後に変更した項目だけをタイプ別に保存します。";
}

- (void)applyTypeSettings:(id)sender {
  (void)sender;
  // Commit any field still being edited before reading its value.
  [self.typeSettingsPanel makeFirstResponder:nil];
  SakuraEditorSettings* settings = [self typeEditorSettingsFromControls];
  NSDictionary<NSString*, id>* values = settings.preferenceValues;
  NSDictionary<NSString*, id>* baseline = self.typeDisplayBaselineValues ?:
      [SakuraEditorSettings settingsForTypeIdentifier:self.typeColorIdentifier
          defaults:[self typeSettingsDefaults]].preferenceValues;
  NSMutableSet<NSString*>* changed = [NSMutableSet set];
  for (NSString* property in values) {
    if (![values[property] isEqual:baseline[property]]) [changed addObject:property];
  }
  // Deletion is deferred until Apply. Cancel never writes a stale display
  // snapshot over another window's newer settings. Unedited inherited fields
  // stay absent, including when a user edits just one field after Reset.
  if (self.typeDisplayResetPending) {
    [SakuraEditorSettings resetForTypeIdentifier:self.typeColorIdentifier
                                      defaults:[self typeSettingsDefaults]];
  }
  [settings saveForTypeIdentifier:self.typeColorIdentifier
                         defaults:[self typeSettingsDefaults] properties:changed];
  [self.typeColorTransaction commit];
  [self refreshTypeEditorSettingsControls];
  [self redrawEditorsForTypeColorChange];
  // Apply establishes a new cancel boundary for both display and live colors.
  [self captureTypeColorSnapshot];
}

- (void)acceptTypeSettings:(id)sender {
  [self applyTypeSettings:sender];
  [self.typeSettingsPanel orderOut:self];
}

- (void)showTypeSettings:(id)sender {
  (void)sender;
  if (self.typeSettingsPanel.visible) {
    [self.typeSettingsPanel makeKeyAndOrderFront:self];
    return;
  }
  self.typeColorIdentifier = [self currentTypeIdentifier];
  self.typeColorEntries = [self defaultTypeColorEntries];
  if (self.typeSettingsPanel == nil) {
    NSPanel* panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 680, 480)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                            NSWindowStyleMaskResizable |
                            NSWindowStyleMaskUtilityWindow
                    backing:NSBackingStoreBuffered
                      defer:NO];
    panel.hidesOnDeactivate = NO;
    panel.floatingPanel = YES;
    panel.delegate = self;
    panel.minSize = NSMakeSize(600, 400);
    NSTabView* tabs = [[NSTabView alloc]
        initWithFrame:NSMakeRect(14, 54, 652, 412)];
    tabs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSTabViewItem* screenTab = [[NSTabViewItem alloc]
        initWithIdentifier:@"スクリーン"];
    screenTab.label = @"スクリーン";
    screenTab.view = [self makeTypeScreenSettingsViewWithFrame:tabs.contentRect];
    [tabs addTabViewItem:screenTab];
    NSTabViewItem* colorTab = [[NSTabViewItem alloc]
        initWithIdentifier:@"カラー"];
    colorTab.label = @"カラー";
    colorTab.view = [self makeTypeColorSettingsViewWithFrame:tabs.contentRect];
    [tabs addTabViewItem:colorTab];
    NSTabViewItem* windowTab = [[NSTabViewItem alloc]
        initWithIdentifier:@"ウィンドウ"];
    windowTab.label = @"ウィンドウ";
    windowTab.view = [self makeTypeWindowSettingsViewWithFrame:tabs.contentRect];
    [tabs addTabViewItem:windowTab];
    [self addSettingsTab:@"支援"
                   lines:@[@"入力補完・自動インデント", @"キーワードヘルプ"]
                      to:tabs];
    [self addSettingsTab:@"正規表現キーワード"
                   lines:@[@"正規表現による強調表示ルール"]
                      to:tabs];
    [self addSettingsTab:@"キーワードヘルプ"
                   lines:@[@"辞書ファイルと表示方法"]
                      to:tabs];
    [panel.contentView addSubview:tabs];
    NSButton* apply = [NSButton buttonWithTitle:@"適用"
                                           target:self
                                           action:@selector(applyTypeSettings:)];
    apply.frame = NSMakeRect(386, 16, 88, 28);
    apply.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [panel.contentView addSubview:apply];
    NSButton* ok = [NSButton buttonWithTitle:@"OK"
                                        target:self
                                        action:@selector(acceptTypeSettings:)];
    ok.keyEquivalent = @"\r";
    ok.frame = NSMakeRect(482, 16, 88, 28);
    ok.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [panel.contentView addSubview:ok];
    NSButton* cancel = [NSButton buttonWithTitle:@"キャンセル"
                                            target:self
                                            action:@selector(cancelTypeSettings:)];
    cancel.frame = NSMakeRect(578, 16, 88, 28);
    cancel.keyEquivalent = @"\e";
    cancel.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [panel.contentView addSubview:cancel];
    self.typeSettingsPanel = panel;
  }
  self.typeSettingsPanel.title = [NSString
      stringWithFormat:@"タイプ別設定 - %@", [self currentTypeName]];
  self.typeSettingsPanel.appearance = self.window.appearance;
  [self refreshTypeEditorSettingsControls];
  [self captureTypeColorSnapshot];
  [self.typeColorTableView reloadData];
  [self.typeColorTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                       byExtendingSelection:NO];
  [self refreshTypeColorControls];
  [self.typeSettingsPanel makeKeyAndOrderFront:self];
}

- (sakura::core::TextEncoding)selectedEncoding {
  return static_cast<sakura::core::TextEncoding>(
      [self.encodingPopup.selectedItem.representedObject integerValue]);
}

- (void)encodingSelectionChanged:(id)sender {
  (void)sender;
  const auto encoding = [self selectedEncoding];
  const BOOL supportsBom = encoding == sakura::core::TextEncoding::utf8 ||
      encoding == sakura::core::TextEncoding::utf16LittleEndian ||
      encoding == sakura::core::TextEncoding::utf16BigEndian;
  self.encodingBomCheckbox.enabled = supportsBom;
  if (!supportsBom) self.encodingBomCheckbox.state = NSControlStateValueOff;
}

- (void)applyEncodingSettings:(id)sender {
  (void)sender;
  SakuraDocument* document = (SakuraDocument*)self.document;
  [document setOutputEncoding:[self selectedEncoding]
                     writeBom:self.encodingBomCheckbox.state == NSControlStateValueOn];
  [document setPreferredLineEndingString:self.encodingEolPopup.titleOfSelectedItem];
  [self updateStatusForEditor:[self activeEditor]];
}

- (void)performEncodingReload {
  NSError* error = nil;
  if (![(SakuraDocument*)self.document reloadUsingEncoding:[self selectedEncoding]
                                                      error:&error]) {
    if (error != nil) [NSApp presentError:error];
    return;
  }
  SakuraDocument* document = (SakuraDocument*)self.document;
  [document setPreferredLineEndingString:self.encodingEolPopup.titleOfSelectedItem];
  [self updateStatusForEditor:[self activeEditor]];
  [self.encodingPanel orderOut:self];
}

- (void)reloadWithEncodingSettings:(id)sender {
  (void)sender;
  if (![(SakuraDocument*)self.document isDocumentEdited]) {
    [self performEncodingReload];
    return;
  }
  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = @"編集中の変更を破棄して開き直しますか？";
  alert.informativeText = @"この操作は取り消せません。";
  [alert addButtonWithTitle:@"開き直す"];
  [alert addButtonWithTitle:@"キャンセル"];
  [alert beginSheetModalForWindow:self.encodingPanel
                completionHandler:^(NSModalResponse response) {
    if (response == NSAlertFirstButtonReturn) [self performEncodingReload];
  }];
}

- (void)acceptEncodingSettings:(id)sender {
  [self applyEncodingSettings:sender];
  [self.encodingPanel orderOut:self];
}

- (void)showEncodingPanel:(id)sender {
  (void)sender;
  if (self.encodingPanel == nil) {
    NSPanel* panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 470, 250)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                            NSWindowStyleMaskUtilityWindow
                    backing:NSBackingStoreBuffered defer:NO];
    panel.title = @"文字コード・改行コード";
    panel.hidesOnDeactivate = NO;
    panel.floatingPanel = YES;
    NSTextField* encodingLabel = [NSTextField labelWithString:@"文字コード:"];
    encodingLabel.frame = NSMakeRect(28, 184, 110, 22);
    [panel.contentView addSubview:encodingLabel];
    NSPopUpButton* encodingPopup = [[NSPopUpButton alloc]
        initWithFrame:NSMakeRect(146, 180, 230, 28) pullsDown:NO];
    NSArray<NSDictionary*>* encodings = @[
      @{ @"title" : @"UTF-8", @"value" : @(static_cast<NSInteger>(sakura::core::TextEncoding::utf8)) },
      @{ @"title" : @"UTF-16 LE", @"value" : @(static_cast<NSInteger>(sakura::core::TextEncoding::utf16LittleEndian)) },
      @{ @"title" : @"UTF-16 BE", @"value" : @(static_cast<NSInteger>(sakura::core::TextEncoding::utf16BigEndian)) },
      @{ @"title" : @"Shift_JIS (CP932)", @"value" : @(static_cast<NSInteger>(sakura::core::TextEncoding::shiftJis)) },
      @{ @"title" : @"EUC-JP", @"value" : @(static_cast<NSInteger>(sakura::core::TextEncoding::eucJp)) },
      @{ @"title" : @"ISO-2022-JP (JIS)", @"value" : @(static_cast<NSInteger>(sakura::core::TextEncoding::iso2022Jp)) },
    ];
    for (NSDictionary* entry in encodings) {
      [encodingPopup addItemWithTitle:entry[@"title"]];
      encodingPopup.lastItem.representedObject = entry[@"value"];
    }
    encodingPopup.target = self;
    encodingPopup.action = @selector(encodingSelectionChanged:);
    [panel.contentView addSubview:encodingPopup];
    NSButton* bom = [NSButton checkboxWithTitle:@"BOMを付けて保存"
                                          target:nil action:nil];
    bom.frame = NSMakeRect(146, 142, 190, 24);
    [panel.contentView addSubview:bom];
    NSTextField* eolLabel = [NSTextField labelWithString:@"入力改行コード:"];
    eolLabel.frame = NSMakeRect(28, 104, 120, 22);
    [panel.contentView addSubview:eolLabel];
    NSPopUpButton* eol = [[NSPopUpButton alloc]
        initWithFrame:NSMakeRect(146, 100, 120, 28) pullsDown:NO];
    [eol addItemsWithTitles:@[ @"CRLF", @"LF", @"CR" ]];
    [panel.contentView addSubview:eol];
    NSButton* reload = [NSButton buttonWithTitle:@"指定して開き直す"
                                           target:self
                                           action:@selector(reloadWithEncodingSettings:)];
    reload.frame = NSMakeRect(28, 28, 128, 30);
    [panel.contentView addSubview:reload];
    NSButton* ok = [NSButton buttonWithTitle:@"OK" target:self
                                      action:@selector(acceptEncodingSettings:)];
    ok.frame = NSMakeRect(274, 28, 78, 30);
    [panel.contentView addSubview:ok];
    NSButton* cancel = [NSButton buttonWithTitle:@"キャンセル" target:panel
                                          action:@selector(orderOut:)];
    cancel.frame = NSMakeRect(360, 28, 88, 30);
    [panel.contentView addSubview:cancel];
    self.encodingPanel = panel;
    self.encodingPopup = encodingPopup;
    self.encodingBomCheckbox = bom;
    self.encodingEolPopup = eol;
  }
  const auto state = ((SakuraDocument*)self.document).documentSession.encodingState();
  for (NSMenuItem* item in self.encodingPopup.itemArray) {
    if ([item.representedObject integerValue] == static_cast<NSInteger>(state.encoding)) {
      [self.encodingPopup selectItem:item];
      break;
    }
  }
  self.encodingBomCheckbox.state = state.hadBom
      ? NSControlStateValueOn : NSControlStateValueOff;
  [self.encodingEolPopup selectItemWithTitle:
      [(SakuraDocument*)self.document preferredLineEndingString]];
  self.encodingPanel.appearance = self.window.appearance;
  [self encodingSelectionChanged:self];
  [self.encodingPanel makeKeyAndOrderFront:self];
}

- (void)applyCommonSettings:(id)sender {
  (void)sender;
  const double fontSize = std::clamp(self.commonFontSizeField.doubleValue,
                                     8.0, 36.0);
  const NSInteger tabWidth = std::clamp<NSInteger>(
      self.commonTabWidthField.integerValue, 1, 16);
  self.commonFontSizeField.doubleValue = fontSize;
  self.commonTabWidthField.integerValue = tabWidth;
  NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
  [defaults setDouble:fontSize forKey:@"SakuraEditorFontSize"];
  [defaults setInteger:tabWidth forKey:@"SakuraEditorTabWidth"];
  NSArray<NSString*>* themeValues = @[
    SakuraEditorColorThemeWindows,
    SakuraEditorColorThemeSystem,
    SakuraEditorColorThemeDark,
  ];
  const NSInteger themeIndex = std::clamp<NSInteger>(
      self.commonThemePopup.indexOfSelectedItem, 0,
      static_cast<NSInteger>(themeValues.count) - 1);
  [defaults setObject:themeValues[static_cast<NSUInteger>(themeIndex)]
               forKey:SakuraEditorColorThemeKey];
  [defaults setBool:self.toolbarFlatCheckbox.state == NSControlStateValueOn
             forKey:@"SakuraToolbarFlat"];
  [defaults setBool:self.toolbarVisibleCheckbox.state == NSControlStateValueOn
             forKey:@"SakuraToolbarVisible"];
  [defaults setObject:self.toolbarDraftItems != nil ? self.toolbarDraftItems : @[]
               forKey:@"SakuraToolbarItems"];
  for (NSWindow* window in NSApp.windows) {
    if (![window.windowController isKindOfClass:[SakuraWindowController class]]) {
      continue;
    }
    SakuraWindowController* controller =
        (SakuraWindowController*)window.windowController;
    [controller rebuildToolbar];
    [controller applyColorTheme];
    for (SakuraEditorView* editor in controller.editorViews) {
      [editor displaySettingsDidChange];
    }
  }
}

- (void)acceptCommonSettings:(id)sender {
  [self applyCommonSettings:sender];
  [self.commonSettingsPanel orderOut:self];
}

- (NSTableView*)toolbarSettingsTableWithIdentifier:(NSString*)identifier
                                              frame:(NSRect)frame
                                             inView:(NSView*)view {
  NSTableView* table = [[NSTableView alloc] initWithFrame:NSZeroRect];
  table.identifier = identifier;
  table.headerView = nil;
  table.rowHeight = 23.0;
  table.dataSource = self;
  table.delegate = self;
  table.allowsMultipleSelection = NO;
  table.usesAlternatingRowBackgroundColors = NO;
  NSTableColumn* column = [[NSTableColumn alloc] initWithIdentifier:@"item"];
  column.width = NSWidth(frame) - 4.0;
  [table addTableColumn:column];
  NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:frame];
  scroll.borderType = NSBezelBorder;
  scroll.hasVerticalScroller = YES;
  scroll.autohidesScrollers = YES;
  scroll.documentView = table;
  scroll.autoresizingMask = NSViewHeightSizable;
  [view addSubview:scroll];
  return table;
}

- (NSView*)makeWindowSettingsViewWithFrame:(NSRect)frame {
  NSView* view = [[NSView alloc] initWithFrame:frame];
  NSBox* bars = [[NSBox alloc]
      initWithFrame:NSMakeRect(18, NSHeight(frame) - 150,
                               NSWidth(frame) - 36, 126)];
  bars.title = @"ウィンドウの表示";
  bars.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
  [view addSubview:bars];
  NSButton* toolbar = [NSButton checkboxWithTitle:@"ツールバー表示(&T)"
                                            target:nil action:nil];
  toolbar.frame = NSMakeRect(18, 76, 210, 24);
  [bars addSubview:toolbar];
  NSButton* tabBar = [NSButton checkboxWithTitle:@"タブバー表示(&B)"
                                           target:nil action:nil];
  tabBar.frame = NSMakeRect(18, 46, 210, 24);
  tabBar.enabled = NO;
  [bars addSubview:tabBar];
  NSButton* functionKeys = [NSButton checkboxWithTitle:@"ファンクションキー表示(&K)"
                                                 target:nil action:nil];
  functionKeys.frame = NSMakeRect(18, 16, 250, 24);
  functionKeys.enabled = NO;
  [bars addSubview:functionKeys];
  NSTextField* note = [NSTextField labelWithString:
      @"ツールバー表示は開いている全ウィンドウへ即時反映されます。"];
  note.textColor = NSColor.secondaryLabelColor;
  note.frame = NSMakeRect(28, NSHeight(frame) - 190, NSWidth(frame) - 56, 22);
  note.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
  [view addSubview:note];
  self.toolbarVisibleCheckbox = toolbar;
  return view;
}

- (void)reloadToolbarAvailableEntries {
  NSString* category = self.toolbarCategoryPopup.titleOfSelectedItem;
  NSPredicate* predicate = [category isEqualToString:@"すべて"]
      ? [NSPredicate predicateWithValue:YES]
      : [NSPredicate predicateWithBlock:^BOOL(NSDictionary* descriptor,
                                               NSDictionary* bindings) {
          (void)bindings;
          return [descriptor[@"category"] isEqualToString:category];
        }];
  self.toolbarAvailableEntries = [[self toolbarDescriptors]
      filteredArrayUsingPredicate:predicate];
  [self.toolbarAvailableTable reloadData];
  if (self.toolbarAvailableEntries.count != 0) {
    [self.toolbarAvailableTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                            byExtendingSelection:NO];
  }
}

- (void)toolbarCategoryChanged:(id)sender {
  (void)sender;
  [self reloadToolbarAvailableEntries];
}

- (NSString*)selectedAvailableToolbarIdentifier {
  const NSInteger row = self.toolbarAvailableTable.selectedRow;
  return row >= 0 && static_cast<NSUInteger>(row) <
      self.toolbarAvailableEntries.count
      ? self.toolbarAvailableEntries[static_cast<NSUInteger>(row)][@"id"] : nil;
}

- (void)reloadToolbarDraftSelectingRow:(NSInteger)row {
  [self.toolbarCurrentTable reloadData];
  if (row >= 0 && static_cast<NSUInteger>(row) < self.toolbarDraftItems.count) {
    [self.toolbarCurrentTable selectRowIndexes:[NSIndexSet indexSetWithIndex:row]
                          byExtendingSelection:NO];
    [self.toolbarCurrentTable scrollRowToVisible:row];
  }
}

- (void)addToolbarItem:(id)sender {
  (void)sender;
  NSString* identifier = [self selectedAvailableToolbarIdentifier];
  if (identifier == nil) {
    NSBeep();
    return;
  }
  [self.toolbarDraftItems addObject:identifier];
  [self reloadToolbarDraftSelectingRow:
      static_cast<NSInteger>(self.toolbarDraftItems.count) - 1];
}

- (void)insertToolbarItem:(id)sender {
  (void)sender;
  NSString* identifier = [self selectedAvailableToolbarIdentifier];
  if (identifier == nil) {
    NSBeep();
    return;
  }
  NSInteger row = self.toolbarCurrentTable.selectedRow;
  if (row < 0) {
    row = 0;
  }
  [self.toolbarDraftItems insertObject:identifier
                               atIndex:static_cast<NSUInteger>(row)];
  [self reloadToolbarDraftSelectingRow:row];
}

- (void)insertToolbarMarker:(NSString*)marker {
  NSInteger row = self.toolbarCurrentTable.selectedRow;
  if (row < 0) {
    row = 0;
  }
  [self.toolbarDraftItems insertObject:marker
                               atIndex:static_cast<NSUInteger>(row)];
  [self reloadToolbarDraftSelectingRow:row];
}

- (void)insertToolbarSeparator:(id)sender {
  (void)sender;
  [self insertToolbarMarker:@"separator"];
}

- (void)insertToolbarWrap:(id)sender {
  (void)sender;
  [self insertToolbarMarker:@"wrap"];
}

- (void)deleteToolbarItem:(id)sender {
  (void)sender;
  const NSInteger row = self.toolbarCurrentTable.selectedRow;
  if (row < 0 || static_cast<NSUInteger>(row) >= self.toolbarDraftItems.count) {
    NSBeep();
    return;
  }
  [self.toolbarDraftItems removeObjectAtIndex:static_cast<NSUInteger>(row)];
  [self reloadToolbarDraftSelectingRow:std::min<NSInteger>(
      row, static_cast<NSInteger>(self.toolbarDraftItems.count) - 1)];
}

- (void)moveToolbarItemBy:(NSInteger)delta {
  const NSInteger row = self.toolbarCurrentTable.selectedRow;
  const NSInteger destination = row + delta;
  if (row < 0 || destination < 0 ||
      static_cast<NSUInteger>(destination) >= self.toolbarDraftItems.count) {
    NSBeep();
    return;
  }
  [self.toolbarDraftItems exchangeObjectAtIndex:static_cast<NSUInteger>(row)
                              withObjectAtIndex:static_cast<NSUInteger>(destination)];
  [self reloadToolbarDraftSelectingRow:destination];
}

- (void)moveToolbarItemUp:(id)sender {
  (void)sender;
  [self moveToolbarItemBy:-1];
}

- (void)moveToolbarItemDown:(id)sender {
  (void)sender;
  [self moveToolbarItemBy:1];
}

- (NSView*)makeToolbarSettingsViewWithFrame:(NSRect)frame {
  NSView* view = [[NSView alloc] initWithFrame:frame];
  NSTextField* categoryLabel = [NSTextField labelWithString:@"種別(&K)"];
  categoryLabel.frame = NSMakeRect(16, NSHeight(frame) - 34, 68, 22);
  [view addSubview:categoryLabel];
  NSPopUpButton* category = [[NSPopUpButton alloc]
      initWithFrame:NSMakeRect(82, NSHeight(frame) - 38, 136, 28)
          pullsDown:NO];
  [category addItemsWithTitles:@[
    @"ファイル", @"編集", @"移動", @"検索", @"ツール", @"設定", @"すべて"
  ]];
  category.target = self;
  category.action = @selector(toolbarCategoryChanged:);
  [view addSubview:category];

  NSButton* flat = [NSButton checkboxWithTitle:@"フラットなボタン(&L)"
                                        target:nil action:nil];
  flat.frame = NSMakeRect(NSWidth(frame) - 190, NSHeight(frame) - 36, 176, 24);
  [view addSubview:flat];

  NSTextField* availableLabel = [NSTextField labelWithString:@"機能(&F)"];
  availableLabel.frame = NSMakeRect(16, NSHeight(frame) - 68, 150, 22);
  [view addSubview:availableLabel];
  NSTextField* currentLabel = [NSTextField labelWithString:@"ツールバー(&T)"];
  currentLabel.frame = NSMakeRect(NSWidth(frame) - 256,
                                  NSHeight(frame) - 68, 180, 22);
  [view addSubview:currentLabel];

  const CGFloat listTop = NSHeight(frame) - 72;
  const CGFloat listHeight = std::max<CGFloat>(180.0, listTop - 18.0);
  self.toolbarAvailableTable = [self toolbarSettingsTableWithIdentifier:
      @"SakuraToolbarAvailable" frame:NSMakeRect(16, 18, 240, listHeight)
      inView:view];
  self.toolbarAvailableTable.doubleAction = @selector(addToolbarItem:);
  self.toolbarAvailableTable.target = self;
  self.toolbarCurrentTable = [self toolbarSettingsTableWithIdentifier:
      @"SakuraToolbarCurrent"
      frame:NSMakeRect(NSWidth(frame) - 256, 18, 240, listHeight) inView:view];

  NSArray<NSDictionary*>* actions = @[
    @{ @"title": @"削除(&D)", @"action": @"deleteToolbarItem:" },
    @{ @"title": @"---(&S)", @"action": @"insertToolbarSeparator:" },
    @{ @"title": @"→(&A)", @"action": @"insertToolbarItem:" },
    @{ @"title": @">>(&B)", @"action": @"addToolbarItem:" },
    @{ @"title": @"↑(&U)", @"action": @"moveToolbarItemUp:" },
    @{ @"title": @"↓(&O)", @"action": @"moveToolbarItemDown:" },
    @{ @"title": @"折返(&W)", @"action": @"insertToolbarWrap:" },
  ];
  CGFloat buttonY = NSHeight(frame) - 112.0;
  for (NSDictionary* action in actions) {
    NSButton* button = [NSButton buttonWithTitle:action[@"title"]
                                          target:self
                                          action:NSSelectorFromString(action[@"action"])];
    button.frame = NSMakeRect((NSWidth(frame) - 86.0) / 2.0,
                              buttonY, 86.0, 26.0);
    [view addSubview:button];
    buttonY -= [action[@"title"] hasPrefix:@"折返"] ? 0.0 : 32.0;
  }
  self.toolbarCategoryPopup = category;
  self.toolbarFlatCheckbox = flat;
  [self reloadToolbarAvailableEntries];
  return view;
}

- (void)showCommonSettings:(id)sender {
  (void)sender;
  if (self.commonSettingsPanel == nil) {
    NSPanel* panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 660, 460)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                            NSWindowStyleMaskResizable |
                            NSWindowStyleMaskUtilityWindow
                    backing:NSBackingStoreBuffered
                      defer:NO];
    panel.title = @"共通設定";
    panel.hidesOnDeactivate = NO;
    panel.floatingPanel = YES;
    panel.minSize = NSMakeSize(600, 400);
    NSTabView* tabs = [[NSTabView alloc]
        initWithFrame:NSMakeRect(14, 54, 632, 392)];
    tabs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSTabViewItem* general = [[NSTabViewItem alloc] initWithIdentifier:@"全般"];
    general.label = @"全般";
    NSView* generalView = [[NSView alloc] initWithFrame:tabs.contentRect];
    NSTextField* fontLabel = [NSTextField labelWithString:@"エディタのフォントサイズ:"];
    fontLabel.frame = NSMakeRect(28, 292, 180, 22);
    [generalView addSubview:fontLabel];
    NSTextField* fontField = [[NSTextField alloc] initWithFrame:NSMakeRect(214, 288, 72, 26)];
    [generalView addSubview:fontField];
    NSTextField* pointLabel = [NSTextField labelWithString:@"pt"];
    pointLabel.frame = NSMakeRect(294, 292, 30, 22);
    [generalView addSubview:pointLabel];
    NSTextField* tabLabel = [NSTextField labelWithString:@"TAB幅:"];
    tabLabel.frame = NSMakeRect(28, 250, 180, 22);
    [generalView addSubview:tabLabel];
    NSTextField* tabField = [[NSTextField alloc] initWithFrame:NSMakeRect(214, 246, 72, 26)];
    [generalView addSubview:tabField];
    NSTextField* themeLabel = [NSTextField labelWithString:@"配色テーマ:"];
    themeLabel.frame = NSMakeRect(28, 208, 180, 22);
    [generalView addSubview:themeLabel];
    NSPopUpButton* themePopup = [[NSPopUpButton alloc]
        initWithFrame:NSMakeRect(214, 204, 210, 28) pullsDown:NO];
    [themePopup addItemsWithTitles:@[
      @"Windows クラシック（既定）",
      @"macOS の外観に合わせる",
      @"ダーク",
    ]];
    [generalView addSubview:themePopup];
    NSTextField* note = [NSTextField labelWithString:
        @"設定はすべての編集中ウィンドウへ即時反映されます。"];
    note.textColor = NSColor.secondaryLabelColor;
    note.frame = NSMakeRect(28, 160, 500, 22);
    [generalView addSubview:note];
    general.view = generalView;
    [tabs addTabViewItem:general];
    NSTabViewItem* windowTab = [[NSTabViewItem alloc]
        initWithIdentifier:@"ウィンドウ"];
    windowTab.label = @"ウィンドウ";
    windowTab.view = [self makeWindowSettingsViewWithFrame:tabs.contentRect];
    [tabs addTabViewItem:windowTab];
    [self addSettingsTab:@"メインメニュー" lines:@[@"メニュー構成とアクセスキー"] to:tabs];
    NSTabViewItem* toolbarTab = [[NSTabViewItem alloc]
        initWithIdentifier:@"ツールバー"];
    toolbarTab.label = @"ツールバー";
    toolbarTab.view = [self makeToolbarSettingsViewWithFrame:tabs.contentRect];
    [tabs addTabViewItem:toolbarTab];
    [self addSettingsTab:@"タブバー" lines:@[@"タブ表示と複数ウィンドウ設定"] to:tabs];
    [self addSettingsTab:@"ステータスバー" lines:@[@"文字コード値と選択文字数表示"] to:tabs];
    [self addSettingsTab:@"検索" lines:@[@"検索・Grepの既定条件"] to:tabs];
    [self addSettingsTab:@"キー割り当て" lines:@[@"コマンドとショートカット"] to:tabs];
    [self addSettingsTab:@"マクロ" lines:@[@"キーマクロと外部マクロ"] to:tabs];
    [self addSettingsTab:@"プラグイン" lines:@[@"プラグインの有効化と管理"] to:tabs];
    [panel.contentView addSubview:tabs];

    NSButton* apply = [NSButton buttonWithTitle:@"適用"
                                           target:self
                                           action:@selector(applyCommonSettings:)];
    apply.frame = NSMakeRect(366, 16, 88, 28);
    apply.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [panel.contentView addSubview:apply];
    NSButton* ok = [NSButton buttonWithTitle:@"OK"
                                        target:self
                                        action:@selector(acceptCommonSettings:)];
    ok.frame = NSMakeRect(462, 16, 88, 28);
    ok.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [panel.contentView addSubview:ok];
    NSButton* cancel = [NSButton buttonWithTitle:@"キャンセル"
                                            target:panel
                                            action:@selector(orderOut:)];
    cancel.frame = NSMakeRect(558, 16, 88, 28);
    cancel.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [panel.contentView addSubview:cancel];
    self.commonSettingsPanel = panel;
    self.commonFontSizeField = fontField;
    self.commonTabWidthField = tabField;
    self.commonThemePopup = themePopup;
  }
  NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
  self.commonFontSizeField.doubleValue = [defaults doubleForKey:@"SakuraEditorFontSize"];
  self.commonTabWidthField.integerValue = [defaults integerForKey:@"SakuraEditorTabWidth"];
  self.toolbarDraftItems = [[self configuredToolbarItems] mutableCopy];
  self.toolbarFlatCheckbox.state = [defaults boolForKey:@"SakuraToolbarFlat"]
      ? NSControlStateValueOn : NSControlStateValueOff;
  self.toolbarVisibleCheckbox.state = [defaults boolForKey:@"SakuraToolbarVisible"]
      ? NSControlStateValueOn : NSControlStateValueOff;
  [self.toolbarCurrentTable reloadData];
  if (self.toolbarDraftItems.count != 0) {
    [self.toolbarCurrentTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                          byExtendingSelection:NO];
  }
  NSString* theme = [defaults stringForKey:SakuraEditorColorThemeKey];
  NSInteger themeIndex = [theme isEqualToString:SakuraEditorColorThemeSystem]
      ? 1 : ([theme isEqualToString:SakuraEditorColorThemeDark] ? 2 : 0);
  [self.commonThemePopup selectItemAtIndex:themeIndex];
  [self.commonSettingsPanel makeKeyAndOrderFront:self];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView {
  if (tableView == self.grepTableView) {
    return static_cast<NSInteger>(self.grepResults.count);
  }
  if (tableView == self.outlineTableView) {
    return static_cast<NSInteger>(self.outlineEntries.count);
  }
  if (tableView == self.commandTableView) {
    return static_cast<NSInteger>(self.commandEntries.count);
  }
  if (tableView == self.toolbarAvailableTable) {
    return static_cast<NSInteger>(self.toolbarAvailableEntries.count);
  }
  if (tableView == self.toolbarCurrentTable) {
    return static_cast<NSInteger>(self.toolbarDraftItems.count);
  }
  if (tableView == self.typeColorTableView) {
    return static_cast<NSInteger>(self.typeColorEntries.count);
  }
  return 0;
}

- (NSView*)tableView:(NSTableView*)tableView
   viewForTableColumn:(NSTableColumn*)tableColumn
                  row:(NSInteger)row {
  (void)tableColumn;
  const BOOL isOutline = tableView == self.outlineTableView;
  const BOOL isCommand = tableView == self.commandTableView;
  const BOOL isGrep = tableView == self.grepTableView;
  const BOOL isToolbarAvailable = tableView == self.toolbarAvailableTable;
  const BOOL isToolbarCurrent = tableView == self.toolbarCurrentTable;
  const BOOL isTypeColor = tableView == self.typeColorTableView;
  if (isTypeColor) {
    if (row < 0 || static_cast<NSUInteger>(row) >= self.typeColorEntries.count) {
      return nil;
    }
    NSDictionary* entry = self.typeColorEntries[static_cast<NSUInteger>(row)];
    NSString* columnIdentifier = tableColumn.identifier;
    NSTextField* cell = [tableView makeViewWithIdentifier:columnIdentifier
                                                    owner:self];
    if (cell == nil) {
      cell = [NSTextField labelWithString:@""];
      cell.identifier = columnIdentifier;
      cell.font = [NSFont systemFontOfSize:12.0];
      cell.lineBreakMode = NSLineBreakByTruncatingTail;
    }
    if ([columnIdentifier isEqualToString:@"item"]) {
      cell.stringValue = entry[@"title"];
      cell.textColor = NSColor.labelColor;
    } else {
      id role = entry[columnIdentifier];
      cell.alignment = NSTextAlignmentCenter;
      cell.stringValue = role == NSNull.null ? @"—" : @"■";
      cell.textColor = role == NSNull.null
          ? NSColor.tertiaryLabelColor : [self effectiveTypeColorForRole:role];
    }
    return cell;
  }
  if (isToolbarAvailable || isToolbarCurrent) {
    const NSUInteger index = static_cast<NSUInteger>(std::max<NSInteger>(0, row));
    if (row < 0 || (isToolbarAvailable
        ? index >= self.toolbarAvailableEntries.count
        : index >= self.toolbarDraftItems.count)) {
      return nil;
    }
    NSDictionary* descriptor = nil;
    NSString* title = nil;
    if (isToolbarAvailable) {
      descriptor = self.toolbarAvailableEntries[index];
      title = descriptor[@"title"];
    } else {
      NSString* toolbarIdentifier = self.toolbarDraftItems[index];
      if ([toolbarIdentifier isEqualToString:@"separator"]) {
        title = @"―― セパレータ ――";
      } else if ([toolbarIdentifier isEqualToString:@"wrap"]) {
        title = @"―― ツールバー折返 ――";
      } else {
        descriptor = [self toolbarDescriptorForIdentifier:toolbarIdentifier];
        title = descriptor[@"title"] != nil ? descriptor[@"title"]
                                               : toolbarIdentifier;
      }
    }
    NSUserInterfaceItemIdentifier identifier = isToolbarAvailable
        ? @"SakuraToolbarAvailableCell" : @"SakuraToolbarCurrentCell";
    NSTableCellView* cell = [tableView makeViewWithIdentifier:identifier owner:self];
    if (cell == nil) {
      cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 220, 23)];
      cell.identifier = identifier;
      NSImageView* imageView = [[NSImageView alloc]
          initWithFrame:NSMakeRect(3, 3, 16, 16)];
      imageView.imageScaling = NSImageScaleNone;
      cell.imageView = imageView;
      [cell addSubview:imageView];
      NSTextField* textField = [NSTextField labelWithString:@""];
      textField.frame = NSMakeRect(25, 2, 190, 19);
      textField.lineBreakMode = NSLineBreakByTruncatingTail;
      textField.font = [NSFont systemFontOfSize:12.0];
      textField.autoresizingMask = NSViewWidthSizable;
      cell.textField = textField;
      [cell addSubview:textField];
    }
    cell.textField.stringValue = title != nil ? title : @"";
    cell.imageView.image = descriptor != nil
        ? [self toolbarImageNamed:descriptor[@"image"]
                  fallbackSymbol:descriptor[@"symbol"]] : nil;
    return cell;
  }
  NSArray<NSDictionary*>* entries = isGrep ? self.grepResults
      : (isOutline ? self.outlineEntries : self.commandEntries);
  if ((!isOutline && !isCommand && !isGrep) || row < 0 ||
      static_cast<NSUInteger>(row) >= entries.count) {
    return nil;
  }
  NSUserInterfaceItemIdentifier identifier = isGrep ? @"SakuraGrepCell"
      : (isOutline ? @"SakuraOutlineCell" : @"SakuraCommandCell");
  NSTextField* cell = [tableView makeViewWithIdentifier:identifier owner:self];
  if (cell == nil) {
    cell = [NSTextField labelWithString:@""];
    cell.identifier = identifier;
    cell.font = [NSFont monospacedSystemFontOfSize:12.0
                                           weight:NSFontWeightRegular];
    cell.lineBreakMode = NSLineBreakByTruncatingTail;
  }
  cell.stringValue = entries[static_cast<NSUInteger>(row)][@"title"];
  return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification*)notification {
  if (notification.object == self.typeColorTableView) {
    [self refreshTypeColorControls];
  }
}

- (void)replaceSearchSelection:(id)sender {
  [NSApp sendAction:@selector(replaceSearchSelection:)
                  to:[self activeEditor]
                from:sender];
}

- (void)toolbarSearch:(id)sender {
  NSString* query = [(NSSearchField*)sender stringValue];
  if (query.length == 0) {
    NSBeep();
    return;
  }
  [[self activeEditor] findTextFromToolbar:query];
}

- (void)toggleSplitEditor:(id)sender {
  (void)sender;
  if (self.secondaryEditorView != nil) {
    [self.primaryScrollView removeFromSuperview];
    self.editorSplitView = nil;
    self.secondaryScrollView = nil;
    self.secondaryEditorView = nil;
    self.primaryScrollView.frame = self.editorHostView.bounds;
    [self.editorHostView addSubview:self.primaryScrollView];
    [self.window makeFirstResponder:self.editorView];
    return;
  }

  const NSRect bounds = self.editorHostView.bounds;
  SakuraEditorView* secondary = [[SakuraEditorView alloc]
      initWithFrame:NSMakeRect(0, 0, NSWidth(bounds) * 0.5, NSHeight(bounds))
           document:(SakuraDocument*)self.document];
  NSScrollView* secondaryScroll = [self scrollViewForEditor:secondary
      frame:NSMakeRect(0, 0, NSWidth(bounds) * 0.5, NSHeight(bounds))];
  NSSplitView* splitView = [[NSSplitView alloc] initWithFrame:bounds];
  splitView.vertical = YES;
  splitView.dividerStyle = NSSplitViewDividerStyleThin;
  splitView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [self.primaryScrollView removeFromSuperview];
  [splitView addSubview:self.primaryScrollView];
  [splitView addSubview:secondaryScroll];
  [self.editorHostView addSubview:splitView];
  [splitView setPosition:std::floor(NSWidth(bounds) * 0.5)
         ofDividerAtIndex:0];
  self.secondaryEditorView = secondary;
  self.secondaryScrollView = secondaryScroll;
  self.editorSplitView = splitView;
  [self.window makeFirstResponder:secondary];
}

- (void)updateStatusForEditor:(SakuraEditorView*)editor {
  if (editor == nil || self.document == nil) {
    return;
  }
  SakuraDocument* document = (SakuraDocument*)self.document;
  const auto& buffer = document.documentSession.buffer();
  const NSRange selection = [editor selectedRange];
  const auto position = buffer.positionAt(
      std::min<sakura::core::TextOffset>(selection.location, buffer.length()));
  self.statusPosition.stringValue = [NSString
      stringWithFormat:@"%zu 行 %llu 桁", position.line + 1,
                       static_cast<unsigned long long>(position.column + 1)];
  switch (buffer.line(position.line).ending) {
    case sakura::core::LineEnding::carriageReturnLineFeed:
      self.statusEol.stringValue = @"CRLF";
      break;
    case sakura::core::LineEnding::lineFeed:
      self.statusEol.stringValue = @"LF";
      break;
    case sakura::core::LineEnding::carriageReturn:
      self.statusEol.stringValue = @"CR";
      break;
    case sakura::core::LineEnding::none:
      self.statusEol.stringValue = @"なし";
      break;
  }
  self.statusEncoding.stringValue = stringFromUtf8(
      sakura::core::EncodingService::name(document.documentSession.encodingState().encoding));
  self.statusCharCode.stringValue = @"";
  if (selection.location < buffer.length()) {
    const auto remaining = buffer.length() - selection.location;
    const auto text = buffer.slice({selection.location, std::min<sakura::core::TextOffset>(
                                                            2, remaining)});
    if (!text.empty()) {
      std::uint32_t codePoint = text.front();
      if (text.size() >= 2 && text[0] >= u'\xD800' && text[0] <= u'\xDBFF' &&
          text[1] >= u'\xDC00' && text[1] <= u'\xDFFF') {
        codePoint = 0x10000U +
                    ((static_cast<std::uint32_t>(text[0]) - 0xD800U) << 10U) +
                    (static_cast<std::uint32_t>(text[1]) - 0xDC00U);
      }
      self.statusCharCode.stringValue = [NSString
          stringWithFormat:codePoint <= 0xFFFFU ? @"U+%04X" : @"U+%06X",
                           codePoint];
    }
  }
  NSString* fileName = document.fileURL.lastPathComponent;
  NSString* baseMessage = fileName != nil ? fileName : @"名称未設定";
  const NSUInteger selectedCount = [editor selectedCharacterCount];
  self.statusMessage.stringValue = selectedCount == 0
      ? baseMessage
      : [NSString stringWithFormat:[editor hasRectangularSelection]
            ? @"%@  (矩形 %lu 文字選択)" : @"%@  (%lu 文字選択)",
          baseMessage, (unsigned long)selectedCount];
}

- (void)showWindow:(id)sender {
  [super showWindow:sender];
  [self.window makeFirstResponder:self.editorView];
}

@end
