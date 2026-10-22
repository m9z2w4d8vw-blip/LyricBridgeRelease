#pragma once
#import <Foundation/Foundation.h>

static inline NSDictionary *DLLyricsSavedPreferences(NSString *domain) {
    NSString *filename = [domain stringByAppendingString:@".plist"];
    for (NSString *root in @[@"/var/jb/var/mobile/Library/Preferences", @"/var/mobile/Library/Preferences"]) {
        NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:[root stringByAppendingPathComponent:filename]];
        if (saved) return saved;
    }
    return nil;
}

static inline id DLLyricsPreferenceValue(NSString *domain, NSString *key, NSDictionary *saved) {
    // music may receive no value from cfprefsd for a tweak's domain.
    id value = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)domain));
    return value ?: saved[key];
}
