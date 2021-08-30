//
//  LSQLiteDB.h
//  MacStroke
//
//  Created by MTJO on 2021/8/26.
//  Copyright © 2021 Chivalry Software. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>
#import "sqlite3.h"

NS_ASSUME_NONNULL_BEGIN

@interface LSQLiteDB : NSObject
-(void)dealloc;
-(LSQLiteDB*)init;
- (int) execBySQL: (NSString *) _sql;
-(NSMutableArray*) queryBySQL:(NSString *) sql;
-(int) tableIsExists:(NSString*) tableName;
@end

NS_ASSUME_NONNULL_END
