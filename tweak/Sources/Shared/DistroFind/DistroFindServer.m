#import "Core/SGCore.h"
#import "DistroFind.h"
#import "DistroFindServer.h"

static NSString *const kServer = @"https://ds-production-a43b.up.railway.app";
static NSString *const kTermAPI = @"https://term.christmas/api/spotify_availability";
static NSString *const kPublicServerKey = @"Carti123!";

@implementation SGDistroAvailability
@end

static NSCache<NSString *, SGDistroAvailability *> *sg_availabilityCache;
static NSCache<NSString *, NSString *> *sg_vydiaCache;

static NSString *serverKey(void) {
    return kPublicServerKey;
}

static NSArray<NSString *> *spotifyMarkets(void) {
    static NSArray<NSString *> *markets;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        markets = [@"AD AE AG AL AM AO AR AT AU AZ BA BB BD BE BF BG BH BI BJ BN BO BR BS BT BW BY BZ CA CD CG CH CI CL CM CO CR CV CW CY CZ DE DJ DK DM DO DZ EC EE EG ES ET FI FJ FM FR GA GB GD GE GH GM GN GQ GR GT GW GY HK HN HR HT HU ID IE IL IN IQ IS IT JM JO JP KE KG KH KI KM KN KR KW KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MG MH MK ML MN MO MR MT MU MV MW MX MY MZ NA NE NG NI NL NO NP NR NZ OM PA PE PG PH PK PL PS PT PW PY QA RO RS RW SA SB SC SE SG SI SK SL SM SN SR ST SV SZ TD TG TH TJ TL TN TO TR TT TV TW TZ UA UG US UY UZ VC VE VN VU WS XK ZA ZM ZW"
            componentsSeparatedByString:@" "];
    });
    return markets;
}

static void onMain(void (^block)(void)) {
    dispatch_async(dispatch_get_main_queue(), block);
}

static NSError *distroError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"spoti.pw.distrofind.server" code:code
        userInfo:@{NSLocalizedDescriptionKey: message ?: @"DistroFind request failed"}];
}

static NSError *statusError(NSInteger status, NSDictionary *json) {
    NSString *message = [json[@"error"] isKindOfClass:NSString.class] ? json[@"error"] :
        [NSString stringWithFormat:@"DistroFind server returned %ld", (long)status];
    return distroError(status, message);
}

static void requestJSON(NSURL *url, BOOL needsServerKey, NSTimeInterval timeout,
                        void (^done)(NSDictionary *, NSInteger, NSError *)) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = timeout;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    if (needsServerKey) {
        NSString *key = serverKey();
        if (!key.length) {
            done(@{}, 0, distroError(401, @"DistroFind server key is not configured"));
            return;
        }
        [request setValue:key forHTTPHeaderField:@"X-Key"];
    }
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSDictionary *json = nil;
        if (data.length) {
            id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([object isKindOfClass:NSDictionary.class]) json = object;
        }
        done(json ?: @{}, status, error);
    }] resume];
}

static SGDistroAvailability *availabilityFromJSON(NSDictionary *json) {
    NSArray *source = [json[@"available"] isKindOfClass:NSArray.class] ? json[@"available"] :
                      ([json[@"markets"] isKindOfClass:NSArray.class] ? json[@"markets"] : nil);
    if (!source) return nil;
    NSMutableOrderedSet<NSString *> *set = [NSMutableOrderedSet orderedSet];
    for (id value in source) {
        if ([value isKindOfClass:NSString.class] && [value length] == 2) [set addObject:[value uppercaseString]];
    }
    NSArray *available = [[set array] sortedArrayUsingSelector:@selector(compare:)];

    NSMutableArray *blocked = [NSMutableArray array];
    for (NSString *market in spotifyMarkets()) if (![set containsObject:market]) [blocked addObject:market];

    SGDistroAvailability *result = [SGDistroAvailability new];
    NSString *kind = [json[@"kind"] isKindOfClass:NSString.class] ? json[@"kind"] : nil;
    if (!kind.length) kind = !available.count ? @"gone" : blocked.count <= 1 ? @"worldwide" : @"locked";
    result.kind = kind;
    result.available = available;
    result.blocked = blocked;
    result.cached = [json[@"cached"] boolValue];
    result.seconds = [json[@"secs"] doubleValue];
    return result;
}

