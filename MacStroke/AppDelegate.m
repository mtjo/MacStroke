#import "AppDelegate.h"


@implementation AppDelegate

static CanvasWindowController *windowController;
static CGEventRef mouseDownEvent, mouseDraggedEvent;
static NSMutableString *direction;
static NSPoint lastLocation;
static CFMachPortRef mouseEventTap;
static BOOL isEnabled;
static AppPrefsWindowController *_preferencesWindowController;
static NSTimeInterval lastMouseWheelEventTime;

static NSMutableArray *gestureB;
static NSInteger actionRuleIndex;

static NSInteger settingRuleIndex;

static RightClickMenu *rightClickMenu;
static HistoryClipboard * historyClipboard;


static HistoryClipoardListWindowController *historyClipoardListWindowController;

+ (AppDelegate *)appDelegate {
    return (AppDelegate *) [[NSApplication sharedApplication] delegate];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSArray *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:[[NSBundle mainBundle] bundleIdentifier]];
    NSDistributedNotificationCenter *center = [NSDistributedNotificationCenter defaultCenter];
    NSString *name = @"MacStrokeOpenPreferences";
    if ([apps count] > 1)
    {
        [center postNotificationName:name object:nil userInfo:nil deliverImmediately:YES];
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSApp terminate:self];
        });
        return ;
    }
    [self initAppAtFirstLaunch];
    windowController = [[CanvasWindowController alloc] init];
    
    CGEventMask eventMask = CGEventMaskBit(kCGEventRightMouseDown) | CGEventMaskBit(kCGEventRightMouseDragged) | CGEventMaskBit(kCGEventRightMouseUp) | CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventScrollWheel);
    mouseEventTap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, eventMask, mouseEventCallback, NULL);
    

    
    const void * keys[] = { kAXTrustedCheckOptionPrompt };
    const void * values[] = { kCFBooleanTrue };
    
    CFDictionaryRef options = CFDictionaryCreate(
                                                  kCFAllocatorDefault,
                                                 keys,
                                                 values,
                                                 sizeof(keys) / sizeof(*keys),
                                                 &kCFCopyStringDictionaryKeyCallBacks,
                                                 &kCFTypeDictionaryValueCallBacks);
    
    BOOL accessibilityEnabled = AXIsProcessTrustedWithOptions(options);
    
    if (accessibilityEnabled) {
        CFRunLoopSourceRef runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, mouseEventTap, 0);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);
        CFRelease(mouseEventTap);
        CFRelease(runLoopSource);
        
        
        
    } else {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setAlertStyle:NSInformationalAlertStyle];
        [alert setMessageText:NSLocalizedString(@"On macOS Mojave(10.14) and later, you must manually enable Accessibility permission for MacStroke to work.\n Please goto System Preferences -> Security & Privacy -> Privacy -> Accessibility to enable it for MacStroke.\nIf is is already enabled but MacStroke is still not working, please re-open MacStroke.", nil)];
        
        [alert runModal];
        
    }
    
    direction = [NSMutableString string];
    
    gestureB = [[NSMutableArray alloc] init];
    isEnabled = YES;
    
    NSURL *defaultPrefsFile = [[NSBundle mainBundle]
                               URLForResource:@"DefaultPreferences" withExtension:@"plist"];
    NSDictionary *defaultPrefs = [NSDictionary dictionaryWithContentsOfURL:defaultPrefsFile];
    [[NSUserDefaults standardUserDefaults] registerDefaults:defaultPrefs];
    
    [BWFilter compatibleProcedureWithPreviousVersionBlockRules];
    
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"openPrefOnStartup"]) {
        [self openPreferences:self];
    }
    
    [self updateStatusBarItem];
    
    [center setSuspended:NO];
    [center addObserver:self selector:@selector(receiveOpenPreferencesNotification:) name:name object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    
    [[NSUserNotificationCenter defaultUserNotificationCenter] setDelegate:self];
    
    lastMouseWheelEventTime = 0;
    settingRuleIndex=-1;
    
    //init Right Click Menu
    [self initRightClickMenu];
    
    //init History Clipboard
    [self initHistoryClipboard];
    
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)theApplication hasVisibleWindows:(BOOL)flag
{
    [self showPreferences];
    return NO;
}

