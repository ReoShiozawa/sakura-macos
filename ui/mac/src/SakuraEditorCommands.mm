// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#import "SakuraEditorView.h"
#import "SakuraDocument.h"
#import "SakuraEditorSettings.h"
#import <objc/runtime.h>
#include "sakura/core/search/BracketSearch.h"
#include "sakura/platform/mac/StringBridge.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <functional>
#include <memory>
#include <optional>
#include <stdexcept>
#include <vector>
#include <unicode/uchar.h>

@interface SakuraBracketNavigationState : NSObject
@property(nonatomic, strong) NSProgress* progress;
@property(nonatomic, strong) id closeObserver;
@property(nonatomic) NSUInteger requests;
@property(nonatomic) NSUInteger completions;
@property(nonatomic) NSUInteger discards;
@property(nonatomic) NSUInteger errors;
@property(nonatomic) BOOL workerOnMain;
@end
@implementation SakuraBracketNavigationState
- (void)dealloc {
  [_progress cancel];
  if (_closeObserver) [NSNotificationCenter.defaultCenter removeObserver:_closeObserver];
}
@end

namespace {
char bracketStateKey;
SakuraBracketNavigationState* bracketState(SakuraEditorView* editor, BOOL create) {
  SakuraBracketNavigationState* state = objc_getAssociatedObject(editor, &bracketStateKey);
  if (!state && create) {
    state = [[SakuraBracketNavigationState alloc] init];
    objc_setAssociatedObject(editor, &bracketStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return state;
}
void clearBracketObserver(SakuraBracketNavigationState* state) {
  if (state.closeObserver) [NSNotificationCenter.defaultCenter removeObserver:state.closeObserver];
  state.closeObserver = nil;
}
dispatch_queue_t bracketSearchQueue() {
  static dispatch_queue_t queue = dispatch_queue_create(
      "local.unofficial-sakura.bracket-search",
      dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
  return queue;
}
struct BracketPane {
  __weak SakuraEditorView* view;
};
struct BracketWork {
  std::shared_ptr<const sakura::core::EditEngine::Snapshot> source;
  sakura::app::PreparedSearchReplacement sourceGuard;
  std::optional<sakura::core::BracketMatch> match;
  bool guardReady{};
};
// Deterministic cell widths for TAB conversion, independent of proportional
// font shaping. Composed emoji/combining sequences are kept together.
NSUInteger cellWidth(NSString* cluster) {
  UChar32 scalar = [cluster characterAtIndex:0];
  if (cluster.length > 1 && CFStringIsSurrogateHighCharacter((UniChar)scalar))
    scalar = CFStringGetLongCharacterForSurrogatePair((UniChar)scalar, [cluster characterAtIndex:1]);
  const auto east = u_getIntPropertyValue(scalar, UCHAR_EAST_ASIAN_WIDTH);
  if (east == U_EA_WIDE || east == U_EA_FULLWIDTH ||
      u_hasBinaryProperty(scalar, UCHAR_EMOJI_PRESENTATION)) return 2;
  const auto type = u_charType(scalar);
  return type == U_NON_SPACING_MARK || type == U_ENCLOSING_MARK ? 0 : 1;
}
NSUInteger columnAfter(NSString* text, NSUInteger width) {
  __block NSUInteger column = 0;
  [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
      options:NSStringEnumerationByComposedCharacterSequences
      usingBlock:^(NSString* cluster, NSRange range, NSRange enclosing, BOOL* stop) {
    (void)range; (void)enclosing; (void)stop;
    if ([cluster isEqual:@"\t"]) column += width - column % width;
    else column += cellWidth(cluster);
  }];
  return column;
}
}

@interface SakuraEditorView (CommandInternals)
@property(nonatomic, weak) SakuraDocument* sakuraDocument;
@property(nonatomic) NSRange committedSelection;
@property(nonatomic) NSUInteger navigationCaret;
@property(nonatomic) uint64_t selectionGeneration;
@property(nonatomic) BOOL rectangularSelectionActive;
@property(nonatomic) NSPoint rectangularCurrentPoint;
- (NSString*)committedString;
- (SakuraEditorSettings*)editorSettings;
- (BOOL)replaceCommittedRange:(NSRange)range withString:(NSString*)text;
- (void)replaceRectangularSelectionWithStrings:(NSArray<NSString*>*)strings;
- (NSArray<NSValue*>*)rectangularCommittedRanges;
- (NSArray<NSDictionary*>*)rectangularSelections;
- (NSRange)wordRangeAtNavigationOffset:(NSUInteger)offset;
- (NSUInteger)wordNavigationOffset:(NSUInteger)offset forward:(BOOL)forward;
- (void)clearRectangularSelection;
- (NSUInteger)displayIndexForLocalPoint:(NSPoint)point;
- (NSArray<SakuraEditorView*>*)replacementAffectedViews;
- (NSArray*)layoutConfigurationKey;
- (void)setFindStatus:(NSString*)status;
- (void)cancelHistoryNavigation:(id)sender;
@end

@interface SakuraDocument (BracketNavigationInternals)
@property(nonatomic, readonly) BOOL closingDocument;
@end

@implementation SakuraEditorView (EditingCommands)

- (BOOL)hasPendingBracketSearch { return bracketState(self, NO).progress != nil; }

- (void)cancelBracketSearch {
  SakuraBracketNavigationState* state = bracketState(self, NO);
  [state.progress cancel];
  state.progress = nil;
  clearBracketObserver(state);
}

- (void)cancelBracketSearchesForDocument {
  for (SakuraEditorView* view in [self replacementAffectedViews]) [view cancelBracketSearch];
}

- (NSDictionary*)bracketSearchStatistics {
  SakuraBracketNavigationState* state = bracketState(self, NO);
  return @{ @"pending":@([self hasPendingBracketSearch]), @"requests":@(state.requests),
      @"completions":@(state.completions), @"discards":@(state.discards),
      @"errors":@(state.errors), @"workerOnMain":@(state.workerOnMain) };
}

- (NSTimeInterval)bracketSearchTimeLimit { return 5.0; }
- (sakura::core::TextOffset)bracketSearchScanLimit { return 0; }
// Test subclasses can return a deterministic worker gate. Normal operation has
// no blocking gate or environment-controlled fault injection.
- (std::function<void()>)bracketSearchWorkGate { return {}; }

- (NSUInteger)bracketSearchCaretOffset {
  if (self.rectangularSelectionActive)
    return [self displayIndexForLocalPoint:self.rectangularCurrentPoint];
  const NSRange selection = self.committedSelection;
  const NSUInteger caret = self.navigationCaret;
  return caret >= selection.location && caret <= NSMaxRange(selection) ? caret : NSMaxRange(selection);
}

- (void)jumpToMatchingBracket:(id)sender {
  (void)sender;
  SakuraBracketNavigationState* state = bracketState(self, YES);
  NSProgress* requestProgress = nil;
  NSUInteger requestNumber = state.requests;
  auto failToStart = [&] {
    [requestProgress cancel];
    ++state.errors;
    // A status/capture callback may have reentered and started another search.
    // Only retire the request owned by this invocation, never its successor.
    if (state.requests != requestNumber || (state.progress && state.progress != requestProgress)) return;
    state.progress = nil;
    clearBracketObserver(state);
    @try {
      try { [self setFindStatus:@"対括弧検索を開始できませんでした。本文は変更していません。"]; }
      catch (...) {}
    } @catch (NSException* exception) { (void)exception; }
  };
  @try {
  try {
    [self cancelBracketSearch];
    SakuraDocument* document = self.sakuraDocument;
    if (!document || document.closingDocument) return;
    for (SakuraEditorView* view in [self replacementAffectedViews]) {
      if (view.sakuraDocument != document) {
        [self setFindStatus:@"ペインの文書が変わったため対括弧検索を中止しました。"];
        return;
      }
      if (view.hasMarkedText) {
        [self setFindStatus:@"IME入力を確定してから対括弧を検索してください。"];
        return;
      }
    }
    [self cancelHistoryNavigation:nil];
    [self cancelSearchOperations:nil];
    const auto seconds = [self bracketSearchTimeLimit];
    if (!std::isfinite(seconds) || seconds <= 0 || seconds > 60) {
      ++bracketState(self, YES).errors;
      [self setFindStatus:@"対括弧検索を中止しました（時間上限の設定が不正です）。"];
      return;
    }
    const auto& current = document.documentSession.buffer();
    const NSRange selection = self.committedSelection;
    if (selection.location > current.length() || selection.length > current.length()-selection.location)
      throw std::out_of_range("invalid bracket caret selection");
    const auto caret = [self bracketSearchCaretOffset];
    const auto generation = self.selectionGeneration;
    NSArray* layoutKey = [self layoutConfigurationKey];
    const BOOL rectangular = self.rectangularSelectionActive;
    const NSPoint rectangularPoint = self.rectangularCurrentPoint;
    auto snapshot = std::make_shared<const sakura::core::EditEngine::Snapshot>(
        document.documentSession.editSnapshot());
    auto panes = std::make_shared<std::vector<BracketPane>>();
    for (SakuraEditorView* view in [self replacementAffectedViews]) {
      if (view.sakuraDocument != document) {
        [self setFindStatus:@"ペインの文書が変わったため対括弧検索を中止しました。"];
        return;
      }
      panes->push_back({view});
    }
    __weak SakuraDocument* expectedDocument = document;
    __weak NSWindow* expectedWindow = self.window;
    const BOOL hadWindow = self.window != nil;
    __weak NSResponder* expectedResponder = self.window.firstResponder;
    const BOOL hadResponder = self.window.firstResponder != nil;
    NSProgress* progress = [NSProgress progressWithTotalUnitCount:1];
    requestProgress = progress;
    state.progress = progress;
    requestNumber = ++state.requests;
    if (self.window) {
      state.closeObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillCloseNotification
          object:self.window queue:nil usingBlock:^(NSNotification*) { [progress cancel]; }];
    }
    [self setFindStatus:@"対括弧を検索しています…（検索中止／⌘.で中止）"];
    const auto scanLimit = [self bracketSearchScanLimit];
    const auto gate = [self bracketSearchWorkGate];
    auto payload = std::make_shared<std::unique_ptr<BracketWork>>(std::make_unique<BracketWork>());
    (*payload)->source = std::move(snapshot);
    __weak SakuraEditorView* weakSelf = self;
    dispatch_async(bracketSearchQueue(), ^{
      @autoreleasepool {
        NSString* error = nil;
        const BOOL workerOnMain = NSThread.isMainThread;
        @try {
        try {
          (*payload)->sourceGuard.edit = sakura::core::EditEngine::prepareOriginalRanges(*(*payload)->source, {},
              [progress] { return progress.cancelled; });
          (*payload)->guardReady = true;
          const auto deadline = std::chrono::steady_clock::now() +
              std::chrono::duration_cast<std::chrono::steady_clock::duration>(std::chrono::duration<double>(seconds));
          if (gate) gate();
          sakura::core::BracketSearchOptions options;
          options.maxScanCodeUnits = scanLimit;
          options.cancelled = [progress, deadline] {
            return progress.cancelled || std::chrono::steady_clock::now() >= deadline;
          };
          (*payload)->match = sakura::core::findBracketPair((*payload)->source->buffer(), caret, options);
        } catch (const std::exception&) {
          error = @"対括弧検索を中止しました（時間・走査上限または検索エラー）。";
        } catch (...) {
          error = @"対括弧検索を完了できませんでした。本文は変更していません。";
        }
        } @catch (NSException* exception) {
          (void)exception;
          error = @"対括弧検索を完了できませんでした。本文は変更していません。";
        }
        dispatch_async(dispatch_get_main_queue(), ^{
          SakuraEditorView* editor = weakSelf;
          SakuraDocument* liveDocument = expectedDocument;
          state.workerOnMain = workerOnMain;
          auto failToDisplay = [&] {
            ++state.errors;
            [progress cancel];
            if (state.requests != requestNumber || (state.progress && state.progress != progress)) return;
            state.progress = nil;
            clearBracketObserver(state);
            @try {
              try {
                if (editor && !editor.sakuraDocument.closingDocument)
                  [editor setFindStatus:@"対括弧検索の結果を表示できませんでした。本文は変更していません。"];
              } catch (...) {}
            } @catch (NSException* exception) { (void)exception; }
          };
          @try {
          try {
          bool authentic = editor && state.progress == progress && !progress.cancelled &&
              liveDocument && editor.sakuraDocument == liveDocument && !liveDocument.closingDocument &&
              editor.selectionGeneration == generation && NSEqualRanges(editor.committedSelection, selection) &&
              [[editor layoutConfigurationKey] isEqual:layoutKey] &&
              editor.rectangularSelectionActive == rectangular &&
              (!rectangular || NSEqualPoints(editor.rectangularCurrentPoint, rectangularPoint)) &&
              [editor bracketSearchCaretOffset] == caret && editor.window == expectedWindow &&
              (!hadWindow || expectedWindow) && editor.window.firstResponder == expectedResponder &&
              (!hadResponder || expectedResponder);
          NSArray<SakuraEditorView*>* currentPanes = authentic ? [editor replacementAffectedViews] : nil;
          authentic = authentic && currentPanes.count == panes->size();
          if (authentic) for (const auto& pane : *panes) {
            SakuraEditorView* view = pane.view;
            if (!view || view.sakuraDocument != liveDocument || ![currentPanes containsObject:view] || view.hasMarkedText) {
              authentic = false; break;
            }
          }
          if (authentic) {
            const auto& live = liveDocument.documentSession.buffer();
            const auto& source = (*payload)->source->buffer();
            authentic = live.revision() == source.revision() && live.sharesStorageWith(source);
          }
          if (authentic && *payload && (*payload)->guardReady)
            authentic = liveDocument.documentSession.commitPreparedReplacement((*payload)->sourceGuard);
          if (!authentic) {
            ++state.discards;
            if (state.progress == progress) {
              state.progress = nil; clearBracketObserver(state);
              if (editor && !editor.sakuraDocument.closingDocument)
                [editor setFindStatus:@"本文・選択位置・入力状態が変わったため対括弧検索を中止しました。"];
            }
          } else {
            state.progress = nil; clearBracketObserver(state);
            if (error || !*payload || !(*payload)->guardReady) {
              ++state.errors;
              [editor setFindStatus:error ? error : @"対括弧検索を準備できませんでした。"];
            } else {
              ++state.completions;
              if ((*payload)->match) {
                [editor jumpToDocumentOffset:(*payload)->match->target.location];
                [editor setFindStatus:@"対応する括弧へ移動しました。"];
              } else [editor setFindStatus:@"対応する括弧が見つかりませんでした。"];
            }
          }
          } catch (...) { failToDisplay(); }
          } @catch (NSException* exception) {
            (void)exception;
            failToDisplay();
          } @finally {
          // Prepared source guards may be the last owner of a large old root.
          // Keep destruction and old-window disposal away from the main thread.
          dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ payload->reset(); });
          }
        });
      }
    });
  } catch (...) { failToStart(); }
  } @catch (NSException* exception) { (void)exception; failToStart(); }
}

