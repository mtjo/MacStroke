//
//  HistoryClipboard.h
//  MacStroke
//
//  Created by MTJO on 2020/8/17.
//  Copyright © 2020 Chivalry Software. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
static NSString *CONTENT = @"content";
static NSString *ISTOP = @"is_top";
static int pageSize = 30;
@interface HistoryClipboard : NSObject
{
    
}

- (void) enableHistoryClipboard;

- (BOOL) isEnable;

- (NSMutableArray *) getHistoryClipboardList:(bool)firstPage;

- (NSMutableArray *) getTopList;

-(BOOL) clearHistoryList;

-(NSMutableDictionary*) insertlocalHistoryClipoard:(NSString* )content isTop:(int)isTop;
-(NSInteger)topCount;

- (bool)addTop:(NSString*) top;

- (void)removeTop:(NSInteger) rowNum;
- (void) nextPage;
- (void) clearTop;
- (void) clearAll;
@end

NS_ASSUME_NONNULL_END
