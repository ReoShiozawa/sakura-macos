// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#import <AppKit/AppKit.h>

#include <cmath>
#include <iostream>
#include <limits>
#include <vector>

#import "SakuraColorTheme.h"
#import "SakuraDocument.h"
#import "SakuraEditorSettings.h"
#import "SakuraEditorView.h"
#import "SakuraWindowController.h"
#include "sakura/platform/mac/StringBridge.h"

@interface SakuraEditorView (EditorSettingsGeometry)
- (SakuraEditorSettings*)editorSettings;
- (NSFont*)editorFont;
- (CGFloat)editorLineHeight;
- (NSRect)localRectForDisplayIndex:(NSUInteger)index;
@end

@interface SakuraWindowController (EditorSettingsTests)
- (NSView*)makeTypeScreenSettingsViewWithFrame:(NSRect)frame;
- (NSView*)makeTypeWindowSettingsViewWithFrame:(NSRect)frame;
- (NSView*)makeTypeColorSettingsViewWithFrame:(NSRect)frame;
- (void)applyTypeColorSettings:(id)sender;
- (void)resetSelectedTypeColor:(id)sender;
- (NSUserDefaults*)typeSettingsDefaults;
- (void)applyCommonSettings:(id)sender;
- (void)refreshTypeEditorSettingsControls;
- (void)resetTypeEditorSettings:(id)sender;
- (void)captureTypeColorSnapshot;
- (void)applyTypeSettings:(id)sender;
- (void)acceptTypeSettings:(id)sender;
- (void)cancelTypeSettings:(id)sender;
- (BOOL)windowShouldClose:(NSWindow*)sender;
@end

@interface SettingsTestEditor : SakuraEditorView
@property(nonatomic) NSUInteger settingsRefreshes;
@end
@implementation SettingsTestEditor
- (void)displaySettingsDidChange {
  ++self.settingsRefreshes;
  [super displaySettingsDidChange];
}
@end

@interface InheritedSettingsTestEditor : SettingsTestEditor
@property(nonatomic, strong) NSUserDefaults* settingsDefaults;
@property(nonatomic, copy) NSString* settingsType;
@end
@implementation InheritedSettingsTestEditor
- (SakuraEditorSettings*)editorSettings {
  if (self.settingsDefaults == nil) return super.editorSettings;
  return [SakuraEditorSettings settingsForTypeIdentifier:self.settingsType
                                               defaults:self.settingsDefaults];
}
@end

@interface SettingsTestPanel : NSPanel
@property(nonatomic) NSUInteger orderOutCount;
@end
@implementation SettingsTestPanel
- (void)orderOut:(id)sender {
  ++self.orderOutCount;
  [super orderOut:sender];
}
@end

@interface SettingsTestController : SakuraWindowController
@property(nonatomic, copy) NSString* testType;
@property(nonatomic, copy) NSArray<SakuraEditorView*>* trackedEditors;
@property(nonatomic, strong) SakuraDocument* testDocument;
@property(nonatomic, strong) NSUserDefaults* testDefaults;
@end
@implementation SettingsTestController
- (NSString*)currentTypeIdentifier { return self.testType ?: @"basic"; }
- (NSUserDefaults*)typeSettingsDefaults {
  return self.testDefaults ?: super.typeSettingsDefaults;
}
- (NSArray<SakuraEditorView*>*)editorViews {
  return self.trackedEditors ?: super.editorViews;
}
@end

