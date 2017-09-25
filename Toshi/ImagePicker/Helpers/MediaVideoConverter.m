#import "MediaVideoConverter.h"

#import <CommonCrypto/CommonDigest.h>
#import <sys/stat.h>

#import "ImageUtils.h"
#import "PhotoEditorUtils.h"

#import "VideoEditAdjustments.h"
#import "PaintingData.h"

@interface MediaVideoConversionPresetSettings : NSObject

+ (CGSize)maximumSizeForPreset:(MediaVideoConversionPreset)preset;
+ (NSDictionary *)videoSettingsForPreset:(MediaVideoConversionPreset)preset dimensions:(CGSize)dimensions;

+ (NSDictionary *)audioSettingsForPreset:(MediaVideoConversionPreset)preset;
+ (bool)keepAudioForPreset:(MediaVideoConversionPreset)preset;

+ (NSInteger)_videoBitrateKbpsForPreset:(MediaVideoConversionPreset)preset;
+ (NSInteger)_audioBitrateKbpsForPreset:(MediaVideoConversionPreset)preset;
+ (NSInteger)_audioChannelsCountForPreset:(MediaVideoConversionPreset)preset;

@end


@interface MediaSampleBufferProcessor : NSObject
{
    AVAssetReaderOutput *_assetReaderOutput;
    AVAssetWriterInput *_assetWriterInput;
    
    SQueue *_queue;
    bool _finished;
    
    void (^_completionBlock)(void);
}

- (instancetype)initWithAssetReaderOutput:(AVAssetReaderOutput *)assetReaderOutput assetWriterInput:(AVAssetWriterInput *)assetWriterInput;

- (void)startWithTimeRange:(CMTimeRange)timeRange progressBlock:(void (^)(CGFloat progress))progressBlock completionBlock:(void (^)(void))completionBlock;
- (void)cancel;

@end


@interface MediaVideoFileWatcher ()
{
    dispatch_source_t _readerSource;
    SQueue *_queue;
}
@end


@interface MediaVideoConversionContext : NSObject

@property (nonatomic, readonly) bool cancelled;
@property (nonatomic, readonly) bool finished;

@property (nonatomic, readonly) SQueue *queue;
@property (nonatomic, readonly) SSubscriber *subscriber;

@property (nonatomic, readonly) AVAssetReader *assetReader;
@property (nonatomic, readonly) AVAssetWriter *assetWriter;

@property (nonatomic, readonly) AVAssetImageGenerator *imageGenerator;

@property (nonatomic, readonly) MediaSampleBufferProcessor *videoProcessor;
@property (nonatomic, readonly) MediaSampleBufferProcessor *audioProcessor;

@property (nonatomic, readonly) CMTimeRange timeRange;
@property (nonatomic, readonly) CGSize dimensions;
@property (nonatomic, readonly) UIImage *coverImage;

+ (instancetype)contextWithQueue:(SQueue *)queue subscriber:(SSubscriber *)subscriber;

- (instancetype)cancelledContext;
- (instancetype)finishedContext;

- (instancetype)addImageGenerator:(AVAssetImageGenerator *)imageGenerator;
- (instancetype)addCoverImage:(UIImage *)coverImage;
- (instancetype)contextWithAssetReader:(AVAssetReader *)assetReader assetWriter:(AVAssetWriter *)assetWriter videoProcessor:(MediaSampleBufferProcessor *)videoProcessor audioProcessor:(MediaSampleBufferProcessor *)audioProcessor timeRange:(CMTimeRange)timeRange dimensions:(CGSize)dimensions;

@end


@interface MediaVideoConversionResult ()

+ (instancetype)resultWithFileURL:(NSURL *)fileUrl fileSize:(NSUInteger)fileSize duration:(NSTimeInterval)duration dimensions:(CGSize)dimensions coverImage:(UIImage *)coverImage liveUploadData:(id)livaUploadData;

@end


@implementation MediaVideoConverter

+ (SSignal *)convertAVAsset:(AVAsset *)avAsset adjustments:(MediaVideoEditAdjustments *)adjustments watcher:(MediaVideoFileWatcher *)watcher
{
    return [self convertAVAsset:avAsset adjustments:adjustments watcher:watcher inhibitAudio:false];
}

