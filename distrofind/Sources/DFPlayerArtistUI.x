// DistroFind controls in Spotify's actual 0.50 now-playing footer and artist ⋯ sheet.
// Guards keep every overlay out of non-artist menus and any missing 9.1.88 UI.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

extern NSString *DFUICurrentTrackID(void);
extern NSString *DFUITrackDistributor(NSString *trackID);
extern void DFUIRequestDistributor(NSString *trackID);
extern void DFUIOpenTrackInfo(NSString *trackID);
extern void DFUIOpenArtistTool(NSString *artistID, BOOL regions);

@class DFPlayerInfoAction;
@interface DFPlayerInfoAction : NSObject
+ (instancetype)shared;
- (void)openInfo:(id)sender;
@end

// The official 0.50 redesign uses this same persisted flag. Do not hook the
// native/stock player, including on builds where the iOS 26 redesign is absent.
static BOOL DFRedesignedPlayerEnabled(void) {
    if (@available(iOS 26.0, *)) {
        return [NSUserDefaults.standardUserDefaults boolForKey:@"spotifyglass.redesign"];
    }
    return NO;
}

static char kInfoKey, kChipKey, kArtistActionsKey;
static NSString *dfMenuArtist;
static NSTimeInterval dfMenuRequestedAt;

static UIView *DFUIFind(UIView *root, NSString *idPart, NSInteger depth) {
    if (!root || depth < 0) return nil;
    if ([root.accessibilityIdentifier containsString:idPart]) return root;
    for (UIView *child in root.subviews) {
        UIView *found = DFUIFind(child, idPart, depth - 1);
        if (found) return found;
    }
    return nil;
}
static UITableView *DFUITable(UIView *root, NSInteger depth) {
    if (!root || depth < 0) return nil;
    if ([root isKindOfClass:UITableView.class]) return (UITableView *)root;
    for (UIView *child in root.subviews) {
        UITableView *found = DFUITable(child, depth - 1);
        if (found) return found;
    }
    return nil;
}
static NSString *DFUIArtistFromPage(UIViewController *controller) {
    if (!controller) return nil;
    SEL selector = NSSelectorFromString(@"spt_pageURI");
    if ([controller respondsToSelector:selector]) {
        id uri = ((id (*)(id, SEL))objc_msgSend)(controller, selector);
        NSString *text = [uri respondsToSelector:@selector(absoluteString)] ? [uri absoluteString] :
            [uri isKindOfClass:NSString.class] ? uri : nil;
        if ([text hasPrefix:@"spotify:artist:"]) {
            NSString *candidate = [text substringFromIndex:15];
            if (candidate.length == 22) return candidate;
        }
    }
    if ([controller isKindOfClass:UINavigationController.class])
        return DFUIArtistFromPage(((UINavigationController *)controller).visibleViewController);
    if ([controller isKindOfClass:UITabBarController.class])
        return DFUIArtistFromPage(((UITabBarController *)controller).selectedViewController);
    for (UIViewController *child in controller.childViewControllers) {
        if (!child.viewIfLoaded.window) continue;
        NSString *result = DFUIArtistFromPage(child);
        if (result) return result;
    }
    return nil;
}