void SGDistroAvailabilityForTrack(NSString *trackID, SGDistroAvailabilityCompletion completion) {
    if (!completion || trackID.length != 22) return;
    SGDistroAvailability *cached = [sg_availabilityCache objectForKey:trackID];
    if (cached) { onMain(^{ completion(cached, nil); }); return; }

    NSString *spotify = [NSString stringWithFormat:@"https://open.spotify.com/track/%@", trackID];
    NSString *escaped = [spotify stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    NSURL *term = [NSURL URLWithString:[NSString stringWithFormat:@"%@?url=%@", kTermAPI, escaped]];
    CFAbsoluteTime began = CFAbsoluteTimeGetCurrent();
    requestJSON(term, NO, 15, ^(NSDictionary *json, NSInteger status, NSError *error) {
        SGDistroAvailability *direct = !error && status >= 200 && status < 300 ? availabilityFromJSON(json) : nil;
        if (direct) {
            direct.seconds = CFAbsoluteTimeGetCurrent() - began;
            [sg_availabilityCache setObject:direct forKey:trackID];
            onMain(^{ completion(direct, nil); });
            return;
        }

        // Keep the desktop extension's Railway fallback with the public extension key.
        if (!serverKey().length) {
            NSError *finalError = error ?: distroError(status ?: 2, @"Could not read track availability");
            onMain(^{ completion(nil, finalError); });
            return;
        }
        NSURL *backup = [NSURL URLWithString:[NSString stringWithFormat:@"%@/regions/%@", kServer, trackID]];
        requestJSON(backup, YES, 150, ^(NSDictionary *fallback, NSInteger backupStatus, NSError *backupError) {
            if (backupError) { onMain(^{ completion(nil, backupError); }); return; }
            if (backupStatus < 200 || backupStatus >= 300) {
                NSError *e = statusError(backupStatus, fallback);
                onMain(^{ completion(nil, e); });
                return;
            }
            SGDistroAvailability *result = availabilityFromJSON(fallback);
            if (!result) {
                NSError *e = distroError(2, @"Availability response had no markets");
                onMain(^{ completion(nil, e); });
                return;
            }
            [sg_availabilityCache setObject:result forKey:trackID];
            onMain(^{ completion(result, nil); });
        });
    });
}

void SGDistroPerformanceDataForTrack(NSString *trackID,
                                     void (^completion)(NSDictionary *, NSError *)) {
    if (!completion || trackID.length != 22) return;
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/performance-data/%@", kServer, trackID]];
    requestJSON(url, YES, 60, ^(NSDictionary *json, NSInteger status, NSError *error) {
        if (!error && status != 200 && status != 202) error = statusError(status, json);
        onMain(^{ completion(error ? nil : json, error); });
    });
}

void SGDistroPerformanceImageForTrack(NSString *trackID, void (^completion)(UIImage *, NSString *, NSError *)) {
    if (!completion || trackID.length != 22) return;
    NSString *key = serverKey();
    if (!key.length) {
        onMain(^{ completion(nil, nil, distroError(401, @"DistroFind server key is not configured")); });
        return;
    }
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/performance/%@.png", kServer, trackID]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 60;
    [request setValue:key forHTTPHeaderField:@"X-Key"];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSString *type = [response isKindOfClass:NSHTTPURLResponse.class] ? [((NSHTTPURLResponse *)response) valueForHTTPHeaderField:@"Content-Type"] : nil;
        UIImage *image = !error && status >= 200 && status < 300 && [type hasPrefix:@"image/"] ? [UIImage imageWithData:data] : nil;
        NSString *message = nil;
        if (!image && data.length) {
            id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([object isKindOfClass:NSDictionary.class] && [object[@"message"] isKindOfClass:NSString.class]) message = object[@"message"];
        }
        NSError *finalError = error;
        if (!image && status != 202 && !finalError) finalError = statusError(status, @{});
        onMain(^{ completion(image, message, finalError); });
    }] resume];
}

void SGDistroOtherVersionsForTrack(NSString *trackID, void (^completion)(NSDictionary *, NSError *)) {
    if (!completion || trackID.length != 22) return;
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/links/%@", kServer, trackID]];
    requestJSON(url, YES, 45, ^(NSDictionary *json, NSInteger status, NSError *error) {
        if (!error && (status < 200 || status >= 300)) error = statusError(status, json);
        onMain(^{ completion(error ? nil : json, error); });
    });
}

void SGDistroVydiaSubDistributor(NSString *albumID, NSString *albumName, NSString *artistName,
                                 void (^completion)(NSString *)) {
    if (!completion || !albumID.length) return;
    NSString *cached = [sg_vydiaCache objectForKey:albumID];
    if (cached) { onMain(^{ completion(cached); }); return; }

    NSURLComponents *parts = [NSURLComponents componentsWithString:
        [NSString stringWithFormat:@"%@/vydia/%@", kServer, albumID]];
    parts.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"name" value:albumName ?: @""],
        [NSURLQueryItem queryItemWithName:@"artist" value:artistName ?: @""],
    ];
    requestJSON(parts.URL, YES, 30, ^(NSDictionary *json, NSInteger status, NSError *error) {
        NSString *sub = !error && status >= 200 && status < 300 && [json[@"sub"] isKindOfClass:NSString.class] ? json[@"sub"] : nil;
        if (sub.length) [sg_vydiaCache setObject:sub forKey:albumID];
        onMain(^{ completion(sub); });
    });
}

__attribute__((constructor))
static void SGDistroServerInit(void) {
    sg_availabilityCache = [NSCache new];
    sg_availabilityCache.countLimit = 3000;
    sg_vydiaCache = [NSCache new];
    sg_vydiaCache.countLimit = 500;
}
