//
// Created by Marko Cicak on 7/31/18.
// Copyright (c) 2018 codecentric AG. All rights reserved.
//

#import <Foundation/Foundation.h>

@class FinderSync;


@interface FinderCommChannel : NSObject

@property(nonatomic, weak) FinderSync* finderSync;

- (void) setup;

- (void) send:(NSString*)name data:(NSDictionary*)data;

@end
