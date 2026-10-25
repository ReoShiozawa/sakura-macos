// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#import "SakuraEditorView.h"

#import <CoreText/CoreText.h>

#include <algorithm>
#include <cmath>
#include <chrono>
#include <deque>
#include <exception>
#include <limits>
#include <memory>
#include <stdexcept>
#include <vector>

#import "SakuraDocument.h"
#import "SakuraColorTheme.h"
#import "SakuraEditorSettings.h"
#import "SakuraSyntaxSettings.h"
#import "SakuraSearchState.h"
#import "SakuraLayoutRows.h"
#import "SakuraWindowController.h"
#include "sakura/core/layout/LayoutEngine.h"
#include "sakura/core/syntax/SyntaxHighlighter.h"
#include "sakura/core/syntax/IndexedSyntax.h"
#include "sakura/platform/mac/CoreTextMetrics.h"
#include "sakura/platform/mac/StringBridge.h"

@interface SakuraDocument (HistoryNavigationInternals)
- (BOOL)closingDocument;
@end

namespace {

constexpr CGFloat kHorizontalInset = 10.0;
constexpr CGFloat kVerticalInset = 8.0;
constexpr CGFloat kGutterWidth = 48.0;
constexpr CGFloat kTextOriginX = kGutterWidth + kHorizontalInset;
constexpr CGFloat kMinimumContentWidth = 320.0;
constexpr CGFloat kMinimumContentHeight = 200.0;
dispatch_queue_t replacementPreparationQueue() {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("local.unofficial-sakura.replacement-preparation",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
  });
  return queue;
}
dispatch_queue_t syntaxPreparationQueue() {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("local.unofficial-sakura.syntax-preparation",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
  });
  return queue;
}
using SyntaxTokens = std::vector<sakura::core::SyntaxToken>;
using SharedSyntaxTokens = std::shared_ptr<const SyntaxTokens>;
using SharedSyntaxIndex = std::shared_ptr<const sakura::core::IndexedSyntax>;
SharedSyntaxTokens emptySyntaxTokens() {
  static const auto empty = std::make_shared<const SyntaxTokens>();
  return empty;
}
struct SyntaxWork {
  std::shared_ptr<const sakura::core::TextBuffer> source;
  sakura::core::TextBuffer display;
  SharedSyntaxIndex previous, base, retiredIndex;
  SharedSyntaxTokens additional, retiredDiagnostic, retiredAdditional;
};
struct RetiredSyntax {
  SharedSyntaxTokens diagnostic, additional;
  SharedSyntaxIndex index;
  std::shared_ptr<const sakura::core::TextBuffer> source;
};
struct SearchNavigationRequest {
  BOOL previous;
  NSUInteger explicitStart; // NSNotFound means start from the latest selection.
};
struct ReplacementViewLayout {
  __weak SakuraEditorView* view;
  NSArray* key;
  std::string fontName;
  float pointSize, characterSpacing;
  SakuraEditorWrapMode wrapMode;
  NSInteger wrapColumn, tabWidth;
  CGFloat viewportWidth;
  std::uint64_t metricsRevision;
  sakura::core::IndexedLayout layout, retired;
};

NSArray* layoutConfigurationKey(SakuraEditorSettings* settings, NSFont* font, NSSize viewport) {
  return @[font.fontName, @(font.pointSize), @(settings.characterSpacing),
      @(settings.tabWidth), @(settings.wrapMode), @(settings.wrapColumn),
      @(settings.wrapMode == SakuraEditorWrapModeWindow ? viewport.width : 0.0)];
}

NSRange clampedRange(NSRange range, NSUInteger length) {
  if (range.location == NSNotFound) {
    return NSMakeRange(length, 0);
  }
  const NSUInteger location = std::min(range.location, length);
  const NSUInteger available = length - location;
  return NSMakeRange(location, std::min(range.length, available));
}

NSString* plainString(id value) {
  if ([value isKindOfClass:[NSAttributedString class]]) {
    return [(NSAttributedString*)value string];
  }
  if ([value isKindOfClass:[NSString class]]) {
    return (NSString*)value;
  }
  NSString* description = [value description];
  return description != nil ? description : @"";
}

NSUInteger lineIndexContainingCharacter(const SakuraLayoutRows& ranges,
                                        NSUInteger index,
                                        NSUInteger* steps) {
  if (ranges.empty()) return 0;
  std::size_t visited = 0;
  const auto row = ranges.index.visualLineForOffset(index, &visited);
  if (steps) *steps += visited;
  return row;
}

CGFloat offsetForIndex(CTLineRef line, NSUInteger index) {
  const CFIndex count = CTLineGetGlyphCount(line);
  if (count == 0) {
    return 0.0;
  }
  CGFloat secondary = 0.0;
  return CTLineGetOffsetForStringIndex(line, static_cast<CFIndex>(index),
                                       &secondary);
}

NSString* syntaxRole(const sakura::core::SyntaxToken& token) {
  switch (token.kind) {
    case sakura::core::SyntaxTokenKind::comment: return @"comment";
    case sakura::core::SyntaxTokenKind::string: return @"string";
    case sakura::core::SyntaxTokenKind::keyword: return SakuraKeywordRole(token.keywordGroup);
    case sakura::core::SyntaxTokenKind::number: return @"number";
    case sakura::core::SyntaxTokenKind::preprocessor: return @"preprocessor";
  }
  return @"text";
}

}  // namespace

@interface SakuraEditorView ()
@property(nonatomic, weak) SakuraDocument* sakuraDocument;
@property(nonatomic) NSRange committedSelection;
@property(nonatomic, strong, nullable) NSAttributedString* markedTextStorage;
@property(nonatomic) NSRange markedReplacementRangeStorage;
@property(nonatomic) NSRange markedSelectionStorage;
@property(nonatomic) BOOL draggingSelection;
@property(nonatomic) NSUInteger dragAnchor;
@property(nonatomic) BOOL draggingWholeWords;
@property(nonatomic) NSRange dragInitialSelection;
@property(nonatomic) NSUInteger navigationAnchor;
@property(nonatomic) NSUInteger navigationCaret;
@property(nonatomic) CGFloat navigationPreferredX;
@property(nonatomic) BOOL rectangularSelectionActive;
@property(nonatomic) NSPoint rectangularAnchorPoint;
@property(nonatomic) NSPoint rectangularCurrentPoint;
@property(nonatomic, strong, nullable) NSPanel* findPanel;
@property(nonatomic, strong, nullable) NSSearchField* findField;
@property(nonatomic, strong, nullable) NSTextField* replaceField;
@property(nonatomic, strong, nullable) NSButton* caseSensitiveButton;
@property(nonatomic, strong, nullable) NSButton* wholeWordButton;
@property(nonatomic, strong, nullable) NSButton* regularExpressionButton;
@property(nonatomic, strong) NSButton* searchWrapButton;
@property(nonatomic, strong) NSButton* searchScopeButton;
@property(nonatomic, strong) NSTextField* searchScopeLabel;
@property(nonatomic, strong) NSPopUpButton* replacementHistoryPopup;
@property(nonatomic) NSRange searchScopeRange;
@property(nonatomic) uint64_t searchScopeRevision;
@property(nonatomic) BOOL searchScopeCaptured;
@property(nonatomic, strong) NSProgress* searchCountProgress;
@property(nonatomic, strong) NSProgress* replacementProgress;
@property(nonatomic, strong) NSProgress* historyProgress;
@property(nonatomic) BOOL applyingHistoryTransition;
@property(nonatomic) BOOL historyWindowClosed;
@property(nonatomic) uint64_t searchCountRevision;
@property(nonatomic, strong) NSProgress* searchHighlightProgress;
@property(nonatomic, copy) NSString* searchHighlightStatusText;
@property(nonatomic, copy) NSString* searchOperationStatusText;
@property(nonatomic, strong) NSProgress* searchNavigationProgress;
@property(nonatomic, copy) NSArray* searchNavigationContextKey;
@property(nonatomic) uint64_t selectionGeneration;
@property(nonatomic) BOOL applyingSearchNavigation;
@property(nonatomic, strong, nullable) NSTextField* findStatusLabel;
@property(nonatomic) BOOL searchMarksHidden;
@property(nonatomic) BOOL hasLastSearchMatch;
@property(nonatomic) NSRange lastSearchMatchRange;
@property(nonatomic) std::uint64_t lastSearchRevision;
@property(nonatomic, copy, nullable) NSString* lastSearchPattern;
@property(nonatomic) NSUInteger lastSearchFlags;
@property(nonatomic) uint64_t lastSearchSelectionGeneration;
@property(nonatomic, strong) NSProgress* syntaxProgress;
@property(nonatomic, copy) NSString* syntaxStatusText;
@property(nonatomic, copy) NSString* customSyntaxStatusText;
- (NSArray*)currentSyntaxKey;
- (void)invalidateOutdatedSyntax;
- (void)prepareSyntax;
- (SyntaxTokens)syntaxTokensInRange:(NSRange)range;
- (void)cancelSearchNavigation;
- (void)cancelPreparedReplacement;
- (void)prepareSearchReplacementAll:(BOOL)all;
- (NSArray*)layoutConfigurationKey;
- (NSArray<SakuraEditorView*>*)replacementAffectedViews;
- (ReplacementViewLayout)captureReplacementLayout;
- (void)adoptReplacementLayout:(ReplacementViewLayout&)work;
- (void)adoptPreparedLayout:(ReplacementViewLayout&)work;
- (void)enqueueHistoryDirection:(sakura::core::EditEngine::HistoryDirection)direction;
- (void)startNextHistoryNavigation;
- (void)updateCommittedSelection:(NSRange)selection preservingHistory:(BOOL)preservingHistory;
- (std::function<void()>)historyWorkGate;
- (NSTimeInterval)historyPreparationTimeLimit;
- (void)startNextSearchNavigation;
- (NSArray*)navigationSearchKey;
@end

@implementation SakuraEditorView {
  NSString* _cachedCommittedString;
  sakura::core::TextBuffer _cachedCommittedBuffer;
  std::uint64_t _cachedTextRevision;
  NSString* _cachedDisplayString;
  NSObject* _cachedCompositionIdentity;
  NSString* _cachedMarkedString;
  NSRange _cachedMarkedReplacement;
  NSString* _layoutDisplayString;
  NSArray* _layoutKey;
  SakuraLayoutRows _cachedLineRanges;
  std::uint64_t _layoutMetricsRevision;
  NSUInteger _layoutMeasuredLines, _layoutFullBuilds, _layoutComparedTextNodes;
  std::unique_ptr<sakura::core::TextBuffer> _markedLayoutBuffer;
  NSString* _markedLayoutString;
  CGFloat _cachedWidestLine;
  NSArray* _syntaxKey;
  SharedSyntaxTokens _cachedSyntaxTokens;
  SharedSyntaxTokens _additionalSyntaxTokens;
  SharedSyntaxIndex _cachedSyntaxIndex, _previousSyntaxIndex;
  BOOL _flattenedSyntaxReady;
  NSUInteger _syntaxFlattenBuilds;
  sakura::core::SyntaxUpdateStatistics _syntaxUpdate;
  std::shared_ptr<const sakura::core::TextBuffer> _syntaxSource;
  NSUInteger _syntaxCompletions, _syntaxDiscards;
  BOOL _syntaxWorkerRanOnMainThread;
  NSArray* _searchKey;
  std::vector<NSRange> _cachedSearchRanges;
  NSArray* _styleKey;
  NSCache<NSNumber*, NSAttributedString*>* _styledLines;
  NSUInteger _textBuilds, _layoutBuilds, _syntaxBuilds, _searchBuilds;
  NSUInteger _styledBuilds, _drawnLines, _lineLookupSteps;
  NSUInteger _searchCompletions, _searchDiscards;
  BOOL _searchWorkerRanOnMainThread;
  NSUInteger _imeSharedBuilds, _imeFullBuilds;
  std::deque<SearchNavigationRequest> _searchNavigationRequests;
  NSUInteger _navigationCompletions, _navigationDiscards;
  BOOL _navigationWorkerRanOnMainThread;
  NSUInteger _replacementCompletions, _replacementDiscards;
  BOOL _replacementWorkerRanOnMainThread;
  NSUInteger _replacementLayoutsAdopted;
  double _replacementMainMilliseconds, _replacementAdoptMilliseconds, _replacementRefreshMilliseconds;
  std::deque<sakura::core::EditEngine::HistoryDirection> _historyRequests;
  NSUInteger _historyCompletions, _historyDiscards, _historyLayoutsAdopted;
  uint64_t _historyCancellationGeneration;
  BOOL _historyWorkerRanOnMainThread;
  double _historyMainMilliseconds, _historyAdoptMilliseconds, _historyRefreshMilliseconds;
}

@synthesize committedSelection = _committedSelection;

- (void)dealloc {
  [self cancelBracketSearch];
  self.findPanel.delegate = nil;
  [self.syntaxProgress cancel];
  [self.searchCountProgress cancel];
  [self.replacementProgress cancel];
  [self.searchHighlightProgress cancel];
  [self.searchNavigationProgress cancel];
  [self.historyProgress cancel];
  [NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowWillCloseNotification object:nil];
  [NSNotificationCenter.defaultCenter removeObserver:self name:SakuraSearchStateDidChangeNotification object:nil];
}
- (NSString*)customSyntaxStatus { return self.customSyntaxStatusText != nil ? self.customSyntaxStatusText : @""; }
- (NSString*)syntaxStatus { return self.syntaxStatusText != nil ? self.syntaxStatusText : @""; }
- (BOOL)hasPendingSyntax { return self.syntaxProgress != nil; }
- (void)cancelSyntaxHighlighting:(id)sender {
  (void)sender;
  if (self.syntaxProgress == nil) return;
  [self.syntaxProgress cancel]; self.syntaxProgress = nil;
  [self setCustomSyntaxStatusMessage:@""];
  [self setSyntaxStatusMessage:@"色分けを中止しました（編集で再解析）。"];
}
- (NSString*)searchHighlightStatus { return self.searchHighlightStatusText != nil ? self.searchHighlightStatusText : @""; }
- (NSString*)searchOperationStatus { return self.searchOperationStatusText != nil ? self.searchOperationStatusText : @""; }
- (void)cancelSearchHighlights {
  [self.searchHighlightProgress cancel]; self.searchHighlightProgress = nil;
  _searchKey = nil; _cachedSearchRanges.clear(); [_styledLines removeAllObjects];
  self.searchHighlightStatusText = @"";
}
- (void)setSearchHighlightStatusMessage:(NSString*)message {
  self.searchHighlightStatusText = message;
  if ([self.window.windowController isKindOfClass:SakuraWindowController.class]) {
    SakuraWindowController* controller = (SakuraWindowController*)self.window.windowController;
    NSResponder* responder = self.window.firstResponder;
    if ([responder isKindOfClass:SakuraEditorView.class] ? responder == self : controller.editorView == self)
      [controller updateStatusForEditor:self];
  }
}
- (NSDictionary*)syntaxPreferences {
  return SakuraSyntaxPreferences(SakuraTypeIdentifierForExtension(self.sakuraDocument.fileURL.pathExtension),
                                 NSUserDefaults.standardUserDefaults);
}
- (void)setCustomSyntaxStatusMessage:(NSString*)message {
  self.customSyntaxStatusText = message;
  if ([self.window.windowController isKindOfClass:SakuraWindowController.class]) {
    SakuraWindowController* controller = (SakuraWindowController*)self.window.windowController;
    NSResponder* responder = self.window.firstResponder;
    if ([responder isKindOfClass:SakuraEditorView.class] ? responder == self : controller.editorView == self)
      [controller updateStatusForEditor:self];
  }
}
- (void)setSyntaxStatusMessage:(NSString*)message {
  self.syntaxStatusText = message;
  // Both statuses use the same status-bar refresh route.
  [self setCustomSyntaxStatusMessage:self.customSyntaxStatus];
}

- (void)setCommittedSelection:(NSRange)selection {
  [self updateCommittedSelection:selection preservingHistory:NO];
}

- (void)updateCommittedSelection:(NSRange)selection preservingHistory:(BOOL)preservingHistory {
  [self cancelBracketSearch];
  if (!preservingHistory && [self hasPendingHistoryNavigation]) {
    [self cancelHistoryNavigation:nil];
    [self setFindStatus:@"選択位置が変わったためUndo／Redoを中止しました。"];
  }
  if (!self.applyingSearchNavigation && ([self hasPendingSearchNavigation] || [self hasPendingReplacement])) {
    [self cancelSearchNavigation];
    [self setFindStatus:@"選択位置が変更されたため検索を中止しました。"];
  }
  ++_selectionGeneration;
  _committedSelection = selection;
  // Assignments from editing, search, IME or document refresh end the current
  // keyboard selection. Navigation restores these values after its assignment.
  _navigationAnchor = NSNotFound;
  _navigationCaret = NSMaxRange(selection);
  _navigationPreferredX = NAN;
}

- (instancetype)initWithFrame:(NSRect)frame document:(SakuraDocument*)document {
  self = [super initWithFrame:frame];
  if (self != nil) {
    _cachedSyntaxTokens = emptySyntaxTokens();
    _additionalSyntaxTokens = emptySyntaxTokens();
    _sakuraDocument = document;
    _committedSelection = NSMakeRange(0, 0);
    _navigationAnchor = NSNotFound;
    _navigationCaret = 0;
    _navigationPreferredX = NAN;
    _markedReplacementRangeStorage = NSMakeRange(NSNotFound, 0);
    _markedSelectionStorage = NSMakeRange(0, 0);
    self.postsFrameChangedNotifications = YES;
    [self setAccessibilityElement:YES];
    [self setAccessibilityRole:NSAccessibilityTextAreaRole];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(editorWindowWillClose:)
        name:NSWindowWillCloseNotification object:nil];
    [self documentContentsDidChange];
  }
  return self;
}

- (BOOL)isFlipped {
  return YES;
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (self.window) self.historyWindowClosed = NO;
}

