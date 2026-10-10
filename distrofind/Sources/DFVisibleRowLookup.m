// Source-aware track identification. Never Spotify-search a displayed title:
// different releases of the same recording can have different licensors.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "Shared/Spotify/Spclient.h"

static NSMutableDictionary<NSString *, NSMutableDictionary *> *pages;
static NSString *str(id s) { return [s isKindOfClass:NSString.class] ? s : [s isKindOfClass:NSURL.class] ? [s absoluteString] : nil; }
static NSString *idFromURI(NSString *uri) {
    NSRange r = [uri rangeOfString:@"spotify:track:"];
    if (r.location == NSNotFound || uri.length < NSMaxRange(r)+22) return nil;
    NSString *v = [uri substringWithRange:NSMakeRange(NSMaxRange(r),22)];
    NSCharacterSet *illegal = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"] invertedSet];
    return [v rangeOfCharacterFromSet:illegal].location == NSNotFound ? v : nil;
}
static NSString *norm(NSString *s) {
    return [str(s) ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
}
static NSString *keyFor(NSString *title, NSString *artist) {
    return [NSString stringWithFormat:@"%@|%@",norm(title),norm(artist)];
}
static NSString *directURI(UIView *cell) {
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:cell];
    NSUInteger visited=0;
    while (queue.count && visited++ < 48) {
        UIView *v=queue.firstObject; [queue removeObjectAtIndex:0];
        NSString *a=idFromURI(v.accessibilityIdentifier), *b=idFromURI(v.accessibilityValue);
        if (a||b) return a?:b;
        for (NSString *selectorName in @[@"URI",@"uri",@"spotifyURI",@"trackURI"]) {
            SEL sel=NSSelectorFromString(selectorName);
            Method m=class_getInstanceMethod(v.class,sel);
            if (!m || method_getNumberOfArguments(m)!=2) continue;
            char type[8]={0}; method_getReturnType(m,type,sizeof(type));
            if (type[0]!='@') continue;
            @try { NSString *track=idFromURI(str(((id(*)(id,SEL))objc_msgSend)(v,sel))); if (track) return track; }
            @catch (__unused NSException *e) {}
        }
        [queue addObjectsFromArray:v.subviews];
    }
    return nil;
}
static NSString *pageURI(UIView *cell) {
    for (UIResponder *r=cell; r; r=r.nextResponder) {
        if (![r isKindOfClass:UIViewController.class] || ![r respondsToSelector:@selector(spt_pageURI)]) continue;
        @try { NSString *uri=str(((id(*)(id,SEL))objc_msgSend)(r,@selector(spt_pageURI))); if (uri.length) return uri; }
        @catch (__unused NSException *e) {}
    }
    return nil;
}
static NSURL *sourceURL(NSString *uri, NSInteger offset) {
    NSString *base=nil;
    NSInteger limit=50;
    if ([uri hasPrefix:@"spotify:playlist:"] && uri.length==39) {
        base=[@"https://api.spotify.com/v1/playlists/" stringByAppendingFormat:@"%@/tracks",[uri substringFromIndex:17]];
        limit=100;
    } else if ([uri hasPrefix:@"spotify:album:"] && uri.length==36) {
        base=[@"https://api.spotify.com/v1/albums/" stringByAppendingFormat:@"%@/tracks",[uri substringFromIndex:14]];
    } else if ([uri isEqualToString:@"spotify:collection:tracks"]) {
        base=@"https://api.spotify.com/v1/me/tracks";
    }
    if (!base) return nil;
    NSURLComponents *parts=[NSURLComponents componentsWithString:base];
    parts.queryItems=@[[NSURLQueryItem queryItemWithName:@"offset" value:[NSString stringWithFormat:@"%ld",(long)offset]],
                       [NSURLQueryItem queryItemWithName:@"limit" value:[NSString stringWithFormat:@"%ld",(long)limit]]];
    return parts.URL;
}
static NSString *artists(NSDictionary *item) {
    NSMutableArray *names=[NSMutableArray array];
    for (NSDictionary *a in [item[@"artists"] isKindOfClass:NSArray.class]?item[@"artists"]:@[])
        if (str(a[@"name"])) [names addObject:a[@"name"]];
    return [names componentsJoinedByString:@", "];
}
static void finish(NSMutableDictionary *page) {
    NSDictionary *index=page[@"index"];
    NSMutableDictionary *pending=page[@"pending"];
    for (NSString *k in [pending.allKeys copy]) {
        NSSet *ids=index[k];
        if (!ids.count && ![page[@"done"] boolValue]) continue;
        NSArray *callbacks=[pending[k] copy]; [pending removeObjectForKey:k];
        NSString *answer=ids.count==1?ids.anyObject:nil;
        for (void (^cb)(NSString *) in callbacks) cb(answer);
    }
}
static void fetchPage(NSString *uri) {
    NSMutableDictionary *page=pages[uri];
    if (!page || [page[@"busy"] boolValue] || [page[@"done"] boolValue]) return;
    NSInteger offset=[page[@"offset"] integerValue];
    NSURL *url=sourceURL(uri,offset);
    if (!url) return;
    NSMutableURLRequest *request=SGSpclientRequest(url);
    if (!request) {
        SGSpclientWhenReady(^{ fetchPage(uri); });
        return;
    }
    // Web API only needs Authorization, not the spclient-specific routing headers.
    for (NSString *header in @[@"client-token",@"app-platform",@"spotify-app-version"])
        [request setValue:nil forHTTPHeaderField:header];
    request.timeoutInterval=12;
    page[@"busy"]=@YES;
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error) {
        NSHTTPURLResponse *http=[response isKindOfClass:NSHTTPURLResponse.class]?(id)response:nil;
        id obj=(!error && http.statusCode==200 && data.length)
            ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
        NSDictionary *json=[obj isKindOfClass:NSDictionary.class]?obj:nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            page[@"busy"]=@NO;
            NSArray *items=[json[@"items"] isKindOfClass:NSArray.class]?json[@"items"]:@[];
            NSMutableDictionary *index=page[@"index"];
            for (NSDictionary *wrapper in items) {
                NSDictionary *track=[wrapper[@"track"] isKindOfClass:NSDictionary.class]?wrapper[@"track"]:wrapper;
                NSString *sid=str(track[@"id"]);
                if (sid.length!=22) sid=idFromURI(str(track[@"uri"]));
                if (!sid.length || !str(track[@"name"]).length) continue;
                NSString *k=keyFor(track[@"name"],artists(track));
                NSMutableSet *ids=index[k];
                if (!ids) index[k]=ids=[NSMutableSet set];
                [ids addObject:sid];
            }
            NSInteger limit=[uri hasPrefix:@"spotify:playlist:"]?100:50;
            NSInteger next=offset+limit;
            page[@"offset"]=@(next);
            BOOL done=!json || items.count<limit || next>=200 || (json[@"total"] && next>=[json[@"total"] integerValue]);
            page[@"done"]=@(done);
            if (!json) NSLog(@"[distrofind] exact row API unavailable (HTTP %ld); no approximate badges",(long)http.statusCode);
            finish(page);
            if (!done && [page[@"pending"] count]) fetchPage(uri);
        });
    }] resume];
}
void DFRowResolveTrack(NSString *title, NSString *artist, UIView *cell, void (^completion)(NSString *trackID)) {
    if (!NSThread.isMainThread || !completion || !cell || !title.length) return;
    NSString *sid=directURI(cell);
    if (sid) { completion(sid); return; }
    NSString *uri=pageURI(cell);
    if (!sourceURL(uri,0)) { completion(nil); return; }
    NSMutableDictionary *page=pages[uri];
    if (!page) {
        page=[@{@"offset":@0,@"busy":@NO,@"done":@NO,
                @"index":[NSMutableDictionary dictionary],@"pending":[NSMutableDictionary dictionary]} mutableCopy];
        pages[uri]=page;
    }
    NSString *key=keyFor(title,artist);
    NSSet *ids=page[@"index"][key];
    if (ids.count>1 || (ids.count && [page[@"done"] boolValue])) { completion(ids.count==1?ids.anyObject:nil); return; }
    if ([page[@"done"] boolValue]) { completion(nil); return; }
    NSMutableArray *callbacks=page[@"pending"][key];
    if (!callbacks) page[@"pending"][key]=callbacks=[NSMutableArray array];
    if (callbacks.count<6) [callbacks addObject:[completion copy]];
    fetchPage(uri);
}
__attribute__((constructor)) static void DFRowInit(void) { pages=[NSMutableDictionary dictionary]; }
