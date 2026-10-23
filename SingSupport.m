#import "SingSupport.h"
#import "CoreLyrics/CoreLyricsDiagnostics.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <stdatomic.h>

static atomic_bool singEnabled;
static atomic_bool singLogging;
static atomic_bool singHooksReady;
static atomic_int singControlState = -1;
static atomic_int singSupportState = -1;
static atomic_uint_fast64_t singReasonState = UINT64_MAX;
static void singControlLog(int state, NSString *event) {
    if (atomic_load(&singLogging) && atomic_exchange(&singControlState, state) != state)
        CLDiagnosticAppend([NSHomeDirectory() stringByAppendingPathComponent:@"Library/CoreLyrics"], @"LyricBridge", NO, event);
}
static void singLog(NSString *event) {
    if (atomic_load(&singLogging)) CLDiagnosticAppend([NSHomeDirectory() stringByAppendingPathComponent:@"Library/CoreLyrics"], @"LyricBridge", NO, event);
}
void NLSingSetLoggingEnabled(BOOL enabled) {
    atomic_store(&singLogging, enabled);
    atomic_store(&singControlState, -1);
    atomic_store(&singSupportState, -1);
    atomic_store(&singReasonState, UINT64_MAX);
    singLog(atomic_load(&singHooksReady) ? @"Sing hooks ready" : @"Sing hooks unavailable");
}
static atomic_bool hasControl;
static BOOL (*originalSupport)(id, SEL);
static id (*originalControl)(id, SEL);
static void (*originalHidden)(id, SEL, BOOL);
static uint64_t (*originalUnavailableReasons)(id, SEL);
static BOOL (*originalDownloadedAsset)(id, SEL);
static BOOL (*originalShouldAttach)(id, SEL, id);
static __thread void *singAttachmentItem;

// ios 17.0 checks catalog access separately from playback and processor readiness.
static const uint64_t singCatalogAccountUnavailable = 1ULL << 1;
static uint64_t singUnavailableReasons(id publisher, SEL selector) {
    uint64_t native = originalUnavailableReasons(publisher, selector);
    uint64_t effective = atomic_load(&singEnabled) ? native & ~singCatalogAccountUnavailable : native;
    if (atomic_load(&singLogging) && atomic_exchange(&singReasonState, native) != native)
        singLog([NSString stringWithFormat:@"Sing availability reasons native=0x%llx effective=0x%llx", (unsigned long long)native, (unsigned long long)effective]);
    return effective;
}
static BOOL singDownloadedAsset(id item, SEL selector) {
    if (atomic_load(&singEnabled) && singAttachmentItem == (__bridge void *)item) return NO;
    return originalDownloadedAsset(item, selector);
}
static BOOL singShouldAttach(id controller, SEL selector, id item) {
    if (originalShouldAttach(controller, selector, item)) return YES;
    if (!atomic_load(&singEnabled) || ![item isKindOfClass:NSClassFromString(@"MPCModelGenericAVItem")]) return NO;
    SEL assetType = NSSelectorFromString(@"loadedAudioAssetType");
    Method method = class_getInstanceMethod([item class], assetType);
    char type[16] = {0};
    if (method) method_getReturnType(method, type, sizeof(type));
    if (!method || method_getNumberOfArguments(method) != 2 || (type[0] != 'q' && type[0] != 'Q')) return NO;
    NSInteger format = ((NSInteger (*)(id, SEL))objc_msgSend)(item, assetType);
    if (format < 0 || format >= 3 || !originalDownloadedAsset(item, NSSelectorFromString(@"isDownloadedAsset"))) return NO;
    // let the native check enforce readiness, policies and format compatibility.
    void *previous = singAttachmentItem;
    singAttachmentItem = (__bridge void *)item;
    @try {
        BOOL allowed = originalShouldAttach(controller, selector, item);
        if (allowed) singLog(@"Sing local audio attachment enabled");
        return allowed;
    } @finally { singAttachmentItem = previous; }
}

static NSObject *commandLock;
static __weak id cachedList;
static id cachedCommand;

@protocol NLSingCommand <NSObject>
- (instancetype)initWithResponse:(id)response;
- (void)setMinLevel:(float)value;
- (void)setMaxLevel:(float)value;
- (void)setLevel:(float)value;
- (void)setContinuous:(BOOL)value;
@end