- (void)editorWindowWillClose:(NSNotification*)notification {
  if (!self.window || notification.object != self.window) return;
  self.historyWindowClosed = YES;
  [self cancelSearchOperations:nil];
  [self cancelSyntaxHighlighting:nil];
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (BOOL)canBecomeKeyView {
  return YES;
}

- (BOOL)becomeFirstResponder {
  [self setNeedsDisplay:YES];
  return YES;
}

- (BOOL)resignFirstResponder {
  [self setNeedsDisplay:YES];
  return YES;
}

- (NSFont*)editorFont {
  return [[self editorSettings] editorFont];
}

- (SakuraEditorSettings*)editorSettings {
  return [SakuraEditorSettings settingsForTypeIdentifier:
      SakuraTypeIdentifierForExtension(self.sakuraDocument.fileURL.pathExtension)];
}

- (CGFloat)editorLineHeight {
  NSFont* font = [self editorFont];
  return std::ceil(font.ascender - font.descender + font.leading) +
      [self editorSettings].lineSpacing;
}

- (NSDictionary<NSAttributedStringKey, id>*)baseTextAttributes {
  NSString* typeIdentifier = SakuraTypeIdentifierForExtension(
      self.sakuraDocument.fileURL.pathExtension);
  NSFont* font = [self editorFont];
  if (SakuraTypeStyleBool(typeIdentifier, @"text", @"bold", NO)) {
    font = [[NSFontManager sharedFontManager] convertFont:font
                                             toHaveTrait:NSBoldFontMask];
  }
  NSMutableDictionary<NSAttributedStringKey, id>* attributes =
      [@{
        NSFontAttributeName : font,
        NSLigatureAttributeName : @0,
        NSForegroundColorAttributeName : SakuraTypeColor(
            typeIdentifier, @"text", self.effectiveAppearance,
            SakuraEditorText(self.effectiveAppearance)),
      } mutableCopy];
  SakuraEditorSettings* settings = [self editorSettings];
  attributes[NSKernAttributeName] = @(settings.characterSpacing);
  NSMutableParagraphStyle* paragraph = [[NSMutableParagraphStyle alloc] init];
  paragraph.tabStops = @[];
  paragraph.defaultTabInterval = std::max<CGFloat>(1.0,
      [@" " sizeWithAttributes:@{NSFontAttributeName:font}].width +
      settings.characterSpacing) * settings.tabWidth;
  attributes[NSParagraphStyleAttributeName] = paragraph;
  if (SakuraTypeStyleBool(typeIdentifier, @"text", @"underline", NO)) {
    attributes[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
  }
  return attributes;
}

- (NSString*)committedString {
  SakuraDocument* document = self.sakuraDocument;
  if (document == nil) return @"";
  const auto revision = document.documentSession.buffer().revision();
  if (_cachedCommittedString == nil || _cachedTextRevision != revision ||
      !_cachedCommittedBuffer.sharesStorageWith(document.documentSession.buffer())) {
    _cachedCommittedString = sakura::platform::mac::stringFromTextBuffer(
        document.documentSession.buffer());
    _cachedTextRevision = revision;
    _cachedCommittedBuffer = document.documentSession.buffer();
    _cachedDisplayString = nil;
    ++_textBuilds;
  }
  return _cachedCommittedString;
}

- (NSString*)displayString {
  NSString* committed = [self committedString];
  if (![self hasMarkedText]) {
    return committed;
  }

  const NSRange replacement =
      clampedRange(self.markedReplacementRangeStorage, committed.length);
  NSString* marked = self.markedTextStorage.string;
  if (_cachedDisplayString == nil ||
      !NSEqualRanges(replacement, _cachedMarkedReplacement) ||
      ![_cachedMarkedString isEqualToString:marked]) {
    if (self.sakuraDocument != nil) {
      _cachedDisplayString = sakura::platform::mac::previewStringFromTextBuffer(
          self.sakuraDocument.documentSession.buffer(), {replacement.location, replacement.length},
          sakura::platform::mac::sakuraStringFromString(marked));
    } else {
      _cachedDisplayString = [committed stringByReplacingCharactersInRange:replacement withString:marked];
    }
    _cachedCompositionIdentity = [[NSObject alloc] init];
    _cachedMarkedString = [marked copy];
    _cachedMarkedReplacement = replacement;
  }
  return _cachedDisplayString;
}

- (id)compositionIdentity {
  if (![self hasMarkedText]) return NSNull.null;
  (void)[self displayString];
  return _cachedCompositionIdentity;
}

- (NSRange)displaySelection {
  if (![self hasMarkedText]) {
    return self.committedSelection;
  }
  const NSUInteger markedLength = self.markedTextStorage.length;
  const NSRange relative =
      clampedRange(self.markedSelectionStorage, markedLength);
  return NSMakeRange(self.markedReplacementRangeStorage.location +
                         relative.location,
                     relative.length);
}

- (void)clearMarkedState {
  self.markedTextStorage = nil;
  self.markedReplacementRangeStorage = NSMakeRange(NSNotFound, 0);
  self.markedSelectionStorage = NSMakeRange(0, 0);
  _markedLayoutBuffer.reset();
  _markedLayoutString = nil;
  [self invalidateOutdatedSyntax];
}

- (NSRange)committedRangeForDisplayRange:(NSRange)displayRange {
  NSString* committed = [self committedString];
  if (displayRange.location == NSNotFound) {
    return self.committedSelection;
  }
  if (![self hasMarkedText]) {
    return clampedRange(displayRange, committed.length);
  }

  const NSRange replacement =
      clampedRange(self.markedReplacementRangeStorage, committed.length);
  const NSRange marked = NSMakeRange(replacement.location,
                                     self.markedTextStorage.length);
  const NSRange clampedDisplay = clampedRange(displayRange, [self displayString].length);
  const NSUInteger displayStart = clampedDisplay.location;
  const NSUInteger displayEnd = NSMaxRange(clampedDisplay);
  const NSUInteger markedEnd = NSMaxRange(marked);

  if ((clampedDisplay.length != 0 &&
       NSIntersectionRange(clampedDisplay, marked).length != 0) ||
      (clampedDisplay.length == 0 && displayStart > marked.location &&
       displayStart < markedEnd)) {
    return replacement;
  }

  const auto mapIndex = [&](NSUInteger index) {
    if (index <= marked.location) {
      return index;
    }
    if (index >= markedEnd) {
      return index - marked.length + replacement.length;
    }
    return replacement.location;
  };

  const NSUInteger start = mapIndex(displayStart);
  const NSUInteger end = mapIndex(displayEnd);
  return clampedRange(NSMakeRange(start, end >= start ? end - start : 0),
                      committed.length);
}

- (BOOL)replaceCommittedRange:(NSRange)range withString:(NSString*)text {
  [self clearRectangularSelection];
  NSString* committed = [self committedString];
  range = clampedRange(range, committed.length);
  if (range.length == 0 && text.length == 0) {
    self.committedSelection = NSMakeRange(range.location, 0);
    [self setNeedsDisplay:YES];
    return YES;
  }

  try {
    const auto replacement =
        sakura::platform::mac::sakuraStringFromString(text);
    self.sakuraDocument.documentSession.replace(
        {static_cast<sakura::core::TextOffset>(range.location),
         static_cast<sakura::core::TextOffset>(range.length)},
        replacement);
    self.committedSelection = NSMakeRange(range.location + text.length, 0);
    [self.sakuraDocument noteEditorChange:NSChangeDone];
    [self.sakuraDocument refreshEditorViews];
    [self scrollSelectionToVisible];
    return YES;
  } catch (const std::exception&) {
    NSBeep();
    return NO;
  }
}

- (void)replaceRectangularSelectionWithStrings:(NSArray<NSString*>*)strings {
  NSArray<NSDictionary*>* selections = [self rectangularSelections];
  if (selections.count == 0 || strings.count == 0) return;
  try {
    std::vector<sakura::core::EditReplacement> replacements;
    replacements.reserve(selections.count);
    for (NSInteger index = static_cast<NSInteger>(selections.count) - 1;
         index >= 0; --index) {
      NSDictionary* selection = selections[static_cast<NSUInteger>(index)];
      const NSRange range = [selection[@"committedRange"] rangeValue];
      NSString* text = strings.count == selections.count
          ? strings[static_cast<NSUInteger>(index)] : strings.firstObject;
      const NSUInteger leadingSpaces =
          [selection[@"leadingVirtualSpaces"] unsignedIntegerValue];
      if (text.length != 0 && leadingSpaces != 0) {
        NSString* padding = [@"" stringByPaddingToLength:leadingSpaces
                                              withString:@" "
                                         startingAtIndex:0];
        text = [padding stringByAppendingString:text];
      }
      replacements.push_back({
          {static_cast<sakura::core::TextOffset>(range.location),
           static_cast<sakura::core::TextOffset>(range.length)},
          sakura::platform::mac::sakuraStringFromString(text),
      });
    }
    NSDictionary* firstSelection = selections.firstObject;
    const NSRange firstRange = [firstSelection[@"committedRange"] rangeValue];
    NSString* firstText = strings.firstObject;
    const NSUInteger firstLeadingSpaces =
        [firstSelection[@"leadingVirtualSpaces"] unsignedIntegerValue];
    if (firstText.length != 0 && firstLeadingSpaces != 0) {
      firstText = [[@"" stringByPaddingToLength:firstLeadingSpaces
                                      withString:@" "
                                 startingAtIndex:0]
          stringByAppendingString:firstText];
    }
    [self clearRectangularSelection];
    self.sakuraDocument.documentSession.replaceMany(replacements);
    self.committedSelection = NSMakeRange(
        firstRange.location + firstText.length, 0);
    [self.sakuraDocument noteEditorChange:NSChangeDone];
    [self.sakuraDocument refreshEditorViews];
    [self scrollSelectionToVisible];
  } catch (const std::exception&) {
    NSBeep();
  }
}

- (NSUInteger)previousEditBoundaryAtOrBefore:(NSUInteger)index {
  const auto& buffer = self.sakuraDocument.documentSession.buffer();
  index = std::min<NSUInteger>(index, static_cast<NSUInteger>(buffer.length()));
  while (index != 0 && !buffer.isEditBoundary(index)) {
    --index;
  }
  return index;
}

- (NSUInteger)nextEditBoundaryAtOrAfter:(NSUInteger)index {
  const auto& buffer = self.sakuraDocument.documentSession.buffer();
  const NSUInteger length = static_cast<NSUInteger>(buffer.length());
  index = std::min(index, length);
  while (index < length && !buffer.isEditBoundary(index)) {
    ++index;
  }
  return index;
}

- (NSRange)rangeByExpandingToEditBoundaries:(NSRange)range {
  const NSUInteger start = [self previousEditBoundaryAtOrBefore:range.location];
  const NSUInteger end =
      [self nextEditBoundaryAtOrAfter:NSMaxRange(range)];
  return NSMakeRange(start, end - start);
}

- (void)documentContentsDidChange {
  [self cancelBracketSearch];
  if (!self.applyingHistoryTransition && [self hasPendingHistoryNavigation]) {
    [self cancelHistoryNavigation:nil];
    [self setFindStatus:@"本文が変わったためUndo／Redoを中止しました。"];
  }
  if ([self hasPendingSearchNavigation] || [self hasPendingReplacement]) {
    [self cancelSearchNavigation];
    [self setFindStatus:@"本文が変更されたため検索を中止しました。"];
  }
  [self cancelSearchHighlights];
  if (self.searchCountProgress != nil && self.searchCountRevision != self.sakuraDocument.documentSession.buffer().revision()) {
    [self.searchCountProgress cancel]; self.searchCountProgress = nil;
    [self setFindStatus:@"本文が変更されたため件数確認を中止しました。"];
  }
  [self clearRectangularSelection];
  const NSUInteger length = [self committedString].length;
  // Only this automatic clamp preserves the queued history transition. A
  // selection change reentered from a notification still uses the public
  // setter and cancels the queue, even while the history refresh is running.
  NSRange selection = clampedRange(self.committedSelection, length);
  if (selection.length) selection = [self rangeByExpandingToEditBoundaries:selection];
  else selection.location = [self previousEditBoundaryAtOrBefore:selection.location];
  [self updateCommittedSelection:selection preservingHistory:self.applyingHistoryTransition];
  [self updateDocumentViewSize];
  [self setNeedsDisplay:YES];
  [self refreshSearchScopeLabel];
}

- (void)displaySettingsDidChange {
  // Appearance changes do not edit text or end keyboard/rectangular selection.
  [self updateDocumentViewSize];
  [self setNeedsDisplay:YES];
}

- (void)viewDidMoveToSuperview {
  [super viewDidMoveToSuperview];
  if (self.superview != nil && self.sakuraDocument != nil) {
    [self updateDocumentViewSize];
  }
}

- (void)viewDidEndLiveResize {
  [super viewDidEndLiveResize];
  [self updateDocumentViewSize];
}

- (void)viewDidChangeEffectiveAppearance {
  [super viewDidChangeEffectiveAppearance];
  [self setNeedsDisplay:YES];
}

- (const SakuraLayoutRows&)displayLineRanges {
  NSString* display = [self displayString];
  SakuraEditorSettings* settings = [self editorSettings];
  NSFont* font = [self baseTextAttributes][NSFontAttributeName];
  const NSSize viewport = self.enclosingScrollView != nil
                              ? self.enclosingScrollView.contentSize
                              : self.bounds.size;
  NSArray* key = layoutConfigurationKey(settings, font, viewport);
  if (_layoutDisplayString == display && [_layoutKey isEqual:key]) {
    return _cachedLineRanges;
  }
  // Use the same layout for the input method's preview, without committing it
  // to the document, undo history, or another pane. Font/viewport changes can
  // reuse this temporary buffer while selectedRange-only updates reuse layout.
  SakuraDocument* document = self.sakuraDocument;
  const sakura::core::TextBuffer* layoutBuffer = nullptr;
  if ([self hasMarkedText] || self.sakuraDocument == nil) {
    if (_markedLayoutBuffer == nullptr || _markedLayoutString != display) {
      NSRange replacement = clampedRange(self.markedReplacementRangeStorage,
          document != nil ? document.documentSession.buffer().length() : 0);
      if (document != nil && document.documentSession.buffer().isEditBoundary(replacement.location) &&
          document.documentSession.buffer().isEditBoundary(NSMaxRange(replacement))) {
        auto preview = std::make_unique<sakura::core::TextBuffer>(document.documentSession.buffer());
        preview->replace({replacement.location, replacement.length},
            sakura::platform::mac::sakuraStringFromString(self.markedTextStorage.string));
        _markedLayoutBuffer = std::move(preview); ++_imeSharedBuilds;
      } else {
        // Preserve NSTextInputClient previews that temporarily address a
        // partial UTF-16/CRLF boundary. Such ranges cannot be core edits.
        _markedLayoutBuffer = std::make_unique<sakura::core::TextBuffer>(
            sakura::platform::mac::sakuraStringFromString(display));
        ++_imeFullBuilds;
      }
      _markedLayoutString = display;
    }
    layoutBuffer = _markedLayoutBuffer.get();
  } else {
    layoutBuffer = &document.documentSession.buffer();
    _markedLayoutBuffer.reset();
    _markedLayoutString = nil;
  }
  const char* fontName = font.fontName.UTF8String;
  sakura::platform::mac::CoreTextMetrics metrics(
      fontName != nullptr ? fontName : "Menlo-Regular", font.pointSize,
      settings.characterSpacing);
  const sakura::core::FontStyle style{0, static_cast<float>(font.pointSize),
                                      400, false};
  float wrapWidth = 0.0F;
  if (settings.wrapMode == SakuraEditorWrapModeWindow) {
    wrapWidth = std::max(1.0F, static_cast<float>(
        viewport.width - kGutterWidth - 2.0 * kHorizontalInset));
  } else if (settings.wrapMode == SakuraEditorWrapModeColumn) {
    wrapWidth = metrics.advance(u' ', style) * settings.wrapColumn;
  }
  const auto metricsRevision = _layoutMetricsRevision + (![_layoutKey isEqual:key] ? 1 : 0);
  _cachedLineRanges.index.update(
      *layoutBuffer, metrics, style,
      {.wrapWidth = wrapWidth,
       .tabWidth = static_cast<sakura::core::TextOffset>(
           settings.tabWidth)}, metricsRevision);
  const auto statistics = _cachedLineRanges.index.lastUpdate();
  _layoutMeasuredLines = statistics.measuredLines;
  _layoutComparedTextNodes = statistics.comparedTextNodes;
  if (statistics.fullRebuild) ++_layoutFullBuilds;
  _layoutMetricsRevision = metricsRevision;
  _cachedWidestLine = _cachedLineRanges.index.widestLine();
  _layoutDisplayString = display;
  _layoutKey = key;
  ++_layoutBuilds;
  [_styledLines removeAllObjects];
  return _cachedLineRanges;
}

- (NSArray*)layoutConfigurationKey {
  NSSize viewport = self.enclosingScrollView ? self.enclosingScrollView.contentSize : self.bounds.size;
  return layoutConfigurationKey([self editorSettings], [self baseTextAttributes][NSFontAttributeName], viewport);
}
- (NSArray<SakuraEditorView*>*)replacementAffectedViews {
  NSMutableArray<SakuraEditorView*>* views = [NSMutableArray arrayWithObject:self];
  for (NSWindowController* controller in self.sakuraDocument.windowControllers) {
    if (![controller isKindOfClass:SakuraWindowController.class]) continue;
    for (SakuraEditorView* view in ((SakuraWindowController*)controller).editorViews)
      if (![views containsObject:view]) [views addObject:view];
  }
  return views;
}
- (ReplacementViewLayout)captureReplacementLayout {
  SakuraEditorSettings* settings = [self editorSettings];
  NSFont* font = [self baseTextAttributes][NSFontAttributeName];
  const NSSize viewport = self.enclosingScrollView ? self.enclosingScrollView.contentSize : self.bounds.size;
  NSArray* key = layoutConfigurationKey(settings, font, viewport);
  const char* name = font.fontName.UTF8String;
  return {self, key, name ? name : "Menlo-Regular", static_cast<float>(font.pointSize),
      static_cast<float>(settings.characterSpacing), settings.wrapMode, settings.wrapColumn, settings.tabWidth,
      viewport.width, _layoutMetricsRevision + (![_layoutKey isEqual:key] ? 1 : 0), _cachedLineRanges.index, {}};
}
- (void)adoptReplacementLayout:(ReplacementViewLayout&)work {
  [self adoptPreparedLayout:work];
  ++_replacementLayoutsAdopted;
}
- (void)adoptPreparedLayout:(ReplacementViewLayout&)work {
  // Keep the old layout alive in the worker-owned result. Releasing a million
  // obsolete row descriptors here would otherwise move the pause to commit.
  work.retired = _cachedLineRanges.index;
  _cachedLineRanges.index = work.layout;
  _layoutMetricsRevision = work.metricsRevision;
  _layoutKey = work.key;
  _layoutDisplayString = [self displayString];
  _cachedWidestLine = work.layout.widestLine();
  const auto statistics = work.layout.lastUpdate();
  _layoutMeasuredLines = statistics.measuredLines;
  _layoutComparedTextNodes = statistics.comparedTextNodes;
  if (statistics.fullRebuild) ++_layoutFullBuilds;
  ++_layoutBuilds;
  [_styledLines removeAllObjects];
}

- (void)updateDocumentViewSize {
  if (self.sakuraDocument == nil) return;
  const auto& lines = [self displayLineRanges];

  NSSize viewport = self.enclosingScrollView != nil
                        ? self.enclosingScrollView.contentSize
                        : self.bounds.size;
  const CGFloat rectangularWidth = self.rectangularSelectionActive
      ? std::max(self.rectangularAnchorPoint.x,
                 self.rectangularCurrentPoint.x) + kHorizontalInset
      : 0.0;
  const CGFloat width = std::max({kMinimumContentWidth, viewport.width,
                                  _cachedWidestLine + kGutterWidth + 2.0 * kHorizontalInset,
                                  rectangularWidth});
  const CGFloat height =
      std::max({kMinimumContentHeight, viewport.height,
                kVerticalInset * 2.0 +
                    [self editorLineHeight] * static_cast<CGFloat>(lines.size())});
  if (std::abs(self.frame.size.width - width) > 0.5 ||
      std::abs(self.frame.size.height - height) > 0.5) {
    [self setFrameSize:NSMakeSize(width, height)];
  }
  [self invalidateOutdatedSyntax];
}

- (void)refreshStyledLineCache {
  NSString* type = SakuraTypeIdentifierForExtension(
      self.sakuraDocument.fileURL.pathExtension);
  NSMutableArray* key = [NSMutableArray arrayWithArray:
      @[type, [self baseTextAttributes], @(SakuraThemeIsDark(self.effectiveAppearance))]];
  NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
  NSMutableArray* roles = [NSMutableArray arrayWithArray:@[@"comment", @"string", @"keyword", @"number", @"preprocessor", @"search"]];
  for (NSUInteger group = 2; group <= 10; ++group) [roles addObject:SakuraKeywordRole(group)];
  for (NSString* role in roles) {
    id color = [defaults objectForKey:SakuraTypeColorPreferenceKey(
        type, role, self.effectiveAppearance)];
    [key addObject:color != nil ? color : NSNull.null];
    for (NSString* attribute in @[@"display", @"bold", @"underline"]) {
      id value = [defaults objectForKey:SakuraTypeStylePreferenceKey(
          type, role, attribute)];
      [key addObject:value != nil ? value : NSNull.null];
    }
  }
  if (_styledLines == nil) {
    _styledLines = [[NSCache alloc] init];
    _styledLines.countLimit = 256;
    _styledLines.totalCostLimit = 8 * 1024 * 1024;
  }
  if (![_styleKey isEqual:key]) {
    _styleKey = [key copy];
    [_styledLines removeAllObjects];
  }
}

- (NSAttributedString*)styledLineAtIndex:(NSUInteger)index {
  NSAttributedString* cached = [_styledLines objectForKey:@(index)];
  if (cached != nil) return cached;
  const NSRange range = _cachedLineRanges[index];
  NSMutableAttributedString* text = [[NSMutableAttributedString alloc]
      initWithString:[[self displayString] substringWithRange:range]
          attributes:[self baseTextAttributes]];
  NSString* type = SakuraTypeIdentifierForExtension(
      self.sakuraDocument.fileURL.pathExtension);
  auto attributesForRole = [&](NSString* role, NSColor* fallback) {
    NSMutableDictionary* attributes = [@{NSForegroundColorAttributeName:
        SakuraTypeColor(type, role, self.effectiveAppearance, fallback)} mutableCopy];
    if (SakuraTypeStyleBool(type, role, @"bold", NO)) {
      attributes[NSFontAttributeName] = [[NSFontManager sharedFontManager]
          convertFont:[self editorFont] toHaveTrait:NSBoldFontMask];
    }
    if (SakuraTypeStyleBool(type, role, @"underline", NO)) {
      attributes[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
    }
    return attributes;
  };
  const auto visibleTokens = [self syntaxTokensInRange:range];
  for (auto iterator = visibleTokens.begin(); iterator != visibleTokens.end(); ++iterator) {
    NSString* role = syntaxRole(*iterator);
    if (!SakuraTypeStyleBool(type, role, @"display", YES)) continue;
    NSColor* fallback = SakuraEditorText(self.effectiveAppearance);
    switch (iterator->kind) {
      case sakura::core::SyntaxTokenKind::comment:
        fallback = SakuraCommentText(self.effectiveAppearance); break;
      case sakura::core::SyntaxTokenKind::string:
        fallback = SakuraStringText(self.effectiveAppearance); break;
      case sakura::core::SyntaxTokenKind::keyword:
        fallback = SakuraKeywordGroupText(iterator->keywordGroup, self.effectiveAppearance); break;
      case sakura::core::SyntaxTokenKind::number:
        fallback = SakuraNumberText(self.effectiveAppearance); break;
      case sakura::core::SyntaxTokenKind::preprocessor:
        fallback = SakuraPreprocessorText(self.effectiveAppearance); break;
    }
    NSRange intersection = NSIntersectionRange(range, NSMakeRange(
        iterator->range.location, iterator->range.length));
    intersection.location -= range.location;
    [text addAttributes:attributesForRole(role, fallback) range:intersection];
  }
  if (SakuraTypeStyleBool(type, @"search", @"display", YES)) {
    auto searchStart = std::lower_bound(_cachedSearchRanges.begin(),
        _cachedSearchRanges.end(), range.location, [](NSRange match, NSUInteger start) {
          return NSMaxRange(match) <= start;
        });
    NSDictionary* attributes = attributesForRole(@"search",
        SakuraSearchText(self.effectiveAppearance));
    for (auto iterator = searchStart; iterator != _cachedSearchRanges.end() &&
         iterator->location < NSMaxRange(range); ++iterator) {
      NSRange intersection = NSIntersectionRange(range, *iterator);
      intersection.location -= range.location;
      [text addAttributes:attributes range:intersection];
    }
  }
  ++_styledBuilds;
  [_styledLines setObject:text forKey:@(index) cost:range.length * sizeof(unichar) + 256];
  return text;
}

- (void)drawRect:(NSRect)dirtyRect {
  if (self.sakuraDocument == nil) return;
  NSString* typeIdentifier = SakuraTypeIdentifierForExtension(
      self.sakuraDocument.fileURL.pathExtension);
  NSColor* editorBackground = SakuraTypeColor(
      typeIdentifier, @"background", self.effectiveAppearance,
      SakuraEditorBackground(self.effectiveAppearance));
  [editorBackground setFill];
  NSRectFill(dirtyRect);
  [SakuraTypeColor(typeIdentifier, @"gutterBackground",
                   self.effectiveAppearance,
                   SakuraGutterBackground(self.effectiveAppearance)) setFill];
  NSRectFill(NSMakeRect(0.0, NSMinY(dirtyRect), kGutterWidth,
                        NSHeight(dirtyRect)));
  [SakuraChromeBorder(self.effectiveAppearance) setFill];
  NSRectFill(NSMakeRect(kGutterWidth - 1.0, NSMinY(dirtyRect), 1.0,
                        NSHeight(dirtyRect)));

  NSString* display = [self displayString];
  const auto& ranges = [self displayLineRanges];
  [self prepareSyntax];
  const auto& searchRanges = [self activeSearchRanges];
  [self refreshStyledLineCache];
  const NSRange selected = clampedRange([self displaySelection], display.length);
  NSArray<NSValue*>* selectionRanges = self.rectangularSelectionActive
      ? [self rectangularDisplayRanges]
      : (selected.length != 0
             ? @[ [NSValue valueWithRange:selected] ] : @[]);
  const NSUInteger selectedCharacterCount = [self selectedCharacterCount];
  NSMutableDictionary<NSAttributedStringKey, id>* selectionAttributes = nil;
  if (selectionRanges.count != 0) {
    selectionAttributes =
        [@{NSForegroundColorAttributeName : SakuraTypeColor(
              typeIdentifier, @"selection", self.effectiveAppearance,
              SakuraSelectionText(self.effectiveAppearance))} mutableCopy];
    if (SakuraTypeStyleBool(typeIdentifier, @"selection", @"bold", NO)) {
      selectionAttributes[NSFontAttributeName] = [[NSFontManager sharedFontManager]
          convertFont:[self editorFont] toHaveTrait:NSBoldFontMask];
    }
    if (SakuraTypeStyleBool(typeIdentifier, @"selection", @"underline", NO)) {
      selectionAttributes[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
    }
  }

  NSRange marked = NSMakeRange(NSNotFound, 0);
  if ([self hasMarkedText]) {
    marked = clampedRange([self markedRange], display.length);
  }

  const NSUInteger caretLine = lineIndexContainingCharacter(
      ranges, selected.location, &_lineLookupSteps);
  NSFont* lineNumberFont = [NSFont monospacedDigitSystemFontOfSize:11.0
                                                            weight:NSFontWeightRegular];
  if (SakuraTypeStyleBool(typeIdentifier, @"gutter", @"bold", NO)) {
    lineNumberFont = [[NSFontManager sharedFontManager]
        convertFont:lineNumberFont toHaveTrait:NSBoldFontMask];
  }
  NSMutableDictionary<NSAttributedStringKey, id>* lineNumberAttributes =
      [@{
        NSFontAttributeName : lineNumberFont,
        NSForegroundColorAttributeName : SakuraTypeColor(
            typeIdentifier, @"gutter", self.effectiveAppearance,
            SakuraGutterText(self.effectiveAppearance)),
      } mutableCopy];
  if (SakuraTypeStyleBool(typeIdentifier, @"gutter", @"underline", NO)) {
    lineNumberAttributes[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
  }
  CGContextRef context = NSGraphicsContext.currentContext.CGContext;
  const CGFloat lineHeight = [self editorLineHeight];
  const NSUInteger firstVisible = std::min<NSUInteger>(ranges.size(),
      static_cast<NSUInteger>(std::max<CGFloat>(0.0,
          std::floor((NSMinY(dirtyRect) - kVerticalInset) / lineHeight))));
  const NSUInteger endVisible = std::min<NSUInteger>(ranges.size(),
      static_cast<NSUInteger>(std::max<CGFloat>(0.0,
          std::ceil((NSMaxY(dirtyRect) - kVerticalInset) / lineHeight))));
  std::size_t previousLogicalLine = std::numeric_limits<std::size_t>::max();
  if (firstVisible != 0 && firstVisible <= ranges.size()) {
    previousLogicalLine = _cachedLineRanges.logicalLine(firstVisible - 1);
  }
  const BOOL showLineNumbers = [self editorSettings].showsLineNumbers;
  NSIndexSet* bookmarks = [self.sakuraDocument bookmarkLines];
  for (NSUInteger lineIndex = firstVisible; lineIndex < endVisible; ++lineIndex) {
    const CGFloat top = kVerticalInset + lineIndex * lineHeight;
    const auto logicalLine = _cachedLineRanges.logicalLine(lineIndex);
    if (logicalLine != previousLogicalLine &&
        showLineNumbers &&
        SakuraTypeStyleBool(typeIdentifier, @"gutter", @"display", YES)) {
      NSString* number = [NSString stringWithFormat:@"%zu", logicalLine + 1];
      [number drawInRect:NSMakeRect(4.0, top + 1.0, kGutterWidth - 10.0,
                                    lineHeight)
            withAttributes:lineNumberAttributes];
      if ([bookmarks containsIndex:logicalLine]) {
        [NSColor.systemBlueColor setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(2, top + 5, 5, 5)] fill];
      }
    }
    previousLogicalLine = logicalLine;
  }
  CGContextSaveGState(context);
  CGContextSetTextMatrix(context, CGAffineTransformMakeScale(1.0, -1.0));

  const CGFloat baselineOffset = [self editorFont].ascender + 1.0;
  auto drawMarker = [&](NSString* marker, NSString* role, CGFloat x,
                        CGFloat markerWidth, CGFloat top) {
    NSFont* markerFont = [NSFont monospacedSystemFontOfSize:11.0
                                                     weight:NSFontWeightRegular];
    if (SakuraTypeStyleBool(typeIdentifier, role, @"bold", NO)) {
      markerFont = [[NSFontManager sharedFontManager]
          convertFont:markerFont toHaveTrait:NSBoldFontMask];
    }
    NSColor* foreground = nil;
    if ([role isEqualToString:@"tabMarker"]) {
      foreground = SakuraTabMarkerText(self.effectiveAppearance);
    } else if ([role isEqualToString:@"halfSpaceMarker"] ||
               [role isEqualToString:@"fullSpaceMarker"]) {
      foreground = SakuraSpaceMarkerText(self.effectiveAppearance);
    } else if ([role isEqualToString:@"eolMarker"]) {
      foreground = SakuraEolMarkerText(self.effectiveAppearance);
    } else if ([role isEqualToString:@"wrapMarker"]) {
      foreground = SakuraWrapMarkerText(self.effectiveAppearance);
    } else {
      foreground = SakuraEofMarkerText(self.effectiveAppearance);
    }
    NSString* backgroundRole = [role stringByAppendingString:@"Background"];
    NSColor* backgroundFallback = [role isEqualToString:@"eofMarker"]
        ? SakuraEofMarkerBackground(self.effectiveAppearance)
        : editorBackground;
    NSMutableDictionary<NSAttributedStringKey, id>* markerAttributes =
        [@{
          NSFontAttributeName : markerFont,
          NSForegroundColorAttributeName : SakuraTypeColor(
              typeIdentifier, role, self.effectiveAppearance, foreground),
        } mutableCopy];
    if (SakuraTypeStyleBool(typeIdentifier, role, @"underline", NO)) {
      markerAttributes[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
    }
    NSAttributedString* markerText = [[NSAttributedString alloc]
        initWithString:marker attributes:markerAttributes];
    CTLineRef markerLine = CTLineCreateWithAttributedString(
        (__bridge CFAttributedStringRef)markerText);
    const CGFloat measuredWidth = static_cast<CGFloat>(
        CTLineGetTypographicBounds(markerLine, nullptr, nullptr, nullptr));
    NSString* backgroundKey = SakuraTypeColorPreferenceKey(
        typeIdentifier, backgroundRole, self.effectiveAppearance);
    if ([role isEqualToString:@"eofMarker"] ||
        [[NSUserDefaults standardUserDefaults] objectForKey:backgroundKey] != nil) {
      [SakuraTypeColor(typeIdentifier, backgroundRole, self.effectiveAppearance,
                       backgroundFallback) setFill];
      NSRectFill(NSMakeRect(x, top, std::max(markerWidth, measuredWidth), lineHeight));
    }
    CGContextSetTextPosition(context, x, top + baselineOffset);
    CTLineDraw(markerLine, context);
    CFRelease(markerLine);
  };
  for (NSUInteger lineIndex = firstVisible; lineIndex < endVisible; ++lineIndex) {
    const CGFloat top = kVerticalInset + lineIndex * lineHeight;
    ++_drawnLines;

    const NSRange lineRange = ranges[lineIndex];
    if (selectedCharacterCount == 0 && lineIndex == caretLine &&
        SakuraTypeStyleBool(typeIdentifier, @"caretLine", @"display", YES)) {
      [SakuraTypeColor(typeIdentifier, @"caretLine", self.effectiveAppearance,
                       SakuraCaretLine(self.effectiveAppearance)) setFill];
      NSRectFill(NSMakeRect(kGutterWidth, top + lineHeight - 1.0,
                           std::max<CGFloat>(0.0,
                               self.bounds.size.width - kGutterWidth), 1.0));
    }
    NSAttributedString* lineText = [self styledLineAtIndex:lineIndex];
    NSMutableAttributedString* overlay = nil;
    for (NSValue* value in selectionRanges) {
      NSRange intersection = NSIntersectionRange(value.rangeValue, lineRange);
      if (intersection.length == 0) continue;
      if (overlay == nil) overlay = [lineText mutableCopy];
      intersection.location -= lineRange.location;
      [overlay addAttributes:selectionAttributes range:intersection];
    }
    if (marked.location != NSNotFound) {
      NSRange intersection = NSIntersectionRange(marked, lineRange);
      if (intersection.length != 0) {
        if (overlay == nil) overlay = [lineText mutableCopy];
        intersection.location -= lineRange.location;
        [overlay addAttributes:@{
            NSUnderlineStyleAttributeName:@(NSUnderlineStyleSingle),
            NSUnderlineColorAttributeName:NSColor.keyboardFocusIndicatorColor}
                         range:intersection];
      }
    }
    if (overlay != nil) lineText = overlay;
    CTLineRef line = CTLineCreateWithAttributedString(
        (__bridge CFAttributedStringRef)lineText);

    const auto syntaxTokens = [self syntaxTokensInRange:lineRange];
    auto tokenStart = std::lower_bound(syntaxTokens.begin(), syntaxTokens.end(),
        lineRange.location, [](const auto& token, NSUInteger start) {
          return token.range.location + token.range.length <= start;
        });
    for (auto iterator = tokenStart; iterator != syntaxTokens.end() &&
         iterator->range.location < NSMaxRange(lineRange); ++iterator) {
      const auto& token = *iterator;
      NSString* role = syntaxRole(token);
      if (!SakuraTypeStyleBool(typeIdentifier, role, @"display", YES)) {
        continue;
      }
      NSRange tokenRange = NSMakeRange(
          static_cast<NSUInteger>(token.range.location),
          static_cast<NSUInteger>(token.range.length));
      NSRange tokenOnLine = NSIntersectionRange(tokenRange, lineRange);
      if (tokenOnLine.length == 0) continue;
      const CGFloat left = offsetForIndex(
          line, tokenOnLine.location - lineRange.location);
      const CGFloat right = offsetForIndex(
          line, NSMaxRange(tokenOnLine) - lineRange.location);
      [SakuraTypeColor(typeIdentifier,
                       [role stringByAppendingString:@"Background"],
                       self.effectiveAppearance, editorBackground) setFill];
      NSRectFill(NSMakeRect(kTextOriginX + left, top,
                            std::max<CGFloat>(1.0, right - left), lineHeight));
    }

    if (SakuraTypeStyleBool(typeIdentifier, @"search", @"display", YES)) {
      auto searchStart = std::lower_bound(searchRanges.begin(), searchRanges.end(),
          lineRange.location, [](NSRange range, NSUInteger start) {
            return NSMaxRange(range) <= start;
          });
      for (auto iterator = searchStart; iterator != searchRanges.end() &&
           iterator->location < NSMaxRange(lineRange); ++iterator) {
        const NSRange searchRange = *iterator;
        const NSRange searchOnLine = NSIntersectionRange(searchRange, lineRange);
        if (searchOnLine.length == 0) continue;
        const CGFloat left = offsetForIndex(
            line, searchOnLine.location - lineRange.location);
        const CGFloat right = offsetForIndex(
            line, NSMaxRange(searchOnLine) - lineRange.location);
        [SakuraTypeColor(typeIdentifier, @"searchBackground",
                         self.effectiveAppearance,
                         SakuraSearchBackground(self.effectiveAppearance)) setFill];
        NSRectFill(NSMakeRect(kTextOriginX + left, top,
                              std::max<CGFloat>(1.0, right - left), lineHeight));
      }
    }

    if (self.rectangularSelectionActive) {
      const NSRange rectangularLines = [self rectangularDisplayLineSpan];
      if (rectangularLines.location != NSNotFound &&
          NSLocationInRange(lineIndex, rectangularLines)) {
        const CGFloat left = std::max<CGFloat>(
            kTextOriginX, std::min(self.rectangularAnchorPoint.x,
                                  self.rectangularCurrentPoint.x));
        const CGFloat right = std::max<CGFloat>(
            kTextOriginX, std::max(self.rectangularAnchorPoint.x,
                                  self.rectangularCurrentPoint.x));
        if (right - left > 0.5) {
          [SakuraTypeColor(typeIdentifier, @"selectionBackground",
                           self.effectiveAppearance,
                           SakuraSelectionBackground(self.effectiveAppearance)) setFill];
          NSRectFill(NSMakeRect(left, top, right - left, lineHeight));
        }
      }
    } else {
      for (NSValue* value in selectionRanges) {
        const NSRange selectedOnLine = NSIntersectionRange(
            value.rangeValue, lineRange);
        if (selectedOnLine.length == 0) continue;
        const CGFloat left = offsetForIndex(line,
            selectedOnLine.location - lineRange.location);
        const CGFloat right = offsetForIndex(line,
            NSMaxRange(selectedOnLine) - lineRange.location);
        [SakuraTypeColor(typeIdentifier, @"selectionBackground",
                         self.effectiveAppearance,
                         SakuraSelectionBackground(self.effectiveAppearance)) setFill];
        NSRectFill(NSMakeRect(kTextOriginX + left, top,
                              std::max<CGFloat>(1.0, right - left), lineHeight));
      }
    }

    if (marked.location != NSNotFound) {
      const NSRange markedOnLine = NSIntersectionRange(marked, lineRange);
      if (markedOnLine.length != 0) {
        const CGFloat left = offsetForIndex(line,
            markedOnLine.location - lineRange.location);
        const CGFloat right = offsetForIndex(line,
            NSMaxRange(markedOnLine) - lineRange.location);
        [[[NSColor keyboardFocusIndicatorColor] colorWithAlphaComponent:0.10]
            setFill];
        NSRectFill(NSMakeRect(kTextOriginX + left, top,
                              std::max<CGFloat>(1.0, right - left), lineHeight));
      }
    }

    CGContextSetTextPosition(context, kTextOriginX, top + baselineOffset);
    CTLineDraw(line, context);

    if (![self hasMarkedText]) {
      NSString* visibleText = [display substringWithRange:lineRange];
      for (NSUInteger localIndex = 0; localIndex < visibleText.length;
           ++localIndex) {
        const unichar character = [visibleText characterAtIndex:localIndex];
        NSString* role = nil;
        NSString* marker = nil;
        BOOL defaultDisplay = YES;
        if (character == '\t') {
          role = @"tabMarker";
          marker = @"›";
        } else if (character == ' ') {
          role = @"halfSpaceMarker";
          marker = @"·";
          defaultDisplay = NO;
        } else if (character == 0x3000) {
          role = @"fullSpaceMarker";
          marker = @"□";
        }
        if (role == nil || !SakuraTypeStyleBool(
                typeIdentifier, role, @"display", defaultDisplay)) {
          continue;
        }
        const CGFloat left = offsetForIndex(line, localIndex);
        const CGFloat right = offsetForIndex(line, localIndex + 1);
        drawMarker(marker, role, kTextOriginX + left,
                   std::max<CGFloat>(1.0, right - left), top);
      }

      const NSUInteger lineEnd = NSMaxRange(lineRange);
      NSString* endRole = nil;
      NSString* endMarker = nil;
      if (lineEnd < display.length) {
        const unichar ending = [display characterAtIndex:lineEnd];
        if (ending == '\r') {
          endRole = @"eolMarker";
          endMarker = lineEnd + 1 < display.length &&
                      [display characterAtIndex:lineEnd + 1] == '\n'
              ? @"↵" : @"←";
        } else if (ending == '\n') {
          endRole = @"eolMarker";
          endMarker = @"↓";
        } else {
          endRole = @"wrapMarker";
          endMarker = @"↩";
        }
      } else {
        endRole = @"eofMarker";
        endMarker = @"[EOF]";
      }
      if (SakuraTypeStyleBool(typeIdentifier, endRole, @"display", YES)) {
        const CGFloat endX = offsetForIndex(line, lineRange.length);
        drawMarker(endMarker, endRole, kTextOriginX + endX, 1.0, top);
      }
    }
    CFRelease(line);
  }

  if (self.window.firstResponder == self && selected.length == 0 &&
      ![self hasRectangularSelection]) {
    const NSRect caret = [self localRectForDisplayIndex:selected.location];
    [SakuraTypeColor(typeIdentifier, @"text", self.effectiveAppearance,
                     SakuraEditorText(self.effectiveAppearance)) setFill];
    NSRectFill(NSMakeRect(caret.origin.x, caret.origin.y, 1.0, caret.size.height));
  }
  CGContextRestoreGState(context);
  if (self.window.firstResponder == self &&
      [self.window.windowController isKindOfClass:[SakuraWindowController class]]) {
    [(SakuraWindowController*)self.window.windowController updateStatusForEditor:self];
  }
}

- (NSRect)localRectForDisplayIndex:(NSUInteger)index {
  NSString* display = [self displayString];
  index = std::min(index, display.length);
  const auto& ranges = [self displayLineRanges];
  const NSUInteger lineIndex = lineIndexContainingCharacter(ranges, index, &_lineLookupSteps);
  const NSRange lineRange = ranges[lineIndex];
  const NSUInteger localIndex = index <= NSMaxRange(lineRange)
                                    ? index - lineRange.location
                                    : lineRange.length;
  NSAttributedString* text = [[NSAttributedString alloc]
      initWithString:[display substringWithRange:lineRange]
          attributes:[self baseTextAttributes]];
  CTLineRef line = CTLineCreateWithAttributedString(
      (__bridge CFAttributedStringRef)text);
  const CGFloat x = offsetForIndex(line, localIndex);
  CFRelease(line);
  return NSMakeRect(kTextOriginX + x,
                    kVerticalInset + lineIndex * [self editorLineHeight], 1.0,
                    [self editorLineHeight]);
}

- (NSUInteger)displayIndexForLocalPoint:(NSPoint)point {
  NSString* display = [self displayString];
  const auto& ranges = [self displayLineRanges];
  const CGFloat relativeY = std::max<CGFloat>(0.0, point.y - kVerticalInset);
  const NSUInteger lineIndex = std::min<NSUInteger>(
      static_cast<NSUInteger>(relativeY / [self editorLineHeight]),
      ranges.size() - 1);
  const NSRange lineRange = ranges[lineIndex];
  NSAttributedString* text = [[NSAttributedString alloc]
      initWithString:[display substringWithRange:lineRange]
          attributes:[self baseTextAttributes]];
  CTLineRef line = CTLineCreateWithAttributedString(
      (__bridge CFAttributedStringRef)text);
  const CGPoint linePoint = CGPointMake(point.x - kTextOriginX, 0.0);
  CFIndex stringIndex = CTLineGetStringIndexForPosition(line, linePoint);
  if (stringIndex == kCFNotFound) {
    stringIndex = point.x <= kTextOriginX
                      ? 0
                      : static_cast<CFIndex>(lineRange.length);
  }
  NSUInteger index = lineRange.location + std::min<NSUInteger>(
      static_cast<NSUInteger>(stringIndex), lineRange.length);
  if (index < display.length) {
    const NSRange cluster = [display rangeOfComposedCharacterSequenceAtIndex:index];
    if (cluster.location < index && NSMaxRange(cluster) <= NSMaxRange(lineRange) &&
        cluster.location >= lineRange.location) {
      const CGFloat left = offsetForIndex(line, cluster.location - lineRange.location);
      const CGFloat right = offsetForIndex(line, NSMaxRange(cluster) - lineRange.location);
      index = linePoint.x < (left + right) * 0.5
          ? cluster.location : NSMaxRange(cluster);
    }
  }
  CFRelease(line);
  return std::min(display.length, index);
}

- (CGFloat)rectangularSpaceAdvance {
  NSAttributedString* text = [[NSAttributedString alloc]
      initWithString:@" " attributes:[self baseTextAttributes]];
  CTLineRef line = CTLineCreateWithAttributedString(
      (__bridge CFAttributedStringRef)text);
  const CGFloat width = static_cast<CGFloat>(
      CTLineGetTypographicBounds(line, nullptr, nullptr, nullptr));
  CFRelease(line);
  return std::max<CGFloat>(1.0, width);
}

- (NSRange)rectangularDisplayLineSpan {
  const auto& lines = [self displayLineRanges];
  if (!self.rectangularSelectionActive || lines.empty()) {
    return NSMakeRange(NSNotFound, 0);
  }
  const CGFloat lineHeight = [self editorLineHeight];
  const auto lineForY = [&](CGFloat y) {
    const CGFloat relative = std::max<CGFloat>(0.0, y - kVerticalInset);
    return std::min<NSUInteger>(
        static_cast<NSUInteger>(relative / lineHeight), lines.size() - 1);
  };
  const NSUInteger anchorLine = lineForY(self.rectangularAnchorPoint.y);
  const NSUInteger currentLine = lineForY(self.rectangularCurrentPoint.y);
  const NSUInteger first = std::min(anchorLine, currentLine);
  return NSMakeRange(first, std::max(anchorLine, currentLine) - first + 1);
}

- (NSArray<NSDictionary*>*)rectangularSelections {
  if (!self.rectangularSelectionActive) return @[];
  const auto& lines = [self displayLineRanges];
  if (lines.empty()) return @[];
  const NSRange lineSpan = [self rectangularDisplayLineSpan];
  if (lineSpan.location == NSNotFound) return @[];
  const CGFloat lineHeight = [self editorLineHeight];
  const CGFloat left = std::max<CGFloat>(
      kTextOriginX, std::min(self.rectangularAnchorPoint.x,
                            self.rectangularCurrentPoint.x));
  const CGFloat right = std::max<CGFloat>(
      kTextOriginX, std::max(self.rectangularAnchorPoint.x,
                            self.rectangularCurrentPoint.x));
  const CGFloat relativeLeft = left - kTextOriginX;
  const CGFloat relativeRight = right - kTextOriginX;
  const CGFloat spaceAdvance = [self rectangularSpaceAdvance];
  NSString* display = [self displayString];
  NSMutableArray<NSDictionary*>* selections = [NSMutableArray array];
  for (NSUInteger line = lineSpan.location; line < NSMaxRange(lineSpan); ++line) {
    const CGFloat y = kVerticalInset +
        (static_cast<CGFloat>(line) + 0.5) * lineHeight;
    const NSUInteger first = [self displayIndexForLocalPoint:NSMakePoint(left, y)];
    const NSUInteger last = [self displayIndexForLocalPoint:NSMakePoint(right, y)];
    const NSRange displayRange = NSMakeRange(
        std::min(first, last), std::max(first, last) - std::min(first, last));
    NSRange committedRange = [self committedRangeForDisplayRange:displayRange];
    committedRange = [self rangeByExpandingToEditBoundaries:committedRange];

    const NSRange lineRange = lines[line];
    NSAttributedString* lineText = [[NSAttributedString alloc]
        initWithString:[display substringWithRange:lineRange]
            attributes:[self baseTextAttributes]];
    CTLineRef ctLine = CTLineCreateWithAttributedString(
        (__bridge CFAttributedStringRef)lineText);
    const CGFloat lineEnd = offsetForIndex(ctLine, lineRange.length);
    CFRelease(ctLine);
    const NSUInteger leadingVirtualSpaces = lineEnd < relativeLeft
        ? static_cast<NSUInteger>(
              std::ceil((relativeLeft - lineEnd) / spaceAdvance))
        : 0;
    const CGFloat trailingStart = std::max(relativeLeft, lineEnd);
    const NSUInteger trailingVirtualSpaces = relativeRight > trailingStart
        ? static_cast<NSUInteger>(
              std::ceil((relativeRight - trailingStart) / spaceAdvance))
        : 0;
    [selections addObject:@{
      @"displayRange" : [NSValue valueWithRange:displayRange],
      @"committedRange" : [NSValue valueWithRange:committedRange],
      @"leadingVirtualSpaces" : @(leadingVirtualSpaces),
      @"trailingVirtualSpaces" : @(trailingVirtualSpaces),
      @"lineIndex" : @(line),
    }];
  }
  return selections;
}

- (NSArray<NSValue*>*)rectangularDisplayRanges {
  NSMutableArray<NSValue*>* ranges = [NSMutableArray array];
  for (NSDictionary* selection in [self rectangularSelections]) {
    [ranges addObject:selection[@"displayRange"]];
  }
  return ranges;
}

- (NSArray<NSValue*>*)rectangularCommittedRanges {
  NSMutableArray<NSValue*>* ranges = [NSMutableArray array];
  for (NSDictionary* selection in [self rectangularSelections]) {
    [ranges addObject:selection[@"committedRange"]];
  }
  return ranges;
}

- (NSUInteger)selectedCharacterCount {
  if (!self.rectangularSelectionActive) return self.committedSelection.length;
  NSUInteger count = 0;
  for (NSDictionary* selection in [self rectangularSelections]) {
    count += [selection[@"committedRange"] rangeValue].length;
    count += [selection[@"trailingVirtualSpaces"] unsignedIntegerValue];
  }
  return count;
}

- (BOOL)hasRectangularSelection {
  return self.rectangularSelectionActive &&
      std::abs(self.rectangularAnchorPoint.x -
               self.rectangularCurrentPoint.x) > 0.5;
}

- (void)updateRectangularSelection {
  NSArray<NSValue*>* ranges = [self rectangularCommittedRanges];
  if (ranges.count == 0) return;
  const NSRange first = ranges.firstObject.rangeValue;
  const NSRange last = ranges.lastObject.rangeValue;
  self.committedSelection = NSMakeRange(
      first.location, NSMaxRange(last) - first.location);
  [self updateDocumentViewSize];
  [self setNeedsDisplay:YES];
  const NSRange lineSpan = [self rectangularDisplayLineSpan];
  const CGFloat bottom = kVerticalInset +
      static_cast<CGFloat>(NSMaxRange(lineSpan)) * [self editorLineHeight];
  [self scrollRectToVisible:NSMakeRect(
      self.rectangularCurrentPoint.x, bottom - [self editorLineHeight],
      1.0, [self editorLineHeight])];
}

- (void)clearRectangularSelection {
  self.rectangularSelectionActive = NO;
}

- (void)toggleRectangularSelection:(id)sender {
  (void)sender;
  if (self.rectangularSelectionActive) {
    [self clearRectangularSelection];
    self.committedSelection = NSMakeRange(self.committedSelection.location, 0);
  } else {
    const NSRect caret = [self localRectForDisplayIndex:
        self.committedSelection.location];
    self.rectangularAnchorPoint = NSMakePoint(
        caret.origin.x, NSMidY(caret));
    self.rectangularCurrentPoint = self.rectangularAnchorPoint;
    self.rectangularSelectionActive = YES;
    [self updateRectangularSelection];
  }
  [self setNeedsDisplay:YES];
}

- (void)scrollSelectionToVisible {
  const NSRange displaySelection = [self displaySelection];
  const NSUInteger caret = ![self hasMarkedText] &&
          self.navigationAnchor != NSNotFound
      ? self.navigationCaret : NSMaxRange(displaySelection);
  [self scrollRectToVisible:[self localRectForDisplayIndex:caret]];
}

- (void)toggleSplitEditor:(id)sender {
  if ([self.window.windowController isKindOfClass:[SakuraWindowController class]]) {
    [(SakuraWindowController*)self.window.windowController toggleSplitEditor:sender];
  }
}

- (void)toggleToolbar:(id)sender {
  if ([self.window.windowController isKindOfClass:[SakuraWindowController class]]) {
    [(SakuraWindowController*)self.window.windowController toggleToolbar:sender];
  }
}

- (void)toggleStatusBar:(id)sender {
  if ([self.window.windowController isKindOfClass:[SakuraWindowController class]]) {
    [(SakuraWindowController*)self.window.windowController toggleStatusBar:sender];
  }
}

- (void)showOutlinePanel:(id)sender {
  if ([self.window.windowController isKindOfClass:[SakuraWindowController class]]) {
    [(SakuraWindowController*)self.window.windowController showOutlinePanel:sender];
  }
}

- (void)showCommandList:(id)sender {
  if ([self.window.windowController isKindOfClass:[SakuraWindowController class]]) {
    [(SakuraWindowController*)self.window.windowController showCommandList:sender];
  }
}

- (void)showTypeSettingsList:(id)sender {
  if ([self.window.windowController isKindOfClass:[SakuraWindowController class]]) {
    [(SakuraWindowController*)self.window.windowController
        showTypeSettingsList:sender];
  }
}

- (void)showTypeSettings:(id)sender {
  if ([self.window.windowController isKindOfClass:[SakuraWindowController class]]) {
    [(SakuraWindowController*)self.window.windowController showTypeSettings:sender];
  }
}

- (void)showCommonSettings:(id)sender {
  if ([self.window.windowController isKindOfClass:[SakuraWindowController class]]) {
    [(SakuraWindowController*)self.window.windowController showCommonSettings:sender];
  }
}

- (void)showEncodingPanel:(id)sender {
  if ([self.window.windowController isKindOfClass:[SakuraWindowController class]]) {
    [(SakuraWindowController*)self.window.windowController showEncodingPanel:sender];
  }
}

- (void)showGrepPanel:(id)sender {
  if ([self.window.windowController isKindOfClass:[SakuraWindowController class]]) {
    [(SakuraWindowController*)self.window.windowController showGrepPanel:sender];
  }
}

- (void)showGrepReplacePanel:(id)sender {
  if ([self.window.windowController isKindOfClass:[SakuraWindowController class]]) {
    [(SakuraWindowController*)self.window.windowController
        showGrepReplacePanel:sender];
  }
}

- (void)goBackInNavigationHistory:(id)sender {
  [(SakuraWindowController*)self.window.windowController
      goBackInNavigationHistory:sender];
}

- (void)goForwardInNavigationHistory:(id)sender {
  [(SakuraWindowController*)self.window.windowController
      goForwardInNavigationHistory:sender];
}

- (void)registerCurrentNavigationPosition:(id)sender {
  [(SakuraWindowController*)self.window.windowController
      registerCurrentNavigationPosition:sender];
}

- (NSUInteger)currentDocumentOffset {
  return self.committedSelection.location;
}

- (void)recordNavigationToOffset:(NSUInteger)offset {
  if ([self.window.windowController isKindOfClass:[SakuraWindowController class]]) {
    [(SakuraWindowController*)self.window.windowController
        noteNavigationFromOffset:self.committedSelection.location
                        toOffset:offset];
  }
}

- (void)setInputLineEndingCRLF:(id)sender {
  (void)sender;
  [self.sakuraDocument setPreferredLineEndingString:@"CRLF"];
}

- (void)setInputLineEndingLF:(id)sender {
  (void)sender;
  [self.sakuraDocument setPreferredLineEndingString:@"LF"];
}

- (void)setInputLineEndingCR:(id)sender {
  (void)sender;
  [self.sakuraDocument setPreferredLineEndingString:@"CR"];
}

- (void)jumpToDocumentOffset:(NSUInteger)offset {
  if ([self hasMarkedText]) {
    [self unmarkText];
  }
  [self clearRectangularSelection];
  const NSUInteger length = [self committedString].length;
  const NSUInteger target =
      [self previousEditBoundaryAtOrBefore:std::min(offset, length)];
  [self recordNavigationToOffset:target];
  self.committedSelection = NSMakeRange(target, 0);
  [self.window makeFirstResponder:self];
  [self setNeedsDisplay:YES];
  [self scrollSelectionToVisible];
}

- (void)findTextFromToolbar:(NSString*)text {
  if (text.length == 0) { NSBeep(); return; }
  [self prepareFindPanel];
  self.findField.stringValue = text;
  [self findNext:self];
}

#pragma mark - Find and replace

- (SakuraSearchState*)searchState { return SakuraSearchState.sharedState; }
- (void)refreshSearchHistoryControls {
  self.findField.recentsAutosaveName = nil;
  self.findField.maximumRecents = 20;
  self.findField.recentSearches = [self searchState].queryHistory;
  [self.replacementHistoryPopup removeAllItems]; [self.replacementHistoryPopup addItemWithTitle:@"置換履歴"];
  for (NSString* value in [self searchState].replacementHistory) {
    NSString* title = value.length ? value : @"（空文字）";
    if (title.length > 40) title = [[title substringToIndex:[title rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 40)].length] stringByAppendingString:@"…"];
    title = [title stringByReplacingOccurrencesOfString:@"\n" withString:@"↵"];
    title = [title stringByReplacingOccurrencesOfString:@"\r" withString:@"↵"];
    [self.replacementHistoryPopup addItemWithTitle:title];
    self.replacementHistoryPopup.lastItem.representedObject = value;
  }
}
- (void)loadSharedSearchCriteria {
  [self cancelSearchNavigation];
  [self cancelSearchHighlights];
  [self.searchCountProgress cancel]; self.searchCountProgress = nil;
  [self setFindStatus:@""];
  NSDictionary* value = [self searchState].criteria;
  self.findField.stringValue = value[@"query"]; self.replaceField.stringValue = value[@"replacement"];
  self.caseSensitiveButton.state = [value[@"caseSensitive"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
  self.wholeWordButton.state = [value[@"wholeWord"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
  self.regularExpressionButton.state = [value[@"regex"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
  self.searchWrapButton.state = [value[@"wrap"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
  self.hasLastSearchMatch = NO; self.searchMarksHidden = NO;
  [self refreshSearchHistoryControls]; [self setNeedsDisplay:YES];
}
- (void)sharedSearchDidChange:(NSNotification*)notification {
  if (notification.userInfo[@"source"] == self || [[self searchCriteriaDictionary] isEqual:[self searchState].criteria]) [self refreshSearchHistoryControls];
  else [self loadSharedSearchCriteria];
}
- (NSDictionary*)searchCriteriaDictionary {
  return @{
    @"query":self.findField.stringValue != nil ? self.findField.stringValue : @"",
    @"replacement":self.replaceField.stringValue != nil ? self.replaceField.stringValue : @"",
    @"caseSensitive":@(self.caseSensitiveButton.state == NSControlStateValueOn),
    @"wholeWord":@(self.wholeWordButton.state == NSControlStateValueOn),
    @"regex":@(self.regularExpressionButton.state == NSControlStateValueOn),
    @"wrap":@(self.searchWrapButton == nil || self.searchWrapButton.state == NSControlStateValueOn)};
}
- (BOOL)publishSearchCriteria:(BOOL)remember replacement:(BOOL)replace {
  if (self.searchCountProgress) { [self.searchCountProgress cancel]; self.searchCountProgress = nil; [self setFindStatus:@""]; }
  BOOL saved = [[self searchState] updateCriteria:[self searchCriteriaDictionary]
    source:self rememberQuery:remember rememberReplacement:replace];
  if (!saved) [self setFindStatus:@"検索文字列は4,096、置換文字列は65,536 UTF-16単位までです。"];
  [self refreshSearchHistoryControls]; return saved;
}
- (void)chooseReplacementHistory:(id)sender {
  (void)sender;
  id value = self.replacementHistoryPopup.selectedItem.representedObject;
  if ([value isKindOfClass:NSString.class]) { [self cancelSearchNavigation]; self.replaceField.stringValue = value; [self publishSearchCriteria:NO replacement:NO]; }
}
- (void)clearSharedSearchHistory:(id)sender {
  (void)sender; [self prepareFindPanel]; [[self searchState] clearHistory];
  [self setFindStatus:@"起動中の共有検索履歴を消去しました。"];
}
- (BOOL)searchScopeIsValid {
  if (self.searchScopeButton.state != NSControlStateValueOn) return YES;
  if (!self.searchScopeCaptured || self.sakuraDocument == nil ||
      self.searchScopeRevision != self.sakuraDocument.documentSession.buffer().revision()) return NO;
  const auto& buffer = self.sakuraDocument.documentSession.buffer();
  NSRange range = self.searchScopeRange;
  return range.location <= buffer.length() && range.length <= buffer.length() - range.location &&
      buffer.isEditBoundary(range.location) && buffer.isEditBoundary(NSMaxRange(range));
}
- (BOOL)ensureSearchScope {
  if ([self searchScopeIsValid]) return YES;
  [self setFindStatus:@"範囲指定後に本文が変更されました。選択し直し「範囲を再指定」を押してください。"];
  [self refreshSearchScopeLabel]; return NO;
}
- (void)refreshSearchScopeLabel {
  if (self.searchScopeButton.state != NSControlStateValueOn) self.searchScopeLabel.stringValue = @"文書全体";
  else if (![self searchScopeIsValid]) self.searchScopeLabel.stringValue = @"範囲が変更されています（再指定が必要）";
  else {
    const auto& buffer = self.sakuraDocument.documentSession.buffer();
    auto start = buffer.positionAt(self.searchScopeRange.location), end = buffer.positionAt(NSMaxRange(self.searchScopeRange));
    self.searchScopeLabel.stringValue = [NSString stringWithFormat:@"%zu行%llu桁 〜 %zu行%llu桁", start.line + 1,
        (unsigned long long)start.column + 1, end.line + 1, (unsigned long long)end.column + 1];
  }
}
- (BOOL)captureCurrentSearchScope {
  if (self.hasMarkedText) [self unmarkText];
  if (self.hasRectangularSelection || !self.committedSelection.length) {
    [self setFindStatus:@"通常の範囲選択をしてから指定してください（矩形範囲は未対応）。"]; return NO;
  }
  self.searchScopeRange = self.committedSelection;
  [self cancelSearchNavigation];
  [self cancelSearchHighlights];
  [self.searchCountProgress cancel]; self.searchCountProgress = nil;
  self.searchScopeRevision = self.sakuraDocument.documentSession.buffer().revision(); self.searchScopeCaptured = YES;
  self.searchScopeButton.state = NSControlStateValueOn; self.hasLastSearchMatch = NO;
  [self refreshSearchScopeLabel]; [self setNeedsDisplay:YES]; return YES;
}
- (void)captureSearchScope:(id)sender { (void)sender; [self captureCurrentSearchScope]; }
- (void)changeSearchScope:(id)sender {
  (void)sender;
  [self cancelSearchNavigation];
  [self cancelSearchHighlights];
  [self.searchCountProgress cancel]; self.searchCountProgress = nil;
  if (self.searchScopeButton.state == NSControlStateValueOn && ![self captureCurrentSearchScope] && !self.searchScopeCaptured)
    self.searchScopeButton.state = NSControlStateValueOff;
  self.hasLastSearchMatch = NO; [self refreshSearchScopeLabel]; [self setNeedsDisplay:YES];
}
- (void)useSelectionForFind:(id)sender {
  (void)sender;
  if (self.hasMarkedText) [self unmarkText];
  if (self.hasRectangularSelection || !self.committedSelection.length || self.committedSelection.length > 4096) {
    NSBeep(); return;
  }
  NSString* text = [[self committedString] substringWithRange:self.committedSelection];
  [self cancelSearchNavigation];
  [self prepareFindPanel]; self.findField.stringValue = text; self.regularExpressionButton.state = NSControlStateValueOff;
  [self publishSearchCriteria:YES replacement:NO]; [self setFindStatus:@"選択文字列を通常検索に設定しました。"];
}

- (void)countSearchMatches:(id)sender {
  [self cancelSearchNavigation];
  [self prepareFindPanel];
  if ([sender isKindOfClass:NSMenuItem.class]) [self showFindPanel:sender];
  if (self.hasMarkedText) [self unmarkText];
  if (![self ensureSearchScope]) return;
  if (!self.findField.stringValue.length) { [self setFindStatus:@"検索文字列を入力してください。"]; return; }
  if (![self publishSearchCriteria:YES replacement:NO]) return;
  const auto needle = sakura::platform::mac::sakuraStringFromString(self.findField.stringValue);
  auto options = [self searchOptions];
  const auto& buffer = self.sakuraDocument.documentSession.buffer();
  if (buffer.length() > 4 * 1024 * 1024 || buffer.lineCount() > 100000) {
    [self setFindStatus:@"件数確認の上限は4Mi UTF-16／100,000行です。通常検索は利用できます。"]; return;
  }
  auto snapshot = std::make_shared<const sakura::core::TextBuffer>(buffer);
  const auto revision = buffer.revision();
  NSString* query = self.findField.stringValue.copy;
  const auto flags = [self searchFlags];
  const NSRange scope = self.searchScopeRange;
  self.searchCountRevision = revision;
  NSProgress* progress = [NSProgress progressWithTotalUnitCount:1]; self.searchCountProgress = progress;
  [self setFindStatus:@"一致件数を確認しています…"];
  options.captureGroups = false; options.maxMatches = 100001; options.regexTimeLimitMilliseconds = 250;
  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
  options.cancelled = [progress, deadline] { return static_cast<bool>(progress.cancelled) || std::chrono::steady_clock::now() > deadline; };
  __weak SakuraEditorView* weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @autoreleasepool {
      NSUInteger count = 0; BOOL failed = NO, invalid = NO;
      try {
        if (!sakura::core::SearchEngine::isValidPattern(needle, options)) invalid = YES;
        else count = sakura::core::SearchEngine{}.findAll(*snapshot, needle, options).size();
      }
      catch (const std::exception&) { failed = YES; }
      dispatch_async(dispatch_get_main_queue(), ^{
        SakuraEditorView* editor = weakSelf;
        if (editor == nil || editor.searchCountProgress != progress) return;
        editor.searchCountProgress = nil;
        if (progress.cancelled || editor.sakuraDocument == nil || editor.sakuraDocument.documentSession.buffer().revision() != revision) {
          [editor setFindStatus:@"本文が変更されたか処理が取り消されたため、件数確認を中止しました。"]; return;
        }
        if (![editor searchScopeIsValid] || ![editor.findField.stringValue isEqual:query] ||
            [editor searchFlags] != flags || !NSEqualRanges(editor.searchScopeRange, scope)) {
          [editor setFindStatus:@"検索条件が変更されたため件数確認を中止しました。"]; return;
        }
        if (invalid) [editor setFindStatus:@"正規表現が正しくありません。"];
        else if (failed) [editor setFindStatus:@"件数確認を中止しました（時間・メモリ上限または検索エラー）。"];
        else if (count > 100000) [editor setFindStatus:@"100,000件を超えています（件数確認の上限）。"];
        else [editor setFindStatus:[NSString stringWithFormat:@"%lu 件一致しました。", (unsigned long)count]];
      });
    }
  });
}

- (sakura::core::SearchOptions)searchOptions {
  sakura::core::SearchOptions options{.caseSensitive = self.caseSensitiveButton.state == NSControlStateValueOn,
          .wholeWord = self.wholeWordButton.state == NSControlStateValueOn,
          .wrap = self.searchWrapButton == nil || self.searchWrapButton.state == NSControlStateValueOn,
          .regularExpression = self.regularExpressionButton.state ==
                               NSControlStateValueOn};
  if (self.searchScopeButton.state == NSControlStateValueOn) {
    if (![self searchScopeIsValid]) throw std::runtime_error("Selection search scope is stale");
    options.range = sakura::core::TextRange{self.searchScopeRange.location, self.searchScopeRange.length};
  }
  return options;
}

- (NSUInteger)searchFlags {
  const auto options = [self searchOptions];
  return (options.caseSensitive ? 1 : 0) | (options.wholeWord ? 2 : 0) |
         (options.regularExpression ? 4 : 0) | (options.wrap ? 8 : 0) |
         (options.range ? 16 : 0);
}

- (void)rememberSearchSelection {
  self.hasLastSearchMatch = YES;
  self.lastSearchMatchRange = self.committedSelection;
  self.lastSearchRevision = self.sakuraDocument.documentSession.buffer().revision();
  self.lastSearchPattern = self.findField.stringValue;
  self.lastSearchFlags = [self searchFlags];
  self.lastSearchSelectionGeneration = self.selectionGeneration;
}

- (void)setFindStatus:(NSString*)status {
  self.searchOperationStatusText = status;
  self.findStatusLabel.stringValue = status;
  if ([self.window.windowController isKindOfClass:SakuraWindowController.class]) {
    SakuraWindowController* controller = (SakuraWindowController*)self.window.windowController;
    NSResponder* responder = self.window.firstResponder;
    if ([responder isKindOfClass:SakuraEditorView.class] ? responder == self : controller.editorView == self)
      [controller updateStatusForEditor:self];
  }
}

- (NSArray*)currentSyntaxKey {
  SakuraDocument* document = self.sakuraDocument;
  NSString* extension = document.fileURL.pathExtension.lowercaseString;
  return @[@(document != nil ? document.documentSession.buffer().revision() : 0),
      extension != nil ? extension : @"", [self compositionIdentity],
      [self syntaxPreferences], [NSValue valueWithNonretainedObject:document]];
}

- (void)invalidateOutdatedSyntax {
  if (_syntaxKey == nil) return;
  SakuraDocument* document = self.sakuraDocument;
  if (!self.syntaxProgress.cancelled && document != nil && [_syntaxKey isEqual:[self currentSyntaxKey]] && _syntaxSource &&
      _syntaxSource->sharesStorageWith(document.documentSession.buffer())) return;
  [self.syntaxProgress cancel]; self.syntaxProgress = nil;
  _syntaxKey = nil;
  // Releasing a large token array or obsolete text tree is not drawing work.
  auto retired = std::make_shared<RetiredSyntax>(RetiredSyntax{std::move(_cachedSyntaxTokens),
      std::move(_additionalSyntaxTokens), std::move(_cachedSyntaxIndex), std::move(_syntaxSource)});
  _cachedSyntaxTokens = emptySyntaxTokens();
  _additionalSyntaxTokens = emptySyntaxTokens(); _flattenedSyntaxReady = NO;
  dispatch_async(syntaxPreparationQueue(), ^{ *retired = {}; });
  [_styledLines removeAllObjects];
  [self setSyntaxStatusMessage:@""];
  [self setCustomSyntaxStatusMessage:@""];
}

- (BOOL)syntaxKeyIsCurrent:(NSArray*)key progress:(NSProgress*)progress
                    source:(const sakura::core::TextBuffer&)source {
  return self.syntaxProgress == progress && !progress.cancelled && self.sakuraDocument != nil &&
      [_syntaxKey isEqual:key] && [[self currentSyntaxKey] isEqual:key] &&
      source.sharesStorageWith(self.sakuraDocument.documentSession.buffer());
}

- (SyntaxTokens)syntaxTokensInRange:(NSRange)range {
  if (!range.length) return {};
  auto result = _cachedSyntaxIndex ? _cachedSyntaxIndex->tokensIn({range.location,range.length}) : SyntaxTokens{};
  const auto baseCount = result.size();
  auto extra = std::lower_bound(_additionalSyntaxTokens->begin(), _additionalSyntaxTokens->end(), range.location,
      [](const auto& t, NSUInteger start) { return t.range.location+t.range.length <= start; });
  for (; extra != _additionalSyntaxTokens->end() && extra->range.location < NSMaxRange(range); ++extra) result.push_back(*extra);
  if (result.size() != baseCount)
    std::sort(result.begin(),result.end(),[](const auto& a,const auto& b){return a.range.location<b.range.location;});
  return result;
}

// Compatibility diagnostics used by object tests. Drawing uses range queries,
// never this whole-document materialization.
- (const std::vector<sakura::core::SyntaxToken>&)activeSyntaxTokens {
  [self prepareSyntax];
  if (!_flattenedSyntaxReady) {
    const auto length = self.hasMarkedText ? [self displayString].length : self.sakuraDocument.documentSession.buffer().length();
    _cachedSyntaxTokens = std::make_shared<const SyntaxTokens>([self syntaxTokensInRange:NSMakeRange(0,length)]);
    _flattenedSyntaxReady = YES;
    ++_syntaxFlattenBuilds;
  }
  return *_cachedSyntaxTokens;
}

- (void)prepareSyntax {
  [self invalidateOutdatedSyntax];
  if (_syntaxKey != nil) return;
  NSArray* key = [self currentSyntaxKey];
  _syntaxKey = key;
  ++_syntaxBuilds;
  [_styledLines removeAllObjects];
  SakuraDocument* document = self.sakuraDocument;
  if (document == nil) return;
  NSDictionary* preferences = key[3];
  const auto language = sakura::core::SyntaxHighlighter::languageForExtension([key[1] UTF8String]);
  const BOOL custom = SakuraSyntaxPreferencesHaveRules(preferences);
  try {
    _syntaxSource = std::make_shared<const sakura::core::TextBuffer>(document.documentSession.buffer());
    if (language == sakura::core::SyntaxLanguage::plain && !custom) return;
    // Layout already owns the current IME preview. Copy its immutable root,
    // never serialize the full display NSString on the main thread.
    if ([self hasMarkedText]) [self displayLineRanges];
    auto payload = std::make_shared<std::unique_ptr<SyntaxWork>>(std::make_unique<SyntaxWork>(
        SyntaxWork{_syntaxSource, [self hasMarkedText] && _markedLayoutBuffer ? *_markedLayoutBuffer : *_syntaxSource,
            _previousSyntaxIndex, {}, {}, {}, {}, {}}));
    NSProgress* progress = [NSProgress progressWithTotalUnitCount:1];
    self.syntaxProgress = progress;
    [self setSyntaxStatusMessage:language == sakura::core::SyntaxLanguage::plain ? @"" : @"通常色分け中…（Escで中止）"];
    [self setCustomSyntaxStatusMessage:custom ? @"追加色分け待機中…" : @""];
    __weak SakuraEditorView* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 75 * NSEC_PER_MSEC), syntaxPreparationQueue(), ^{
      @autoreleasepool {
        const BOOL ranOnMain = NSThread.isMainThread;
        NSString* baseMessage = @"";
        NSString* customMessage = @"";
        auto& work = **payload;
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
        try {
          sakura::core::IndexedSyntax candidate = work.previous ? *work.previous : sakura::core::IndexedSyntax{};
          candidate.update(work.display, language, [progress, deadline] {
                return static_cast<bool>(progress.cancelled) || std::chrono::steady_clock::now() > deadline;
              });
          work.base = std::make_shared<const sakura::core::IndexedSyntax>(std::move(candidate));
          // Publish immutable base tokens first. Custom rules can take longer,
          // but never run against a missing/incomplete comment/string mask.
          dispatch_async(dispatch_get_main_queue(), ^{
            SakuraEditorView* target = weakSelf;
            if (target == nil || ![target syntaxKeyIsCurrent:key progress:progress source:*(*payload)->source]) return;
            auto& accepted = **payload;
            accepted.retiredIndex = std::move(target->_previousSyntaxIndex);
            target->_previousSyntaxIndex = accepted.base;
            target->_cachedSyntaxIndex = accepted.base;
            target->_syntaxUpdate = accepted.base->lastUpdate();
            target->_cachedSyntaxTokens = emptySyntaxTokens(); target->_flattenedSyntaxReady = NO;
            [target->_styledLines removeAllObjects];
            [target setSyntaxStatusMessage:@""];
            [target setCustomSyntaxStatusMessage:custom ? @"追加色分け中…" : @""];
            [target setNeedsDisplay:YES];
          });
        } catch (const std::exception&) {
          baseMessage = std::chrono::steady_clock::now() > deadline
              ? @"通常色分け: 時間上限（装飾なしで表示）" : @"通常色分けを中止しました（解析・メモリエラー）。";
        }
        if (work.base && custom && !progress.cancelled) {
          using Status = sakura::core::CustomSyntaxStatus;
          sakura::core::CustomSyntaxResult result;
          try {
            sakura::core::CustomSyntaxRules rules;
            if (work.display.length() > sakura::core::kCustomSyntaxTextLimit ||
                work.display.lineCount() > sakura::core::kCustomSyntaxLineLimit) result.status = Status::tooLarge;
            else if (SakuraParseSyntaxPreferences(preferences, rules)) result.status = Status::invalidRules;
            else {
              auto mask = work.base->tokens([progress] { return static_cast<bool>(progress.cancelled); });
              result = sakura::core::highlightCustomSyntax(work.display, mask, rules,
                  [progress] { return static_cast<bool>(progress.cancelled); });
            }
            if (result.status == Status::ok) {
              work.additional = std::make_shared<const SyntaxTokens>(std::move(result.tokens));
            }
          } catch (const std::exception&) { result.status = progress.cancelled ? Status::cancelled : Status::tooLarge; }
          switch (result.status) {
            case Status::ok: case Status::cancelled: break;
            case Status::invalidRules: customMessage = @"追加色分け: 設定エラー"; break;
            case Status::tooLarge: customMessage = @"追加色分け: サイズ／行数上限"; break;
            case Status::tooManyMatches: customMessage = @"追加色分け: 10,000件上限"; break;
            case Status::timedOut: customMessage = @"追加色分け: 時間上限（通常表示を継続）"; break;
          }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
          SakuraEditorView* target = weakSelf;
          if (target != nil) {
            if ([target syntaxKeyIsCurrent:key progress:progress source:*(*payload)->source]) {
              auto& completed = **payload;
              completed.retiredDiagnostic = std::move(target->_cachedSyntaxTokens);
              completed.retiredAdditional = std::move(target->_additionalSyntaxTokens);
              target->_cachedSyntaxTokens = emptySyntaxTokens(); target->_flattenedSyntaxReady = NO;
              target->_additionalSyntaxTokens = completed.additional ? completed.additional : emptySyntaxTokens();
              target.syntaxProgress = nil;
              ++target->_syntaxCompletions; target->_syntaxWorkerRanOnMainThread = ranOnMain;
              [target->_styledLines removeAllObjects];
              [target setSyntaxStatusMessage:baseMessage];
              [target setCustomSyntaxStatusMessage:baseMessage.length ? @"" : customMessage];
              [target setNeedsDisplay:YES];
            } else {
              ++target->_syntaxDiscards;
              if (target.syntaxProgress == progress) [target invalidateOutdatedSyntax];
            }
          }
          // Main callbacks hold only the small payload handle. Discarded
          // source snapshots and token arrays are destroyed on the worker.
          dispatch_async(syntaxPreparationQueue(), ^{ payload->reset(); });
        });
      }
    });
  } catch (const std::exception&) {
    self.syntaxProgress = nil;
    [self setSyntaxStatusMessage:@"通常色分けを開始できませんでした。"];
  }
}

- (NSArray*)searchHighlightKey {
  SakuraDocument* document = self.sakuraDocument;
  NSString* pattern = self.findField.stringValue.copy;
  if (pattern == nil) pattern = @"";
  const BOOL enabled = document != nil && !self.searchMarksHidden &&
      self.findPanel.isVisible && pattern.length != 0 && ![self hasMarkedText] && [self searchScopeIsValid];
  return @[@(document != nil ? document.documentSession.buffer().revision() : 0),
                   pattern, @(enabled ? [self searchFlags] : 0), @(enabled),
                   @(self.searchScopeRange.location), @(self.searchScopeRange.length),
                   [NSValue valueWithNonretainedObject:document]];
}

- (const std::vector<NSRange>&)activeSearchRanges {
  NSArray* key = [self searchHighlightKey];
  if ([_searchKey isEqual:key]) return _cachedSearchRanges;
  [self.searchHighlightProgress cancel]; self.searchHighlightProgress = nil;
  _searchKey = key;
  ++_searchBuilds;
  [_styledLines removeAllObjects];
  _cachedSearchRanges.clear();
  if (![key[3] boolValue]) {
    [self setSearchHighlightStatusMessage:@""];
    return _cachedSearchRanges;
  }
  try {
    if (self.findField.stringValue.length > 4096) {
      [self setSearchHighlightStatusMessage:@"検索強調の文字列上限は4,096 UTF-16単位です。"];
      return _cachedSearchRanges;
    }
    const auto needle = sakura::platform::mac::sakuraStringFromString(
        self.findField.stringValue);
    auto options = [self searchOptions]; options.captureGroups = false; options.maxMatches = 10001;
    auto snapshot = std::make_shared<const sakura::core::TextBuffer>(self.sakuraDocument.documentSession.buffer());
    NSProgress* progress = [NSProgress progressWithTotalUnitCount:1]; self.searchHighlightProgress = progress;
    [self setSearchHighlightStatusMessage:@"検索強調を更新中…"];
    __weak SakuraEditorView* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      @autoreleasepool {
        if (progress.cancelled) return;
        const BOOL ranOnMain = NSThread.isMainThread;
        std::shared_ptr<std::vector<NSRange>> ranges;
        NSString* message = @"";
        try {
          auto workerOptions = options;
          auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
          workerOptions.regexTimeLimitMilliseconds = 250;
          workerOptions.cancelled = [progress, deadline] { return static_cast<bool>(progress.cancelled) || std::chrono::steady_clock::now() > deadline; };
          ranges = std::make_shared<std::vector<NSRange>>();
          if (!sakura::core::SearchEngine::isValidPattern(needle, workerOptions)) message = @"正規表現が正しくありません（検索強調）。";
          else {
            const auto matches = sakura::core::SearchEngine{}.findAll(*snapshot, needle, workerOptions);
            ranges->reserve(std::min<std::size_t>(10000, matches.size()));
            for (std::size_t index = 0; index < std::min<std::size_t>(10000, matches.size()); ++index)
              ranges->push_back(NSMakeRange(matches[index].range.location, matches[index].range.length));
            if (matches.size() > 10000) message = @"検索強調は先頭10,000件までです。";
          }
        } catch (const std::exception&) { message = @"検索強調を中止しました（時間・メモリ上限または検索エラー）。"; }
        dispatch_async(dispatch_get_main_queue(), ^{
          SakuraEditorView* editor = weakSelf;
          if (!editor) return;
          if (editor.searchHighlightProgress != progress || progress.cancelled ||
              ![editor->_searchKey isEqual:key] || ![[editor searchHighlightKey] isEqual:key]) {
            ++editor->_searchDiscards;
            if (editor.searchHighlightProgress == progress) {
              editor.searchHighlightProgress = nil; editor->_searchKey = nil;
              editor->_cachedSearchRanges.clear(); [editor->_styledLines removeAllObjects];
              [editor setSearchHighlightStatusMessage:@""]; [editor setNeedsDisplay:YES];
            }
            return;
          }
          editor.searchHighlightProgress = nil; ++editor->_searchCompletions;
          editor->_searchWorkerRanOnMainThread = ranOnMain;
          if (ranges) editor->_cachedSearchRanges.swap(*ranges);
          else editor->_cachedSearchRanges.clear();
          [editor->_styledLines removeAllObjects];
          [editor setSearchHighlightStatusMessage:message]; [editor setNeedsDisplay:YES];
        });
      }
    });
  } catch (const std::exception&) {
    [self setSearchHighlightStatusMessage:@"検索強調を開始できませんでした。"];
  }
  return _cachedSearchRanges;
}

- (NSDictionary<NSString*, NSNumber*>*)renderingStatistics {
  return @{@"textBuilds":@(_textBuilds), @"layoutBuilds":@(_layoutBuilds),
           @"layoutMeasuredLines":@(_layoutMeasuredLines), @"layoutFullBuilds":@(_layoutFullBuilds),
           @"layoutComparedTextNodes":@(_layoutComparedTextNodes),
           @"syntaxBuilds":@(_syntaxBuilds), @"searchBuilds":@(_searchBuilds),
           @"syntaxPending":@([self hasPendingSyntax]), @"syntaxCompletions":@(_syntaxCompletions),
           @"syntaxDiscards":@(_syntaxDiscards), @"syntaxWorkerOnMain":@(_syntaxWorkerRanOnMainThread),
           @"syntaxParsedUnits":@(_syntaxUpdate.parsedUnits), @"syntaxSerializedUnits":@(_syntaxUpdate.serializedUnits),
           @"syntaxReusedUnits":@(_syntaxUpdate.reusedUnits), @"syntaxRebuiltBlocks":@(_syntaxUpdate.rebuiltBlocks),
           @"syntaxFullRebuild":@(_syntaxUpdate.fullRebuild),
           @"syntaxFlattenBuilds":@(_syntaxFlattenBuilds),
           @"styledBuilds":@(_styledBuilds), @"drawnLines":@(_drawnLines),
           @"lineLookupSteps":@(_lineLookupSteps), @"searchCompletions":@(_searchCompletions),
           @"searchDiscards":@(_searchDiscards), @"searchWorkerOnMain":@(_searchWorkerRanOnMainThread),
           @"searchPending":@(self.searchHighlightProgress != nil),
           @"imeSharedBuilds":@(_imeSharedBuilds), @"imeFullBuilds":@(_imeFullBuilds),
           @"navigationPending":@([self hasPendingSearchNavigation]), @"navigationCompletions":@(_navigationCompletions),
           @"navigationDiscards":@(_navigationDiscards), @"navigationWorkerOnMain":@(_navigationWorkerRanOnMainThread),
           @"replacementPending":@([self hasPendingReplacement]), @"replacementCompletions":@(_replacementCompletions),
           @"replacementDiscards":@(_replacementDiscards), @"replacementWorkerOnMain":@(_replacementWorkerRanOnMainThread),
           @"replacementLayoutsAdopted":@(_replacementLayoutsAdopted), @"replacementMainMilliseconds":@(_replacementMainMilliseconds),
           @"replacementAdoptMilliseconds":@(_replacementAdoptMilliseconds), @"replacementRefreshMilliseconds":@(_replacementRefreshMilliseconds),
           @"historyPending":@([self hasPendingHistoryNavigation]), @"historyQueuedRequests":@(_historyRequests.size()),
           @"historyCompletions":@(_historyCompletions), @"historyDiscards":@(_historyDiscards),
           @"historyWorkerOnMain":@(_historyWorkerRanOnMainThread), @"historyLayoutsAdopted":@(_historyLayoutsAdopted),
           @"historyMainMilliseconds":@(_historyMainMilliseconds), @"historyAdoptMilliseconds":@(_historyAdoptMilliseconds),
           @"historyRefreshMilliseconds":@(_historyRefreshMilliseconds)};
}

- (void)refreshSearchHighlights:(id)sender {
  (void)sender;
  [self cancelSearchNavigation];
  [self cancelSearchHighlights];
  [self setFindStatus:@""];
  [self publishSearchCriteria:NO replacement:NO];
  self.searchMarksHidden = NO;
  [self setNeedsDisplay:YES];
}

- (void)controlTextDidChange:(NSNotification*)notification {
  if (notification.object == self.findField || notification.object == self.replaceField) {
    [self cancelSearchNavigation];
    [self cancelSearchHighlights];
    [self setFindStatus:@""];
    [self publishSearchCriteria:NO replacement:NO];
    self.searchMarksHidden = NO;
    [self setNeedsDisplay:YES];
  }
}

- (void)prepareFindPanel {
  if (self.findPanel == nil) {
    NSPanel* panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 660, 254)
                  styleMask:NSWindowStyleMaskTitled |
                            NSWindowStyleMaskClosable |
                            NSWindowStyleMaskUtilityWindow
                    backing:NSBackingStoreBuffered
                      defer:NO];
    panel.title = @"検索・置換";
    panel.hidesOnDeactivate = NO;
    panel.floatingPanel = YES;

    NSView* content = panel.contentView;
    const CGFloat labelX = 16.0;
    const CGFloat fieldX = 110.0;
    const CGFloat fieldWidth = 440.0;
    NSTextField* findLabel = [NSTextField labelWithString:@"検索文字列:"];
    findLabel.frame = NSMakeRect(labelX, 210, 88, 22);
    [content addSubview:findLabel];
    NSSearchField* findField = [[NSSearchField alloc]
        initWithFrame:NSMakeRect(fieldX, 206, 540, 26)];
    findField.sendsSearchStringImmediately = NO;
    findField.delegate = self;
    findField.target = self;
    findField.action = @selector(findNext:);
    findField.toolTip = @"履歴は起動中だけ共有します。強調表示は先頭10,000件までです。";
    [content addSubview:findField];

    NSTextField* replaceLabel = [NSTextField labelWithString:@"置換文字列:"];
    replaceLabel.frame = NSMakeRect(labelX, 174, 88, 22);
    [content addSubview:replaceLabel];
    NSTextField* replaceField = [[NSTextField alloc]
        initWithFrame:NSMakeRect(fieldX, 170, fieldWidth, 26)];
    replaceField.delegate = self;
    [content addSubview:replaceField];

    NSButton* caseSensitive = [NSButton checkboxWithTitle:@"大文字と小文字を区別"
                                                    target:self
                                                    action:@selector(refreshSearchHighlights:)];
    caseSensitive.frame = NSMakeRect(fieldX, 138, 180, 22);
    caseSensitive.state = NSControlStateValueOn;
    [content addSubview:caseSensitive];
    NSButton* wholeWord = [NSButton checkboxWithTitle:@"単語単位"
                                                target:self
                                                action:@selector(refreshSearchHighlights:)];
    wholeWord.frame = NSMakeRect(300, 138, 100, 22);
    [content addSubview:wholeWord];
    NSButton* regularExpression = [NSButton checkboxWithTitle:@"正規表現"
                                                        target:self
                                                        action:@selector(refreshSearchHighlights:)];
    regularExpression.frame = NSMakeRect(410, 138, 110, 22);
    [content addSubview:regularExpression];
    NSButton* cancel = [NSButton buttonWithTitle:@"検索中止" target:self action:@selector(cancelSearchOperations:)];
    cancel.frame = NSMakeRect(16,135,80,26); [content addSubview:cancel];

    NSButton* previousButton = [NSButton buttonWithTitle:@"上検索"
                                                    target:self
                                                    action:@selector(findPrevious:)];
    previousButton.frame = NSMakeRect(16, 66, 84, 28);
    [content addSubview:previousButton];
    NSButton* findButton = [NSButton buttonWithTitle:@"下検索"
                                                target:self
                                                action:@selector(findNext:)];
    findButton.frame = NSMakeRect(106, 66, 84, 28);
    findButton.keyEquivalent = @"\r";
    [content addSubview:findButton];
    NSButton* replaceButton = [NSButton buttonWithTitle:@"置換"
                                                   target:self
                                                   action:@selector(replaceSearchSelection:)];
    replaceButton.frame = NSMakeRect(196, 66, 84, 28);
    [content addSubview:replaceButton];
    NSButton* replaceAllButton = [NSButton buttonWithTitle:@"すべて置換"
                                                      target:self
                                                      action:@selector(replaceAll:)];
    replaceAllButton.frame = NSMakeRect(286, 66, 110, 28);
    [content addSubview:replaceAllButton];
    NSTextField* status = [NSTextField wrappingLabelWithString:@""];
    status.frame = NSMakeRect(16, 8, 634, 44);
    status.textColor = NSColor.secondaryLabelColor;
    [content addSubview:status];

    self.findPanel = panel;
    panel.delegate = self;
    self.findField = findField;
    self.replaceField = replaceField;
    self.caseSensitiveButton = caseSensitive;
    self.wholeWordButton = wholeWord;
    self.regularExpressionButton = regularExpression;
    self.findStatusLabel = status;
    self.searchWrapButton = [NSButton checkboxWithTitle:@"折返し検索" target:self action:@selector(refreshSearchHighlights:)];
    self.searchWrapButton.frame = NSMakeRect(530, 138, 120, 22); [content addSubview:self.searchWrapButton];
    self.searchScopeButton = [NSButton checkboxWithTitle:@"選択範囲内" target:self action:@selector(changeSearchScope:)];
    self.searchScopeButton.frame = NSMakeRect(16, 107, 120, 22); [content addSubview:self.searchScopeButton];
    NSButton* scope = [NSButton buttonWithTitle:@"範囲を再指定" target:self action:@selector(captureSearchScope:)];
    scope.frame = NSMakeRect(140, 104, 130, 28); [content addSubview:scope];
    self.searchScopeLabel = [NSTextField labelWithString:@"文書全体"];
    self.searchScopeLabel.frame = NSMakeRect(282, 107, 368, 22); [content addSubview:self.searchScopeLabel];
    NSButton* count = [NSButton buttonWithTitle:@"一致件数" target:self action:@selector(countSearchMatches:)];
    count.frame = NSMakeRect(404, 66, 104, 28); [content addSubview:count];
    NSButton* clear = [NSButton buttonWithTitle:@"履歴を消去" target:self action:@selector(clearSharedSearchHistory:)];
    clear.frame = NSMakeRect(518, 66, 132, 28); [content addSubview:clear];
    self.replacementHistoryPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(556, 170, 94, 26) pullsDown:YES];
    self.replacementHistoryPopup.target = self; self.replacementHistoryPopup.action = @selector(chooseReplacementHistory:);
    [content addSubview:self.replacementHistoryPopup];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(sharedSearchDidChange:)
        name:SakuraSearchStateDidChangeNotification object:[self searchState]];
    [self loadSharedSearchCriteria];
  }
}

- (void)showFindPanel:(id)sender {
  (void)sender;
  [self prepareFindPanel];
  [self.findPanel makeKeyAndOrderFront:self];
  [self.findPanel makeFirstResponder:self.findField];
}

- (BOOL)hasPendingSearchNavigation {
  return self.searchNavigationProgress != nil || !_searchNavigationRequests.empty();
}
- (void)cancelSearchNavigation {
  [self cancelPreparedReplacement];
  [self.searchNavigationProgress cancel]; self.searchNavigationProgress = nil;
  _searchNavigationRequests.clear(); self.searchNavigationContextKey = nil;
}
- (BOOL)hasPendingReplacement { return self.replacementProgress != nil; }
- (void)cancelPreparedReplacement {
  [self.replacementProgress cancel]; self.replacementProgress = nil;
}
- (NSArray*)navigationSearchKey {
  SakuraDocument* document = self.sakuraDocument;
  NSMutableDictionary* criteria = [[self searchCriteriaDictionary] mutableCopy];
  criteria[@"query"] = [criteria[@"query"] copy];
  criteria[@"replacement"] = [criteria[@"replacement"] copy];
  return @[@(document != nil ? document.documentSession.buffer().revision() : 0),
      [NSValue valueWithNonretainedObject:document], criteria.copy,
      @(self.searchScopeButton.state == NSControlStateValueOn),
      [NSValue valueWithRange:self.searchScopeRange], @(self.searchScopeRevision),
      @(self.searchScopeCaptured), @([self hasMarkedText])];
}
- (BOOL)enqueueSearchNavigationPrevious:(BOOL)previous explicitStart:(NSUInteger)start {
  [self cancelHistoryNavigation:nil];
  [self cancelBracketSearch];
  if (self.sakuraDocument.closingDocument || self.historyWindowClosed) return NO;
  [self cancelPreparedReplacement];
  if ([self hasPendingSearchNavigation] && ![self.searchNavigationContextKey isEqual:[self navigationSearchKey]])
    [self cancelSearchNavigation];
  if (self.sakuraDocument == nil || ![self ensureSearchScope]) { [self cancelSearchNavigation]; return NO; }
  if (!self.findField.stringValue.length) {
    [self cancelSearchNavigation]; [self setFindStatus:@"検索文字列を入力してください。"]; NSBeep(); return NO;
  }
  if (![self publishSearchCriteria:YES replacement:NO]) { [self cancelSearchNavigation]; return NO; }
  try {
    if (![self hasPendingSearchNavigation]) self.searchNavigationContextKey = [self navigationSearchKey];
    _searchNavigationRequests.push_back({previous,start});
    if (self.searchNavigationProgress) {
      [self setFindStatus:[NSString stringWithFormat:@"検索中…（次の操作 %lu 件を待機）", (unsigned long)_searchNavigationRequests.size()]];
    } else [self startNextSearchNavigation];
    return YES;
  } catch (const std::exception&) {
    [self cancelSearchNavigation]; [self setFindStatus:@"検索を開始できませんでした。"]; return NO;
  }
}
- (void)startNextSearchNavigation {
  if (self.searchNavigationProgress) return;
  if (_searchNavigationRequests.empty()) { self.searchNavigationContextKey = nil; return; }
  if (self.sakuraDocument == nil || self.sakuraDocument.closingDocument || self.historyWindowClosed ||
      ![self ensureSearchScope]) { [self cancelSearchNavigation]; return; }
  const auto request = _searchNavigationRequests.front(); _searchNavigationRequests.pop_front();
  try {
    auto options = [self searchOptions];
    NSUInteger start = request.explicitStart;
    if (start == NSNotFound) {
      start = request.previous ? self.committedSelection.location : NSMaxRange(self.committedSelection);
      if (!request.previous && self.hasLastSearchMatch && !self.committedSelection.length &&
          NSEqualRanges(self.committedSelection,self.lastSearchMatchRange) &&
          self.lastSearchRevision == self.sakuraDocument.documentSession.buffer().revision() &&
          self.lastSearchSelectionGeneration == self.selectionGeneration &&
          [self.lastSearchPattern isEqual:self.findField.stringValue] && self.lastSearchFlags == [self searchFlags]) {
        const auto& buffer = self.sakuraDocument.documentSession.buffer();
        const auto limit = options.range ? options.range->location + options.range->length : buffer.length();
        if (start >= limit && !options.wrap) {
          [self setFindStatus:@"範囲の末尾です。見つかりませんでした。"];
          if (_searchNavigationRequests.empty()) self.searchNavigationContextKey = nil;
          else {
            __weak SakuraEditorView* weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf startNextSearchNavigation]; });
          }
          return;
        }
        if (start < limit) { do { ++start; } while (start < limit && !buffer.isEditBoundary(start)); }
        else start = options.range ? options.range->location : 0;
      }
    }
    const auto needle = sakura::platform::mac::sakuraStringFromString(self.findField.stringValue);
    auto snapshot = std::make_shared<const sakura::core::TextBuffer>(self.sakuraDocument.documentSession.buffer());
    NSArray* key = [self navigationSearchKey]; self.searchNavigationContextKey = key;
    NSRange expectedSelection = self.committedSelection;
    const auto generation = self.selectionGeneration;
    NSProgress* progress = [NSProgress progressWithTotalUnitCount:2]; self.searchNavigationProgress = progress;
    options.captureGroups = false; options.regexTimeLimitMilliseconds = 250;
    self.hasLastSearchMatch = NO;
    [self setFindStatus:request.previous ? @"上検索中…" : @"下検索中…"];
    __weak SakuraEditorView* weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
      @autoreleasepool {
        progress.completedUnitCount = 1;
        if (progress.cancelled) { progress.completedUnitCount = 2; return; }
        std::optional<sakura::core::SearchMatch> match;
        BOOL invalid = NO, failed = NO;
        const BOOL ranOnMain = NSThread.isMainThread;
        try {
          auto workerOptions = options;
          const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
          workerOptions.cancelled = [progress,deadline] { return static_cast<bool>(progress.cancelled) || std::chrono::steady_clock::now() > deadline; };
          if (!sakura::core::SearchEngine::isValidPattern(needle,workerOptions)) invalid = YES;
          else if (request.previous) match = sakura::core::SearchEngine{}.findPrevious(*snapshot,needle,start,workerOptions);
          else match = sakura::core::SearchEngine{}.findNext(*snapshot,needle,start,workerOptions);
        } catch (const std::exception&) { failed = YES; }
        progress.completedUnitCount = 2;
        dispatch_async(dispatch_get_main_queue(), ^{
          SakuraEditorView* editor = weakSelf;
          if (editor == nil) return;
          if (editor.searchNavigationProgress != progress) { ++editor->_navigationDiscards; return; }
          if (progress.cancelled || editor.sakuraDocument.closingDocument || editor.historyWindowClosed ||
              ![[editor navigationSearchKey] isEqual:key] ||
              editor.selectionGeneration != generation || !NSEqualRanges(editor.committedSelection,expectedSelection)) {
            ++editor->_navigationDiscards; [editor cancelSearchNavigation];
            [editor setFindStatus:@"本文・条件・選択位置が変更されたため検索を中止しました。"]; return;
          }
          editor.searchNavigationProgress = nil;
          ++editor->_navigationCompletions; editor->_navigationWorkerRanOnMainThread = ranOnMain;
          if (invalid || failed) {
            [editor cancelSearchNavigation];
            [editor setFindStatus:invalid ? @"正規表現が正しくありません。" : @"検索を中止しました（時間・メモリ上限または検索エラー）。"];
            return;
          }
          if (match) {
            editor.applyingSearchNavigation = YES;
            [editor clearRectangularSelection]; [editor recordNavigationToOffset:match->range.location];
            editor.committedSelection = NSMakeRange(match->range.location,match->range.length);
            editor.applyingSearchNavigation = NO;
            [editor rememberSearchSelection]; editor.searchMarksHidden = NO;
            [editor setFindStatus:@"検索文字列を選択しました。"];
            [editor setNeedsDisplay:YES]; [editor scrollSelectionToVisible];
          } else { [editor setFindStatus:@"見つかりませんでした。"]; NSBeep(); }
          [editor startNextSearchNavigation];
        });
      }
    });
  } catch (const std::exception&) {
    [self cancelSearchNavigation]; [self setFindStatus:@"検索を開始できませんでした。"];
  }
}
- (BOOL)selectNextSearchMatchFrom:(NSUInteger)start {
  return [self enqueueSearchNavigationPrevious:NO explicitStart:start];
}
- (void)findNext:(id)sender {
  (void)sender;
  if (self.findPanel == nil) {
    [self prepareFindPanel];
    if (!self.findField.stringValue.length) { [self showFindPanel:self]; return; }
  }
  if ([self hasMarkedText]) [self unmarkText];
  [self enqueueSearchNavigationPrevious:NO explicitStart:NSNotFound];
}
- (void)findPrevious:(id)sender {
  (void)sender;
  if (self.findPanel == nil) {
    [self prepareFindPanel];
    if (!self.findField.stringValue.length) { [self showFindPanel:self]; return; }
  }
  if ([self hasMarkedText]) [self unmarkText];
  [self enqueueSearchNavigationPrevious:YES explicitStart:NSNotFound];
}
- (void)cancelSearchOperations:(id)sender {
  (void)sender;
  [self cancelHistoryNavigation:nil];
  [self cancelBracketSearch];
  [self cancelSearchNavigation]; [self cancelSearchHighlights];
  [self.searchCountProgress cancel]; self.searchCountProgress = nil;
  self.searchMarksHidden = YES;
  [self setFindStatus:@"検索処理を中止しました。"]; [self setNeedsDisplay:YES];
}
- (void)windowWillClose:(NSNotification*)notification {
  if (notification.object == self.findPanel) [self cancelSearchOperations:nil];
}

