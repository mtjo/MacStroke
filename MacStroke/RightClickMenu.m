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