- (BOOL)jumpToLogicalLine:(NSUInteger)line {
  const auto& buffer = self.sakuraDocument.documentSession.buffer();
  if (!line || line > buffer.lineCount()) return NO;
  [self jumpToDocumentOffset:buffer.lineStartOffset(line - 1)];
  return YES;
}

- (void)showLineJump:(id)sender {
  (void)sender;
  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = @"指定行へジャンプ";
  alert.informativeText = [NSString stringWithFormat:@"1〜%zuの論理行番号を入力してください。",
      self.sakuraDocument.documentSession.buffer().lineCount()];
  NSTextField* field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 240, 24)];
  field.stringValue = @"1";
  alert.accessoryView = field;
  [alert addButtonWithTitle:@"移動"];
  [alert addButtonWithTitle:@"キャンセル"];
  [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
    if (response != NSAlertFirstButtonReturn) return;
    NSScanner* scanner = [NSScanner scannerWithString:field.stringValue];
    long long number = 0;
    if (![scanner scanLongLong:&number] || !scanner.isAtEnd || number <= 0 ||
        ![self jumpToLogicalLine:(NSUInteger)number]) NSBeep();
  }];
}

- (void)toggleBookmark:(id)sender {
  (void)sender;
  if (self.hasMarkedText) [self unmarkText];
  [self.sakuraDocument toggleBookmarkAtLine:
      self.sakuraDocument.documentSession.buffer().positionAt(self.currentDocumentOffset).line];
}
- (void)nextBookmark:(id)sender { (void)sender; [self visitBookmarkBackwards:NO]; }
- (void)previousBookmark:(id)sender { (void)sender; [self visitBookmarkBackwards:YES]; }
- (void)visitBookmarkBackwards:(BOOL)backwards {
  if (self.hasMarkedText) [self unmarkText];
  NSIndexSet* lines = self.sakuraDocument.bookmarkLines;
  if (!lines.count) { NSBeep(); return; }
  NSUInteger current = self.sakuraDocument.documentSession.buffer().positionAt(self.currentDocumentOffset).line;
  NSUInteger target = backwards ? [lines indexLessThanIndex:current] : [lines indexGreaterThanIndex:current];
  if (target == NSNotFound) target = backwards ? lines.lastIndex : lines.firstIndex;
  [self jumpToLogicalLine:target + 1];
}
- (void)clearBookmarks:(id)sender { (void)sender; [self.sakuraDocument clearBookmarks]; }
- (void)showBookmarks:(id)sender {
  (void)sender;
  NSIndexSet* lines = self.sakuraDocument.bookmarkLines;
  if (!lines.count) { NSBeep(); return; }
  NSPopUpButton* popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 400, 28)];
  const auto& buffer = self.sakuraDocument.documentSession.buffer();
  [lines enumerateIndexesUsingBlock:^(NSUInteger line, BOOL* stop) {
    (void)stop;
    NSString* body = sakura::platform::mac::stringFromSakuraString(buffer.line(line).content);
    if (body.length > 80) body = [body substringToIndex:80];
    [popup addItemWithTitle:[NSString stringWithFormat:@"%lu: %@", (unsigned long)line + 1, body]];
    popup.lastItem.representedObject = @(line + 1);
  }];
  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = @"ブックマークの一覧";
  alert.accessoryView = popup;
  [alert addButtonWithTitle:@"移動"]; [alert addButtonWithTitle:@"キャンセル"];
  [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
    if (response == NSAlertFirstButtonReturn)
      [self jumpToLogicalLine:[popup.selectedItem.representedObject unsignedIntegerValue]];
  }];
}

