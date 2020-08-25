//
// Created by codefalling on 15/10/17.
// Copyright (c) 2015 Chivalry Software. All rights reserved.
//


#import "RulesList.h"
#import "AppleScriptsList.h"
#import <Carbon/Carbon.h>
#import "utils.h"
#import "PreGesture.h"

@implementation RulesList {

}

NSMutableArray<NSMutableDictionary *> *_rulesList;  // private

- (NSString *)directionAtIndex:(NSUInteger)index {
    return _rulesList[index][@"direction"];
}

- (NSString *)filterAtIndex:(NSUInteger)index {
    return _rulesList[index][@"filter"];
}

- (FilterType)filterTypeAtIndex:(NSUInteger)index {
    return (FilterType) [_rulesList[index][@"filterType"] integerValue];
}

- (ActionType)actionTypeAtIndex:(NSUInteger)index {
    return (ActionType) [_rulesList[index][@"actionType"] integerValue];
}

- (NSUInteger)shortcutKeycodeAtIndex:(NSUInteger)index {
    NSUInteger keycode = [_rulesList[index][@"shortcut_code"] unsignedIntegerValue];
    return keycode;
}

- (NSUInteger)shortcutFlagAtIndex:(NSUInteger)index {
    NSUInteger flag = [_rulesList[index][@"shortcut_flag"] unsignedIntegerValue];
    return flag;
}

- (NSString *)appleScriptIdAtIndex:(NSUInteger)index {
    return _rulesList[index][@"apple_script_id"];
}

- (NSString *)dataAtIndex:(NSUInteger)index {
    return _rulesList[index][@"data"];
}

- (NSString *)textAtIndex:(NSUInteger)index {
    return _rulesList[index][@"text"];
}

- (NSString *)passwordAtIndex:(NSUInteger)index {
    return _rulesList[index][@"password"];
}

- (NSInteger)count {
    return [_rulesList count];
}

- (void)clear {
    [_rulesList removeAllObjects];
    [self save];
}

- (void)save {
    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
    [userDefaults setObject:self.nsData forKey:@"rules"];
    [userDefaults synchronize];
}

+ (id)readRulesList {
    id result;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    result = [defaults objectForKey:@"rules"];
    
    return result;
}

static inline void addWildcardShortcutRule(RulesList *rulesList,
                                           NSString *gesture,
                                           NSMutableArray *gestureData,
                                           ActionType actiontype,
                                           NSInteger keycode,
                                           NSInteger flag,
                                           NSString *text,
                                           NSString *password,
                                           NSString *note) {
    [rulesList addRuleWithDirection:gesture gestureData:gestureData filter:@"*" filterType:FILTER_TYPE_WILDCARD actionType:actiontype shortcutKeyCode:keycode shortcutFlag: flag appleScriptId:nil text:text password:password note:note];
}

