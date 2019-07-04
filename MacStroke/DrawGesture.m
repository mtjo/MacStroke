//
//  DrawGesture.m
//  MacStroke
//
//  Created by MTJO on 2017/1/30.
//  Copyright © 2017年 Chivalry Software. All rights reserved.
//

#import "DrawGesture.h"
#import <CoreImage/CoreImage.h>
#import "AppPrefsWindowController.h"
#import "AppDelegate.h"

@implementation DrawGesture
- (id)initWithFrame:(NSRect)frameRect atRow:(NSInteger)row atAppPrefsWindowController:(AppPrefsWindowController*)appPrefsWindowController;
{
    self = [super initWithFrame:frameRect];
    ruleIndex = row;
    points = [[NSMutableArray alloc] init];
    _appPrefsWindowController = appPrefsWindowController;
    
    return self;
}

- (void)setPoints:(NSMutableArray *)ruleDataPoints;{
    NSInteger pcount =ruleDataPoints.count;
    double max_x = 0;
    double max_y = 0;
    
    double min_x = 0;
    double min_y = 0;
    
    for (NSInteger i=0; i<pcount; i++) {
        NSPoint p = [ruleDataPoints[i] pointValue];
        if(i==0){
            min_x=p.x;
            min_y=p.y;
            max_x=p.x;
            max_y=p.y;
        }else{
            min_x =p.x<min_x?p.x:min_x;
            min_y =p.y<min_y?p.y:min_y;
            max_x =p.x>max_x?p.x:max_x;
            max_y =p.y>max_y?p.y:max_y;
        }
    }
    double width = fabs(max_x-min_x);
    double hight = fabs(max_y-min_y);
    //NSLog(@"width:%f hight:%f",width,hight);
    
    double canvas_width = 60;
    
    double canvas_hight = 60;
    
    double x_zoo = width /canvas_width*1.0;
    double y_zoo = hight /canvas_hight*1.0;
    double zoo = width>hight?x_zoo:y_zoo;
    
    double fix_x = (width<hight?(canvas_width-(width/zoo))/2:0)+12;
    double fix_y = (width>hight?(canvas_hight-(hight/zoo))/2:0)+12;
    //NSLog(@"fix_x:%f fix_y:%f",fix_x,fix_y);
    
    
    for (NSInteger i=0; i<pcount; i++) {
        NSPoint p = [ruleDataPoints[i] pointValue];
        [points addObject:[NSValue valueWithPoint:NSMakePoint((int)((p.x-min_x)/zoo+fix_x),(int)((p.y-min_y)/zoo+fix_y))]];
    }
    //NSLog(@"%@",points);
}

- (void)drawRect:(NSRect)rec;
{
    NSBezierPath *path = [NSBezierPath bezierPath];
    path.lineWidth =  2;
    NSColor *color = [NSColor colorWithRed:1 green:0.1 blue:0 alpha:1];
    if ([points count]>0){
        for (int i = 0; i < points.count-1; i++) {
            color = [NSColor colorWithRed:0.5*i/(1.00*points.count) green:0.47+0.53*i/(1.00*points.count) blue:0.9 alpha:1];
            [color setStroke];
            [path moveToPoint:[points[i] pointValue]];
            [path lineToPoint:[points[i+1] pointValue]];
            [path stroke];
            [path removeAllPoints];
        }
    }else{
        
        NSButton *addButton = [[NSButton alloc] initWithFrame:NSMakeRect(0 , 28, 80, 25)] ;
        [addButton setTag:ruleIndex];
        [addButton setBezelStyle:NSTexturedSquareBezelStyle];
        
        [addButton setAction:@selector(onSetGestureData:)];
        [addButton setTitle:NSLocalizedString(@"Draw Gesture", nil)];
        [addButton setTranslatesAutoresizingMaskIntoConstraints:YES];
        [self addSubview:addButton];

        
    }
}
- (void)mouseDown:(NSEvent *)theEvent;{
    if (theEvent.clickCount == 2) {
        //NSLog(@"双击");
        //NSLog(@"indexId:%ld",(long) ruleIndex);
        [_appPrefsWindowController preSetRuleGestureAtIndex:ruleIndex];
    }
}
@end