@interface DFInfoChip : UIControl
@property (nonatomic, copy) NSString *trackID;
@property (nonatomic, strong) UILabel *text;
@property (nonatomic) BOOL layoutAllowed;
- (void)refresh;
@end
@implementation DFInfoChip
- (instancetype)init {
    if ((self = [super init])) {
        self.backgroundColor = [UIColor colorWithWhite:1 alpha:0.17];
        self.layer.cornerRadius = 7;
        self.clipsToBounds = YES;
        _text = [UILabel new];
        _text.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        _text.textColor = UIColor.whiteColor;
        [self addSubview:_text];
        [self addTarget:self action:@selector(infoPressed) forControlEvents:UIControlEventTouchUpInside];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(metadata:) name:@"DistroFind.MetadataReady" object:nil];
    }
    return self;
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)metadata:(NSNotification *)note {
    if ([note.object isEqualToString:self.trackID]) [self refresh];
}
- (void)infoPressed { if (self.trackID.length) DFUIOpenTrackInfo(self.trackID); }
- (void)refresh {
    NSString *name = DFUITrackDistributor(self.trackID);
    // Never draw a provisional chip over Spotify's real title while loading.
    self.hidden = !self.layoutAllowed || !name.length;
    if ([_text.text isEqualToString:name]) return;
    _text.text = name ?: @"";
    [_text.layer removeAnimationForKey:@"df.player.marquee"];
    [self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    NSString *name = _text.text ?: @"";
    CGFloat length = [name sizeWithAttributes:@{NSFontAttributeName:_text.font}].width;
    CGFloat inner = MAX(1, self.bounds.size.width - 14);
    _text.frame = CGRectMake(7, 0, MAX(inner, length), self.bounds.size.height);
    if (length > inner + 3 && self.window && ![_text.layer animationForKey:@"df.player.marquee"]) {
        CGFloat over = length - inner;
        CAKeyframeAnimation *marquee = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
        marquee.values = @[@0, @0, @(-over), @(-over), @0];
        marquee.keyTimes = @[@0, @0.18, @0.57, @0.78, @1];
        marquee.duration = MAX(6, over / 11 + 4);
        marquee.repeatCount = HUGE_VALF;
        [_text.layer addAnimation:marquee forKey:@"df.player.marquee"];
    }
}
@end

// This must be the InformationElementsUnit *view*, never the nearest
// 40-point title-label clip. A clip made the original badge paint right over
// the title and steal its gestures on Spotify 9.1.88.
static void DFUIInstallTitle(UIView *host) {
    if (!DFRedesignedPlayerEnabled() || !host || !host.window) return;
    UIView *title = DFUIFind(host, @"now-playing-title-label", 8);
    UIView *artist = DFUIFind(host, @"now-playing-subtitle-label", 8);
    if (!title || !artist || host.bounds.size.width < 250 || host.bounds.size.height < 48) return;

    DFInfoChip *chip = objc_getAssociatedObject(host, &kChipKey);
    if (!chip) {
        chip = [DFInfoChip new];
        chip.accessibilityIdentifier = @"DistroFind.Redesigned.Player.Distributor";
        chip.accessibilityLabel = @"DistroFind track information";
        [host addSubview:chip];
        objc_setAssociatedObject(host, &kChipKey, chip, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSLog(@"[distrofind] redesigned player artist-line distributor chip created");
    }
    NSString *trackID = DFUICurrentTrackID();
    if (![chip.trackID isEqualToString:trackID]) {
        chip.trackID = trackID;
        [chip refresh];
    }
    if (trackID.length && !DFUITrackDistributor(trackID)) DFUIRequestDistributor(trackID);

    // The redesign's info unit is just 64 points high: title on top, artist
    // below. Place the chip *after the artist*, not on the long/marquee title.
    CGRect artistBounds = [artist convertRect:artist.bounds toView:host];
    UILabel *artistLabel = nil;
    if ([artist isKindOfClass:UILabel.class]) artistLabel = (UILabel *)artist;
    else {
        for (UIView *child in artist.subviews) {
            if ([child isKindOfClass:UILabel.class]) {
                artistLabel = (UILabel *)child;
                break;
            }
        }
    }
    CGFloat artistWidth = artistBounds.size.width;
    if (artistLabel.text.length) {
        UIFont *font = artistLabel.font ?: [UIFont systemFontOfSize:14];
        artistWidth = MIN(artistBounds.size.width,
                          ceil([artistLabel.text sizeWithAttributes:@{NSFontAttributeName:font}].width));
    } else if (artistBounds.size.width > 0) {
        // A clipped marquee might not expose a UILabel at all. Don't put the
        // distributor on top of a name whose real width we cannot measure.
        chip.layoutAllowed = NO;
        chip.hidden = YES;
        return;
    }
    CGFloat x = CGRectGetMinX(artistBounds) + artistWidth + 11;
    CGFloat reserveForSave = 75;  // Spotify's green save/check button
    CGFloat right = MIN(host.bounds.size.width - reserveForSave,
                        CGRectGetMaxX(artistBounds) - 2);
    CGFloat available = right - x;
    if (available < 58 || artistBounds.size.height < 12) {
        chip.layoutAllowed = NO;
        chip.hidden = YES;
        return;
    }
    CGFloat width = MIN(118, available);
    CGRect frame = CGRectMake(round(x), round(CGRectGetMidY(artistBounds) - 10), round(width), 20);
    if (!CGRectEqualToRect(chip.frame, frame)) chip.frame = frame;
    chip.layoutAllowed = YES;
    chip.hidden = ![DFUITrackDistributor(trackID) length];
    if (chip.superview == host) [host bringSubviewToFront:chip];
}

// The *redesigned* spoti.pw footer already places Lyrics/Devices/Queue at
// 20/50/80% of its width and lowers the entire row. Do not re-transform queue:
// applying translations twice was unstable and could hide the fourth button.
static void DFUIAddFooterInfo(UIView *host) {
    if (!DFRedesignedPlayerEnabled() || !host || !host.window ||
        host.bounds.size.width < 250 || host.bounds.size.height < 35) return;
    UIView *queue = DFUIFind(host, @"QueueButtonNowPlaying", 9);
    if (!queue) return; // A different player, not the redesigned three-icon row.

    UIButton *button = objc_getAssociatedObject(host, &kInfoKey);
    if (!button) {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tintColor = UIColor.whiteColor;
        button.accessibilityLabel = @"DistroFind Track Info";
        button.accessibilityIdentifier = @"DistroFind.Redesigned.Player.InfoButton";
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:22 weight:UIImageSymbolWeightRegular];
        [button setImage:[UIImage systemImageNamed:@"info.circle" withConfiguration:cfg]
                forState:UIControlStateNormal];
        [button addTarget:[DFPlayerInfoAction shared] action:@selector(openInfo:)
            forControlEvents:UIControlEventTouchUpInside];
        button.layer.zPosition = 200;
        [host addSubview:button];
        objc_setAssociatedObject(host, &kInfoKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSLog(@"[distrofind] redesigned player fourth Info button attached");
    }
    // To the RIGHT of queue (at 80% width), within the host's real bounds.
    // The original 3 redesigned controls do not move.
    CGFloat width = host.bounds.size.width, height = host.bounds.size.height;
    CGRect frame = CGRectMake(round(width - 45), round((height - 42) / 2), 42, 42);
    if (!CGRectEqualToRect(button.frame, frame)) button.frame = frame;
    button.hidden = NO;
    button.alpha = 1;
    button.userInteractionEnabled = YES;
    if (button.superview != host) [host addSubview:button];
    [host bringSubviewToFront:button];
}

// A one-time action target shared by the player's new Info button.
@implementation DFPlayerInfoAction
+ (instancetype)shared {
    static DFPlayerInfoAction *one;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ one = [DFPlayerInfoAction new]; });
    return one;
}
- (void)openInfo:(id)sender { DFUIOpenTrackInfo(DFUICurrentTrackID()); }
@end

