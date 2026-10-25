// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#import <AppKit/AppKit.h>

static NSString* const SakuraEditorColorThemeKey = @"SakuraEditorColorTheme";
static NSString* const SakuraEditorColorThemeWindows = @"windows-classic";
static NSString* const SakuraEditorColorThemeSystem = @"system";
static NSString* const SakuraEditorColorThemeDark = @"dark";

static inline BOOL SakuraThemeIsDark(NSAppearance* appearance);

static inline NSColor* SakuraRGB(CGFloat red, CGFloat green, CGFloat blue) {
  return [NSColor colorWithSRGBRed:red / 255.0
                            green:green / 255.0
                             blue:blue / 255.0
                            alpha:1.0];
}

static inline NSString* SakuraTypeIdentifierForExtension(NSString* extension) {
  NSString* value = extension.lowercaseString;
  if (value == nil) {
    value = @"";
  }
  if ([@[ @"c", @"cc", @"cpp", @"cxx", @"h", @"hh", @"hpp", @"hxx",
          @"m", @"mm" ] containsObject:value]) {
    return @"cpp";
  }
  if ([@[ @"htm", @"html", @"xhtml", @"xml" ] containsObject:value]) {
    return @"html";
  }
  if ([value isEqualToString:@"java"] || [value isEqualToString:@"swift"] ||
      [value isEqualToString:@"plsql"] || [value isEqualToString:@"cob"] ||
      [value isEqualToString:@"asm"] || [value isEqualToString:@"pl"] ||
      [value isEqualToString:@"vb"]) {
    return value;
  }
  if ([@[ @"md", @"markdown" ] containsObject:value]) {
    return @"markdown";
  }
  return value.length == 0 ? @"basic" : @"text";
}

static inline NSString* SakuraTypeColorPreferenceKey(
    NSString* typeIdentifier, NSString* role, NSAppearance* appearance) {
  NSString* variant = SakuraThemeIsDark(appearance) ? @"dark" : @"light";
  return [NSString stringWithFormat:@"SakuraTypeColor.%@.%@.%@",
                                    typeIdentifier, variant, role];
}