- (void)reInit {
    [self clear];
    NSMutableArray *Gesture;
    
    
    //P Revered
    Gesture=[PreGesture getGestureByLetter:@"P" IsRevered:YES];
    addWildcardShortcutRule(self, @"password", Gesture, ACTION_TYPE_PASSWORD, kVK_ANSI_W, NSCommandKeyMask, @"",@"12345678", @"input password");
    
    //M
    Gesture=[PreGesture getGestureByLetter:@"M" IsRevered:NO];
    addWildcardShortcutRule(self, @"Email", Gesture, ACTION_TYPE_TEXT, kVK_ANSI_W, NSCommandKeyMask, @"mtjo.net@gmail.com",@"", @"input e-mail");
    
    //@"←"
    Gesture=[PreGesture getGestureByLetter:@"←" IsRevered:NO];
    addWildcardShortcutRule(self, @"Back",Gesture, ACTION_TYPE_SHORTCUT, kVK_LeftArrow, NSCommandKeyMask, @"",@"", @"Back");
    
    
    //@"←",@"↑",@"→",@"↓",
    //@"→"
    Gesture=[PreGesture getGestureByLetter:@"→" IsRevered:NO];
    addWildcardShortcutRule(self, @"Next",Gesture,ACTION_TYPE_SHORTCUT,kVK_RightArrow, NSCommandKeyMask, @"",@"", @"Next");
    
    //@"↘"
    Gesture=[PreGesture getGestureByLetter:@"↘" IsRevered:NO];
    addWildcardShortcutRule(self, @"MinSizeAll", Gesture, ACTION_TYPE_SHORTCUT, kVK_ANSI_M, NSCommandKeyMask|NSAlternateKeyMask, @"",@"", @"Min Size All Windows");
    
    
    //@"↙"
    Gesture=[PreGesture getGestureByLetter:@"↙" IsRevered:NO];
    addWildcardShortcutRule(self, @"MinSize", Gesture, ACTION_TYPE_SHORTCUT, kVK_ANSI_M, NSCommandKeyMask, @"",@"", @"Min Size Windows");
    
    //@"↙",@"↗",@"↘",@"↖"
    //@"↗"
    Gesture=[PreGesture getGestureByLetter:@"↗" IsRevered:NO];
    addWildcardShortcutRule(self, @"FullScreen", Gesture, ACTION_TYPE_SHORTCUT, kVK_ANSI_F, NSCommandKeyMask|NSControlKeyMask, @"",@"", @"Full screen");
    
    //L Reversed
    Gesture=[PreGesture getGestureByLetter:@"L" IsRevered:YES];
    addWildcardShortcutRule(self, @"Exit", Gesture, ACTION_TYPE_SHORTCUT, kVK_ANSI_Q, NSCommandKeyMask, @"",@"", @"Exit App");
    
    
    //L
    Gesture=[PreGesture getGestureByLetter:@"L" IsRevered:NO];
    addWildcardShortcutRule(self, @"CloseTab", Gesture,ACTION_TYPE_SHORTCUT, kVK_ANSI_W, NSCommandKeyMask, @"",@"", @"Close Tab");
    
    
    //V
    Gesture = [PreGesture getGestureByLetter:@"V" IsRevered:NO];
    addWildcardShortcutRule(self, @"Paste",Gesture,ACTION_TYPE_SHORTCUT, kVK_ANSI_V,NSCommandKeyMask, @"",@"", @"Paste");
    
    
    
    //A
    Gesture = [PreGesture getGestureByLetter:@"A" IsRevered:NO];
    addWildcardShortcutRule(self, @"SelectAll",Gesture,ACTION_TYPE_SHORTCUT, kVK_ANSI_A,NSCommandKeyMask, @"",@"", @"SelectALL");
    
    
    //I Reversed
    Gesture = [PreGesture getGestureByLetter:@"I" IsRevered:YES];
    addWildcardShortcutRule(self, @"PageUp",Gesture,ACTION_TYPE_SHORTCUT, kVK_PageUp, kVK_PageUp, @"",@"", @"PageUp");
    
    
    //I
    Gesture = [PreGesture getGestureByLetter:@"I" IsRevered:NO];
    addWildcardShortcutRule(self, @"PageDown",Gesture,ACTION_TYPE_SHORTCUT, kVK_PageDown,kVK_PageDown, @"",@"", @"PageDown");
    
    
    //T Revered
    Gesture=[PreGesture getGestureByLetter:@"T" IsRevered:NO];
    addWildcardShortcutRule(self, @"PrevTab", Gesture,ACTION_TYPE_SHORTCUT, kVK_ANSI_LeftBracket, NSShiftKeyMask|NSCommandKeyMask, @"",@"", @"Prev Tab");
    
    
    //F Revered
    Gesture=[PreGesture getGestureByLetter:@"F" IsRevered:YES];
    addWildcardShortcutRule(self, @"NextTab", Gesture,ACTION_TYPE_SHORTCUT, kVK_ANSI_RightBracket, NSShiftKeyMask|NSCommandKeyMask, @"",@"", @"Next Tab");
    
    
    
    
}

+ (RulesList *)sharedRulesList {
    static dispatch_once_t pred;
    static RulesList *rulesList = nil;
    dispatch_once(&pred, ^{
        rulesList = [[RulesList alloc] init];
    });
    
    NSData *data;
    if ((data = [self readRulesList])) {
        rulesList = [[RulesList alloc] initWithNsData:data];
    }
    if (rulesList == nil) {
        rulesList = [[RulesList alloc] init];
        [rulesList reInit];
        [rulesList save];
    }
    return rulesList;
}
+(void)pressKeyWithFlags:(CGEventFlags)flags virtualKey:(CGKeyCode)virtualKey;{
    pressKeyWithFlags(virtualKey, flags);
    
}
static inline void pressKeyWithFlags(CGKeyCode virtualKey, CGEventFlags flags) {
    CGEventRef event = CGEventCreateKeyboardEvent(NULL, virtualKey, true);
    CGEventSetFlags(event, flags);
    CGEventPost(kCGSessionEventTap, event);
    CFRelease(event);
    
    event = CGEventCreateKeyboardEvent(NULL, virtualKey, false);
    CGEventSetFlags(event, flags);
    CGEventPost(kCGSessionEventTap, event);
    CFRelease(event);
}

