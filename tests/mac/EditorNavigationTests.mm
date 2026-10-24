// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#import <AppKit/AppKit.h>

#include <iostream>
#include <string_view>

#import "SakuraDocument.h"
#import "SakuraEditorView.h"
#include "sakura/platform/mac/StringBridge.h"

@interface SakuraEditorView (NavigationTestGeometry)
- (NSRect)localRectForDisplayIndex:(NSUInteger)index;
@end

// These tests construct their own objects and never start document recovery
// timers, open files, or send events to another application's windows.
@interface NavigationTestDocument : SakuraDocument
@end
@implementation NavigationTestDocument
- (void)noteEditorChange:(NSDocumentChangeType)changeType { (void)changeType; }
@end

namespace {

int failures = 0;

void expect(bool condition, std::string_view test, std::string_view expression,
            int line) {
  if (condition) return;
  std::cerr << test << ':' << line << ": " << expression << '\n';
  ++failures;
}

#define EXPECT(test, expression) expect((expression), test, #expression, __LINE__)

void expectSelection(SakuraEditorView* view, NSRange expected,
                     std::string_view test, int line) {
  const NSRange actual = view.selectedRange;
  if (NSEqualRanges(actual, expected)) return;
  std::cerr << test << ':' << line << ": expected selection "
            << expected.location << ',' << expected.length << ", got "
            << actual.location << ',' << actual.length << '\n';
  ++failures;
}

#define EXPECT_SELECTION(test, view, location, length) \
  expectSelection(view, NSMakeRange(location, length), test, __LINE__)

struct Fixture {
  NavigationTestDocument* document;
  SakuraEditorView* view;
  NSScrollView* scroll;

  explicit Fixture(NSString* text) {
    document = [[NavigationTestDocument alloc] init];
    document.documentSession.insert(0,
        sakura::platform::mac::sakuraStringFromString(text));
    view = [[SakuraEditorView alloc] initWithFrame:NSMakeRect(0, 0, 700, 200)
                                        document:document];
    scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 700, 120)];
    scroll.documentView = view;
  }

  void command(SEL selector) { [view doCommandBySelector:selector]; }
};

void shiftSelectionPreservesAnchorAcrossDirectionChanges() {
  constexpr std::string_view test = "shiftSelectionPreservesAnchorAcrossDirectionChanges";
  Fixture fixture(@"abcdef");
  [fixture.view jumpToDocumentOffset:4];
  fixture.command(@selector(moveLeftAndModifySelection:));
  fixture.command(@selector(moveLeftAndModifySelection:));
  EXPECT_SELECTION(test, fixture.view, 2, 2);
  fixture.command(@selector(moveRightAndModifySelection:));
  EXPECT_SELECTION(test, fixture.view, 3, 1);
  fixture.command(@selector(moveRightAndModifySelection:));
  fixture.command(@selector(moveRightAndModifySelection:));
  EXPECT_SELECTION(test, fixture.view, 4, 1);
  fixture.command(@selector(moveLeftAndModifySelection:));
  EXPECT_SELECTION(test, fixture.view, 4, 0);
  fixture.command(@selector(moveLeftAndModifySelection:));
  EXPECT_SELECTION(test, fixture.view, 3, 1);
  fixture.command(@selector(moveLeft:));
  EXPECT_SELECTION(test, fixture.view, 3, 0);
  fixture.command(@selector(moveRightAndModifySelection:));
  EXPECT_SELECTION(test, fixture.view, 3, 1);
}

void navigationProtectsGraphemesAndCrLf() {
  constexpr std::string_view test = "navigationProtectsGraphemesAndCrLf";
  Fixture fixture(@"Ae\u0301😀\r\nB");
  [fixture.view jumpToDocumentOffset:1];
  fixture.command(@selector(moveRightAndModifySelection:));
  EXPECT_SELECTION(test, fixture.view, 1, 2);  // e + combining acute
  fixture.command(@selector(moveRightAndModifySelection:));
  EXPECT_SELECTION(test, fixture.view, 1, 4);  // entire surrogate pair
  fixture.command(@selector(moveRightAndModifySelection:));
  EXPECT_SELECTION(test, fixture.view, 1, 6);  // entire CRLF
  fixture.command(@selector(moveLeftAndModifySelection:));
  EXPECT_SELECTION(test, fixture.view, 1, 4);
  fixture.command(@selector(moveLeftAndModifySelection:));
  EXPECT_SELECTION(test, fixture.view, 1, 2);
  fixture.command(@selector(moveLeftAndModifySelection:));
  EXPECT_SELECTION(test, fixture.view, 1, 0);
  [fixture.view jumpToDocumentOffset:5];
  fixture.command(@selector(moveRight:));
  EXPECT_SELECTION(test, fixture.view, 7, 0);
  fixture.command(@selector(moveLeft:));
  EXPECT_SELECTION(test, fixture.view, 5, 0);
}