- (void)updateStatusBarItem {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"showIconInStatusBar"]) {
        [self setStatusItem:[[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength]];
        
        NSImage *menuIcon = [NSImage imageNamed:@"Menu Icon Enabled"];
        //NSImage *highlightIcon = [NSImage imageNamed:@"Menu Icon"]; // Yes, we're using the exact same image asset.
        //[highlightIcon setTemplate:YES]; // Allows the correct highlighting of the icon when the menu is clicked.
        [menuIcon setTemplate:YES];
        [[self statusItem] setImage:menuIcon];
        //    [[self statusItem] setAlternateImage:highlightIcon];
        [[self statusItem] setMenu:[self menu]];
        [[self statusItem] setHighlightMode:YES];
    } else {
        if ([self statusItem]) {
            [[NSStatusBar systemStatusBar] removeStatusItem:[self statusItem]];
            [self setStatusItem:nil];
        }
    }
}

- (BOOL)userNotificationCenter:(NSUserNotificationCenter *)center shouldPresentNotification:(NSUserNotification *)notification{
    return YES;
}

- (void)showPreferences {
    [NSApp activateIgnoringOtherApps:YES];
    
    //instantiate preferences window controller
    if (!_preferencesWindowController) {
        _preferencesWindowController = [[AppPrefsWindowController alloc] initWithWindowNibName:@"Preferences"];
        [_preferencesWindowController showWindow:self];
    } else {
        [[_preferencesWindowController window] orderFront:self];
    }
}

- (void)setEnabled:(BOOL)enabled {
    isEnabled = enabled;
    if ([self statusItem]) {
        NSImage *menuIcon;
        if (isEnabled) {
            menuIcon = [NSImage imageNamed:@"Menu Icon Enabled"];
        } else {
            menuIcon = [NSImage imageNamed:@"Menu Icon Disabled"];
        }
        [[self statusItem] setImage:menuIcon];
    }
}

- (IBAction)openPreferences:(id)sender {
    [self showPreferences];
}

- (void)receiveOpenPreferencesNotification:(NSNotification *)notification {
    [self showPreferences];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    // This event can be triggered when switching desktops in Sierra. See BUG #37
    // [self showPreferences];
}

static void setGestureB(NSEvent *event){
    NSPoint newLocation = event.locationInWindow;
    [gestureB addObject:[NSValue valueWithPoint:newLocation]];
}

static void setActionIndex(){
    RulesList *rulesList = [RulesList sharedRulesList];
    
    NSInteger count = [rulesList count];
    //NSLog(@"%ld",(long)count);
    NSArray *ruleListArr=[NSKeyedUnarchiver unarchiveObjectWithData:[rulesList nsData]];
    //NSLog(@"%@",ruleListArr);
    int tmpIndex=-1;
    double tmp_score = 0.0;
    double minscore =[[NSUserDefaults standardUserDefaults] doubleForKey:@"minScore"];
    bool enableGestureMinScore=[[NSUserDefaults standardUserDefaults] boolForKey:@"enableGestureMinScore"];
    NSString *frontApp = frontBundleName();
    for (int i=0; i<count; i++) {
        if([rulesList matchFilter:frontApp atIndex:i]/*||[rulesList triggerOnEveryMatchAtIndex:i]*/){
            //}
            NSArray *Ruledata=[[ruleListArr objectAtIndex:i] objectForKey:@"data"];
            if(Ruledata!=nil){
                NSMutableArray *gestureA = [[NSMutableArray alloc] initWithArray:Ruledata];
                double score = [GestureCompare compareByGestureA:gestureA GestureB:gestureB];
                //NSLog(@"%d:%f",i,score);
                if(enableGestureMinScore){
                    if(score>0 && score>tmp_score && score >minscore){
                        tmpIndex=i;
                        tmp_score=score;
                    }
                }else {
                    if(score>0 && score>tmp_score){
                        tmpIndex=i;
                        tmp_score=score;
                    }
                    
                }
                
            }
        }
        
    }
    actionRuleIndex=tmpIndex;
    [windowController writeActionRuleIndex:actionRuleIndex];
}