- (void)clearSearchMarks:(id)sender {
  (void)sender;
  [self cancelSearchNavigation];
  [self cancelSearchHighlights];
  self.searchMarksHidden = YES;
  [self setFindStatus:@"検索マークを解除しました。"];
  [self setNeedsDisplay:YES];
}

- (void)replaceSearchSelection:(id)sender {
  (void)sender;
  [self cancelPreparedReplacement];
  if ([self hasPendingSearchNavigation]) {
    [self setFindStatus:@"検索中です。完了後に置換を実行してください。"]; return;
  }
  [self prepareSearchReplacementAll:NO];
}

- (void)replaceAll:(id)sender {
  (void)sender;
  [self cancelSearchNavigation];
  [self prepareSearchReplacementAll:YES];
}

- (void)prepareSearchReplacementAll:(BOOL)all {
  [self cancelHistoryNavigation:nil];
  [self cancelBracketSearch];
  if (self.sakuraDocument.closingDocument || self.historyWindowClosed) return;
  if (self.findPanel == nil) {
    [self showFindPanel:self];
    return;
  }
  if (self.findField.stringValue.length == 0) {
    [self setFindStatus:@"検索文字列を入力してください。"];
    NSBeep();
    return;
  }
  if ([self hasMarkedText]) {
    [self unmarkText];
  }
  try {
    if (self.sakuraDocument == nil || ![self ensureSearchScope]) return;
    // Publishing history can notify peer panes. Freeze the final criteria only
    // after that notification, before taking the immutable edit snapshot.
    if (![self publishSearchCriteria:YES replacement:YES]) return;
    const auto needle = sakura::platform::mac::sakuraStringFromString(
        self.findField.stringValue);
    const auto replacement = sakura::platform::mac::sakuraStringFromString(
        self.replaceField.stringValue);
    auto options = [self searchOptions]; options.maxReplacementCodeUnits = (all ? 128 : 64) * 1024 * 1024;
    auto layouts = std::make_shared<std::vector<ReplacementViewLayout>>();
    BOOL paneCompositionAtStart = NO;
    for (SakuraEditorView* view in [self replacementAffectedViews]) {
      if (view.sakuraDocument != self.sakuraDocument) {
        [self setFindStatus:@"ペインの文書が変わったため置換を中止しました。"];
        return;
      }
      if (view.hasMarkedText) {
        if (all) {
          [self setFindStatus:@"別のペインでIME入力中です。未確定文字を確定してから置換してください。"];
          return;
        }
        paneCompositionAtStart = YES;
      }
      layouts->push_back([view captureReplacementLayout]);
    }
    const auto snapshot = std::make_shared<const sakura::core::EditEngine::Snapshot>(
        self.sakuraDocument.documentSession.editSnapshot());
    NSArray* key = [self navigationSearchKey];
    const NSRange expectedSelection = self.committedSelection;
    const auto selectionGeneration = self.selectionGeneration;
    NSProgress* progress = [NSProgress progressWithTotalUnitCount:1];
    self.replacementProgress = progress;
    [self setFindStatus:all ? @"全置換を準備しています…（検索中止／⌘.で中止）" : @"置換を準備しています…（検索中止／⌘.で中止）"];
    auto payload = std::make_shared<std::unique_ptr<sakura::app::PreparedSearchReplacement>>();
    __weak SakuraEditorView* weakSelf = self;
    dispatch_async(replacementPreparationQueue(), ^{
      @autoreleasepool {
        NSString* error = nil;
        const BOOL ranOnMain = NSThread.isMainThread;
        try {
          auto workerOptions = options;
          const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
          workerOptions.regexTimeLimitMilliseconds = 250;
          workerOptions.cancelled = [progress, deadline] {
            return static_cast<bool>(progress.cancelled) || std::chrono::steady_clock::now() > deadline;
          };
          if (progress.cancelled) throw std::runtime_error("replacement cancelled before start");
          *payload = std::make_unique<sakura::app::PreparedSearchReplacement>(all
              ? sakura::app::DocumentSession::prepareReplaceAll(*snapshot, needle, replacement, workerOptions)
              : sakura::app::DocumentSession::prepareSingleReplacement(*snapshot,
                  {expectedSelection.location,expectedSelection.length},needle,replacement,workerOptions));
          if ((*payload)->result.valid && (*payload)->result.changed && paneCompositionAtStart)
            error = @"別のペインでIME入力中です。未確定文字を確定してから置換してください。";
          if (error == nil && (*payload)->result.valid && (*payload)->result.changed) {
            for (auto& work : *layouts) {
              if (workerOptions.cancelled()) throw std::runtime_error("replacement layout cancelled");
              sakura::platform::mac::CoreTextMetrics metrics(work.fontName, work.pointSize, work.characterSpacing);
              const sakura::core::FontStyle style{0, work.pointSize, 400, false};
              float wrap = 0;
              if (work.wrapMode == SakuraEditorWrapModeWindow)
                wrap = std::max(1.0F, static_cast<float>(work.viewportWidth - kGutterWidth - 2 * kHorizontalInset));
              else if (work.wrapMode == SakuraEditorWrapModeColumn)
                wrap = metrics.advance(u' ', style) * work.wrapColumn;
              work.layout.update((*payload)->edit.resultingBuffer(), metrics, style,
                  {.wrapWidth = wrap, .tabWidth = static_cast<sakura::core::TextOffset>(work.tabWidth)},
                  work.metricsRevision, workerOptions.cancelled);
            }
          }
        } catch (const std::exception&) {
          error = @"置換を中止しました（時間・件数・文字数上限、検索／置換エラー）。本文は変更していません。";
        }
        dispatch_async(dispatch_get_main_queue(), ^{
          SakuraEditorView* editor = weakSelf;
          BOOL textApplied = NO, editNotified = NO;
          const auto callbackStarted = std::chrono::steady_clock::now();
          try {
          if (editor != nil) {
            editor->_replacementWorkerRanOnMainThread = ranOnMain;
            bool current = editor.replacementProgress == progress && !progress.cancelled &&
                editor.sakuraDocument != nil && !editor.sakuraDocument.closingDocument &&
                !editor.historyWindowClosed && editor.selectionGeneration == selectionGeneration &&
                NSEqualRanges(editor.committedSelection,expectedSelection) &&
                [[editor navigationSearchKey] isEqual:key];
            const bool requiresLayouts = error == nil && *payload && (*payload)->result.valid && (*payload)->result.changed;
            NSArray<SakuraEditorView*>* currentViews = current && requiresLayouts ? [editor replacementAffectedViews] : nil;
            if (requiresLayouts) current = current && currentViews.count == layouts->size();
            if (current && requiresLayouts) for (const auto& work : *layouts) {
              SakuraEditorView* view = work.view;
              if (view == nil || view.sakuraDocument != editor.sakuraDocument || ![currentViews containsObject:view] || view.hasMarkedText ||
                  ![[view layoutConfigurationKey] isEqual:work.key]) { current = false; break; }
            }
            if (!current) {
              ++editor->_replacementDiscards;
              if (editor.replacementProgress == progress) {
                editor.replacementProgress = nil;
                [editor setFindStatus:@"本文・検索条件・選択位置・ペインの表示設定が変わったため置換を中止しました。"];
              }
            } else {
              editor.replacementProgress = nil;
              auto* prepared = payload->get();
              if (error != nil || prepared == nullptr) [editor setFindStatus:error != nil ? error : @"置換を準備できませんでした。"];
              else if (!prepared->result.valid) [editor setFindStatus:@"正規表現または置換文字列が正しくありません。"];
              else if (!editor.sakuraDocument.documentSession.commitPreparedReplacement(*prepared))
                [editor setFindStatus:@"本文または編集履歴が変わったため置換を中止しました。"];
              else {
                ++editor->_replacementCompletions;
                const auto result = prepared->result;
                textApplied = result.changed;
                BOOL scopeInvalidated = NO;
                if (!all && prepared->selectionAfter) {
                  [editor clearRectangularSelection];
                  editor.committedSelection = NSMakeRange(prepared->selectionAfter->location,prepared->selectionAfter->length);
                }
                if (!result.replacements) {
                  if (!all && prepared->fallbackSelection) {
                    const auto range = *prepared->fallbackSelection;
                    [editor clearRectangularSelection]; [editor recordNavigationToOffset:range.location];
                    editor.committedSelection = NSMakeRange(range.location,range.length);
                    [editor rememberSearchSelection]; editor.searchMarksHidden = NO;
                    [editor setFindStatus:@"検索文字列を選択しました。"];
                    [editor setNeedsDisplay:YES]; [editor scrollSelectionToVisible];
                  } else [editor setFindStatus:@"見つかりませんでした。"];
                }
                else if (!result.changed)
                  [editor setFindStatus:[NSString stringWithFormat:@"%zu 件の置換対象がありました（本文の変更なし）。", result.replacements]];
                else {
                  textApplied = YES;
                  const auto adoptStarted = std::chrono::steady_clock::now();
                  for (auto& work : *layouts) {
                    SakuraEditorView* view = work.view;
                    if (view != nil && work.layout.matchesText(editor.sakuraDocument.documentSession.buffer()))
                      [view adoptReplacementLayout:work];
                  }
                  editor->_replacementAdoptMilliseconds = std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-adoptStarted).count();
                  if (result.resultingRange) {
                    const auto& buffer = editor.sakuraDocument.documentSession.buffer();
                    editor.searchScopeRange = NSMakeRange(result.resultingRange->location, result.resultingRange->length);
                    editor.searchScopeRevision = buffer.revision();
                    if (!buffer.isEditBoundary(result.resultingRange->location) ||
                        !buffer.isEditBoundary(result.resultingRange->location + result.resultingRange->length)) {
                      editor.searchScopeCaptured = NO; scopeInvalidated = YES;
                    }
                    if (all) editor.committedSelection = [editor rangeByExpandingToEditBoundaries:editor.searchScopeRange];
                  } else if (all) editor.committedSelection = NSMakeRange(0, 0);
                  editNotified = YES;
                  [editor.sakuraDocument noteEditorChange:NSChangeDone];
                  const auto refreshStarted = std::chrono::steady_clock::now();
                  [editor.sakuraDocument refreshEditorViews];
                  editor->_replacementRefreshMilliseconds = std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-refreshStarted).count();
                  [editor setFindStatus:[NSString stringWithFormat:@"%zu 件置換しました。%@", result.replacements,
                      scopeInvalidated ? @"検索範囲は境界が変わったため再指定してください。" : @""]];
                }
                if (!all && result.replacements) {
                  [editor setNeedsDisplay:YES]; [editor scrollSelectionToVisible];
                  if (!scopeInvalidated && prepared->nextSearchStart)
                    [editor selectNextSearchMatchFrom:*prepared->nextSearchStart];
                }
              }
            }
          }
          } catch (const std::exception&) {
            if (editor != nil) {
              editor.replacementProgress = nil;
              if (textApplied && !editNotified) [editor.sakuraDocument noteEditorChange:NSChangeDone];
              [editor setFindStatus:textApplied
                  ? @"置換は反映済みですが画面更新に失敗しました。Undoで戻せます。"
                  : @"置換を反映できませんでした。本文は変更していません。"];
            }
          }
          if (editor != nil)
            editor->_replacementMainMilliseconds = std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-callbackStarted).count();
          // Prepared/retired roots and redo history may be large. Release their
          // owning unique_ptr on the serial worker, not at this main callback's end.
          dispatch_async(replacementPreparationQueue(), ^{ payload->reset(); layouts->clear(); });
        });
      }
    });
  } catch (const std::exception&) {
    [self setFindStatus:@"置換できませんでした。"];
    NSBeep();
  }
}

