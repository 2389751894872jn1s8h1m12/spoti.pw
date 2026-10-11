#import "Core/SGCore.h"
#import "Headers/SPTPlayer.h"
#import "Headers/SPTLinkDispatcherImplementation.h"
#import "Shared/DistroFind/DistroFind.h"
#import "Shared/DistroFind/DistroFindData.h"
#import "Shared/DistroFind/DistroFindServer.h"
#import "DFChip.h"
#import <objc/message.h>

// Posted with the new track id whenever the playing track changes, and with a track id whenever that
// track's distributor has been read.
NSString *const DFCurrentTrackChangedNotification = @"DistroFind.CurrentTrackChanged";
NSString *const DFMetadataReadyNotification = @"DistroFind.MetadataReady";

static NSString *const kVydiaUUID = @"9c290842b7fa4396bb0dcb3ad95634f5";
static NSArray<NSString *> *kTitleIDs(void) { return @[@"Track.Row.Content.Title", @"Granular.Title"]; }
static NSArray<NSString *> *kSubtitleIDs(void) { return @[@"Track.Row.Content.Subtitle", @"Granular.Subtitle"]; }

static __weak SPTPlayerTrack *df_currentTrack;
static NSString *df_currentTrackID;
static __weak SPTLinkDispatcherImplementation *df_linkDispatcher;
static NSMutableDictionary<NSString *, SGDistroMetadata *> *df_metadata;
static NSString *df_filter = @"";
static char kDFTrackKey, kDFBadgeKey, kDFLookupKey, kDFFadedKey, kDFDimmedKey;
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

static NSString *DFCurrentTrackID(void) {
    NSString *trackID = DFTrackIDFromURI(df_currentTrack.URI);
    return trackID ?: df_currentTrackID;
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

#pragma mark - resolving, a few at a time

// Every lookup -- rows on screen, rows prefetched ahead of them, the player, an artist scan -- goes
// through these few slots, so a long playlist or a big discography cannot fire hundreds of requests at
// spclient at once and have them come back 429. Urgent lookups (what is on screen) jump the queue, the
// newest first, so the rows the user scrolled to fill in before the ones they scrolled past.
static const NSUInteger kDFResolveSlots = 4;
static NSMutableArray<NSString *> *df_resolveQueue;
static NSMutableDictionary<NSString *, NSDictionary *> *df_pendingAlbums;
static NSUInteger df_resolveActive;

static void DFResolvePump(void);

static void DFResolveFinished(NSString *trackID, SGDistroMetadata *resolved, NSError *failure) {
    if (resolved) {
        df_metadata[trackID] = resolved;
        [[NSNotificationCenter defaultCenter] postNotificationName:DFMetadataReadyNotification object:trackID];
    } else if (failure) {
        SGLog(@"DistroFind metadata lookup failed, status %ld", (long)failure.code);
    }
    NSArray *callbacks = [df_pendingLookups[trackID] copy];
    [df_pendingLookups removeObjectForKey:trackID];
    if (df_resolveActive) df_resolveActive--;
    if (resolved) DFRefreshVisible();
    for (void (^callback)(SGDistroMetadata *, NSError *) in callbacks) callback(resolved, failure);
    DFResolvePump();
}

static void DFResolveStart(NSString *trackID) {
    NSDictionary *album = df_pendingAlbums[trackID];
    [df_pendingAlbums removeObjectForKey:trackID];
    df_resolveActive++;
    SGDistroMetadataCompletion got = ^(SGDistroMetadata *meta, NSError *error) {
        if (meta && !error && [meta.licensorUUID isEqualToString:kVydiaUUID] &&
            !meta.likelyDistributor.length && meta.albumID.length) {
            SGDistroVydiaSubDistributor(meta.albumID, meta.albumName, meta.artist, ^(NSString *sub) {
                if (sub.length) meta.likelyDistributor = sub;
                DFResolveFinished(trackID, meta, nil);
            });
        } else {
            DFResolveFinished(trackID, meta, error);
        }
    };
    if (album.count) SGDistroMetadataForTrackUsingAlbum(trackID, album, got);
    else SGDistroMetadataForTrack(trackID, got);
}

static void DFResolvePump(void) {
    while (df_resolveActive < kDFResolveSlots && df_resolveQueue.count) {
        NSString *next = df_resolveQueue.firstObject;
        [df_resolveQueue removeObjectAtIndex:0];
        DFResolveStart(next);
    }
}

// Each track is fetched once regardless of how many rows, layout passes or scans ask for it.
static void DFResolveFull(NSString *trackID, BOOL urgent, NSDictionary *album,
                          void (^completion)(SGDistroMetadata *meta, NSError *error)) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ DFResolveFull(trackID, urgent, album, completion); });
        return;
    }
    if (trackID.length != 22) {
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
        NSUInteger queued = [df_resolveQueue indexOfObject:trackID];
        if (queued != NSNotFound) {
            if (album.count && !df_pendingAlbums[trackID]) df_pendingAlbums[trackID] = album;
            if (urgent && queued > 0) {
                [df_resolveQueue removeObjectAtIndex:queued];
                [df_resolveQueue insertObject:trackID atIndex:0];
            }
        }
        return;
    }
    pending = [NSMutableArray array];
    if (completion) [pending addObject:[completion copy]];
    df_pendingLookups[trackID] = pending;
    if (album.count) df_pendingAlbums[trackID] = album;
    if (urgent) [df_resolveQueue insertObject:trackID atIndex:0];
    else [df_resolveQueue addObject:trackID];
    DFResolvePump();
}

static void DFResolve(NSString *trackID, void (^completion)(SGDistroMetadata *meta, NSError *error)) {
    DFResolveFull(trackID, YES, nil, completion);
}

