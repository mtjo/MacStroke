//
//  DrawGesture.h
//  MacStroke
//
//  Created by MTJO on 2017/1/30.
//  Copyright © 2017年 Chivalry Software. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "AppPrefsWindowController.h"

@interface DrawGesture : NSView{

    NSMutableArray *points;
    NSInteger ruleIndex;
    AppPrefsWindowController * _appPrefsWindowController;
}


- (id)initWithFrame:(NSRect)frameRect atRow:(NSInteger)row atAppPrefsWindowController:(AppPrefsWindowController *)appPrefsWindowController;

- (void) setPoints:(NSMutableArray *)ruleDataPoints;

- (void)drawRect:(NSRect)rec;

@end
