//
//  CanvasWindowController.h
//  MouseGesture
//
//  Created by keakon on 11-11-18.
//  Copyright (c) 2011年 keakon.net. All rights reserved.
//
#import <CoolToast/ToastWindowController.h>
#import <Cocoa/Cocoa.h>
#import "DrawNoteView.h"
#import "CanvasView.h"


@interface CanvasWindowController : NSWindowController {
    BOOL enable;
    NSMutableArray<NSView *> *viewList;
    
    NSMutableDictionary *windows;
    NSWindow *window;
    NSView *view;
}

@property(assign, nonatomic) BOOL enable;

- (void)handleMouseEvent:(NSEvent *)event;

- (void)handleScreenParametersChange:(NSNotification *)notification;

//- (void)writeActionRuleIndex:(NSInteger)actionRuleIndex;

- (void)showNoteTost:(NSString*) note;

- (void)reinitWindow; // reinit canvas window for dual screen

- (void)rightClick:(NSDictionary*) pointDic;

- (void)threadRightClick:(CGPoint) point;

// - (void)clearNote:(NSTimer *)timer;

@end
