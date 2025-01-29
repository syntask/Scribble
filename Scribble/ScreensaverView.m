//
//  ScribbleView.m
//  Scribble
//
//  Created by You on [Date].
//

#import "ScreensaverView.h"
#import <math.h>

#pragma mark - 3D Point Struct

typedef struct {
    CGFloat x;
    CGFloat y;
    CGFloat z;
} Point3D;

static inline Point3D MakePoint3D(CGFloat x, CGFloat y, CGFloat z) {
    Point3D p; p.x = x; p.y = y; p.z = z;
    return p;
}

#pragma mark - Helper Functions

/**
 * Euclidean distance between two 3D points
 */
static CGFloat distance3D(Point3D p1, Point3D p2) {
    CGFloat dx = p2.x - p1.x;
    CGFloat dy = p2.y - p1.y;
    CGFloat dz = p2.z - p1.z;
    return sqrt(dx*dx + dy*dy + dz*dz);
}

/**
 * Linearly interpolate between two 3D points
 * p1 + t*(p2 - p1)
 */
static Point3D interpolate3D(Point3D p1, Point3D p2, CGFloat t) {
    return MakePoint3D(p1.x + t*(p2.x - p1.x),
                       p1.y + t*(p2.y - p1.y),
                       p1.z + t*(p2.z - p1.z));
}

/**
 * Returns the cumulative length of the entire path.
 */
static CGFloat pathLength(NSArray<NSValue*> *path) {
    if (path.count < 2) return 0;
    
    CGFloat total = 0;
    for (NSInteger i=1; i<path.count; i++) {
        Point3D p1, p2;
        [path[i-1] getValue:&p1];
        [path[i]   getValue:&p2];
        total += distance3D(p1, p2);
    }
    return total;
}

/**
 * Trim a 3D path by `startOffset` and `endOffset`, returning a new array of points.
 * Essentially: keep the segment from startOffset to (totalLength - endOffset).
 */
static NSArray<NSValue*>* trimPath3D(NSArray<NSValue*> *path,
                                     CGFloat startOffset,
                                     CGFloat endOffset) {
    if (path.count < 2) {
        return path;
    }
    
    // Build cumulative distances
    NSMutableArray<NSNumber*> *distances = [NSMutableArray arrayWithCapacity:path.count];
    [distances addObject:@0];
    
    for (NSInteger i=1; i<path.count; i++) {
        Point3D p1, p2;
        [path[i-1] getValue:&p1];
        [path[i]   getValue:&p2];
        
        CGFloat d = distance3D(p1, p2);
        CGFloat cumulative = distances[i-1].doubleValue + d;
        [distances addObject:@(cumulative)];
    }
    
    CGFloat totalLength = distances.lastObject.doubleValue;
    CGFloat keepLength  = totalLength - (startOffset + endOffset);
    if (keepLength <= 0) {
        // The requested segment is empty
        return @[];
    }
    
    // Helper to get interpolated point at distance d
    Point3D (^pointAtDistance)(CGFloat) = ^(CGFloat d){
        if (d <= 0) {
            Point3D p0; [path[0] getValue:&p0];
            return p0;
        }
        if (d >= totalLength) {
            Point3D pLast; [path.lastObject getValue:&pLast];
            return pLast;
        }
        
        // Find which segment contains d
        NSInteger iSegment = 0;
        while (iSegment < distances.count && distances[iSegment].doubleValue < d) {
            iSegment++;
        }
        NSInteger segIndex = MAX(0, iSegment - 1);
        
        CGFloat segStartDist = distances[segIndex].doubleValue;
        CGFloat segEndDist   = distances[iSegment].doubleValue;
        CGFloat segLength    = segEndDist - segStartDist;
        CGFloat t = (d - segStartDist) / segLength;
        
        Point3D segStart, segEnd;
        [path[segIndex] getValue:&segStart];
        [path[iSegment] getValue:&segEnd];
        
        return interpolate3D(segStart, segEnd, t);
    };
    
    // New start point
    Point3D newStart = pointAtDistance(startOffset);
    // New end point
    Point3D newEnd   = pointAtDistance(totalLength - endOffset);
    
    NSMutableArray<NSValue*> *trimmedPath = [NSMutableArray array];
    [trimmedPath addObject:[NSValue valueWithBytes:&newStart objCType:@encode(Point3D)]];
    
    // Keep any original points that are strictly inside the start/end range
    for (NSInteger i = 1; i < path.count - 1; i++) {
        CGFloat dist = distances[i].doubleValue;
        if (dist > startOffset && dist < (totalLength - endOffset)) {
            [trimmedPath addObject:path[i]];
        }
    }
    [trimmedPath addObject:[NSValue valueWithBytes:&newEnd objCType:@encode(Point3D)]];
    
    return trimmedPath;
}