namespace {
int failures = 0;
void expect(bool condition, const char* message) {
  if (condition) return;
  std::cerr << message << '\n';
  ++failures;
}

bool storedStringEquals(NSUserDefaults* defaults, NSString* key, NSString* expected) {
  NSString* actual = [defaults stringForKey:key];
  if ([actual isEqualToString:expected]) return true;
  std::cerr << "Preference " << key.UTF8String << " expected " << expected.UTF8String
            << " but found " << (actual.UTF8String ?: "<absent>") << '\n';
  return false;
}

void modelInheritsCommonAndIsolatesTypes() {
  NSString* suite = [@"sakura-editor-settings-test-"
      stringByAppendingString:NSUUID.UUID.UUIDString];
  NSUserDefaults* defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
  auto* initial = [SakuraEditorSettings settingsForTypeIdentifier:@"cpp"
                                                        defaults:defaults];
  expect(initial.fontSize == 13 && initial.tabWidth == 4,
         "new settings have usable font and TAB defaults");
  expect(initial.wrapMode == SakuraEditorWrapModeWindow &&
         initial.wrapColumn == 120 && initial.showsLineNumbers,
         "new types preserve window wrapping and line numbers");
  [defaults setDouble:17 forKey:@"SakuraEditorFontSize"];
  [defaults setInteger:8 forKey:@"SakuraEditorTabWidth"];
  auto* cpp = [SakuraEditorSettings settingsForTypeIdentifier:@"cpp"
                                                    defaults:defaults];
  expect(cpp.fontSize == 17 && cpp.tabWidth == 8,
         "absent type settings inherit existing common values");
  cpp.fontSize = 21;
  cpp.tabWidth = 3;
  cpp.wrapMode = SakuraEditorWrapModeColumn;
  cpp.wrapColumn = 80;
  cpp.fontName = @"__missing_test_font__";
  cpp.lineSpacing = 7.5;
  cpp.characterSpacing = 1.25;
  cpp.showsLineNumbers = NO;
  [cpp saveForTypeIdentifier:@"cpp" defaults:defaults];
  auto* saved = [SakuraEditorSettings settingsForTypeIdentifier:@"cpp"
                                                      defaults:defaults];
  expect(saved.fontSize == 21 && saved.tabWidth == 3 && saved.wrapColumn == 80 &&
         saved.wrapMode == SakuraEditorWrapModeColumn &&
         saved.lineSpacing == 7.5 && saved.characterSpacing == 1.25 &&
         !saved.showsLineNumbers, "all type display settings round trip");
  expect(saved.editorFont != nil && saved.editorFont.pointSize == 21,
         "unavailable fonts fall back safely while preserving requested size");
  auto* html = [SakuraEditorSettings settingsForTypeIdentifier:@"html"
                                                     defaults:defaults];
  expect(html.fontSize == 17 && html.tabWidth == 8 && html.showsLineNumbers,
         "one type does not overwrite another or the common defaults");
  expect([SakuraEditorSettings preferenceKeysForTypeIdentifier:@"cpp"].count == 8,
         "cancel snapshots cover every persisted display preference");
  [defaults removePersistentDomainForName:suite];
}

void modelRejectsOutOfRangeAndMalformedPreferences() {
  NSString* suite = [@"sakura-editor-settings-bounds-"
      stringByAppendingString:NSUUID.UUID.UUIDString];
  NSUserDefaults* defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
  auto* value = [[SakuraEditorSettings alloc] init];
  value.wrapMode = static_cast<SakuraEditorWrapMode>(99);
  value.wrapColumn = 50000;
  value.tabWidth = -4;
  value.fontSize = std::numeric_limits<double>::quiet_NaN();
  value.lineSpacing = -2;
  value.characterSpacing = std::numeric_limits<double>::infinity();
  [value saveForTypeIdentifier:@"bounds" defaults:defaults];
  auto* saved = [SakuraEditorSettings settingsForTypeIdentifier:@"bounds"
                                                      defaults:defaults];
  expect(saved.wrapMode == SakuraEditorWrapModeWindow && saved.wrapColumn == 10000 &&
         saved.tabWidth == 1 && saved.fontSize == 13 && saved.lineSpacing == 0 &&
         saved.characterSpacing == 0, "save normalizes invalid and nonfinite values");
  [defaults setObject:@[@42] forKey:@"SakuraTypeEditor.bounds.fontName"];
  [defaults setObject:@"invalid" forKey:@"SakuraTypeEditor.bounds.fontSize"];
  saved = [SakuraEditorSettings settingsForTypeIdentifier:@"bounds" defaults:defaults];
  expect(saved.fontName.length == 0 && saved.fontSize == 13,
         "malformed preference types cannot escape into font layout");
  [defaults removePersistentDomainForName:suite];
}

void modelResetAndSelectiveSavePreserveInheritance() {
  NSString* suite = [@"sakura-settings-inheritance-"
      stringByAppendingString:NSUUID.UUID.UUIDString];
  NSUserDefaults* defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
  [defaults setDouble:18 forKey:@"SakuraEditorFontSize"];
  [defaults setInteger:7 forKey:@"SakuraEditorTabWidth"];
  auto* custom = [[SakuraEditorSettings alloc] init];
  custom.fontSize = 27;
  custom.lineSpacing = 9;
  [custom saveForTypeIdentifier:@"cpp" defaults:defaults];
  [custom saveForTypeIdentifier:@"html" defaults:defaults];
  auto* inherited = [SakuraEditorSettings inheritedSettingsWithDefaults:defaults];
  expect(inherited.fontSize == 18 && inherited.tabWidth == 7 &&
         inherited.lineSpacing == 3 && inherited.wrapMode == SakuraEditorWrapModeWindow,
         "reset values inherit common font/TAB and restore other built-in defaults");
  expect([SakuraEditorSettings settingsForTypeIdentifier:@"cpp"
      defaults:defaults].fontSize == 27,
      "reading inherited reset values does not mutate type preferences");
  [SakuraEditorSettings resetForTypeIdentifier:@"cpp" defaults:defaults];
  for (NSString* key in [SakuraEditorSettings preferenceKeysForTypeIdentifier:@"cpp"]) {
    expect([defaults objectForKey:key] == nil, "reset removes every type display override");
  }
  inherited.lineSpacing = 5;
  [inherited saveForTypeIdentifier:@"cpp" defaults:defaults
                        properties:[NSSet setWithArray:@[@"lineSpacing", @"unknown"]]];
  auto* saved = [SakuraEditorSettings settingsForTypeIdentifier:@"cpp" defaults:defaults];
  expect(saved.lineSpacing == 5 && saved.fontSize == 18 && saved.tabWidth == 7,
         "selective save overrides only its allowlisted edited property");
  [defaults setDouble:20 forKey:@"SakuraEditorFontSize"];
  [defaults setInteger:6 forKey:@"SakuraEditorTabWidth"];
  saved = [SakuraEditorSettings settingsForTypeIdentifier:@"cpp" defaults:defaults];
  expect(saved.fontSize == 20 && saved.tabWidth == 6 && saved.lineSpacing == 5,
         "later common changes flow through missing keys after a selective save");
  expect([SakuraEditorSettings settingsForTypeIdentifier:@"html"
      defaults:defaults].fontSize == 27,
      "reset and selective save leave other types' overrides untouched");
  [defaults removePersistentDomainForName:suite];
}

SettingsTestController* controllerForType(NSString* type, NSUInteger panes,
                                        NSUserDefaults* defaults = nil) {
  SakuraDocument* document = [[SakuraDocument alloc] init];
  auto* controller = [[SettingsTestController alloc] initWithDocument:document];
  [document addWindowController:controller];
  controller.testDocument = document;
  controller.testType = type;
  controller.testDefaults = defaults;
  NSMutableArray<SakuraEditorView*>* editors = [NSMutableArray array];
  for (NSUInteger index = 0; index < panes; ++index) {
    [editors addObject:[[SettingsTestEditor alloc]
        initWithFrame:NSMakeRect(0, 0, 640, 300) document:document]];
  }
  controller.trackedEditors = editors;
  return controller;
}

void draftApplyCancelAndLiveColorHaveOneBoundary() {
  // Isolated objects and unique keys: never show a window, start recovery, or
  // send events to the user's running application.
  NSString* type = [@"settings-test-" stringByAppendingString:NSUUID.UUID.UUIDString];
  NSUserDefaults* defaults = [[NSUserDefaults alloc] initWithSuiteName:type];
  auto* controller = controllerForType(type, 2, defaults);
  auto* sameType = controllerForType(type, 1, defaults);
  auto* otherType = controllerForType([type stringByAppendingString:@"-other"], 1, defaults);
  NSPanel* panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 680, 480)
      styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
  [controller setValue:panel forKey:@"typeSettingsPanel"];
  [controller setValue:type forKey:@"typeColorIdentifier"];
  [controller setValue:@[ @{ @"foreground": @"text", @"background": @"background",
                             @"style": @"text" } ] forKey:@"typeColorEntries"];
  NSView* screen = [controller makeTypeScreenSettingsViewWithFrame:NSMakeRect(0, 0, 620, 370)];
  NSView* window = [controller makeTypeWindowSettingsViewWithFrame:NSMakeRect(0, 0, 620, 370)];
  NSView* colors = [controller makeTypeColorSettingsViewWithFrame:NSMakeRect(0, 0, 620, 370)];
  [panel.contentView addSubview:screen];
  [panel.contentView addSubview:window];
  [panel.contentView addSubview:colors];
  NSTableView* colorTable = [controller valueForKey:@"typeColorTableView"];
  [colorTable reloadData];
  [colorTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
         byExtendingSelection:NO];
  [controller refreshTypeEditorSettingsControls];
  [controller captureTypeColorSnapshot];
  SakuraDocument* document = (SakuraDocument*)controller.document;
  document.documentSession.insert(0, u"abcdef\nabcdef\nabcdef");
  [document refreshEditorViews];
  SakuraEditorView* linear = controller.editorViews[0];
  SakuraEditorView* rectangle = controller.editorViews[1];
  [linear jumpToDocumentOffset:4];
  [linear doCommandBySelector:@selector(moveLeftAndModifySelection:)];
  [linear doCommandBySelector:@selector(moveLeftAndModifySelection:)];
  [rectangle toggleRectangularSelection:nil];
  [rectangle doCommandBySelector:@selector(moveRight:)];
  [rectangle doCommandBySelector:@selector(moveDown:)];
  const NSUInteger rectangleCount = rectangle.selectedCharacterCount;
  auto* size = (NSTextField*)[controller valueForKey:@"typeFontSizeField"];
  auto* tab = (NSTextField*)[controller valueForKey:@"typeTabWidthField"];
  auto* wrap = (NSPopUpButton*)[controller valueForKey:@"typeWrapModePopup"];
  auto* column = (NSTextField*)[controller valueForKey:@"typeWrapColumnField"];
  expect(!column.enabled, "wrap column control is disabled for window wrapping");
  [wrap selectItemAtIndex:SakuraEditorWrapModeColumn];
  [NSApp sendAction:wrap.action to:wrap.target from:wrap];
  expect(column.enabled, "choosing column wrapping enables the column field");
  size.doubleValue = 23;
  tab.integerValue = 7;
  column.integerValue = 90;
  NSString* colorKey = SakuraTypeColorPreferenceKey(type, @"text", panel.effectiveAppearance);
  ((NSColorWell*)[controller valueForKey:@"typeForegroundColorWell"]).color =
      SakuraColorFromHexString(@"#123456");
  [controller applyTypeColorSettings:nil];
  expect(NSEqualRanges(linear.selectedRange, NSMakeRange(2, 2)) &&
         rectangle.hasRectangularSelection &&
         rectangle.selectedCharacterCount == rectangleCount,
         "live color preview preserves linear and rectangular selections");
  [linear doCommandBySelector:@selector(moveRightAndModifySelection:)];
  expect(NSEqualRanges(linear.selectedRange, NSMakeRange(3, 1)),
         "live color preview preserves the Shift selection anchor");
  [controller cancelTypeSettings:nil];
  expect([defaults objectForKey:colorKey] == nil,
         "cancel restores live colors as well as discarding display drafts");
  expect([defaults objectForKey:[SakuraEditorSettings
      preferenceKeysForTypeIdentifier:type].firstObject] == nil,
      "cancelled display draft does not persist type preferences");
  [controller refreshTypeEditorSettingsControls];
  [controller captureTypeColorSnapshot];
  size.doubleValue = 19;
  tab.integerValue = 6;
  [wrap selectItemAtIndex:SakuraEditorWrapModeNone];
  for (SettingsTestController* current in @[ controller, sameType, otherType ]) {
    for (SettingsTestEditor* editor in current.editorViews) editor.settingsRefreshes = 0;
  }
  auto* colorWell = (NSColorWell*)[controller valueForKey:@"typeForegroundColorWell"];
  expect([(NSTableView*)[controller valueForKey:@"typeColorTableView"] selectedRow] == 0,
         "color fixture retains its selected row before editing");
  colorWell.color = SakuraColorFromHexString(@"#654321");
  [controller applyTypeColorSettings:colorWell];
  [controller applyTypeSettings:nil];
  expect(NSEqualRanges(linear.selectedRange, NSMakeRange(3, 1)) &&
         rectangle.hasRectangularSelection &&
         rectangle.selectedCharacterCount == rectangleCount,
         "Apply preserves linear and rectangular selections");
  [linear doCommandBySelector:@selector(moveRightAndModifySelection:)];
  expect(NSEqualRanges(linear.selectedRange, NSMakeRange(4, 0)),
         "Apply preserves the original Shift selection anchor");
  auto* applied = [SakuraEditorSettings settingsForTypeIdentifier:type defaults:defaults];
  expect(applied.fontSize == 19 && applied.tabWidth == 6 &&
         applied.wrapMode == SakuraEditorWrapModeNone,
         "Apply persists the display controls");
  for (SettingsTestController* current in @[ controller, sameType ]) {
    for (SettingsTestEditor* editor in current.editorViews) {
      expect(editor.settingsRefreshes > 0, "Apply refreshes every same-type pane");
    }
  }
  expect(((SettingsTestEditor*)otherType.editorViews.firstObject).settingsRefreshes == 0,
         "applying one type does not invalidate unrelated type panes");
  size.doubleValue = 30;
  colorWell.color = SakuraColorFromHexString(@"#FFFFFF");
  [controller applyTypeColorSettings:colorWell];
  expect(![controller windowShouldClose:panel], "titlebar close runs cancel semantics");
  expect([SakuraEditorSettings settingsForTypeIdentifier:type defaults:defaults].fontSize == 19 &&
         storedStringEquals(defaults, colorKey, @"#654321"),
         "Cancel after Apply retains the applied display and color settings");
  size.doubleValue = 22;
  [controller acceptTypeSettings:nil];
  expect([SakuraEditorSettings settingsForTypeIdentifier:type defaults:defaults].fontSize == 22,
         "OK commits the current draft");
  for (NSString* key in [SakuraEditorSettings preferenceKeysForTypeIdentifier:type]) {
    [defaults removeObjectForKey:key];
  }
  for (NSString* role in @[ @"text", @"background" ]) {
    [defaults removeObjectForKey:SakuraTypeColorPreferenceKey(type, role, panel.effectiveAppearance)];
  }
  for (NSString* attribute in @[ @"display", @"bold", @"underline" ]) {
    [defaults removeObjectForKey:SakuraTypeStylePreferenceKey(type, @"text", attribute)];
  }
  [panel close];
  for (SettingsTestController* current in @[ controller, sameType, otherType ]) {
    [current.window close];
    current.testDocument = nil;
  }
  [defaults removePersistentDomainForName:type];
}

