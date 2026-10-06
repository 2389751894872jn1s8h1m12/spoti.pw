#import "Core/SGCore.h"
#import "SpotifyTypes.h"
#import "DistroFindRuntime.h"
#import "DistroFindUI.h"
#import "Shared/DistroFind/DistroFind.h"
#import "Shared/DistroFind/DistroFindServer.h"
#import <objc/message.h>

#pragma mark - Shared badge UI

static UIColor *DFBadgeBackground(void) {
    return [UIColor colorWithWhite:0.13 alpha:0.92];
}

static void DFStyleBadge(UIButton *button, CGFloat fontSize) {
    button.backgroundColor = DFBadgeBackground();
    button.layer.cornerRadius = 8;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.clipsToBounds = YES;
    button.contentEdgeInsets = UIEdgeInsetsMake(2, 7, 2, 7);
    button.titleLabel.font = [UIFont systemFontOfSize:fontSize weight:UIFontWeightSemibold];
    button.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [button setTitleColor:[UIColor colorWithRed:0.70 green:0.90 blue:1.0 alpha:1] forState:UIControlStateNormal];
}

static NSString *DFDisplayNameWithVydia(SGDistroMetadata *meta, void (^updated)(NSString *name)) {
    NSString *name = SGDistroDisplayName(meta);
    if (![meta.licensorUUID.lowercaseString isEqualToString:@"9c290842b7fa4396bb0dcb3ad95634f5"] ||
        meta.likelyDistributor.length || !meta.albumID.length) return name;

    SGDistroVydiaSubDistributor(meta.albumID, @"", meta.artist, ^(NSString *sub) {
        if (sub.length && updated) updated(sub);
    });
    return name;
}

#pragma mark - Player + now playing badge

%hook SPTEsperantoPlayer
- (SPTPlayerState *)state {
    SPTPlayerState *state = %orig;
    DFNotePlayerState(state);
    return state;
}
%end

@interface DFNowPlayingBadge : UIButton
@property (nonatomic, weak) UIViewController *hostController;
@property (nonatomic, copy) NSString *trackID;
@end

@implementation DFNowPlayingBadge
- (void)tapped {
    if (self.trackID.length == 22) DFShowTrackActions(self.trackID, DFCurrentTrackTitle(), self.hostController);
}
@end

static char kNowPlayingBadgeKey;

