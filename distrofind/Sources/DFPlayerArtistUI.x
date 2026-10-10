// DistroFind controls in Spotify's actual 0.50 now-playing footer and artist ⋯ sheet.
// Guards keep every overlay out of non-artist menus and any missing 9.1.88 UI.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

extern NSString *DFUICurrentTrackID(void);
extern NSString *DFUITrackDistributor(NSString *trackID);
extern void DFUIRequestDistributor(NSString *trackID);
extern void DFUIOpenTrackInfo(NSString *trackID);
extern void DFUIOpenArtistTool(NSString *artistID, BOOL regions);

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
    NSString *name = DFUITrackDistributor(self.trackID) ?: @"DistroFind…";
    if ([_text.text isEqualToString:name]) return;
    _text.text = name;
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

static void DFUIInstallTitle(UIView *host) {
    UIView *title = DFUIFind(host, @"now-playing-title-label", 9);
    if (!title) return;
    DFInfoChip *chip = objc_getAssociatedObject(host, &kChipKey);
    if (!chip) {
        chip = [DFInfoChip new];
        chip.accessibilityIdentifier = @"DistroFind.Player.TitleBadge";
        [host addSubview:chip];
        objc_setAssociatedObject(host, &kChipKey, chip, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    chip.trackID = DFUICurrentTrackID();
    if (chip.trackID.length && !DFUITrackDistributor(chip.trackID))
        DFUIRequestDistributor(chip.trackID);
    [chip refresh];

    CGRect titleFrame = [title convertRect:title.bounds toView:host];
    UIFont *font = [title isKindOfClass:UILabel.class] ? ((UILabel *)title).font : [UIFont boldSystemFontOfSize:20];
    NSString *titleText = [title isKindOfClass:UILabel.class] ? ((UILabel *)title).text : nil;
    CGFloat titleTextWidth = [titleText sizeWithAttributes:@{NSFontAttributeName:font}].width;
    CGFloat maxChip = MIN(136, MAX(65, host.bounds.size.width * 0.33));
    CGFloat idealX = CGRectGetMinX(titleFrame) + MIN(titleTextWidth, titleFrame.size.width) + 8;
    CGFloat cap = host.bounds.size.width - maxChip - 10;
    // Don't cover the title if it is long: drop beside the artist line instead.
    CGFloat x = idealX <= cap ? idealX : MAX(CGRectGetMinX(titleFrame), cap);
    CGFloat y = idealX <= cap ? CGRectGetMidY(titleFrame) - 10 : CGRectGetMaxY(titleFrame) + 2;
    CGRect frame = CGRectMake(x, y, maxChip, 20);
    if (!CGRectEqualToRect(chip.frame, frame)) chip.frame = frame;
}

static UIView *DFUIArrangedHolder(UIView *child, UIView *host) {
    for (UIView *view = child; view && view != host; view = view.superview)
        if ([view.superview isKindOfClass:UIStackView.class]) return view;
    return nil;
}
static void DFUIAddFooterInfo(UIView *host) {
    if (host.bounds.size.width < 180) return;
    UIButton *button = objc_getAssociatedObject(host, &kInfoKey);
    if (!button) {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tintColor = UIColor.whiteColor;
        button.accessibilityLabel = @"DistroFind Track Info";
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightRegular];
        [button setImage:[UIImage systemImageNamed:@"info.circle" withConfiguration:cfg] forState:UIControlStateNormal];
        [button addTarget:button action:@selector(df_unusedTap:) forControlEvents:UIControlEventTouchUpInside];
        // Actual action is installed below via a local target; don't depend on
        // private Spotify selectors.
        button.layer.zPosition = 200;
        [host addSubview:button];
        objc_setAssociatedObject(host, &kInfoKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGFloat w = host.bounds.size.width;
    CGFloat h = host.bounds.size.height;
    CGRect frame = CGRectMake(round(w * 0.91 - 22), round((h - 44) / 2), 44, 44);
    if (!CGRectEqualToRect(button.frame, frame)) button.frame = frame;

    UIView *queue = DFUIFind(host, @"QueueButtonNowPlaying", 9);
    UIView *holder = DFUIArrangedHolder(queue, host);
    if (holder && queue) {
        CGFloat current = [queue convertPoint:CGPointMake(CGRectGetMidX(queue.bounds), CGRectGetMidY(queue.bounds)) toView:host].x;
        CGFloat delta = round(w * 0.73 - current);
        if (fabs(delta) > 1 && fabs(delta) < w / 2)
            holder.transform = CGAffineTransformTranslate(holder.transform, delta, 0);
    }
}

// A one-time action target shared by the player's new Info button.
@interface DFPlayerInfoAction : NSObject
+ (instancetype)shared;
- (void)openInfo:(id)sender;
@end
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

static void DFUIArtistMenu(UIViewController *menu) {
    if (!dfMenuArtist.length || CFAbsoluteTimeGetCurrent() - dfMenuRequestedAt > 8) return;
    UITableView *table = DFUITable(menu.viewIfLoaded, 9);
    if (!table || table.bounds.size.width < 100) return;
    DFArtistExtraActions *extra = objc_getAssociatedObject(menu, &kArtistActionsKey);
    if (!extra) {
        BOOL freeFooter = !table.tableFooterView || table.tableFooterView.bounds.size.height < 1;
        BOOL freeHeader = !table.tableHeaderView || table.tableHeaderView.bounds.size.height < 1;
        if (!freeFooter && !freeHeader) return;
        extra = [[DFArtistExtraActions alloc] initWithFrame:CGRectMake(0, 0, table.bounds.size.width, 104)];
        extra.artistID = dfMenuArtist;
        objc_setAssociatedObject(menu, &kArtistActionsKey, extra, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (freeFooter) table.tableFooterView = extra;
        else table.tableHeaderView = extra;
    }
}

%hook UIViewController
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion {
    if ([NSStringFromClass(controller.class) containsString:@"ContextMenuViewController"]) {
        NSString *artist = DFUIArtistFromPage((UIViewController *)self);
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

%ctor {
    %init;
}
