#import <UIKit/UIKit.h>
@class SPTPlayerState;

void DFNotePlayerState(SPTPlayerState *state);
NSString *DFCurrentTrackID(void);
NSString *DFCurrentTrackTitle(void);
NSString *DFCurrentTrackArtist(void);

NSString *DFPageURIForController(UIViewController *controller);
UIViewController *DFPageControllerForView(UIView *view);
UIViewController *DFTopController(void);
