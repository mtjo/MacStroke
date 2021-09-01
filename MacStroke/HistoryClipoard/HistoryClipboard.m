//
//  HistoryClipboard.m
//  MacStroke
//
//  Created by MTJO on 2020/8/17.
//  Copyright © 2020 Chivalry Software. All rights reserved.
//

#import "HistoryClipboard.h"
#import "LSQLiteDB.h"

@implementation HistoryClipboard
static NSTimer *timer = nil;
static long changeCount;
static NSMutableArray<NSMutableDictionary *> *historyList = nil;
static NSMutableArray<NSMutableDictionary *> *topList = nil;
static long maxListCount = 0;
static long maxTopCount = 0;
NSUserDefaults *sharedDefaults;
static  bool enable = false;
static  bool STROAGE_LOCAL = false;
static NSString *CLIPOARD_STROAGE_LOCAL = @"clipoardStroageLocal";
static NSString *HISTORY_CLIPOARD_TABLES = @"local_history_clipoard";
static NSString *ENABLE_LIMIT_TOP = @"enableLimitTop";
static NSString *LIMIT_TOP = @"limitTop";

static NSString *ENABLE_LIMIT_SAVE_DAYS = @"enableLimitSaveDays";
static NSString *LIMIT_SAVE_DAYS = @"limitSaveDays";

static NSString *ENABLE_LIMIT_TOTAL = @"enableLimitTotal";
static NSString *LIMIT_TOTAL = @"limitTotal";


NSString *createTable  = @"create table if not exists local_history_clipoard ( id integer PRIMARY KEY AUTOINCREMENT, content text, is_top intger, create_time DATE, modify_time DATE )";
static LSQLiteDB *sqlite= nil;
int page = 0;


- (void) handleTimer: (NSTimer *) timer
{
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    if (changeCount < [pasteboard changeCount]) {
#ifdef DEBUG
        NSLog(@"changeCount:%ld", (long)[pasteboard changeCount]);
#endif
        
        NSArray *types = [pasteboard types];
        if ([types containsObject:NSPasteboardTypeString]) {
            NSString *s = [pasteboard stringForType:NSPasteboardTypeString];
            NSMutableDictionary *item = [[NSMutableDictionary alloc] init];
            
            item = [self insertlocalHistoryClipoard:s isTop:0];
#ifdef DEBUG
            NSLog(@"item :%@",item);
#endif
            
            [historyList insertObject:item atIndex:0];
            
            if (STROAGE_LOCAL) {
                maxListCount = [sharedDefaults integerForKey:LIMIT_TOTAL];
                if ([sharedDefaults boolForKey:ENABLE_LIMIT_TOTAL] && maxListCount>0) {
                    if ([self getCount:NO] > maxListCount) {
                        [historyList removeLastObject];
                        [self deleteEarliestItem:NO];
                    }
                    
                }
            }
            
#ifdef DEBUG
            NSLog(@"CLIPOARD_STROAGE_LOCAL:%hdd", [[NSUserDefaults standardUserDefaults] boolForKey:CLIPOARD_STROAGE_LOCAL]);
#endif
            
        }
        changeCount = [pasteboard changeCount];
    }
}

