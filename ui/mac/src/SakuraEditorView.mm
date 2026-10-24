// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#import "SakuraEditorView.h"

#import <CoreText/CoreText.h>

#include <algorithm>
#include <cmath>
#include <exception>
#include <limits>
#include <memory>
#include <vector>

#import "SakuraDocument.h"
#import "SakuraColorTheme.h"
#import "SakuraEditorSettings.h"
#import "SakuraWindowController.h"
#include "sakura/core/layout/LayoutEngine.h"
#include "sakura/core/syntax/SyntaxHighlighter.h"
#include "sakura/platform/mac/CoreTextMetrics.h"
#include "sakura/platform/mac/StringBridge.h"

namespace {

constexpr CGFloat kHorizontalInset = 10.0;
constexpr CGFloat kVerticalInset = 8.0;
constexpr CGFloat kGutterWidth = 48.0;
constexpr CGFloat kTextOriginX = kGutterWidth + kHorizontalInset;
constexpr CGFloat kMinimumContentWidth = 320.0;
constexpr CGFloat kMinimumContentHeight = 200.0;

NSRange clampedRange(NSRange range, NSUInteger length) {
  if (range.location == NSNotFound) {
    return NSMakeRange(length, 0);
  }
  const NSUInteger location = std::min(range.location, length);
  const NSUInteger available = length - location;
  return NSMakeRange(location, std::min(range.length, available));
}

NSString* plainString(id value) {
  if ([value isKindOfClass:[NSAttributedString class]]) {
    return [(NSAttributedString*)value string];
  }
  if ([value isKindOfClass:[NSString class]]) {
    return (NSString*)value;
  }
  NSString* description = [value description];
  return description != nil ? description : @"";
}

NSUInteger lineIndexContainingCharacter(const std::vector<NSRange>& ranges,
                                        NSUInteger index,
                                        NSUInteger* steps) {
  if (ranges.empty()) return 0;
  auto found = std::lower_bound(ranges.begin(), ranges.end(), index,
      [steps](NSRange range, NSUInteger position) {
        if (steps != nullptr) ++*steps;
        return NSMaxRange(range) < position;
      });
  if (found == ranges.end()) return ranges.size() - 1;
  // Newline code units belong to the preceding row, as does a soft-wrap end.
  if (found->location > index && found != ranges.begin()) --found;
  return static_cast<NSUInteger>(found - ranges.begin());
}

CGFloat offsetForIndex(CTLineRef line, NSUInteger index) {
  const CFIndex count = CTLineGetGlyphCount(line);
  if (count == 0) {
    return 0.0;
  }
  CGFloat secondary = 0.0;
  return CTLineGetOffsetForStringIndex(line, static_cast<CFIndex>(index),
                                       &secondary);
}

NSString* syntaxRole(sakura::core::SyntaxTokenKind kind) {
  switch (kind) {
    case sakura::core::SyntaxTokenKind::comment: return @"comment";
    case sakura::core::SyntaxTokenKind::string: return @"string";
    case sakura::core::SyntaxTokenKind::keyword: return @"keyword";
    case sakura::core::SyntaxTokenKind::number: return @"number";
    case sakura::core::SyntaxTokenKind::preprocessor: return @"preprocessor";
  }
  return @"text";
}

}  // namespace

@interface SakuraEditorView ()
@property(nonatomic, weak) SakuraDocument* sakuraDocument;
@property(nonatomic) NSRange committedSelection;
@property(nonatomic, strong, nullable) NSAttributedString* markedTextStorage;
@property(nonatomic) NSRange markedReplacementRangeStorage;
@property(nonatomic) NSRange markedSelectionStorage;
@property(nonatomic) BOOL draggingSelection;
@property(nonatomic) NSUInteger dragAnchor;
@property(nonatomic) BOOL draggingWholeWords;
@property(nonatomic) NSRange dragInitialSelection;
@property(nonatomic) NSUInteger navigationAnchor;
@property(nonatomic) NSUInteger navigationCaret;
@property(nonatomic) CGFloat navigationPreferredX;
@property(nonatomic) BOOL rectangularSelectionActive;
@property(nonatomic) NSPoint rectangularAnchorPoint;
@property(nonatomic) NSPoint rectangularCurrentPoint;
@property(nonatomic, strong, nullable) NSPanel* findPanel;
@property(nonatomic, strong, nullable) NSSearchField* findField;
@property(nonatomic, strong, nullable) NSTextField* replaceField;
@property(nonatomic, strong, nullable) NSButton* caseSensitiveButton;
@property(nonatomic, strong, nullable) NSButton* wholeWordButton;
@property(nonatomic, strong, nullable) NSButton* regularExpressionButton;
@property(nonatomic, strong, nullable) NSTextField* findStatusLabel;
@property(nonatomic) BOOL searchMarksHidden;
@property(nonatomic) BOOL hasLastSearchMatch;
@property(nonatomic) NSRange lastSearchMatchRange;
@property(nonatomic) std::uint64_t lastSearchRevision;
@property(nonatomic, copy, nullable) NSString* lastSearchPattern;
@property(nonatomic) NSUInteger lastSearchFlags;
@end

@implementation SakuraEditorView {
  NSString* _cachedCommittedString;
  std::uint64_t _cachedTextRevision;
  NSString* _cachedDisplayString;
  NSString* _cachedMarkedString;
  NSRange _cachedMarkedReplacement;
  NSString* _layoutDisplayString;
  NSArray* _layoutKey;
  std::vector<NSRange> _cachedLineRanges;
  std::vector<std::size_t> _cachedLogicalLines;
  std::unique_ptr<sakura::core::TextBuffer> _markedLayoutBuffer;
  NSString* _markedLayoutString;
  CGFloat _cachedWidestLine;
  NSArray* _syntaxKey;
  std::vector<sakura::core::SyntaxToken> _cachedSyntaxTokens;
  NSArray* _searchKey;
  std::vector<NSRange> _cachedSearchRanges;
  NSArray* _styleKey;
  NSCache<NSNumber*, NSAttributedString*>* _styledLines;
  NSUInteger _textBuilds, _layoutBuilds, _syntaxBuilds, _searchBuilds;
  NSUInteger _styledBuilds, _drawnLines, _lineLookupSteps;
}

@synthesize committedSelection = _committedSelection;

- (void)setCommittedSelection:(NSRange)selection {
  _committedSelection = selection;
  // Assignments from editing, search, IME or document refresh end the current
  // keyboard selection. Navigation restores these values after its assignment.
  _navigationAnchor = NSNotFound;
  _navigationCaret = NSMaxRange(selection);
  _navigationPreferredX = NAN;
}

- (instancetype)initWithFrame:(NSRect)frame document:(SakuraDocument*)document {
  self = [super initWithFrame:frame];
  if (self != nil) {
    _sakuraDocument = document;
    _committedSelection = NSMakeRange(0, 0);
    _navigationAnchor = NSNotFound;
    _navigationCaret = 0;
    _navigationPreferredX = NAN;
    _markedReplacementRangeStorage = NSMakeRange(NSNotFound, 0);
    _markedSelectionStorage = NSMakeRange(0, 0);
    self.postsFrameChangedNotifications = YES;
    [self setAccessibilityElement:YES];
    [self setAccessibilityRole:NSAccessibilityTextAreaRole];
    [self documentContentsDidChange];
  }
  return self;
}

