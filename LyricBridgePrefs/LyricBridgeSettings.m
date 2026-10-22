#import "CoreLyrics/DateLyricsFetchSettings.h"
#import "CoreLyrics/DateLyricsProviderOrder.h"
#import "CoreLyrics/CoreLyricsStorage.h"
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <Preferences/PSControlTableCell.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#define PREFS_SUITE @"com.shalamand3r.lyricbridge"
#define SHARED_SUITE @"com.shalamand3r.datelyrics"
#define PINK_COLOR [UIColor colorWithRed:255/255.0 green:127/255.0 blue:189/255.0 alpha:1.0]

static UIImage *_cachedGithubIcon = nil;

// mark: - destructive button styling

static void LyricBridgeApplyRedColorToView(UIView *view) {
    if (!view) return;
    view.tintColor = UIColor.systemRedColor;
    if ([view isKindOfClass:UILabel.class]) {
        ((UILabel *)view).textColor = UIColor.systemRedColor;
    } else if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        button.tintColor = UIColor.systemRedColor;
        [button setTitleColor:UIColor.systemRedColor forState:UIControlStateNormal];
        [button setTitleColor:UIColor.systemRedColor forState:UIControlStateHighlighted];
        [button setTitleColor:UIColor.systemRedColor forState:UIControlStateSelected];
    }
    for (UIView *sub in view.subviews) {
        LyricBridgeApplyRedColorToView(sub);
    }
}

static void LyricBridgeStyleDestructiveCell(UITableViewCell *cell, PSSpecifier *specifier) {
    if (!cell || ![[specifier propertyForKey:@"isDestructive"] boolValue]) return;
    cell.tintColor = UIColor.systemRedColor;
    cell.contentView.tintColor = UIColor.systemRedColor;
    cell.textLabel.textColor = UIColor.systemRedColor;
    if ([cell isKindOfClass:PSTableCell.class]) {
        ((PSTableCell *)cell).titleLabel.textColor = UIColor.systemRedColor;
    }
    LyricBridgeApplyRedColorToView(cell);
}

// mark: - cache inspection and wiping helpers

static dispatch_queue_t LyricBridgeCacheMaintenanceQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.shalamand3r.lyricbridge.cache-maintenance", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static inline BOOL LyricBridgeIsLyricCacheFile(NSString *filename) {
    return DLLyricsIsCacheFilename(filename);
}

static unsigned long long LyricBridgeGetPathSize(NSString *path, NSFileManager *fm) {
    if (!path.length) return 0;
    NSDictionary *attributes = [fm attributesOfItemAtPath:path error:nil];
    if ([attributes.fileType isEqualToString:NSFileTypeRegular]) {
        return LyricBridgeIsLyricCacheFile(path.lastPathComponent) ? attributes.fileSize : 0;
    }
    if (![attributes.fileType isEqualToString:NSFileTypeDirectory]) return 0;
    unsigned long long total = 0;
    for (NSString *entry in [fm contentsOfDirectoryAtPath:path error:nil]) {
        total += LyricBridgeGetPathSize([path stringByAppendingPathComponent:entry], fm);
    }
    return total;
}

static NSArray<NSString *> *LyricBridgeCacheRoots(void) {
    NSMutableArray *roots = [NSMutableArray array];
    NSArray *candidates = @[
        @"/var/mobile/Library/CoreLyrics",
        @"/var/jb/var/mobile/Library/CoreLyrics",
        @"/var/mobile/Library/DateLyrics",
        @"/var/jb/var/mobile/Library/DateLyrics"
    ];
    for (NSString *cand in candidates) {
        if (![roots containsObject:cand]) [roots addObject:cand];
    }

    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    if (proxyClass && [proxyClass respondsToSelector:@selector(bundleProxyForIdentifier:)]) {
        id proxy = [proxyClass performSelector:@selector(bundleProxyForIdentifier:) withObject:@"com.apple.Music"];
        if (proxy && [proxy respondsToSelector:@selector(dataContainerURL)]) {
            NSURL *url = [proxy performSelector:@selector(dataContainerURL)];
            if (url.path.length) {
                NSString *coreCache = [url.path stringByAppendingPathComponent:@"Library/CoreLyrics"];
                NSString *dateLyricsCache = [url.path stringByAppendingPathComponent:@"Library/DateLyrics"];
                if (![roots containsObject:coreCache]) [roots addObject:coreCache];
                if (![roots containsObject:dateLyricsCache]) [roots addObject:dateLyricsCache];
            }
        }
    }
    return roots;
}

