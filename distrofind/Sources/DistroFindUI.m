#import "Core/SGCore.h"
#import "DistroFindRuntime.h"
#import "DistroFindUI.h"
#import "Shared/DistroFind/DistroFind.h"
#import "Shared/DistroFind/DistroFindRemote.h"
#import "Shared/DistroFind/DistroFindServer.h"
#import "Shared/DistroFind/DistroFindArtist.h"

@interface DFPanelController : UIViewController
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, copy) NSString *body;
- (instancetype)initWithTitle:(NSString *)title body:(NSString *)body;
- (void)setPanelBody:(NSString *)body;
@end

@implementation DFPanelController
- (instancetype)initWithTitle:(NSString *)title body:(NSString *)body {
    if (!(self = [super init])) return nil;
    self.title = title;
    _body = [body copy] ?: @"";
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1];
    _textView = [UITextView new];
    _textView.translatesAutoresizingMaskIntoConstraints = NO;
    _textView.editable = NO;
    _textView.selectable = YES;
    _textView.backgroundColor = UIColor.clearColor;
    _textView.textColor = UIColor.whiteColor;
    _textView.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    _textView.textContainerInset = UIEdgeInsetsMake(18, 16, 28, 16);
    _textView.text = _body;
    [self.view addSubview:_textView];
    [NSLayoutConstraint activateConstraints:@[
        [_textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_textView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_textView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                     target:self action:@selector(close)];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)setPanelBody:(NSString *)body {
    _body = [body copy] ?: @"";
    if (self.isViewLoaded) _textView.text = _body;
}
@end

@interface DFImageController : UIViewController
@property (nonatomic, strong) UIImage *image;
- (instancetype)initWithTitle:(NSString *)title image:(UIImage *)image;
@end

@implementation DFImageController
- (instancetype)initWithTitle:(NSString *)title image:(UIImage *)image {
    if (!(self = [super init])) return nil;
    self.title = title;
    _image = image;
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    UIImageView *view = [[UIImageView alloc] initWithImage:_image];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    view.contentMode = UIViewContentModeScaleAspectFit;
    [self.view addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [view.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [view.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
    ]];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                     target:self action:@selector(close)];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

static UIViewController *DFPresenter(UIViewController *presenter) {
    return presenter ?: DFTopController();
}

static DFPanelController *DFShowPanel(NSString *title, NSString *body, UIViewController *presenter) {
    presenter = DFPresenter(presenter);
    if (!presenter) return nil;
    DFPanelController *panel = [[DFPanelController alloc] initWithTitle:title body:body];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:panel];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [presenter presentViewController:nav animated:YES completion:nil];
    return panel;
}

static void DFShowImage(NSString *title, UIImage *image, UIViewController *presenter) {
    presenter = DFPresenter(presenter);
    if (!presenter || !image) return;
    DFImageController *panel = [[DFImageController alloc] initWithTitle:title image:image];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:panel];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [presenter presentViewController:nav animated:YES completion:nil];
}

static void DFPresentActionSheet(UIAlertController *alert, UIViewController *presenter) {
    presenter = DFPresenter(presenter);
    if (!presenter) return;
    UIPopoverPresentationController *popover = alert.popoverPresentationController;
    if (popover) {
        popover.sourceView = presenter.view;
        popover.sourceRect = CGRectMake(CGRectGetMidX(presenter.view.bounds),
                                        CGRectGetMaxY(presenter.view.bounds) - 80, 1, 1);
        popover.permittedArrowDirections = 0;
    }
    [presenter presentViewController:alert animated:YES completion:nil];
}

