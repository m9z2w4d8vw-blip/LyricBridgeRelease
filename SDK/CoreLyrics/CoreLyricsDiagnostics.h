#pragma once
#import <Foundation/Foundation.h>
#import <sys/file.h>
#import <fcntl.h>
#import <unistd.h>

static inline NSArray<NSString *> *CLDiagnosticFilenames(void) {
    return @[@"CoreLyrics-debug.log", @"CoreLyrics-performance.log", @"LyricBridge-debug.log", @"LyricBridge-performance.log"];
}
static inline int CLDiagnosticLock(NSString *root) {
    if (![NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil]) return -1;
    int descriptor = open([root stringByAppendingPathComponent:@".diagnostics.lock"].fileSystemRepresentation, O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
    if (descriptor >= 0 && flock(descriptor, LOCK_EX) != 0) { close(descriptor); return -1; }
    return descriptor;
}
static inline void CLDiagnosticUnlock(int descriptor) { if (descriptor >= 0) { flock(descriptor, LOCK_UN); close(descriptor); } }
static inline void CLDiagnosticAppend(NSString *root, NSString *component, BOOL performance, NSString *message) {
    NSTimeInterval timestamp = NSDate.date.timeIntervalSince1970;
    NSString *filename = [NSString stringWithFormat:@"%@-%@.log", component, performance ? @"performance" : @"debug"];
    if (![CLDiagnosticFilenames() containsObject:filename]) return;
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.shalamand3r.lyrics.diagnostics", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0)); });
    dispatch_async(queue, ^{
        @autoreleasepool {
            int lock = CLDiagnosticLock(root); if (lock < 0) return;
            NSString *marker = [root stringByAppendingPathComponent:@".diagnostics-cleared"];
            double cleared = [[NSString stringWithContentsOfFile:marker encoding:NSUTF8StringEncoding error:nil] doubleValue];
            if (timestamp >= cleared) {
                NSString *line = [NSString stringWithFormat:@"[%@] %.3f pid=%d %@\n", component, timestamp, getpid(), message];
                NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
                int file = open([root stringByAppendingPathComponent:filename].fileSystemRepresentation, O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW, 0600);
                if (file >= 0) {
                    const uint8_t *bytes = data.bytes; NSUInteger remaining = data.length;
                    while (remaining) { ssize_t count = write(file, bytes, remaining); if (count <= 0) break; bytes += count; remaining -= count; }
                    close(file);
                }
            }
            CLDiagnosticUnlock(lock);
        }
    });
}
static inline void CLDiagnosticClear(NSString *root) {
    int lock = CLDiagnosticLock(root); if (lock < 0) return;
    NSString *marker = [root stringByAppendingPathComponent:@".diagnostics-cleared"];
    [[NSString stringWithFormat:@"%.6f", NSDate.date.timeIntervalSince1970] writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
    for (NSString *name in CLDiagnosticFilenames())
        [NSFileManager.defaultManager removeItemAtPath:[root stringByAppendingPathComponent:name] error:nil];
    CLDiagnosticUnlock(lock);
}
