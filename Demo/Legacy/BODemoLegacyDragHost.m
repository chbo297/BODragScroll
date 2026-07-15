#import "BODemoLegacyDragHost.h"
#import "Original/BODragScrollView.h"

typedef struct BODemoLegacyAttachInfo {
    NSInteger scrollViewIdx;
    CGFloat displayH;
    CGFloat dragSVOffsetY;
    BOOL dragInner;
    CGFloat innerOffsetA;
    CGFloat innerOffsetB;
    CGFloat dragSVOffsetY2;
} BODemoLegacyAttachInfo;

@interface BODragScrollView (BODemoPrivateAdapter)
@property (nonatomic, assign) BOOL isScrollAnimating;
// The original header intentionally exposes this as readonly, while its class extension owns the
// setter. The comparison adapter needs that setter only to reconcile a safe-area relayout after a
// nested capture; otherwise the original model can retain the pre-rotation diagnostic height even
// though the panel frame has already been clamped to the new viewport.
@property (nonatomic, assign) CGFloat currDisplayH;
- (void)forceReloadCurrInnerScrollView;
- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView;
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView
                  willDecelerate:(BOOL)decelerate;
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView;
- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView;
- (void)__liteAnimateToOffset:(CGPoint)offset
                          vel:(CGFloat)velocity
              additionOptions:(UIViewAnimationOptions)options
                      subInfo:(nullable NSDictionary *)subInfo
                   completion:(void (^ __nullable)(BOOL finished))completion;
- (NSInteger)__scrollViewWillEndDragging:(UIScrollView *)scrollView
                            withVelocity:(CGPoint)velocity
                     targetContentOffset:(CGPoint *)targetContentOffset
                              attachInfo:(BODemoLegacyAttachInfo *)attachInfo;
@end

/// Guards the byte-identical source implementation before it consumes its untagged UIKit
/// terminals. A cancelled generation can otherwise deliver after a new one starts and clear the
/// source's shared `_waitMayAnimationScroll` / `_waitDidTargetTo` state for the wrong movement.
@interface BODemoLegacyTrackedDragView : BODragScrollView
@property (nonatomic, assign) BOOL hasSystemGeneration;
@property (nonatomic, assign) BOOL didDeliverSystemTerminal;
@property (nonatomic, assign) BOOL dropsUntrackedSystemTerminals;
@property (nonatomic, assign) BOOL systemGenerationRequiresPredecessorProof;
@property (nonatomic, assign) CGPoint systemTargetOffset;
@property (nonatomic, assign) NSUInteger nextSystemGenerationID;
@property (nonatomic, assign) NSUInteger systemGenerationID;
@property (nonatomic, assign) NSUInteger deliveringSystemGenerationID;
@property (nonatomic, assign) BOOL hasDragGeneration;
@property (nonatomic, assign) BOOL dragExpectsDeceleration;
@property (nonatomic, assign) BOOL didDeliverDecelerationTerminal;
@property (nonatomic, assign) BOOL cancelledCurrentDragDeceleration;
@property (nonatomic, assign) BOOL dropsUntrackedDecelerationTerminals;
@property (nonatomic, assign) NSUInteger viewCancellationEpoch;
@property (nonatomic, assign) NSUInteger nextViewSequenceID;
@property (nonatomic, assign) NSUInteger latestViewSequenceID;
@property (nonatomic, assign) NSUInteger deliveringViewSequenceID;
@property (nonatomic, assign) NSUInteger deliveringViewEpoch;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *activeViewSequenceIDs;
- (void)armCancelledSystemGeneration;
- (void)armCancelledDecelerationGeneration;
- (void)invalidateViewGenerations;
- (void)forceSuperDidEndScrollingAnimation;
- (void)forceSuperDidEndDecelerating;
- (BOOL)presentationReachedSystemTarget;
- (BOOL)hasActiveViewGeneration;
- (BOOL)isDeliveringViewGeneration;
- (BOOL)isDeliveringCurrentViewGeneration;
- (BOOL)isDeliveringSystemGeneration;
- (BOOL)isDeliveringCurrentSystemGeneration;
@end

@implementation BODemoLegacyTrackedDragView

- (void)setContentOffset:(CGPoint)contentOffset animated:(BOOL)animated {
    if (animated && isfinite(contentOffset.x) && isfinite(contentOffset.y)) {
        BOOL hasPotentialPredecessor = self.hasSystemGeneration
            || self.dropsUntrackedSystemTerminals;
        self.hasSystemGeneration = YES;
        self.didDeliverSystemTerminal = NO;
        self.dropsUntrackedSystemTerminals = NO;
        self.systemGenerationRequiresPredecessorProof = hasPotentialPredecessor;
        self.systemTargetOffset = contentOffset;
        self.nextSystemGenerationID += 1;
        self.systemGenerationID = self.nextSystemGenerationID;
    } else if (!animated
               && self.hasDragGeneration
               && [[self valueForKey:@"ignoreWaitDidTargetTo"] boolValue]) {
        // The source selects its custom UIView-animation path by cancelling UIKit deceleration
        // only inside its exact `_ignoreWaitDidTargetTo` window. A generic tracking check would
        // misclassify the nonanimated offset reconciliation used by a rotation during a live drag.
        self.cancelledCurrentDragDeceleration = YES;
    }
    [super setContentOffset:contentOffset animated:animated];
}

- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView {
    if (self.hasSystemGeneration) {
        BOOL reachedTarget = [self presentationReachedSystemTarget];
        BOOL isInteractionInterruption = self.isTracking
            || self.isDragging
            || self.isDecelerating;
        BOOL mayBelongToCurrentGeneration = reachedTarget
            || isInteractionInterruption
            || !self.systemGenerationRequiresPredecessorProof;
        if (self.didDeliverSystemTerminal || !mayBelongToCurrentGeneration) {
            return;
        }
        NSUInteger generationID = self.systemGenerationID;
        self.didDeliverSystemTerminal = YES;
        self.dropsUntrackedSystemTerminals = NO;
        self.deliveringSystemGenerationID = generationID;
        [super scrollViewDidEndScrollingAnimation:scrollView];
        self.deliveringSystemGenerationID = 0;
        return;
    }
    if (self.dropsUntrackedSystemTerminals) { return; }
    [super scrollViewDidEndScrollingAnimation:scrollView];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    self.hasDragGeneration = YES;
    self.dragExpectsDeceleration = NO;
    self.didDeliverDecelerationTerminal = NO;
    self.cancelledCurrentDragDeceleration = NO;
    [super scrollViewWillBeginDragging:scrollView];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    self.dragExpectsDeceleration = decelerate && !self.cancelledCurrentDragDeceleration;
    [super scrollViewDidEndDragging:scrollView willDecelerate:decelerate];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    if (self.hasDragGeneration) {
        BOOL isSemanticTerminal = self.dragExpectsDeceleration
            && !self.isDecelerating;
        if (self.didDeliverDecelerationTerminal || !isSemanticTerminal) { return; }
        self.didDeliverDecelerationTerminal = YES;
        self.dropsUntrackedDecelerationTerminals = NO;
        [super scrollViewDidEndDecelerating:scrollView];
        return;
    }
    if (self.dropsUntrackedDecelerationTerminals) { return; }
    [super scrollViewDidEndDecelerating:scrollView];
}

- (void)armCancelledSystemGeneration {
    self.hasSystemGeneration = NO;
    self.didDeliverSystemTerminal = NO;
    self.systemGenerationRequiresPredecessorProof = NO;
    self.dropsUntrackedSystemTerminals = YES;
}

- (void)armCancelledDecelerationGeneration {
    self.hasDragGeneration = NO;
    self.dragExpectsDeceleration = NO;
    self.didDeliverDecelerationTerminal = NO;
    self.cancelledCurrentDragDeceleration = NO;
    self.dropsUntrackedDecelerationTerminals = YES;
}

- (void)__liteAnimateToOffset:(CGPoint)offset
                          vel:(CGFloat)velocity
              additionOptions:(UIViewAnimationOptions)options
                      subInfo:(NSDictionary *)subInfo
                   completion:(void (^)(BOOL))completion {
    self.nextViewSequenceID += 1;
    NSUInteger sequenceID = self.nextViewSequenceID;
    NSUInteger epoch = self.viewCancellationEpoch;
    self.latestViewSequenceID = sequenceID;
    if (!self.activeViewSequenceIDs) {
        self.activeViewSequenceIDs = [NSMutableSet set];
    }
    [self.activeViewSequenceIDs addObject:@(sequenceID)];

    __weak typeof(self) weakSelf = self;
    [super __liteAnimateToOffset:offset
                             vel:velocity
                 additionOptions:options
                         subInfo:subInfo
                      completion:^(BOOL finished) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) { return; }
        [self.activeViewSequenceIDs removeObject:@(sequenceID)];
        if (epoch != self.viewCancellationEpoch) {
            // Relayout/new non-View ownership already closed this generation. Do not execute the
            // original completion: it contains both the old public completion and old didTarget.
            if (self.activeViewSequenceIDs.count > 0) {
                self.isScrollAnimating = YES;
            }
            return;
        }

        self.deliveringViewEpoch = epoch;
        self.deliveringViewSequenceID = sequenceID;
        if (completion) { completion(finished); }
        self.deliveringViewSequenceID = 0;
        self.deliveringViewEpoch = 0;
        // UIKit sets the source's shared bit to NO before invoking this wrapper. Restore it when a
        // begin-from-current-state replacement is still owned by a newer sequence.
        if (self.activeViewSequenceIDs.count > 0) {
            self.isScrollAnimating = YES;
        }
    }];
}

- (void)invalidateViewGenerations {
    self.viewCancellationEpoch += 1;
    [self.activeViewSequenceIDs removeAllObjects];
    self.latestViewSequenceID = 0;
    self.deliveringViewSequenceID = 0;
    self.deliveringViewEpoch = 0;
}

- (void)forceSuperDidEndScrollingAnimation {
    [super scrollViewDidEndScrollingAnimation:self];
}

- (void)forceSuperDidEndDecelerating {
    [super scrollViewDidEndDecelerating:self];
}

- (BOOL)presentationReachedSystemTarget {
    CGFloat epsilon = 1.0 / MAX(UIScreen.mainScreen.scale, 1.0);
    CGPoint modelOffset = self.contentOffset;
    BOOL modelReachedTarget = isfinite(modelOffset.x)
        && isfinite(modelOffset.y)
        && fabs(modelOffset.x - self.systemTargetOffset.x) <= epsilon
        && fabs(modelOffset.y - self.systemTargetOffset.y) <= epsilon;
    if (modelReachedTarget) { return YES; }

    CALayer *presentationLayer = self.layer.presentationLayer;
    if (!presentationLayer) { return NO; }
    CGPoint presentationOffset = presentationLayer.bounds.origin;
    if (!isfinite(presentationOffset.x) || !isfinite(presentationOffset.y)) { return NO; }
    return fabs(presentationOffset.x - self.systemTargetOffset.x) <= epsilon
        && fabs(presentationOffset.y - self.systemTargetOffset.y) <= epsilon;
}

- (BOOL)hasActiveViewGeneration {
    return self.activeViewSequenceIDs.count > 0;
}

- (BOOL)isDeliveringViewGeneration {
    return self.deliveringViewSequenceID != 0;
}

- (BOOL)isDeliveringCurrentViewGeneration {
    return self.deliveringViewSequenceID != 0
        && self.deliveringViewEpoch == self.viewCancellationEpoch
        && self.deliveringViewSequenceID == self.latestViewSequenceID;
}

- (BOOL)isDeliveringSystemGeneration {
    return self.deliveringSystemGenerationID != 0;
}

