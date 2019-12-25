//
//  FinderService.h
//  FinderService
//
//  Created by MTJO on 2019/12/23.
//  Copyright © 2019 Chivalry Software. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "FinderServiceProtocol.h"

// This object implements the protocol which we have defined. It provides the actual behavior for the service. It is 'exported' by the service to make it available to the process hosting the service over an NSXPCConnection.
@interface FinderService : NSObject <FinderServiceProtocol>
@end
