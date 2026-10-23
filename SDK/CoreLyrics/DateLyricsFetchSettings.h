#pragma once
#import <Foundation/Foundation.h>
#import <math.h>

// preserve the unlimited sentinel used by earlier slider settings.
static const NSInteger DateLyricsUnlimitedRequestTimeout = 21;
static const NSInteger DateLyricsDefaultRequestTimeout = 15;
static const NSInteger DateLyricsShortRequestTimeout = 5;
static const NSInteger DateLyricsLongRequestTimeout = 15;

static inline NSInteger DateLyricsSanitizedRequestTimeout(id saved) {
    if (![saved isKindOfClass:NSNumber.class]) return DateLyricsDefaultRequestTimeout;
    double value = [saved doubleValue];
    if (!isfinite(value)) return DateLyricsDefaultRequestTimeout;
    if (value <= 0.0) return DateLyricsDefaultRequestTimeout;
    // check bounds before rounding untrusted preference values.
    if (value >= 20.0 || value == 16.0) return DateLyricsUnlimitedRequestTimeout;
    return value < 7.5 ? DateLyricsShortRequestTimeout : DateLyricsLongRequestTimeout;
}

static inline NSString *DateLyricsRequestTimeoutLabel(NSInteger value) {
    return value == DateLyricsUnlimitedRequestTimeout ? @"No Limit" : [NSString stringWithFormat:@"%lds", (long)value];
}

static inline BOOL DateLyricsSourceAllowedForMatchMode(NSString *source, BOOL relaxed) {
    return relaxed || ![source isEqualToString:@"musixmatch-relaxed"];
}
