//
//  RightClickMenu.m
//  MacStroke
//
//  Created by MTJO on 2019/12/25.
//  Copyright © 2019 Chivalry Software. All rights reserved.
//

#import "RightClickMenu.h"

@implementation RightClickMenu

- (void) initFinderSyncExtension
{
    NSDistributedNotificationCenter* center = [NSDistributedNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(rootPathRequested:)
                   name:@"RequestObservingPathNotification" object:nil];
    [center addObserver:self selector:@selector(customMessageReceivedFromFinder:)
                   name:@"CustomMessageReceivedNotification" object:nil];
    [self syncSharedDefaultsToFinderSyncExtension];
    if (self.queuedUpdates.count == 0)
    {
        return;
    }
    [self syncSharedDefaultsToFinderSyncExtension];
    id data = @{ @"paths": self.queuedUpdates };
    [self send:@"FilesStatusUpdatedNotification" data:data];
    [self.queuedUpdates removeAllObjects];
}

- (void) send:(NSString*)name data:(id)data
{
#ifdef DEBUG
    NSLog(@"Sending %@ data: %@", name, data);
#endif
    NSDistributedNotificationCenter* center = [NSDistributedNotificationCenter defaultCenter];
    [center postNotificationName:name
                          object:NSBundle.mainBundle.bundleIdentifier
                        userInfo:data
              deliverImmediately:YES];
}

- (void) updatePath:(NSString*)path withStatus:(NSNumber*)status
{
    self.queuedUpdates[path] = status;
}

#pragma mark - Message from FinderSync extension

- (void) rootPathRequested:(NSNotification*)notif
{
    [self send:@"ObservingPathSetNotification" data:@{ @"path": @"/" }];
    [self syncSharedDefaultsToFinderSyncExtension];
    
}

- (void) syncSharedDefaultsToFinderSyncExtension
{
    NSMutableArray<NSString*> *array = [[NSMutableArray alloc] init];
    [array addObject:NSLocalizedString(@"New text file",nil)];
    [array addObject:NSLocalizedString(@"Open in Terminal",nil)];
    [array addObject:NSLocalizedString(@"Copy file path",nil)];
    NSString *items = [array componentsJoinedByString:@","];
    
    NSUserDefaults *sharedDefaults = [NSUserDefaults standardUserDefaults];
    [self send:@"SyncSharedDefaultsNotification" data:@{
        @"enableRightClickMenu":  [NSString stringWithFormat: @"%hhd",  [sharedDefaults boolForKey:@"enableRightClickMenu"]],
        @"enableNewFile": [NSString stringWithFormat: @"%hhd", [sharedDefaults boolForKey:@"newFile"]],
        @"enableOpenInTerminal":  [NSString stringWithFormat: @"%hhd", [sharedDefaults boolForKey:@"openInTerminal"]],
        @"enableCopyFilePath":  [NSString stringWithFormat: @"%hhd", [sharedDefaults boolForKey:@"copyFilePath"]],
        @"items": items
    }];
}

- (void) customMessageReceivedFromFinder:(NSNotification*)notif
{
    // data form finder is delivered through notifiaction.object (and not notification.userInfo dictionary)
    NSString* jsonString = notif.object;
    NSData* jsonData = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
    NSError* error;
    NSDictionary* data = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
    
    NSLog(@"NSNotification: %@",  [notif name]);
    
    NSString* operation = data[@"operation"];
    NSLog(@"data: %@",data);
    NSLog(@"operation: %@",operation);
    if ([operation isEqualToString:@"newFile"]) {
        [self newFile:data[@"path"]];
    } else if ([operation isEqualToString:@"openInTerminal"]){
        [self openInTerminal:[data[@"items"] length]>0?data[@"items"]:data[@"path"]];
    } else if([operation isEqualToString:@"copyFilePath"]){
        [self copyFilePath:[data[@"items"] length]>0?data[@"items"]:data[@"path"]];
    }
}

#pragma mark - Getters

- (NSMutableDictionary<NSString*, NSNumber*>*) queuedUpdates
{
    if (!_queuedUpdates)
    {
        _queuedUpdates = NSMutableDictionary.dictionary;
    }
    return _queuedUpdates;
}

- (void) newFile:(NSString*) path{
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    NSString *filepath =  [path stringByAppendingString:NSLocalizedString(@"/newTextFile",nil)];
    BOOL isDirectory = NO;
    BOOL isExist =  [fileManager fileExistsAtPath:filepath isDirectory:&isDirectory];
    long i = 1;
    while (isExist) {
        NSString *_filepath = [filepath stringByAppendingString:[NSString stringWithFormat: @"%ld", i++]];
        isExist =  [fileManager fileExistsAtPath:_filepath isDirectory:&isDirectory];
        if (!isExist) {
            filepath= _filepath;
        }
    }
    
    BOOL ret = [fileManager createFileAtPath:filepath contents:nil attributes:nil];
    if (ret) {
        NSLog(@"文件创建成功");
        return;
    }else {
        NSLog(@"文件创建失败，尝试用root创建");
        NSString *fullScript = [@"touch " stringByAppendingString:filepath];
        NSDictionary *errorInfo = [NSDictionary new];
        NSString *script =  [NSString stringWithFormat:@"do shell script \"%@\" with administrator privileges", fullScript];
        
        NSAppleScript *appleScript = [[NSAppleScript new] initWithSource:script];
        NSAppleEventDescriptor * eventResult = [appleScript executeAndReturnError:&errorInfo];
        
        // Check errorInfo
        if (! eventResult)
        {
            // do something you want
            NSAlert *alert = [[NSAlert alloc] init];
            [alert setAlertStyle:NSInformationalAlertStyle];
            NSString *msg =  NSLocalizedString(@"The current directory: %s does not have write permission!", nil);
            msg = [msg stringByReplacingOccurrencesOfString:@"%s" withString:path];
            [alert setMessageText:msg];
            
            [alert runModal];
            return;
        }else{
            return;
        }
        
    }
}
- (void) openInTerminal:(NSString*) path{
    NSString *terminal = @"open -a Terminal ";
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"useIterm"]){
        terminal =@"open -a Iterm ";
    }
    
    NSString *cmd = [terminal stringByAppendingString: path];
    system([cmd UTF8String]);
}

- (void) copyFilePath:(NSString*) path{
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];  //必须清空，否则setString会失败。
    [pasteboard setString:path forType:NSStringPboardType];
}

- (void) reEnableFinderExtension{
    [self disableFinderExtension];
    [NSTimer scheduledTimerWithTimeInterval:2
                                     target:self selector:@selector(enableFinderExtension) userInfo:nil repeats:NO];
}
-(void) enableFinderExtension{
    system("pluginkit -e use -i net.mtjo.MacStroke.FinderSyncExtension");
}
-(void) disableFinderExtension{
    system("pluginkit -e ignore -i net.mtjo.MacStroke.FinderSyncExtension");
}

-(void) delayedEnableFinderExtension{
    [NSTimer scheduledTimerWithTimeInterval:10
                                     target:self selector:@selector(enableFinderExtension) userInfo:nil repeats:NO];
    [NSTimer scheduledTimerWithTimeInterval:120
                                     target:self selector:@selector(enableFinderExtension) userInfo:nil repeats:NO];
}

@end
