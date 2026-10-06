#import <Foundation/Foundation.h>

typedef void (^DFJSONCompletion)(NSDictionary *json, NSError *error);

// Authenticated metadata/4 requests through the exact Spotify session already maintained by
// spoti.pw 0.50.0. kind is track, album or artist and spotifyID is the normal 22-char id.
void DFSpotifyMetadataJSON(NSString *kind, NSString *spotifyID, DFJSONCompletion completion);

// Same endpoint when the caller already has Spotify's 32-char hexadecimal gid.
void DFSpotifyMetadataJSONForGID(NSString *kind, NSString *gid, DFJSONCompletion completion);

// The signed-in account market when Spotify's own token permits /v1/me; device locale is the fallback.
void DFSpotifyAccountMarket(void (^completion)(NSString *market));