+ (SSignal *)convertAVAsset:(AVAsset *)avAsset adjustments:(MediaVideoEditAdjustments *)adjustments watcher:(MediaVideoFileWatcher *)watcher inhibitAudio:(bool)inhibitAudio
{
    SQueue *queue = [[SQueue alloc] init];
    
    return [[SSignal alloc] initWithGenerator:^id<SDisposable>(SSubscriber *subscriber)
    {
        SAtomic *context = [[SAtomic alloc] initWithValue:[MediaVideoConversionContext contextWithQueue:queue subscriber:subscriber]];
        NSURL *outputUrl = [self _randomTemporaryURL];
        
        NSArray *requiredKeys = @[ @"tracks", @"duration" ];
        [avAsset loadValuesAsynchronouslyForKeys:requiredKeys completionHandler:^
        {
            [queue dispatch:^
            {
                if (((MediaVideoConversionContext *)context.value).cancelled)
                    return;
                
                CGSize dimensions = [avAsset tracksWithMediaType:AVMediaTypeVideo].firstObject.naturalSize;
                MediaVideoConversionPreset preset = adjustments.sendAsGif ? MediaVideoConversionPresetAnimation : [self _presetFromAdjustments:adjustments];
                if (!CGSizeEqualToSize(dimensions, CGSizeZero) && preset != MediaVideoConversionPresetAnimation)
                {
                    MediaVideoConversionPreset bestPreset = [self bestAvailablePresetForDimensions:dimensions];
                    if (preset > bestPreset)
                        preset = bestPreset;
                }
                
                NSError *error = nil;
                for (NSString *key in requiredKeys)
                {
                    if ([avAsset statusOfValueForKey:key error:&error] != AVKeyValueStatusLoaded || error != nil)
                    {
                        [subscriber putError:error];
                        return;
                    }
                }

                NSString *outputPath = outputUrl.path;
                NSFileManager *fileManager = [NSFileManager defaultManager];
                if ([fileManager fileExistsAtPath:outputPath])
                {
                    [fileManager removeItemAtPath:outputPath error:&error];
                    if (error != nil)
                    {
                        [subscriber putError:error];
                        return;
                    }
                }
                
                if (![self setupAssetReaderWriterForAVAsset:avAsset outputURL:outputUrl preset:preset adjustments:adjustments inhibitAudio:inhibitAudio conversionContext:context error:&error])
                {
                    [subscriber putError:error];
                    return;
                }
                
                if (watcher != nil)
                    [watcher setupWithFileURL:outputUrl];
                
                [self processWithConversionContext:context completionBlock:^
                {
                    MediaVideoConversionContext *resultContext = context.value;
                    [resultContext.imageGenerator generateCGImagesAsynchronouslyForTimes:@[ [NSValue valueWithCMTime:kCMTimeZero] ] completionHandler:^(__unused CMTime requestedTime, CGImageRef  _Nullable image, __unused CMTime actualTime, AVAssetImageGeneratorResult result, __unused NSError * _Nullable error)
                     {
                        UIImage *coverImage = nil;
                        if (result == AVAssetImageGeneratorSucceeded)
                            coverImage = [UIImage imageWithCGImage:image];
                         
                         [context modify:^id(MediaVideoConversionContext *resultContext)
                         {
                             id liveUploadData = nil;
                             if (watcher != nil)
                                 liveUploadData = [watcher fileUpdated:true];
                             
                             MediaVideoConversionResult *result = [MediaVideoConversionResult resultWithFileURL:outputUrl fileSize:0 duration:CMTimeGetSeconds(resultContext.timeRange.duration) dimensions:resultContext.dimensions coverImage:coverImage liveUploadData:liveUploadData];
                             [subscriber putNext:result];
                             return [resultContext finishedContext];
                         }];
                         
                         [subscriber putCompletion];
                     }];
                }];
            }];
        }];
        
        return [[SBlockDisposable alloc] initWithBlock:^
        {
            [context modify:^id(MediaVideoConversionContext *currentContext)
            {
                if (currentContext.finishedContext)
                    return currentContext;
                
                [currentContext.videoProcessor cancel];
                [currentContext.audioProcessor cancel];
                
                return [currentContext cancelledContext];
            }];
        }];
    }];
}

