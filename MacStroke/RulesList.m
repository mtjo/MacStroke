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

- (NSInteger)count {
    return [_rulesList count];
}

- (void)clear {
    [_rulesList removeAllObjects];
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

+ (void)setRuleIdex:(NSInteger) index;{
    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
    [userDefaults setInteger:index forKey:@"rule_index"];
    [userDefaults synchronize];
}

+ (NSInteger)getRuleIdex;{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return  [defaults integerForKey:@"rule_index"];
}

static inline void addWildcardShortcutRule(RulesList *rulesList, NSString *gesture, NSMutableArray *gestureData, NSInteger keycode, NSInteger flag, NSString *note) {
    [rulesList addRuleWithDirection:gesture gestureData:gestureData filter:@"*" filterType:FILTER_TYPE_WILDCARD actionType:ACTION_TYPE_SHORTCUT shortcutKeyCode:keycode shortcutFlag: flag appleScriptId:nil note:note];
}

- (void)reInit {
    [self clear];
    NSMutableArray *Gesture;
    
    //F Revered
    Gesture=[PreGesture getGestureByLetter:@"F" IsRevered:YES];
    addWildcardShortcutRule(self, @"NextTab", Gesture, kVK_ANSI_RightBracket, NSShiftKeyMask|NSCommandKeyMask, @"Next Tab");
    //T Revered
    Gesture=[PreGesture getGestureByLetter:@"T" IsRevered:NO];
    addWildcardShortcutRule(self, @"PrevTab", Gesture, kVK_ANSI_LeftBracket, NSShiftKeyMask|NSCommandKeyMask, @"Prev Tab");
    //I
    Gesture = [PreGesture getGestureByLetter:@"I" IsRevered:NO];
    addWildcardShortcutRule(self, @"PageDown",Gesture, kVK_PageDown,kVK_PageDown, @"PageDown");
    
    //I Reversed
    Gesture = [PreGesture getGestureByLetter:@"I" IsRevered:YES];
    addWildcardShortcutRule(self, @"PageUp",Gesture, kVK_PageUp, kVK_PageUp, @"PageUp");
    
    //A
    Gesture = [PreGesture getGestureByLetter:@"A" IsRevered:NO];
    addWildcardShortcutRule(self, @"SelectAll",Gesture, kVK_ANSI_A,NSCommandKeyMask, @"SelectALL");
    
    //V
    Gesture = [PreGesture getGestureByLetter:@"V" IsRevered:NO];
    addWildcardShortcutRule(self, @"Paste",Gesture, kVK_ANSI_V,NSCommandKeyMask, @"Paste");
    
    //L
    Gesture=[PreGesture getGestureByLetter:@"L" IsRevered:NO];
    addWildcardShortcutRule(self, @"CloseTab", Gesture, kVK_ANSI_W, NSCommandKeyMask, @"Close Tab");
    
    //L Reversed
    Gesture=[PreGesture getGestureByLetter:@"L" IsRevered:YES];
    addWildcardShortcutRule(self, @"Exit", Gesture, kVK_ANSI_Q, NSCommandKeyMask, @"Exit App");
    
    //top right corner
    int x,y;
    NSMutableArray *top_right_corner = [[NSMutableArray alloc] init];
    x=200;
    y=200;
    for (int i=0; i<60; i++) {
        [top_right_corner addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
        x=y=y+i;
        
    }
    addWildcardShortcutRule(self, @"FullScreen", top_right_corner, kVK_ANSI_F, NSCommandKeyMask|NSControlKeyMask, @"Full screen");
    
    
    //bottom left corner
    NSMutableArray *bottom_left_corner = [[NSMutableArray alloc] init];
    x=200;
    y=200;
    for (int i=0; i<60; i++) {
        [bottom_left_corner addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
        x=y=y-i;
        
    }
    addWildcardShortcutRule(self, @"MinSize", bottom_left_corner, kVK_ANSI_M, NSCommandKeyMask, @"Min Size Windows");
    
    //bottom left corner
    NSMutableArray *bottom_right_corner = [[NSMutableArray alloc] init];
    x=200;
    y=200;
    for (int i=0; i<60; i++) {
        [bottom_right_corner addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
        x=x+i;
        y=y-i;
        
    }
    
    addWildcardShortcutRule(self, @"MinSizeAll", bottom_right_corner, kVK_ANSI_M, NSCommandKeyMask|NSAlternateKeyMask, @"Min Size All Windows");
    
    
    
    //R
    NSMutableArray *R = [[NSMutableArray alloc] init];
    x=200;
    y=200;
    for (int i=0; i<30; i++) {
        [R addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
        x=x+i;
    }
    
    addWildcardShortcutRule(self, @"Next",R,kVK_RightArrow, NSCommandKeyMask, @"Next");
    
    //L
    NSMutableArray *L = [[NSMutableArray alloc] init];
    x=200;
    y=200;
    for (int i=0; i<30; i++) {
        [L addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
        x=x-i;
    }
    addWildcardShortcutRule(self, @"Back",L, kVK_LeftArrow, NSCommandKeyMask, @"Back");
    


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
        case ACTION_TYPE_STRING:
            typeSting(@"aaa");
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
                        note:(NSString *)note; {
    NSMutableDictionary *rule = [[NSMutableDictionary alloc] init];
    rule[@"direction"] = direction;
    rule[@"data"]=gestureData;
    rule[@"filter"] = filter;
    rule[@"filterType"] = @(filterType);
    rule[@"actionType"] = @(actionType);
    if (actionType == ACTION_TYPE_SHORTCUT) {
        rule[@"shortcut_code"] = @(shortcutKeyCode);
        rule[@"shortcut_flag"] = @(shortcutFlag);

    } else if (actionType == ACTION_TYPE_APPLE_SCRIPT) {
        rule[@"apple_script_id"] = appleScriptId;
    }
    rule[@"note"] = note;
    [_rulesList addObject:rule];
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
