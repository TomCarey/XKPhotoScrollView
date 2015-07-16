//
//  XKPhotoScrollView.m
//  XKPhotoScrollView
//
//  Created by Karl von Randow on 2/08/08.
//  Copyright 2008 XK72 Ltd. All rights reserved.
//

#import "XKPhotoScrollView.h"

#import "XKCGUtils.h"

#import <UIKit/UIGestureRecognizerSubclass.h>

#define DEBUG_PHOTO_SCROLL_VIEW
#undef DEBUG_PHOTO_SCROLL_VIEW

typedef NS_ENUM(NSInteger, XKPhotoScrollViewTouchMode) {
	XKPhotoScrollViewTouchModeNone,
	XKPhotoScrollViewTouchModeDragging,
	XKPhotoScrollViewTouchModeZooming
};

typedef NS_ENUM(NSInteger, XKPhotoScrollViewDragAxis) {
	XKPhotoScrollViewDragAxisNone,
	XKPhotoScrollViewDragAxisVertical,
	XKPhotoScrollViewDragAxisHorizontal
};

typedef NS_ENUM(NSInteger, XKPhotoScrollViewRevealMode) {
	XKPhotoScrollViewRevealModeNone,
	XKPhotoScrollViewRevealModeUp,
	XKPhotoScrollViewRevealModeDown,
	XKPhotoScrollViewRevealModeRight,
	XKPhotoScrollViewRevealModeLeft
};

#define kRevealGutter  40

@interface XKPhotoScrollView ()

- (BOOL)startTouches:(NSSet *)touches;
- (BOOL)moveTouches:(NSSet *)touches event:(UIEvent *)event;
- (void)finishedTouches:(NSSet *)touches;
- (BOOL)endTouches:(NSSet *)touches;

@end

@implementation XKPhotoScrollViewGestureRecognizer

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
    [_photoScrollView startTouches:[event allTouches]];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
    if ([_photoScrollView moveTouches:touches event:event]) {
        if (self.state == UIGestureRecognizerStatePossible) {
            self.state = UIGestureRecognizerStateBegan;
        } else {
            self.state = UIGestureRecognizerStateChanged;
        }
    }
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
    if ([_photoScrollView endTouches:touches]) {
        self.state = UIGestureRecognizerStateEnded;
    }
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event
{
    if ([_photoScrollView endTouches:touches]) {
        self.state = UIGestureRecognizerStateCancelled;
    }
}

@end

@implementation XKPhotoScrollView {
    CADisplayLink *_displayLink;
    
    XKPhotoScrollViewViewState *_currentViewState;
    XKPhotoScrollViewViewState *_revealViewState;
    XKPhotoScrollViewRevealMode _revealMode;
    
    NSUInteger _cols, _rows;
    
    CGPoint _animationStartCenter;
    CGPoint _animationTargetCenter;
    CGFloat _animationStartScale;
    CGFloat _animationTargetScale;
    NSTimeInterval _animationStartTime;
    NSTimeInterval _animationDuration;
    BOOL _decelerating;
    
    XKPhotoScrollViewTouchMode _touchMode;
    XKPhotoScrollViewTouchMode _lastTouchMode;
    
    int _rotation;
    CGSize _initialSize;
    
    CGPoint _zoomTouchStart;
    CGPoint _zoomCurrentViewStart;
    CGFloat _zoomRadiusStart;
    CGAffineTransform _zoomTransformStart;
    CGFloat _zoomScaleStart;
    CGFloat _zoomScaleTarget;
    CGFloat _zoomMaxScale;
    CGFloat _zoomMinScale;
    
    CGPoint _dragTouchStart;
    CGPoint _dragTouchLast;
    CGPoint _dragCurrentViewStart;
    CGPoint _dragLastVector;
    XKPhotoScrollViewDragAxis _dragAxis;
    BOOL _draggedSomeDistance;
    
    UIView *_placeholderCurrentView;
    UIView *_placeholderRevealView;
    
    NSIndexPath *_request1IndexPath, *_request2IndexPath;
    
    BOOL _cancelledForeignTouches;
    BOOL _owningTouch;
    
    CGPoint _longPressLocationInView, _singleTapLocationInView;
    
    XKPhotoScrollViewGestureRecognizer *_gestureRecognizer;
}

- (instancetype)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame]) != nil) {
		[self setup];
	}
	return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self) {
        [self setup];
    }
    return self;
}

- (void)setup
{
    _initialSize = self.bounds.size;
    
    _animationType = XKPhotoScrollViewAnimationTypeFade;
    
    _currentViewState = [[XKPhotoScrollViewViewState alloc] init];
    _revealViewState = [[XKPhotoScrollViewViewState alloc] init];
    _currentViewState.indexPath = [NSIndexPath indexPathForRow:0 inColumn:0];
    _revealViewState.indexPath = nil;
    _request1IndexPath = _request2IndexPath = nil;
    
    self.multipleTouchEnabled = YES;
    
    self.bouncesZoom = YES;
    self.alwaysBounceScroll = NO;
    self.maximumZoomScale = 3;
    self.minimumZoomScale = 1;
    self.maximumBaseScale = 1;
    self.minimumLongPressDuration = 0.4;
    _minimumDrag = 5;
    
    _placeholderCurrentView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 100, 100)];
    _placeholderRevealView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 100, 100)];
    
    _gestureRecognizer = [XKPhotoScrollViewGestureRecognizer new];
    _gestureRecognizer.photoScrollView = self;
    [self addGestureRecognizer:_gestureRecognizer];
}

- (void)dealloc {
    if (_delegate) {
		NSLog(@"*** WARNING: delegate not nil in dealloc. Please set delegate to nil when releasing.");
	}

	_currentViewState.view = nil;
	_revealViewState.view = nil;

	[_displayLink invalidate];
	_displayLink = nil;
}

#pragma mark Configure views

- (void)updateTransformation:(XKPhotoScrollViewViewState *)viewState {
	CGFloat baseScale = viewState.baseScale;
	CGFloat scale = viewState.scale;

	/* Be careful about scaling by 1.0 as it raises an error message on the device */
	if (scale == 1.0)
		if (baseScale == 1.0 || baseScale == 0.0)
			viewState.view.transform = CGAffineTransformIdentity;
		else
			viewState.view.transform = CGAffineTransformMakeScale(baseScale, baseScale);
	else
		viewState.view.transform = CGAffineTransformScale(CGAffineTransformMakeScale(baseScale, baseScale), scale, scale);

	if ([_delegate respondsToSelector:@selector(photoScrollView:didUpdateTransformationForView:withState:)])
		[_delegate photoScrollView:self didUpdateTransformationForView:viewState.view withState:[viewState copy]];
}

