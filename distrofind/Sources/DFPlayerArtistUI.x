// DistroFind on the full-screen player and on the artist page's ⋯ sheet.
//
// **The player: spoti.pw's Redesigned UI only.** The native look's player is left exactly as Spotify
// draws it; these hooks are a group of their own that is not even installed unless the redesign is on.
//
// - The distributor chip sits after the title when the whole title shows and the chip fits before the
//   add button, else after the artist line, else nowhere: it is never drawn over Spotify's text. It is a
//   subview of the arranged element that holds the title and the artist, not of the unit, so when the
//   lyrics lift the title up beside the thumbnail (the redesign's PlayerLyrics.x moves that element) the
//   chip goes with it. Tapping it opens Track Info.
//
// - ⓘ joins the footer as a fourth glyph after Lyrics, Devices and Queue. The redesign spreads its three
//   at 20/50/80% of the footer's width (PlayerFooter.x); with four they go to 20/40/60/80% so the row
//   stays even. Lyrics is the redesign's own glyph and is re-centred; Devices and Queue are Spotify's
//   controls and are moved the way the redesign moves them, by a translation of the arranged view that
//   holds each, so their touches stay their own. The redesign lowers the whole footer unit and hands the
//   touches below it back to the unit, and ⓘ is the unit's subview, so it is lowered and reachable with
//   the rest.
//
// The companion is injected after spotifyglass.dylib, so its hooks wrap the redesign's and run after
// them in the same layout pass. Should that ever be the other way round, a pass is also queued for
// right after, which puts the row back.
//
// **The artist page's ⋯: either look.** Artist Scan and Regioned Releases are two rows of the sheet,
// laid out the way the redesign's own rows on that sheet are (PlaylistMenu.x). Spotify's rows come from
// Swift item factories with no ObjC surface, so nothing can go between them; the closest place to
// "under Go to radio" is right after Spotify's last row, the table's footer. Which sheet is the artist's
// is known from the ⋯ that opened it: the artist header's ⋯ is
// Components.UI.ContextMenuButton-<artist id> on the creator page (the redesign's ArtistFollow.x reads the
// id the same way, since the artist page's controllers carry no URI), and the redesign's pinned ⋯ sits
// straight on the creator page.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "DFChip.h"

extern NSString *const DFCurrentTrackChangedNotification;
extern NSString *const DFMetadataReadyNotification;
extern NSString *DFUICurrentTrackID(void);
extern NSString *DFUITrackDistributor(NSString *trackID);
extern void DFUIRequestDistributor(NSString *trackID);
extern void DFUIOpenTrackInfo(NSString *trackID);
extern void DFUIOpenArtistTool(NSString *artistID, BOOL regions);

// Read once, as the mod reads it: a change takes the restart the mod already asks for. The redesign
// only exists from iOS 26 on, whatever is stored.
static BOOL DFRedesignedPlayerEnabled(void) {
    static BOOL on;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (@available(iOS 26.0, *)) on = [NSUserDefaults.standardUserDefaults boolForKey:@"spotifyglass.redesign"];
    });
    return on;
}

static NSString *const kArtistMoreButton = @"Components.UI.ContextMenuButton-";
static NSString *const kCreatorPage = @"creator-page";
// The redesign's footer: where its outermost glyphs sit, as parts of the footer's width.
static const CGFloat kLeading = 0.2, kTrailing = 0.8;
static const CGFloat kGlyphMaxWidth = 30, kInfoGlyphSize = 20, kTouch = 44;
static const CGFloat kChipHeight = 18, kChipGap = 8, kChipMinWidth = 44, kChipMaxWidth = 120;
// A sheet this soon after the artist's ⋯ was used is the artist's.
static const NSTimeInterval kMenuWindow = 3;

static char kChipKey, kInfoKey, kQueuedKey, kMenuArtistKey, kMenuBlockKey;
static __weak UIView *df_infoHost;
static NSString *df_menuArtist;
static CFAbsoluteTime df_menuArtistAt;

#pragma mark - views

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

