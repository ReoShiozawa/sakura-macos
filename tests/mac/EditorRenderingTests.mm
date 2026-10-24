// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <iostream>
#include <string_view>
#include <vector>

#import "SakuraDocument.h"
#import "SakuraEditorView.h"
#include "sakura/core/syntax/SyntaxHighlighter.h"
#include "sakura/platform/mac/StringBridge.h"

@interface SakuraEditorView (RenderingTestDiagnostics)
- (NSDictionary<NSString*, NSNumber*>*)renderingStatistics;
- (const std::vector<NSRange>&)displayLineRanges;
- (NSString*)displayString;
- (NSRect)localRectForDisplayIndex:(NSUInteger)index;
- (NSUInteger)displayIndexForLocalPoint:(NSPoint)point;
- (const std::vector<sakura::core::SyntaxToken>&)activeSyntaxTokens;
- (const std::vector<NSRange>&)activeSearchRanges;
- (CGFloat)editorLineHeight;
- (NSDictionary<NSAttributedStringKey, id>*)baseTextAttributes;
- (void)updateDocumentViewSize;
@end

// No windows are ordered, document services are never started, and drawing is
// confined to an in-memory bitmap. Preferences use a volatile override domain.
@interface RenderingTestDocument : SakuraDocument
@end
@implementation RenderingTestDocument
- (void)noteEditorChange:(NSDocumentChangeType)changeType { (void)changeType; }
@end

@interface RenderingTestSearchPanel : NSPanel
@end
@implementation RenderingTestSearchPanel
- (BOOL)isVisible { return YES; }
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

using Statistics = NSDictionary<NSString*, NSNumber*>*;

NSUInteger count(Statistics statistics, NSString* key) {
  return [statistics[key] unsignedIntegerValue];
}

void expectBuildsUnchanged(Statistics before, Statistics after,
                          std::string_view test, int line) {
  for (NSString* key in @[ @"textBuilds", @"layoutBuilds", @"syntaxBuilds",
                           @"searchBuilds", @"styledBuilds" ]) {
    if (before[key] != nil && after[key] != nil &&
        [before[key] isEqualToNumber:after[key]]) continue;
    std::cerr << test << ':' << line << ": " << key.UTF8String
              << " changed from " << count(before, key)
              << " to " << count(after, key) << '\n';
    ++failures;
  }
}

#define EXPECT_STABLE(test, before, after) \
  expectBuildsUnchanged(before, after, test, __LINE__)

struct Preferences {
  NSDictionary* saved;
  NSMutableDictionary* values;

  Preferences() {
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    saved = [defaults volatileDomainForName:NSArgumentDomain];
    if (saved == nil) saved = @{};
    values = [saved mutableCopy];
    values[@"SakuraEditorFontSize"] = @13;
    values[@"SakuraEditorTabWidth"] = @4;
    values[@"SakuraEditorColorTheme"] = @"windows-classic";
    for (NSString* type in @[ @"basic", @"cpp", @"text" ]) {
      NSDictionary* properties = @{
        @"wrapMode" : @1, @"wrapColumn" : @120, @"tabWidth" : @4,
        @"fontName" : @"", @"fontSize" : @13, @"lineSpacing" : @3,
        @"characterSpacing" : @0, @"showsLineNumbers" : @YES,
      };
      for (NSString* property in properties) {
        values[[NSString stringWithFormat:@"SakuraTypeEditor.%@.%@", type,
                                             property]] = properties[property];
      }
    }
    [defaults setVolatileDomain:values forName:NSArgumentDomain];
  }

  void set(NSString* key, id value) {
    values[key] = value;
    [NSUserDefaults.standardUserDefaults setVolatileDomain:values
                                                   forName:NSArgumentDomain];
  }

  ~Preferences() {
    [NSUserDefaults.standardUserDefaults setVolatileDomain:saved
                                                   forName:NSArgumentDomain];
  }
};

struct Fixture {
  RenderingTestDocument* document;
  SakuraEditorView* view;
  NSScrollView* scroll;
  NSSearchField* find;
  NSBitmapImageRep* bitmap;

  explicit Fixture(NSString* text) {
    document = [[RenderingTestDocument alloc] init];
    document.fileURL = [NSURL fileURLWithPath:@"/rendering-tests/source.cpp"];
    document.documentSession.insert(
        0, sakura::platform::mac::sakuraStringFromString(text));
    view = [[SakuraEditorView alloc] initWithFrame:NSMakeRect(0, 0, 700, 200)
                                        document:document];
    view.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 700, 160)];
    scroll.documentView = view;
    find = [[NSSearchField alloc] init];
    find.stringValue = @"int";
    [view setValue:[[RenderingTestSearchPanel alloc] init] forKey:@"findPanel"];
    [view setValue:find forKey:@"findField"];
    NSButton* sensitive = [[NSButton alloc] init];
    sensitive.state = NSControlStateValueOn;
    [view setValue:sensitive forKey:@"caseSensitiveButton"];
    [view setValue:[[NSButton alloc] init] forKey:@"wholeWordButton"];
    [view setValue:[[NSButton alloc] init] forKey:@"regularExpressionButton"];
    bitmap = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:nullptr pixelsWide:800 pixelsHigh:300
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
  }

  void draw(NSRect dirty = NSMakeRect(0, 0, 700, 160)) {
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext =
        [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    [view drawRect:dirty];
    [NSGraphicsContext restoreGraphicsState];
  }

  Statistics statistics() { return [view renderingStatistics]; }
};

