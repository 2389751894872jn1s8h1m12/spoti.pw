// Source-aware track identification for the rows of a playlist, an album, Liked Songs and an artist's
// popular tracks. Never Spotify-search a displayed title: different releases of the same recording can
// have different licensors.
//
// A row's id comes only from the page's own source, in the page's own order: the playlist's items, the
// album's discs, the artist's top tracks, the library's saved tracks. And it is accepted only once that
// track's own metadata carries the row's title (and, where the row shows artists, one of them), so a
// guessed position can never put another track's distributor on a row.
//
// Where the source gives ids alone (spclient's playlist and album), the row's place in the list says which
// few ids to ask about: a row's ordinal in the collection view minus the header cells before the first
// track. That offset is not known up front, so the first rows ask about a window wide enough to hold it,
// and every row that matches pins it down for the rows after. Each match also asks ahead for the next few
// tracks, so their badges are ready by the time they scroll in.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "Shared/Spotify/Spclient.h"
#import "Shared/DistroFind/DistroFind.h"

// The companion's throttled, cached metadata resolver (DistroFindCompanion.x).
extern void DFLookupMetadata(NSString *trackID, BOOL urgent, void (^done)(SGDistroMetadata *meta));

typedef NS_ENUM(NSInteger, DFSourceKind) {
    DFSourcePlaylist,
    DFSourceAlbum,
    DFSourceLiked,
    DFSourceArtist,
};

static const NSInteger kAhead = 6, kBehind = 2;     // tracks prefetched around a row that matched
static const NSUInteger kMaxSources = 16, kMaxWaiters = 80;
static const NSUInteger kMaxWebRequests = 2;
// A list whose page names no source is asked again after this long, not on every row it lays out.
static const NSTimeInterval kNoSourceRetry = 5;
static NSUInteger df_webActive;
static BOOL df_loggedWebFailure;
static NSMutableDictionary<NSString *, id> *df_sources;
static NSMutableArray<NSString *> *df_sourceOrder;
static char kSourceURIKey, kNoSourceKey;

#pragma mark - text

static NSString *str(id s) {
    return [s isKindOfClass:NSString.class] ? s : [s isKindOfClass:NSURL.class] ? [s absoluteString] : nil;
}

