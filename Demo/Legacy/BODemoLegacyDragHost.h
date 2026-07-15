#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, BODemoLegacyMovementStyle) {
    BODemoLegacyMovementStyleAutomatic = 0,
    BODemoLegacyMovementStyleSystemScroll = 1,
    BODemoLegacyMovementStyleViewAnimation = 2,
};

typedef NS_ENUM(NSInteger, BODemoLegacyHandoffMode) {
    BODemoLegacyHandoffModeCoordinated = 0,
    BODemoLegacyHandoffModeInnerFirst = 1,
    BODemoLegacyHandoffModeInnerFirstAtBoundary = 2,
};

typedef NS_ENUM(NSInteger, BODemoLegacyInnerPlacement) {
    BODemoLegacyInnerPlacementAutomatic = 0,
    BODemoLegacyInnerPlacementAfterFullyDisplayed = 1,
    BODemoLegacyInnerPlacementAtDisplayHeight = 2,
    BODemoLegacyInnerPlacementFromTouchedPosition = 3,
};

typedef NS_ENUM(NSInteger, BODemoLegacyOffsetMismatch) {
    BODemoLegacyOffsetMismatchWait = 0,
    BODemoLegacyOffsetMismatchRestore = 1,
    BODemoLegacyOffsetMismatchContinue = 2,
};

typedef NS_ENUM(NSInteger, BODemoLegacyBounceOwner) {
    BODemoLegacyBounceOwnerPanel = 0,
    BODemoLegacyBounceOwnerInnerScrollView = 1,
};

typedef NS_ENUM(NSInteger, BODemoLegacyAccessibilityDisposition) {
    BODemoLegacyAccessibilityDispositionAutomatic = 0,
    BODemoLegacyAccessibilityDispositionHandled = 1,
    BODemoLegacyAccessibilityDispositionPanelOnly = 2,
};

@interface BODemoLegacyConfiguration : NSObject <NSCopying>

@property (nonatomic, assign) BODemoLegacyHandoffMode handoffMode;
@property (nonatomic, assign) BODemoLegacyInnerPlacement innerPlacement;
@property (nonatomic, assign) CGFloat innerPlacementHeight;
@property (nonatomic, assign) BODemoLegacyOffsetMismatch offsetMismatch;
@property (nonatomic, assign) BOOL preventsInnerToPanelHandoff;
@property (nonatomic, assign) BOOL resistsCollapse;

@property (nonatomic, assign) BOOL allowsPanelTopBounce;
@property (nonatomic, assign) BOOL allowsPanelBottomBounce;
@property (nonatomic, assign) BODemoLegacyBounceOwner preferredTopBounceOwner;
@property (nonatomic, assign) BODemoLegacyBounceOwner preferredBottomBounceOwner;
@property (nonatomic, assign) BOOL forcesInnerTopBounce;

@property (nonatomic, assign) BOOL ignoresMultipleNestedWebScrollViews;
@property (nonatomic, assign) BOOL disablesPanelInteractionInWebView;
@property (nonatomic, assign) BOOL automaticallyShowsInnerIndicator;

@property (nonatomic, assign) BODemoLegacyMovementStyle defaultMovementStyle;
@property (nonatomic, assign) CGFloat animationSpeed;
@property (nonatomic, assign) NSTimeInterval baseAnimationDuration;
@property (nonatomic, assign) NSTimeInterval maximumAnimationDuration;
@property (nonatomic, assign) BOOL usesSpring;
@property (nonatomic, assign) BOOL defersDisplayHeightUpdates;
@property (nonatomic, assign) BOOL animatesDeferredDisplayHeightUpdates;

@end

@class BODemoLegacyDragHost;

@protocol BODemoLegacyDragHostDelegate <NSObject>

- (CGSize)legacyDragHost:(BODemoLegacyDragHost *)host
          sizeForPanelView:(UIView *)panelView
               firstLayout:(BOOL)firstLayout
     proposedDisplayHeight:(CGFloat *)proposedDisplayHeight
    NS_SWIFT_NAME(legacyHost(_:sizeFor:firstLayout:proposedDisplayHeight:));

- (nullable NSArray<NSDictionary<NSString *, NSNumber *> *> *)legacyDragHost:(BODemoLegacyDragHost *)host
                                                       segmentsForScrollView:(UIScrollView *)scrollView
    NS_SWIFT_NAME(legacyHost(_:segmentsFor:));
- (BOOL)legacyDragHost:(BODemoLegacyDragHost *)host canCaptureScrollView:(UIScrollView *)scrollView
    NS_SWIFT_NAME(legacyHost(_:canCapture:));
- (nullable NSDictionary<NSString *, id> *)legacyDragHost:(BODemoLegacyDragHost *)host
                                        adjustCaptureInfo:(NSDictionary<NSString *, id> *)captureInfo
    NS_SWIFT_NAME(legacyHost(_:adjustCaptureInfo:));
- (BODemoLegacyMovementStyle)legacyDragHost:(BODemoLegacyDragHost *)host
                         movementStyleFromHeight:(CGFloat)fromHeight
                                       toHeight:(CGFloat)toHeight
                                         reason:(NSString *)reason
    NS_SWIFT_NAME(legacyHost(_:movementStyleFrom:to:reason:));