static NSString *DFStr(id value) {
    return [value isKindOfClass:NSString.class] ? value : nil;
}
static NSArray *DFArr(id value) {
    return [value isKindOfClass:NSArray.class] ? value : @[];
}
static NSDictionary *DFDic(id value) {
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
static NSString *DFExternalID(NSDictionary *json, NSString *type) {
    for (NSDictionary *entry in DFArr(json[@"external_id"])) {
        if ([[DFStr(entry[@"type"]) lowercaseString] isEqualToString:type.lowercaseString])
            return DFStr(entry[@"id"]);
    }
    return nil;
}
static NSString *DFArtists(NSDictionary *json) {
    NSMutableArray *names = [NSMutableArray array];
    for (NSDictionary *artist in DFArr(json[@"artist"])) {
        NSString *name = DFStr(artist[@"name"]);
        if (name.length) [names addObject:name];
    }
    return [names componentsJoinedByString:@", "];
}
static NSString *DFDate(NSDictionary *json) {
    NSDictionary *date = DFDic(json[@"date"]);
    NSNumber *year = [date[@"year"] respondsToSelector:@selector(integerValue)] ? date[@"year"] : nil;
    if (!year.integerValue) return @"";
    NSNumber *month = [date[@"month"] respondsToSelector:@selector(integerValue)] ? date[@"month"] : nil;
    NSNumber *day = [date[@"day"] respondsToSelector:@selector(integerValue)] ? date[@"day"] : nil;
    NSMutableArray *parts = [NSMutableArray arrayWithObject:[NSString stringWithFormat:@"%04ld", (long)year.integerValue]];
    if (month.integerValue) [parts addObject:[NSString stringWithFormat:@"%02ld", (long)month.integerValue]];
    if (day.integerValue) [parts addObject:[NSString stringWithFormat:@"%02ld", (long)day.integerValue]];
    return [parts componentsJoinedByString:@"-"];
}
static NSString *DFDuration(id value) {
    long long ms = [value respondsToSelector:@selector(longLongValue)] ? [value longLongValue] : 0;
    if (ms <= 0) return @"";
    if (ms < 10000) ms *= 1000;
    long long seconds = ms / 1000;
    return [NSString stringWithFormat:@"%lld:%02lld", seconds / 60, seconds % 60];
}
static void DFAppend(NSMutableString *out, NSString *name, id value) {
    NSString *text = nil;
    if ([value isKindOfClass:NSString.class]) text = value;
    else if ([value respondsToSelector:@selector(stringValue)]) text = [value stringValue];
    if (!text.length) return;
    [out appendFormat:@"%@ %@\n", [name stringByAppendingString:@":"], text];
}

static void DFTrackInfo(NSString *trackID, NSString *fallbackName, UIViewController *presenter) {
    DFPanelController *panel = DFShowPanel(@"Track Info", @"Loading Spotify metadata…", presenter);
    if (!panel) return;

    dispatch_group_t group = dispatch_group_create();
    __block SGDistroMetadata *meta = nil;
    __block NSDictionary *track = nil;
    __block NSDictionary *album = nil;
    __block NSString *vydia = nil;
    __block NSError *firstError = nil;

    dispatch_group_enter(group);
    SGDistroMetadataForTrack(trackID, ^(SGDistroMetadata *value, NSError *error) {
        meta = value;
        if (!firstError && error) firstError = error;
        if (value && [value.licensorUUID.lowercaseString isEqualToString:@"9c290842b7fa4396bb0dcb3ad95634f5"]
            && !value.likelyDistributor.length && value.albumID.length) {
            SGDistroVydiaSubDistributor(value.albumID, @"", value.artist, ^(NSString *sub) {
                vydia = sub;
                dispatch_group_leave(group);
            });
        } else {
            dispatch_group_leave(group);
        }
    });

    dispatch_group_enter(group);
    DFSpotifyMetadataJSON(@"track", trackID, ^(NSDictionary *value, NSError *error) {
        track = value;
        if (!firstError && error) firstError = error;
        NSString *gid = DFStr(DFDic(value[@"album"])[@"gid"]);
        if (!gid.length) {
            dispatch_group_leave(group);
            return;
        }
        DFSpotifyMetadataJSONForGID(@"album", gid, ^(NSDictionary *fullAlbum, NSError *albumError) {
            album = fullAlbum ?: DFDic(value[@"album"]);
            if (!firstError && albumError) firstError = albumError;
            dispatch_group_leave(group);
        });
    });

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        if (!track && !meta) {
            [panel setPanelBody:firstError.localizedDescription ?: @"Spotify did not return this track."];
            return;
        }
        NSDictionary *albumJSON = album ?: DFDic(track[@"album"]) ?: @{};
        NSMutableString *out = [NSMutableString string];

        NSString *title = DFStr(track[@"name"]) ?: meta.title ?: fallbackName;
        NSString *artists = DFArtists(track);
        if (!artists.length) artists = meta.artist;
        DFAppend(out, @"Track", title);
        DFAppend(out, @"Artist(s)", artists);
        DFAppend(out, @"Album", DFStr(albumJSON[@"name"]) ?: DFStr(DFDic(track[@"album"])[@"name"]));
        DFAppend(out, @"Type", [DFStr(albumJSON[@"type"]) lowercaseString]);
        DFAppend(out, @"Track no.", track[@"number"]);
        DFAppend(out, @"Duration", DFDuration(track[@"duration"]));
        DFAppend(out, @"Release", DFDate(albumJSON));
        DFAppend(out, @"ISRC", DFExternalID(track, @"isrc") ?: meta.isrc);
        DFAppend(out, @"UPC", DFExternalID(albumJSON, @"upc"));
        DFAppend(out, @"Label", DFStr(albumJSON[@"label"]) ?: meta.label);

        NSString *parent = meta.distributor;
        NSString *likely = vydia.length ? vydia : meta.likelyDistributor;
        DFAppend(out, @"Distributor", likely.length ? likely : (parent.length ? parent : (meta.licensorUUID.length ? @"Unknown" : @"?")));
        DFAppend(out, @"Parent distro", parent);
        DFAppend(out, @"Likely sub", likely);
        DFAppend(out, @"Licensor UUID", meta.licensorUUID);
        DFAppend(out, @"Spotify ID", trackID);

        long long live = [track[@"earliest_live_timestamp"] respondsToSelector:@selector(longLongValue)]
            ? [track[@"earliest_live_timestamp"] longLongValue] : 0;
        if (!live) live = [albumJSON[@"earliest_live_timestamp"] respondsToSelector:@selector(longLongValue)]
            ? [albumJSON[@"earliest_live_timestamp"] longLongValue] : 0;
        if (live) {
            NSDate *date = [NSDate dateWithTimeIntervalSince1970:live];
            DFAppend(out, @"Earliest live", [NSDateFormatter localizedStringFromDate:date
                dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle]);
        }

        NSMutableArray *copyrights = [NSMutableArray array];
        for (NSDictionary *entry in DFArr(albumJSON[@"copyright"])) {
            NSString *text = DFStr(entry[@"text"]);
            if (text.length) [copyrights addObject:text];
        }
        if (copyrights.count) {
            [out appendString:@"\nCopyright\n"];
            for (NSString *line in copyrights) [out appendFormat:@"• %@\n", line];
        }

        if (meta.allowedCountries.count || meta.forbiddenCountries.count) {
            [out appendString:@"\nMetadata restrictions\n"];
            if (meta.allowedCountries.count)
                [out appendFormat:@"Allowed: %lu markets\n", (unsigned long)meta.allowedCountries.count];
            if (meta.forbiddenCountries.count)
                [out appendFormat:@"Forbidden: %@\n", [meta.forbiddenCountries componentsJoinedByString:@", "]];
        }

        [panel setPanelBody:out];
    });
}