- (CGSize)viewportSize {
	return self.bounds.size;
}

/**
 * Scale the given view so that it is appropriately sized for display in this view.
 */
- (void)configureView:(XKPhotoScrollViewViewState *)viewState andInitialise:(BOOL)initialise {
	if (!viewState.view)
		return;

	CGSize viewportSize = [self viewportSize];
	CGSize viewSize = viewState.view.bounds.size;

	CGFloat baseScaleWidth = (viewportSize.width - _baseInsets.left - _baseInsets.right) / viewSize.width;
	CGFloat baseScaleHeight = (viewportSize.height - _baseInsets.top - _baseInsets.bottom) / viewSize.height;
	CGFloat baseScale = baseScaleWidth < baseScaleHeight ? baseScaleWidth : baseScaleHeight;
    if (baseScale > self.maximumBaseScale) {
		baseScale = self.maximumBaseScale;
    }

    BOOL initialiseCentre = initialise;
    if (viewState.baseScale == 0) {
        /* If the old baseScale was invalid, then we re-centre the view - such as if the view was positioned when the photo scroll view had zero size */
        initialiseCentre = YES;
    }
    
	viewState.baseScale = baseScale;
	// viewState.view.userInteractionEnabled = NO;

    if (initialiseCentre) {
        /* Change the centre of the view to the centre of the viewport and ensure we're on a whole pixel. This
         * must be done in one step as we may be inside an animation block.
         */
        viewState.view.center = CGPointMake(viewportSize.width / 2, viewportSize.height / 2);
    }
	if (initialise) {
		viewState.scale = 1.0;
		viewState.placeholder = YES;
	}

	[self updateTransformation:viewState];
}

#pragma mark Layout

- (void)layoutSubviews
{
    [super layoutSubviews];
    
    const CGRect bounds = self.bounds;
    if (!CGSizeEqualToSize(bounds.size, _initialSize)) {
        const CGSize previousSize = _initialSize;
        _initialSize = bounds.size;
        
        [self configureView:_currentViewState andInitialise:NO];
        [self configureView:_revealViewState andInitialise:NO];
        
        if (!CGSizeEqualToSize(previousSize, CGSizeZero)) {
            if (_currentViewState.view) {
                _currentViewState.view.center = CGPointFromProportional(CGPointMakeProportional(_currentViewState.view.center, previousSize), bounds.size);
                
                [self stabiliseCurrentView:YES];
            }
            if (_revealViewState.view) {
                _revealViewState.view.center = CGPointFromProportional(CGPointMakeProportional(_revealViewState.view.center, previousSize), bounds.size);
            }
        }
    }
}

#pragma mark Getters / Setters

- (XKPhotoScrollViewViewState *)currentViewState {
	return [_currentViewState copy];
}

- (UIView *)currentView {
	return _currentViewState.view;
}

- (CGFloat)baseScale {
	return _currentViewState.baseScale;
}

- (CGFloat)viewScale {
	return _currentViewState.scale;
}

- (void)setViewScale:(CGFloat)scale {
	_currentViewState.scale = scale;
	[self updateTransformation:_currentViewState];
}

- (CGRect)viewFrame {
	return _currentViewState.view.frame;
}

- (CGPoint)viewOffset {
	CGSize viewportSize = [self viewportSize];
	CGPoint baseCenter = CGPointMake(viewportSize.width / 2, viewportSize.height / 2);

	return CGPointMake(_currentViewState.view.center.x - baseCenter.x, _currentViewState.view.center.y - baseCenter.y);
}

- (void)setViewOffset:(CGPoint)c {
	CGSize viewportSize = [self viewportSize];
	CGPoint baseCenter = CGPointMake(viewportSize.width / 2, viewportSize.height / 2);

	_currentViewState.view.center = CGPointMake(baseCenter.x + c.x, baseCenter.y + c.y);
//	[self updateTransformation:&currentView];
}

#pragma mark Animation

- (void)slideAnimateFrom:(XKPhotoScrollViewViewState *)fromState to:(XKPhotoScrollViewViewState *)toState {
    NSIndexPath *fromIndexPath = fromState.indexPath;
    NSIndexPath *toIndexPath = toState.indexPath;
    
	int dirx = toIndexPath.col == fromIndexPath.col ? 0 : toIndexPath.col > fromIndexPath.col ? -1 : 1;
	int diry = toIndexPath.row == fromIndexPath.row ? 0 : toIndexPath.row > fromIndexPath.row ? -1 : 1;

	CGFloat deltax = dirx * (_initialSize.width + kRevealGutter);
	CGFloat deltay = diry * (_initialSize.height + kRevealGutter);

	CGPoint saveToStateCenter = toState.view.center;

	toState.view.center = CGPointOffset(saveToStateCenter, -deltax, -deltay);

    UIView *saveCurrentView = fromState.view;
    [UIView animateWithDuration:0.5
                     animations:^{
                         fromState.view.center = CGPointOffset(fromState.view.center, deltax, deltay);
                         toState.view.center = saveToStateCenter;
                     }
                     completion:^(BOOL finished) {
                         [self setCurrentRowAnimationStoppedForView:saveCurrentView];
                     }];
}

- (void)fadeAnimateFrom:(XKPhotoScrollViewViewState *)fromState to:(XKPhotoScrollViewViewState *)toState {
	toState.view.alpha = 0;

    UIView *saveCurrentView = fromState.view;
    [UIView animateWithDuration:0.5
                     animations:^{
                         fromState.view.alpha = 0;
                         toState.view.alpha = 1;
                     }
                     completion:^(BOOL finished) {
                         [self setCurrentRowAnimationStoppedForView:saveCurrentView];
                     }];
}

- (void)animateFrom:(XKPhotoScrollViewViewState *)fromState to:(XKPhotoScrollViewViewState *)toState {
	if (_animationType == XKPhotoScrollViewAnimationTypeSlide) {
		[self slideAnimateFrom:fromState to:toState];
	} else {
		[self fadeAnimateFrom:fromState to:toState];
	}
}

#pragma mark DataSource