void unchangedDocumentAndSelectionReuseRenderingWork() {
  constexpr std::string_view test =
      "unchangedDocumentAndSelectionReuseRenderingWork";
  Preferences preferences;
  Fixture fixture(@"int first = 1;\n// comment\nint second = 2;\nreturn first;\n");
  fixture.draw();
  Statistics warm = fixture.statistics();
  for (NSString* key in @[ @"textBuilds", @"layoutBuilds", @"syntaxBuilds",
                           @"searchBuilds", @"styledBuilds", @"drawnLines",
                           @"lineLookupSteps" ]) {
    EXPECT(test, warm[key] != nil);
  }
  EXPECT(test, count(warm, @"textBuilds") > 0);
  EXPECT(test, count(warm, @"layoutBuilds") > 0);
  EXPECT(test, count(warm, @"syntaxBuilds") > 0);
  EXPECT(test, count(warm, @"searchBuilds") > 0);
  EXPECT(test, count(warm, @"styledBuilds") > 0);
  for (NSUInteger iteration = 0; iteration < 8; ++iteration) {
    (void)[fixture.view displayLineRanges];
    (void)[fixture.view localRectForDisplayIndex:25];
    fixture.draw();
  }
  EXPECT_STABLE(test, warm, fixture.statistics());

  [fixture.view doCommandBySelector:@selector(moveRightAndModifySelection:)];
  [fixture.view doCommandBySelector:@selector(moveRightAndModifySelection:)];
  fixture.draw();
  EXPECT(test, fixture.view.selectedRange.length == 2);
  EXPECT_STABLE(test, warm, fixture.statistics());
}

void editsInvalidateTextAnalysisAndSearchOnce() {
  constexpr std::string_view test = "editsInvalidateTextAnalysisAndSearchOnce";
  Preferences preferences;
  Fixture fixture(@"int first = 1;\nint second = 2;\n");
  fixture.draw();
  Statistics before = fixture.statistics();
  fixture.document.documentSession.insert(0, u"// newly inserted\n");
  [fixture.view documentContentsDidChange];
  fixture.draw();
  Statistics changed = fixture.statistics();
  for (NSString* key in @[ @"textBuilds", @"layoutBuilds", @"syntaxBuilds",
                           @"searchBuilds" ]) {
    EXPECT(test, count(changed, key) > count(before, key));
  }
  EXPECT(test, [[fixture.view displayString] hasPrefix:@"// newly inserted\n"]);
  fixture.draw();
  (void)[fixture.view localRectForDisplayIndex:20];
  EXPECT_STABLE(test, changed, fixture.statistics());

  fixture.find.stringValue = @"second";
  fixture.draw();
  Statistics searched = fixture.statistics();
  EXPECT(test, count(searched, @"searchBuilds") > count(changed, @"searchBuilds"));
  EXPECT(test, count(searched, @"textBuilds") == count(changed, @"textBuilds"));
  EXPECT(test, count(searched, @"layoutBuilds") == count(changed, @"layoutBuilds"));
  EXPECT(test, count(searched, @"syntaxBuilds") == count(changed, @"syntaxBuilds"));
  fixture.draw();
  EXPECT_STABLE(test, searched, fixture.statistics());
}

void viewportAndTypeSettingsInvalidateOnlyDependentCaches() {
  constexpr std::string_view test =
      "viewportAndTypeSettingsInvalidateOnlyDependentCaches";
  Preferences preferences;
  Fixture fixture(@"int first = 1;\n\tint second = 2;\n");
  fixture.draw();
  Statistics previous = fixture.statistics();
  [fixture.scroll setFrameSize:NSMakeSize(450, 160)];
  [fixture.view updateDocumentViewSize];
  fixture.draw();
  Statistics resized = fixture.statistics();
  EXPECT(test, count(resized, @"layoutBuilds") > count(previous, @"layoutBuilds"));
  EXPECT(test, count(resized, @"textBuilds") == count(previous, @"textBuilds"));
  EXPECT(test, count(resized, @"syntaxBuilds") == count(previous, @"syntaxBuilds"));
  EXPECT(test, count(resized, @"searchBuilds") == count(previous, @"searchBuilds"));
  fixture.draw();
  EXPECT_STABLE(test, resized, fixture.statistics());

  for (NSString* property in @[ @"fontSize", @"tabWidth", @"characterSpacing" ]) {
    previous = fixture.statistics();
    preferences.set([@"SakuraTypeEditor.cpp." stringByAppendingString:property],
                    [property isEqualToString:@"fontSize"] ? @18
                      : [property isEqualToString:@"tabWidth"] ? @8 : @2);
    [fixture.view updateDocumentViewSize];
    fixture.draw();
    Statistics updated = fixture.statistics();
    EXPECT(test, count(updated, @"layoutBuilds") > count(previous, @"layoutBuilds"));
    EXPECT(test, count(updated, @"textBuilds") == count(previous, @"textBuilds"));
    EXPECT(test, count(updated, @"syntaxBuilds") == count(previous, @"syntaxBuilds"));
    EXPECT(test, count(updated, @"searchBuilds") == count(previous, @"searchBuilds"));
    fixture.draw();
    EXPECT_STABLE(test, updated, fixture.statistics());
  }
}