static void DFAvailability(NSString *trackID, UIViewController *presenter) {
    DFPanelController *panel = DFShowPanel(@"Availability", @"Checking regions…", presenter);
    SGDistroAvailabilityForTrack(trackID, ^(SGDistroAvailability *result, NSError *error) {
        if (error || !result) {
            [panel setPanelBody:error.localizedDescription ?: @"Availability lookup failed."];
            return;
        }
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"Status: %@\n", result.kind.capitalizedString ?: @"Unknown"];
        [out appendFormat:@"Available markets: %lu\n", (unsigned long)result.available.count];
        [out appendFormat:@"Blocked markets: %lu\n", (unsigned long)result.blocked.count];
        if (result.seconds > 0) [out appendFormat:@"Checked in: %.1fs\n", result.seconds];
        if (result.blocked.count) {
            [out appendString:@"\nBlocked\n"];
            [out appendString:[result.blocked componentsJoinedByString:@", "]];
            [out appendString:@"\n"];
        } else if (result.available.count) {
            [out appendString:@"\nAvailable\n"];
            [out appendString:[result.available componentsJoinedByString:@", "]];
            [out appendString:@"\n"];
        }
        [panel setPanelBody:out];
    });
}

static void DFPerformance(NSString *trackID, UIViewController *presenter) {
    DFPanelController *loading = DFShowPanel(@"Performance", @"Loading performance chart…", presenter);
    SGDistroPerformanceImageForTrack(trackID, ^(UIImage *image, NSString *message, NSError *error) {
        if (image) {
            [loading dismissViewControllerAnimated:NO completion:^{
                DFShowImage(@"Performance", image, DFTopController());
            }];
        } else {
            [loading setPanelBody:message.length ? message : (error.localizedDescription ?: @"Not enough data.")];
        }
    });
}

