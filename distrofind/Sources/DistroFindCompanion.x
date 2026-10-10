#import "Core/SGCore.h"
#import "Headers/SPTPlayer.h"
#import "Headers/SPTLinkDispatcherImplementation.h"
#import "Shared/DistroFind/DistroFind.h"
#import "Shared/DistroFind/DistroFindData.h"
#import "Shared/DistroFind/DistroFindServer.h"
#import <objc/message.h>

static __weak SPTPlayerTrack *df_currentTrack;
static NSString *df_currentTrackID;
static __weak SPTLinkDispatcherImplementation *df_linkDispatcher;
static NSMutableDictionary<NSString *, NSString *> *df_trackByKey;
static NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *df_tracksByTitle;
static NSMutableDictionary<NSString *, SGDistroMetadata *> *df_metadata;
static NSString *df_filter = @"";
static char kDFTrackKey, kDFBadgeKey, kDFLookupKey;
static NSString *DFCurrentTrackID(void);
static NSObject *df_playbackLock;
static NSString *df_lastQueuedTrackID;
static BOOL df_stateCheckQueued;
static CFAbsoluteTime df_lastPlaybackPoll;
static BOOL df_refreshQueued;
static NSMutableDictionary<NSString *, NSMutableArray *> *df_pendingLookups;
static void DFPresentDashboard(NSString *trackID);
void DFRowResolveTrack(NSString *title, NSString *artist, UIView *cell,
                       void (^completion)(NSString *trackID));
UIViewController *DFPerformanceGraphController(NSDictionary *data);

static NSString *DFURIString(id uri) {
    if ([uri isKindOfClass:NSURL.class]) return [(NSURL *)uri absoluteString];
    if ([uri isKindOfClass:NSString.class]) return uri;
    return [uri respondsToSelector:@selector(description)] ? [uri description] : nil;
}

static NSString *DFTrackIDFromURI(id uri) {
    NSString *text = DFURIString(uri);
    NSString *prefix = @"spotify:track:";
    if (![text hasPrefix:prefix]) return nil;
    NSString *track = [text substringFromIndex:prefix.length];
    return track.length == 22 ? track : nil;
}

static NSString *DFNormalize(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return @"";
    NSString *s = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
    return [[s componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "];
}

static NSString *DFKey(NSString *title, NSString *artist) {
    return [NSString stringWithFormat:@"%@\n%@", DFNormalize(title), DFNormalize(artist)];
}

// Spotify can call its player getters from playback threads. Do not touch
// trackTitle/artistName in a metadata hook or force UIKit to relayout there.
static void DFRememberTrack(SPTPlayerTrack *track) {
    if (!track) return;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ DFRememberTrack(track); });
        return;
    }
    NSString *trackID = DFTrackIDFromURI(track.URI);
    if (!trackID.length) return;
    NSString *title = track.trackTitle ?: @"";
    NSString *artist = track.artistName ?: @"";
    if (title.length) {
        df_trackByKey[DFKey(title, artist)] = trackID;
        NSString *t = DFNormalize(title);
        NSMutableSet *ids = df_tracksByTitle[t];
        if (!ids) df_tracksByTitle[t] = ids = [NSMutableSet set];
        [ids addObject:trackID];
    }
}

// Update visible rows only, and coalesce bursts of metadata completions.
// Invalidating every collection layout and every subview caused a layout
// feedback loop when playback updated the now-playing bar.
static void DFRefreshVisible(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (df_refreshQueued) return;
        df_refreshQueued = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            df_refreshQueued = NO;
            for (UIWindow *window in UIApplication.sharedApplication.windows) {
                [window setNeedsLayout];
                NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
                NSUInteger visited = 0;
                while (stack.count && visited++ < 1800) {
                    UIView *view = stack.lastObject;
                    [stack removeLastObject];
                    if ([view isKindOfClass:UICollectionView.class]) {
                        for (UICollectionViewCell *cell in ((UICollectionView *)view).visibleCells)
                            [cell setNeedsLayout];
                    }
                    if ([view isKindOfClass:UIButton.class] &&
                        [view.accessibilityIdentifier isEqualToString:@"DistroFind.NowPlaying.Badge"]) {
                        UIButton *button = (UIButton *)view;
                        NSString *name = SGDistroDisplayName(df_metadata[DFCurrentTrackID()]) ?: @"DistroFind…";
                        if (![[button titleForState:UIControlStateNormal] isEqualToString:name])
                            [button setTitle:name forState:UIControlStateNormal];
                    }
                    [stack addObjectsFromArray:view.subviews];
                }
            }
        });
    });
}