static unsigned long long LyricBridgeTotalLyricsCacheSize(void) {
    unsigned long long total = 0;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *root in LyricBridgeCacheRoots()) {
        total += LyricBridgeGetPathSize(root, fm);
    }
    return total;
}

static NSString *LyricBridgeFormattedCacheSize(unsigned long long bytes) {
    if (bytes == 0) return @"0 KB";
    if (bytes < 1024) return @"1 KB";
    return [NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleFile];
}

static void LyricBridgeRemoveCachedLyrics(NSString *directory, NSFileManager *fm) {
    if (!directory.length) return;
    NSDictionary *attributes = [fm attributesOfItemAtPath:directory error:nil];
    if (![attributes.fileType isEqualToString:NSFileTypeDirectory]) return;
    for (NSString *file in [fm contentsOfDirectoryAtPath:directory error:nil]) {
        if (!LyricBridgeIsLyricCacheFile(file)) continue;
        NSString *path = [directory stringByAppendingPathComponent:file];
        if ([[fm attributesOfItemAtPath:path error:nil].fileType isEqualToString:NSFileTypeRegular]) {
            [fm removeItemAtPath:path error:nil];
        }
    }
}

static void LyricBridgeWipeLyricsCaches(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *root in LyricBridgeCacheRoots()) {
        LyricBridgeRemoveCachedLyrics(root, fm);
        LyricBridgeRemoveCachedLyrics([root stringByAppendingPathComponent:@"External"], fm);
    }

    // bump generation in shared suite so running hosts clear in-memory caches
    NSNumber *generation = (__bridge_transfer NSNumber *)CFPreferencesCopyAppValue(CFSTR("CacheGeneration"), CFSTR("com.shalamand3r.datelyrics"));
    NSUInteger nextGen = [generation isKindOfClass:NSNumber.class] ? generation.unsignedIntegerValue + 1 : 1;
    CFPreferencesSetAppValue(CFSTR("CacheGeneration"), (__bridge CFNumberRef)@(nextGen), CFSTR("com.shalamand3r.datelyrics"));
    CFPreferencesAppSynchronize(CFSTR("com.shalamand3r.datelyrics"));

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.shalamand3r.datelyrics/ClearCaches"), NULL, NULL, YES);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.shalamand3r.datelyrics/ReloadPrefs"), NULL, NULL, YES);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.shalamand3r.lyricbridge/ReloadPrefs"), NULL, NULL, YES);
}

// mark: - root list controller

@interface LyricBridgeSettings : PSListController
@end

@implementation LyricBridgeSettings

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];

        for (PSSpecifier *spec in _specifiers) {
            if ([[spec propertyForKey:@"id"] isEqualToString:@"GitHubCell"]) {
                if (_cachedGithubIcon) {
                    [spec setProperty:_cachedGithubIcon forKey:@"iconImage"];
                } else {
                    UIGraphicsBeginImageContextWithOptions(CGSizeMake(29, 29), NO, 0);
                    UIImage *blank = UIGraphicsGetImageFromCurrentImageContext();
                    UIGraphicsEndImageContext();
                    [spec setProperty:blank forKey:@"iconImage"];
                }
            }
        }
    }
    return _specifiers;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];

    if ([[specifier propertyForKey:@"id"] isEqualToString:@"GitHubCell"]) {
        if (!_cachedGithubIcon) {
            UIActivityIndicatorView *spinner = (UIActivityIndicatorView *)[cell.imageView viewWithTag:1234];
            if (!spinner) {
                spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
                spinner.tag = 1234;
                [cell.imageView addSubview:spinner];

                spinner.translatesAutoresizingMaskIntoConstraints = NO;
                [NSLayoutConstraint activateConstraints:@[
                    [spinner.centerXAnchor constraintEqualToAnchor:cell.imageView.centerXAnchor],
                    [spinner.centerYAnchor constraintEqualToAnchor:cell.imageView.centerYAnchor]
                ]];
            }
            [spinner startAnimating];
        } else {
            UIView *spinner = [cell.imageView viewWithTag:1234];
            if (spinner) [spinner removeFromSuperview];
        }
    } else if (cell.imageView.image) {
        cell.imageView.tintColor = PINK_COLOR;
    }

    return cell;
}