// The first label with text at or under `root`: Spotify's title and artist are marquee labels inside
// clipping views, a level or two down from the view that carries the identifier.
static UILabel *DFUILabelIn(UIView *root) {
    if (!root) return nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSUInteger visited = 0;
    while (queue.count && visited++ < 30) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([view isKindOfClass:UILabel.class] && ((UILabel *)view).text.length) return (UILabel *)view;
        [queue addObjectsFromArray:view.subviews];
    }
    return nil;
}

static CGFloat DFUITextWidth(UILabel *label) {
    if (label.attributedText.length) return ceil(label.attributedText.size.width);
    if (!label.text.length) return 0;
    return ceil([label.text sizeWithAttributes:@{NSFontAttributeName: label.font ?: [UIFont systemFontOfSize:17]}].width);
}

// The view a stack view arranges around `view`.
static UIView *DFUIArrangedAround(UIView *view, UIView *host) {
    for (UIView *v = view; v && v != host; v = v.superview) {
        if ([v.superview isKindOfClass:UIStackView.class]) return v;
    }
    return nil;
}

#pragma mark - the player: the distributor chip

static DFChip *DFUIPlayerChip(UIView *host) {
    DFChip *chip = objc_getAssociatedObject(host, &kChipKey);
    if (!chip) {
        chip = [[DFChip alloc] initWithFontSize:11];
        chip.backgroundColor = [UIColor colorWithWhite:1 alpha:0.17];
        chip.accessibilityIdentifier = @"DistroFind.Redesigned.Player.Distributor";
        chip.onTap = ^(DFChip *tapped) {
            NSString *trackID = tapped.trackID.length ? tapped.trackID : DFUICurrentTrackID();
            if (trackID.length) DFUIOpenTrackInfo(trackID);
        };
        objc_setAssociatedObject(host, &kChipKey, chip, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSLog(@"[distrofind] redesigned player distributor chip created");
    }
    return chip;
}

// Where the element's text may run to: its trailing edge, or the first control inside it past the text.
static CGFloat DFUIElementRight(UIView *element, CGFloat textStart, UIView *chip) {
    CGFloat right = element.bounds.size.width - 2;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithArray:element.subviews];
    NSUInteger visited = 0;
    while (queue.count && visited++ < 60) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (view == chip) continue;
        if ([view isKindOfClass:UIControl.class] && !view.hidden && view.alpha > 0.01) {
            CGRect frame = [view convertRect:view.bounds toView:element];
            if (frame.size.width > 0 && CGRectGetMinX(frame) > textStart + 40) {
                right = MIN(right, CGRectGetMinX(frame) - 4);
                continue;
            }
        }
        [queue addObjectsFromArray:view.subviews];
    }
    return right;
}

// Shown and hidden by alpha: the chip lives in Spotify's element view, and Spotify's stacks trap when a
// view in them hides (AGENTS.md).
static void DFUIShowChip(DFChip *chip, BOOL shown) {
    CGFloat alpha = shown ? 1 : 0;
    if (chip.alpha != alpha) chip.alpha = alpha;
    if (chip.userInteractionEnabled != shown) chip.userInteractionEnabled = shown;
    chip.accessibilityElementsHidden = !shown;
}

static BOOL DFUIIsSpotifyStack(UIView *view) {
    NSString *name = NSStringFromClass(view.class);
    return [name containsString:@"OverflowStack"] || [name containsString:@"AutoLayoutStack"];
}