static void DFUpdateNowPlayingBadge(UIViewController *controller) {
    NSString *trackID = DFCurrentTrackID();
    DFNowPlayingBadge *badge = objc_getAssociatedObject(controller, &kNowPlayingBadgeKey);
    if (!badge) {
        badge = [DFNowPlayingBadge buttonWithType:UIButtonTypeSystem];
        badge.hostController = controller;
        badge.accessibilityLabel = @"DistroFind distributor";
        DFStyleBadge(badge, 9.5);
        [badge addTarget:badge action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
        [controller.view addSubview:badge];
        objc_setAssociatedObject(controller, &kNowPlayingBadgeKey, badge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    badge.hidden = !trackID.length;
    if (!trackID.length) return;

    CGFloat maxWidth = MIN(118, MAX(70, controller.view.bounds.size.width * 0.30));
    badge.frame = CGRectMake(MAX(58, controller.view.bounds.size.width - maxWidth - 70),
                             MAX(2, controller.view.bounds.size.height - 21),
                             maxWidth, 18);

    if ([badge.trackID isEqualToString:trackID]) return;
    badge.trackID = trackID;
    [badge setTitle:@"Distro…" forState:UIControlStateNormal];

    NSString *requested = [trackID copy];
    SGDistroMetadataForTrack(trackID, ^(SGDistroMetadata *meta, NSError *error) {
        if (![badge.trackID isEqualToString:requested]) return;
        if (!meta) {
            [badge setTitle:@"Distro ?" forState:UIControlStateNormal];
            return;
        }
        void (^show)(NSString *) = ^(NSString *name) {
            if (![badge.trackID isEqualToString:requested]) return;
            [badge setTitle:name.length ? name : @"Unknown" forState:UIControlStateNormal];
        };
        NSString *name = DFDisplayNameWithVydia(meta, show);
        show(name);
    });
}

%hook _TtC18NowPlaying_BarImpl27NowPlayingBarViewController
- (void)viewDidLayoutSubviews {
    %orig;
    DFUpdateNowPlayingBadge((UIViewController *)self);
}
%end

#pragma mark - Page action button

@interface DFPageButton : UIButton
@property (nonatomic, weak) UIViewController *hostController;
@property (nonatomic, copy) NSString *pageURI;
@end

@implementation DFPageButton
- (void)tapped {
    if (self.hostController && self.pageURI.length) DFShowPageActions(self.hostController, self.pageURI);
}
@end

static char kPageButtonKey;

static BOOL DFSupportedPageURI(NSString *uri) {
    return [uri hasPrefix:@"spotify:track:"] || [uri hasPrefix:@"spotify:album:"] ||
           [uri hasPrefix:@"spotify:playlist:"] || [uri hasPrefix:@"spotify:artist:"];
}

static void DFUpdatePageButton(UIViewController *controller) {
    NSString *uri = DFPageURIForController(controller);
    DFPageButton *button = objc_getAssociatedObject(controller, &kPageButtonKey);
    if (!DFSupportedPageURI(uri)) {
        button.hidden = YES;
        return;
    }

    if (!button) {
        button = [DFPageButton buttonWithType:UIButtonTypeSystem];
        button.hostController = controller;
        DFStyleBadge(button, 11);
        [button setTitle:@"DF" forState:UIControlStateNormal];
        button.accessibilityLabel = @"DistroFind";
        [button addTarget:button action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
        [controller.view addSubview:button];
        objc_setAssociatedObject(controller, &kPageButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    button.hidden = NO;
    button.pageURI = uri;

    UIEdgeInsets safe = controller.view.safeAreaInsets;
    CGFloat size = 34;
    button.frame = CGRectMake(controller.view.bounds.size.width - size - 12,
                              MAX(safe.top + 8, 12), size, size);
    [controller.view bringSubviewToFront:button];
}

%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    DFUpdatePageButton(self);
}
- (void)viewDidLayoutSubviews {
    %orig;
    DFPageButton *button = objc_getAssociatedObject(self, &kPageButtonKey);
    if (button && !button.hidden) DFUpdatePageButton(self);
}
%end

#pragma mark - Recovering a track URI from Spotify row objects

static NSString *DFTrackIDFromText(NSString *text) {
    if (!text.length) return nil;
    NSRange marker = [text rangeOfString:@"spotify:track:"];
    if (marker.location != NSNotFound) {
        NSUInteger start = NSMaxRange(marker);
        if (text.length >= start + 22) {
            NSString *sid = [text substringWithRange:NSMakeRange(start, 22)];
            NSCharacterSet *bad = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
            if ([sid rangeOfCharacterFromSet:bad].location == NSNotFound) return sid;
        }
    }
    marker = [text rangeOfString:@"open.spotify.com/track/"];
    if (marker.location != NSNotFound) {
        NSUInteger start = NSMaxRange(marker);
        if (text.length >= start + 22) return [text substringWithRange:NSMakeRange(start, 22)];
    }
    return nil;
}

static BOOL DFShouldDescendIntoObject(id object, NSUInteger depth) {
    if (depth <= 1) return YES;
    NSString *name = NSStringFromClass([object class]);
    if ([name hasPrefix:@"NS"] || [name hasPrefix:@"__NS"] || [name hasPrefix:@"UI"] ||
        [name hasPrefix:@"_UI"] || [name hasPrefix:@"CALayer"]) return NO;
    return YES;
}

static NSString *DFTrackIDInObject(id object, NSUInteger depth, NSMutableSet<NSValue *> *seen) {
    if (!object || depth > 5) return nil;

    if ([object isKindOfClass:NSString.class]) return DFTrackIDFromText(object);
    if ([object isKindOfClass:NSURL.class]) return DFTrackIDFromText([(NSURL *)object absoluteString]);

    NSValue *pointer = [NSValue valueWithPointer:(__bridge const void *)object];
    if ([seen containsObject:pointer]) return nil;
    [seen addObject:pointer];

    if ([object isKindOfClass:NSDictionary.class]) {
        for (id value in [(NSDictionary *)object allValues]) {
            NSString *sid = DFTrackIDInObject(value, depth + 1, seen);
            if (sid) return sid;
        }
        return nil;
    }
    if ([object isKindOfClass:NSArray.class] || [object isKindOfClass:NSSet.class] ||
        [object isKindOfClass:NSOrderedSet.class]) {
        for (id value in object) {
            NSString *sid = DFTrackIDInObject(value, depth + 1, seen);
            if (sid) return sid;
        }
        return nil;
    }

    for (NSString *selectorName in @[@"URI", @"uri", @"trackURI", @"trackUri", @"spotifyURI", @"spotifyUri"]) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![object respondsToSelector:selector]) continue;
        id (*send)(id, SEL) = (void *)objc_msgSend;
        id value = nil;
        @try { value = send(object, selector); } @catch (__unused NSException *e) {}
        NSString *sid = DFTrackIDInObject(value, depth + 1, seen);
        if (sid) return sid;
    }

    if (!DFShouldDescendIntoObject(object, depth)) return nil;

    for (Class cls = object_getClass(object); cls && cls != NSObject.class; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (!type || type[0] != '@') continue;
            id value = nil;
            @try { value = object_getIvar(object, ivars[i]); } @catch (__unused NSException *e) {}
            NSString *sid = DFTrackIDInObject(value, depth + 1, seen);
            if (sid) { free(ivars); return sid; }
        }
        free(ivars);
    }
    return nil;
}

static NSString *DFTrackIDForCell(UIView *cell) {
    return DFTrackIDInObject(cell, 0, [NSMutableSet set]);
}

static UILabel *DFLabelWithIdentifier(UIView *root, NSArray<NSString *> *identifiers) {
    if ([root isKindOfClass:UILabel.class]) {
        NSString *identifier = root.accessibilityIdentifier;
        for (NSString *wanted in identifiers) if ([identifier isEqualToString:wanted]) return (UILabel *)root;
    }
    for (UIView *child in root.subviews) {
        UILabel *found = DFLabelWithIdentifier(child, identifiers);
        if (found) return found;
    }
    return nil;
}

#pragma mark - Playlist and album row badges + filter

@interface DFRowBadge : UIButton
@property (nonatomic, weak) UIView *cell;
@property (nonatomic, copy) NSString *trackID;
@end

@implementation DFRowBadge
- (void)tapped {
    UIViewController *page = DFPageControllerForView(self.cell);
    NSString *name = DFLabelWithIdentifier(self.cell, @[
        @"Track.Row.Content.Title",
        @"EncoreConsumerMobile.View.Granular.Title"
    ]).text;
    DFShowTrackActions(self.trackID, name, page);
}
@end

static char kRowBadgeKey, kRowTrackKey, kRowDistroKey, kRowPageKey;

static BOOL DFIsListPageURI(NSString *pageURI) {
    return [pageURI hasPrefix:@"spotify:playlist:"] || [pageURI hasPrefix:@"spotify:album:"];
}

static void DFLayoutRowBadge(UIView *cell, DFRowBadge *badge) {
    [badge sizeToFit];
    CGFloat width = MIN(MAX(badge.bounds.size.width, 42), MIN(118, cell.bounds.size.width * 0.34));
    CGFloat height = 18;
    CGFloat trailing = 44;
    badge.frame = CGRectMake(MAX(8, cell.bounds.size.width - trailing - width),
                             MAX(2, cell.bounds.size.height - height - 3),
                             width, height);
}

static void DFResolveRow(UIView *cell) {
    UIViewController *page = DFPageControllerForView(cell);
    NSString *pageURI = DFPageURIForController(page);
    if (!DFIsListPageURI(pageURI)) return;

    NSString *trackID = objc_getAssociatedObject(cell, &kRowTrackKey);
    if (!trackID.length) {
        trackID = DFTrackIDForCell(cell);
        if (trackID.length != 22) return;
        objc_setAssociatedObject(cell, &kRowTrackKey, trackID, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    objc_setAssociatedObject(cell, &kRowPageKey, pageURI, OBJC_ASSOCIATION_COPY_NONATOMIC);

    DFRowBadge *badge = objc_getAssociatedObject(cell, &kRowBadgeKey);
    if (!badge) {
        badge = [DFRowBadge buttonWithType:UIButtonTypeSystem];
        badge.cell = cell;
        DFStyleBadge(badge, 9);
        [badge addTarget:badge action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
        [cell addSubview:badge];
        objc_setAssociatedObject(cell, &kRowBadgeKey, badge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    badge.trackID = trackID;
    badge.hidden = NO;
    DFLayoutRowBadge(cell, badge);

    NSString *known = objc_getAssociatedObject(cell, &kRowDistroKey);
    if (known.length) {
        [badge setTitle:known forState:UIControlStateNormal];
        DFRegisterRowDistributor(pageURI, known);
        return;
    }
    [badge setTitle:@"…" forState:UIControlStateNormal];

    NSString *requested = [trackID copy];
    __weak UIView *weakCell = cell;
    SGDistroMetadataForTrack(trackID, ^(SGDistroMetadata *meta, NSError *error) {
        UIView *strongCell = weakCell;
        if (!strongCell) return;
        NSString *still = objc_getAssociatedObject(strongCell, &kRowTrackKey);
        if (![still isEqualToString:requested] || !meta) return;

        void (^show)(NSString *) = ^(NSString *name) {
            UIView *liveCell = weakCell;
            if (!liveCell || !name.length) return;
            NSString *liveTrack = objc_getAssociatedObject(liveCell, &kRowTrackKey);
            if (![liveTrack isEqualToString:requested]) return;
            objc_setAssociatedObject(liveCell, &kRowDistroKey, name, OBJC_ASSOCIATION_COPY_NONATOMIC);
            DFRowBadge *liveBadge = objc_getAssociatedObject(liveCell, &kRowBadgeKey);
            [liveBadge setTitle:name forState:UIControlStateNormal];
            DFLayoutRowBadge(liveCell, liveBadge);
            NSString *livePage = objc_getAssociatedObject(liveCell, &kRowPageKey);
            DFRegisterRowDistributor(livePage, name);
            [((UICollectionViewCell *)liveCell).superview setNeedsLayout];
            if ([liveCell.superview isKindOfClass:UICollectionView.class])
                [((UICollectionView *)liveCell.superview).collectionViewLayout invalidateLayout];
        };
        NSString *name = DFDisplayNameWithVydia(meta, show);
        show(name ?: @"Unknown");
    });
}

static UICollectionViewLayoutAttributes *DFFilterAttributes(UIView *cell, UICollectionViewLayoutAttributes *attributes) {
    NSString *pageURI = objc_getAssociatedObject(cell, &kRowPageKey);
    NSString *selected = DFSelectedDistributor(pageURI);
    NSString *distro = objc_getAssociatedObject(cell, &kRowDistroKey);
    if (selected.length && distro.length && ![selected isEqualToString:distro]) {
        UICollectionViewLayoutAttributes *copy = [attributes copy];
        copy.size = CGSizeMake(copy.size.width, 0);
        copy.alpha = 0;
        return copy;
    }
    return attributes;
}

static void DFResetCell(UIView *cell) {
    objc_setAssociatedObject(cell, &kRowTrackKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(cell, &kRowDistroKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(cell, &kRowPageKey, nil, OBJC_ASSOCIATION_ASSIGN);
    DFRowBadge *badge = objc_getAssociatedObject(cell, &kRowBadgeKey);
    badge.trackID = nil;
    badge.hidden = YES;
}

%hook _TtC35ListUXPlatform_FreeTierPlaylistImpl25ElementCollectionViewCell
- (void)layoutSubviews {
    %orig;
    DFResolveRow((UIView *)self);
}
- (void)prepareForReuse {
    DFResetCell((UIView *)self);
    %orig;
}
- (UICollectionViewLayoutAttributes *)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes *)attributes {
    UICollectionViewLayoutAttributes *result = %orig;
    return DFFilterAttributes((UIView *)self, result);
}
%end

%hook _TtC12Element_List18CollectionViewCell
- (void)layoutSubviews {
    %orig;
    UIView *cell = (UIView *)self;
    UIViewController *page = DFPageControllerForView(cell);
    NSString *uri = DFPageURIForController(page);
    if ([uri hasPrefix:@"spotify:album:"]) DFResolveRow(cell);
}
- (void)prepareForReuse {
    DFResetCell((UIView *)self);
    %orig;
}
- (UICollectionViewLayoutAttributes *)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes *)attributes {
    UICollectionViewLayoutAttributes *result = %orig;
    return DFFilterAttributes((UIView *)self, result);
}
%end

%ctor {
    %init;
    SGRequireClasses(@[
        @"SPTEsperantoPlayer",
        @"_TtC18NowPlaying_BarImpl27NowPlayingBarViewController",
        @"_TtC35ListUXPlatform_FreeTierPlaylistImpl25ElementCollectionViewCell",
        @"_TtC12Element_List18CollectionViewCell",
    ]);
    SGLog(@"DistroFind companion loaded");
}
