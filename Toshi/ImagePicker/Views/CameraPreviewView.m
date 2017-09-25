
#import "CameraPreviewView.h"

#import <AVFoundation/AVFoundation.h>
#import "ImageUtils.h"

#import "Camera.h"
#import "CameraCaptureSession.h"

#import "Common.h"

@protocol CameraPreviewLayerView <NSObject>

@property (nonatomic, strong) NSString *videoGravity;
@property (nonatomic, readonly) AVCaptureConnection *connection;
- (CGPoint)captureDevicePointOfInterestForPoint:(CGPoint)point;

@optional
- (AVSampleBufferDisplayLayer *)displayLayer;
- (AVCaptureVideoPreviewLayer *)previewLayer;

@end


@interface CameraPreviewLayerWrapperView : UIView <CameraPreviewLayerView>
{
    __weak AVCaptureConnection *_connection;
}

@property (nonatomic, readonly) AVSampleBufferDisplayLayer *displayLayer;

- (void)enqueueSampleBuffer:(CMSampleBufferRef)buffer connection:(AVCaptureConnection *)connection;

@end


@interface CameraLegacyPreviewLayerWrapperView : UIView <CameraPreviewLayerView>

@property (nonatomic, readonly) AVCaptureVideoPreviewLayer *previewLayer;

@end


@interface CameraPreviewView ()
{
    UIView<CameraPreviewLayerView> *_wrapperView;
    UIView *_fadeView;
    UIView *_snapshotView;
    
    Camera *_camera;
}
@end

@implementation CameraPreviewView

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self != nil)
    {
        self.backgroundColor = [UIColor blackColor];
        self.clipsToBounds = true;
        
        if (false)
            _wrapperView = [[CameraPreviewLayerWrapperView alloc] init];
        else
            _wrapperView = [[CameraLegacyPreviewLayerWrapperView alloc] init];
        [self addSubview:_wrapperView];
        
        _wrapperView.videoGravity = AVLayerVideoGravityResizeAspectFill;
        
        _fadeView = [[UIView alloc] initWithFrame:self.bounds];
        _fadeView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _fadeView.backgroundColor = [UIColor blackColor];
        _fadeView.userInteractionEnabled = false;
        [self addSubview:_fadeView];
    }
    return self;
}

- (AVCaptureConnection *)captureConnection
{
    return _wrapperView.connection;
}

- (AVSampleBufferDisplayLayer *)displayLayer
{
    return _wrapperView.displayLayer;
}

- (AVCaptureVideoPreviewLayer *)legacyPreviewLayer
{
    return _wrapperView.previewLayer;
}

- (void)setupWithCamera:(Camera *)camera
{
    _camera = camera;
    
    __weak CameraPreviewView *weakSelf = self;
    if ([_wrapperView isKindOfClass:[CameraPreviewLayerWrapperView class]])
    {
        [self.displayLayer flushAndRemoveImage];
        camera.captureSession.outputSampleBuffer = ^(CMSampleBufferRef buffer, AVCaptureConnection *connection)
        {
            __strong CameraPreviewView *strongSelf = weakSelf;
            if (strongSelf == nil)
                return;
            
            [(CameraPreviewLayerWrapperView *)strongSelf->_wrapperView enqueueSampleBuffer:buffer connection:connection];
        };
    }
    else
    {
#if !TARGET_IPHONE_SIMULATOR
        [self.legacyPreviewLayer setSession:camera.captureSession];
#endif
    }
    
    camera.captureStarted = ^(bool resume)
    {
        __strong CameraPreviewView *strongSelf = weakSelf;
        if (strongSelf == nil)
            return;
        
        if (resume)
            [strongSelf endResetTransitionAnimated:true];
        else
            [strongSelf fadeInAnimated:true];
    };
    
    camera.captureStopped = ^(bool pause)
    {
        __strong CameraPreviewView *strongSelf = weakSelf;
        if (strongSelf == nil)
            return;
        
        if (pause)
            [strongSelf beginResetTransitionAnimated:true];
        else
            [strongSelf fadeOutAnimated:true];
    };
}

- (void)invalidate
{
    if ([_wrapperView isKindOfClass:[CameraPreviewLayerWrapperView class]])
    {
        [self.displayLayer flushAndRemoveImage];
        _camera.captureSession.outputSampleBuffer = nil;
    }
    else
    {
        [self.legacyPreviewLayer setSession:nil];
    }
    _wrapperView = nil;
}

- (Camera *)camera
{
    return _camera;
}

- (void)fadeInAnimated:(bool)animated
{
    if (animated)
    {
        [UIView animateWithDuration:0.3f delay:0.05f options:UIViewAnimationOptionCurveLinear animations:^
        {
            _fadeView.alpha = 0.0f;
        } completion:nil];
    }
    else
    {
        _fadeView.alpha = 0.0f;
    }
}