void resetGestureB() {
    [gestureB removeAllObjects];
    actionRuleIndex =-1;
}
bool setRuleData(){
    if(settingRuleIndex>-1){
        [[RulesList sharedRulesList] setGestureData:gestureB atIndex:settingRuleIndex];
        NSUserNotification *notification = [[NSUserNotification alloc] init];
        notification.title = @"MacStroke";
        notification.informativeText = NSLocalizedString(@"Gesture draw complete!", nil);
        notification.soundName = NSUserNotificationDefaultSoundName;
        [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
        [_preferencesWindowController.rulesTableView reloadData];
        
        settingRuleIndex = -1;
        
        NSString *appname =frontBundleName();
        if ([appname isEqualToString:@"net.mtjo.MacStroke"]) {
            [RulesList pressKeyWithFlags:kVK_Return virtualKey:kVK_Return];
        }
        return YES;
    }
    return NO;
}

static bool handleGesture(BOOL lastGesture) {
    if(lastGesture){
        setActionIndex();
        if(setRuleData()){
            return YES;
        }
    }
    return [[RulesList sharedRulesList] handleGesture:actionRuleIndex isLastGesture:lastGesture];
}

void resetDirection() {
    [direction setString:@""];
}

// See https://developer.apple.com/library/mac/documentation/Carbon/Reference/QuartzEventServicesRef/#//apple_ref/c/tdef/CGEventTapCallBack
static CGEventRef mouseEventCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    static BOOL shouldShow;
    
    if (!isEnabled) {
        return event;
    }
    NSEvent *mouseEvent;
    switch (type) {
        case kCGEventRightMouseDown:
            // not thread safe, but it's always called in main thread
            // check blocker apps
            //    if(wildLike(frontBundleName(), [[NSUserDefaults standardUserDefaults] stringForKey:@"blockFilter"])){
            if (true)
            {
                NSString *frontBundle = frontBundleName();
                if (![BWFilter shouldHookMouseEventForApp:frontBundle] || !([[NSUserDefaults standardUserDefaults] boolForKey:@"showUIInWhateverApp"] || [[RulesList sharedRulesList] appSuitedRule:frontBundle])) {
                    //        CGEventPost(kCGSessionEventTap, mouseDownEvent);
                    //        if (mouseDraggedEvent) {
                    //            CGEventPost(kCGSessionEventTap, mouseDraggedEvent);
                    //        }
                    shouldShow = NO;
                    return event;
                }
                
                shouldShow = YES;
            }
            
            if (mouseDownEvent) { // mouseDownEvent may not release when kCGEventTapDisabledByTimeout
                //resetDirection();
                resetGestureB();
                
                CGPoint location = CGEventGetLocation(mouseDownEvent);
                CGEventPost(kCGSessionEventTap, mouseDownEvent);
                CFRelease(mouseDownEvent);
                if (mouseDraggedEvent) {
                    location = CGEventGetLocation(mouseDraggedEvent);
                    CGEventPost(kCGSessionEventTap, mouseDraggedEvent);
                    CFRelease(mouseDraggedEvent);
                }
                CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventRightMouseUp, location, kCGMouseButtonRight);
                CGEventPost(kCGSessionEventTap, event);
                CFRelease(event);
                mouseDownEvent = mouseDraggedEvent = NULL;
            }
            mouseEvent = [NSEvent eventWithCGEvent:event];
            mouseDownEvent = event;
            CFRetain(mouseDownEvent);
            
            [windowController reinitWindow];
            [windowController handleMouseEvent:mouseEvent];
            lastLocation = mouseEvent.locationInWindow;
            
            break;
        case kCGEventRightMouseDragged:
            if (!shouldShow){
                return event;
            }
            
            if (mouseDownEvent) {
                mouseEvent = [NSEvent eventWithCGEvent:event];
                
                // Hack when Synergy is started after MacStroke
                // -- when dragging to a client, the mouse point resets to (server_screenwidth/2+rnd(-1,1),server_screenheight/2+rnd(-1,1))
                if (mouseDraggedEvent) {
                    NSPoint lastPoint = CGEventGetLocation(mouseDraggedEvent);
                    NSPoint currentPoint = [mouseEvent locationInWindow];
                    NSRect screen = [[NSScreen mainScreen] frame];
                    float d1 = fabs(lastPoint.x - screen.origin.x), d2 = fabs(lastPoint.x - screen.origin.x - screen.size.width);
                    float d3 = fabs(lastPoint.y - screen.origin.y), d4 = fabs(lastPoint.y - screen.origin.y - screen.size.height);
                    
                    float d5 = fabs(currentPoint.x - screen.origin.x - screen.size.width/2), d6 = fabs(currentPoint.y - screen.origin.y - screen.size.height/2);
                    
                    const float threshold = 30.0;
                    if ((d1 < threshold || d2 < threshold || d3 < threshold || d4 < threshold) &&
                        d5 < threshold && d6 < threshold) {
                        CFRelease(mouseDraggedEvent);
                        CFRelease(mouseDownEvent);
                        mouseDownEvent = mouseDraggedEvent = NULL;
                        shouldShow = NO;
                        [windowController reinitWindow];
                        
                        //resetDirection();
                        resetGestureB();
                        break;
                    }
                    
                }
                
                if (mouseDraggedEvent) {
                    CFRelease(mouseDraggedEvent);
                }
                mouseDraggedEvent = event;
                CFRetain(mouseDraggedEvent);
                
                [windowController handleMouseEvent:mouseEvent];
                //updateDirections(mouseEvent);]
                
                setGestureB(mouseEvent);
            }
            break;
        case kCGEventRightMouseUp: {
            if (!shouldShow){
                return event;
            }
            if (mouseDownEvent) {
                mouseEvent = [NSEvent eventWithCGEvent:event];
                [windowController handleMouseEvent:mouseEvent];
                setGestureB(mouseEvent);
                if (!handleGesture(true)) {
                    NSString *appname =frontBundleName();
                    if ([[RightClicksList sharedRightClicksList] needRightClickByAppname:appname]  &&!mouseDraggedEvent) {
                        CGPoint p = CGEventGetLocation(mouseDownEvent);
                        [windowController threadRightClick:p];
                    }else{
                        CGEventPost(kCGSessionEventTap, mouseDownEvent);
                        //if (mouseDraggedEvent) {
                        //    CGEventPost(kCGSessionEventTap, mouseDraggedEvent);
                        //}
                        CGEventPost(kCGSessionEventTap, event);
                    }
                }else {
                    [windowController reinitWindow];
                }
                CFRelease(mouseDownEvent);            }
            
            if (mouseDraggedEvent) {
                CFRelease(mouseDraggedEvent);
            }
            
            mouseDownEvent = mouseDraggedEvent = NULL;
            shouldShow = NO;
            
            resetGestureB();
            break;
        }
        case kCGEventScrollWheel: {
            if (!shouldShow || !mouseDownEvent) {
                return event;
            }
            
            double delta = CGEventGetDoubleValueField(event, kCGScrollWheelEventDeltaAxis1);
            
            NSTimeInterval current = [NSDate timeIntervalSinceReferenceDate];
            if (current - lastMouseWheelEventTime > 0.3) {
                if (delta > 0) {
                    //NSLog(@"Down!");
                    //addDirection('d', true);
                    
                } else if (delta < 0){
                    // NSLog(@"Up!");
                    //addDirection('u', true);
                }
                lastMouseWheelEventTime = current;
            }
            break;
        }
        case kCGEventTapDisabledByTimeout:
            CGEventTapEnable(mouseEventTap, true); // re-enable
            // windowController.enable = isEnable;
            break;
        case kCGEventLeftMouseDown: {
            if (!shouldShow || !mouseDownEvent) {
                return event;
            }
            //[direction appendString:@"Z"];
            //[windowController writeDirection:direction];
            break;
        }
        default:
            return event;
    }
    
    return NULL;
}



