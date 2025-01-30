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
    Point3D p;
    p.x = x; p.y = y; p.z = z;
    return p;
}

#pragma mark - Distance Helpers

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
 * Euclidean distance from p to the sphere center (cx, cy, z=0).
 */
static CGFloat distanceFromCenter(Point3D p, CGFloat cx, CGFloat cy) {
    CGFloat dx = p.x - cx;
    CGFloat dy = p.y - cy;
    CGFloat dz = p.z; // centerZ=0
    return sqrt(dx*dx + dy*dy + dz*dz);
}

#pragma mark - Interpolation

/**
 * Linearly interpolate between two 3D points: p1 + t*(p2 - p1)
 */
static Point3D interpolate3D(Point3D p1, Point3D p2, CGFloat t) {
    return MakePoint3D(p1.x + t*(p2.x - p1.x),
                       p1.y + t*(p2.y - p1.y),
                       p1.z + t*(p2.z - p1.z));
}

#pragma mark - Cartesian <--> Spherical

/**
 * Convert Cartesian to Spherical coordinates.
 *   r     = distance from origin
 *   theta = polar angle   [0..π]   (angle from +Z axis)
 *   phi   = azimuth angle [-π..π]  (angle in the X–Y plane from +X)
 */
static void cartesianToSpherical(CGFloat x, CGFloat y, CGFloat z,
                                 CGFloat *r, CGFloat *theta, CGFloat *phi)
{
    *r = sqrt(x*x + y*y + z*z);
    if (*r < 1e-9) {
        // Degenerate case
        *theta = 0;
        *phi   = 0;
        return;
    }
    *theta = acos(z / *r);  // [0..π]
    *phi   = atan2(y, x);   // [-π..π]
}

/**
 * Convert Spherical coords back to Cartesian.
 */
static void sphericalToCartesian(CGFloat r, CGFloat theta, CGFloat phi,
                                 CGFloat *x, CGFloat *y, CGFloat *z)
{
    CGFloat sinTheta = sin(theta);
    *x = r * sinTheta * cos(phi);
    *y = r * sinTheta * sin(phi);
    *z = r * cos(theta);
}

#pragma mark - Animation Mode Enum

typedef NS_ENUM(NSInteger, ScribbleAnimationMode) {
    ScribbleAnimationModeOld    = 1,  // old random points
    ScribbleAnimationModeSmooth = 2,  // smooth lines
    ScribbleAnimationModeMixed  = 3   // toggles between old & smooth
};

#pragma mark - ScribbleView Interface

@interface ScribbleView ()

// The path is stored as an array of Point3D in NSValue
@property (nonatomic, strong) NSMutableArray<NSValue*> *path;

// The incremental array of cumulative distances.
// cumulativeDistances[i] = total path distance from path[0] to path[i].
@property (nonatomic, strong) NSMutableArray<NSNumber*> *cumulativeDistances;

// For controlling which segment of the path is currently shown
@property (nonatomic, assign) CGFloat trimAmount;  // how far along the path we've "drawn"

// Rotation (in radians) to apply each frame
@property (nonatomic, assign) CGFloat rotation;

// The spherical bounding region
@property (nonatomic, assign) CGFloat sphereCenterX;
@property (nonatomic, assign) CGFloat sphereCenterY;
@property (nonatomic, assign) CGFloat sphereRadius;

// Configuration for speed, draw-length, etc.
@property (nonatomic, assign) CGFloat drawSpeed;      // e.g. ~1..20
@property (nonatomic, assign) CGFloat rotationSpeed;  // in rotations/min or per second
@property (nonatomic, assign) CGFloat drawLength;     // how long the visible path is
@property (nonatomic, assign) CGFloat keepBehind;     // how much to keep behind the current trim

// scaleFactor for pixelation (e.g. 0.1 => 1/10 scale, then scaled up)
@property (nonatomic, assign) CGFloat scaleFactor;

// "Organic" path parameters (for smooth lines)
@property (nonatomic, assign) CGFloat pathMinSegmentLength;
@property (nonatomic, assign) CGFloat pathMaxSegmentLength;
@property (nonatomic, assign) CGFloat maxBendAngleDeg;

// Animation mode
@property (nonatomic, assign) ScribbleAnimationMode animationMode;

// For "Mode 3 (Mixed)" toggling
@property (nonatomic, assign) BOOL usingSmoothSegments; // if YES => smooth, else => old
@property (nonatomic, assign) NSInteger toggleCountdown; // or a timer to switch after some frames