void wordAndLineCommandsRespectSelectionDirection() {
  constexpr std::string_view test = "wordAndLineCommandsRespectSelectionDirection";
  Fixture fixture(@"foo_bar  baz\r\nqux");
  fixture.command(@selector(moveWordRight:));
  EXPECT_SELECTION(test, fixture.view, 7, 0);
  fixture.command(@selector(moveWordRightAndModifySelection:));
  EXPECT_SELECTION(test, fixture.view, 7, 5);
  fixture.command(@selector(moveWordLeftAndModifySelection:));
  EXPECT_SELECTION(test, fixture.view, 7, 2);
  fixture.command(@selector(moveWordLeftAndModifySelection:));
  EXPECT_SELECTION(test, fixture.view, 0, 7);
  [fixture.view jumpToDocumentOffset:4];
  fixture.command(@selector(moveToBeginningOfLineAndModifySelection:));
  EXPECT_SELECTION(test, fixture.view, 0, 4);
  fixture.command(@selector(moveToEndOfLineAndModifySelection:));
  EXPECT_SELECTION(test, fixture.view, 4, 8);
  fixture.command(@selector(moveToEndOfDocumentAndModifySelection:));
  EXPECT_SELECTION(test, fixture.view, 4, 13);
  fixture.command(@selector(moveToBeginningOfDocumentAndModifySelection:));
  EXPECT_SELECTION(test, fixture.view, 0, 4);
}

void verticalAndPageCommandsKeepTheirDesiredColumn() {
  constexpr std::string_view test = "verticalAndPageCommandsKeepTheirDesiredColumn";
  Fixture fixture(@"abcdef\nx\nabcdef\nabcdef\nabcdef\nabcdef\nabcdef\nabcdef\nabcdef\nabcdef");
  [fixture.view jumpToDocumentOffset:5];
  fixture.command(@selector(moveDown:));
  EXPECT_SELECTION(test, fixture.view, 8, 0);
  fixture.command(@selector(moveDown:));
  EXPECT_SELECTION(test, fixture.view, 14, 0);
  fixture.command(@selector(moveUpAndModifySelection:));
  EXPECT_SELECTION(test, fixture.view, 8, 6);
  fixture.command(@selector(moveDownAndModifySelection:));
  EXPECT_SELECTION(test, fixture.view, 14, 0);
  [fixture.view jumpToDocumentOffset:0];
  fixture.command(@selector(pageDownAndModifySelection:));
  const NSRange page = fixture.view.selectedRange;
  EXPECT(test, page.location == 0);
  EXPECT(test, page.length > 9);
  EXPECT(test, page.length < fixture.document.documentSession.buffer().length());
  fixture.command(@selector(pageUpAndModifySelection:));
  EXPECT_SELECTION(test, fixture.view, 0, 0);
}

void doubleClickSelectsWordsAndShiftClickKeepsAnchor() {
  constexpr std::string_view test = "doubleClickSelectsWordsAndShiftClickKeepsAnchor";
  Fixture fixture(@"one two_three four");
  const auto click = [&](NSUInteger index, NSInteger count,
                         NSEventModifierFlags modifiers) {
    const NSRect rect = [fixture.view localRectForDisplayIndex:index];
    const NSPoint point = [fixture.view convertPoint:
        NSMakePoint(rect.origin.x + 0.1, NSMidY(rect)) toView:nil];
    NSEvent* event = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                      location:point modifierFlags:modifiers
                                     timestamp:0 windowNumber:0 context:nil
                                   eventNumber:0 clickCount:count pressure:1];
    [fixture.view mouseDown:event];
    [fixture.view mouseUp:event];
  };
  click(7, 2, 0);
  EXPECT_SELECTION(test, fixture.view, 4, 9);
  click(2, 1, NSEventModifierFlagShift);
  EXPECT_SELECTION(test, fixture.view, 2, 2);
  click(16, 1, NSEventModifierFlagShift);
  EXPECT_SELECTION(test, fixture.view, 4, 12);
}

void imeCommitAndRectangleNavigationStillWork() {
  constexpr std::string_view test = "imeCommitAndRectangleNavigationStillWork";
  Fixture fixture(@"abc\ndef");
  [fixture.view setMarkedText:@"桜" selectedRange:NSMakeRange(1, 0)
             replacementRange:NSMakeRange(NSNotFound, 0)];
  EXPECT(test, fixture.view.hasMarkedText);
  fixture.command(@selector(moveRightAndModifySelection:));
  EXPECT(test, !fixture.view.hasMarkedText);
  EXPECT(test, fixture.document.documentSession.buffer().text() == u"桜abc\ndef");
  EXPECT_SELECTION(test, fixture.view, 1, 1);
  Fixture rectangle(@"abc\ndef");
  [rectangle.view toggleRectangularSelection:nil];
  rectangle.command(@selector(moveRight:));
  rectangle.command(@selector(moveDown:));
  EXPECT(test, rectangle.view.hasRectangularSelection);
  EXPECT(test, rectangle.view.selectedCharacterCount == 2);
}

}  // namespace

int main() {
  @autoreleasepool {
    [NSApplication sharedApplication];
    shiftSelectionPreservesAnchorAcrossDirectionChanges();
    navigationProtectsGraphemesAndCrLf();
    wordAndLineCommandsRespectSelectionDirection();
    verticalAndPageCommandsKeepTheirDesiredColumn();
    doubleClickSelectsWordsAndShiftClickKeepsAnchor();
    imeCommitAndRectangleNavigationStillWork();
  }
  if (failures != 0) {
    std::cerr << failures << " editor navigation test(s) failed\n";
    return 1;
  }
  std::cout << "All editor navigation tests passed\n";
  return 0;
}
