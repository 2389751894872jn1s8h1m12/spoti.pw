#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#define SGLog(fmt, ...) NSLog(@"[distrofind] " fmt, ##__VA_ARGS__)

static inline void SGRequireClasses(NSArray<NSString *> *names) {
    for (NSString *name in names) {
        if (!NSClassFromString(name)) SGLog(@"class missing: %@", name);
    }
}

static inline NSString *SGURIString(id uri) {
    if ([uri isKindOfClass:NSURL.class]) return [(NSURL *)uri absoluteString];
    if ([uri isKindOfClass:NSString.class]) return uri;
    return [uri respondsToSelector:@selector(description)] ? [uri description] : nil;
}
