//
//  CanvasWindowController.m
//  MouseGesture
//
//  Created by keakon on 11-11-18.
//  Copyright (c) 2011年 keakon.net. All rights reserved.
//

#import "CanvasWindowController.h"
#import "CanvasWindow.h"
#import "CanvasView.h"
#import "RulesList.h"

@implementation CanvasWindowController

- (void)reinitWindow {
    NSRect frame = NSScreen.mainScreen.frame;
    NSWindow *window = [[CanvasWindow alloc] initWithContentRect:frame];
    NSView *view = [[CanvasView alloc] initWithFrame:frame];
    [viewList addObject:view];
    window.contentView = view;
    window.level = CGShieldingWindowLevel();
    window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces;
    self.window = window;
    [window orderFront:self];
    
}

- (id)init {
    self = [super init];
    viewList = [[NSMutableArray alloc] init];
    if (self) {
        [self reinitWindow];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(handleScreenParametersChange:) name:NSApplicationDidChangeScreenParametersNotification object:nil];
    }
    return self;
}

- (BOOL)enable {
    return enable;
}

- (void)setEnable:(BOOL)shouldEnable {
    enable = shouldEnable;
    if (shouldEnable) {
        [self.window orderFront:self];
    } else {
        [self.window orderOut:self];
    }
    [self.window.contentView setEnable:shouldEnable];
}

- (void)handleMouseEvent:(NSEvent *)event {
    switch (event.type) {
        case NSRightMouseDown:
            [self.window.contentView mouseDown:event];
            break;
        case NSRightMouseDragged:
            [self.window.contentView mouseDragged:event];
            break;
        case NSRightMouseUp:
            [self.window.contentView mouseUp:event];
            //clear draw note after noteRetetionTime
            double noteRetetionTime = [[NSUserDefaults standardUserDefaults] doubleForKey:@"noteRetetionTime"];
            [NSTimer scheduledTimerWithTimeInterval:noteRetetionTime target:self selector:@selector(clearNote:) userInfo:viewList repeats:NO];
            break;
        default:
            break;
    }
}

- (void)handleScreenParametersChange:(NSNotification *)notification {
    NSRect frame = NSScreen.mainScreen.frame;
    [self.window setFrame:frame display:NO];
    [self.window.contentView resizeTo:frame];
}

- (void)writeActionRuleIndex:(NSInteger)actionRuleIndex; {
    [self.window.contentView writeActionRuleIndex:actionRuleIndex];
}

- (void)rightClick:(NSDictionary*) pointDic;{
    double x =[[pointDic valueForKey:@"x"] doubleValue];
    double y =[[pointDic valueForKey:@"y"] doubleValue];
#ifdef DEBUG
    NSLog(@"NSDictionary point:%@", pointDic);
    NSLog(@"callRightMenu at x:%f y:%f", x,y);
#endif
    CGPoint point = CGPointMake(x, y);
    //usleep(25000);
    CGEventRef controlDown = CGEventCreateKeyboardEvent(NULL, 0x3B, true);
    CGEventPost(kCGSessionEventTap, controlDown);
    CFRelease(controlDown);
    usleep(25000);// Improve reliability
    
    CGEventRef leftDown = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown,point, kCGMouseButtonLeft);
    CGEventPost(kCGHIDEventTap, leftDown);
    CFRelease(leftDown);
    
    usleep(15000); // Improve reliability
    
    // Left button up
    CGEventRef leftUp = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, point, kCGMouseButtonLeft);
    CGEventPost(kCGHIDEventTap, leftUp);
    
    CGEventRef controlUp  = CGEventCreateKeyboardEvent(NULL, 0x3B, false);
    CGEventPost(kCGSessionEventTap, controlUp);
    CFRelease(controlUp);
    
    CFRelease(leftUp);
}

- (void)threadRightClick:(CGPoint) point;{
    NSThread * newThread = [[NSThread alloc]initWithTarget:self selector:@selector(rightClick:) object:@{@"x":@(point.x),@"y":@(point.y)}] ;
    [newThread start];
}

- (void)clearNote:(NSTimer *)timer{
#ifdef DEBUG
    NSLog(@"%ld",[viewList count]);
#endif
    NSArray *_viewList = [[NSArray alloc] initWithArray: [timer userInfo]];
    _viewList = [[_viewList reverseObjectEnumerator] allObjects];
    if ([_viewList count]>0) {
        for(int i = 0; i < [_viewList count]; i++){
            if (i>5) {
                break;
            }
#ifdef DEBUG
            NSLog(@"%d",i );
#endif
            
            [[_viewList objectAtIndex:i] removeFromSuperview];
            [[_viewList objectAtIndex:i] releaseGState];
        }
    }
}

@end
