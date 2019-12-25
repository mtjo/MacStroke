//
//  FinderSync.m
//  FinderSyncExtension
//
//  Created by Marko Cicak on 7/26/18.
//  Copyright © 2018 codecentric AG. All rights reserved.
//

#import "FinderSync.h"
#import "FinderCommChannel.h"

@implementation FinderSync

- (instancetype) init
{
    self = [super init];
    
    NSLog(@"%s launched from %@ ; compiled at %s", __PRETTY_FUNCTION__, [[NSBundle mainBundle] bundlePath], __TIME__);
    
    // Set up the directory we are syncing.
    //    self.myFolderURL = [NSURL fileURLWithPath:@"/Users/Shared/MySyncExtension Documents"];
    //    [FIFinderSyncController defaultController].directoryURLs = [NSSet setWithObject:self.myFolderURL];
    
    [self.commChannel setup];
    
    // FinderSync extension is being launched and it wants to ask the main app what root folder to observe
    [self.commChannel send:@"RequestObservingPathNotification" data:@{}];
    
    // Set up images for our badge identifiers. For demonstration purposes, this uses off-the-shelf images.
    //    [[FIFinderSyncController defaultController] setBadgeImage:[NSImage imageNamed:NSImageNameColorPanel]
    //                                                        label:@"Status One" forBadgeIdentifier:@"1"];
    //    [[FIFinderSyncController defaultController] setBadgeImage:[NSImage imageNamed:NSImageNameCaution]
    //                                                        label:@"Status Two" forBadgeIdentifier:@"2"];
    
    return self;
}

- (void) setRoot:(NSURL*)root
{
    if ([self.root isEqualTo:root])
    {
        return;
    }
    _root = root;
    NSLog(@"New root set to: %@", root);
    [FIFinderSyncController defaultController].directoryURLs = [NSSet setWithObject:root];
}

#pragma mark - Primary Finder Sync methods

- (void) beginObservingDirectoryAtURL:(NSURL*)url
{
    // The user is now seeing the container's contents.
    // If they see it in more than one view at a time, we're only told once.
    NSLog(@"beginObservingDirectoryAtURL:%@", url.filePathURL);
}

- (void) endObservingDirectoryAtURL:(NSURL*)url
{
    // The user is no longer seeing the container's contents.
    NSLog(@"endObservingDirectoryAtURL:%@", url.filePathURL);
}

- (void) requestBadgeIdentifierForURL:(NSURL*)url
{
    NSLog(@"requestBadgeIdentifierForURL:%@", url.filePathURL);
    
    NSString* status = [self.index[url.path] stringValue];
    if (status.length == 0)
    {
        status = @"";
    }
    [[FIFinderSyncController defaultController] setBadgeIdentifier:status forURL:url];
}

#pragma mark - Menu and toolbar item support

- (NSString*) toolbarItemName
{
    return @"FinderSyncExtension";
}

- (NSString*) toolbarItemToolTip
{
    return @"FinderSyncExtension: Click the toolbar item for a menu.";
}

- (NSImage*) toolbarItemImage
{
    return [NSImage imageNamed:NSImageNameCaution];
}

- (NSMenu*) menuForMenuKind:(FIMenuKind)whichMenu
{
    // Produce a menu for the extension.
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@""];
    [menu addItemWithTitle:@"新建文本文件" action:@selector(newFile:) keyEquivalent:@""];
    [menu addItemWithTitle:@"在终端中打开" action:@selector(openInTerminal:) keyEquivalent:@""];
    return menu;
}

- (IBAction) newFile:(id)sender
{
    NSURL* target = [[FIFinderSyncController defaultController] targetedURL];
    NSArray* items = [[FIFinderSyncController defaultController] selectedItemURLs];
    ;
    // send custom message to the MainApp
    [self.commChannel send:@"CustomMessageReceivedNotification"
                      data:@{ @"operation":@"newFile",@"target": [target absoluteString]}];
    //,@"target": target, @"items":items
}


- (IBAction) openInTerminal:(id)sender
{
    NSURL* target = [[FIFinderSyncController defaultController] targetedURL];
    NSLog(@"target absoluteString: %s",[target absoluteString]);
    NSArray* items = [[FIFinderSyncController defaultController] selectedItemURLs];
    // send custom message to the MainApp
    [self.commChannel send:@"CustomMessageReceivedNotification"
                      data:@{ @"operation":@"openInTerminal",@"target": [target absoluteString]}];
}

#pragma mark - Getters

- (FinderCommChannel*) commChannel
{
    NSLog(@"commChannel: %@",_commChannel);
    if (!_commChannel)
    {
        _commChannel = FinderCommChannel.new;
        _commChannel.finderSync = self;
    }
    return _commChannel;
}

- (NSMutableDictionary<NSString*, NSNumber*>*) index
{
    if (!_index)
    {
        _index = NSMutableDictionary.dictionary;
    }
    return _index;
}

@end