-(void) setSettingRuleIndex:(NSInteger)index;
{
    settingRuleIndex = index;
}
- (NSInteger) getSettingRuleIndex;
{
    return settingRuleIndex;
}

-(void) initAppAtFirstLaunch;
{
    // 判断是不是第一次启动APP
    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"firstLaunch"]) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"firstLaunch"];
        [[RulesList sharedRulesList] reInit];
        [[RightClicksList sharedRightClicksList] reInit];
        [[NSUserDefaults standardUserDefaults] synchronize];
        //载入预设值
        NSUserDefaults * defs = [NSUserDefaults standardUserDefaults];
        NSURL *defaultPrefsFile = [[NSBundle mainBundle]
                                   URLForResource:@"DefaultPreferences" withExtension:@"plist"];
        NSDictionary *defaultPrefs =
        [NSDictionary dictionaryWithContentsOfURL:defaultPrefsFile];
        for (NSString *key in defaultPrefs) {
            [defs setObject:[defaultPrefs objectForKey:key] forKey:key];
        }
        [defs synchronize];
        [MGOptionsDefine resetColors];
                
    }
}


-(void) initRightClickMenu;
{
    rightClickMenu = [[RightClickMenu alloc] init];
    [rightClickMenu delayedEnableFinderExtension];
    [rightClickMenu initFinderSyncExtension];
}


