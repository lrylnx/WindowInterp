#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
NS_ASSUME_NONNULL_BEGIN
BOOL WIAppleSupported(void);
NSObject * _Nullable WIAppleConfiguration(NSInteger width, NSInteger height);
NSObject * _Nullable WIAppleConfigurationForMultiplier(NSInteger width, NSInteger height, NSInteger multiplier);
NSDictionary *WIAppleAttributes(NSObject *configuration, BOOL destination);
NSObject * _Nullable WIAppleProcessor(void);
NSError * _Nullable WIAppleStart(NSObject *processor, NSObject *configuration);
NSError * _Nullable WIAppleInterpolate(NSObject *processor, CVPixelBufferRef previous,
    CMTime previousPTS, CVPixelBufferRef current, CMTime currentPTS, CVPixelBufferRef destination);
NSError * _Nullable WIAppleInterpolateFrames(NSObject *processor, CVPixelBufferRef previous, CMTime previousPTS,
    CVPixelBufferRef current, CMTime currentPTS, CFArrayRef destinations);
void WIAppleEnd(NSObject *processor);
NS_ASSUME_NONNULL_END
