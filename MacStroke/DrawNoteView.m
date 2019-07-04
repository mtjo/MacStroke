//
//  NoteView.m
//  MacStroke
//
//  Created by MTJO on 2019/6/29.
//  Copyright © 2019 Chivalry Software. All rights reserved.
//

#import "DrawNoteView.h"

@implementation DrawNoteView


- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        noteColor = [MGOptionsDefine getNoteColor];
    }
    return self;
}
- (void)drawNote:(NSString*) noteStr {
    // This should be called in drawRect
    note = noteStr;
    NSLog(@"note:%@",note);
    
    [NSGraphicsContext saveGraphicsState];
    double noteBackgroundAlpha=[[NSUserDefaults standardUserDefaults] doubleForKey:@"noteBackgroundAlpha"];
    
    CGRect screenRect = [[NSScreen mainScreen] frame];
    
    NSFont *font = [NSFont fontWithName:[[NSUserDefaults standardUserDefaults] objectForKey:@"noteFontName"] size:[[NSUserDefaults standardUserDefaults] doubleForKey:@"noteFontSize"]];
    
    NSDictionary *textAttributes = @{NSFontAttributeName : font, NSForegroundColorAttributeName : noteColor};
    
    CGSize size = [note sizeWithAttributes:textAttributes];
    float x = ((screenRect.size.width - size.width) / 2);
    float y = ((screenRect.size.height)/2);
    
    
    CGContextRef context = [[NSGraphicsContext currentContext] graphicsPort];
    CGContextSetRGBFillColor (context, 0, 0, 0, noteBackgroundAlpha);
    CGContextFillRect (context, CGRectMake (x, y, size.width,size.height));
    
    [note drawAtPoint:NSMakePoint(x, y) withAttributes:textAttributes];
    [NSGraphicsContext restoreGraphicsState];
    
    
    self.needsDisplay = YES;
}
- (void)setNote:(NSString*) noteStr;{
    note = noteStr;
    self.needsDisplay = YES;
}
@end
