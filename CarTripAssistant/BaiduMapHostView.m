#import "BaiduMapHostView.h"
#import <CoreLocation/CoreLocation.h>
#import <BaiduMapAPI_Base/BMKBaseComponent.h>
#import <BaiduMapAPI_Map/BMKMapComponent.h>
#import <BaiduMapAPI_Utils/BMKUtilsComponent.h>

@interface BaiduMapHostView () <BMKMapViewDelegate>
@property(nonatomic,strong) BMKMapView *map;
@property(nonatomic,strong) NSArray<NSArray<NSNumber *> *> *previousCoordinates;
@property(nonatomic,strong) BMKPolyline *route;
@property(nonatomic,strong) BMKPointAnnotation *vehicle;
@property(nonatomic,assign) BOOL fitted;
@property(nonatomic,strong) BMKPointAnnotation *startPin;
@property(nonatomic,strong) BMKPointAnnotation *endPin;
@property(nonatomic,strong) NSArray<NSArray<NSNumber *> *> *lastPairs;
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
- (void)renderCoordinates:(NSArray<NSArray<NSNumber *> *> *)coordinates
                playback:(NSArray<NSNumber *> *)playback {
    if (!self.map) return;
    BOOL changed = ![self.lastPairs isEqualToArray:coordinates];
    if (changed) {
        self.lastPairs = [coordinates copy];
        if (self.route) { [self.map removeOverlay:self.route]; self.route = nil; }
        self.previousCoordinates = coordinates;
        NSUInteger count = coordinates.count;
        if (count) {
            CLLocationCoordinate2D first = [self baidu:coordinates.firstObject];
            CLLocationCoordinate2D last = [self baidu:coordinates.lastObject];
            if (!self.startPin) { self.startPin = [BMKPointAnnotation new]; self.startPin.title = @"起点"; [self.map addAnnotation:self.startPin]; }
            if (!self.endPin) { self.endPin = [BMKPointAnnotation new]; self.endPin.title = @"终点 / 最新位置"; [self.map addAnnotation:self.endPin]; }
            self.startPin.coordinate = first;
            self.endPin.coordinate = last;
        }
        if (count > 1) {
            CLLocationCoordinate2D *coords = calloc(count, sizeof(CLLocationCoordinate2D));
            for (NSUInteger i = 0; i < count; i++) coords[i] = [self baidu:coordinates[i]];
            self.route = [BMKPolyline polylineWithCoordinates:coords count:(NSUInteger)count];
            [self.map addOverlay:self.route];
            if (!self.fitted) {
                CLLocationDegrees minLat=90,maxLat=-90,minLon=180,maxLon=-180;
                for (NSUInteger i=0;i<count;i++) {
                    minLat=MIN(minLat,coords[i].latitude); maxLat=MAX(maxLat,coords[i].latitude);
                    minLon=MIN(minLon,coords[i].longitude); maxLon=MAX(maxLon,coords[i].longitude);
                }
                CLLocationCoordinate2D center=CLLocationCoordinate2DMake((minLat+maxLat)/2,(minLon+maxLon)/2);
                BMKCoordinateSpan span=BMKCoordinateSpanMake(MAX(0.005,(maxLat-minLat)*1.3),MAX(0.005,(maxLon-minLon)*1.3));
                [self.map setRegion:BMKCoordinateRegionMake(center,span) animated:NO];
                self.fitted=YES;
            }
            free(coords);
        } else if (count == 1 && !self.fitted) {
            CLLocationCoordinate2D center=[self baidu:coordinates[0]];
            [self.map setRegion:BMKCoordinateRegionMake(center,BMKCoordinateSpanMake(0.015,0.015)) animated:NO];
            self.fitted=YES;
        }
    }
    if (playback.count == 2) {
        if (!self.vehicle) {
            self.vehicle=[BMKPointAnnotation new];
            [self.map addAnnotation:self.vehicle];
        }
        self.vehicle.coordinate=[self baidu:playback];
    } else if (self.vehicle) {
        [self.map removeAnnotation:self.vehicle]; self.vehicle=nil;
    }
}
- (BMKOverlayView *)mapView:(BMKMapView *)mapView viewForOverlay:(id<BMKOverlay>)overlay {
    if ([overlay isKindOfClass:[BMKPolyline class]]) {
        BMKPolylineView *line=[[BMKPolylineView alloc] initWithPolyline:(BMKPolyline *)overlay];
        line.strokeColor=[UIColor colorWithRed:0.07 green:0.48 blue:0.98 alpha:0.95];
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