-(void) initHistoryClipboard
{
    
    NSUserDefaultsController *defaults = NSUserDefaultsController.sharedUserDefaultsController;
    NSString *keyPath = @"values.historyCilpboardListShortcut";
    NSDictionary *options = @{NSValueTransformerNameBindingOption: NSKeyedUnarchiveFromDataTransformerName};

    SRShortcutAction *showHistoryCilpboardList = [SRShortcutAction shortcutActionWithKeyPath:keyPath
                                                                                    ofObject:defaults
                                                                               actionHandler:^BOOL(SRShortcutAction *anAction) {
        if ([[AppDelegate appDelegate] isHistoryClipboardEnable] ) {
            [self showHistoryCilpboardList:nil];
        }
        
        return YES;
    }];
    [[SRGlobalShortcutMonitor sharedMonitor] addAction:showHistoryCilpboardList forKeyEvent:SRKeyEventTypeDown];
    
    SRRecorderControl *recorder = [SRRecorderControl new];
    [recorder bind:NSValueBinding toObject:defaults withKeyPath:keyPath options:options];
    
    //recorder.objectValue = [SRShortcut shortcutWithKeyEquivalent:@"^⇧V"];
    NSLog(@"historyCilpboardListShortcut:%@", [[NSUserDefaults standardUserDefaults] objectForKey:@"historyCilpboardListShortcut"]);
    
   

    historyClipboard = [[HistoryClipboard alloc] init];
    
    [historyClipboard enableHistoryClipboard];

}
-(HistoryClipboard *) getHistoryClipboard{
    return historyClipboard;
}

-(BOOL) isHistoryClipboardEnable{
    return [historyClipboard isEnable];
}

- (IBAction)showHistoryCilpboardList:(id)sender {
    //instantiate preferences window controller
    if (!historyClipoardListWindowController) {
        historyClipoardListWindowController = [[HistoryClipoardListWindowController alloc] initWithWindowNibName:@"HistoryClipoardListWindowController"];
        [historyClipoardListWindowController showWindow:self];
        [historyClipoardListWindowController.window center];
        [historyClipoardListWindowController.window makeKeyWindow];
        [historyClipoardListWindowController.window setLevel:21];
    } else {
        [historyClipoardListWindowController.window close];
        historyClipoardListWindowController = [[HistoryClipoardListWindowController alloc] initWithWindowNibName:@"HistoryClipoardListWindowController"];
        [historyClipoardListWindowController showWindow:self];
        [historyClipoardListWindowController.window center];
        [historyClipoardListWindowController.window makeKeyWindow];
        [historyClipoardListWindowController.window setLevel:21];
    }
}

@end
