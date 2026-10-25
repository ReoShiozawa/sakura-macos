// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#import <AppKit/AppKit.h>

@class SakuraDocument;

@interface SakuraEditorView
    : NSView <NSTextInputClient, NSUserInterfaceValidations, NSSearchFieldDelegate, NSWindowDelegate>

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
- (NSString*)customSyntaxStatus;
- (NSString*)syntaxStatus;
- (BOOL)hasPendingSyntax;
- (void)cancelSyntaxHighlighting:(id)sender;
- (NSString*)searchHighlightStatus;
- (NSString*)searchOperationStatus;
- (void)useSelectionForFind:(id)sender;
- (void)countSearchMatches:(id)sender;
- (void)clearSharedSearchHistory:(id)sender;
- (void)cancelSearchOperations:(id)sender;
- (BOOL)hasPendingSearchNavigation;
- (BOOL)hasPendingReplacement;
@end

@interface SakuraEditorView (HistoryNavigation)
- (void)undo:(id)sender;
- (void)redo:(id)sender;
- (BOOL)hasPendingHistoryNavigation;
- (void)cancelHistoryNavigation:(id)sender;
@end

@interface SakuraEditorView (EditingCommands)
- (void)jumpToMatchingBracket:(id)sender;
- (BOOL)hasPendingBracketSearch;
- (void)cancelBracketSearch;
- (void)cancelBracketSearchesForDocument;
- (BOOL)jumpToLogicalLine:(NSUInteger)line;
- (void)showLineJump:(id)sender;
- (void)toggleBookmark:(id)sender;
- (void)nextBookmark:(id)sender;
- (void)previousBookmark:(id)sender;
- (void)clearBookmarks:(id)sender;
- (void)showBookmarks:(id)sender;
- (void)indentWithTab:(id)sender;
- (void)unindentWithTab:(id)sender;
- (void)indentWithSpaces:(id)sender;
- (void)unindentWithSpaces:(id)sender;
- (void)trimLeadingWhitespace:(id)sender;
- (void)trimTrailingWhitespace:(id)sender;
- (void)sortLinesAscending:(id)sender;
- (void)sortLinesDescending:(id)sender;
- (void)uniqueConsecutiveLines:(id)sender;
- (void)duplicateLogicalLines:(id)sender;
- (void)convertToHalfwidth:(id)sender;
- (void)convertToFullwidthKatakana:(id)sender;
- (void)convertToFullwidthHiragana:(id)sender;
- (void)tabsToSpaces:(id)sender;
- (void)spacesToTabs:(id)sender;
- (void)insertDate:(id)sender;
- (void)insertTime:(id)sender;
- (void)selectCurrentWord:(id)sender;
- (void)deleteCurrentWord:(id)sender;
- (void)deleteWordToLeft:(id)sender;
- (void)deleteWordToRight:(id)sender;
- (void)deleteToLogicalLineStart:(id)sender;
- (void)deleteToLogicalLineEnd:(id)sender;
- (void)deleteLogicalLines:(id)sender;
- (void)copyFileName:(id)sender;
- (void)copyFilePath:(id)sender;
- (void)copyFileLocation:(id)sender;
- (void)copyWithCRLF:(id)sender;

@end
