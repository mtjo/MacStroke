//
//  HistoryClipoardListWindowController.h
//  MacStroke
//
//  Created by MTJO on 2020/8/21.
//  Copyright © 2020 Chivalry Software. All rights reserved.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface HistoryClipoardListWindowController : NSWindowController <NSTableViewDelegate, NSTableViewDataSource>
@property(nonatomic, strong) IBOutlet NSTableView *historyClipoard;
@end

NS_ASSUME_NONNULL_END