- (void)requestViewAtIndexPath:(NSIndexPath *)indexPath {
	if (!_request1IndexPath) {
        _request1IndexPath = indexPath;
	} else if (!_request2IndexPath) {
        _request2IndexPath = indexPath;
    } else if (![_request1IndexPath isEqual:_currentViewState.indexPath] && ![_request1IndexPath isEqual:_revealViewState.indexPath]) {
        [_dataSource photoScrollView:self cancelRequestAtIndexPath:_request1IndexPath];
        _request1IndexPath = indexPath;
	} else if (![_request2IndexPath isEqual:_currentViewState.indexPath] && ![_request2IndexPath isEqual:_revealViewState.indexPath]) {
		[_dataSource photoScrollView:self cancelRequestAtIndexPath:_request2IndexPath];
        _request2IndexPath = indexPath;
	}
    
	[_dataSource photoScrollView:self requestViewAtIndexPath:indexPath];
}

- (void)cancelRequestAtIndexPath:(NSIndexPath *)indexPath {
    if ([_request1IndexPath isEqual:indexPath]) {
        _request1IndexPath = nil;
		[_dataSource photoScrollView:self cancelRequestAtIndexPath:indexPath];
	} else if ([_request2IndexPath isEqual:indexPath]) {
        _request2IndexPath = nil;
		[_dataSource photoScrollView:self cancelRequestAtIndexPath:indexPath];
	}
}

- (void)reloadData:(BOOL)animated {
	[_currentViewState.view removeFromSuperview];
	[_revealViewState.view removeFromSuperview];
    
    _request1IndexPath = nil;
    _request2IndexPath = nil;
    
	_revealViewState.view = nil;
	_revealMode = XKPhotoScrollViewRevealModeNone;

	_currentViewState.view = _placeholderCurrentView;
	[self configureView:_currentViewState andInitialise:YES];
	[self addSubview:_currentViewState.view];

	_cols = [_dataSource photoScrollViewCols:self];
	_rows = [_dataSource photoScrollViewRows:self];

	if (!animated) {
		if ([_delegate respondsToSelector:@selector(photoScrollView:didChangeToIndexPath:)]) {
            [_delegate photoScrollView:self didChangeToIndexPath:_currentViewState.indexPath];
		}
	}

    [self requestViewAtIndexPath:_currentViewState.indexPath];
}

- (void)reloadData {
	[self reloadData:NO];
}

- (void)setView:(UIView *)view atIndexPath:(NSIndexPath *)indexPath placeholder:(BOOL)placeholder {
	if (![NSThread isMainThread]) {
		[NSException raise:@"XKPhotoScrollView.setView called not on main thread" format:@""];
	}

	if (!placeholder) {
        if ([indexPath isEqual:_request1IndexPath]) {
            _request1IndexPath = nil;
        }
        if ([indexPath isEqual:_request2IndexPath]) {
            _request2IndexPath = nil;
        }
	}

    if ([indexPath isEqual:_currentViewState.indexPath]) {
		/* Only set the view if it's not already set to this one, and only set a placeholder
		 * image if what we already have is a placeholder too.
		 */
		if (_currentViewState.view != view && (!placeholder || _currentViewState.placeholder)) {
			UIView *tmp = _currentViewState.view;

			_currentViewState.view = view;
			_currentViewState.placeholder = placeholder;
			[self configureView:_currentViewState andInitialise:NO];
            _currentViewState.view.center = tmp.center;
            [self addSubview:_currentViewState.view];

			[tmp removeFromSuperview];

			if ([_delegate respondsToSelector:@selector(photoScrollView:didSetCurrentView:withState:)])
				[_delegate photoScrollView:self didSetCurrentView:_currentViewState.view withState:_currentViewState];
#ifdef DEBUG_PHOTO_SCROLL_VIEW
			NSLog(@"SET CURRENT VIEW %@ @ %@ REVEAL %@ @ %@ (mainThread=%i)", _currentViewState.view, _currentViewState.indexPath, _revealViewState.view, _revealViewState.indexPath, [NSThread isMainThread]);
#endif
		}
	} else if ([indexPath isEqual:_revealViewState.indexPath]) {
		if (_revealViewState.view != view && (!placeholder || _revealViewState.placeholder)) {
			UIView *tmp = _revealViewState.view;

			_revealViewState.view = view;
			_revealViewState.placeholder = placeholder;
			[self configureView:_revealViewState andInitialise:NO];
            _revealViewState.view.center = tmp.center;
            [self addSubview:_revealViewState.view];

			[tmp removeFromSuperview];
#ifdef DEBUG_PHOTO_SCROLL_VIEW
			NSLog(@"SET REVEAL VIEW %@ @ %@ CURRENT %@ @ %@ (mainThread=%i)", _revealViewState.view, _revealViewState.indexPath, _currentViewState.view, _currentViewState.indexPath, [NSThread isMainThread]);
#endif
		}
	}
}

- (BOOL)wantsViewAtIndexPath:(NSIndexPath *)indexPath {
    if ([indexPath isEqual:_currentViewState.indexPath]) {
        return YES;
    } else if (_revealMode != XKPhotoScrollViewRevealModeNone && [indexPath isEqual:_revealViewState.indexPath]) {
        return YES;
    } else {
        return NO;
    }
}

- (void)setCurrentIndexPath:(NSIndexPath *)currentIndexPath
{
    [self setCurrentIndexPath:currentIndexPath animated:NO];
}

- (void)setCurrentIndexPath:(NSIndexPath *)currentIndexPath animated:(BOOL)animated
{
    if (![currentIndexPath isEqual:_currentViewState.indexPath]) {
		XKPhotoScrollViewViewState *saveCurrentView = [_currentViewState copy];
		_currentViewState.indexPath = currentIndexPath;
		if (animated) {
			_currentViewState.view = nil; /* prevent the view from being removed by reloadData */
			[self reloadData:YES];

			[self animateFrom:saveCurrentView to:_currentViewState];
		} else {
			[self reloadData:NO];
		}
	}
}

- (void)setCurrentRowAnimationStoppedForView:(UIView *)saveCurrentView {
	[saveCurrentView removeFromSuperview];

	if ([_delegate respondsToSelector:@selector(photoScrollView:didChangeToIndexPath:)]) {
		[_delegate photoScrollView:self didChangeToIndexPath:_currentViewState.indexPath];
	}
}

- (void)setDataSource:(id<XKPhotoScrollViewDataSource>)aDataSource {
	_dataSource = aDataSource;
	[self reloadData];
}

#pragma mark Move current view

- (CGSize)halfSizeForReveal:(XKPhotoScrollViewViewState *)viewState {
	CGFloat currentHalfWidth = viewState.view.frame.size.width / 2;
	CGFloat currentHalfHeight = viewState.view.frame.size.height / 2;
	CGSize viewportSize = [self viewportSize];

	if (currentHalfWidth / viewState.scale < viewportSize.width / 2)
		currentHalfWidth += (viewportSize.width / 2) - (currentHalfWidth / viewState.scale);
	if (currentHalfHeight / viewState.scale < viewportSize.height / 2)
		currentHalfHeight += (viewportSize.height / 2) - (currentHalfHeight / viewState.scale);
	return CGSizeMake(currentHalfWidth, currentHalfHeight);
}