void dirtyRectDrawsOnlyIntersectingRows() {
  constexpr std::string_view test = "dirtyRectDrawsOnlyIntersectingRows";
  Preferences preferences;
  Fixture fixture(@"int a;\nint b;\nint c;\nint d;\nint e;\nint f;\nint g;\n");
  fixture.draw();
  const NSRect line = [fixture.view localRectForDisplayIndex:21];
  Statistics before = fixture.statistics();
  fixture.draw(NSMakeRect(0, line.origin.y + 1, 700, line.size.height - 2));
  Statistics after = fixture.statistics();
  EXPECT(test, count(after, @"drawnLines") - count(before, @"drawnLines") == 1);
  EXPECT_STABLE(test, before, after);

  before = fixture.statistics();
  fixture.draw(NSMakeRect(0, NSMaxY(fixture.view.bounds) + 100, 700, 20));
  after = fixture.statistics();
  EXPECT(test, count(after, @"drawnLines") == count(before, @"drawnLines"));
  EXPECT_STABLE(test, before, after);
}

void typeSettingsChangeWrapTabAndLineGeometry() {
  constexpr std::string_view test = "typeSettingsChangeWrapTabAndLineGeometry";
  Preferences preferences;
  preferences.set(@"SakuraTypeEditor.cpp.wrapMode", @0);
  Fixture fixture(@"\tX\nabcdefghijabcdefghijabcdefghij");
  EXPECT(test, [fixture.view displayLineRanges].size() == 2);
  const CGFloat initialHeight = [fixture.view editorLineHeight];
  const NSRect beforeTab = [fixture.view localRectForDisplayIndex:0];
  const NSRect afterTab = [fixture.view localRectForDisplayIndex:1];
  const CGFloat fourColumnTab = afterTab.origin.x - beforeTab.origin.x;
  EXPECT(test, fourColumnTab > 0);
  preferences.set(@"SakuraTypeEditor.cpp.tabWidth", @8);
  const NSRect eightTab = [fixture.view localRectForDisplayIndex:1];
  EXPECT(test, eightTab.origin.x - beforeTab.origin.x > fourColumnTab * 1.8);

  preferences.set(@"SakuraTypeEditor.cpp.fontSize", @18);
  EXPECT(test, [fixture.view editorLineHeight] > initialHeight);
  const CGFloat enlargedHeight = [fixture.view editorLineHeight];
  preferences.set(@"SakuraTypeEditor.cpp.lineSpacing", @16);
  EXPECT(test, [fixture.view editorLineHeight] >= enlargedHeight + 12);

  preferences.set(@"SakuraTypeEditor.cpp.wrapMode", @2);
  preferences.set(@"SakuraTypeEditor.cpp.wrapColumn", @10);
  const auto& columnLines = [fixture.view displayLineRanges];
  EXPECT(test, columnLines.size() >= 4);
  for (const NSRange range : columnLines) EXPECT(test, range.length <= 10);
  preferences.set(@"SakuraTypeEditor.cpp.wrapMode", @1);
  EXPECT(test, [fixture.view displayLineRanges].size() == 2);
}

void colorEditsInvalidateStylingWithoutReparsing() {
  constexpr std::string_view test = "colorEditsInvalidateStylingWithoutReparsing";
  Preferences preferences;
  Fixture fixture(@"int a = 1;\nreturn a;\n");
  fixture.draw();
  Statistics before = fixture.statistics();
  preferences.set(@"SakuraTypeColor.cpp.light.keyword", @"#FF0000");
  fixture.draw();
  Statistics after = fixture.statistics();
  EXPECT(test, count(after, @"styledBuilds") > count(before, @"styledBuilds"));
  for (NSString* key in @[ @"textBuilds", @"layoutBuilds", @"syntaxBuilds",
                           @"searchBuilds" ]) {
    EXPECT(test, count(after, key) == count(before, key));
  }
  fixture.draw();
  EXPECT_STABLE(test, after, fixture.statistics());
}

void wrappedTabsUseTheSameStopsForLayoutAndDrawing() {
  constexpr std::string_view test =
      "wrappedTabsUseTheSameStopsForLayoutAndDrawing";
  Preferences preferences;
  preferences.set(@"SakuraTypeEditor.cpp.wrapMode", @2);
  preferences.set(@"SakuraTypeEditor.cpp.wrapColumn", @10);
  for (NSString* source in @[ @"abcdefghij\tabcdefghi",
                              @"abcdefghi\tabcdefghi" ]) {
    Fixture fixture(source);
    const NSUInteger tab = [source rangeOfString:@"\t"].location;
    const NSRect origin = [fixture.view localRectForDisplayIndex:0];
    const NSRect firstCharacter = [fixture.view localRectForDisplayIndex:1];
    const CGFloat columnWidth = firstCharacter.origin.x - origin.origin.x;
    const NSRect afterTab = [fixture.view localRectForDisplayIndex:tab + 1];
    EXPECT(test, afterTab.origin.y > origin.origin.y);
    EXPECT(test, std::abs(afterTab.origin.x - origin.origin.x -
                          columnWidth * 4) < 0.5);
    const auto& lines = [fixture.view displayLineRanges];
    EXPECT(test, lines.size() >= 3);
    for (const NSRange range : lines) {
      const NSRect end = [fixture.view localRectForDisplayIndex:NSMaxRange(range)];
      EXPECT(test, end.origin.x - origin.origin.x <= columnWidth * 10 + 0.5);
    }
  }
}

