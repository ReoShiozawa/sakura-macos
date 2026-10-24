// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#import <AppKit/AppKit.h>
#import "SakuraAppDelegate.h"

#include <cstdlib>
#include <iostream>

@interface SakuraAppDelegate (PublicationTesting)
- (void)installMainMenu;
- (void)showUnofficialAbout:(id)sender;
@end

// Inspect About options without opening a panel or starting document recovery.
@interface PublicationTestApplication : NSApplication
@property(nonatomic, copy) NSDictionary* capturedAboutOptions;
@end

@implementation PublicationTestApplication
- (void)orderFrontStandardAboutPanelWithOptions:(NSDictionary*)options {
  self.capturedAboutOptions = options;
}
@end

namespace {
int failures = 0;
void expect(BOOL result, const char* message) {
  if (result) return;
  ++failures;
  std::cerr << message << '\n';
}

NSUInteger inspectMenu(NSMenu* menu, SakuraAppDelegate* delegate) {
  NSUInteger aboutItems = 0;
  for (NSMenuItem* item in menu.itemArray) {
    if (item.action == @selector(showUnofficialAbout:)) {
      expect(item.target == delegate, "About item must target the unofficial delegate");
      ++aboutItems;
    }
    if (item.action == NSSelectorFromString(@"showBundledLicenses:")) {
      expect(item.target == delegate, "Licenses item must target the unofficial delegate");
    }
    expect(item.action != @selector(orderFrontStandardAboutPanel:),
        "Menus must not bypass the unofficial About information");
    if (item.submenu != nil) aboutItems += inspectMenu(item.submenu, delegate);
  }
  return aboutItems;
}
}

int main() {
  @autoreleasepool {
    PublicationTestApplication* application = [PublicationTestApplication sharedApplication];
    SakuraAppDelegate* delegate = [[SakuraAppDelegate alloc] init];
    [delegate installMainMenu];
    NSMenu* applicationMenu = application.mainMenu.itemArray.firstObject.submenu;
    expect([applicationMenu.title containsString:@"Unofficial"], "Application menu must identify the unofficial port");
    expect(inspectMenu(application.mainMenu, delegate) == 2, "Application and Help menus need unofficial About items");
    [delegate showUnofficialAbout:nil];
    NSDictionary* options = application.capturedAboutOptions;
    expect([options[NSAboutPanelOptionApplicationName] containsString:@"Unofficial"],
        "About name must identify the unofficial port");
    expect([options[@"Copyright"] containsString:@"Unofficial Sakura macOS port contributors"],
        "About copyright must identify port contributors");
    NSAttributedString* credits = options[NSAboutPanelOptionCredits];
    expect([credits.string containsString:@"Sakura Editor Organization"],
        "About must credit upstream");
    expect([credits.string containsString:@"提供・承認・サポートする製品ではありません"],
        "About must disclaim upstream endorsement");
    expect([credits.string containsString:@"zlib"], "About must point to licensing");
  }
  return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
