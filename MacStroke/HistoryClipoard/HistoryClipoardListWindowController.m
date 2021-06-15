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
    historyClipboard = [[AppDelegate appDelegate] getHistoryClipboard];
    // Implement this method to handle any initialization after your window controller's window has been loaded from its nib file.
    _dataArray = [historyClipboard getHistoryClipboardList];
    _topArray = [historyClipboard getTopList];
    [_tableOutlet reloadData];
    
#ifdef DEBUG
    NSLog(@"HistoryClipoardList:%@",_dataArray);
    NSLog(@"_topArray:%@",_topArray);
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
    
#ifdef DEBUG
    NSLog(@"identifier:%@",tableColumn.identifier);
    NSLog(@"_dataArray:%@",_dataArray[row]);
#endif

    if ([tableColumn.identifier isEqualToString:@"id"]) {
        NSInteger topCount = [_topArray count];
        if (row<topCount) {
            [textField setStringValue:[NSString stringWithFormat:@"[%ld]",(long)row+1]];
            NSColor *color = [NSColor colorWithCalibratedWhite:0.65 alpha:1.0];
            [textField setTextColor:color];
        }else{
            [textField setStringValue:[NSString stringWithFormat:@"%ld",(long)row-topCount+1]];
        }
        result = textField;
    }else if ([tableColumn.identifier isEqualToString:@"content"]) {
        if ([_dataArray[row][@"isTop"] isEqualToString:@"1"]) {
            NSColor *color = [NSColor colorWithCalibratedWhite:0.65 alpha:1.0];
            [textField setTextColor:color];
        }
        [textField setStringValue:_dataArray[row][@"content"]];
        result = textField;
    }else if ([tableColumn.identifier isEqualToString:@"operate"]) {
        NSButton *topBtn = [[NSButton alloc] initWithFrame:NSMakeRect(0 , 0, 20, 20)] ;
        [topBtn setTag:row];
        [topBtn setBezelStyle:NSTexturedSquareBezelStyle];
        [topBtn setTranslatesAutoresizingMaskIntoConstraints:YES];
        [topBtn setTag:row];
        //[operate setAction:@selector(onSetGestureData:)];
        if ([_dataArray[row][@"isTop"] isEqualToString:@"0"]) {
            [topBtn setTitle:@"↑"];
            [topBtn setToolTip:NSLocalizedString(@"top", nil)];
            [topBtn setAction:@selector(addTop:)];
        }else{
            [topBtn setTitle:@"-"];
            [topBtn setToolTip:NSLocalizedString(@"remove top", nil)];
            [topBtn setAction:@selector(removeTop:)];
        }
        result = topBtn;
    }
        
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
    NSString *s = _dataArray[row][@"content"];
    [_dataArray removeObjectAtIndex:row];
    
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];  //必须清空，否则setString会失败。
    [pasteboard setString:s forType:NSStringPboardType];
    [self.window close];
}
- (IBAction)clearHistoryList:(id)sender {
    [_dataArray removeAllObjects];
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"clipoardStroageLocal"]) {
        NSLog(@"clipoardStroageLocal:%hhd",[[NSUserDefaults standardUserDefaults] boolForKey:@"clipoardStroageLocal"]);
        [historyClipboard clearHistoryList];
    }
    [self windowDidLoad];
}
- (void)keyDown:(NSEvent*)event {
  NSLog(@"%@ %@ - %@", self.className, NSStringFromSelector(_cmd), event);
  [self interpretKeyEvents:[NSArray arrayWithObject:event]];
}
- (void)cancelOperation:(id)sender {
  NSLog(@"%@ %@ - %@", self.className, NSStringFromSelector(_cmd), sender);
  [self close];
}

- (IBAction)addTop:(id)sender {
    NSButton * btn = (NSButton *)sender;
    NSInteger row = [btn tag];
    
#ifdef DEBUG
    NSLog(@"addTop rowNumber:%ld",row);
#endif
    if (row < 0) {
        return;
    }
    NSString *s = _dataArray[row][@"content"];
#ifdef DEBUG
    NSLog(@"addTop content:%@",s);
#endif
    NSMutableDictionary *item = [[NSMutableDictionary alloc] init];
    [item setValue:s forKey:@"content"];
    [item setValue:@"1" forKey:@"isTop"];
    
    [_topArray insertObject:item atIndex:0];
    
#ifdef DEBUG
    NSLog(@"item to add:%@ ,_topArray :%@",item, _topArray);
#endif
    [historyClipboard saveTop:_topArray];
    [self windowDidLoad];

    [_tableOutlet scrollRowToVisible:0];

}

- (IBAction)removeTop:(id)sender {
    NSButton * btn = (NSButton *)sender;
    NSInteger row = [btn tag];
    
#ifdef DEBUG
    NSLog(@"removeTop rowNumber:%ld",row);
#endif
    if (row < 0) {
        return;
    }
    [_topArray removeObjectAtIndex:row];
#ifdef DEBUG
    NSLog(@"_topArray :%@",_topArray);
#endif
    [historyClipboard saveTop:_topArray];
    [self windowDidLoad];
}

@end