// Operate on logical lines. A selection ending at the next line's start does
// not include that line. Sorting keeps EOLs in their original slots, including
// the final newline/no-newline state. No locale-dependent sort is used.
- (void)editLogicalLines:(NSString*)operation {
  if (self.hasMarkedText) [self unmarkText];
  if (self.hasRectangularSelection) { NSBeep(); return; }
  const auto& buffer = self.sakuraDocument.documentSession.buffer();
  NSRange selection = self.committedSelection;
  NSUInteger first = buffer.positionAt(selection.location).line;
  NSUInteger last = buffer.positionAt(selection.length ? NSMaxRange(selection) - 1 : selection.location).line;
  NSUInteger start = buffer.lineStartOffset(first);
  NSUInteger end = last + 1 < buffer.lineCount() ? buffer.lineStartOffset(last + 1) : buffer.length();
  NSMutableArray<NSString*>* bodies = [NSMutableArray array];
  NSMutableArray<NSString*>* endings = [NSMutableArray array];
  NSString* whole = [self committedString];
  for (NSUInteger index = first; index <= last; ++index) {
    NSUInteger offset = buffer.lineStartOffset(index);
    NSString* body = sakura::platform::mac::stringFromSakuraString(buffer.line(index).content);
    NSUInteger next = index + 1 < buffer.lineCount() ? buffer.lineStartOffset(index + 1) : buffer.length();
    [bodies addObject:body];
    [endings addObject:[whole substringWithRange:NSMakeRange(offset + body.length, next - offset - body.length)]];
  }
  NSUInteger width = MAX(1, [self editorSettings].tabWidth);
  NSString* padding = [@"" stringByPaddingToLength:width withString:@" " startingAtIndex:0];
  if ([operation hasPrefix:@"sort"]) {
    [bodies sortUsingComparator:^NSComparisonResult(NSString* a, NSString* b) {
      NSComparisonResult result = [a compare:b options:NSLiteralSearch];
      return [operation isEqual:@"sortDown"] ? (NSComparisonResult)-result : result;
    }];
  } else if ([operation isEqual:@"unique"]) {
    NSMutableArray* unique = [NSMutableArray array];
    for (NSString* body in bodies)
      if (![unique.lastObject isEqual:body]) [unique addObject:body];
    NSString* finalEnding = endings.lastObject;
    bodies = unique;
    while (endings.count > bodies.count) [endings removeLastObject];
    endings[endings.count - 1] = finalEnding;
  } else if (![operation isEqual:@"duplicate"]) {
    for (NSUInteger index = 0; index < bodies.count; ++index) {
      NSString* body = bodies[index];
      NSUInteger left = 0, right = body.length;
      if ([operation isEqual:@"indentTab"]) body = [@"\t" stringByAppendingString:body];
      else if ([operation isEqual:@"indentSpace"]) body = [padding stringByAppendingString:body];
      else if ([operation isEqual:@"unindent"]) {
        if ([body hasPrefix:@"\t"]) left = 1;
        else while (left < MIN(width, body.length) && [body characterAtIndex:left] == ' ') ++left;
        body = [body substringFromIndex:left];
      } else {
        if ([operation isEqual:@"trimLeft"])
          while (left < right && ([body characterAtIndex:left] == ' ' || [body characterAtIndex:left] == '\t')) ++left;
        else if ([operation isEqual:@"trimRight"])
          while (right > left && ([body characterAtIndex:right - 1] == ' ' || [body characterAtIndex:right - 1] == '\t')) --right;
        body = [body substringWithRange:NSMakeRange(left, right - left)];
      }
      bodies[index] = body;
    }
  }
  NSMutableString* output = [NSMutableString string];
  for (NSUInteger i = 0; i < bodies.count; ++i) { [output appendString:bodies[i]]; [output appendString:endings[i]]; }
  if ([operation isEqual:@"duplicate"]) {
    NSString* block = output.copy;
    if (!endings.lastObject.length) [output appendString:self.sakuraDocument.newlineInsertionString];
    [output appendString:block];
  }
  NSRange range = NSMakeRange(start, end - start);
  if ([[whole substringWithRange:range] isEqual:output]) return;
  [self replaceCommittedRange:range withString:output];
  self.committedSelection = NSMakeRange(start, output.length);
  [self setNeedsDisplay:YES];
}

