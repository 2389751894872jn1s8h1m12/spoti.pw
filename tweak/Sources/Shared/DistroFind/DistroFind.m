#import "Core/SGCore.h"
#import "DistroFind.h"
#import "DistroFindData.h"
#import "Shared/Spotify/Spclient.h"
#include <string.h>

@implementation SGDistroMetadata
@end

static NSCache<NSString *, SGDistroMetadata *> *sg_cache;
static NSMutableDictionary<NSString *, NSMutableArray *> *sg_waiting;
static NSOperationQueue *sg_queue;

static const char kBase62[] = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";

static NSInteger digit62(unichar c) {
    const char *p = strchr(kBase62, (char)c);
    return p ? (NSInteger)(p - kBase62) : -1;
}

NSString *SGDistroGIDForSpotifyID(NSString *spotifyID) {
    if (spotifyID.length != 22) return nil;
    unsigned __int128 value = 0;
    for (NSUInteger i = 0; i < spotifyID.length; i++) {
        NSInteger digit = digit62([spotifyID characterAtIndex:i]);
        if (digit < 0) return nil;
        value = value * 62 + (unsigned)digit;
    }
    unsigned long long hi = (unsigned long long)(value >> 64);
    unsigned long long lo = (unsigned long long)value;
    return [NSString stringWithFormat:@"%016llx%016llx", hi, lo];
}

NSString *SGDistroSpotifyIDForGID(NSString *gid) {
    if (gid.length != 32) return nil;
    NSString *hiText = [gid substringToIndex:16], *loText = [gid substringFromIndex:16];
    unsigned long long hi = 0, lo = 0;
    NSScanner *a = [NSScanner scannerWithString:hiText], *b = [NSScanner scannerWithString:loText];
    if (![a scanHexLongLong:&hi] || ![b scanHexLongLong:&lo]) return nil;
    unsigned __int128 value = ((unsigned __int128)hi << 64) | lo;
    char out[23] = {0};
    for (NSInteger i = 21; i >= 0; i--) {
        out[i] = kBase62[(NSUInteger)(value % 62)];
        value /= 62;
    }
    if (value) return nil;
    return [[NSString alloc] initWithBytes:out length:22 encoding:NSASCIIStringEncoding];
}

