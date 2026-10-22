#pragma once
#import <Foundation/Foundation.h>

// tokens, diagnostics and unrelated files are never lyric-cache entries.
static inline BOOL DLLyricsIsCacheFilename(NSString *name) {
    if (!name.length || [name hasPrefix:@"."]) return NO;
    if (name.length == 69 && [name hasSuffix:@".json"] &&
        [[name substringToIndex:64] rangeOfCharacterFromSet:
            [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet].location == NSNotFound) return YES;
    if ([name hasPrefix:@"score-"] && ([name hasSuffix:@".json"] || [name hasSuffix:@".tmp"])) return YES;
    return ([name hasPrefix:@"syllable-lyrics_"] && [name hasSuffix:@".xml"]) || [name hasSuffix:@".lrc"];
}