- (int)shouldReveal {
	/* No reveal when zooming, only when dragging */
	if (_lastTouchMode != XKPhotoScrollViewTouchModeDragging)
		return XKPhotoScrollViewRevealModeNone;

	CGPoint center = _currentViewState.view.center;
	CGSize currentHalfSize = [self halfSizeForReveal:_currentViewState];
	CGSize viewportSize = [self viewportSize];

	if (center.x + currentHalfSize.width + kRevealGutter < viewportSize.width && _currentViewState.indexPath.col < _cols - 1) {
		return XKPhotoScrollViewRevealModeRight;
	} else if (center.x - currentHalfSize.width - kRevealGutter > 0 && _currentViewState.indexPath.col > 0) {
		return XKPhotoScrollViewRevealModeLeft;
	} else if (center.y - currentHalfSize.height - kRevealGutter > 0 && _currentViewState.indexPath.row > 0) {
		return XKPhotoScrollViewRevealModeUp;
	} else if (center.y + currentHalfSize.height + kRevealGutter < viewportSize.height && _currentViewState.indexPath.row < _rows - 1) {
		return XKPhotoScrollViewRevealModeDown;
	} else {
		return XKPhotoScrollViewRevealModeNone;
	}
}

static BOOL XKCGPointIsValid(CGPoint pt) {
    if (isnan(pt.x) || isnan(pt.y))
        return NO;
    return YES;
}

- (void)moveCurrentView:(CGPoint)center {
    /* We sometimes (rarely) get NaNs in the center point, so we test for it and skip it */
    if (XKCGPointIsValid(center)) {
        _currentViewState.view.center = center;
    }

	/* Check if we should activate a reveal */
	if (_revealMode == XKPhotoScrollViewRevealModeNone) {
		_revealMode = [self shouldReveal];

        NSIndexPath * const currentIndexPath = _currentViewState.indexPath;
        
		switch (_revealMode) {
			case XKPhotoScrollViewRevealModeRight:
                _revealViewState.indexPath = [NSIndexPath indexPathForRow:currentIndexPath.row inColumn:currentIndexPath.col + 1];
				break;

			case XKPhotoScrollViewRevealModeLeft:
                _revealViewState.indexPath = [NSIndexPath indexPathForRow:currentIndexPath.row inColumn:currentIndexPath.col - 1];
				break;

			case XKPhotoScrollViewRevealModeUp:
                _revealViewState.indexPath = [NSIndexPath indexPathForRow:currentIndexPath.row - 1 inColumn:currentIndexPath.col];
				break;

            case XKPhotoScrollViewRevealModeDown:
                _revealViewState.indexPath = [NSIndexPath indexPathForRow:currentIndexPath.row + 1 inColumn:currentIndexPath.col];
				break;
                
            case XKPhotoScrollViewRevealModeNone:
                break;
		}

		if (_revealMode != XKPhotoScrollViewRevealModeNone) {
			_revealViewState.view = _placeholderRevealView;
			[self configureView:_revealViewState andInitialise:YES];
            [self requestViewAtIndexPath:_revealViewState.indexPath];
        }
	}

	/* Update the reveal */
	if (_revealMode != XKPhotoScrollViewRevealModeNone) {
		CGPoint revealCenter = _revealViewState.view.center;
		CGSize revealHalfSize = [self halfSizeForReveal:_revealViewState];
		CGSize currentHalfSize = [self halfSizeForReveal:_currentViewState];

		switch (_revealMode) {
			case XKPhotoScrollViewRevealModeRight:
				revealCenter.x = center.x + currentHalfSize.width + revealHalfSize.width + kRevealGutter;
				break;

			case XKPhotoScrollViewRevealModeLeft:
				revealCenter.x = center.x - currentHalfSize.width - revealHalfSize.width - kRevealGutter;
				break;

			case XKPhotoScrollViewRevealModeUp:
				revealCenter.y = center.y - currentHalfSize.height - revealHalfSize.height - kRevealGutter;
				break;

			case XKPhotoScrollViewRevealModeDown:
				revealCenter.y = center.y + currentHalfSize.height + revealHalfSize.height + kRevealGutter;
                break;
                
            case XKPhotoScrollViewRevealModeNone:
                break;
		}

        if (XKCGPointIsValid(revealCenter)) {
            _revealViewState.view.center = revealCenter;
        }
		if (!_revealViewState.view.superview) {
			[self addSubview:_revealViewState.view];
		}

		/* Check for the end of the reveal */
		if ([self shouldReveal] == XKPhotoScrollViewRevealModeNone) {
            [self cancelRequestAtIndexPath:_revealViewState.indexPath];

			/* So that setImage doesn't mistakenly set a reveal view, as it is in a different thread */
            _revealViewState.indexPath = nil;

			[_revealViewState.view removeFromSuperview];
			_revealViewState.view = nil;
			_revealMode = XKPhotoScrollViewRevealModeNone;
		}
	}
}

#pragma mark Stabilise

- (void)stableViewZoom {
	_animationTargetScale = _currentViewState.scale;
	if (_zoomScaleTarget != 0) {
		_animationTargetScale = _zoomScaleTarget;
		_zoomScaleTarget = 0;
	}

	if (_animationTargetScale > _maximumZoomScale)
		_animationTargetScale = _maximumZoomScale;
	else if (_animationTargetScale < _minimumZoomScale)
		_animationTargetScale = _minimumZoomScale;

	if (_animationTargetScale != _currentViewState.scale) {
		CGPoint offset = CGPointAdd(_zoomCurrentViewStart, CGPointNegate(_zoomTouchStart));

		/* Work out where the zoom operation would have finished - as we may have had drags since our last zoom so
		 * the current center is not necessarily where the zoom finished.
		 */
		CGFloat scaledRatio = _currentViewState.scale / _zoomScaleStart;
		CGPoint scaledCenter = CGPointAdd(_zoomCurrentViewStart, CGPointMul(offset, scaledRatio - 1));
		CGPoint currentDiff = CGPointAdd(_animationTargetCenter, CGPointNegate(scaledCenter));

		/* Work out where we'd like to end up after correcting the scale */
		CGFloat targetRatio = _animationTargetScale / _zoomScaleStart;
		CGPoint targetCenter = CGPointAdd(_zoomCurrentViewStart, CGPointMul(offset, targetRatio - 1));

		/* New target is our target centre adjusted for whatever drag movements have occurred since the zoom */
		_animationTargetCenter = CGPointAdd(targetCenter, currentDiff);
	}
}