static NSString *norm(NSString *s) {
    NSString *text = [str(s) ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
    NSArray *words = [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [[words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]] componentsJoinedByString:@" "];
}

static BOOL isBase62ID(NSString *value) {
    if (value.length != 22) return NO;
    static NSCharacterSet *illegal;
    if (!illegal) illegal = [[NSCharacterSet characterSetWithCharactersInString:
        @"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"] invertedSet];
    return [value rangeOfCharacterFromSet:illegal].location == NSNotFound;
}

static NSString *idFromURI(NSString *uri) {
    NSRange r = [uri rangeOfString:@"spotify:track:"];
    if (r.location == NSNotFound || uri.length < NSMaxRange(r) + 22) return nil;
    NSString *v = [uri substringWithRange:NSMakeRange(NSMaxRange(r), 22)];
    return isBase62ID(v) ? v : nil;
}

// The row shows "Artist, Artist" (sometimes behind an explicit or download mark); the metadata knows the
// same names joined the same way. One shared name is enough; a row with no artist line agrees with any.
static BOOL artistsAgree(NSString *row, NSString *known) {
    NSString *shown = row.lowercaseString ?: @"";
    if (!shown.length || !known.length) return YES;
    for (NSString *name in [known componentsSeparatedByString:@", "]) {
        if (name.length >= 2 && [shown containsString:name]) return YES;
    }
    return [known containsString:shown];
}

#pragma mark - the source

@interface DFRowWaiter : NSObject
@property (nonatomic, copy) NSString *title, *artist;
@property (nonatomic) NSInteger ordinal;
@property (nonatomic) NSInteger stage;   // 0 near the row, 1 wider, 2 most of the source
@property (nonatomic, strong) NSMutableArray *callbacks;
@end
@implementation DFRowWaiter
@end

@interface DFSource : NSObject
@property (nonatomic, copy) NSString *uri;
@property (nonatomic) DFSourceKind kind;
@property (nonatomic, strong) NSMutableArray<NSString *> *ids;      // by position, @"" for a non-track item
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *titles;   // normalized, @"" = unreadable
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *artists;  // lowercased
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *byTitle;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *asked, *askedUrgent;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *webLoading, *webDone;
@property (nonatomic, strong) NSMutableArray<DFRowWaiter *> *waiters;
@property (nonatomic) BOOL loading, loaded, failed, webMode, wakeQueued, shiftKnown;
@property (nonatomic) NSInteger total;   // -1 while unknown
@property (nonatomic) NSInteger shift;   // a row's ordinal minus its track's position
@end
@implementation DFSource
@end

static void wake(DFSource *s);

static void noteTitle(DFSource *s, NSInteger position, NSString *title, NSString *artists) {
    NSNumber *key = @(position);
    if (s.titles[key].length) return;
    NSString *t = norm(title);
    s.titles[key] = t;
    if (artists.length) s.artists[key] = artists.lowercaseString;
    if (!t.length) return;
    NSMutableArray *positions = s.byTitle[t];
    if (!positions) s.byTitle[t] = positions = [NSMutableArray array];
    [positions addObject:key];
}

static void setID(DFSource *s, NSInteger position, NSString *trackID) {
    while ((NSInteger)s.ids.count <= position) [s.ids addObject:@""];
    s.ids[position] = trackID ?: @"";
}

static NSString *idAt(DFSource *s, NSInteger position) {
    return position >= 0 && position < (NSInteger)s.ids.count ? s.ids[position] : @"";
}

// Asks for the metadata of every track in [from, to] not asked for yet. Urgent for the rows on screen,
// at the back of the queue for the ones prefetched ahead of them.
static void ask(DFSource *s, NSInteger from, NSInteger to, BOOL urgent) {
    from = MAX(0, from);
    to = MIN(to, (NSInteger)s.ids.count - 1);
    for (NSInteger position = from; position <= to; position++) {
        NSString *trackID = idAt(s, position);
        if (!trackID.length) continue;
        NSNumber *key = @(position);
        if (urgent ? [s.askedUrgent containsObject:key] : [s.asked containsObject:key]) continue;
        [s.asked addObject:key];
        if (urgent) [s.askedUrgent addObject:key];
        __weak DFSource *weakSource = s;
        DFLookupMetadata(trackID, urgent, ^(SGDistroMetadata *meta) {
            DFSource *source = weakSource;
            if (!source) return;
            if (![idAt(source, position) isEqualToString:trackID]) return;
            noteTitle(source, position, meta.title ?: @"", meta.artist);
            wake(source);
        });
    }
}

static NSString *match(DFSource *s, DFRowWaiter *w, NSInteger *outPosition) {
    NSArray<NSNumber *> *positions = s.byTitle[w.title];
    if (!positions.count) return nil;
    NSInteger expected = s.shiftKnown && w.ordinal >= 0 ? w.ordinal - s.shift : w.ordinal;
    NSString *best = nil;
    NSInteger bestPosition = -1, bestDistance = NSIntegerMax;
    for (NSNumber *key in positions) {
        NSInteger position = key.integerValue;
        NSString *trackID = idAt(s, position);
        if (!trackID.length || !artistsAgree(w.artist, s.artists[key])) continue;
        NSInteger distance = expected >= 0 ? labs(position - expected) : position;
        if (distance < bestDistance) {
            best = trackID;
            bestPosition = position;
            bestDistance = distance;
        }
    }
    if (outPosition) *outPosition = bestPosition;
    return best;
}

static NSInteger webLimit(DFSource *s) {
    return s.kind == DFSourcePlaylist ? 100 : 50;
}

// The positions a waiter at its stage needs settled before it gives up on that stage.
static NSRange windowFor(DFSource *s, DFRowWaiter *w) {
    NSInteger count = s.webMode ? (s.total >= 0 ? s.total : w.ordinal + 60) : (NSInteger)s.ids.count;
    NSInteger ordinal = MAX(0, w.ordinal);
    NSInteger center = s.shiftKnown ? ordinal - s.shift : ordinal;
    NSInteger from, to;
    // A small source is read whole: an album, an artist's top tracks.
    if (!s.webMode && count <= 60) {
        from = 0;
        to = count - 1;
    } else if (w.stage == 0) {
        from = s.shiftKnown ? center - 2 : ordinal - 10;
        to = s.shiftKnown ? center + 2 : ordinal + 3;
    } else if (w.stage == 1) {
        from = center - 25;
        to = center + 25;
    } else {
        from = center - 80;
        to = center + 80;
    }
    from = MAX(0, from);
    to = MIN(to, count - 1);
    if (to < from) return NSMakeRange(0, 0);
    return NSMakeRange((NSUInteger)from, (NSUInteger)(to - from + 1));
}

static BOOL idsSettled(DFSource *s, NSRange window) {
    for (NSUInteger position = window.location; position < NSMaxRange(window); position++) {
        if (idAt(s, (NSInteger)position).length && !s.titles[@(position)]) return NO;
    }
    return YES;
}

#pragma mark - the Web API (Liked Songs, and playlists spclient will not give)

static NSURL *webURL(DFSource *s, NSInteger offset) {
    NSString *base = nil;
    if (s.kind == DFSourcePlaylist) {
        base = [NSString stringWithFormat:@"https://api.spotify.com/v1/playlists/%@/tracks", [s.uri substringFromIndex:17]];
    } else if (s.kind == DFSourceAlbum) {
        base = [NSString stringWithFormat:@"https://api.spotify.com/v1/albums/%@/tracks", [s.uri substringFromIndex:14]];
    } else if (s.kind == DFSourceLiked) {
        base = @"https://api.spotify.com/v1/me/tracks";
    }
    if (!base) return nil;
    NSURLComponents *parts = [NSURLComponents componentsWithString:base];
    NSMutableArray *query = [NSMutableArray arrayWithObjects:
        [NSURLQueryItem queryItemWithName:@"offset" value:[NSString stringWithFormat:@"%ld", (long)offset]],
        [NSURLQueryItem queryItemWithName:@"limit" value:[NSString stringWithFormat:@"%ld", (long)webLimit(s)]], nil];
    if (s.kind == DFSourcePlaylist)
        [query addObject:[NSURLQueryItem queryItemWithName:@"fields" value:@"total,items(track(id,uri,name,artists(name)))"]];
    parts.queryItems = query;
    return parts.URL;
}

static NSString *artistNames(NSDictionary *item) {
    NSMutableArray *names = [NSMutableArray array];
    for (NSDictionary *a in [item[@"artists"] isKindOfClass:NSArray.class] ? item[@"artists"] : @[]) {
        if ([a isKindOfClass:NSDictionary.class] && str(a[@"name"])) [names addObject:a[@"name"]];
    }
    return [names componentsJoinedByString:@", "];
}

static void wakeAll(void) {
    for (NSString *uri in [df_sources.allKeys copy]) wake(df_sources[uri]);
}

static void loadWebPage(DFSource *s, NSInteger offset) {
    NSNumber *key = @(offset);
    if (offset < 0 || [s.webLoading containsObject:key] || [s.webDone containsObject:key]) return;
    if (s.total >= 0 && offset >= s.total) {
        [s.webDone addObject:key];
        return;
    }
    if (df_webActive >= kMaxWebRequests) return;   // asked again when a slot frees (wakeAll)
    NSURL *url = webURL(s, offset);
    NSMutableURLRequest *request = SGSpclientRequest(url);
    if (!request) {
        SGSpclientWhenReady(^{ wake(s); });
        return;
    }
    // The Web API takes the same bearer token, without spclient's routing headers.
    for (NSString *header in @[@"client-token", @"app-platform", @"spotify-app-version"])
        [request setValue:nil forHTTPHeaderField:header];
    request.timeoutInterval = 12;
    [s.webLoading addObject:key];
    df_webActive++;
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        id object = (!error && http.statusCode == 200 && data.length) ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *json = [object isKindOfClass:NSDictionary.class] ? object : nil;
        double retryAfter = [[http valueForHTTPHeaderField:@"Retry-After"] doubleValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (df_webActive) df_webActive--;
            [s.webLoading removeObject:key];
            if (http.statusCode == 429) {
                double delay = MIN(MAX(retryAfter, 1), 10);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ wake(s); });
                wakeAll();
                return;
            }
            [s.webDone addObject:key];
            if (!json) {
                if (!df_loggedWebFailure) {
                    df_loggedWebFailure = YES;
                    NSLog(@"[distrofind] exact row source unavailable (HTTP %ld); those rows stay without a badge", (long)http.statusCode);
                }
                if (offset == 0) s.failed = YES;
            } else {
                if ([json[@"total"] respondsToSelector:@selector(integerValue)]) s.total = [json[@"total"] integerValue];
                NSArray *items = [json[@"items"] isKindOfClass:NSArray.class] ? json[@"items"] : @[];
                for (NSUInteger i = 0; i < items.count; i++) {
                    NSDictionary *wrapper = [items[i] isKindOfClass:NSDictionary.class] ? items[i] : nil;
                    NSDictionary *track = [wrapper[@"track"] isKindOfClass:NSDictionary.class] ? wrapper[@"track"] : wrapper;
                    NSString *sid = str(track[@"id"]);
                    if (!isBase62ID(sid)) sid = idFromURI(str(track[@"uri"]));
                    NSInteger position = offset + (NSInteger)i;
                    setID(s, position, sid);
                    if (sid.length) noteTitle(s, position, str(track[@"name"]) ?: @"", artistNames(track));
                }
                if (s.total < 0 && items.count < (NSUInteger)webLimit(s)) s.total = offset + (NSInteger)items.count;
            }
            wake(s);
            wakeAll();
        });
    }] resume];
}

