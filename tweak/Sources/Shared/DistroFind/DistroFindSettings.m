#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Shared/Player/PlayerState.h"
#import "DistroFind.h"
#import "DistroFindServer.h"
#import "DistroFindSettings.h"

static NSString *sg_trackID;
static SGDistroMetadata *sg_metadata;
static NSString *sg_metadataStatus = @"Play a Spotify track";
static SGDistroAvailability *sg_availability;
static NSString *sg_availabilityStatus = @"Not checked";

static NSString *currentTrackID(void) {
    SPTPlayerTrack *track = SGPlayerState().track;
    NSString *uri = SGURIString(track.URI);
    NSString *prefix = @"spotify:track:";
    if (![uri hasPrefix:prefix] || uri.length <= prefix.length) return nil;
    NSString *trackID = [uri substringFromIndex:prefix.length];
    return trackID.length == 22 ? trackID : nil;
}

static void clearForTrack(NSString *trackID) {
    if ((sg_trackID == trackID) || [sg_trackID isEqualToString:trackID]) return;
    sg_trackID = [trackID copy];
    sg_metadata = nil;
    sg_availability = nil;
    sg_availabilityStatus = @"Not checked";
}

static void lookupCurrentTrack(void) {
    NSString *trackID = currentTrackID();
    clearForTrack(trackID);
    if (!trackID.length) {
        sg_metadataStatus = @"Play a Spotify track";
        return;
    }

    sg_metadataStatus = @"Loading…";
    SGDistroMetadataForTrack(trackID, ^(SGDistroMetadata *metadata, NSError *error) {
        if (![currentTrackID() isEqualToString:trackID]) return;
        if (error || !metadata) {
            sg_metadata = nil;
            sg_metadataStatus = error.localizedDescription ?: @"Metadata lookup failed";
            return;
        }
        sg_metadata = metadata;
        sg_metadataStatus = @"Loaded";
        SGLog(@"distrofind: %@ — %@ -> %@%@",
              metadata.artist ?: @"", metadata.title ?: @"", metadata.distributor ?: @"Unknown",
              metadata.likelyDistributor.length ? [NSString stringWithFormat:@" (likely %@)", metadata.likelyDistributor] : @"");
    });
}

static void checkAvailability(void) {
    NSString *trackID = currentTrackID();
    clearForTrack(trackID);
    if (!trackID.length) {
        sg_availabilityStatus = @"Play a Spotify track";
        return;
    }
    sg_availabilityStatus = @"Checking…";
    SGDistroAvailabilityForTrack(trackID, ^(SGDistroAvailability *result, NSError *error) {
        if (![currentTrackID() isEqualToString:trackID]) return;
        if (error || !result) {
            sg_availability = nil;
            sg_availabilityStatus = error.localizedDescription ?: @"Availability failed";
            return;
        }
        sg_availability = result;
        if ([result.kind isEqualToString:@"worldwide"]) sg_availabilityStatus = @"Worldwide";
        else if ([result.kind isEqualToString:@"gone"]) sg_availabilityStatus = @"Unavailable";
        else if ([result.kind isEqualToString:@"locked"]) {
            sg_availabilityStatus = [NSString stringWithFormat:@"%lu blocked", (unsigned long)result.blocked.count];
        } else {
            sg_availabilityStatus = result.kind.capitalizedString ?: @"Loaded";
        }
    });
}

static NSString *trackTitle(void) {
    SPTPlayerTrack *track = SGPlayerState().track;
    NSString *title = [track respondsToSelector:@selector(trackTitle)] ? track.trackTitle : nil;
    if (!title.length) title = sg_metadata.title;
    return title.length ? title : @"—";
}

static NSString *artistName(void) {
    SPTPlayerTrack *track = SGPlayerState().track;
    NSString *artist = [track respondsToSelector:@selector(artistName)] ? track.artistName : nil;
    if (!artist.length) artist = sg_metadata.artist;
    return artist.length ? artist : @"—";
}

static NSString *displayDistributor(void) {
    NSString *name = SGDistroDisplayName(sg_metadata);
    return name.length ? name : (sg_metadataStatus.length ? sg_metadataStatus : @"—");
}

UIViewController *SGDistroFindSettingsPage(void) {
    lookupCurrentTrack();

    SGModRow *trackID = SGStatRow(@"Spotify ID", ^NSString *{
        NSString *value = currentTrackID();
        return value.length ? value : @"—";
    });
    SGModRow *refresh = SGActionRow(@"Refresh metadata", @"Uses Spotify's signed-in metadata/4 session.", ^{
        lookupCurrentTrack();
    });

    SGModSection *track = SGNotedSection(@"Current track", @[
        SGStatRow(@"Track", ^NSString *{ return trackTitle(); }),
        SGStatRow(@"Artist", ^NSString *{ return artistName(); }),
        trackID,
        SGStatRow(@"Metadata", ^NSString *{ return sg_metadataStatus ?: @"—"; }),
        refresh,
    ], @"This page is the first DistroFind device test. If Metadata reaches Loaded, the Spotify authentication and metadata path are working.");

    SGModSection *distro = SGSection(@"Distributor", @[
        SGStatRow(@"Distributor", ^NSString *{ return displayDistributor(); }),
        SGStatRow(@"Parent", ^NSString *{ return sg_metadata.distributor ?: @"—"; }),
        SGStatRow(@"Likely sub-distributor", ^NSString *{ return sg_metadata.likelyDistributor ?: @"—"; }),
        SGStatRow(@"Label", ^NSString *{ return sg_metadata.label.length ? sg_metadata.label : @"—"; }),
        SGStatRow(@"Licensor UUID", ^NSString *{ return sg_metadata.licensorUUID.length ? sg_metadata.licensorUUID : @"—"; }),
        SGStatRow(@"ISRC", ^NSString *{ return sg_metadata.isrc.length ? sg_metadata.isrc : @"—"; }),
    ]);

    SGModSection *availability = SGNotedSection(@"Availability", @[
        SGStatRow(@"Status", ^NSString *{ return sg_availabilityStatus ?: @"—"; }),
        SGStatRow(@"Available markets", ^NSString *{
            return sg_availability ? [NSString stringWithFormat:@"%lu", (unsigned long)sg_availability.available.count] : @"—";
        }),
        SGStatRow(@"Blocked markets", ^NSString *{
            return sg_availability ? [NSString stringWithFormat:@"%lu", (unsigned long)sg_availability.blocked.count] : @"—";
        }),
        SGActionRow(@"Check availability", @"Uses DistroFind's direct availability endpoint.", ^{
            checkAvailability();
        }),
    ], @"Availability is deliberately separate from metadata so a server/API problem cannot hide whether Spotify distributor lookup works.");

    return [[SGModPage alloc] initWithTitle:@"DistroFind"
                                      intro:@"Native DistroFind test · play a track, then verify its distributor below."
                                   sections:@[track, distro, availability]
                                     footer:nil];
}
