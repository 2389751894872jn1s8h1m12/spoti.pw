#import <Foundation/Foundation.h>

@interface SPTPlayerTrack : NSObject
@property (nonatomic, readonly) id URI;
@property (nonatomic, readonly) id artistURI;
@property (nonatomic, readonly) NSString *artistName;
@property (nonatomic, readonly) NSString *trackTitle;
@property (nonatomic, readonly) NSDictionary *metadata;
@end

@interface SPTPlayerState : NSObject
@property (nonatomic, readonly) SPTPlayerTrack *track;
@property (nonatomic, readonly) BOOL isPlaying;
@property (nonatomic, readonly) BOOL isPaused;
@end

@interface SPTEsperantoPlayer : NSObject
- (SPTPlayerState *)state;
@end
