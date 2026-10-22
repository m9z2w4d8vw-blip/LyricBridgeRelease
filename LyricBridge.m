#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <ptrauth.h>
#import <substrate.h>
#import <stdatomic.h>
#import "CoreLyrics/CoreLyrics.h"
#import "CoreLyrics/LyricsPreferences.h"
#import "SingSupport.h"
#import "CoreLyrics/CoreLyricsDiagnostics.h"
#import <QuartzCore/QuartzCore.h>

typedef void * __attribute__((swiftcall)) (*NLModelInit)(uintptr_t, uintptr_t, void *, void * __attribute__((swift_context)));
typedef BOOL __attribute__((swiftcall)) (*NLSupportsSong)(void *, void * __attribute__((swift_context)));
typedef void __attribute__((swiftcall)) (*NLLoadLyrics)(void *, void *, void *, void * __attribute__((swift_context)));
typedef void __attribute__((swiftcall)) (*NLCompleteLyrics)(void *, uintptr_t, uint8_t, void *, void * __attribute__((swift_context)));
typedef void * __attribute__((swiftcall)) (*NLGetLyrics)(void * __attribute__((swift_context)));
typedef void __attribute__((swiftcall)) (*NLSetLyrics)(void *, void * __attribute__((swift_context)));
static NLSupportsSong originalSupports;
static NLLoadLyrics originalLoad;
static NLModelInit createModel;
static NLGetLyrics getLyrics;
static NLSetLyrics setLyrics;
typedef uint8_t __attribute__((swiftcall)) (*NLLyricsType)(void * __attribute__((swift_context)));
static NLLyricsType lyricsType;
static void (*originalLyricsDidAppear)(id, SEL, BOOL);
static void *(*retainSwift)(void *);
static void (*releaseSwift)(void *);
static atomic_bool enabled = true;
static atomic_bool keepOffline;
static atomic_bool diagnostics;
static atomic_bool performanceLogging;
static NSMutableDictionary<NSValue *, id> *pending;
static NSMutableDictionary<NSString *, NSDate *> *negativeResults;
typedef void (*NLGetPlaybackInfo)(dispatch_queue_t, void (^)(CFDictionaryRef));
static NLGetPlaybackInfo getPlaybackInfo;
static NSObject *playbackLock;
static NSDictionary *playbackInfo;
static NSUInteger playbackGeneration;
static id songObserver;

static void NLWriteLog(NSString *message);
#define NLLog(...) do { if (atomic_load(&diagnostics)) NLWriteLog(__VA_ARGS__); } while (0)
static NSDictionary *NLPlaybackSnapshot(void) {
    @synchronized (playbackLock) { return playbackInfo; }
}
static BOOL NLPlaybackMatches(NSDictionary *info, NSString *title, NSString *artist) {
    id playingTitle = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
    id playingArtist = info[@"kMRMediaRemoteNowPlayingInfoArtist"];
    return [playingTitle isKindOfClass:NSString.class] && [playingArtist isKindOfClass:NSString.class] &&
        [title isKindOfClass:NSString.class] && [artist isKindOfClass:NSString.class] && title.length && artist.length &&
        [playingTitle caseInsensitiveCompare:title] == NSOrderedSame &&
        [playingArtist caseInsensitiveCompare:artist] == NSOrderedSame;
}
static double NLPlaybackDuration(NSDictionary *info) {
    id value = info[@"kMRMediaRemoteNowPlayingInfoDuration"];
    double duration = [value isKindOfClass:NSNumber.class] ? [value doubleValue] : 0;
    return isfinite(duration) && duration > 0 ? duration : 0;
}
static DLLyricsTrack *NLPlaybackTrack(NSDictionary *info) {
    id title = info[@"kMRMediaRemoteNowPlayingInfoTitle"], artist = info[@"kMRMediaRemoteNowPlayingInfoArtist"];
    if (!NLPlaybackMatches(info, title, artist)) return nil;
    DLLyricsTrack *track = [DLLyricsTrack trackWithTitle:title artist:artist duration:NLPlaybackDuration(info)];
    id album = info[@"kMRMediaRemoteNowPlayingInfoAlbum"];
    if ([album isKindOfClass:NSString.class]) track.album = album;
    return track;
}
static void NLReadPlaybackInfo(void (^completion)(NSDictionary *)) {
    if (!getPlaybackInfo) { NLLog(@"Metadata API unavailable"); completion(nil); return; }
    NSUInteger generation = playbackGeneration;
    __block BOOL finished = NO;
    void (^finish)(NSDictionary *) = ^(NSDictionary *info) {
        if (finished) return;
        finished = YES;
        if (generation != playbackGeneration) { NLLog(@"Discarded stale metadata response"); completion(nil); return; }
        if (info) {
            @synchronized (playbackLock) { playbackInfo = [info copy]; }
        }
        NLLog([NSString stringWithFormat:@"Metadata response: available=%d duration=%.3f", info != nil, NLPlaybackDuration(info)]);
        completion(info);
    };
    // metadata can arrive late; never hold apple's lyric loader indefinitely.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ finish(nil); });
    getPlaybackInfo(dispatch_get_main_queue(), ^(CFDictionaryRef info) {
        finish(info ? (__bridge NSDictionary *)info : nil);
    });
}

