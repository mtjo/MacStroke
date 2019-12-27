//
// Created by Marko Cicak on 7/31/18.
// Copyright (c) 2018 codecentric AG. All rights reserved.
//

#import "FinderCommChannel.h"
#import "FinderSync.h"


@implementation FinderCommChannel

- (void) setup
{
    NSString* observedObject = self.mainAppBundleID;
    NSDistributedNotificationCenter* center = [NSDistributedNotificationCenter defaultCenter];
    
    [center addObserver:self selector:@selector(observingPathSet:)
                   name:@"ObservingPathSetNotification" object:observedObject];
    [center addObserver:self selector:@selector(filesStatusUpdated:)
                   name:@"FilesStatusUpdatedNotification" object:observedObject];
    [center addObserver:self selector:@selector(syncSharedDefaults:)
                   name:@"SyncSharedDefaultsNotification" object:observedObject];
}

- (void) send:(NSString*)name data:(NSDictionary*)data
{
    NSDistributedNotificationCenter* center = [NSDistributedNotificationCenter defaultCenter];
    NSData* jsonData = [NSJSONSerialization dataWithJSONObject:data options:0 error:nil];
    NSString* json = [NSString.alloc initWithData:jsonData encoding:NSUTF8StringEncoding];
    [center postNotificationName:name object:json userInfo:nil deliverImmediately:YES];
}

#pragma mark - Incoming notifications

- (void) observingPathSet:(NSNotification*)notif
{
    NSLog(@"observingPathSet: %@", notif.userInfo);
    NSString* path = notif.userInfo[@"path"];
    NSURL* root = [NSURL fileURLWithPath:path];
    self.finderSync.root = root;
}

- (void) filesStatusUpdated:(NSNotification*)notif
{
    NSDictionary* paths = notif.userInfo[@"paths"];
    for (NSString* path in paths.allKeys)
    {
        NSURL* url = [NSURL fileURLWithPath:path];
        NSNumber* syncStatus = paths[path];
        syncStatus = @(syncStatus.integerValue);
        self.finderSync.index[path] = syncStatus;
        NSLog(@"Setting status %@ for %@", syncStatus, path);
        [[FIFinderSyncController defaultController] setBadgeIdentifier:syncStatus.stringValue forURL:url];
    }
}

- (void) syncSharedDefaults:(NSNotification*)notif
{
    NSLog(@"NSNotification: %@",  [notif name]);
    NSDictionary *data = notif.userInfo;
    NSLog(@"syncSharedDefaults data: %@", data);
    
    NSUserDefaults *sharedDefaults = [NSUserDefaults standardUserDefaults];
    
    NSLog(@"enable: %@",data[@"enableNewFile"] );
    NSLog(@"enableRightClickMenu: %@",data[@"enableRightClickMenu"] );
    
    [sharedDefaults setBool:[data[@"enableRightClickMenu"] intValue]  forKey:@"enableRightClickMenu"];
    [sharedDefaults setBool:[data[@"enableNewFile"] intValue]  forKey:@"enableNewFile"];
    [sharedDefaults setBool:[data[@"enableOpenInTerminal"] intValue]  forKey:@"enableOpenInTerminal"];
    [sharedDefaults setBool:[data[@"enableCopyFilePath"] intValue]  forKey:@"enableCopyFilePath"];
    [sharedDefaults setBool:[data[@"enableCopyFilePath"] intValue]  forKey:@"enableCopyFilePath"];
    [sharedDefaults setObject:data[@"items"] forKey:@"items"];
}


#pragma mark - Getters

- (NSString*) mainAppBundleID
{
    NSString* bundleID = NSBundle.mainBundle.bundleIdentifier;
    NSMutableArray* bundleComponents = [[bundleID componentsSeparatedByString:@"."] mutableCopy];
    [bundleComponents removeLastObject];
    bundleID = [bundleComponents componentsJoinedByString:@"."];
    return bundleID;
}

@end
