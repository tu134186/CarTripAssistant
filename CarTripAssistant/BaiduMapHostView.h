#import <UIKit/UIKit.h>
@interface BaiduMapHostView : UIView
- (void)renderCoordinates:(NSArray<NSArray<NSNumber *> *> *)coordinates
                playback:(nullable NSArray<NSNumber *> *)playback;
- (void)renderSegments:(NSArray<NSDictionary *> *)segments
                playback:(nullable NSArray<NSNumber *> *)playback;
- (void)setLivePosition:(nullable NSArray<NSNumber *> *)position follow:(BOOL)follow;
@end