// Coalesce requests from player state, row layout, and the mini-player.
// Each track is fetched once regardless of how many layout passes occur.
static void DFResolve(NSString *trackID, void (^completion)(SGDistroMetadata *meta, NSError *error)) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ DFResolve(trackID, completion); });
        return;
    }
    if (!trackID.length) {
        if (completion) completion(nil, nil);
        return;
    }
    SGDistroMetadata *cached = df_metadata[trackID];
    if (cached) {
        if (completion) completion(cached, nil);
        return;
    }
    NSMutableArray *pending = df_pendingLookups[trackID];
    if (pending) {
        if (completion) [pending addObject:[completion copy]];
        return;
    }
    pending = [NSMutableArray array];
    if (completion) [pending addObject:[completion copy]];
    df_pendingLookups[trackID] = pending;

    SGDistroMetadataForTrack(trackID, ^(SGDistroMetadata *meta, NSError *error) {
        void (^finish)(SGDistroMetadata *, NSError *) = ^(SGDistroMetadata *resolved, NSError *failure) {
            if (resolved) {
                df_metadata[trackID] = resolved;
                [[NSNotificationCenter defaultCenter] postNotificationName:@"DistroFind.MetadataReady"
                    object:trackID];
                SGLog(@"DistroFind metadata ready for a track");
            } else if (failure) {
                SGLog(@"DistroFind metadata lookup failed, status %ld", (long)failure.code);
            }
            NSArray *callbacks = [df_pendingLookups[trackID] copy];
            [df_pendingLookups removeObjectForKey:trackID];
            if (resolved) DFRefreshVisible();
            for (void (^callback)(SGDistroMetadata *, NSError *) in callbacks)
                callback(resolved, failure);
        };
        if (meta && !error &&
            [meta.licensorUUID isEqualToString:@"9c290842b7fa4396bb0dcb3ad95634f5"] &&
            !meta.likelyDistributor.length && meta.albumID.length) {
            SGDistroVydiaSubDistributor(meta.albumID, meta.albumName, meta.artist, ^(NSString *sub) {
                if (sub.length) meta.likelyDistributor = sub;
                finish(meta, nil);
            });
        } else {
            finish(meta, error);
        }
    });
}

static UIViewController *DFTopController(void) {
    UIWindow *window = UIApplication.sharedApplication.keyWindow;
    if (!window) for (UIWindow *candidate in UIApplication.sharedApplication.windows) if (!candidate.hidden) { window = candidate; break; }
    UIViewController *vc = window.rootViewController;
    while (vc) {
        if (vc.presentedViewController) { vc = vc.presentedViewController; continue; }
        if ([vc isKindOfClass:UINavigationController.class]) { vc = ((UINavigationController *)vc).visibleViewController; continue; }
        if ([vc isKindOfClass:UITabBarController.class]) { vc = ((UITabBarController *)vc).selectedViewController; continue; }
        break;
    }
    return vc;
}

static BOOL DFOpenURI(NSString *uri) {
    NSURL *url = [NSURL URLWithString:uri];
    id dispatcher = df_linkDispatcher;
    SEL sel = @selector(navigateToURI:options:interactionID:);
    if (!url || ![dispatcher respondsToSelector:sel]) return NO;
    ((void (*)(id, SEL, id, long long, id))objc_msgSend)(dispatcher, sel, url, 0, nil);
    return YES;
}

static NSString *DFPageArtistID(void) {
    NSMutableArray<UIViewController *> *queue = [NSMutableArray array];
    UIViewController *top = DFTopController();
    if (top) [queue addObject:top];
    while (queue.count) {
        UIViewController *vc = queue.firstObject;
        [queue removeObjectAtIndex:0];
        SEL sel = NSSelectorFromString(@"spt_pageURI");
        if ([vc respondsToSelector:sel]) {
            id uri = ((id (*)(id, SEL))objc_msgSend)(vc, sel);
            NSString *text = DFURIString(uri);
            if ([text hasPrefix:@"spotify:artist:"] && text.length >= 37) return [text substringFromIndex:15];
        }
        if ([vc isKindOfClass:UINavigationController.class]) [queue addObjectsFromArray:((UINavigationController *)vc).viewControllers];
        [queue addObjectsFromArray:vc.childViewControllers];
    }
    NSString *text = DFURIString(df_currentTrack.artistURI);
    return [text hasPrefix:@"spotify:artist:"] ? [text substringFromIndex:15] : nil;
}

static NSString *DFCurrentTrackID(void) {
    NSString *trackID = DFTrackIDFromURI(df_currentTrack.URI);
    return trackID ?: df_currentTrackID;
}

static UILabel *DFLabelInside(UIView *root) {
    if ([root isKindOfClass:UILabel.class]) return (UILabel *)root;
    for (UIView *sub in root.subviews) {
        UILabel *label = DFLabelInside(sub);
        if (label) return label;
    }
    return nil;
}

static UIView *DFFindIdentifier(UIView *root, NSArray<NSString *> *needles) {
    NSString *identifier = root.accessibilityIdentifier ?: @"";
    for (NSString *needle in needles) if ([identifier containsString:needle]) return root;
    for (UIView *sub in root.subviews) {
        UIView *found = DFFindIdentifier(sub, needles);
        if (found) return found;
    }
    return nil;
}

static NSString *DFTrackForCell(UIView *cell, NSString *title, NSString *artist) {
    // Only the verified, source-backed ID associated with this exact row.
    // Never use the current player's title/artist as a playlist ID guess.
    NSString *sid = objc_getAssociatedObject(cell, &kDFTrackKey);
    return sid.length == 22 ? sid : nil;
}

