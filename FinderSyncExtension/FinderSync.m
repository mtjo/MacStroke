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
    sharedDefaults = [NSUserDefaults standardUserDefaults];
    enableRightClickMenu = [sharedDefaults boolForKey:@"enableRightClickMenu"];
    enableNewFile = [sharedDefaults boolForKey:@"enableNewFile"];
    enableOpenInTerminal = [sharedDefaults boolForKey:@"enableOpenInTerminal"];
    enableCopyFilePath = [sharedDefaults boolForKey:@"enableCopyFilePath"];
    items = [[sharedDefaults stringForKey:@"items"] componentsSeparatedByString:@","];
    NSNotificationCenter *center = [NSNotificationCenter  defaultCenter]; [center addObserver:self selector:@selector(defaultsChanged:) name:NSUserDefaultsDidChangeNotification object:nil];
    
#ifdef DEBUG
    NSLog(@"defaultsChanged: enableRightClickMenu: %hhd ,enableNewFile: %hhd ,enableOpenInTerminal:%hhd ,enableCopyFilePath: %hhd , items: %@",
          enableRightClickMenu,
          enableNewFile,
          enableOpenInTerminal,
          enableCopyFilePath,
          items
          );
#endif
    
    
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
    //NSLog(@"beginObservingDirectoryAtURL:%@", url.filePathURL);
}

- (void) endObservingDirectoryAtURL:(NSURL*)url
{
    // The user is no longer seeing the container's contents.
    //NSLog(@"endObservingDirectoryAtURL:%@", url.filePathURL);
}

- (void) requestBadgeIdentifierForURL:(NSURL*)url
{
    //NSLog(@"requestBadgeIdentifierForURL:%@", url.filePathURL);
    
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
    return @"MacStroke";
}

- (NSString*) toolbarItemToolTip
{
    return @"MacStroke: Click the toolbar item for a menu.";
}

- (NSImage*) toolbarItemImage
{
    //return [NSImage imageNamed:NSImageNameCaution];
    return [NSImage imageNamed:@"newFile.png"];
}

- (NSMenu*) menuForMenuKind:(FIMenuKind)whichMenu
{
    // Produce a menu for the extension.
    
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@""];
    
    if (enableRightClickMenu) {
        if(enableNewFile) {
            [menu addItemWithTitle:[items objectAtIndex:0] action:@selector(newFile:) keyEquivalent:@""];
        }
        if (enableOpenInTerminal) {
            [menu addItemWithTitle:[items objectAtIndex:1] action:@selector(openInTerminal:) keyEquivalent:@""];
        }
        if (enableCopyFilePath) {
            [menu addItemWithTitle:[items objectAtIndex:2] action:@selector(copyFilePath:) keyEquivalent:@""];
        }
    }
    
    return menu;
}

- (IBAction) newFile:(id)sender
{
    NSURL* target = [[FIFinderSyncController defaultController] targetedURL];
    NSArray* items = [[FIFinderSyncController defaultController] selectedItemURLs];
    
    NSMutableArray<NSString*> *_item = [[NSMutableArray alloc] init];
    [items enumerateObjectsUsingBlock: ^(id obj, NSUInteger idx, BOOL *stop) {
        [_item addObject: [obj path]];
    }];
    
    // send custom message to the MainApp
    [self.commChannel send:@"CustomMessageReceivedNotification"
                      data:@{ @"operation":@"newFile",@"path": [target path],@"items":[_item componentsJoinedByString:@","]}];
    //,@"target": target, @"items":items
}


- (IBAction) openInTerminal:(id)sender
{
    NSURL* target = [[FIFinderSyncController defaultController] targetedURL];
    NSArray* items = [[FIFinderSyncController defaultController] selectedItemURLs];
    
    NSMutableArray<NSString*> *_item = [[NSMutableArray alloc] init];
    [items enumerateObjectsUsingBlock: ^(id obj, NSUInteger idx, BOOL *stop) {
        [_item addObject: [obj path]];
    }];
    
    // send custom message to the MainApp
    [self.commChannel send:@"CustomMessageReceivedNotification"
                      data:@{ @"operation":@"openInTerminal",@"path": [target path],@"items":[_item componentsJoinedByString:@","]}];
}

- (IBAction) copyFilePath:(id)sender
{
    NSURL* target = [[FIFinderSyncController defaultController] targetedURL];
    NSArray* items = [[FIFinderSyncController defaultController] selectedItemURLs];
    
    NSMutableArray<NSString*> *_item = [[NSMutableArray alloc] init];
    [items enumerateObjectsUsingBlock: ^(id obj, NSUInteger idx, BOOL *stop) {
        [_item addObject: [obj path]];
    }];
    // send custom message to the MainApp
    [self.commChannel send:@"CustomMessageReceivedNotification"
                      data:@{ @"operation":@"copyFilePath",@"path": [target path],@"items":[_item componentsJoinedByString:@","]}];
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


- (void)defaultsChanged:(NSNotification *)notification {
    sharedDefaults = [NSUserDefaults standardUserDefaults];
    enableRightClickMenu = [sharedDefaults boolForKey:@"enableRightClickMenu"];
    enableNewFile = [sharedDefaults boolForKey:@"enableNewFile"];
    enableOpenInTerminal = [sharedDefaults boolForKey:@"enableOpenInTerminal"];
    enableCopyFilePath = [sharedDefaults boolForKey:@"enableCopyFilePath"];
    items = [[sharedDefaults stringForKey:@"items"] componentsSeparatedByString:@","];
#ifdef DEBUG
    NSLog(@"defaultsChanged: enableRightClickMenu: %hhd ,enableNewFile: %hhd ,enableOpenInTerminal:%hhd ,enableCopyFilePath: %hhd , items: %@",
          enableRightClickMenu,
          enableNewFile,
          enableOpenInTerminal,
          enableCopyFilePath,
          items
          );
#endif
}

@end