- (void)mouseDown:(NSEvent*)event {
  [self.window makeFirstResponder:self];
  if ([self hasMarkedText]) {
    [self unmarkText];
  }
  const NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  const NSUInteger index = [self safeNavigationOffset:
      [self displayIndexForLocalPoint:point]];
  self.draggingWholeWords = NO;
  if ((event.modifierFlags & NSEventModifierFlagOption) != 0) {
    self.rectangularSelectionActive = YES;
    self.rectangularAnchorPoint = point;
    self.rectangularCurrentPoint = point;
    self.committedSelection = NSMakeRange(index, 0);
  } else if ((event.modifierFlags & NSEventModifierFlagShift) != 0) {
    [self clearRectangularSelection];
    const NSUInteger anchor = self.navigationAnchor != NSNotFound
        ? self.navigationAnchor : self.committedSelection.location;
    [self moveSelectionToOffset:index modifyingSelection:YES
         preservingHorizontalPosition:NO];
    self.dragAnchor = anchor;
  } else if (event.clickCount >= 2) {
    [self clearRectangularSelection];
    NSRange selection = [self wordRangeAtNavigationOffset:index];
    if (event.clickCount >= 3) {
      NSString* text = [self committedString];
      selection = [text lineRangeForRange:NSMakeRange(index, 0)];
    }
    self.committedSelection = selection;
    self.navigationAnchor = selection.location;
    self.navigationCaret = NSMaxRange(selection);
    self.dragAnchor = selection.location;
    self.dragInitialSelection = selection;
    self.draggingWholeWords = YES;
  } else {
    [self clearRectangularSelection];
    self.committedSelection = NSMakeRange(index, 0);
    self.dragAnchor = index;
  }
  self.draggingSelection = YES;
  [self setNeedsDisplay:YES];
}