// For DFVisibleRowLookup.m, which reads titles off the same cache to match rows to their source.
void DFLookupMetadata(NSString *trackID, BOOL urgent, void (^done)(SGDistroMetadata *meta)) {
    DFResolveFull(trackID, urgent, nil, ^(SGDistroMetadata *meta, NSError *error) {
        if (done) done(meta);
    });
}

#pragma mark - presenting

static UIViewController *DFTopController(void) {
    UIWindow *window = UIApplication.sharedApplication.keyWindow;
    if (!window) for (UIWindow *candidate in UIApplication.sharedApplication.windows) if (!candidate.hidden) { window = candidate; break; }
    UIViewController *vc = window.rootViewController;
    while (vc) {
        if (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) { vc = vc.presentedViewController; continue; }
        if ([vc isKindOfClass:UINavigationController.class] && ((UINavigationController *)vc).visibleViewController) { vc = ((UINavigationController *)vc).visibleViewController; continue; }
        if ([vc isKindOfClass:UITabBarController.class] && ((UITabBarController *)vc).selectedViewController) { vc = ((UITabBarController *)vc).selectedViewController; continue; }
        break;
    }
    return vc;
}

// Spotify is dark throughout, and a sheet presented over the player inherits the system's appearance,
// which would turn it light in light mode.
static void DFPresentSheet(UIViewController *root, void (^completion)(void)) {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [DFTopController() presentViewController:nav animated:YES completion:completion];
}

static BOOL DFOpenURI(NSString *uri) {
    NSURL *url = [NSURL URLWithString:uri];
    id dispatcher = df_linkDispatcher;
    SEL sel = @selector(navigateToURI:options:interactionID:);
    if (!url || ![dispatcher respondsToSelector:sel]) return NO;
    ((void (*)(id, SEL, id, long long, id))objc_msgSend)(dispatcher, sel, url, 0, nil);
    return YES;
}

// Opening a release from one of the sheets: the sheet goes first, or Spotify would navigate behind it.
static void DFOpenFromSheet(UIViewController *controller, NSString *uri) {
    if (!uri.length) return;
    UIViewController *sheet = controller.navigationController ?: controller;
    if (sheet.presentingViewController) {
        [sheet.presentingViewController dismissViewControllerAnimated:YES completion:^{ DFOpenURI(uri); }];
    } else {
        DFOpenURI(uri);
    }
}

#pragma mark - the rows' badges

// The first label with text at or under `root`, nearest first.
static UILabel *DFLabelInside(UIView *root) {
    if (!root) return nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSUInteger visited = 0;
    while (queue.count && visited++ < 40) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([view isKindOfClass:UILabel.class] && ((UILabel *)view).text.length) return (UILabel *)view;
        [queue addObjectsFromArray:view.subviews];
    }
    return nil;
}

// Bounded, and never into a nested list: a Home shelf is a cell holding a whole carousel of cells.
static UIView *DFFindIdentifier(UIView *root, NSArray<NSString *> *needles, NSInteger depth) {
    if (!root || depth < 0) return nil;
    NSString *identifier = root.accessibilityIdentifier;
    if (identifier.length) for (NSString *needle in needles) if ([identifier containsString:needle]) return root;
    for (UIView *sub in root.subviews) {
        if ([sub isKindOfClass:UIScrollView.class]) continue;
        UIView *found = DFFindIdentifier(sub, needles, depth - 1);
        if (found) return found;
    }
    return nil;
}

static CGFloat DFTextWidth(UILabel *label) {
    if (label.attributedText.length) return ceil(label.attributedText.size.width);
    if (!label.text.length) return 0;
    return ceil([label.text sizeWithAttributes:@{NSFontAttributeName: label.font ?: [UIFont systemFontOfSize:15]}].width);
}

// The view that holds the row's text: the nearest one holding both the title and the artist.
static UIView *DFTextColumn(UIView *title, UIView *artist) {
    if (!artist) return title.superview;
    for (UIView *view = title.superview; view; view = view.superview) {
        if ([artist isDescendantOfView:view]) return view;
    }
    return nil;
}

// Where the row's text column ends, measured on the row rather than assumed, so the badge never sits
// under the Save/+ button whatever the row carries: the end of the view holding the title and the
// artist, and the left edge of the first thing at the trailing end -- a control, Spotify's ⋯, or any
// small identified piece that is not text (an Encore button that takes its taps through a recognizer
// is not a UIControl).
//
// The column only counts when it is the row's flexible text area -- wider than the text it holds, or
// cutting that text short -- not a box that just hugs a short title.
static CGFloat DFColumnRight(UIView *cell, UIView *parent, CGRect titleRect, UIView *textColumn,
                             CGFloat textEnd, BOOL truncated, UIView *badge) {
    CGFloat right = parent.bounds.size.width - 12;
    if (textColumn && textColumn != cell && textColumn != parent) {
        CGRect column = [textColumn convertRect:textColumn.bounds toView:parent];
        BOOL flexible = truncated || CGRectGetMaxX(column) >= textEnd + 40;
        if (flexible && CGRectGetMaxX(column) > CGRectGetMinX(titleRect) + 40) right = MIN(right, CGRectGetMaxX(column));
    }
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:cell];
    NSUInteger visited = 0;
    while (queue.count && visited++ < 160) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (view == badge || [view isKindOfClass:UIScrollView.class]) continue;
        if (view != cell && !view.hidden && view.alpha > 0.01 && ![view isKindOfClass:UILabel.class] &&
            (!textColumn || ![textColumn isDescendantOfView:view])) {
            CGRect frame = [view convertRect:view.bounds toView:parent];
            BOOL control = [view isKindOfClass:UIControl.class] || [view.accessibilityIdentifier containsString:@"ContextMenuButton"];
            BOOL accessory = view.accessibilityIdentifier.length && frame.size.width <= 64 && frame.size.height >= 12 &&
                             (!textColumn || ![view isDescendantOfView:textColumn]);
            if ((control || accessory) && frame.size.width > 0 && frame.size.width < parent.bounds.size.width * 0.4 &&
                CGRectGetMinX(frame) > CGRectGetMinX(titleRect) + 40) {
                right = MIN(right, CGRectGetMinX(frame));
                continue;
            }
        }
        [queue addObjectsFromArray:view.subviews];
    }
    return right - 8;
}