/**
 * Add a new random segment to the path.
 */
static void addPathSegment(NSMutableArray<NSValue*> *path,
                           CGFloat bounds,
                           CGFloat padX,
                           CGFloat padY) {
    // For the 3D effect, let Z range from -bounds/2 to +bounds/2
    CGFloat x = (CGFloat)arc4random()/(CGFloat)UINT32_MAX * bounds + padX;
    CGFloat y = (CGFloat)arc4random()/(CGFloat)UINT32_MAX * bounds + padY;
    CGFloat z = ((CGFloat)arc4random()/(CGFloat)UINT32_MAX * bounds) - (bounds/2);
    
    Point3D p = MakePoint3D(x, y, z);
    [path addObject:[NSValue valueWithBytes:&p objCType:@encode(Point3D)]];
}

#pragma mark - ScribbleView Interface

@interface ScribbleView ()

// The 3D path
@property (nonatomic, strong) NSMutableArray<NSValue*> *path;

// For controlling which segment of the path is currently shown
@property (nonatomic, assign) CGFloat trimAmount;

// Rotation (in radians) to apply each frame
@property (nonatomic, assign) CGFloat rotation;

// Screen bounds-based values
@property (nonatomic, assign) CGFloat boundsSize;
@property (nonatomic, assign) CGFloat padX;
@property (nonatomic, assign) CGFloat padY;

// Configuration for speed, draw-length, etc.
@property (nonatomic, assign) CGFloat drawSpeed;      // e.g. ~1..20
@property (nonatomic, assign) CGFloat rotationSpeed;  // in rotations/min or per second
@property (nonatomic, assign) CGFloat drawLength;     // how long the visible path is
@property (nonatomic, assign) CGFloat keepBehind;     // how much to keep behind the current trim

// scaleFactor for pixelation (e.g. 0.1 => 1/10 scale, then scaled up)
@property (nonatomic, assign) CGFloat scaleFactor;

@end

@implementation ScribbleView

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview
{
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        // Example: 30 FPS (adjust as you wish)
        [self setAnimationTimeInterval:1.0/30.0];
        
        // Initial config (tweak to preference)
        _drawSpeed     = 50.0;   // speed at which trimAmount moves forward
        _rotationSpeed = 1.0;    // if in rotations/min, adjust in animateOneFrame
        _drawLength    = 1000.0;  // # of path units visible
        _rotation      = 0.0;
        _trimAmount    = 0.0;
        _keepBehind    = 1.5 * (_drawLength * 10.0);
        
        // The pixelation factor: 0.1 => 1/10 resolution
        _scaleFactor   = 0.5;
        
        // Prepare the path array
        _path = [NSMutableArray array];
    }
    return self;
}

- (void)startAnimation
{
    [super startAnimation];
    [self resetPath];
}

- (void)stopAnimation
{
    [super stopAnimation];
}

