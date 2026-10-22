#import "LyricBridgeDiagnostics.h"
#import "CoreLyrics/CoreLyricsDiagnostics.h"

NSArray<NSString *> *LyricBridgeDiagnosticRoots(void) {
    NSMutableArray *roots = [NSMutableArray arrayWithArray:@[@"/var/mobile/Library/CoreLyrics", @"/var/jb/var/mobile/Library/CoreLyrics"]];
    Class cls = NSClassFromString(@"LSApplicationProxy");
    if ([cls respondsToSelector:@selector(applicationProxyForIdentifier:)]) {
        id proxy = [cls performSelector:@selector(applicationProxyForIdentifier:) withObject:@"com.apple.Music"];
        NSURL *container = [proxy respondsToSelector:@selector(dataContainerURL)] ? [proxy performSelector:@selector(dataContainerURL)] : nil;
        if (container.isFileURL) [roots addObject:[container.path stringByAppendingPathComponent:@"Library/CoreLyrics"]];
    }
    NSMutableOrderedSet *resolved = [NSMutableOrderedSet new];
    for (NSString *root in roots) [resolved addObject:root.stringByResolvingSymlinksInPath];
    return resolved.array;
}
NSArray<NSURL *> *LyricBridgeDiagnosticFiles(void) {
    NSMutableArray *files = [NSMutableArray new];
    for (NSString *root in LyricBridgeDiagnosticRoots()) {
        for (NSString *filename in CLDiagnosticFilenames()) {
            NSString *path = [root stringByAppendingPathComponent:filename];
            NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
            if ([attrs.fileType isEqual:NSFileTypeRegular]) [files addObject:[NSURL fileURLWithPath:path]];
        }
    }
    return files;
}
void LyricBridgeClearDiagnosticLogs(void) {
    for (NSString *root in LyricBridgeDiagnosticRoots()) CLDiagnosticClear(root);
}
static void LyricBridgeShareURLs(UIViewController *presenter, NSArray<NSURL *> *files, NSURL *cleanup) {
    if (!files.count) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"No Logs Yet" message:@"Enable logging, then reproduce the issue in Music." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        if (cleanup) [NSFileManager.defaultManager removeItemAtURL:cleanup error:nil];
        [presenter presentViewController:alert animated:YES completion:nil]; return;
    }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:files applicationActivities:nil];
    share.popoverPresentationController.sourceView = presenter.view;
    share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(presenter.view.bounds), CGRectGetMaxY(presenter.view.bounds)-1, 1, 1);
    share.completionWithItemsHandler = ^(UIActivityType type, BOOL completed, NSArray *items, NSError *error) { if (cleanup) [NSFileManager.defaultManager removeItemAtURL:cleanup error:nil]; };
    [presenter presentViewController:share animated:YES completion:nil];
}
void LyricBridgeExportDiagnosticLogs(UIViewController *presenter) {
    __weak UIViewController *weakPresenter = presenter;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray *files = LyricBridgeDiagnosticFiles();
        NSURL *folder = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[@"LyricBridge-export-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *destination = [folder URLByAppendingPathComponent:@"LyricBridge-diagnostics.log"];
        [NSFileManager.defaultManager createFileAtPath:destination.path contents:nil attributes:@{NSFilePosixPermissions:@0600}];
        NSFileHandle *output = [NSFileHandle fileHandleForWritingToURL:destination error:nil];
        BOOL wrote = NO;
        @try {
            for (NSURL *url in files) {
                int lock = CLDiagnosticLock(url.path.stringByDeletingLastPathComponent);
                if (lock < 0) continue;
                NSFileHandle *input = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
                @try {
                    if (input && output) {
                        [output writeData:[[NSString stringWithFormat:@"--- %@ ---\n", url.lastPathComponent] dataUsingEncoding:NSUTF8StringEncoding]];
                        NSData *chunk;
                        while ((chunk = [input readDataOfLength:64*1024]).length) [output writeData:chunk];
                        [output writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
                        wrote = YES;
                    }
                } @finally { [input closeFile]; CLDiagnosticUnlock(lock); }
            }
        } @catch (__unused NSException *exception) { wrote = NO; }
        @finally { [output closeFile]; }
        NSArray *copies = wrote ? @[destination] : @[];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakPresenter) LyricBridgeShareURLs(weakPresenter, copies, folder);
            else [NSFileManager.defaultManager removeItemAtURL:folder error:nil];
        });
    });
}
static NSString *LyricBridgeLogTail(NSURL *url) {
    NSFileHandle *file = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    if (!file) return @"";
    NSData *data;
    @try {
        unsigned long long size = [file seekToEndOfFile];
        unsigned long long start = size > 1024*1024 ? size-1024*1024 : 0;
        [file seekToFileOffset:start]; data = [file readDataToEndOfFile];
        if (start) {
            const uint8_t *bytes = data.bytes; NSUInteger offset = 0;
            while (offset < data.length && bytes[offset++] != '\n') {}
            data = [data subdataWithRange:NSMakeRange(offset, data.length-offset)];
        }
    } @catch (__unused NSException *exception) { data = nil; }
    @finally { [file closeFile]; }
    return [[NSString alloc] initWithData:data ?: NSData.data encoding:NSUTF8StringEncoding] ?: @"";
}
@interface LyricBridgeLogController ()
@property(strong) UITextView *textView;
@property NSUInteger refreshGeneration;
@end
@implementation LyricBridgeLogController
- (void)loadView {
    self.textView = [UITextView new]; self.textView.editable = NO; self.textView.selectable = YES;
    self.textView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.textView.backgroundColor = UIColor.systemBackgroundColor; self.textView.textColor = UIColor.labelColor;
    self.view = self.textView;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"Diagnostics";
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refreshLog)],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:self action:@selector(exportLog)],
        [[UIBarButtonItem alloc] initWithTitle:@"Copy" style:UIBarButtonItemStylePlain target:self action:@selector(copyLog)]];
    [self loadLog];
}
- (void)refreshLog {
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [self loadLog];
}
- (void)loadLog {
    NSUInteger generation = ++self.refreshGeneration;
    NSArray *files = LyricBridgeDiagnosticFiles();
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableArray *sections = [NSMutableArray new];
        for (NSURL *url in files) { NSString *text = LyricBridgeLogTail(url); if (text.length) [sections addObject:[NSString stringWithFormat:@"--- %@ ---\n%@", url.lastPathComponent, text]]; }
        NSString *text = [sections componentsJoinedByString:@"\n\n"];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) controller = weakSelf;
            if (!controller || generation != controller.refreshGeneration) return;
            controller.textView.text = text.length ? [@"Recent entries shown; exports include complete logs.\n\n" stringByAppendingString:text] : @"No log entries yet.";
        });
    });
}
- (void)copyLog {
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    UIPasteboard.generalPasteboard.string = self.textView.text;
}
- (void)exportLog {
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    LyricBridgeExportDiagnosticLogs(self);
}
@end