void cancellingOneWindowPreservesAnotherWindowsAppliedDisplaySettings() {
  NSString* type = [@"settings-concurrent-"
      stringByAppendingString:NSUUID.UUID.UUIDString];
  NSUserDefaults* defaults = [[NSUserDefaults alloc] initWithSuiteName:type];
  auto* first = controllerForType(type, 1, defaults);
  auto* second = controllerForType(type, 1, defaults);
  for (SettingsTestController* controller in @[first, second]) {
    NSPanel* panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 680, 480)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    [controller setValue:panel forKey:@"typeSettingsPanel"];
    [controller setValue:type forKey:@"typeColorIdentifier"];
    [controller setValue:@[] forKey:@"typeColorEntries"];
    [panel.contentView addSubview:[controller
        makeTypeScreenSettingsViewWithFrame:NSMakeRect(0, 0, 620, 370)]];
    [panel.contentView addSubview:[controller
        makeTypeWindowSettingsViewWithFrame:NSMakeRect(0, 0, 620, 370)]];
    [controller refreshTypeEditorSettingsControls];
    [controller captureTypeColorSnapshot];
  }
  ((NSTextField*)[second valueForKey:@"typeFontSizeField"]).doubleValue = 25;
  ((NSTextField*)[second valueForKey:@"typeTabWidthField"]).integerValue = 9;
  [(NSPopUpButton*)[second valueForKey:@"typeWrapModePopup"]
      selectItemAtIndex:SakuraEditorWrapModeColumn];
  ((NSTextField*)[second valueForKey:@"typeWrapColumnField"]).integerValue = 72;
  [second applyTypeSettings:nil];
  // The first panel is stale and its draft was never written to preferences.
  ((NSTextField*)[first valueForKey:@"typeFontSizeField"]).doubleValue = 10;
  [first cancelTypeSettings:nil];
  auto* result = [SakuraEditorSettings settingsForTypeIdentifier:type defaults:defaults];
  expect(result.fontSize == 25 && result.tabWidth == 9 &&
         result.wrapMode == SakuraEditorWrapModeColumn && result.wrapColumn == 72,
         "Cancel in a stale window preserves another window's applied settings");
  for (NSString* key in [SakuraEditorSettings preferenceKeysForTypeIdentifier:type]) {
    [defaults removeObjectForKey:key];
  }
  for (SettingsTestController* controller in @[first, second]) {
    [(NSPanel*)[controller valueForKey:@"typeSettingsPanel"] close];
    [controller.window close];
    controller.testDocument = nil;
  }
  [defaults removePersistentDomainForName:type];
}