- (void)stableViewCenter {
	CGSize viewportSize = [self viewportSize];
	CGSize currentSize = _currentViewState.view.frame.size;

	/* Adjust current size for stable zoom so that we reposition according to where the stable zoom will be */
	currentSize = CGSizeMul(CGSizeMul(currentSize, 1 / _currentViewState.scale), _animationTargetScale);
	CGPoint center = _animationTargetCenter;
	CGPoint stable;

	if (currentSize.width <= viewportSize.width) {
		stable.x = viewportSize.width / 2;
	} else {
		CGFloat currentHalfWidth = currentSize.width / 2;
		if (center.x - currentHalfWidth > 0) {
			stable.x = currentHalfWidth + _insets.left;
		} else if (center.x + currentHalfWidth < viewportSize.width) {
			stable.x = viewportSize.width - currentHalfWidth - _insets.right;
		} else {
			stable.x = center.x;
		}
	}
	if (currentSize.height <= viewportSize.height) {
		stable.y = viewportSize.height / 2;
	} else {
		CGFloat currentHalfHeight = currentSize.height / 2;
		if (center.y - currentHalfHeight > 0) {
			stable.y = currentHalfHeight + _insets.top;
		} else if (center.y + currentHalfHeight < viewportSize.height) {
			stable.y = viewportSize.height - currentHalfHeight - _insets.bottom;
		} else {
			stable.y = center.y;
		}
	}
    
	_animationTargetCenter = stable;
}

- (BOOL)shouldSwitchToRevealed {
	if (!_revealViewState.view)
		return NO;

	/* Check if the current view is at a valid size, otherwise it may be too small to determine whether to switch */
	if (_currentViewState.scale < _minimumZoomScale || _currentViewState.scale > _maximumZoomScale)
		return NO;

	/* Check if enough of the reveal view is visible to swap to the revealed cell */
	CGPoint revealCenter = _revealViewState.view.center;
	CGSize revealHalfSize = [self halfSizeForReveal:_revealViewState];
	CGSize viewportSize = [self viewportSize];

	CGFloat revealed = 0;
	switch (_revealMode) {
		case XKPhotoScrollViewRevealModeUp:
			revealed = revealCenter.y + revealHalfSize.height;
			break;

		case XKPhotoScrollViewRevealModeDown:
			revealed = viewportSize.height - revealCenter.y + revealHalfSize.height;
			break;

		case XKPhotoScrollViewRevealModeLeft:
			revealed = revealCenter.x + revealHalfSize.width;
			break;

		case XKPhotoScrollViewRevealModeRight:
			revealed = viewportSize.width - revealCenter.x + revealHalfSize.width;
            break;
            
        case XKPhotoScrollViewRevealModeNone:
            break;
	}

	CGFloat revealThreshold = 0;
	switch (_revealMode) {
		case XKPhotoScrollViewRevealModeUp:
		case XKPhotoScrollViewRevealModeDown:
			revealThreshold = _currentViewState.scale > 1 ? revealHalfSize.height : 30;
			break;

		case XKPhotoScrollViewRevealModeLeft:
		case XKPhotoScrollViewRevealModeRight:
			revealThreshold = _currentViewState.scale > 1 ? revealHalfSize.width : 30;
            break;
            
        case XKPhotoScrollViewRevealModeNone:
            break;
	}

#ifdef DEBUG_PHOTO_SCROLL_VIEW
	NSLog(@"REVEALED %f vs %f", revealed, revealThreshold);
#endif

	return (revealed >= revealThreshold);
}

- (void)switchToRevealed {
	/* Switch current to revealed */
	XKPhotoScrollViewViewState *oldCurrentView = _currentViewState;

	_currentViewState = _revealViewState;
	_revealViewState = oldCurrentView;

	switch (_revealMode) {
		case XKPhotoScrollViewRevealModeUp:
			_revealMode = XKPhotoScrollViewRevealModeDown;
			break;

		case XKPhotoScrollViewRevealModeDown:
			_revealMode = XKPhotoScrollViewRevealModeUp;
			break;

		case XKPhotoScrollViewRevealModeLeft:
			_revealMode = XKPhotoScrollViewRevealModeRight;
			break;

		case XKPhotoScrollViewRevealModeRight:
			_revealMode = XKPhotoScrollViewRevealModeLeft;
            break;
            
        case XKPhotoScrollViewRevealModeNone:
            break;
	}

    
    if ([_delegate respondsToSelector:@selector(photoScrollView:didSetCurrentView:withState:)])
        [_delegate photoScrollView:self didSetCurrentView:_currentViewState.view withState:[_currentViewState copy]];
    
	if ([_delegate respondsToSelector:@selector(photoScrollView:didChangeToIndexPath:)]) {
        [_delegate photoScrollView:self didChangeToIndexPath:_currentViewState.indexPath];
	}

#ifdef DEBUG_PHOTO_SCROLL_VIEW
	NSLog(@"Switched to reveal at %@", _currentViewState.indexPath);
#endif
}

/* Return the view to a steady state */
- (void)stabiliseCurrentView:(BOOL)animated {
    if (!_currentViewState.view)
        return;
    
	_animationTargetCenter = _currentViewState.view.center;

	/* Must stabilise zoom before center as zoom may move center and stableViewCenter needs to know the size that the view is going to
	 * be to correctly position it after any zooming.
	 */
	[self stableViewZoom];
	[self stableViewCenter];

    if ( CGPointEqualToPoint( _animationTargetCenter, _currentViewState.view.center ) && _animationTargetScale == _currentViewState.scale )
        return;

	if (animated) {
		/* Animate */
		_animationStartCenter = _currentViewState.view.center;
		_animationStartScale = _currentViewState.scale;
		_animationStartTime = [NSDate timeIntervalSinceReferenceDate];
		_animationDuration = 0.25;
        
        [_displayLink invalidate];
        _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(stabiliseAnimation)];
        [_displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
	} else {
		[self moveCurrentView:_animationTargetCenter];
		_currentViewState.scale = _animationTargetScale;
		[self updateTransformation:_currentViewState];
	}
}