- (void)mouseDragged:(NSEvent*)event {
  if (!self.draggingSelection) {
    return;
  }
  const NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  if (self.rectangularSelectionActive) {
    self.rectangularCurrentPoint = point;
    [self updateRectangularSelection];
    return;
  }
  NSUInteger index = [self safeNavigationOffset:
      [self displayIndexForLocalPoint:point]];
  if (self.draggingWholeWords) {
    const NSRange word = [self wordRangeAtNavigationOffset:index];
    if (index < self.dragInitialSelection.location) {
      self.dragAnchor = NSMaxRange(self.dragInitialSelection);
      index = word.location;
    } else {
      self.dragAnchor = self.dragInitialSelection.location;
      index = std::max(NSMaxRange(self.dragInitialSelection), NSMaxRange(word));
    }
  }
  self.navigationAnchor = self.dragAnchor;
  [self moveSelectionToOffset:index modifyingSelection:YES
       preservingHorizontalPosition:NO];
}

- (void)mouseUp:(NSEvent*)event {
  (void)event;
  self.draggingSelection = NO;
  self.draggingWholeWords = NO;
  if (self.rectangularSelectionActive && ![self hasRectangularSelection]) {
    const NSUInteger index = [self displayIndexForLocalPoint:
        self.rectangularCurrentPoint];
    [self clearRectangularSelection];
    self.committedSelection = NSMakeRange(index, 0);
    [self setNeedsDisplay:YES];
  }
}