+ (AVAssetReaderVideoCompositionOutput *)setupVideoCompositionOutputWithAVAsset:(AVAsset *)avAsset composition:(AVMutableComposition *)composition videoTrack:(AVAssetTrack *)videoTrack preset:(MediaVideoConversionPreset)preset adjustments:(MediaVideoEditAdjustments *)adjustments timeRange:(CMTimeRange)timeRange outputSettings:(NSDictionary **)outputSettings dimensions:(CGSize *)dimensions conversionContext:(SAtomic *)conversionContext
{
    CGSize transformedSize = CGRectApplyAffineTransform((CGRect){CGPointZero, videoTrack.naturalSize}, videoTrack.preferredTransform).size;;
    CGRect transformedRect = CGRectMake(0, 0, transformedSize.width, transformedSize.height);
    if (CGSizeEqualToSize(transformedRect.size, CGSizeZero))
        transformedRect = CGRectMake(0, 0, videoTrack.naturalSize.width, videoTrack.naturalSize.height);
    
    bool hasCropping = [adjustments cropAppliedForAvatar:false];
    CGRect cropRect = hasCropping ? CGRectIntegral(adjustments.cropRect) : transformedRect;
    
    CGSize maxDimensions = [MediaVideoConversionPresetSettings maximumSizeForPreset:preset];
    CGSize outputDimensions = TGFitSizeF(cropRect.size, maxDimensions);
    outputDimensions = CGSizeMake(ceil(outputDimensions.width), ceil(outputDimensions.height));
    outputDimensions = [self _renderSizeWithCropSize:outputDimensions];
    
    if (TGOrientationIsSideward(adjustments.cropOrientation, NULL))
        outputDimensions = CGSizeMake(outputDimensions.height, outputDimensions.width);
    
    AVMutableVideoComposition *videoComposition = [AVMutableVideoComposition videoComposition];
    videoComposition.frameDuration = CMTimeMake(1, (int32_t)videoTrack.nominalFrameRate);
    
    AVMutableCompositionTrack *trimVideoTrack = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
    [trimVideoTrack insertTimeRange:timeRange ofTrack:videoTrack atTime:kCMTimeZero error:NULL];

    if (TGOrientationIsSideward(adjustments.cropOrientation, NULL))
        videoComposition.renderSize = [self _renderSizeWithCropSize:CGSizeMake(cropRect.size.height, cropRect.size.width)];
    else
        videoComposition.renderSize = [self _renderSizeWithCropSize:cropRect.size];
    
    bool mirrored = false;
    UIImageOrientation videoOrientation = VideoOrientationForAsset(avAsset, &mirrored);
    CGAffineTransform transform = VideoTransformForOrientation(videoOrientation, videoTrack.naturalSize, cropRect, mirrored);
    CGAffineTransform rotationTransform = VideoTransformForCrop(adjustments.cropOrientation, cropRect.size, adjustments.cropMirrored);
    CGAffineTransform finalTransform = CGAffineTransformConcat(transform, rotationTransform);
    
    AVMutableVideoCompositionLayerInstruction *transformer = [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:trimVideoTrack];
    [transformer setTransform:finalTransform atTime:kCMTimeZero];
    
    AVMutableVideoCompositionInstruction *instruction = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    instruction.timeRange = CMTimeRangeMake(kCMTimeZero, timeRange.duration);
    instruction.layerInstructions = [NSArray arrayWithObject:transformer];
    videoComposition.instructions = [NSArray arrayWithObject:instruction];
    
    UIImage *overlayImage = nil;
    if (adjustments.paintingData.imagePath != nil)
        overlayImage = [UIImage imageWithContentsOfFile:adjustments.paintingData.imagePath];
    
    if (overlayImage != nil)
    {
        CALayer *parentLayer = [CALayer layer];
        parentLayer.frame = CGRectMake(0, 0, videoComposition.renderSize.width, videoComposition.renderSize.height);
        
        CALayer *videoLayer = [CALayer layer];
        videoLayer.frame = parentLayer.frame;
        [parentLayer addSublayer:videoLayer];
        
        CGSize parentSize = parentLayer.bounds.size;
        if (TGOrientationIsSideward(adjustments.cropOrientation, NULL))
            parentSize = CGSizeMake(parentSize.height, parentSize.width);
        
        CGSize size = CGSizeMake(parentSize.width * transformedSize.width / cropRect.size.width, parentSize.height * transformedSize.height / cropRect.size.height);
        CGPoint origin = CGPointMake(-parentSize.width / cropRect.size.width * cropRect.origin.x,  -parentSize.height / cropRect.size.height * (transformedSize.height - cropRect.size.height - cropRect.origin.y));
        
        CALayer *rotationLayer = [CALayer layer];
        rotationLayer.frame = CGRectMake(0, 0, parentSize.width, parentSize.height);
        [parentLayer addSublayer:rotationLayer];
        
        UIImageOrientation orientation = TGMirrorSidewardOrientation(adjustments.cropOrientation);
        CATransform3D layerTransform = CATransform3DMakeTranslation(rotationLayer.frame.size.width / 2.0f, rotationLayer.frame.size.height / 2.0f, 0.0f);
        layerTransform = CATransform3DRotate(layerTransform, TGRotationForOrientation(orientation), 0.0f, 0.0f, 1.0f);
        layerTransform = CATransform3DTranslate(layerTransform, -parentLayer.bounds.size.width / 2.0f, -parentLayer.bounds.size.height / 2.0f, 0.0f);
        rotationLayer.transform = layerTransform;
        rotationLayer.frame = parentLayer.frame;
        
        CALayer *overlayLayer = [CALayer layer];
        overlayLayer.contents = (id)overlayImage.CGImage;
        overlayLayer.frame = CGRectMake(origin.x, origin.y, size.width, size.height);
        [rotationLayer addSublayer:overlayLayer];
        
        videoComposition.animationTool = [AVVideoCompositionCoreAnimationTool videoCompositionCoreAnimationToolWithPostProcessingAsVideoLayer:videoLayer inLayer:parentLayer];
    }
    
    AVAssetReaderVideoCompositionOutput *output = [[AVAssetReaderVideoCompositionOutput alloc] initWithVideoTracks:[composition tracksWithMediaType:AVMediaTypeVideo] videoSettings:@{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) }];
    output.videoComposition = videoComposition;
    
    AVAssetImageGenerator *imageGenerator = [[AVAssetImageGenerator alloc] initWithAsset:composition];
    imageGenerator.videoComposition = videoComposition;
    imageGenerator.maximumSize = maxDimensions;
    imageGenerator.requestedTimeToleranceBefore = kCMTimeZero;
    imageGenerator.requestedTimeToleranceAfter = kCMTimeZero;
    
    [conversionContext modify:^id(MediaVideoConversionContext *context)
    {
        return [context addImageGenerator:imageGenerator];
    }];
    
    *outputSettings = [MediaVideoConversionPresetSettings videoSettingsForPreset:preset dimensions:outputDimensions];
    *dimensions = outputDimensions;

    return output;
}