// Neutral chip with an internal marquee; the chip itself stays still.
@interface DFBadgeLabel : UIControl
@property (nonatomic, copy) NSString *trackID;
@property (nonatomic, strong) UILabel *textView;
- (void)setBadgeText:(NSString *)value;
@end
@implementation DFBadgeLabel
- (instancetype)init {
    if ((self = [super init])) {
        self.backgroundColor = [UIColor colorWithWhite:1 alpha:0.13];
        self.layer.cornerRadius = 6;
        self.clipsToBounds = YES;
        self.layer.zPosition = 50;
        _textView = [UILabel new];
        _textView.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
        _textView.textColor = [UIColor colorWithWhite:1 alpha:0.88];
        _textView.userInteractionEnabled = NO;
        [self addSubview:_textView];
        [self addTarget:self action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}
- (void)open { if (self.trackID.length) DFPresentDashboard(self.trackID); }
- (void)setBadgeText:(NSString *)value {
    if ([_textView.text isEqualToString:value]) return;
    [_textView.layer removeAnimationForKey:@"df.marquee"];
    _textView.text = value;
    [self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat realWidth = ceil([_textView.text sizeWithAttributes:@{NSFontAttributeName:_textView.font}].width) + 12;
    CGFloat innerWidth = MAX(1, self.bounds.size.width - 12);
    CGFloat overflow = MAX(0, realWidth - innerWidth);
    _textView.frame = CGRectMake(6, 0, MAX(innerWidth, realWidth), self.bounds.size.height);
    if (overflow > 2 && ![_textView.layer animationForKey:@"df.marquee"] && self.window) {
        CAKeyframeAnimation *animation = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
        animation.values = @[@0, @0, @(-overflow), @(-overflow), @0];
        animation.keyTimes = @[@0, @0.16, @0.57, @0.75, @1];
        animation.duration = MAX(6, overflow / 12.0 + 3);
        animation.repeatCount = HUGE_VALF;
        [_textView.layer addAnimation:animation forKey:@"df.marquee"];
    }
}
@end

static DFBadgeLabel *DFBadge(UIView *cell) {
    DFBadgeLabel *badge = objc_getAssociatedObject(cell, &kDFBadgeKey);
    if (!badge) {
        badge = [DFBadgeLabel new];
        [cell addSubview:badge];
        objc_setAssociatedObject(cell, &kDFBadgeKey, badge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return badge;
}

static BOOL DFFilterRejects(SGDistroMetadata *meta) {
    if (!df_filter.length || !meta) return NO;
    NSString *name = SGDistroDisplayName(meta).lowercaseString ?: @"";
    NSString *parent = meta.distributor.lowercaseString ?: @"";
    NSString *needle = df_filter.lowercaseString;
    return ![name containsString:needle] && ![parent containsString:needle];
}

static void DFApplyCell(UIView *cell) {
    UIView *titleView = DFFindIdentifier(cell, @[@"Track.Row.Content.Title", @"Granular.Title"]);
    if (!titleView) return;
    UILabel *titleLabel = DFLabelInside(titleView);
    if (!titleLabel.text.length) return;
    UIView *subtitleView = DFFindIdentifier(cell, @[@"Track.Row.Content.Subtitle", @"Granular.Subtitle"]);
    NSString *artist = DFLabelInside(subtitleView).text ?: @"";
    NSString *trackID = DFTrackForCell(cell, titleLabel.text, artist);
    if (!trackID.length) {
        CGRect onScreen = [cell convertRect:cell.bounds toView:cell.window];
        CGFloat center = CGRectGetMidY(onScreen);
        NSString *lookupKey = DFKey(titleLabel.text, artist);
        if (cell.window && center >= -110 && center <= cell.window.bounds.size.height + 110
            && ![objc_getAssociatedObject(cell, &kDFLookupKey) isEqualToString:lookupKey]) {
            objc_setAssociatedObject(cell, &kDFLookupKey, lookupKey, OBJC_ASSOCIATION_COPY_NONATOMIC);
            __weak UIView *weakCell = cell;
            NSString *wantedTitle = [titleLabel.text copy];
            NSString *wantedArtist = [artist copy];
            DFRowResolveTrack(wantedTitle, wantedArtist, cell, ^(NSString *verified) {
                UIView *visible = weakCell;
                if (!visible || !visible.window || !verified.length) return;
                UIView *currentTitle = DFFindIdentifier(visible, @[@"Track.Row.Content.Title", @"Granular.Title"]);
                UIView *currentArtist = DFFindIdentifier(visible, @[@"Track.Row.Content.Subtitle", @"Granular.Subtitle"]);
                if (![DFLabelInside(currentTitle).text isEqualToString:wantedTitle]
                    || ![(DFLabelInside(currentArtist).text ?: @"") isEqualToString:wantedArtist]) return;
                objc_setAssociatedObject(visible, &kDFTrackKey, verified, OBJC_ASSOCIATION_COPY_NONATOMIC);
                [visible setNeedsLayout];
            });
        }
        DFBadgeLabel *existing = objc_getAssociatedObject(cell, &kDFBadgeKey);
        existing.hidden = YES;
        return;
    }
    objc_setAssociatedObject(cell, &kDFTrackKey, trackID, OBJC_ASSOCIATION_COPY_NONATOMIC);

    DFBadgeLabel *badge = DFBadge(cell);
    badge.trackID = trackID;
    badge.hidden = NO;
    SGDistroMetadata *meta = df_metadata[trackID];
    NSString *name = meta ? SGDistroDisplayName(meta) : @"…";
    [badge setBadgeText:name.length ? name : @"Unknown"];
    CGSize size = [badge.textView.text sizeWithAttributes:@{NSFontAttributeName:badge.textView.font}];
    // Narrow enough to fit beside short mobile titles; longer names move
    // inside the chip via the marquee instead of pushing it under Save/+.
    CGFloat width = MIN(100, MAX(42, ceil(size.width) + 16));
    CGFloat height = 18;
    CGRect titleRect = [titleLabel convertRect:titleLabel.bounds toView:cell];
    CGFloat renderedTitle = [titleLabel.text sizeWithAttributes:@{NSFontAttributeName:titleLabel.font}].width;
    CGFloat inlineX = CGRectGetMinX(titleRect) + MIN(renderedTitle, titleRect.size.width) + 8;
    // Keep the chip INSIDE the text column, not under the + / saved control.
    CGFloat columnRight = MIN(CGRectGetMaxX(titleRect), cell.bounds.size.width - 75);
    CGFloat x, y;
    if (inlineX + width <= columnRight) {
        x = inlineX;
        y = CGRectGetMidY(titleRect) - height / 2.0;
    } else {
        // Long title: place the chip beside the artist, still within the
        // title/artist region rather than next to the playlist add control.
        UILabel *artistLabel = DFLabelInside(subtitleView);
        CGRect artistRect = artistLabel ? [artistLabel convertRect:artistLabel.bounds toView:cell] : titleRect;
        CGFloat artistEnd = CGRectGetMinX(artistRect) +
            MIN([artist sizeWithAttributes:@{NSFontAttributeName:artistLabel.font ?: titleLabel.font}].width, artistRect.size.width);
        x = MIN(MAX(CGRectGetMinX(titleRect), artistEnd + 8), MAX(CGRectGetMinX(titleRect), columnRight - width));
        y = CGRectGetMidY(artistRect) - height / 2.0;
    }
    y = MAX(2, y);
    CGRect next = CGRectMake(x, y, width, height);
    if (!CGRectEqualToRect(badge.frame, next)) badge.frame = next;
    BOOL reject = DFFilterRejects(meta);
    cell.alpha = reject ? 0.15 : 1;
    cell.userInteractionEnabled = !reject;
    if (!meta) DFResolve(trackID, nil);
}

static BOOL DFShouldCollapse(UIView *cell) {
    NSString *trackID = objc_getAssociatedObject(cell, &kDFTrackKey);
    return trackID.length && DFFilterRejects(df_metadata[trackID]);
}

@interface DFTextController : UIViewController
- (instancetype)initWithTitle:(NSString *)title text:(NSString *)text;
@end

@implementation DFTextController {
    NSString *_body;
}
- (instancetype)initWithTitle:(NSString *)title text:(NSString *)text {
    if ((self = [super init])) { self.title = title; _body = [text copy]; }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UITextView *text = [[UITextView alloc] initWithFrame:self.view.bounds];
    text.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    text.editable = NO;
    text.font = [UIFont systemFontOfSize:15];
    text.text = _body ?: @"";
    text.textContainerInset = UIEdgeInsetsMake(18, 16, 18, 16);
    [self.view addSubview:text];
}
@end

@interface DFImageController : UIViewController
- (instancetype)initWithTitle:(NSString *)title image:(UIImage *)image message:(NSString *)message;
@end

@implementation DFImageController {
    UIImage *_image;
    NSString *_message;
}
- (instancetype)initWithTitle:(NSString *)title image:(UIImage *)image message:(NSString *)message {
    if ((self = [super init])) { self.title = title; _image = image; _message = [message copy]; }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UIImageView *image = [[UIImageView alloc] initWithImage:_image];
    image.frame = self.view.bounds;
    image.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    image.contentMode = UIViewContentModeScaleAspectFit;
    [self.view addSubview:image];
    if (!_image) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 24, 80)];
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        label.numberOfLines = 0;
        label.textAlignment = NSTextAlignmentCenter;
        label.text = _message ?: @"No performance image available.";
        [self.view addSubview:label];
    }
}
@end

@interface DFListController : UITableViewController
@property (nonatomic, copy) NSArray<NSDictionary *> *items;
@property (nonatomic, copy) void (^picked)(NSDictionary *item);
- (instancetype)initWithTitle:(NSString *)title items:(NSArray<NSDictionary *> *)items;
@end

@implementation DFListController
- (instancetype)initWithTitle:(NSString *)title items:(NSArray<NSDictionary *> *)items {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) { self.title = title; _items = [items copy]; }
    return self;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.items.count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"df"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"df"];
    NSDictionary *item = self.items[indexPath.row];
    cell.textLabel.text = item[@"title"] ?: @"";
    cell.detailTextLabel.text = item[@"subtitle"] ?: @"";
    cell.detailTextLabel.numberOfLines = 0;
    cell.accessoryType = item[@"uri"] ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *item = self.items[indexPath.row];
    if (self.picked) self.picked(item);
    else if (item[@"uri"]) DFOpenURI(item[@"uri"]);
}
@end

