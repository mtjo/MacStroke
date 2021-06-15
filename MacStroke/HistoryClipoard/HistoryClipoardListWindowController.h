//
//  HistoryClipoardListWindowController.h
//  MacStroke
//
//  Created by MTJO on 2020/8/21.
//  Copyright © 2020 Chivalry Software. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"
#import "HistoryClipboard.h"
NS_ASSUME_NONNULL_BEGIN

@interface HistoryClipoardListWindowController : NSWindowController <NSTableViewDelegate, NSTableViewDataSource>
{
    NSMutableArray<NSMutableDictionary* > * _dataArray;
    NSMutableArray<NSMutableDictionary* > * _topArray;
    IBOutlet NSTableView *tableOutlet;
    HistoryClipboard * historyClipboard;
}
- (IBAction)clearAllTop:(id)sender;
- (IBAction)clearHistoryList:(id)sender;
@property (assign) IBOutlet NSTableView *tableOutlet;

- (void)doubleClick:(id)nid;

@end

NS_ASSUME_NONNULL_END
