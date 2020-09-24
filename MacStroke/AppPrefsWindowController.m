//
//  AppPrefsWindowController.m
//
#import "AppPrefsWindowController.h"
#import "RulesList.h"
#import "AppleScriptsList.h"
#import "RightClicksList.h"
#import "SRRecorderControlWithTagid.h"
#import "BlackWhiteFilter.h"
#import "HexColors.h"
#import "MGOptionsDefine.h"
#import "AppDelegate.h"
#import "CanvasView.h"
#import "DrawGesture.h"
#import "PreGesture.h"
#import "HistoryClipoardListWindowController.h"
#import <ShortcutRecorder/SRShortcutAction.h>

@interface AppPrefsWindowController ()
@property AppPickerWindowController *pickerWindowController;
@property HistoryClipoardListWindowController *historyClipoardListWindowController;

@end

@interface HistoryClipoardListWindowController ()
@property HistoryClipoardListWindowController *historyClipoardListWindowController;
@end

// A hack for the private getter of contentSubview
@interface DBPrefsWindowController (PrivateMethodHack)
-(NSView *)contentSubview;
@end




@implementation AppPrefsWindowController

@synthesize rulesTableView = _rulesTableView;

static NSSize const PREF_WINDOW_SIZES[3] = {{600, 400}, {800, 600}, {1000, 800}};
static NSInteger const PREF_WINDOW_SIZECOUNT = 3;
static NSInteger currentRulesWindowSizeIndex = 0;
static NSInteger currentFiltersWindowSizeIndex = 0;


static NSArray *exampleAppleScripts;

+ (void)initialize {
    exampleAppleScripts = [NSArray arrayWithObjects:@"ChromeCloseTabsToTheRight",
                           @"Close Tabs To The Right In Chrome",
                           @"OpenMacStrokePreferences",
                           @"Open MacStroke Preferences",
                           @"SearchInWeb",
                           @"Search in Web", nil];
    
}

- (void)changeSize:(NSInteger *)index changeSizeButton:(NSButton *)button preferenceView:(NSView *)view {
    *index += 1;
    *index %= PREF_WINDOW_SIZECOUNT;
    
    NSString *title;
    
    if (*index != PREF_WINDOW_SIZECOUNT - 1) {
        title = NSLocalizedString(@"Go bigger", nil);
    } else {
        title = NSLocalizedString(@"Reset size", nil);
    }
    
    [button setTitle:title];
    
    [view setFrameSize:PREF_WINDOW_SIZES[*index]];
    [self changeWindowSizeToFitInsideView:view];
    [self crossFadeView:view withView:view];
    
}

- (IBAction)blockFilterDidEdit:(id)sender {
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)windowDidLoad {
    [super windowDidLoad];
    //    [self.blockFilter bind:NSValueBinding toObject:[NSUserDefaults standardUserDefaults]  withKeyPath:@"blockFilter" options:nil];
    
    [[self window] setDelegate:self];
    
    self.autoStartAtLogin.state = [[NSBundle mainBundle] isLoginItem] ? NSOnState : NSOffState;
    self.versionCode.stringValue = [[NSBundle mainBundle] infoDictionary][@"CFBundleShortVersionString"];
    [self refreshFilterRadioAndTextViewState];
    self.blackListTextView.string = BWFilter.blackListText;
    self.whiteListTextView.string = BWFilter.whiteListText;
    self.blackListTextView.font = [NSFont systemFontOfSize:14];
    self.whiteListTextView.font = [NSFont systemFontOfSize:14];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(tableViewSelectionChanged:)
                                                 name:NSTableViewSelectionDidChangeNotification
                                               object:[self appleScriptTableView]];
    
    [[self languageComboBox] addItemsWithObjectValues:[NSArray arrayWithObjects:@"en", @"zh-Hans", nil]];
    
    NSArray *languages = [[NSUserDefaults standardUserDefaults] objectForKey:@"AppleLanguages"];
#ifdef DEBUG
    NSLog(@"languages:%@",languages);
#endif
    if (languages) {
        for (int i=0;i<[[self languageComboBox] numberOfItems];i++) {
            if ([languages[0] hasPrefix:[[self languageComboBox] itemObjectValueAtIndex:i]]) {
                [[self languageComboBox] selectItemAtIndex:i];
            }
        }
    }
    
    for (NSUInteger i = 0;i < [exampleAppleScripts count];i += 2) {
        NSMenuItem *item = [[NSMenuItem alloc] init];
        [item setTitle:exampleAppleScripts[i+1]];
        [item setTag:i];
        [item setAction:@selector(exampleAppleScriptSelected:)];
        [[[self loadAppleScriptExampleButton] menu] addItem:item];
    }
    
    NSString *readme = [[NSBundle mainBundle] pathForResource:@"README" ofType:@"html"];
    NSString *content = [NSString stringWithContentsOfFile:readme encoding:NSUTF8StringEncoding error:NULL];
    
    [[[self webView] mainFrame] loadHTMLString:content baseURL:[NSURL URLWithString:readme]];
    
    //right click menu
    if(![[NSUserDefaults standardUserDefaults] boolForKey:@"enableRightClickMenu"]){
        [[self enableNewFileButton] setEnabled:NO];
        [[self enableOpenInTerminalButton] setEnabled:NO];
        [[self enablecopyFilePathButton] setEnabled:NO];
    }
    
    [self initCilpboardShotCut];
    
    
}

- (BOOL)windowShouldClose:(id)sender {
    [[self window] orderOut:self];
    return NO;
}

- (void)refreshFilterRadioAndTextViewState {
    //    self.blackListModeRadio.cell stat
    //NSLog(@"BWFilter.isInWhiteListMode: %d", BWFilter.isInWhiteListMode);
    [self.blackListModeRadio setState:BWFilter.isInWhiteListMode ? NSOffState : NSOnState];
    [self.whiteListModeRadio setState:BWFilter.isInWhiteListMode ? NSOnState : NSOffState];
    NSColor *notActive = self.window.backgroundColor;//[NSColor hx_colorWithHexString:@"ffffff" alpha:0];//[NSColor colorWithCGColor: self.filtersPrefrenceView.layer.backgroundColor];
    //[NSColor hx_colorWithHexString:@"E3E6EA"];
    NSColor *active = [NSColor hx_colorWithHexRGBAString:@"#ffffff"];
    self.blackListTextView.backgroundColor = BWFilter.isInWhiteListMode ? notActive : active;
    //    ((NSScrollView *)(self.blackListTextView.superview.superview)).backgroundColor=BWFilter.isInWhiteListMode?notActive:active;
    self.whiteListTextView.backgroundColor = BWFilter.isInWhiteListMode ? active : notActive;
    //    ((NSScrollView *)(self.whiteListTextView.superview.superview)).backgroundColor=BWFilter.isInWhiteListMode?active:notActive;
    
    [self.whiteListTextView.superview.superview needsLayout];
    [self.whiteListTextView.superview.superview needsDisplay];
    [self.blackListTextView.superview.superview needsLayout];
    [self.blackListTextView.superview.superview needsDisplay];
}