@interface DFRelease : NSObject
@property (nonatomic, copy) NSString *albumID, *gid, *name, *type, *year, *label, *firstTrack;
@property (nonatomic, strong) SGDistroMetadata *distro;
@property (nonatomic, strong) SGDistroAvailability *availability;
@end
@implementation DFRelease @end

static NSArray *DFArray(id value) { return [value isKindOfClass:NSArray.class] ? value : @[]; }
static NSDictionary *DFDict(id value) { return [value isKindOfClass:NSDictionary.class] ? value : nil; }
static NSString *DFString(id value) { return [value isKindOfClass:NSString.class] ? value : nil; }

static void DFLoadReleaseAlbums(NSArray<DFRelease *> *releases, NSUInteger start, void (^done)(void)) {
    if (start >= releases.count) { done(); return; }
    NSUInteger end = MIN(start + 4, releases.count);
    dispatch_group_t group = dispatch_group_create();
    for (NSUInteger i = start; i < end; i++) {
        DFRelease *rel = releases[i];
        dispatch_group_enter(group);
        SGDistroRawMetadataForGID(@"album", rel.gid, ^(NSDictionary *album, NSError *error) {
            if (album) {
                rel.name = DFString(album[@"name"]) ?: rel.name;
                rel.type = DFString(album[@"type"]) ?: rel.type;
                rel.label = DFString(album[@"label"]) ?: @"";
                NSDictionary *date = DFDict(album[@"date"]);
                if ([date[@"year"] integerValue]) rel.year = [NSString stringWithFormat:@"%ld", (long)[date[@"year"] integerValue]];
                NSDictionary *disc = DFArray(album[@"disc"]).firstObject;
                NSDictionary *track = DFArray(disc[@"track"]).firstObject;
                rel.firstTrack = SGDistroSpotifyIDForGID(DFString(track[@"gid"]));
            }
            dispatch_group_leave(group);
        });
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{ DFLoadReleaseAlbums(releases, end, done); });
}

