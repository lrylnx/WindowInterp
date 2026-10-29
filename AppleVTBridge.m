#import "AppleVTBridge.h"
#import <VideoToolbox/VideoToolbox.h>
// Public VideoToolbox API, resolved at runtime for builds using the older installed SDK.
// This is the low-latency processor used by frameinterp/gpu, not FrameRateConversion.
@protocol WIAppleRuntime
+ (BOOL)isSupported;
- (id)initWithFrameWidth:(NSInteger)width frameHeight:(NSInteger)height numberOfInterpolatedFrames:(NSInteger)count;
- (NSDictionary *)sourcePixelBufferAttributes;
- (NSDictionary *)destinationPixelBufferAttributes;
- (id)initWithBuffer:(CVPixelBufferRef)buffer presentationTimeStamp:(CMTime)pts;
- (id)initWithSourceFrame:(id)source previousFrame:(id)previous interpolationPhase:(NSArray *)phases destinationFrames:(NSArray *)destinations;
- (BOOL)startSessionWithConfiguration:(id)configuration error:(NSError **)error;
- (void)processWithParameters:(id)parameters completionHandler:(void (^)(id, NSError *))completion;
- (void)endSession;
@end
static NSError *WIError(NSString *message) {
    return [NSError errorWithDomain:@"WindowInterp.Apple" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}
BOOL WIAppleSupported(void) {
    Class c = NSClassFromString(@"VTLowLatencyFrameInterpolationConfiguration");
    return c && [c respondsToSelector:@selector(isSupported)] && [(id<WIAppleRuntime>)c isSupported];
}
NSObject *WIAppleConfiguration(NSInteger w, NSInteger h) {
    return WIAppleConfigurationForMultiplier(w, h, 2);
}
NSObject *WIAppleConfigurationForMultiplier(NSInteger w, NSInteger h, NSInteger multiplier) {
    if (!WIAppleSupported() || (multiplier != 2 && multiplier != 4)) return nil;
    // Apple defines a depth: 1 exposes 0.5; 2 exposes 0.25, 0.5, 0.75.
    return (NSObject *)[(id<WIAppleRuntime>)[NSClassFromString(@"VTLowLatencyFrameInterpolationConfiguration") alloc]
        initWithFrameWidth:w frameHeight:h numberOfInterpolatedFrames:(multiplier == 4 ? 2 : 1)];
}
NSDictionary *WIAppleAttributes(NSObject *c, BOOL d) {
    return d ? [(id<WIAppleRuntime>)c destinationPixelBufferAttributes] : [(id<WIAppleRuntime>)c sourcePixelBufferAttributes];
}
NSObject *WIAppleProcessor(void) { return [NSClassFromString(@"VTFrameProcessor") new]; }
NSError *WIAppleStart(NSObject *p, NSObject *c) {
    NSError *e = nil;
    return [(id<WIAppleRuntime>)p startSessionWithConfiguration:c error:&e] ? nil : (e ?: WIError(@"苹果插帧会话启动失败"));
}
NSError *WIAppleInterpolate(NSObject *p, CVPixelBufferRef a, CMTime at, CVPixelBufferRef b, CMTime bt, CVPixelBufferRef d) {
    @autoreleasepool { return WIAppleInterpolateFrames(p, a, at, b, bt, (__bridge CFArrayRef)@[(__bridge id)d]); }
}
NSError *WIAppleInterpolateFrames(NSObject *p, CVPixelBufferRef a, CMTime at, CVPixelBufferRef b, CMTime bt, CFArrayRef destinations) {
    @autoreleasepool {
    Class frame = NSClassFromString(@"VTFrameProcessorFrame");
    id af = [(id<WIAppleRuntime>)[frame alloc] initWithBuffer:a presentationTimeStamp:at];
    id bf = [(id<WIAppleRuntime>)[frame alloc] initWithBuffer:b presentationTimeStamp:bt];
    NSArray *buffers = (__bridge NSArray *)destinations;
    if (!af || !bf || (buffers.count != 1 && buffers.count != 3)) return WIError(@"苹果插帧无法创建输入或输出帧");
    NSMutableArray *frames = [NSMutableArray array], *phases = [NSMutableArray array];
    for (NSUInteger i = 0; i < buffers.count; i++) {
        double phase = (double)(i + 1) / (buffers.count + 1);
        CMTime time = CMTimeAdd(at, CMTimeMultiplyByFloat64(CMTimeSubtract(bt, at), phase));
        id f = [(id<WIAppleRuntime>)[frame alloc] initWithBuffer:(__bridge CVPixelBufferRef)buffers[i] presentationTimeStamp:time];
        if (!f) return WIError(@"苹果插帧无法创建输出帧");
        [frames addObject:f]; [phases addObject:@(phase)];
    }
    id params = [(id<WIAppleRuntime>)[NSClassFromString(@"VTLowLatencyFrameInterpolationParameters") alloc]
        initWithSourceFrame:bf previousFrame:af interpolationPhase:phases destinationFrames:frames];
    if (!params) return WIError(@"苹果插帧参数不支持当前尺寸或格式");
    __block NSError *error = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [(id<WIAppleRuntime>)p processWithParameters:params completionHandler:^(id result, NSError *e) {
        error = e;
        dispatch_semaphore_signal(sem);
    }];
    // The owning serial queue also owns endSession, so shutdown cannot race a request.
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    return error;
    }
}
void WIAppleEnd(NSObject *p) { [(id<WIAppleRuntime>)p endSession]; }
