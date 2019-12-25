//
//  FinderService.m
//  FinderService
//
//  Created by MTJO on 2019/12/23.
//  Copyright © 2019 Chivalry Software. All rights reserved.
//

#import "FinderService.h"

@implementation FinderService

// This implements the example protocol. Replace the body of this class with the implementation of this service's protocol.
- (void)upperCaseString:(NSString *)aString withReply:(void (^)(NSString *))reply {
    NSString *response = [aString uppercaseString];
    NSLog(@"upperCaseString:%@", aString);
    system("open -F -n -a Terminal ~/docker");
    reply(response);
}


- (void)openInTerminal:(NSString *)aString withReply:(void (^)(NSString *))reply {
    NSString *response = [aString uppercaseString];
    system("open -F -n -a Terminal ~/docker");
    reply(response);
}




@end