// Fades a label's text out before `visible` points, for a row whose title and artist both run to the
// controls. Our mask only: a label that already carries one of Spotify's is left alone (NO).
static BOOL DFFadeLabel(UILabel *label, CGFloat visible) {
    if (!label) return YES;
    CALayer *mask = label.layer.mask;
    BOOL ours = [mask.name isEqualToString:@"df.fade"];
    if (visible <= 0) {
        if (ours) label.layer.mask = nil;
        return YES;
    }
    if (mask && !ours) return NO;
    CAGradientLayer *fade = ours ? (CAGradientLayer *)mask : [CAGradientLayer layer];
    CGFloat width = MAX(1, label.bounds.size.width);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    fade.name = @"df.fade";
    fade.frame = label.bounds;
    fade.startPoint = CGPointMake(0, 0.5);
    fade.endPoint = CGPointMake(1, 0.5);
    fade.colors = @[(__bridge id)UIColor.blackColor.CGColor, (__bridge id)UIColor.blackColor.CGColor,
                    (__bridge id)UIColor.clearColor.CGColor, (__bridge id)UIColor.clearColor.CGColor];
    fade.locations = @[@0, @(MAX(0, (visible - 14) / width)), @(MIN(1, visible / width)), @1];
    if (!ours) label.layer.mask = fade;
    [CATransaction commit];
    return YES;
}

