//
//  HistoryClipboard.m
//  MacStroke
//
//  Created by MTJO on 2020/8/17.
//  Copyright © 2020 Chivalry Software. All rights reserved.
//

#import "HistoryClipboard.h"

@implementation HistoryClipboard
static NSTimer *timer = nil;
static long changeCount;
static    NSMutableArray<NSString *> *historyList = nil;

- (void) handleTimer: (NSTimer *) timer
{
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    if (changeCount < [pasteboard changeCount]) {
#ifdef DEBUG
        NSLog(@"changeCount:%ld", (long)[pasteboard changeCount]);
#endif
        
        NSArray *types = [pasteboard types];
        if ([types containsObject:NSPasteboardTypeString]) {
            NSString *s = [pasteboard stringForType:NSPasteboardTypeString];
            [historyList insertObject:s atIndex:0];
            NSLog(@"NSPasteboard:%@", historyList);
           
        }
        changeCount = [pasteboard changeCount];
    }
}

- (void) enableHistoryClipboard
{
    NSUserDefaults *sharedDefaults = [NSUserDefaults standardUserDefaults];
    bool enableHistoryClipboard =  [sharedDefaults boolForKey:@"enableHistoryClipboard"];
    NSLog(@"enableHistoryClipboard:%hdd", enableHistoryClipboard);
    
    if (enableHistoryClipboard) {
        if (timer != nil) {
            [timer invalidate];
        }
        if (historyList == nil) {
            historyList = [[NSMutableArray alloc] init];
        }
        timer = [NSTimer scheduledTimerWithTimeInterval: 1
                                                 target: self
                                               selector: @selector(handleTimer:)
                                               userInfo: nil
                                                repeats: YES];
        
    }else{
        [timer invalidate];
    }
    
    
    
}



@end