static BOOL webSettled(DFSource *s, NSRange window) {
    NSInteger limit = webLimit(s);
    NSInteger first = ((NSInteger)window.location / limit) * limit;
    NSInteger last = window.length ? ((NSInteger)NSMaxRange(window) - 1) : (NSInteger)window.location;
    BOOL settled = YES;
    for (NSInteger offset = first; offset <= last; offset += limit) {
        if (s.total >= 0 && offset >= s.total) break;
        if ([s.webDone containsObject:@(offset)]) continue;
        settled = NO;
        loadWebPage(s, offset);
    }
    return settled;
}

#pragma mark - spclient (playlists, albums, artists)

// spclient's playlist answer is protobuf. Its items are the track URIs, in the playlist's order, and
// nothing else in it is a track URI, so they are read straight off the bytes. Episodes and local files
// keep their place in the order with no id.
static NSArray<NSString *> *playlistIDsFromBody(NSData *data) {
    NSString *text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if (!text.length) return nil;
    static NSRegularExpression *items;
    if (!items) items = [NSRegularExpression regularExpressionWithPattern:
        @"spotify:(?:(track|episode):([0-9A-Za-z]{22})|local:[!-~]*)" options:0 error:nil];
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    for (NSTextCheckingResult *found in [items matchesInString:text options:0 range:NSMakeRange(0, text.length)]) {
        NSRange kind = [found rangeAtIndex:1], value = [found rangeAtIndex:2];
        BOOL track = kind.location != NSNotFound && [[text substringWithRange:kind] isEqualToString:@"track"];
        [ids addObject:track && value.location != NSNotFound ? [text substringWithRange:value] : @""];
    }
    return ids;
}