void imeDisplayChangesDoNotReuseStaleTextOrGeometry() {
  constexpr std::string_view test = "imeDisplayChangesDoNotReuseStaleTextOrGeometry";
  Preferences preferences;
  Fixture fixture(@"int first = 1;\nint second = 2;");
  fixture.draw();
  [fixture.view setMarkedText:@"桜\n花" selectedRange:NSMakeRange(3, 0)
             replacementRange:NSMakeRange(0, 0)];
  fixture.draw();
  EXPECT(test, fixture.view.hasMarkedText);
  EXPECT(test, [[fixture.view displayString] hasPrefix:@"桜\n花int first"]);
  EXPECT(test, [fixture.view displayLineRanges].size() == 3);
  Statistics marked = fixture.statistics();
  fixture.draw();
  (void)[fixture.view localRectForDisplayIndex:3];
  EXPECT_STABLE(test, marked, fixture.statistics());

  [fixture.view setMarkedText:@"蕾" selectedRange:NSMakeRange(1, 0)
             replacementRange:NSMakeRange(NSNotFound, 0)];
  fixture.draw();
  EXPECT(test, [[fixture.view displayString] hasPrefix:@"蕾int first"]);
  EXPECT(test, [fixture.view displayLineRanges].size() == 2);
  marked = fixture.statistics();
  fixture.draw();
  EXPECT_STABLE(test, marked, fixture.statistics());
}

void expectSameLineRanges(const std::vector<NSRange>& actual,
                         const std::vector<NSRange>& expected,
                         std::string_view test) {
  EXPECT(test, actual.size() == expected.size());
  for (NSUInteger row = 0; row < std::min(actual.size(), expected.size()); ++row) {
    EXPECT(test, NSEqualRanges(actual[row], expected[row]));
  }
}

void expectSameGeometry(Fixture& marked, Fixture& committed,
                        std::string_view test) {
  NSString* display = [marked.view displayString];
  EXPECT(test, [display isEqualToString:[committed.view displayString]]);
  expectSameLineRanges([marked.view displayLineRanges],
                       [committed.view displayLineRanges], test);
  for (NSUInteger index = 0; index <= display.length; ++index) {
    const NSRect actual = [marked.view localRectForDisplayIndex:index];
    const NSRect expected = [committed.view localRectForDisplayIndex:index];
    EXPECT(test, std::abs(actual.origin.x - expected.origin.x) < 0.1);
    EXPECT(test, std::abs(actual.origin.y - expected.origin.y) < 0.1);
    EXPECT(test, std::abs(actual.size.height - expected.size.height) < 0.1);
    const NSPoint point = NSMakePoint(expected.origin.x, NSMidY(expected));
    EXPECT(test, [marked.view displayIndexForLocalPoint:point] ==
                     [committed.view displayIndexForLocalPoint:point]);
  }
}

void imeUsesCommittedWrapTabAndFontGeometry() {
  constexpr std::string_view test = "imeUsesCommittedWrapTabAndFontGeometry";
  Preferences preferences;
  preferences.set(@"SakuraTypeEditor.cpp.fontSize", @18);
  preferences.set(@"SakuraTypeEditor.cpp.characterSpacing", @1);
  preferences.set(@"SakuraTypeEditor.cpp.lineSpacing", @7);
  preferences.set(@"SakuraTypeEditor.cpp.tabWidth", @8);
  preferences.set(@"SakuraTypeEditor.cpp.wrapColumn", @10);
  NSString* source = @"head0123456789ABCDEFGHIJKLMNOPQRSTUV\r\nend";
  NSString* marked = @"abcdefghij\tklmnopqrstuvwxy\r\nz0123456789abcdefghij\tK";
  const NSRange replacement = NSMakeRange(4, 8);
  NSString* expected = [source stringByReplacingCharactersInRange:replacement
                                                      withString:marked];
  for (NSNumber* mode in @[ @0, @1, @2 ]) {
    preferences.set(@"SakuraTypeEditor.cpp.wrapMode", mode);
    Fixture fixture(source);
    Fixture reference(expected);
    [fixture.scroll setFrameSize:NSMakeSize(220, 160)];
    [reference.scroll setFrameSize:NSMakeSize(220, 160)];
    const auto revision = fixture.document.documentSession.buffer().revision();
    [fixture.view setMarkedText:marked selectedRange:NSMakeRange(marked.length, 0)
               replacementRange:replacement];
    [reference.view updateDocumentViewSize];
    EXPECT(test, fixture.view.hasMarkedText);
    EXPECT(test, NSEqualRanges(fixture.view.markedRange,
                              NSMakeRange(replacement.location, marked.length)));
    EXPECT(test, fixture.document.documentSession.buffer().revision() == revision);
    EXPECT(test, fixture.document.documentSession.buffer().text() ==
                     sakura::platform::mac::sakuraStringFromString(source));
    expectSameGeometry(fixture, reference, test);
    const auto& lines = [fixture.view displayLineRanges];
    EXPECT(test, mode.integerValue == 0 ? lines.size() == 3 : lines.size() > 3);
    // CRLF remains outside all visual line content, including IME-owned rows.
    for (NSRange range : lines) {
      NSString* line = [[fixture.view displayString] substringWithRange:range];
      EXPECT(test, [line rangeOfCharacterFromSet:
          NSCharacterSet.newlineCharacterSet].location == NSNotFound);
    }
    fixture.draw();
    Statistics warm = fixture.statistics();
    fixture.draw();
    (void)[fixture.view localRectForDisplayIndex:expected.length];
    EXPECT_STABLE(test, warm, fixture.statistics());
  }
}

