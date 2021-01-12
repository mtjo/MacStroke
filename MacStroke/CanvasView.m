//
//  CanvasView.m
//  MouseGesture
//
//  Created by keakon on 11-11-14.
//  Copyright (c) 2011年 keakon.net. All rights reserved.
//

#import "CanvasView.h"
#import "RulesList.h"
#import "MGOptionsDefine.h"
#import <CoreImage/CoreImage.h>
#import "CanvasWindow.h"

@implementation CanvasView

static NSColor *loadedColor;

- (id)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    
    if (self) {
        color = [MGOptionsDefine getLineColor];
        points = [[NSMutableArray alloc] init];
        radius = 2;
    }
    
    return self;
}



- (void)drawRect:(NSRect)dirtyRect {
    // draw mouse line
    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"disableMousePath"]) {
        NSBezierPath *path = [NSBezierPath bezierPath];
        path.lineWidth = radius * 2;
        [color setStroke];
        //NSLog(@"%@",points);
        if (points.count >= 1) {
            [path moveToPoint:[points[0] pointValue]];
        }
        for (int i = 1; i < points.count; i++) {
            [path lineToPoint:[points[i] pointValue]];
        }
        [path stroke];
    }
}

- (void)clear {
    [points removeAllObjects];
    self.needsDisplay = YES;
}

- (void)resizeTo:(NSRect)frame {
    self.frame = frame;
    self.needsDisplay = YES;
}


- (void)mouseDown:(NSEvent *)event {
    lastLocation = [NSEvent mouseLocation];
    NSWindow *w = self.window;
    NSScreen *s = w.screen;
    lastLocation.x -= s.frame.origin.x;
    lastLocation.y -= s.frame.origin.y;
#ifdef DEBUG
    NSLog(@"mouseDown frame:%@, window:%@, screen:%@, point:%@", NSStringFromRect(self.frame), NSStringFromRect(w.frame), NSStringFromRect(s.frame), NSStringFromPoint(lastLocation));
#endif
    [points addObject:[NSValue valueWithPoint:lastLocation]];
}

- (void)mouseDragged:(NSEvent *)event {
    
    @autoreleasepool {
        NSPoint newLocation = event.locationInWindow;
        NSWindow *w = self.window;
        NSScreen *s = w.screen;
        newLocation.x -= s.frame.origin.x;
        newLocation.y -= s.frame.origin.y;
        
#ifdef DEBUG
        NSLog(@"mouseDragged frame:%@, window:%@, screen:%@, point:%@", NSStringFromRect(self.frame), NSStringFromRect(w.frame), NSStringFromRect(s.frame), NSStringFromPoint(newLocation));
#endif
        
        //[self drawCircleAtPoint:newLocation];
        [points addObject:[NSValue valueWithPoint:newLocation]];
        self.needsDisplay = YES;
        //		[self setNeedsDisplayInRect:NSMakeRect(fmin(lastLocation.x - radius, newLocation.x - radius),
        //											   fmin(lastLocation.y - radius, newLocation.y - radius),
        //											   abs(newLocation.x - lastLocation.x) + radius * 2,
        //											   abs(newLocation.y - lastLocation.y) + radius * 2)];
        lastLocation = newLocation;
    }
    
}

- (void)setEnable:(BOOL)shouldEnable {
    // No op. Supress warning and avoid possible selector not found errors.
}

- (void)mouseUp:(NSEvent *)event {
    [self clear];
}

@end