- (void)loadView {
    [super loadView];

    UITableView *tableView = [self table];
    tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;

    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, 180)];
    headerView.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UIImageView *imageView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 20, 100, 100)];
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSString *headerPath = [bundle pathForResource:@"header_icon" ofType:@"png"];
    if (!headerPath) headerPath = [bundle pathForResource:@"icon" ofType:@"png"];
    UIImage *image = headerPath ? [UIImage imageWithContentsOfFile:headerPath] : nil;

    if (!image) {
        // fallback placeholder icon
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(100, 100), NO, 0);
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 100, 100) cornerRadius:22];
        [PINK_COLOR setFill];
        [path fill];
        UIImage *symbol = [UIImage systemImageNamed:@"music.note.list"];
        if (symbol) {
            [[UIColor whiteColor] set];
            [symbol drawInRect:CGRectMake(25, 25, 50, 50)];
        }
        image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    }

    imageView.image = image;
    imageView.contentMode = UIViewContentModeScaleAspectFit;
    imageView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    imageView.center = CGPointMake(headerView.center.x, imageView.center.y);
    imageView.layer.cornerRadius = 22;
    imageView.layer.masksToBounds = YES;
    [headerView addSubview:imageView];

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 130, headerView.bounds.size.width, 40)];
    titleLabel.text = @"LyricBridge";
    titleLabel.font = [UIFont systemFontOfSize:30 weight:UIFontWeightBold];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [headerView addSubview:titleLabel];

    tableView.tableHeaderView = headerView;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    UIColor *tintColor = PINK_COLOR;
    [UISwitch appearanceWhenContainedInInstancesOfClasses:@[[self class]]].onTintColor = tintColor;
    self.view.tintColor = tintColor;

    if (!_cachedGithubIcon) {
        [self fetchGithubLogo];
    }
}

- (void)openGithub {
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [haptic impactOccurred];
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://github.com/shalamand3r/LyricBridge"] options:@{} completionHandler:nil];
}

- (void)fetchGithubLogo {
    if (_cachedGithubIcon) return;
    NSURL *url = [NSURL URLWithString:@"https://github.com/shalamand3r/shalamand3r.github.io/blob/main/CydiaIcon.png?raw=true"];
    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!data || error) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || _cachedGithubIcon) return;

            UIImage *image = [UIImage imageWithData:data];
            if (!image) return;

            UIImageView *imageView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 29, 29)];
            imageView.image = image;
            imageView.layer.cornerRadius = 7;
            imageView.layer.masksToBounds = YES;
            imageView.layer.contentsGravity = kCAGravityResizeAspectFill;

            UIGraphicsBeginImageContextWithOptions(imageView.bounds.size, NO, [UIScreen mainScreen].scale);
            [imageView.layer renderInContext:UIGraphicsGetCurrentContext()];
            UIImage *squircleImage = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();

            _cachedGithubIcon = squircleImage;

            PSSpecifier *githubSpecifier = [strongSelf specifierForID:@"GitHubCell"];
            if (githubSpecifier) {
                [githubSpecifier setProperty:squircleImage forKey:@"iconImage"];
                [strongSelf reloadSpecifier:githubSpecifier];

                NSIndexPath *indexPath = [strongSelf indexPathForSpecifier:githubSpecifier];
                if (indexPath) {
                    UITableViewCell *cell = [strongSelf.table cellForRowAtIndexPath:indexPath];
                    if (cell) {
                        UIView *spinner = [cell.imageView viewWithTag:1234];
                        if (spinner) [spinner removeFromSuperview];
                    }
                }
            }
        });
    }] resume];
}

@end

// mark: - lyric services order controller

@interface LyricBridgeProviderOrderController : PSListController
@property (nonatomic, strong) NSMutableArray<NSString *> *providerKeys;
@end

@implementation LyricBridgeProviderOrderController

