//
//  DMTableRowView.m
//  MacStroke
//
//  Created by MTJO on 2021/8/26.
//  Copyright © 2021 Chivalry Software. All rights reserved.
//

#import "DMTableRowView.h"
#import "DMRefreshTableView.h"


@implementation DMTableRowView

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    
    // Drawing code here.
}


- (void)drawSelectionInRect:(NSRect)dirtyRect {
    if (self.selectionHighlightStyle != NSTableViewSelectionHighlightStyleNone) {
        NSRect selectionRect = NSInsetRect(self.bounds, 0, 0);
        //[NSColorFromRGB(0xEAF5FF,1.0f) setFill];
        NSBezierPath *selectionPath = [NSBezierPath bezierPathWithRoundedRect:selectionRect xRadius:0 yRadius:0];
        [selectionPath fill];
    }
}

@end