+ (bool)setupAssetReaderWriterForAVAsset:(AVAsset *)avAsset outputURL:(NSURL *)outputURL preset:(MediaVideoConversionPreset)preset adjustments:(MediaVideoEditAdjustments *)adjustments inhibitAudio:(bool)inhibitAudio conversionContext:(SAtomic *)outConversionContext error:(NSError **)error
{
    MediaSampleBufferProcessor *videoProcessor = nil;
    MediaSampleBufferProcessor *audioProcessor = nil;
    
    AVAssetTrack *audioTrack = [[avAsset tracksWithMediaType:AVMediaTypeAudio] firstObject];
    AVAssetTrack *videoTrack = [[avAsset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (videoTrack == nil)
        return false;
    
    CGSize dimensions = CGSizeZero;
    CMTimeRange timeRange = videoTrack.timeRange;
    if (adjustments.trimApplied)
    {
        NSTimeInterval duration = CMTimeGetSeconds(videoTrack.timeRange.duration);
        if (adjustments.trimEndValue < duration)
        {
            timeRange = adjustments.trimTimeRange;
        }
        else
        {
            timeRange = CMTimeRangeMake(CMTimeMakeWithSeconds(adjustments.trimStartValue, NSEC_PER_SEC), CMTimeMakeWithSeconds(duration - adjustments.trimStartValue, NSEC_PER_SEC));
        }
    }
    timeRange = CMTimeRangeMake(CMTimeAdd(timeRange.start, CMTimeMake(10, 100)), CMTimeSubtract(timeRange.duration, CMTimeMake(10, 100)));
    
    NSDictionary *outputSettings = nil;
    AVMutableComposition *composition = [AVMutableComposition composition];
    AVAssetReaderVideoCompositionOutput *output = [self setupVideoCompositionOutputWithAVAsset:avAsset composition:composition videoTrack:videoTrack preset:preset adjustments:adjustments timeRange:timeRange outputSettings:&outputSettings dimensions:&dimensions conversionContext:outConversionContext];
    
    AVAssetReader *assetReader = [[AVAssetReader alloc] initWithAsset:composition error:error];
    if (assetReader == nil)
        return false;
    
    AVAssetWriter *assetWriter = [[AVAssetWriter alloc] initWithURL:outputURL fileType:AVFileTypeMPEG4 error:error];
    if (assetWriter == nil)
        return false;
    
    [assetReader addOutput:output];
    
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:outputSettings];
    [assetWriter addInput:input];
    
    videoProcessor = [[MediaSampleBufferProcessor alloc] initWithAssetReaderOutput:output assetWriterInput:input];
    
    if (!inhibitAudio && [MediaVideoConversionPresetSettings keepAudioForPreset:preset] && audioTrack != nil)
    {
        AVMutableCompositionTrack *trimAudioTrack = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
        [trimAudioTrack insertTimeRange:timeRange ofTrack:audioTrack atTime:kCMTimeZero error:NULL];

        AVAssetReaderOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:trimAudioTrack outputSettings:@{ AVFormatIDKey: @(kAudioFormatLinearPCM) }];
        [assetReader addOutput:output];
        
        AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:[MediaVideoConversionPresetSettings audioSettingsForPreset:preset]];
        [assetWriter addInput:input];
        
        audioProcessor = [[MediaSampleBufferProcessor alloc] initWithAssetReaderOutput:output assetWriterInput:input];
    }
    
    [outConversionContext modify:^id(MediaVideoConversionContext *currentContext)
    {
        return [currentContext contextWithAssetReader:assetReader assetWriter:assetWriter videoProcessor:videoProcessor audioProcessor:audioProcessor timeRange:timeRange dimensions:dimensions];
    }];
    
    return true;
}

+ (void)processWithConversionContext:(SAtomic *)context_ completionBlock:(void (^)(void))completionBlock
{
    MediaVideoConversionContext *context = [context_ value];
    
    if (![context.assetReader startReading])
    {
        [context.subscriber putError:context.assetReader.error];
        return;
    }
    
    if (![context.assetWriter startWriting])
    {
        [context.subscriber putError:context.assetWriter.error];
        return;
    }
    
    dispatch_group_t dispatchGroup = dispatch_group_create();
    
    [context.assetWriter startSessionAtSourceTime:kCMTimeZero];
    
    if (context.audioProcessor != nil)
    {
        dispatch_group_enter(dispatchGroup);
        [context.audioProcessor startWithTimeRange:context.timeRange progressBlock:nil completionBlock:^
        {
            dispatch_group_leave(dispatchGroup);
        }];
    }
    
    if (context.videoProcessor != nil)
    {
        dispatch_group_enter(dispatchGroup);
        
        SSubscriber *subscriber = context.subscriber;
        [context.videoProcessor startWithTimeRange:context.timeRange progressBlock:^(CGFloat progress)
        {
            [subscriber putNext:@(progress)];
        } completionBlock:^
        {
            dispatch_group_leave(dispatchGroup);
        }];
    }
    
    dispatch_group_notify(dispatchGroup, context.queue._dispatch_queue, ^
    {
        MediaVideoConversionContext *context = [context_ value];
        if (context.cancelled)
        {
            [context.assetReader cancelReading];
            [context.assetWriter cancelWriting];
        }
        else
        {
            if (context.assetReader.status != AVAssetReaderStatusFailed)
            {
                [context.assetWriter finishWritingWithCompletionHandler:^
                {
                    if (context.assetWriter.status != AVAssetWriterStatusFailed)
                        completionBlock();
                    else
                        [context.subscriber putError:context.assetWriter.error];
                }];
            }
            else
            {
                [context.subscriber putError:context.assetReader.error];
            }
        }
        
    });
}