@end

@implementation ScribbleView

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        // e.g. 30 FPS
        [self setAnimationTimeInterval:1.0 / 30.0];
        
        // Initial config
        _drawSpeed     = 100.0;
        _rotationSpeed = 1.0;        // rotations per minute
        _drawLength    = 12000.0;    // visible length
        _rotation      = 0.0;
        _trimAmount    = 0.0;
        _keepBehind    = 1.5 * (_drawLength * 10.0);
        
        // pixelation factor
        _scaleFactor   = 0.5;
        
        // Organic path params (for smooth lines)
        _pathMinSegmentLength = 10.0;
        _pathMaxSegmentLength = 60.0;
        _maxBendAngleDeg      = 30.0;
        
        // Prepare arrays
        _path = [NSMutableArray array];
        _cumulativeDistances = [NSMutableArray array];
        
        // Choose an animation mode
        //  1 => old random only
        //  2 => smooth only
        //  3 => mixed
        _animationMode = ScribbleAnimationModeSmooth;  // example default
        
        // For mixed mode
        _usingSmoothSegments = NO; // start in 'old' if in mode 3
        _toggleCountdown = 0;      // or set to random frames
    }
    return self;
}

- (void)startAnimation {
    [super startAnimation];
    [self resetPath];
}

- (void)stopAnimation {
    [super stopAnimation];
}

#pragma mark - Reset & Spherical Bounds

- (void)resetPath {
    // Spherical bounds
    CGFloat width  = NSWidth(self.bounds);
    CGFloat height = NSHeight(self.bounds);
    CGFloat minDim = MIN(width, height);
    
    self.sphereCenterX = width  * 0.5;
    self.sphereCenterY = height * 0.5;
    self.sphereRadius  = minDim * 0.67;
    
    [self.path removeAllObjects];
    [self.cumulativeDistances removeAllObjects];
    
    // Seed with some initial points
    for (NSInteger i = 0; i < 20; i++) {
        [self addPathSegment];
    }
    
    self.trimAmount = 0;
    self.rotation   = 0;
}

#pragma mark - Adding Segments

/**
 * Central function that decides how to add a segment
 * depending on animationMode (old vs. smooth vs. mixed).
 */
- (void)addPathSegment {
    
    switch (self.animationMode) {
        case ScribbleAnimationModeOld:
            [self addRandomPointOLD];
            break;
            
        case ScribbleAnimationModeSmooth:
            [self addSmoothSegmentNEW];
            break;
            
        case ScribbleAnimationModeMixed:
        default:
            // If "mixed," we pick which approach based on self.usingSmoothSegments
            if (self.usingSmoothSegments) {
                [self addSmoothSegmentNEW];
            } else {
                [self addRandomPointOLD];
            }
            break;
    }
}

/**
 * Old logic: Just pick a random point in the sphere (or bounding box).
 * This is effectively "jagged lines."
 */
- (void)addRandomPointOLD {
    // If fewer than 2 points, or always, just pick a random point in sphere
    // (If you want to literally replicate your earliest code, which used a bounding box,
    //  you can do that. For now, let's do "anywhere in the sphere".)
    
    CGFloat x = (CGFloat)arc4random()/(CGFloat)UINT32_MAX * (self.sphereRadius*2)
                + (self.sphereCenterX - self.sphereRadius);
    CGFloat y = (CGFloat)arc4random()/(CGFloat)UINT32_MAX * (self.sphereRadius*2)
                + (self.sphereCenterY - self.sphereRadius);
    // For 3D effect, Z in [-sphereRadius..sphereRadius]
    CGFloat z = ((CGFloat)arc4random()/(CGFloat)UINT32_MAX * (self.sphereRadius*2))
                - (self.sphereRadius);
    
    Point3D p = MakePoint3D(x, y, z);
    [self appendPoint:p];
}

/**
 * New logic: "Smooth lines" with boundary steering/clamping (Strategy #2).
 */