- (void) enableHistoryClipboard
{
    sharedDefaults = [NSUserDefaults standardUserDefaults];
    bool enableHistoryClipboard =  [sharedDefaults boolForKey:@"enableHistoryClipboard"];
    STROAGE_LOCAL =[[NSUserDefaults standardUserDefaults] boolForKey:CLIPOARD_STROAGE_LOCAL];
    topList = [self getTopList];
    if (sqlite == nil){
        sqlite = [LSQLiteDB new];
    }
#ifdef DEBUG
    NSLog(@"tableIsExists:%hhd",[sqlite tableIsExists:HISTORY_CLIPOARD_TABLES]);
#endif
    if (![sqlite tableIsExists:HISTORY_CLIPOARD_TABLES]) {
        [sqlite execBySQL:createTable];
    }
    
#ifdef DEBUG
    NSLog(@"enableHistoryClipboard:%hdd", enableHistoryClipboard);
#endif
    
    if (enableHistoryClipboard) {
        enable = true;
        if (timer != nil) {
            [timer invalidate];
        }
        if (topList == nil) {
            topList = [[NSMutableArray alloc] init];
        }
        if (historyList == nil) {
            historyList = [[NSMutableArray alloc] init];
        }
        if(STROAGE_LOCAL){
            @try {
                maxTopCount =  [sharedDefaults integerForKey:LIMIT_TOP];
                topList = [self selectLocalHistoryClipoardIsTop:YES start:0 end: maxTopCount>0&& [sharedDefaults integerForKey:ENABLE_LIMIT_TOP]?maxTopCount:1000];
                historyList = [self selectLocalHistoryClipoardIsTop:NO start:page end:pageSize];
                
                // delete expired item
                [self deleteExpired];
            } @catch (NSException *exception) {
                NSLog(@"LOCAL_HISTORY_CLIPOARD_LIST exception:%@", exception);
            }
#ifdef DEBUG
            NSLog(@"LOCAL_HISTORY_CLIPOARD_LIST:%@", historyList);
#endif
            
            
        }
        timer = [NSTimer scheduledTimerWithTimeInterval: 0.5
                                                 target: self
                                               selector: @selector(handleTimer:)
                                               userInfo: nil
                                                repeats: YES];
    }else{
        maxListCount = 0;
        enable = false;
        [timer invalidate];
    }
}

- (NSMutableArray<NSMutableDictionary*> *) getHistoryClipboardList:(bool)firstPage{
    NSMutableArray<NSMutableDictionary*> * list = [[NSMutableArray alloc] init];
    if(STROAGE_LOCAL){
        topList = [self getTopList];
        if (firstPage) {
            page = 0;
            historyList = [self selectLocalHistoryClipoardIsTop:NO start:page end:pageSize];
        }else{
            [self nextPage];
        }
    }
    [list addObjectsFromArray:topList];
    [list addObjectsFromArray:historyList];
    return list;
}


- (NSMutableArray *) getTopList {
    NSMutableArray *toplist =[[NSMutableArray alloc] init];
    @try {
        toplist =  [self selectLocalHistoryClipoardIsTop:YES start:0 end:1000];
        //        NSLog(@"toplist2: %@", toplist2);
        //        NSData *data  =   [sharedDefaults objectForKey:LOCAL_TOP_HISTORY_CLIPOARD_LIST];
        //        toplist = [[NSMutableArray alloc] initWithArray:[NSKeyedUnarchiver unarchiveObjectWithData:data]];
        
    } @catch (NSException *exception) {
        NSLog(@"LOCAL_TOP_HISTORY_CLIPOARD_LIST exception: %@", exception);
    }
    
#ifdef DEBUG
    NSLog(@"topList:%@", toplist);
#endif
    topList = toplist;
    return toplist;
}
-(BOOL) clearHistoryList{
    [historyList removeAllObjects];
    NSString *sql= [NSString stringWithFormat:@"DELETE FROM %@ where is_top = 0;",HISTORY_CLIPOARD_TABLES];
#ifdef DEBUG
    NSLog(@"clearHistoryList: %@", sql);
#endif
    return [sqlite execBySQL:sql];
}

-(void) clearTop{
    [topList removeAllObjects];
    NSString *sql= [NSString stringWithFormat:@"DELETE FROM '%@' where is_top = 1;",HISTORY_CLIPOARD_TABLES];
#ifdef DEBUG
    NSLog(@"clearTop: %@", sql);
#endif
    if (STROAGE_LOCAL) {
        [sqlite execBySQL:sql];
    }
}

