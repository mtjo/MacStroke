//
//  BtDelegate.h
//  MacStroke
//
//  Created by MTJO on 2019/6/5.
//  Copyright © 2019 Chivalry Software. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreServices/CoreServices.h>
#import <IOBluetooth/objc/IOBluetoothDeviceInquiry.h>
#import <IOBluetooth/IOBluetoothUserLib.h>
#import <IOBluetoothUI/IOBluetoothUIUserLib.h>
#import <IOBluetooth/IOBluetooth.h>
#import <IOBluetoothUI/IOBluetoothUI.h>

@protocol BtGetter

-(void)found;

@end

@interface BtDelegate : NSObject <IOBluetoothDeviceInquiryDelegate>

@property (nonatomic) NSArray *devices;
@property (weak) id<BtGetter> delegate;
@end
