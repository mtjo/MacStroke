//
//  RightClicksList.m
//  MacStroke
//
//  Created by MTJO on 2019/7/2.
//  Copyright © 2019 Chivalry Software. All rights reserved.
//

#import "RightClicksList.h"

@implementation RightClicksList
NSMutableArray<NSString *> *_rightClicksList;  // private
+ (RightClicksList *)sharedRightClicksList {
    static dispatch_once_t pred;
    static RightClicksList *sharedInstance = nil;
    dispatch_once(&pred, ^{
        sharedInstance = [[super alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSData *data;
        NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
        data = [userDefaults objectForKey:@"rightClicksList"];
        _rightClicksList = [[NSMutableArray alloc] initWithArray:[NSKeyedUnarchiver unarchiveObjectWithData:data]];
    }
    
    if (_rightClicksList == nil) {
        _rightClicksList = [[NSMutableArray alloc] init];
    }
    
    return self;
}


- (void)reInit {
    [_rightClicksList removeAllObjects];
    [_rightClicksList addObject:@"com.jetbrains.*"];
    [self save];
}

- (void)clear {
    [_rightClicksList removeAllObjects];
    [self save];
}

- (void)save {
    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
    [userDefaults setObject:self.nsData forKey:@"rightClicksList"];
    [userDefaults synchronize];
}

- (NSData *)nsData {
    return [NSKeyedArchiver archivedDataWithRootObject:_rightClicksList];
}
- (NSInteger)count {
    return [_rightClicksList count];
}

- (NSString *)appnameAtIndex:(NSUInteger)index {
    return [_rightClicksList objectAtIndex:index];
}

- (void)addRightClicks:(NSString *)appname{
    [_rightClicksList addObject:appname];
    
}
- (void)removeAtIndex:(NSInteger)index {
    [_rightClicksList removeObjectAtIndex:index];
}
- (void)setAppnameAtIndex:(NSUInteger)index appname:(NSString *)appname{
    [_rightClicksList setObject:appname atIndexedSubscript:index];
    [self save];
}

- (BOOL)needRightClickByAppname:(NSString *)appname{
    if ([self count]>0) {
        if ([_rightClicksList containsObject:appname]) {
            return YES;
        }
        for(id obj in _rightClicksList){
            if ([appname hasPrefix:[obj substringToIndex:([obj length]-1)]]) {
                return YES;
            };
        }
    }
    return NO;
}

@end