-(void) clearAll{
    [historyList removeAllObjects];
    [topList removeAllObjects];
    NSString *sql= [NSString stringWithFormat:@"DELETE FROM '%@';",HISTORY_CLIPOARD_TABLES];
    
#ifdef DEBUG
    NSLog(@"clearAll sql: %@", sql);
#endif
    
    if ([sqlite execBySQL:sql]) {
        NSString *sql2= [NSString stringWithFormat:@"DELETE FROM sqlite_sequence WHERE name = '%@';",HISTORY_CLIPOARD_TABLES];
#ifdef DEBUG
        NSLog(@"clearAll sql2: %@", sql);
#endif
        if (STROAGE_LOCAL) {
            [sqlite execBySQL:sql2];
        }
    }
}

-(BOOL) isEnable{
    return enable;
}

//-(NSString *) localHistoryFilePath {
//
//    //NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
//    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
//
//    NSString *fileName = [LOCAL_HISTORY_CLIPOARD_LIST stringByAppendingString:@".plist"];
//    NSString *documentsDirectory = [paths lastObject];
//
//    NSFileManager* fm=[NSFileManager defaultManager];
//
//    NSString *dic = [documentsDirectory stringByAppendingPathComponent:@"MacStroke"];
//
//    if(![fm fileExistsAtPath:dic]){
//        //创建目录
//        NSDictionary *attributes;
//        [attributes setValue:[NSString stringWithFormat:@"%d", 0777]
//                      forKey:@"NSFilePosixPermissions"];
//        [fm createDirectoryAtPath:dic withIntermediateDirectories:YES attributes:attributes error:nil];
//    }
//
//    return [dic stringByAppendingPathComponent:fileName];
//}
-(NSMutableArray*)  selectLocalHistoryClipoardIsTop:(BOOL)isTop start:(long)start end:(long)end {
    //    NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:base64String options:0];
    //    NSString *decodedString = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
    //    NSLog(@"decodedString: %@", decodedString);
    
    NSString *sql= [NSString stringWithFormat:@"SELECT id, content, is_top, create_time, modify_time FROM local_history_clipoard where is_top = %d order by id desc limit %ld, %ld;",isTop,start,end];
#ifdef DEBUG
    NSLog(@"selectLocalHistoryClipoardIsTop: %@", sql);
#endif
    return [sqlite queryBySQL:sql];
}

-(NSMutableDictionary*)insertlocalHistoryClipoard:(NSString* )content isTop:(int)isTop{
    UInt64 recordTime = [[NSDate date] timeIntervalSince1970];
    //    NSString *content = [array valueForKey:CONTENT];
    NSData *encodeData = [content dataUsingEncoding:NSUTF8StringEncoding];
    NSString *base64String = [encodeData base64EncodedStringWithOptions:0];
    //    NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:base64String options:0];
    //    NSString *decodedString = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
    //    NSLog(@"decodedString: %@", decodedString);
    
    if (STROAGE_LOCAL) {
        NSString *sql= [NSString stringWithFormat:@"INSERT INTO local_history_clipoard (content, is_top, create_time, modify_time) VALUES ('%@', %d, %llu, %llu);"
                        ,base64String
                        ,isTop
                        ,recordTime
                        ,recordTime];
#ifdef DEBUG
        NSLog(@"insertlocalHistoryClipoard :%@", sql);
#endif
        if ([sqlite execBySQL:sql]) {
            NSString *sql2= @"SELECT * FROM local_history_clipoard where id = last_insert_rowid();";
#ifdef DEBUG
            NSLog(@"insertlocalHistoryClipoard2 :%@", sql2);
#endif
            return [[sqlite queryBySQL:sql2] lastObject];
        }
    }else{
        NSMutableDictionary *item = [[NSMutableDictionary alloc]init];
        [item setValue:@(isTop) forKey:ISTOP];
        [item setValue:base64String forKey:CONTENT];
        return item;
    }
    return nil;
}

-(int)delByRowID:(long) rowId{
    NSString *sql= [NSString stringWithFormat:@"DELETE FROM local_history_clipoard WHERE id = %ld;" ,rowId];
    NSLog(@"del sql:%@", sql);
    return [sqlite execBySQL:sql];
}