void imeSelectionAndReplacementCacheDependencies() {
  constexpr std::string_view test = "imeSelectionAndReplacementCacheDependencies";
  Preferences preferences;
  preferences.set(@"SakuraTypeEditor.cpp.wrapMode", @2);
  preferences.set(@"SakuraTypeEditor.cpp.wrapColumn", @10);
  Fixture fixture(@"int alpha = 1;\nint beta = 2;");
  fixture.draw();
  EXPECT(test, ![fixture.view activeSyntaxTokens].empty());
  EXPECT(test, ![fixture.view activeSearchRanges].empty());
  NSString* marked = @"0123456789abcdefghij\tklmnopqrst";
  [fixture.view setMarkedText:marked selectedRange:NSMakeRange(0, 0)
             replacementRange:NSMakeRange(4, 5)];
  fixture.draw();
  EXPECT(test, [fixture.view activeSyntaxTokens].empty());
  EXPECT(test, [fixture.view activeSearchRanges].empty());
  Statistics warm = fixture.statistics();
  const auto revision = fixture.document.documentSession.buffer().revision();
  for (NSUInteger offset : { 1U, 11U, 22U }) {
    // Equal contents, not object identity, determine the temporary text cache.
    NSMutableString* sameText = [marked mutableCopy];
    [fixture.view setMarkedText:sameText selectedRange:NSMakeRange(offset, 2)
               replacementRange:NSMakeRange(NSNotFound, 0)];
    fixture.draw();
    EXPECT(test, NSEqualRanges(fixture.view.selectedRange,
                              NSMakeRange(4 + offset, 2)));
    EXPECT_STABLE(test, warm, fixture.statistics());
  }
  EXPECT(test, fixture.document.documentSession.buffer().revision() == revision);

  [fixture.view setMarkedText:marked selectedRange:NSMakeRange(1, 0)
             replacementRange:NSMakeRange(0, 2)];
  fixture.draw();
  Statistics moved = fixture.statistics();
  EXPECT(test, count(moved, @"layoutBuilds") == count(warm, @"layoutBuilds") + 1);
  EXPECT(test, count(moved, @"textBuilds") == count(warm, @"textBuilds"));
  EXPECT(test, count(moved, @"syntaxBuilds") == count(warm, @"syntaxBuilds"));
  EXPECT(test, count(moved, @"searchBuilds") == count(warm, @"searchBuilds"));
  EXPECT(test, [[fixture.view displayString] hasPrefix:marked]);
  EXPECT(test, NSEqualRanges(fixture.view.markedRange,
                            NSMakeRange(0, marked.length)));
  EXPECT(test, [fixture.view activeSyntaxTokens].empty());
  EXPECT(test, [fixture.view activeSearchRanges].empty());
  fixture.draw();
  EXPECT_STABLE(test, moved, fixture.statistics());
}

