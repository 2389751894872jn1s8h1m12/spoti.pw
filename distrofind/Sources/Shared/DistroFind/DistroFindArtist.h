#import <Foundation/Foundation.h>

@interface DFArtistRelease : NSObject
@property (nonatomic, copy) NSString *releaseID;
@property (nonatomic, copy) NSString *gid;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *type;
@property (nonatomic, copy) NSString *year;
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) NSString *firstTrackID;
@property (nonatomic, copy) NSString *licensorUUID;
@property (nonatomic, copy) NSString *parentDistributor;
@property (nonatomic, copy) NSString *likelyDistributor;
@property (nonatomic, copy) NSArray<NSString *> *allowedCountries;
@property (nonatomic, copy) NSArray<NSString *> *forbiddenCountries;
@end

typedef void (^DFArtistScanProgress)(NSUInteger completed, NSUInteger total);
typedef void (^DFArtistScanCompletion)(NSArray<DFArtistRelease *> *releases, NSError *error);

void DFScanArtist(NSString *artistID, DFArtistScanProgress progress, DFArtistScanCompletion completion);
BOOL DFReleaseUnavailableInMarket(DFArtistRelease *release, NSString *market);
NSString *DFReleaseDisplayDistributor(DFArtistRelease *release);
