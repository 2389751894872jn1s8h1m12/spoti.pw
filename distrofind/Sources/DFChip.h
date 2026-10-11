// The distributor chip: a small neutral capsule whose text scrolls inside it when the name is longer
// than the room it was given, so the chip itself never grows into Spotify's controls.
//
// A UIButton rather than a bare UIControl: UIKit lets a button's own tap win over a tap recognizer on a
// view around it, so tapping the chip opens Track Info without also playing the row or opening the
// player's album link underneath it.
#import <UIKit/UIKit.h>

@interface DFChip : UIButton
@property (nonatomic, copy) NSString *trackID;
@property (nonatomic, copy) void (^onTap)(DFChip *chip);
- (instancetype)initWithFontSize:(CGFloat)size;
- (void)setChipText:(NSString *)text;
- (NSString *)chipText;
// The width that shows the whole name without scrolling.
- (CGFloat)fittingWidth;
@end