static inline NSColor* SakuraColorFromHexString(NSString* value) {
  if (value.length != 7 || ![value hasPrefix:@"#"]) {
    return nil;
  }
  unsigned int rgb = 0;
  NSScanner* scanner = [NSScanner scannerWithString:[value substringFromIndex:1]];
  if (![scanner scanHexInt:&rgb] || !scanner.isAtEnd) {
    return nil;
  }
  return SakuraRGB((rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff);
}

static inline NSString* SakuraHexStringFromColor(NSColor* color) {
  NSColor* rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  if (rgb == nil) {
    return @"#000000";
  }
  NSInteger red = (NSInteger)(rgb.redComponent * 255.0 + 0.5);
  NSInteger green = (NSInteger)(rgb.greenComponent * 255.0 + 0.5);
  NSInteger blue = (NSInteger)(rgb.blueComponent * 255.0 + 0.5);
  return [NSString stringWithFormat:@"#%02lX%02lX%02lX",
                                    (long)red, (long)green, (long)blue];
}

static inline NSColor* SakuraTypeColor(NSString* typeIdentifier,
                                      NSString* role,
                                      NSAppearance* appearance,
                                      NSColor* fallback) {
  NSString* value = [[NSUserDefaults standardUserDefaults]
      stringForKey:SakuraTypeColorPreferenceKey(typeIdentifier, role,
                                                appearance)];
  NSColor* customized = SakuraColorFromHexString(value);
  return customized != nil ? customized : fallback;
}

static inline NSString* SakuraTypeStylePreferenceKey(
    NSString* typeIdentifier, NSString* role, NSString* attribute) {
  return [NSString stringWithFormat:@"SakuraTypeStyle.%@.%@.%@",
                                    typeIdentifier, role, attribute];
}

static inline BOOL SakuraTypeStyleBool(NSString* typeIdentifier,
                                       NSString* role,
                                       NSString* attribute,
                                       BOOL fallback) {
  NSString* key = SakuraTypeStylePreferenceKey(typeIdentifier, role, attribute);
  NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
  return [defaults objectForKey:key] == nil ? fallback : [defaults boolForKey:key];
}

static inline BOOL SakuraThemeIsDark(NSAppearance* appearance) {
  NSString* mode = [[NSUserDefaults standardUserDefaults]
      stringForKey:SakuraEditorColorThemeKey];
  if ([mode isEqualToString:SakuraEditorColorThemeDark]) {
    return YES;
  }
  if (![mode isEqualToString:SakuraEditorColorThemeSystem]) {
    return NO;
  }
  NSAppearanceName match = [appearance
      bestMatchFromAppearancesWithNames:@[
        NSAppearanceNameAqua, NSAppearanceNameDarkAqua
      ]];
  return [match isEqualToString:NSAppearanceNameDarkAqua];
}

// Light values mirror Sakura Editor for Windows' ColorInfo_DEFAULT.
static inline NSColor* SakuraEditorBackground(NSAppearance* appearance) {
  return SakuraThemeIsDark(appearance) ? SakuraRGB(30, 30, 30)
                                       : SakuraRGB(255, 251, 240);
}

static inline NSColor* SakuraEditorText(NSAppearance* appearance) {
  return SakuraThemeIsDark(appearance) ? SakuraRGB(232, 232, 232)
                                       : SakuraRGB(0, 0, 0);
}

static inline NSColor* SakuraGutterBackground(NSAppearance* appearance) {
  return SakuraThemeIsDark(appearance) ? SakuraRGB(43, 43, 43)
                                       : SakuraRGB(239, 239, 239);
}

static inline NSColor* SakuraGutterText(NSAppearance* appearance) {
  return SakuraThemeIsDark(appearance) ? SakuraRGB(130, 170, 255)
                                       : SakuraRGB(0, 0, 255);
}

static inline NSColor* SakuraCommentText(NSAppearance* appearance) {
  return SakuraThemeIsDark(appearance) ? SakuraRGB(106, 181, 108)
                                       : SakuraRGB(0, 128, 0);
}

static inline NSColor* SakuraStringText(NSAppearance* appearance) {
  return SakuraThemeIsDark(appearance) ? SakuraRGB(224, 128, 170)
                                       : SakuraRGB(128, 0, 64);
}

static inline NSColor* SakuraKeywordText(NSAppearance* appearance) {
  return SakuraThemeIsDark(appearance) ? SakuraRGB(115, 160, 255)
                                       : SakuraRGB(0, 0, 255);
}

static inline NSString* SakuraKeywordRole(NSUInteger group) {
  return group <= 1 || group > 10 ? @"keyword" : [NSString stringWithFormat:@"keyword%lu", (unsigned long)group];
}
static inline NSColor* SakuraKeywordGroupText(NSUInteger group, NSAppearance* appearance) {
  if (group <= 1 || group > 10) return SakuraKeywordText(appearance);
  static const unsigned char light[9][3] = {{0,128,128},{128,0,128},{128,64,0},{160,0,0},
      {192,0,128},{160,80,0},{0,96,160},{64,64,160},{96,112,0}};
  static const unsigned char dark[9][3] = {{80,210,210},{210,150,255},{220,180,120},{255,140,140},
      {255,140,210},{255,190,100},{120,200,255},{170,170,255},{200,220,120}};
  const auto* color = SakuraThemeIsDark(appearance) ? dark[group - 2] : light[group - 2];
  return SakuraRGB(color[0], color[1], color[2]);
}

static inline NSColor* SakuraNumberText(NSAppearance* appearance) {
  return SakuraThemeIsDark(appearance) ? SakuraRGB(255, 115, 115)
                                       : SakuraRGB(235, 0, 0);
}

static inline NSColor* SakuraPreprocessorText(NSAppearance* appearance) {
  return SakuraThemeIsDark(appearance) ? SakuraRGB(104, 190, 190)
                                       : SakuraRGB(64, 128, 128);
}

static inline NSColor* SakuraTabMarkerText(NSAppearance* appearance) {
  return SakuraThemeIsDark(appearance) ? SakuraRGB(150, 150, 150)
                                       : SakuraRGB(128, 128, 128);
}

static inline NSColor* SakuraSpaceMarkerText(NSAppearance* appearance) {
  return SakuraThemeIsDark(appearance) ? SakuraRGB(105, 105, 105)
                                       : SakuraRGB(192, 192, 192);
}

static inline NSColor* SakuraEolMarkerText(NSAppearance* appearance) {
  return SakuraThemeIsDark(appearance) ? SakuraRGB(80, 170, 255)
                                       : SakuraRGB(0, 128, 255);
}

static inline NSColor* SakuraWrapMarkerText(NSAppearance* appearance) {
  return SakuraThemeIsDark(appearance) ? SakuraRGB(255, 105, 255)
                                       : SakuraRGB(255, 0, 255);
}

static inline NSColor* SakuraEofMarkerText(NSAppearance* appearance) {
  (void)appearance;
  return SakuraRGB(0, 255, 255);
}

static inline NSColor* SakuraEofMarkerBackground(NSAppearance* appearance) {
  (void)appearance;
  return SakuraRGB(0, 0, 0);
}

static inline NSColor* SakuraSelectionBackground(NSAppearance* appearance) {
  return SakuraThemeIsDark(appearance) ? SakuraRGB(55, 95, 145)
                                       : SakuraRGB(49, 106, 197);
}

static inline NSColor* SakuraSelectionText(NSAppearance* appearance) {
  (void)appearance;
  return NSColor.whiteColor;
}

static inline NSColor* SakuraSearchBackground(NSAppearance* appearance) {
  return SakuraThemeIsDark(appearance) ? SakuraRGB(145, 125, 0)
                                       : SakuraRGB(255, 255, 0);
}

static inline NSColor* SakuraSearchText(NSAppearance* appearance) {
  (void)appearance;
  return SakuraRGB(0, 0, 0);
}

static inline NSColor* SakuraCaretLine(NSAppearance* appearance) {
  return SakuraThemeIsDark(appearance) ? SakuraRGB(100, 145, 255)
                                       : SakuraRGB(0, 0, 255);
}

static inline NSColor* SakuraChromeBackground(NSAppearance* appearance) {
  return SakuraThemeIsDark(appearance) ? SakuraRGB(45, 45, 45)
                                       : SakuraRGB(240, 240, 240);
}

static inline NSColor* SakuraChromeText(NSAppearance* appearance) {
  return SakuraThemeIsDark(appearance) ? SakuraRGB(235, 235, 235)
                                       : SakuraRGB(0, 0, 0);
}

static inline NSColor* SakuraChromeBorder(NSAppearance* appearance) {
  return SakuraThemeIsDark(appearance) ? SakuraRGB(82, 82, 82)
                                       : SakuraRGB(160, 160, 160);
}