- (NSArray *)specifiers {
    if (!_specifiers) {
        id saved = (__bridge_transfer id)CFPreferencesCopyAppValue(CFSTR("LyricsProviderOrder"), CFSTR("com.shalamand3r.datelyrics"));
        self.providerKeys = [DateLyricsSanitizedProviderOrder(saved) mutableCopy];
        NSMutableArray *specs = [[self loadSpecifiersFromPlistName:@"Services" target:self] mutableCopy];
        NSUInteger index = 1;
        for (NSString *key in self.providerKeys) {
            NSDictionary *def = DateLyricsProviderDefinition(key);
            PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:def[@"name"] ?: key
                target:self set:NULL get:NULL detail:Nil cell:PSTitleValueCell edit:Nil];
            specifier.identifier = key;
            [specs insertObject:specifier atIndex:index++];
        }
        _specifiers = specs;
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Lyric Services";
    self.view.tintColor = PINK_COLOR;
    self.table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.table setEditing:YES animated:NO];
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    id value = [super readPreferenceValue:specifier];
    if ([[specifier propertyForKey:@"key"] isEqual:@"LyricsRequestTimeout"]) {
        return @(DateLyricsSanitizedRequestTimeout(value));
    }
    return value;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if ([key isEqual:@"LyricsRequestTimeout"]) {
        value = @(DateLyricsSanitizedRequestTimeout(value));
    } else if ([key isEqual:@"MusixmatchUserToken"] && [value isKindOfClass:NSString.class]) {
        value = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
    [super setPreferenceValue:value specifier:specifier];

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 0;
}

- (NSIndexPath *)tableView:(UITableView *)tableView targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)sourceIndexPath toProposedIndexPath:(NSIndexPath *)proposedDestinationIndexPath {
    return proposedDestinationIndexPath.section == 0 ? proposedDestinationIndexPath
        : [NSIndexPath indexPathForRow:self.providerKeys.count - 1 inSection:0];
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath {
    if (sourceIndexPath.section != 0 || destinationIndexPath.section != 0) return;
    if (sourceIndexPath.row == destinationIndexPath.row) return;

    NSString *movedKey = self.providerKeys[sourceIndexPath.row];
    [self.providerKeys removeObjectAtIndex:sourceIndexPath.row];
    [self.providerKeys insertObject:movedKey atIndex:destinationIndexPath.row];

    NSMutableArray *specs = self.specifiers;
    PSSpecifier *movedSpecifier = specs[sourceIndexPath.row + 1];
    [specs removeObjectAtIndex:sourceIndexPath.row + 1];
    [specs insertObject:movedSpecifier atIndex:destinationIndexPath.row + 1];

    CFPreferencesSetAppValue(CFSTR("LyricsProviderOrder"), (__bridge CFArrayRef)self.providerKeys, CFSTR("com.shalamand3r.datelyrics"));
    CFPreferencesAppSynchronize(CFSTR("com.shalamand3r.datelyrics"));

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (CFStringRef)@"com.shalamand3r.datelyrics/ReloadPrefs", NULL, NULL, YES);

    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) return 60.0;
    return [super tableView:tableView heightForRowAtIndexPath:indexPath];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        static NSString *cellId = @"LyricBridgeProviderReorderCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
        if (!cell) {
            cell = [[PSTableCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId specifier:[self specifierAtIndexPath:indexPath]];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        ((PSTableCell *)cell).specifier = [self specifierAtIndexPath:indexPath];

        NSString *key = self.providerKeys[indexPath.row];
        NSDictionary *definition = DateLyricsProviderDefinition(key);
        cell.textLabel.text = definition[@"name"];
        cell.detailTextLabel.text = definition[@"detail"];
        cell.imageView.image = [UIImage systemImageNamed:definition[@"symbol"]];

        cell.imageView.tintColor = PINK_COLOR;
        cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.showsReorderControl = YES;

        return cell;
    }

    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    cell.showsReorderControl = NO;
    cell.tintColor = self.view.tintColor;
    if ([cell isKindOfClass:PSControlTableCell.class]) {
        UIControl *control = ((PSControlTableCell *)cell).control;
        control.tintColor = self.view.tintColor;
        if ([control isKindOfClass:UISlider.class]) {
            ((UISlider *)control).minimumTrackTintColor = self.view.tintColor;
        }
    }
    return cell;
}

@end

// mark: - experimental options controller

@interface LyricBridgeExperimentalController : PSListController
@property (nonatomic) BOOL resetInProgress;
@property (nonatomic) NSUInteger cacheSizeRequest;
- (void)updateWipeCacheSpecifier;
@end

