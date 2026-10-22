#pragma once
#import <Foundation/Foundation.h>

static inline NSArray<NSDictionary<NSString *, NSString *> *> *DateLyricsProviderDefinitions(void) {
    static NSArray *definitions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        definitions = @[
            @{@"key": @"musixmatch", @"name": @"Musixmatch", @"detail": @"Line-by-line or word-by-word lyrics", @"symbol": @"globe"},
            @{@"key": @"lrclib", @"name": @"LRCLIB", @"detail": @"Line-by-line lyrics", @"symbol": @"bolt.fill"},
            @{@"key": @"megalobiz", @"name": @"Megalobiz", @"detail": @"Community synchronized lyrics & leaks", @"symbol": @"waveform"},
            @{@"key": @"netease", @"name": @"NetEase Cloud Music", @"detail": @"Line-by-line or word-by-word lyrics", @"symbol": @"cloud.fill"},
            @{@"key": @"qqmusic", @"name": @"QQ Music", @"detail": @"Line-by-line or word-by-word lyrics", @"symbol": @"music.note.list"}
        ];
    });
    return definitions;
}

static inline NSArray<NSString *> *DateLyricsDefaultProviderOrder(void) {
    static NSArray *order;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ order = [DateLyricsProviderDefinitions() valueForKey:@"key"]; });
    return order;
}

static inline NSDictionary<NSString *, NSString *> *DateLyricsProviderDefinition(NSString *key) {
    for (NSDictionary *definition in DateLyricsProviderDefinitions()) {
        if ([definition[@"key"] isEqualToString:key]) return definition;
    }
    return nil;
}

// settings and the runtime must agree on the supported keys and their fallback
// order. discard stale/invalid entries, deduplicate, then append new providers.
static inline NSArray<NSString *> *DateLyricsSanitizedProviderOrder(id saved) {
    NSArray<NSString *> *known = DateLyricsDefaultProviderOrder();
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    if ([saved isKindOfClass:NSArray.class]) {
        for (id key in saved) {
            if ([known containsObject:key] && ![result containsObject:key]) [result addObject:key];
        }
    }
    for (NSString *key in known) {
        if (![result containsObject:key]) [result addObject:key];
    }
    return [result copy];
}

static inline BOOL DateLyricsProviderHasWordTiming(NSString *provider) {
    return [@[@"musixmatch", @"qqmusic", @"netease"] containsObject:provider];
}
