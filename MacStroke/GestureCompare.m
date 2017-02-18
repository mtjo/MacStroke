//
//  GestureCompare.m
//  MacStroke
//
//  Created by MTJO on 2017/1/28.
//  Copyright © 2017年 Chivalry Software. All rights reserved.
//


#import "GestureCompare.h"
#import "Stroke.h"
#define EPS 0.000001

@implementation GestureCompare
CGFloat const stroke_infinity = 0.2;
+ (void)addPoint:(Stroke *)stroke withPointX:(CGFloat)x PointY:(CGFloat)y {
    assert(stroke.capacity > stroke.n);
    JOPoint *point = [JOPoint pointWithPointX:x PointY:y];
    [stroke.p addObject:point];
    stroke.n++;
}

+ (CGFloat)angle_differenceWithAlpha:(CGFloat)alpha Beta:(CGFloat)beta {
    
    CGFloat d = alpha - beta;
    if (d < -1.0f) {
        d += 2;
    } else if (d > 1.0f) {
        d -= 2;
    }
    //NSLog(@"alpha:%f beta:%f d:%f",alpha,beta,d);
    return d;
}

+ (void)finshWithStroke:(Stroke *)stroke {
    assert(stroke.capacity > 0);
    
    stroke.capacity = -1;
    NSInteger n = stroke.n - 1;
    CGFloat total = 0.0;
    stroke.p[0].t = 0;
    
    for (int i = 0; i < n; i++) {
        total += hypot(stroke.p[i+1].x - stroke.p[i].x, stroke.p[i+1].y - stroke.p[i].y);
        
        stroke.p[i+1].t = total;
    }
    
    for (int i = 0; i <= n; i++) {
        stroke.p[i].t /= total;
    }
    
    CGFloat minX = stroke.p[0].x;
    CGFloat minY = stroke.p[0].y;
    CGFloat maxX = minX;
    CGFloat maxY = minY;
    
    for (int i = 0; i <= n; i++) {
        if (stroke.p[i].x < minX) {
            minX = stroke.p[i].x;
        }
        if (stroke.p[i].x > maxX) {
            maxX = stroke.p[i].x;
        }
        if (stroke.p[i].y < minX) {
            minY = stroke.p[i].y;
        }
        if (stroke.p[i].y > maxY) {
            maxY = stroke.p[i].y;
        }
    }
    
    CGFloat scaleX = maxX - minX;
    CGFloat scaleY = maxY - minY;
    CGFloat scale = scaleX > scaleY ? scaleX : scaleY;
    
    if (scale < 0.001) {
        scale = 1;
    }
    
    for (int i = 0; i <= n; i++) {
        stroke.p[i].x = (stroke.p[i].x - (minX + maxX) / 2) / scale + 0.5;
        stroke.p[i].y = (stroke.p[i].y - (minY + maxY) / 2) / scale + 0.5;
    }
    
    for (int i = 0; i < n; i++) {
        stroke.p[i].dt = stroke.p[i+1].t - stroke.p[i].t;
        stroke.p[i].alpha = atan2(stroke.p[i+1].y - stroke.p[i].y, stroke.p[i+1].x - stroke.p[i].x) / M_PI;
    }
}

+ (NSInteger)getSize:(Stroke *)stroke {
    return stroke.n;
}

+ (void)getPointWithStroke:(Stroke *)stroke number:(NSInteger)n PointX:(CGFloat *)x PointY:(CGFloat *)y {
    assert(n < stroke.n);
    if (x) {
        *x = stroke.p[n].x;
    }
    if (y) {
        *y = stroke.p[n].y;
    }
}

+ (CGFloat)getTimeWithStroke:(Stroke *)stroke number:(NSInteger)n {
    assert(n < stroke.n);
    return stroke.p[n].t;
}

+ (CGFloat)getAngleWithStroke:(Stroke *)stroke number:(NSInteger)n {
    assert(n + 1 < stroke.n);
    return stroke.p[n].alpha;
}

+ (CGFloat)sqr:(CGFloat)x {
    return x*x;
}

+ (CGFloat)stroke_angle_differenceWithStrokeA:(Stroke *)a StrokeB:(Stroke *)b i:(NSInteger)i j:(NSInteger)j {
    return fabs([self angle_differenceWithAlpha:[self getAngleWithStroke:a number:i] Beta:[self getAngleWithStroke:b number:j]]);
}