static void finishLoad(DFSource *s, NSArray<NSString *> *ids) {
    s.loading = NO;
    s.loaded = YES;
    if (ids.count) {
        [s.ids setArray:ids];
        s.total = (NSInteger)ids.count;
    } else if (s.kind == DFSourceArtist) {
        s.failed = YES;
    } else {
        // Fall back to the Web API, which also says the titles.
        s.webMode = YES;
        [s.ids removeAllObjects];
        s.total = -1;
    }
    static NSMutableSet *logged;
    if (!logged) logged = [NSMutableSet set];
    NSString *line = [NSString stringWithFormat:@"%ld-%@", (long)s.kind, s.webMode ? @"web" : s.failed ? @"none" : @"spclient"];
    if (![logged containsObject:line]) {
        [logged addObject:line];
        NSLog(@"[distrofind] row source kind %ld from %@ (%lu items)", (long)s.kind,
              s.webMode ? @"the Web API" : s.failed ? @"nowhere" : @"spclient", (unsigned long)s.ids.count);
    }
    wake(s);
}

static void loadSource(DFSource *s) {
    if (s.loading || s.loaded) return;
    s.loading = YES;
    if (s.kind == DFSourceLiked) {
        finishLoad(s, nil);
        return;
    }
    if (s.kind == DFSourcePlaylist) {
        NSString *playlistID = [s.uri substringFromIndex:17];
        NSURL *url = [NSURL URLWithString:[@"https://spclient.wg.spotify.com/playlist/v2/playlist/" stringByAppendingString:playlistID]];
        NSMutableURLRequest *request = SGSpclientRequest(url);
        if (!request) {
            s.loading = NO;
            SGSpclientWhenReady(^{ loadSource(s); });
            return;
        }
        [request setValue:@"application/x-protobuf" forHTTPHeaderField:@"Accept"];
        request.timeoutInterval = 15;
        [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
            NSArray *ids = !error && status == 200 && data.length ? playlistIDsFromBody(data) : nil;
            dispatch_async(dispatch_get_main_queue(), ^{ finishLoad(s, ids); });
        }] resume];
        return;
    }
    NSString *entity = s.kind == DFSourceAlbum ? @"album" : @"artist";
    NSString *spotifyID = [s.uri substringFromIndex:s.kind == DFSourceAlbum ? 14 : 15];
    SGDistroRawMetadataForSpotifyID(entity, spotifyID, ^(NSDictionary *json, NSError *error) {
        NSMutableArray<NSString *> *ids = [NSMutableArray array];
        if (s.kind == DFSourceAlbum) {
            for (NSDictionary *disc in [json[@"disc"] isKindOfClass:NSArray.class] ? json[@"disc"] : @[]) {
                if (![disc isKindOfClass:NSDictionary.class]) continue;
                for (NSDictionary *track in [disc[@"track"] isKindOfClass:NSArray.class] ? disc[@"track"] : @[]) {
                    if (![track isKindOfClass:NSDictionary.class]) continue;
                    [ids addObject:SGDistroSpotifyIDForGID(str(track[@"gid"])) ?: @""];
                }
            }
        } else {
            NSMutableSet *seen = [NSMutableSet set];
            for (NSDictionary *group in [json[@"top_track"] isKindOfClass:NSArray.class] ? json[@"top_track"] : @[]) {
                if (![group isKindOfClass:NSDictionary.class]) continue;
                for (NSDictionary *track in [group[@"track"] isKindOfClass:NSArray.class] ? group[@"track"] : @[]) {
                    if (![track isKindOfClass:NSDictionary.class]) continue;
                    NSString *sid = SGDistroSpotifyIDForGID(str(track[@"gid"]));
                    if (sid.length && ![seen containsObject:sid] && ids.count < 60) {
                        [seen addObject:sid];
                        [ids addObject:sid];
                    }
                }
            }
        }
        finishLoad(s, ids);
    });
}