static void DFUIPlaceTitleChip(UIView *host) {
    if (!host.window) return;
    UIView *titleClip = DFUIFind(host, @"now-playing-title-label", 10);
    if (!titleClip) return;
    UIView *artistClip = DFUIFind(host, @"now-playing-subtitle-label", 10);
    UIView *element = DFUIArrangedAround(titleClip, host) ?: titleClip.superview;
    // Into a plain element only; a stack of Spotify's own lays out (and traps on) what it holds, so there
    // the chip stays on the unit, where it still never covers the text but does not follow the lyrics.
    if (!element || DFUIIsSpotifyStack(element)) element = host;
    df_infoHost = host;

    DFChip *chip = DFUIPlayerChip(host);
    if (chip.superview != element) {
        [chip removeFromSuperview];
        [element addSubview:chip];
    } else if (element.subviews.lastObject != chip) {
        [element bringSubviewToFront:chip];
    }

    NSString *trackID = DFUICurrentTrackID();
    chip.trackID = trackID;
    NSString *name = DFUITrackDistributor(trackID);
    // Never a provisional chip: it waits for the name rather than drawing "…" next to the title.
    if (!name.length) {
        DFUIShowChip(chip, NO);
        if (trackID.length) DFUIRequestDistributor(trackID);
        return;
    }
    [chip setChipText:name];
    CGFloat wanted = MIN(kChipMaxWidth, MAX(kChipMinWidth, [chip fittingWidth]));

    CGRect frame = CGRectNull;
    UILabel *titleLabel = DFUILabelIn(titleClip);
    CGRect titleRect = [titleClip convertRect:titleClip.bounds toView:element];
    CGFloat right = DFUIElementRight(element, CGRectGetMinX(titleRect), chip);
    // After the title, only when the whole title shows: a title that scrolls has no end to sit after.
    CGFloat titleText = DFUITextWidth(titleLabel);
    if (titleText > 0 && titleText <= titleRect.size.width + 0.5) {
        CGFloat x = CGRectGetMinX(titleRect) + titleText + kChipGap;
        if (x + kChipMinWidth <= right) frame = CGRectMake(x, CGRectGetMidY(titleRect) - kChipHeight / 2, MIN(wanted, right - x), kChipHeight);
    }
    // Else after the artist, on the same terms.
    if (CGRectIsNull(frame) && artistClip) {
        UILabel *artistLabel = DFUILabelIn(artistClip);
        CGRect artistRect = [artistClip convertRect:artistClip.bounds toView:element];
        CGFloat artistText = DFUITextWidth(artistLabel);
        if (artistText > 0 && artistText <= artistRect.size.width + 0.5) {
            CGFloat x = CGRectGetMinX(artistRect) + artistText + kChipGap;
            if (x + kChipMinWidth <= right) frame = CGRectMake(x, CGRectGetMidY(artistRect) - kChipHeight / 2, MIN(wanted, right - x), kChipHeight);
        }
    }
    if (CGRectIsNull(frame)) {
        DFUIShowChip(chip, NO);
        return;
    }
    frame = CGRectMake(round(frame.origin.x), round(frame.origin.y), round(frame.size.width), kChipHeight);
    if (!CGRectEqualToRect(chip.frame, frame)) chip.frame = frame;
    DFUIShowChip(chip, YES);
}

#pragma mark - the player: ⓘ in the footer

@interface DFUIInfoTarget : NSObject
+ (instancetype)shared;
- (void)openInfo:(id)sender;
@end

@implementation DFUIInfoTarget
+ (instancetype)shared {
    static DFUIInfoTarget *one;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ one = [DFUIInfoTarget new]; });
    return one;
}
- (void)openInfo:(id)sender {
    NSString *trackID = DFUICurrentTrackID();
    if (trackID.length) DFUIOpenTrackInfo(trackID);
}
@end

// Drawn the way the redesign draws its Lyrics glyph beside it: a 20pt regular symbol in the secondary
// white, on a 44pt target.
static UIButton *DFUIInfoButton(UIView *host) {
    UIButton *button = objc_getAssociatedObject(host, &kInfoKey);
    if (!button) {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:kInfoGlyphSize
            weight:UIImageSymbolWeightRegular];
        [button setImage:[UIImage systemImageNamed:@"info.circle" withConfiguration:config] forState:UIControlStateNormal];
        button.tintColor = [UIColor colorWithWhite:1 alpha:UIAccessibilityDarkerSystemColorsEnabled() ? 0.80 : 0.65];
        button.accessibilityLabel = @"Track Info";
        button.accessibilityIdentifier = @"DistroFind.Redesigned.Player.InfoButton";
        button.showsLargeContentViewer = YES;
        button.largeContentTitle = @"Track Info";
        [button addInteraction:[UILargeContentViewerInteraction new]];
        [button addTarget:[DFUIInfoTarget shared] action:@selector(openInfo:) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(host, &kInfoKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSLog(@"[distrofind] redesigned player Info glyph created");
    }
    if (button.superview != host) [host addSubview:button];
    else if (host.subviews.lastObject != button) [host bringSubviewToFront:button];
    return button;
}

// The redesign's Lyrics glyph: its own control, straight on the footer unit's view.
static UIView *DFUILyricsGlyph(UIView *host, UIView *info) {
    for (UIView *view in host.subviews) {
        if (view == info || ![view isKindOfClass:UIControl.class]) continue;
        if ([NSStringFromClass(view.class) containsString:@"GlyphButton"] || [view.accessibilityLabel isEqualToString:@"Lyrics"]) return view;
    }
    return nil;
}

// Connect's own glyph, which the redesign centres rather than the whole holder.
static UIView *DFUIConnectGlyph(UIView *holder) {
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:holder];
    NSUInteger visited = 0;
    while (queue.count && visited++ < 30) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([view isKindOfClass:UIImageView.class] && view.bounds.size.width > 0 && view.bounds.size.width <= kGlyphMaxWidth) return view;
        [queue addObjectsFromArray:view.subviews];
    }
    return nil;
}