- (BODemoLegacyAccessibilityDisposition)legacyDragHost:(BODemoLegacyDragHost *)host
                         accessibilityDispositionFor:(UIAccessibilityScrollDirection)direction
    NS_SWIFT_NAME(legacyHost(_:accessibilityDispositionFor:));
- (nullable NSNumber *)legacyDragHost:(BODemoLegacyDragHost *)host
                 shouldBypassDetentsAt:(CGFloat)displayHeight
    NS_SWIFT_NAME(legacyHost(_:shouldBypassDetentsAt:));
- (void)legacyDragHost:(BODemoLegacyDragHost *)host
    adjustTargetContentOffset:(CGPoint *)targetContentOffset
                     velocity:(CGPoint)velocity
    NS_SWIFT_NAME(legacyHost(_:adjustTargetContentOffset:velocity:));
- (BOOL)legacyDragHostShouldScrollToTop:(BODemoLegacyDragHost *)host
    NS_SWIFT_NAME(legacyHostShouldScrollToTop(_:));

- (void)legacyDragHost:(BODemoLegacyDragHost *)host didChangeDisplayHeight:(CGFloat)displayHeight
    NS_SWIFT_NAME(legacyHost(_:didChangeDisplayHeight:));
- (void)legacyDragHost:(BODemoLegacyDragHost *)host
              didScrollToDisplayHeight:(CGFloat)displayHeight
                              isInner:(BOOL)isInner
    NS_SWIFT_NAME(legacyHost(_:didScrollToDisplayHeight:isInner:));
- (void)legacyDragHost:(BODemoLegacyDragHost *)host
       willMoveToDisplayHeight:(CGFloat)displayHeight
                        reason:(NSString *)reason
    NS_SWIFT_NAME(legacyHost(_:willMoveToDisplayHeight:reason:));
- (void)legacyDragHost:(BODemoLegacyDragHost *)host
        didMoveToDisplayHeight:(CGFloat)displayHeight
                        reason:(NSString *)reason
    NS_SWIFT_NAME(legacyHost(_:didMoveToDisplayHeight:reason:));
- (void)legacyDragHostWillBeginDragging:(BODemoLegacyDragHost *)host
    NS_SWIFT_NAME(legacyHostWillBeginDragging(_:));
- (void)legacyDragHost:(BODemoLegacyDragHost *)host
        willEndDraggingWithVelocity:(CGPoint)velocity
           resolvedTargetContentOffset:(CGPoint)targetContentOffset
    NS_SWIFT_NAME(legacyHost(_:willEndDraggingWithVelocity:resolvedTargetContentOffset:));
- (void)legacyDragHost:(BODemoLegacyDragHost *)host didEndDraggingWillDecelerate:(BOOL)willDecelerate
    NS_SWIFT_NAME(legacyHost(_:didEndDraggingWillDecelerate:));
- (void)legacyDragHostDidEndDecelerating:(BODemoLegacyDragHost *)host
    NS_SWIFT_NAME(legacyHostDidEndDecelerating(_:));
- (void)legacyDragHostDidEndScrollingAnimation:(BODemoLegacyDragHost *)host
    NS_SWIFT_NAME(legacyHostDidEndScrollingAnimation(_:));
- (void)legacyDragHostDidScrollToTop:(BODemoLegacyDragHost *)host
    NS_SWIFT_NAME(legacyHostDidScrollToTop(_:));

@end

@interface BODemoLegacyDragHost : NSObject

@property (nonatomic, strong, readonly) UIScrollView *scrollView;
@property (nonatomic, weak, nullable) id<BODemoLegacyDragHostDelegate> delegate;
@property (nonatomic, strong, nullable) UIView *panelView;
@property (nonatomic, readonly) CGFloat displayHeight;
@property (nonatomic, readonly) BOOL isAnimatingDisplayHeight;
@property (nonatomic, copy) NSArray<NSNumber *> *detentHeights;
@property (nonatomic, copy) NSArray<NSValue *> *nonSnappingRanges;
@property (nonatomic, strong, nullable) NSNumber *minimumDisplayHeight;
@property (nonatomic, copy) BODemoLegacyConfiguration *configuration;

- (instancetype)initWithFrame:(CGRect)frame NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (CGFloat)moveToDisplayHeight:(CGFloat)displayHeight
                      animated:(BOOL)animated
                         style:(BODemoLegacyMovementStyle)style
                       subInfo:(nullable NSDictionary<NSString *, NSNumber *> *)subInfo
                    completion:(void (^ __nullable)(CGFloat finalDisplayHeight))completion
    NS_SWIFT_NAME(move(toDisplayHeight:animated:style:subInfo:completion:));
- (CGFloat)settleToNearestDetentAnimated:(BOOL)animated
                                   style:(BODemoLegacyMovementStyle)style
                                 subInfo:(nullable NSDictionary<NSString *, NSNumber *> *)subInfo
                              completion:(void (^ __nullable)(CGFloat requestedDisplayHeight,
                                                               CGFloat finalDisplayHeight))completion
    NS_SWIFT_NAME(settleToNearestDetent(animated:style:subInfo:completion:));
- (void)invalidatePanelLayout NS_SWIFT_NAME(invalidatePanelLayout());
- (void)reloadScrollMetrics NS_SWIFT_NAME(reloadScrollMetrics());
- (BOOL)performAccessibilityScroll:(UIAccessibilityScrollDirection)direction
    NS_SWIFT_NAME(performAccessibilityScroll(_:));
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
