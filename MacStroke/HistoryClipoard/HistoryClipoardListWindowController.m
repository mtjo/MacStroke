//
//  HistoryClipoardListWindowController.m
//  MacStroke
//
//  Created by MTJO on 2020/8/21.
//  Copyright © 2020 Chivalry Software. All rights reserved.
//

#import "HistoryClipoardListWindowController.h"

@interface HistoryClipoardListWindowController (){
    
}
@end

@implementation HistoryClipoardListWindowController
@synthesize tableOutlet = _tableOutlet;

- (void)windowDidLoad {
    [super windowDidLoad];
    
    // Implement this method to handle any initialization after your window controller's window has been loaded from its nib file.
    _dataArray = [[[AppDelegate appDelegate] getHistoryClipboard] getHistoryClipboardList];
#ifdef DEBUG
    NSLog(@"HistoryClipoardList:%@",_dataArray);
#endif
    
    
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    return 20;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSView *result;
    NSTextField *textField = [[NSTextField alloc] init];
    [textField setBezeled:NO];
    [textField setEditable:NO];
    [textField setDrawsBackground:NO];
    [textField setTag:row];
    
    //NSLog(@"identifier:%@",tableColumn.identifier);
    //NSLog(@"_dataArray:%@",_dataArray[row]);
    if ([tableColumn.identifier isEqualToString:@"id"]) {
        [textField setStringValue:[NSString stringWithFormat:@"%ld",(long)row+1]];
    }else if ([tableColumn.identifier isEqualToString:@"content"]) {
        [textField setStringValue:_dataArray[row]];
    }
    
    result = textField;
    
    return result;
}


- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return [_dataArray count];
}



- (void)awakeFromNib {
    [_tableOutlet setTarget:self];
    [_tableOutlet setDoubleAction:@selector(doubleClick:)];
}

- (void)doubleClick:(id)object {
    // This gets called after following steps 1-3.
    NSInteger row = [_tableOutlet clickedRow];
    
#ifdef DEBUG
    NSLog(@"doubleClick rowNumber:%ld",row);
#endif
    if (row < 0) {
        return;
    }
    NSString *s =_dataArray[row];
    [_dataArray removeObjectAtIndex:row];
    
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];  //必须清空，否则setString会失败。
    [pasteboard setString:s forType:NSStringPboardType];
    [self.window close];
}
- (IBAction)clearHistoryList:(id)sender {
    [_dataArray removeAllObjects];
    [_tableOutlet reloadData];
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"clipoardStroageLocal"]) {
        NSLog(@"clipoardStroageLocal:%hhd",[[NSUserDefaults standardUserDefaults] boolForKey:@"clipoardStroageLocal"]);
        
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"localHistoryClipoardList"];
    }
}


@end