- (bool)executeActionAt:(NSUInteger)index {
    NSAppleScript *script;
    NSString *appleScriptId;
    NSString *appleScript;
    NSDictionary *errorDict;
    NSAppleEventDescriptor *returnDescriptor;
    switch ([self actionTypeAtIndex:index]) {
        case ACTION_TYPE_SHORTCUT:
            pressKeyWithFlags([self shortcutKeycodeAtIndex:index], [self shortcutFlagAtIndex:index]);
            break;
        case ACTION_TYPE_APPLE_SCRIPT:
            appleScriptId = [self appleScriptIdAtIndex:index];
            appleScript = [[AppleScriptsList sharedAppleScriptsList] getScriptById:appleScriptId];
            script = [[NSAppleScript alloc] initWithSource:appleScript];
            returnDescriptor = [script executeAndReturnError:&errorDict];
            if (errorDict != nil) {
                NSLog(@"Execute Apple Script: returnDescriptor: %@, errorDict: %@", returnDescriptor, errorDict);
                NSUserNotification *userNotification = [[NSUserNotification alloc] init];
                userNotification.title = @"MacStroke AppleScript Error";
                userNotification.informativeText = errorDict[NSAppleScriptErrorMessage];
                [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:userNotification];
            }
            break;
        case ACTION_TYPE_TEXT:
            typeSting([self textAtIndex:index]);
            break;
        case ACTION_TYPE_PASSWORD:
            typeSting([self passwordAtIndex:index]);
            break;
        default:
            break;
    }
    return YES;
}

- (NSInteger)suitedRuleWithGesture:(NSString *)gesture {
    NSString *frontApp = frontBundleName();
    for (NSUInteger i = 0; i < [self count]; i++) {
        if ([self matchFilter:frontApp atIndex:i]) {
            //if ([gesture isEqualToString:[self directionAtIndex:i]]) {
            if (wildcardString(gesture, [self directionAtIndex:i], NO)) {
                return i;
            }
        }
    }
    return -1;
}

- (BOOL)appSuitedRule:(NSString*)bundleId {
    for (NSUInteger i = 0; i < [self count]; i++) {
        if ([self matchFilter:bundleId atIndex:i]) {
            return YES;
        }
    }
    return NO;
}

- (bool)handleGesture:(NSInteger)Index isLastGesture:(BOOL)last {
    // if last, only match rules without trigger_on_every_match
    // if last = false, only match rules with trigger_on_every_match
    if(Index<0){
        return NO;
    }
    if (last) {
        [self executeActionAt:Index];
        return YES;
    }
    
    return NO;
}


- (NSString *)noteAtIndex:(NSUInteger)index {
    NSString *value = _rulesList[index][@"note"];
    return value ? value : @"";
}

- (BOOL)triggerOnEveryMatchAtIndex:(NSUInteger)index {
    NSNumber *b = _rulesList[index][@"trigger_on_every_match"];
    return [b boolValue];
}

- (void)setTriggerOnEveryMatch:(BOOL)match atIndex:(NSUInteger)index {
    _rulesList[index][@"trigger_on_every_match"] = [[NSNumber alloc] initWithBool:match];
    [self save];
}

- (void)setGestureData:(NSMutableArray*)data atIndex:(NSUInteger)index {
    _rulesList[index][@"data"] = data;
    [self save];
}

- (void)setNote:(NSString *)note atIndex:(NSUInteger)index {
    _rulesList[index][@"note"] = note;
    [self save];
}

- (void)setText:(NSString *)text atIndex:(NSUInteger)index {
    _rulesList[index][@"text"] = text;
    [self save];
}

- (void)setPassword:(NSString *)password atIndex:(NSUInteger)index {
    _rulesList[index][@"password"] = password;
    [self save];
}

- (void)setAppleScriptId:(NSString *)id atIndex:(NSUInteger)index {
    _rulesList[index][@"apple_script_id"] = id;
    [self save];
}

