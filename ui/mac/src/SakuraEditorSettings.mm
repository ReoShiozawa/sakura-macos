// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#import "SakuraEditorSettings.h"

#include <algorithm>
#include <cmath>

namespace {
NSArray<NSString*>* editorSettingProperties() {
  return @[ @"wrapMode", @"wrapColumn", @"tabWidth", @"fontName", @"fontSize",
            @"lineSpacing", @"characterSpacing", @"showsLineNumbers" ];
}

NSString* keyFor(NSString* typeIdentifier, NSString* property) {
  return [NSString stringWithFormat:@"SakuraTypeEditor.%@.%@",
      typeIdentifier.length != 0 ? typeIdentifier : @"basic", property];
}

CGFloat finiteValue(CGFloat value, CGFloat fallback, CGFloat minimum,
                    CGFloat maximum) {
  return std::isfinite(value) ? std::clamp(value, minimum, maximum) : fallback;
}
}  // namespace

@implementation SakuraEditorSettings

+ (NSArray<NSString*>*)preferenceKeysForTypeIdentifier:(NSString*)typeIdentifier {
  NSMutableArray<NSString*>* keys = [NSMutableArray array];
  for (NSString* property in editorSettingProperties()) {
    [keys addObject:keyFor(typeIdentifier, property)];
  }
  return keys;
}

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _wrapMode = SakuraEditorWrapModeWindow;
    _wrapColumn = 120;
    _tabWidth = 4;
    _fontName = @"";
    _fontSize = 13;
    _lineSpacing = 3;
    _characterSpacing = 0;
    _showsLineNumbers = YES;
  }
  return self;
}

- (void)normalize {
  if (self.wrapMode < SakuraEditorWrapModeNone ||
      self.wrapMode > SakuraEditorWrapModeColumn) {
    self.wrapMode = SakuraEditorWrapModeWindow;
  }
  self.wrapColumn = std::clamp<NSInteger>(self.wrapColumn, 10, 10000);
  self.tabWidth = std::clamp<NSInteger>(self.tabWidth, 1, 16);
  self.fontSize = finiteValue(self.fontSize, 13, 8, 36);
  self.lineSpacing = finiteValue(self.lineSpacing, 3, 0, 30);
  self.characterSpacing = finiteValue(self.characterSpacing, 0, 0, 10);
  if (self.fontName == nil) self.fontName = @"";
}

+ (instancetype)settingsForTypeIdentifier:(NSString*)typeIdentifier {
  return [self settingsForTypeIdentifier:typeIdentifier
                               defaults:NSUserDefaults.standardUserDefaults];
}

+ (instancetype)settingsForTypeIdentifier:(NSString*)typeIdentifier
                                defaults:(NSUserDefaults*)defaults {
  SakuraEditorSettings* result = [self inheritedSettingsWithDefaults:defaults];
  for (NSString* property in editorSettingProperties()) {
    id value = [defaults objectForKey:keyFor(typeIdentifier, property)];
    if (value == nil) continue;
    if ([property isEqualToString:@"fontName"]) {
      if ([value isKindOfClass:NSString.class]) result.fontName = value;
    } else if ([value isKindOfClass:NSNumber.class]) {
      [result setValue:value forKey:property];
    }
  }
  [result normalize];
  return result;
}

+ (instancetype)inheritedSettingsWithDefaults:(NSUserDefaults*)defaults {
  SakuraEditorSettings* result = [[self alloc] init];
  if ([defaults objectForKey:@"SakuraEditorFontSize"] != nil) {
    result.fontSize = [defaults doubleForKey:@"SakuraEditorFontSize"];
  }
  if ([defaults objectForKey:@"SakuraEditorTabWidth"] != nil) {
    result.tabWidth = [defaults integerForKey:@"SakuraEditorTabWidth"];
  }
  [result normalize];
  return result;
}

+ (void)resetForTypeIdentifier:(NSString*)typeIdentifier
                     defaults:(NSUserDefaults*)defaults {
  for (NSString* key in [self preferenceKeysForTypeIdentifier:typeIdentifier]) {
    [defaults removeObjectForKey:key];
  }
}

- (void)saveForTypeIdentifier:(NSString*)typeIdentifier {
  [self saveForTypeIdentifier:typeIdentifier
                    defaults:NSUserDefaults.standardUserDefaults];
}

- (void)saveForTypeIdentifier:(NSString*)typeIdentifier
                    defaults:(NSUserDefaults*)defaults {
  [self saveForTypeIdentifier:typeIdentifier defaults:defaults
                  properties:[NSSet setWithArray:editorSettingProperties()]];
}

- (void)saveForTypeIdentifier:(NSString*)typeIdentifier
                    defaults:(NSUserDefaults*)defaults
                  properties:(NSSet<NSString*>*)properties {
  [self normalize];
  for (NSString* property in editorSettingProperties()) {
    if (![properties containsObject:property]) continue;
    [defaults setObject:[self valueForKey:property]
                forKey:keyFor(typeIdentifier, property)];
  }
}

- (NSDictionary<NSString*, id>*)preferenceValues {
  [self normalize];
  return [self dictionaryWithValuesForKeys:editorSettingProperties()];
}

- (NSFont*)editorFont {
  const CGFloat size = finiteValue(self.fontSize, 13, 8, 36);
  NSFont* font = self.fontName.length != 0
      ? [NSFont fontWithName:self.fontName size:size] : nil;
  return font != nil ? font
      : [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightRegular];
}

