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
#import "DMRefreshTableView.h"
NS_ASSUME_NONNULL_BEGIN

@interface HistoryClipoardListWindowController : NSWindowController <NSTableViewDelegate,DMRefreshTableViewDelegate, NSTableViewDataSource>
{
    NSMutableArray<NSMutableDictionary* > * _dataArray;
    HistoryClipboard * historyClipboard;
}
- (IBAction)clearAllTop:(id)sender;
- (IBAction)clearHistoryList:(id)sender;
@property (assign) IBOutlet DMRefreshTableView *tableOutlet;

@property (nonatomic, assign) DMRefreshTableViewState state;
@property (nonatomic, weak) id<DMRefreshTableViewDelegate> refreshDelegate;

- (void)doubleClick:(id)nid;
- (IBAction)clearAll:(id)sender;

@end

NS_ASSUME_NONNULL_END