- (IBAction) addShortcutRule:(id)sender {
    [[RulesList sharedRulesList] addRuleWithDirection:NSLocalizedString(@"Double click Modify", nil) gestureData:nil filter:@"*" filterType:FILTER_TYPE_WILDCARD actionType:ACTION_TYPE_SHORTCUT shortcutKeyCode:0 shortcutFlag:0 appleScriptId:nil text:NSLocalizedString(@"Double click Modify", nil) password:NSLocalizedString(@"Double click Modify", nil) note:NSLocalizedString(@"Double click Modify", nil)];
    [_rulesTableView reloadData];
}

- (IBAction)removeRule:(id)sender {
    if ([_rulesTableView selectedRow] == -1) {
        NSUserNotification *notification = [[NSUserNotification alloc] init];
        notification.title = @"MacStroke";
        notification.informativeText = NSLocalizedString(@"Select a filter first!", nil);
        notification.soundName = NSUserNotificationDefaultSoundName;
        
        [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
        return ;
    }
    [[RulesList sharedRulesList] removeRuleAtIndex:_rulesTableView.selectedRow];
    [_rulesTableView reloadData];
}

- (IBAction)changeSizeOfPreferenceWindow:(id)sender {
    [self changeSize:&currentRulesWindowSizeIndex changeSizeButton:[self changeRulesWindowSizeButton] preferenceView:[self rulesPreferenceView]];
}

- (void)changeWindowSizeToFitInsideView:(NSView *)view {
    NSRect frame = [view bounds];
    NSView *p = [self contentSubview];
    frame.origin.y = NSHeight([p frame]) - NSHeight([view bounds]);
    [view setFrame:frame];
}

- (IBAction)resetRules:(id)sender {
    [[RulesList sharedRulesList] reInit];
    [[RulesList sharedRulesList] save];
    [_rulesTableView reloadData];
}

- (IBAction)clearRules:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    NSString *title1 =NSLocalizedString(@"Ok", nil);
    NSString *title2 =NSLocalizedString(@"Cancel", nil);
    NSString *messagetext =NSLocalizedString(@"warning!", nil);
    NSString *informativetext =NSLocalizedString(@"Are you sure you want to clear all the rules?", nil);
    
    [alert addButtonWithTitle:title1];
    [alert addButtonWithTitle:title2];
    [alert setMessageText:messagetext];
    [alert setInformativeText:informativetext];
    [alert setAlertStyle:NSWarningAlertStyle];
    
    [[[alert window] contentView] autoresizesSubviews];
    
    NSUInteger action = [alert runModal];
    
    
    if(action == NSAlertFirstButtonReturn)
    {
        [[RulesList sharedRulesList] clear];
        [_rulesTableView reloadData];
        
    }
    else if(action == NSAlertSecondButtonReturn )
    {
        
        
    }
    
}

- (void)setupToolbar {
    [self addView:self.generalPreferenceView label:NSLocalizedString(@"General", nil) image:[NSImage imageNamed:@"General.png"]];
    [self addView:self.rulesPreferenceView label:NSLocalizedString(@"Rules", nil) image:[NSImage imageNamed:@"Rules.png"]];
    [self addView:self.filtersPrefrenceView label:NSLocalizedString(@"Filters", nil) image:[NSImage imageNamed:@"list@2x.png"]];
    [self addView:self.appleScriptPreferenceView label:NSLocalizedString(@"AppleScript", nil) image:[NSImage imageNamed:@"AppleScript_Editor_Logo.png"]];
    [self addView:self.rightClickPrefrenceView label:NSLocalizedString(@"RightClick", nil) image:[NSImage imageNamed:@"RightClick.png"]];
    [self addView:self.rightClickMenuPrefrenceView label:NSLocalizedString(@"RightClickMenu", nil) image:[NSImage imageNamed:@"RightClickMenu.png"]];
    [self addView:self.clipboardPrefrenceView label:NSLocalizedString(@"Clipboard", nil) image:[NSImage imageNamed:@"Clipboard.png"]];
    [self addFlexibleSpacer];
    [self addView:self.aboutPreferenceView label:NSLocalizedString(@"About", nil) image:[NSImage imageNamed:@"About.png"]];
    
    // Optional configuration settings.
    [self setCrossFade:[[NSUserDefaults standardUserDefaults] boolForKey:@"fade"]];
    [self setShiftSlowsAnimation:[[NSUserDefaults standardUserDefaults] boolForKey:@"shiftSlowsAnimation"]];
    
}

- (IBAction)blockFilterPickBtnDidClick:(id)sender {
    //    self.pickerWindowController = [[AppPickerWindowController alloc] initWithWindowNibName:@"AppPickerWindowController"];
    //
    //
    ////    [self.pickerWindowController  showDialog];
    //    [self.pickerWindowController  showWindow:self];
    //
    //    if([windowController generateFilter]){
    //        _blockFilter.stringValue = [windowController generateFilter];
    //        [[NSUserDefaults standardUserDefaults] setObject:[windowController generateFilter] forKey:@"blockFilter"];
    //    }
    //    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)close {
    [[NSUserDefaults standardUserDefaults] synchronize];
    [super close];
}

- (IBAction)autoStartAction:(id)sender {
    switch (self.autoStartAtLogin.state) {
        case NSOnState:
            [[NSBundle mainBundle] addToLoginItems];
            break;
        case NSOffState:
            [[NSBundle mainBundle] removeFromLoginItems];
            break;
    }
}

- (IBAction)whiteBlackRadioClicked:(id)sender {
    if (sender == self.whiteListModeRadio) {
        BWFilter.isInWhiteListMode = YES;
    } else if (sender == self.blackListModeRadio) {
        BWFilter.isInWhiteListMode = NO;
    }
    
    [self refreshFilterRadioAndTextViewState];
}

- (IBAction)filterViewGoBiggerClicked:(id)sender {
    [self changeSize:&currentFiltersWindowSizeIndex changeSizeButton:[self changeFiltersWindowSizeButton] preferenceView:[self filtersPrefrenceView]];
}

- (IBAction)filterViewApplyClicked:(id)sender {
    BWFilter.blackListText = [self.blackListTextView string];
    BWFilter.whiteListText = [self.whiteListTextView string];
    [self refreshFilterRadioAndTextViewState];
    self.blackListTextView.string = BWFilter.blackListText;
    self.whiteListTextView.string = BWFilter.whiteListText;
}