static NSString *string(id value) {
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSArray *array(id value) {
    return [value isKindOfClass:NSArray.class] ? value : @[];
}

static NSDictionary *dict(id value) {
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static NSArray<NSString *> *countryCodes(NSArray *restrictions, NSString *key) {
    NSMutableOrderedSet<NSString *> *set = [NSMutableOrderedSet orderedSet];
    for (NSDictionary *restriction in restrictions) {
        NSString *packed = string(restriction[key]);
        for (NSUInteger i = 0; i + 1 < packed.length; i += 2) {
            [set addObject:[[packed substringWithRange:NSMakeRange(i, 2)] uppercaseString]];
        }
    }
    return [[set array] sortedArrayUsingSelector:@selector(compare:)];
}

static BOOL textMatches(NSDictionary *rule, NSString *text) {
    if (!text.length) return NO;
    NSString *needle = string(rule[@"match"]);
    if (!needle.length) return NO;
    if ([rule[@"caseSensitive"] boolValue]) return [text containsString:needle];
    NSString *left = text.lowercaseString, *right = needle.lowercaseString;
    if ([rule[@"exact"] boolValue]) return [left isEqualToString:right];
    if ([rule[@"prefix"] boolValue]) return [left hasPrefix:right];
    return [left containsString:right];
}

static NSArray<NSString *> *artistIDs(NSDictionary *track, NSDictionary *album) {
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    for (NSDictionary *source in @[track ?: @{}, album ?: @{}]) {
        for (NSDictionary *artist in array(source[@"artist"])) {
            NSString *gid = string(artist[@"gid"]);
            NSString *sid = SGDistroSpotifyIDForGID(gid);
            if (sid.length) [ids addObject:sid];
        }
    }
    return ids;
}

static NSString *externalID(NSDictionary *object, NSString *kind) {
    for (NSDictionary *external in array(object[@"external_id"])) {
        if ([string(external[@"type"]).lowercaseString isEqualToString:kind.lowercaseString]) {
            return string(external[@"id"]);
        }
    }
    return nil;
}

static NSString *ISRC(NSDictionary *track) {
    return externalID(track, @"isrc").uppercaseString;
}

static NSString *dateText(NSDictionary *object) {
    NSDictionary *date = dict(object[@"date"]);
    NSInteger year = [date[@"year"] integerValue];
    if (!year) return nil;
    NSInteger month = [date[@"month"] integerValue], day = [date[@"day"] integerValue];
    if (month && day) return [NSString stringWithFormat:@"%04ld-%02ld-%02ld", (long)year, (long)month, (long)day];
    if (month) return [NSString stringWithFormat:@"%04ld-%02ld", (long)year, (long)month];
    return [NSString stringWithFormat:@"%04ld", (long)year];
}

static NSString *coverURL(NSDictionary *album) {
    NSArray *images = array(dict(album[@"cover_group"])[@"image"]);
    NSDictionary *best = nil;
    for (NSDictionary *image in images) {
        if (!best || [image[@"width"] integerValue] > [best[@"width"] integerValue]) best = image;
    }
    NSString *fileID = string(best[@"file_id"]);
    return fileID.length ? [@"https://i.scdn.co/image/" stringByAppendingString:fileID] : nil;
}

static NSDictionary *matchingRule(NSString *uuid, NSArray<NSString *> *labels,
                                  NSArray<NSString *> *copyrights,
                                  NSArray<NSString *> *artists, NSString *isrc) {
    for (NSDictionary *rule in SGDistroLikelyRulesForUUID(uuid)) {
        NSString *prefix = string(rule[@"isrcPrefix"]);
        if (prefix.length) {
            if ([isrc hasPrefix:prefix.uppercaseString]) return rule;
            continue;
        }
        NSArray *wantedArtists = array(rule[@"artists"]);
        if (wantedArtists.count) {
            for (NSString *artist in wantedArtists) if ([artists containsObject:artist]) return rule;
            continue;
        }
        for (NSString *label in labels) if (textMatches(rule, label)) return rule;
        if ([rule[@"inCopyright"] boolValue]) {
            for (NSString *copyright in copyrights) if (textMatches(rule, copyright)) return rule;
        }
    }
    return nil;
}

static NSURL *metadataURL(NSString *kind, NSString *gid) {
    return [NSURL URLWithString:[NSString stringWithFormat:
        @"https://spclient.wg.spotify.com/metadata/4/%@/%@?market=from_token", kind, gid]];
}

static void fetchJSON(NSURL *url, void (^done)(NSDictionary *, NSError *)) {
    NSMutableURLRequest *request = SGSpclientRequest(url);
    if (!request) {
        NSError *error = [NSError errorWithDomain:@"spoti.pw.distrofind" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"Spotify authentication is not ready"}];
        done(nil, error);
        return;
    }
    request.timeoutInterval = 15;
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (!error && (status < 200 || status >= 300)) {
            error = [NSError errorWithDomain:@"spoti.pw.distrofind" code:status
                userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Spotify metadata returned %ld", (long)status]}];
        }
        NSDictionary *json = nil;
        if (!error && data.length) {
            id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
            json = dict(object);
            if (!json && !error) error = [NSError errorWithDomain:@"spoti.pw.distrofind" code:2
                userInfo:@{NSLocalizedDescriptionKey: @"Spotify metadata was not a JSON object"}];
        }
        done(json, error);
    }] resume];
}