static void DFArtistReleases(NSString *artistID, void (^completion)(NSArray<DFRelease *> *releases, NSError *error)) {
    SGDistroRawMetadataForSpotifyID(@"artist", artistID, ^(NSDictionary *artist, NSError *error) {
        if (!artist || error) { completion(nil, error); return; }
        NSMutableArray<DFRelease *> *out = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];
        NSArray *groups = @[@[@"album_group", @"album"], @[@"single_group", @"single"], @[@"compilation_group", @"compilation"]];
        for (NSArray *pair in groups) {
            for (NSDictionary *group in DFArray(artist[pair[0]])) {
                for (NSDictionary *album in DFArray(group[@"album"])) {
                    NSString *gid = DFString(album[@"gid"]);
                    if (gid.length != 32 || [seen containsObject:gid]) continue;
                    [seen addObject:gid];
                    DFRelease *rel = [DFRelease new];
                    rel.gid = gid;
                    rel.albumID = SGDistroSpotifyIDForGID(gid);
                    rel.name = DFString(album[@"name"]) ?: @"Untitled";
                    rel.type = pair[1];
                    [out addObject:rel];
                }
            }
        }
        DFLoadReleaseAlbums(out, 0, ^{ completion(out, nil); });
    });
}

static void DFResolveReleaseDistros(NSArray<DFRelease *> *releases, void (^done)(void)) {
    dispatch_group_t group = dispatch_group_create();
    for (DFRelease *rel in releases) {
        if (!rel.firstTrack.length) continue;
        dispatch_group_enter(group);
        DFResolve(rel.firstTrack, ^(SGDistroMetadata *meta, NSError *error) {
            rel.distro = meta;
            dispatch_group_leave(group);
        });
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), done);
}

static void DFCheckRegions(NSArray<DFRelease *> *releases, NSUInteger start, void (^done)(void)) {
    if (start >= releases.count) { done(); return; }
    NSUInteger end = MIN(start + 4, releases.count);
    dispatch_group_t group = dispatch_group_create();
    for (NSUInteger i = start; i < end; i++) {
        DFRelease *rel = releases[i];
        if (!rel.firstTrack.length) continue;
        dispatch_group_enter(group);
        SGDistroAvailabilityForTrack(rel.firstTrack, ^(SGDistroAvailability *result, NSError *error) {
            rel.availability = result;
            dispatch_group_leave(group);
        });
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{ DFCheckRegions(releases, end, done); });
}

@interface DFDashboardController : UITableViewController
@property (nonatomic, copy) NSString *artistIDOverride;
@property (nonatomic, copy) NSString *trackID;
@property (nonatomic, strong) SGDistroMetadata *meta;
- (instancetype)initWithTrackID:(NSString *)trackID;
@end

@implementation DFDashboardController

- (instancetype)init { return [self initWithTrackID:DFCurrentTrackID()]; }

- (instancetype)initWithTrackID:(NSString *)trackID {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _trackID = [trackID copy];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 65;
    self.title = @"DistroFind";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    [self reloadMetadata];
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)reloadMetadata {
    NSString *trackID = self.trackID;
    if (!trackID.length) { [self.tableView reloadData]; return; }
    DFResolve(trackID, ^(SGDistroMetadata *meta, NSError *error) {
        self.meta = meta;
        [self.tableView reloadData];
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 16;
    if (section == 1) return 4;
    if (section == 2) return 2;
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"Current track", @"Track tools", @"Distributor filter", @"Artist tools"][section];
}

- (NSArray<NSString *> *)infoValues {
    SGDistroMetadata *m = self.meta;
    NSString *duration = m.durationMs > 0 ? [NSString stringWithFormat:@"%ld:%02ld", (long)(m.durationMs / 60000), (long)((m.durationMs / 1000) % 60)] : @"—";
    NSString *live = m.earliestLiveTimestamp > 0 ? [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:m.earliestLiveTimestamp] dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle] : @"—";
    return @[
        m.title ?: ([self.trackID isEqualToString:DFCurrentTrackID()] ? df_currentTrack.trackTitle : nil) ?: @"—",
        m.artist ?: ([self.trackID isEqualToString:DFCurrentTrackID()] ? df_currentTrack.artistName : nil) ?: @"—",
        SGDistroDisplayName(m) ?: @"Loading…",
        m.distributor ?: @"—",
        m.likelyDistributor ?: @"—",
        m.albumName ?: @"—",
        m.label ?: @"—",
        m.releaseDate ?: @"—",
        m.isrc ?: @"—",
        m.upc ?: @"—",
        m.licensorUUID ?: @"—",
        m.pLine.length ? m.pLine : @"Not supplied by Spotify",
        m.cLine.length ? m.cLine : @"Not supplied by Spotify",
        m.copyrights.count ? [m.copyrights componentsJoinedByString:@"\n"] : @"—",
        duration,
        live,
    ];
}