#pragma mark - Hash

+ (SSignal *)hashForAVAsset:(AVAsset *)avAsset adjustments:(MediaVideoEditAdjustments *)adjustments
{
    if ([adjustments trimApplied] || [adjustments cropAppliedForAvatar:false] || adjustments.sendAsGif)
        return [SSignal single:nil];
    
    NSURL *fileUrl = nil;
    
    if ([avAsset isKindOfClass:[AVURLAsset class]])
    {
        fileUrl = ((AVURLAsset *)avAsset).URL;
    }
    else
    {
        AVComposition *composition = (AVComposition *)avAsset;
        AVCompositionTrack *videoTrack = [composition tracksWithMediaType:AVMediaTypeVideo].firstObject;
        if (videoTrack != nil)
        {
            AVCompositionTrackSegment *firstSegment = videoTrack.segments.firstObject;
            
            NSMutableData *timingData = [[NSMutableData alloc] init];
            for (AVCompositionTrackSegment *segment in videoTrack.segments)
            {
                CMTimeRange targetRange = segment.timeMapping.target;
                CMTimeValue startTime = targetRange.start.value / targetRange.start.timescale;
                CMTimeValue duration = targetRange.duration.value / targetRange.duration.timescale;
                [timingData appendBytes:&startTime length:sizeof(startTime)];
                [timingData appendBytes:&duration length:sizeof(duration)];
            }
            
            fileUrl = firstSegment.sourceURL;
        }
    }

    return [SSignal new];
//    return [SSignal defer:^SSignal *
//    {
//        NSError *error;
//        NSData *fileData = [NSData dataWithContentsOfURL:fileUrl options:NSDataReadingMappedIfSafe error:&error];
//        if (error == nil)
//            return [SSignal single:[self _hashForVideoWithFileData:fileData timingData:timingData preset:[self _presetFromAdjustments:adjustments]]];
//        else
//            return [SSignal fail:error];
//    }];
}

+ (NSString *)_hashForVideoWithFileData:(NSData *)fileData timingData:(NSData *)timingData preset:(MediaVideoConversionPreset)preset
{
    const NSUInteger bufSize = 1024;
    const NSUInteger numberOfBuffersToRead = 32;
    uint8_t buf[bufSize];
    NSUInteger size = fileData.length;
    
    CC_MD5_CTX md5;
    CC_MD5_Init(&md5);
    
    CC_MD5_Update(&md5, &size, sizeof(size));
    const char *SDString = "SD";
    CC_MD5_Update(&md5, SDString, (CC_LONG)strlen(SDString));
    
    if (timingData != nil)
        CC_MD5_Update(&md5, timingData.bytes, (CC_LONG)timingData.length);
    
    NSMutableData *presetData = [[NSMutableData alloc] init];
    NSInteger presetValue = preset;
    [presetData appendBytes:&presetValue length:sizeof(NSInteger)];
    CC_MD5_Update(&md5, presetData.bytes, (CC_LONG)presetData.length);
    
    for (NSUInteger i = 0; (i < size) && (i < bufSize * numberOfBuffersToRead); i += bufSize)
    {
        [fileData getBytes:buf range:NSMakeRange(i, bufSize)];
        CC_MD5_Update(&md5, buf, bufSize);
    }
    
    for (NSUInteger i = size - MIN(size, bufSize * numberOfBuffersToRead); i < size; i += bufSize)
    {
        [fileData getBytes:buf range:NSMakeRange(i, bufSize)];
        CC_MD5_Update(&md5, buf, bufSize);
    }
    
    unsigned char md5Buffer[16];
    CC_MD5_Final(md5Buffer, &md5);
    NSString *hash = [[NSString alloc] initWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x", md5Buffer[0], md5Buffer[1], md5Buffer[2], md5Buffer[3], md5Buffer[4], md5Buffer[5], md5Buffer[6], md5Buffer[7], md5Buffer[8], md5Buffer[9], md5Buffer[10], md5Buffer[11], md5Buffer[12], md5Buffer[13], md5Buffer[14], md5Buffer[15]];
    
    return hash;
}

+ (MediaVideoConversionPreset)_presetFromAdjustments:(MediaVideoEditAdjustments *)adjustments
{
    MediaVideoConversionPreset preset = adjustments.preset;
    if (preset == MediaVideoConversionPresetCompressedDefault)
    {
        NSNumber *presetValue = [[NSUserDefaults standardUserDefaults] objectForKey:@"TG_preferredVideoPreset_v0"];
        preset = presetValue != nil ? (MediaVideoConversionPreset)presetValue.integerValue : MediaVideoConversionPresetCompressedMedium;
    }
    return preset;
}

#pragma mark - Miscellaneous

+ (CGSize)_renderSizeWithCropSize:(CGSize)cropSize
{
    const CGFloat blockSize = 16.0f;
    
    CGFloat renderWidth = floor(cropSize.width / blockSize) * blockSize;
    CGFloat renderHeight = floor(cropSize.height * renderWidth / cropSize.width);
    if (fmod(renderHeight, blockSize) != 0)
        renderHeight = floor(cropSize.height / blockSize) * blockSize;
    return CGSizeMake(renderWidth, renderHeight);
}

+ (NSURL *)_randomTemporaryURL
{
    return [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSString alloc] initWithFormat:@"%x.tmp", (int)arc4random()]]];
}

