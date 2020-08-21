//
//  HistoryClipoardListWindowController.m
//  MacStroke
//
//  Created by MTJO on 2020/8/21.
//  Copyright © 2020 Chivalry Software. All rights reserved.
//

#import "HistoryClipoardListWindowController.h"

@interface HistoryClipoardListWindowController (){
    NSTableView * _tableView;
    NSMutableArray * _dataArray;
}
@end

@implementation HistoryClipoardListWindowController

- (void)windowDidLoad {
    [super windowDidLoad];
    
    // Implement this method to handle any initialization after your window controller's window has been loaded from its nib file.
   
    _dataArray = [NSMutableArray array];
    for (int i=0; i<20; i++) {
        [_dataArray addObject:[NSString stringWithFormat:@"%d行数据",i]];
    }
    [self.historyClipoard reloadData];
    
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    return 20;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSView *result;
    
    //if ([tableColumn.identifier isEqualToString:@"CheckBox"]) {
        NSTextField *textField = [[NSTextField alloc] init];
        [textField setBezeled:NO];
        [textField setEditable:NO];
        [textField setDrawsBackground:NO];
        [textField setStringValue:_dataArray[row] ];
        result = textField;
    //}

    return result;
}


- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return [_dataArray count];
}


@end