- (BOOL)isFlipped {
  return YES;
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (BOOL)canBecomeKeyView {
  return YES;
}

- (BOOL)becomeFirstResponder {
  [self setNeedsDisplay:YES];
  return YES;
}

- (BOOL)resignFirstResponder {
  [self setNeedsDisplay:YES];
  return YES;
}

- (NSFont*)editorFont {
  return [[self editorSettings] editorFont];
}

- (SakuraEditorSettings*)editorSettings {
  return [SakuraEditorSettings settingsForTypeIdentifier:
      SakuraTypeIdentifierForExtension(self.sakuraDocument.fileURL.pathExtension)];
}

- (CGFloat)editorLineHeight {
  NSFont* font = [self editorFont];
  return std::ceil(font.ascender - font.descender + font.leading) +
      [self editorSettings].lineSpacing;
}

- (NSDictionary<NSAttributedStringKey, id>*)baseTextAttributes {
  NSString* typeIdentifier = SakuraTypeIdentifierForExtension(
      self.sakuraDocument.fileURL.pathExtension);
  NSFont* font = [self editorFont];
  if (SakuraTypeStyleBool(typeIdentifier, @"text", @"bold", NO)) {
    font = [[NSFontManager sharedFontManager] convertFont:font
                                             toHaveTrait:NSBoldFontMask];
  }
  NSMutableDictionary<NSAttributedStringKey, id>* attributes =
      [@{
        NSFontAttributeName : font,
        NSLigatureAttributeName : @0,
        NSForegroundColorAttributeName : SakuraTypeColor(
            typeIdentifier, @"text", self.effectiveAppearance,
            SakuraEditorText(self.effectiveAppearance)),
      } mutableCopy];
  SakuraEditorSettings* settings = [self editorSettings];
  attributes[NSKernAttributeName] = @(settings.characterSpacing);
  NSMutableParagraphStyle* paragraph = [[NSMutableParagraphStyle alloc] init];
  paragraph.tabStops = @[];
  paragraph.defaultTabInterval = std::max<CGFloat>(1.0,
      [@" " sizeWithAttributes:@{NSFontAttributeName:font}].width +
      settings.characterSpacing) * settings.tabWidth;
  attributes[NSParagraphStyleAttributeName] = paragraph;
  if (SakuraTypeStyleBool(typeIdentifier, @"text", @"underline", NO)) {
    attributes[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
  }
  return attributes;
}

- (NSString*)committedString {
  SakuraDocument* document = self.sakuraDocument;
  if (document == nil) return @"";
  const auto revision = document.documentSession.buffer().revision();
  if (_cachedCommittedString == nil || _cachedTextRevision != revision) {
    _cachedCommittedString = sakura::platform::mac::stringFromSakuraString(
        document.documentSession.buffer().text());
    _cachedTextRevision = revision;
    _cachedDisplayString = nil;
    ++_textBuilds;
  }
  return _cachedCommittedString;
}

- (NSString*)displayString {
  NSString* committed = [self committedString];
  if (![self hasMarkedText]) {
    return committed;
  }

  const NSRange replacement =
      clampedRange(self.markedReplacementRangeStorage, committed.length);
  NSString* marked = self.markedTextStorage.string;
  if (_cachedDisplayString == nil ||
      !NSEqualRanges(replacement, _cachedMarkedReplacement) ||
      ![_cachedMarkedString isEqualToString:marked]) {
    NSMutableString* display = [committed mutableCopy];
    [display replaceCharactersInRange:replacement withString:marked];
    _cachedDisplayString = display;
    _cachedMarkedString = [marked copy];
    _cachedMarkedReplacement = replacement;
  }
  return _cachedDisplayString;
}

- (NSRange)displaySelection {
  if (![self hasMarkedText]) {
    return self.committedSelection;
  }
  const NSUInteger markedLength = self.markedTextStorage.length;
  const NSRange relative =
      clampedRange(self.markedSelectionStorage, markedLength);
  return NSMakeRange(self.markedReplacementRangeStorage.location +
                         relative.location,
                     relative.length);
}

- (void)clearMarkedState {
  self.markedTextStorage = nil;
  self.markedReplacementRangeStorage = NSMakeRange(NSNotFound, 0);
  self.markedSelectionStorage = NSMakeRange(0, 0);
  _markedLayoutBuffer.reset();
  _markedLayoutString = nil;
}

- (NSRange)committedRangeForDisplayRange:(NSRange)displayRange {
  NSString* committed = [self committedString];
  if (displayRange.location == NSNotFound) {
    return self.committedSelection;
  }
  if (![self hasMarkedText]) {
    return clampedRange(displayRange, committed.length);
  }

  const NSRange replacement =
      clampedRange(self.markedReplacementRangeStorage, committed.length);
  const NSRange marked = NSMakeRange(replacement.location,
                                     self.markedTextStorage.length);
  const NSRange clampedDisplay = clampedRange(displayRange, [self displayString].length);
  const NSUInteger displayStart = clampedDisplay.location;
  const NSUInteger displayEnd = NSMaxRange(clampedDisplay);
  const NSUInteger markedEnd = NSMaxRange(marked);

  if ((clampedDisplay.length != 0 &&
       NSIntersectionRange(clampedDisplay, marked).length != 0) ||
      (clampedDisplay.length == 0 && displayStart > marked.location &&
       displayStart < markedEnd)) {
    return replacement;
  }

  const auto mapIndex = [&](NSUInteger index) {
    if (index <= marked.location) {
      return index;
    }
    if (index >= markedEnd) {
      return index - marked.length + replacement.length;
    }
    return replacement.location;
  };

  const NSUInteger start = mapIndex(displayStart);
  const NSUInteger end = mapIndex(displayEnd);
  return clampedRange(NSMakeRange(start, end >= start ? end - start : 0),
                      committed.length);
}

- (void)replaceCommittedRange:(NSRange)range withString:(NSString*)text {
  [self clearRectangularSelection];
  NSString* committed = [self committedString];
  range = clampedRange(range, committed.length);
  if (range.length == 0 && text.length == 0) {
    self.committedSelection = NSMakeRange(range.location, 0);
    [self setNeedsDisplay:YES];
    return;
  }

  try {
    const auto replacement =
        sakura::platform::mac::sakuraStringFromString(text);
    self.sakuraDocument.documentSession.replace(
        {static_cast<sakura::core::TextOffset>(range.location),
         static_cast<sakura::core::TextOffset>(range.length)},
        replacement);
    self.committedSelection = NSMakeRange(range.location + text.length, 0);
    [self.sakuraDocument noteEditorChange:NSChangeDone];
    [self.sakuraDocument refreshEditorViews];
    [self scrollSelectionToVisible];
  } catch (const std::exception&) {
    NSBeep();
  }
}

- (void)replaceRectangularSelectionWithStrings:(NSArray<NSString*>*)strings {
  NSArray<NSDictionary*>* selections = [self rectangularSelections];
  if (selections.count == 0 || strings.count == 0) return;
  try {
    std::vector<sakura::core::EditReplacement> replacements;
    replacements.reserve(selections.count);
    for (NSInteger index = static_cast<NSInteger>(selections.count) - 1;
         index >= 0; --index) {
      NSDictionary* selection = selections[static_cast<NSUInteger>(index)];
      const NSRange range = [selection[@"committedRange"] rangeValue];
      NSString* text = strings.count == selections.count
          ? strings[static_cast<NSUInteger>(index)] : strings.firstObject;
      const NSUInteger leadingSpaces =
          [selection[@"leadingVirtualSpaces"] unsignedIntegerValue];
      if (text.length != 0 && leadingSpaces != 0) {
        NSString* padding = [@"" stringByPaddingToLength:leadingSpaces
                                              withString:@" "
                                         startingAtIndex:0];
        text = [padding stringByAppendingString:text];
      }
      replacements.push_back({
          {static_cast<sakura::core::TextOffset>(range.location),
           static_cast<sakura::core::TextOffset>(range.length)},
          sakura::platform::mac::sakuraStringFromString(text),
      });
    }
    NSDictionary* firstSelection = selections.firstObject;
    const NSRange firstRange = [firstSelection[@"committedRange"] rangeValue];
    NSString* firstText = strings.firstObject;
    const NSUInteger firstLeadingSpaces =
        [firstSelection[@"leadingVirtualSpaces"] unsignedIntegerValue];
    if (firstText.length != 0 && firstLeadingSpaces != 0) {
      firstText = [[@"" stringByPaddingToLength:firstLeadingSpaces
                                      withString:@" "
                                 startingAtIndex:0]
          stringByAppendingString:firstText];
    }
    [self clearRectangularSelection];
    self.sakuraDocument.documentSession.replaceMany(replacements);
    self.committedSelection = NSMakeRange(
        firstRange.location + firstText.length, 0);
    [self.sakuraDocument noteEditorChange:NSChangeDone];
    [self.sakuraDocument refreshEditorViews];
    [self scrollSelectionToVisible];
  } catch (const std::exception&) {
    NSBeep();
  }
}

- (NSUInteger)previousEditBoundaryAtOrBefore:(NSUInteger)index {
  const auto& buffer = self.sakuraDocument.documentSession.buffer();
  index = std::min<NSUInteger>(index, static_cast<NSUInteger>(buffer.length()));
  while (index != 0 && !buffer.isEditBoundary(index)) {
    --index;
  }
  return index;
}

- (NSUInteger)nextEditBoundaryAtOrAfter:(NSUInteger)index {
  const auto& buffer = self.sakuraDocument.documentSession.buffer();
  const NSUInteger length = static_cast<NSUInteger>(buffer.length());
  index = std::min(index, length);
  while (index < length && !buffer.isEditBoundary(index)) {
    ++index;
  }
  return index;
}

- (NSRange)rangeByExpandingToEditBoundaries:(NSRange)range {
  const NSUInteger start = [self previousEditBoundaryAtOrBefore:range.location];
  const NSUInteger end =
      [self nextEditBoundaryAtOrAfter:NSMaxRange(range)];
  return NSMakeRange(start, end - start);
}

- (void)documentContentsDidChange {
  [self clearRectangularSelection];
  const NSUInteger length = [self committedString].length;
  self.committedSelection = clampedRange(self.committedSelection, length);
  [self updateDocumentViewSize];
  [self setNeedsDisplay:YES];
}

- (void)displaySettingsDidChange {
  // Appearance changes do not edit text or end keyboard/rectangular selection.
  [self updateDocumentViewSize];
  [self setNeedsDisplay:YES];
}

- (void)viewDidMoveToSuperview {
  [super viewDidMoveToSuperview];
  if (self.superview != nil && self.sakuraDocument != nil) {
    [self updateDocumentViewSize];
  }
}

- (void)viewDidEndLiveResize {
  [super viewDidEndLiveResize];
  [self updateDocumentViewSize];
}

- (void)viewDidChangeEffectiveAppearance {
  [super viewDidChangeEffectiveAppearance];
  [self setNeedsDisplay:YES];
}

- (const std::vector<NSRange>&)displayLineRanges {
  NSString* display = [self displayString];
  SakuraEditorSettings* settings = [self editorSettings];
  NSFont* font = [self baseTextAttributes][NSFontAttributeName];
  const NSSize viewport = self.enclosingScrollView != nil
                              ? self.enclosingScrollView.contentSize
                              : self.bounds.size;
  NSArray* key = @[font.fontName, @(font.pointSize), @(settings.characterSpacing),
      @(settings.tabWidth), @(settings.wrapMode), @(settings.wrapColumn),
      @(settings.wrapMode == SakuraEditorWrapModeWindow ? viewport.width : 0.0),
      @([self hasMarkedText])];
  if (_layoutDisplayString == display && [_layoutKey isEqual:key]) {
    return _cachedLineRanges;
  }
  _layoutDisplayString = display;
  _layoutKey = key;
  _cachedLineRanges.clear();
  _cachedLogicalLines.clear();
  _cachedWidestLine = 0.0;
  ++_layoutBuilds;
  [_styledLines removeAllObjects];
  // Use the same layout for the input method's preview, without committing it
  // to the document, undo history, or another pane. Font/viewport changes can
  // reuse this temporary buffer while selectedRange-only updates reuse layout.
  SakuraDocument* document = self.sakuraDocument;
  const sakura::core::TextBuffer* layoutBuffer = nullptr;
  if ([self hasMarkedText] || self.sakuraDocument == nil) {
    if (_markedLayoutBuffer == nullptr || _markedLayoutString != display) {
      _markedLayoutBuffer = std::make_unique<sakura::core::TextBuffer>(
          sakura::platform::mac::sakuraStringFromString(display));
      _markedLayoutString = display;
    }
    layoutBuffer = _markedLayoutBuffer.get();
  } else {
    layoutBuffer = &document.documentSession.buffer();
    _markedLayoutBuffer.reset();
    _markedLayoutString = nil;
  }
  const char* fontName = font.fontName.UTF8String;
  sakura::platform::mac::CoreTextMetrics metrics(
      fontName != nullptr ? fontName : "Menlo-Regular", font.pointSize,
      settings.characterSpacing);
  sakura::core::LayoutEngine engine;
  const sakura::core::FontStyle style{0, static_cast<float>(font.pointSize),
                                      400, false};
  float wrapWidth = 0.0F;
  if (settings.wrapMode == SakuraEditorWrapModeWindow) {
    wrapWidth = std::max(1.0F, static_cast<float>(
        viewport.width - kGutterWidth - 2.0 * kHorizontalInset));
  } else if (settings.wrapMode == SakuraEditorWrapModeColumn) {
    wrapWidth = metrics.advance(u' ', style) * settings.wrapColumn;
  }
  const auto layout = engine.layout(
      *layoutBuffer, metrics, style,
      {.wrapWidth = wrapWidth,
       .tabWidth = static_cast<sakura::core::TextOffset>(
           settings.tabWidth)});

  _cachedLineRanges.reserve(layout.visualLines.size());
  _cachedLogicalLines.reserve(layout.visualLines.size());
  const auto& buffer = *layoutBuffer;
  std::size_t logicalLine = 0;
  sakura::core::TextOffset logicalStart = 0;
  for (const auto& visual : layout.visualLines) {
    // Layout rows are ordered. Accumulate offsets once instead of making a
    // prefix-index query for every fragment in a million-line cold layout.
    while (logicalLine < visual.logicalLine) {
      const auto& previous = buffer.line(logicalLine++);
      logicalStart += previous.content.size();
      switch (previous.ending) {
        case sakura::core::LineEnding::none: break;
        case sakura::core::LineEnding::lineFeed:
        case sakura::core::LineEnding::carriageReturn: ++logicalStart; break;
        case sakura::core::LineEnding::carriageReturnLineFeed: logicalStart += 2; break;
      }
    }
    const auto start = logicalStart + visual.startColumn;
    _cachedLineRanges.push_back(NSMakeRange(static_cast<NSUInteger>(start),
                                 static_cast<NSUInteger>(visual.endColumn -
                                                         visual.startColumn)));
    _cachedLogicalLines.push_back(visual.logicalLine);
    _cachedWidestLine = std::max<CGFloat>(_cachedWidestLine, visual.width);
  }
  return _cachedLineRanges;
}

- (void)updateDocumentViewSize {
  if (self.sakuraDocument == nil) return;
  const auto& lines = [self displayLineRanges];

  NSSize viewport = self.enclosingScrollView != nil
                        ? self.enclosingScrollView.contentSize
                        : self.bounds.size;
  const CGFloat rectangularWidth = self.rectangularSelectionActive
      ? std::max(self.rectangularAnchorPoint.x,
                 self.rectangularCurrentPoint.x) + kHorizontalInset
      : 0.0;
  const CGFloat width = std::max({kMinimumContentWidth, viewport.width,
                                  _cachedWidestLine + kGutterWidth + 2.0 * kHorizontalInset,
                                  rectangularWidth});
  const CGFloat height =
      std::max({kMinimumContentHeight, viewport.height,
                kVerticalInset * 2.0 +
                    [self editorLineHeight] * static_cast<CGFloat>(lines.size())});
  if (std::abs(self.frame.size.width - width) > 0.5 ||
      std::abs(self.frame.size.height - height) > 0.5) {
    [self setFrameSize:NSMakeSize(width, height)];
  }
}

- (void)refreshStyledLineCache {
  NSString* type = SakuraTypeIdentifierForExtension(
      self.sakuraDocument.fileURL.pathExtension);
  NSMutableArray* key = [NSMutableArray arrayWithArray:
      @[type, [self baseTextAttributes], @(SakuraThemeIsDark(self.effectiveAppearance))]];
  NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
  for (NSString* role in @[@"comment", @"string", @"keyword", @"number",
                            @"preprocessor", @"search"]) {
    id color = [defaults objectForKey:SakuraTypeColorPreferenceKey(
        type, role, self.effectiveAppearance)];
    [key addObject:color != nil ? color : NSNull.null];
    for (NSString* attribute in @[@"display", @"bold", @"underline"]) {
      id value = [defaults objectForKey:SakuraTypeStylePreferenceKey(
          type, role, attribute)];
      [key addObject:value != nil ? value : NSNull.null];
    }
  }
  if (_styledLines == nil) {
    _styledLines = [[NSCache alloc] init];
    _styledLines.countLimit = 256;
    _styledLines.totalCostLimit = 8 * 1024 * 1024;
  }
  if (![_styleKey isEqual:key]) {
    _styleKey = [key copy];
    [_styledLines removeAllObjects];
  }
}

- (NSAttributedString*)styledLineAtIndex:(NSUInteger)index {
  NSAttributedString* cached = [_styledLines objectForKey:@(index)];
  if (cached != nil) return cached;
  const NSRange range = _cachedLineRanges[index];
  NSMutableAttributedString* text = [[NSMutableAttributedString alloc]
      initWithString:[[self displayString] substringWithRange:range]
          attributes:[self baseTextAttributes]];
  NSString* type = SakuraTypeIdentifierForExtension(
      self.sakuraDocument.fileURL.pathExtension);
  auto attributesForRole = [&](NSString* role, NSColor* fallback) {
    NSMutableDictionary* attributes = [@{NSForegroundColorAttributeName:
        SakuraTypeColor(type, role, self.effectiveAppearance, fallback)} mutableCopy];
    if (SakuraTypeStyleBool(type, role, @"bold", NO)) {
      attributes[NSFontAttributeName] = [[NSFontManager sharedFontManager]
          convertFont:[self editorFont] toHaveTrait:NSBoldFontMask];
    }
    if (SakuraTypeStyleBool(type, role, @"underline", NO)) {
      attributes[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
    }
    return attributes;
  };
  auto tokenStart = std::lower_bound(_cachedSyntaxTokens.begin(),
      _cachedSyntaxTokens.end(), range.location,
      [](const auto& token, NSUInteger start) {
        return token.range.location + token.range.length <= start;
      });
  for (auto iterator = tokenStart; iterator != _cachedSyntaxTokens.end() &&
       iterator->range.location < NSMaxRange(range); ++iterator) {
    NSString* role = syntaxRole(iterator->kind);
    if (!SakuraTypeStyleBool(type, role, @"display", YES)) continue;
    NSColor* fallback = SakuraEditorText(self.effectiveAppearance);
    switch (iterator->kind) {
      case sakura::core::SyntaxTokenKind::comment:
        fallback = SakuraCommentText(self.effectiveAppearance); break;
      case sakura::core::SyntaxTokenKind::string:
        fallback = SakuraStringText(self.effectiveAppearance); break;
      case sakura::core::SyntaxTokenKind::keyword:
        fallback = SakuraKeywordText(self.effectiveAppearance); break;
      case sakura::core::SyntaxTokenKind::number:
        fallback = SakuraNumberText(self.effectiveAppearance); break;
      case sakura::core::SyntaxTokenKind::preprocessor:
        fallback = SakuraPreprocessorText(self.effectiveAppearance); break;
    }
    NSRange intersection = NSIntersectionRange(range, NSMakeRange(
        iterator->range.location, iterator->range.length));
    intersection.location -= range.location;
    [text addAttributes:attributesForRole(role, fallback) range:intersection];
  }
  if (SakuraTypeStyleBool(type, @"search", @"display", YES)) {
    auto searchStart = std::lower_bound(_cachedSearchRanges.begin(),
        _cachedSearchRanges.end(), range.location, [](NSRange match, NSUInteger start) {
          return NSMaxRange(match) <= start;
        });
    NSDictionary* attributes = attributesForRole(@"search",
        SakuraSearchText(self.effectiveAppearance));
    for (auto iterator = searchStart; iterator != _cachedSearchRanges.end() &&
         iterator->location < NSMaxRange(range); ++iterator) {
      NSRange intersection = NSIntersectionRange(range, *iterator);
      intersection.location -= range.location;
      [text addAttributes:attributes range:intersection];
    }
  }
  ++_styledBuilds;
  [_styledLines setObject:text forKey:@(index) cost:range.length * sizeof(unichar) + 256];
  return text;
}

- (void)drawRect:(NSRect)dirtyRect {
  if (self.sakuraDocument == nil) return;
  NSString* typeIdentifier = SakuraTypeIdentifierForExtension(
      self.sakuraDocument.fileURL.pathExtension);
  NSColor* editorBackground = SakuraTypeColor(
      typeIdentifier, @"background", self.effectiveAppearance,
      SakuraEditorBackground(self.effectiveAppearance));
  [editorBackground setFill];
  NSRectFill(dirtyRect);
  [SakuraTypeColor(typeIdentifier, @"gutterBackground",
                   self.effectiveAppearance,
                   SakuraGutterBackground(self.effectiveAppearance)) setFill];
  NSRectFill(NSMakeRect(0.0, NSMinY(dirtyRect), kGutterWidth,
                        NSHeight(dirtyRect)));
  [SakuraChromeBorder(self.effectiveAppearance) setFill];
  NSRectFill(NSMakeRect(kGutterWidth - 1.0, NSMinY(dirtyRect), 1.0,
                        NSHeight(dirtyRect)));

  NSString* display = [self displayString];
  const auto& ranges = [self displayLineRanges];
  const auto& syntaxTokens = [self activeSyntaxTokens];
  const auto& searchRanges = [self activeSearchRanges];
  [self refreshStyledLineCache];
  const NSRange selected = clampedRange([self displaySelection], display.length);
  NSArray<NSValue*>* selectionRanges = self.rectangularSelectionActive
      ? [self rectangularDisplayRanges]
      : (selected.length != 0
             ? @[ [NSValue valueWithRange:selected] ] : @[]);
  const NSUInteger selectedCharacterCount = [self selectedCharacterCount];
  NSMutableDictionary<NSAttributedStringKey, id>* selectionAttributes = nil;
  if (selectionRanges.count != 0) {
    selectionAttributes =
        [@{NSForegroundColorAttributeName : SakuraTypeColor(
              typeIdentifier, @"selection", self.effectiveAppearance,
              SakuraSelectionText(self.effectiveAppearance))} mutableCopy];
    if (SakuraTypeStyleBool(typeIdentifier, @"selection", @"bold", NO)) {
      selectionAttributes[NSFontAttributeName] = [[NSFontManager sharedFontManager]
          convertFont:[self editorFont] toHaveTrait:NSBoldFontMask];
    }
    if (SakuraTypeStyleBool(typeIdentifier, @"selection", @"underline", NO)) {
      selectionAttributes[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
    }
  }

  NSRange marked = NSMakeRange(NSNotFound, 0);
  if ([self hasMarkedText]) {
    marked = clampedRange([self markedRange], display.length);
  }

  const NSUInteger caretLine = lineIndexContainingCharacter(
      ranges, selected.location, &_lineLookupSteps);
  NSFont* lineNumberFont = [NSFont monospacedDigitSystemFontOfSize:11.0
                                                            weight:NSFontWeightRegular];
  if (SakuraTypeStyleBool(typeIdentifier, @"gutter", @"bold", NO)) {
    lineNumberFont = [[NSFontManager sharedFontManager]
        convertFont:lineNumberFont toHaveTrait:NSBoldFontMask];
  }
  NSMutableDictionary<NSAttributedStringKey, id>* lineNumberAttributes =
      [@{
        NSFontAttributeName : lineNumberFont,
        NSForegroundColorAttributeName : SakuraTypeColor(
            typeIdentifier, @"gutter", self.effectiveAppearance,
            SakuraGutterText(self.effectiveAppearance)),
      } mutableCopy];
  if (SakuraTypeStyleBool(typeIdentifier, @"gutter", @"underline", NO)) {
    lineNumberAttributes[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
  }
  CGContextRef context = NSGraphicsContext.currentContext.CGContext;
  const CGFloat lineHeight = [self editorLineHeight];
  const NSUInteger firstVisible = std::min<NSUInteger>(ranges.size(),
      static_cast<NSUInteger>(std::max<CGFloat>(0.0,
          std::floor((NSMinY(dirtyRect) - kVerticalInset) / lineHeight))));
  const NSUInteger endVisible = std::min<NSUInteger>(ranges.size(),
      static_cast<NSUInteger>(std::max<CGFloat>(0.0,
          std::ceil((NSMaxY(dirtyRect) - kVerticalInset) / lineHeight))));
  std::size_t previousLogicalLine = std::numeric_limits<std::size_t>::max();
  if (firstVisible != 0 && firstVisible <= ranges.size()) {
    previousLogicalLine = _cachedLogicalLines[firstVisible - 1];
  }
  const BOOL showLineNumbers = [self editorSettings].showsLineNumbers;
  for (NSUInteger lineIndex = firstVisible; lineIndex < endVisible; ++lineIndex) {
    const CGFloat top = kVerticalInset + lineIndex * lineHeight;
    const auto logicalLine = _cachedLogicalLines[lineIndex];
    if (logicalLine != previousLogicalLine &&
        showLineNumbers &&
        SakuraTypeStyleBool(typeIdentifier, @"gutter", @"display", YES)) {
      NSString* number = [NSString stringWithFormat:@"%zu", logicalLine + 1];
      [number drawInRect:NSMakeRect(4.0, top + 1.0, kGutterWidth - 10.0,
                                    lineHeight)
            withAttributes:lineNumberAttributes];
    }
    previousLogicalLine = logicalLine;
  }
  CGContextSaveGState(context);
  CGContextSetTextMatrix(context, CGAffineTransformMakeScale(1.0, -1.0));

  const CGFloat baselineOffset = [self editorFont].ascender + 1.0;
  auto drawMarker = [&](NSString* marker, NSString* role, CGFloat x,
                        CGFloat markerWidth, CGFloat top) {
    NSFont* markerFont = [NSFont monospacedSystemFontOfSize:11.0
                                                     weight:NSFontWeightRegular];
    if (SakuraTypeStyleBool(typeIdentifier, role, @"bold", NO)) {
      markerFont = [[NSFontManager sharedFontManager]
          convertFont:markerFont toHaveTrait:NSBoldFontMask];
    }
    NSColor* foreground = nil;
    if ([role isEqualToString:@"tabMarker"]) {
      foreground = SakuraTabMarkerText(self.effectiveAppearance);
    } else if ([role isEqualToString:@"halfSpaceMarker"] ||
               [role isEqualToString:@"fullSpaceMarker"]) {
      foreground = SakuraSpaceMarkerText(self.effectiveAppearance);
    } else if ([role isEqualToString:@"eolMarker"]) {
      foreground = SakuraEolMarkerText(self.effectiveAppearance);
    } else if ([role isEqualToString:@"wrapMarker"]) {
      foreground = SakuraWrapMarkerText(self.effectiveAppearance);
    } else {
      foreground = SakuraEofMarkerText(self.effectiveAppearance);
    }
    NSString* backgroundRole = [role stringByAppendingString:@"Background"];
    NSColor* backgroundFallback = [role isEqualToString:@"eofMarker"]
        ? SakuraEofMarkerBackground(self.effectiveAppearance)
        : editorBackground;
    NSMutableDictionary<NSAttributedStringKey, id>* markerAttributes =
        [@{
          NSFontAttributeName : markerFont,
          NSForegroundColorAttributeName : SakuraTypeColor(
              typeIdentifier, role, self.effectiveAppearance, foreground),
        } mutableCopy];
    if (SakuraTypeStyleBool(typeIdentifier, role, @"underline", NO)) {
      markerAttributes[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
    }
    NSAttributedString* markerText = [[NSAttributedString alloc]
        initWithString:marker attributes:markerAttributes];
    CTLineRef markerLine = CTLineCreateWithAttributedString(
        (__bridge CFAttributedStringRef)markerText);
    const CGFloat measuredWidth = static_cast<CGFloat>(
        CTLineGetTypographicBounds(markerLine, nullptr, nullptr, nullptr));
    NSString* backgroundKey = SakuraTypeColorPreferenceKey(
        typeIdentifier, backgroundRole, self.effectiveAppearance);
    if ([role isEqualToString:@"eofMarker"] ||
        [[NSUserDefaults standardUserDefaults] objectForKey:backgroundKey] != nil) {
      [SakuraTypeColor(typeIdentifier, backgroundRole, self.effectiveAppearance,
                       backgroundFallback) setFill];
      NSRectFill(NSMakeRect(x, top, std::max(markerWidth, measuredWidth), lineHeight));
    }
    CGContextSetTextPosition(context, x, top + baselineOffset);
    CTLineDraw(markerLine, context);
    CFRelease(markerLine);
  };
  for (NSUInteger lineIndex = firstVisible; lineIndex < endVisible; ++lineIndex) {
    const CGFloat top = kVerticalInset + lineIndex * lineHeight;
    ++_drawnLines;

    const NSRange lineRange = ranges[lineIndex];
    if (selectedCharacterCount == 0 && lineIndex == caretLine &&
        SakuraTypeStyleBool(typeIdentifier, @"caretLine", @"display", YES)) {
      [SakuraTypeColor(typeIdentifier, @"caretLine", self.effectiveAppearance,
                       SakuraCaretLine(self.effectiveAppearance)) setFill];
      NSRectFill(NSMakeRect(kGutterWidth, top + lineHeight - 1.0,
                           std::max<CGFloat>(0.0,
                               self.bounds.size.width - kGutterWidth), 1.0));
    }
    NSAttributedString* lineText = [self styledLineAtIndex:lineIndex];
    NSMutableAttributedString* overlay = nil;
    for (NSValue* value in selectionRanges) {
      NSRange intersection = NSIntersectionRange(value.rangeValue, lineRange);
      if (intersection.length == 0) continue;
      if (overlay == nil) overlay = [lineText mutableCopy];
      intersection.location -= lineRange.location;
      [overlay addAttributes:selectionAttributes range:intersection];
    }
    if (marked.location != NSNotFound) {
      NSRange intersection = NSIntersectionRange(marked, lineRange);
      if (intersection.length != 0) {
        if (overlay == nil) overlay = [lineText mutableCopy];
        intersection.location -= lineRange.location;
        [overlay addAttributes:@{
            NSUnderlineStyleAttributeName:@(NSUnderlineStyleSingle),
            NSUnderlineColorAttributeName:NSColor.keyboardFocusIndicatorColor}
                         range:intersection];
      }
    }
    if (overlay != nil) lineText = overlay;
    CTLineRef line = CTLineCreateWithAttributedString(
        (__bridge CFAttributedStringRef)lineText);

    auto tokenStart = std::lower_bound(syntaxTokens.begin(), syntaxTokens.end(),
        lineRange.location, [](const auto& token, NSUInteger start) {
          return token.range.location + token.range.length <= start;
        });
    for (auto iterator = tokenStart; iterator != syntaxTokens.end() &&
         iterator->range.location < NSMaxRange(lineRange); ++iterator) {
      const auto& token = *iterator;
      NSString* role = nil;
      switch (token.kind) {
        case sakura::core::SyntaxTokenKind::comment: role = @"comment"; break;
        case sakura::core::SyntaxTokenKind::string: role = @"string"; break;
        case sakura::core::SyntaxTokenKind::keyword: role = @"keyword"; break;
        case sakura::core::SyntaxTokenKind::number: role = @"number"; break;
        case sakura::core::SyntaxTokenKind::preprocessor:
          role = @"preprocessor";
          break;
      }
      if (!SakuraTypeStyleBool(typeIdentifier, role, @"display", YES)) {
        continue;
      }
      NSRange tokenRange = NSMakeRange(
          static_cast<NSUInteger>(token.range.location),
          static_cast<NSUInteger>(token.range.length));
      NSRange tokenOnLine = NSIntersectionRange(tokenRange, lineRange);
      if (tokenOnLine.length == 0) continue;
      const CGFloat left = offsetForIndex(
          line, tokenOnLine.location - lineRange.location);
      const CGFloat right = offsetForIndex(
          line, NSMaxRange(tokenOnLine) - lineRange.location);
      [SakuraTypeColor(typeIdentifier,
                       [role stringByAppendingString:@"Background"],
                       self.effectiveAppearance, editorBackground) setFill];
      NSRectFill(NSMakeRect(kTextOriginX + left, top,
                            std::max<CGFloat>(1.0, right - left), lineHeight));
    }

    if (SakuraTypeStyleBool(typeIdentifier, @"search", @"display", YES)) {
      auto searchStart = std::lower_bound(searchRanges.begin(), searchRanges.end(),
          lineRange.location, [](NSRange range, NSUInteger start) {
            return NSMaxRange(range) <= start;
          });
      for (auto iterator = searchStart; iterator != searchRanges.end() &&
           iterator->location < NSMaxRange(lineRange); ++iterator) {
        const NSRange searchRange = *iterator;
        const NSRange searchOnLine = NSIntersectionRange(searchRange, lineRange);
        if (searchOnLine.length == 0) continue;
        const CGFloat left = offsetForIndex(
            line, searchOnLine.location - lineRange.location);
        const CGFloat right = offsetForIndex(
            line, NSMaxRange(searchOnLine) - lineRange.location);
        [SakuraTypeColor(typeIdentifier, @"searchBackground",
                         self.effectiveAppearance,
                         SakuraSearchBackground(self.effectiveAppearance)) setFill];
        NSRectFill(NSMakeRect(kTextOriginX + left, top,
                              std::max<CGFloat>(1.0, right - left), lineHeight));
      }
    }

    if (self.rectangularSelectionActive) {
      const NSRange rectangularLines = [self rectangularDisplayLineSpan];
      if (rectangularLines.location != NSNotFound &&
          NSLocationInRange(lineIndex, rectangularLines)) {
        const CGFloat left = std::max<CGFloat>(
            kTextOriginX, std::min(self.rectangularAnchorPoint.x,
                                  self.rectangularCurrentPoint.x));
        const CGFloat right = std::max<CGFloat>(
            kTextOriginX, std::max(self.rectangularAnchorPoint.x,
                                  self.rectangularCurrentPoint.x));
        if (right - left > 0.5) {
          [SakuraTypeColor(typeIdentifier, @"selectionBackground",
                           self.effectiveAppearance,
                           SakuraSelectionBackground(self.effectiveAppearance)) setFill];
          NSRectFill(NSMakeRect(left, top, right - left, lineHeight));
        }
      }
    } else {
      for (NSValue* value in selectionRanges) {
        const NSRange selectedOnLine = NSIntersectionRange(
            value.rangeValue, lineRange);
        if (selectedOnLine.length == 0) continue;
        const CGFloat left = offsetForIndex(line,
            selectedOnLine.location - lineRange.location);
        const CGFloat right = offsetForIndex(line,
            NSMaxRange(selectedOnLine) - lineRange.location);
        [SakuraTypeColor(typeIdentifier, @"selectionBackground",
                         self.effectiveAppearance,
                         SakuraSelectionBackground(self.effectiveAppearance)) setFill];
        NSRectFill(NSMakeRect(kTextOriginX + left, top,
                              std::max<CGFloat>(1.0, right - left), lineHeight));
      }
    }

    if (marked.location != NSNotFound) {
      const NSRange markedOnLine = NSIntersectionRange(marked, lineRange);
      if (markedOnLine.length != 0) {
        const CGFloat left = offsetForIndex(line,
            markedOnLine.location - lineRange.location);
        const CGFloat right = offsetForIndex(line,
            NSMaxRange(markedOnLine) - lineRange.location);
        [[[NSColor keyboardFocusIndicatorColor] colorWithAlphaComponent:0.10]
            setFill];
        NSRectFill(NSMakeRect(kTextOriginX + left, top,
                              std::max<CGFloat>(1.0, right - left), lineHeight));
      }
    }

    CGContextSetTextPosition(context, kTextOriginX, top + baselineOffset);
    CTLineDraw(line, context);

    if (![self hasMarkedText]) {
      NSString* visibleText = [display substringWithRange:lineRange];
      for (NSUInteger localIndex = 0; localIndex < visibleText.length;
           ++localIndex) {
        const unichar character = [visibleText characterAtIndex:localIndex];
        NSString* role = nil;
        NSString* marker = nil;
        BOOL defaultDisplay = YES;
        if (character == '\t') {
          role = @"tabMarker";
          marker = @"›";
        } else if (character == ' ') {
          role = @"halfSpaceMarker";
          marker = @"·";
          defaultDisplay = NO;
        } else if (character == 0x3000) {
          role = @"fullSpaceMarker";
          marker = @"□";
        }
        if (role == nil || !SakuraTypeStyleBool(
                typeIdentifier, role, @"display", defaultDisplay)) {
          continue;
        }
        const CGFloat left = offsetForIndex(line, localIndex);
        const CGFloat right = offsetForIndex(line, localIndex + 1);
        drawMarker(marker, role, kTextOriginX + left,
                   std::max<CGFloat>(1.0, right - left), top);
      }

      const NSUInteger lineEnd = NSMaxRange(lineRange);
      NSString* endRole = nil;
      NSString* endMarker = nil;
      if (lineEnd < display.length) {
        const unichar ending = [display characterAtIndex:lineEnd];
        if (ending == '\r') {
          endRole = @"eolMarker";
          endMarker = lineEnd + 1 < display.length &&
                      [display characterAtIndex:lineEnd + 1] == '\n'
              ? @"↵" : @"←";
        } else if (ending == '\n') {
          endRole = @"eolMarker";
          endMarker = @"↓";
        } else {
          endRole = @"wrapMarker";
          endMarker = @"↩";
        }
      } else {
        endRole = @"eofMarker";
        endMarker = @"[EOF]";
      }
      if (SakuraTypeStyleBool(typeIdentifier, endRole, @"display", YES)) {
        const CGFloat endX = offsetForIndex(line, lineRange.length);
        drawMarker(endMarker, endRole, kTextOriginX + endX, 1.0, top);
      }
    }
    CFRelease(line);
  }

  if (self.window.firstResponder == self && selected.length == 0 &&
      ![self hasRectangularSelection]) {
    const NSRect caret = [self localRectForDisplayIndex:selected.location];
    [SakuraTypeColor(typeIdentifier, @"text", self.effectiveAppearance,
                     SakuraEditorText(self.effectiveAppearance)) setFill];
    NSRectFill(NSMakeRect(caret.origin.x, caret.origin.y, 1.0, caret.size.height));
  }
  CGContextRestoreGState(context);
  if (self.window.firstResponder == self &&
      [self.window.windowController isKindOfClass:[SakuraWindowController class]]) {
    [(SakuraWindowController*)self.window.windowController updateStatusForEditor:self];
  }
}

- (NSRect)localRectForDisplayIndex:(NSUInteger)index {
  NSString* display = [self displayString];
  index = std::min(index, display.length);
  const auto& ranges = [self displayLineRanges];
  const NSUInteger lineIndex = lineIndexContainingCharacter(ranges, index, &_lineLookupSteps);
  const NSRange lineRange = ranges[lineIndex];
  const NSUInteger localIndex = index <= NSMaxRange(lineRange)
                                    ? index - lineRange.location
                                    : lineRange.length;
  NSAttributedString* text = [[NSAttributedString alloc]
      initWithString:[display substringWithRange:lineRange]
          attributes:[self baseTextAttributes]];
  CTLineRef line = CTLineCreateWithAttributedString(
      (__bridge CFAttributedStringRef)text);
  const CGFloat x = offsetForIndex(line, localIndex);
  CFRelease(line);
  return NSMakeRect(kTextOriginX + x,
                    kVerticalInset + lineIndex * [self editorLineHeight], 1.0,
                    [self editorLineHeight]);
}

- (NSUInteger)displayIndexForLocalPoint:(NSPoint)point {
  NSString* display = [self displayString];
  const auto& ranges = [self displayLineRanges];
  const CGFloat relativeY = std::max<CGFloat>(0.0, point.y - kVerticalInset);
  const NSUInteger lineIndex = std::min<NSUInteger>(
      static_cast<NSUInteger>(relativeY / [self editorLineHeight]),
      ranges.size() - 1);
  const NSRange lineRange = ranges[lineIndex];
  NSAttributedString* text = [[NSAttributedString alloc]
      initWithString:[display substringWithRange:lineRange]
          attributes:[self baseTextAttributes]];
  CTLineRef line = CTLineCreateWithAttributedString(
      (__bridge CFAttributedStringRef)text);
  const CGPoint linePoint = CGPointMake(point.x - kTextOriginX, 0.0);
  CFIndex stringIndex = CTLineGetStringIndexForPosition(line, linePoint);
  if (stringIndex == kCFNotFound) {
    stringIndex = point.x <= kTextOriginX
                      ? 0
                      : static_cast<CFIndex>(lineRange.length);
  }
  NSUInteger index = lineRange.location + std::min<NSUInteger>(
      static_cast<NSUInteger>(stringIndex), lineRange.length);
  if (index < display.length) {
    const NSRange cluster = [display rangeOfComposedCharacterSequenceAtIndex:index];
    if (cluster.location < index && NSMaxRange(cluster) <= NSMaxRange(lineRange) &&
        cluster.location >= lineRange.location) {
      const CGFloat left = offsetForIndex(line, cluster.location - lineRange.location);
      const CGFloat right = offsetForIndex(line, NSMaxRange(cluster) - lineRange.location);
      index = linePoint.x < (left + right) * 0.5
          ? cluster.location : NSMaxRange(cluster);
    }
  }
  CFRelease(line);
  return std::min(display.length, index);
}

- (CGFloat)rectangularSpaceAdvance {
  NSAttributedString* text = [[NSAttributedString alloc]
      initWithString:@" " attributes:[self baseTextAttributes]];
  CTLineRef line = CTLineCreateWithAttributedString(
      (__bridge CFAttributedStringRef)text);
  const CGFloat width = static_cast<CGFloat>(
      CTLineGetTypographicBounds(line, nullptr, nullptr, nullptr));
  CFRelease(line);
  return std::max<CGFloat>(1.0, width);
}

- (NSRange)rectangularDisplayLineSpan {
  const auto& lines = [self displayLineRanges];
  if (!self.rectangularSelectionActive || lines.empty()) {
    return NSMakeRange(NSNotFound, 0);
  }
  const CGFloat lineHeight = [self editorLineHeight];
  const auto lineForY = [&](CGFloat y) {
    const CGFloat relative = std::max<CGFloat>(0.0, y - kVerticalInset);
    return std::min<NSUInteger>(
        static_cast<NSUInteger>(relative / lineHeight), lines.size() - 1);
  };
  const NSUInteger anchorLine = lineForY(self.rectangularAnchorPoint.y);
  const NSUInteger currentLine = lineForY(self.rectangularCurrentPoint.y);
  const NSUInteger first = std::min(anchorLine, currentLine);
  return NSMakeRange(first, std::max(anchorLine, currentLine) - first + 1);
}

- (NSArray<NSDictionary*>*)rectangularSelections {
  if (!self.rectangularSelectionActive) return @[];
  const auto& lines = [self displayLineRanges];
  if (lines.empty()) return @[];
  const NSRange lineSpan = [self rectangularDisplayLineSpan];
  if (lineSpan.location == NSNotFound) return @[];
  const CGFloat lineHeight = [self editorLineHeight];
  const CGFloat left = std::max<CGFloat>(
      kTextOriginX, std::min(self.rectangularAnchorPoint.x,
                            self.rectangularCurrentPoint.x));
  const CGFloat right = std::max<CGFloat>(
      kTextOriginX, std::max(self.rectangularAnchorPoint.x,
                            self.rectangularCurrentPoint.x));
  const CGFloat relativeLeft = left - kTextOriginX;
  const CGFloat relativeRight = right - kTextOriginX;
  const CGFloat spaceAdvance = [self rectangularSpaceAdvance];
  NSString* display = [self displayString];
  NSMutableArray<NSDictionary*>* selections = [NSMutableArray array];
  for (NSUInteger line = lineSpan.location; line < NSMaxRange(lineSpan); ++line) {
    const CGFloat y = kVerticalInset +
        (static_cast<CGFloat>(line) + 0.5) * lineHeight;
    const NSUInteger first = [self displayIndexForLocalPoint:NSMakePoint(left, y)];
    const NSUInteger last = [self displayIndexForLocalPoint:NSMakePoint(right, y)];
    const NSRange displayRange = NSMakeRange(
        std::min(first, last), std::max(first, last) - std::min(first, last));
    NSRange committedRange = [self committedRangeForDisplayRange:displayRange];
    committedRange = [self rangeByExpandingToEditBoundaries:committedRange];

    const NSRange lineRange = lines[line];
    NSAttributedString* lineText = [[NSAttributedString alloc]
        initWithString:[display substringWithRange:lineRange]
            attributes:[self baseTextAttributes]];
    CTLineRef ctLine = CTLineCreateWithAttributedString(
        (__bridge CFAttributedStringRef)lineText);
    const CGFloat lineEnd = offsetForIndex(ctLine, lineRange.length);
    CFRelease(ctLine);
    const NSUInteger leadingVirtualSpaces = lineEnd < relativeLeft
        ? static_cast<NSUInteger>(
              std::ceil((relativeLeft - lineEnd) / spaceAdvance))
        : 0;
    const CGFloat trailingStart = std::max(relativeLeft, lineEnd);
    const NSUInteger trailingVirtualSpaces = relativeRight > trailingStart
        ? static_cast<NSUInteger>(
              std::ceil((relativeRight - trailingStart) / spaceAdvance))
        : 0;
    [selections addObject:@{
      @"displayRange" : [NSValue valueWithRange:displayRange],
      @"committedRange" : [NSValue valueWithRange:committedRange],
      @"leadingVirtualSpaces" : @(leadingVirtualSpaces),
      @"trailingVirtualSpaces" : @(trailingVirtualSpaces),
      @"lineIndex" : @(line),
    }];
  }
  return selections;
}

- (NSArray<NSValue*>*)rectangularDisplayRanges {
  NSMutableArray<NSValue*>* ranges = [NSMutableArray array];
  for (NSDictionary* selection in [self rectangularSelections]) {
    [ranges addObject:selection[@"displayRange"]];
  }
  return ranges;
}

- (NSArray<NSValue*>*)rectangularCommittedRanges {
  NSMutableArray<NSValue*>* ranges = [NSMutableArray array];
  for (NSDictionary* selection in [self rectangularSelections]) {
    [ranges addObject:selection[@"committedRange"]];
  }
  return ranges;
}

- (NSUInteger)selectedCharacterCount {
  if (!self.rectangularSelectionActive) return self.committedSelection.length;
  NSUInteger count = 0;
  for (NSDictionary* selection in [self rectangularSelections]) {
    count += [selection[@"committedRange"] rangeValue].length;
    count += [selection[@"trailingVirtualSpaces"] unsignedIntegerValue];
  }
  return count;
}

- (BOOL)hasRectangularSelection {
  return self.rectangularSelectionActive &&
      std::abs(self.rectangularAnchorPoint.x -
               self.rectangularCurrentPoint.x) > 0.5;
}

- (void)updateRectangularSelection {
  NSArray<NSValue*>* ranges = [self rectangularCommittedRanges];
  if (ranges.count == 0) return;
  const NSRange first = ranges.firstObject.rangeValue;
  const NSRange last = ranges.lastObject.rangeValue;
  self.committedSelection = NSMakeRange(
      first.location, NSMaxRange(last) - first.location);
  [self updateDocumentViewSize];
  [self setNeedsDisplay:YES];
  const NSRange lineSpan = [self rectangularDisplayLineSpan];
  const CGFloat bottom = kVerticalInset +
      static_cast<CGFloat>(NSMaxRange(lineSpan)) * [self editorLineHeight];
  [self scrollRectToVisible:NSMakeRect(
      self.rectangularCurrentPoint.x, bottom - [self editorLineHeight],
      1.0, [self editorLineHeight])];
}

- (void)clearRectangularSelection {
  self.rectangularSelectionActive = NO;
}

- (void)toggleRectangularSelection:(id)sender {
  (void)sender;
  if (self.rectangularSelectionActive) {
    [self clearRectangularSelection];
    self.committedSelection = NSMakeRange(self.committedSelection.location, 0);
  } else {
    const NSRect caret = [self localRectForDisplayIndex:
        self.committedSelection.location];
    self.rectangularAnchorPoint = NSMakePoint(
        caret.origin.x, NSMidY(caret));
    self.rectangularCurrentPoint = self.rectangularAnchorPoint;
    self.rectangularSelectionActive = YES;
    [self updateRectangularSelection];
  }
  [self setNeedsDisplay:YES];
}

- (void)scrollSelectionToVisible {
  const NSRange displaySelection = [self displaySelection];
  const NSUInteger caret = ![self hasMarkedText] &&
          self.navigationAnchor != NSNotFound
      ? self.navigationCaret : NSMaxRange(displaySelection);
  [self scrollRectToVisible:[self localRectForDisplayIndex:caret]];
}

- (void)toggleSplitEditor:(id)sender {
  if ([self.window.windowController isKindOfClass:[SakuraWindowController class]]) {
    [(SakuraWindowController*)self.window.windowController toggleSplitEditor:sender];
  }
}

- (void)toggleToolbar:(id)sender {
  if ([self.window.windowController isKindOfClass:[SakuraWindowController class]]) {
    [(SakuraWindowController*)self.window.windowController toggleToolbar:sender];
  }
}

- (void)toggleStatusBar:(id)sender {
  if ([self.window.windowController isKindOfClass:[SakuraWindowController class]]) {
    [(SakuraWindowController*)self.window.windowController toggleStatusBar:sender];
  }
}

- (void)showOutlinePanel:(id)sender {
  if ([self.window.windowController isKindOfClass:[SakuraWindowController class]]) {
    [(SakuraWindowController*)self.window.windowController showOutlinePanel:sender];
  }
}

- (void)showCommandList:(id)sender {
  if ([self.window.windowController isKindOfClass:[SakuraWindowController class]]) {
    [(SakuraWindowController*)self.window.windowController showCommandList:sender];
  }
}

- (void)showTypeSettingsList:(id)sender {
  if ([self.window.windowController isKindOfClass:[SakuraWindowController class]]) {
    [(SakuraWindowController*)self.window.windowController
        showTypeSettingsList:sender];
  }
}

- (void)showTypeSettings:(id)sender {
  if ([self.window.windowController isKindOfClass:[SakuraWindowController class]]) {
    [(SakuraWindowController*)self.window.windowController showTypeSettings:sender];
  }
}

- (void)showCommonSettings:(id)sender {
  if ([self.window.windowController isKindOfClass:[SakuraWindowController class]]) {
    [(SakuraWindowController*)self.window.windowController showCommonSettings:sender];
  }
}

- (void)showEncodingPanel:(id)sender {
  if ([self.window.windowController isKindOfClass:[SakuraWindowController class]]) {
    [(SakuraWindowController*)self.window.windowController showEncodingPanel:sender];
  }
}

- (void)showGrepPanel:(id)sender {
  if ([self.window.windowController isKindOfClass:[SakuraWindowController class]]) {
    [(SakuraWindowController*)self.window.windowController showGrepPanel:sender];
  }
}

- (void)showGrepReplacePanel:(id)sender {
  if ([self.window.windowController isKindOfClass:[SakuraWindowController class]]) {
    [(SakuraWindowController*)self.window.windowController
        showGrepReplacePanel:sender];
  }
}

- (void)goBackInNavigationHistory:(id)sender {
  [(SakuraWindowController*)self.window.windowController
      goBackInNavigationHistory:sender];
}

- (void)goForwardInNavigationHistory:(id)sender {
  [(SakuraWindowController*)self.window.windowController
      goForwardInNavigationHistory:sender];
}

- (void)registerCurrentNavigationPosition:(id)sender {
  [(SakuraWindowController*)self.window.windowController
      registerCurrentNavigationPosition:sender];
}

- (NSUInteger)currentDocumentOffset {
  return self.committedSelection.location;
}

- (void)recordNavigationToOffset:(NSUInteger)offset {
  if ([self.window.windowController isKindOfClass:[SakuraWindowController class]]) {
    [(SakuraWindowController*)self.window.windowController
        noteNavigationFromOffset:self.committedSelection.location
                        toOffset:offset];
  }
}

- (void)setInputLineEndingCRLF:(id)sender {
  (void)sender;
  [self.sakuraDocument setPreferredLineEndingString:@"CRLF"];
}

- (void)setInputLineEndingLF:(id)sender {
  (void)sender;
  [self.sakuraDocument setPreferredLineEndingString:@"LF"];
}

- (void)setInputLineEndingCR:(id)sender {
  (void)sender;
  [self.sakuraDocument setPreferredLineEndingString:@"CR"];
}

- (void)jumpToDocumentOffset:(NSUInteger)offset {
  if ([self hasMarkedText]) {
    [self unmarkText];
  }
  [self clearRectangularSelection];
  const NSUInteger length = [self committedString].length;
  const NSUInteger target =
      [self previousEditBoundaryAtOrBefore:std::min(offset, length)];
  [self recordNavigationToOffset:target];
  self.committedSelection = NSMakeRange(target, 0);
  [self.window makeFirstResponder:self];
  [self setNeedsDisplay:YES];
  [self scrollSelectionToVisible];
}

- (void)findTextFromToolbar:(NSString*)text {
  if (text.length == 0) {
    NSBeep();
    return;
  }
  if ([self hasMarkedText]) {
    [self unmarkText];
  }
  try {
    const auto needle = sakura::platform::mac::sakuraStringFromString(text);
    const auto match = self.sakuraDocument.documentSession.findNext(
        needle, NSMaxRange(self.committedSelection),
        {.caseSensitive = true, .wholeWord = false, .wrap = true});
    if (!match.has_value()) {
      NSBeep();
      return;
    }
    [self clearRectangularSelection];
    [self recordNavigationToOffset:
        static_cast<NSUInteger>(match->range.location)];
    self.committedSelection = NSMakeRange(
        static_cast<NSUInteger>(match->range.location),
        static_cast<NSUInteger>(match->range.length));
    [self setNeedsDisplay:YES];
    [self scrollSelectionToVisible];
  } catch (const std::exception&) {
    NSBeep();
  }
}

#pragma mark - Find and replace

- (sakura::core::SearchOptions)searchOptions {
  return {.caseSensitive = self.caseSensitiveButton.state == NSControlStateValueOn,
          .wholeWord = self.wholeWordButton.state == NSControlStateValueOn,
          .wrap = true,
          .regularExpression = self.regularExpressionButton.state ==
                               NSControlStateValueOn};
}

- (NSUInteger)searchFlags {
  const auto options = [self searchOptions];
  return (options.caseSensitive ? 1 : 0) | (options.wholeWord ? 2 : 0) |
         (options.regularExpression ? 4 : 0);
}

- (void)rememberSearchSelection {
  self.hasLastSearchMatch = YES;
  self.lastSearchMatchRange = self.committedSelection;
  self.lastSearchRevision = self.sakuraDocument.documentSession.buffer().revision();
  self.lastSearchPattern = self.findField.stringValue;
  self.lastSearchFlags = [self searchFlags];
}

- (void)setFindStatus:(NSString*)status {
  self.findStatusLabel.stringValue = status;
}

- (const std::vector<sakura::core::SyntaxToken>&)activeSyntaxTokens {
  SakuraDocument* document = self.sakuraDocument;
  NSString* extension = document.fileURL.pathExtension.lowercaseString;
  if (extension == nil) extension = @"";
  NSArray* key = @[@(document != nil ? document.documentSession.buffer().revision() : 0),
                   extension, @([self hasMarkedText])];
  if ([_syntaxKey isEqual:key]) return _cachedSyntaxTokens;
  _syntaxKey = key;
  ++_syntaxBuilds;
  [_styledLines removeAllObjects];
  _cachedSyntaxTokens.clear();
  if (document != nil && ![self hasMarkedText] &&
      [@[ @"c", @"cc", @"cpp", @"cxx", @"h", @"hh", @"hpp", @"hxx",
           @"m", @"mm", @"swift" ] containsObject:extension]) {
    _cachedSyntaxTokens = sakura::core::SyntaxHighlighter{}.highlightCLike(
        document.documentSession.buffer());
  }
  return _cachedSyntaxTokens;
}

- (const std::vector<NSRange>&)activeSearchRanges {
  SakuraDocument* document = self.sakuraDocument;
  NSString* pattern = self.findField.stringValue;
  if (pattern == nil) pattern = @"";
  const BOOL enabled = document != nil && !self.searchMarksHidden &&
      self.findPanel.isVisible && pattern.length != 0 && ![self hasMarkedText];
  NSArray* key = @[@(document != nil ? document.documentSession.buffer().revision() : 0),
                   pattern, @([self searchFlags]), @(enabled)];
  if ([_searchKey isEqual:key]) return _cachedSearchRanges;
  _searchKey = key;
  ++_searchBuilds;
  [_styledLines removeAllObjects];
  _cachedSearchRanges.clear();
  if (!enabled) {
    return _cachedSearchRanges;
  }
  try {
    const auto needle = sakura::platform::mac::sakuraStringFromString(
        self.findField.stringValue);
    const auto matches = self.sakuraDocument.documentSession.findAll(
        needle, [self searchOptions]);
    _cachedSearchRanges.reserve(matches.size());
    for (const auto& match : matches) {
      _cachedSearchRanges.push_back(NSMakeRange(static_cast<NSUInteger>(match.range.location),
                                   static_cast<NSUInteger>(match.range.length)));
    }
  } catch (const std::exception&) {
    // Rendering a transient, malformed search must not disturb editing.
  }
  return _cachedSearchRanges;
}

- (NSDictionary<NSString*, NSNumber*>*)renderingStatistics {
  return @{@"textBuilds":@(_textBuilds), @"layoutBuilds":@(_layoutBuilds),
           @"syntaxBuilds":@(_syntaxBuilds), @"searchBuilds":@(_searchBuilds),
           @"styledBuilds":@(_styledBuilds), @"drawnLines":@(_drawnLines),
           @"lineLookupSteps":@(_lineLookupSteps)};
}

- (void)refreshSearchHighlights:(id)sender {
  (void)sender;
  self.searchMarksHidden = NO;
  [self setNeedsDisplay:YES];
}

- (void)controlTextDidChange:(NSNotification*)notification {
  if (notification.object == self.findField) {
    self.searchMarksHidden = NO;
    [self setNeedsDisplay:YES];
  }
}

- (void)showFindPanel:(id)sender {
  (void)sender;
  if (self.findPanel == nil) {
    NSPanel* panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 500, 178)
                  styleMask:NSWindowStyleMaskTitled |
                            NSWindowStyleMaskClosable |
                            NSWindowStyleMaskUtilityWindow
                    backing:NSBackingStoreBuffered
                      defer:NO];
    panel.title = @"検索・置換";
    panel.hidesOnDeactivate = NO;
    panel.floatingPanel = YES;

    NSView* content = panel.contentView;
    const CGFloat labelX = 16.0;
    const CGFloat fieldX = 94.0;
    const CGFloat fieldWidth = 384.0;
    NSTextField* findLabel = [NSTextField labelWithString:@"検索文字列:"];
    findLabel.frame = NSMakeRect(labelX, 130, 70, 22);
    [content addSubview:findLabel];
    NSSearchField* findField = [[NSSearchField alloc]
        initWithFrame:NSMakeRect(fieldX, 126, fieldWidth, 26)];
    findField.sendsSearchStringImmediately = NO;
    findField.delegate = self;
    findField.target = self;
    findField.action = @selector(findNext:);
    [content addSubview:findField];

    NSTextField* replaceLabel = [NSTextField labelWithString:@"置換文字列:"];
    replaceLabel.frame = NSMakeRect(labelX, 94, 70, 22);
    [content addSubview:replaceLabel];
    NSTextField* replaceField = [[NSTextField alloc]
        initWithFrame:NSMakeRect(fieldX, 90, fieldWidth, 26)];
    [content addSubview:replaceField];

    NSButton* caseSensitive = [NSButton checkboxWithTitle:@"大文字と小文字を区別"
                                                    target:self
                                                    action:@selector(refreshSearchHighlights:)];
    caseSensitive.frame = NSMakeRect(fieldX, 61, 125, 22);
    caseSensitive.state = NSControlStateValueOn;
    [content addSubview:caseSensitive];
    NSButton* wholeWord = [NSButton checkboxWithTitle:@"単語単位"
                                                target:self
                                                action:@selector(refreshSearchHighlights:)];
    wholeWord.frame = NSMakeRect(225, 61, 105, 22);
    [content addSubview:wholeWord];
    NSButton* regularExpression = [NSButton checkboxWithTitle:@"正規表現"
                                                        target:self
                                                        action:@selector(refreshSearchHighlights:)];
    regularExpression.frame = NSMakeRect(338, 61, 145, 22);
    [content addSubview:regularExpression];

    NSButton* previousButton = [NSButton buttonWithTitle:@"上検索"
                                                    target:self
                                                    action:@selector(findPrevious:)];
    previousButton.frame = NSMakeRect(16, 25, 80, 28);
    [content addSubview:previousButton];
    NSButton* findButton = [NSButton buttonWithTitle:@"下検索"
                                                target:self
                                                action:@selector(findNext:)];
    findButton.frame = NSMakeRect(102, 25, 80, 28);
    findButton.keyEquivalent = @"\r";
    [content addSubview:findButton];
    NSButton* replaceButton = [NSButton buttonWithTitle:@"置換"
                                                   target:self
                                                   action:@selector(replaceSearchSelection:)];
    replaceButton.frame = NSMakeRect(188, 25, 80, 28);
    [content addSubview:replaceButton];
    NSButton* replaceAllButton = [NSButton buttonWithTitle:@"すべて置換"
                                                      target:self
                                                      action:@selector(replaceAll:)];
    replaceAllButton.frame = NSMakeRect(274, 25, 100, 28);
    [content addSubview:replaceAllButton];
    NSTextField* status = [NSTextField labelWithString:@""];
    status.frame = NSMakeRect(16, 5, 468, 16);
    status.textColor = NSColor.secondaryLabelColor;
    [content addSubview:status];

    self.findPanel = panel;
    self.findField = findField;
    self.replaceField = replaceField;
    self.caseSensitiveButton = caseSensitive;
    self.wholeWordButton = wholeWord;
    self.regularExpressionButton = regularExpression;
    self.findStatusLabel = status;
  }
  [self.findPanel makeKeyAndOrderFront:self];
  [self.findPanel makeFirstResponder:self.findField];
}

- (BOOL)selectNextSearchMatchFrom:(NSUInteger)start {
  self.hasLastSearchMatch = NO;
  if (self.findField.stringValue.length == 0) {
    [self setFindStatus:@"検索文字列を入力してください。"];
    NSBeep();
    return NO;
  }
  try {
    const auto needle = sakura::platform::mac::sakuraStringFromString(
        self.findField.stringValue);
    if (!sakura::core::SearchEngine::isValidPattern(needle, [self searchOptions])) {
      [self setFindStatus:@"正規表現が正しくありません。"];
      NSBeep();
      return NO;
    }
    const auto match = self.sakuraDocument.documentSession.findNext(
        needle, static_cast<sakura::core::TextOffset>(start),
        [self searchOptions]);
    if (!match.has_value()) {
      [self setFindStatus:@"見つかりませんでした。"];
      NSBeep();
      return NO;
    }
    [self clearRectangularSelection];
    [self recordNavigationToOffset:
        static_cast<NSUInteger>(match->range.location)];
    self.committedSelection = NSMakeRange(
        static_cast<NSUInteger>(match->range.location),
        static_cast<NSUInteger>(match->range.length));
    [self rememberSearchSelection];
    self.searchMarksHidden = NO;
    [self setFindStatus:@"検索文字列を選択しました。"];
    [self setNeedsDisplay:YES];
    [self scrollSelectionToVisible];
    return YES;
  } catch (const std::exception&) {
    [self setFindStatus:@"検索文字列が正しくありません。"];
    NSBeep();
    return NO;
  }
}

- (void)findNext:(id)sender {
  (void)sender;
  if (self.findPanel == nil) {
    [self showFindPanel:self];
    return;
  }
  if ([self hasMarkedText]) {
    [self unmarkText];
  }
  NSUInteger start = NSMaxRange(self.committedSelection);
  if (self.hasLastSearchMatch && self.committedSelection.length == 0 &&
      NSEqualRanges(self.committedSelection, self.lastSearchMatchRange) &&
      self.lastSearchRevision == self.sakuraDocument.documentSession.buffer().revision() &&
      [self.lastSearchPattern isEqualToString:self.findField.stringValue] &&
      self.lastSearchFlags == [self searchFlags]) {
    const NSUInteger length = [self committedString].length;
    start = start < length ? [self nextEditBoundaryAtOrAfter:start + 1] : 0;
  }
  [self selectNextSearchMatchFrom:start];
}

- (void)findPrevious:(id)sender {
  (void)sender;
  if (self.findPanel == nil) {
    [self showFindPanel:self];
    return;
  }
  if (self.findField.stringValue.length == 0) {
    [self setFindStatus:@"検索文字列を入力してください。"];
    NSBeep();
    return;
  }
  if ([self hasMarkedText]) {
    [self unmarkText];
  }
  try {
    const auto needle = sakura::platform::mac::sakuraStringFromString(
        self.findField.stringValue);
    const auto matches = self.sakuraDocument.documentSession.findAll(
        needle, [self searchOptions]);
    if (matches.empty()) {
      [self setFindStatus:@"見つかりませんでした。"];
      NSBeep();
      return;
    }
    const NSUInteger cursor = self.committedSelection.location;
    const sakura::core::SearchMatch* selected = &matches.back();
    for (auto iterator = matches.rbegin(); iterator != matches.rend(); ++iterator) {
      if (iterator->range.location < cursor) {
        selected = &*iterator;
        break;
      }
    }
    [self clearRectangularSelection];
    [self recordNavigationToOffset:
        static_cast<NSUInteger>(selected->range.location)];
    self.committedSelection = NSMakeRange(
        static_cast<NSUInteger>(selected->range.location),
        static_cast<NSUInteger>(selected->range.length));
    [self rememberSearchSelection];
    self.searchMarksHidden = NO;
    [self setFindStatus:@"検索文字列を選択しました。"];
    [self setNeedsDisplay:YES];
    [self scrollSelectionToVisible];
  } catch (const std::exception&) {
    [self setFindStatus:@"検索文字列が正しくありません。"];
    NSBeep();
  }
}

- (void)clearSearchMarks:(id)sender {
  (void)sender;
  self.searchMarksHidden = YES;
  [self setFindStatus:@"検索マークを解除しました。"];
  [self setNeedsDisplay:YES];
}

- (void)replaceSearchSelection:(id)sender {
  (void)sender;
  if (self.findPanel == nil) {
    [self showFindPanel:self];
    return;
  }
  if ([self hasMarkedText]) {
    [self unmarkText];
  }
  try {
    const auto needle = sakura::platform::mac::sakuraStringFromString(
        self.findField.stringValue);
    auto options = [self searchOptions];
    options.wrap = false;
    if (!sakura::core::SearchEngine::isValidPattern(needle, options)) {
      [self setFindStatus:@"正規表現が正しくありません。"];
      NSBeep();
      return;
    }
    const auto current = self.sakuraDocument.documentSession.findNext(
        needle, self.committedSelection.location, options);
    if (!current.has_value() ||
        current->range.location != self.committedSelection.location ||
        current->range.length != self.committedSelection.length) {
      [self selectNextSearchMatchFrom:self.committedSelection.location];
      return;
    }
    const auto replacement = sakura::platform::mac::sakuraStringFromString(
        self.replaceField.stringValue);
    const auto expanded = self.sakuraDocument.documentSession.replacementText(
        *current, replacement, options);
    const BOOL emptyMatch = self.committedSelection.length == 0;
    [self replaceCommittedRange:self.committedSelection
                     withString:sakura::platform::mac::stringFromSakuraString(expanded)];
    [self setFindStatus:@"置換しました。"];
    NSUInteger next = NSMaxRange(self.committedSelection);
    if (emptyMatch) {
      const NSUInteger length = [self committedString].length;
      next = next < length ? [self nextEditBoundaryAtOrAfter:next + 1] : 0;
    }
    [self selectNextSearchMatchFrom:next];
  } catch (const std::exception&) {
    [self setFindStatus:@"置換文字列が正しくありません。"];
    NSBeep();
  }
}

- (void)replaceAll:(id)sender {
  (void)sender;
  if (self.findPanel == nil) {
    [self showFindPanel:self];
    return;
  }
  if (self.findField.stringValue.length == 0) {
    [self setFindStatus:@"検索文字列を入力してください。"];
    NSBeep();
    return;
  }
  if ([self hasMarkedText]) {
    [self unmarkText];
  }
  try {
    const auto needle = sakura::platform::mac::sakuraStringFromString(
        self.findField.stringValue);
    const auto replacement = sakura::platform::mac::sakuraStringFromString(
        self.replaceField.stringValue);
    const auto result = self.sakuraDocument.documentSession.replaceAll(
        needle, replacement, [self searchOptions]);
    if (!result.valid) {
      [self setFindStatus:@"正規表現または置換文字列が正しくありません。"];
      NSBeep();
      return;
    }
    if (result.replacements == 0) {
      [self setFindStatus:@"見つかりませんでした。"];
      NSBeep();
      return;
    }
    self.committedSelection = NSMakeRange(0, 0);
    [self.sakuraDocument noteEditorChange:NSChangeDone];
    [self.sakuraDocument refreshEditorViews];
    [self setFindStatus:[NSString stringWithFormat:@"%zu 件置換しました。",
                                                   result.replacements]];
  } catch (const std::exception&) {
    [self setFindStatus:@"置換できませんでした。"];
    NSBeep();
  }
}

- (void)mouseDown:(NSEvent*)event {
  [self.window makeFirstResponder:self];
  if ([self hasMarkedText]) {
    [self unmarkText];
  }
  const NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  const NSUInteger index = [self safeNavigationOffset:
      [self displayIndexForLocalPoint:point]];
  self.draggingWholeWords = NO;
  if ((event.modifierFlags & NSEventModifierFlagOption) != 0) {
    self.rectangularSelectionActive = YES;
    self.rectangularAnchorPoint = point;
    self.rectangularCurrentPoint = point;
    self.committedSelection = NSMakeRange(index, 0);
  } else if ((event.modifierFlags & NSEventModifierFlagShift) != 0) {
    [self clearRectangularSelection];
    const NSUInteger anchor = self.navigationAnchor != NSNotFound
        ? self.navigationAnchor : self.committedSelection.location;
    [self moveSelectionToOffset:index modifyingSelection:YES
         preservingHorizontalPosition:NO];
    self.dragAnchor = anchor;
  } else if (event.clickCount >= 2) {
    [self clearRectangularSelection];
    NSRange selection = [self wordRangeAtNavigationOffset:index];
    if (event.clickCount >= 3) {
      NSString* text = [self committedString];
      selection = [text lineRangeForRange:NSMakeRange(index, 0)];
    }
    self.committedSelection = selection;
    self.navigationAnchor = selection.location;
    self.navigationCaret = NSMaxRange(selection);
    self.dragAnchor = selection.location;
    self.dragInitialSelection = selection;
    self.draggingWholeWords = YES;
  } else {
    [self clearRectangularSelection];
    self.committedSelection = NSMakeRange(index, 0);
    self.dragAnchor = index;
  }
  self.draggingSelection = YES;
  [self setNeedsDisplay:YES];
}

- (void)mouseDragged:(NSEvent*)event {
  if (!self.draggingSelection) {
    return;
  }
  const NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  if (self.rectangularSelectionActive) {
    self.rectangularCurrentPoint = point;
    [self updateRectangularSelection];
    return;
  }
  NSUInteger index = [self safeNavigationOffset:
      [self displayIndexForLocalPoint:point]];
  if (self.draggingWholeWords) {
    const NSRange word = [self wordRangeAtNavigationOffset:index];
    if (index < self.dragInitialSelection.location) {
      self.dragAnchor = NSMaxRange(self.dragInitialSelection);
      index = word.location;
    } else {
      self.dragAnchor = self.dragInitialSelection.location;
      index = std::max(NSMaxRange(self.dragInitialSelection), NSMaxRange(word));
    }
  }
  self.navigationAnchor = self.dragAnchor;
  [self moveSelectionToOffset:index modifyingSelection:YES
       preservingHorizontalPosition:NO];
}

- (void)mouseUp:(NSEvent*)event {
  (void)event;
  self.draggingSelection = NO;
  self.draggingWholeWords = NO;
  if (self.rectangularSelectionActive && ![self hasRectangularSelection]) {
    const NSUInteger index = [self displayIndexForLocalPoint:
        self.rectangularCurrentPoint];
    [self clearRectangularSelection];
    self.committedSelection = NSMakeRange(index, 0);
    [self setNeedsDisplay:YES];
  }
}

- (void)keyDown:(NSEvent*)event {
  if (![[self inputContext] handleEvent:event]) {
    [super keyDown:event];
  }
}

#pragma mark - NSTextInputClient

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
  NSString* inserted = plainString(string);
  if (self.rectangularSelectionActive && ![self hasMarkedText] &&
      replacementRange.location == NSNotFound) {
    [self replaceRectangularSelectionWithStrings:@[ inserted ]];
    return;
  }
  NSRange range = replacementRange.location == NSNotFound
                      ? ([self hasMarkedText]
                             ? self.markedReplacementRangeStorage
                             : self.committedSelection)
                      : [self committedRangeForDisplayRange:replacementRange];
  [self clearMarkedState];
  [self replaceCommittedRange:range withString:inserted];
}

- (void)setMarkedText:(id)string
         selectedRange:(NSRange)selectedRange
       replacementRange:(NSRange)replacementRange {
  if (self.rectangularSelectionActive) {
    const NSUInteger index = [self displayIndexForLocalPoint:
        self.rectangularCurrentPoint];
    [self clearRectangularSelection];
    self.committedSelection = NSMakeRange(index, 0);
  }
  NSString* markedString = plainString(string);
  if (markedString.length == 0) {
    [self clearMarkedState];
    [self updateDocumentViewSize];
    [self setNeedsDisplay:YES];
    return;
  }

  NSRange replacement = self.committedSelection;
  if ([self hasMarkedText]) {
    replacement = self.markedReplacementRangeStorage;
  }
  if (replacementRange.location != NSNotFound) {
    replacement = [self committedRangeForDisplayRange:replacementRange];
  }

  NSDictionary* attributes = [string isKindOfClass:[NSAttributedString class]]
                                 ? nil
                                 : [self baseTextAttributes];
  self.markedTextStorage = [string isKindOfClass:[NSAttributedString class]]
                               ? [(NSAttributedString*)string copy]
                               : [[NSAttributedString alloc]
                                     initWithString:markedString
                                         attributes:attributes];
  self.markedReplacementRangeStorage = replacement;
  self.markedSelectionStorage = clampedRange(selectedRange, markedString.length);
  [self updateDocumentViewSize];
  [self setNeedsDisplay:YES];
  [self scrollSelectionToVisible];
}

- (void)unmarkText {
  if (![self hasMarkedText]) {
    return;
  }
  NSString* committedMarkedText = self.markedTextStorage.string;
  const NSRange replacement = self.markedReplacementRangeStorage;
  [self clearMarkedState];
  [self replaceCommittedRange:replacement withString:committedMarkedText];
}

- (BOOL)hasMarkedText {
  return self.markedTextStorage != nil;
}

- (NSRange)markedRange {
  if (![self hasMarkedText]) {
    return NSMakeRange(NSNotFound, 0);
  }
  return NSMakeRange(self.markedReplacementRangeStorage.location,
                     self.markedTextStorage.length);
}

- (NSRange)selectedRange {
  return [self displaySelection];
}

- (NSArray<NSAttributedStringKey>*)validAttributesForMarkedText {
  return @[ NSUnderlineStyleAttributeName, NSUnderlineColorAttributeName ];
}

- (NSAttributedString*)attributedSubstringForProposedRange:(NSRange)range
                                                actualRange:(NSRangePointer)actualRange {
  NSString* display = [self displayString];
  const NSRange actual = clampedRange(range, display.length);
  if (actualRange != nullptr) {
    *actualRange = actual;
  }
  return [[NSAttributedString alloc]
      initWithString:[display substringWithRange:actual]
          attributes:[self baseTextAttributes]];
}

- (NSRect)firstRectForCharacterRange:(NSRange)range
                           actualRange:(NSRangePointer)actualRange {
  NSString* display = [self displayString];
  NSRange actual = clampedRange(range, display.length);
  const auto& rows = [self displayLineRanges];
  NSUInteger rowIndex = lineIndexContainingCharacter(
      rows, actual.location, &_lineLookupSteps);
  // A nonempty character range at a soft-wrap boundary belongs downstream.
  // A zero-length caret query retains the editor's preceding-row affinity.
  if (actual.length != 0 && rowIndex + 1 < rows.size() &&
      rows[rowIndex + 1].location == actual.location) ++rowIndex;
  const NSRange row = rows[rowIndex];
  // A candidate window needs the rectangle of the first visual fragment,
  // not a range claiming to cover subsequent wrapped rows with a caret box.
  actual.length = actual.location <= NSMaxRange(row)
      ? std::min(actual.length, NSMaxRange(row) - actual.location) : 0;
  if (actualRange != nullptr) {
    *actualRange = actual;
  }
  NSAttributedString* rowText = [[NSAttributedString alloc]
      initWithString:[display substringWithRange:row]
          attributes:[self baseTextAttributes]];
  CTLineRef line = CTLineCreateWithAttributedString(
      (__bridge CFAttributedStringRef)rowText);
  const NSUInteger start = std::min(actual.location - row.location, row.length);
  const CGFloat left = offsetForIndex(line, start);
  const CGFloat right = offsetForIndex(line, start + actual.length);
  CFRelease(line);
  const CGFloat height = [self editorLineHeight];
  NSRect local = NSMakeRect(kTextOriginX + left,
      kVerticalInset + rowIndex * height, std::max<CGFloat>(1.0, right - left), height);
  NSRect windowRect = [self convertRect:local toView:nil];
  return self.window != nil ? [self.window convertRectToScreen:windowRect]
                            : NSZeroRect;
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point {
  if (self.window == nil) {
    return NSNotFound;
  }
  const NSPoint windowPoint = [self.window convertPointFromScreen:point];
  const NSPoint localPoint = [self convertPoint:windowPoint fromView:nil];
  return [self displayIndexForLocalPoint:localPoint];
}

- (NSInteger)conversationIdentifier {
  return reinterpret_cast<NSInteger>((__bridge void*)self);
}

- (NSWindowLevel)windowLevel {
  return self.window.level;
}

- (BOOL)drawsVerticallyForCharacterAtIndex:(NSUInteger)charIndex {
  (void)charIndex;
  return NO;
}

- (CGFloat)fractionOfDistanceThroughGlyphForPoint:(NSPoint)point {
  (void)point;
  return 0.0;
}

- (void)doCommandBySelector:(SEL)selector {
  if (![self tryToPerform:selector with:self]) {
    NSBeep();
  }
}

#pragma mark - Editing commands

- (void)insertNewline:(id)sender {
  (void)sender;
  [self insertText:[self.sakuraDocument newlineInsertionString]
  replacementRange:NSMakeRange(NSNotFound, 0)];
}

- (void)insertTab:(id)sender {
  (void)sender;
  [self insertText:@"\t" replacementRange:NSMakeRange(NSNotFound, 0)];
}

- (void)deleteBackward:(id)sender {
  (void)sender;
  if ([self hasMarkedText]) {
    [self clearMarkedState];
    [self setNeedsDisplay:YES];
    return;
  }
  if ([self hasRectangularSelection]) {
    [self replaceRectangularSelectionWithStrings:@[ @"" ]];
    return;
  }
  if (self.committedSelection.length != 0) {
    [self replaceCommittedRange:
              [self rangeByExpandingToEditBoundaries:self.committedSelection]
                      withString:@""];
    return;
  }
  if (self.committedSelection.location == 0) {
    return;
  }
  NSString* text = [self committedString];
  const NSRange previous = [self rangeByExpandingToEditBoundaries:
      [text rangeOfComposedCharacterSequenceAtIndex:
          self.committedSelection.location - 1]];
  [self replaceCommittedRange:previous withString:@""];
}

- (void)deleteForward:(id)sender {
  (void)sender;
  if ([self hasMarkedText]) {
    [self clearMarkedState];
    [self setNeedsDisplay:YES];
    return;
  }
  if ([self hasRectangularSelection]) {
    [self replaceRectangularSelectionWithStrings:@[ @"" ]];
    return;
  }
  if (self.committedSelection.length != 0) {
    [self replaceCommittedRange:
              [self rangeByExpandingToEditBoundaries:self.committedSelection]
                      withString:@""];
    return;
  }
  NSString* text = [self committedString];
  if (self.committedSelection.location >= text.length) {
    return;
  }
  const NSRange next = [self rangeByExpandingToEditBoundaries:
      [text rangeOfComposedCharacterSequenceAtIndex:
          self.committedSelection.location]];
  [self replaceCommittedRange:next withString:@""];
}

- (void)delete:(id)sender {
  [self deleteForward:sender];
}

- (void)copy:(id)sender {
  (void)sender;
  if ([self hasMarkedText]) {
    [self unmarkText];
  }
  if ([self hasRectangularSelection]) {
    NSMutableArray<NSString*>* rows = [NSMutableArray array];
    NSString* text = [self committedString];
    for (NSDictionary* selection in [self rectangularSelections]) {
      NSMutableString* row = [[text substringWithRange:
          [selection[@"committedRange"] rangeValue]] mutableCopy];
      const NSUInteger trailingSpaces =
          [selection[@"trailingVirtualSpaces"] unsignedIntegerValue];
      if (trailingSpaces != 0) {
        [row appendString:[@"" stringByPaddingToLength:trailingSpaces
                                           withString:@" "
                                      startingAtIndex:0]];
      }
      [rows addObject:row];
    }
    NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    [pasteboard writeObjects:@[ [rows componentsJoinedByString:@"\n"] ]];
    return;
  }
  if (self.committedSelection.length == 0) {
    return;
  }
  NSString* selected = [[self committedString]
      substringWithRange:self.committedSelection];
  NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
  [pasteboard clearContents];
  [pasteboard writeObjects:@[ selected ]];
}

- (void)cut:(id)sender {
  if ([self hasRectangularSelection]) {
    [self copy:sender];
    [self replaceRectangularSelectionWithStrings:@[ @"" ]];
    return;
  }
  [self copy:sender];
  if (self.committedSelection.length != 0) {
    [self replaceCommittedRange:
              [self rangeByExpandingToEditBoundaries:self.committedSelection]
                      withString:@""];
  }
}

- (void)paste:(id)sender {
  (void)sender;
  NSString* pasted = [[NSPasteboard generalPasteboard]
      stringForType:NSPasteboardTypeString];
  if (pasted != nil) {
    if (self.rectangularSelectionActive) {
      NSString* normalized = [pasted
          stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
      normalized = [normalized stringByReplacingOccurrencesOfString:@"\r"
                                                          withString:@"\n"];
      NSArray<NSString*>* lines = [normalized componentsSeparatedByString:@"\n"];
      NSArray<NSValue*>* ranges = [self rectangularCommittedRanges];
      if (lines.count > 1 && ranges.count != 0) {
        NSMutableArray<NSString*>* mapped = [NSMutableArray array];
        for (NSUInteger index = 0; index < ranges.count; ++index) {
          [mapped addObject:index < lines.count ? lines[index] : @""];
        }
        [self replaceRectangularSelectionWithStrings:mapped];
      } else {
        [self replaceRectangularSelectionWithStrings:@[ pasted ]];
      }
      return;
    }
    [self insertText:pasted replacementRange:NSMakeRange(NSNotFound, 0)];
  }
}

- (void)selectAll:(id)sender {
  (void)sender;
  if ([self hasMarkedText]) {
    [self unmarkText];
  }
  [self clearRectangularSelection];
  self.committedSelection = NSMakeRange(0, [self committedString].length);
  [self setNeedsDisplay:YES];
}

- (void)convertSelectionToUppercase:(id)sender {
  (void)sender;
  if ([self hasMarkedText]) {
    [self unmarkText];
  }
  if ([self hasRectangularSelection]) {
    NSMutableArray<NSString*>* rows = [NSMutableArray array];
    NSString* text = [self committedString];
    for (NSValue* value in [self rectangularCommittedRanges]) {
      [rows addObject:[text substringWithRange:value.rangeValue].uppercaseString];
    }
    [self replaceRectangularSelectionWithStrings:rows];
    return;
  }
  if (self.committedSelection.length == 0) {
    return;
  }
  NSString* selected = [[self committedString]
      substringWithRange:self.committedSelection];
  [self replaceCommittedRange:self.committedSelection
                   withString:selected.uppercaseString];
}

- (void)convertSelectionToLowercase:(id)sender {
  (void)sender;
  if ([self hasMarkedText]) {
    [self unmarkText];
  }
  if ([self hasRectangularSelection]) {
    NSMutableArray<NSString*>* rows = [NSMutableArray array];
    NSString* text = [self committedString];
    for (NSValue* value in [self rectangularCommittedRanges]) {
      [rows addObject:[text substringWithRange:value.rangeValue].lowercaseString];
    }
    [self replaceRectangularSelectionWithStrings:rows];
    return;
  }
  if (self.committedSelection.length == 0) {
    return;
  }
  NSString* selected = [[self committedString]
      substringWithRange:self.committedSelection];
  [self replaceCommittedRange:self.committedSelection
                   withString:selected.lowercaseString];
}

- (void)undo:(id)sender {
  (void)sender;
  [self clearMarkedState];
  [self clearRectangularSelection];
  if (self.sakuraDocument.documentSession.undo()) {
    self.committedSelection =
        clampedRange(self.committedSelection, [self committedString].length);
    [self.sakuraDocument noteEditorChange:NSChangeUndone];
    [self.sakuraDocument refreshEditorViews];
  }
}

- (void)redo:(id)sender {
  (void)sender;
  [self clearMarkedState];
  [self clearRectangularSelection];
  if (self.sakuraDocument.documentSession.redo()) {
    self.committedSelection =
        clampedRange(self.committedSelection, [self committedString].length);
    [self.sakuraDocument noteEditorChange:NSChangeRedone];
    [self.sakuraDocument refreshEditorViews];
  }
}

- (void)cancelOperation:(id)sender {
  (void)sender;
  [self clearMarkedState];
  [self clearRectangularSelection];
  [self updateDocumentViewSize];
  [self setNeedsDisplay:YES];
}

- (NSUInteger)safeNavigationOffset:(NSUInteger)offset {
  return [self safeNavigationOffset:offset inString:[self committedString]];
}

- (NSUInteger)safeNavigationOffset:(NSUInteger)offset inString:(NSString*)text {
  offset = [self previousEditBoundaryAtOrBefore:std::min(offset, text.length)];
  if (offset < text.length) {
    offset = [text rangeOfComposedCharacterSequenceAtIndex:offset].location;
  }
  return [self previousEditBoundaryAtOrBefore:offset];
}

- (NSUInteger)navigationCaretOffset {
  return self.navigationAnchor == NSNotFound
      ? NSMaxRange(self.committedSelection) : self.navigationCaret;
}

- (NSUInteger)previousNavigationOffset:(NSUInteger)offset {
  return [self previousNavigationOffset:offset inString:[self committedString]];
}

- (NSUInteger)previousNavigationOffset:(NSUInteger)offset inString:(NSString*)text {
  offset = [self safeNavigationOffset:offset inString:text];
  if (offset == 0) return 0;
  return [self safeNavigationOffset:
      [text rangeOfComposedCharacterSequenceAtIndex:offset - 1].location
                          inString:text];
}

- (NSUInteger)nextNavigationOffset:(NSUInteger)offset {
  return [self nextNavigationOffset:offset inString:[self committedString]];
}

- (NSUInteger)nextNavigationOffset:(NSUInteger)offset inString:(NSString*)text {
  offset = [self safeNavigationOffset:offset inString:text];
  if (offset >= text.length) return text.length;
  const NSUInteger next = NSMaxRange(
      [text rangeOfComposedCharacterSequenceAtIndex:offset]);
  return [self nextEditBoundaryAtOrAfter:next];
}

- (void)moveSelectionToOffset:(NSUInteger)offset
          modifyingSelection:(BOOL)modify
 preservingHorizontalPosition:(BOOL)preserveX {
  offset = [self safeNavigationOffset:offset];
  const NSUInteger anchor = [self safeNavigationOffset:
      self.navigationAnchor == NSNotFound
          ? self.committedSelection.location : self.navigationAnchor];
  const CGFloat preferredX = self.navigationPreferredX;
  self.committedSelection = modify
      ? NSMakeRange(std::min(anchor, offset),
                    std::max(anchor, offset) - std::min(anchor, offset))
      : NSMakeRange(offset, 0);
  self.navigationAnchor = modify ? anchor : NSNotFound;
  self.navigationCaret = offset;
  self.navigationPreferredX = preserveX ? preferredX : NAN;
  [self setNeedsDisplay:YES];
  [self scrollSelectionToVisible];
}

- (void)prepareLinearNavigation {
  if ([self hasMarkedText]) [self unmarkText];
  [self clearRectangularSelection];
}

// Group letters, digits and '_' as identifiers; preserve composed sequences
// (including emoji) as indivisible units when crossing punctuation or spaces.
- (NSInteger)wordKindAtNavigationOffset:(NSUInteger)offset inString:(NSString*)text {
  if (offset >= text.length) return -1;
  const NSRange cluster = [text rangeOfComposedCharacterSequenceAtIndex:offset];
  NSString* character = [text substringWithRange:cluster];
  if ([character rangeOfCharacterFromSet:
          [NSCharacterSet newlineCharacterSet]].location != NSNotFound) return 3;
  if ([character rangeOfCharacterFromSet:
          [NSCharacterSet whitespaceCharacterSet]].location != NSNotFound) return 0;
  if ([character isEqualToString:@"_"] ||
      [character rangeOfCharacterFromSet:
          [NSCharacterSet alphanumericCharacterSet]].location != NSNotFound) return 1;
  return 2;
}

- (NSRange)wordRangeAtNavigationOffset:(NSUInteger)offset {
  return [self wordRangeAtNavigationOffset:offset inString:[self committedString]];
}

- (NSRange)wordRangeAtNavigationOffset:(NSUInteger)offset inString:(NSString*)text {
  if (text.length == 0) return NSMakeRange(0, 0);
  offset = offset >= text.length
      ? [self previousNavigationOffset:text.length inString:text]
      : [self safeNavigationOffset:offset inString:text];
  const NSInteger kind = [self wordKindAtNavigationOffset:offset inString:text];
  NSUInteger start = offset;
  NSUInteger end = [self nextNavigationOffset:offset inString:text];
  if (kind != 3) {
    while (start != 0) {
      const NSUInteger previous = [self previousNavigationOffset:start inString:text];
      if ([self wordKindAtNavigationOffset:previous inString:text] != kind) break;
      start = previous;
    }
    while (end < text.length &&
           [self wordKindAtNavigationOffset:end inString:text] == kind) {
      end = [self nextNavigationOffset:end inString:text];
    }
  }
  return NSMakeRange(start, end - start);
}

- (NSUInteger)wordNavigationOffset:(NSUInteger)offset forward:(BOOL)forward {
  NSString* text = [self committedString];
  offset = [self safeNavigationOffset:offset inString:text];
  if (forward) {
    while (offset < text.length &&
           ([self wordKindAtNavigationOffset:offset inString:text] == 0 ||
            [self wordKindAtNavigationOffset:offset inString:text] == 3)) {
      offset = [self nextNavigationOffset:offset inString:text];
    }
    if (offset < text.length) {
      offset = NSMaxRange([self wordRangeAtNavigationOffset:offset inString:text]);
    }
  } else {
    while (offset != 0) {
      const NSUInteger previous = [self previousNavigationOffset:offset inString:text];
      const NSInteger kind = [self wordKindAtNavigationOffset:previous inString:text];
      if (kind != 0 && kind != 3) {
        return [self wordRangeAtNavigationOffset:previous inString:text].location;
      }
      offset = previous;
    }
  }
  return offset;
}

- (void)moveHorizontally:(BOOL)forward modifyingSelection:(BOOL)modify {
  [self prepareLinearNavigation];
  NSUInteger caret = [self navigationCaretOffset];
  if (!modify && self.committedSelection.length != 0) {
    caret = forward ? NSMaxRange(self.committedSelection)
                    : self.committedSelection.location;
  } else {
    caret = forward ? [self nextNavigationOffset:caret]
                    : [self previousNavigationOffset:caret];
  }
  [self moveSelectionToOffset:caret modifyingSelection:modify
       preservingHorizontalPosition:NO];
}

- (void)moveWordHorizontally:(BOOL)forward modifyingSelection:(BOOL)modify {
  [self prepareLinearNavigation];
  const NSUInteger caret = [self wordNavigationOffset:[self navigationCaretOffset]
                                            forward:forward];
  [self moveSelectionToOffset:caret modifyingSelection:modify
       preservingHorizontalPosition:NO];
}

- (void)moveLeft:(id)sender {
  (void)sender;
  if ([self hasMarkedText]) {
    [self unmarkText];
  }
  if (self.rectangularSelectionActive) {
    const auto& ranges = [self displayLineRanges];
    const NSRange lineSpan = [self rectangularDisplayLineSpan];
    const NSUInteger lineIndex = lineSpan.location == NSNotFound
        ? 0 : std::min<NSUInteger>(
            static_cast<NSUInteger>(std::max<CGFloat>(
                0.0, (self.rectangularCurrentPoint.y - kVerticalInset) /
                    [self editorLineHeight])), ranges.size() - 1);
    const NSRange lineRange = ranges[lineIndex];
    const NSUInteger current = [self displayIndexForLocalPoint:
        self.rectangularCurrentPoint];
    NSRect endRect = [self localRectForDisplayIndex:NSMaxRange(lineRange)];
    if (self.rectangularCurrentPoint.x > endRect.origin.x + 0.5) {
      self.rectangularCurrentPoint = NSMakePoint(
          std::max(endRect.origin.x,
                   self.rectangularCurrentPoint.x -
                       [self rectangularSpaceAdvance]),
          self.rectangularCurrentPoint.y);
    } else if (current > lineRange.location) {
      NSString* text = [self committedString];
      const NSRange previous = [text rangeOfComposedCharacterSequenceAtIndex:
          current - 1];
      const NSRect rect = [self localRectForDisplayIndex:
          [self previousEditBoundaryAtOrBefore:previous.location]];
      self.rectangularCurrentPoint = NSMakePoint(rect.origin.x,
                                                 self.rectangularCurrentPoint.y);
    }
    [self updateRectangularSelection];
    return;
  }
  [self moveHorizontally:NO modifyingSelection:NO];
}

- (void)moveRight:(id)sender {
  (void)sender;
  if ([self hasMarkedText]) {
    [self unmarkText];
  }
  if (self.rectangularSelectionActive) {
    const auto& ranges = [self displayLineRanges];
    const NSUInteger lineIndex = std::min<NSUInteger>(
        static_cast<NSUInteger>(std::max<CGFloat>(
            0.0, (self.rectangularCurrentPoint.y - kVerticalInset) /
                [self editorLineHeight])), ranges.size() - 1);
    const NSRange lineRange = ranges[lineIndex];
    const NSUInteger current = [self displayIndexForLocalPoint:
        self.rectangularCurrentPoint];
    NSRect endRect = [self localRectForDisplayIndex:NSMaxRange(lineRange)];
    if (self.rectangularCurrentPoint.x >= endRect.origin.x - 0.5) {
      self.rectangularCurrentPoint = NSMakePoint(
          std::max(self.rectangularCurrentPoint.x, endRect.origin.x) +
              [self rectangularSpaceAdvance],
          self.rectangularCurrentPoint.y);
    } else if (current < NSMaxRange(lineRange)) {
      NSString* text = [self committedString];
      const NSRange next = [text rangeOfComposedCharacterSequenceAtIndex:current];
      const NSRect rect = [self localRectForDisplayIndex:
          [self nextEditBoundaryAtOrAfter:NSMaxRange(next)]];
      self.rectangularCurrentPoint = NSMakePoint(rect.origin.x,
                                                 self.rectangularCurrentPoint.y);
    }
    [self updateRectangularSelection];
    return;
  }
  [self moveHorizontally:YES modifyingSelection:NO];
}

- (void)moveUp:(id)sender {
  (void)sender;
  [self moveVertically:-1];
}

- (void)moveDown:(id)sender {
  (void)sender;
  [self moveVertically:1];
}

- (void)moveVertically:(NSInteger)delta {
  if ([self hasMarkedText]) {
    [self unmarkText];
  }
  if (self.rectangularSelectionActive) {
    self.rectangularCurrentPoint = NSMakePoint(
        self.rectangularCurrentPoint.x,
        self.rectangularCurrentPoint.y +
            static_cast<CGFloat>(delta) * [self editorLineHeight]);
    [self updateRectangularSelection];
    return;
  }
  [self moveVertically:delta modifyingSelection:NO];
}

- (void)moveVertically:(NSInteger)delta modifyingSelection:(BOOL)modify {
  [self prepareLinearNavigation];
  const NSUInteger caret = [self navigationCaretOffset];
  const auto& ranges = [self displayLineRanges];
  const NSUInteger current = lineIndexContainingCharacter(ranges, caret, &_lineLookupSteps);
  const NSInteger target = std::clamp<NSInteger>(
      static_cast<NSInteger>(current) + delta, 0,
      static_cast<NSInteger>(ranges.size()) - 1);
  if (std::isnan(self.navigationPreferredX)) {
    self.navigationPreferredX = [self localRectForDisplayIndex:caret].origin.x;
  }
  const NSPoint targetPoint = NSMakePoint(
      self.navigationPreferredX,
      kVerticalInset + static_cast<CGFloat>(target) * [self editorLineHeight] +
          0.5 * [self editorLineHeight]);
  const NSUInteger offset = current == static_cast<NSUInteger>(target)
      ? (delta < 0 ? 0 : [self committedString].length)
      : [self displayIndexForLocalPoint:targetPoint];
  [self moveSelectionToOffset:offset modifyingSelection:modify
       preservingHorizontalPosition:YES];
}

- (void)moveToBeginningOfLine:(id)sender {
  (void)sender;
  [self moveToLineBoundary:NO modifyingSelection:NO];
}

- (void)moveToEndOfLine:(id)sender {
  (void)sender;
  [self moveToLineBoundary:YES modifyingSelection:NO];
}

- (void)moveToBeginningOfDocument:(id)sender {
  (void)sender;
  [self prepareLinearNavigation];
  [self moveSelectionToOffset:0 modifyingSelection:NO
       preservingHorizontalPosition:NO];
}

- (void)moveToEndOfDocument:(id)sender {
  (void)sender;
  [self prepareLinearNavigation];
  [self moveSelectionToOffset:[self committedString].length modifyingSelection:NO
       preservingHorizontalPosition:NO];
}

- (void)moveToLineBoundary:(BOOL)end modifyingSelection:(BOOL)modify {
  [self prepareLinearNavigation];
  const auto& buffer = self.sakuraDocument.documentSession.buffer();
  const auto position = buffer.positionAt([self navigationCaretOffset]);
  const NSUInteger offset = static_cast<NSUInteger>(end
      ? buffer.offsetAt({position.line, buffer.line(position.line).content.size()})
      : buffer.lineStartOffset(position.line));
  [self moveSelectionToOffset:offset modifyingSelection:modify
       preservingHorizontalPosition:NO];
}

- (void)moveLeftAndModifySelection:(id)sender {
  (void)sender;
  [self moveHorizontally:NO modifyingSelection:YES];
}

- (void)moveRightAndModifySelection:(id)sender {
  (void)sender;
  [self moveHorizontally:YES modifyingSelection:YES];
}

- (void)moveUpAndModifySelection:(id)sender {
  (void)sender;
  [self moveVertically:-1 modifyingSelection:YES];
}

- (void)moveDownAndModifySelection:(id)sender {
  (void)sender;
  [self moveVertically:1 modifyingSelection:YES];
}

- (void)moveWordLeft:(id)sender {
  (void)sender;
  [self moveWordHorizontally:NO modifyingSelection:NO];
}

- (void)moveWordRight:(id)sender {
  (void)sender;
  [self moveWordHorizontally:YES modifyingSelection:NO];
}

- (void)moveWordLeftAndModifySelection:(id)sender {
  (void)sender;
  [self moveWordHorizontally:NO modifyingSelection:YES];
}

- (void)moveWordRightAndModifySelection:(id)sender {
  (void)sender;
  [self moveWordHorizontally:YES modifyingSelection:YES];
}

- (void)moveToBeginningOfLineAndModifySelection:(id)sender {
  (void)sender;
  [self moveToLineBoundary:NO modifyingSelection:YES];
}

- (void)moveToEndOfLineAndModifySelection:(id)sender {
  (void)sender;
  [self moveToLineBoundary:YES modifyingSelection:YES];
}

- (void)moveToBeginningOfDocumentAndModifySelection:(id)sender {
  (void)sender;
  [self prepareLinearNavigation];
  [self moveSelectionToOffset:0 modifyingSelection:YES
       preservingHorizontalPosition:NO];
}

- (void)moveToEndOfDocumentAndModifySelection:(id)sender {
  (void)sender;
  [self prepareLinearNavigation];
  [self moveSelectionToOffset:[self committedString].length modifyingSelection:YES
       preservingHorizontalPosition:NO];
}

- (NSInteger)navigationPageLineCount {
  const CGFloat height = self.enclosingScrollView != nil
      ? self.enclosingScrollView.contentView.bounds.size.height
      : std::min<CGFloat>(self.visibleRect.size.height, 600.0);
  return std::max<NSInteger>(1, static_cast<NSInteger>(
      std::floor(height / [self editorLineHeight])) - 1);
}

- (void)pageUp:(id)sender {
  (void)sender;
  [self moveVertically:-[self navigationPageLineCount] modifyingSelection:NO];
}

- (void)pageDown:(id)sender {
  (void)sender;
  [self moveVertically:[self navigationPageLineCount] modifyingSelection:NO];
}

- (void)pageUpAndModifySelection:(id)sender {
  (void)sender;
  [self moveVertically:-[self navigationPageLineCount] modifyingSelection:YES];
}

- (void)pageDownAndModifySelection:(id)sender {
  (void)sender;
  [self moveVertically:[self navigationPageLineCount] modifyingSelection:YES];
}

// AppKit key bindings use both logical and visual selector spellings.
- (void)moveBackward:(id)sender { [self moveLeft:sender]; }
- (void)moveForward:(id)sender { [self moveRight:sender]; }
- (void)moveBackwardAndModifySelection:(id)sender {
  [self moveLeftAndModifySelection:sender];
}
- (void)moveForwardAndModifySelection:(id)sender {
  [self moveRightAndModifySelection:sender];
}
- (void)moveWordBackward:(id)sender { [self moveWordLeft:sender]; }
- (void)moveWordForward:(id)sender { [self moveWordRight:sender]; }
- (void)moveWordBackwardAndModifySelection:(id)sender {
  [self moveWordLeftAndModifySelection:sender];
}
- (void)moveWordForwardAndModifySelection:(id)sender {
  [self moveWordRightAndModifySelection:sender];
}
- (void)moveToLeftEndOfLine:(id)sender { [self moveToBeginningOfLine:sender]; }
- (void)moveToRightEndOfLine:(id)sender { [self moveToEndOfLine:sender]; }
- (void)moveToLeftEndOfLineAndModifySelection:(id)sender {
  [self moveToBeginningOfLineAndModifySelection:sender];
}
- (void)moveToRightEndOfLineAndModifySelection:(id)sender {
  [self moveToEndOfLineAndModifySelection:sender];
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item {
  const SEL action = item.action;
  if (action == @selector(undo:)) {
    return self.sakuraDocument.documentSession.canUndo();
  }
  if (action == @selector(redo:)) {
    return self.sakuraDocument.documentSession.canRedo();
  }
  if (action == @selector(copy:) || action == @selector(cut:)) {
    return [self selectedCharacterCount] != 0;
  }
  if (action == @selector(paste:)) {
    return [[NSPasteboard generalPasteboard]
               availableTypeFromArray:@[ NSPasteboardTypeString ]] != nil;
  }
  return YES;
}

@end
