#import <UIKit/UIKit.h>

void DFShowTrackActions(NSString *trackID, NSString *name, UIViewController *presenter);
void DFShowPageActions(UIViewController *controller, NSString *pageURI);

void DFRegisterRowDistributor(NSString *pageURI, NSString *distributor);
NSString *DFSelectedDistributor(NSString *pageURI);
void DFShowDistributorFilter(NSString *pageURI, UIViewController *presenter);
void DFInvalidateCollectionLayouts(UIView *root);
