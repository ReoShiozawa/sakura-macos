// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#import "SakuraDocument.h"
#import "SakuraEditorView.h"
#import "SakuraAppDelegate.h"
#include "sakura/platform/mac/StringBridge.h"
#include <iostream>

@interface CommandTestDocument : SakuraDocument
@end
@implementation CommandTestDocument
- (void)noteEditorChange:(NSDocumentChangeType)changeType { (void)changeType; }
@end

@interface ExtraCommandView : SakuraEditorView
@property(nonatomic, copy) NSString* capturedCopy;
@end
@implementation ExtraCommandView
- (void)copyCommandString:(NSString*)text { if (text) self.capturedCopy = text; }
- (NSDate*)dateForInsertion {
  NSCalendar* calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
  NSDateComponents* parts = [[NSDateComponents alloc] init];
  parts.year = 2001; parts.month = 2; parts.day = 3;
  parts.hour = 4; parts.minute = 5; parts.second = 6;
  return [calendar dateFromComponents:parts];
}
@end

namespace {
int failures = 0;
void check(bool ok, const char* label) {
  if (!ok) { std::cerr << label << '\n'; ++failures; }
}
struct Fixture {
  CommandTestDocument* document;
  SakuraEditorView* view;
  NSScrollView* scroll;
  Fixture(NSString* text) {
    document = [[CommandTestDocument alloc] init];
    document.documentSession.insert(0, sakura::platform::mac::sakuraStringFromString(text));
    view = [[ExtraCommandView alloc] initWithFrame:NSMakeRect(0, 0, 700, 200) document:document];
    scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 700, 120)];
    scroll.documentView = view;
  }
  NSString* text() { return sakura::platform::mac::stringFromSakuraString(document.documentSession.buffer().text()); }
  void select(NSUInteger start, NSUInteger length) {
    [view setValue:[NSValue valueWithRange:NSMakeRange(start, length)] forKey:@"committedSelection"];
  }
  void all() { [view selectAll:nil]; }
  void command(SEL selector) { [view doCommandBySelector:selector]; }
};
void roundTrip(NSString* input, NSString* output, SEL selector) {
  Fixture f(input); f.all(); f.command(selector);
  check([f.text() isEqual:output], sel_getName(selector));
  check(f.document.documentSession.undo(), "one undo available");
  [f.view documentContentsDidChange];
  check([f.text() isEqual:input], "one undo restores exact source");
  check(f.document.documentSession.redo(), "one redo available");
  [f.view documentContentsDidChange];
  check([f.text() isEqual:output], "one redo restores transformed source");
}
void deleteAt(NSString* input, NSString* output, NSUInteger offset, SEL selector) {
  Fixture f(input); [f.view jumpToDocumentOffset:offset]; f.command(selector);
  check([f.text() isEqual:output], sel_getName(selector));
  check(f.document.documentSession.undo(), "delete is undoable");
  check([f.text() isEqual:input], "delete undo preserves exact CRLF and Unicode");
}
void verifyMenu(NSMenu* menu, NSUInteger* found) {
  NSArray<NSString*>* names = @[@"showLineJump:", @"toggleBookmark:", @"nextBookmark:",
      @"previousBookmark:", @"clearBookmarks:", @"showBookmarks:", @"indentWithTab:",
      @"unindentWithTab:", @"indentWithSpaces:", @"unindentWithSpaces:",
      @"trimLeadingWhitespace:", @"trimTrailingWhitespace:", @"sortLinesAscending:",
      @"sortLinesDescending:", @"uniqueConsecutiveLines:", @"duplicateLogicalLines:",
      @"convertToHalfwidth:", @"convertToFullwidthKatakana:", @"convertToFullwidthHiragana:",
      @"tabsToSpaces:", @"spacesToTabs:",
      @"moveWordLeft:", @"moveWordRight:", @"pageUp:", @"pageDown:",
      @"moveToBeginningOfLine:", @"moveToEndOfLine:",
      @"moveWordLeftAndModifySelection:", @"moveWordRightAndModifySelection:",
      @"pageUpAndModifySelection:", @"pageDownAndModifySelection:",
      @"moveToBeginningOfLineAndModifySelection:", @"moveToEndOfLineAndModifySelection:",
      @"moveToBeginningOfDocumentAndModifySelection:", @"moveToEndOfDocumentAndModifySelection:",
      @"insertDate:", @"insertTime:", @"selectCurrentWord:", @"deleteCurrentWord:",
      @"deleteWordToLeft:", @"deleteWordToRight:", @"deleteToLogicalLineStart:",
      @"deleteToLogicalLineEnd:", @"deleteLogicalLines:", @"copyFileName:", @"copyFilePath:",
      @"copyFileLocation:", @"copyWithCRLF:"];
  for (NSMenuItem* item in menu.itemArray) {
    if ([names containsObject:NSStringFromSelector(item.action)]) {
      check(item.enabled, "new command menu enabled"); ++*found;
      check([SakuraEditorView instancesRespondToSelector:item.action], "menu action implemented");
    }
    if (item.submenu) verifyMenu(item.submenu, found);
  }
}
}
int main() {
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    NSDictionary* oldArguments = [NSUserDefaults.standardUserDefaults volatileDomainForName:NSArgumentDomain];
    [NSUserDefaults.standardUserDefaults setVolatileDomain:@{@"SakuraEditorTabWidth":@4}
                                                 forName:NSArgumentDomain];
    roundTrip(@"b\r\na\nc\r", @"a\r\nb\nc\r", @selector(sortLinesAscending:));
    roundTrip(@"b\r\na\nc", @"c\r\nb\na", @selector(sortLinesDescending:));
    roundTrip(@"a\r\na\nb", @"a\r\nb", @selector(uniqueConsecutiveLines:));
    roundTrip(@"a\na", @"a", @selector(uniqueConsecutiveLines:));
    roundTrip(@"a\na\n", @"a\n", @selector(uniqueConsecutiveLines:));
    roundTrip(@" a\t\r\n\tb  \n", @" a\r\n\tb\n", @selector(trimTrailingWhitespace:));
    roundTrip(@" a\t\r\n\tb  \n", @"a\t\r\nb  \n", @selector(trimLeadingWhitespace:));
    roundTrip(@"a\r\nb\n", @"\ta\r\n\tb\n", @selector(indentWithTab:));
    roundTrip(@"a\r\nb", @"    a\r\n    b", @selector(indentWithSpaces:));
    roundTrip(@"\ta\n  b\n    c", @"a\nb\nc", @selector(unindentWithTab:));
    roundTrip(@"\ta\n  b\n    c", @"a\nb\nc", @selector(unindentWithSpaces:));
    roundTrip(@"a\r\nb", @"a\r\nb\na\r\nb", @selector(duplicateLogicalLines:));
    roundTrip(@"a\r\nb\r\n", @"a\r\nb\r\na\r\nb\r\n", @selector(duplicateLogicalLines:));
    roundTrip(@"ＡＢＣ ガ😀", @"ABC ｶﾞ😀", @selector(convertToHalfwidth:));
    roundTrip(@"abc ｶﾞ ひらがな😀", @"ａｂｃ　ガ　ヒラガナ😀", @selector(convertToFullwidthKatakana:));
    roundTrip(@"ｶﾞ カタカナ", @"が　かたかな", @selector(convertToFullwidthHiragana:));
    roundTrip(@"a\tb\r\n\tx", @"a   b\r\n    x", @selector(tabsToSpaces:));
    roundTrip(@"a   b\r\n    x", @"a\tb\r\n\tx", @selector(spacesToTabs:));
    roundTrip(@"あ\t😀\te\u0301\t", @"あ  😀  e\u0301   ", @selector(tabsToSpaces:));
    roundTrip(@"あ  😀  e\u0301   ", @"あ\t😀\te\u0301\t", @selector(spacesToTabs:));
    deleteAt(@"one two", @"one ", 4, @selector(deleteWordToRight:));
    deleteAt(@"one two", @"one ", 7, @selector(deleteWordToLeft:));
    deleteAt(@"one two", @"one ", 5, @selector(deleteCurrentWord:));
    deleteAt(@"A😀e\u0301\r\nB", @"Ae\u0301\r\nB", 1, @selector(deleteCurrentWord:));
    deleteAt(@"ab😀x\r\nB", @"x\r\nB", 4, @selector(deleteToLogicalLineStart:));
    deleteAt(@"ab😀x\r\nB", @"ab\r\nB", 2, @selector(deleteToLogicalLineEnd:));
    deleteAt(@"a\r\nb", @"a", 3, @selector(deleteLogicalLines:));
    deleteAt(@"a\r\nb\r\nc", @"a\r\nc", 3, @selector(deleteLogicalLines:));
    {
      Fixture f(@"one two"); [f.view jumpToDocumentOffset:5];
      f.command(@selector(selectCurrentWord:));
      check(NSEqualRanges(f.view.selectedRange, NSMakeRange(4, 3)), "select current word");
    }
    roundTrip(@"selection", @"2001/02/03", @selector(insertDate:));
    roundTrip(@"selection", @"04:05:06", @selector(insertTime:));
    {
      Fixture f(@"X"); [f.view jumpToDocumentOffset:1];
      [f.view setMarkedText:@"未確定" selectedRange:NSMakeRange(3, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
      f.command(@selector(insertDate:));
      check([f.text() isEqual:@"X未確定2001/02/03"], "date insertion commits marked text first");
    }
    {
      Fixture f(@"a\r\nb\rc\nd"); f.all(); f.command(@selector(copyWithCRLF:));
      ExtraCommandView* view = (ExtraCommandView*)f.view;
      check([view.capturedCopy isEqual:@"a\r\nb\r\nc\r\nd"], "CRLF copy normalizes all EOLs");
      check([f.text() isEqual:@"a\r\nb\rc\nd"], "CRLF copy does not edit source");
      f.document.fileURL = [NSURL fileURLWithPath:@"/Demo/test.cpp"];
      f.command(@selector(copyFileName:)); check([view.capturedCopy isEqual:@"test.cpp"], "copy file name");
      f.command(@selector(copyFilePath:)); check([view.capturedCopy isEqual:@"/Demo/test.cpp"], "copy file path");
      [f.view jumpToDocumentOffset:4];
      f.command(@selector(copyFileLocation:)); check([view.capturedCopy isEqual:@"/Demo/test.cpp:2:2"], "copy file line and column");
      f.document.fileURL = nil; f.command(@selector(copyFilePath:));
      check([view.capturedCopy isEqual:@"/Demo/test.cpp:2:2"], "untitled copy keeps clipboard");
    }
    {
      Fixture f(@"\ta\tb"); f.select(2, 1); f.command(@selector(tabsToSpaces:));
      check([f.text() isEqual:@"\ta   b"], "partial selection uses preceding tab stops");
    }
    {
      Fixture f(@"a\nb\n"); f.all(); f.command(@selector(insertTab:));
      check([f.text() isEqual:@"\ta\n\tb\n"], "TAB indents selected lines");
      f.command(@selector(insertBacktab:));
      check([f.text() isEqual:@"a\nb\n"], "shift TAB unindents selected lines");
    }
    {
      Fixture f(@"a\nb"); f.all();
      auto before = f.document.documentSession.makeSaveSnapshot().token;
      f.command(@selector(sortLinesAscending:));
      check(f.document.documentSession.makeSaveSnapshot().token.stateId == before.stateId,
            "no-op sort adds no undo record");
    }
    {
      Fixture f(@"b\na\nc"); f.select(0, 4); f.command(@selector(sortLinesAscending:));
      check([f.text() isEqual:@"a\nb\nc"], "selection at next line start excludes that line");
      check(NSEqualRanges(f.view.selectedRange, NSMakeRange(0, 4)), "selection retains transformed block");
    }
    {
      Fixture f(@"a\r\n😀\rb\n");
      check(![f.view jumpToLogicalLine:0] && ![f.view jumpToLogicalLine:5], "invalid line jump rejected");
      check([f.view jumpToLogicalLine:2] && f.view.currentDocumentOffset == 3, "logical jump CRLF");
      [f.view toggleBookmark:nil];
      [f.view jumpToLogicalLine:3]; [f.view toggleBookmark:nil];
      check(f.document.bookmarkLines.count == 2, "two bookmarks");
      [f.view nextBookmark:nil]; check(f.view.currentDocumentOffset == 3, "bookmark wraps forward");
      [f.view previousBookmark:nil]; check(f.view.currentDocumentOffset == 6, "bookmark wraps backwards");
      SakuraEditorView* second = [[SakuraEditorView alloc] initWithFrame:NSMakeRect(0, 0, 700, 200) document:f.document];
      [second nextBookmark:nil]; check(second.currentDocumentOffset == 3, "panes share bookmarks");
      f.document.documentSession.insert(0, u"prefix\n"); [f.document refreshEditorViews];
      check([f.document.bookmarkLines containsIndex:2] && [f.document.bookmarkLines containsIndex:3], "bookmarks track insertion");
      f.document.documentSession.undo(); [f.document refreshEditorViews];
      check([f.document.bookmarkLines containsIndex:1] && [f.document.bookmarkLines containsIndex:2], "bookmarks track undo");
      [f.view clearBookmarks:nil]; check(f.document.bookmarkLines.count == 0, "clear bookmarks");
    }
    {
      SakuraAppDelegate* delegate = [[SakuraAppDelegate alloc] init];
      [delegate applicationWillFinishLaunching:[NSNotification notificationWithName:NSApplicationWillFinishLaunchingNotification object:NSApp]];
      NSUInteger count = 0; verifyMenu(NSApp.mainMenu, &count);
      check(count == 49, "new commands and navigation connected to menu");
    }
    [NSUserDefaults.standardUserDefaults setVolatileDomain:oldArguments forName:NSArgumentDomain];
  }
  return failures ? 1 : 0;
}
