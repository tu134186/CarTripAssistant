#import "BaiduMapHostView.h"
#import <CoreLocation/CoreLocation.h>
#import <BaiduMapAPI_Base/BMKBaseComponent.h>
#import <BaiduMapAPI_Map/BMKMapComponent.h>
#import <BaiduMapAPI_Utils/BMKUtilsComponent.h>

@interface BaiduMapHostView () <BMKMapViewDelegate>
@property(nonatomic,strong) BMKMapView *map;
@property(nonatomic,strong) BMKPointAnnotation *vehicle;
@property(nonatomic,strong) BMKPointAnnotation *livePin;
@property(nonatomic,assign) BOOL fitted;
@property(nonatomic,strong) BMKPointAnnotation *startPin;
@property(nonatomic,strong) BMKPointAnnotation *endPin;
@property(nonatomic,strong) NSArray<NSDictionary *> *lastSegments;
@property(nonatomic,strong) NSMutableArray<BMKPolyline *> *passengerLines;
@end

@implementation BaiduMapHostView
static BMKMapManager *sharedManager;
static BOOL started = NO;
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        if (!started) {
            NSString *key = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"BaiduMapAK"];
            if (key.length) {
                [BMKMapManager setAgreePrivacy:YES]; // Host is created only after explicit in-app consent.
                sharedManager = [BMKMapManager new];
                started = [sharedManager start:key generalDelegate:nil];
            }
        }
        if (started) {
            _map = [[BMKMapView alloc] initWithFrame:self.bounds];
            _map.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            _map.delegate = self;
            [self addSubview:_map];
        }
    }
    return self;
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) { [self.map viewWillAppear]; }
    else { [self.map viewWillDisappear]; }
}
- (CLLocationCoordinate2D)baidu:(NSArray<NSNumber *> *)pair {
    CLLocationCoordinate2D gps = CLLocationCoordinate2DMake(pair[0].doubleValue, pair[1].doubleValue);
    return BMKCoordTrans(gps, BMK_COORDTYPE_GPS, BMK_COORDTYPE_BD09LL);
}
- (void)renderSegments:(NSArray<NSDictionary *> *)segments playback:(NSArray<NSNumber *> *)playback {
    if (!self.map) return;
    if (![self.lastSegments isEqualToArray:segments]) {
        self.lastSegments = [segments copy];
        if (self.passengerLines.count) {
            for (BMKPolyline *line in self.passengerLines) [self.map removeOverlay:line];
        }
        self.passengerLines = [NSMutableArray array];
        NSMutableArray<NSArray<NSNumber *> *> *all = [NSMutableArray array];
        for (NSDictionary *entry in segments) {
            NSArray<NSArray<NSNumber *> *> *pairs = entry[@"points"];
            if (pairs.count == 0) continue;
            [all addObjectsFromArray:pairs];
            if (pairs.count < 2) continue;
            CLLocationCoordinate2D *coords = calloc(pairs.count, sizeof(CLLocationCoordinate2D));
            for (NSUInteger i=0;i<pairs.count;i++) coords[i]=[self baidu:pairs[i]];
            BMKPolyline *line=[BMKPolyline polylineWithCoordinates:coords count:pairs.count];
            free(coords);
            if ([entry[@"passenger"] boolValue]) [self.passengerLines addObject:line];
            [self.map addOverlay:line];
        }
        if (!all.count) {
            if (self.startPin) { [self.map removeAnnotation:self.startPin]; self.startPin=nil; }
            if (self.endPin) { [self.map removeAnnotation:self.endPin]; self.endPin=nil; }
            self.fitted=NO;
        }
        if (all.count) {
            CLLocationCoordinate2D first=[self baidu:all.firstObject], last=[self baidu:all.lastObject];
            if (!self.startPin) { self.startPin=[BMKPointAnnotation new]; self.startPin.title=@"起点"; [self.map addAnnotation:self.startPin]; }
            if (!self.endPin) { self.endPin=[BMKPointAnnotation new]; self.endPin.title=@"终点 / 最新位置"; [self.map addAnnotation:self.endPin]; }
            self.startPin.coordinate=first;
            self.endPin.coordinate=last;
            if (!self.fitted) {
                CLLocationDegrees minLat=90,maxLat=-90,minLon=180,maxLon=-180;
                for (NSArray<NSNumber *> *pair in all) {
                    CLLocationCoordinate2D p=[self baidu:pair];
                    minLat=MIN(minLat,p.latitude);maxLat=MAX(maxLat,p.latitude);
                    minLon=MIN(minLon,p.longitude);maxLon=MAX(maxLon,p.longitude);
                }
                BMKCoordinateSpan span=BMKCoordinateSpanMake(MAX(0.005,(maxLat-minLat)*1.3),MAX(0.005,(maxLon-minLon)*1.3));
                [self.map setRegion:BMKCoordinateRegionMake(CLLocationCoordinate2DMake((minLat+maxLat)/2,(minLon+maxLon)/2),span) animated:NO];
                self.fitted=YES;
            }
        }
    }
    if (playback.count==2) {
        if (!self.vehicle) { self.vehicle=[BMKPointAnnotation new]; self.vehicle.title=@"回放车辆"; [self.map addAnnotation:self.vehicle]; }
        self.vehicle.coordinate=[self baidu:playback];
    } else if (self.vehicle) {
        [self.map removeAnnotation:self.vehicle];self.vehicle=nil;
    }
}
- (void)setLivePosition:(NSArray<NSNumber *> *)position follow:(BOOL)follow {
    if (!self.map) return;
    if (position.count != 2) {
        if (self.livePin) { [self.map removeAnnotation:self.livePin]; self.livePin=nil; }
        return;
    }
    CLLocationCoordinate2D coordinate=[self baidu:position];
    if (!self.livePin) {
        self.livePin=[BMKPointAnnotation new];
        self.livePin.title=@"实时位置";
        [self.map addAnnotation:self.livePin];
    }
    self.livePin.coordinate=coordinate;
    if (follow) {
        CLLocation *oldCenter = [[CLLocation alloc] initWithLatitude:self.map.centerCoordinate.latitude longitude:self.map.centerCoordinate.longitude];
        CLLocation *newCenter = [[CLLocation alloc] initWithLatitude:coordinate.latitude longitude:coordinate.longitude];
        if ([oldCenter distanceFromLocation:newCenter] > 12) {
            [self.map setCenterCoordinate:coordinate animated:YES];
        }
    }
}
- (BMKOverlayView *)mapView:(BMKMapView *)mapView viewForOverlay:(id<BMKOverlay>)overlay {
    if ([overlay isKindOfClass:[BMKPolyline class]]) {
        BMKPolylineView *line=[[BMKPolylineView alloc] initWithPolyline:(BMKPolyline *)overlay];
        BOOL passenger=[self.passengerLines containsObject:(BMKPolyline *)overlay];
        line.strokeColor=passenger ? [UIColor colorWithRed:0.12 green:0.76 blue:0.38 alpha:0.95] : [UIColor colorWithRed:0.07 green:0.48 blue:0.98 alpha:0.95];
        line.lineWidth=5;
        return line;
    }
    return nil;
}
- (void)dealloc {
    [self.map viewWillDisappear];
    self.map.delegate=nil;
}
@end