void previewTransactionsComposeWithoutLosingCommittedOrPendingValues() {
  NSString* suite = [@"sakura-preview-test-" stringByAppendingString:NSUUID.UUID.UUIDString];
  NSUserDefaults* defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
  auto transaction = [&]() {
    return [[SakuraSettingsPreviewTransaction alloc] initWithDefaults:defaults];
  };
  auto equals = [&](NSString* key, NSString* expected) {
    return [[defaults stringForKey:key] isEqualToString:expected];
  };
  [defaults setObject:@"original" forKey:@"color"];
  auto* first = transaction();
  auto* second = transaction();
  [first setObject:@"red" forKey:@"color"];
  [second setObject:@"blue" forKey:@"color"];
  [second commit];
  [first cancel];
  expect(equals(@"color", @"blue"),
         "older Cancel cannot roll back a newer committed color");

  [defaults setObject:@"original" forKey:@"color"];
  [first setObject:@"red" forKey:@"color"];
  [second setObject:@"blue" forKey:@"color"];
  [first commit];
  expect(equals(@"color", @"blue"), "Apply preserves a newer uncommitted preview");
  [second cancel];
  expect(equals(@"color", @"red"), "newer Cancel reveals the older applied value");

  [defaults setObject:@"original" forKey:@"color"];
  [first setObject:@"red" forKey:@"color"];
  [second setObject:@"blue" forKey:@"color"];
  [first cancel];
  expect(equals(@"color", @"blue"), "Cancel removes a hidden preview only");
  [second cancel];
  expect(equals(@"color", @"original"), "cancelling both previews restores the initial value");

  [first setObject:@"red" forKey:@"color"];
  [second setObject:@"blue" forKey:@"color"];
  [second cancel];
  expect(equals(@"color", @"red"), "newer Cancel reveals another pending preview");
  [first cancel];

  [first setObject:@"red" forKey:@"color"];
  [second setObject:@"blue" forKey:@"background"];
  [second commit];
  [first cancel];
  expect(equals(@"color", @"original") && equals(@"background", @"blue"),
         "different-key commit does not take ownership of another preview");

  [first setObject:@"red" forKey:@"color"];
  [second setObject:nil forKey:@"color"];
  [second commit];
  [first cancel];
  expect([defaults objectForKey:@"color"] == nil,
         "committed reset cannot be undone by an older preview Cancel");
  [defaults setObject:@"original" forKey:@"color"];
  [first setObject:@"red" forKey:@"color"];
  [second setObject:nil forKey:@"color"];
  [second cancel];
  expect(equals(@"color", @"red"), "reset Cancel reveals the other pending preview");
  [first cancel];

  [first setObject:@"same" forKey:@"color"];
  [second setObject:@"same" forKey:@"color"];
  [second commit];
  [first cancel];
  expect(equals(@"color", @"same"), "same-value writes still have independent ownership");

  [first setObject:@"red" forKey:@"color"];
  [second setObject:@"blue" forKey:@"color"];
  [first setObject:@"green" forKey:@"color"];
  [first cancel];
  expect(equals(@"color", @"blue"), "repeated edits move their preview to the newest layer");
  [second cancel];
  expect(equals(@"color", @"same"), "repeated edits retain the committed base");

  [first setObject:@"red" forKey:@"color"];
  [defaults setObject:@"external" forKey:@"color"];
  [first cancel];
  expect(equals(@"color", @"external"), "Cancel preserves a write outside the preview model");
  @autoreleasepool {
    auto* abandoned = transaction();
    [abandoned setObject:@"temporary" forKey:@"color"];
  }
  expect(equals(@"color", @"external"), "destroying a preview owner rolls back its pending values");
  [defaults removePersistentDomainForName:suite];
}