- (BOOL)isDeliveringCurrentSystemGeneration {
    return self.hasSystemGeneration
        && self.deliveringSystemGenerationID != 0
        && self.deliveringSystemGenerationID == self.systemGenerationID;
}

@end

@interface BODemoLegacyMoveToken : NSObject
@property (nonatomic, assign) BOOL animated;
@property (nonatomic, assign) BOOL resolved;
@property (nonatomic, copy, nullable) void (^completion)(CGFloat finalDisplayHeight);
@end

@implementation BODemoLegacyMoveToken
@end

@implementation BODemoLegacyConfiguration

- (instancetype)init {
    self = [super init];
    if (self) {
        _handoffMode = BODemoLegacyHandoffModeCoordinated;
        _innerPlacement = BODemoLegacyInnerPlacementAutomatic;
        _offsetMismatch = BODemoLegacyOffsetMismatchWait;
        _allowsPanelTopBounce = YES;
        _allowsPanelBottomBounce = YES;
        _preferredTopBounceOwner = BODemoLegacyBounceOwnerPanel;
        _preferredBottomBounceOwner = BODemoLegacyBounceOwnerInnerScrollView;
        _recognizesSimultaneouslyWithOtherGestures = YES;
        _failsOtherTapDuringDeceleration = YES;
        _automaticallyShowsInnerIndicator = YES;
        _defaultMovementStyle = BODemoLegacyMovementStyleSystemScroll;
        _animationSpeed = 1000;
        _baseAnimationDuration = 0.12;
        _maximumAnimationDuration = 0.32;
        _usesSpring = YES;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    BODemoLegacyConfiguration *copy = [[[self class] allocWithZone:zone] init];
    copy.handoffMode = self.handoffMode;
    copy.innerPlacement = self.innerPlacement;
    copy.innerPlacementHeight = self.innerPlacementHeight;
    copy.offsetMismatch = self.offsetMismatch;
    copy.preventsInnerToPanelHandoff = self.preventsInnerToPanelHandoff;
    copy.resistsCollapse = self.resistsCollapse;
    copy.allowsPanelTopBounce = self.allowsPanelTopBounce;
    copy.allowsPanelBottomBounce = self.allowsPanelBottomBounce;
    copy.preferredTopBounceOwner = self.preferredTopBounceOwner;
    copy.preferredBottomBounceOwner = self.preferredBottomBounceOwner;
    copy.forcesInnerTopBounce = self.forcesInnerTopBounce;
    copy.ignoresMultipleNestedWebScrollViews = self.ignoresMultipleNestedWebScrollViews;
    copy.disablesPanelInteractionInWebView = self.disablesPanelInteractionInWebView;
    copy.recognizesSimultaneouslyWithOtherGestures = self.recognizesSimultaneouslyWithOtherGestures;
    copy.failsOtherTapDuringDeceleration = self.failsOtherTapDuringDeceleration;
    copy.automaticallyShowsInnerIndicator = self.automaticallyShowsInnerIndicator;
    copy.defaultMovementStyle = self.defaultMovementStyle;
    copy.animationSpeed = self.animationSpeed;
    copy.baseAnimationDuration = self.baseAnimationDuration;
    copy.maximumAnimationDuration = self.maximumAnimationDuration;
    copy.usesSpring = self.usesSpring;
    copy.defersDisplayHeightUpdates = self.defersDisplayHeightUpdates;
    copy.animatesDeferredDisplayHeightUpdates = self.animatesDeferredDisplayHeightUpdates;
    return copy;
}

@end

@interface BODemoLegacyDragHost () <BODragScrollViewDelegate>
@property (nonatomic, strong) BODemoLegacyTrackedDragView *legacyView;
@property (nonatomic, strong, nullable) UIView *exposedPanelView;
@property (nonatomic, assign) BODemoLegacyMovementStyle activeMovementStyle;
@property (nonatomic, assign) BOOL forcesSettleSnapping;
@property (nonatomic, assign) BOOL isRelayoutingPanel;
@property (nonatomic, assign) BOOL didCloseRelayoutDeceleration;
@property (nonatomic, assign) BOOL isClosingSupersededLegacyMotion;
@property (nonatomic, assign) NSUInteger movementRequestEpoch;
@property (nonatomic, assign) NSUInteger executingMoveRequestEpoch;
@property (nonatomic, strong) NSMutableArray<BODemoLegacyMoveToken *> *pendingMoveTokens;
@property (nonatomic, strong, nullable) BODemoLegacyMoveToken *activeMovementToken;
@end

@implementation BODemoLegacyDragHost

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super init];
    if (self) {
        _legacyView = [[BODemoLegacyTrackedDragView alloc] initWithFrame:frame];
        _legacyView.dragScrollDelegate = self;
        _configuration = [[BODemoLegacyConfiguration alloc] init];
        _detentHeights = @[];
        _nonSnappingRanges = @[];
        _activeMovementStyle = BODemoLegacyMovementStyleAutomatic;
        _pendingMoveTokens = [NSMutableArray array];
        [self applyConfiguration];
    }
    return self;
}

- (void)dealloc {
    [self invalidate];
}

- (UIScrollView *)scrollView { return self.legacyView; }
- (UIView *)panelView { return self.exposedPanelView; }
- (void)setPanelView:(UIView *)panelView {
    if (!self.exposedPanelView && !panelView) { return; }
    if (!panelView) {
        // The original nullable setter calls -addSubview:nil and crashes. Detach the visible panel
        // and disable interaction instead; assigning a later non-nil panel through the original
        // setter safely replaces its retained (but detached) reference.
        [self.exposedPanelView removeFromSuperview];
        self.exposedPanelView = nil;
        self.legacyView.userInteractionEnabled = NO;
        return;
    }
    self.exposedPanelView = panelView;
    self.legacyView.userInteractionEnabled = YES;
    self.legacyView.embedView = panelView;
}
- (CGFloat)displayHeight {
    return self.exposedPanelView ? self.legacyView.currDisplayH : 0;
}
- (BOOL)isAnimatingDisplayHeight {
    // The original toggles `isScrollAnimating` inside each UIView animation block. Starting a
    // replacement animation can let the interrupted block's completion set that bit back to NO
    // while the replacement is still active. The adapter-owned token is the reliable public
    // transaction lifetime for programmatic moves.
    return self.legacyView.animationSetting
        || self.legacyView.hasActiveViewGeneration
        || self.activeMovementToken != nil;
}