@interface DFArtistExtraActions : UIView
@property (nonatomic, copy) NSString *artistID;
@end
@implementation DFArtistExtraActions
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        NSArray *items = @[@[@"magnifyingglass", @"Artist Scan"], @[@"globe", @"Regioned Releases"]];
        for (NSUInteger i = 0; i < items.count; i++) {
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
            button.tag = i;
            button.frame = CGRectMake(12, i * 52, MAX(100, frame.size.width - 24), 52);
            button.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
            button.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
            button.tintColor = UIColor.labelColor;
            [button setTitle:[@"    " stringByAppendingString:items[i][1]] forState:UIControlStateNormal];
            [button setImage:[UIImage systemImageNamed:items[i][0]] forState:UIControlStateNormal];
            [button addTarget:self action:@selector(picked:) forControlEvents:UIControlEventTouchUpInside];
            [self addSubview:button];
        }
    }
    return self;
}
- (void)picked:(UIButton *)sender {
    NSString *artistID = self.artistID;
    if (!artistID.length) return;
    UIViewController *presenter = nil;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.isKeyWindow) { presenter = window.rootViewController; break; }
    }
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    [presenter dismissViewControllerAnimated:YES completion:^{
        DFUIOpenArtistTool(artistID, sender.tag == 1);
    }];
}
@end

static NSString *DFUIArtistInForeground(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (!window.isKeyWindow) continue;
        NSString *artistID = DFUIArtistFromPage(window.rootViewController);
        if (artistID.length) return artistID;
    }
    return nil;
}

