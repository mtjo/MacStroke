//
//  RightClickMenu.m
//  MacStroke
//
//  Created by MTJO on 2019/12/25.
//  Copyright © 2019 Chivalry Software. All rights reserved.
//

#import "RightClickMenu.h"

@implementation RightClickMenu

- (void) tick
{
    NSLog(@"tick call");
    NSDistributedNotificationCenter* center = [NSDistributedNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(rootPathRequested:)
                   name:@"RequestObservingPathNotification" object:nil];
    
    [center addObserver:self selector:@selector(customMessageReceivedFromFinder:)
                   name:@"CustomMessageReceivedNotification" object:nil];
    
    //_timer = [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    
    if (self.queuedUpdates.count == 0)
    {
        return;
    }
    
    id data = @{ @"paths": self.queuedUpdates };
    [self send:@"FilesStatusUpdatedNotification" data:data];
    [self.queuedUpdates removeAllObjects];
}

- (void) send:(NSString*)name data:(id)data
{
    NSLog(@"Sending %@ data: %@", name, data);
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
    NSLog(@"rootPathRequested: %@", notif);
    [self send:@"ObservingPathSetNotification" data:@{ @"path": @"/" }];
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
    //system("open -F -a Terminal ~/docker");
    NSLog(@"data: %@",data);
    NSLog(@"operation: %@",operation);
    if ([operation isEqualToString:@"newFile"]) {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        
        NSLog(@"isWritableFileAtPath: %hhd",  [fileManager isWritableFileAtPath:data[@"path"]]);
        if (![fileManager isWritableFileAtPath:data[@"path"]]) {
            NSAlert *alert = [[NSAlert alloc] init];
            [alert setAlertStyle:NSInformationalAlertStyle];
            NSString *msg =  NSLocalizedString(@"The current directory: %s does not have write permission!", nil);
            msg = [msg stringByReplacingOccurrencesOfString:@"%s" withString:data[@"path"]];
            [alert setMessageText:msg];
            
            [alert runModal];
            return;
        }
        
        NSString *filepath =  [data[@"path"] stringByAppendingString:NSLocalizedString(@"/newTextFile",nil)];
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
        }else {
            NSLog(@"文件创建失败");
        }

    } else if ([operation isEqualToString:@"openInTerminal"]){
        NSString *cmd = [@"open -a Terminal " stringByAppendingString: data[@"path"]];
        system([cmd UTF8String]);
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


@end