static void DFClearRowFade(UIView *cell) {
    UILabel *faded = objc_getAssociatedObject(cell, &kDFFadedKey);
    if (faded) DFFadeLabel(faded, 0);
    objc_setAssociatedObject(cell, &kDFFadedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static DFChip *DFRowChip(UIView *cell, UIView *parent) {
    DFChip *chip = objc_getAssociatedObject(cell, &kDFBadgeKey);
    if (!chip) {
        chip = [[DFChip alloc] initWithFontSize:10];
        chip.backgroundColor = [UIColor colorWithWhite:1 alpha:0.13];
        chip.layer.zPosition = 50;
        chip.accessibilityIdentifier = @"DistroFind.Row.Badge";
        chip.onTap = ^(DFChip *tapped) {
            if (tapped.trackID.length) DFPresentDashboard(tapped.trackID);
        };
        objc_setAssociatedObject(cell, &kDFBadgeKey, chip, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Last among the row's views, so it is the one a tap on it reaches.
    if (chip.superview != parent) [parent addSubview:chip];
    else if (parent.subviews.lastObject != chip) [parent bringSubviewToFront:chip];
    return chip;
}

static void DFHideRowChip(UIView *cell) {
    DFChip *chip = objc_getAssociatedObject(cell, &kDFBadgeKey);
    chip.trackID = nil;
    chip.hidden = YES;
    DFClearRowFade(cell);
}

static BOOL DFFilterRejects(SGDistroMetadata *meta) {
    if (!df_filter.length || !meta) return NO;
    NSString *name = SGDistroDisplayName(meta).lowercaseString ?: @"";
    NSString *parent = meta.distributor.lowercaseString ?: @"";
    NSString *needle = df_filter.lowercaseString;
    return ![name containsString:needle] && ![parent containsString:needle];
}

// Only while a filter is on, and only back to what the row had: Spotify dims unplayable rows itself.
static void DFApplyFilter(UIView *cell, SGDistroMetadata *meta) {
    BOOL reject = DFFilterRejects(meta);
    BOOL dimmed = [objc_getAssociatedObject(cell, &kDFDimmedKey) boolValue];
    if (reject == dimmed) return;
    cell.alpha = reject ? 0.15 : 1;
    cell.userInteractionEnabled = !reject;
    objc_setAssociatedObject(cell, &kDFDimmedKey, reject ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void DFApplyCell(UIView *cell) {
    if (!cell.window) return;
    UIView *titleView = DFFindIdentifier(cell, kTitleIDs(), 10);
    if (!titleView) return;
    UILabel *titleLabel = DFLabelInside(titleView);
    NSString *title = titleLabel.text;
    if (!title.length) return;
    UILabel *artistLabel = DFLabelInside(DFFindIdentifier(cell, kSubtitleIDs(), 10));
    NSString *artist = artistLabel.text ?: @"";

    // A track id belongs to the title and artist it was found for. A list that reconfigures a cell in
    // place, without reusing it, gets a fresh lookup instead of the previous row's badge.
    NSString *lookupKey = DFKey(title, artist);
    if (![objc_getAssociatedObject(cell, &kDFLookupKey) isEqualToString:lookupKey]) {
        objc_setAssociatedObject(cell, &kDFLookupKey, lookupKey, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(cell, &kDFTrackKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        __weak UIView *weakCell = cell;
        DFRowResolveTrack(title, artist, cell, ^(NSString *verified) {
            UIView *row = weakCell;
            if (!row || verified.length != 22) return;
            if (![objc_getAssociatedObject(row, &kDFLookupKey) isEqualToString:lookupKey]) return;
            objc_setAssociatedObject(row, &kDFTrackKey, verified, OBJC_ASSOCIATION_COPY_NONATOMIC);
            [row setNeedsLayout];
        });
    }
    NSString *trackID = objc_getAssociatedObject(cell, &kDFTrackKey);
    if (trackID.length != 22) {
        DFHideRowChip(cell);
        return;
    }

    UIView *parent = [cell isKindOfClass:UICollectionViewCell.class] ? ((UICollectionViewCell *)cell).contentView : cell;
    DFChip *chip = DFRowChip(cell, parent);
    chip.trackID = trackID;
    SGDistroMetadata *meta = df_metadata[trackID];
    [chip setChipText:meta ? (SGDistroDisplayName(meta) ?: @"Unknown") : @"…"];

    const CGFloat height = 16, gap = 6, minWidth = 40, maxWidth = 104;
    CGFloat wanted = MIN(maxWidth, MAX(minWidth, [chip fittingWidth]));
    CGRect titleRect = [titleLabel convertRect:titleLabel.bounds toView:parent];
    CGFloat titleText = DFTextWidth(titleLabel);
    CGRect artistBox = artistLabel ? [artistLabel convertRect:artistLabel.bounds toView:parent] : CGRectNull;
    CGFloat artistWidth = artistLabel ? DFTextWidth(artistLabel) : 0;
    CGFloat textEnd = MAX(CGRectGetMinX(titleRect) + MIN(titleText, titleRect.size.width),
                          artistLabel ? CGRectGetMinX(artistBox) + MIN(artistWidth, artistBox.size.width) : 0);
    BOOL truncated = titleText > titleRect.size.width + 0.5 || (artistLabel && artistWidth > artistBox.size.width + 0.5);
    CGFloat right = DFColumnRight(cell, parent, titleRect, DFTextColumn(titleLabel, artistLabel), textEnd, truncated, chip);
    CGRect frame = CGRectNull;
    UILabel *fade = nil;
    CGFloat fadeAt = 0;

    // After the title, when the whole title shows and the chip still fits before the controls.
    CGFloat x = CGRectGetMinX(titleRect) + MIN(titleText, titleRect.size.width) + gap;
    if (titleText <= titleRect.size.width + 0.5 && x + minWidth <= right) {
        frame = CGRectMake(x, CGRectGetMidY(titleRect) - height / 2, MIN(wanted, right - x), height);
    } else if (artistLabel) {
        // Else after the artist line, where it ends.
        CGRect artistRect = [artistLabel convertRect:artistLabel.bounds toView:parent];
        CGFloat artistText = DFTextWidth(artistLabel);
        CGFloat ax = CGRectGetMinX(artistRect) + MIN(artistText, artistRect.size.width) + gap;
        CGFloat y = CGRectGetMidY(artistRect) - height / 2;
        if (ax + minWidth <= right) {
            frame = CGRectMake(ax, y, MIN(wanted, right - ax), height);
        } else {
            // Both lines run to the controls: the chip takes the end of the artist line and the artist
            // fades out before it, so nothing is drawn over Spotify's text.
            CGFloat width = MIN(wanted, MAX(minWidth, 64));
            CGFloat cx = right - width;
            if (cx > CGRectGetMinX(artistRect) + 40) {
                frame = CGRectMake(cx, y, width, height);
                fade = artistLabel;
                fadeAt = cx - gap - CGRectGetMinX(artistRect);
            }
        }
    }

    UILabel *previous = objc_getAssociatedObject(cell, &kDFFadedKey);
    if (previous && previous != fade) DFClearRowFade(cell);
    if (fade) {
        if (DFFadeLabel(fade, fadeAt)) objc_setAssociatedObject(cell, &kDFFadedKey, fade, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        else frame = CGRectNull;
    }
    if (CGRectIsNull(frame) || frame.size.width < minWidth - 0.5) {
        chip.hidden = YES;
    } else {
        frame = CGRectMake(round(frame.origin.x), round(MAX(1, frame.origin.y)), round(frame.size.width), height);
        if (!CGRectEqualToRect(chip.frame, frame)) chip.frame = frame;
        chip.hidden = NO;
    }
    DFApplyFilter(cell, meta);
    if (!meta) DFResolve(trackID, nil);
}

static void DFResetCell(UIView *cell) {
    objc_setAssociatedObject(cell, &kDFTrackKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(cell, &kDFLookupKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    if ([objc_getAssociatedObject(cell, &kDFDimmedKey) boolValue]) {
        cell.alpha = 1;
        cell.userInteractionEnabled = YES;
        objc_setAssociatedObject(cell, &kDFDimmedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    DFHideRowChip(cell);
}

static BOOL DFShouldCollapse(UIView *cell) {
    NSString *trackID = objc_getAssociatedObject(cell, &kDFTrackKey);
    return trackID.length && DFFilterRejects(df_metadata[trackID]);
}

#pragma mark - small pages

@interface DFTextController : UIViewController
@property (nonatomic, copy) NSString *openURI;
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
    if (self.openURI.length) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Open"
            style:UIBarButtonItemStylePlain target:self action:@selector(open)];
    }
}
- (void)open {
    DFOpenFromSheet(self, self.openURI);
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
    if (item[@"uri"]) DFOpenFromSheet(self, item[@"uri"]);
}
@end

#pragma mark - an artist's releases

static NSArray *DFArray(id value) { return [value isKindOfClass:NSArray.class] ? value : @[]; }
static NSDictionary *DFDict(id value) { return [value isKindOfClass:NSDictionary.class] ? value : nil; }
static NSString *DFString(id value) { return [value isKindOfClass:NSString.class] ? value : nil; }

@interface DFRelease : NSObject
@property (nonatomic, copy) NSString *albumID, *gid, *name, *type, *year, *label, *firstTrack, *upc;
@property (nonatomic, strong) SGDistroMetadata *distro;
@property (nonatomic, copy) NSArray<NSString *> *available, *blocked;
@property (nonatomic) BOOL restricted, loaded, failed;
@end
@implementation DFRelease
@end

// Spotify's restrictions name markets two letters at a time. A market is open when any one restriction
// lets it in (each restriction can be for a different tier); a release with no restriction is everywhere.
static void DFApplyRestrictions(DFRelease *rel, NSArray *restrictions) {
    NSArray<NSString *> *markets = SGDistroSpotifyMarkets();
    NSMutableArray<NSDictionary *> *rules = [NSMutableArray array];
    for (NSDictionary *restriction in restrictions) {
        if (!DFDict(restriction)) continue;
        NSString *allowed = DFString(restriction[@"countries_allowed"]);
        NSString *forbidden = DFString(restriction[@"countries_forbidden"]);
        if (!allowed && !forbidden) continue;
        NSMutableSet *allow = allowed ? [NSMutableSet set] : nil, *deny = [NSMutableSet set];
        for (NSUInteger i = 0; i + 1 < allowed.length; i += 2) [allow addObject:[allowed substringWithRange:NSMakeRange(i, 2)].uppercaseString];
        for (NSUInteger i = 0; i + 1 < forbidden.length; i += 2) [deny addObject:[forbidden substringWithRange:NSMakeRange(i, 2)].uppercaseString];
        [rules addObject:allow ? @{@"allow": allow, @"deny": deny} : @{@"deny": deny}];
    }
    rel.restricted = rules.count > 0;
    if (!rel.restricted) {
        rel.available = markets;
        rel.blocked = @[];
        return;
    }
    NSMutableArray *available = [NSMutableArray array], *blocked = [NSMutableArray array];
    for (NSString *market in markets) {
        BOOL reachable = NO;
        for (NSDictionary *rule in rules) {
            NSSet *allow = rule[@"allow"];
            if ((!allow || [allow containsObject:market]) && ![rule[@"deny"] containsObject:market]) { reachable = YES; break; }
        }
        [reachable ? available : blocked addObject:market];
    }
    rel.available = available;
    rel.blocked = blocked;
}

static BOOL DFRegioned(DFRelease *rel) {
    return rel.loaded && rel.restricted && (rel.blocked.count > 1 || !rel.available.count);
}

static NSString *DFAvailabilityLine(DFRelease *rel) {
    if (!rel.loaded) return rel.failed ? @"Could not be read" : @"";
    if (!rel.available.count) return @"Not available in any market";
    if (!DFRegioned(rel)) return @"Available worldwide";
    if (rel.available.count <= rel.blocked.count)
        return [NSString stringWithFormat:@"Only in %lu markets", (unsigned long)rel.available.count];
    return [NSString stringWithFormat:@"Blocked in %lu markets", (unsigned long)rel.blocked.count];
}

static NSString *DFMarketList(NSArray<NSString *> *codes, NSUInteger limit) {
    if (codes.count <= limit) return [codes componentsJoinedByString:@", "];
    return [[[codes subarrayWithRange:NSMakeRange(0, limit)] componentsJoinedByString:@", "]
        stringByAppendingFormat:@" +%lu", (unsigned long)(codes.count - limit)];
}

static void DFFillRelease(DFRelease *rel, NSDictionary *album) {
    rel.loaded = YES;
    rel.name = DFString(album[@"name"]) ?: rel.name;
    NSString *type = DFString(album[@"type"]);
    if (type.length) rel.type = type.lowercaseString;
    rel.label = DFString(album[@"label"]) ?: @"";
    NSDictionary *date = DFDict(album[@"date"]);
    if ([date[@"year"] integerValue]) rel.year = [NSString stringWithFormat:@"%ld", (long)[date[@"year"] integerValue]];
    for (NSDictionary *external in DFArray(album[@"external_id"])) {
        if ([[DFString(DFDict(external)[@"type"]) lowercaseString] isEqualToString:@"upc"]) rel.upc = DFString(external[@"id"]);
    }
    for (NSDictionary *disc in DFArray(album[@"disc"])) {
        NSDictionary *track = DFDict(DFArray(DFDict(disc)[@"track"]).firstObject);
        rel.firstTrack = SGDistroSpotifyIDForGID(DFString(track[@"gid"]));
        if (rel.firstTrack.length) break;
    }
    DFApplyRestrictions(rel, DFArray(album[@"restriction"]));
}

// Every release the artist has of their own: albums, singles and EPs, compilations. Each group can hold
// several versions of one release, one per set of markets -- which is what Regioned Releases is after.
static NSArray<DFRelease *> *DFReleasesOfArtist(NSDictionary *artist) {
    NSMutableArray<DFRelease *> *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSArray *groups = @[@[@"album_group", @"album"], @[@"single_group", @"single"], @[@"compilation_group", @"compilation"]];
    for (NSArray *pair in groups) {
        for (NSDictionary *group in DFArray(artist[pair[0]])) {
            for (NSDictionary *album in DFArray(DFDict(group)[@"album"])) {
                NSString *gid = DFString(DFDict(album)[@"gid"]);
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
    return out;
}

// Runs `work` for 0..count-1, at most `width` at a time, then `done`, all on the main queue. Each work
// item calls its `finished` once; the pool lives as long as one of them is outstanding.
@interface DFPool : NSObject
@property (nonatomic) NSUInteger count, width, next, completed;
@property (nonatomic, copy) void (^work)(NSUInteger index, dispatch_block_t finished);
@property (nonatomic, copy) dispatch_block_t done;
- (void)launch;
@end

@implementation DFPool
- (void)launch {
    while (self.work && self.next < self.count && self.next - self.completed < self.width) {
        NSUInteger index = self.next;
        self.next = index + 1;
        __block BOOL called = NO;
        DFPool *pool = self;
        void (^work)(NSUInteger, dispatch_block_t) = self.work;
        work(index, ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                if (called) return;
                called = YES;
                pool.completed = pool.completed + 1;
                if (pool.completed < pool.count) {
                    [pool launch];
                    return;
                }
                dispatch_block_t done = pool.done;
                pool.work = nil;
                pool.done = nil;
                if (done) done();
            });
        });
    }
}
@end

static void DFRunPool(NSUInteger count, NSUInteger width, void (^work)(NSUInteger index, dispatch_block_t finished), dispatch_block_t done) {
    if (!count) {
        done();
        return;
    }
    DFPool *pool = [DFPool new];
    pool.count = count;
    pool.width = MAX((NSUInteger)1, width);
    pool.work = work;
    pool.done = done;
    [pool launch];
}

typedef NS_ENUM(NSInteger, DFArtistTool) {
    DFArtistToolScan,
    DFArtistToolRegions,
};

// Artist Scan (every release and who distributes it) and Regioned Releases (the releases that are not
// in every market, and where they are). Both read the artist's discography from Spotify's own
// metadata; the markets come with each release, so Regioned Releases needs nothing beyond it.
@interface DFArtistToolController : UITableViewController
- (instancetype)initWithArtistID:(NSString *)artistID name:(NSString *)name tool:(DFArtistTool)tool;
@end

@implementation DFArtistToolController {
    NSString *_artistID, *_artistName;
    DFArtistTool _tool;
    NSArray<DFRelease *> *_releases;
    NSError *_error;
    NSUInteger _done;
    BOOL _finished, _cancelled, _reloadQueued;
}

- (instancetype)initWithArtistID:(NSString *)artistID name:(NSString *)name tool:(DFArtistTool)tool {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _artistID = [artistID copy];
        _artistName = [name copy];
        _tool = tool;
        self.title = tool == DFArtistToolScan ? @"Artist Scan" : @"Regioned Releases";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 60;
    if (self.navigationController.viewControllers.firstObject == self) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
            target:self action:@selector(close)];
    }
    [self start];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isMovingFromParentViewController || self.navigationController.isBeingDismissed || self.isBeingDismissed) _cancelled = YES;
}

- (void)reloadSoon {
    if (_reloadQueued) return;
    _reloadQueued = YES;
    __weak DFArtistToolController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DFArtistToolController *me = weakSelf;
        if (!me) return;
        me->_reloadQueued = NO;
        [me.tableView reloadData];
    });
}

- (void)start {
    __weak DFArtistToolController *weakSelf = self;
    SGDistroRawMetadataForSpotifyID(@"artist", _artistID, ^(NSDictionary *artist, NSError *error) {
        DFArtistToolController *me = weakSelf;
        if (!me || me->_cancelled) return;
        if (!artist) {
            me->_error = error ?: [NSError errorWithDomain:@"spoti.pw.distrofind" code:2
                userInfo:@{NSLocalizedDescriptionKey: @"Spotify did not return this artist."}];
            me->_finished = YES;
            [me.tableView reloadData];
            return;
        }
        if (DFString(artist[@"name"]).length) me->_artistName = DFString(artist[@"name"]);
        NSArray<DFRelease *> *releases = DFReleasesOfArtist(artist);
        me->_releases = releases;
        [me.tableView reloadData];
        BOOL scan = me->_tool == DFArtistToolScan;
        DFRunPool(releases.count, 4, ^(NSUInteger index, dispatch_block_t finished) {
            DFArtistToolController *current = weakSelf;
            DFRelease *rel = releases[index];
            if (!current || current->_cancelled) { finished(); return; }
            SGDistroRawMetadataForGID(@"album", rel.gid, ^(NSDictionary *album, NSError *albumError) {
                if (album) DFFillRelease(rel, album);
                else rel.failed = YES;
                void (^counted)(void) = ^{
                    DFArtistToolController *live = weakSelf;
                    if (live) {
                        live->_done++;
                        [live reloadSoon];
                    }
                    finished();
                };
                DFArtistToolController *live = weakSelf;
                if (scan && album && rel.firstTrack.length && live && !live->_cancelled) {
                    DFResolveFull(rel.firstTrack, NO, album, ^(SGDistroMetadata *meta, NSError *metaError) {
                        rel.distro = meta;
                        counted();
                    });
                } else {
                    counted();
                }
            });
        }, ^{
            DFArtistToolController *last = weakSelf;
            if (!last) return;
            last->_finished = YES;
            [last.tableView reloadData];
            SGLog(@"DistroFind %@ read %lu releases", scan ? @"artist scan" : @"regioned releases", (unsigned long)releases.count);
        });
    });
}

- (NSString *)statusLine {
    if (_error) return _error.localizedDescription ?: @"The scan failed.";
    if (!_releases) return @"Reading the artist's releases…";
    if (!_finished) return [NSString stringWithFormat:@"Reading release %lu of %lu…", (unsigned long)MIN(_done + 1, _releases.count), (unsigned long)_releases.count];
    return [NSString stringWithFormat:@"%lu releases read", (unsigned long)_releases.count];
}

- (NSArray<DFRelease *> *)shownReleases {
    if (_tool == DFArtistToolScan) return _releases ?: @[];
    NSMutableArray *regioned = [NSMutableArray array];
    for (DFRelease *rel in _releases) if (DFRegioned(rel)) [regioned addObject:rel];
    return regioned;
}

// Distributor name -> how many releases, most first.
- (NSArray<NSArray *> *)distributorCounts {
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    for (DFRelease *rel in _releases) {
        if (!rel.distro) continue;
        NSString *name = SGDistroDisplayName(rel.distro) ?: @"Unknown";
        counts[name] = @(counts[name].integerValue + 1);
    }
    NSArray *names = [counts keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) { return [b compare:a]; }];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *name in names) [out addObject:@[name, counts[name]]];
    return out;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1 + (_tool == DFArtistToolScan ? (NSInteger)[self distributorCounts].count : 0);
    NSInteger shown = (NSInteger)[self shownReleases].count;
    return shown ?: (_finished && _releases ? 1 : 0);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return _artistName.length ? _artistName : @"Artist";
    if (_tool == DFArtistToolScan) return @"Releases";
    return @"Not in every market";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != 1 || _tool != DFArtistToolRegions || !_finished) return nil;
    return @"Markets come from Spotify's own release metadata. A release missing from one market only is counted as worldwide.";
}

- (UITableViewCell *)cellIn:(UITableView *)tableView style:(UITableViewCellStyle)style {
    NSString *reuse = style == UITableViewCellStyleValue1 ? @"df.value" : @"df.subtitle";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:style reuseIdentifier:reuse];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryView = nil;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            UITableViewCell *cell = [self cellIn:tableView style:UITableViewCellStyleSubtitle];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
            if (_tool == DFArtistToolScan) {
                NSUInteger distributors = [self distributorCounts].count;
                cell.textLabel.text = _finished && _releases ? [NSString stringWithFormat:@"%lu %@ across %lu releases",
                    (unsigned long)distributors, distributors == 1 ? @"distributor" : @"distributors", (unsigned long)_releases.count] : @"Scanning";
            } else {
                NSUInteger regioned = [self shownReleases].count;
                cell.textLabel.text = _finished && _releases ? [NSString stringWithFormat:@"%lu of %lu releases are region-locked",
                    (unsigned long)regioned, (unsigned long)_releases.count] : @"Checking markets";
            }
            cell.detailTextLabel.text = [self statusLine];
            if (!_finished) {
                UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
                [spinner startAnimating];
                cell.accessoryView = spinner;
            }
            return cell;
        }
        NSArray *entry = [self distributorCounts][indexPath.row - 1];
        UITableViewCell *cell = [self cellIn:tableView style:UITableViewCellStyleValue1];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.font = [UIFont systemFontOfSize:15];
        cell.textLabel.text = entry[0];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@", entry[1]];
        return cell;
    }

    NSArray<DFRelease *> *shown = [self shownReleases];
    UITableViewCell *cell = [self cellIn:tableView style:UITableViewCellStyleSubtitle];
    cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    if (!shown.count) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = _tool == DFArtistToolScan ? @"No releases found" : @"No regioned releases found";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu releases checked", (unsigned long)_releases.count];
        return cell;
    }
    DFRelease *rel = shown[indexPath.row];
    cell.textLabel.text = rel.name ?: @"Untitled";
    NSMutableArray *parts = [NSMutableArray array];
    if (_tool == DFArtistToolScan) {
        if (rel.distro) [parts addObject:SGDistroDisplayName(rel.distro) ?: @"Unknown"];
        else if (rel.loaded && !rel.firstTrack.length) [parts addObject:@"No tracks"];
        else if (rel.failed) [parts addObject:@"Could not be read"];
        else [parts addObject:@"…"];
    } else {
        [parts addObject:DFAvailabilityLine(rel)];
    }
    if (rel.type.length) [parts addObject:rel.type.capitalizedString];
    if (rel.year.length) [parts addObject:rel.year];
    if (rel.label.length) [parts addObject:rel.label];
    // Artist Scan says when a release is region-locked too.
    if (_tool == DFArtistToolScan && DFRegioned(rel)) [parts addObject:DFAvailabilityLine(rel)];
    cell.detailTextLabel.text = [parts componentsJoinedByString:@" · "];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSArray<DFRelease *> *shown = [self shownReleases];
    if (indexPath.section != 1 || indexPath.row >= (NSInteger)shown.count) return;
    DFRelease *rel = shown[indexPath.row];
    NSMutableArray *lines = [NSMutableArray array];
    [lines addObject:rel.name ?: @"Untitled"];
    if (rel.distro) {
        [lines addObject:[NSString stringWithFormat:@"Distributor: %@", SGDistroDisplayName(rel.distro) ?: @"Unknown"]];
        if (rel.distro.distributor.length) [lines addObject:[NSString stringWithFormat:@"Parent: %@", rel.distro.distributor]];
    }
    if (rel.label.length) [lines addObject:[NSString stringWithFormat:@"Label: %@", rel.label]];
    if (rel.year.length) [lines addObject:[NSString stringWithFormat:@"Year: %@", rel.year]];
    if (rel.upc.length) [lines addObject:[NSString stringWithFormat:@"UPC: %@", rel.upc]];
    if (rel.distro.pLine.length) [lines addObject:rel.distro.pLine];
    if (rel.distro.cLine.length) [lines addObject:rel.distro.cLine];
    if (rel.loaded) {
        [lines addObject:@""];
        [lines addObject:DFAvailabilityLine(rel)];
        if (rel.restricted && rel.available.count) [lines addObject:[NSString stringWithFormat:@"\nAvailable (%lu)\n%@", (unsigned long)rel.available.count, DFMarketList(rel.available, 400)]];
        if (rel.blocked.count) [lines addObject:[NSString stringWithFormat:@"\nBlocked (%lu)\n%@", (unsigned long)rel.blocked.count, DFMarketList(rel.blocked, 400)]];
    }
    DFTextController *detail = [[DFTextController alloc] initWithTitle:rel.name ?: @"Release" text:[lines componentsJoinedByString:@"\n"]];
    detail.openURI = rel.albumID.length ? [@"spotify:album:" stringByAppendingString:rel.albumID] : nil;
    [self.navigationController pushViewController:detail animated:YES];
}

