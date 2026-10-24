// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#import <AppKit/AppKit.h>

// Independent geometric document artwork. No upstream icon pixels, font glyphs,
// screenshots, SF Symbols exports or third-party artwork are used.
static BOOL writeIcon(NSString* path, NSInteger pixels) {
  NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc]
      initWithBitmapDataPlanes:nullptr pixelsWide:pixels pixelsHigh:pixels
      bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
      colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
  if (bitmap == nil) return NO;
  [NSGraphicsContext saveGraphicsState];
  NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
  CGContextRef context = NSGraphicsContext.currentContext.CGContext;
  CGContextClearRect(context, CGRectMake(0, 0, pixels, pixels));
  CGContextScaleCTM(context, pixels / 1024.0, pixels / 1024.0);
  NSBezierPath* tile = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(48, 48, 928, 928)
      xRadius:200 yRadius:200];
  NSGradient* gradient = [[NSGradient alloc]
      initWithStartingColor:[NSColor colorWithSRGBRed:0.16 green:0.25 blue:0.46 alpha:1]
      endingColor:[NSColor colorWithSRGBRed:0.34 green:0.25 blue:0.52 alpha:1]];
  [gradient drawInBezierPath:tile angle:70];
  NSBezierPath* paper = [NSBezierPath bezierPath];
  [paper moveToPoint:NSMakePoint(300, 206)];
  [paper lineToPoint:NSMakePoint(724, 206)];
  [paper lineToPoint:NSMakePoint(724, 650)];
  [paper lineToPoint:NSMakePoint(566, 818)];
  [paper lineToPoint:NSMakePoint(300, 818)];
  [paper closePath];
  [[NSColor colorWithSRGBRed:0.95 green:0.96 blue:0.99 alpha:1] setFill];
  [paper fill];
  NSBezierPath* fold = [NSBezierPath bezierPath];
  [fold moveToPoint:NSMakePoint(566, 818)];
  [fold lineToPoint:NSMakePoint(566, 650)];
  [fold lineToPoint:NSMakePoint(724, 650)];
  [fold closePath];
  [[NSColor colorWithSRGBRed:0.68 green:0.74 blue:0.88 alpha:1] setFill];
  [fold fill];
  [[NSColor colorWithSRGBRed:0.25 green:0.37 blue:0.58 alpha:1] setFill];
  for (NSInteger line = 0; line < 3; ++line) {
    [[NSBezierPath bezierPathWithRoundedRect:
        NSMakeRect(366, 342 + line * 94, line == 0 ? 170 : 292, 30)
        xRadius:15 yRadius:15] fill];
  }
  [NSGraphicsContext restoreGraphicsState];
  NSData* data = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
  return data != nil && [data writeToFile:path atomically:YES];
}

int main(int argc, const char* argv[]) {
  @autoreleasepool {
    if (argc != 2) return 2;
    NSString* directory = [NSString stringWithUTF8String:argv[1]];
    if (directory == nil || ![NSFileManager.defaultManager createDirectoryAtPath:directory
        withIntermediateDirectories:YES attributes:nil error:nullptr]) return 1;
    const NSInteger sizes[] = {16, 32, 128, 256, 512};
    for (NSInteger size : sizes) {
      for (NSInteger scale = 1; scale <= 2; ++scale) {
        NSString* filename = [NSString stringWithFormat:@"icon_%ldx%ld%@.png",
            (long)size, (long)size, scale == 2 ? @"@2x" : @""];
        if (!writeIcon([directory stringByAppendingPathComponent:filename], size * scale)) return 1;
      }
    }
  }
  return 0;
}