+ (void)stepWithStokeA:(Stroke *)a StokeB:(Stroke *)b N:(NSInteger)N dist:(CGFloat *)dist prev_x:(NSInteger *)prev_x prev_y:(NSInteger *)prev_y x:(NSInteger)x y:(NSInteger)y tx:(CGFloat)tx ty:(CGFloat)ty k:(NSInteger *)k x2:(NSInteger)x2 y2:(NSInteger)y2 {
    CGFloat dtx = a.p[x2].t - tx;
    CGFloat dty = b.p[y2].t - ty;
    if (dtx >= dty * 2.2 || dty >= dtx * 2.2 || dtx < EPS || dty < EPS) {
        return;
    }
    (*k)++;
    
    CGFloat d=0.0;
    NSInteger i = x,  j = y;
    CGFloat next_tx =  (a.p[i+1].t - tx) / dtx;
    CGFloat next_ty =  (b.p[j+1].t - ty) / dty;
    CGFloat cur_t=0.000000001;
    
    for (; ; ) {
        CGFloat ad = [self sqr:[self angle_differenceWithAlpha:a.p[i].alpha Beta:b.p[j].alpha]];
        CGFloat next_t = next_tx < next_ty ? next_tx : next_ty;
        BOOL done = next_t >= 1.0 - EPS;
        if (done) {
            next_t = 1.0;
        }
        d += (next_t - cur_t) * ad;
        if (done) {
            break;
        }
        cur_t = next_t;
        if (next_tx < next_ty) {
            next_tx = (a.p[++i+1].t - tx) / dtx;
        } else {
            next_ty = (b.p[++j+1].t - ty) / dty;
        }
        
    }
    
    double new_dist = dist[x * N + y] + d * (dtx + dty);
    
    if (new_dist != new_dist) {
        abort();
    }
    
    if (new_dist >= dist[x2 * N + y2]) {
        return;
    }
    
    prev_x[x2 * N + y2] = x;
    prev_y[x2 * N + y2] = y;
    dist[x2 * N + y2] = new_dist;
}

+ (CGFloat)stroke_compareWithStrokeA:(Stroke *)a StrokeB:(Stroke *)b PathX:(NSInteger *)pathX PathY:(NSInteger *)pathY {
    const NSInteger M = a.n;
    const NSInteger N = b.n;
    //NSLog(@"M:%ld N:%ld",M,N);
    const NSInteger m = M - 1;
    const NSInteger n = N - 1;
    
    CGFloat *dist = malloc(M * N * sizeof(CGFloat));
    NSInteger *prev_x = malloc(M * N * sizeof(NSInteger));
    NSInteger *prev_y = malloc(M * N * sizeof(NSInteger));
    
    for (int i = 0; i < m; i++) {
        for (int j = 0; j < n; j++) {
            dist[i * N + j] = stroke_infinity;
        }
    }
    
    dist[M * N - 1] = stroke_infinity;
    dist[0] = 0.0;
    
    for (int x = 0; x < m; x++) {
        for (int y = 0; y < n; y++) {
            if (dist[x * N + y] >= stroke_infinity) {
                continue;
            }
            CGFloat tx = a.p[x].t;
            CGFloat ty = b.p[y].t;
            //NSLog(@"tx:%f ty:%f",tx,ty);
            NSInteger max_x = x;
            NSInteger max_y = y;
            
            NSInteger k = 0;
            
            while (k < 4) {
                if (a.p[max_x + 1].t - tx > b.p[max_y+1].t - ty) {
                    max_y++;
                    if (max_y == n) {
                        [self stepWithStokeA:a StokeB:b N:N dist:dist prev_x:prev_x prev_y:prev_y x:x y:y tx:tx ty:ty k:&k x2:m y2:n];
                        break;
                    }
                    for (int x2 = x + 1; x2 <= max_x; x2++) {
                        [self stepWithStokeA:a StokeB:b N:N dist:dist prev_x:prev_x prev_y:prev_y x:x y:y tx:tx ty:ty k:&k x2:x2 y2:max_y];
                    }
                } else {
                    max_x++;
                    if (max_x == m) {
                        [self stepWithStokeA:a StokeB:b N:N dist:dist prev_x:prev_x prev_y:prev_y x:x y:y tx:tx ty:ty k:&k x2:m y2:n];
                        break;
                    }
                    for (int y2 = y + 1; y2 <= max_y; y2++) {
                        [self stepWithStokeA:a StokeB:b N:N dist:dist prev_x:prev_x prev_y:prev_y x:x y:y tx:tx ty:ty k:&k x2:max_x y2:y2];
                    }
                }
            }
            //NSLog(@"max_x:%ld max_y:%ld",max_x,max_y);
            
        }
    }
    CGFloat cost = dist[M * N - 1];
    if (pathX && pathY) {
        if (cost < stroke_infinity) {
            NSInteger x = m;
            NSInteger y = n;
            NSInteger k = 0;
            while (x || y) {
                NSInteger old_x = x;
                x = prev_x[x * N + y];
                y = prev_y[old_x * N +y];
                pathX[k] = x;
                pathY[k] = y;
                k++;
            }
        }else {
            pathX[0] = 0;
            pathY[0] = 0;
        }
    }
    
    free(prev_x);
    free(prev_y);
    free(dist);
    
    return cost;
}
+ (double) compareByGestureA:(NSMutableArray*)A
                    GestureB:(NSMutableArray*)B;
{
    NSInteger n = A.count>B.count?B.count:A.count;
    
    if(n<5){
        return 0.000000;
    }
    Stroke *strokeA = [[Stroke alloc] initWithPointMutableArray:A];
    Stroke *strokeB = [[Stroke alloc] initWithPointMutableArray:B];
    [self finshWithStroke:strokeA];
    [self finshWithStroke:strokeB];
    double cost=[self stroke_compareWithStrokeA:strokeA StrokeB:strokeB PathX:nil PathY:nil];
    return  MAX(1.0 - 2.5*cost, 0.0)*100;
}
@end