// Moves an arranged view so the middle of `view` (inside it) lands on `x` of the host, measured with the
// arranged view's own transform left out -- the same arithmetic as the redesign's PlayerFooter.x, so the
// two agree on where a control is.
static void DFUIMoveTo(UIView *arranged, UIView *view, UIView *host, CGFloat x) {
    if (!arranged || !view || !arranged.superview) return;
    CGPoint middle = CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds));
    CGPoint local = [view convertPoint:middle toView:arranged];
    CGPoint inRow = CGPointMake(arranged.center.x + local.x - CGRectGetMidX(arranged.bounds), arranged.center.y);
    CGFloat from = [arranged.superview convertPoint:inRow toView:host].x;
    CGAffineTransform move = CGAffineTransformMakeTranslation(round(x - from), 0);
    if (!CGAffineTransformEqualToTransform(arranged.transform, move)) arranged.transform = move;
}

static void DFUIPlaceFooter(UIView *host) {
    if (!host.window || host.bounds.size.width < 200 || host.bounds.size.height < 30) return;
    // Only the redesign's row: Spotify's queue control is what says this is the player's footer.
    UIView *queue = DFUIFind(host, @"QueueButtonNowPlaying", 10);
    if (!queue) return;
    UIView *connect = DFUIFind(host, @"Components.ConnectButtonOutputSwitcher", 10);
    UIButton *info = DFUIInfoButton(host);
    UIView *lyrics = DFUILyricsGlyph(host, info);

    NSMutableArray<UIView *> *row = [NSMutableArray array];
    if (lyrics) [row addObject:lyrics];
    if (connect) [row addObject:connect];
    [row addObject:queue];
    [row addObject:info];

    BOOL rtl = host.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    CGFloat width = host.bounds.size.width, middle = CGRectGetMidY(host.bounds);
    NSUInteger count = row.count;
    for (NSUInteger i = 0; i < count; i++) {
        CGFloat share = count > 1 ? kLeading + (kTrailing - kLeading) * (CGFloat)i / (CGFloat)(count - 1) : 0.5;
        CGFloat x = round(width * (rtl ? 1 - share : share));
        UIView *view = row[i];
        if (view == info) {
            CGRect bounds = CGRectMake(0, 0, kTouch, kTouch);
            if (!CGRectEqualToRect(info.bounds, bounds)) info.bounds = bounds;
            CGPoint center = CGPointMake(x, middle);
            if (!CGPointEqualToPoint(info.center, center)) info.center = center;
        } else if (view == lyrics) {
            CGPoint center = CGPointMake(x, lyrics.center.y);
            if (!CGPointEqualToPoint(lyrics.center, center)) lyrics.center = center;
        } else if (view == connect) {
            DFUIMoveTo(DFUIArrangedAround(connect, host), DFUIConnectGlyph(connect) ?: connect, host, x);
        } else {
            DFUIMoveTo(DFUIArrangedAround(queue, host), queue, host, x);
        }
    }
    info.hidden = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSLog(@"[distrofind] redesigned footer: %lu glyphs evenly from %.0f to %.0f (lyrics %@, devices %@)",
              (unsigned long)count, width * kLeading, width * kTrailing, lyrics ? @"found" : @"missing", connect ? @"found" : @"missing");
    });
}