static void DFUIArtistMenu(UIViewController *menu) {
    NSString *artist = dfMenuArtist;
    if (!artist.length || CFAbsoluteTimeGetCurrent() - dfMenuRequestedAt > 8)
        artist = DFUIArtistInForeground();
    if (!artist.length) return;
    UITableView *table = DFUITable(menu.viewIfLoaded, 9);
    if (!table || table.bounds.size.width < 100) return;
    DFArtistExtraActions *extra = objc_getAssociatedObject(menu, &kArtistActionsKey);
    if (extra) { extra.artistID = artist; return; }

    UIView *oldFooter = table.tableFooterView;
    CGFloat oldHeight = oldFooter && oldFooter.bounds.size.height > 1 ? oldFooter.bounds.size.height : 0;
    extra = [[DFArtistExtraActions alloc] initWithFrame:CGRectMake(0, oldHeight, table.bounds.size.width, 104)];
    extra.artistID = artist;
    objc_setAssociatedObject(menu, &kArtistActionsKey, extra, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Preserve Spotify's pre-existing footer. Both header AND footer can
    // be occupied on 9.1.88, which made the previous code silently give up.
    if (oldHeight > 0) {
        UIView *wrapper = [[UIView alloc] initWithFrame:CGRectMake(0, 0, table.bounds.size.width, oldHeight + 104)];
        table.tableFooterView = nil;
        [oldFooter removeFromSuperview];
        oldFooter.frame = CGRectMake(0, 0, table.bounds.size.width, oldHeight);
        [wrapper addSubview:oldFooter];
        [wrapper addSubview:extra];
        table.tableFooterView = wrapper;
    } else {
        table.tableFooterView = extra;
    }
    [table invalidateIntrinsicContentSize];
    NSLog(@"[distrofind] installed artist scan actions in Spotify context menu");
}

%hook UIControl
- (void)sendAction:(SEL)action to:(id)target forEvent:(UIEvent *)event {
    NSString *identifier = self.accessibilityIdentifier ?: @"";
    NSString *label = self.accessibilityLabel ?: @"";
    if ([identifier containsString:@"ContextMenuButton"] ||
        [identifier containsString:@"PinnedMore"] ||
        [label isEqualToString:@"More"]) {
        NSString *artist = DFUIArtistInForeground();
        if (artist.length) {
            dfMenuArtist = artist;
            dfMenuRequestedAt = CFAbsoluteTimeGetCurrent();
        }
    }
    %orig;
}
%end

%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSString *name = NSStringFromClass([self class]);
    if ([name containsString:@"ContextMenu"] && [name containsString:@"ViewController"]) {
        DFUIArtistMenu((UIViewController *)self);
    }
}
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion {
    if ([NSStringFromClass(controller.class) containsString:@"ContextMenuViewController"]) {
        NSString *artist = DFUIArtistFromPage((UIViewController *)self);
        if (!artist.length) {
            // Depending on the host's presentation style, Spotify can ask a
            // coordinator instead of its actual page to present the menu.
            for (UIWindow *window in UIApplication.sharedApplication.windows) {
                if (!window.isKeyWindow) continue;
                artist = DFUIArtistFromPage(window.rootViewController);
                if (artist.length) break;
            }
        }
        if (artist.length) {
            dfMenuArtist = artist;
            dfMenuRequestedAt = CFAbsoluteTimeGetCurrent();
        } else {
            dfMenuArtist = nil;
        }
    }
    %orig;
}
%end

%hook _TtC20NowPlaying_ModesImpl23InformationElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    DFUIInstallTitle(((UIViewController *)self).viewIfLoaded);
}
%end

%hook _TtC20NowPlaying_ModesImpl18FooterElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    UIView *host = ((UIViewController *)self).viewIfLoaded;
    DFUIAddFooterInfo(host);
}
%end

%hook _TtC24ContextMenu_InternalImpl25ContextMenuViewController
- (void)viewDidLayoutSubviews {
    %orig;
    DFUIArtistMenu((UIViewController *)self);
}
%end

static UIView *DFUIHostOf(UIView *view, NSString *unit) {
    for (UIView *v = view; v; v = v.superview) {
        UIResponder *responder = v.nextResponder;
        if (![responder isKindOfClass:UIViewController.class]) continue;
        UIViewController *controller = (UIViewController *)responder;
        if (controller.viewIfLoaded != v) continue;
        if ([NSStringFromClass(controller.class) containsString:unit]) return v;
    }
    return nil;
}
static char kDFUIRefreshStamp;
// Observe only the exact player control identifiers rather than relying
// exclusively on Swift module class names from a different Spotify version.
%hook UIView
- (void)didMoveToWindow {
    %orig;
    if (!self.window) return;
    NSString *identifier = self.accessibilityIdentifier;
    BOOL title = [identifier containsString:@"now-playing-title-label"];
    BOOL queue = [identifier containsString:@"QueueButtonNowPlaying"];
    if (!title && !queue) return;
    __weak UIView *weakView = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *anchor = weakView;
        UIView *host = DFUIHostOf(anchor, title ? @"InformationElementsUnit" : @"FooterElementsUnit");
        if (!host) return;
        if (title) DFUIInstallTitle(host);
        else DFUIAddFooterInfo(host);
    });
}
- (void)layoutSubviews {
    %orig;
    if (!self.window) return;
    NSString *identifier = self.accessibilityIdentifier;
    BOOL title = [identifier containsString:@"now-playing-title-label"];
    BOOL queue = [identifier containsString:@"QueueButtonNowPlaying"];
    if (!title && !queue) return;
    NSNumber *previous = objc_getAssociatedObject(self, &kDFUIRefreshStamp);
    NSTimeInterval now = CACurrentMediaTime();
    if (now - previous.doubleValue < 0.6) return;
    objc_setAssociatedObject(self, &kDFUIRefreshStamp, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *weakView = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *anchor = weakView;
        if (!anchor.window) return;
        UIView *host = DFUIHostOf(anchor, title ? @"InformationElementsUnit" : @"FooterElementsUnit");
        if (!host) return;
        if (title) DFUIInstallTitle(host);
        else DFUIAddFooterInfo(host);
    });
}
%end

%ctor {
    if (!DFRedesignedPlayerEnabled()) {
        NSLog(@"[distrofind] native Spotify look: redesigned player controls are disabled");
        return;
    }
    %init;
    NSLog(@"[distrofind] redesigned-only player/info and artist menu hooks installed");
}