- (void)indentWithTab:(id)sender { (void)sender; [self editLogicalLines:@"indentTab"]; }
- (void)unindentWithTab:(id)sender { (void)sender; [self editLogicalLines:@"unindent"]; }
- (void)indentWithSpaces:(id)sender { (void)sender; [self editLogicalLines:@"indentSpace"]; }
- (void)unindentWithSpaces:(id)sender { (void)sender; [self editLogicalLines:@"unindent"]; }
- (void)trimLeadingWhitespace:(id)sender { (void)sender; [self editLogicalLines:@"trimLeft"]; }
- (void)trimTrailingWhitespace:(id)sender { (void)sender; [self editLogicalLines:@"trimRight"]; }
- (void)sortLinesAscending:(id)sender { (void)sender; [self editLogicalLines:@"sortUp"]; }
- (void)sortLinesDescending:(id)sender { (void)sender; [self editLogicalLines:@"sortDown"]; }
- (void)uniqueConsecutiveLines:(id)sender { (void)sender; [self editLogicalLines:@"unique"]; }
- (void)duplicateLogicalLines:(id)sender { (void)sender; [self editLogicalLines:@"duplicate"]; }

- (NSString*)transformText:(NSString*)input operation:(NSString*)operation column:(NSUInteger)column {
  NSMutableString* text = input.mutableCopy;
  if ([operation isEqual:@"half"]) CFStringTransform((__bridge CFMutableStringRef)text, nullptr, kCFStringTransformFullwidthHalfwidth, false);
  else if ([operation isEqual:@"kata"] || [operation isEqual:@"hira"]) {
    CFStringTransform((__bridge CFMutableStringRef)text, nullptr, kCFStringTransformFullwidthHalfwidth, true);
    CFStringTransform((__bridge CFMutableStringRef)text, nullptr, kCFStringTransformHiraganaKatakana, [operation isEqual:@"hira"]);
  } else {
    NSUInteger width = MAX(1, [self editorSettings].tabWidth);
    text = [NSMutableString string];
    for (NSUInteger i = 0; i < input.length; ++i) {
      unichar c = [input characterAtIndex:i];
      if (c == '\r' || c == '\n') { [text appendFormat:@"%C", c]; column = 0; }
      else if (c == '\t') {
        NSUInteger spaces = width - column % width;
        if ([operation isEqual:@"expand"]) [text appendString:[@"" stringByPaddingToLength:spaces withString:@" " startingAtIndex:0]];
        else [text appendString:@"\t"];
        column += spaces;
      } else if (c == ' ' && [operation isEqual:@"compress"]) {
        NSUInteger count = 1;
        while (i + count < input.length && [input characterAtIndex:i + count] == ' ') ++count;
        while (count) {
          NSUInteger spaces = width - column % width;
          if (spaces > 1 && count >= spaces) { [text appendString:@"\t"]; column += spaces; count -= spaces; i += spaces; }
          else { [text appendString:@" "]; ++column; --count; ++i; }
        }
        --i;
      } else {
        NSRange clusterRange = [input rangeOfComposedCharacterSequenceAtIndex:i];
        NSString* cluster = [input substringWithRange:clusterRange];
        [text appendString:cluster];
        column += cellWidth(cluster);
        i = NSMaxRange(clusterRange) - 1;
      }
    }
  }
  return text;
}