-(NSInteger) topCount{
    return [topList count];
}
- (bool)addTop:(NSString*)top{
    NSMutableDictionary *item = [[NSMutableDictionary alloc] init];
    item = [self insertlocalHistoryClipoard:top isTop:YES];
    [topList insertObject:item atIndex:0];
    
    //delete Expired Top
    if ([sharedDefaults boolForKey:ENABLE_LIMIT_TOP]) {
        if ( [self getCount:YES] > [sharedDefaults integerForKey:LIMIT_TOP]) {
            [self deleteEarliestItem:YES];
        }
    }
    return 1;
}
- (void)removeTop:(NSInteger) rowNum{
    NSMutableDictionary *dictionary = topList[rowNum];
    NSNumber *removeId =( NSNumber *)[dictionary valueForKey:@"id"];
#ifdef DEBUG
    NSLog(@"item: %@ , \nrowId:%ld, \nremoveId:%@",topList[topRow],topRow,removeId);
#endif
    [topList removeObjectAtIndex:rowNum];
    [self delByRowID:[removeId longValue]];
    
}

- (void) nextPage {
    page++;
    NSMutableArray<NSMutableDictionary *> *dblist = [self selectLocalHistoryClipoardIsTop:NO start:(pageSize*page) end:pageSize];
    [historyList addObjectsFromArray:dblist];
}

-(NSInteger) getCount:(BOOL)isTop{
    NSString *sql = [NSString stringWithFormat:@"SELECT count(*) as count_num FROM %@ WHERE is_top=%d;",HISTORY_CLIPOARD_TABLES,isTop];
    NSMutableArray *arr = [sqlite queryBySQL:sql];
    NSMutableDictionary *dic = [arr objectAtIndex:0];
    NSNumber *count = (NSNumber *)[dic valueForKey:@"count_num"];
    return [count integerValue];
}

-(int) deleteEarliestItem:(bool)isTop{
    NSString *sql = [NSString stringWithFormat:@"DELETE FROM %@ WHERE id IN (SELECT id from %@ WHERE is_top=%d ORDER BY id ASC LIMIT 1);",HISTORY_CLIPOARD_TABLES,HISTORY_CLIPOARD_TABLES,isTop];
    return [sqlite execBySQL: sql];
}

-(int) deleteExpiredHistory:(int)days{
    UInt64 recordTime = [[NSDate date] timeIntervalSince1970] - days*24*60*60;
    NSString *sql = [NSString stringWithFormat:@"DELETE FROM %@ WHERE id IN (SELECT id FROM %@ WHERE is_top=0 AND create_time < %llu order by id desc);",HISTORY_CLIPOARD_TABLES,HISTORY_CLIPOARD_TABLES,recordTime];
    return [sqlite execBySQL: sql];
}

-(void)deleteExpired{
    //delete Expired Top
    @try {
        long limitTop = [sharedDefaults integerForKey:LIMIT_TOP];
        if ([sharedDefaults boolForKey:ENABLE_LIMIT_TOP] && limitTop>0) {
            long jj =[self getCount:YES] - limitTop;
            if (jj > 0) {
                for (long j=0; j<jj; j++) {
                    [self deleteEarliestItem:YES];
                }
            }
        }
        if(STROAGE_LOCAL){
            long limitTotal = [sharedDefaults integerForKey:LIMIT_TOTAL];
            if ([sharedDefaults boolForKey:ENABLE_LIMIT_TOTAL] && limitTotal>0) {
                long ii =[self getCount:NO]-limitTotal;
                if (ii > 0) {
                    for (long i=0; i<ii; i++) {
                        [self deleteEarliestItem:NO];
                    }
                }
            }
            if ([sharedDefaults boolForKey:ENABLE_LIMIT_SAVE_DAYS]) {
                NSInteger day = [sharedDefaults integerForKey:LIMIT_SAVE_DAYS];
                [self deleteExpiredHistory:(int)day];
            }
        }
    } @catch (NSException *exception) {
        NSLog(@"deleteExpired: %@",exception);
    }
    
}

@end