- (void)decelerateCurrentView {
	if (!CGPointEqualToPoint(_dragLastVector, CGPointZero)) {
		_decelerating = YES;
		_animationStartTime = [NSDate timeIntervalSinceReferenceDate];
		_animationDuration = 0.25;
        
        [_displayLink invalidate];
        _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(decelerateAnimation)];
        [_displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
	} else {
		if ([self shouldSwitchToRevealed])
			[self switchToRevealed];
		[self stabiliseCurrentView:YES];
	}
}

- (void)_reduceDragLastVector {
	/* Reduce vectors on boundaries */
	CGPoint center = _currentViewState.view.center;
	CGFloat currentHalfWidth = _currentViewState.view.frame.size.width / 2;
	CGFloat currentHalfHeight = _currentViewState.view.frame.size.height / 2;
	CGSize viewportSize = [self viewportSize];

    NSIndexPath * const currentIndexPath = _currentViewState.indexPath;
    
	if ((currentIndexPath.col == 0 && _dragLastVector.x > 0 && center.x > currentHalfWidth) ||
		(currentIndexPath.col == _cols - 1 && _dragLastVector.x < 0 && center.x + currentHalfWidth < viewportSize.width)) {
		_dragLastVector.x /= 2;
	}
	if ((currentIndexPath.row == 0 && _dragLastVector.y > 0 && center.y > currentHalfHeight) ||
		(currentIndexPath.row == _rows - 1 && _dragLastVector.y < 0 && center.y + currentHalfHeight < viewportSize.height)) {
		_dragLastVector.y /= 2;
	}
}

#pragma mark Animation

static CGFloat linear_easeNone(NSTimeInterval t, CGFloat b /* begin */, CGFloat c /* change */, NSTimeInterval d /* duration */) {
	return c * t / d + b;
}

- (void)decelerateAnimation {
	NSTimeInterval t = [NSDate timeIntervalSinceReferenceDate] - _animationStartTime;

	if (t > _animationDuration)
		t = _animationDuration;

    CGFloat m = linear_easeNone(t, 1, -1, _animationDuration);
    [self _reduceDragLastVector];
    CGPoint p = CGPointAdd(_currentViewState.view.center, CGPointMul(_dragLastVector, m));
    [self moveCurrentView:p];

	if ([self shouldSwitchToRevealed]) {
		[self switchToRevealed];
		t = _animationDuration;
	}

	/* Check if animation is complete or if our drag vector has been reduced to nothing */
	if (t == _animationDuration || (fabs(_dragLastVector.x) < 1 && fabs(_dragLastVector.y) < 1)) {
		[_displayLink invalidate];
		_displayLink = nil;
		_decelerating = NO;
		[self stabiliseCurrentView:YES];
	}
}

- (void)stabiliseAnimation {
    NSTimeInterval t = [NSDate timeIntervalSinceReferenceDate] - _animationStartTime;

	if (t > _animationDuration)
		t = _animationDuration;

	/* Animate centre */
	CGPoint p;
    p.x = linear_easeNone(t, _animationStartCenter.x, _animationTargetCenter.x - _animationStartCenter.x, _animationDuration);
    p.y = linear_easeNone(t, _animationStartCenter.y, _animationTargetCenter.y - _animationStartCenter.y, _animationDuration);
	[self moveCurrentView:p];

	/* Animate scale */
	if (_animationStartScale != _animationTargetScale) {
		CGFloat scale = linear_easeNone(t, _animationStartScale, _animationTargetScale - _animationStartScale, _animationDuration);
		_currentViewState.scale = scale;
		[self updateTransformation:_currentViewState];
	}

	if (t == _animationDuration) {
		[_displayLink invalidate];
		_displayLink = nil;
        if ([_delegate respondsToSelector:@selector(photoScrollView:didStabilizeView:)])
            [_delegate photoScrollView:self didStabilizeView:_currentViewState.view];
	} else {
        if ([_delegate respondsToSelector:@selector(photoScrollView:isStabilizing:)])
            [_delegate photoScrollView:self isStabilizing:_currentViewState.view];
    }
}

#pragma mark Drag & Zoom

- (void)startDrag:(UITouch *)touch {
	_dragCurrentViewStart = _currentViewState.view.center;
	_dragTouchStart = [touch locationInView:self];
	_dragTouchLast = _dragTouchStart;
	_touchMode = _lastTouchMode = XKPhotoScrollViewTouchModeDragging;
	_dragLastVector = CGPointZero;
	_dragAxis = XKPhotoScrollViewDragAxisNone;
	_draggedSomeDistance = NO;
}

- (BOOL)drag:(UITouch *)touch {
	if (_touchMode != XKPhotoScrollViewTouchModeDragging) {
		[self startDrag:touch];
	}

	CGPoint touchNow = [touch locationInView:self];
	CGPoint dragVector = CGPointAdd(touchNow, CGPointNegate(_dragTouchStart));

	if (!_draggedSomeDistance) {
		_owningTouch = _draggedSomeDistance = (fabs(dragVector.x) > _minimumDrag || fabs(dragVector.y) > _minimumDrag);
	}

	_dragLastVector = CGPointAdd(touchNow, CGPointNegate(_dragTouchLast));
	_dragTouchLast = touchNow;

	BOOL shouldAxisLock = _currentViewState.scale <= 1;
	if (shouldAxisLock) {
		if (_dragAxis == XKPhotoScrollViewDragAxisNone) {
			if (_draggedSomeDistance) {
				if (fabs(dragVector.x) > fabs(dragVector.y) && _cols > 1) {
					_dragAxis = XKPhotoScrollViewDragAxisHorizontal;
				} else if (_rows > 1) {
					_dragAxis = XKPhotoScrollViewDragAxisVertical;
				} else if (_cols > 1 || _alwaysBounceScroll) {
					_dragAxis = XKPhotoScrollViewDragAxisHorizontal;
				}
			}
		}
		if (_dragAxis == XKPhotoScrollViewDragAxisHorizontal) {
			_dragLastVector.y = 0;
		} else if (_dragAxis == XKPhotoScrollViewDragAxisVertical) {
			_dragLastVector.x = 0;
		} else {
			/* If we haven't locked in an axis then we don't move at all */
			_dragLastVector = CGPointZero;
		}
	}

	/* Reduce vectors on boundaries */
	[self _reduceDragLastVector];
    
#ifdef DEBUG_PHOTO_SCROLL_VIEW
    NSLog(@"DRAG %@ currentViewScale = %f, dragAxis = %li, draggedSomeDistance = %i", NSStringFromCGPoint(_dragLastVector), _currentViewState.scale, (long) _dragAxis, _draggedSomeDistance);
#endif

	/* Calculate new centre */
	CGPoint center = _currentViewState.view.center;
	CGPoint contentNow = CGPointAdd(center, _dragLastVector);
	[self moveCurrentView:contentNow];
    
    if ([_delegate respondsToSelector:@selector(photoScrollView:didDragView:atIndexPath:)])
        [_delegate photoScrollView:self didDragView:_currentViewState.view atIndexPath:_currentViewState.indexPath];
    
    return !CGPointEqualToPoint(_dragLastVector, CGPointZero);
}

