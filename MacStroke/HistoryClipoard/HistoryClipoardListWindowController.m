//
//  HistoryClipoardListWindowController.m
//  MacStroke
//
//  Created by MTJO on 2020/8/21.
//  Copyright © 2020 Chivalry Software. All rights reserved.
//

#import "HistoryClipoardListWindowController.h"
#import "LSQLiteDB.h"

@interface HistoryClipoardListWindowController (){
    BOOL isScrollAnimated;
    BOOL isperformSelector;
    NSRect lastRect;
    BOOL isAddObserverNotify;
    BOOL _isLastPage;
}
@end

@implementation HistoryClipoardListWindowController
@synthesize tableOutlet = _tableOutlet;

- (void)windowDidLoad {
    [super windowDidLoad];
    historyClipboard = [[AppDelegate appDelegate] getHistoryClipboard];
    // Implement this method to handle any initialization after your window controller's window has been loaded from its nib file.
    
    // delete expired item
    [historyClipboard deleteExpired];
    _dataArray = [historyClipboard getHistoryClipboardList:YES];
    [_tableOutlet reloadData];
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
    [[textField cell] setLineBreakMode:NSLineBreakByTruncatingMiddle];
    //[[textField cell] setTruncatesLastVisibleLine:YES];
    
    [textField setTag:row];
    NSInteger topCount = [historyClipboard topCount];
    @try {
        
#ifdef DEBUG
        NSLog(@"identifier:%@",tableColumn.identifier);
        NSLog(@"_dataArray:%@",_dataArray[row]);
#endif
        
        if ([tableColumn.identifier isEqualToString:@"id"]) {
            if (row<topCount) {
                [textField setStringValue:[NSString stringWithFormat:@"[%ld]",(long)row+1]];
                NSColor *color = [NSColor colorWithCalibratedWhite:0.65 alpha:1.0];
                [textField setTextColor:color];
            }else{
                [textField setStringValue:[NSString stringWithFormat:@"%ld",(long)row-topCount+1]];
            }
            result = textField;
        }else if ([tableColumn.identifier isEqualToString:@"content"]) {
            //NSLog(@"is_top:%@",_dataArray[row][ISTOP]);
            if (row<topCount) {
                NSColor *color = [NSColor colorWithCalibratedWhite:0.65 alpha:1.0];
                [textField setTextColor:color];
            }
            NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:_dataArray[row][@"content"] options:0];
            NSString *decodedString = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
            //NSLog(@"decodedString: %@", decodedString);
            [textField setStringValue:[decodedString stringByReplacingOccurrencesOfString:@"\n" withString:@" "]];
            //        [textField setStringValue:[_dataArray[row][@"content"]  stringByReplacingOccurrencesOfString:@"\n" withString:@"↵"]];
            result = textField;
        }else if ([tableColumn.identifier isEqualToString:@"operate"]) {
            NSButton *topBtn = [[NSButton alloc] initWithFrame:NSMakeRect(0 , 0, 25, 25)] ;
            [topBtn setTag:row];
            [topBtn setBezelStyle:NSTexturedSquareBezelStyle];
            [topBtn setAutoresizesSubviews:false];
            ///[topBtn setTranslatesAutoresizingMaskIntoConstraints:YES];
            [topBtn setTag:row];
            //[operate setAction:@selector(onSetGestureData:)];
            if (row < topCount ) {
                [topBtn setTitle:@"-"];
                [topBtn setToolTip:NSLocalizedString(@"remove top", nil)];
                [topBtn setAction:@selector(removeTop:)];
            }else{
                [topBtn setTitle:@"↑"];
                [topBtn setToolTip:NSLocalizedString(@"top", nil)];
                [topBtn setAction:@selector(addTop:)];
            }
            //[textField addSubview:topBtn];
            result = topBtn;
        }
    } @catch (NSException *exception) {
        NSLog(@"tableView exception:%@",exception);
    }
    return result;
}


- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return [_dataArray count];
}

- (void)refreshView:(id)view didChangeState:(DMRefreshTableViewState)state{
    
    NSLog(@"state:%u",state);
    
}

- (void)refreshViewDidLoading:(id)view{
    
} // only footer

- (void) setTableViewIsScrollAnimated:(BOOL)isAnimated
                              endRect:(CGRect)endRect{
    
}