void imeCancelEmptyUnmarkAndCommitPreserveTheDocument() {
  constexpr std::string_view test =
      "imeCancelEmptyUnmarkAndCommitPreserveTheDocument";
  Preferences preferences;
  preferences.set(@"SakuraTypeEditor.cpp.wrapMode", @2);
  preferences.set(@"SakuraTypeEditor.cpp.wrapColumn", @10);
  NSString* source = @"int alpha = 1;\r\nint beta = 2;";
  NSString* marked = @"桜\r\n葉\t0123456789abcdefghij";
  Fixture fixture(source);
  [fixture.view jumpToDocumentOffset:4];
  const std::vector<NSRange> originalLines = [fixture.view displayLineRanges];
  const auto revision = fixture.document.documentSession.buffer().revision();
  [fixture.view setMarkedText:marked selectedRange:NSMakeRange(marked.length, 0)
             replacementRange:NSMakeRange(4, 5)];
  [fixture.view cancelOperation:nil];
  EXPECT(test, !fixture.view.hasMarkedText);
  EXPECT(test, fixture.view.markedRange.location == NSNotFound);
  EXPECT(test, [[fixture.view displayString] isEqualToString:source]);
  EXPECT(test, fixture.document.documentSession.buffer().revision() == revision);
  expectSameLineRanges([fixture.view displayLineRanges], originalLines, test);
  fixture.draw();
  EXPECT(test, ![fixture.view activeSyntaxTokens].empty());
  EXPECT(test, ![fixture.view activeSearchRanges].empty());

  const CGFloat originalHeight = fixture.view.frame.size.height;
  NSString* manyRows = [@"" stringByPaddingToLength:1200
                                        withString:@"abcdefghij\r\n"
                                   startingAtIndex:0];
  [fixture.view setMarkedText:manyRows selectedRange:NSMakeRange(0, 0)
             replacementRange:NSMakeRange(4, 5)];
  EXPECT(test, fixture.view.frame.size.height > originalHeight + 100);
  [fixture.view setMarkedText:@"" selectedRange:NSMakeRange(0, 0)
             replacementRange:NSMakeRange(NSNotFound, 0)];
  EXPECT(test, !fixture.view.hasMarkedText);
  EXPECT(test, [[fixture.view displayString] isEqualToString:source]);
  EXPECT(test, std::abs(fixture.view.frame.size.height - originalHeight) < 0.1);
  EXPECT(test, fixture.document.documentSession.buffer().revision() == revision);

  [fixture.view setMarkedText:marked selectedRange:NSMakeRange(marked.length, 0)
             replacementRange:NSMakeRange(4, 5)];
  const std::vector<NSRange> markedLines = [fixture.view displayLineRanges];
  NSString* expected = [source stringByReplacingCharactersInRange:NSMakeRange(4, 5)
                                                      withString:marked];
  [fixture.view unmarkText];
  EXPECT(test, !fixture.view.hasMarkedText);
  EXPECT(test, [[fixture.view displayString] isEqualToString:expected]);
  EXPECT(test, NSEqualRanges(fixture.view.selectedRange,
                            NSMakeRange(4 + marked.length, 0)));
  expectSameLineRanges([fixture.view displayLineRanges], markedLines, test);
  EXPECT(test, fixture.document.documentSession.undo());
  [fixture.view documentContentsDidChange];
  EXPECT(test, [[fixture.view displayString] isEqualToString:source]);
  expectSameLineRanges([fixture.view displayLineRanges], originalLines, test);

  [fixture.view setMarkedText:marked selectedRange:NSMakeRange(marked.length, 0)
             replacementRange:NSMakeRange(4, 5)];
  [fixture.view insertText:@"確定\tABC" replacementRange:NSMakeRange(NSNotFound, 0)];
  EXPECT(test, !fixture.view.hasMarkedText);
  EXPECT(test, [[fixture.view displayString] isEqualToString:
      [source stringByReplacingCharactersInRange:NSMakeRange(4, 5)
                                      withString:@"確定\tABC"]]);
  EXPECT(test, NSEqualRanges(fixture.view.selectedRange, NSMakeRange(10, 0)));
  EXPECT(test, fixture.document.documentSession.undo());
  [fixture.view documentContentsDidChange];
  EXPECT(test, [[fixture.view displayString] isEqualToString:source]);
}

void imeCandidateRectAndHitTestingUseWrappedDisplayRows() {
  constexpr std::string_view test =
      "imeCandidateRectAndHitTestingUseWrappedDisplayRows";
  Preferences preferences;
  preferences.set(@"SakuraTypeEditor.cpp.wrapMode", @2);
  preferences.set(@"SakuraTypeEditor.cpp.wrapColumn", @10);
  Fixture fixture(@"int alpha = 1;\r\nint beta = 2;");
  NSWindow* window = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(200, 200, 700, 160)
                styleMask:NSWindowStyleMaskBorderless
                  backing:NSBackingStoreBuffered defer:NO];
  window.releasedWhenClosed = NO;
  window.contentView = fixture.scroll;
  [fixture.view setMarkedText:@"abcdefghij\tklmnopqrst\r\n0123456789ABCDEF"
               selectedRange:NSMakeRange(15, 0)
             replacementRange:NSMakeRange(4, 5)];
  EXPECT(test, !window.isVisible);
  const auto& lines = [fixture.view displayLineRanges];
  EXPECT(test, lines.size() > 3);
  const CGFloat textOrigin =
      [fixture.view localRectForDisplayIndex:0].origin.x;
  for (NSUInteger rowIndex = 0; rowIndex < lines.size(); ++rowIndex) {
    const NSRange line = lines[rowIndex];
    if (line.length < 2) continue;
    const NSUInteger index = line.location + 1;
    NSRange actual = NSMakeRange(NSNotFound, 0);
    const NSRect screen = [fixture.view firstRectForCharacterRange:
        NSMakeRange(index, 0) actualRange:&actual];
    const NSRect local = [fixture.view localRectForDisplayIndex:index];
    const NSRect expected = [window convertRectToScreen:
        [fixture.view convertRect:local toView:nil]];
    EXPECT(test, NSEqualRanges(actual, NSMakeRange(index, 0)));
    EXPECT(test, std::abs(screen.origin.x - expected.origin.x) < 0.1);
    EXPECT(test, std::abs(screen.origin.y - expected.origin.y) < 0.1);
    EXPECT(test, [fixture.view characterIndexForPoint:
        NSMakePoint(screen.origin.x, NSMidY(screen))] == index);

    // A nonempty request spanning several visual rows must report only its
    // first fragment, with the fragment width rather than a one-pixel caret.
    const NSRect fragment = [fixture.view firstRectForCharacterRange:
        NSMakeRange(index, [fixture.view displayString].length - index)
        actualRange:&actual];
    EXPECT(test, NSEqualRanges(actual,
                              NSMakeRange(index, NSMaxRange(line) - index)));
    const NSRect end = [fixture.view localRectForDisplayIndex:NSMaxRange(line)];
    EXPECT(test, std::abs(fragment.size.width -
                         std::max<CGFloat>(1.0, end.origin.x - local.origin.x)) < 0.1);
    EXPECT(test, std::abs(fragment.origin.x - screen.origin.x) < 0.1);
    EXPECT(test, std::abs(fragment.origin.y - screen.origin.y) < 0.1);

    // At a soft-wrap boundary a nonempty request addresses the next row's
    // first character, even though a zero-length caret retains upstream
    // affinity. Its reported actualRange must never collapse to zero.
    const NSRect rowFragment = [fixture.view firstRectForCharacterRange:
        NSMakeRange(line.location,
                    [fixture.view displayString].length - line.location)
        actualRange:&actual];
    EXPECT(test, NSEqualRanges(actual, line));
    const NSRect rowLocal = NSMakeRect(
        textOrigin, 8.0 + rowIndex * [fixture.view editorLineHeight],
        std::max<CGFloat>(1.0, end.origin.x - textOrigin),
        [fixture.view editorLineHeight]);
    const NSRect rowScreen = [window convertRectToScreen:
        [fixture.view convertRect:rowLocal toView:nil]];
    EXPECT(test, std::abs(rowFragment.origin.x - rowScreen.origin.x) < 0.1);
    EXPECT(test, std::abs(rowFragment.origin.y - rowScreen.origin.y) < 0.1);
    EXPECT(test, std::abs(rowFragment.size.width - rowScreen.size.width) < 0.1);
  }
  NSRange actual = NSMakeRange(NSNotFound, 0);
  (void)[fixture.view firstRectForCharacterRange:NSMakeRange(NSNotFound, 100)
                                   actualRange:&actual];
  EXPECT(test, NSEqualRanges(actual,
      NSMakeRange([fixture.view displayString].length, 0)));
  EXPECT(test, !window.isVisible);
  [window close];
}

