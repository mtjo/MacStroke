//
//  AppPrefsWindowController.h
//

#import <Cocoa/Cocoa.h>
#import <Webkit/Webkit.h>
#import "DBPrefsWindowController.h"
#import "SRRecorderControl.h"
#import "AppPickerWindowController.h"
#import "HistoryClipoardListWindowController.h"
#import <Sparkle/Sparkle.h>

@class LaunchAtLoginController;

@interface AppPrefsWindowController : DBPrefsWindowController <NSTableViewDelegate, NSTableViewDataSource, SRRecorderControlDelegate, NSTextFieldDelegate, AppPickerCallback, NSComboBoxDataSource, NSWindowDelegate>

@property(strong, nonatomic) IBOutlet NSView *generalPreferenceView;
@property(strong, nonatomic) IBOutlet NSView *rulesPreferenceView;
@property(strong, nonatomic) IBOutlet NSView *appleScriptPreferenceView;
@property(strong, nonatomic) IBOutlet NSView *aboutPreferenceView;
@property(strong, nonatomic) IBOutlet NSView *filtersPrefrenceView;
@property(strong, nonatomic) IBOutlet NSView *rightClickPrefrenceView;
@property(strong, nonatomic) IBOutlet NSView *rightClickMenuPrefrenceView;
@property(strong, nonatomic) IBOutlet NSView *clipboardPrefrenceView;

@property(weak) IBOutlet NSTableView *rulesTableView;

@property(weak) IBOutlet NSTextField *blockFilter;
@property(strong) IBOutlet SUUpdater *updater;

@property(weak) IBOutlet NSButton *autoStartAtLogin;

@property(weak) IBOutlet NSTextField *versionCode;
@property(weak) IBOutlet NSButton *blackListModeRadio;
@property(weak) IBOutlet NSButton *whiteListModeRadio;
@property(unsafe_unretained) IBOutlet NSTextView *blackListTextView;
@property(unsafe_unretained) IBOutlet NSTextView *whiteListTextView;
@property(weak) IBOutlet NSButton *changeRulesWindowSizeButton;
@property(weak) IBOutlet NSButton *changeFiltersWindowSizeButton;
@property(weak) IBOutlet NSButton *editInExternalEditorButton;
@property(weak) IBOutlet NSPopUpButton *loadAppleScriptExampleButton;
@property(weak) IBOutlet NSButton *addAppleScriptButton;
@property(weak) IBOutlet NSButton *removeAppleScriptButton;
@property(weak) IBOutlet NSTextField *fontNameTextField;
@property(weak) IBOutlet NSTextField *fontSizeTextField;
@property(weak) IBOutlet NSTextField *minScoreTextField;
@property(weak) IBOutlet NSSlider *minScoreSlider;
@property(weak) IBOutlet NSTableView *appleScriptTableView;

@property(weak) IBOutlet NSTextField *appleScriptTextField;
@property(weak) IBOutlet NSTableView *rightClickTableView;
@property(weak) IBOutlet NSButton *showIconInStatusBarButton;
@property(weak) IBOutlet NSComboBox *languageComboBox;
@property(weak) IBOutlet NSButton *enableNewFileButton;
@property (weak) IBOutlet NSButton *enableOpenInTerminalButton;
@property (weak) IBOutlet NSButton *enablecopyFilePathButton;

@property(weak) IBOutlet NSColorWell *lineColorWell;

@property(assign) IBOutlet WebView *webView;

@property(assign) IBOutlet NSView *keyboardShortcut;

- (void)rulePickCallback:(NSString *)rulesStringSplitedByStick atIndex:(NSInteger)index;

- (void) preSetRuleGestureAtIndex:(NSInteger)index;

- (IBAction)onSetGestureData:(id)sender;

- (void)rightClickPickCallback:(NSString *)appname atIndex:(NSInteger)index;

- (IBAction)onToggleRightClickMenu:(id)sender;

@property (weak) IBOutlet NSButton *useTerminalRadio;

@property (weak) IBOutlet NSButton *useItermRadio;

- (IBAction)onChangeTerminal:(id)sender;

- (void)initCilpboardShotCut;
@end
