//
//  DMRefreshTableView.m
//  MacStroke
//
//  Created by MTJO on 2021/8/26.
//  Copyright © 2021 Chivalry Software. All rights reserved.
//

#import "DMRefreshTableView.h"

@interface DMRefreshTableView () {
    BOOL isScrollAnimated;
    BOOL isperformSelector;
    NSRect lastRect;
    BOOL isAddObserverNotify;
}
@end


@implementation DMRefreshTableView
@synthesize state = _state;

-(void)dealloc{
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSViewBoundsDidChangeNotification object:nil];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    // Drawing code here.
}
-(void)awakeFromNib{
    
    self.state = DMRefreshTableViewStateDefault;
    NSLog(@"self.state : %d",self.state);

    if(!isAddObserverNotify) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(prepareForNewDisplay:) name:NSViewBoundsDidChangeNotification object:[[self enclosingScrollView] contentView]];
        isAddObserverNotify = YES;
    }
    
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
    NSLog(@"DMRefreshTableView \n\n%f - %f\n%f - %f\n\n",clipView.documentRect.origin.y,clipView.documentRect.size.height,clipView.documentVisibleRect.origin.y,clipView.documentVisibleRect.size.height);
    
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
    
    NSLog(@"self.state : %d",self.state);
    
    if(!isperformSelector) {
        lastRect = clipView.documentVisibleRect;
        /** 0.5s 后执行滑动停止*/
        [self performSelector:@selector(stopScrollAnimated) withObject:nil afterDelay:0.5f];
        isperformSelector = YES;
    }
    
    
}
 
 
//- (void)setState:(DMRefreshTableViewState)state
//{
//    _state = state;
//    if ([self.refreshDelegate respondsToSelector:@selector(refreshView:didChangeState:)]) {
//        [self.refreshDelegate refreshView:self didChangeState:self.state];
//    }
//}
 
- (void)setState:(DMRefreshTableViewState)state
{
    NSLog(@"self.state : %d",self.state);

    if (_isLastPage) {
        return;
    }
    
    _state = state;
    
    switch (state) {
        case DMRefreshTableViewStateDefault:
        {
//            self.titleLabel.stringValue =  footStr1;
            break;
        }
        case DMRefreshTableViewStateTriggered:
        {
            [self setState:DMRefreshTableViewStateLoading];
            break;
        }
        case DMRefreshTableViewStateLoading:
        {
            NSLog(@"self.state : %d",self.state);

            
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