- (BOOL)legacyHasPendingSystemScrollAnimation {
    // This temporary comparison adapter is intentionally coupled to the bundled, byte-identical
    // source implementation. KVC reads its private wait flag without modifying that source, so a
    // relayout only synthesizes the terminal delegate callback that UIKit may omit for a genuinely
    // cancelled animated content-offset operation.
    return [[self.legacyView valueForKey:@"waitMayAnimationScroll"] boolValue];
}

- (void)setDetentHeights:(NSArray<NSNumber *> *)detentHeights {
    _detentHeights = [detentHeights copy] ?: @[];
    self.legacyView.attachDisplayHAr = _detentHeights.count > 0 ? _detentHeights : nil;
}

- (void)setNonSnappingRanges:(NSArray<NSValue *> *)nonSnappingRanges {
    _nonSnappingRanges = [nonSnappingRanges copy] ?: @[];
    self.legacyView.misAttachRangeAr = _nonSnappingRanges.count > 0 ? _nonSnappingRanges : nil;
}

- (void)setMinimumDisplayHeight:(NSNumber *)minimumDisplayHeight {
    _minimumDisplayHeight = minimumDisplayHeight;
    self.legacyView.minDisplayH = minimumDisplayHeight;
}

- (void)setConfiguration:(BODemoLegacyConfiguration *)configuration {
    _configuration = [configuration copy] ?: [[BODemoLegacyConfiguration alloc] init];
    [self applyConfiguration];
}

- (void)applyConfiguration {
    BODemoLegacyConfiguration *configuration = self.configuration;
    BODragScrollView *view = self.legacyView;

    view.innerScrollViewFirst = NO;
    view.innerScrollViewFirstButCanDrag = NO;
    if (configuration.handoffMode == BODemoLegacyHandoffModeInnerFirst) {
        view.innerScrollViewFirst = YES;
    } else if (configuration.handoffMode == BODemoLegacyHandoffModeInnerFirstAtBoundary) {
        view.innerScrollViewFirstButCanDrag = YES;
    }

    view.prefDragInnerScroll = NO;
    view.prefDragCardWhenExpand = NO;
    view.prefDragInnerScrollDisplayH = nil;
    if (configuration.innerPlacement == BODemoLegacyInnerPlacementAfterFullyDisplayed) {
        view.prefDragCardWhenExpand = YES;
    } else if (configuration.innerPlacement == BODemoLegacyInnerPlacementAtDisplayHeight) {
        view.prefDragInnerScrollDisplayH = @(configuration.innerPlacementHeight);
    } else if (configuration.innerPlacement == BODemoLegacyInnerPlacementFromTouchedPosition) {
        view.prefDragInnerScroll = YES;
    }

    view.autoResetInnerSVOffsetWhenAttachMiss = configuration.offsetMismatch == BODemoLegacyOffsetMismatchRestore;
    view.allowInnerSVWhenAttachMiss = configuration.offsetMismatch == BODemoLegacyOffsetMismatchContinue;
    view.disableInnerScrollToOut = configuration.preventsInnerToPanelHandoff;
    view.shrinkResistance = configuration.resistsCollapse;

    view.allowBouncesCardTop = configuration.allowsPanelTopBounce;
    view.allowBouncesCardBottom = configuration.allowsPanelBottomBounce;
    view.prefBouncesCardTop = configuration.preferredTopBounceOwner == BODemoLegacyBounceOwnerPanel;
    view.prefBouncesCardBottom = configuration.preferredBottomBounceOwner == BODemoLegacyBounceOwnerPanel;
    view.forceBouncesInnerTop = configuration.forcesInnerTopBounce;

    view.ignoreWebMulInnerScroll = configuration.ignoresMultipleNestedWebScrollViews;
    view.inhibitPanelForWebView = configuration.disablesPanelInteractionInWebView;
    view.shouldSimultaneouslyWithOtherGesture = configuration.recognizesSimultaneouslyWithOtherGestures;
    view.shouldFailureOtherTapGestureWhenDecelerating = configuration.failsOtherTapDuringDeceleration;
    view.autoShowInnerIndictor = configuration.automaticallyShowsInnerIndicator;

    view.defaultDecelerateStyle = [self legacyStyleForDemoStyle:configuration.defaultMovementStyle];
    view.caAnimationSpeed = configuration.animationSpeed;
    view.caAnimationBaseDur = configuration.baseAnimationDuration;
    view.caAnimationMaxDur = configuration.maximumAnimationDuration;
    view.caAnimationUseSpring = configuration.usesSpring;
    view.delayCallDisplayHChangeWhenAnimation = configuration.defersDisplayHeightUpdates;
    view.needsAnimationWhenDelayCall = configuration.animatesDeferredDisplayHeightUpdates;
}

- (BODragScrollDecelerateStyle)legacyStyleForDemoStyle:(BODemoLegacyMovementStyle)style {
    switch (style) {
        case BODemoLegacyMovementStyleSystemScroll: return BODragScrollDecelerateStyleNature;
        case BODemoLegacyMovementStyleViewAnimation: return BODragScrollDecelerateStyleCAAnimation;
        case BODemoLegacyMovementStyleAutomatic: return BODragScrollDecelerateStyleDefault;
    }
}

