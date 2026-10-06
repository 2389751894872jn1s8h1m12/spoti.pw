// Reuse spoti.pw 0.50.0's own authenticated Spotify session state.
//
// The official 0.50.0 binary keeps the current Authorization value for its own metadata/artwork
// requests. The companion is always packaged with that exact release-kit binary (verified by SHA-256
// in pipeline-v050.sh), so reading its existing in-process value avoids stacking another URLSession
// interception on Spotify.
#import "Core/SGCore.h"
#import "Spclient.h"
#import <mach-o/dyld.h>
#include <stdint.h>

static const uintptr_t kSpoti050AuthLockOffset = 0x3b1168;
static const uintptr_t kSpoti050AuthorizationOffset = 0x3b11f0;

static intptr_t spoti050Slide(void) {
    static intptr_t slide = INTPTR_MIN;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        slide = 0;
        for (uint32_t i = 0; i < _dyld_image_count(); i++) {
            const char *path = _dyld_get_image_name(i);
            if (!path) continue;
            NSString *name = [[NSString stringWithUTF8String:path] lastPathComponent];
            if ([name isEqualToString:@"spotifyglass.dylib"]) {
                slide = _dyld_get_image_vmaddr_slide(i);
                SGLog(@"using spoti.pw 0.50 session bridge");
                break;
            }
        }
    });
    return slide;
}

static NSString *authorization(void) {
    intptr_t slide = spoti050Slide();
    if (!slide) return nil;

    __unsafe_unretained NSObject **lockSlot =
        (__unsafe_unretained NSObject **)(slide + kSpoti050AuthLockOffset);
    __unsafe_unretained NSString **authSlot =
        (__unsafe_unretained NSString **)(slide + kSpoti050AuthorizationOffset);

    NSObject *lock = *lockSlot;
    if (!lock) return [*authSlot copy];
    @synchronized (lock) {
        NSString *value = *authSlot;
        return [value isKindOfClass:NSString.class] ? [value copy] : nil;
    }
}

NSDictionary<NSString *, NSString *> *SGSpclientHeaders(void) {
    NSString *auth = authorization();
    return auth.length ? @{@"authorization": auth} : @{};
}

NSString *SGSpclientAuthorization(void) {
    return authorization();
}

NSMutableURLRequest *SGSpclientRequest(NSURL *url) {
    NSString *auth = authorization();
    if (!url || !auth.length) return nil;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:auth forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    return request;
}

void SGSpclientWhenReady(void (^block)(void)) {
    if (!block) return;
    if (authorization().length) {
        dispatch_async(dispatch_get_main_queue(), block);
        return;
    }

    __block NSUInteger tries = 0;
    __block void (^check)(void);
    check = ^{
        if (authorization().length || tries++ >= 60) {
            if (authorization().length) block();
            else SGLog(@"Spotify session was not ready after 30s");
            check = nil;
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), check);
    };
    dispatch_async(dispatch_get_main_queue(), check);
}

void SGSpclientAddObserver(SGSpclientDataObserver dataObserver,
                           SGSpclientCompletionObserver completionObserver) {
    // The companion has no response-observer clients. This API stays present so the metadata layer
    // remains source-compatible with the proven standalone port.
}
