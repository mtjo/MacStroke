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
static bool limitHistoryListCount = false;
NSUserDefaults *sharedDefaults;
static  bool enable = false;
static NSString *HISTORY_CLIPOARD_LIST=@"historyClipoardList";
static NSString *LOCAL_HISTORY_CLIPOARD_LIST = @"localHistoryClipoardList";
static NSString *LOCAL_TOP_HISTORY_CLIPOARD_LIST = @"localTopHistoryClipoardList";
static NSString *CLIPOARD_STROAGE_LOCAL = @"clipoardStroageLocal";
static NSString *HISTORY_CLIPOARD_TABLES = @"local_history_clipoard";
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
            
            if([sharedDefaults boolForKey:CLIPOARD_STROAGE_LOCAL]){
                item = [self insertlocalHistoryClipoard:s isTop:0];
            }
            
            [historyList insertObject:item atIndex:0];
            maxListCount = [sharedDefaults integerForKey:HISTORY_CLIPOARD_LIST];
            if (maxListCount > 0 && limitHistoryListCount) {
                if ([historyList count] >maxListCount) {
                    for (long i=maxListCount-1; i<[historyList count]; i++) {
                        [historyList removeObjectAtIndex:i];
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
    topList = [self getTopList];
    sqlite = [LSQLiteDB new];
    if (![sqlite tableIsExists:HISTORY_CLIPOARD_TABLES]) {
        [sqlite execBySQL:createTable];
    }
    
#ifdef DEBUG
    NSLog(@"enableHistoryClipboard:%hdd", enableHistoryClipboard);
#endif
    
    if (enableHistoryClipboard) {
        limitHistoryListCount =  [sharedDefaults boolForKey:@"limitHistoryListCount"];
        
        enable = true;
        if (timer != nil) {
            [timer invalidate];
        }
        if (historyList == nil) {
            historyList = [[NSMutableArray alloc] init];
        }
        if([[NSUserDefaults standardUserDefaults] boolForKey:CLIPOARD_STROAGE_LOCAL]){
            @try {
                topList = [self selectLocalHistoryClipoardIsTop:YES start:0 end: 200];
                historyList = [self selectLocalHistoryClipoardIsTop:NO start:page end:pageSize];
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
    topList = [self getTopList];
    if (firstPage) {
        page = 0;
        historyList = [self selectLocalHistoryClipoardIsTop:NO start:page end:pageSize];
    }else{
        [self nextPage];
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

-(BOOL) clearTop{
    [topList removeAllObjects];
    NSString *sql= [NSString stringWithFormat:@"DELETE FROM '%@' where is_top = 1;",HISTORY_CLIPOARD_TABLES];
#ifdef DEBUG
    NSLog(@"clearTop: %@", sql);
#endif
    return [sqlite execBySQL:sql];
}

-(BOOL) clearAll{
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
        return [sqlite execBySQL:sql2];
    }
    return 0;
}



-(BOOL) isEnable{
    return enable;
}

-(NSString *) localHistoryFilePath {
    
    //NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    
    NSString *fileName = [LOCAL_HISTORY_CLIPOARD_LIST stringByAppendingString:@".plist"];
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
    
    return [dic stringByAppendingPathComponent:fileName];
}
-(NSMutableArray*)  selectLocalHistoryClipoardIsTop:(BOOL)isTop start:(int)start end:(int)end {
    //    NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:base64String options:0];
    //    NSString *decodedString = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
    //    NSLog(@"decodedString: %@", decodedString);
    
    NSString *sql= [NSString stringWithFormat:@"SELECT id, content, is_top, create_time, modify_time FROM local_history_clipoard where is_top = %d order by modify_time desc limit %d, %d;",isTop,start,end];
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
    return 1;
}
- (bool)removeTop:(NSInteger) topRow{
    NSMutableDictionary *dictionary = topList[topRow];
    NSNumber *removeId =( NSNumber *)[dictionary valueForKey:@"id"];
    
    NSLog(@"item: %@ , \nrowId:%ld, \nremoveId:%@",topList[topRow],topRow,removeId);
    
    [topList removeObjectAtIndex:topRow];
    return [self delByRowID:[removeId longValue] ];
}

- (void) nextPage {
    page++;
    NSMutableArray<NSMutableDictionary *> *dblist = [self selectLocalHistoryClipoardIsTop:NO start:(pageSize*page) end:pageSize];
    [historyList addObjectsFromArray:dblist];
}

- (void) setPage:(int)pageNum {
    page = pageNum;
}


@end
