// One hook for Spotify's authenticated spclient traffic. Features consume the captured headers
// through Spclient.h rather than stacking hooks on Spotify's URLSession delegates.
#import "Core/SGCore.h"
#import "Spclient.h"

static NSString *const kHeaders[] = {
    @"authorization", @"client-token", @"app-platform",
    @"spotify-app-version", @"user-agent", @"accept-language",
};

static NSObject *sg_lock;
static NSDictionary<NSString *, NSString *> *sg_headers;
static NSMutableArray<SGSpclientDataObserver> *sg_dataObservers;
static NSMutableArray<SGSpclientCompletionObserver> *sg_completionObservers;
static NSMutableArray *sg_readyBlocks;

static void rememberHeaders(NSURLSession *session, NSURLRequest *request) {
    if (![request.URL.host.lowercaseString containsString:@"spclient"]) return;

    NSMutableDictionary<NSString *, NSString *> *all = [NSMutableDictionary dictionary];
    NSDictionary *additional = session.configuration.HTTPAdditionalHeaders;
    [additional enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        if ([key isKindOfClass:NSString.class] && [value isKindOfClass:NSString.class]) {
            all[((NSString *)key).lowercaseString] = value;
        }
    }];
    [request.allHTTPHeaderFields enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        if ([key isKindOfClass:NSString.class] && [value isKindOfClass:NSString.class]) {
            all[key.lowercaseString] = value;
        }
    }];
    if (!all[@"authorization"]) return;

    NSMutableDictionary<NSString *, NSString *> *captured = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < sizeof(kHeaders) / sizeof(*kHeaders); i++) {
        NSString *name = kHeaders[i];
        if (all[name]) captured[name] = all[name];
    }

    NSArray *ready = nil;
    @synchronized (sg_lock) {
        if ([sg_headers isEqualToDictionary:captured]) return;
        BOOL first = !sg_headers;
        sg_headers = [captured copy];
        if (first && sg_readyBlocks.count) {
            ready = [sg_readyBlocks copy];
            [sg_readyBlocks removeAllObjects];
        }
    }
    if (ready.count) dispatch_async(dispatch_get_main_queue(), ^{
        for (void (^block)(void) in ready) block();
    });
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"spclient: captured authenticated Spotify headers"); });
}

NSDictionary<NSString *, NSString *> *SGSpclientHeaders(void) {
    @synchronized (sg_lock) { return [sg_headers copy]; }
}

NSString *SGSpclientAuthorization(void) {
    @synchronized (sg_lock) { return sg_headers[@"authorization"]; }
}

NSMutableURLRequest *SGSpclientRequest(NSURL *url) {
    if (!url) return nil;
    NSDictionary<NSString *, NSString *> *headers = SGSpclientHeaders();
    if (!headers[@"authorization"]) return nil;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *value, BOOL *stop) {
        [request setValue:value forHTTPHeaderField:name];
    }];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    return request;
}

void SGSpclientWhenReady(void (^block)(void)) {
    if (!block) return;
    BOOL ready;
    @synchronized (sg_lock) {
        ready = sg_headers[@"authorization"] != nil;
        if (!ready) [sg_readyBlocks addObject:[block copy]];
    }
    if (ready) dispatch_async(dispatch_get_main_queue(), block);
}

void SGSpclientAddObserver(SGSpclientDataObserver dataObserver,
                           SGSpclientCompletionObserver completionObserver) {
    @synchronized (sg_lock) {
        if (dataObserver) [sg_dataObservers addObject:[dataObserver copy]];
        if (completionObserver) [sg_completionObservers addObject:[completionObserver copy]];
    }
}

static void received(NSURLSession *session, NSURLSessionTask *task, NSData *data) {
    rememberHeaders(session, task.currentRequest);
    NSArray<SGSpclientDataObserver> *observers;
    @synchronized (sg_lock) { observers = [sg_dataObservers copy]; }
    for (SGSpclientDataObserver observer in observers) observer(session, task, data);
}

static void completed(NSURLSession *session, NSURLSessionTask *task, NSError *error) {
    rememberHeaders(session, task.currentRequest);
    NSArray<SGSpclientCompletionObserver> *observers;
    @synchronized (sg_lock) { observers = [sg_completionObservers copy]; }
    for (SGSpclientCompletionObserver observer in observers) observer(task, error);
}

%hook SPTDataLoaderService
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    received(session, task, data);
    %orig;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    completed(session, task, error);
    %orig;
}
%end

%hook _TtC26Connectivity_HttpClientKit20HttpClientURLSession
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    received(session, task, data);
    %orig;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    completed(session, task, error);
    %orig;
}
%end

%ctor {
    sg_lock = [NSObject new];
    sg_dataObservers = [NSMutableArray array];
    sg_completionObservers = [NSMutableArray array];
    sg_readyBlocks = [NSMutableArray array];
    %init;
    SGRequireClasses(@[
        @"SPTDataLoaderService",
        @"_TtC26Connectivity_HttpClientKit20HttpClientURLSession",
    ]);
}