- (IBAction)filterBlackListAddClicked:(id)sender {
    self.pickerWindowController = [[AppPickerWindowController alloc] initWithWindowNibName:@"AppPickerWindowController"];
    self.pickerWindowController.addedToTextView = self.blackListTextView;
    [self.pickerWindowController showWindow:self];
}

- (IBAction)filterWhiteListAddClicked:(id)sender {
    self.pickerWindowController = [[AppPickerWindowController alloc] initWithWindowNibName:@"AppPickerWindowController"];
    self.pickerWindowController.addedToTextView = self.whiteListTextView;
    [self.pickerWindowController showWindow:self];
}

- (IBAction)colorChanged:(id)sender {
    //    SET_LINE_COLOR(self.lineColorWell.color);
    [MGOptionsDefine setLineColor:self.lineColorWell.color];
}

- (IBAction)chooseFont:(id)sender {
    NSFontManager *fontManager = [NSFontManager sharedFontManager];
    [fontManager setSelectedFont:[NSFont fontWithName:[self.fontNameTextField stringValue] size:[self.fontNameTextField floatValue]] isMultiple:NO];
    [fontManager setTarget:self];
    
    NSFontPanel *fontPanel = [fontManager fontPanel:YES];
    [fontPanel makeKeyAndOrderFront:self];
    // This allow to change note color via font panel
    [fontManager setSelectedAttributes:@{NSForegroundColorAttributeName:[MGOptionsDefine getNoteColor]} isMultiple:NO]; //must setup color AFTER displayed or it will keeps black...
}

- (void)changeFont:(nullable id)sender {
    NSFontManager *fontManager = [NSFontManager sharedFontManager];
    NSFont *font = [fontManager convertFont:[NSFont systemFontOfSize:[NSFont systemFontSize]]];
    [[NSUserDefaults standardUserDefaults] setObject:[font fontName] forKey:@"noteFontName"];
    [[NSUserDefaults standardUserDefaults] setDouble:[font pointSize] forKey:@"noteFontSize"];
}

// These two functions repond to text color change.
- (void)setColor:(NSColor *)col forAttribute:(NSString *)attr {
    if ([attr isEqualToString:@"NSColor"]) {
        [MGOptionsDefine setNoteColor:col];
    }
}

- (void)changeAttributes:(id)sender{
    NSDictionary * newAttributes = [sender convertAttributes:@{}];
    NSLog(@"attr:%@",newAttributes);
}