- (void)addSmoothSegmentNEW {
    // If fewer than 2 points, pick a random point in sphere
    if (self.path.count < 2) {
        [self addRandomPointInSphere]; // the random-in-sphere from your code
        return;
    }
    
    // Exactly like your "smooth lines" method:
    Point3D pLast, pSecondLast;
    [self.path[self.path.count - 1] getValue:&pLast];
    [self.path[self.path.count - 2] getValue:&pSecondLast];
    
    CGFloat dirX = pLast.x - pSecondLast.x;
    CGFloat dirY = pLast.y - pSecondLast.y;
    CGFloat dirZ = pLast.z - pSecondLast.z;
    
    // Convert to spherical
    CGFloat r, theta, phi;
    cartesianToSpherical(dirX, dirY, dirZ, &r, &theta, &phi);
    
    // Random bend
    CGFloat maxBendRadians = self.maxBendAngleDeg * (M_PI / 180.0);
    CGFloat dTheta = ((CGFloat)arc4random()/(CGFloat)UINT32_MAX - 0.5f) * 2.0f * maxBendRadians;
    CGFloat dPhi   = ((CGFloat)arc4random()/(CGFloat)UINT32_MAX - 0.5f) * 2.0f * maxBendRadians;
    
    CGFloat newTheta = theta + dTheta;
    CGFloat newPhi   = phi   + dPhi;
    
    // Clamp newTheta
    if (newTheta < 0)    newTheta = 0;
    if (newTheta > M_PI) newTheta = M_PI;
    
    // Pick segment length
    CGFloat segLen = self.pathMinSegmentLength + ((CGFloat)arc4random()/(CGFloat)UINT32_MAX)
                     * (self.pathMaxSegmentLength - self.pathMinSegmentLength);
    
    // Convert back to cartesian
    CGFloat segX, segY, segZ;
    sphericalToCartesian(segLen, newTheta, newPhi, &segX, &segY, &segZ);
    
    // Candidate
    CGFloat candidateX = pLast.x + segX;
    CGFloat candidateY = pLast.y + segY;
    CGFloat candidateZ = pLast.z + segZ;
    
    // If near boundary, pull inward
    CGFloat dist = distanceFromCenter(pLast, self.sphereCenterX, self.sphereCenterY);
    CGFloat ratio = dist / self.sphereRadius;
    CGFloat boundaryThreshold = 0.6;
    if (ratio > boundaryThreshold) {
        CGFloat pull = (ratio - boundaryThreshold) / (1.0 - boundaryThreshold);
        if (pull > 1.0) pull = 1.0;
        
        // Vector inward
        CGFloat inX = (self.sphereCenterX - pLast.x);
        CGFloat inY = (self.sphereCenterY - pLast.y);
        CGFloat inZ = (0                     - pLast.z);
        
        CGFloat mixX = (1.0 - pull)*segX + pull*inX;
        CGFloat mixY = (1.0 - pull)*segY + pull*inY;
        CGFloat mixZ = (1.0 - pull)*segZ + pull*inZ;
        
        CGFloat mixLen = sqrt(mixX*mixX + mixY*mixY + mixZ*mixZ);
        if (mixLen > 1e-9) {
            CGFloat scale = segLen / mixLen;
            mixX *= scale;
            mixY *= scale;
            mixZ *= scale;
        }
        
        candidateX = pLast.x + mixX;
        candidateY = pLast.y + mixY;
        candidateZ = pLast.z + mixZ;
        
        segX = mixX;
        segY = mixY;
        segZ = mixZ;
    }
    
    // Final clamp if still out-of-bounds
    CGFloat candidateDist = distanceFromCenter(MakePoint3D(candidateX, candidateY, candidateZ),
                                               self.sphereCenterX, self.sphereCenterY);
    if (candidateDist > self.sphereRadius) {
        CGFloat overshoot = candidateDist - self.sphereRadius;
        CGFloat scale = (self.sphereRadius - dist) / (candidateDist - dist);
        if (scale < 0.0 || scale > 1.0) {
            // fallback: place exactly on boundary
            scale = self.sphereRadius / candidateDist;
        }
        candidateX = pLast.x + scale*segX;
        candidateY = pLast.y + scale*segY;
        candidateZ = pLast.z + scale*segZ;
    }
    
    Point3D newP = MakePoint3D(candidateX, candidateY, candidateZ);
    [self appendPoint:newP];
}

/**
 * Random point in sphere (used when we have < 2 points)
 */
- (void)addRandomPointInSphere {
    CGFloat r  = self.sphereRadius
                 * cbrt((CGFloat)arc4random()/(CGFloat)UINT32_MAX); // uniform in volume
    CGFloat th = acos(2.0*((CGFloat)arc4random()/(CGFloat)UINT32_MAX)-1.0);
    CGFloat ph = 2.0*M_PI * ((CGFloat)arc4random()/(CGFloat)UINT32_MAX);
    
    CGFloat x, y, z;
    sphericalToCartesian(r, th, ph, &x, &y, &z);
    x += self.sphereCenterX;
    y += self.sphereCenterY;
    
    Point3D p = MakePoint3D(x, y, z);
    [self appendPoint:p];
}