@end

@interface SakuraSettingsPreviewEntry : NSObject
@property(nonatomic, copy) NSString* owner;
@property(nonatomic, strong) id value;
@end
@implementation SakuraSettingsPreviewEntry
@end

@interface SakuraSettingsPreviewState : NSObject
@property(nonatomic, strong) id committedValue;
@property(nonatomic, strong) id expectedValue;
@property(nonatomic, strong) NSMutableArray<SakuraSettingsPreviewEntry*>* previews;
@end
@implementation SakuraSettingsPreviewState
@end

namespace {
using PreviewStates = NSMutableDictionary<NSString*, SakuraSettingsPreviewState*>;

PreviewStates* previewStatesForDefaults(NSUserDefaults* defaults) {
  static NSMapTable<NSUserDefaults*, PreviewStates*>* registry = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ registry = [NSMapTable weakToStrongObjectsMapTable]; });
  PreviewStates* states = [registry objectForKey:defaults];
  if (states == nil) {
    states = [NSMutableDictionary dictionary];
    [registry setObject:states forKey:defaults];
  }
  return states;
}

id previewStoredValue(NSUserDefaults* defaults, NSString* key) {
  return [defaults objectForKey:key] ?: NSNull.null;
}

void synchronizePreviewState(SakuraSettingsPreviewState* state,
                             NSUserDefaults* defaults, NSString* key) {
  id current = previewStoredValue(defaults, key);
  if (![state.expectedValue isEqual:current]) {
    // A writer outside the preview model establishes a new boundary. Never
    // overwrite that writer's value when an old panel subsequently cancels.
    state.committedValue = current;
    state.expectedValue = current;
    [state.previews removeAllObjects];
  }
}

void publishPreviewState(SakuraSettingsPreviewState* state,
                         NSUserDefaults* defaults, NSString* key) {
  id value = state.previews.lastObject.value ?: state.committedValue;
  state.expectedValue = value;
  if (value == NSNull.null) [defaults removeObjectForKey:key];
  else [defaults setObject:value forKey:key];
}
}  // namespace

@implementation SakuraSettingsPreviewTransaction {
  NSUserDefaults* _defaults;
  NSString* _owner;
  NSMutableSet<NSString*>* _pendingKeys;
}

- (instancetype)initWithDefaults:(NSUserDefaults*)defaults {
  self = [super init];
  if (self != nil) {
    _defaults = defaults;
    _owner = NSUUID.UUID.UUIDString;
    _pendingKeys = [NSMutableSet set];
  }
  return self;
}

- (void)setObject:(id)value forKey:(NSString*)key {
  NSAssert(NSThread.isMainThread, @"Settings previews must run on the main thread");
  PreviewStates* states = previewStatesForDefaults(_defaults);
  SakuraSettingsPreviewState* state = states[key];
  if (state == nil) {
    state = [[SakuraSettingsPreviewState alloc] init];
    state.committedValue = previewStoredValue(_defaults, key);
    state.expectedValue = state.committedValue;
    state.previews = [NSMutableArray array];
    states[key] = state;
  } else {
    synchronizePreviewState(state, _defaults, key);
  }
  NSIndexSet* ownEntries = [state.previews indexesOfObjectsPassingTest:
      ^BOOL(SakuraSettingsPreviewEntry* entry, NSUInteger index, BOOL* stop) {
    (void)index; (void)stop;
    return [entry.owner isEqualToString:_owner];
  }];
  [state.previews removeObjectsAtIndexes:ownEntries];
  SakuraSettingsPreviewEntry* entry = [[SakuraSettingsPreviewEntry alloc] init];
  entry.owner = _owner;
  entry.value = [value copy] ?: NSNull.null;
  [state.previews addObject:entry];
  [_pendingKeys addObject:key];
  publishPreviewState(state, _defaults, key);
}

- (void)finishCommitting:(BOOL)commit {
  PreviewStates* states = previewStatesForDefaults(_defaults);
  for (NSString* key in _pendingKeys) {
    SakuraSettingsPreviewState* state = states[key];
    if (state == nil) continue;
    synchronizePreviewState(state, _defaults, key);
    NSUInteger ownIndex = [state.previews indexOfObjectPassingTest:
        ^BOOL(SakuraSettingsPreviewEntry* entry, NSUInteger index, BOOL* stop) {
      (void)index; (void)stop;
      return [entry.owner isEqualToString:_owner];
    }];
    if (ownIndex != NSNotFound) {
      if (commit) {
        state.committedValue = state.previews[ownIndex].value;
        // An older hidden preview cannot resurface after a newer Apply.
        [state.previews removeObjectsInRange:NSMakeRange(0, ownIndex + 1)];
      } else {
        [state.previews removeObjectAtIndex:ownIndex];
      }
      publishPreviewState(state, _defaults, key);
    }
    if (state.previews.count == 0) [states removeObjectForKey:key];
  }
  [_pendingKeys removeAllObjects];
}

- (void)commit {
  NSAssert(NSThread.isMainThread, @"Settings previews must run on the main thread");
  [self finishCommitting:YES];
}

- (void)cancel {
  NSAssert(NSThread.isMainThread, @"Settings previews must run on the main thread");
  [self finishCommitting:NO];
}

- (void)dealloc {
  // Closing an owning document/window also discards its unfinished preview.
  if (_pendingKeys.count != 0) [self finishCommitting:NO];
}

@end