+ (NSUInteger)estimatedSizeForPreset:(MediaVideoConversionPreset)preset duration:(NSTimeInterval)duration hasAudio:(bool)hasAudio
{
    NSInteger bitrate = [MediaVideoConversionPresetSettings _videoBitrateKbpsForPreset:preset];
    if (hasAudio)
        bitrate += [MediaVideoConversionPresetSettings _audioBitrateKbpsForPreset:preset] * [MediaVideoConversionPresetSettings _audioChannelsCountForPreset:preset];
    
    NSInteger dataRate = bitrate * 1000 / 8;
    return (NSInteger)(dataRate * duration);
}

+ (MediaVideoConversionPreset)bestAvailablePresetForDimensions:(CGSize)dimensions
{
    MediaVideoConversionPreset preset = MediaVideoConversionPresetCompressedVeryHigh;
    CGFloat maxSide = MAX(dimensions.width, dimensions.height);
    for (NSInteger i = MediaVideoConversionPresetCompressedVeryHigh; i >= MediaVideoConversionPresetCompressedMedium; i--)
    {
        CGFloat presetMaxSide = [MediaVideoConversionPresetSettings maximumSizeForPreset:(MediaVideoConversionPreset)i].width;
        if (maxSide >= presetMaxSide)
            break;
        
        preset = (MediaVideoConversionPreset)i;
    }
    return preset;
}

@end


static CGFloat progressOfSampleBufferInTimeRange(CMSampleBufferRef sampleBuffer, CMTimeRange timeRange)
{
    CMTime progressTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    CMTime sampleDuration = CMSampleBufferGetDuration(sampleBuffer);
    if (CMTIME_IS_NUMERIC(sampleDuration))
        progressTime = CMTimeAdd(progressTime, sampleDuration);
    return MAX(0.0f, MIN(1.0f, CMTimeGetSeconds(progressTime) / CMTimeGetSeconds(timeRange.duration)));
}


@implementation MediaSampleBufferProcessor

- (instancetype)initWithAssetReaderOutput:(AVAssetReaderOutput *)assetReaderOutput assetWriterInput:(AVAssetWriterInput *)assetWriterInput
{
    self = [super init];
    if (self != nil)
    {
        _assetReaderOutput = assetReaderOutput;
        _assetWriterInput = assetWriterInput;
        
        _queue = [[SQueue alloc] init];
        _finished = false;
    }
    return self;
}

- (void)startWithTimeRange:(CMTimeRange)timeRange progressBlock:(void (^)(CGFloat progress))progressBlock completionBlock:(void (^)(void))completionBlock
{
    _completionBlock = [completionBlock copy];
    
    [_assetWriterInput requestMediaDataWhenReadyOnQueue:_queue._dispatch_queue usingBlock:^
    {
        if (_finished)
            return;
        
        bool ended = false;
        while ([_assetWriterInput isReadyForMoreMediaData] && !ended)
        {
            CMSampleBufferRef sampleBuffer = [_assetReaderOutput copyNextSampleBuffer];
            if (sampleBuffer != NULL)
            {
                if (progressBlock != nil)
                    progressBlock(progressOfSampleBufferInTimeRange(sampleBuffer, timeRange));
                
                bool success = [_assetWriterInput appendSampleBuffer:sampleBuffer];
                CFRelease(sampleBuffer);
                
                ended = !success;
            }
            else
            {
                ended = true;
            }
        }
        
        if (ended)
            [self _finish];
    }];
}

- (void)cancel
{
//    [_queue dispatch:^
//    {
//        [self _finish];
//    } synchronous:true];
}

- (void)_finish
{
    bool didFinish = _finished;
    _finished = true;
    
    if (!didFinish)
    {
        [_assetWriterInput markAsFinished];
        
        if (_completionBlock != nil)
        {
            void (^completionBlock)(void) = [_completionBlock copy];
            _completionBlock = nil;
            completionBlock();
        }
    }
}

@end


@implementation MediaVideoFileWatcher

- (instancetype)init
{
    self = [super init];
    if (self != nil)
    {
        _queue = [[SQueue alloc] init];
    }
    return self;
}

- (void)dealloc
{
    dispatch_source_t readerSource = _readerSource;
    
    [_queue dispatch:^
    {
        if (readerSource != nil)
            dispatch_source_cancel(readerSource);
    }];
}

- (void)setupWithFileURL:(NSURL *)fileURL
{
    if (_fileURL != nil)
        return;
    
    _fileURL = fileURL;
    _readerSource = [self _setup];
}