void warmLargeDocumentLookupsAreLogarithmic() {
  constexpr std::string_view test = "warmLargeDocumentLookupsAreLogarithmic";
  Preferences preferences;
  constexpr NSUInteger rows = 32768;
  NSMutableString* text = [NSMutableString stringWithCapacity:rows * 2];
  for (NSUInteger index = 0; index < rows; ++index) [text appendString:@"x\n"];
  Fixture fixture(text);
  fixture.draw();
  const auto& ranges = [fixture.view displayLineRanges];
  EXPECT(test, ranges.size() == rows + 1);
  Statistics before = fixture.statistics();
  constexpr NSUInteger queries = 256;
  const CGFloat lineHeight = [fixture.view editorLineHeight];
  for (NSUInteger index = 0; index < queries; ++index) {
    const NSUInteger row = rows - 1 - index % 64;
    const NSRect caret = [fixture.view localRectForDisplayIndex:row * 2];
    EXPECT(test, std::abs(caret.origin.y - (8.0 + row * lineHeight)) < 0.1);
    const NSUInteger character = [fixture.view displayIndexForLocalPoint:
        NSMakePoint(caret.origin.x, NSMidY(caret))];
    EXPECT(test, character == row * 2);
  }
  Statistics after = fixture.statistics();
  EXPECT_STABLE(test, before, after);
  const NSUInteger steps = count(after, @"lineLookupSteps") -
                           count(before, @"lineLookupSteps");
  EXPECT(test, steps > 0);
  EXPECT(test, steps <= queries * 20);
}

