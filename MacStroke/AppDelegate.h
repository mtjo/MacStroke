#import <Cocoa/Cocoa.h>
#import "AppPrefsWindowController.h"
#import "CanvasWindowController.h"
#import "RulesList.h"
#import "utils.h"
#import "NSBundle+LoginItem.h"
#import "BlackWhiteFilter.h"
#import "GestureCompare.h"
#import "RightClicksList.h"
#import "RightClickMenu.h"
#import "HistoryClipboard.h"
#import <ShortcutRecorder/SRShortcutAction.h>
@class RulesList;


@interface AppDelegate : NSObject <NSApplicationDelegate, NSUserNotificationCenterDelegate>

@property(assign) IBOutlet NSWindow *window;

@property(readwrite, retain) IBOutlet NSMenu *menu;
@property(readwrite, retain) NSStatusItem *statusItem;

+ (AppDelegate *)appDelegate;

- (void)updateStatusBarItem;

- (void)receiveOpenPreferencesNotification:(NSNotification *)notification;

- (void)setEnabled:(BOOL)enabled;

- (void)showPreferences;

- (void) setSettingRuleIndex:(NSInteger)index;

- (NSInteger) getSettingRuleIndex;

-(void) initRightClickMenu;

-(void) initHistoryClipboard;

-(HistoryClipboard *) getHistoryClipboard;
-(BOOL) isHistoryClipboardEnable;

@end