- (CGFloat)visibleDisplayHeight {
    UIView *panelView = self.exposedPanelView;
    if (!panelView) { return 0; }

    CALayer *hostLayer = self.legacyView.layer.presentationLayer ?: self.legacyView.layer;
    CALayer *panelLayer = panelView.layer.presentationLayer ?: panelView.layer;
    CGFloat visibleHeight = CGRectGetHeight(hostLayer.bounds)
        - (CGRectGetMinY(panelLayer.frame) - CGRectGetMinY(hostLayer.bounds));
    return isfinite(visibleHeight) ? visibleHeight : self.displayHeight;
}

- (NSArray *)detachMoveTokens:(NSArray<BODemoLegacyMoveToken *> *)tokens
                       notify:(BOOL)notify {
    // Detach every token before invoking any client completion. A completion is allowed to start a
    // new movement; it must never observe half of the superseded token set still installed.
    NSMutableArray *callbacks = [NSMutableArray array];
    for (BODemoLegacyMoveToken *token in tokens) {
        if (!token || token.resolved) { continue; }
        token.resolved = YES;
        [self.pendingMoveTokens removeObjectIdenticalTo:token];
        if (self.activeMovementToken == token) {
            self.activeMovementToken = nil;
            self.activeMovementStyle = BODemoLegacyMovementStyleAutomatic;
        }
        void (^completion)(CGFloat) = token.completion;
        token.completion = nil;
        if (notify && completion) { [callbacks addObject:[completion copy]]; }
    }
    return callbacks;
}

- (void)notifyMoveCallbacks:(NSArray *)callbacks height:(CGFloat)height {
    for (id callbackObject in callbacks) {
        void (^callback)(CGFloat) = callbackObject;
        callback(height);
    }
}

- (void)resolveMoveToken:(BODemoLegacyMoveToken *)token
                  height:(CGFloat)height
                  notify:(BOOL)notify {
    if (!token) { return; }
    NSArray *callbacks = [self detachMoveTokens:@[token] notify:notify];
    [self notifyMoveCallbacks:callbacks height:height];
}

- (void)resolveAllMoveTokensAtHeight:(CGFloat)height notify:(BOOL)notify {
    [self resolveMoveTokens:[self.pendingMoveTokens copy] height:height notify:notify];
}

- (void)resolveMoveTokens:(NSArray<BODemoLegacyMoveToken *> *)tokens
                   height:(CGFloat)height
                   notify:(BOOL)notify {
    NSArray *callbacks = [self detachMoveTokens:tokens notify:notify];
    [self notifyMoveCallbacks:callbacks height:height];
}

- (CGPoint)presentationContentOffset {
    CALayer *presentationLayer = self.legacyView.layer.presentationLayer;
    CGPoint offset = presentationLayer ? presentationLayer.bounds.origin : self.legacyView.contentOffset;
    if (!isfinite(offset.x) || !isfinite(offset.y)) {
        return self.legacyView.contentOffset;
    }
    return offset;
}

- (void)retireViewAnimationOwnershipPreservingPresentation {
    if (!self.legacyView.hasActiveViewGeneration) { return; }
    CGPoint preservedOffset = [self presentationContentOffset];
    [self.legacyView invalidateViewGenerations];
    [self.legacyView.layer removeAllAnimations];
    [self.exposedPanelView.layer removeAllAnimations];
    self.legacyView.isScrollAnimating = NO;
    [self.legacyView setContentOffset:preservedOffset animated:NO];
}

- (void)retirePendingSystemOwnership {
    BOOL wasWaitingForSystem = [self legacyHasPendingSystemScrollAnimation];
    BOOL hadTrackedSystemOwnership = self.legacyView.hasSystemGeneration;
    void (^systemCompletion)(void) = nil;
    if (wasWaitingForSystem) {
        systemCompletion = [self.legacyView valueForKey:@"animationScrollDidEndBlock"];
    }
    if (wasWaitingForSystem || hadTrackedSystemOwnership) {
        [self.legacyView armCancelledSystemGeneration];
    }
    if (wasWaitingForSystem) {
        [self.legacyView setContentOffset:[self presentationContentOffset] animated:NO];
    }

    if (wasWaitingForSystem) {
        // Match the source's own system→system ownership handoff: clear the old wait/block without
        // manufacturing didTarget/didEnd callbacks or a tap-repair timestamp for a programmatic
        // replacement. Any adapter token was already detached before this block runs.
        [self.legacyView setValue:@NO forKey:@"waitMayAnimationScroll"];
        [self.legacyView setValue:nil forKey:@"animationScrollDidEndBlock"];
        if (systemCompletion) { systemCompletion(); }
    }
}

- (void)retirePendingSystemAndDecelerationOwnership {
    BOOL wasDecelerating = self.legacyView.isDecelerating;
    if (wasDecelerating) {
        // Arm before stopping a simultaneous system animation so a synchronous old deceleration
        // callback cannot enter the byte-identical source with the next owner's shared state.
        [self.legacyView armCancelledDecelerationGeneration];
    }
    [self retirePendingSystemOwnership];
    if (wasDecelerating) {
        [self.legacyView setContentOffset:[self presentationContentOffset] animated:NO];
        self.isClosingSupersededLegacyMotion = YES;
        [self.legacyView forceSuperDidEndDecelerating];
        self.isClosingSupersededLegacyMotion = NO;
    }
}