- (void)resetPath
{
    // Compute 'boundsSize' to be a portion of the window
    CGFloat width  = NSWidth(self.bounds);
    CGFloat height = NSHeight(self.bounds);
    CGFloat minDim = MIN(width, height);
    
    self.boundsSize = minDim * 0.8;
    self.padX       = (width  - self.boundsSize) / 2.0;
    self.padY       = (height - self.boundsSize) / 2.0;
    
    [self.path removeAllObjects];
    
    // Seed with some initial points
    for (NSInteger i = 0; i < 20; i++) {
        addPathSegment(self.path, self.boundsSize, self.padX, self.padY);
    }
    
    self.trimAmount = 0;
    self.rotation   = 0;
}

#pragma mark - Core Animation Loop

- (void)animateOneFrame
{
    // We'll interpret rotationSpeed as "rotations per minute" (RPM).
    // Convert to radians/frame at 30 FPS:
    //   (rotationSpeed / 60) rotations/sec => * (2π) => radians/sec => * (1/30) => radians/frame
    CGFloat rotationsPerSec = (self.rotationSpeed / 60.0);
    CGFloat dRotation = rotationsPerSec * (2.0 * M_PI) * (1.0/30.0);
    
    // Move trim forward (adjust speed as you like)
    CGFloat frameSpeed = self.drawSpeed / 10.0;
    self.trimAmount += frameSpeed;
    
    // Purge old points
    CGFloat purgeDistance = self.trimAmount - self.keepBehind;
    if (purgeDistance > 0) {
        NSArray<NSValue*> *newPath = trimPath3D(self.path, purgeDistance, 0.0);
        if (newPath.count > 1) {
            self.path = [newPath mutableCopy];
        } else {
            [self resetPath];
            return;
        }
        self.trimAmount -= purgeDistance;
    }
    
    // Add new points if needed
    CGFloat currentLen = pathLength(self.path);
    CGFloat neededEnd  = self.trimAmount + (self.drawLength * 10.0);
    while (currentLen < neededEnd) {
        addPathSegment(self.path, self.boundsSize, self.padX, self.padY);
        currentLen = pathLength(self.path);
    }
    
    // Update rotation
    self.rotation += dRotation;
    if (self.rotation > 2.0 * M_PI) {
        self.rotation -= 2.0 * M_PI;
    }
    
    [self setNeedsDisplay:YES];
}

#pragma mark - Drawing

/**
 * Draws the Scribblee into a given CGContext at a given viewSize.
 * We do the path-trimming, rotation, etc. inside here.
 */
- (void)drawScribbleeInContext:(CGContextRef)ctx viewSize:(CGSize)viewSize
{
    // Turn off anti-aliasing for jagged (pixel-like) lines
    CGContextSetAllowsAntialiasing(ctx, false);
    CGContextSetShouldAntialias(ctx, false);
    
    // 1) Fill background black
    [[NSColor blackColor] setFill];
    CGRect fullRect = CGRectMake(0, 0, viewSize.width, viewSize.height);
    CGContextFillRect(ctx, fullRect);

    // 2) Calculate visible portion:
    CGFloat visibleLength = (self.boundsSize * self.drawLength) * 0.66;
    CGFloat startOfVisible = MAX(0, self.trimAmount - visibleLength);
    CGFloat endOfVisible   = self.trimAmount;
    
    CGFloat totalLen = pathLength(self.path);
    CGFloat startOffset = startOfVisible;
    CGFloat endOffset   = totalLen - endOfVisible;
    
    NSArray<NSValue*> *trimmed = trimPath3D(self.path, startOffset, endOffset);
    if (trimmed.count < 2) return;
    
    // 3) Create a path
    NSBezierPath *bezier = [NSBezierPath bezierPath];
    [bezier setLineWidth:1.0];
    
    Point3D firstP;
    [trimmed[0] getValue:&firstP];
    
    CGFloat halfW = viewSize.width / 2.0;
    CGFloat halfH = viewSize.height / 2.0;
    CGFloat r = self.rotation;

    CGFloat fX = firstP.x - halfW;
    CGFloat fY = firstP.y - halfH;
    CGFloat fZ = firstP.z;

    // rotate around the Y-axis:
    CGFloat rx = fX * cos(r) - fZ * sin(r);
    CGFloat ry = fY;
    
    [bezier moveToPoint:NSMakePoint(rx + halfW, ry + halfH)];
    
    for (NSInteger i = 1; i < trimmed.count; i++) {
        Point3D p;
        [trimmed[i] getValue:&p];
        
        CGFloat x = p.x - halfW;
        CGFloat y = p.y - halfH;
        CGFloat z = p.z;
        
        CGFloat rX = x * cos(r) - z * sin(r);
        CGFloat rY = y;
        
        [bezier lineToPoint:NSMakePoint(rX + halfW, rY + halfH)];
    }
    
    [[NSColor whiteColor] setStroke];
    [bezier stroke];
}