// The pass after this one, once per host at a time.
static void DFUIQueueFooter(UIView *host) {
    if ([objc_getAssociatedObject(host, &kQueuedKey) boolValue]) return;
    objc_setAssociatedObject(host, &kQueuedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *weakHost = host;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *later = weakHost;
        if (!later) return;
        objc_setAssociatedObject(later, &kQueuedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        DFUIPlaceFooter(later);
    });
}

// The chip follows the track and its distributor, which arrive after the unit last laid out.
@interface DFUIPlayerObserver : NSObject
@end

@implementation DFUIPlayerObserver
- (instancetype)init {
    if ((self = [super init])) {
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(changed:) name:DFCurrentTrackChangedNotification object:nil];
        [center addObserver:self selector:@selector(changed:) name:DFMetadataReadyNotification object:nil];
    }
    return self;
}
- (void)changed:(NSNotification *)note {
    UIView *host = df_infoHost;
    if (!host) return;
    NSString *trackID = [note.object isKindOfClass:NSString.class] ? note.object : nil;
    if ([note.name isEqualToString:DFMetadataReadyNotification] && ![trackID isEqualToString:DFUICurrentTrackID()]) return;
    DFUIPlaceTitleChip(host);
}
@end

static DFUIPlayerObserver *df_playerObserver;

%group DFRedesignedPlayer

%hook _TtC20NowPlaying_ModesImpl23InformationElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    DFUIPlaceTitleChip(((UIViewController *)self).viewIfLoaded);
}
%end

%hook _TtC20NowPlaying_ModesImpl18FooterElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    UIView *host = ((UIViewController *)self).viewIfLoaded;
    DFUIPlaceFooter(host);
    if (host) DFUIQueueFooter(host);
}
%end

%end

#pragma mark - the artist page's ⋯

static BOOL DFUIIsBase62(NSString *value) {
    if (value.length != 22) return NO;
    static NSCharacterSet *illegal;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        illegal = [[NSCharacterSet characterSetWithCharactersInString:
            @"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"] invertedSet];
    });
    return [value rangeOfCharacterFromSet:illegal].location == NSNotFound;
}

static NSString *DFUIArtistFromIdentifier(NSString *identifier) {
    if (![identifier hasPrefix:kArtistMoreButton]) return nil;
    NSString *artist = [identifier substringFromIndex:kArtistMoreButton.length];
    return DFUIIsBase62(artist) ? artist : nil;
}

static UIView *DFUICreatorPage(UIView *view) {
    for (UIView *v = view; v; v = v.superview) {
        if ([v.accessibilityIdentifier isEqualToString:kCreatorPage]) return v;
    }
    return nil;
}

static BOOL DFUIInsideCell(UIView *view, UIView *stop) {
    for (UIView *v = view; v && v != stop; v = v.superview) {
        if ([v isKindOfClass:UICollectionViewCell.class] || [v isKindOfClass:UITableViewCell.class]) return YES;
    }
    return NO;
}

// The artist header's ⋯ on a creator page, wherever the header has put it. Rows are skipped, so a track's
// own ⋯ is never taken for the artist's.
static NSString *DFUIArtistOnPage(UIView *page) {
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:page];
    NSUInteger visited = 0;
    while (queue.count && visited++ < 1500) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        NSString *artist = DFUIArtistFromIdentifier(view.accessibilityIdentifier);
        if (artist) return artist;
        if ([view isKindOfClass:UICollectionViewCell.class] || [view isKindOfClass:UITableViewCell.class]) continue;
        [queue addObjectsFromArray:view.subviews];
    }
    return nil;
}

static void DFUIRememberArtist(NSString *artist) {
    df_menuArtist = [artist copy];
    df_menuArtistAt = CFAbsoluteTimeGetCurrent();
}

// Spotify can move the artist's ⋯ into the navigation bar (ios-creator-impl.context_menu_in_navigation_bar_
// enabled_artist), out of the creator page. There it counts only while the bar's top page is an artist's.
static BOOL DFUIBarOverArtist(UIView *view) {
    UINavigationBar *bar = nil;
    for (UIView *v = view; v && !bar; v = v.superview) {
        if ([v isKindOfClass:UINavigationBar.class]) bar = (UINavigationBar *)v;
    }
    if (!bar) return NO;
    UINavigationController *nav = nil;
    for (UIResponder *r = bar; r && !nav; r = r.nextResponder) {
        if ([r isKindOfClass:UINavigationController.class]) nav = (UINavigationController *)r;
    }
    UIView *top = nav.topViewController.viewIfLoaded;
    return top && DFUIFind(top, kCreatorPage, 6) != nil;
}