#pragma mark - matching rows

static void finishWaiter(DFSource *s, DFRowWaiter *w, NSString *trackID) {
    [s.waiters removeObject:w];
    for (void (^callback)(NSString *) in w.callbacks) callback(trackID);
}

static void accept(DFSource *s, NSInteger position, NSInteger ordinal) {
    if (ordinal >= 0 && position >= 0) {
        s.shift = ordinal - position;
        s.shiftKnown = YES;
    }
    // The next rows, before they scroll in.
    ask(s, position + 1, position + kAhead, NO);
    ask(s, position - kBehind, position - 1, NO);
}

static void evaluate(DFSource *s) {
    if (!s.loaded) return;
    for (DFRowWaiter *w in [s.waiters copy]) {
        for (int guard = 0; guard < 4; guard++) {
            NSInteger position = -1;
            NSString *found = match(s, w, &position);
            if (found) {
                accept(s, position, w.ordinal);
                finishWaiter(s, w, found);
                break;
            }
            if (s.failed || w.stage > 2) {
                finishWaiter(s, w, nil);
                break;
            }
            NSRange window = windowFor(s, w);
            BOOL settled;
            if (s.webMode) settled = webSettled(s, window);
            else {
                settled = idsSettled(s, window);
                if (!settled) ask(s, (NSInteger)window.location, (NSInteger)NSMaxRange(window) - 1, YES);
            }
            if (!settled) break;
            w.stage++;
            // A small source was read whole at stage 0: nothing wider to look at.
            BOOL whole = !s.webMode && s.ids.count <= 60;
            if (w.stage > 2 || whole) {
                finishWaiter(s, w, nil);
                break;
            }
        }
    }
}

static void wake(DFSource *s) {
    if (!s || s.wakeQueued) return;
    s.wakeQueued = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        s.wakeQueued = NO;
        evaluate(s);
    });
}

#pragma mark - which source a row belongs to