void prepareHiddenTypePanel(SettingsTestController* controller, NSString* type) {
  NSPanel* panel = [[SettingsTestPanel alloc] initWithContentRect:NSMakeRect(0, 0, 680, 480)
      styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
  [controller setValue:panel forKey:@"typeSettingsPanel"];
  [controller setValue:type forKey:@"typeColorIdentifier"];
  [controller setValue:@[ @{ @"foreground": @"text", @"background": @"background",
                            @"style": @"text", @"font": @YES, @"display": @YES } ]
                forKey:@"typeColorEntries"];
  NSRect frame = NSMakeRect(0, 0, 620, 370);
  [panel.contentView addSubview:[controller makeTypeScreenSettingsViewWithFrame:frame]];
  [panel.contentView addSubview:[controller makeTypeWindowSettingsViewWithFrame:frame]];
  [panel.contentView addSubview:[controller makeTypeColorSettingsViewWithFrame:frame]];
  auto* table = (NSTableView*)[controller valueForKey:@"typeColorTableView"];
  [table reloadData];
  [table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
  [controller refreshTypeEditorSettingsControls];
  [controller captureTypeColorSnapshot];
}

void resetDraftAndPartialEditsDoNotFreezeInheritedSettings() {
  NSString* type = [@"sakura-reset-panel-" stringByAppendingString:NSUUID.UUID.UUIDString];
  NSUserDefaults* defaults = [[NSUserDefaults alloc] initWithSuiteName:type];
  [defaults setDouble:18 forKey:@"SakuraEditorFontSize"];
  [defaults setInteger:7 forKey:@"SakuraEditorTabWidth"];
  auto* custom = [[SakuraEditorSettings alloc] init];
  custom.fontSize = 27;
  custom.tabWidth = 3;
  custom.wrapMode = SakuraEditorWrapModeNone;
  custom.lineSpacing = 9;
  custom.characterSpacing = 1;
  custom.showsLineNumbers = NO;
  [custom saveForTypeIdentifier:type defaults:defaults];
  auto* controller = controllerForType(type, 2, defaults);
  auto* sibling = controllerForType(type, 1, defaults);
  auto* other = controllerForType([type stringByAppendingString:@"-other"], 1, defaults);
  // Isolated defaults are injected into hidden editors as well as the panel;
  // real application defaults and the user's running process are untouched.
  for (SettingsTestController* current in @[controller, sibling]) {
    current.testDocument.documentSession.insert(0, u"abc\ndef\nghi\n");
    NSMutableArray<SakuraEditorView*>* panes = [NSMutableArray array];
    for (NSUInteger index = 0; index < current.editorViews.count; ++index) {
      auto* editor = [[InheritedSettingsTestEditor alloc]
          initWithFrame:NSMakeRect(0, 0, 640, 300) document:current.testDocument];
      editor.settingsDefaults = defaults;
      editor.settingsType = type;
      [editor displaySettingsDidChange];
      [panes addObject:editor];
    }
    current.trackedEditors = panes;
    prepareHiddenTypePanel(current, type);
  }
  auto overrideCount = [&]() {
    NSUInteger count = 0;
    for (NSString* key in [SakuraEditorSettings preferenceKeysForTypeIdentifier:type]) {
      if ([defaults objectForKey:key] != nil) ++count;
    }
    return count;
  };
  NSButton* resetButton = nil;
  NSPanel* panel = [controller valueForKey:@"typeSettingsPanel"];
  for (NSView* tab in panel.contentView.subviews) {
    for (NSView* child in tab.subviews) {
      if ([child.identifier isEqualToString:@"SakuraTypeDisplayReset"]) {
        resetButton = (NSButton*)child;
      }
    }
  }
  expect(resetButton != nil, "screen tab exposes the reset-to-inherited-defaults action");
  [NSApp sendAction:resetButton.action to:resetButton.target from:resetButton];
  expect(overrideCount() == 8 &&
         ((NSTextField*)[controller valueForKey:@"typeFontSizeField"]).doubleValue == 18 &&
         ((NSTextField*)[controller valueForKey:@"typeTabWidthField"]).integerValue == 7,
         "Reset changes draft controls to inherited defaults without deleting stored keys");
  expect(((NSTextField*)[controller valueForKey:@"typeLineSpacingField"]).doubleValue == 3 &&
         ((NSPopUpButton*)[controller valueForKey:@"typeWrapModePopup"]).indexOfSelectedItem ==
             SakuraEditorWrapModeWindow &&
         ((NSButton*)[controller valueForKey:@"typeLineNumbersCheckbox"]).state == NSControlStateValueOn,
         "Reset covers window and screen settings, not just font size and TAB width");
  [controller cancelTypeSettings:nil];
  expect(overrideCount() == 8 &&
         [SakuraEditorSettings settingsForTypeIdentifier:type defaults:defaults].fontSize == 27,
         "Cancel discards a pending reset without touching original overrides");
  [controller refreshTypeEditorSettingsControls];
  [controller captureTypeColorSnapshot];
  [controller resetTypeEditorSettings:nil];
  expect(![controller windowShouldClose:panel] && overrideCount() == 8,
         "titlebar close also discards a pending reset");

  [controller refreshTypeEditorSettingsControls];
  [controller captureTypeColorSnapshot];
  [controller resetTypeEditorSettings:nil];
  ((NSTextField*)[controller valueForKey:@"typeLineSpacingField"]).doubleValue = 5;
  for (SettingsTestController* current in @[controller, sibling, other]) {
    for (SettingsTestEditor* editor in current.editorViews) editor.settingsRefreshes = 0;
  }
  [controller applyTypeSettings:nil];
  auto* result = [SakuraEditorSettings settingsForTypeIdentifier:type defaults:defaults];
  expect(overrideCount() == 1 && result.lineSpacing == 5 &&
         result.fontSize == 18 && result.tabWidth == 7 && result.characterSpacing == 0,
         "Reset then one edit saves only that override and preserves common inheritance");
  for (SettingsTestController* current in @[controller, sibling]) {
    for (SettingsTestEditor* editor in current.editorViews) {
      expect(editor.settingsRefreshes > 0 && editor.editorFont.pointSize == 18,
             "Apply immediately refreshes inherited font values in every same-type pane");
    }
  }
  expect(((SettingsTestEditor*)other.editorViews.firstObject).settingsRefreshes == 0,
         "reset Apply leaves unrelated type panes unchanged");
  [defaults setDouble:20 forKey:@"SakuraEditorFontSize"];
  [defaults setInteger:6 forKey:@"SakuraEditorTabWidth"];
  for (SettingsTestController* current in @[controller, sibling]) {
    for (SakuraEditorView* editor in current.editorViews) {
      [editor displaySettingsDidChange];
      expect(editor.editorFont.pointSize == 20 && editor.editorSettings.tabWidth == 6,
             "later common changes still flow into every reset pane after a partial override");
    }
  }
  [controller resetTypeEditorSettings:nil];
  [controller applyTypeSettings:nil];
  expect(overrideCount() == 0, "unmodified reset Apply removes all eight override keys");
  [controller applyTypeSettings:nil];
  expect(overrideCount() == 0, "unmodified Apply does not freeze inherited font and TAB values");
  ((NSTextField*)[controller valueForKey:@"typeFontSizeField"]).doubleValue = 23;
  [controller applyTypeSettings:nil];
  [sibling cancelTypeSettings:nil];
  expect(overrideCount() == 1 &&
         [SakuraEditorSettings settingsForTypeIdentifier:type defaults:defaults].fontSize == 23,
         "stale Cancel cannot resurrect pre-reset overrides or roll back a newer Apply");
  for (SettingsTestController* current in @[controller, sibling, other]) {
    [(NSPanel*)[current valueForKey:@"typeSettingsPanel"] close];
    [current.window close];
    current.testDocument = nil;
  }
  [defaults removePersistentDomainForName:type];
}

void concurrentColorPanelsApplyCancelCloseAndResetSafely() {
  NSString* type = [@"sakura-color-panels-" stringByAppendingString:NSUUID.UUID.UUIDString];
  NSUserDefaults* defaults = [[NSUserDefaults alloc] initWithSuiteName:type];
  auto* first = controllerForType(type, 1, defaults);
  auto* second = controllerForType(type, 1, defaults);
  prepareHiddenTypePanel(first, type);
  prepareHiddenTypePanel(second, type);
  NSPanel* firstPanel = [first valueForKey:@"typeSettingsPanel"];
  NSString* foregroundKey = SakuraTypeColorPreferenceKey(type, @"text", firstPanel.effectiveAppearance);
  NSString* backgroundKey = SakuraTypeColorPreferenceKey(type, @"background", firstPanel.effectiveAppearance);
  NSString* boldKey = SakuraTypeStylePreferenceKey(type, @"text", @"bold");
  auto setColor = [](SettingsTestController* controller, NSString* property, NSString* color) {
    auto* table = (NSTableView*)[controller valueForKey:@"typeColorTableView"];
    expect(table.numberOfRows == 1 && table.selectedRow == 0,
           "color control refresh preserves the selected row before editing");
    auto* well = (NSColorWell*)[controller valueForKey:property];
    well.color = SakuraColorFromHexString(color);
    [controller applyTypeColorSettings:well];
  };
  setColor(first, @"typeForegroundColorWell", @"#112233");
  setColor(second, @"typeForegroundColorWell", @"#445566");
  [second applyTypeSettings:nil];
  [first cancelTypeSettings:nil];
  expect(storedStringEquals(defaults, foregroundKey, @"#445566"),
         "stale panel Cancel preserves another panel's same-key Apply");

  [first captureTypeColorSnapshot];
  setColor(first, @"typeForegroundColorWell", @"#AABBCC");
  setColor(second, @"typeBackgroundColorWell", @"#123456");
  auto* bold = (NSButton*)[second valueForKey:@"typeColorBoldCheckbox"];
  bold.state = NSControlStateValueOn;
  [second applyTypeColorSettings:bold];
  [second applyTypeSettings:nil];
  expect(storedStringEquals(defaults, foregroundKey, @"#AABBCC"),
         "background and style edits do not re-publish another panel's stale foreground");
  expect(![first windowShouldClose:firstPanel], "titlebar close uses preview cancellation");
  expect(storedStringEquals(defaults, foregroundKey, @"#445566") &&
         storedStringEquals(defaults, backgroundKey, @"#123456") &&
         [defaults boolForKey:boldKey],
         "titlebar close reverts only its preview, retaining another panel's different-key Apply");

  [first captureTypeColorSnapshot];
  setColor(first, @"typeForegroundColorWell", @"#ABCDEF");
  [second resetSelectedTypeColor:nil];
  [second cancelTypeSettings:nil];
  expect(storedStringEquals(defaults, foregroundKey, @"#ABCDEF") &&
         storedStringEquals(defaults, backgroundKey, @"#123456") &&
         [defaults boolForKey:boldKey],
         "Cancel of a reset restores pending and committed colors and styles");
  [second captureTypeColorSnapshot];
  [second resetSelectedTypeColor:nil];
  [second acceptTypeSettings:nil];
  [first cancelTypeSettings:nil];
  expect([defaults objectForKey:foregroundKey] == nil &&
         [defaults objectForKey:backgroundKey] == nil &&
         [defaults objectForKey:boldKey] == nil,
         "OK commits reset removals that an older panel cannot resurrect");
  for (SettingsTestController* controller in @[first, second]) {
    [(NSPanel*)[controller valueForKey:@"typeSettingsPanel"] close];
    [controller.window close];
    controller.testDocument = nil;
  }
  [defaults removePersistentDomainForName:type];
}

void closingPreviewOwnerRestoresAndRedrawsSurvivingWindows() {
  for (BOOL throughController : {NO, YES}) {
    NSString* type = [@"sakura-owner-close-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults* defaults = [[NSUserDefaults alloc] initWithSuiteName:type];
    auto* owner = controllerForType(type, 1, defaults);
    auto* survivor = controllerForType(type, 1, defaults);
    prepareHiddenTypePanel(owner, type);
    prepareHiddenTypePanel(survivor, type);
    auto* panel = (SettingsTestPanel*)[owner valueForKey:@"typeSettingsPanel"];
    NSString* foregroundKey = SakuraTypeColorPreferenceKey(type, @"text", panel.effectiveAppearance);
    NSString* backgroundKey = SakuraTypeColorPreferenceKey(type, @"background", panel.effectiveAppearance);
    [defaults setObject:@"#112233" forKey:foregroundKey];
    auto* background = (NSColorWell*)[survivor valueForKey:@"typeBackgroundColorWell"];
    background.color = SakuraColorFromHexString(@"#AABBCC");
    [survivor applyTypeColorSettings:background];
    [survivor applyTypeSettings:nil];
    auto* foreground = (NSColorWell*)[owner valueForKey:@"typeForegroundColorWell"];
    foreground.color = SakuraColorFromHexString(@"#445566");
    [owner applyTypeColorSettings:foreground];
    auto* survivorEditor = (SettingsTestEditor*)survivor.editorViews.firstObject;
    survivorEditor.settingsRefreshes = 0;
    const NSUInteger previousOrderOutCount = panel.orderOutCount;
    // Neither window nor auxiliary panel was ever ordered on screen. Keeping
    // owner strongly referenced proves cleanup does not depend on dealloc.
    if (throughController) [owner close];
    else [owner.window close];
    expect(storedStringEquals(defaults, foregroundKey, @"#112233") &&
           storedStringEquals(defaults, backgroundKey, @"#AABBCC"),
           "closing a preview owner restores its key and retains another owner's Apply");
    expect([owner valueForKey:@"typeColorTransaction"] == nil &&
           panel.orderOutCount > previousOrderOutCount,
           "closing an owner immediately cancels its transaction and hides its settings panel");
    expect(survivorEditor.settingsRefreshes > 0,
           "closing an owner publishes rollback to surviving same-type editor windows");
    [survivor cancelTypeSettings:nil];
    [survivor.window close];
    [panel close];
    [(NSPanel*)[survivor valueForKey:@"typeSettingsPanel"] close];
    owner.testDocument = nil;
    survivor.testDocument = nil;
    [defaults removePersistentDomainForName:type];
  }
}

void changingFileTypeImmediatelyRelayoutsEveryPane() {
  NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
  NSDictionary* saved = [defaults volatileDomainForName:NSArgumentDomain] ?: @{};
  NSMutableDictionary* overrides = [saved mutableCopy];
  for (NSString* type in @[@"basic", @"cpp"]) {
    NSDictionary* values = @{
      @"wrapMode": @(SakuraEditorWrapModeNone), @"wrapColumn": @120,
      @"tabWidth": @4, @"fontName": @"", @"fontSize": [type isEqual:@"basic"] ? @10 : @22,
      @"lineSpacing": [type isEqual:@"basic"] ? @0 : @9,
      @"characterSpacing": @0, @"showsLineNumbers": @YES,
    };
    for (NSString* property in values) {
      overrides[[NSString stringWithFormat:@"SakuraTypeEditor.%@.%@", type, property]] =
          values[property];
    }
  }
  [defaults setVolatileDomain:overrides forName:NSArgumentDomain];
  SakuraDocument* document = [[SakuraDocument alloc] init];
  NSMutableString* text = [NSMutableString string];
  for (NSUInteger row = 0; row < 120; ++row) [text appendString:@"abc\n"];
  document.documentSession.insert(0,
      sakura::platform::mac::sakuraStringFromString(text));
  NSMutableArray<SakuraWindowController*>* controllers = [NSMutableArray array];
  NSMutableArray<SakuraEditorView*>* panes = [NSMutableArray array];
  std::vector<CGFloat> initialHeights;
  for (NSUInteger index = 0; index < 2; ++index) {
    auto* controller = [[SakuraWindowController alloc] initWithDocument:document];
    [document addWindowController:controller];
    [controller toggleSplitEditor:nil];
    [controllers addObject:controller];
    [panes addObjectsFromArray:controller.editorViews];
  }
  for (SakuraEditorView* editor in panes) {
    initialHeights.push_back(editor.frame.size.height);
    expect(editor.editorFont.pointSize == 10,
           "unsaved document starts with the basic type font");
  }
  // Save As updates NSDocument.fileURL. No manual refresh or redraw should be
  // needed before all windows and their split panes acquire the new geometry.
  document.fileURL = [NSURL fileURLWithPath:@"/settings-test/renamed.cpp"];
  for (NSUInteger index = 0; index < panes.count; ++index) {
    SakuraEditorView* editor = panes[index];
    const CGFloat expectedHeight = std::ceil(editor.editorFont.ascender -
        editor.editorFont.descender + editor.editorFont.leading) + 9;
    expect(editor.editorFont.pointSize == 22 &&
           std::abs(editor.editorLineHeight - expectedHeight) < 0.01,
           "type change immediately selects its font and line spacing");
    expect(editor.frame.size.height > initialHeights[index] + 100,
           "type change immediately expands every pane's document frame");
    const NSRect secondLine = [editor localRectForDisplayIndex:4];
    const NSRect firstLine = [editor localRectForDisplayIndex:0];
    expect(std::abs(secondLine.origin.y - firstLine.origin.y - expectedHeight) < 0.01,
           "type change keeps line and caret geometry aligned");
  }
  // Test objects were never shown and document recovery services were not run.
  for (SakuraWindowController* controller in controllers) [controller.window close];
  [defaults setVolatileDomain:saved forName:NSArgumentDomain];
}
}  // namespace

int main() {
  @autoreleasepool {
    [NSApplication sharedApplication];
    modelInheritsCommonAndIsolatesTypes();
    modelRejectsOutOfRangeAndMalformedPreferences();
    modelResetAndSelectiveSavePreserveInheritance();
    draftApplyCancelAndLiveColorHaveOneBoundary();
    cancellingOneWindowPreservesAnotherWindowsAppliedDisplaySettings();
    previewTransactionsComposeWithoutLosingCommittedOrPendingValues();
    resetDraftAndPartialEditsDoNotFreezeInheritedSettings();
    concurrentColorPanelsApplyCancelCloseAndResetSafely();
    closingPreviewOwnerRestoresAndRedrawsSurvivingWindows();
    changingFileTypeImmediatelyRelayoutsEveryPane();
  }
  if (failures != 0) return 1;
  std::cout << "All editor settings tests passed\n";
  return 0;
}