@end

#pragma mark - Track Info

@interface DFDashboardController : UITableViewController
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
    __weak DFDashboardController *weakSelf = self;
    DFResolve(trackID, ^(SGDistroMetadata *meta, NSError *error) {
        DFDashboardController *me = weakSelf;
        if (!me) return;
        me.meta = meta;
        [me.tableView reloadData];
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
    return @[@"Track", @"Track tools", @"Distributor filter", @"Artist tools"][section];
}

- (NSArray<NSString *> *)infoValues {
    SGDistroMetadata *m = self.meta;
    BOOL current = [self.trackID isEqualToString:DFCurrentTrackID()];
    NSString *duration = m.durationMs > 0 ? [NSString stringWithFormat:@"%ld:%02ld", (long)(m.durationMs / 60000), (long)((m.durationMs / 1000) % 60)] : @"—";
    NSString *live = m.earliestLiveTimestamp > 0 ? [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:m.earliestLiveTimestamp] dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle] : @"—";
    return @[
        m.title ?: (current ? df_currentTrack.trackTitle : nil) ?: @"—",
        m.artist ?: (current ? df_currentTrack.artistName : nil) ?: @"—",
        SGDistroDisplayName(m) ?: (self.trackID.length ? @"Loading…" : @"—"),
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

// The artists the tools can run on: the track's own credited artists, or while its metadata is still
// loading, the playing track's main artist. [[id, name], ...]
- (NSArray<NSArray<NSString *> *> *)artistChoices {
    NSMutableArray *choices = [NSMutableArray array];
    NSArray *ids = self.meta.trackArtistIDs, *names = self.meta.trackArtistNames;
    for (NSUInteger i = 0; i < ids.count && i < names.count; i++) [choices addObject:@[ids[i], names[i]]];
    if (!choices.count && [self.trackID isEqualToString:DFCurrentTrackID()]) {
        NSString *uri = DFURIString(df_currentTrack.artistURI);
        if ([uri hasPrefix:@"spotify:artist:"] && uri.length == 37)
            [choices addObject:@[[uri substringFromIndex:15], df_currentTrack.artistName ?: @"Artist"]];
    }
    return choices;
}

- (UITableViewCell *)basicCell:(UITableView *)tableView title:(NSString *)title value:(NSString *)value action:(BOOL)action {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"dfdash"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"dfdash"];
    cell.textLabel.text = title;
    cell.detailTextLabel.text = value;
    cell.detailTextLabel.numberOfLines = 0;
    cell.accessoryType = action ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    cell.selectionStyle = action ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
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
    NSArray *choices = [self artistChoices];
    NSString *who = choices.count == 1 ? choices[0][1] : choices.count > 1 ?
        [NSString stringWithFormat:@"Choose from %lu artists", (unsigned long)choices.count] : @"Waiting for the track's artists…";
    return [self basicCell:tableView title:indexPath.row ? @"Regioned Releases" : @"Artist Scan" value:who action:YES];
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
            NSString *url = DFString(DFDict(link)[@"url"]);
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

- (void)openArtistTool:(DFArtistTool)tool from:(NSIndexPath *)indexPath {
    NSArray<NSArray<NSString *> *> *choices = [self artistChoices];
    if (!choices.count) {
        [self showText:tool == DFArtistToolScan ? @"Artist Scan" : @"Regioned Releases"
                  text:@"The track's artists are still loading. Try again in a moment."];
        return;
    }
    void (^run)(NSArray<NSString *> *) = ^(NSArray<NSString *> *choice) {
        DFArtistToolController *page = [[DFArtistToolController alloc] initWithArtistID:choice[0] name:choice[1] tool:tool];
        [self.navigationController pushViewController:page animated:YES];
    };
    if (choices.count == 1) {
        run(choices[0]);
        return;
    }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Which artist?" message:nil
        preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSArray<NSString *> *choice in choices) {
        [sheet addAction:[UIAlertAction actionWithTitle:choice[1] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { run(choice); }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
    sheet.popoverPresentationController.sourceView = cell ?: self.view;
    sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) {
        if (!self.trackID.length) return;
        if (indexPath.row == 0) [self availability];
        else if (indexPath.row == 1) [self otherVersions];
        else if (indexPath.row == 2) [self performance];
        else { [df_metadata removeObjectForKey:self.trackID]; self.meta = nil; [self reloadMetadata]; }
    } else if (indexPath.section == 2) {
        if (indexPath.row == 0) [self setFilter];
        else { df_filter = @""; [self.tableView reloadData]; DFRefreshVisible(); }
    } else if (indexPath.section == 3) {
        [self openArtistTool:indexPath.row ? DFArtistToolRegions : DFArtistToolScan from:indexPath];
    }
}
@end

static void DFPresentDashboard(NSString *trackID) {
    DFPresentSheet([[DFDashboardController alloc] initWithTrackID:trackID], nil);
}

#pragma mark - for DFPlayerArtistUI.x

NSString *DFUICurrentTrackID(void) { return DFCurrentTrackID(); }
NSString *DFUITrackDistributor(NSString *trackID) {
    return trackID.length ? SGDistroDisplayName(df_metadata[trackID]) : nil;
}
void DFUIRequestDistributor(NSString *trackID) {
    if (trackID.length) DFResolve(trackID, nil);
}
void DFUIOpenTrackInfo(NSString *trackID) { DFPresentDashboard(trackID); }
// The artist page's ⋯ rows open the tool straight on that artist.
void DFUIOpenArtistTool(NSString *artistID, BOOL regions) {
    if (artistID.length != 22) return;
    DFPresentSheet([[DFArtistToolController alloc] initWithArtistID:artistID name:nil
        tool:regions ? DFArtistToolRegions : DFArtistToolScan], nil);
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

// Do not call a track property getter synchronously from Spotify's frequently-invoked playback state
// getter, and keep this hook minimal: only enqueue one snapshot.
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
                DFResolve(trackID, nil);
                [[NSNotificationCenter defaultCenter] postNotificationName:DFCurrentTrackChangedNotification object:trackID];
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

// Playlist and Liked Songs rows.
%hook _TtC35ListUXPlatform_FreeTierPlaylistImpl25ElementCollectionViewCell
- (void)layoutSubviews {
    %orig;
    DFApplyCell((UIView *)self);
}
- (void)prepareForReuse {
    %orig;
    DFResetCell((UIView *)self);
}
%end

// Album rows, the artist's popular tracks, and every other Element_List row (which find no source and
// stay without a badge).
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
    DFResetCell((UIView *)self);
}
%end

%ctor {
    df_playbackLock = [NSObject new];
    df_pendingLookups = [NSMutableDictionary dictionary];
    df_pendingAlbums = [NSMutableDictionary dictionary];
    df_resolveQueue = [NSMutableArray array];
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