- (CGFloat)moveToDisplayHeight:(CGFloat)displayHeight
                      animated:(BOOL)animated
                         style:(BODemoLegacyMovementStyle)style
                       subInfo:(NSDictionary<NSString *,NSNumber *> *)subInfo
                    completion:(void (^)(CGFloat))completion {
    if (!self.exposedPanelView) {
        if (completion) { completion(0); }
        return 0;
    }

    NSUInteger requestEpoch = ++self.movementRequestEpoch;
    CGFloat interruptedHeight = [self visibleDisplayHeight];
    NSArray *supersededCallbacks = [self detachMoveTokens:[self.pendingMoveTokens copy]
                                                    notify:YES];
    [self retirePendingSystemAndDecelerationOwnership];
    if (!animated || style == BODemoLegacyMovementStyleSystemScroll) {
        [self retireViewAnimationOwnershipPreservingPresentation];
    }
    [self notifyMoveCallbacks:supersededCallbacks height:interruptedHeight];
    // A superseded completion may synchronously author a newer transaction. In that case this
    // outer request has lost ownership and must not start after the newer one.
    if (requestEpoch != self.movementRequestEpoch) {
        return [self visibleDisplayHeight];
    }

    BODemoLegacyMoveToken *token = [BODemoLegacyMoveToken new];
    token.animated = animated;
    token.completion = completion;
    [self.pendingMoveTokens addObject:token];
    self.activeMovementToken = token;
    self.activeMovementStyle = style;
    __weak typeof(self) weakSelf = self;
    NSUInteger previousExecutingRequest = self.executingMoveRequestEpoch;
    self.executingMoveRequestEpoch = requestEpoch;
    CGFloat result = [self.legacyView scrollToDisplayH:displayHeight
                                              animated:animated
                                               subInfo:subInfo
                                            completion:^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) { return; }
        if (self.isRelayoutingPanel) { return; }
        if (token.resolved) { return; }
        CGFloat finalHeight = token.animated ? [self visibleDisplayHeight] : self.displayHeight;
        [self resolveMoveToken:token height:finalHeight notify:YES];
    }];
    self.executingMoveRequestEpoch = previousExecutingRequest;
    return result;
}

- (CGFloat)settleToNearestDetentAnimated:(BOOL)animated
                                   style:(BODemoLegacyMovementStyle)style
                                 subInfo:(NSDictionary<NSString *,NSNumber *> *)subInfo
                              completion:(void (^)(CGFloat, CGFloat))completion {
    CGFloat currentHeight = self.displayHeight;
    if (!self.exposedPanelView || self.detentHeights.count == 0) {
        if (completion) { completion(currentHeight, currentHeight); }
        return currentHeight;
    }

    CGPoint currentOffset = self.legacyView.contentOffset;
    CGPoint targetOffset = currentOffset;
    BODemoLegacyAttachInfo attachInfo = {0};
    self.forcesSettleSnapping = YES;
    [self.legacyView __scrollViewWillEndDragging:self.legacyView
                                    withVelocity:CGPointZero
                             targetContentOffset:&targetOffset
                                      attachInfo:&attachInfo];
    self.forcesSettleSnapping = NO;

    // Mirror the original -takeAttach: decision while executing the actual movement through the
    // adapter-owned completion. This avoids guessing transaction ownership from untagged legacy
    // willTarget/didTarget callbacks when animations overlap.
    if (fabs(targetOffset.y - currentOffset.y) <= 0.01) {
        if (completion) { completion(currentHeight, currentHeight); }
        return currentHeight;
    }

    CGFloat requestedHeight = attachInfo.displayH;
    return [self moveToDisplayHeight:requestedHeight
                            animated:animated
                               style:style
                             subInfo:subInfo
                          completion:^(CGFloat finalDisplayHeight) {
        if (completion) { completion(requestedHeight, finalDisplayHeight); }
    }];
}

- (void)invalidatePanelLayout {
    UIView *panelView = self.exposedPanelView;
    if (!panelView) { return; }

    // The original public contract explicitly requires assigning embedView again when its desired
    // size changes. Freeze the presentation state first so a safe-area change during an animation
    // preserves what is actually visible rather than jumping through the animation's model target.
    CGFloat logicalDisplayHeightBeforeRelayout = self.displayHeight;
    CGFloat preservedDisplayHeight = [self visibleDisplayHeight];
    BOOL wasWaitingForSystemScrollAnimation = [self legacyHasPendingSystemScrollAnimation];
    self.isRelayoutingPanel = YES;
    self.didCloseRelayoutDeceleration = NO;
    [self.legacyView invalidateViewGenerations];
    BOOL wasDecelerating = self.legacyView.isDecelerating;
    void (^systemCompletion)(void) = wasWaitingForSystemScrollAnimation
        ? [self.legacyView valueForKey:@"animationScrollDidEndBlock"]
        : nil;
    if (wasDecelerating) {
        [self.legacyView armCancelledDecelerationGeneration];
    }
    if (wasWaitingForSystemScrollAnimation) {
        [self.legacyView armCancelledSystemGeneration];
    }
    [self.legacyView setContentOffset:[self presentationContentOffset] animated:NO];
    if (wasDecelerating && !self.didCloseRelayoutDeceleration) {
        // Closing the original delegate lifecycle explicitly also clears its untagged pending
        // drag target; UIKit does not guarantee this callback after a forced stop.
        [self.legacyView forceSuperDidEndDecelerating];
    }
    if (wasWaitingForSystemScrollAnimation) {
        // A viewport cancellation is not a user touch. Clear the exact private wait/block used by
        // the bundled source without synthesizing its touch-interruption timestamp or terminals.
        [self.legacyView setValue:@NO forKey:@"waitMayAnimationScroll"];
        [self.legacyView setValue:nil forKey:@"animationScrollDidEndBlock"];
        if (systemCompletion) { systemCompletion(); }
    }
    self.legacyView.isScrollAnimating = NO;
    [self.legacyView.layer removeAllAnimations];
    [panelView.layer removeAllAnimations];
    self.legacyView.embedView = panelView;
    [self.legacyView layoutIfNeeded];
    // Rotation can shrink the legal viewport while the presentation layer still reports the old
    // portrait height. Never feed that stale value back into the original unrestricted
    // scrollToDisplayH API: doing so moves the host beyond the now-smaller panel even though the
    // panel frame itself was laid out correctly.
    CGFloat maximumDisplayHeight = CGRectGetHeight(panelView.bounds);
    NSNumber *highestDetent = self.detentHeights.lastObject;
    if (highestDetent) {
        maximumDisplayHeight = MIN(maximumDisplayHeight, highestDetent.doubleValue);
    }
    CGFloat targetDisplayHeight = MIN(MAX(0, preservedDisplayHeight), maximumDisplayHeight);
    [self.legacyView scrollToDisplayH:targetDisplayHeight animated:NO];
    CGFloat restoredHeight = CGRectGetHeight(self.legacyView.bounds)
        - (CGRectGetMinY(panelView.frame) - CGRectGetMinY(self.legacyView.bounds));
    restoredHeight = MIN(MAX(0, restoredHeight), maximumDisplayHeight);
    self.legacyView.currDisplayH = restoredHeight;
    NSArray<BODemoLegacyMoveToken *> *interruptedTokens = [self.pendingMoveTokens copy];
    self.isRelayoutingPanel = NO;
    if (fabs(restoredHeight - logicalDisplayHeightBeforeRelayout) > 0.01) {
        [self.delegate legacyDragHost:self didChangeDisplayHeight:restoredHeight];
    }
    [self resolveMoveTokens:interruptedTokens height:restoredHeight notify:YES];
}