- (UITableViewCell *)basicCell:(UITableView *)tableView title:(NSString *)title value:(NSString *)value action:(BOOL)action {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"dfdash"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"dfdash"];
    cell.textLabel.text = title;
    cell.detailTextLabel.text = value;
    cell.detailTextLabel.numberOfLines = 2;
    cell.accessoryType = action ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    cell.textLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        NSArray *names = @[@"Track", @"Artist(s)", @"Distributor", @"Parent", @"Likely sub-distributor", @"Album", @"Label", @"Release date", @"ISRC", @"UPC", @"Licensor UUID", @"℗ line", @"© line", @"All rights statements", @"Duration", @"Went live"];
        return [self basicCell:tableView title:names[indexPath.row] value:[self infoValues][indexPath.row] action:NO];
    }
    if (indexPath.section == 1) {
        return [self basicCell:tableView title:@[@"Availability", @"Other Versions", @"Performance", @"Refresh metadata"][indexPath.row] value:@"" action:YES];
    }
    if (indexPath.section == 2) {
        return [self basicCell:tableView title:indexPath.row ? @"Clear filter" : @"Filter rows by distributor" value:indexPath.row ? @"" : (df_filter.length ? df_filter : @"Off") action:YES];
    }
    return [self basicCell:tableView title:indexPath.row ? @"Regioned Releases" : @"Artist Scan" value:@"" action:YES];
}

- (void)showText:(NSString *)title text:(NSString *)text {
    DFTextController *vc = [[DFTextController alloc] initWithTitle:title text:text];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)showError:(NSError *)error title:(NSString *)title {
    [self showText:title text:error.localizedDescription ?: @"Request failed."];
}

- (void)availability {
    NSString *trackID = self.trackID;
    SGDistroAvailabilityForTrack(trackID, ^(SGDistroAvailability *result, NSError *error) {
        if (!result || error) { [self showError:error title:@"Availability"]; return; }
        NSString *text = [NSString stringWithFormat:@"Status: %@\n\nAvailable: %lu markets\nBlocked: %lu markets\n\nAvailable markets\n%@\n\nBlocked markets\n%@",
                          result.kind.capitalizedString, (unsigned long)result.available.count, (unsigned long)result.blocked.count,
                          [result.available componentsJoinedByString:@", "], [result.blocked componentsJoinedByString:@", "]];
        [self showText:@"Availability" text:text];
    });
}

- (void)otherVersions {
    NSString *trackID = self.trackID;
    SGDistroOtherVersionsForTrack(trackID, ^(NSDictionary *result, NSError *error) {
        if (!result || error) { [self showError:error title:@"Other Versions"]; return; }
        NSArray *links = DFArray(result[@"links"]);
        NSMutableArray *items = [NSMutableArray array];
        dispatch_group_t group = dispatch_group_create();
        for (NSDictionary *link in links) {
            NSString *url = DFString(link[@"url"]);
            NSRange marker = [url rangeOfString:@"/track/"];
            if (marker.location == NSNotFound) continue;
            NSString *sid = [[url substringFromIndex:NSMaxRange(marker)] componentsSeparatedByString:@"?"].firstObject;
            if (sid.length != 22) continue;
            NSMutableDictionary *item = [@{@"title": sid, @"subtitle": url ?: @"", @"uri": [@"spotify:track:" stringByAppendingString:sid]} mutableCopy];
            [items addObject:item];
            dispatch_group_enter(group);
            DFResolve(sid, ^(SGDistroMetadata *meta, NSError *e) {
                if (meta) {
                    item[@"title"] = meta.title.length ? meta.title : sid;
                    item[@"subtitle"] = [NSString stringWithFormat:@"%@ · %@%@", meta.artist ?: @"", SGDistroDisplayName(meta) ?: @"Unknown", meta.label.length ? [@" · " stringByAppendingString:meta.label] : @""];
                }
                dispatch_group_leave(group);
            });
        }
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            NSString *title = [NSString stringWithFormat:@"Other Versions (%lu)", (unsigned long)items.count];
            DFListController *vc = [[DFListController alloc] initWithTitle:title items:items];
            [self.navigationController pushViewController:vc animated:YES];
        });
    });
}

- (void)performance {
    SGDistroPerformanceDataForTrack(self.trackID, ^(NSDictionary *json, NSError *error) {
        if (!error && [json[@"ready"] boolValue] && [json[@"daily"] isKindOfClass:NSArray.class] &&
            [json[@"daily"] count]) {
            UIViewController *graph = DFPerformanceGraphController(json);
            [self.navigationController pushViewController:graph animated:YES];
            return;
        }
        // Older servers expose only the PNG endpoint. If new server says
        // "not ready", show that status rather than treating it as an error.
        if (!error && json && ![json[@"ready"] boolValue] && [json[@"message"] isKindOfClass:NSString.class]) {
            [self showText:@"Performance" text:json[@"message"]];
            return;
        }
        SGDistroPerformanceImageForTrack(self.trackID, ^(UIImage *image, NSString *message, NSError *imageError) {
            DFImageController *vc = [[DFImageController alloc] initWithTitle:@"Performance" image:image
                message:message ?: imageError.localizedDescription ?: @"Not enough performance data yet."];
            [self.navigationController pushViewController:vc animated:YES];
        });
    });
}

