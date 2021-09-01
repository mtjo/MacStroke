//
//  LSQLiteDB.m
//  MacStroke
//
//  Created by MTJO on 2021/8/26.
//  Copyright © 2021 Chivalry Software. All rights reserved.
//

#import "LSQLiteDB.h"
static sqlite3 * db = nil;
#define SQLITE_OK           0   /* Successful result */
/* beginning-of-error-codes */
#define SQLITE_ERROR        1   /* SQL error or missing database */
#define SQLITE_INTERNAL     2   /* Internal logic error in SQLite */
#define SQLITE_PERM         3   /* Access permission denied */
#define SQLITE_ABORT        4   /* Callback routine requested an abort */
#define SQLITE_BUSY         5   /* The database file is locked */
#define SQLITE_LOCKED       6   /* A table in the database is locked */
#define SQLITE_NOMEM        7   /* A malloc() failed */
#define SQLITE_READONLY     8   /* Attempt to write a readonly database */
#define SQLITE_INTERRUPT    9   /* Operation terminated by sqlite3_interrupt()*/
#define SQLITE_IOERR       10   /* Some kind of disk I/O error occurred */
#define SQLITE_CORRUPT     11   /* The database disk image is malformed */
#define SQLITE_NOTFOUND    12   /* Unknown opcode in sqlite3_file_control() */
#define SQLITE_FULL        13   /* Insertion failed because database is full */
#define SQLITE_CANTOPEN    14   /* Unable to open the database file */
#define SQLITE_PROTOCOL    15   /* Database lock protocol error */
#define SQLITE_EMPTY       16   /* Database is empty */
#define SQLITE_SCHEMA      17   /* The database schema changed */
#define SQLITE_TOOBIG      18   /* String or BLOB exceeds size limit */
#define SQLITE_CONSTRAINT  19   /* Abort due to constraint violation */
#define SQLITE_MISMATCH    20   /* Data type mismatch */
#define SQLITE_MISUSE      21   /* Library used incorrectly */
#define SQLITE_NOLFS       22   /* Uses OS features not supported on host */
#define SQLITE_AUTH        23   /* Authorization denied */
#define SQLITE_FORMAT      24   /* Auxiliary database format error */
#define SQLITE_RANGE       25   /* 2nd parameter to sqlite3_bind out of range */
#define SQLITE_NOTADB      26   /* File opened that is not a database file */
#define SQLITE_NOTICE      27   /* Notifications from sqlite3_log() */
#define SQLITE_WARNING     28   /* Warnings from sqlite3_log() */
#define SQLITE_ROW         100  /* sqlite3_step() has another row ready */
#define SQLITE_DONE        101  /* sqlite3_step() has finished executing */
/* end-of-error-codes */



@implementation LSQLiteDB

-(LSQLiteDB*) init {
    /*
     directory 目录类型 比如Documents目录 就是NSDocumentDirectory
     domainMask 在iOS的程序中这个取NSUserDomainMask
     expandTilde YES，表示将~展开成完整路径
     */
    //NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths lastObject];
    NSFileManager* fm=[NSFileManager defaultManager];
    NSString *dic = [documentsDirectory stringByAppendingPathComponent:@"MacStroke"];
    if(![fm fileExistsAtPath:dic]){
        //创建目录
        NSDictionary *attributes;
        [attributes setValue:[NSString stringWithFormat:@"%d", 0777]
                      forKey:@"NSFilePosixPermissions"];
        [fm createDirectoryAtPath:dic withIntermediateDirectories:YES attributes:attributes error:nil];
    }
    
    NSString * fileName = [dic stringByAppendingPathComponent:@"database.sqlite"];
#ifdef DEBUG
    NSLog(@"%@",fileName);
#endif
    //打开数据库 如果没有打开的数据库就建立一个
    //第一个参数是数据库的路径 注意要转换为c的字符串
    if (sqlite3_open(fileName.UTF8String, &db) == SQLITE_OK) {
        //[self initTables];
#ifdef DEBUG
        NSLog(@"打开数据库成功");
#endif
    }else{
#ifdef DEBUG
        NSLog(@"打开数据库失败");
#endif
    }
    
    return self;
    
}


// 执行一条slq
- (int) execBySQL: (NSString *) _sql {
    char *errorMsg;
    if (sqlite3_exec(db, [_sql UTF8String], NULL, NULL, &errorMsg)==SQLITE_OK) {
#ifdef DEBUG
        NSLog(@"Exec Success. sql:%s",_sql);
#endif
        return YES;
    }else {
#ifdef DEBUG
        NSLog(@"Exec Failure %s",errorMsg);
#endif
        return NO;
    }
}

// 关闭数据库
-(int) closeDatabase {
    sqlite3_close(db);
    return YES;
}
-(void) dealloc{
    [self closeDatabase];
}

-(NSMutableArray*) queryBySQL:(NSString *) sql
{
    NSMutableArray *result = [[NSMutableArray alloc]init];
    sqlite3_stmt *stmt;
    if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &stmt, nil) == SQLITE_OK) {
        //        int num_cols = sqlite3_data_count(stmt);
        while (sqlite3_step(stmt)==SQLITE_ROW) {
            int num_cols = sqlite3_column_count(stmt);
            NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithCapacity:num_cols];
            if (num_cols > 0) {
                int i;
                for (i = 0; i < num_cols; i++) {
                    const char *col_name = sqlite3_column_name(stmt, i);
                    if (col_name) {
                        NSString *colName = [NSString stringWithUTF8String:col_name];
                        id value = nil;
                        // fetch according to type
                        switch (sqlite3_column_type(stmt, i)) {
                            case SQLITE_INTEGER: {
                                int i_value = sqlite3_column_int(stmt, i);
                                value = [NSNumber numberWithInt:i_value];
                                break;
                            }
                            case SQLITE_FLOAT: {
                                double d_value = sqlite3_column_double(stmt, i);
                                value = [NSNumber numberWithDouble:d_value];
                                break;
                            }
                            case SQLITE_TEXT: {
                                char *c_value = (char *)sqlite3_column_text(stmt, i);
                                value = [[NSString alloc] initWithUTF8String:c_value];
                                break;
                            }
                            case SQLITE_BLOB: {
                                //const void * pFileContent = sqlite3_column_blob(stmt,i);
                                NSData *thumbnailData = [[NSData alloc] initWithBytes:sqlite3_column_blob(stmt,i) length:sqlite3_column_bytes(stmt,i)];
                                value = thumbnailData;
                                break;
                            }
                        }
                        // save to dict
                        if (value) {
                            [dict setObject:value forKey:colName];
                        }
                    }
                }
            }
            [result addObject:dict];
        }
        /*
         while (sqlite3_step(stmt)==SQLITE_ROW) {
         char *name = (char *)sqlite3_column_text(stmt, 1);
         NSString *nameString = [[NSString alloc] initWithUTF8String:name];
         NSLog(@"%@", nameString);
         }*/
        sqlite3_finalize(stmt);
    }
    return result;
}
// 判断表是否存在
-(BOOL) tableIsExists:(NSString*) tableName
{
    NSString *sql = [NSString stringWithFormat:@"SELECT count(*) as count_num FROM sqlite_master WHERE type='table' AND name = '%@';", tableName ];
    NSMutableArray *arr = [self queryBySQL: sql];
    NSMutableDictionary *dic = [arr objectAtIndex:0];
    NSNumber *count = (NSNumber*)[dic valueForKey:@"count_num"];
    return [count intValue]>0;
}
@end