static void DFCollectTrackIDs(id object, NSMutableOrderedSet<NSString *> *ids) {
    if (!object || ids.count >= 50) return;
    if ([object isKindOfClass:NSString.class]) {
        NSString *text = object;
        NSRegularExpression *re = [NSRegularExpression
            regularExpressionWithPattern:@"(?:spotify:track:|open\\.spotify\\.com/track/)([A-Za-z0-9]{22})"
                                  options:NSRegularExpressionCaseInsensitive error:nil];
        for (NSTextCheckingResult *match in [re matchesInString:text options:0 range:NSMakeRange(0, text.length)]) {
            if (match.numberOfRanges > 1) [ids addObject:[text substringWithRange:[match rangeAtIndex:1]]];
        }
        return;
    }
    if ([object isKindOfClass:NSDictionary.class]) {
        for (id value in [(NSDictionary *)object allValues]) DFCollectTrackIDs(value, ids);
    } else if ([object isKindOfClass:NSArray.class]) {
        for (id value in (NSArray *)object) DFCollectTrackIDs(value, ids);
    }
}

static void DFOtherVersions(NSString *trackID, UIViewController *presenter) {
    DFPanelController *panel = DFShowPanel(@"Other Versions", @"Looking for releases with the same recording…", presenter);
    SGDistroOtherVersionsForTrack(trackID, ^(NSDictionary *result, NSError *error) {
        if (error || !result) {
            [panel setPanelBody:error.localizedDescription ?: @"Other Versions lookup failed."];
            return;
        }
        NSMutableOrderedSet<NSString *> *ids = [NSMutableOrderedSet orderedSet];
        DFCollectTrackIDs(result, ids);
        [ids removeObject:trackID];
        if (!ids.count) {
            [panel setPanelBody:@"No other Spotify versions were returned."];
            return;
        }

        NSMutableDictionary<NSString *, SGDistroMetadata *> *info = [NSMutableDictionary dictionary];
        dispatch_group_t group = dispatch_group_create();
        for (NSString *sid in ids) {
            dispatch_group_enter(group);
            SGDistroMetadataForTrack(sid, ^(SGDistroMetadata *meta, NSError *metaError) {
                if (meta) info[sid] = meta;
                dispatch_group_leave(group);
            });
        }
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            NSMutableString *out = [NSMutableString stringWithFormat:@"%lu other version%@\n\n",
                (unsigned long)ids.count, ids.count == 1 ? @"" : @"s"];
            NSUInteger n = 1;
            for (NSString *sid in ids) {
                SGDistroMetadata *meta = info[sid];
                NSString *distro = SGDistroDisplayName(meta) ?: @"?";
                [out appendFormat:@"%lu. %@%@\n", (unsigned long)n++,
                    meta.title.length ? meta.title : sid,
                    meta.artist.length ? [NSString stringWithFormat:@" — %@", meta.artist] : @""];
                [out appendFormat:@"   %@%@\n", distro,
                    meta.label.length ? [NSString stringWithFormat:@" · %@", meta.label] : @""];
                [out appendFormat:@"   https://open.spotify.com/track/%@\n\n", sid];
            }
            [panel setPanelBody:out];
        });
    });
}