- (void)addRuleWithDirection:(NSString *)direction
                 gestureData:(NSMutableArray*)gestureData
                      filter:(NSString *)filter
                  filterType:(FilterType)filterType
                  actionType:(ActionType)actionType
             shortcutKeyCode:(NSUInteger)shortcutKeyCode
                shortcutFlag:(NSUInteger)shortcutFlag
               appleScriptId:(NSString *)appleScriptId
                        text:(NSString *)text
                    password:(NSString*)password
                        note:(NSString *)note; {
    NSMutableDictionary *rule = [[NSMutableDictionary alloc] init];
    rule[@"direction"] = direction;
    rule[@"data"]=gestureData;
    rule[@"filter"] = filter;
    rule[@"filterType"] = @(filterType);
    rule[@"actionType"] = @(actionType);
    rule[@"text"] = text;
    rule[@"password"] = password;
    if (actionType == ACTION_TYPE_SHORTCUT) {
        rule[@"shortcut_code"] = @(shortcutKeyCode);
        rule[@"shortcut_flag"] = @(shortcutFlag);
        
    } else if (actionType == ACTION_TYPE_APPLE_SCRIPT) {
        rule[@"apple_script_id"] = appleScriptId;
    }
    rule[@"note"] = note;
    [_rulesList insertObject:rule atIndex:0];
    [self save];
}

-(void)setActionTypeWithActionType:(ActionType)actonType atIndex:(NSUInteger)index
{
    _rulesList[index][@"actionType"] = @(actonType);
    [self save];
}

- (void)removeRuleAtIndex:(NSInteger)index {
    [_rulesList removeObjectAtIndex:index];
    [self save];
}

- (void)setShortcutWithKeycode:(NSUInteger)keycode withFlag:(NSUInteger)flag atIndex:(NSUInteger)index {
    _rulesList[index][@"shortcut_code"] = @(keycode);
    _rulesList[index][@"shortcut_flag"] = @(flag);
    _rulesList[index][@"actionType"] = @(ACTION_TYPE_SHORTCUT);
    [self save];
}

- (void)setWildFilter:(NSString *)filter atIndex:(NSUInteger)index {
    _rulesList[index][@"filter"] = filter;
    _rulesList[index][@"filterType"] = @(FILTER_TYPE_WILDCARD);
    [self save];
}

- (void)setRegexFilter:(NSString *)filter atIndex:(NSUInteger)index {
    _rulesList[index][@"filter"] = filter;
    _rulesList[index][@"filterType"] = @(FILTER_TYPE_REGEX);
    [self save];
}

- (BOOL)matchFilter:(NSString *)text atIndex:(NSUInteger)index {
    NSRegularExpression *regex;
    NSError *error;
    switch ([self filterTypeAtIndex:index]) {
        case FILTER_TYPE_REGEX:
            // need ignore case here
            regex = [NSRegularExpression regularExpressionWithPattern:[self filterAtIndex:index] options:0 error:&error];
            if ([regex firstMatchInString:text options:0 range:NSMakeRange(0, [text length])]) {
                return YES;
            }
            break;
        case FILTER_TYPE_WILDCARD:
            return wildcardString(text, [self filterAtIndex:index], YES);
            break;
    }
    return NO;
}

- (void)setDirection:(NSString *)direction atIndex:(NSUInteger)index {
    _rulesList[index][@"direction"] = direction;
    [self save];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _rulesList = [[NSMutableArray alloc] init];
    }
    
    return self;
}

- (NSData *)nsData {
    return [NSKeyedArchiver archivedDataWithRootObject:_rulesList];
}

- (RulesList *)initWithNsData:(NSData *)data {
    self = [self init];
    if (self) {
        _rulesList = [[NSMutableArray alloc] initWithArray:[NSKeyedUnarchiver unarchiveObjectWithData:data]];
    }
    
    return self;
}
static inline void typeSting(NSString *string) {
    UniCharCount stringLength = string.length;
    UniChar *unicodeString = (UniChar *)malloc(sizeof(UniChar) * stringLength);
    [string getCharacters:unicodeString range:NSMakeRange(0, stringLength)];
    
    CGEventRef event = CGEventCreateKeyboardEvent(NULL, 0, true);
    CGEventKeyboardSetUnicodeString(event, stringLength, unicodeString);
    CGEventPost(kCGSessionEventTap, event);
    CFRelease(event);
    
    event = CGEventCreateKeyboardEvent(NULL, 0, false); // not sure whether it's needed
    CGEventKeyboardSetUnicodeString(event, stringLength, unicodeString);
    CGEventPost(kCGSessionEventTap, event);
    CFRelease(event);
    free(unicodeString);
}

@end