- (void)keyDown:(NSEvent*)event {
  if (![[self inputContext] handleEvent:event]) {
    [super keyDown:event];
  }
}

#pragma mark - NSTextInputClient

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
  NSString* inserted = plainString(string);
  if (self.rectangularSelectionActive && ![self hasMarkedText] &&
      replacementRange.location == NSNotFound) {
    [self replaceRectangularSelectionWithStrings:@[ inserted ]];
    return;
  }
  NSRange range = replacementRange.location == NSNotFound
                      ? ([self hasMarkedText]
                             ? self.markedReplacementRangeStorage
                             : self.committedSelection)
                      : [self committedRangeForDisplayRange:replacementRange];
  [self clearMarkedState];
  [self replaceCommittedRange:range withString:inserted];
}

- (void)setMarkedText:(id)string
         selectedRange:(NSRange)selectedRange
       replacementRange:(NSRange)replacementRange {
  [self cancelBracketSearchesForDocument];
  for (SakuraEditorView* view in [self replacementAffectedViews]) {
    if (view.hasPendingHistoryNavigation) {
      [view cancelHistoryNavigation:nil];
      [view setFindStatus:@"IME入力が始まったためUndo／Redoを中止しました。"];
    }
  }
  if ([self hasPendingSearchNavigation] || [self hasPendingReplacement]) {
    [self cancelSearchNavigation]; [self setFindStatus:@"IME入力が始まったため検索を中止しました。"];
  }
  if (self.rectangularSelectionActive) {
    const NSUInteger index = [self displayIndexForLocalPoint:
        self.rectangularCurrentPoint];
    [self clearRectangularSelection];
    self.committedSelection = NSMakeRange(index, 0);
  }
  NSString* markedString = plainString(string);
  if (markedString.length == 0) {
    [self clearMarkedState];
    [self updateDocumentViewSize];
    [self setNeedsDisplay:YES];
    return;
  }

  NSRange replacement = self.committedSelection;
  if ([self hasMarkedText]) {
    replacement = self.markedReplacementRangeStorage;
  }
  if (replacementRange.location != NSNotFound) {
    replacement = [self committedRangeForDisplayRange:replacementRange];
  }

  NSDictionary* attributes = [string isKindOfClass:[NSAttributedString class]]
                                 ? nil
                                 : [self baseTextAttributes];
  self.markedTextStorage = [string isKindOfClass:[NSAttributedString class]]
                               ? [(NSAttributedString*)string copy]
                               : [[NSAttributedString alloc]
                                     initWithString:markedString
                                         attributes:attributes];
  self.markedReplacementRangeStorage = replacement;
  self.markedSelectionStorage = clampedRange(selectedRange, markedString.length);
  [self updateDocumentViewSize];
  [self setNeedsDisplay:YES];
  [self scrollSelectionToVisible];
}

