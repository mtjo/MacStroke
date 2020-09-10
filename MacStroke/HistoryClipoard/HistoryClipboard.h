//
//  HistoryClipboard.h
//  MacStroke
//
//  Created by MTJO on 2020/8/17.
//  Copyright © 2020 Chivalry Software. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface HistoryClipboard : NSObject
{
 
}

- (void) enableHistoryClipboard;

- (BOOL) isEnable;

- (NSMutableArray *) getHistoryClipboardList;

@end

NS_ASSUME_NONNULL_END