- (void)setFilter {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Distributor filter" message:@"Only matching playlist/album rows stay visible." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.text = df_filter; field.placeholder = @"DistroKid, FUGA, ONErpm…"; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Apply" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        df_filter = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
        [self.tableView reloadData];
        DFRefreshVisible();
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)artistScan {
    NSString *artistID = self.artistIDOverride ?: DFPageArtistID();
    if (!artistID.length) { [self showText:@"Artist Scan" text:@"Open an artist page, or play one of the artist's tracks, then run Artist Scan again."]; return; }
    self.navigationItem.prompt = @"Reading artist releases…";
    DFArtistReleases(artistID, ^(NSArray<DFRelease *> *releases, NSError *error) {
        if (!releases || error) { self.navigationItem.prompt = nil; [self showError:error title:@"Artist Scan"]; return; }
        DFResolveReleaseDistros(releases, ^{
            self.navigationItem.prompt = nil;
            NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
            NSMutableArray *items = [NSMutableArray array];
            for (DFRelease *rel in releases) {
                NSString *distro = SGDistroDisplayName(rel.distro) ?: @"Unknown";
                counts[distro] = @([counts[distro] integerValue] + 1);
                NSString *sub = [NSString stringWithFormat:@"%@%@%@", distro, rel.year.length ? [@" · " stringByAppendingString:rel.year] : @"", rel.label.length ? [@" · " stringByAppendingString:rel.label] : @""];
                [items addObject:@{@"title": rel.name ?: @"Untitled", @"subtitle": sub, @"uri": [@"spotify:album:" stringByAppendingString:rel.albumID ?: @""]}];
            }
            NSArray *sortedNames = [counts keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) { return [b compare:a]; }];
            NSMutableArray *summary = [NSMutableArray array];
            for (NSString *name in sortedNames) [summary addObject:[NSString stringWithFormat:@"%@ × %@", counts[name], name]];
            [items insertObject:@{@"title": [NSString stringWithFormat:@"%lu distributors across %lu releases", (unsigned long)counts.count, (unsigned long)releases.count],
                                  @"subtitle": [summary componentsJoinedByString:@"  •  "]} atIndex:0];
            DFListController *vc = [[DFListController alloc] initWithTitle:@"Artist Scan" items:items];
            [self.navigationController pushViewController:vc animated:YES];
        });
    });
}

- (void)regionedReleases {
    NSString *artistID = self.artistIDOverride ?: DFPageArtistID();
    if (!artistID.length) { [self showText:@"Regioned Releases" text:@"Open an artist page, or play one of the artist's tracks, then run the scan again."]; return; }
    self.navigationItem.prompt = @"Checking release regions…";
    DFArtistReleases(artistID, ^(NSArray<DFRelease *> *releases, NSError *error) {
        if (!releases || error) { self.navigationItem.prompt = nil; [self showError:error title:@"Regioned Releases"]; return; }
        DFCheckRegions(releases, 0, ^{
            self.navigationItem.prompt = nil;
            NSMutableArray *items = [NSMutableArray array];
            for (DFRelease *rel in releases) {
                SGDistroAvailability *a = rel.availability;
                if (!a || [a.kind isEqualToString:@"worldwide"]) continue;
                NSString *status = [a.kind isEqualToString:@"gone"] ? @"Taken down" : [NSString stringWithFormat:@"Playable in %lu markets", (unsigned long)a.available.count];
                [items addObject:@{@"title": rel.name ?: @"Untitled",
                                   @"subtitle": [NSString stringWithFormat:@"%@%@%@", status, rel.year.length ? [@" · " stringByAppendingString:rel.year] : @"", rel.label.length ? [@" · " stringByAppendingString:rel.label] : @""],
                                   @"uri": [@"spotify:album:" stringByAppendingString:rel.albumID ?: @""]}];
            }
            if (!items.count) [items addObject:@{@"title": @"No regioned releases found", @"subtitle": [NSString stringWithFormat:@"%lu releases checked", (unsigned long)releases.count]}];
            DFListController *vc = [[DFListController alloc] initWithTitle:@"Regioned Releases" items:items];
            [self.navigationController pushViewController:vc animated:YES];
        });
    });
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) {
        if (indexPath.row == 0) [self availability];
        else if (indexPath.row == 1) [self otherVersions];
        else if (indexPath.row == 2) [self performance];
        else { [df_metadata removeObjectForKey:self.trackID]; self.meta = nil; [self reloadMetadata]; }
    } else if (indexPath.section == 2) {
        if (indexPath.row == 0) [self setFilter];
        else { df_filter = @""; [self.tableView reloadData]; DFRefreshVisible(); }
    } else if (indexPath.section == 3) {
        if (indexPath.row == 0) [self artistScan];
        else [self regionedReleases];
    }
}
@end

static void DFPresentDashboard(NSString *trackID) {
    DFDashboardController *page = [[DFDashboardController alloc] initWithTrackID:trackID];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:page];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [DFTopController() presentViewController:nav animated:YES completion:nil];
}

// Artist-page actions use the same existing scan methods, on the real artist ID.
void DFUIOpenArtistTool(NSString *artistID, BOOL regions) {
    if (!artistID.length) return;
    DFDashboardController *page = [[DFDashboardController alloc] initWithTrackID:DFCurrentTrackID()];
    page.artistIDOverride = artistID;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:page];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [DFTopController() presentViewController:nav animated:YES completion:^{
        if (regions) [page regionedReleases]; else [page artistScan];
    }];
}

@interface DFTarget : NSObject
+ (instancetype)shared;
- (void)openDashboard:(id)sender;
@end

@implementation DFTarget
+ (instancetype)shared { static DFTarget *x; static dispatch_once_t once; dispatch_once(&once, ^{ x = [DFTarget new]; }); return x; }
- (void)openDashboard:(id)sender {
    DFPresentDashboard(DFCurrentTrackID());
}
@end