- (void)fadeOutAnimated:(bool)animated
{
    if (animated)
    {
        [UIView animateWithDuration:0.3f animations:^
        {
            _fadeView.alpha = 1.0f;
        }];
    }
    else
    {
        _fadeView.alpha = 1.0f;
    }
}

- (void)beginTransitionWithSnapshotImage:(UIImage *)image animated:(bool)animated
{
    [_snapshotView removeFromSuperview];
    
    UIImageView *snapshotView = [[UIImageView alloc] initWithFrame:_wrapperView.frame];
    snapshotView.contentMode = UIViewContentModeScaleAspectFill;
    snapshotView.image = image;
    [self insertSubview:snapshotView aboveSubview:_wrapperView];
    
    _snapshotView = snapshotView;
    
    if (animated)
    {
        _snapshotView.alpha = 0.0f;
        [UIView animateWithDuration:0.3f delay:0.0f options:UIViewAnimationOptionCurveEaseInOut animations:^
        {
            _snapshotView.alpha = 1.0f;
        } completion:nil];
    }
}

- (void)endTransitionAnimated:(bool)animated
{
    if (animated)
    {
        UIView *snapshotView = _snapshotView;
        _snapshotView = nil;
        
        [UIView animateWithDuration:0.4f delay:0.0f options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState animations:^
        {
            snapshotView.alpha = 0.0f;
        } completion:^(__unused BOOL finished)
        {
            [snapshotView removeFromSuperview];
        }];
    }
    else
    {
        [_snapshotView removeFromSuperview];
        _snapshotView = nil;
    }
}

- (void)beginResetTransitionAnimated:(bool)animated
{
    [_snapshotView removeFromSuperview];
    
    _snapshotView = [_wrapperView snapshotViewAfterScreenUpdates:false];
    _snapshotView.frame = _wrapperView.frame;
    [self insertSubview:_snapshotView aboveSubview:_wrapperView];
    
    if (animated)
    {
        _snapshotView.alpha = 0.0f;
        [UIView animateWithDuration:0.3f delay:0.0f options:UIViewAnimationOptionCurveEaseInOut animations:^
        {
            _snapshotView.alpha = 1.0f;
        } completion:nil];
    }
}

- (void)endResetTransitionAnimated:(bool)animated
{
    if (animated)
    {
        UIView *snapshotView = _snapshotView;
        _snapshotView = nil;
        
        [UIView animateWithDuration:0.4f delay:0.05f options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState animations:^
        {
            snapshotView.alpha = 0.0f;
        } completion:^(__unused BOOL finished)
        {
            [snapshotView removeFromSuperview];
        }];
    }
    else
    {
        [_snapshotView removeFromSuperview];
        _snapshotView = nil;
    }
}

- (CGPoint)devicePointOfInterestForPoint:(CGPoint)point
{
    return [_wrapperView captureDevicePointOfInterestForPoint:point];
}

- (void)layoutSubviews
{
    _wrapperView.frame = self.bounds;
    
    if (_snapshotView != nil)
    {
        CGSize size = ScaleToFill(_snapshotView.frame.size, _wrapperView.frame.size);
        _snapshotView.frame = CGRectMake(floor((self.frame.size.width - size.width) / 2.0f), floor((self.frame.size.height - size.height) / 2.0f), size.width, size.height);
    }
}

@end


@implementation CameraPreviewLayerWrapperView

- (NSString *)videoGravity
{
    return [self displayLayer].videoGravity;
}

- (void)setVideoGravity:(NSString *)videoGravity
{
    self.displayLayer.videoGravity = videoGravity;
}

- (AVCaptureConnection *)connection
{
    return _connection;
}

- (CGPoint)captureDevicePointOfInterestForPoint:(CGPoint)point
{
    return CGPointZero;
}

- (void)enqueueSampleBuffer:(CMSampleBufferRef)buffer connection:(AVCaptureConnection *)connection
{
    _connection = connection;
    
    //self.orientation = connection.videoOrientation;
    //self.mirrored = connection.videoMirrored;
    
    [self.displayLayer enqueueSampleBuffer:buffer];
}

- (AVSampleBufferDisplayLayer *)displayLayer
{
    return (AVSampleBufferDisplayLayer *)self.layer;
}

+ (Class)layerClass
{
    return [AVSampleBufferDisplayLayer class];
}

@end


@implementation CameraLegacyPreviewLayerWrapperView

- (NSString *)videoGravity
{
    return self.previewLayer.videoGravity;
}

- (void)setVideoGravity:(NSString *)videoGravity
{
    self.previewLayer.videoGravity = videoGravity;
}

- (AVCaptureConnection *)connection
{
    return self.previewLayer.connection;
}

- (CGPoint)captureDevicePointOfInterestForPoint:(CGPoint)point
{
    return [self.previewLayer captureDevicePointOfInterestForPoint:point];
}

- (AVCaptureVideoPreviewLayer *)previewLayer
{
    return (AVCaptureVideoPreviewLayer *)self.layer;
}

+ (Class)layerClass
{
    return [AVCaptureVideoPreviewLayer class];
}

@end
