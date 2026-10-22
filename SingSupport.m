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
    singLog(atomic_load(&singHooksReady) ? @"Sing hooks ready" : @"Sing hooks unavailable");
}
static atomic_bool hasControl;
static BOOL (*originalSupport)(id, SEL);
static id (*originalControl)(id, SEL);
static void (*originalHidden)(id, SEL, BOOL);
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
}
