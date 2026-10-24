// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#import <AppKit/AppKit.h>

@class SakuraDocument;
@class SakuraEditorView;

@interface SakuraWindowController : NSWindowController

- (instancetype)initWithDocument:(SakuraDocument*)document
    NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithWindow:(NSWindow*)window NS_UNAVAILABLE;
- (instancetype)initWithWindowNibName:(NSNibName)windowNibName NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder*)coder NS_UNAVAILABLE;

@property(nonatomic, strong, readonly) SakuraEditorView* editorView;
@property(nonatomic, copy, readonly) NSArray<SakuraEditorView*>* editorViews;

- (void)toggleSplitEditor:(id)sender;
- (void)updateStatusForEditor:(SakuraEditorView*)editor;
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
- (void)noteNavigationFromOffset:(NSUInteger)fromOffset
                        toOffset:(NSUInteger)toOffset;
- (void)toggleToolbar:(id)sender;
- (void)toggleStatusBar:(id)sender;

@end
