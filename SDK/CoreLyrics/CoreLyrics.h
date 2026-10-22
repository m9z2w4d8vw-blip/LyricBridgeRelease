#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DLLyricsTrack : NSObject <NSCopying>
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy) NSString *album;
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic) NSInteger catalogID;
@property (nonatomic) BOOL hasNativeLineTiming;
@property (nonatomic, readonly) NSString *cacheKey;
+ (instancetype)trackWithTitle:(NSString *)title artist:(NSString *)artist duration:(NSTimeInterval)duration;
@end

@interface DLLyricsResult : NSObject
@property (nonatomic, copy, readonly) NSArray<NSDictionary *> *lines;
@property (nonatomic, copy, readonly) NSString *provider;
@property (nonatomic, readonly) BOOL hasWordTiming;
@property (nonatomic, readonly) BOOL relaxedMatch;
@property (nonatomic, readonly) BOOL savedOffline;
- (NSData *)TTMLData;
@end

// each client owns its subscription. cancelling one does not cancel another client.
@interface DLLyricsSubscription : NSObject
- (void)cancel;
@end

typedef void (^DLLyricsUpdate)(DLLyricsResult * _Nullable result, BOOL finished, NSError * _Nullable error);

@interface DLLyricsEngine : NSObject
+ (instancetype)sharedEngine;
// callbacks arrive on main. lines may arrive before a later word-timing upgrade.
- (DLLyricsSubscription *)fetchTrack:(DLLyricsTrack *)track client:(NSString *)client update:(DLLyricsUpdate)update;
- (void)cachedTrack:(DLLyricsTrack *)track completion:(void (^)(DLLyricsResult * _Nullable))completion;
// adopt validated existing downloads during a client upgrade without refetching.
- (void)importCachedLines:(NSArray<NSDictionary *> *)lines forTrack:(DLLyricsTrack *)track relaxedMatch:(BOOL)relaxed;
- (void)setSavedOffline:(BOOL)saved forTrack:(DLLyricsTrack *)track completion:(void (^)(BOOL))completion;
- (void)clearCacheKeepingSaved:(BOOL)keepSaved completion:(dispatch_block_t)completion;
// uses the same provider keys, order, matching and timeout settings as datelyrics.
- (void)reloadPreferences;
@end

// convenient corelyrics aliases
typedef DLLyricsTrack CLLyricsTrack;
typedef DLLyricsResult CLLyricsResult;
typedef DLLyricsSubscription CLLyricsSubscription;
typedef DLLyricsEngine CLLyricsEngine;
typedef DLLyricsUpdate CLLyricsUpdate;

NS_ASSUME_NONNULL_END