- (void)unmarkText {
  if (![self hasMarkedText]) {
    return;
  }
  NSString* committedMarkedText = self.markedTextStorage.string;
  const NSRange replacement = self.markedReplacementRangeStorage;
  [self clearMarkedState];
  [self replaceCommittedRange:replacement withString:committedMarkedText];
}

- (BOOL)hasMarkedText {
  return self.markedTextStorage != nil;
}

- (NSRange)markedRange {
  if (![self hasMarkedText]) {
    return NSMakeRange(NSNotFound, 0);
  }
  return NSMakeRange(self.markedReplacementRangeStorage.location,
                     self.markedTextStorage.length);
}

- (NSRange)selectedRange {
  return [self displaySelection];
}

- (NSArray<NSAttributedStringKey>*)validAttributesForMarkedText {
  return @[ NSUnderlineStyleAttributeName, NSUnderlineColorAttributeName ];
}

- (NSAttributedString*)attributedSubstringForProposedRange:(NSRange)range
                                                actualRange:(NSRangePointer)actualRange {
  NSString* display = [self displayString];
  const NSRange actual = clampedRange(range, display.length);
  if (actualRange != nullptr) {
    *actualRange = actual;
  }
  return [[NSAttributedString alloc]
      initWithString:[display substringWithRange:actual]
          attributes:[self baseTextAttributes]];
}