- (dispatch_source_t)_setup
{
    int fd = open([_fileURL.path UTF8String], O_NONBLOCK | O_RDONLY);
    if (fd > 0)
    {
        dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, _queue._dispatch_queue);
        
        __block NSUInteger lastFileSize = 0;
        
        __weak MediaVideoFileWatcher *weakSelf = self;
        dispatch_source_set_event_handler(source, ^
        {
            struct stat st;
            fstat(fd, &st);
            
            if (st.st_size > (long long)(lastFileSize + 32 * 1024))
            {
                lastFileSize = (NSUInteger)st.st_size;
                
                __strong MediaVideoFileWatcher *strongSelf = weakSelf;
                [strongSelf fileUpdated:false];
            }
        });
        
        dispatch_source_set_cancel_handler(source,^
        {
            close(fd);
        });
        
        dispatch_resume(source);
        
        return source;
    }
    
    return nil;
}

- (id)fileUpdated:(bool)__unused completed
{
    return nil;
}

@end


@implementation MediaVideoConversionContext

+ (instancetype)contextWithQueue:(SQueue *)queue subscriber:(SSubscriber *)subscriber
{
    MediaVideoConversionContext *context = [[MediaVideoConversionContext alloc] init];
    context->_queue = queue;
    context->_subscriber = subscriber;
    return context;
}

- (instancetype)cancelledContext
{
    MediaVideoConversionContext *context = [[MediaVideoConversionContext alloc] init];
    context->_queue = _queue;
    context->_subscriber = _subscriber;
    context->_cancelled = true;
    context->_assetReader = _assetReader;
    context->_assetWriter = _assetWriter;
    context->_videoProcessor = _videoProcessor;
    context->_audioProcessor = _audioProcessor;
    context->_timeRange = _timeRange;
    context->_dimensions = _dimensions;
    context->_coverImage = _coverImage;
    context->_imageGenerator = _imageGenerator;
    return context;
}

- (instancetype)finishedContext
{
    MediaVideoConversionContext *context = [[MediaVideoConversionContext alloc] init];
    context->_queue = _queue;
    context->_subscriber = _subscriber;
    context->_cancelled = false;
    context->_finished = true;
    context->_assetReader = _assetReader;
    context->_assetWriter = _assetWriter;
    context->_videoProcessor = _videoProcessor;
    context->_audioProcessor = _audioProcessor;
    context->_timeRange = _timeRange;
    context->_dimensions = _dimensions;
    context->_coverImage = _coverImage;
    context->_imageGenerator = _imageGenerator;
    return context;
}

- (instancetype)addImageGenerator:(AVAssetImageGenerator *)imageGenerator
{
    MediaVideoConversionContext *context = [[MediaVideoConversionContext alloc] init];
    context->_queue = _queue;
    context->_subscriber = _subscriber;
    context->_cancelled = _cancelled;
    context->_assetReader = _assetReader;
    context->_assetWriter = _assetWriter;
    context->_videoProcessor = _videoProcessor;
    context->_audioProcessor = _audioProcessor;
    context->_timeRange = _timeRange;
    context->_dimensions = _dimensions;
    context->_coverImage = _coverImage;
    context->_imageGenerator = imageGenerator;
    return context;
}

- (instancetype)addCoverImage:(UIImage *)coverImage
{
    MediaVideoConversionContext *context = [[MediaVideoConversionContext alloc] init];
    context->_queue = _queue;
    context->_subscriber = _subscriber;
    context->_cancelled = _cancelled;
    context->_assetReader = _assetReader;
    context->_assetWriter = _assetWriter;
    context->_videoProcessor = _videoProcessor;
    context->_audioProcessor = _audioProcessor;
    context->_timeRange = _timeRange;
    context->_dimensions = _dimensions;
    context->_coverImage = coverImage;
    context->_imageGenerator = _imageGenerator;
    return context;
}

- (instancetype)contextWithAssetReader:(AVAssetReader *)assetReader assetWriter:(AVAssetWriter *)assetWriter videoProcessor:(MediaSampleBufferProcessor *)videoProcessor audioProcessor:(MediaSampleBufferProcessor *)audioProcessor timeRange:(CMTimeRange)timeRange dimensions:(CGSize)dimensions
{
    MediaVideoConversionContext *context = [[MediaVideoConversionContext alloc] init];
    context->_queue = _queue;
    context->_subscriber = _subscriber;
    context->_cancelled = _cancelled;
    context->_assetReader = assetReader;
    context->_assetWriter = assetWriter;
    context->_videoProcessor = videoProcessor;
    context->_audioProcessor = audioProcessor;
    context->_timeRange = timeRange;
    context->_dimensions = dimensions;
    context->_coverImage = _coverImage;
    context->_imageGenerator = _imageGenerator;
    return context;
}

@end


@implementation MediaVideoConversionResult

+ (instancetype)resultWithFileURL:(NSURL *)fileUrl fileSize:(NSUInteger)fileSize duration:(NSTimeInterval)duration dimensions:(CGSize)dimensions coverImage:(UIImage *)coverImage liveUploadData:(id)livaUploadData
{
    MediaVideoConversionResult *result = [[MediaVideoConversionResult alloc] init];
    result->_fileURL = fileUrl;
    result->_fileSize = fileSize;
    result->_duration = duration;
    result->_dimensions = dimensions;
    result->_coverImage = coverImage;
    result->_liveUploadData = livaUploadData;
    return result;
}

