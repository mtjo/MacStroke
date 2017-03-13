//
//  PreGesture.h
//  MacStroke
//
//  Created by MTJO on 2017/2/25.
//  Copyright © 2017年 Chivalry Software. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface PreGesture : NSObject
+ (NSMutableArray*)getGestureByLetter:(NSString*)Letter IsRevered:(BOOL)Revered;
@end