void composedCharactersWrapAndHitTestAsWholeClusters() {
  constexpr std::string_view test = "composedCharactersWrapAndHitTestAsWholeClusters";
  Preferences preferences;
  NSString* source = @"Ae\u0301😀👨‍👩‍👧‍👦🇯🇵か\u3099👍🏽1\uFE0F\u20E3Z\tfinish";
  NSMutableIndexSet* boundaries = [NSMutableIndexSet indexSetWithIndex:0];
  [source enumerateSubstringsInRange:NSMakeRange(0, source.length)
                            options:NSStringEnumerationByComposedCharacterSequences
                         usingBlock:^(NSString* substring, NSRange range,
                                      NSRange enclosing, BOOL* stop) {
    (void)substring; (void)enclosing; (void)stop;
    [boundaries addIndex:range.location];
    [boundaries addIndex:NSMaxRange(range)];
  }];
  preferences.set(@"SakuraTypeEditor.cpp.wrapColumn", @10);
  for (NSNumber* spacing in @[@0, @2]) {
    preferences.set(@"SakuraTypeEditor.cpp.characterSpacing", spacing);
    for (NSNumber* mode in @[@0, @1, @2]) {
      preferences.set(@"SakuraTypeEditor.cpp.wrapMode", mode);
      Fixture fixture(source);
      [fixture.scroll setFrameSize:NSMakeSize(180, 160)];
      [fixture.view updateDocumentViewSize];
      const std::vector<NSRange> rows = [fixture.view displayLineRanges];
      const CGFloat origin = [fixture.view localRectForDisplayIndex:0].origin.x;
      const auto attributes = [fixture.view baseTextAttributes];
      const CGFloat available = mode.integerValue == 2
          ? [@" " sizeWithAttributes:attributes].width * 10
          : fixture.scroll.contentSize.width - origin - 10;
      for (NSUInteger row = 0; row < rows.size(); ++row) {
        NSRange range = rows[row];
        EXPECT(test, [boundaries containsIndex:range.location]);
        EXPECT(test, [boundaries containsIndex:NSMaxRange(range)]);
        NSAttributedString* text = [[NSAttributedString alloc]
            initWithString:[source substringWithRange:range] attributes:attributes];
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)text);
        const CGFloat width = CTLineGetTypographicBounds(line, nullptr, nullptr, nullptr);
        CFRelease(line);
        if (mode.integerValue != 0) {
          EXPECT(test, width <= available + 0.5 ||
              [boundaries countOfIndexesInRange:range] == 1);
        }
        const CGFloat y = 8 + (row + 0.5) * [fixture.view editorLineHeight];
        for (CGFloat x = 0; x <= width + 1; x += 0.5) {
          const NSUInteger offset = [fixture.view displayIndexForLocalPoint:
              NSMakePoint(origin + x, y)];
          EXPECT(test, [boundaries containsIndex:offset]);
          EXPECT(test, offset >= range.location && offset <= NSMaxRange(range));
        }
      }
      fixture.draw();
      const auto stable = fixture.statistics();
      fixture.draw();
      EXPECT_STABLE(test, stable, fixture.statistics());
      Fixture marked(@"");
      [marked.scroll setFrameSize:NSMakeSize(180, 160)];
      [marked.view setMarkedText:source selectedRange:NSMakeRange(0, 0)
               replacementRange:NSMakeRange(0, 0)];
      expectSameLineRanges([marked.view displayLineRanges], rows, test);
    }
  }
}

void benchmarkMillionLineDocument() {
  constexpr std::string_view test = "benchmarkMillionLineDocument";
  using Clock = std::chrono::steady_clock;
  const auto milliseconds = [](Clock::duration elapsed) {
    return std::chrono::duration<double, std::milli>(elapsed).count();
  };
  Preferences preferences;
  constexpr NSUInteger rows = 1000000;
  NSString* text = [@"" stringByPaddingToLength:rows * 2 withString:@"x\n"
                                startingAtIndex:0];
  const auto started = Clock::now();
  Fixture fixture(text);
  const auto constructed = Clock::now();
  fixture.draw();
  const auto firstDraw = Clock::now();
  Statistics warm = fixture.statistics();
  constexpr NSUInteger redraws = 100;
  for (NSUInteger iteration = 0; iteration < redraws; ++iteration) fixture.draw();
  const auto redrawn = Clock::now();
  constexpr NSUInteger queries = 256;
  for (NSUInteger index = 0; index < queries; ++index) {
    (void)[fixture.view localRectForDisplayIndex:(rows - 1 - index) * 2];
  }
  const auto queried = Clock::now();
  Statistics after = fixture.statistics();
  EXPECT_STABLE(test, warm, after);
  EXPECT(test, [fixture.view displayLineRanges].size() == rows + 1);
  EXPECT(test, count(after, @"lineLookupSteps") -
               count(warm, @"lineLookupSteps") <= (redraws + queries) * 21);
  std::cout << "Million-line rendering benchmark: construction/layout="
            << milliseconds(constructed - started)
            << " ms, first visible draw=" << milliseconds(firstDraw - constructed)
            << " ms, " << redraws << " warm redraws="
            << milliseconds(redrawn - firstDraw) << " ms, " << queries
            << " tail lookups=" << milliseconds(queried - redrawn)
            << " ms, visible rows per redraw="
            << (count(after, @"drawnLines") - count(warm, @"drawnLines")) / redraws
            << '\n';
}

}  // namespace

int main(int argc, const char* argv[]) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    if (argc == 2 && std::string_view(argv[1]) == "--benchmark") {
      benchmarkMillionLineDocument();
    } else {
      unchangedDocumentAndSelectionReuseRenderingWork();
      editsInvalidateTextAnalysisAndSearchOnce();
      viewportAndTypeSettingsInvalidateOnlyDependentCaches();
      dirtyRectDrawsOnlyIntersectingRows();
      typeSettingsChangeWrapTabAndLineGeometry();
      colorEditsInvalidateStylingWithoutReparsing();
      wrappedTabsUseTheSameStopsForLayoutAndDrawing();
      imeDisplayChangesDoNotReuseStaleTextOrGeometry();
      imeUsesCommittedWrapTabAndFontGeometry();
      imeSelectionAndReplacementCacheDependencies();
      imeCancelEmptyUnmarkAndCommitPreserveTheDocument();
      imeCandidateRectAndHitTestingUseWrappedDisplayRows();
      warmLargeDocumentLookupsAreLogarithmic();
      composedCharactersWrapAndHitTestAsWholeClusters();
    }
  }
  if (failures != 0) {
    std::cerr << failures << " editor rendering test(s) failed\n";
    return 1;
  }
  std::cout << "All editor rendering tests passed\n";
  return 0;
}