static UIButton *DFBarButton(UIViewController *controller) {
    static char key;
    UIButton *button = objc_getAssociatedObject(controller, &key);
    if (!button) {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.titleLabel.font = [UIFont systemFontOfSize:9 weight:UIFontWeightBold];
        button.tintColor = UIColor.whiteColor;
        button.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
        button.layer.cornerRadius = 7;
        button.clipsToBounds = YES;
        button.accessibilityIdentifier = @"DistroFind.NowPlaying.Badge";
        [button addTarget:[DFTarget shared] action:@selector(openDashboard:) forControlEvents:UIControlEventTouchUpInside];
        [controller.view addSubview:button];
        objc_setAssociatedObject(controller, &key, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return button;
}

// The old SPTEsperantoPlayer -state hook called track metadata getters
// synchronously, and the SPTPlayerTrack -metadata hook could recursively
// re-enter those getters as soon as playback began. Keep this hook minimal.
// Do not call a track property getter synchronously from Spotify's
// frequently-invoked playback state getter. Only enqueue one snapshot.
// Public bridge used by optional player/artist UI hooks; no player getter hooks here.
NSString *DFUICurrentTrackID(void) { return DFCurrentTrackID(); }
NSString *DFUITrackDistributor(NSString *trackID) {
    return SGDistroDisplayName(df_metadata[trackID]);
}
void DFUIRequestDistributor(NSString *trackID) {
    if (trackID.length) DFResolve(trackID, nil);
}
void DFUIOpenTrackInfo(NSString *trackID) { DFPresentDashboard(trackID); }

%hook SPTEsperantoPlayer
- (id)state {
    SPTPlayerState *state = %orig;
    SPTPlayerTrack *track = state.track;
    if (!track) return state;

    BOOL schedule = NO;
    @synchronized(df_playbackLock) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (!df_stateCheckQueued && now - df_lastPlaybackPoll >= 0.35) {
            df_lastPlaybackPoll = now;
            df_stateCheckQueued = YES;
            schedule = YES;
        }
    }
    if (schedule) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *trackID = DFTrackIDFromURI(track.URI);
            BOOL changed = NO;
            @synchronized(df_playbackLock) {
                df_stateCheckQueued = NO;
                if (trackID.length && ![trackID isEqualToString:df_lastQueuedTrackID]) {
                    df_lastQueuedTrackID = [trackID copy];
                    changed = YES;
                }
            }
            if (changed) {
                df_currentTrack = track;
                df_currentTrackID = [trackID copy];
                SGLog(@"DistroFind queued new playing track");
                DFRememberTrack(track);
                DFResolve(trackID, nil);
                DFRefreshVisible();
            }
        });
    }
    return state;
}
%end

%hook SPTLinkDispatcherImplementation
- (void)setMainUILoaded:(BOOL)loaded {
    %orig;
    df_linkDispatcher = self;
}
%end

%hook _TtC18NowPlaying_BarImpl27NowPlayingBarViewController
- (void)viewDidLayoutSubviews {
    %orig;
    UIViewController *controller = (UIViewController *)self;
    UIButton *button = DFBarButton(controller);
    NSString *trackID = DFCurrentTrackID();
    SGDistroMetadata *meta = df_metadata[trackID];
    NSString *name = SGDistroDisplayName(meta) ?: (trackID.length ? @"DistroFind…" : @"DistroFind");
    if (![[button titleForState:UIControlStateNormal] isEqualToString:name])
        [button setTitle:name forState:UIControlStateNormal];
    CGFloat width = MIN(116, MAX(64, [name sizeWithAttributes:@{NSFontAttributeName:button.titleLabel.font}].width + 16));
    CGRect bounds = controller.view.bounds;
    button.frame = CGRectMake(MAX(56, bounds.size.width - width - 52), MAX(2, bounds.size.height - 19), width, 16);
    if (trackID.length && !meta) DFResolve(trackID, nil);
}
%end

%hook _TtC35ListUXPlatform_FreeTierPlaylistImpl25ElementCollectionViewCell
- (void)layoutSubviews {
    %orig;
    DFApplyCell((UIView *)self);
}
- (UICollectionViewLayoutAttributes *)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes *)attributes {
    UICollectionViewLayoutAttributes *result = %orig;
    return result;
}
- (void)prepareForReuse {
    %orig;
    objc_setAssociatedObject(self, &kDFTrackKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(self, &kDFLookupKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    UIView *view = (UIView *)self;
    view.alpha = 1;
    view.userInteractionEnabled = YES;
    DFBadgeLabel *badge = objc_getAssociatedObject(view, &kDFBadgeKey);
    badge.trackID = nil;
    [badge setBadgeText:@"…"];
    badge.hidden = YES;
}
%end

%hook _TtC12Element_List18CollectionViewCell
- (void)layoutSubviews {
    %orig;
    DFApplyCell((UIView *)self);
}
- (UICollectionViewLayoutAttributes *)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes *)attributes {
    UICollectionViewLayoutAttributes *result = %orig;
    if (DFShouldCollapse((UIView *)self)) result.size = CGSizeMake(result.size.width, 0.01);
    return result;
}
- (void)prepareForReuse {
    %orig;
    objc_setAssociatedObject(self, &kDFTrackKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(self, &kDFLookupKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    UIView *view = (UIView *)self;
    view.alpha = 1;
    view.userInteractionEnabled = YES;
    DFBadgeLabel *badge = objc_getAssociatedObject(view, &kDFBadgeKey);
    badge.trackID = nil;
    badge.hidden = YES;
}
%end

%ctor {
    df_playbackLock = [NSObject new];
    df_pendingLookups = [NSMutableDictionary dictionary];
    df_trackByKey = [NSMutableDictionary dictionary];
    df_tracksByTitle = [NSMutableDictionary dictionary];
    df_metadata = [NSMutableDictionary dictionary];
    %init;
    SGLog(@"full companion loaded");
    SGRequireClasses(@[
        @"SPTEsperantoPlayer",
        @"SPTLinkDispatcherImplementation",
        @"_TtC18NowPlaying_BarImpl27NowPlayingBarViewController",
        @"_TtC35ListUXPlatform_FreeTierPlaylistImpl25ElementCollectionViewCell",
        @"_TtC12Element_List18CollectionViewCell",
    ]);
}
