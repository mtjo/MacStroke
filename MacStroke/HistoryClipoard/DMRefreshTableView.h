//
//  DMRefreshTableView.h
//  MacStroke
//
//  Created by MTJO on 2021/8/26.
//  Copyright © 2021 Chivalry Software. All rights reserved.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

typedef enum {
    DMRefreshTableViewStateDefault = 1,    //默认
    DMRefreshTableViewStateTriggered,      //已经可以出发刷新委托事件
    DMRefreshTableViewStateLoading         //正在加载
} DMRefreshTableViewState;
 
@protocol DMRefreshTableViewDelegate <NSObject>
@optional
 
- (void)refreshView:(id)view didChangeState:(DMRefreshTableViewState)state;
 
- (void)refreshViewDidLoading:(id)view; // only footer
 
- (void) setTableViewIsScrollAnimated:(BOOL)isAnimated
                              endRect:(CGRect)endRect;
@end


@interface DMRefreshTableView : NSTableView

@property (nonatomic, assign) DMRefreshTableViewState state;
@property (nonatomic, weak) id<DMRefreshTableViewDelegate> refreshDelegate;
 
- (void)finishedLoading;
 
@property (nonatomic, assign) BOOL isLastPage;

@end

NS_ASSUME_NONNULL_END
