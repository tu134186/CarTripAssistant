#import <UIKit/UIKit.h>
@interface BaiduMapHostView : UIView
- (void)renderSegments:(NSArray<NSDictionary *> *)segments
                playback:(nullable NSArray<NSNumber *> *)playback;
- (void)fitReplayRoute:(NSArray<NSArray<NSNumber *> *> *)points active:(BOOL)active;
- (void)followPlaybackPosition:(nullable NSArray<NSNumber *> *)position;
- (void)setLivePosition:(nullable NSArray<NSNumber *> *)position mode:(NSInteger)mode heading:(double)heading;
@end
