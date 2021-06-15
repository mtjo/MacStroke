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
static NSMutableArray<NSMutableDictionary *> *historyList = nil;
static NSMutableArray<NSMutableDictionary *> *topList = nil;
static long maxListCount = 0;
static bool limitHistoryListCount = false;
NSUserDefaults *sharedDefaults;
static  bool enable = false;

static NSString *HISTORY_CLIPOARD_LIST=@"historyClipoardList";
static NSString *LOCAL_HISTORY_CLIPOARD_LIST = @"localHistoryClipoardList";
static NSString *LOCAL_TOP_HISTORY_CLIPOARD_LIST = @"localTopHistoryClipoardList";
static NSString *CONTENT = @"content";
static NSString *ISTOP = @"isTop";

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
            NSMutableDictionary *item = [[NSMutableDictionary alloc] init];
            [item setValue:s forKey:CONTENT];
            [item setValue:@"0" forKey:ISTOP];
            [historyList insertObject:item atIndex:0];
            maxListCount = [sharedDefaults integerForKey:HISTORY_CLIPOARD_LIST];
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
                
                NSData *nsHistoryList = [NSKeyedArchiver archivedDataWithRootObject:historyList];
               
                [sharedDefaults setObject:nsHistoryList forKey:LOCAL_HISTORY_CLIPOARD_LIST];
                
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
    topList = [self getTopList];
    
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
            @try {
                NSData * data =   [sharedDefaults objectForKey:LOCAL_HISTORY_CLIPOARD_LIST];
                historyList = [[NSMutableArray alloc] initWithArray:[NSKeyedUnarchiver unarchiveObjectWithData:data]];
            } @catch (NSException *exception) {
                NSLog(@"LOCAL_HISTORY_CLIPOARD_LIST exception:%@", exception);
            }
            
#ifdef DEBUG
            NSLog(@"LOCAL_HISTORY_CLIPOARD_LIST:%@", historyList);
#endif

            
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

- (NSMutableArray<NSMutableDictionary*> *) getHistoryClipboardList{
    NSMutableArray<NSMutableDictionary*> * list = [[NSMutableArray alloc] init];
    [list addObjectsFromArray:topList];
    [list addObjectsFromArray:historyList];
    return list;
}

- (void) saveTop: (NSMutableArray<NSMutableDictionary*>*) saveList {
    topList = saveList;
    NSData *nsTopList = [NSKeyedArchiver archivedDataWithRootObject:saveList];
    [sharedDefaults setObject:nsTopList forKey:LOCAL_TOP_HISTORY_CLIPOARD_LIST];
    
#ifdef DEBUG
    NSLog(@"saveTop%@", saveList);
#endif
    [sharedDefaults synchronize];
}

- (NSMutableArray *) getTopList {
    NSMutableArray *toplist =[[NSMutableArray alloc] init];
    @try {
        NSData *data  =   [sharedDefaults objectForKey:LOCAL_TOP_HISTORY_CLIPOARD_LIST];
        toplist = [[NSMutableArray alloc] initWithArray:[NSKeyedUnarchiver unarchiveObjectWithData:data]];
    } @catch (NSException *exception) {
        NSLog(@"LOCAL_TOP_HISTORY_CLIPOARD_LIST exception: %@", exception);
    }
   
#ifdef DEBUG
    NSLog(@"topList:%@", toplist);
#endif
    return toplist;
}
-(BOOL) clearHistoryList{
    [historyList removeAllObjects];
    [self saveHistoryList:historyList];
    return enable;
}

- (void) saveHistoryList: (NSMutableArray<NSMutableDictionary*>*) saveList {
    NSData *nsTopList = [NSKeyedArchiver archivedDataWithRootObject:saveList];
    [sharedDefaults setObject:nsTopList forKey:LOCAL_HISTORY_CLIPOARD_LIST];
    
#ifdef DEBUG
    NSLog(@"saveHistoryList:%@", saveList);
#endif
    [sharedDefaults synchronize];
}

-(BOOL) isEnable{
    return enable;
}
@end
