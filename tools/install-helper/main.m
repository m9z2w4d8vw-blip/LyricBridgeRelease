#import <Foundation/Foundation.h>
#include <grp.h>
#include <unistd.h>

static BOOL LyricBridgeResetDiagnosticPreferences(CFStringRef domain) {
    CFPreferencesSetAppValue(CFSTR("DebugLogging"), kCFBooleanFalse, domain);
    CFPreferencesSetAppValue(CFSTR("PerformanceLogging"), kCFBooleanFalse, domain);
    return CFPreferencesAppSynchronize(domain);
}

int main(void) {
    // use mobile's preference service; root has a separate preference domain.
    if (geteuid() == 0 && (initgroups("mobile", 501) != 0 || setgid(501) != 0 || setuid(501) != 0)) return 1;
    if (geteuid() != 501) return 1;
    @autoreleasepool {
        for (NSString *root in @[@"/var/jb/var/mobile/Library/Preferences", @"/var/mobile/Library/Preferences"]) {
            NSString *path = [root stringByAppendingPathComponent:@"com.shalamand3r.lyricbridge.plist"];
            NSMutableDictionary *saved = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy];
            if (!saved) continue;
            saved[@"DebugLogging"] = @NO; saved[@"PerformanceLogging"] = @NO;
            if (![saved writeToFile:path atomically:YES]) return 1;
        }
        if (!LyricBridgeResetDiagnosticPreferences(CFSTR("com.shalamand3r.lyricbridge"))) return 1;
        for (NSString *name in @[@"com.shalamand3r.lyricbridge/ReloadPrefs", @"com.shalamand3r.corelyrics/ReloadPrefs"])
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)name, NULL, NULL, YES);
        return 0;
    }
}