- (IBAction)resetDefaults:(id)sender {
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

- (IBAction)pickBtnDidClick:(id)sender {
    if ([_rulesTableView selectedRow] == -1) {
        NSUserNotification *notification = [[NSUserNotification alloc] init];
        notification.title = @"MacStroke";
        notification.informativeText = NSLocalizedString(@"Select a filter first!", nil);
        notification.soundName = NSUserNotificationDefaultSoundName;
        
        [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
        return ;
    }
    
    self.pickerWindowController = [[AppPickerWindowController alloc] initWithWindowNibName:@"AppPickerWindowController"];
    self.pickerWindowController.parentWindow = self;
    self.pickerWindowController.indexForParentWindow = [_rulesTableView selectedRow];
    [self.pickerWindowController showWindow:self];
    
    //    [windowController showDialog];
    //    if([windowController generateFilter]){
    //        [[RulesList sharedRulesList] setWildFilter:[windowController generateFilter] atIndex:index];
    //    }
    //    [[RulesList sharedRulesList] save];
    //    [_rulesTableView reloadData];
}



- (IBAction)rightClickPickBtnDidClick:(id)sender {
    if ([_rightClickTableView selectedRow] == -1) {
        NSUserNotification *notification = [[NSUserNotification alloc] init];
        notification.title = @"MacStroke";
        notification.informativeText = NSLocalizedString(@"Select a filter first!", nil);
        notification.soundName = NSUserNotificationDefaultSoundName;
        
        [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
        return ;
    }
    
    self.pickerWindowController = [[AppPickerWindowController alloc] initWithWindowNibName:@"AppPickerWindowController"];
    self.pickerWindowController.parentWindow = self;
    self.pickerWindowController.selectOne = YES;
    self.pickerWindowController.indexForParentWindow = [_rightClickTableView selectedRow];
    [self.pickerWindowController showWindow:self];
    
    
    //    [windowController showDialog];
    //    if([windowController generateFilter]){
    //        [[RulesList sharedRulesList] setWildFilter:[windowController generateFilter] atIndex:index];
    //    }
    //    [[RulesList sharedRulesList] save];
    //    [_rulesTableView reloadData];
}


- (IBAction)createAppleScript:(id)sender {
    [[AppleScriptsList sharedAppleScriptsList] addAppleScript:@"New AppleScript"
                                                       script:@""];
    [[AppleScriptsList sharedAppleScriptsList] save];
    [[self appleScriptTableView] reloadData];
    [[self appleScriptTableView] selectRowIndexes:[NSIndexSet indexSetWithIndex:[[AppleScriptsList sharedAppleScriptsList] count] - 1] byExtendingSelection:NO];
}

- (void)exampleAppleScriptSelected:(id)sender {
    NSInteger index = [sender tag];
    
    NSString* path = [[NSBundle mainBundle] pathForResource:exampleAppleScripts[index]
                                                     ofType:@"scpt"];
    NSError* error = nil;
    NSURL *scriptURL = [NSURL fileURLWithPath: path];
    NSAppleScript *as = [[NSAppleScript alloc]
                         initWithContentsOfURL: scriptURL
                         error: nil];
    ;
    
    [[AppleScriptsList sharedAppleScriptsList] addAppleScript:exampleAppleScripts[index+1]
                                                       script: [as source]];
    NSLog(@"error: %@",error);
    
    [[AppleScriptsList sharedAppleScriptsList] save];
    
    [[self appleScriptTableView] reloadData];
    [[self appleScriptTableView] selectRowIndexes:[NSIndexSet indexSetWithIndex:[[AppleScriptsList sharedAppleScriptsList] count] - 1] byExtendingSelection:NO];
}

- (IBAction)removeAppleScript:(id)sender {
    NSInteger index = [[self appleScriptTableView] selectedRow];
    if (index != -1) {
        [[AppleScriptsList sharedAppleScriptsList] removeAtIndex:index];
        [[AppleScriptsList sharedAppleScriptsList] save];
        [[self appleScriptTableView] reloadData];
        if ([[AppleScriptsList sharedAppleScriptsList] count] > 0) {
            index = MIN(index, [[AppleScriptsList sharedAppleScriptsList] count] - 1);
            [[self appleScriptTableView] selectRowIndexes:[NSIndexSet indexSetWithIndex:index] byExtendingSelection:NO];
        } else {
            [[self appleScriptTextField] setEnabled:NO];
            [[self appleScriptTextField] setStringValue:@""];
        }
        
        [[self rulesTableView] reloadData];
    }
}

static BOOL isEditing = NO;
static NSString *currentScriptPath = nil;
static NSString *currentScriptId = nil;

- (IBAction)editAppleScriptInExternalEditor:(id)sender {
    NSInteger index = [[self appleScriptTableView] selectedRow];
    if (index == -1) {
        NSUserNotification *notification = [[NSUserNotification alloc] init];
        notification.title = @"MacStroke";
        notification.informativeText = NSLocalizedString(@"Select a AppleScript first!", nil);
        notification.soundName = NSUserNotificationDefaultSoundName;
        
        [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
        return ;
    }
    
    if (!isEditing) {
        currentScriptId = [[AppleScriptsList sharedAppleScriptsList] idAtIndex:index];
        NSError *error = nil;
        
        currentScriptPath = [NSString stringWithFormat:@"%@/%@", NSTemporaryDirectory(), currentScriptId];
        [[NSFileManager defaultManager] createDirectoryAtPath:currentScriptPath withIntermediateDirectories:NO attributes:nil error:nil];
        
        currentScriptPath = [NSString stringWithFormat:@"%@/%@", currentScriptPath, @"MacStroke.applescript"];
        
        [[NSFileManager defaultManager] removeItemAtPath:currentScriptPath error:&error];
        [[[AppleScriptsList sharedAppleScriptsList] scriptAtIndex:index] writeToFile:currentScriptPath atomically:YES
                                                                            encoding:NSUTF8StringEncoding error:&error];
        [[NSWorkspace sharedWorkspace] openFile:currentScriptPath];
        
        isEditing = YES;
        [[self editInExternalEditorButton] setTitle:NSLocalizedString(@"Stop",nil)];
    } else {
        NSError *error = nil;
        NSString *content = [NSString stringWithContentsOfFile:currentScriptPath
                                                      encoding:NSUTF8StringEncoding
                                                         error:&error];
        
        if (content != nil) {
            [[AppleScriptsList sharedAppleScriptsList] setScriptAtIndex:index script:content];
            [[AppleScriptsList sharedAppleScriptsList] save];
            
            NSInteger currentIndex = [[self appleScriptTableView] selectedRow];
            NSString *currentId = [[AppleScriptsList sharedAppleScriptsList] idAtIndex:currentIndex];
            if (currentId == currentScriptId && ![content isEqualToString:[[self appleScriptTextField] stringValue]]) {
                [[self appleScriptTextField] setStringValue:content];
            }
        }
        
        isEditing = NO;
        [[self editInExternalEditorButton] setTitle:NSLocalizedString(@"Edit in External Editor",nil)];
    }
    
    [[self appleScriptTableView] setEnabled:!isEditing];
    [[self loadAppleScriptExampleButton] setEnabled:!isEditing];
    [[self addAppleScriptButton] setEnabled:!isEditing];
    [[self removeAppleScriptButton] setEnabled:!isEditing];
    [[self appleScriptTextField] setEnabled:!isEditing];
    
}

- (IBAction)appleScriptSelectionChanged:(NSNotification *)notification {
    NSComboBox *comboBox = (NSComboBox *)[notification object];
    NSInteger row = [comboBox tag];
    [[RulesList sharedRulesList] setAppleScriptId:[[AppleScriptsList sharedAppleScriptsList] idAtIndex:[comboBox indexOfSelectedItem]] atIndex:row];
}

- (IBAction)onTriggerOnEveryMatchChanged:(id)sender {
    NSButton *button = sender;
    NSInteger index = [button tag];
    [[RulesList sharedRulesList] setTriggerOnEveryMatch:[button state] atIndex:index];
}
- (IBAction)onSetGestureData:(id)sender {
    NSButton *button = sender;
    
    NSInteger index = [button tag];
    [self preSetRuleGestureAtIndex:index];
    
    
}

-(void) preSetRuleGestureAtIndex:(NSInteger)index;
{
    [[AppDelegate appDelegate] setSettingRuleIndex: index];
    
    NSString *title1 =NSLocalizedString(@"Ok", nil);
    
    NSString *title2 =NSLocalizedString(@"Cancel", nil);
    
    NSString *messagetext =NSLocalizedString(@"Draw Gesture!", nil);
    
    NSString *informativetext =NSLocalizedString(@"You can draw a gesture anywhere on the screen. If you want to cancel, click the Cancel button!", nil);
    
    [self alertModalFirstBtnTitle:title1 SecondBtnTitle:title2 MessageText:messagetext InformativeText:informativetext];
    
    
}



-(void)alertModalFirstBtnTitle:(NSString *)firstname SecondBtnTitle:(NSString *)secondname MessageText:(NSString *)messagetext InformativeText:(NSString *)informativetext{
    
    NSAlert *alert = [[NSAlert alloc] init];
    
    [alert addButtonWithTitle:firstname];
    
    [alert addButtonWithTitle:secondname];
    
    [alert setMessageText:messagetext];
    
    [alert setInformativeText:informativetext];
    
    [alert setAlertStyle:NSWarningAlertStyle];
    
    
    NSComboBox *comboBox = [[NSComboBox alloc]initWithFrame:NSMakeRect(110 , 17, 100, 25)];
    [comboBox setEditable:NO];
    
    NSArray *preArray=[[NSArray alloc]initWithObjects:
                       @"←",@"↑",@"→",@"↓",
                       @"↙",@"↗",@"↘",@"↖",
                       @"┏",@"┏ Revered",
                       @"┓",@"┓ Revered",
                       @"┗",@"┗ Revered",
                       @"┛",@"┛ Revered",
                       @"A",@"A Revered",
                       @"B",@"B Revered",
                       @"C",@"C Revered",
                       @"D",@"D Revered",
                       @"E",@"E Revered",
                       @"F",@"F Revered",
                       @"G",@"G Revered",
                       @"H",@"H Revered",
                       @"I",@"I Revered",
                       @"J",@"J Revered",
                       @"K",@"K Revered",
                       @"L",@"L Revered",
                       @"M",@"M Revered",
                       @"N",@"N Revered",
                       @"O",@"O Revered",
                       @"P",@"P Revered",
                       @"Q",@"Q Revered",
                       @"R",@"R Revered",
                       @"S",@"S Revered",
                       @"T",@"T Revered",
                       @"U",@"U Revered",
                       @"V",@"V Revered",
                       @"W",@"W Revered",
                       @"X",@"X Revered",
                       @"Y",@"Y Revered",
                       @"Z",@"Z Revered", nil];
    [comboBox addItemsWithObjectValues:preArray];
    comboBox.stringValue=@"Plase Select";
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(preGestureSelectionChanged:)
                                                 name:NSComboBoxSelectionDidChangeNotification
                                               object:comboBox];
    [comboBox setTranslatesAutoresizingMaskIntoConstraints:YES];
    
    
    [[[alert window] contentView] addSubview:comboBox];
    
    [[[alert window] contentView] autoresizesSubviews];
    
    NSUInteger action = [alert runModal];
    
    
    if(action == NSAlertFirstButtonReturn)
    {
        NSLog(@"defaultButton clicked!");
        
    }
    else if(action == NSAlertSecondButtonReturn )
    {
        //settingRuleIndex = -1;
        [[AppDelegate appDelegate] setSettingRuleIndex:-1];
        
    }
}

- (IBAction)preGestureSelectionChanged:(NSNotification *)notification {
    NSComboBox *comboBox = (NSComboBox *)[notification object];
    //NSInteger row = [comboBox tag];
    //NSLog(@"%ld",(long)row);
    
    NSInteger index_for_combox = [comboBox indexOfSelectedItem];
    NSString *m_text_combobox;
    m_text_combobox = [comboBox itemObjectValueAtIndex:index_for_combox];
    NSArray *array = [m_text_combobox componentsSeparatedByString:@" "];
    
    NSMutableArray* Gesture =[PreGesture getGestureByLetter:array[0] IsRevered:(array.count>1?YES:NO)];
    NSInteger settingRuleIndex = [[AppDelegate appDelegate] getSettingRuleIndex];
    if(settingRuleIndex>-1){
        [[RulesList sharedRulesList] setGestureData:Gesture atIndex:settingRuleIndex];
        NSUserNotification *notification = [[NSUserNotification alloc] init];
        notification.title = @"MacStroke";
        notification.informativeText = NSLocalizedString(@"Gesture draw complete!", nil);
        notification.soundName = NSUserNotificationDefaultSoundName;
        [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
        [[AppDelegate appDelegate] setSettingRuleIndex:-1];
        
        [_rulesTableView reloadData];
        [RulesList pressKeyWithFlags:kVK_Return virtualKey:kVK_Return];
        
    }
}


- (IBAction)changeActionType:(NSNotification *)notification
{
    
    NSComboBox *comboBox = (NSComboBox *)[notification object];
    
    NSInteger index_for_combox = [comboBox indexOfSelectedItem];
    
    NSInteger index = [comboBox tag];
    
    ActionType actiontype = (ActionType)index_for_combox;
    
    [[RulesList sharedRulesList]  setActionTypeWithActionType:actiontype atIndex:index];
    [_rulesTableView reloadData];
}


- (void)tableViewSelectionChanged:(NSNotification* )notification
{
    NSInteger selectedRow = [[self appleScriptTableView] selectedRow];
    
    if (selectedRow != -1) {
        [[self appleScriptTextField] setEnabled:YES];
        NSString *applescript =  [[AppleScriptsList sharedAppleScriptsList] scriptAtIndex:selectedRow];
        if (applescript == nil) {
            applescript = @"";
        }
        [[self appleScriptTextField] setStringValue:applescript];
    } else {
        [[self appleScriptTextField] setEnabled:NO];
        [[self appleScriptTextField] setStringValue:@""];
    }
}


- (IBAction)showInStatusBarCheckChanged:(id)sender {
    [[AppDelegate appDelegate] updateStatusBarItem];
}

- (IBAction)languageChanged:(id)sender {
    NSString *language = [[self languageComboBox] objectValueOfSelectedItem];
    [[NSUserDefaults standardUserDefaults] setObject:[NSArray arrayWithObject:language] forKey:@"AppleLanguages"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    NSUserNotification *notification = [[NSUserNotification alloc] init];
    notification.title = @"MacStroke";
    notification.informativeText = NSLocalizedString(@"Restart MacStroke to take effect", nil);
    notification.soundName = NSUserNotificationDefaultSoundName;
    
    [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
}

- (IBAction)onToggleMacStrokeEnabled:(id)sender {
    NSButton *button = (NSButton *)sender;
    bool enabled = [button state];
    [[AppDelegate appDelegate] setEnabled:enabled];
}

- (IBAction)doImport:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    
    if ([panel runModal] == NSOKButton) {
        NSURL *url = [panel URL];
        NSTask *task = [[NSTask alloc] init];
        [task setLaunchPath:@"/bin/sh"];
        
        NSArray *arguments = [NSArray arrayWithObjects:
                              @"-c" ,
                              @"defaults import com.codefalling.MacStroke -",
                              nil];
        
        [task setArguments:arguments];
        NSPipe *pipe = [NSPipe pipe];
        [task setStandardInput:pipe];
        
        NSFileHandle *file = [pipe fileHandleForWriting];
        
        [task launch];
        
        NSData *data = [NSData dataWithContentsOfURL:url];
        if (data) {
            [file writeData:data];
        }
        [file closeFile];
        
        NSUserNotification *notification = [[NSUserNotification alloc] init];
        notification.title = @"MacStroke";
        notification.informativeText = NSLocalizedString(@"Restart MacStroke to take effect", nil);
        notification.soundName = NSUserNotificationDefaultSoundName;
        
        [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
    }
}

- (IBAction)doExport:(id)sender {
    NSSavePanel *panel = [NSSavePanel savePanel];
    
    if ([panel runModal] == NSOKButton) {
        NSURL *url = [panel URL];
        NSTask *task = [[NSTask alloc] init];
        [task setLaunchPath:@"/bin/sh"];
        
        NSArray *arguments = [NSArray arrayWithObjects:
                              @"-c" ,
                              @"defaults export com.codefalling.MacStroke -",
                              nil];
        
        [task setArguments:arguments];
        NSPipe *pipe = [NSPipe pipe];
        [task setStandardOutput:pipe];
        
        NSFileHandle *file = [pipe fileHandleForReading];
        
        [task launch];
        
        NSData *data = [file readDataToEndOfFile];
        if (data) {
            [data writeToURL:url atomically:YES];
        }
        [file closeFile];
        
        NSUserNotification *notification = [[NSUserNotification alloc] init];
        notification.title = @"MacStroke";
        notification.informativeText = NSLocalizedString(@"Export succeeded", nil);
        notification.soundName = NSUserNotificationDefaultSoundName;
        
        [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
    }
}

#pragma mark -
#pragma mark NSComboBoxDataSource Implementation

- (NSInteger)numberOfItemsInComboBox:(NSComboBox *)aComboBox {
    return [[AppleScriptsList sharedAppleScriptsList] count];
}

- (id)comboBox:(NSComboBox *)aComboBox objectValueForItemAtIndex:(NSInteger)index {
    return [[AppleScriptsList sharedAppleScriptsList] titleAtIndex:index];
}

#pragma mark -
#pragma mark SRRecorderControlDelegate Implementation

- (void)shortcutRecorderDidEndRecording:(SRRecorderControl *)aRecorder {
    
    NSLog(@"SRRecorderControl%@",aRecorder);
    
    NSInteger id = ((SRRecorderControlWithTagid *) aRecorder).tagid;
    NSUInteger keycode = [aRecorder.objectValue[@"keyCode"] unsignedIntegerValue];
    NSUInteger flag = [[aRecorder objectValue][@"modifierFlags"] unsignedIntegerValue];
    
    [[RulesList sharedRulesList] setShortcutWithKeycode:keycode withFlag:flag atIndex:id];
}

#pragma mark -
#pragma mark NSControlTextEditingDelegate Implementation

- (BOOL)control:(NSControl *)control textShouldEndEditing:(NSText *)fieldEditor {
    // control is editfield,control.id == row,control.identifier == "Gesture"|"Filter"|Other(only saving)
    if ([control.identifier isEqualToString:@"Gesture"]) {    // edit gesture
        NSString *gesture = control.stringValue;
        NSCharacterSet *invalidGestureCharacters = [NSCharacterSet characterSetWithCharactersInString:@"ULDRZud?*"];
        invalidGestureCharacters = [invalidGestureCharacters invertedSet];
        //        if ([gesture rangeOfCharacterFromSet:invalidGestureCharacters].location != NSNotFound) {
        //            NSUserNotification *notification = [[NSUserNotification alloc] init];
        //            notification.title = @"MacStroke";
        //            notification.informativeText = NSLocalizedString(@"Gesture must only contain \"ULDRZud?*\"", nil);
        //            notification.soundName = NSUserNotificationDefaultSoundName;
        //
        //            [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
        //            return NO;
        //        }
        [control setStringValue:gesture];
        [[RulesList sharedRulesList] setDirection:gesture atIndex:control.tag];
    } else if ([control.identifier isEqualToString:@"Filter"]) {  // edit filter
        [[RulesList sharedRulesList] setWildFilter:control.stringValue atIndex:control.tag];
    } else if ([control.identifier isEqualToString:@"Note"]) {  // edit filter
        [[RulesList sharedRulesList] setNote:control.stringValue atIndex:control.tag];
    } else if ([control.identifier isEqualToString:@"Apple Script"]) {  // edit apple script
        [[AppleScriptsList sharedAppleScriptsList] setScriptAtIndex:[[self appleScriptTableView] selectedRow] script:control.stringValue];
    } else if ([control.identifier isEqualToString:@"Title"]) {  // edit title
        [[AppleScriptsList sharedAppleScriptsList] setTitleAtIndex:[[self appleScriptTableView] selectedRow] title:control.stringValue];
    } else if ([control.identifier isEqualToString:@"Text"]) {  // edit title
        [[RulesList sharedRulesList] setText:control.stringValue atIndex:control.tag];
    }
    else if ([control.identifier isEqualToString:@"Password"]) {  // edit title
        [[RulesList sharedRulesList] setPassword:control.stringValue atIndex:control.tag];
    }
    else if ([control.identifier isEqualToString:@"Appname"]) {  // edit title
        [[RightClicksList sharedRightClicksList] setAppnameAtIndex:[[self rightClickTableView] selectedRow] appname:control.stringValue];
    }
    [[RulesList sharedRulesList] save];
    [[AppleScriptsList sharedAppleScriptsList] save];
    return YES;
}

#pragma mark -
#pragma mark AppPickerCallback Implementation

- (void)rulePickCallback:(NSString *)rulesStringSplitedByStick atIndex:(NSInteger)index {
    [[RulesList sharedRulesList] setWildFilter:rulesStringSplitedByStick atIndex:index];
    [[RulesList sharedRulesList] save];
    [_rulesTableView reloadData];
}

#pragma mark -
#pragma mark AppPickerCallback Implementation
- (void)rightClickPickCallback:(NSString *)appname atIndex:(NSInteger)index {
    [[RightClicksList sharedRightClicksList] setAppnameAtIndex:index appname:appname];
    [[RightClicksList sharedRightClicksList]  save];
    [_rightClickTableView reloadData];
}


#pragma mark -
#pragma mark NSTableViewDataSource Implementation

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    if (tableView == [self rulesTableView]) {
        return [[RulesList sharedRulesList] count];
    } else if(tableView == [self appleScriptTableView]) {
        return [[AppleScriptsList sharedAppleScriptsList] count];
    }else if(tableView == [self rightClickTableView]){
        return [[RightClicksList sharedRightClicksList] count];
    }
    return 0;
}

#pragma mark -
#pragma mark NSTableViewDelegate Implementation

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    if (tableView == [self rulesTableView]) {
        return 84;
    } else {
        return 25;
    }
}

- (NSView *)tableViewForRules:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSView *result = nil;
    NSView *cloumn;
    RulesList *rulesList = [RulesList sharedRulesList];
    NSMutableArray *ruleListArr= [NSKeyedUnarchiver unarchiveObjectWithData:[rulesList nsData]];
    if ([tableColumn.identifier isEqualToString:@"Gesture"] || [tableColumn.identifier isEqualToString:@"Filter"] || [tableColumn.identifier isEqualToString:@"Note"]) {
        cloumn = [[NSView alloc] initWithFrame:self.window.frame];
        NSTextField *textField ;
        if ([tableColumn.identifier isEqualToString:@"Gesture"]) {
            textField = [[NSTextField alloc] initWithFrame:NSMakeRect(0 , 30, 100, 20)];
        }else if([tableColumn.identifier isEqualToString:@"Filter"] ){
            textField = [[NSTextField alloc] initWithFrame:NSMakeRect(0 , 30, 160, 20)];
        }else{
            
            textField = [[NSTextField alloc] initWithFrame:NSMakeRect(0 , 30, 400, 20)];
        }
        
        
        [textField.cell setWraps:YES];
        [textField.cell setScrollable:YES];
        [textField setEditable:YES];
        [textField setBezeled:NO];
        [textField setDrawsBackground:YES];
        [textField setBezelStyle:NSTextFieldSquareBezel];
        //[textField setFont:[NSFont fontWithName:@"Monaco" size:14]];
        [textField setLineBreakMode:NSLineBreakByTruncatingTail];
        if ([tableColumn.identifier isEqualToString:@"Gesture"]) {
            textField.stringValue = [rulesList directionAtIndex:row];
            textField.identifier = @"Gesture";
        } else if ([tableColumn.identifier isEqualToString:@"Filter"]) {
            textField.stringValue = [rulesList filterAtIndex:row];
            textField.identifier = @"Filter";
        } else if ([tableColumn.identifier isEqualToString:@"Note"]) {
            textField.stringValue = [rulesList noteAtIndex:row];
            textField.identifier = @"Note";
        }
        textField.delegate = self;
        textField.tag = row;
        [textField setTranslatesAutoresizingMaskIntoConstraints:YES];
        [cloumn addSubview:textField];
        result = cloumn;
    } else if ([tableColumn.identifier isEqualToString:@"Action"]) {
        cloumn = [[NSView alloc] initWithFrame:self.window.frame];
        if ([rulesList actionTypeAtIndex:row] == ACTION_TYPE_SHORTCUT) {
            SRRecorderControlWithTagid *recordView = [[SRRecorderControlWithTagid alloc] initWithFrame:NSMakeRect(0 , 27, 100, 25)];
            
            
            recordView.delegate = self;
            [recordView setAllowedModifierFlags:SRCocoaModifierFlagsMask requiredModifierFlags:0 allowsEmptyModifierFlags:YES];
            recordView.tagid = row;
            recordView.objectValue = [SRShortcut shortcutWithDictionary:@{
                @"keyCode" : @([rulesList shortcutKeycodeAtIndex:row]),
                @"modifierFlags" : @([rulesList shortcutFlagAtIndex:row]),
            }];
            [recordView setTranslatesAutoresizingMaskIntoConstraints:YES];
            [cloumn addSubview:recordView];
            result = cloumn;
        } else if ([rulesList actionTypeAtIndex:row] == ACTION_TYPE_APPLE_SCRIPT) {
            NSComboBox *comboBox = [[NSComboBox alloc]initWithFrame:NSMakeRect(0 , 27, 100, 25)];
            [comboBox setUsesDataSource:YES];
            [comboBox setDataSource:self];
            [comboBox setEditable:NO];
            [comboBox setTag:row];
            NSInteger index = [[AppleScriptsList sharedAppleScriptsList] getIndexById:[rulesList appleScriptIdAtIndex:row]];
            if (index != -1) {
                [comboBox selectItemAtIndex:index];
            }
            [[NSNotificationCenter defaultCenter] addObserver:self
                                                     selector:@selector(appleScriptSelectionChanged:)
                                                         name:NSComboBoxSelectionDidChangeNotification
                                                       object:comboBox];
            [comboBox setTranslatesAutoresizingMaskIntoConstraints:YES];
            [cloumn addSubview:comboBox];
            result = cloumn;
        }else if ([rulesList actionTypeAtIndex:row] == ACTION_TYPE_TEXT){
            
            cloumn = [[NSView alloc] initWithFrame:self.window.frame];
            NSTextField *textField = [[NSTextField alloc] initWithFrame:NSMakeRect(0 , 30, 100, 20)];
            
            [textField.cell setWraps:YES];
            [textField.cell setScrollable:YES];
            [textField setEditable:YES];
            [textField setBezeled:NO];
            [textField setDrawsBackground:YES];
            [textField setBezelStyle:NSTextFieldSquareBezel];
            
            //[textField setFont:[NSFont fontWithName:@"Monaco" size:14]];
            [textField setLineBreakMode:NSLineBreakByTruncatingTail];
            
            textField.stringValue = [rulesList textAtIndex:row];
            textField.identifier = @"Text";
            textField.delegate = self;
            textField.tag = row;
            [textField setTranslatesAutoresizingMaskIntoConstraints:YES];
            [cloumn addSubview:textField];
            result = cloumn;
            
            
        }else if ([rulesList actionTypeAtIndex:row] == ACTION_TYPE_PASSWORD){
            cloumn = [[NSView alloc] initWithFrame:self.window.frame];
            NSSecureTextField *textField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0 , 30, 100, 20)];
            
            [textField.cell setWraps:YES];
            [textField.cell setScrollable:YES];
            [textField setEditable:YES];
            [textField setBezeled:NO];
            [textField setDrawsBackground:YES];
            [textField setBezelStyle:NSTextFieldSquareBezel];
            //[textField setFont:[NSFont fontWithName:@"Monaco" size:14]];
            [textField setLineBreakMode:NSLineBreakByTruncatingTail];
            
            textField.stringValue = [rulesList passwordAtIndex:row];
            textField.identifier = @"Password";
            textField.delegate = self;
            textField.tag = row;
            [textField setTranslatesAutoresizingMaskIntoConstraints:YES];
            [cloumn addSubview:textField];
            result = cloumn;
            
        }
    } else if ([tableColumn.identifier isEqualToString:@"TriggerOnEveryMatch"]) {
        cloumn = [[NSView alloc] initWithFrame:self.window.frame];
        NSButton *checkButton = [[NSButton alloc] init];
        [checkButton setButtonType:NSSwitchButton];
        [checkButton setState:[rulesList triggerOnEveryMatchAtIndex:row]];
        [checkButton setTag:row];
        [checkButton setAction:@selector(onTriggerOnEveryMatchChanged:)];
        [checkButton setImagePosition:NSImageOnly];
        
        result = checkButton;
    }else if ([tableColumn.identifier isEqualToString:@"Gesture_Image"]) {
        NSMutableArray *ruleGestureData= [[ruleListArr objectAtIndex:row] objectForKey:@"data"];
        
        if ([ruleGestureData count]>0) {
            DrawGesture *drawGesture = [[DrawGesture alloc] initWithFrame:self.window.frame atRow:row atAppPrefsWindowController:self];
            [drawGesture setPoints:ruleGestureData];
            result = drawGesture;
        }else{
            NSButton *addButton = [[NSButton alloc] initWithFrame:NSMakeRect(0 , 28, 80, 25)] ;
            [addButton setTag:row];
            [addButton setBezelStyle:NSTexturedSquareBezelStyle];
            
            [addButton setAction:@selector(onSetGestureData:)];
            [addButton setTitle:NSLocalizedString(@"Draw Gesture", nil)];
            [addButton setTranslatesAutoresizingMaskIntoConstraints:YES];
            result = addButton;
        }
        
        
        
    }else if ([tableColumn.identifier isEqualToString:@"Type"]) {
        cloumn = [[NSView alloc] initWithFrame:self.window.frame];
        
        NSComboBox *comboBox = [[NSComboBox alloc]initWithFrame:NSMakeRect(0 , 25, 90, 27)];
        [comboBox setEditable:NO];
        [comboBox setTag:row];
        
        NSArray *preArray=[[NSArray alloc]initWithObjects:
                           NSLocalizedString(@"Hot Key", nil),
                           NSLocalizedString(@"Apple Script", nil),
                           NSLocalizedString(@"Text", nil),
                           NSLocalizedString(@"Password", nil),
                           nil];
        [comboBox addItemsWithObjectValues:preArray];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(changeActionType:)
                                                     name:NSComboBoxSelectionDidChangeNotification
                                                   object:comboBox];
        
        switch ([rulesList actionTypeAtIndex:row]) {
            case ACTION_TYPE_SHORTCUT:
                comboBox.stringValue=NSLocalizedString(@"Hot Key", nil);
                break;
            case ACTION_TYPE_APPLE_SCRIPT:
                comboBox.stringValue=NSLocalizedString(@"Apple Script", nil);
                break;
            case ACTION_TYPE_TEXT:
                comboBox.stringValue=NSLocalizedString(@"Text", nil);
                break;
            case ACTION_TYPE_PASSWORD:
                comboBox.stringValue=NSLocalizedString(@"Password", nil);
                break;
            default:
                break;
        }
        [cloumn addSubview:comboBox];
        //[comboBox ];
        result = cloumn;
        
    }
    return result;
}

- (NSView *)tableViewForAppleScripts:(NSTableColumn *)tableColumn row:(NSInteger)row {
    AppleScriptsList *appleScriptsList = [AppleScriptsList sharedAppleScriptsList];
    NSTextField *textField = [[NSTextField alloc] init];
    [textField.cell setWraps:NO];
    [textField.cell setScrollable:YES];
    [textField setEditable:YES];
    [textField setBezeled:NO];
    [textField setDrawsBackground:NO];
    [textField setDelegate:self];
    [textField setLineBreakMode:NSLineBreakByTruncatingMiddle];
    [textField setStringValue:[appleScriptsList titleAtIndex:row]];
    [textField setIdentifier:@"Title"];
    return textField;
}
 
- (NSView *)tableViewForRightClicks:(NSTableColumn *)tableColumn row:(NSInteger)row {
    RightClicksList *rightClicksList = [RightClicksList sharedRightClicksList];
    NSTextField *textField = [[NSTextField alloc] init];
    [textField.cell setWraps:NO];
    [textField.cell setScrollable:YES];
    [textField setEditable:YES];
    [textField setBezeled:NO];
    [textField setDrawsBackground:NO];
    [textField setDelegate:self];
    [textField setLineBreakMode:NSLineBreakByTruncatingMiddle];
    [textField setStringValue:[rightClicksList appnameAtIndex:row]];
    [textField setIdentifier:@"Appname"];
    return textField;
}
- (IBAction)createRightClick:(id)sender {
    RightClicksList *rightClicksList =  [RightClicksList sharedRightClicksList];
    [rightClicksList addRightClicks:@"appname"];
    [rightClicksList save];
    NSLog(@"removeRightClick count:%ld",(long)[rightClicksList count]);
    [_rightClickTableView reloadData];
    [_rightClickTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:[rightClicksList count] - 1] byExtendingSelection:NO];
}