@implementation LyricBridgeExperimentalController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Experimental" target:self];
        for (PSSpecifier *spec in _specifiers) {
            if ([[spec propertyForKey:@"id"] isEqualToString:@"WipeSavedLyrics"] ||
                [[spec propertyForKey:@"action"] isEqualToString:@"wipeSavedLyrics"] ||
                [[spec propertyForKey:@"action"] isEqualToString:@"wipeLyricsCache"]) {
                spec.name = @"Wipe Lyrics Cache";
            }
        }
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Experimental";
    UIColor *tintColor = PINK_COLOR;
    [UISwitch appearanceWhenContainedInInstancesOfClasses:@[[self class]]].onTintColor = tintColor;
    self.view.tintColor = tintColor;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateWipeCacheSpecifier];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    LyricBridgeStyleDestructiveCell(cell, specifier);
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    LyricBridgeStyleDestructiveCell(cell, specifier);
}

- (void)updateWipeCacheSpecifier {
    NSUInteger request = ++self.cacheSizeRequest;
    __weak typeof(self) weakSelf = self;
    dispatch_async(LyricBridgeCacheMaintenanceQueue(), ^{
        unsigned long long size = LyricBridgeTotalLyricsCacheSize();
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) controller = weakSelf;
            if (!controller || request != controller.cacheSizeRequest) return;
            PSSpecifier *spec = [controller specifierForID:@"WipeSavedLyrics"];
            if (!spec) return;
            NSString *title = [NSString stringWithFormat:@"Wipe Lyrics Cache (%@)", LyricBridgeFormattedCacheSize(size)];
            spec.name = title;
            [spec setProperty:title forKey:@"label"];
            [controller reloadSpecifier:spec animated:NO];

            PSTableCell *cached = [controller cachedCellForSpecifier:spec];
            LyricBridgeStyleDestructiveCell(cached, spec);
            NSIndexPath *indexPath = [controller indexPathForSpecifier:spec];
            if (indexPath) {
                LyricBridgeStyleDestructiveCell([controller.table cellForRowAtIndexPath:indexPath], spec);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                LyricBridgeStyleDestructiveCell([controller cachedCellForSpecifier:spec], spec);
                NSIndexPath *ip = [controller indexPathForSpecifier:spec];
                if (ip) {
                    LyricBridgeStyleDestructiveCell([controller.table cellForRowAtIndexPath:ip], spec);
                }
            });
        });
    });
}

- (void)wipeSavedLyrics {
    [self wipeLyricsCache];
}

- (void)wipeLyricsCache {
    static BOOL inProgress = NO;
    if (inProgress) return;
    inProgress = YES;
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy] impactOccurred];

    __weak typeof(self) weakSelf = self;
    dispatch_async(LyricBridgeCacheMaintenanceQueue(), ^{
        LyricBridgeWipeLyricsCaches();
        dispatch_async(dispatch_get_main_queue(), ^{
            inProgress = NO;
            typeof(self) controller = weakSelf;
            if (controller) {
                [controller updateWipeCacheSpecifier];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    [controller updateWipeCacheSpecifier];
                });
            }

            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Cache Reset Requested"
                message:@"Resume playback in your music app to fetch fresh lyrics."
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [controller presentViewController:alert animated:YES completion:nil];
        });
    });
}

- (void)resetSettings {
    if (self.resetInProgress) return;
    self.resetInProgress = YES;

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [haptic impactOccurred];

    CFPreferencesSetAppValue(CFSTR("Enabled"), (__bridge CFPropertyListRef)@YES, CFSTR("com.shalamand3r.lyricbridge"));
    CFPreferencesSetAppValue(CFSTR("EnableSing"), (__bridge CFPropertyListRef)@YES, CFSTR("com.shalamand3r.lyricbridge"));
    CFPreferencesAppSynchronize(CFSTR("com.shalamand3r.lyricbridge"));

    _specifiers = nil;
    [self reloadSpecifiers];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.shalamand3r.lyricbridge/ReloadPrefs"), NULL, NULL, YES);
    for (UIViewController *controller in self.navigationController.viewControllers) {
        if ([controller isKindOfClass:[LyricBridgeSettings class]]) {
            [((LyricBridgeSettings *)controller) reloadSpecifiers];
        }
    }
    self.resetInProgress = NO;
}

@end