- (void)startZoom:(NSArray *)allTouches {
	UITouch *a = allTouches[0];
	UITouch *b = allTouches[1];
	CGPoint pA = [a locationInView:self];
	CGPoint pB = [b locationInView:self];

	_zoomCurrentViewStart = _currentViewState.view.center;
	_zoomTouchStart = CGPointMid(pA, pB);
	_touchMode = _lastTouchMode = XKPhotoScrollViewTouchModeZooming;
	_zoomRadiusStart = CGPointDist(_zoomTouchStart, pA);
	_zoomTransformStart = _currentViewState.view.transform;
	_zoomScaleStart = _zoomMinScale = _zoomMaxScale = _currentViewState.scale;
	_dragLastVector = CGPointZero;
	_zoomScaleTarget = 0;
}

- (BOOL)zoom:(NSArray *)allTouches {
	/* Sometimes we get a touch moved with two fingers before we get the touch start for the second finger. This caused
	 * the black screen bug that occurred when you tapped with two fingers when the photoscrollview first appeared.
	 * As zoom was called before startZoom was called so zoomRadiusStart was 0 so ratio became infinity!
	 */
	if (_touchMode != XKPhotoScrollViewTouchModeZooming) {
		[self startZoom:allTouches];
	}

	UITouch *a = allTouches[0];
	UITouch *b = allTouches[1];
	CGPoint pA = [a locationInView:self];
	CGPoint pB = [b locationInView:self];

	CGFloat radiusNow = CGPointDist(pA, pB) / 2;
	CGFloat ratio = radiusNow / _zoomRadiusStart;

	if (!_owningTouch && fabs(radiusNow - _zoomRadiusStart) > _minimumDrag) {
		_owningTouch = YES;
    }
    
    /* If we haven't moved enough to start the zoom, then bail */
    if (!_owningTouch) {
        return NO;
    }

	CGFloat newScale = _zoomScaleStart * ratio;
	if (!_bouncesZoom) {
		if (newScale < _minimumZoomScale)
			newScale = _minimumZoomScale;
		if (newScale > _maximumZoomScale)
			newScale = _maximumZoomScale;
	} else {
		/* Reduce scale on boundaries */
		if (newScale < _minimumZoomScale)
			newScale += (_minimumZoomScale - newScale) / 1.3;
		if (newScale > _maximumZoomScale)
			newScale -= (newScale - _maximumZoomScale) / 1.3;
	}

    if (newScale < _zoomMinScale) {
        _zoomMinScale = newScale;
    }
    if (newScale > _zoomMaxScale) {
        _zoomMaxScale = newScale;
    }
    
    BOOL adjustedScale = NO;
    if (_currentViewState.scale != newScale) {
        _currentViewState.scale = newScale;
        adjustedScale = YES;
    }

	/* Recalculate ratio based on limits above */
	ratio = newScale / _zoomScaleStart;

	CGPoint offset = CGPointAdd(_zoomCurrentViewStart, CGPointNegate(_zoomTouchStart));
	[self updateTransformation:_currentViewState];
	[self moveCurrentView:CGPointAdd(_zoomCurrentViewStart, CGPointMul(offset, ratio - 1))];
    
    return adjustedScale;
}

- (void)resetZoom:(UITouch *)touch {
	if (_currentViewState.scale != 1.0) {
		_zoomScaleStart = _currentViewState.scale;
		_zoomScaleTarget = 1.0;
		_zoomCurrentViewStart = _currentViewState.view.center;
		_zoomTouchStart = [touch locationInView:self];
	} else {
		_zoomScaleStart = _currentViewState.scale;
		_zoomScaleTarget = 2.0;
		_zoomCurrentViewStart = _currentViewState.view.center;
		_zoomTouchStart = [touch locationInView:self];
	}
}

#pragma mark Start & Stop touching

- (void)singleTap {
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(singleTap) object:nil];

	if ([_delegate respondsToSelector:@selector(photoScrollView:didTapView:atPoint:atIndexPath:)])
		[_delegate photoScrollView:self didTapView:_currentViewState.view atPoint:_singleTapLocationInView atIndexPath:_currentViewState.indexPath];

	_touchMode = _lastTouchMode = XKPhotoScrollViewTouchModeNone;
	[self decelerateCurrentView];
}

- (void)longPress {
	if ([_delegate respondsToSelector:@selector(photoScrollView:didLongPressView:atPoint:atIndexPath:)])
		[_delegate photoScrollView:self didLongPressView:_currentViewState.view atPoint:_longPressLocationInView atIndexPath:_currentViewState.indexPath];

	_touchMode = _lastTouchMode = XKPhotoScrollViewTouchModeNone;
	[self decelerateCurrentView];
}

- (BOOL)startTouches:(NSSet *)touches {
    if (!_currentViewState.view)
        return NO;
    
	if (_displayLink) {
		[_displayLink invalidate];
		_displayLink = nil;
	}
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(singleTap) object:nil];
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(longPress) object:nil];

	_cancelledForeignTouches = NO;
	_owningTouch = NO;

	unsigned long c = [touches count];
	if (c == 1) {
		UITouch *touch = [touches anyObject];
		_longPressLocationInView = [touch locationInView:_currentViewState.view];
		[self performSelector:@selector(longPress) withObject:nil afterDelay:self.minimumLongPressDuration];
		if (touch.tapCount < 2) {
			[self startDrag:touch];
		}
	} else if (c == 2) {
		NSArray *allTouches = [touches allObjects];
		[self startZoom:allTouches];
	}

	if ([_delegate respondsToSelector:@selector(photoScrollView:didTouchView:withTouches:atIndexPath:)])
		[_delegate photoScrollView:self didTouchView:_currentViewState.view withTouches:touches atIndexPath:_currentViewState.indexPath];
    
    return YES;
}

