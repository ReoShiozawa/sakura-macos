// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#import <AppKit/AppKit.h>

#include <iostream>

#import "SakuraDocument.h"
#import "SakuraEditorView.h"
#import "SearchTestSupport.h"
#include "sakura/platform/mac/StringBridge.h"

@interface SakuraEditorView (SearchTests)
- (void)findNext:(id)sender;
- (void)replaceSearchSelection:(id)sender;
@end

// Isolated document objects: these tests never open a real user's documents or
// start recovery timers, and all panels remain hidden.
@interface SearchTestDocument : SakuraDocument
@end
@implementation SearchTestDocument
- (void)noteEditorChange:(NSDocumentChangeType)changeType { (void)changeType; }
@end

namespace {
int failures = 0;
void expect(bool condition, const char* message) {
  if (!condition) { std::cerr << message << '\n'; ++failures; }
}

struct Fixture {
  SearchTestDocument* document;
  SakuraEditorView* view;
  NSSearchField* find;
  NSTextField* replacement;
  NSButton* regex;

  explicit Fixture(NSString* text) {
    document = [[SearchTestDocument alloc] init];
    document.documentSession.insert(0,
        sakura::platform::mac::sakuraStringFromString(text));
    view = [[SakuraEditorView alloc] initWithFrame:NSMakeRect(0, 0, 640, 400)
                                        document:document];
    find = [[NSSearchField alloc] init];
    replacement = [[NSTextField alloc] init];
    regex = [[NSButton alloc] init];
    regex.state = NSControlStateValueOn;
    [view setValue:[[NSPanel alloc] init] forKey:@"findPanel"];
    [view setValue:find forKey:@"findField"];
    [view setValue:replacement forKey:@"replaceField"];
    [view setValue:regex forKey:@"regularExpressionButton"];
    [view setValue:[[NSTextField alloc] init] forKey:@"findStatusLabel"];
    NSButton* sensitive = [[NSButton alloc] init];
    sensitive.state = NSControlStateValueOn;
    [view setValue:sensitive forKey:@"caseSensitiveButton"];
    [view setValue:[[NSButton alloc] init] forKey:@"wholeWordButton"];
  }

  void selection(NSUInteger location, NSUInteger length, const char* message) {
    expect(SakuraWaitForSearchNavigation(view), "async search reached terminal state");
    expect(NSEqualRanges(view.selectedRange, NSMakeRange(location, length)), message);
  }
};

void zeroWidthNextSearchAdvancesAndWraps() {
  Fixture fixture(@"aa");
  fixture.find.stringValue = @"(?=a)|$";
  [fixture.view findNext:nil];
  fixture.selection(0, 0, "first zero width match at zero");
  [fixture.view findNext:nil];
  fixture.selection(1, 0, "zero width next advances");
  [fixture.view findNext:nil];
  fixture.selection(2, 0, "zero width includes document end");
  [fixture.view findNext:nil];
  fixture.selection(0, 0, "zero width wraps after document end");

  Fixture emoji(@"😀");
  emoji.find.stringValue = @"(?=.)|$";
  [emoji.view findNext:nil];
  emoji.selection(0, 0, "emoji zero width start");
  [emoji.view findNext:nil];
  emoji.selection(2, 0, "zero width skips low surrogate boundary");
}

void singleReplaceRetainsRegexFlagsAndCaptures() {
  Fixture fixture(@"ab ab");
  fixture.find.stringValue = @"a(?=(b))";
  fixture.replacement.stringValue = @"[$1]";
  [fixture.view findNext:nil];
  fixture.selection(0, 1, "lookahead selected before replace");
  [fixture.view replaceSearchSelection:nil];
  expect(SakuraWaitForReplacement(fixture.view), "single replacement reaches terminal state");
  expect(fixture.document.documentSession.buffer().text() == u"[b]b ab",
         "single replace uses lookahead capture from original context");
  fixture.selection(5, 1, "single replace selects next regex match");
  expect(fixture.document.documentSession.undo(), "single regex replace undo");
  expect(fixture.document.documentSession.buffer().text() == u"ab ab",
         "single regex replace undo restores original");

  Fixture insensitive(@"桜A");
  ((NSButton*)[insensitive.view valueForKey:@"caseSensitiveButton"]).state =
      NSControlStateValueOff;
  insensitive.find.stringValue = @"(桜a)";
  insensitive.replacement.stringValue = @"<$1>";
  [insensitive.view findNext:nil];
  expect(SakuraWaitForSearchNavigation(insensitive.view), "case-insensitive search completed before replace");
  [insensitive.view replaceSearchSelection:nil];
  expect(SakuraWaitForReplacement(insensitive.view), "case-insensitive replacement reaches terminal state");
  expect(insensitive.document.documentSession.buffer().text() == u"<桜A>",
         "single replace preserves Unicode case-insensitive regex option");
}

void zeroWidthReplaceDoesNotReselectTheSameOriginalCharacter() {
  Fixture fixture(@"aa");
  fixture.find.stringValue = @"(?=a)|$";
  fixture.replacement.stringValue = @"X";
  [fixture.view findNext:nil];
  expect(SakuraWaitForSearchNavigation(fixture.view), "zero-width search completed before replace");
  [fixture.view replaceSearchSelection:nil];
  expect(SakuraWaitForReplacement(fixture.view), "first zero-width replacement reaches terminal state");
  expect(fixture.document.documentSession.buffer().text() == u"Xaa",
         "zero width insertion preserves source character");
  fixture.selection(2, 0, "zero width replace advances beyond original character");
  [fixture.view replaceSearchSelection:nil];
  expect(SakuraWaitForReplacement(fixture.view), "second zero-width replacement reaches terminal state");
  expect(fixture.document.documentSession.buffer().text() == u"XaXa",
         "second zero width replacement targets next original character");
  fixture.selection(4, 0, "zero width replace progresses to document end");
}
}  // namespace

int main() {
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    zeroWidthNextSearchAdvancesAndWraps();
    singleReplaceRetainsRegexFlagsAndCaptures();
    zeroWidthReplaceDoesNotReselectTheSameOriginalCharacter();
  }
  if (failures) return 1;
  std::cout << "All editor search tests passed\n";
  return 0;
}