- (void)awakeFromNib {
    [_tableOutlet setTarget:self];
    [_tableOutlet setDoubleAction:@selector(doubleClick:)];
    [_tableOutlet awakeFromNib];
    self.state = DMRefreshTableViewStateDefault;
#ifdef DEBUG
    NSLog(@"self.state : %d",self.state);
#endif
    if(!isAddObserverNotify) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(prepareForNewDisplay:) name:NSViewBoundsDidChangeNotification object:[[_tableOutlet enclosingScrollView] contentView]];
        isAddObserverNotify = YES;
    }
    
}

- (IBAction)clearAll:(id)sender {
    
    NSAlert *alert = [[NSAlert alloc] init];
    NSString *title1 =NSLocalizedString(@"Ok", nil);
    NSString *title2 =NSLocalizedString(@"Cancel", nil);
    NSString *messagetext =NSLocalizedString(@"warning!", nil);
    NSString *informativetext =NSLocalizedString(@"Are you sure to clear all top records and history clipboard records?", nil);
    [alert addButtonWithTitle:title1];
    [alert addButtonWithTitle:title2];
    
    [alert setMessageText:messagetext];
    [alert setInformativeText:informativetext];
    [alert setAlertStyle:NSAlertStyleInformational];
    
    [[[alert window] contentView] autoresizesSubviews];
    
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSInteger result) {
        
        if (result == NSAlertFirstButtonReturn) {
            [self->historyClipboard clearAll];
            [self windowDidLoad];
        }
        
        if (result == NSAlertSecondButtonReturn) {
#ifdef DEBUG
            NSLog(@"Cancel");
#endif
            
        }
    }];
    
    
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
    NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:s options:0];
    NSString *decodedString = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
    [_dataArray removeObjectAtIndex:row];
    
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];  //必须清空，否则setString会失败。
    [pasteboard setString:decodedString forType:NSStringPboardType];
    [self.window close];
}
- (IBAction)clearHistoryList:(id)sender {
    
    NSAlert *alert = [[NSAlert alloc] init];
    NSString *title1 =NSLocalizedString(@"Ok", nil);
    NSString *title2 =NSLocalizedString(@"Cancel", nil);
    NSString *messagetext =NSLocalizedString(@"warning!", nil);
    NSString *informativetext =NSLocalizedString(@"Are you sure to clear all history clipboard records?", nil);
    [alert addButtonWithTitle:title1];
    [alert addButtonWithTitle:title2];
    
    [alert setMessageText:messagetext];
    [alert setInformativeText:informativetext];
    [alert setAlertStyle:NSAlertStyleInformational];
    
    [[[alert window] contentView] autoresizesSubviews];
    
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSInteger result) {
        
        if (result == NSAlertFirstButtonReturn) {
            [self->historyClipboard clearHistoryList];
            [self windowDidLoad];
            
        }
        
        if (result == NSAlertSecondButtonReturn) {
#ifdef DEBUG
            NSLog(@"Cancel");
#endif
            
        }
    }];
    
}

- (IBAction)clearAllTop:(id)sender{
    
    NSAlert *alert = [[NSAlert alloc] init];
    NSString *title1 =NSLocalizedString(@"Ok", nil);
    NSString *title2 =NSLocalizedString(@"Cancel", nil);
    NSString *messagetext =NSLocalizedString(@"warning!", nil);
    NSString *informativetext =NSLocalizedString(@"Are you sure to clear all top records?", nil);
    [alert addButtonWithTitle:title1];
    [alert addButtonWithTitle:title2];
    
    [alert setMessageText:messagetext];
    [alert setInformativeText:informativetext];
    [alert setAlertStyle:NSAlertStyleInformational];
    
    [[[alert window] contentView] autoresizesSubviews];
    
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSInteger result) {
        
        if (result == NSAlertFirstButtonReturn) {
            [self->historyClipboard clearTop];
            [self windowDidLoad];
        }
        
        if (result == NSAlertSecondButtonReturn) {
#ifdef DEBUG
            NSLog(@"Cancel");
#endif
            
        }
    }];
}

- (void)keyDown:(NSEvent*)event {
#ifdef DEBUG
    NSLog(@"%@ %@ - %@", self.className, NSStringFromSelector(_cmd), event);
#endif
    [self interpretKeyEvents:[NSArray arrayWithObject:event]];
}
- (void)cancelOperation:(id)sender {
#ifdef DEBUG
    NSLog(@"%@ %@ - %@", self.className, NSStringFromSelector(_cmd), sender);
#endif
    [self close];
}