/**
 * Append a brand-new point to self.path, maintaining cumulativeDistances incrementally.
 */
- (void)appendPoint:(Point3D)pt {
    if (self.path.count == 0) {
        [self.path addObject:[NSValue valueWithBytes:&pt objCType:@encode(Point3D)]];
        [self.cumulativeDistances addObject:@(0.0)];
        return;
    }
    
    Point3D pLast;
    [self.path.lastObject getValue:&pLast];
    CGFloat segLen = distance3D(pLast, pt);
    
    CGFloat lastDist = self.cumulativeDistances.lastObject.doubleValue;
    CGFloat newCumDist = lastDist + segLen;
    
    [self.path addObject:[NSValue valueWithBytes:&pt objCType:@encode(Point3D)]];
    [self.cumulativeDistances addObject:@(newCumDist)];
}

#pragma mark - AnimateOneFrame

- (void)animateOneFrame {
    // rotationSpeed => radians/frame
    CGFloat rotationsPerSec = (self.rotationSpeed / 60.0);
    CGFloat dRotation = rotationsPerSec * (2.0 * M_PI) * (1.0 / 30.0);
    
    // For "Mode 3 (Mixed)": occasionally toggle between old & smooth
    if (self.animationMode == ScribbleAnimationModeMixed) {
        [self updateMixedModeToggle];
    }
    
    // Move trim forward
    CGFloat frameSpeed = self.drawSpeed / 10.0;
    self.trimAmount += frameSpeed;
    
    // Purge old points
    CGFloat purgeDistance = self.trimAmount - self.keepBehind;
    if (purgeDistance > 0) {
        [self purgePathUpToDistance:purgeDistance];
        self.trimAmount -= purgeDistance;
    }
    
    // Add new points if needed
    CGFloat pathEnd = (self.cumulativeDistances.count > 0)
                      ? self.cumulativeDistances.lastObject.doubleValue
                      : 0.0;
    CGFloat neededEnd = self.trimAmount + (self.drawLength * 10.0);
    while (pathEnd < neededEnd) {
        [self addPathSegment];
        pathEnd = self.cumulativeDistances.lastObject.doubleValue;
    }
    
    // Update rotation
    self.rotation += dRotation;
    if (self.rotation > 2.0 * M_PI) {
        self.rotation -= 2.0 * M_PI;
    }
    
    [self setNeedsDisplay:YES];
}

/**
 * For Mixed mode: decide if we want to toggle from old -> smooth or smooth -> old.
 * You can do a random check each frame or a countdown timer. Here's a simple random check:
 */
- (void)updateMixedModeToggle {
    // Example approach: 1% chance each frame to toggle
    // (At 30 FPS, that’s ~ once every ~3 seconds on average, but random.)
    
    // Tweak this probability to your liking
    const CGFloat toggleChance = 0.01;
    
    CGFloat roll = (CGFloat)arc4random()/(CGFloat)UINT32_MAX;
    if (roll < toggleChance) {
        self.usingSmoothSegments = !self.usingSmoothSegments;
    }
    
    // OR you could do a countdown approach: e.g. self.toggleCountdown--
    // and if it hits 0, toggle and reset to a random # of frames, etc.
}

#pragma mark - Purge

/**
 * Remove points from the front of the path until cumulativeDistances
 * is >= purgeDist. Also preserve continuity by adjusting the first
 * point if purgeDist falls in the middle of a segment.
 */
- (void)purgePathUpToDistance:(CGFloat)purgeDist {
    if (self.path.count < 2) {
        return;
    }
    
    CGFloat totalLen = self.cumulativeDistances.lastObject.doubleValue;
    if (purgeDist >= totalLen) {
        [self.path removeAllObjects];
        [self.cumulativeDistances removeAllObjects];
        return;
    }
    
    NSInteger iSegment = [self indexForCumulativeDistance:purgeDist];
    if (iSegment == NSNotFound) {
        return;
    }
    
    NSInteger segIndex = MAX(0, iSegment - 1);
    
    CGFloat segStartDist = self.cumulativeDistances[segIndex].doubleValue;
    CGFloat segEndDist   = self.cumulativeDistances[iSegment].doubleValue;
    CGFloat segLength    = segEndDist - segStartDist;
    CGFloat t = (purgeDist - segStartDist) / segLength;
    
    Point3D pStart, pEnd;
    [self.path[segIndex] getValue:&pStart];
    [self.path[iSegment] getValue:&pEnd];
    
    Point3D newStart = interpolate3D(pStart, pEnd, t);
    
    if (segIndex > 0) {
        NSRange removeRange = NSMakeRange(0, segIndex);
        [self.path removeObjectsInRange:removeRange];
        [self.cumulativeDistances removeObjectsInRange:removeRange];
    }
    
    // Replace the old iSegment point with newStart
    self.path[0] = [NSValue valueWithBytes:&newStart objCType:@encode(Point3D)];
    self.cumulativeDistances[0] = @(0.0);
    
    CGFloat distOffset = purgeDist;
    for (NSInteger i = 1; i < self.cumulativeDistances.count; i++) {
        CGFloat oldVal = self.cumulativeDistances[i].doubleValue;
        self.cumulativeDistances[i] = @(oldVal - distOffset);
    }
}