- (void)reloadScrollMetrics {
    // This method is internal in the original implementation. It is called only by this temporary
    // comparison adapter so dynamic-content demos can start from equivalent snapshots.
    [self.legacyView forceReloadCurrInnerScrollView];
}

- (BOOL)performAccessibilityScroll:(UIAccessibilityScrollDirection)direction {
    NSUInteger requestEpoch = ++self.movementRequestEpoch;
    CGFloat interruptedHeight = [self visibleDisplayHeight];
    NSArray *callbacks = [self detachMoveTokens:[self.pendingMoveTokens copy] notify:YES];
    [self retirePendingSystemAndDecelerationOwnership];
    [self notifyMoveCallbacks:callbacks height:interruptedHeight];
    if (requestEpoch != self.movementRequestEpoch) { return YES; }
    return [self.legacyView accessibilityScroll:direction];
}

- (void)invalidate {
    [self resolveAllMoveTokensAtHeight:self.displayHeight notify:NO];
    self.legacyView.dragScrollDelegate = nil;
    self.panelView = nil;
    [self.legacyView removeFromSuperview];
}

#pragma mark - Original behavior delegate

- (CGSize)dragScrollView:(BODragScrollView *)dragScrollView
         layoutEmbedView:(UIView *)embedView
             firstLayout:(BOOL)firstLayout
          willShowHeight:(CGFloat *)willShowHeight {
    CGSize size = [self.delegate legacyDragHost:self
                              sizeForPanelView:embedView
                                   firstLayout:firstLayout
                         proposedDisplayHeight:willShowHeight];
    CGFloat maximum = CGRectGetHeight(dragScrollView.bounds);
    size.width = MIN(MAX(0, size.width), CGRectGetWidth(dragScrollView.bounds));
    size.height = MIN(MAX(0, size.height), maximum);
    *willShowHeight = MIN(MAX(0, *willShowHeight), size.height);
    return size;
}

- (NSArray<NSDictionary *> *)dragScrollView:(BODragScrollView *)dragScrollView
                   scrollBehaviorForInnerSV:(UIScrollView *)innerSV {
    return [self.delegate legacyDragHost:self segmentsForScrollView:innerSV];
}

- (BOOL)dragScrollView:(BODragScrollView *)dragScrollView canCatchInnerSV:(UIScrollView *)sv {
    return [self.delegate legacyDragHost:self canCaptureScrollView:sv];
}

- (void)dragScrollView:(BODragScrollView *)dragScrollView
  catchAndPriorityInfo:(NSMutableDictionary *)catchAndPriorityInfo {
    NSDictionary *adjustments = [self.delegate legacyDragHost:self
                                            adjustCaptureInfo:[catchAndPriorityInfo copy]];
    if (![adjustments isKindOfClass:[NSDictionary class]]) { return; }

    NSArray *behaviors = catchAndPriorityInfo[@"otherSVBehaviorAr"];
    UIScrollView *adjustedPrimary = adjustments[@"catchSV"];
    if ([adjustedPrimary isKindOfClass:[UIScrollView class]]) {
        BOOL isKnownCandidate = adjustedPrimary == catchAndPriorityInfo[@"catchSV"];
        for (NSDictionary *behavior in behaviors) {
            if (behavior[@"sv"] == adjustedPrimary) {
                isKnownCandidate = YES;
                break;
            }
        }
        if (isKnownCandidate) { catchAndPriorityInfo[@"catchSV"] = adjustedPrimary; }
    }

    NSArray *priorityAdjustments = adjustments[@"candidatePriorities"];
    for (NSMutableDictionary *behavior in behaviors) {
        if (![behavior isKindOfClass:[NSMutableDictionary class]]) { continue; }
        UIScrollView *scrollView = behavior[@"sv"];
        for (NSDictionary *adjustment in priorityAdjustments) {
            if (adjustment[@"sv"] == scrollView
                && [adjustment[@"priority"] isKindOfClass:[NSNumber class]]) {
                behavior[@"priority"] = adjustment[@"priority"];
                break;
            }
        }
    }
}

- (NSInteger)dragScrollView:(BODragScrollView *)dragScrollView
    recognizeStrategyForGes:(UIGestureRecognizer *)ges
                   otherGes:(UIGestureRecognizer *)otherGes {
    BODemoLegacyGestureStrategy strategy = [self.delegate legacyDragHost:self
                                                      strategyForGesture:ges
                                                            otherGesture:otherGes];
    return strategy == BODemoLegacyGestureStrategyDefault ? NSNotFound : strategy;
}

