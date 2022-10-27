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
    //[NSScreen mainScreen]
    NSNumber *longNumber = [NSNumber numberWithLong:[[NSScreen mainScreen] hash]];
    NSString *screenkey = [longNumber stringValue];
    if ([[windows allKeys] containsObject:screenkey]) {
        window = [windows objectForKey:screenkey];
    }else{
        window = [[CanvasWindow alloc] initWithContentRect:frame];
        [windows setObject:window forKey:screenkey];
    }
    [view releaseGState];
    
    view = [[CanvasView alloc] initWithFrame:frame];
    
    [viewList addObject:view];
    window.contentView = view;
    window.level = CGShieldingWindowLevel();
    window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces;
    self.window = window;
    [window orderFront:self];
    [window setReleasedWhenClosed:YES];
}

- (id)init {
    self = [super init];
    viewList = [[NSMutableArray alloc] init];
    windows = [NSMutableDictionary dictionary];
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

- (void)showNoteTost:(NSString*) note {
    if (note) {
        
        float noteBackgroundAlpha=[[NSUserDefaults standardUserDefaults] doubleForKey:@"noteBackgroundAlpha"];
        
        //clear draw note after noteRetetionTime
        NSInteger noteRetetionTime = [[NSUserDefaults standardUserDefaults] integerForKey:@"noteRetetionTime"];
        ToastWindowController *toastWindow=[ToastWindowController getToastWindow];
        toastWindow.toastBackgroundColor=[NSColor colorWithRed:0 green:0 blue:0 alpha:noteBackgroundAlpha];
        //toastWindow.backgroundColor
        NSFont *font = [NSFont fontWithName:[[NSUserDefaults standardUserDefaults] objectForKey:@"noteFontName"] size:[[NSUserDefaults standardUserDefaults] doubleForKey:@"noteFontSize"]];
        
        BOOL hiddenNoteIcon = ![[NSUserDefaults standardUserDefaults] boolForKey:@"showNoteIcon"];
        toastWindow.hiddenIcon=hiddenNoteIcon;
        toastWindow.textFont = font;
        toastWindow.animater=CTAnimaterFade;
        toastWindow.animaterTimeSecond=0.3;
        toastWindow.autoDismissTimeInSecond=noteRetetionTime;
        
        long notePostion  = [[NSUserDefaults standardUserDefaults] integerForKey:@"notePostion"];
        switch (notePostion) {
            case 0:
                toastWindow.toastPostion=CTPositionMouse;
                break;
            case 1:
                toastWindow.toastPostion=CTPositionCenter;
                break;
            case 2:
                toastWindow.toastPostion=CTPositionRight|CTPositionTop;
                break;
            case 3:
                toastWindow.toastPostion=CTPositionRight|CTPositionBottom;
                break;
            case 4:
                toastWindow.toastPostion=CTPositionLeft|CTPositionTop;
                break;
            case 5:
                toastWindow.toastPostion=CTPositionLeft|CTPositionBottom;
                break;
            default:
                toastWindow.toastPostion=CTPositionCenter;
                break;
        }
        
        
        
        //toastWindow.maxWidth=250;
        //toastWindow.delegate=self;
        [toastWindow showCoolToast:note];
    }
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
