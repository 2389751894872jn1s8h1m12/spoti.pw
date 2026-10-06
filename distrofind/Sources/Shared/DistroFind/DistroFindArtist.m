#import "Core/SGCore.h"
#import "DistroFind.h"
#import "DistroFindData.h"
#import "DistroFindRemote.h"
#import "DistroFindServer.h"
#import "DistroFindArtist.h"

@implementation DFArtistRelease
@end

static NSString *DFString(id value) {
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSArray *DFArray(id value) {
    return [value isKindOfClass:NSArray.class] ? value : @[];
}

static NSDictionary *DFDict(id value) {
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static NSArray<NSString *> *DFCountryCodes(NSArray *restrictions, NSString *key) {
    NSMutableOrderedSet<NSString *> *set = [NSMutableOrderedSet orderedSet];
    for (NSDictionary *restriction in restrictions) {
        NSString *packed = DFString(restriction[key]);
        for (NSUInteger i = 0; i + 1 < packed.length; i += 2) {
            [set addObject:[[packed substringWithRange:NSMakeRange(i, 2)] uppercaseString]];
        }
    }
    return [[set array] sortedArrayUsingSelector:@selector(compare:)];
}

static NSString *DFFirstTrackID(NSDictionary *album) {
    for (NSDictionary *disc in DFArray(album[@"disc"])) {
        for (NSDictionary *track in DFArray(disc[@"track"])) {
            NSString *gid = DFString(track[@"gid"]);
            NSString *sid = SGDistroSpotifyIDForGID(gid);
            if (sid.length) return sid;
        }
    }
    return nil;
}

static NSArray<NSDictionary *> *DFReleaseStubs(NSDictionary *artist) {
    NSMutableDictionary<NSString *, NSDictionary *> *byGID = [NSMutableDictionary dictionary];
    NSArray *groups = @[
        @[@"album_group", @"album"],
        @[@"single_group", @"single"],
        @[@"compilation_group", @"compilation"],
    ];
    for (NSArray *pair in groups) {
        NSString *key = pair[0], *type = pair[1];
        for (NSDictionary *group in DFArray(artist[key])) {
            for (NSDictionary *album in DFArray(group[@"album"])) {
                NSString *gid = DFString(album[@"gid"]);
                if (!gid.length || byGID[gid]) continue;
                byGID[gid] = @{
                    @"gid": gid,
                    @"name": DFString(album[@"name"]) ?: @"Untitled",
                    @"type": type,
                };
            }
        }
    }
    return byGID.allValues;
}

NSString *DFReleaseDisplayDistributor(DFArtistRelease *release) {
    if (release.likelyDistributor.length) return release.likelyDistributor;
    if (release.parentDistributor.length) return release.parentDistributor;
    return release.licensorUUID.length ? @"Unknown" : @"?";
}

BOOL DFReleaseUnavailableInMarket(DFArtistRelease *release, NSString *market) {
    if (market.length != 2) return NO;
    market = market.uppercaseString;
    if ([release.forbiddenCountries containsObject:market]) return YES;
    if (release.allowedCountries.count && ![release.allowedCountries containsObject:market]) return YES;
    return NO;
}

static void DFFillRelease(DFArtistRelease *release, NSDictionary *album,
                          void (^done)(void)) {
    release.name = DFString(album[@"name"]) ?: release.name ?: @"Untitled";
    release.type = [DFString(album[@"type"]) lowercaseString] ?: release.type ?: @"release";
    NSDictionary *date = DFDict(album[@"date"]);
    NSNumber *year = [date[@"year"] respondsToSelector:@selector(stringValue)] ? date[@"year"] : nil;
    if (year) release.year = year.stringValue;
    release.label = DFString(album[@"label"]) ?: @"";

    NSString *uuid = DFString(DFDict(album[@"licensor"])[@"uuid"]);
    release.licensorUUID = uuid;
    release.parentDistributor = SGDistroNameForUUID(uuid);

    NSArray *restrictions = DFArray(album[@"restriction"]);
    release.allowedCountries = DFCountryCodes(restrictions, @"countries_allowed");
    release.forbiddenCountries = DFCountryCodes(restrictions, @"countries_forbidden");
    release.firstTrackID = DFFirstTrackID(album);

    if (!release.firstTrackID.length) {
        done();
        return;
    }

    SGDistroMetadataForTrack(release.firstTrackID, ^(SGDistroMetadata *meta, NSError *error) {
        if (meta) {
            release.licensorUUID = meta.licensorUUID ?: release.licensorUUID;
            release.parentDistributor = meta.distributor ?: release.parentDistributor;
            release.likelyDistributor = meta.likelyDistributor;
            if (!release.label.length) release.label = meta.label ?: @"";
            if (!release.allowedCountries.count) release.allowedCountries = meta.allowedCountries ?: @[];
            if (!release.forbiddenCountries.count) release.forbiddenCountries = meta.forbiddenCountries ?: @[];

            if ([meta.licensorUUID.lowercaseString isEqualToString:@"9c290842b7fa4396bb0dcb3ad95634f5"]
                && !release.likelyDistributor.length) {
                SGDistroVydiaSubDistributor(release.releaseID, release.name, meta.artist, ^(NSString *sub) {
                    if (sub.length) release.likelyDistributor = sub;
                    done();
                });
                return;
            }
        }
        done();
    });
}

void DFScanArtist(NSString *artistID, DFArtistScanProgress progress, DFArtistScanCompletion completion) {
    if (!completion) return;
    if (artistID.length != 22) {
        completion(nil, [NSError errorWithDomain:@"distrofind.artist" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"Invalid Spotify artist id"}]);
        return;
    }

    DFSpotifyMetadataJSON(@"artist", artistID, ^(NSDictionary *artist, NSError *error) {
        if (error || !artist) {
            completion(nil, error);
            return;
        }

        NSArray<NSDictionary *> *stubs = DFReleaseStubs(artist);
        if (!stubs.count) {
            completion(@[], nil);
            return;
        }

        NSMutableArray<DFArtistRelease *> *results = [NSMutableArray arrayWithCapacity:stubs.count];
        for (NSDictionary *stub in stubs) {
            DFArtistRelease *release = [DFArtistRelease new];
            release.gid = stub[@"gid"];
            release.releaseID = SGDistroSpotifyIDForGID(release.gid);
            release.name = stub[@"name"];
            release.type = stub[@"type"];
            release.allowedCountries = @[];
            release.forbiddenCountries = @[];
            [results addObject:release];
        }

        dispatch_group_t group = dispatch_group_create();
        __block NSUInteger finished = 0;
        for (DFArtistRelease *release in results) {
            dispatch_group_enter(group);
            DFSpotifyMetadataJSONForGID(@"album", release.gid, ^(NSDictionary *album, NSError *albumError) {
                if (album) {
                    DFFillRelease(release, album, ^{
                        finished++;
                        if (progress) progress(finished, results.count);
                        dispatch_group_leave(group);
                    });
                } else {
                    finished++;
                    if (progress) progress(finished, results.count);
                    dispatch_group_leave(group);
                }
            });
        }

        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            [results sortUsingComparator:^NSComparisonResult(DFArtistRelease *a, DFArtistRelease *b) {
                NSComparisonResult byYear = [b.year ?: @"" compare:a.year ?: @"" options:NSNumericSearch];
                if (byYear != NSOrderedSame) return byYear;
                return [a.name compare:b.name options:NSCaseInsensitiveSearch];
            }];
            completion(results, nil);
        });
    });
}