- (IBAction)resetRightClick:(id)sender {
    RightClicksList *rightClicksList =  [RightClicksList sharedRightClicksList];
    [rightClicksList reInit];
    [rightClicksList save];
    [_rightClickTableView reloadData];
    [_rightClickTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:[rightClicksList count] - 1] byExtendingSelection:NO];
}


- (IBAction)removeRightClick:(id)sender {
    NSInteger index = [[self rightClickTableView] selectedRow];
    
    RightClicksList *rightClicksList =  [RightClicksList sharedRightClicksList];
    if (index != -1) {
        [rightClicksList removeAtIndex:index];
        [rightClicksList save];
        [_rightClickTableView reloadData];
        if ([rightClicksList count] > 0) {
            index = MIN(index, [rightClicksList count] - 1);
            [_rightClickTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:index] byExtendingSelection:NO];
        }
    }
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (tableView == [self rulesTableView]) {
        return [self tableViewForRules:tableColumn row:row];
    } else if (tableView == [self appleScriptTableView]) {
        return [self tableViewForAppleScripts:tableColumn row:row];
    }else if (tableView == [self rightClickTableView]) {
        return [self tableViewForRightClicks:tableColumn row:row];
    }
    return nil;
}

- (IBAction)onToggleRightClickMenu:(id)sender{
    //
    //    NSButton *button = (NSButton *)sender;
    //    bool enabled = [button state];
    //    [[self enableNewFileButton] setEnabled:enabled];
    //    [[self enableOpenInTerminalButton] setEnabled:enabled];
    //    [[self enablecopyFilePathButton] setEnabled:enabled];
    [[AppDelegate appDelegate] initRightClickMenu];
}