- (void)transformSelection:(NSString*)operation {
  if (self.hasMarkedText) [self unmarkText];
  NSString* whole = [self committedString];
  if (self.hasRectangularSelection) {
    NSMutableArray* rows = [NSMutableArray array];
    for (NSValue* value in [self rectangularCommittedRanges]) {
      NSRange range = value.rangeValue;
      NSUInteger column = [self conversionColumnAtOffset:range.location];
      [rows addObject:[self transformText:[whole substringWithRange:range] operation:operation column:column]];
    }
    [self replaceRectangularSelectionWithStrings:rows];
  } else {
    NSRange range = self.committedSelection;
    if (!range.length) return;
    NSUInteger column = [self conversionColumnAtOffset:range.location];
    NSString* input = [whole substringWithRange:range];
    NSString* output = [self transformText:input operation:operation column:column];
    if ([input isEqual:output]) return;
    [self replaceCommittedRange:range withString:output];
    self.committedSelection = NSMakeRange(range.location, output.length);
    [self setNeedsDisplay:YES];
  }
}
- (NSUInteger)conversionColumnAtOffset:(NSUInteger)offset {
  const auto& buffer = self.sakuraDocument.documentSession.buffer();
  NSUInteger start = buffer.lineStartOffset(buffer.positionAt(offset).line);
  return columnAfter([[self committedString] substringWithRange:NSMakeRange(start, offset - start)],
                     MAX(1, [self editorSettings].tabWidth));
}
- (void)convertToHalfwidth:(id)sender { (void)sender; [self transformSelection:@"half"]; }
- (void)convertToFullwidthKatakana:(id)sender { (void)sender; [self transformSelection:@"kata"]; }
- (void)convertToFullwidthHiragana:(id)sender { (void)sender; [self transformSelection:@"hira"]; }
- (void)tabsToSpaces:(id)sender { (void)sender; [self transformSelection:@"expand"]; }
- (void)spacesToTabs:(id)sender { (void)sender; [self transformSelection:@"compress"]; }

