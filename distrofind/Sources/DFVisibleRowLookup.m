// Resolve visible Spotify track rows without touching the playback getter or
// reflecting over Swift object ivars. Cache searches and rate limit requests.
#import <Foundation/Foundation.h>
#import "Shared/Spotify/Spclient.h"

typedef void (^DFRowCompletion)(NSString *trackID);

static NSMutableDictionary<NSString *, NSMutableArray<DFRowCompletion> *> *dfRowWaiting;
static NSMutableDictionary<NSString *, id> *dfRowCache;
static NSMutableArray<NSString *> *dfRowQueue;
static NSSet *dfRowFailures;
static NSInteger dfRowInFlight;

static NSString *dfRowClean(NSString *s) {
    if (![s isKindOfClass:NSString.class]) return @"";
    return [[s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
}
static NSString *dfRowKey(NSString *title, NSString *artist) {
    return [NSString stringWithFormat:@"%@\n%@", dfRowClean(title), dfRowClean(artist)];
}
static BOOL dfRowArtistMatches(NSString *wanted, NSArray *artists) {
    NSString *needle = dfRowClean(wanted);
    if (!needle.length) return YES;
    for (NSDictionary *a in artists) {
        NSString *name = dfRowClean(a[@"name"]);
        if (name.length && ([needle isEqualToString:name] || [needle containsString:name] || [name containsString:needle]))
            return YES;
    }
    return NO;
}
static void dfRowPump(void);
static void dfRowFinish(NSString *key, NSString *trackID) {
    dispatch_async(dispatch_get_main_queue(), ^{
        dfRowCache[key] = trackID ?: NSNull.null;
        NSArray *callbacks = [dfRowWaiting[key] copy];
        [dfRowWaiting removeObjectForKey:key];
        dfRowInFlight = MAX(0, dfRowInFlight - 1);
        for (DFRowCompletion callback in callbacks) callback(trackID);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 180 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{ dfRowPump(); });
    });
}
static void dfRowQuery(NSString *key) {
    NSArray *parts = [key componentsSeparatedByString:@"\n"];
    NSString *title = parts.firstObject ?: @"";
    NSString *artist = parts.count > 1 ? parts[1] : @"";
    NSURLComponents *url = [NSURLComponents componentsWithString:@"https://api.spotify.com/v1/search"];
    NSString *query = artist.length
        ? [NSString stringWithFormat:@"track:%@ artist:%@", title, artist]
        : [NSString stringWithFormat:@"track:%@", title];
    url.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"q" value:query],
        [NSURLQueryItem queryItemWithName:@"type" value:@"track"],
        [NSURLQueryItem queryItemWithName:@"limit" value:@"8"]
    ];
    NSMutableURLRequest *request = SGSpclientRequest(url.URL);
    if (!request) {
        // Auth is captured after Spotify signs in, without ever logging credentials.
        SGSpclientWhenReady(^{ dispatch_async(dispatch_get_main_queue(), ^{ dfRowQuery(key); }); });
        return;
    }
    request.timeoutInterval = 12;
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *found = nil;
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
            ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (!error && status == 200 && data.length) {
            NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSArray *items = [payload[@"tracks"][@"items"] isKindOfClass:NSArray.class] ? payload[@"tracks"][@"items"] : @[];
            NSMutableSet<NSString *> *matches = [NSMutableSet set];
            for (NSDictionary *track in items) {
                NSString *candidate = track[@"id"];
                if (![candidate isKindOfClass:NSString.class] || candidate.length != 22) continue;
                if (![dfRowClean(track[@"name"]) isEqualToString:title]) continue;
                if (!dfRowArtistMatches(artist, track[@"artists"])) continue;
                [matches addObject:candidate];
            }
            // A duplicate title with multiple Spotify IDs is ambiguous. Don't
            // silently badge the wrong master/release/version.
            if (matches.count == 1) found = matches.anyObject;
        }
        dfRowFinish(key, found);
    }] resume];
}
static void dfRowPump(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ dfRowPump(); }); return; }
    while (dfRowInFlight < 2 && dfRowQueue.count) {
        NSString *key = dfRowQueue.firstObject;
        [dfRowQueue removeObjectAtIndex:0];
        dfRowInFlight++;
        dfRowQuery(key);
    }
}

// Called only for cells close to the collection view's visible rectangle.
// Completion is always on the main thread. A nil ID leaves the row unbadged.
void DFRowResolveTrack(NSString *title, NSString *artist, DFRowCompletion completion) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ DFRowResolveTrack(title, artist, completion); });
        return;
    }
    if (!title.length || !completion) return;
    NSString *key = dfRowKey(title, artist);
    id cached = dfRowCache[key];
    if (cached) { completion(cached == NSNull.null ? nil : cached); return; }
    NSMutableArray *pending = dfRowWaiting[key];
    if (pending) { [pending addObject:[completion copy]]; return; }
    if (dfRowQueue.count > 60) { completion(nil); return; }
    dfRowWaiting[key] = [NSMutableArray arrayWithObject:[completion copy]];
    [dfRowQueue addObject:key];
    dfRowPump();
}

__attribute__((constructor))
static void DFRowInit(void) {
    dfRowWaiting = [NSMutableDictionary dictionary];
    dfRowCache = [NSMutableDictionary dictionary];
    dfRowQueue = [NSMutableArray array];
}