void DFShowTrackActions(NSString *trackID, NSString *name, UIViewController *presenter) {
    if (trackID.length != 22) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:name.length ? name : @"DistroFind"
        message:trackID preferredStyle:UIAlertControllerStyleActionSheet];

    [alert addAction:[UIAlertAction actionWithTitle:@"Track Info" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *a) { DFTrackInfo(trackID, name, DFPresenter(presenter)); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Availability" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *a) { DFAvailability(trackID, DFPresenter(presenter)); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Performance" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *a) { DFPerformance(trackID, DFPresenter(presenter)); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Other Versions" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *a) { DFOtherVersions(trackID, DFPresenter(presenter)); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    DFPresentActionSheet(alert, presenter);
}

#pragma mark - Artist pages

static void DFArtistScanUI(NSString *artistID, UIViewController *presenter) {
    DFPanelController *panel = DFShowPanel(@"Artist Scan", @"Reading artist releases…", presenter);
    DFScanArtist(artistID, ^(NSUInteger completed, NSUInteger total) {
        [panel setPanelBody:[NSString stringWithFormat:@"Scanning distributors… %lu/%lu",
            (unsigned long)completed, (unsigned long)total]];
    }, ^(NSArray<DFArtistRelease *> *releases, NSError *error) {
        if (error) {
            [panel setPanelBody:error.localizedDescription];
            return;
        }
        NSMutableDictionary<NSString *, NSMutableArray<DFArtistRelease *> *> *groups = [NSMutableDictionary dictionary];
        for (DFArtistRelease *release in releases) {
            NSString *name = DFReleaseDisplayDistributor(release);
            if (!groups[name]) groups[name] = [NSMutableArray array];
            [groups[name] addObject:release];
        }
        NSArray *names = [groups.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            NSUInteger ac = groups[a].count, bc = groups[b].count;
            if (ac != bc) return ac > bc ? NSOrderedAscending : NSOrderedDescending;
            return [a compare:b options:NSCaseInsensitiveSearch];
        }];
        NSMutableString *out = [NSMutableString stringWithFormat:@"%lu releases · %lu distributors\n",
            (unsigned long)releases.count, (unsigned long)names.count];
        for (NSString *distro in names) {
            [out appendFormat:@"\n%@ (%lu)\n", distro, (unsigned long)groups[distro].count];
            for (DFArtistRelease *release in groups[distro]) {
                [out appendFormat:@"• %@%@%@\n", release.name,
                    release.year.length ? [NSString stringWithFormat:@" · %@", release.year] : @"",
                    release.label.length ? [NSString stringWithFormat:@" · %@", release.label] : @""];
            }
        }
        [panel setPanelBody:out];
    });
}

static void DFRegionedReleasesUI(NSString *artistID, UIViewController *presenter) {
    DFPanelController *panel = DFShowPanel(@"Regioned Releases", @"Reading your Spotify market…", presenter);
    DFSpotifyAccountMarket(^(NSString *market) {
        [panel setPanelBody:[NSString stringWithFormat:@"Scanning releases for %@…", market.length ? market : @"your market"]];
        DFScanArtist(artistID, ^(NSUInteger completed, NSUInteger total) {
            [panel setPanelBody:[NSString stringWithFormat:@"Scanning %@… %lu/%lu",
                market.length ? market : @"releases", (unsigned long)completed, (unsigned long)total]];
        }, ^(NSArray<DFArtistRelease *> *releases, NSError *error) {
            if (error) {
                [panel setPanelBody:error.localizedDescription];
                return;
            }
            NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(DFArtistRelease *release, NSDictionary *bindings) {
                return DFReleaseUnavailableInMarket(release, market);
            }];
            NSArray<DFArtistRelease *> *locked = [releases filteredArrayUsingPredicate:predicate];
            NSMutableString *out = [NSMutableString stringWithFormat:@"Market: %@\n%lu regioned release%@\n",
                market.length ? market : @"Unknown",
                (unsigned long)locked.count, locked.count == 1 ? @"" : @"s"];
            for (DFArtistRelease *release in locked) {
                [out appendFormat:@"\n%@%@\n%@ · %@\nspotify:album:%@\n",
                    release.name,
                    release.year.length ? [NSString stringWithFormat:@" (%@)", release.year] : @"",
                    DFReleaseDisplayDistributor(release),
                    release.label.length ? release.label : release.type,
                    release.releaseID ?: @""];
            }
            if (!locked.count) [out appendString:@"\nNothing in the artist metadata is blocked in this market."];
            [panel setPanelBody:out];
        });
    });
}

#pragma mark - Distributor filters

static NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *df_pageDistros;
static NSMutableDictionary<NSString *, NSString *> *df_pageFilters;

static void DFEnsureFilterStorage(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df_pageDistros = [NSMutableDictionary dictionary];
        df_pageFilters = [NSMutableDictionary dictionary];
    });
}

void DFRegisterRowDistributor(NSString *pageURI, NSString *distributor) {
    if (!pageURI.length || !distributor.length) return;
    DFEnsureFilterStorage();
    @synchronized (df_pageDistros) {
        NSMutableSet *set = df_pageDistros[pageURI];
        if (!set) df_pageDistros[pageURI] = (set = [NSMutableSet set]);
        [set addObject:distributor];
    }
}

NSString *DFSelectedDistributor(NSString *pageURI) {
    if (!pageURI.length) return nil;
    DFEnsureFilterStorage();
    @synchronized (df_pageFilters) { return [df_pageFilters[pageURI] copy]; }
}

