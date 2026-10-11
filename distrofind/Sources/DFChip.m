#import "DFChip.h"
#import <QuartzCore/QuartzCore.h>

// The text's inset from the chip's edges, and how much of each end fades while it scrolls.
static const CGFloat kPad = 7, kFade = 6;
static NSString *const kMarqueeKey = @"df.marquee";

@implementation DFChip {
    UIView *_clip;
    UILabel *_label;
    CGFloat _scrolling;   // the overflow the running marquee was built for, 0 while the text is still
}

- (instancetype)initWithFontSize:(CGFloat)size {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    self.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    self.layer.cornerRadius = 6;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.clipsToBounds = YES;

    _clip = [UIView new];
    _clip.userInteractionEnabled = NO;
    _clip.clipsToBounds = YES;
    [self addSubview:_clip];

    _label = [UILabel new];
    _label.font = [UIFont systemFontOfSize:size weight:UIFontWeightSemibold];
    _label.textColor = [UIColor colorWithWhite:1 alpha:0.88];
    _label.userInteractionEnabled = NO;
    [_clip addSubview:_label];

    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.accessibilityHint = @"Opens Track Info";
    [self addTarget:self action:@selector(df_tapped) forControlEvents:UIControlEventTouchUpInside];
    return self;
}

- (void)df_tapped {
    if (self.onTap) self.onTap(self);
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    _clip.alpha = highlighted ? 0.5 : 1;
}

- (NSString *)chipText {
    return _label.text;
}

- (void)setChipText:(NSString *)text {
    text = text ?: @"";
    if ([_label.text isEqualToString:text]) return;
    _label.text = text;
    self.accessibilityLabel = text.length ? [@"Distributor " stringByAppendingString:text] : @"Distributor";
    [self df_stopMarquee];
    [self setNeedsLayout];
}

- (CGFloat)df_textWidth {
    return ceil([_label.text ?: @"" sizeWithAttributes:@{NSFontAttributeName: _label.font}].width);
}

- (CGFloat)fittingWidth {
    return [self df_textWidth] + 2 * kPad;
}

- (void)df_stopMarquee {
    [_label.layer removeAnimationForKey:kMarqueeKey];
    _clip.layer.mask = nil;
    _scrolling = 0;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    // The clip reaches to within a point of the edges so the fade has room; at rest the text still
    // starts kPad in.
    CGRect clipFrame = CGRectInset(bounds, MAX(0, kPad - kFade), 0);
    if (!CGRectEqualToRect(_clip.frame, clipFrame)) {
        _clip.frame = clipFrame;
        [self df_stopMarquee];
    }
    CGFloat text = [self df_textWidth];
    CGFloat room = MAX(0, clipFrame.size.width - 2 * kFade);
    CGRect labelFrame = CGRectMake(kFade, 0, MAX(room, text), clipFrame.size.height);
    if (!CGRectEqualToRect(_label.frame, labelFrame)) _label.frame = labelFrame;

    CGFloat overflow = text - room;
    if (overflow <= 1) {
        if (_scrolling > 0) [self df_stopMarquee];
        return;
    }
    BOOL running = [_label.layer animationForKey:kMarqueeKey] != nil || UIAccessibilityIsReduceMotionEnabled();
    if (_scrolling == overflow && running) return;
    if (!self.window) return;
    [self df_startMarquee:overflow];
}

// Infinite animations are dropped when the app goes to the background or the view leaves the screen.
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window && ![_label.layer animationForKey:kMarqueeKey]) {
        _scrolling = 0;
        [self setNeedsLayout];
    }
}

- (void)df_startMarquee:(CGFloat)overflow {
    [_label.layer removeAnimationForKey:kMarqueeKey];
    _scrolling = overflow;

    CGFloat width = MAX(1, _clip.bounds.size.width);
    CAGradientLayer *fade = [CAGradientLayer layer];
    fade.frame = _clip.bounds;
    fade.startPoint = CGPointMake(0, 0.5);
    fade.endPoint = CGPointMake(1, 0.5);
    fade.colors = @[(__bridge id)UIColor.clearColor.CGColor, (__bridge id)UIColor.blackColor.CGColor,
                    (__bridge id)UIColor.blackColor.CGColor, (__bridge id)UIColor.clearColor.CGColor];
    fade.locations = @[@0, @(kFade / width), @(1 - kFade / width), @1];
    _clip.layer.mask = fade;

    // With Reduce Motion the name stays put, cut off under the fade.
    if (UIAccessibilityIsReduceMotionEnabled()) return;
    CAKeyframeAnimation *marquee = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
    marquee.values = @[@0, @0, @(-overflow), @(-overflow), @0];
    marquee.keyTimes = @[@0, @0.16, @0.57, @0.75, @1];
    marquee.duration = MAX(6, overflow / 12.0 + 3);
    marquee.repeatCount = HUGE_VALF;
    [_label.layer addAnimation:marquee forKey:kMarqueeKey];
}

@end
