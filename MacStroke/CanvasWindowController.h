//
//  CanvasWindowController.h
//  MouseGesture
//
//  Created by keakon on 11-11-18.
//  Copyright (c) 2011年 keakon.net. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "DrawNoteView.h"
#import "CanvasView.h"

@interface CanvasWindowController : NSWindowController {
    BOOL enable;
    NSRect frame;
    NSWindow *window;
    NSView *view, *lastView;
    NSMutableArray<NSView *> *viewList;
    BOOL cleanNote;
}

@property(assign, nonatomic) BOOL enable;

- (void)handleMouseEvent:(NSEvent *)event;

- (void)handleScreenParametersChange:(NSNotification *)notification;

- (void)writeActionRuleIndex:(NSInteger)actionRuleIndex;

- (void)reinitWindow; // reinit canvas window for dual screen

- (void)rightClick:(NSDictionary*) pointDic;

- (void)threadRightClick:(CGPoint) point;

@end
