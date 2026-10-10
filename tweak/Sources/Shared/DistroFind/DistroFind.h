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
@property (nonatomic, copy) NSString *albumName;
@property (nonatomic, copy) NSString *upc;
@property (nonatomic, copy) NSString *releaseDate;
@property (nonatomic, copy) NSString *coverURL;
@property (nonatomic, copy) NSArray<NSString *> *copyrights;
@property (nonatomic, copy) NSString *pLine;
@property (nonatomic, copy) NSString *cLine;
@property (nonatomic, copy) NSArray<NSString *> *artistIDs;
@property (nonatomic) NSInteger durationMs;
@property (nonatomic) NSInteger trackNumber;
@property (nonatomic) NSInteger discNumber;
@property (nonatomic) NSTimeInterval earliestLiveTimestamp;
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


// Raw authenticated metadata helpers used by Artist Scan / Regioned Releases.
// kind is "track", "album" or "artist". Completion is delivered on the main queue.
void SGDistroRawMetadataForSpotifyID(NSString *kind, NSString *spotifyID,
                                     void (^completion)(NSDictionary *json, NSError *error));
void SGDistroRawMetadataForGID(NSString *kind, NSString *gid,
                               void (^completion)(NSDictionary *json, NSError *error));