static id objectProperty(id value, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    Method method = class_getInstanceMethod([value class], selector);
    char type[16] = {0};
    if (method) method_getReturnType(method, type, sizeof(type));
    if (!method || type[0] != '@' || method_getNumberOfArguments(method) != 2) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(value, selector);
}
static BOOL supportsVocals(id item, SEL selector) {
    BOOL native = originalSupport(item, selector);
    BOOL forced = atomic_load(&singEnabled);
    int state = (native ? 1 : 0) | (forced ? 2 : 0);
    if (atomic_load(&singLogging) && atomic_exchange(&singSupportState, state) != state)
        singLog([NSString stringWithFormat:@"Sing capability native=%d override=%d", native, forced]);
    return native || forced;
}
static id vocalsControl(id list, SEL selector) {
    id native = originalControl(list, selector);
    if (!atomic_load(&singEnabled)) { singControlLog(0, @"Sing using original control; override disabled"); return native; }
    id song = objectProperty(objectProperty(objectProperty(list, @"playingItem"), @"metadataObject"), @"song");
    if (native || !song) {
        singControlLog(native ? 1 : 2, native ? @"Sing native control available" : @"Sing waiting for song metadata");
        atomic_store(&hasControl, native != nil);
        @synchronized (commandLock) { cachedCommand = nil; cachedList = nil; }
        return native;
    }
    @synchronized (commandLock) {
        if (cachedList != list) { cachedCommand = nil; cachedList = list; }
        if (!cachedCommand) {
            Ivar responseIvar = class_getInstanceVariable([list class], "_response");
            const char *type = responseIvar ? ivar_getTypeEncoding(responseIvar) : NULL;
            id response = type && type[0] == '@' ? object_getIvar(list, responseIvar) : nil;
            Class cls = NSClassFromString(@"_MPCVocalsControlCommand");
            if (response && [cls instancesRespondToSelector:@selector(initWithResponse:)]) {
                id<NLSingCommand> command = [[cls alloc] initWithResponse:response];
                [command setMinLevel:0];
                [command setMaxLevel:1];
                [command setLevel:1];
                [command setContinuous:YES];
                cachedCommand = command;
                singControlLog(cachedCommand ? 3 : 4, cachedCommand ? @"Sing fallback command created" : @"Sing fallback command initialization failed");
            } else {
                singControlLog(response ? 5 : 6, response ? @"Sing fallback command class unavailable" : @"Sing waiting for player response");
            }
        }
        atomic_store(&hasControl, cachedCommand != nil);
        return cachedCommand;
    }
}
static void sliderHidden(id slider, SEL selector, BOOL hidden) {
    if (atomic_load(&singEnabled) && atomic_load(&hasControl)) hidden = NO;
    originalHidden(slider, selector, hidden);
}
void NLSingSetEnabled(BOOL enabled) {
    atomic_store(&singEnabled, enabled);
    singLog(enabled ? @"Sing enabled" : @"Sing disabled");
    if (!enabled) {
        atomic_store(&hasControl, false);
        @synchronized (commandLock) { cachedCommand = nil; cachedList = nil; }
    }
}
void NLSingStart(void) {
    commandLock = [NSObject new];
    Class item = NSClassFromString(@"MPCModelGenericAVItem");
    Class list = NSClassFromString(@"MPCPlayerResponseTracklist");
    Class slider = NSClassFromString(@"MusicVocalsAttenuationSlider");
    Method support = class_getInstanceMethod(item, NSSelectorFromString(@"supportsVocalAttenuation"));
    Method control = class_getInstanceMethod(list, NSSelectorFromString(@"vocalsControlCommand"));
    Method hidden = class_getInstanceMethod(slider, @selector(setHidden:));
    if (!support || !control || !hidden ||
        strcmp(method_getTypeEncoding(support), "B16@0:8") ||
        strcmp(method_getTypeEncoding(control), "@16@0:8") ||
        strcmp(method_getTypeEncoding(hidden), "v20@0:8B16")) return;
    MSHookMessageEx(item, NSSelectorFromString(@"supportsVocalAttenuation"), (IMP)supportsVocals, (IMP *)&originalSupport);
    MSHookMessageEx(list, NSSelectorFromString(@"vocalsControlCommand"), (IMP)vocalsControl, (IMP *)&originalControl);
    MSHookMessageEx(slider, @selector(setHidden:), (IMP)sliderHidden, (IMP *)&originalHidden);
    atomic_store(&singHooksReady, originalSupport && originalControl && originalHidden);
    NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
    if (version.majorVersion != 17 || version.minorVersion != 0) return;
    Class publisher = NSClassFromString(@"_MPCMediaRemotePublisher");
    Class whisky = NSClassFromString(@"MPCWhiskyController");
    SEL reasonsSelector = NSSelectorFromString(@"vocalAttenuationUnavailabilityReasons");
    SEL downloadedSelector = NSSelectorFromString(@"isDownloadedAsset");
    SEL attachSelector = NSSelectorFromString(@"shouldAttachAudioTapToItem:");
    Method reasons = class_getInstanceMethod(publisher, reasonsSelector);
    Method downloaded = class_getInstanceMethod(item, downloadedSelector);
    Method attach = class_getInstanceMethod(whisky, attachSelector);
    if (reasons && strcmp(method_getTypeEncoding(reasons), "Q16@0:8") == 0)
        MSHookMessageEx(publisher, reasonsSelector, (IMP)singUnavailableReasons, (IMP *)&originalUnavailableReasons);
    if (downloaded && attach && strcmp(method_getTypeEncoding(downloaded), "B16@0:8") == 0 &&
        strcmp(method_getTypeEncoding(attach), "B24@0:8@16") == 0) {
        MSHookMessageEx(item, downloadedSelector, (IMP)singDownloadedAsset, (IMP *)&originalDownloadedAsset);
        if (originalDownloadedAsset)
            MSHookMessageEx(whisky, attachSelector, (IMP)singShouldAttach, (IMP *)&originalShouldAttach);
    }

}
