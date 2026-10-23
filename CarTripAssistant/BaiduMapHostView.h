#import <UIKit/UIKit.h>
@interface BaiduMapHostView : UIView
- (void)renderCoordinates:(NSArray<NSArray<NSNumber *> *> *)coordinates
                playback:(nullable NSArray<NSNumber *> *)playback;
@end
