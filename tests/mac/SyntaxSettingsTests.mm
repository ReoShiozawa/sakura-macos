// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#import "SakuraDocument.h"
#import "SakuraEditorView.h"
#import "SakuraLayoutRows.h"
#import "SakuraWindowController.h"
#import "SakuraSyntaxSettings.h"
#import "SakuraKeywordFile.h"
#import "SakuraColorTheme.h"
#include "sakura/platform/mac/StringBridge.h"
#include <functional>
#include <iostream>

@interface SakuraEditorView (CustomSyntaxTesting)
- (const std::vector<sakura::core::SyntaxToken>&)activeSyntaxTokens;
- (const SakuraLayoutRows&)displayLineRanges;
- (void)refreshStyledLineCache;
- (NSAttributedString*)styledLineAtIndex:(NSUInteger)index;
@end
@interface SakuraWindowController (SyntaxPanelTesting)
- (NSUserDefaults*)typeSettingsDefaults;
- (NSView*)makeTypeScreenSettingsViewWithFrame:(NSRect)frame;
- (NSView*)makeTypeWindowSettingsViewWithFrame:(NSRect)frame;
- (NSView*)makeTypeSyntaxSettingsViewWithFrame:(NSRect)frame;
- (void)refreshTypeEditorSettingsControls;
- (void)refreshTypeSyntaxSettingsControls;
- (void)applyTypeSettings:(id)sender;
- (void)acceptTypeSettings:(id)sender;
- (void)cancelTypeSettings:(id)sender;
- (void)syntaxGroupChanged:(id)sender;
- (BOOL)importKeywordData:(NSData*)data encoding:(sakura::core::TextEncoding)encoding group:(NSUInteger)group;
- (NSArray<NSDictionary*>*)defaultTypeColorEntries;
@end
static NSUserDefaults* preferences;
@interface SyntaxTestDocument : SakuraDocument
@end
@implementation SyntaxTestDocument
- (void)noteEditorChange:(NSDocumentChangeType)change { (void)change; }
@end
@interface SyntaxTestEditor : SakuraEditorView
@end
@implementation SyntaxTestEditor
- (NSDictionary*)syntaxPreferences { return SakuraSyntaxPreferences(@"cpp", preferences); }
@end
@interface SyntaxTestController : SakuraWindowController
@property(nonatomic, strong) SyntaxTestDocument* retainedDocument;
@property(nonatomic, strong) NSView* syntaxRoot;
@end
@implementation SyntaxTestController
- (NSUserDefaults*)typeSettingsDefaults { return preferences; }
- (void)redrawEditorsForTypeColorChange {} // Never touch other app windows.
@end
namespace {
int failures = 0;
void check(bool ok, const char* label) { if (!ok) { std::cerr << label << '\n'; ++failures; } }
bool pump(const std::function<bool()>& predicate) {
  NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:5];
  while (!predicate() && deadline.timeIntervalSinceNow > 0)
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  return predicate();
}
NSDictionary* rules(NSString* words, NSString* patterns) {
  return @{@"keywords":words, @"patterns":patterns, @"caseSensitive":@YES};
}
void save(NSDictionary* value) { [preferences setObject:value forKey:SakuraSyntaxPreferenceKey(@"cpp")]; }
void setText(SakuraWindowController* controller, NSString* key, NSString* text) {
  ((NSTextView*)[controller valueForKey:key]).string = text;
}
SyntaxTestController* makeController() {
  SyntaxTestDocument* doc = [[SyntaxTestDocument alloc] init];
  doc.fileURL = [NSURL fileURLWithPath:@"/Demo/test.cpp"];
  SyntaxTestController* controller = [[SyntaxTestController alloc] initWithDocument:doc];
  controller.retainedDocument = doc;
  [controller setValue:@"cpp" forKey:@"typeColorIdentifier"];
  [controller makeTypeScreenSettingsViewWithFrame:NSMakeRect(0, 0, 600, 350)];
  [controller makeTypeWindowSettingsViewWithFrame:NSMakeRect(0, 0, 600, 350)];
  controller.syntaxRoot = [controller makeTypeSyntaxSettingsViewWithFrame:NSMakeRect(0, 0, 600, 350)];
  [controller refreshTypeEditorSettingsControls]; [controller refreshTypeSyntaxSettingsControls];
  return controller;
}
void selectGroup(SyntaxTestController* controller, NSInteger index) {
  [(NSPopUpButton*)[controller valueForKey:@"typeSyntaxGroupPopup"] selectItemAtIndex:index];
  [controller syntaxGroupChanged:nil];
}
}
int main() {
  @autoreleasepool {
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    NSString* suite = [@"SakuraSyntaxTests." stringByAppendingString:NSUUID.UUID.UUIDString];
    preferences = [[NSUserDefaults alloc] initWithSuiteName:suite];
    {
      sakura::core::CustomSyntaxRules parsed;
      check(SakuraParseSyntaxPreferences(rules(@"日本語 Foo", @"  foo\r\nbar"), parsed) == nil &&
            parsed.patterns[0] == u"  foo" && parsed.patterns[1] == u"bar", "parser preserves regex leading spaces and normalizes CRLF");
      [preferences setObject:@[@"invalid"] forKey:SakuraSyntaxPreferenceKey(@"cpp")];
      check([SakuraSyntaxPreferences(@"cpp", preferences)[@"keywords"] isEqual:@""], "malformed preferences fall back without crashing");
      save(rules(@"Foo", @"bar"));
      SyntaxTestController* a = makeController();
      SyntaxTestController* b = makeController();
      setText(b, @"typeKeywordText", @"Baz"); [b applyTypeSettings:nil];
      setText(a, @"typePatternText", @"qux"); [a applyTypeSettings:nil];
      NSDictionary* merged = SakuraSyntaxPreferences(@"cpp", preferences);
      check([merged[@"keywords"] isEqual:@"Baz"] && [merged[@"patterns"] isEqual:@"qux"],
            "stale panels preserve another panel's unedited fields");
      setText(a, @"typePatternText", @"["); [a acceptTypeSettings:nil];
      check(![[a valueForKey:@"typeSettingsApplySucceeded"] boolValue] &&
            [SakuraSyntaxPreferences(@"cpp", preferences)[@"patterns"] isEqual:@"qux"], "invalid apply does not persist or succeed");
      check(((NSTextField*)[a valueForKey:@"typeSyntaxStatus"]).stringValue.length > 0, "validation error visible");
      setText(a, @"typeKeywordText", @"Discarded"); [a cancelTypeSettings:nil];
      check([SakuraSyntaxPreferences(@"cpp", preferences)[@"keywords"] isEqual:@"Baz"], "cancel leaves committed keywords intact");
      check([SakuraSyntaxPreferences(@"basic", preferences)[@"keywords"] isEqual:@""], "type settings isolated");
      [a.window close]; [b.window close];
    }
    {
      save(rules(@"Legacy", @"legacyRegex"));
      check([SakuraSyntaxGroups(SakuraSyntaxPreferences(@"cpp", preferences))[0][@"keywords"] isEqual:@"Legacy"], "old single-group preferences remain group 1");
      SyntaxTestController* a = makeController(); SyntaxTestController* b = makeController();
      selectGroup(a, 1); setText(a, @"typeKeywordText", @"GroupTwo");
      setText(a, @"typePatternText", @"two[0-9]+");
      selectGroup(a, 9); setText(a, @"typeKeywordText", @"GroupTen");
      selectGroup(a, 1);
      check([((NSTextView*)[a valueForKey:@"typeKeywordText"]).string isEqual:@"GroupTwo"], "switching groups preserves uncommitted drafts");
      [a applyTypeSettings:nil];
      selectGroup(b, 2); setText(b, @"typeKeywordText", @"GroupThree"); [b applyTypeSettings:nil];
      NSArray* groups = SakuraSyntaxGroups(SakuraSyntaxPreferences(@"cpp", preferences));
      check([groups[0][@"keywords"] isEqual:@"Legacy"] && [groups[1][@"keywords"] isEqual:@"GroupTwo"] &&
          [groups[2][@"keywords"] isEqual:@"GroupThree"] && [groups[9][@"keywords"] isEqual:@"GroupTen"],
          "stale panels merge independent groups and preserve legacy data");
      selectGroup(a, 1);
      NSData* imported = [@"// CASE=False\nImported\n日本語\n" dataUsingEncoding:NSUTF8StringEncoding];
      check([a importKeywordData:imported encoding:sakura::core::TextEncoding::utf8 group:1], "import changes selected draft group");
      check([((NSTextView*)[a valueForKey:@"typePatternText"]).string isEqual:@"two[0-9]+"], "kwd import preserves regex rules");
      check([SakuraSyntaxGroups(SakuraSyntaxPreferences(@"cpp", preferences))[1][@"keywords"] isEqual:@"GroupTwo"], "import never persists before apply");
      check(![a importKeywordData:[@"bad-word\n" dataUsingEncoding:NSUTF8StringEncoding]
          encoding:sakura::core::TextEncoding::utf8 group:1], "invalid import rejects whole file");
      check([((NSTextView*)[a valueForKey:@"typeKeywordText"]).string isEqual:@"Imported\n日本語"], "invalid import keeps previous draft intact");
      [a cancelTypeSettings:nil];
      check([SakuraSyntaxGroups(SakuraSyntaxPreferences(@"cpp", preferences))[1][@"keywords"] isEqual:@"GroupTwo"], "cancel discards imported draft");
      NSArray* colors = [a defaultTypeColorEntries];
      for (NSUInteger n = 1; n <= 10; ++n)
        check([[colors valueForKey:@"foreground"] containsObject:SakuraKeywordRole(n)], "all groups have independent color entries");
      for (NSView* control in a.syntaxRoot.subviews) check(NSContainsRect(a.syntaxRoot.bounds, control.frame), "group controls fit settings view");
      [a.window close]; [b.window close];
    }
    {
      save(rules(@"old", @""));
      SyntaxTestDocument* doc = [[SyntaxTestDocument alloc] init];
      doc.documentSession.insert(0, u"old new");
      SyntaxTestEditor* editor = [[SyntaxTestEditor alloc] initWithFrame:NSMakeRect(0, 0, 700, 200) document:doc];
      check([editor activeSyntaxTokens].empty(), "custom rules start asynchronously for plain text");
      check(editor.customSyntaxStatus.length > 0, "in-progress state visible");
      save(rules(@"new", @"")); (void)[editor activeSyntaxTokens];
      check(pump([&]{ return editor.customSyntaxStatus.length == 0 && ![editor activeSyntaxTokens].empty(); }), "newest custom rules complete");
      auto tokens = [editor activeSyntaxTokens];
      check(tokens.size() == 1 && tokens.front().range.location == 4, "stale result cannot overwrite new settings");
      doc.documentSession.insert(0, u"new "); [editor documentContentsDidChange];
      (void)[editor activeSyntaxTokens];
      check(pump([&]{ return editor.customSyntaxStatus.length == 0 && [editor activeSyntaxTokens].size() == 2; }), "custom syntax follows edits");
      check(doc.documentSession.buffer().text() == u"new old new", "async coloring never edits source");
      save(rules(@"", @"(a+)+$"));
      doc.documentSession.replace({0, doc.documentSession.buffer().length()}, sakura::core::SakuraString(16000, u'a') + u"!");
      [editor documentContentsDidChange]; (void)[editor activeSyntaxTokens];
      check(pump([&]{ return [editor.customSyntaxStatus containsString:@"時間上限"]; }), "slow regex times out off main thread");
      check([editor activeSyntaxTokens].empty(), "timeout keeps base lexical result");
    }
    {
      NSMutableArray* groups = [SakuraSyntaxGroups(rules(@"first", @"")) mutableCopy];
      groups[1] = rules(@"second", @""); groups[9] = rules(@"tenth", @"");
      save(SakuraSyntaxPreferencesFromGroups(groups));
      SyntaxTestDocument* doc = [[SyntaxTestDocument alloc] init];
      doc.fileURL = [NSURL fileURLWithPath:@"/Demo/test.cpp"];
      doc.documentSession.insert(0, u"first second tenth");
      SyntaxTestEditor* editor = [[SyntaxTestEditor alloc] initWithFrame:NSMakeRect(0, 0, 700, 200) document:doc];
      (void)[editor activeSyntaxTokens];
      check(pump([&]{ return editor.customSyntaxStatus.length == 0 && [editor activeSyntaxTokens].size() == 3; }), "all groups reach async renderer");
      auto tokens = [editor activeSyntaxTokens];
      check(tokens.size() == 3 && tokens[1].keywordGroup == 2 && tokens[2].keywordGroup == 10, "async merge preserves group numbers");
      NSDictionary* old = [NSUserDefaults.standardUserDefaults volatileDomainForName:NSArgumentDomain];
      NSMutableDictionary* arguments = old.mutableCopy;
      arguments[SakuraTypeColorPreferenceKey(@"cpp", @"text", editor.effectiveAppearance)] = @"#000000";
      arguments[SakuraTypeStylePreferenceKey(@"cpp", @"keyword2", @"display")] = @YES;
      arguments[SakuraTypeStylePreferenceKey(@"cpp", @"keyword10", @"display")] = @YES;
      arguments[SakuraTypeColorPreferenceKey(@"cpp", @"keyword2", editor.effectiveAppearance)] = @"#123456";
      arguments[SakuraTypeStylePreferenceKey(@"cpp", @"keyword10", @"underline")] = @YES;
      [NSUserDefaults.standardUserDefaults setVolatileDomain:arguments forName:NSArgumentDomain];
      (void)[editor displayLineRanges]; [editor refreshStyledLineCache];
      NSAttributedString* styled = [editor styledLineAtIndex:0];
      check([SakuraHexStringFromColor([styled attribute:NSForegroundColorAttributeName atIndex:6 effectiveRange:nil]) isEqual:@"#123456"],
            "group 2 uses its own color preference");
      check([[styled attribute:NSUnderlineStyleAttributeName atIndex:13 effectiveRange:nil] integerValue] == NSUnderlineStyleSingle,
            "group 10 uses its own underline preference");
      arguments[SakuraTypeStylePreferenceKey(@"cpp", @"keyword2", @"display")] = @NO;
      [NSUserDefaults.standardUserDefaults setVolatileDomain:arguments forName:NSArgumentDomain];
      [editor refreshStyledLineCache]; NSAttributedString* hidden = [editor styledLineAtIndex:0];
      check(![SakuraHexStringFromColor([hidden attribute:NSForegroundColorAttributeName atIndex:6 effectiveRange:nil]) isEqual:@"#123456"],
            "group display change invalidates styled cache");
      [NSUserDefaults.standardUserDefaults setVolatileDomain:old forName:NSArgumentDomain];
    }
    [preferences removePersistentDomainForName:suite]; preferences = nil;
  }
  return failures ? 1 : 0;
}
