// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#import <AppKit/AppKit.h>

@class SakuraDocument;

@interface SakuraEditorView
    : NSView <NSTextInputClient, NSUserInterfaceValidations, NSSearchFieldDelegate>

- (instancetype)initWithFrame:(NSRect)frame
                      document:(SakuraDocument*)document
    NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder*)coder NS_UNAVAILABLE;

- (void)documentContentsDidChange;
- (void)displaySettingsDidChange;
- (void)toggleSplitEditor:(id)sender;
- (void)findTextFromToolbar:(NSString*)text;
- (void)findPrevious:(id)sender;
- (void)clearSearchMarks:(id)sender;
- (void)showOutlinePanel:(id)sender;
- (void)showCommandList:(id)sender;
- (void)showTypeSettingsList:(id)sender;
- (void)showTypeSettings:(id)sender;
- (void)showCommonSettings:(id)sender;
- (void)showEncodingPanel:(id)sender;
- (void)showGrepPanel:(id)sender;
- (void)showGrepReplacePanel:(id)sender;
- (void)goBackInNavigationHistory:(id)sender;
- (void)goForwardInNavigationHistory:(id)sender;
- (void)registerCurrentNavigationPosition:(id)sender;
- (NSUInteger)currentDocumentOffset;
- (NSUInteger)selectedCharacterCount;
- (BOOL)hasRectangularSelection;
- (void)toggleRectangularSelection:(id)sender;
- (void)jumpToDocumentOffset:(NSUInteger)offset;
- (void)toggleToolbar:(id)sender;
- (void)toggleStatusBar:(id)sender;

@end
