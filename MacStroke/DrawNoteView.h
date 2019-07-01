//
//  NoteView.h
//  MacStroke
//
//  Created by MTJO on 2019/6/29.
//  Copyright © 2019 Chivalry Software. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "MGOptionsDefine.h"


NS_ASSUME_NONNULL_BEGIN

@interface DrawNoteView : NSView{
    NSString *note;
    NSColor *noteColor;
}

- (void)setNote:(NSString*) noteStr;
- (void)drawNote:(NSString*) noteStr;

@end


NS_ASSUME_NONNULL_END