- (void)drawRect:(NSRect)rect
{
    [super drawRect:rect];
    
    // 1) Figure out how big our offscreen buffer should be
    CGFloat scale = (self.scaleFactor > 0.0) ? self.scaleFactor : 0.1;
    CGFloat smallWidth  = NSWidth(self.bounds)  * scale;
    CGFloat smallHeight = NSHeight(self.bounds) * scale;
    
    // Ensure at least 1×1 pixel if scale is very small
    NSInteger pixelWidth  = MAX(1, (NSInteger) floor(smallWidth));
    NSInteger pixelHeight = MAX(1, (NSInteger) floor(smallHeight));
    
    // 2) Create an offscreen bitmap
    NSBitmapImageRep *bitmapRep = [[NSBitmapImageRep alloc]
                                   initWithBitmapDataPlanes:NULL
                                   pixelsWide:pixelWidth
                                   pixelsHigh:pixelHeight
                                   bitsPerSample:8
                                   samplesPerPixel:4
                                   hasAlpha:YES
                                   isPlanar:NO
                                   colorSpaceName:NSCalibratedRGBColorSpace
                                   bytesPerRow:0
                                   bitsPerPixel:0];
    
    NSGraphicsContext *offscreenCtx = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmapRep];
    
    // Save current graphics state and switch to offscreen
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:offscreenCtx];
    
    // Disable anti-aliasing in the offscreen context as well
    offscreenCtx.shouldAntialias = NO;
    CGContextSetAllowsAntialiasing(offscreenCtx.CGContext, false);
    CGContextSetShouldAntialias(offscreenCtx.CGContext, false);
    
    // 3) Scale so the Scribblee code can still assume "full size"
    CGContextScaleCTM(offscreenCtx.CGContext, scale, scale);

    // 4) Draw the Scribblee into the offscreen context
    [self drawScribbleeInContext:offscreenCtx.CGContext viewSize:self.bounds.size];

    // Restore graphics state (return to the main context)
    [NSGraphicsContext restoreGraphicsState];
    
    // 5) Draw that offscreen image into the main view with nearest neighbor
    CGContextRef mainCG = [[NSGraphicsContext currentContext] CGContext];
    CGContextSaveGState(mainCG);
    CGContextSetInterpolationQuality(mainCG, kCGInterpolationNone); // crucial for pixelation
    
    NSRect destRect   = NSMakeRect(0, 0, NSWidth(self.bounds), NSHeight(self.bounds));
    NSRect sourceRect = NSMakeRect(0, 0, pixelWidth, pixelHeight);
    
    // Draw the scaled-up image
    [bitmapRep drawInRect:destRect
                 fromRect:sourceRect
                operation:NSCompositingOperationSourceOver
                 fraction:1.0
           respectFlipped:YES
                    hints:nil];
    
    CGContextRestoreGState(mainCG);
}

#pragma mark - ScreenSaverView Standard

- (BOOL)hasConfigureSheet
{
    return NO;
}

- (NSWindow*)configureSheet
{
    return nil;
}

@end