static void finish(NSString *trackID, SGDistroMetadata *metadata, NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray *callbacks = [sg_waiting[trackID] copy];
        [sg_waiting removeObjectForKey:trackID];
        if (metadata) [sg_cache setObject:metadata forKey:trackID];
        for (SGDistroMetadataCompletion callback in callbacks) callback(metadata, error);
    });
}

static void parseAndFinish(NSString *trackID, NSDictionary *track) {
    NSDictionary *album = dict(track[@"album"]);
    NSString *uuid = string(album[@"licensor"][@"uuid"]) ?: string(track[@"licensor"][@"uuid"]);
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    NSString *label = string(album[@"label"]);
    if (label.length) [labels addObject:label];

    NSMutableArray<NSString *> *copyrights = [NSMutableArray array];
    for (NSDictionary *entry in array(album[@"copyright"])) {
        NSString *text = string(entry[@"text"]);
        if (text.length) [copyrights addObject:text];
    }
    NSArray<NSString *> *artists = artistIDs(track, album);
    NSString *isrc = ISRC(track);
    NSDictionary *rule = matchingRule(uuid, labels, copyrights, artists, isrc);

    void (^build)(NSDictionary *) = ^(NSDictionary *fullAlbum) {
        NSMutableArray *finalLabels = [labels mutableCopy];
        NSMutableArray *finalCopyrights = [copyrights mutableCopy];
        NSString *fullLabel = string(fullAlbum[@"label"]);
        if (fullLabel.length && ![finalLabels containsObject:fullLabel]) [finalLabels addObject:fullLabel];
        for (NSDictionary *entry in array(fullAlbum[@"copyright"])) {
            NSString *text = string(entry[@"text"]);
            if (text.length && ![finalCopyrights containsObject:text]) [finalCopyrights addObject:text];
        }
        NSDictionary *finalRule = rule ?: matchingRule(uuid, finalLabels, finalCopyrights, artists, isrc);

        SGDistroMetadata *meta = [SGDistroMetadata new];
        meta.trackID = trackID;
        meta.title = string(track[@"name"]) ?: @"";
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (NSDictionary *artist in array(track[@"artist"])) {
            NSString *name = string(artist[@"name"]);
            if (name.length) [names addObject:name];
        }
        meta.artist = [names componentsJoinedByString:@", "];
        NSDictionary *albumInfo = fullAlbum.count ? fullAlbum : album;
        meta.albumName = string(albumInfo[@"name"]) ?: string(album[@"name"]) ?: @"";
        meta.label = fullLabel ?: label ?: @"";
        meta.upc = externalID(albumInfo, @"upc") ?: externalID(album, @"upc") ?: @"";
        meta.releaseDate = dateText(albumInfo) ?: dateText(album) ?: @"";
        meta.coverURL = coverURL(albumInfo) ?: coverURL(album) ?: @"";
        meta.copyrights = [finalCopyrights copy];
        meta.artistIDs = [[NSOrderedSet orderedSetWithArray:artists] array];
        meta.durationMs = [track[@"duration"] integerValue];
        meta.trackNumber = [track[@"number"] integerValue];
        meta.discNumber = [track[@"disc_number"] integerValue];
        meta.earliestLiveTimestamp = [track[@"earliest_live_timestamp"] doubleValue] ?: [albumInfo[@"earliest_live_timestamp"] doubleValue];
        meta.licensorUUID = uuid;
        meta.distributor = SGDistroNameForUUID(uuid);
        meta.likelyDistributor = string(finalRule[@"name"]);
        meta.isrc = isrc;
        NSString *albumGID = string(album[@"gid"]);
        meta.albumID = SGDistroSpotifyIDForGID(albumGID);
        NSArray *restrictions = [array(track[@"restriction"]) arrayByAddingObjectsFromArray:array(album[@"restriction"])];
        meta.allowedCountries = countryCodes(restrictions, @"countries_allowed");
        meta.forbiddenCountries = countryCodes(restrictions, @"countries_forbidden");
        finish(trackID, meta, nil);
    };

    NSArray *rules = SGDistroLikelyRulesForUUID(uuid);
    BOOL needsCopyright = NO;
    for (NSDictionary *candidate in rules) if ([candidate[@"inCopyright"] boolValue]) { needsCopyright = YES; break; }
    NSString *albumGID = string(album[@"gid"]);
    if (!rule && albumGID.length && (!label.length || (needsCopyright && !copyrights.count))) {
        fetchJSON(metadataURL(@"album", albumGID), ^(NSDictionary *fullAlbum, NSError *error) {
            build(fullAlbum ?: @{});
        });
    } else {
        build(@{});
    }
}

