//
//  RightClicksList.h
//  MacStroke
//
//  Created by MTJO on 2019/7/2.
//  Copyright © 2019 Chivalry Software. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface RightClicksList : NSObject
+ (RightClicksList *)sharedRightClicksList;

- (void)reInit;

- (void)clear;

- (void)save;

- (NSData *)nsData;

- (NSInteger)count;

- (NSString *)appnameAtIndex:(NSUInteger)index;

- (void)addRightClicks:(NSString *)appname;

- (void)removeAtIndex:(NSInteger)index;

- (void)setAppnameAtIndex:(NSUInteger)atIndex appname:(NSString *)appname;

- (BOOL)needRightClickByAppname:(NSString *)appname;

@end