// A control that is, or is in, the artist header's ⋯; or the redesign's pinned ⋯ on the creator page.
static void DFUINoteControl(UIView *control) {
    UIView *v = control;
    for (NSUInteger depth = 0; v && depth < 4; depth++, v = v.superview) {
        NSString *artist = DFUIArtistFromIdentifier(v.accessibilityIdentifier);
        if (!artist) continue;
        UIView *page = DFUICreatorPage(v);
        if (page ? !DFUIInsideCell(v, page) : DFUIBarOverArtist(v)) DFUIRememberArtist(artist);
        return;
    }
    UIView *page = control.superview;
    if ([page.accessibilityIdentifier isEqualToString:kCreatorPage] && [NSStringFromClass(control.class) containsString:@"Mirror"]) {
        NSString *artist = DFUIArtistOnPage(page);
        if (artist) DFUIRememberArtist(artist);
    }
}

// One row of the block: a glyph, a word, and the sheet's whole width to tap -- the measures of the
// redesign's own rows on this sheet.
static const CGFloat kRowHeight = 56, kSideMargin = 16, kGlyphSide = 24, kGlyphGap = 16;

@interface DFUIMenuRow : UIControl
- (instancetype)initWithSymbol:(NSString *)symbol word:(NSString *)word;
@end

@implementation DFUIMenuRow {
    UIImageView *_glyph;
    UILabel *_word;
}

- (instancetype)initWithSymbol:(NSString *)symbol word:(NSString *)word {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    _glyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    _glyph.contentMode = UIViewContentModeScaleAspectFit;
    _glyph.tintColor = UIColor.whiteColor;
    _glyph.userInteractionEnabled = NO;
    [self addSubview:_glyph];
    _word = [UILabel new];
    _word.text = word;
    _word.textColor = UIColor.whiteColor;
    _word.font = [UIFont systemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleBody].pointSize weight:UIFontWeightRegular];
    _word.userInteractionEnabled = NO;
    [self addSubview:_word];
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = word;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    [self addTarget:self action:@selector(df_down) forControlEvents:UIControlEventTouchDown];
    [self addTarget:self action:@selector(df_up)
   forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    _glyph.frame = CGRectMake(kSideMargin, round((bounds.size.height - kGlyphSide) / 2), kGlyphSide, kGlyphSide);
    CGFloat lead = kSideMargin + kGlyphSide + kGlyphGap;
    [_word sizeToFit];
    _word.frame = CGRectMake(lead, round((bounds.size.height - _word.bounds.size.height) / 2),
                             MAX(0, bounds.size.width - lead - kSideMargin), _word.bounds.size.height);
}

- (void)df_down { self.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10]; }
- (void)df_up { self.backgroundColor = UIColor.clearColor; }

@end

// The two rows, under whatever footer Spotify already had on the sheet.
@interface DFUIArtistMenuBlock : UIView
@property (nonatomic, copy) NSString *artistID;
@property (nonatomic, weak) UIViewController *menu;
@property (nonatomic, strong) UIView *spotifyFooter;
@property (nonatomic) NSUInteger wraps;
- (CGFloat)wantedHeight;
@end