// A track URI the row carries itself, when it does.
static NSString *directURI(UIView *cell) {
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:cell];
    NSUInteger visited = 0;
    while (queue.count && visited++ < 48) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        NSString *a = idFromURI(v.accessibilityIdentifier), *b = idFromURI(v.accessibilityValue);
        if (a || b) return a ?: b;
        for (NSString *selectorName in @[@"URI", @"uri", @"spotifyURI", @"trackURI"]) {
            SEL sel = NSSelectorFromString(selectorName);
            Method m = class_getInstanceMethod(v.class, sel);
            if (!m || method_getNumberOfArguments(m) != 2) continue;
            char type[8] = {0};
            method_getReturnType(m, type, sizeof(type));
            if (type[0] != '@') continue;
            @try {
                NSString *track = idFromURI(str(((id (*)(id, SEL))objc_msgSend)(v, sel)));
                if (track) return track;
            } @catch (__unused NSException *e) {}
        }
        [queue addObjectsFromArray:v.subviews];
    }
    return nil;
}

static NSString *pageURI(UIView *cell) {
    for (UIResponder *r = cell; r; r = r.nextResponder) {
        if (![r isKindOfClass:UIViewController.class] || ![r respondsToSelector:@selector(spt_pageURI)]) continue;
        @try {
            NSString *uri = str(((id (*)(id, SEL))objc_msgSend)(r, @selector(spt_pageURI)));
            if (uri.length) return uri;
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

static BOOL kindOfURI(NSString *uri, DFSourceKind *kind) {
    if ([uri hasPrefix:@"spotify:playlist:"] && uri.length == 39) { *kind = DFSourcePlaylist; return YES; }
    if ([uri hasPrefix:@"spotify:album:"] && uri.length == 36) { *kind = DFSourceAlbum; return YES; }
    if ([uri hasPrefix:@"spotify:artist:"] && uri.length == 37) { *kind = DFSourceArtist; return YES; }
    if ([uri isEqualToString:@"spotify:collection:tracks"] || [uri isEqualToString:@"spotify:collection"] ||
        ([uri hasPrefix:@"spotify:user:"] && [uri hasSuffix:@":collection"])) { *kind = DFSourceLiked; return YES; }
    return NO;
}

static BOOL isTrackRow(UIView *view) {
    NSString *identifier = view.accessibilityIdentifier ?: @"";
    return [identifier containsString:@"Track.Row"] || [identifier containsString:@"ItemCell"] ||
           [identifier containsString:@"RetrievalRow"];
}

// Some pages carry no URI (the artist's, per the redesign's ArtistFollow.x), but the page header's ⋯ is
// Components.UI.ContextMenuButton-<id of the page's entity>. Track rows are skipped on the way, so their
// own ⋯ is never taken for the page's.
static NSString *headerEntityID(UIView *root) {
    static NSString *const prefix = @"Components.UI.ContextMenuButton-";
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSUInteger visited = 0;
    while (queue.count && visited++ < 1500) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        NSString *identifier = v.accessibilityIdentifier;
        if ([identifier hasPrefix:prefix]) {
            NSString *entity = [identifier substringFromIndex:prefix.length];
            if (isBase62ID(entity)) return entity;
        }
        if (isTrackRow(v)) continue;
        [queue addObjectsFromArray:v.subviews];
    }
    return nil;
}

static UICollectionView *collectionOf(UIView *cell) {
    for (UIView *v = cell.superview; v; v = v.superview) {
        if ([v isKindOfClass:UICollectionView.class]) return (UICollectionView *)v;
    }
    return nil;
}

static NSString *sourceURI(UIView *cell, DFSourceKind *kind) {
    UICollectionView *list = collectionOf(cell);
    NSString *cached = list ? objc_getAssociatedObject(list, &kSourceURIKey) : nil;
    if (cached.length && kindOfURI(cached, kind)) return cached;
    NSNumber *gaveUp = list ? objc_getAssociatedObject(list, &kNoSourceKey) : nil;
    if (gaveUp && CFAbsoluteTimeGetCurrent() - gaveUp.doubleValue < kNoSourceRetry) return nil;

    NSString *uri = pageURI(cell);
    if (!kindOfURI(uri, kind)) {
        uri = nil;
        // The list can be a child of the page that holds the header (the artist's tabs), so the search
        // climbs a few controllers.
        NSString *entity = nil;
        NSUInteger controllers = 0;
        for (UIResponder *r = cell; r && !entity && controllers < 4; r = r.nextResponder) {
            if (![r isKindOfClass:UIViewController.class]) continue;
            controllers++;
            UIView *root = ((UIViewController *)r).viewIfLoaded;
            if (root) entity = headerEntityID(root);
        }
        if (entity) {
            BOOL artistPage = NO;
            for (UIView *v = cell; v; v = v.superview) {
                if ([v.accessibilityIdentifier isEqualToString:@"creator-page"]) { artistPage = YES; break; }
            }
            NSString *cellClass = NSStringFromClass(cell.class);
            if (artistPage) uri = [@"spotify:artist:" stringByAppendingString:entity];
            else if ([cellClass containsString:@"Playlist"]) uri = [@"spotify:playlist:" stringByAppendingString:entity];
            else if ([cellClass containsString:@"Element_List"]) uri = [@"spotify:album:" stringByAppendingString:entity];
        }
        if (!kindOfURI(uri, kind)) {
            if (list) objc_setAssociatedObject(list, &kNoSourceKey, @(CFAbsoluteTimeGetCurrent()), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return nil;
        }
    }
    if (list) objc_setAssociatedObject(list, &kSourceURIKey, uri, OBJC_ASSOCIATION_COPY_NONATOMIC);
    return uri;
}

// Where the cell is in its list, counting every item of the sections before it.
static NSInteger ordinalOf(UIView *cell) {
    UICollectionView *list = collectionOf(cell);
    if (![cell isKindOfClass:UICollectionViewCell.class] || !list) return -1;
    NSIndexPath *path = [list indexPathForCell:(UICollectionViewCell *)cell];
    if (!path) return -1;
    NSInteger ordinal = path.item;
    for (NSInteger section = 0; section < path.section; section++) ordinal += [list numberOfItemsInSection:section];
    return ordinal;
}

static DFSource *sourceFor(NSString *uri, DFSourceKind kind) {
    DFSource *s = df_sources[uri];
    if (s) {
        [df_sourceOrder removeObject:uri];
        [df_sourceOrder addObject:uri];
        return s;
    }
    s = [DFSource new];
    s.uri = uri;
    s.kind = kind;
    s.ids = [NSMutableArray array];
    s.titles = [NSMutableDictionary dictionary];
    s.artists = [NSMutableDictionary dictionary];
    s.byTitle = [NSMutableDictionary dictionary];
    s.asked = [NSMutableSet set];
    s.askedUrgent = [NSMutableSet set];
    s.webLoading = [NSMutableSet set];
    s.webDone = [NSMutableSet set];
    s.waiters = [NSMutableArray array];
    s.total = -1;
    df_sources[uri] = s;
    [df_sourceOrder addObject:uri];
    while (df_sourceOrder.count > kMaxSources) {
        NSString *oldest = df_sourceOrder.firstObject;
        DFSource *old = df_sources[oldest];
        for (DFRowWaiter *w in [old.waiters copy]) finishWaiter(old, w, nil);
        [df_sources removeObjectForKey:oldest];
        [df_sourceOrder removeObjectAtIndex:0];
    }
    return s;
}

void DFRowResolveTrack(NSString *title, NSString *artist, UIView *cell, void (^completion)(NSString *trackID)) {
    if (!NSThread.isMainThread || !completion || !cell || !title.length) return;
    NSString *sid = directURI(cell);
    if (sid) { completion(sid); return; }

    DFSourceKind kind = DFSourcePlaylist;
    NSString *uri = sourceURI(cell, &kind);
    if (!uri) { completion(nil); return; }
    DFSource *s = sourceFor(uri, kind);
    if (s.failed) { completion(nil); return; }

    DFRowWaiter *w = [DFRowWaiter new];
    w.title = norm(title);
    w.artist = artist ?: @"";
    w.ordinal = ordinalOf(cell);
    w.callbacks = [NSMutableArray arrayWithObject:[completion copy]];

    if (s.loaded) {
        NSInteger position = -1;
        NSString *found = match(s, w, &position);
        if (found) {
            accept(s, position, w.ordinal);
            completion(found);
            return;
        }
    }
    [s.waiters addObject:w];
    while (s.waiters.count > kMaxWaiters) finishWaiter(s, s.waiters.firstObject, nil);
    if (!s.loaded) loadSource(s);
    else wake(s);
}

__attribute__((constructor)) static void DFRowInit(void) {
    df_sources = [NSMutableDictionary dictionary];
    df_sourceOrder = [NSMutableArray array];
}