- (NSDate*)dateForInsertion { return NSDate.date; }
- (void)insertDateWithFormat:(NSString*)format {
  if (self.hasMarkedText) [self unmarkText];
  NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
  formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
  formatter.dateFormat = format;
  [self insertText:[formatter stringFromDate:[self dateForInsertion]]
      replacementRange:NSMakeRange(NSNotFound, 0)];
}
- (void)insertDate:(id)sender { (void)sender; [self insertDateWithFormat:@"yyyy/MM/dd"]; }
- (void)insertTime:(id)sender { (void)sender; [self insertDateWithFormat:@"HH:mm:ss"]; }

- (void)selectCurrentWord:(id)sender {
  (void)sender;
  if (self.hasMarkedText) [self unmarkText];
  [self clearRectangularSelection];
  self.committedSelection = [self wordRangeAtNavigationOffset:self.currentDocumentOffset];
  [self setNeedsDisplay:YES];
}
- (void)deleteCurrentWord:(id)sender {
  [self selectCurrentWord:sender];
  if (self.committedSelection.length)
    [self replaceCommittedRange:self.committedSelection withString:@""];
}
- (void)deleteTowards:(NSString*)destination {
  if (self.hasMarkedText) [self unmarkText];
  if (self.hasRectangularSelection) { NSBeep(); return; }
  NSRange range = self.committedSelection;
  if (!range.length) {
    const auto& buffer = self.sakuraDocument.documentSession.buffer();
    NSUInteger caret = range.location, target = caret;
    if ([destination isEqual:@"wordLeft"] || [destination isEqual:@"wordRight"])
      target = [self wordNavigationOffset:caret forward:[destination isEqual:@"wordRight"]];
    else {
      auto position = buffer.positionAt(caret);
      target = buffer.lineStartOffset(position.line);
      if ([destination isEqual:@"lineEnd"]) target += buffer.line(position.line).content.length();
    }
    range = NSMakeRange(MIN(caret, target), MAX(caret, target) - MIN(caret, target));
  }
  if (range.length) [self replaceCommittedRange:range withString:@""];
}
- (void)deleteWordToLeft:(id)sender { (void)sender; [self deleteTowards:@"wordLeft"]; }
- (void)deleteWordToRight:(id)sender { (void)sender; [self deleteTowards:@"wordRight"]; }
- (void)deleteToLogicalLineStart:(id)sender { (void)sender; [self deleteTowards:@"lineStart"]; }
- (void)deleteToLogicalLineEnd:(id)sender { (void)sender; [self deleteTowards:@"lineEnd"]; }
- (void)deleteLogicalLines:(id)sender {
  (void)sender;
  if (self.hasMarkedText) [self unmarkText];
  if (self.hasRectangularSelection) { NSBeep(); return; }
  const auto& buffer = self.sakuraDocument.documentSession.buffer();
  NSRange selection = self.committedSelection;
  NSUInteger first = buffer.positionAt(selection.location).line;
  NSUInteger last = buffer.positionAt(selection.length ? NSMaxRange(selection) - 1 : selection.location).line;
  NSUInteger start = buffer.lineStartOffset(first);
  NSUInteger end = last + 1 < buffer.lineCount() ? buffer.lineStartOffset(last + 1) : buffer.length();
  // Removing the final unterminated line consumes the preceding EOL, but no
  // code unit of the previous line. CRLF is always removed as a complete pair.
  if (last + 1 == buffer.lineCount() && first > 0) {
    start = buffer.lineStartOffset(first - 1) + buffer.line(first - 1).content.length();
  }
  if (end > start) [self replaceCommittedRange:NSMakeRange(start, end - start) withString:@""];
}

