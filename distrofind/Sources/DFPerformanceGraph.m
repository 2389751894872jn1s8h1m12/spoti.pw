#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

// A native UIKit performance chart backed by the updated DistroFind
// /performance-data/{track} endpoint. All values originate from server data.
@interface DFHistoryPlot : UIView <UIGestureRecognizerDelegate>
@property (nonatomic, copy) NSArray<NSDictionary *> *daily;
@property (nonatomic) NSInteger selectedIndex;
@property (nonatomic, strong) UILabel *detail;
@end

static NSString *DFShortCount(double number) {
    double n = fabs(number);
    if (n >= 1e9) return [NSString stringWithFormat:@"%.1fB", number / 1e9];
    if (n >= 1e6) return [NSString stringWithFormat:@"%.1fM", number / 1e6];
    if (n >= 1e3) return [NSString stringWithFormat:@"%.1fK", number / 1e3];
    return [NSString stringWithFormat:@"%.0f", number];
}

@implementation DFHistoryPlot
- (instancetype)init {
    if ((self = [super init])) {
        _selectedIndex = NSNotFound;
        _detail = [UILabel new];
        _detail.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold];
        _detail.textColor = UIColor.whiteColor;
        _detail.backgroundColor = [UIColor colorWithWhite:0.17 alpha:0.95];
        _detail.layer.cornerRadius = 7;
        _detail.clipsToBounds = YES;
        _detail.textAlignment = NSTextAlignmentCenter;
        _detail.adjustsFontSizeToFitWidth = YES;
        _detail.minimumScaleFactor = 0.8;
        _detail.hidden = YES;
        [self addSubview:_detail];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(scrub:)];
        pan.delegate = self;
        pan.cancelsTouchesInView = NO;
        [self addGestureRecognizer:pan];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(scrub:)];
        tap.delegate = self;
        [self addGestureRecognizer:tap];
        self.isAccessibilityElement = YES;
        self.accessibilityLabel = @"Daily Spotify streams graph. Drag or tap to inspect a date.";
    }
    return self;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    // Vertical movement must continue to scroll the info page.
    return YES;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.detail.frame = CGRectMake(8, 2, MAX(1, self.bounds.size.width - 16), 23);
}
- (void)scrub:(UIGestureRecognizer *)gesture {
    if (!self.daily.count || gesture.state == UIGestureRecognizerStateCancelled ||
        gesture.state == UIGestureRecognizerStateFailed) return;
    CGFloat plotLeft = 52, plotRight = 12;
    CGFloat plotWidth = MAX(1, self.bounds.size.width - plotLeft - plotRight);
    CGFloat touch = [gesture locationInView:self].x;
    double progress = MIN(1, MAX(0, (touch - plotLeft) / plotWidth));
    NSInteger index = (NSInteger)llround(progress * (self.daily.count - 1));
    if (index == self.selectedIndex) return;
    self.selectedIndex = index;
    NSDictionary *item = self.daily[index];
    NSString *date = [item[@"date"] isKindOfClass:NSString.class] ? item[@"date"] : @"Unknown day";
    NSNumberFormatter *format = [NSNumberFormatter new];
    format.numberStyle = NSNumberFormatterDecimalStyle;
    NSString *value = [format stringFromNumber:@([item[@"streams"] doubleValue])] ?: @"0";
    NSInteger start = MAX(0, index - 6);
    double sum = 0;
    for (NSInteger j = start; j <= index; j++) sum += [self.daily[j][@"streams"] doubleValue];
    NSString *average = [format stringFromNumber:@(llround(sum / (index - start + 1)))] ?: @"0";
    self.detail.text = [NSString stringWithFormat:@" %@ · %@ streams · avg %@ ", date, value, average];
    self.detail.hidden = NO;
    self.accessibilityValue = self.detail.text;
    [self setNeedsDisplay];
}
- (void)drawRect:(CGRect)bounds {
    NSArray<NSDictionary *> *rows = self.daily;
    if (!rows.count) return;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    CGFloat left = 52, right = 12, top = 22, bottom = 38;
    CGFloat width = MAX(1, bounds.size.width - left - right);
    CGFloat height = MAX(1, bounds.size.height - top - bottom);
    NSMutableArray<NSNumber *> *values = [NSMutableArray array];
    double maximum = 1;
    for (NSDictionary *item in rows) {
        double value = MAX(0, [item[@"streams"] doubleValue]);
        [values addObject:@(value)];
        maximum = MAX(maximum, value);
    }
    maximum *= 1.15;
    UIColor *muted = [UIColor colorWithWhite:0.56 alpha:1];
    NSDictionary *attrs = @{NSFontAttributeName:[UIFont systemFontOfSize:10],
                            NSForegroundColorAttributeName:muted};
    for (NSUInteger i = 0; i < 5; i++) {
        CGFloat y = top + height * i / 4.0;
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0.25 alpha:0.8].CGColor);
        CGContextSetLineWidth(ctx, 0.5);
        CGContextMoveToPoint(ctx, left, y);
        CGContextAddLineToPoint(ctx, bounds.size.width - right, y);
        CGContextStrokePath(ctx);
        NSString *label = DFShortCount(maximum * (1.0 - i / 4.0));
        [label drawAtPoint:CGPointMake(4, y - 7) withAttributes:attrs];
    }
    CGFloat (^px)(NSUInteger) = ^CGFloat(NSUInteger i) {
        return left + width * i / MAX((NSInteger)values.count - 1, 1);
    };
    CGFloat (^py)(double) = ^CGFloat(double v) {
        return top + height * (1 - v / maximum);
    };
    UIBezierPath *line = [UIBezierPath bezierPath];
    NSUInteger highestIndex = 0;
    for (NSUInteger i = 0; i < values.count; i++) {
        if ([values[i] doubleValue] > [values[highestIndex] doubleValue]) highestIndex = i;
        CGPoint point = CGPointMake(px(i), py([values[i] doubleValue]));
        if (!i) [line moveToPoint:point]; else [line addLineToPoint:point];
    }
    UIBezierPath *area = [line copy];
    [area addLineToPoint:CGPointMake(px(values.count - 1), top + height)];
    [area addLineToPoint:CGPointMake(left, top + height)];
    [area closePath];
    [[UIColor colorWithRed:0.12 green:0.85 blue:0.40 alpha:0.13] setFill];
    [area fill];
    UIColor *green = [UIColor colorWithRed:0.12 green:0.85 blue:0.40 alpha:1];
    [green setStroke];
    line.lineWidth = 2.5;
    line.lineJoinStyle = kCGLineJoinRound;
    [line stroke];

    UIBezierPath *avg = [UIBezierPath bezierPath];
    for (NSUInteger i = 6; i < values.count; i++) {
        double total = 0;
        for (NSUInteger j = i - 6; j <= i; j++) total += [values[j] doubleValue];
        CGPoint point = CGPointMake(px(i), py(total / 7.0));
        if (i == 6) [avg moveToPoint:point]; else [avg addLineToPoint:point];
    }
    if (values.count > 6) {
        CGFloat dash[] = {5, 4};
        CGContextSaveGState(ctx);
        CGContextSetLineDash(ctx, 0, dash, 2);
        [[UIColor colorWithWhite:1 alpha:0.6] setStroke];
        avg.lineWidth = 1.3;
        [avg stroke];
        CGContextRestoreGState(ctx);
    }
    if (self.selectedIndex != NSNotFound && self.selectedIndex < (NSInteger)values.count) {
        CGFloat x = px(self.selectedIndex);
        CGContextSaveGState(ctx);
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.6].CGColor);
        CGContextSetLineWidth(ctx, 1);
        CGContextMoveToPoint(ctx, x, top);
        CGContextAddLineToPoint(ctx, x, top + height);
        CGContextStrokePath(ctx);
        CGFloat y = py([values[self.selectedIndex] doubleValue]);
        [[UIColor whiteColor] setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(x - 4.5, y - 4.5, 9, 9)] fill];
        CGContextRestoreGState(ctx);
    }
    CGPoint best = CGPointMake(px(highestIndex), py([values[highestIndex] doubleValue]));
    [[UIColor whiteColor] setFill];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(best.x - 4, best.y - 4, 8, 8)] fill];
    NSUInteger step = MAX((NSUInteger)1, values.count / 5);
    for (NSUInteger i = 0; i < rows.count; i += step) {
        NSString *date = [rows[i][@"date"] isKindOfClass:NSString.class] ? rows[i][@"date"] : @"";
        if (date.length >= 10) date = [date substringFromIndex:5];
        CGRect rect = CGRectMake(px(i) - 22, top + height + 7, 54, 18);
        [date drawInRect:rect withAttributes:attrs];
    }
}
@end

