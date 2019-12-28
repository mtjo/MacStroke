//
//  RightClickMenu.h
//  MacStroke
//
//  Created by MTJO on 2019/12/25.
//  Copyright © 2019 Chivalry Software. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RightClickMenu : NSObject
@property(nonatomic, copy) NSMutableDictionary<NSString*, NSNumber*>* queuedUpdates;
@property(nonatomic, strong) NSTimer* timer;

- (void) initFinderSyncExtension;

- (void) updatePath:(NSString*)path withStatus:(NSNumber*)status;

- (void) send:(NSString*)name data:(id)data;

- (void) rootPathRequested:(NSNotification*)notif;

- (void) customMessageReceivedFromFinder:(NSNotification*)notif;

- (NSMutableDictionary<NSString*, NSNumber*>*) queuedUpdates;

- (void) reEnableFinderExtension;

- (void) enableFinderExtension;

- (void) disableFinderExtension;

-(void) delayedEnableFinderExtension;

@end

NS_ASSUME_NONNULL_END
