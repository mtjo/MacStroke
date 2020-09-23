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
static NSMutableArray *historyList = nil;
static long maxListCount = 0;
static bool limitHistoryListCount = false;
NSUserDefaults *sharedDefaults;
static  bool enable = false;

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
            maxListCount = [sharedDefaults integerForKey:@"historyClipoardList"];
            if (maxListCount > 0 && limitHistoryListCount) {
                
                if ([historyList count] >maxListCount) {
                    for (long i=maxListCount-1; i<[historyList count]; i++) {
                        [historyList removeObjectAtIndex:i];
                    }
                }
            }
            
            //NSLog(@"NSPasteboard:%@", historyList);
            
#ifdef DEBUG
            NSLog(@"clipoardStroageLocal:%hdd", [[NSUserDefaults standardUserDefaults] boolForKey:@"clipoardStroageLocal"]);
#endif
            if([sharedDefaults boolForKey:@"clipoardStroageLocal"]){
                [sharedDefaults setObject:historyList forKey:@"localHistoryClipoardList"];
                
#ifdef DEBUG
                NSLog(@"NSPasteboard:%@", historyList);
#endif
                [sharedDefaults synchronize];
            }
            
            
        }
        changeCount = [pasteboard changeCount];
    }
}

- (void) enableHistoryClipboard
{
    sharedDefaults = [NSUserDefaults standardUserDefaults];
    bool enableHistoryClipboard =  [sharedDefaults boolForKey:@"enableHistoryClipboard"];
    
#ifdef DEBUG
    NSLog(@"enableHistoryClipboard:%hdd", enableHistoryClipboard);
#endif
    
    
    if (enableHistoryClipboard) {
        limitHistoryListCount =  [sharedDefaults boolForKey:@"limitHistoryListCount"];
        
        enable = true;
        if (timer != nil) {
            [timer invalidate];
        }
        if (historyList == nil) {
            historyList = [[NSMutableArray alloc] init];
        }
        if([[NSUserDefaults standardUserDefaults] boolForKey:@"clipoardStroageLocal"]){
            NSArray * array =   [sharedDefaults arrayForKey:@"localHistoryClipoardList"];
            
#ifdef DEBUG
            NSLog(@"localHistoryClipoardList:%@", array);
#endif
            [historyList addObjectsFromArray:array];
            
        }
        timer = [NSTimer scheduledTimerWithTimeInterval: 0.5
                                                 target: self
                                               selector: @selector(handleTimer:)
                                               userInfo: nil
                                                repeats: YES];
        
    }else{
        maxListCount = 0;
        enable = false;
        [timer invalidate];
    }
}

- (NSMutableArray *) getHistoryClipboardList{
    return historyList;
}
-(BOOL) isEnable{
    return enable;
}
@end