/**
 * Binary search: returns the index i such that
 *    cumulativeDistances[i] >= dist
 * If dist <= first entry => 0
 * If dist > last => NSNotFound
 */
- (NSInteger)indexForCumulativeDistance:(CGFloat)dist {
    if (self.cumulativeDistances.count < 1) return NSNotFound;
    if (dist <= self.cumulativeDistances[0].doubleValue) {
        return 0;
    }
    CGFloat lastVal = self.cumulativeDistances.lastObject.doubleValue;
    if (dist > lastVal) {
        return NSNotFound;
    }
    
    NSInteger low = 0;
    NSInteger high = self.cumulativeDistances.count - 1;
    while (low < high) {
        NSInteger mid = (low + high) / 2;
        CGFloat midVal = self.cumulativeDistances[mid].doubleValue;
        if (midVal < dist) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    return low;
}

#pragma mark - Drawing

- (void)drawRect:(NSRect)rect {
    [super drawRect:rect];
    
    // 1) Offscreen buffer for pixelation
    CGFloat scale = (self.scaleFactor > 0.0) ? self.scaleFactor : 0.1;
    CGFloat smallWidth  = NSWidth(self.bounds)  * scale;
    CGFloat smallHeight = NSHeight(self.bounds) * scale;
    
    NSInteger pixelWidth  = MAX(1, (NSInteger) floor(smallWidth));
    NSInteger pixelHeight = MAX(1, (NSInteger) floor(smallHeight));
    
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
    
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:offscreenCtx];
    
    offscreenCtx.shouldAntialias = NO;
    CGContextSetAllowsAntialiasing(offscreenCtx.CGContext, false);
    CGContextSetShouldAntialias(offscreenCtx.CGContext, false);
    
    // 2) Scale so our internal "viewSize" matches self.bounds
    CGContextScaleCTM(offscreenCtx.CGContext, scale, scale);
    
    // 3) Draw the scribble into offscreen
    [self drawScribbleeInContext:offscreenCtx.CGContext viewSize:self.bounds.size];
    
    [NSGraphicsContext restoreGraphicsState];
    
    // 4) Draw the offscreen to main
    CGContextRef mainCG = [[NSGraphicsContext currentContext] CGContext];
    CGContextSaveGState(mainCG);
    CGContextSetInterpolationQuality(mainCG, kCGInterpolationNone);
    
    NSRect destRect   = NSMakeRect(0, 0, NSWidth(self.bounds), NSHeight(self.bounds));
    NSRect sourceRect = NSMakeRect(0, 0, pixelWidth, pixelHeight);
    
    [bitmapRep drawInRect:destRect
                 fromRect:sourceRect
                operation:NSCompositingOperationSourceOver
                 fraction:1.0
           respectFlipped:YES
                    hints:nil];
    
    CGContextRestoreGState(mainCG);
}

/**
 * Actually render the scribble (the part from [trimAmount - visibleLen .. trimAmount]).
 */
- (void)drawScribbleeInContext:(CGContextRef)ctx viewSize:(CGSize)viewSize {
    CGContextSetAllowsAntialiasing(ctx, false);
    CGContextSetShouldAntialias(ctx, false);
    
    [[NSColor blackColor] setFill];
    CGRect fullRect = CGRectMake(0, 0, viewSize.width, viewSize.height);
    CGContextFillRect(ctx, fullRect);
    
    // We'll define visible range
    CGFloat startOfVisible = MAX(0, self.trimAmount - self.drawLength);
    CGFloat endOfVisible   = self.trimAmount;
    
    [self drawTrimmedPathInContext:ctx
                           viewSize:viewSize
                       startOffset:startOfVisible
                         endOffset:endOfVisible];
}