- (NSPasteboard*)clipboardForCommands { return NSPasteboard.generalPasteboard; }
- (void)copyCommandString:(NSString*)text {
  if (!text) { NSBeep(); return; }
  NSPasteboard* clipboard = [self clipboardForCommands];
  [clipboard clearContents];
  [clipboard writeObjects:@[text]];
}
- (void)copyFileName:(id)sender { (void)sender; [self copyCommandString:self.sakuraDocument.fileURL.lastPathComponent]; }
- (void)copyFilePath:(id)sender { (void)sender; [self copyCommandString:self.sakuraDocument.fileURL.path]; }
- (void)copyFileLocation:(id)sender {
  (void)sender;
  NSString* path = self.sakuraDocument.fileURL.path;
  if (!path) { NSBeep(); return; }
  auto position = self.sakuraDocument.documentSession.buffer().positionAt(self.currentDocumentOffset);
  [self copyCommandString:[NSString stringWithFormat:@"%@:%zu:%llu", path,
      position.line + 1, (unsigned long long)position.column + 1]];
}
- (void)copyWithCRLF:(id)sender {
  (void)sender;
  if (self.hasMarkedText) [self unmarkText];
  NSString* whole = [self committedString];
  NSMutableArray<NSString*>* rows = [NSMutableArray array];
  NSArray<NSDictionary*>* selections = self.hasRectangularSelection ? [self rectangularSelections] :
      @[@{@"committedRange":[NSValue valueWithRange:self.committedSelection]}];
  for (NSDictionary* selection in selections) {
    NSMutableString* row = [[whole substringWithRange:[selection[@"committedRange"] rangeValue]] mutableCopy];
    NSUInteger spaces = [selection[@"trailingVirtualSpaces"] unsignedIntegerValue];
    if (spaces) [row appendString:[@"" stringByPaddingToLength:spaces withString:@" " startingAtIndex:0]];
    NSString* text = row;
    text = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
        stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    [rows addObject:[text stringByReplacingOccurrencesOfString:@"\n" withString:@"\r\n"]];
  }
  if (self.hasRectangularSelection || self.committedSelection.length)
    [self copyCommandString:[rows componentsJoinedByString:@"\r\n"]];
}
@end