- (BOOL)moveTouches:(NSSet *)touches event:(UIEvent *)event {
    if (!_currentViewState.view)
        return NO;
    
    [self resetTimedTouches];
    
    /* We treat all the touches as for us. If there is a subview that
     * supports userInteraction then the touches will be for it, so we
     * don't use touchesForView.
     */
    NSSet * const touchesForView = [event allTouches];
    
    BOOL handledTouch = NO;
    unsigned long c = [touchesForView count];
    if (c == 1) {
        UITouch *touch = [touchesForView anyObject];
        handledTouch = [self drag:touch];
    } else if (c == 2) {
        NSArray *allTouches = [touchesForView allObjects];
        handledTouch = [self zoom:allTouches];
    }
    
    if (_owningTouch && !_cancelledForeignTouches) {
        _cancelledForeignTouches = YES;
        for (UITouch *touch in touchesForView) {
            if (touch.view != self) {
                [touch.view touchesCancelled:[NSSet setWithObject:touch] withEvent:event];
            }
        }
    }
    
    return handledTouch;
}

- (BOOL)endTouches:(NSSet *)touches {
    if (!_currentViewState.view)
        return NO;
    
    NSMutableSet *remainingTouches = [[NSMutableSet alloc] initWithCapacity:[touches count]];
    
    for (UITouch *touch in touches) {
        /* Remaining touches are touches with a valid view (not sure will null views come here but we
         * never get any more notification for them so if we call startTouches with them we never end.
         */
        if (touch.view && touch.phase != UITouchPhaseEnded && touch.phase != UITouchPhaseCancelled) {
            [remainingTouches addObject:touch];
        }
    }
    
    if ([remainingTouches count] == 0) {
        [self finishedTouches:touches];
        return YES;
    } else {
        return NO;
    }
}

- (void)finishedTouches:(NSSet *)touches {
    [self resetTimedTouches];

	if (_touchMode == XKPhotoScrollViewTouchModeDragging) {
		if (!_draggedSomeDistance) {
			if ([touches count] == 1) {
				UITouch *touch = [touches anyObject];
				if (touch.tapCount == 1) {
					_singleTapLocationInView = [touch locationInView:_currentViewState.view];
					[self performSelector:@selector(singleTap) withObject:nil afterDelay:0.3];
					return;
				} else if (touch.tapCount == 2) {
					[self resetZoom:touch];
				}
			}
		} else {
			if ([_delegate respondsToSelector:@selector(photoScrollView:didDragView:atIndexPath:)])
				[_delegate photoScrollView:self didDragView:_currentViewState.view atIndexPath:_currentViewState.indexPath];
		}
	} else if (_touchMode == XKPhotoScrollViewTouchModeZooming) {
		if ([_delegate respondsToSelector:@selector(photoScrollView:didZoomView:atIndexPath:)])
			[_delegate photoScrollView:self
						  didZoomView:_currentViewState.view
								atIndexPath:_currentViewState.indexPath];
        
        if (_currentViewState.scale < 0.90 && _zoomMaxScale <= _zoomScaleStart * 1.05) {
            /* If the user pinches the view by more than 10% below its base scale, and they didn't
               zoom it more than 5% above the initial scale, then it's a pinch dismiss gesture.
             */
            if ([_delegate respondsToSelector:@selector(photoScrollView:didPinchDismissView:atIndexPath:)])
                [_delegate photoScrollView:self
                      didPinchDismissView:_currentViewState.view
                                    atIndexPath:_currentViewState.indexPath];
        }
	}

	_touchMode = XKPhotoScrollViewTouchModeNone;
	[self decelerateCurrentView];
}

- (void)resetTimedTouches
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(singleTap) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(longPress) object:nil];
}

#pragma mark Orientation

- (void)notifyDeviceOrientationDidChange:(UIDeviceOrientation)orientation animated:(BOOL)animated {
	int newRotation;

	switch (orientation) {
		case UIDeviceOrientationPortrait:
			newRotation = 0;
			break;

		case UIDeviceOrientationPortraitUpsideDown:
			newRotation = 180;
			break;

		case UIDeviceOrientationLandscapeLeft:
			newRotation = 90;
			break;

		case UIDeviceOrientationLandscapeRight:
			newRotation = 270;
			break;

		default:
			newRotation = _rotation;
			break;
	}

#ifdef DEBUG_PHOTO_SCROLL_VIEW
	NSLog(@"newRotation=%i", newRotation);
#endif

	if (_rotation != newRotation) {
        int oldRotation = _rotation;
		_rotation = newRotation;

        if (_currentViewState.view) {
            if (animated) {
                [UIView beginAnimations:nil context:nil];
                [UIView setAnimationDuration:0.25];
            }
            CGRect bounds = self.bounds;
            CGPoint center = CGPointMakeProportional(_currentViewState.view.center, bounds.size);
            CGPoint revealCenter = CGPointMakeProportional(_revealViewState.view.center, bounds.size);
            
            bool oldRotationIsLandscape = oldRotation % 180 == 90;
            bool newRotationIsLandscape = newRotation % 180 == 90;
            
            if (oldRotationIsLandscape != newRotationIsLandscape) {
                bounds.size = CGSizeInvert(_initialSize);
            } else {
                bounds.size = _initialSize;
            }

            self.bounds = bounds;
            _currentViewState.view.center = CGPointFromProportional(center, bounds.size);
            _revealViewState.view.center = CGPointFromProportional(revealCenter, bounds.size);

            [self configureView:_currentViewState andInitialise:NO];
            [self configureView:_revealViewState andInitialise:NO];

            self.transform = CGAffineTransformMakeRotation(_rotation * M_PI / 180);

            if (animated)
                [UIView commitAnimations];

            [self stabiliseCurrentView:animated];
        }

		if ([self.delegate respondsToSelector:@selector(photoScrollView:didRotateTo:)])
			[self.delegate photoScrollView:self didRotateTo:_rotation];
	}
}

#pragma mark Properties

- (NSIndexPath *)currentIndexPath
{
    return _currentViewState.indexPath;
}

- (BOOL)touching {
	return _touchMode != XKPhotoScrollViewTouchModeNone;
}

@end

@implementation XKPhotoScrollViewViewState

- (id)copyWithZone:(NSZone *)zone {
    XKPhotoScrollViewViewState *copy = [[XKPhotoScrollViewViewState allocWithZone:zone] init];
    copy.view = self.view;
    copy.scale = self.scale;
    copy.baseScale = self.baseScale;
    copy.indexPath = self.indexPath;
    copy.placeholder = self.placeholder;
    return copy;
}

@end

@implementation NSIndexPath (XKPhotoScrollView)

+ (NSIndexPath *)indexPathForRow:(NSInteger)row inColumn:(NSInteger)column
{
    return [NSIndexPath indexPathForRow:row inSection:column];
}

- (NSInteger)col
{
    return self.section;
}

@end
