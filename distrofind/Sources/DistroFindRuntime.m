#import "Core/SGCore.h"
#import "SpotifyTypes.h"
#import "DistroFindRuntime.h"
#import <objc/message.h>

static NSString *df_trackID;
static NSString *df_trackTitle;
static NSString *df_trackArtist;

void DFNotePlayerState(SPTPlayerState *state) {
    SPTPlayerTrack *track = [state isKindOfClass:NSClassFromString(@"SPTPlayerState")] ? state.track : nil;
    NSString *uri = SGURIString(track.URI);
    NSString *prefix = @"spotify:track:";
    NSString *trackID = [uri hasPrefix:prefix] ? [uri substringFromIndex:prefix.length] : nil;
    if (trackID.length != 22) trackID = nil;

    @synchronized (SPTPlayerState.class) {
        df_trackID = [trackID copy];
        df_trackTitle = [track.trackTitle copy] ?: @"";
        df_trackArtist = [track.artistName copy] ?: @"";
    }
}

NSString *DFCurrentTrackID(void) {
    @synchronized (SPTPlayerState.class) { return [df_trackID copy]; }
}
NSString *DFCurrentTrackTitle(void) {
    @synchronized (SPTPlayerState.class) { return [df_trackTitle copy]; }
}
NSString *DFCurrentTrackArtist(void) {
    @synchronized (SPTPlayerState.class) { return [df_trackArtist copy]; }
}

NSString *DFPageURIForController(UIViewController *controller) {
    if (!controller) return nil;
    SEL selector = NSSelectorFromString(@"spt_pageURI");
    if (![controller respondsToSelector:selector]) return nil;
    id (*send)(id, SEL) = (void *)objc_msgSend;
    id value = send(controller, selector);
    return SGURIString(value);
}

UIViewController *DFPageControllerForView(UIView *view) {
    UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:UIViewController.class]) {
            UIViewController *controller = (id)responder;
            if (DFPageURIForController(controller).length) return controller;
        }
        responder = responder.nextResponder;
    }
    return nil;
}

UIViewController *DFTopController(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive ||
            ![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) { window = candidate; break; }
            if (!window && !candidate.hidden) window = candidate;
        }
        if (window) break;
    }
    UIViewController *top = window.rootViewController;
    while (top) {
        UIViewController *next = top.presentedViewController;
        if (!next && [top isKindOfClass:UINavigationController.class])
            next = ((UINavigationController *)top).visibleViewController;
        if (!next && [top isKindOfClass:UITabBarController.class])
            next = ((UITabBarController *)top).selectedViewController;
        if (!next || next == top) break;
        top = next;
    }
    return top;
}