/**
 * "Trim" using the cached distances + binary search. Then stroke.
 */
- (void)drawTrimmedPathInContext:(CGContextRef)ctx
                        viewSize:(CGSize)viewSize
                     startOffset:(CGFloat)startOffset
                       endOffset:(CGFloat)endOffset
{
    if (self.path.count < 2) return;
    
    CGFloat totalLength = self.cumulativeDistances.lastObject.doubleValue;
    if (startOffset >= totalLength) return;
    if (endOffset <= 0) return;
    
    startOffset = MAX(0, startOffset);
    endOffset   = MIN(totalLength, endOffset);
    if (endOffset <= startOffset) return;
    
    NSMutableArray<NSValue*> *displayPts = [NSMutableArray array];
    
    // 1) Start point
    Point3D startP = [self pointAtDistance:startOffset];
    [displayPts addObject:[NSValue valueWithBytes:&startP objCType:@encode(Point3D)]];
    
    // 2) Intermediate points
    NSInteger startIdx = [self indexForCumulativeDistance:startOffset];
    NSInteger endIdx   = [self indexForCumulativeDistance:endOffset];
    for (NSInteger i = startIdx; i < self.path.count && i < endIdx; i++) {
        CGFloat dist = self.cumulativeDistances[i].doubleValue;
        if (dist > startOffset && dist < endOffset) {
            [displayPts addObject:self.path[i]];
        }
    }
    
    // 3) End point
    Point3D endP = [self pointAtDistance:endOffset];
    [displayPts addObject:[NSValue valueWithBytes:&endP objCType:@encode(Point3D)]];
    
    if (displayPts.count < 2) return;
    
    // 4) Build a path
    NSBezierPath *bpath = [NSBezierPath bezierPath];
    bpath.lineWidth = 1.0;
    
    CGFloat halfW = viewSize.width / 2.0;
    CGFloat halfH = viewSize.height / 2.0;
    CGFloat r = self.rotation;
    
    Point3D firstPt;
    [displayPts[0] getValue:&firstPt];
    
    CGFloat fX = firstPt.x - halfW;
    CGFloat fY = firstPt.y - halfH;
    CGFloat fZ = firstPt.z;
    
    CGFloat rx = fX * cos(r) - fZ * sin(r);
    CGFloat ry = fY;
    
    [bpath moveToPoint:NSMakePoint(rx + halfW, ry + halfH)];
    
    for (NSInteger i = 1; i < displayPts.count; i++) {
        Point3D p;
        [displayPts[i] getValue:&p];
        
        CGFloat x = p.x - halfW;
        CGFloat y = p.y - halfH;
        CGFloat z = p.z;
        
        CGFloat rX = x * cos(r) - z * sin(r);
        CGFloat rY = y;
        
        [bpath lineToPoint:NSMakePoint(rX + halfW, rY + halfH)];
    }
    
    [[NSColor whiteColor] setStroke];
    [bpath stroke];
}

/**
 * Interpolate a point at distance d using our cached cumulativeDistances
 */
- (Point3D)pointAtDistance:(CGFloat)d {
    if (self.path.count == 0) {
        return MakePoint3D(0, 0, 0);
    }
    if (self.path.count == 1) {
        Point3D p;
        [self.path[0] getValue:&p];
        return p;
    }
    
    CGFloat totalLen = self.cumulativeDistances.lastObject.doubleValue;
    if (d <= 0) {
        Point3D p;
        [self.path[0] getValue:&p];
        return p;
    }
    if (d >= totalLen) {
        Point3D p;
        [self.path.lastObject getValue:&p];
        return p;
    }
    
    NSInteger idx = [self indexForCumulativeDistance:d];
    NSInteger segIndex = MAX(0, idx - 1);
    
    CGFloat segStartDist = self.cumulativeDistances[segIndex].doubleValue;
    CGFloat segEndDist   = self.cumulativeDistances[idx].doubleValue;
    CGFloat segLen       = segEndDist - segStartDist;
    CGFloat t = (d - segStartDist) / segLen;
    
    Point3D pStart, pEnd;
    [self.path[segIndex] getValue:&pStart];
    [self.path[idx] getValue:&pEnd];
    
    return interpolate3D(pStart, pEnd, t);
}

#pragma mark - ScreenSaverView Standard

- (BOOL)hasConfigureSheet {
    return NO;
}

- (NSWindow*)configureSheet {
    return nil;
}

@end
