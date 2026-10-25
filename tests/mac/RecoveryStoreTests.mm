// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib
#import <AppKit/AppKit.h>
#import "SakuraRecoveryStore.h"
#import "SakuraDocument.h"
#import "SakuraRecoveryWriter.h"
#include <iostream>
#include <functional>
#include <fcntl.h>
#include <spawn.h>
#include <sys/file.h>
#include <sys/wait.h>
#include <unistd.h>
extern char** environ;

@interface SakuraDocument (RecoveryTests)
- (NSURL*)recoveryBackupURL;
- (void)writeRecoveryBackupIfNeeded;
@end

static NSURL* testDirectory;
@interface RecoveryTestDocument : SakuraDocument
@end
@implementation RecoveryTestDocument
- (NSURL*)recoveryBackupURL {
  return [testDirectory URLByAppendingPathComponent:@"integration.sakura-recovery"];
}
@end

// Prove the early size guard without allocating hundreds of MiB or relying on
// disk exhaustion. Any attempt to serialize this string is a test failure.
@interface OversizedRecoveryString : NSString
@end
@implementation OversizedRecoveryString
- (NSUInteger)length { return 257ULL * 1024 * 1024; }
- (unichar)characterAtIndex:(NSUInteger)index {
  (void)index;
  [NSException raise:NSInternalInconsistencyException format:@"oversized recovery text must not be serialized"];
  return 0;
}
@end

namespace {
int failures = 0;
void expect(bool value, const char* message) {
  if (!value) { std::cerr << message << '\n'; ++failures; }
}
void awaitRecovery() {
  __block BOOL done = NO;
  SakuraRecoveryWhenIdle(^{ done = YES; });
  NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:10];
  while (!done && deadline.timeIntervalSinceNow > 0)
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
        beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
  expect(done, "asynchronous document recovery drains");
}
NSDictionary* record(NSString* text) {
  return @{@"version":@1, @"text":text, @"encoding":@1, @"bom":@NO,
           @"lineEnding":@"CRLF", @"date":NSDate.date,
           @"displayName":@"test", @"originalPath":@"/example/test.txt"};
}
NSURL* generation(NSURL* url, NSUInteger index) {
  return [NSURL fileURLWithPath:[url.path stringByAppendingFormat:@".previous-%lu",
                                        (unsigned long)index]];
}
void rawWrite(id value, NSURL* url) {
  NSData* data = [NSPropertyListSerialization dataWithPropertyList:value
      format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
  expect([data writeToURL:url atomically:YES], "write test record");
}
}