- (IBAction)onToggleClipboard:(id)sender{
    [[AppDelegate appDelegate] initHistoryClipboard];
}
- (IBAction)onToggleNewFile:(id)sender {
    [[AppDelegate appDelegate] initRightClickMenu];
}
- (IBAction)onChangeTerminal:(id)sender {
    if(sender == self.useItermRadio ){
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"useIterm"];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"useTerminal"];
    }else{
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"useIterm"];
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"useTerminal"];
    }
}


- (IBAction)changeStroageLocalction:(NSButton *)sender {
#ifdef DEBUG
    NSLog(@"changeStroageLocalction tag:%ld" , (long)[sender tag]);
#endif
    switch ([sender tag]) {
        case 0:
            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"clipoardStroageRam"];
            [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"clipoardStroageLocal"];            break;
        case 1:
            [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"clipoardStroageRam"];
            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"clipoardStroageLocal"];            break;
        default:
            break;
    }
    
    [self onToggleClipboard:sender];
}

- (void)initCilpboardShotCut{
    NSUserDefaultsController *defaults = NSUserDefaultsController.sharedUserDefaultsController;
    NSString *keyPath = @"values.historyCilpboardListShortcut";
    NSDictionary *options = @{NSValueTransformerNameBindingOption: NSKeyedUnarchiveFromDataTransformerName};
    
    SRRecorderControl *recorder = [SRRecorderControl new];
    [recorder bind:NSValueBinding toObject:defaults withKeyPath:keyPath options:options];
    
    [recorder bind:NSEnabledBinding toObject:defaults withKeyPath:@"values.enableHistoryClipboard" options:nil];
        
    [_keyboardShortcut addSubview:recorder];
}

@end
