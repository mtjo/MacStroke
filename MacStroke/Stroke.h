//
//  Stroke.h
//  MacStroke
//
//  Created by MTJO on 2017/1/28.
//  Copyright © 2017年 Chivalry Software. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface JOPoint : NSObject

@property(nonatomic, assign) CGFloat x;
@property(nonatomic, assign) CGFloat y;
@property(nonatomic, assign) CGFloat t;
@property(nonatomic, assign) CGFloat dt;
@property(nonatomic, assign) CGFloat alpha;

- (instancetype)initWithPointX:(CGFloat)x PointY:(CGFloat)y;
+ (instancetype)pointWithPointX:(CGFloat)x PointY:(CGFloat)y;

@end


@interface Stroke : NSObject

@property(nonatomic, assign) NSInteger n;
@property(nonatomic, assign) NSInteger capacity;
@property(nonatomic, copy) NSMutableArray<JOPoint *> *p;

- (instancetype)initWithCapacity:(NSInteger)capacity;
- (instancetype)initWithPointMutableArray:(NSMutableArray*)points;
+ (instancetype)strokeWithCapacity:(NSInteger)capacity;

@end