static void startLookup(NSString *trackID) {
    NSString *gid = SGDistroGIDForSpotifyID(trackID);
    if (!gid) {
        finish(trackID, nil, [NSError errorWithDomain:@"spoti.pw.distrofind" code:3
            userInfo:@{NSLocalizedDescriptionKey: @"Invalid Spotify track id"}]);
        return;
    }
    fetchJSON(metadataURL(@"track", gid), ^(NSDictionary *track, NSError *error) {
        if (error || !track) { finish(trackID, nil, error); return; }
        parseAndFinish(trackID, track);
    });
}

void SGDistroMetadataForTrack(NSString *trackID, SGDistroMetadataCompletion completion) {
    if (!completion) return;
    if (trackID.length != 22) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, [NSError errorWithDomain:@"spoti.pw.distrofind" code:3
                userInfo:@{NSLocalizedDescriptionKey: @"Invalid Spotify track id"}]);
        });
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        SGDistroMetadata *cached = [sg_cache objectForKey:trackID];
        if (cached) { completion(cached, nil); return; }

        NSMutableArray *callbacks = sg_waiting[trackID];
        if (callbacks) { [callbacks addObject:[completion copy]]; return; }
        sg_waiting[trackID] = [NSMutableArray arrayWithObject:[completion copy]];

        void (^go)(void) = ^{
            [sg_queue addOperationWithBlock:^{ startLookup(trackID); }];
        };
        if (SGSpclientHeaders()[@"authorization"]) go();
        else SGSpclientWhenReady(go);
    });
}

NSString *SGDistroDisplayName(SGDistroMetadata *metadata) {
    if (!metadata.licensorUUID.length) return nil;
    return metadata.likelyDistributor.length ? metadata.likelyDistributor
        : (metadata.distributor.length ? metadata.distributor : @"Unknown");
}

void SGDistroRawMetadataForGID(NSString *kind, NSString *gid,
                               void (^completion)(NSDictionary *json, NSError *error)) {
    if (!completion || !kind.length || gid.length != 32) return;
    void (^go)(void) = ^{
        fetchJSON(metadataURL(kind, gid), ^(NSDictionary *json, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(json, error); });
        });
    };
    if (SGSpclientHeaders()[@"authorization"]) go();
    else SGSpclientWhenReady(go);
}

void SGDistroRawMetadataForSpotifyID(NSString *kind, NSString *spotifyID,
                                     void (^completion)(NSDictionary *json, NSError *error)) {
    NSString *gid = SGDistroGIDForSpotifyID(spotifyID);
    if (!gid) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, [NSError errorWithDomain:@"spoti.pw.distrofind" code:3
                userInfo:@{NSLocalizedDescriptionKey: @"Invalid Spotify id"}]);
        });
        return;
    }
    SGDistroRawMetadataForGID(kind, gid, completion);
}


__attribute__((constructor))
static void SGDistroInit(void) {
    sg_cache = [NSCache new];
    sg_cache.countLimit = 500;
    sg_waiting = [NSMutableDictionary dictionary];
    sg_queue = [NSOperationQueue new];
    sg_queue.maxConcurrentOperationCount = 5;
    sg_queue.qualityOfService = NSQualityOfServiceUtility;
}