static NSString *NLDiagnosticRoot(void) { return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/CoreLyrics"]; }
static void NLWriteLog(NSString *message) { CLDiagnosticAppend(NLDiagnosticRoot(), @"LyricBridge", NO, message); }
static void NLPerformance(NSString *event, CFTimeInterval started) {
    if (!atomic_load(&performanceLogging)) return;
    CLDiagnosticAppend(NLDiagnosticRoot(), @"LyricBridge", YES,
        [NSString stringWithFormat:@"event=%@ seconds=%.3f", event, started > 0 ? CACurrentMediaTime() - started : 0]);
}
static id NLObject(id object, NSString *property) {
    Method method = class_getInstanceMethod([object class], NSSelectorFromString(property));
    char type[16] = {0}; if (method) method_getReturnType(method, type, sizeof(type));
    @try { return type[0] == '@' ? ((id (*)(id, SEL))objc_msgSend)(object, NSSelectorFromString(property)) : nil; }
    @catch (__unused NSException *exception) { return nil; }
}
static double NLDuration(id song) {
    @try {
        id value = [song valueForKey:@"duration"];
        double duration = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0;
        return isfinite(duration) && duration > 0 ? duration : 0;
    } @catch (__unused NSException *exception) { return 0; }
}
static BOOL NLHasTimedAppleLyrics(id song) {
    id lyrics = NLObject(song, @"lyrics");
    if (!lyrics) return NO;
    Method method = class_getInstanceMethod([lyrics class], NSSelectorFromString(@"hasTimeSyncedLyrics"));
    char type[16] = {0}; if (method) method_getReturnType(method, type, sizeof(type));
    if (type[0] != 'B' && type[0] != 'c') return YES;
    return ((BOOL (*)(id, SEL))objc_msgSend)(lyrics, NSSelectorFromString(@"hasTimeSyncedLyrics"));
}
static DLLyricsTrack *NLTrack(id song) {
    NSString *title = NLObject(song, @"title"), *artist = NLObject(NLObject(song, @"artist"), @"name");
    if (![title isKindOfClass:NSString.class] || ![artist isKindOfClass:NSString.class] || !title.length || !artist.length) return nil;
    double duration = NLDuration(song);
    NSDictionary *info = NLPlaybackSnapshot();
    if (duration <= 0 && NLPlaybackMatches(info, title, artist)) duration = NLPlaybackDuration(info);
    DLLyricsTrack *track = [DLLyricsTrack trackWithTitle:title artist:artist duration:duration];
    NSString *album = NLObject(NLObject(song, @"album"), @"title");
    if ([album isKindOfClass:NSString.class]) track.album = album;
    return track;
}
static id NLModel(DLLyricsResult *result) {
    CFTimeInterval started = atomic_load(&performanceLogging) ? CACurrentMediaTime() : 0;
    Class parserClass = NSClassFromString(@"MSVLyricsTTMLParser");
    Class modelClass = NSClassFromString(@"_TtC11MusicCoreUI6Lyrics") ?: NSClassFromString(@"MusicCoreUI.Lyrics");
    if (!createModel || !parserClass || !modelClass || class_getInstanceSize(modelClass) == 0) return nil;
    @try {
        id parser = ((id (*)(id, SEL, id))objc_msgSend)([parserClass alloc], NSSelectorFromString(@"initWithTTMLData:"), result.TTMLData);
        NSError *error = nil;
        id info = ((id (*)(id, SEL, NSError **))objc_msgSend)(parser, NSSelectorFromString(@"parseWithError:"), &error);
        if (!info || error || ![NLObject(info, @"lyricsLines") count]) { NLLog(@"Native TTML parser rejected result"); return nil; }
        NLPerformance(@"parse-ttml", started);
        return CFBridgingRelease(createModel(0, 0, (void *)CFBridgingRetain(info), (__bridge void *)modelClass));
    } @catch (NSException *exception) { NLLog(@"Native model exception"); return nil; }
}
@interface NLRequest : NSObject
@property (nonatomic, strong) id song;
@property (nonatomic, strong) DLLyricsTrack *track;
@property (nonatomic, strong) DLLyricsSubscription *subscription;
@property (nonatomic, strong) id displayedModel;
@property (nonatomic, strong) DLLyricsResult *displayedResult;
@property (nonatomic) void *callback;
@property (nonatomic) void *context;
@property (nonatomic, strong) id loaderObject;
@property (nonatomic, readonly) void *loader;
@property (nonatomic) BOOL completed;
@property (nonatomic) BOOL lookupFinished;
@property (nonatomic) NSUInteger lookupGeneration;
@property (nonatomic, strong) id pendingUpgrade;
@property (nonatomic) BOOL preservingAppleLyrics;
@property (nonatomic, weak) UIViewController *viewer;
- (BOOL)isCurrent;
- (void)forwardOriginal;
@end
@implementation NLRequest
- (void *)loader { return (__bridge void *)self.loaderObject; }
- (BOOL)isCurrent { return atomic_load(&enabled) && pending[[NSValue valueWithPointer:self.loader]] == self; }
- (void)forwardOriginal {
    if (self.completed) return;
    self.completed = YES;
    originalLoad((__bridge void *)self.song, self.callback, self.context, self.loader);
}
- (void)dealloc {
    [self.subscription cancel];
    if (_context) releaseSwift(_context);
}
@end
static NSArray<UIViewController *> *NLControllers(void) {
    NSMutableArray *queue = [NSMutableArray array], *result = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.rootViewController) [queue addObject:window.rootViewController];
        }
    }
    while (queue.count && result.count < 150) {
        UIViewController *controller = queue.firstObject; [queue removeObjectAtIndex:0];
        if ([result containsObject:controller]) continue;
        [result addObject:controller]; [queue addObjectsFromArray:controller.childViewControllers];
        if (controller.presentedViewController) [queue addObject:controller.presentedViewController];
    }
    return result;
}
static BOOL NLUpgrade(NLRequest *request, id model) {
    if (!getLyrics || !setLyrics || ![request isCurrent]) return NO;
    NSArray *controllers = request.viewer ? @[request.viewer] : NLControllers();
    for (UIViewController *target in controllers) {
        if (![NSStringFromClass(target.class) hasSuffix:@"SyncedLyricsViewController"]) continue;
        id current = CFBridgingRelease(getLyrics((__bridge void *)target));
        // only replace the exact model this request supplied or observed.
        if (!current || current != request.displayedModel) continue;
        setLyrics((void *)CFBridgingRetain(model), (__bridge void *)target);
        request.viewer = target;
        request.displayedModel = model;
        request.pendingUpgrade = nil;
        NLLog(@"Upgraded visible lyrics to word timing");
        return YES;
    }
    request.pendingUpgrade = model;
    NLLog(@"Word timing ready; waiting for its lyric viewer");
    return NO;
}
static void NLApplyPendingUpgrades(void) {
    for (NSValue *key in [pending.allKeys copy]) {
        NLRequest *request = pending[key];
        if (request.pendingUpgrade && NLUpgrade(request, request.pendingUpgrade) && request.lookupFinished)
            [pending removeObjectForKey:key];
    }
}
static BOOL __attribute__((swiftcall)) NLSupports(void *song, void * __attribute__((swift_context)) context) {
    BOOL native = originalSupports(song, context);
    if (native || !atomic_load(&enabled)) return native;
    DLLyricsTrack *track = NLTrack((__bridge id)song);
    if (!track) return NO;
    @synchronized (negativeResults) {
        NSDate *until = negativeResults[track.cacheKey];
        if (until && [until timeIntervalSinceNow] > 0) return NO;
    }
    return YES;
}
static void NLBeginFetch(NLRequest *request, NSValue *key) {
    NLLog([NSString stringWithFormat:@"Lookup: generation=%lu duration=%.3f preservingApple=%d", (unsigned long)request.lookupGeneration, request.track.duration, request.preservingAppleLyrics]);
    CFTimeInterval started = atomic_load(&performanceLogging) ? CACurrentMediaTime() : 0;
    NSUInteger generation = request.lookupGeneration;
    __weak NLRequest *weakRequest = request;
    request.subscription = [DLLyricsEngine.sharedEngine fetchTrack:request.track client:@"LyricBridge" update:^(DLLyricsResult *result, BOOL finished, NSError *error) {
        NLRequest *active = weakRequest;
        if (!active || ![active isCurrent] || active.lookupGeneration != generation) return;
        NLLog([NSString stringWithFormat:@"Result: provider=%@ lines=%lu words=%d finished=%d errorCode=%ld", result.provider, (unsigned long)result.lines.count, result.hasWordTiming, finished, (long)error.code]);
        if (result) NLPerformance(result.hasWordTiming ? @"word-result" : @"line-result", started);
        if (finished) NLPerformance(@"lookup-finished", started);
        BOOL usable = result && (!active.preservingAppleLyrics || result.hasWordTiming);
        id model = usable && result != active.displayedResult ? NLModel(result) : nil;
        if (model) {
            active.displayedResult = result;
            if (!active.completed) {
                void *plain = ptrauth_auth_and_resign(active.callback, ptrauth_key_function_pointer, 0x23f0, ptrauth_key_function_pointer, 0);
                active.completed = YES; active.displayedModel = model;
                ((NLCompleteLyrics)plain)((__bridge void *)model, 0, 1, NULL, active.context);
                NLLog([NSString stringWithFormat:@"Displayed %@ lyrics: %lu lines, words=%d", result.provider, (unsigned long)result.lines.count, result.hasWordTiming]);
            } else if (result.hasWordTiming && model != active.displayedModel) NLUpgrade(active, model);
            if (atomic_load(&keepOffline) && !result.savedOffline)
                [DLLyricsEngine.sharedEngine setSavedOffline:YES forTrack:active.track completion:^(BOOL saved) {}];
        }
        if (!finished) return;
        if (!active.completed) {
            if (![error.domain isEqualToString:NSURLErrorDomain] || error.code != NSURLErrorCancelled) {
                @synchronized (negativeResults) {
                    if (negativeResults.count > 64) [negativeResults removeAllObjects];
                    negativeResults[active.track.cacheKey] = [NSDate dateWithTimeIntervalSinceNow:30];
                }
            }
            NLLog([NSString stringWithFormat:@"No usable external lyrics: errorCode=%ld", (long)error.code]);
            [active forwardOriginal];
        }
        active.lookupFinished = YES;
        // retain an on-screen line result until late duration metadata can upgrade it.
        if (!active.pendingUpgrade && (active.track.duration > 0 || !active.displayedModel || active.displayedResult.hasWordTiming))
            [pending removeObjectForKey:key];
    }];
}
static void NLFetchRequest(NLRequest *request, NSValue *key) {
    NSUInteger generation = ++request.lookupGeneration;
    [request.subscription cancel]; request.subscription = nil;
    request.lookupFinished = NO;
    if (request.track.duration > 0) { NLBeginFetch(request, key); return; }
    NLReadPlaybackInfo(^(NSDictionary *info) {
        if (![request isCurrent] || request.lookupGeneration != generation) return;
        if (NLPlaybackMatches(info, request.track.title, request.track.artist))
            request.track.duration = NLPlaybackDuration(info);
        NLBeginFetch(request, key);
    });
}
static void __attribute__((swiftcall)) NLLoad(void *song, void *callback, void *context, void * __attribute__((swift_context)) loader) {
    // apple's loader inherits nsobject, first field is a dict not swift refcount
    if (!atomic_load(&enabled) || NLHasTimedAppleLyrics((__bridge id)song)) {
        originalLoad(song, callback, context, loader);
        return;
    }
    NLRequest *request = [NLRequest new]; request.song = (__bridge id)song;
    request.callback = callback; request.context = context ? retainSwift(context) : NULL;
    request.loaderObject = (__bridge id)loader;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSValue *key = [NSValue valueWithPointer:loader];
        NLRequest *old = pending[key]; [old.subscription cancel]; [old forwardOriginal];
        pending[key] = request;
        request.track = NLTrack(request.song);
        if (!atomic_load(&enabled) || !request.track || NLHasTimedAppleLyrics(request.song)) {
            [request forwardOriginal]; [pending removeObjectForKey:key]; return;
        }
        NLFetchRequest(request, key);
    });
}
static void NLObserveAppleLyrics(UIViewController *viewer, id model) {
    if (!atomic_load(&enabled) || !viewer || !model || !lyricsType || !getLyrics) return;
    uint8_t type = lyricsType((__bridge void *)model);
    NLLog([NSString stringWithFormat:@"Apple timing model observed type=%u", type]);
    // lyricstype: 0 = static, 1 = timed lines, 2 = timed words
    if (type != 1) return;
    id current = CFBridgingRelease(getLyrics((__bridge void *)viewer));
    if (current && model && current != model) return;
    for (NLRequest *request in pending.allValues) {
        if (!request.preservingAppleLyrics && request.displayedModel == model && [request isCurrent]) {
            request.viewer = viewer;
            return;
        }
    }
    id song = nil;
    UIViewController *parent = viewer.parentViewController;
    while (parent) {
        if ([NSStringFromClass(parent.class) hasSuffix:@"NowPlayingLyricsViewController"]) {
            Ivar songField = class_getInstanceVariable(parent.class, "song");
            if (songField && ivar_getOffset(songField) > 0) {
                song = object_getIvar(parent, songField);
            }
            break;
        }
        parent = parent.parentViewController;
    }
    if (!song) {
        for (UIViewController *owner in NLControllers()) {
            if (![NSStringFromClass(owner.class) hasSuffix:@"NowPlayingLyricsViewController"]) continue;
            Ivar songField = class_getInstanceVariable(owner.class, "song");
            Ivar viewerField = class_getInstanceVariable(owner.class, "syncedLyricsViewController");
            if (!songField || !viewerField) continue;
            ptrdiff_t songOffset = ivar_getOffset(songField), viewerOffset = ivar_getOffset(viewerField);
            if (songOffset <= 0 || viewerOffset <= 0) continue;
            if (object_getIvar(owner, viewerField) != viewer) continue;
            song = object_getIvar(owner, songField);
            break;
        }
    }
    DLLyricsTrack *track = NLTrack(song);
    if (!track) track = NLPlaybackTrack(NLPlaybackSnapshot());
    if (!track) {
        __weak UIViewController *waitingViewer = viewer;
        NLReadPlaybackInfo(^(NSDictionary *info) {
            if (NLPlaybackTrack(info)) NLObserveAppleLyrics(waitingViewer, model);
        });
        return;
    }
    NSValue *key = [NSValue valueWithPointer:(__bridge void *)viewer];
    NLRequest *old = pending[key];
    if (old.displayedModel == model && [old.track.cacheKey isEqualToString:track.cacheKey]) return;
    [old.subscription cancel]; [pending removeObjectForKey:key];
    NLRequest *request = [NLRequest new];
    request.song = song; request.track = track; request.track.hasNativeLineTiming = YES;
    request.completed = YES; request.preservingAppleLyrics = YES;
    request.viewer = viewer; request.loaderObject = viewer; request.displayedModel = model;
    pending[key] = request;
    NLFetchRequest(request, key);
}
static void __attribute__((swiftcall)) NLSetLyricsObserved(void *value, void * __attribute__((swift_context)) controller) {
    id model = (__bridge id)value;
    __weak UIViewController *viewer = (__bridge id)controller;
    setLyrics(value, controller);
    dispatch_async(dispatch_get_main_queue(), ^{ NLApplyPendingUpgrades(); NLObserveAppleLyrics(viewer, model); });
}
static void NLLyricsDidAppear(id controller, SEL selector, BOOL animated) {
    originalLyricsDidAppear(controller, selector, animated);
    NLApplyPendingUpgrades();
    id model = getLyrics ? CFBridgingRelease(getLyrics((__bridge void *)controller)) : nil;
    NLObserveAppleLyrics(controller, model);
}
static BOOL NLPreference(NSString *key, BOOL fallback, NSDictionary *saved) {
    id value = DLLyricsPreferenceValue(@"com.shalamand3r.lyricbridge", key, saved);
    return [value isKindOfClass:NSNumber.class] ? [value boolValue] : fallback;
}
static void NLSongChanged(NSDictionary *info) {
    NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"], *artist = info[@"kMRMediaRemoteNowPlayingInfoArtist"];
    if (![title isKindOfClass:NSString.class] || ![artist isKindOfClass:NSString.class]) return;
    if (!title.length || !artist.length) return;
    for (NSValue *key in [pending.allKeys copy]) {
        NLRequest *request = pending[key];
        if ([request.track.title caseInsensitiveCompare:title] == NSOrderedSame &&
            [request.track.artist caseInsensitiveCompare:artist] == NSOrderedSame) {
            double duration = NLPlaybackDuration(info);
            if (request.track.duration <= 0 && duration > 0) {
                request.track.duration = duration;
                NLLog([NSString stringWithFormat:@"Late playback duration: %.3f; retrying current lyric upgrade", duration]);
                NLFetchRequest(request, key);
            }
            continue;
        }
        [request.subscription cancel];
        [request forwardOriginal];
        [pending removeObjectForKey:key];
        NLLog(@"Cancelled external request after song changed");
    }
}
static void NLClearCache(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (NLRequest *request in pending.allValues) { [request.subscription cancel]; [request forwardOriginal]; }
        [pending removeAllObjects];
        @synchronized (negativeResults) { [negativeResults removeAllObjects]; }
    });
}
static void NLReload(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    NSDictionary *saved = DLLyricsSavedPreferences(@"com.shalamand3r.lyricbridge");
    atomic_store(&enabled, NLPreference(@"Enabled", YES, saved));
    atomic_store(&keepOffline, NLPreference(@"KeepOffline", NO, saved));
    atomic_store(&diagnostics, NLPreference(@"DebugLogging", NO, saved));
    atomic_store(&performanceLogging, NLPreference(@"PerformanceLogging", NO, saved));
    NLSingSetLoggingEnabled(atomic_load(&diagnostics));
    NLSingSetEnabled(atomic_load(&enabled) && NLPreference(@"EnableSing", YES, saved));
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!atomic_load(&enabled)) {
            for (NLRequest *request in pending.allValues) { [request.subscription cancel]; [request forwardOriginal]; }
            [pending removeAllObjects];
        }
        @synchronized (negativeResults) { [negativeResults removeAllObjects]; }
    });
}
static void *NLBranchDestination(void *symbol) {
    void *plain = ptrauth_strip(symbol, ptrauth_key_function_pointer);
    uint32_t instruction = *(uint32_t *)plain;
    if ((instruction & 0xfc000000) != 0x14000000) return NULL;
    int64_t offset = ((int64_t)(int32_t)(instruction << 6)) >> 4;
    return ptrauth_sign_unauthenticated((uint8_t *)plain + offset, ptrauth_key_function_pointer, 0);
}
__attribute__((constructor)) static void NLStart(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.Music"]) return;
        playbackLock = [NSObject new];
        negativeResults = [NSMutableDictionary dictionary];
        NSDictionary *saved = DLLyricsSavedPreferences(@"com.shalamand3r.lyricbridge");
        atomic_store(&diagnostics, NLPreference(@"DebugLogging", NO, saved));
        NLLog(@"LyricBridge startup entered");
        NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
        if (version.majorVersion < 16 || (version.majorVersion == 16 && version.minorVersion < 2)) {
            NLLog([NSString stringWithFormat:@"Unsupported iOS version: %ld.%ld", (long)version.majorVersion, (long)version.minorVersion]);
            return;
        }
        pending = [NSMutableDictionary dictionary];
        NLSingStart();
        NLReload(NULL, NULL, NULL, NULL, NULL);
        retainSwift = dlsym(RTLD_DEFAULT, "swift_retain"); releaseSwift = dlsym(RTLD_DEFAULT, "swift_release");
        createModel = (NLModelInit)dlsym(RTLD_DEFAULT, "$s11MusicCoreUI6LyricsC10identifier8songInfoACSSSg_So013MSVLyricsSongG0CtcfC");
        getLyrics = (NLGetLyrics)dlsym(RTLD_DEFAULT, "$s11MusicCoreUI26SyncedLyricsViewControllerC6lyricsAA0E0CSgvg");
        setLyrics = (NLSetLyrics)dlsym(RTLD_DEFAULT, "$s11MusicCoreUI26SyncedLyricsViewControllerC6lyricsAA0E0CSgvs");
        lyricsType = (NLLyricsType)dlsym(RTLD_DEFAULT, "$s11MusicCoreUI6LyricsC4typeAC0D4TypeOvg");
        void *supports = dlsym(RTLD_DEFAULT, "$s11MusicCoreUI12LyricsLoaderC08supportsD03forSbSo11MPModelSongC_tFZ");
        void *load = dlsym(RTLD_DEFAULT, "$s11MusicCoreUI12LyricsLoaderC04loadD03for10completionySo11MPModelSongC_yAC6ResultOSg_s5Error_pSgtctF");
        void *body = supports ? NLBranchDestination(supports) : NULL;
        NLLog([NSString stringWithFormat:@"Symbol check: supports=%d body=%d load=%d model=%d retain=%d release=%d",
               supports != NULL, body != NULL, load != NULL, createModel != NULL, retainSwift != NULL, releaseSwift != NULL]);
        if (!body || !load || !createModel || !retainSwift || !releaseSwift) {
            NLLog(@"Hook startup stopped: required MusicCoreUI symbol unavailable");
            return;
        }
        MSHookFunction(load, (void *)NLLoad, (void **)&originalLoad);
        if (!originalLoad) { NLLog(@"Hook startup stopped: load hook installation failed"); return; }
        MSHookFunction(body, (void *)NLSupports, (void **)&originalSupports);
        if (setLyrics && getLyrics && lyricsType)
            MSHookFunction((void *)setLyrics, (void *)NLSetLyricsObserved, (void **)&setLyrics);
        if (getLyrics && lyricsType)
            MSHookMessageEx(NSClassFromString(@"_TtC11MusicCoreUI26SyncedLyricsViewController"), @selector(viewDidAppear:), (IMP)NLLyricsDidAppear, (IMP *)&originalLyricsDidAppear);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, NLReload, CFSTR("com.shalamand3r.lyricbridge/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, NLReload, CFSTR("com.shalamand3r.corelyrics/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, NLReload, CFSTR("com.shalamand3r.datelyrics/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, NLClearCache, CFSTR("com.shalamand3r.corelyrics/ClearCaches"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, NLClearCache, CFSTR("com.shalamand3r.datelyrics/ClearCaches"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        dispatch_async(dispatch_get_main_queue(), ^{
            void *mediaRemote = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
            getPlaybackInfo = (NLGetPlaybackInfo)dlsym(mediaRemote ?: RTLD_DEFAULT, "MRMediaRemoteGetNowPlayingInfo");
            void (*registerNotifications)(dispatch_queue_t) = dlsym(mediaRemote ?: RTLD_DEFAULT, "MRMediaRemoteRegisterForNowPlayingNotifications");
            if (registerNotifications) registerNotifications(dispatch_get_main_queue());
            songObserver = [NSNotificationCenter.defaultCenter addObserverForName:@"kMRMediaRemoteNowPlayingInfoDidChangeNotification" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
                ++playbackGeneration;
                @synchronized (playbackLock) { playbackInfo = nil; }
                NLReadPlaybackInfo(^(NSDictionary *info) { NLSongChanged(info); });
            }];
            NLReadPlaybackInfo(^(NSDictionary *info) { NLSongChanged(info); });
        });
        NLLog(@"LyricBridge loaded; native Apple lyrics retained; automatic external fallback ready");
    }
}
