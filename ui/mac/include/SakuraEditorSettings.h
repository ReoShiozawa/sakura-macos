// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SakuraEditorWrapMode) {
  SakuraEditorWrapModeNone = 0,
  SakuraEditorWrapModeWindow = 1,
  SakuraEditorWrapModeColumn = 2,
};

// Type-specific display settings. Absent type keys inherit the common font
// size/TAB width so upgrading does not silently change existing documents.
@interface SakuraEditorSettings : NSObject
@property(nonatomic) SakuraEditorWrapMode wrapMode;
@property(nonatomic) NSInteger wrapColumn;       // 10...10000, default 120
@property(nonatomic) NSInteger tabWidth;         // 1...16, default 4
@property(nonatomic, copy) NSString* fontName;   // empty = system monospaced
@property(nonatomic) CGFloat fontSize;          // 8...36, default 13
@property(nonatomic) CGFloat lineSpacing;       // 0...30 points, default 3
@property(nonatomic) CGFloat characterSpacing;  // 0...10 points, default 0
@property(nonatomic) BOOL showsLineNumbers;     // default YES

+ (instancetype)settingsForTypeIdentifier:(NSString*)typeIdentifier;
+ (instancetype)settingsForTypeIdentifier:(NSString*)typeIdentifier
                                defaults:(NSUserDefaults*)defaults;
// Default display values, with font size/TAB width inherited from common
// settings. Reading these values never modifies persisted type preferences.
+ (instancetype)inheritedSettingsWithDefaults:(NSUserDefaults*)defaults;
+ (void)resetForTypeIdentifier:(NSString*)typeIdentifier
                     defaults:(NSUserDefaults*)defaults;
- (void)saveForTypeIdentifier:(NSString*)typeIdentifier;
- (void)saveForTypeIdentifier:(NSString*)typeIdentifier
                    defaults:(NSUserDefaults*)defaults;
// Save only edited properties. Other keys (including absent inherited keys)
// remain untouched, so a stale panel cannot republish unrelated controls.
- (void)saveForTypeIdentifier:(NSString*)typeIdentifier
                    defaults:(NSUserDefaults*)defaults
                  properties:(NSSet<NSString*>*)properties;
- (NSDictionary<NSString*, id>*)preferenceValues;
- (NSFont*)editorFont;
+ (NSArray<NSString*>*)preferenceKeysForTypeIdentifier:(NSString*)typeIdentifier;
@end

// Main-thread live-preview transaction. Transactions sharing a defaults object
// compose per key: Cancel removes only this transaction's uncommitted changes;
// Commit preserves newer previews while retiring older previews of those keys.
@interface SakuraSettingsPreviewTransaction : NSObject
- (instancetype)initWithDefaults:(NSUserDefaults*)defaults;
- (void)setObject:(nullable id)value forKey:(NSString*)key;
- (void)commit;
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
