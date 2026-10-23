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
    if (!WIAppleSupported()) return nil;
    return (NSObject *)[(id<WIAppleRuntime>)[NSClassFromString(@"VTLowLatencyFrameInterpolationConfiguration") alloc]
        initWithFrameWidth:w frameHeight:h numberOfInterpolatedFrames:1];
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
    Class frame = NSClassFromString(@"VTFrameProcessorFrame");
    CMTime mt = CMTimeAdd(at, CMTimeMultiplyByFloat64(CMTimeSubtract(bt, at), 0.5));
    id af = [(id<WIAppleRuntime>)[frame alloc] initWithBuffer:a presentationTimeStamp:at];
    id bf = [(id<WIAppleRuntime>)[frame alloc] initWithBuffer:b presentationTimeStamp:bt];
    id df = [(id<WIAppleRuntime>)[frame alloc] initWithBuffer:d presentationTimeStamp:mt];
    if (!af || !bf || !df) return WIError(@"苹果插帧无法创建输入或输出帧");
    id params = [(id<WIAppleRuntime>)[NSClassFromString(@"VTLowLatencyFrameInterpolationParameters") alloc]
        initWithSourceFrame:bf previousFrame:af interpolationPhase:@[@0.5] destinationFrames:@[df]];
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
void WIAppleEnd(NSObject *p) { [(id<WIAppleRuntime>)p endSession]; }