- (NSRect)firstRectForCharacterRange:(NSRange)range
                           actualRange:(NSRangePointer)actualRange {
  NSString* display = [self displayString];
  NSRange actual = clampedRange(range, display.length);
  const auto& rows = [self displayLineRanges];
  NSUInteger rowIndex = lineIndexContainingCharacter(
      rows, actual.location, &_lineLookupSteps);
  // A nonempty character range at a soft-wrap boundary belongs downstream.
  // A zero-length caret query retains the editor's preceding-row affinity.
  if (actual.length != 0 && rowIndex + 1 < rows.size() &&
      rows[rowIndex + 1].location == actual.location) ++rowIndex;
  const NSRange row = rows[rowIndex];
  // A candidate window needs the rectangle of the first visual fragment,
  // not a range claiming to cover subsequent wrapped rows with a caret box.
  actual.length = actual.location <= NSMaxRange(row)
      ? std::min(actual.length, NSMaxRange(row) - actual.location) : 0;
  if (actualRange != nullptr) {
    *actualRange = actual;
  }
  NSAttributedString* rowText = [[NSAttributedString alloc]
      initWithString:[display substringWithRange:row]
          attributes:[self baseTextAttributes]];
  CTLineRef line = CTLineCreateWithAttributedString(
      (__bridge CFAttributedStringRef)rowText);
  const NSUInteger start = std::min(actual.location - row.location, row.length);
  const CGFloat left = offsetForIndex(line, start);
  const CGFloat right = offsetForIndex(line, start + actual.length);
  CFRelease(line);
  const CGFloat height = [self editorLineHeight];
  NSRect local = NSMakeRect(kTextOriginX + left,
      kVerticalInset + rowIndex * height, std::max<CGFloat>(1.0, right - left), height);
  NSRect windowRect = [self convertRect:local toView:nil];
  return self.window != nil ? [self.window convertRectToScreen:windowRect]
                            : NSZeroRect;
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point {
  if (self.window == nil) {
    return NSNotFound;
  }
  const NSPoint windowPoint = [self.window convertPointFromScreen:point];
  const NSPoint localPoint = [self convertPoint:windowPoint fromView:nil];
  return [self displayIndexForLocalPoint:localPoint];
}

- (NSInteger)conversationIdentifier {
  return reinterpret_cast<NSInteger>((__bridge void*)self);
}

- (NSWindowLevel)windowLevel {
  return self.window.level;
}

- (BOOL)drawsVerticallyForCharacterAtIndex:(NSUInteger)charIndex {
  (void)charIndex;
  return NO;
}

- (CGFloat)fractionOfDistanceThroughGlyphForPoint:(NSPoint)point {
  (void)point;
  return 0.0;
}

- (void)doCommandBySelector:(SEL)selector {
  if (![self tryToPerform:selector with:self]) {
    NSBeep();
  }
}

#pragma mark - Editing commands

- (void)insertNewline:(id)sender {
  (void)sender;
  [self insertText:[self.sakuraDocument newlineInsertionString]
  replacementRange:NSMakeRange(NSNotFound, 0)];
}

- (void)insertTab:(id)sender {
  if (!self.hasMarkedText && !self.hasRectangularSelection && self.committedSelection.length) {
    [self indentWithTab:sender];
    return;
  }
  [self insertText:@"\t" replacementRange:NSMakeRange(NSNotFound, 0)];
}

- (void)insertBacktab:(id)sender { [self unindentWithTab:sender]; }

- (void)deleteBackward:(id)sender {
  (void)sender;
  if ([self hasMarkedText]) {
    [self clearMarkedState];
    [self setNeedsDisplay:YES];
    return;
  }
  if ([self hasRectangularSelection]) {
    [self replaceRectangularSelectionWithStrings:@[ @"" ]];
    return;
  }
  if (self.committedSelection.length != 0) {
    [self replaceCommittedRange:
              [self rangeByExpandingToEditBoundaries:self.committedSelection]
                      withString:@""];
    return;
  }
  if (self.committedSelection.location == 0) {
    return;
  }
  NSString* text = [self committedString];
  const NSRange previous = [self rangeByExpandingToEditBoundaries:
      [text rangeOfComposedCharacterSequenceAtIndex:
          self.committedSelection.location - 1]];
  [self replaceCommittedRange:previous withString:@""];
}

- (void)deleteForward:(id)sender {
  (void)sender;
  if ([self hasMarkedText]) {
    [self clearMarkedState];
    [self setNeedsDisplay:YES];
    return;
  }
  if ([self hasRectangularSelection]) {
    [self replaceRectangularSelectionWithStrings:@[ @"" ]];
    return;
  }
  if (self.committedSelection.length != 0) {
    [self replaceCommittedRange:
              [self rangeByExpandingToEditBoundaries:self.committedSelection]
                      withString:@""];
    return;
  }
  NSString* text = [self committedString];
  if (self.committedSelection.location >= text.length) {
    return;
  }
  const NSRange next = [self rangeByExpandingToEditBoundaries:
      [text rangeOfComposedCharacterSequenceAtIndex:
          self.committedSelection.location]];
  [self replaceCommittedRange:next withString:@""];
}

- (void)delete:(id)sender {
  [self deleteForward:sender];
}

- (void)copy:(id)sender {
  (void)sender;
  if ([self hasMarkedText]) {
    [self unmarkText];
  }
  if ([self hasRectangularSelection]) {
    NSMutableArray<NSString*>* rows = [NSMutableArray array];
    NSString* text = [self committedString];
    for (NSDictionary* selection in [self rectangularSelections]) {
      NSMutableString* row = [[text substringWithRange:
          [selection[@"committedRange"] rangeValue]] mutableCopy];
      const NSUInteger trailingSpaces =
          [selection[@"trailingVirtualSpaces"] unsignedIntegerValue];
      if (trailingSpaces != 0) {
        [row appendString:[@"" stringByPaddingToLength:trailingSpaces
                                           withString:@" "
                                      startingAtIndex:0]];
      }
      [rows addObject:row];
    }
    NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    [pasteboard writeObjects:@[ [rows componentsJoinedByString:@"\n"] ]];
    return;
  }
  if (self.committedSelection.length == 0) {
    return;
  }
  NSString* selected = [[self committedString]
      substringWithRange:self.committedSelection];
  NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
  [pasteboard clearContents];
  [pasteboard writeObjects:@[ selected ]];
}

- (void)cut:(id)sender {
  if ([self hasRectangularSelection]) {
    [self copy:sender];
    [self replaceRectangularSelectionWithStrings:@[ @"" ]];
    return;
  }
  [self copy:sender];
  if (self.committedSelection.length != 0) {
    [self replaceCommittedRange:
              [self rangeByExpandingToEditBoundaries:self.committedSelection]
                      withString:@""];
  }
}

- (void)paste:(id)sender {
  (void)sender;
  NSString* pasted = [[NSPasteboard generalPasteboard]
      stringForType:NSPasteboardTypeString];
  if (pasted != nil) {
    if (self.rectangularSelectionActive) {
      NSString* normalized = [pasted
          stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
      normalized = [normalized stringByReplacingOccurrencesOfString:@"\r"
                                                          withString:@"\n"];
      NSArray<NSString*>* lines = [normalized componentsSeparatedByString:@"\n"];
      NSArray<NSValue*>* ranges = [self rectangularCommittedRanges];
      if (lines.count > 1 && ranges.count != 0) {
        NSMutableArray<NSString*>* mapped = [NSMutableArray array];
        for (NSUInteger index = 0; index < ranges.count; ++index) {
          [mapped addObject:index < lines.count ? lines[index] : @""];
        }
        [self replaceRectangularSelectionWithStrings:mapped];
      } else {
        [self replaceRectangularSelectionWithStrings:@[ pasted ]];
      }
      return;
    }
    [self insertText:pasted replacementRange:NSMakeRange(NSNotFound, 0)];
  }
}

- (void)selectAll:(id)sender {
  (void)sender;
  if ([self hasMarkedText]) {
    [self unmarkText];
  }
  [self clearRectangularSelection];
  self.committedSelection = NSMakeRange(0, [self committedString].length);
  [self setNeedsDisplay:YES];
}

- (void)convertSelectionToUppercase:(id)sender {
  (void)sender;
  if ([self hasMarkedText]) {
    [self unmarkText];
  }
  if ([self hasRectangularSelection]) {
    NSMutableArray<NSString*>* rows = [NSMutableArray array];
    NSString* text = [self committedString];
    for (NSValue* value in [self rectangularCommittedRanges]) {
      [rows addObject:[text substringWithRange:value.rangeValue].uppercaseString];
    }
    [self replaceRectangularSelectionWithStrings:rows];
    return;
  }
  if (self.committedSelection.length == 0) {
    return;
  }
  NSString* selected = [[self committedString]
      substringWithRange:self.committedSelection];
  [self replaceCommittedRange:self.committedSelection
                   withString:selected.uppercaseString];
}

- (void)convertSelectionToLowercase:(id)sender {
  (void)sender;
  if ([self hasMarkedText]) {
    [self unmarkText];
  }
  if ([self hasRectangularSelection]) {
    NSMutableArray<NSString*>* rows = [NSMutableArray array];
    NSString* text = [self committedString];
    for (NSValue* value in [self rectangularCommittedRanges]) {
      [rows addObject:[text substringWithRange:value.rangeValue].lowercaseString];
    }
    [self replaceRectangularSelectionWithStrings:rows];
    return;
  }
  if (self.committedSelection.length == 0) {
    return;
  }
  NSString* selected = [[self committedString]
      substringWithRange:self.committedSelection];
  [self replaceCommittedRange:self.committedSelection
                   withString:selected.lowercaseString];
}

- (void)undo:(id)sender {
  (void)sender;
  [self enqueueHistoryDirection:sakura::core::EditEngine::HistoryDirection::undo];
}

- (void)redo:(id)sender {
  (void)sender;
  [self enqueueHistoryDirection:sakura::core::EditEngine::HistoryDirection::redo];
}

- (BOOL)hasPendingHistoryNavigation {
  return self.historyProgress != nil || !_historyRequests.empty();
}
- (void)cancelHistoryNavigation:(id)sender {
  (void)sender;
  ++_historyCancellationGeneration;
  [self.historyProgress cancel]; self.historyProgress = nil;
  _historyRequests.clear();
}
- (void)enqueueHistoryDirection:(sakura::core::EditEngine::HistoryDirection)direction {
  [self cancelSearchNavigation]; // Also cancels a prepared replacement, even with no usable history.
  [self cancelBracketSearch];
  [self.searchCountProgress cancel]; self.searchCountProgress = nil;
  [self cancelSearchHighlights];
  SakuraDocument* document = self.sakuraDocument;
  if (!document || document.closingDocument || self.historyWindowClosed) return;
  for (SakuraEditorView* view in [self replacementAffectedViews]) {
    if (view != self && view.hasMarkedText) {
      [self setFindStatus:@"別のペインでIME入力中です。確定してからUndo／Redoを実行してください。"];
      return;
    }
  }
  if (_historyRequests.size() >= 256) {
    [self setFindStatus:@"Undo／Redoの待機上限です。完了後に再操作してください。"];
    return;
  }
  [self clearMarkedState]; [self clearRectangularSelection];
  _historyRequests.push_back(direction);
  [self startNextHistoryNavigation];
}

- (void)startNextHistoryNavigation {
  NSProgress* startingProgress = nil;
  const auto cancellationGenerationAtStart = _historyCancellationGeneration;
  auto failToStart = [&] {
    [startingProgress cancel];
    // A capture/status callback may cancel this request and start a new one.
    // Retire only this invocation, not that newer request or its status.
    if (_historyCancellationGeneration != cancellationGenerationAtStart ||
        (self.historyProgress && self.historyProgress != startingProgress)) return;
    [self cancelHistoryNavigation:nil];
    @try {
      try { [self setFindStatus:@"Undo／Redoを開始できませんでした。本文と履歴は変更していません。"]; }
      catch (...) {}
    } @catch (NSException* statusException) { (void)statusException; }
  };
  @try {
  if (self.historyProgress || self.applyingHistoryTransition || _historyRequests.empty()) return;
  SakuraDocument* document = self.sakuraDocument;
  if (!document || document.closingDocument || self.historyWindowClosed) {
    [self cancelHistoryNavigation:nil]; return;
  }
  using Direction = sakura::core::EditEngine::HistoryDirection;
  bool skipped = false;
  while (!_historyRequests.empty()) {
    const auto direction = _historyRequests.front();
    if (direction == Direction::undo ? document.documentSession.canUndo() : document.documentSession.canRedo()) break;
    _historyRequests.pop_front(); skipped = true;
  }
  if (_historyRequests.empty()) {
    if (skipped) [self setFindStatus:@"対象のUndo／Redo履歴がありません。"];
    return;
  }
  try {
    const auto direction = _historyRequests.front();
    const auto gate = [self historyWorkGate];
    const auto seconds = [self historyPreparationTimeLimit];
    if (!std::isfinite(seconds) || seconds <= 0 || seconds > 60)
      throw std::invalid_argument("invalid history time limit");
    auto layouts = std::make_shared<std::vector<ReplacementViewLayout>>();
    for (SakuraEditorView* view in [self replacementAffectedViews]) {
      if (view.sakuraDocument != document) {
        [self cancelHistoryNavigation:nil];
        [self setFindStatus:@"ペインの文書が変わったためUndo／Redoを中止しました。"];
        return;
      }
      if (view.hasMarkedText) {
        [self cancelHistoryNavigation:nil];
        [self setFindStatus:@"IME入力中のためUndo／Redoを中止しました。"];
        return;
      }
      layouts->push_back([view captureReplacementLayout]);
    }
    const auto source = std::make_shared<const sakura::core::EditEngine::HistorySnapshot>(
        document.documentSession.historySnapshot());
    const auto selectionGeneration = self.selectionGeneration;
    const NSRange expectedSelection = self.committedSelection;
    __weak NSWindow* expectedWindow = self.window;
    const BOOL hadWindow = self.window != nil;
    __weak SakuraDocument* expectedDocument = document;
    NSProgress* progress = [NSProgress progressWithTotalUnitCount:1];
    if (self.historyProgress || _historyCancellationGeneration != cancellationGenerationAtStart) return;
    startingProgress = progress;
    self.historyProgress = progress;
    [self setFindStatus:direction == Direction::undo
        ? @"元に戻す準備中…（⌘.／Escapeで中止）" : @"やり直す準備中…（⌘.／Escapeで中止）"];
    auto payload = std::make_shared<std::unique_ptr<sakura::core::EditEngine::PreparedHistory>>();
    __weak SakuraEditorView* weakSelf = self;
    dispatch_async(replacementPreparationQueue(), ^{
      @autoreleasepool {
        NSString* error = nil;
        const BOOL ranOnMain = NSThread.isMainThread;
        @try {
          try {
            const auto deadline = std::chrono::steady_clock::now()+
                std::chrono::duration_cast<std::chrono::steady_clock::duration>(std::chrono::duration<double>(seconds));
            if (gate) gate();
            const std::function<bool()> cancelled = [progress,deadline] {
              return progress.cancelled || std::chrono::steady_clock::now()>=deadline;
            };
            *payload = std::make_unique<sakura::core::EditEngine::PreparedHistory>(
                sakura::app::DocumentSession::prepareHistory(*source,direction,cancelled));
            if ((*payload)->hasChanges()) for (auto& work : *layouts) {
              if (cancelled()) throw std::runtime_error("history layout cancelled");
              sakura::platform::mac::CoreTextMetrics metrics(work.fontName,work.pointSize,work.characterSpacing);
              const sakura::core::FontStyle style{0,work.pointSize,400,false};
              float wrap = 0;
              if (work.wrapMode == SakuraEditorWrapModeWindow)
                wrap = std::max(1.0F,static_cast<float>(work.viewportWidth-kGutterWidth-2*kHorizontalInset));
              else if (work.wrapMode == SakuraEditorWrapModeColumn)
                wrap = metrics.advance(u' ',style)*work.wrapColumn;
              work.layout.update((*payload)->resultingBuffer(),metrics,style,
                  {.wrapWidth=wrap,.tabWidth=static_cast<sakura::core::TextOffset>(work.tabWidth)},
                  work.metricsRevision,cancelled);
            }
          } catch (const std::exception&) {
            error = @"Undo／Redoを中止しました（時間上限・表示準備エラー）。本文と履歴は変更していません。";
          }
        } @catch (NSException* exception) {
          (void)exception;
          error = @"Undo／Redoの表示を準備できませんでした。本文と履歴は変更していません。";
        }
        dispatch_async(dispatch_get_main_queue(), ^{
          SakuraEditorView* editor = weakSelf;
          const auto callbackStarted = std::chrono::steady_clock::now();
          SakuraDocument* liveDocument = expectedDocument;
          BOOL applied = NO, notified = NO, continueQueue = NO;
          auto reportFailure = [&] {
            if (!editor) return;
            [editor cancelHistoryNavigation:nil];
            editor.applyingHistoryTransition = NO;
            if (applied && !notified) {
              notified = YES;
              [liveDocument noteEditorChange:direction == Direction::undo ? NSChangeUndone : NSChangeRedone];
            }
            [editor setFindStatus:applied
                ? @"Undo／Redoは反映済みですが画面更新に失敗しました。履歴は保持されています。"
                : @"Undo／Redoを反映できませんでした。本文と履歴は変更していません。"];
          };
          @try {
            try {
              if (editor) {
                editor->_historyWorkerRanOnMainThread = ranOnMain;
                bool current = editor.historyProgress == progress && !progress.cancelled &&
                    liveDocument && editor.sakuraDocument == liveDocument &&
                    !liveDocument.closingDocument && !editor.historyWindowClosed &&
                    !editor.hasRectangularSelection &&
                    (!hadWindow || (expectedWindow && editor.window == expectedWindow)) &&
                    editor.selectionGeneration == selectionGeneration &&
                    NSEqualRanges(editor.committedSelection,expectedSelection);
                const auto currentViews = current ? [editor replacementAffectedViews] : nil;
                current = current && currentViews.count == layouts->size();
                if (current) for (const auto& work : *layouts) {
                  SakuraEditorView* view = work.view;
                  if (!view || view.sakuraDocument != liveDocument || ![currentViews containsObject:view] || view.hasMarkedText ||
                      ![[view layoutConfigurationKey] isEqual:work.key]) { current = false; break; }
                }
                if (!current) {
                  ++editor->_historyDiscards;
                  if (editor.historyProgress == progress) {
                    [editor cancelHistoryNavigation:nil];
                    [editor setFindStatus:@"本文・選択・IME・ペイン表示が変わったためUndo／Redoを中止しました。"];
                  }
                } else if (error || !*payload) {
                  [editor cancelHistoryNavigation:nil];
                  [editor setFindStatus:error ? error : @"Undo／Redoを準備できませんでした。"];
                } else if (!liveDocument.documentSession.commitPreparedHistory(**payload)) {
                  ++editor->_historyDiscards;
                  [editor cancelHistoryNavigation:nil];
                  [editor setFindStatus:@"本文または編集履歴が変わったためUndo／Redoを中止しました。"];
                } else {
                  editor.historyProgress = nil;
                  if (!editor->_historyRequests.empty()) editor->_historyRequests.pop_front();
                  ++editor->_historyCompletions;
                  applied = (*payload)->hasChanges();
                  const auto cancellationGeneration = editor->_historyCancellationGeneration;
                  editor.applyingHistoryTransition = YES;
                  if (applied) {
                    const auto adoptStarted = std::chrono::steady_clock::now();
                    for (auto& work : *layouts) {
                      SakuraEditorView* view = work.view;
                      [view adoptPreparedLayout:work]; ++view->_historyLayoutsAdopted;
                    }
                    editor->_historyAdoptMilliseconds = std::chrono::duration<double,std::milli>(
                        std::chrono::steady_clock::now()-adoptStarted).count();
                    NSRange selection = clampedRange(editor.committedSelection,
                        liveDocument.documentSession.buffer().length());
                    if (selection.length) selection = [editor rangeByExpandingToEditBoundaries:selection];
                    else selection.location = [editor previousEditBoundaryAtOrBefore:selection.location];
                    [editor updateCommittedSelection:selection preservingHistory:YES];
                    notified = YES;
                    [liveDocument noteEditorChange:direction == Direction::undo ? NSChangeUndone : NSChangeRedone];
                    const auto refreshStarted = std::chrono::steady_clock::now();
                    [liveDocument refreshEditorViews];
                    editor->_historyRefreshMilliseconds = std::chrono::duration<double,std::milli>(
                        std::chrono::steady_clock::now()-refreshStarted).count();
                  }
                  editor.applyingHistoryTransition = NO;
                  const auto& live = liveDocument.documentSession.buffer();
                  const auto& published = (*payload)->resultingBuffer();
                  if (editor->_historyCancellationGeneration != cancellationGeneration ||
                      editor.sakuraDocument != liveDocument || liveDocument.closingDocument ||
                      (applied && (live.revision() != published.revision() || !live.sharesStorageWith(published)))) {
                    [editor cancelHistoryNavigation:nil];
                    [editor setFindStatus:@"Undo／Redoは反映済みです。操作状態が変わったため、残りの履歴操作を中止しました。"];
                  } else {
                    if (applied) [editor setFindStatus:direction == Direction::undo ? @"元に戻しました。" : @"やり直しました。"];
                    continueQueue = YES;
                  }
                }
              }
            } catch (const std::exception&) { reportFailure(); }
          } @catch (NSException* exception) { (void)exception; reportFailure(); }
          if (editor) editor->_historyMainMilliseconds = std::chrono::duration<double,std::milli>(
              std::chrono::steady_clock::now()-callbackStarted).count();
          // Retired history/text/layout roots outlive publication and are freed
          // on the worker, before it starts preparing the next queued request.
          dispatch_async(replacementPreparationQueue(), ^{ payload->reset(); layouts->clear(); });
          if (continueQueue && editor) [editor startNextHistoryNavigation];
        });
      }
    });
  } catch (...) { failToStart(); }
  } @catch (NSException* exception) {
    (void)exception;
    failToStart();
  }
}

- (std::function<void()>)historyWorkGate { return {}; } // Deterministic worker gating in isolated UI tests only.
- (NSTimeInterval)historyPreparationTimeLimit { return 5.0; }

- (void)cancelOperation:(id)sender {
  (void)sender;
  if ([self hasPendingSearchNavigation] || [self hasPendingReplacement] || [self hasPendingHistoryNavigation] ||
      [self hasPendingBracketSearch] || self.searchCountProgress) [self cancelSearchOperations:nil];
  [self cancelSyntaxHighlighting:nil];
  [self clearMarkedState];
  [self clearRectangularSelection];
  [self updateDocumentViewSize];
  [self setNeedsDisplay:YES];
}

- (NSUInteger)safeNavigationOffset:(NSUInteger)offset {
  return [self safeNavigationOffset:offset inString:[self committedString]];
}

- (NSUInteger)safeNavigationOffset:(NSUInteger)offset inString:(NSString*)text {
  offset = [self previousEditBoundaryAtOrBefore:std::min(offset, text.length)];
  if (offset < text.length) {
    offset = [text rangeOfComposedCharacterSequenceAtIndex:offset].location;
  }
  return [self previousEditBoundaryAtOrBefore:offset];
}

- (NSUInteger)navigationCaretOffset {
  return self.navigationAnchor == NSNotFound
      ? NSMaxRange(self.committedSelection) : self.navigationCaret;
}

- (NSUInteger)previousNavigationOffset:(NSUInteger)offset {
  return [self previousNavigationOffset:offset inString:[self committedString]];
}

- (NSUInteger)previousNavigationOffset:(NSUInteger)offset inString:(NSString*)text {
  offset = [self safeNavigationOffset:offset inString:text];
  if (offset == 0) return 0;
  return [self safeNavigationOffset:
      [text rangeOfComposedCharacterSequenceAtIndex:offset - 1].location
                          inString:text];
}

- (NSUInteger)nextNavigationOffset:(NSUInteger)offset {
  return [self nextNavigationOffset:offset inString:[self committedString]];
}

- (NSUInteger)nextNavigationOffset:(NSUInteger)offset inString:(NSString*)text {
  offset = [self safeNavigationOffset:offset inString:text];
  if (offset >= text.length) return text.length;
  const NSUInteger next = NSMaxRange(
      [text rangeOfComposedCharacterSequenceAtIndex:offset]);
  return [self nextEditBoundaryAtOrAfter:next];
}

- (void)moveSelectionToOffset:(NSUInteger)offset
          modifyingSelection:(BOOL)modify
 preservingHorizontalPosition:(BOOL)preserveX {
  offset = [self safeNavigationOffset:offset];
  const NSUInteger anchor = [self safeNavigationOffset:
      self.navigationAnchor == NSNotFound
          ? self.committedSelection.location : self.navigationAnchor];
  const CGFloat preferredX = self.navigationPreferredX;
  self.committedSelection = modify
      ? NSMakeRange(std::min(anchor, offset),
                    std::max(anchor, offset) - std::min(anchor, offset))
      : NSMakeRange(offset, 0);
  self.navigationAnchor = modify ? anchor : NSNotFound;
  self.navigationCaret = offset;
  self.navigationPreferredX = preserveX ? preferredX : NAN;
  [self setNeedsDisplay:YES];
  [self scrollSelectionToVisible];
}

- (void)prepareLinearNavigation {
  if ([self hasMarkedText]) [self unmarkText];
  [self clearRectangularSelection];
}

// Group letters, digits and '_' as identifiers; preserve composed sequences
// (including emoji) as indivisible units when crossing punctuation or spaces.
- (NSInteger)wordKindAtNavigationOffset:(NSUInteger)offset inString:(NSString*)text {
  if (offset >= text.length) return -1;
  const NSRange cluster = [text rangeOfComposedCharacterSequenceAtIndex:offset];
  NSString* character = [text substringWithRange:cluster];
  if ([character rangeOfCharacterFromSet:
          [NSCharacterSet newlineCharacterSet]].location != NSNotFound) return 3;
  if ([character rangeOfCharacterFromSet:
          [NSCharacterSet whitespaceCharacterSet]].location != NSNotFound) return 0;
  if ([character isEqualToString:@"_"] ||
      [character rangeOfCharacterFromSet:
          [NSCharacterSet alphanumericCharacterSet]].location != NSNotFound) return 1;
  return 2;
}

- (NSRange)wordRangeAtNavigationOffset:(NSUInteger)offset {
  return [self wordRangeAtNavigationOffset:offset inString:[self committedString]];
}

- (NSRange)wordRangeAtNavigationOffset:(NSUInteger)offset inString:(NSString*)text {
  if (text.length == 0) return NSMakeRange(0, 0);
  offset = offset >= text.length
      ? [self previousNavigationOffset:text.length inString:text]
      : [self safeNavigationOffset:offset inString:text];
  const NSInteger kind = [self wordKindAtNavigationOffset:offset inString:text];
  NSUInteger start = offset;
  NSUInteger end = [self nextNavigationOffset:offset inString:text];
  if (kind != 3) {
    while (start != 0) {
      const NSUInteger previous = [self previousNavigationOffset:start inString:text];
      if ([self wordKindAtNavigationOffset:previous inString:text] != kind) break;
      start = previous;
    }
    while (end < text.length &&
           [self wordKindAtNavigationOffset:end inString:text] == kind) {
      end = [self nextNavigationOffset:end inString:text];
    }
  }
  return NSMakeRange(start, end - start);
}

- (NSUInteger)wordNavigationOffset:(NSUInteger)offset forward:(BOOL)forward {
  NSString* text = [self committedString];
  offset = [self safeNavigationOffset:offset inString:text];
  if (forward) {
    while (offset < text.length &&
           ([self wordKindAtNavigationOffset:offset inString:text] == 0 ||
            [self wordKindAtNavigationOffset:offset inString:text] == 3)) {
      offset = [self nextNavigationOffset:offset inString:text];
    }
    if (offset < text.length) {
      offset = NSMaxRange([self wordRangeAtNavigationOffset:offset inString:text]);
    }
  } else {
    while (offset != 0) {
      const NSUInteger previous = [self previousNavigationOffset:offset inString:text];
      const NSInteger kind = [self wordKindAtNavigationOffset:previous inString:text];
      if (kind != 0 && kind != 3) {
        return [self wordRangeAtNavigationOffset:previous inString:text].location;
      }
      offset = previous;
    }
  }
  return offset;
}

- (void)moveHorizontally:(BOOL)forward modifyingSelection:(BOOL)modify {
  [self prepareLinearNavigation];
  NSUInteger caret = [self navigationCaretOffset];
  if (!modify && self.committedSelection.length != 0) {
    caret = forward ? NSMaxRange(self.committedSelection)
                    : self.committedSelection.location;
  } else {
    caret = forward ? [self nextNavigationOffset:caret]
                    : [self previousNavigationOffset:caret];
  }
  [self moveSelectionToOffset:caret modifyingSelection:modify
       preservingHorizontalPosition:NO];
}

- (void)moveWordHorizontally:(BOOL)forward modifyingSelection:(BOOL)modify {
  [self prepareLinearNavigation];
  const NSUInteger caret = [self wordNavigationOffset:[self navigationCaretOffset]
                                            forward:forward];
  [self moveSelectionToOffset:caret modifyingSelection:modify
       preservingHorizontalPosition:NO];
}

- (void)moveLeft:(id)sender {
  (void)sender;
  if ([self hasMarkedText]) {
    [self unmarkText];
  }
  if (self.rectangularSelectionActive) {
    const auto& ranges = [self displayLineRanges];
    const NSRange lineSpan = [self rectangularDisplayLineSpan];
    const NSUInteger lineIndex = lineSpan.location == NSNotFound
        ? 0 : std::min<NSUInteger>(
            static_cast<NSUInteger>(std::max<CGFloat>(
                0.0, (self.rectangularCurrentPoint.y - kVerticalInset) /
                    [self editorLineHeight])), ranges.size() - 1);
    const NSRange lineRange = ranges[lineIndex];
    const NSUInteger current = [self displayIndexForLocalPoint:
        self.rectangularCurrentPoint];
    NSRect endRect = [self localRectForDisplayIndex:NSMaxRange(lineRange)];
    if (self.rectangularCurrentPoint.x > endRect.origin.x + 0.5) {
      self.rectangularCurrentPoint = NSMakePoint(
          std::max(endRect.origin.x,
                   self.rectangularCurrentPoint.x -
                       [self rectangularSpaceAdvance]),
          self.rectangularCurrentPoint.y);
    } else if (current > lineRange.location) {
      NSString* text = [self committedString];
      const NSRange previous = [text rangeOfComposedCharacterSequenceAtIndex:
          current - 1];
      const NSRect rect = [self localRectForDisplayIndex:
          [self previousEditBoundaryAtOrBefore:previous.location]];
      self.rectangularCurrentPoint = NSMakePoint(rect.origin.x,
                                                 self.rectangularCurrentPoint.y);
    }
    [self updateRectangularSelection];
    return;
  }
  [self moveHorizontally:NO modifyingSelection:NO];
}

- (void)moveRight:(id)sender {
  (void)sender;
  if ([self hasMarkedText]) {
    [self unmarkText];
  }
  if (self.rectangularSelectionActive) {
    const auto& ranges = [self displayLineRanges];
    const NSUInteger lineIndex = std::min<NSUInteger>(
        static_cast<NSUInteger>(std::max<CGFloat>(
            0.0, (self.rectangularCurrentPoint.y - kVerticalInset) /
                [self editorLineHeight])), ranges.size() - 1);
    const NSRange lineRange = ranges[lineIndex];
    const NSUInteger current = [self displayIndexForLocalPoint:
        self.rectangularCurrentPoint];
    NSRect endRect = [self localRectForDisplayIndex:NSMaxRange(lineRange)];
    if (self.rectangularCurrentPoint.x >= endRect.origin.x - 0.5) {
      self.rectangularCurrentPoint = NSMakePoint(
          std::max(self.rectangularCurrentPoint.x, endRect.origin.x) +
              [self rectangularSpaceAdvance],
          self.rectangularCurrentPoint.y);
    } else if (current < NSMaxRange(lineRange)) {
      NSString* text = [self committedString];
      const NSRange next = [text rangeOfComposedCharacterSequenceAtIndex:current];
      const NSRect rect = [self localRectForDisplayIndex:
          [self nextEditBoundaryAtOrAfter:NSMaxRange(next)]];
      self.rectangularCurrentPoint = NSMakePoint(rect.origin.x,
                                                 self.rectangularCurrentPoint.y);
    }
    [self updateRectangularSelection];
    return;
  }
  [self moveHorizontally:YES modifyingSelection:NO];
}

- (void)moveUp:(id)sender {
  (void)sender;
  [self moveVertically:-1];
}

- (void)moveDown:(id)sender {
  (void)sender;
  [self moveVertically:1];
}

- (void)moveVertically:(NSInteger)delta {
  if ([self hasMarkedText]) {
    [self unmarkText];
  }
  if (self.rectangularSelectionActive) {
    self.rectangularCurrentPoint = NSMakePoint(
        self.rectangularCurrentPoint.x,
        self.rectangularCurrentPoint.y +
            static_cast<CGFloat>(delta) * [self editorLineHeight]);
    [self updateRectangularSelection];
    return;
  }
  [self moveVertically:delta modifyingSelection:NO];
}

- (void)moveVertically:(NSInteger)delta modifyingSelection:(BOOL)modify {
  [self prepareLinearNavigation];
  const NSUInteger caret = [self navigationCaretOffset];
  const auto& ranges = [self displayLineRanges];
  const NSUInteger current = lineIndexContainingCharacter(ranges, caret, &_lineLookupSteps);
  const NSInteger target = std::clamp<NSInteger>(
      static_cast<NSInteger>(current) + delta, 0,
      static_cast<NSInteger>(ranges.size()) - 1);
  if (std::isnan(self.navigationPreferredX)) {
    self.navigationPreferredX = [self localRectForDisplayIndex:caret].origin.x;
  }
  const NSPoint targetPoint = NSMakePoint(
      self.navigationPreferredX,
      kVerticalInset + static_cast<CGFloat>(target) * [self editorLineHeight] +
          0.5 * [self editorLineHeight]);
  const NSUInteger offset = current == static_cast<NSUInteger>(target)
      ? (delta < 0 ? 0 : [self committedString].length)
      : [self displayIndexForLocalPoint:targetPoint];
  [self moveSelectionToOffset:offset modifyingSelection:modify
       preservingHorizontalPosition:YES];
}

- (void)moveToBeginningOfLine:(id)sender {
  (void)sender;
  [self moveToLineBoundary:NO modifyingSelection:NO];
}

- (void)moveToEndOfLine:(id)sender {
  (void)sender;
  [self moveToLineBoundary:YES modifyingSelection:NO];
}

- (void)moveToBeginningOfDocument:(id)sender {
  (void)sender;
  [self prepareLinearNavigation];
  [self moveSelectionToOffset:0 modifyingSelection:NO
       preservingHorizontalPosition:NO];
}

- (void)moveToEndOfDocument:(id)sender {
  (void)sender;
  [self prepareLinearNavigation];
  [self moveSelectionToOffset:[self committedString].length modifyingSelection:NO
       preservingHorizontalPosition:NO];
}

- (void)moveToLineBoundary:(BOOL)end modifyingSelection:(BOOL)modify {
  [self prepareLinearNavigation];
  const auto& buffer = self.sakuraDocument.documentSession.buffer();
  const auto position = buffer.positionAt([self navigationCaretOffset]);
  const NSUInteger offset = static_cast<NSUInteger>(end
      ? buffer.offsetAt({position.line, buffer.line(position.line).content.size()})
      : buffer.lineStartOffset(position.line));
  [self moveSelectionToOffset:offset modifyingSelection:modify
       preservingHorizontalPosition:NO];
}

- (void)moveLeftAndModifySelection:(id)sender {
  (void)sender;
  [self moveHorizontally:NO modifyingSelection:YES];
}

- (void)moveRightAndModifySelection:(id)sender {
  (void)sender;
  [self moveHorizontally:YES modifyingSelection:YES];
}

- (void)moveUpAndModifySelection:(id)sender {
  (void)sender;
  [self moveVertically:-1 modifyingSelection:YES];
}

- (void)moveDownAndModifySelection:(id)sender {
  (void)sender;
  [self moveVertically:1 modifyingSelection:YES];
}

- (void)moveWordLeft:(id)sender {
  (void)sender;
  [self moveWordHorizontally:NO modifyingSelection:NO];
}

- (void)moveWordRight:(id)sender {
  (void)sender;
  [self moveWordHorizontally:YES modifyingSelection:NO];
}

- (void)moveWordLeftAndModifySelection:(id)sender {
  (void)sender;
  [self moveWordHorizontally:NO modifyingSelection:YES];
}

- (void)moveWordRightAndModifySelection:(id)sender {
  (void)sender;
  [self moveWordHorizontally:YES modifyingSelection:YES];
}

- (void)moveToBeginningOfLineAndModifySelection:(id)sender {
  (void)sender;
  [self moveToLineBoundary:NO modifyingSelection:YES];
}

- (void)moveToEndOfLineAndModifySelection:(id)sender {
  (void)sender;
  [self moveToLineBoundary:YES modifyingSelection:YES];
}

- (void)moveToBeginningOfDocumentAndModifySelection:(id)sender {
  (void)sender;
  [self prepareLinearNavigation];
  [self moveSelectionToOffset:0 modifyingSelection:YES
       preservingHorizontalPosition:NO];
}

- (void)moveToEndOfDocumentAndModifySelection:(id)sender {
  (void)sender;
  [self prepareLinearNavigation];
  [self moveSelectionToOffset:[self committedString].length modifyingSelection:YES
       preservingHorizontalPosition:NO];
}

- (NSInteger)navigationPageLineCount {
  const CGFloat height = self.enclosingScrollView != nil
      ? self.enclosingScrollView.contentView.bounds.size.height
      : std::min<CGFloat>(self.visibleRect.size.height, 600.0);
  return std::max<NSInteger>(1, static_cast<NSInteger>(
      std::floor(height / [self editorLineHeight])) - 1);
}

- (void)pageUp:(id)sender {
  (void)sender;
  [self moveVertically:-[self navigationPageLineCount] modifyingSelection:NO];
}

- (void)pageDown:(id)sender {
  (void)sender;
  [self moveVertically:[self navigationPageLineCount] modifyingSelection:NO];
}

- (void)pageUpAndModifySelection:(id)sender {
  (void)sender;
  [self moveVertically:-[self navigationPageLineCount] modifyingSelection:YES];
}

- (void)pageDownAndModifySelection:(id)sender {
  (void)sender;
  [self moveVertically:[self navigationPageLineCount] modifyingSelection:YES];
}

// AppKit key bindings use both logical and visual selector spellings.
- (void)moveBackward:(id)sender { [self moveLeft:sender]; }
- (void)moveForward:(id)sender { [self moveRight:sender]; }
- (void)moveBackwardAndModifySelection:(id)sender {
  [self moveLeftAndModifySelection:sender];
}
- (void)moveForwardAndModifySelection:(id)sender {
  [self moveRightAndModifySelection:sender];
}
- (void)moveWordBackward:(id)sender { [self moveWordLeft:sender]; }
- (void)moveWordForward:(id)sender { [self moveWordRight:sender]; }
- (void)moveWordBackwardAndModifySelection:(id)sender {
  [self moveWordLeftAndModifySelection:sender];
}
- (void)moveWordForwardAndModifySelection:(id)sender {
  [self moveWordRightAndModifySelection:sender];
}
- (void)moveToLeftEndOfLine:(id)sender { [self moveToBeginningOfLine:sender]; }
- (void)moveToRightEndOfLine:(id)sender { [self moveToEndOfLine:sender]; }
- (void)moveToLeftEndOfLineAndModifySelection:(id)sender {
  [self moveToBeginningOfLineAndModifySelection:sender];
}
- (void)moveToRightEndOfLineAndModifySelection:(id)sender {
  [self moveToEndOfLineAndModifySelection:sender];
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item {
  const SEL action = item.action;
  if (action == @selector(cancelSearchOperations:))
    return [self hasPendingSearchNavigation] || [self hasPendingHistoryNavigation] || [self hasPendingBracketSearch] ||
        self.searchCountProgress != nil || self.searchHighlightProgress != nil;
  if (action == @selector(undo:)) {
    return [self hasPendingHistoryNavigation] || self.sakuraDocument.documentSession.canUndo();
  }
  if (action == @selector(redo:)) {
    return [self hasPendingHistoryNavigation] || self.sakuraDocument.documentSession.canRedo();
  }
  if (action == @selector(copy:) || action == @selector(cut:)) {
    return [self selectedCharacterCount] != 0;
  }
  if (action == @selector(paste:)) {
    return [[NSPasteboard generalPasteboard]
               availableTypeFromArray:@[ NSPasteboardTypeString ]] != nil;
  }
  return YES;
}

@end