@implementation DFUIArtistMenuBlock {
    DFUIMenuRow *_scan, *_regions;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _scan = [[DFUIMenuRow alloc] initWithSymbol:@"magnifyingglass" word:@"Artist Scan"];
    _regions = [[DFUIMenuRow alloc] initWithSymbol:@"globe" word:@"Regioned Releases"];
    for (DFUIMenuRow *row in @[_scan, _regions]) {
        [row addTarget:self action:@selector(df_tapped:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:row];
    }
    return self;
}

- (CGFloat)spotifyHeight {
    return self.spotifyFooter.bounds.size.height >= 1 ? self.spotifyFooter.bounds.size.height : 0;
}

- (CGFloat)wantedHeight {
    return [self spotifyHeight] + 2 * kRowHeight;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width, top = [self spotifyHeight];
    if (self.spotifyFooter) self.spotifyFooter.frame = CGRectMake(0, 0, width, top);
    _scan.frame = CGRectMake(0, top, width, kRowHeight);
    _regions.frame = CGRectMake(0, top + kRowHeight, width, kRowHeight);
}

// The sheet closes first, so the tool's own sheet is not put up behind it.
- (void)df_tapped:(DFUIMenuRow *)row {
    NSString *artist = self.artistID;
    BOOL regions = row == _regions;
    void (^open)(void) = ^{ DFUIOpenArtistTool(artist, regions); };
    UIViewController *menu = self.menu;
    UIViewController *presented = menu.navigationController ?: menu;
    if (presented.presentingViewController) [presented dismissViewControllerAnimated:YES completion:open];
    else open();
}

@end

static void DFUIArtistMenu(UIViewController *menu) {
    // Decided once per sheet, from the ⋯ that opened it, and that ⋯ is spent on it.
    id decided = objc_getAssociatedObject(menu, &kMenuArtistKey);
    if (!decided) {
        BOOL recent = df_menuArtist.length && CFAbsoluteTimeGetCurrent() - df_menuArtistAt <= kMenuWindow;
        decided = recent ? df_menuArtist : (id)NSNull.null;
        objc_setAssociatedObject(menu, &kMenuArtistKey, decided, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (recent) df_menuArtist = nil;
    }
    if (decided == NSNull.null) return;

    UITableView *table = DFUITable(menu.viewIfLoaded, 9);
    CGFloat width = table.bounds.size.width;
    if (!table || width < 100) return;
    DFUIArtistMenuBlock *block = objc_getAssociatedObject(menu, &kMenuBlockKey);
    if (!block) {
        block = [[DFUIArtistMenuBlock alloc] initWithFrame:CGRectZero];
        block.artistID = decided;
        block.menu = menu;
        objc_setAssociatedObject(menu, &kMenuBlockKey, block, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSLog(@"[distrofind] artist ⋯ sheet gets Artist Scan and Regioned Releases");
    }
    // A footer of Spotify's goes inside the block, above the rows, and stays Spotify's. A sheet that keeps
    // putting its footer back is left to it after a few rounds rather than fought over every pass.
    UIView *footer = table.tableFooterView;
    if (footer && footer != block) {
        if (block.wraps >= 4) return;
        block.wraps++;
        if (block.spotifyFooter && block.spotifyFooter != footer) [block.spotifyFooter removeFromSuperview];
        block.spotifyFooter = nil;
        if (footer.bounds.size.height >= 1) {
            [footer removeFromSuperview];
            block.spotifyFooter = footer;
            [block addSubview:footer];
        }
        table.tableFooterView = nil;
    }
    CGRect frame = CGRectMake(0, 0, width, [block wantedHeight]);
    if (table.tableFooterView == block && CGRectEqualToRect(block.frame, frame)) return;
    block.frame = frame;
    [block setNeedsLayout];
    table.tableFooterView = block;
    [table invalidateIntrinsicContentSize];
}

%group DFArtistMenu

%hook UIControl
- (void)sendAction:(SEL)action to:(id)target forEvent:(UIEvent *)event {
    DFUINoteControl((UIView *)self);
    %orig;
}
// Some of Encore's buttons read their tap through a recognizer and never send an action; a touch on the
// artist's own ⋯ is noted as it begins, the way the redesign notes its pinned ⋯ on touch down.
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    if ([self.accessibilityIdentifier hasPrefix:kArtistMoreButton]) DFUINoteControl((UIView *)self);
    %orig;
}
%end

%hook _TtC24ContextMenu_InternalImpl25ContextMenuViewController
- (void)viewDidLayoutSubviews {
    %orig;
    DFUIArtistMenu((UIViewController *)self);
}
%end

%end

%ctor {
    %init(DFArtistMenu);
    if (!DFRedesignedPlayerEnabled()) {
        NSLog(@"[distrofind] native look: the player is left as Spotify draws it");
        return;
    }
    %init(DFRedesignedPlayer);
    df_playerObserver = [DFUIPlayerObserver new];
    NSLog(@"[distrofind] redesigned player: distributor chip and Info glyph installed");
}
