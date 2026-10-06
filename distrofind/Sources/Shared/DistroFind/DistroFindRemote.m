#import "Core/SGCore.h"
#import "DistroFind.h"
#import "DistroFindRemote.h"
#import "Shared/Spotify/Spclient.h"

static NSError *DFRemoteError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"distrofind.spotify" code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Spotify request failed"}];
}

static void DFGetJSONAttempt(NSURL *url, NSUInteger attempt, DFJSONCompletion completion) {
    NSMutableURLRequest *request = SGSpclientRequest(url);
    if (!request) {
        SGSpclientWhenReady(^{
            DFGetJSONAttempt(url, attempt, completion);
        });
        return;
    }
    request.timeoutInterval = 20;

    [[NSURLSession.sharedSession dataTaskWithRequest:request
                                  completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (id)response : nil;
        NSInteger status = http.statusCode;
        if (!error && status == 429 && attempt < 3) {
            NSTimeInterval wait = [http.allHeaderFields[@"Retry-After"] doubleValue];
            if (wait <= 0) wait = (NSTimeInterval)(1u << attempt);
            wait = MIN(wait, 15);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                DFGetJSONAttempt(url, attempt + 1, completion);
            });
            return;
        }

        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
            return;
        }
        if (status < 200 || status >= 300) {
            NSError *e = DFRemoteError(status, [NSString stringWithFormat:@"Spotify returned %ld", (long)status]);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, e); });
            return;
        }

        NSError *jsonError = nil;
        id object = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError] : nil;
        NSDictionary *json = [object isKindOfClass:NSDictionary.class] ? object : nil;
        if (!json) {
            NSError *e = jsonError ?: DFRemoteError(2, @"Spotify response was not a JSON object");
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, e); });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(json, nil); });
    }] resume];
}

void DFSpotifyMetadataJSONForGID(NSString *kind, NSString *gid, DFJSONCompletion completion) {
    if (!completion) return;
    if (!kind.length || gid.length != 32) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, DFRemoteError(3, @"Invalid metadata request"));
        });
        return;
    }
    NSString *address = [NSString stringWithFormat:
        @"https://spclient.wg.spotify.com/metadata/4/%@/%@?market=from_token", kind, gid];
    DFGetJSONAttempt([NSURL URLWithString:address], 0, completion);
}

void DFSpotifyMetadataJSON(NSString *kind, NSString *spotifyID, DFJSONCompletion completion) {
    NSString *gid = SGDistroGIDForSpotifyID(spotifyID);
    if (!gid) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, DFRemoteError(3, @"Invalid Spotify id"));
        });
        return;
    }
    DFSpotifyMetadataJSONForGID(kind, gid, completion);
}

void DFSpotifyAccountMarket(void (^completion)(NSString *market)) {
    if (!completion) return;
    NSMutableURLRequest *request = SGSpclientRequest([NSURL URLWithString:@"https://api.spotify.com/v1/me"]);
    if (!request) {
        SGSpclientWhenReady(^{ DFSpotifyAccountMarket(completion); });
        return;
    }
    request.timeoutInterval = 12;
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:
      ^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *market = nil;
        if (!error && data.length) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            id country = [json isKindOfClass:NSDictionary.class] ? json[@"country"] : nil;
            if ([country isKindOfClass:NSString.class] && [country length] == 2) market = [country uppercaseString];
        }
        if (!market.length) {
            if (@available(iOS 16.0, *)) market = NSLocale.currentLocale.regionCode;
            else market = [NSLocale.currentLocale objectForKey:NSLocaleCountryCode];
        }
        market = market.uppercaseString ?: @"";
        dispatch_async(dispatch_get_main_queue(), ^{ completion(market); });
    }] resume];
}