void DFInvalidateCollectionLayouts(UIView *root) {
    if (!root) return;
    if ([root isKindOfClass:UICollectionView.class]) {
        UICollectionView *view = (id)root;
        [view.collectionViewLayout invalidateLayout];
        [view setNeedsLayout];
    }
    for (UIView *child in root.subviews) DFInvalidateCollectionLayouts(child);
}

void DFShowDistributorFilter(NSString *pageURI, UIViewController *presenter) {
    if (!pageURI.length) return;
    DFEnsureFilterStorage();
    NSArray<NSString *> *names;
    @synchronized (df_pageDistros) {
        names = [[df_pageDistros[pageURI] allObjects]
            sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Distributor Filter"
        message:names.count ? @"Show only one distributor on this page." : @"Scroll through some tracks first so DistroFind can identify their distributors."
        preferredStyle:UIAlertControllerStyleActionSheet];

    [alert addAction:[UIAlertAction actionWithTitle:@"Search distributor…" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *a) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *search = [UIAlertController alertControllerWithTitle:@"Distributor Filter"
                    message:@"Type any part of a parent or likely distributor name."
                    preferredStyle:UIAlertControllerStyleAlert];
                [search addTextFieldWithConfigurationHandler:^(UITextField *field) {
                    field.placeholder = @"e.g. DistroKid, FUGA, DireNote";
                    field.text = DFSelectedDistributor(pageURI);
                    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
                    field.clearButtonMode = UITextFieldViewModeWhileEditing;
                }];
                [search addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
                [search addAction:[UIAlertAction actionWithTitle:@"Apply" style:UIAlertActionStyleDefault
                    handler:^(__unused UIAlertAction *apply) {
                        NSString *text = [search.textFields.firstObject.text stringByTrimmingCharactersInSet:
                            NSCharacterSet.whitespaceAndNewlineCharacterSet];
                        @synchronized (df_pageFilters) {
                            if (text.length) df_pageFilters[pageURI] = text;
                            else [df_pageFilters removeObjectForKey:pageURI];
                        }
                        DFInvalidateCollectionLayouts(DFPresenter(presenter).view);
                    }]];
                DFPresentActionSheet(search, presenter);
            });
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"All distributors" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *a) {
            @synchronized (df_pageFilters) { [df_pageFilters removeObjectForKey:pageURI]; }
            DFInvalidateCollectionLayouts(DFPresenter(presenter).view);
        }]];
    for (NSString *name in names) {
        [alert addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *a) {
                @synchronized (df_pageFilters) { df_pageFilters[pageURI] = name; }
                DFInvalidateCollectionLayouts(DFPresenter(presenter).view);
            }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    DFPresentActionSheet(alert, presenter);
}

#pragma mark - Page actions

static NSString *DFIDFromURI(NSString *uri, NSString *kind) {
    NSString *prefix = [NSString stringWithFormat:@"spotify:%@:", kind];
    if (![uri hasPrefix:prefix]) return nil;
    NSString *sid = [uri substringFromIndex:prefix.length];
    return sid.length == 22 ? sid : nil;
}

void DFShowPageActions(UIViewController *controller, NSString *pageURI) {
    if (!controller || !pageURI.length) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"DistroFind"
        message:pageURI preferredStyle:UIAlertControllerStyleActionSheet];

    NSString *artist = DFIDFromURI(pageURI, @"artist");
    NSString *track = DFIDFromURI(pageURI, @"track");
    BOOL listPage = [pageURI hasPrefix:@"spotify:album:"] || [pageURI hasPrefix:@"spotify:playlist:"];

    if (track) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Track actions" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *a) { DFShowTrackActions(track, nil, controller); }]];
    }
    if (artist) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Artist Scan" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *a) { DFArtistScanUI(artist, controller); }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Regioned Releases" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *a) { DFRegionedReleasesUI(artist, controller); }]];
    }
    if (listPage) {
        NSString *selected = DFSelectedDistributor(pageURI);
        NSString *title = selected.length ? [NSString stringWithFormat:@"Filter: %@", selected] : @"Filter by distributor";
        [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *a) { DFShowDistributorFilter(pageURI, controller); }]];
    }

    NSString *playing = DFCurrentTrackID();
    if (playing.length && ![playing isEqualToString:track]) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Current track actions" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *a) {
                DFShowTrackActions(playing, DFCurrentTrackTitle(), controller);
            }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    DFPresentActionSheet(alert, controller);
}