- (BODragScrollDecelerateStyle)dragScrollViewDecelerate:(BODragScrollView *)dragScrollView
                                                  fromH:(CGFloat)fromH
                                                    toH:(CGFloat)toH
                                                 reason:(NSString *)reason {
    BODemoLegacyMovementStyle style = self.activeMovementStyle;
    if (style == BODemoLegacyMovementStyleAutomatic) {
        style = [self.delegate legacyDragHost:self
                      movementStyleFromHeight:fromH
                                     toHeight:toH
                                       reason:reason];
    }
    BODemoLegacyMovementStyle resolvedStyle = style;
    if (resolvedStyle == BODemoLegacyMovementStyleAutomatic) {
        resolvedStyle = self.configuration.defaultMovementStyle;
    }
    if (resolvedStyle == BODemoLegacyMovementStyleSystemScroll) {
        // The actual driver is known only after the source asks its delegate for automatic style.
        // Retire any older UIView generation before UIKit takes system-scroll ownership.
        [self retireViewAnimationOwnershipPreservingPresentation];
    }
    return [self legacyStyleForDemoStyle:style];
}

- (NSNumber *)dragScrollView:(BODragScrollView *)dragScrollView
         accessibilityScroll:(UIAccessibilityScrollDirection)direction {
    BODemoLegacyAccessibilityDisposition disposition =
        [self.delegate legacyDragHost:self accessibilityDispositionFor:direction];
    if (disposition == BODemoLegacyAccessibilityDispositionAutomatic) { return nil; }
    return @(disposition == BODemoLegacyAccessibilityDispositionHandled);
}

- (BOOL)dragScrollView:(BODragScrollView *)dragScrollView
   shouldMisAttachForH:(CGFloat)displayHeight {
    if (self.forcesSettleSnapping) { return NO; }

    NSNumber *decision = [self.delegate legacyDragHost:self shouldBypassDetentsAt:displayHeight];
    if (decision) { return decision.boolValue; }

    CGFloat epsilon = 1.0 / MAX(UIScreen.mainScreen.scale, 1.0);
    for (NSValue *value in self.nonSnappingRanges) {
        CGPoint range = value.CGPointValue;
        if (displayHeight > range.x - epsilon && displayHeight < range.y + epsilon) {
            return YES;
        }
    }
    return NO;
}

#pragma mark - Original events

- (void)dragScrollView:(BODragScrollView *)dragScrollView displayHDidChange:(CGFloat)displayH {
    if (self.isRelayoutingPanel) { return; }
    [self.delegate legacyDragHost:self didChangeDisplayHeight:displayH];
}

- (void)dragScrollView:(BODragScrollView *)dragScrollView didScroll:(CGFloat)displayH isInner:(BOOL)isInner {
    if (self.isRelayoutingPanel) { return; }
    [self.delegate legacyDragHost:self didScrollToDisplayHeight:displayH isInner:isInner];
}

- (void)dragScrollView:(BODragScrollView *)dragScrollView willTargetToH:(CGFloat)height reason:(NSString *)reason {
    if (self.isRelayoutingPanel) { return; }
    [self.delegate legacyDragHost:self willMoveToDisplayHeight:height reason:reason ?: @"legacy"];
}

- (void)dragScrollView:(BODragScrollView *)dragScrollView didTargetToH:(CGFloat)height reason:(NSString *)reason {
    if (self.isRelayoutingPanel || self.isClosingSupersededLegacyMotion) { return; }
    if (self.legacyView.isDeliveringViewGeneration
        && !self.legacyView.isDeliveringCurrentViewGeneration) { return; }
    if (self.legacyView.isDeliveringSystemGeneration
        && !self.legacyView.isDeliveringCurrentSystemGeneration) { return; }
    if (self.executingMoveRequestEpoch != 0
        && self.executingMoveRequestEpoch != self.movementRequestEpoch) { return; }
    [self.delegate legacyDragHost:self didMoveToDisplayHeight:height reason:reason ?: @"legacy"];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    ++self.movementRequestEpoch;
    CGFloat interruptedHeight = [self visibleDisplayHeight];
    NSArray *callbacks = [self detachMoveTokens:[self.pendingMoveTokens copy] notify:YES];
    [self retirePendingSystemOwnership];
    [self.legacyView invalidateViewGenerations];
    [self notifyMoveCallbacks:callbacks height:interruptedHeight];
    if (!self.activeMovementToken) {
        self.activeMovementStyle = BODemoLegacyMovementStyleAutomatic;
    }
    [self.delegate legacyDragHostWillBeginDragging:self];
}

- (void)scrollViewWillEndDragging:(UIScrollView *)scrollView
                     withVelocity:(CGPoint)velocity
              targetContentOffset:(inout CGPoint *)targetContentOffset {
    [self.delegate legacyDragHost:self
    adjustTargetContentOffset:targetContentOffset
                     velocity:velocity];
    [self.delegate legacyDragHost:self
         willEndDraggingWithVelocity:velocity
      resolvedTargetContentOffset:*targetContentOffset];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    [self.delegate legacyDragHost:self didEndDraggingWillDecelerate:decelerate];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    if (self.isClosingSupersededLegacyMotion) { return; }
    if (self.isRelayoutingPanel) {
        self.didCloseRelayoutDeceleration = YES;
        return;
    }
    [self.delegate legacyDragHostDidEndDecelerating:self];
}

- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView {
    if (self.isRelayoutingPanel || self.isClosingSupersededLegacyMotion) { return; }
    if (self.legacyView.isDeliveringSystemGeneration
        && !self.legacyView.isDeliveringCurrentSystemGeneration) { return; }
    [self.delegate legacyDragHostDidEndScrollingAnimation:self];
}

- (void)scrollViewDidScrollToTop:(UIScrollView *)scrollView {
    [self.delegate legacyDragHostDidScrollToTop:self];
}

- (BOOL)scrollViewShouldScrollToTop:(UIScrollView *)scrollView {
    return [self.delegate legacyDragHostShouldScrollToTop:self];
}

@end
