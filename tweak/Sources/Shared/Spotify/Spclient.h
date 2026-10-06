// Shared authenticated access to Spotify's spclient endpoints.
//
// Spotify's own requests carry a short-lived authorization token plus client headers. The tweak
// sees those requests in the two URLSession delegate implementations Spotify uses; this helper
// remembers the latest usable set and lets shared features make their own requests without each
// feature hooking the delegates again.
#import <Foundation/Foundation.h>

typedef void (^SGSpclientDataObserver)(NSURLSession *session, NSURLSessionTask *task, NSData *data);
typedef void (^SGSpclientCompletionObserver)(NSURLSessionTask *task, NSError *error);

// Nil until Spotify has made an authenticated spclient request in this process.
NSDictionary<NSString *, NSString *> *SGSpclientHeaders(void);
NSString *SGSpclientAuthorization(void);

// A request carrying the latest captured Spotify headers, or nil until headers are available.
NSMutableURLRequest *SGSpclientRequest(NSURL *url);

// Runs on the main queue as soon as an authenticated header set exists. If Spotify has already
// made a request, the block runs immediately; otherwise it is kept once and released after capture.
void SGSpclientWhenReady(void (^block)(void));

// Receives the same response chunks/completions Spotify's delegates receive. Intended for the
// existing lyrics cache, which needs the raw body of Spotify's own color-lyrics requests.
void SGSpclientAddObserver(SGSpclientDataObserver dataObserver,
                           SGSpclientCompletionObserver completionObserver);
