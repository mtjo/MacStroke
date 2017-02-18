//
//  DrawGesture.h
//  MacStroke
//
//  Created by MTJO on 2017/1/30.
//  Copyright © 2017年 Chivalry Software. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface DrawGesture : NSView{

    NSMutableArray *points;

}


- (id)initWithFrame:(NSRect)frameRect;

- (void) setPoints:(NSMutableArray *)ruleDataPoints;

- (void)drawRect:(NSRect)rec;

@end
