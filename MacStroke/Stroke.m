//
//  Stroke.m
//  MacStroke
//
//  Created by MTJO on 2017/1/28.
//  Copyright © 2017年 Chivalry Software. All rights reserved.
//

#import "Stroke.h"



@implementation JOPoint

- (instancetype)initWithPointX:(CGFloat)x PointY:(CGFloat)y {
    if (self = [super init]) {
        _x = x;
        _y = y;
    }
    return self;
}

+ (instancetype)pointWithPointX:(CGFloat)x PointY:(CGFloat)y {
    return [[JOPoint alloc] initWithPointX:x PointY:y];
}

@end


@implementation Stroke

#pragma mark - Init
- (instancetype)initWithCapacity:(NSInteger)capacity {
    assert(capacity > 0);
    if (self = [super init]) {
        self.capacity = capacity;
        self.p = [[NSMutableArray alloc] initWithCapacity:capacity];
    }
    return self;
}

#pragma mark - Init
- (instancetype)initWithPointMutableArray:(NSMutableArray*)points {
    assert(points.count > 0);
    NSInteger capacity=points.count;
    if (self = [super init]) {
        self.capacity = capacity;
        self.p = [[NSMutableArray alloc] initWithCapacity:capacity];
        NSMutableArray<JOPoint *> *initP=[[NSMutableArray<JOPoint *> alloc] init];
        JOPoint *p=[[JOPoint alloc] init];
        for (int i = 0; i<capacity; i++) {
            NSPoint point = [points[i] pointValue];
             p= [JOPoint pointWithPointX:point.x PointY:point.y];
            
            [initP addObject:p];
        }
        
        self.p=initP;
        self.n=capacity;
    }
    return self;
}
+ (instancetype)strokeWithCapacity:(NSInteger)capacity {
    return [[Stroke alloc] initWithCapacity:capacity];
}
@end