int main(int argc, char** argv) {
  @autoreleasepool {
    if (argc == 4 && std::string(argv[1]) == "--quota-child") {
      NSURL* destination = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]];
      NSString* text = [@"" stringByPaddingToLength:400 withString:@"x" startingAtIndex:0];
      return SakuraWriteRecovery(destination, record(text), std::stoull(argv[3]), nil) ? 0 : 86;
    }
    testDirectory = [NSURL fileURLWithPath:[NSTemporaryDirectory()
        stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    NSURL* url = [testDirectory URLByAppendingPathComponent:@"doc.sakura-recovery"];
    const unsigned long long budget = 1024 * 1024;
    for (NSString* text in @[@"one", @"two", @"three", @"four"])
      expect(SakuraWriteRecovery(url, record(text), budget, nil), "write generation");
    expect([SakuraReadRecovery(url)[@"text"] isEqual:@"four"], "latest retained");
    expect([SakuraReadRecovery(generation(url, 1))[@"text"] isEqual:@"three"], "first previous retained");
    expect([SakuraReadRecovery(generation(url, 2))[@"text"] isEqual:@"two"], "second previous retained");
    NSData* latest = [NSData dataWithContentsOfURL:url];
    NSError* error = nil;
    expect(!SakuraWriteRecovery(url, record([[OversizedRecoveryString alloc] init]),
                               4096ULL * 1024 * 1024, &error) && error,
           "oversized text is rejected before property-list serialization");
    expect([[NSData dataWithContentsOfURL:url] isEqual:latest], "early rejection preserves current recovery");
    error = nil;
    expect(!SakuraWriteRecovery(url, record(@"too large"), 10, &error) && error,
           "quota rejects with error");
    expect([[NSData dataWithContentsOfURL:url] isEqual:latest], "quota preserves current");
    NSURL* other = [testDirectory URLByAppendingPathComponent:@"other.sakura-recovery"];
    rawWrite(record(@"other document"), other);
    NSData* otherData = [NSData dataWithContentsOfURL:other];
    expect(!SakuraWriteRecovery(url, record(@"overflow"), latest.length, nil),
           "other documents count toward quota");
    expect([[NSData dataWithContentsOfURL:other] isEqual:otherData], "quota keeps other document");
    rawWrite(@[@"not a dictionary"], url);
    expect([SakuraReadRecovery(url)[@"text"] isEqual:@"three"], "invalid top level falls back");
    expect(SakuraWriteRecovery(url, record(@"repaired"), budget, nil), "repair corrupt primary");
    expect([SakuraReadRecovery(generation(url, 1))[@"text"] isEqual:@"three"], "repair preserves good fallback");
    NSMutableDictionary* invalid = [record(@"bad") mutableCopy];
    invalid[@"encoding"] = @999;
    rawWrite(invalid, url);
    expect([SakuraReadRecovery(url)[@"text"] isEqual:@"three"], "invalid enum falls back");
    invalid[@"encoding"] = @4294967297ULL;
    rawWrite(invalid, url);
    expect([SakuraReadRecovery(url)[@"text"] isEqual:@"three"], "overflow enum cannot alias UTF8");
    invalid[@"encoding"] = @1.5;
    rawWrite(invalid, url);
    expect([SakuraReadRecovery(url)[@"text"] isEqual:@"three"], "fractional enum rejected");
    invalid[@"encoding"] = @1; invalid[@"version"] = @1.5;
    rawWrite(invalid, url);
    expect([SakuraReadRecovery(url)[@"text"] isEqual:@"three"], "fractional schema version rejected");
    rawWrite(@{@"text":@"incomplete"}, generation(url, 1));
    expect([SakuraReadRecovery(url)[@"text"] isEqual:@"two"], "second fallback works");
    NSURL* unknown = [testDirectory URLByAppendingPathComponent:@"keep.txt"];
    rawWrite(@[@"user data"], unknown);
    SakuraRemoveRecovery(url);
    expect(!SakuraReadRecovery(url), "explicit cleanup removes generations");
    expect([NSFileManager.defaultManager fileExistsAtPath:unknown.path], "cleanup keeps unrelated file");
    expect([[NSData dataWithContentsOfURL:other] isEqual:otherData], "cleanup keeps other document");
    SakuraRemoveRecovery(unknown);
    expect([NSFileManager.defaultManager fileExistsAtPath:unknown.path], "cleanup rejects unrelated extension even when directly passed");
    error = nil;
    expect(!SakuraRemoveRecoveryChecked(unknown, &error) && error,
           "checked cleanup reports invalid target without deleting user data");
    NSURL* missing = [[testDirectory URLByAppendingPathComponent:@"absent" isDirectory:YES]
        URLByAppendingPathComponent:@"missing.sakura-recovery"];
    expect(SakuraRemoveRecoveryChecked(missing, nil), "already absent recovery directory is successful cleanup");
    NSURL* fakeRecordDirectory = [testDirectory URLByAppendingPathComponent:@"directory.sakura-recovery" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:fakeRecordDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL* inside = [fakeRecordDirectory URLByAppendingPathComponent:@"keep"];
    rawWrite(@[@"protected"], inside);
    error = nil;
    expect(!SakuraRemoveRecoveryChecked(fakeRecordDirectory, &error) && error,
           "nonregular recovery entry is a reported cleanup error");
    expect([NSFileManager.defaultManager fileExistsAtPath:inside.path], "cleanup never recursively deletes a directory with record-like name");
    [NSFileManager.defaultManager removeItemAtURL:fakeRecordDirectory error:nil];
    NSURL* link = [testDirectory URLByAppendingPathComponent:@"link"];
    expect([NSFileManager.defaultManager createSymbolicLinkAtURL:link
        withDestinationURL:unknown error:nil], "create symlink fixture");
    expect(!SakuraWriteRecovery(url, record(@"no"), budget, nil), "symlink blocks write");
    [NSFileManager.defaultManager removeItemAtURL:link error:nil];
    {
      NSString* suite = [@"SakuraRecoveryTests." stringByAppendingString:NSUUID.UUID.UUIDString];
      NSUserDefaults* defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
      expect(SakuraRecoveryGenerations(defaults) == 2 && SakuraRecoveryBudgetMiB(defaults) == 256, "recovery settings defaults");
      expect(SakuraSetRecoverySettings(defaults, 5, 32, nil), "valid settings accepted");
      expect(SakuraRecoveryGenerations(defaults) == 5 && SakuraRecoveryBudgetMiB(defaults) == 32, "settings round trip");
      expect(!SakuraSetRecoverySettings(defaults, 21, 64, nil) && SakuraRecoveryGenerations(defaults) == 5 && SakuraRecoveryBudgetMiB(defaults) == 32, "invalid settings do not partially apply");
      [defaults setObject:@1.5 forKey:SakuraRecoveryGenerationsKey];
      [defaults setObject:@"bad" forKey:SakuraRecoveryBudgetMiBKey];
      expect(SakuraRecoveryGenerations(defaults) == 2 && SakuraRecoveryBudgetMiB(defaults) == 256, "corrupt preferences fail to safe defaults");
      [defaults removePersistentDomainForName:suite];
    }
    {
      NSURL* custom = [testDirectory URLByAppendingPathComponent:@"custom.sakura-recovery"];
      for (NSUInteger index = 0; index < 7; ++index)
        expect(SakuraWriteRecoveryWithGenerations(custom, record([NSString stringWithFormat:@"%lu", (unsigned long)index]), budget, 5, nil), "custom generation write");
      expect([SakuraReadRecovery(generation(custom,5))[@"text"] isEqual:@"1"], "five previous generations retained");
      rawWrite(@[@"corrupt"], custom);
      for (NSUInteger index=1; index<5; ++index) rawWrite(@[@"corrupt"], generation(custom,index));
      expect([SakuraReadRecovery(custom)[@"text"] isEqual:@"1"], "read scans beyond legacy two generations");
      expect(SakuraWriteRecoveryWithGenerations(custom, record(@"repaired"), budget, 0, nil), "corrupt primary repaired with zero requested history");
      expect([NSFileManager.defaultManager fileExistsAtPath:generation(custom,5).path], "repair preserves old fallback until next valid rotation");
      expect(SakuraWriteRecoveryWithGenerations(custom, record(@"newest"), budget, 0, nil), "zero-history write succeeds");
      expect(![NSFileManager.defaultManager fileExistsAtPath:generation(custom,5).path] && [SakuraReadRecovery(custom)[@"text"] isEqual:@"newest"], "history pruned only after durable primary commit");
      expect([[NSData dataWithContentsOfURL:other] isEqual:otherData], "pruning never touches another document");
      NSData* before = [NSData dataWithContentsOfURL:custom];
      expect(!SakuraWriteRecoveryWithGenerations(custom, @{@"bad":@YES}, budget, 2, nil) && [[NSData dataWithContentsOfURL:custom] isEqual:before], "invalid record cannot replace good primary");
      SakuraRemoveRecovery(custom);
    }
    {
      NSURL* concurrent = [testDirectory URLByAppendingPathComponent:@"concurrent" isDirectory:YES];
      [NSFileManager.defaultManager createDirectoryAtURL:concurrent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
      auto spawn = [&](NSURL* destination, const char* bytes, pid_t* pid) {
        char* arguments[] = {argv[0], const_cast<char*>("--quota-child"), const_cast<char*>(destination.fileSystemRepresentation), const_cast<char*>(bytes), nullptr};
        return ::posix_spawn(pid, argv[0], nullptr, nullptr, arguments, environ);
      };
      NSURL* first = [concurrent URLByAppendingPathComponent:@"a.sakura-recovery"];
      NSURL* second = [concurrent URLByAppendingPathComponent:@"b.sakura-recovery"];
      NSURL* lockURL = [concurrent URLByAppendingPathComponent:@".sakura-recovery.lock"];
      int fd = ::open(lockURL.fileSystemRepresentation, O_RDWR | O_CREAT, 0600);
      expect(fd >= 0 && ::flock(fd, LOCK_EX | LOCK_NB) == 0, "hold real process lock");
      NSError* removalError = nil;
      expect(!SakuraRemoveRecoveryChecked(first, &removalError) && removalError,
             "checked cleanup reports a busy cross-process lock");
      pid_t blocked = -1; expect(spawn(first,"1000",&blocked) == 0, "spawn blocked writer");
      int blockedStatus=0; if(blocked>0) ::waitpid(blocked,&blockedStatus,0);
      expect(WIFEXITED(blockedStatus) && WEXITSTATUS(blockedStatus) == 86 && !SakuraReadRecovery(first), "second process cannot write while lock held");
      if(fd>=0) ::close(fd);
      pid_t a=-1,b=-1; expect(spawn(first,"1000",&a)==0 && spawn(second,"1000",&b)==0, "spawn competing quota writers");
      int aStatus=0,bStatus=0; if(a>0) ::waitpid(a,&aStatus,0); if(b>0) ::waitpid(b,&bStatus,0);
      const bool aSucceeded=WIFEXITED(aStatus)&&WEXITSTATUS(aStatus)==0;
      const bool bSucceeded=WIFEXITED(bStatus)&&WEXITSTATUS(bStatus)==0;
      expect(aSucceeded != bSucceeded, "cross-process quota admits only one record");
      expect((SakuraReadRecovery(first)!=nil) != (SakuraReadRecovery(second)!=nil), "quota loser cannot create partial primary");
      [NSFileManager.defaultManager removeItemAtURL:concurrent error:nil];
    }
    // Exercise the actual document serializer without windows/timers/defaults.
    RecoveryTestDocument* doc = [[RecoveryTestDocument alloc] init];
    const char bytes[] = "hello";
    expect([doc readFromData:[NSData dataWithBytes:bytes length:5]
                     ofType:@"public.plain-text" error:nil], "load document");
    doc.documentSession.insert(5, u"!");
    [doc writeRecoveryBackupIfNeeded];
    awaitRecovery();
    expect([SakuraReadRecovery(doc.recoveryBackupURL)[@"text"] isEqual:@"hello!"],
           "document writes recovery record");
    expect(![SakuraReadRecovery(doc.recoveryBackupURL)[@"sourceEncodingAmbiguous"] boolValue],
           "ordinary Unicode recovery is not marked ambiguous");
    doc.documentSession.restoreSourceEncodingAmbiguity();
    [doc writeRecoveryBackupIfNeeded];
    awaitRecovery();
    expect([SakuraReadRecovery(doc.recoveryBackupURL)[@"sourceEncodingAmbiguous"] boolValue],
           "document serializer retains uncertainty for recovery");
    NSMutableDictionary* malformed = [record(@"invalid ambiguity metadata") mutableCopy];
    malformed[@"sourceEncodingAmbiguous"] = @"YES";
    expect(!SakuraWriteRecovery(doc.recoveryBackupURL, malformed, budget, nil),
           "string cannot masquerade as recovery ambiguity flag");
    malformed[@"sourceEncodingAmbiguous"] = @2;
    expect(!SakuraWriteRecovery(doc.recoveryBackupURL, malformed, budget, nil),
           "non-boolean number cannot masquerade as recovery ambiguity flag");
    expect([SakuraReadRecovery(doc.recoveryBackupURL)[@"sourceEncodingAmbiguous"] boolValue],
           "invalid metadata preserves previous recovery warning");
    [doc close];
    awaitRecovery();
    expect(!SakuraReadRecovery(doc.recoveryBackupURL), "close clears own backup");
    [NSFileManager.defaultManager removeItemAtURL:testDirectory error:nil];
  }
  return failures ? 1 : 0;
}
