//
//  FinderSync.h
//  FinderSyncExtension
//
//  Created by Marko Cicak on 7/26/18.
//  Copyright © 2018 codecentric AG. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import <FinderSync/FinderSync.h>

@class FinderCommChannel;

@interface FinderSync : FIFinderSync
{
    BOOL enableRightClickMenu;
    BOOL enableNewFile;
    BOOL enableOpenInTerminal;
    BOOL enableCopyFilePath;
    NSArray<NSString *> *items;
    NSUserDefaults *sharedDefaults;
}
@property(nonatomic, strong) NSURL* root;
@property(nonatomic, strong) FinderCommChannel* commChannel;

// This index serves as cache for paths and file statuses
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSNumber*>* index;

@end