- (IBAction)addTop:(id)sender {
    NSButton * btn = (NSButton *)sender;
    NSInteger row = [btn tag];
    if (row < 0) {
        return;
    }
    NSString *s = _dataArray[row][@"content"];
    NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:s options:0];
    NSString *decodedString = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
    [historyClipboard addTop:decodedString];
    
#ifdef DEBUG
    NSLog(@"addTop content:%@",s);
#endif
    
#ifdef DEBUG
    NSLog(@"item to add:%@ ,_topArray :%@",item, _topArray);
#endif
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
#ifdef DEBUG
    NSLog(@"_topArray :%@",_topArray);
#endif
    [historyClipboard removeTop:row];
    [self windowDidLoad];
}
- (void) prepareForNewDisplay:(NSNotification *)notificaition{
    
    if(isperformSelector) {
        /** 触发则取消之前的函数委托*/
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(stopScrollAnimated) object:nil];
        isperformSelector = NO;
    }
    
    if(!isScrollAnimated) {
        isScrollAnimated = YES;
        if ([self.refreshDelegate respondsToSelector:@selector(setTableViewIsScrollAnimated:endRect:)]) {
            [self.refreshDelegate setTableViewIsScrollAnimated:isScrollAnimated endRect:NSZeroRect];
        }
    }
    
    NSClipView *clipView = [notificaition object];
#ifdef DEBUG
    NSLog(@"DMRefreshTableView \n\n%f - %f\n%f - %f\n\n",clipView.documentRect.origin.y,clipView.documentRect.size.height,clipView.documentVisibleRect.origin.y,clipView.documentVisibleRect.size.height);
#endif
    // 如果第一次进来数据很少也会触发
    if (clipView.documentRect.size.height <= clipView.documentVisibleRect.size.height) {
        return;
    }
    
    float originSizeAndOffSize = clipView.documentVisibleRect.origin.y + clipView.documentVisibleRect.size.height;
    
    if  (originSizeAndOffSize >= clipView.documentRect.size.height ) {
        if (self.state == DMRefreshTableViewStateDefault) {
            self.state = DMRefreshTableViewStateTriggered;
        }else if(self.state == DMRefreshTableViewStateTriggered ){
            if (self.state != DMRefreshTableViewStateLoading) {
                self.state = DMRefreshTableViewStateLoading;
            }
        }
        
    } else if (originSizeAndOffSize < clipView.documentRect.size.height && self.state != DMRefreshTableViewStateDefault && self.state == DMRefreshTableViewStateLoading){
        self.state = DMRefreshTableViewStateDefault;
    }
    
    if(!isperformSelector) {
        lastRect = clipView.documentVisibleRect;
        /** 0.5s 后执行滑动停止*/
        [self performSelector:@selector(stopScrollAnimated) withObject:nil afterDelay:0.5f];
        isperformSelector = YES;
    }
    
}


- (void)setState:(DMRefreshTableViewState)state
{
    
#ifdef DEBUG
    NSLog(@"setState : %d",self.state);
#endif
    if (_isLastPage) {
        return;
    }
    
    _state = state;
    
    switch (state) {
        case DMRefreshTableViewStateDefault:
        {
#ifdef DEBUG
            NSLog(@"DMRefreshTableViewStateDefault : %d",self.state);
#endif
            
            break;
        }
        case DMRefreshTableViewStateTriggered:
        {
            
#ifdef DEBUG
            NSLog(@"DMRefreshTableViewStateTriggered : %d",self.state);
#endif
            
            _dataArray = [historyClipboard getHistoryClipboardList:NO];
            [_tableOutlet reloadData];
            
            [self setState:DMRefreshTableViewStateLoading];
            break;
        }
        case DMRefreshTableViewStateLoading:
        {
#ifdef DEBUG
            NSLog(@"DMRefreshTableViewStateLoading : %d",self.state);
#endif
            if ([self.refreshDelegate respondsToSelector:@selector(refreshViewDidLoading:)]) {
                //[self.refreshDelegate refreshViewDidLoading:weakSelf];
            }
            
            break;
        }
    }
}



- (void)finishedLoading
{
    [self setState:DMRefreshTableViewStateDefault];
}


- (void) stopScrollAnimated {
    isperformSelector = isScrollAnimated = NO;
    if ([self.refreshDelegate respondsToSelector:@selector(setTableViewIsScrollAnimated:endRect:)]) {
        [self.refreshDelegate setTableViewIsScrollAnimated:isScrollAnimated endRect:lastRect];
    }
}

@end