- (NSDictionary *)dictionary
{
    NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
    dict[@"fileUrl"] = self.fileURL;
    dict[@"dimensions"] = [NSValue valueWithCGSize:self.dimensions];
    dict[@"duration"] = @(self.duration);
    if (self.coverImage != nil)
        dict[@"previewImage"] = self.coverImage;
    if (self.liveUploadData != nil)
        dict[@"liveUploadData"] = self.liveUploadData;
    return dict;
}

@end


@implementation MediaVideoConversionPresetSettings

+ (CGSize)maximumSizeForPreset:(MediaVideoConversionPreset)preset
{
    switch (preset)
    {
        case MediaVideoConversionPresetCompressedVeryLow:
            return (CGSize){ 480.0f, 480.0f };
            
        case MediaVideoConversionPresetCompressedLow:
            return (CGSize){ 640.0f, 640.0f };

        case MediaVideoConversionPresetCompressedMedium:
            return (CGSize){ 848.0f, 848.0f };
            
        case MediaVideoConversionPresetCompressedHigh:
            return (CGSize){ 1280.0f, 1280.0f };
            
        case MediaVideoConversionPresetCompressedVeryHigh:
            return (CGSize){ 1920.0f, 1920.0f };
            
        default:
            return (CGSize){ 640.0f, 640.0f };
    }
}

+ (bool)keepAudioForPreset:(MediaVideoConversionPreset)preset
{
    return preset != MediaVideoConversionPresetAnimation;
}

+ (NSDictionary *)audioSettingsForPreset:(MediaVideoConversionPreset)preset
{
    NSInteger bitrate = [self _audioBitrateKbpsForPreset:preset];
    NSInteger channels = [self _audioChannelsCountForPreset:preset];
    
    AudioChannelLayout acl;
    bzero( &acl, sizeof(acl));
    acl.mChannelLayoutTag = channels > 1 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_Mono;
    
    return @
    {
      AVFormatIDKey: @(kAudioFormatMPEG4AAC),
      AVSampleRateKey: @44100.0f,
      AVEncoderBitRateKey: @(bitrate * 1000),
      AVNumberOfChannelsKey: @(channels),
      AVChannelLayoutKey: [NSData dataWithBytes:&acl length:sizeof(acl)]
    };
}

+ (NSDictionary *)videoSettingsForPreset:(MediaVideoConversionPreset)preset dimensions:(CGSize)dimensions
{
    NSDictionary *videoCleanApertureSettings = @
    {
        AVVideoCleanApertureWidthKey: @((NSInteger)dimensions.width),
        AVVideoCleanApertureHeightKey: @((NSInteger)dimensions.height),
        AVVideoCleanApertureHorizontalOffsetKey: @10,
        AVVideoCleanApertureVerticalOffsetKey: @10
    };
    
    NSDictionary *videoAspectRatioSettings = @
    {
        AVVideoPixelAspectRatioHorizontalSpacingKey: @3,
        AVVideoPixelAspectRatioVerticalSpacingKey: @3
    };
    
    NSDictionary *codecSettings = @
    {
        AVVideoAverageBitRateKey: @([self _videoBitrateKbpsForPreset:preset] * 1000),
        AVVideoCleanApertureKey: videoCleanApertureSettings,
        AVVideoPixelAspectRatioKey: videoAspectRatioSettings
    };
    
    return @
    {
        AVVideoCodecKey: AVVideoCodecH264,
        AVVideoCompressionPropertiesKey: codecSettings,
        AVVideoWidthKey: @((NSInteger)dimensions.width),
        AVVideoHeightKey: @((NSInteger)dimensions.height)
    };
}

+ (NSInteger)_videoBitrateKbpsForPreset:(MediaVideoConversionPreset)preset
{
    switch (preset)
    {
        case MediaVideoConversionPresetCompressedVeryLow:
            return 400;
            
        case MediaVideoConversionPresetCompressedLow:
            return 700;
            
        case MediaVideoConversionPresetCompressedMedium:
            return 1100;
            
        case MediaVideoConversionPresetCompressedHigh:
            return 2500;
            
        case MediaVideoConversionPresetCompressedVeryHigh:
            return 4000;
            
        default:
            return 700;
    }
}

+ (NSInteger)_audioBitrateKbpsForPreset:(MediaVideoConversionPreset)preset
{
    switch (preset)
    {
        case MediaVideoConversionPresetCompressedVeryLow:
            return 32;
            
        case MediaVideoConversionPresetCompressedLow:
            return 32;
            
        case MediaVideoConversionPresetCompressedMedium:
            return 64;
            
        case MediaVideoConversionPresetCompressedHigh:
            return 64;
            
        case MediaVideoConversionPresetCompressedVeryHigh:
            return 64;
            
        default:
            return 32;
    }
}

+ (NSInteger)_audioChannelsCountForPreset:(MediaVideoConversionPreset)preset
{
    switch (preset)
    {
        case MediaVideoConversionPresetCompressedVeryLow:
            return 1;
            
        case MediaVideoConversionPresetCompressedLow:
            return 1;
            
        case MediaVideoConversionPresetCompressedMedium:
            return 2;
            
        case MediaVideoConversionPresetCompressedHigh:
            return 2;
            
        case MediaVideoConversionPresetCompressedVeryHigh:
            return 2;
            
        default:
            return 1;
    }
}

@end