@interface DFHistoryController : UIViewController
- (instancetype)initWithData:(NSDictionary *)json;
@end

@implementation DFHistoryController {
    NSDictionary *_data;
}
- (instancetype)initWithData:(NSDictionary *)json {
    if ((self = [super init])) { _data = [json copy]; self.title = @"Streaming performance"; }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:scroll];

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    stack.alignment = UIStackViewAlignmentFill;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-20],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40]
    ]];
    UILabel *(^label)(NSString *, CGFloat, BOOL) = ^UILabel *(NSString *value, CGFloat size, BOOL bold) {
        UILabel *result = [UILabel new];
        result.font = bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
        result.text = value;
        result.numberOfLines = 0;
        return result;
    };
    NSString *name = [_data[@"name"] isKindOfClass:NSString.class] ? _data[@"name"] : @"";
    NSString *artist = [_data[@"artist"] isKindOfClass:NSString.class] ? _data[@"artist"] : @"";
    [stack addArrangedSubview:label(name, 23, YES)];
    [stack addArrangedSubview:label(artist, 14, NO)];

    NSArray *days = [_data[@"daily"] isKindOfClass:NSArray.class] ? _data[@"daily"] : @[];
    NSNumber *trend = [_data[@"trend"] respondsToSelector:@selector(doubleValue)] ? _data[@"trend"] : nil;
    NSDictionary *best = [_data[@"best"] isKindOfClass:NSDictionary.class] ? _data[@"best"] : @{};
    NSArray *metrics = @[
        @[@"Total streams", DFShortCount([_data[@"total"] doubleValue])],
        @[@"Gained", [@"+" stringByAppendingString:DFShortCount([_data[@"gained"] doubleValue])]],
        @[@"Daily median", DFShortCount([_data[@"median"] doubleValue])],
        @[@"7-day trend", trend ? [NSString stringWithFormat:@"%@ %.1f%%", trend.doubleValue < 0 ? @"▼" : @"▲", fabs(trend.doubleValue)] : @"—"],
        @[@"Best day", DFShortCount([best[@"streams"] doubleValue])]
    ];
    for (NSArray *entry in metrics) {
        UIStackView *row = [UIStackView new];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.distribution = UIStackViewDistributionEqualSpacing;
        [row addArrangedSubview:label(entry[0], 13, NO)];
        [row addArrangedSubview:label(entry[1], 16, YES)];
        [stack addArrangedSubview:row];
    }

    DFHistoryPlot *plot = [DFHistoryPlot new];
    plot.daily = days;
    plot.backgroundColor = [UIColor colorWithWhite:0.11 alpha:1];
    plot.layer.cornerRadius = 12;
    plot.clipsToBounds = YES;
    [stack addArrangedSubview:plot];
    [plot.heightAnchor constraintEqualToConstant:275].active = YES;
    [stack addArrangedSubview:label(@"Green: daily Spotify streams    Dashed: 7-day average    White: best day", 12, NO)];
    [stack addArrangedSubview:label([NSString stringWithFormat:@"%lu days of stream history", (unsigned long)days.count], 12, NO)];
}
@end

UIViewController *DFPerformanceGraphController(NSDictionary *data) {
    return [[DFHistoryController alloc] initWithData:data];
}
