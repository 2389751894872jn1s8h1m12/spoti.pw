#import <UIKit/UIKit.h>

@interface SGDistroAvailability : NSObject
@property (nonatomic, copy) NSString *kind; // worldwide, locked, gone, unknown
@property (nonatomic, copy) NSArray<NSString *> *available;
@property (nonatomic, copy) NSArray<NSString *> *blocked;
@property (nonatomic) BOOL cached;
@property (nonatomic) NSTimeInterval seconds;
@end

typedef void (^SGDistroAvailabilityCompletion)(SGDistroAvailability *result, NSError *error);

void SGDistroAvailabilityForTrack(NSString *trackID, SGDistroAvailabilityCompletion completion);
void SGDistroPerformanceImageForTrack(NSString *trackID, void (^completion)(UIImage *image, NSString *message, NSError *error));
void SGDistroOtherVersionsForTrack(NSString *trackID, void (^completion)(NSDictionary *result, NSError *error));
void SGDistroVydiaSubDistributor(NSString *albumID, NSString *albumName, NSString *artistName,
                                 void (^completion)(NSString *subDistributor));
