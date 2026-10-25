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
@property(nonatomic,assign) double lastValidHeading;
@property(nonatomic,assign) BOOL navigationZoomInitialized;
@property(nonatomic,assign) NSInteger previousCameraMode;
@property(nonatomic,assign) BOOL cameraModeReady;
@property(nonatomic,assign) CLLocationCoordinate2D lastCameraFix;
@property(nonatomic,assign) BOOL hasCameraFix;
@property(nonatomic,assign) BOOL replayCameraFitted;
@property(nonatomic,assign) BOOL pendingFit;
@property(nonatomic,assign) BMKCoordinateRegion initialRegion;
@property(nonatomic,strong) BMKPointAnnotation *startPin;
@property(nonatomic,strong) NSArray<NSDictionary *> *lastSegments;
@property(nonatomic,strong) NSMutableArray<BMKPolyline *> *passengerLines;
@property(nonatomic,strong) NSMutableArray<BMKPolyline *> *routeLines;
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
- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.pendingFit && self.bounds.size.width > 0 && self.bounds.size.height > 0) {
        [self.map setRegion:self.initialRegion animated:NO];
        self.pendingFit = NO;
        self.fitted = YES;
    }
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
        // Preserve unchanged overlays while playback extends or rewinds.
        NSArray<NSDictionary *> *old = self.lastSegments ?: @[];
        NSUInteger common = 0;
        while (common < old.count && common < segments.count &&
               [old[common] isEqualToDictionary:segments[common]]) common++;
        if (!self.routeLines) self.routeLines = [NSMutableArray array];
        for (NSUInteger i=self.routeLines.count; i>common; i--) {
            id line=self.routeLines[i-1];
            if (line != (id)[NSNull null]) [self.map removeOverlay:line];
            [self.routeLines removeObjectAtIndex:i-1];
        }
        NSMutableArray<NSArray<NSNumber *> *> *all = [NSMutableArray array];
        self.passengerLines = [NSMutableArray array];
        for (NSUInteger idx=0; idx<segments.count; idx++) {
            NSDictionary *entry=segments[idx];
            NSArray<NSArray<NSNumber *> *> *pairs=entry[@"points"];
            if (pairs.count) [all addObjectsFromArray:pairs];
            if (idx>=common) {
                if (pairs.count<2) {
                    [self.routeLines addObject:(id)[NSNull null]];
                } else {
                    CLLocationCoordinate2D *coords=calloc(pairs.count,sizeof(CLLocationCoordinate2D));
                    for (NSUInteger i=0;i<pairs.count;i++) coords[i]=[self baidu:pairs[i]];
                    BMKPolyline *line=[BMKPolyline polylineWithCoordinates:coords count:pairs.count];
                    free(coords);
                    [self.routeLines addObject:line];
                    // Baidu SDK may ask for the overlay renderer immediately.
                    // Register passenger classification before addOverlay.
                    if ([entry[@"passenger"] boolValue]) [self.passengerLines addObject:line];
                    [self.map addOverlay:line];
                }
            }
            id line=self.routeLines[idx];
            if ([entry[@"passenger"] boolValue] && line != (id)[NSNull null])
                [self.passengerLines addObject:line];
        }
        self.lastSegments=[segments copy];
        if (!all.count) {
            if (self.startPin) { [self.map removeAnnotation:self.startPin]; self.startPin=nil; }
            // Playback may temporarily have zero drawable segments (first GPS
            // fix). Keep the full-day camera instead of resetting its fit.
            // A new map view starts with fitted=NO naturally.
        }
        if (all.count) {
            CLLocationCoordinate2D first=[self baidu:all.firstObject];
            if (!self.startPin) { self.startPin=[BMKPointAnnotation new]; self.startPin.title=@"起点"; [self.map addAnnotation:self.startPin]; }
            self.startPin.coordinate=first;
            if (!self.fitted) {
                CLLocationDegrees minLat=90,maxLat=-90,minLon=180,maxLon=-180;
                for (NSArray<NSNumber *> *pair in all) {
                    CLLocationCoordinate2D p=[self baidu:pair];
                    minLat=MIN(minLat,p.latitude);maxLat=MAX(maxLat,p.latitude);
                    minLon=MIN(minLon,p.longitude);maxLon=MAX(maxLon,p.longitude);
                }
                // Fit the actual Shenzhen track bounds rather than the SDK's
                // default world view. Keep a minimum span for very short trips.
                BMKCoordinateSpan span=BMKCoordinateSpanMake(MAX(0.003,(maxLat-minLat)*1.25),MAX(0.003,(maxLon-minLon)*1.25));
                self.initialRegion = BMKCoordinateRegionMake(CLLocationCoordinate2DMake((minLat+maxLat)/2,(minLon+maxLon)/2),span);
                self.pendingFit = YES;
                [self setNeedsLayout];
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
- (void)fitReplayRoute:(NSArray<NSArray<NSNumber *> *> *)points active:(BOOL)active {
    if (!active) { self.replayCameraFitted=NO; return; }
    if (self.replayCameraFitted || !self.map || points.count < 2) return;
    CLLocationDegrees minLat=90,maxLat=-90,minLon=180,maxLon=-180;
    for (NSArray<NSNumber *> *pair in points) {
        if (pair.count != 2) continue;
        CLLocationCoordinate2D p=[self baidu:pair];
        minLat=MIN(minLat,p.latitude);maxLat=MAX(maxLat,p.latitude);
        minLon=MIN(minLon,p.longitude);maxLon=MAX(maxLon,p.longitude);
    }
    if (minLat > maxLat) return;
    self.map.rotation=0;
    BMKCoordinateSpan span=BMKCoordinateSpanMake(MAX(0.003,(maxLat-minLat)*1.35),
                                                 MAX(0.003,(maxLon-minLon)*1.35));
    [self.map setRegion:BMKCoordinateRegionMake(
        CLLocationCoordinate2DMake((minLat+maxLat)/2,(minLon+maxLon)/2),span) animated:NO];
    self.pendingFit=NO;
    self.fitted=YES;
    self.replayCameraFitted=YES;
}
- (void)followPlaybackPosition:(NSArray<NSNumber *> *)position {
    // Fixed viewport during replay: only the historical car moves.
    (void)position;
}
- (void)setLivePosition:(NSArray<NSNumber *> *)position mode:(NSInteger)mode heading:(double)heading {
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
    // Do not let inaccurate stationary GPS fixes pull the car into adjacent lanes.
    if (mode != 0 && self.hasCameraFix) {
        CLLocation *oldFix=[[CLLocation alloc] initWithLatitude:self.lastCameraFix.latitude longitude:self.lastCameraFix.longitude];
        CLLocation *newFix=[[CLLocation alloc] initWithLatitude:coordinate.latitude longitude:coordinate.longitude];
        if ([oldFix distanceFromLocation:newFix] < 8.0) coordinate=self.lastCameraFix;
    }
    self.livePin.coordinate=coordinate;
    // Replay keeps its existing full-route overview. Live camera modes are independent.
    if (self.vehicle) return;
    BOOL modeChanged = !self.cameraModeReady || self.previousCameraMode != mode;
    self.previousCameraMode = mode;
    self.cameraModeReady = YES;
    self.map.rotateEnabled = (mode == 0);
    self.map.overlookEnabled = NO;
    if (mode == 0) return; // Free browsing: preserve user camera and zoom.

    CLLocation *oldFix = self.hasCameraFix
        ? [[CLLocation alloc] initWithLatitude:self.lastCameraFix.latitude longitude:self.lastCameraFix.longitude]
        : nil;
    CLLocation *newFix = [[CLLocation alloc] initWithLatitude:coordinate.latitude longitude:coordinate.longitude];
    BOOL moved = !oldFix || [oldFix distanceFromLocation:newFix] >= 5.0;
    if (moved) {
        self.lastCameraFix=coordinate;
        self.hasCameraFix=YES;
    }
    if (!self.navigationZoomInitialized) {
        self.map.zoomLevel = 17.5f;
        self.navigationZoomInitialized = YES;
    }
    if (mode == 2) {
        if (isfinite(heading) && heading >= 0 && heading < 360) {
            double delta = remainder(heading - self.lastValidHeading, 360.0);
            if (modeChanged || fabs(delta) >= 5.0)
                self.lastValidHeading = fmod(self.lastValidHeading + delta + 360.0, 360.0);
        }
        double rotationDelta = fabs(remainder(self.lastValidHeading - self.map.rotation, 360.0));
        if (modeChanged || rotationDelta >= 3.0)
            self.map.rotation = (int)lrint(self.lastValidHeading);
    } else if (modeChanged || fabs(self.map.rotation) > 0.5) {
        self.map.rotation = 0;
    }
    // Only update camera when necessary; do not reset zoom at each GPS fix.
    if (!modeChanged && !moved) return;
    if (mode == 2 && self.map.bounds.size.height > 0) {
        [self.map setCenterCoordinate:coordinate animated:NO];
        CGPoint ahead = CGPointMake(CGRectGetMidX(self.map.bounds),
                                    CGRectGetHeight(self.map.bounds) * 0.28);
        CLLocationCoordinate2D center = [self.map convertPoint:ahead toCoordinateFromView:self.map];
        if (CLLocationCoordinate2DIsValid(center))
            [self.map setCenterCoordinate:center animated:NO];
    } else {
        [self.map setCenterCoordinate:coordinate animated:NO];
    }
}
- (BMKAnnotationView *)mapView:(BMKMapView *)mapView viewForAnnotation:(id<BMKAnnotation>)annotation {
    if (annotation != self.vehicle && annotation != self.livePin) return nil;
    static NSString *reuseID = @"CarTripVehicle";
    BMKAnnotationView *view = [mapView dequeueReusableAnnotationViewWithIdentifier:reuseID];
    if (!view) {
        view = [[BMKAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:reuseID];
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightSemibold];
        UIImage *symbol = [UIImage systemImageNamed:@"car.fill" withConfiguration:config];
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(26, 26)];
        view.image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [[UIColor colorWithRed:0.07 green:0.43 blue:0.88 alpha:1] setFill];
            [symbol drawInRect:CGRectMake(3, 4, 20, 18)];
        }];
        view.centerOffset = CGPointZero;
    }
    view.annotation = annotation;
    return view;
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
