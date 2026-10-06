// DistroFind's shared metadata engine. UI layers ask for a Spotify track id and get the
// distributor/licensor information parsed from Spotify's metadata/4 endpoint.
#import <Foundation/Foundation.h>

#define SGKeyDistroFind @"spotifyglass.distrofind"

@interface SGDistroMetadata : NSObject
@property (nonatomic, copy) NSString *trackID;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) NSString *licensorUUID;
@property (nonatomic, copy) NSString *distributor;
@property (nonatomic, copy) NSString *likelyDistributor;
@property (nonatomic, copy) NSString *isrc;
@property (nonatomic, copy) NSString *albumID;
@property (nonatomic, copy) NSArray<NSString *> *allowedCountries;
@property (nonatomic, copy) NSArray<NSString *> *forbiddenCountries;
@end

typedef void (^SGDistroMetadataCompletion)(SGDistroMetadata *metadata, NSError *error);

// Cached, asynchronous lookup. Completion is always delivered on the main queue.
void SGDistroMetadataForTrack(NSString *trackID, SGDistroMetadataCompletion completion);

// A short label for badges: likely sub-distributor when known, otherwise parent distributor,
// otherwise "Unknown". Nil only when no licensor UUID was returned at all.
NSString *SGDistroDisplayName(SGDistroMetadata *metadata);

// Base62 Spotify id <-> 32-character metadata gid helpers.
NSString *SGDistroGIDForSpotifyID(NSString *spotifyID);
NSString *SGDistroSpotifyIDForGID(NSString *gid);
