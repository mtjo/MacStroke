//
//  GestureCompare.h
//  MacStroke
//
//  Created by MTJO on 2017/1/28.
//  Copyright © 2017年 Chivalry Software. All rights reserved.
//

#import <Foundation/Foundation.h>

@class Stroke;

@interface GestureCompare : NSObject

extern CGFloat const stroke_infinity;

+ (void)addPoint:(Stroke *)stroke withPointX:(CGFloat)x PointY:(CGFloat)y;
+ (void)finshWithStroke:(Stroke *)stroke;


+ (NSInteger)getSize:(Stroke *)stroke;
+ (void)getPointWithStroke:(Stroke *)stroke number:(NSInteger)n PointX:(CGFloat *)x PointY:(CGFloat *)y;
+ (CGFloat)getTimeWithStroke:(Stroke *)stroke number:(NSInteger)n;
+ (CGFloat)getAngleWithStroke:(Stroke *)stroke number:(NSInteger)n;
+ (CGFloat)stroke_angle_differenceWithStrokeA:(Stroke *)a StrokeB:(Stroke *)b i:(NSInteger)i j:(NSInteger)j;
+ (CGFloat)stroke_compareWithStrokeA:(Stroke *)a StrokeB:(Stroke *)b PathX:(NSInteger *)pathX PathY:(NSInteger *)pathY;
+ (double) compareByGestureA:(NSMutableArray*)A GestureB:(NSMutableArray*)B;
@end
