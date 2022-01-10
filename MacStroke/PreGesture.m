//
//  PreGesture.m
//  MacStroke
//
//  Created by MTJO on 2017/2/25.
//  Copyright © 2017年 Chivalry Software. All rights reserved.
//

#import "PreGesture.h"

@implementation PreGesture

+ (NSMutableArray*)getGestureByLetter:(NSString*)Letter IsRevered:(BOOL)Revered;
{
    NSArray *Letters = [NSArray arrayWithObjects:@"A",@"B",@"C",@"D",@"E",@"F",@"G",@"H",@"I",@"J",@"K",@"L",@"M",@"N",@"O",@"P",@"Q",@"R",@"S",@"T",@"U",@"V",@"W",@"X",@"Y",@"Z",@"↙",@"↘",@"↖",@"↗",@"┏",@"┓",@"┗",@"┛",@"←",@"↑",@"→",@"↓",nil];

    long index = [Letters indexOfObject:Letter];
    NSMutableArray *GestureData = [[NSMutableArray alloc]init];
    double x,y,_x,_y;
    switch (index) {
        case 0 ://A
            x=200.0;
            y=200.0;
            for (int i=0; i<30; i++) {
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
                y=y+i;
                x=x+0.4*i;
            }
            for (int i=0; i<30; i++) {
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
                y=y-i;
                x=x+0.4*i;
            }
            break;
        case 1://B
            x=200;y=200;
            for (int i=0; i<=80; i++) {
                y=y+1;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
                
            }
            x=230;//y=240;
            [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            for (int i=0; i<=40; i++) {

                x=200+30+sqrt(20*20-(20-i)*(20-i));
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
                y--;
            }
            x=210;//y=240;
            [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            for (int i=0; i<=40; i++) {
                y--;
                x=200+35+sqrt(20*20-(20-i)*(20-i));
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            x=200;y=200;
            [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            
            break;
        case 2://C
            x=220;y=200;
            for (int i=0; i<40; i++) {
                if(i>2)
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
                x=x-1;
                y=200+sqrt(20*20-(20-i)*(20-i));
            }
            x=179;y=200;
            for (int i=0; i<15; i++) {
                y=y-1;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            for (int i=0; i<40; i++) {
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
                x=x+1;
                y=184-sqrt(20*20-(20-i)*(20-i));
            }
            [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            
            break;
        case 3://D
            x=200;y=200;
            for (int i=0; i<=40; i++) {
                y=y+1;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];

            }
            x=210;//y=240;
            [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            for (int i=0; i<=40; i++) {

                x=200+10+sqrt(20*20-(20-i)*(20-i));
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
                y--;
            }
            x=200;y=200;
            [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            
            break;
        case 4://E
            x=200;y=200;
            for (int i=0; i<80; i++) {
                y=y+1;
                //[GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            x=200;//y=240;
            [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            for (int i=0; i<40; i++) {
                y=y-1;
                x=200-20-sqrt(20*20-(20-i)*(20-i));
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            x=200;//y=240;
            [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            for (int i=0; i<=40; i++) {
                y=y-1;
                x=200-20-sqrt(20*20-(20-i)*(20-i));
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            x=210;y=200;
            [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            
            break;
        case 5://F
            x=y=200;
            for (int i=0; i<15; i++) {
                x--;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            for (int i=0; i<20; i++) {
                y--;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            break;
        case 6://G
            x=220;y=200;
            //[GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            for (int i=0; i<40; i++) {
                if(i>3)
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
                x=x-1;
                y=200+sqrt(20*20-(20-i)*(20-i));
            }
            x=179;y=200;
            for (int i=0; i<10; i++) {
                y=y-1;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            for (int i=0; i<=40; i++) {
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
                x=x+1;
                y=190-sqrt(20*20-(20-i)*(20-i));
            }
            for (int i=0; i<15; i++) {
                x=x-1;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            break;
        case 7://H
            x=220;y=200;
            for (int i=0; i<80; i++) {

                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
                y--;
            }
            for (int i=0; i<30; i++) {
                
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
                y++;
            }
            _y=y;
            _x=x;
            for (int i=0; i<=40; i++) {
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
                x=x+1;
                y=_y+sqrt(20*20-(20-i)*(20-i));
            }
            for (int i=0; i<30; i++) {
                
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
                y--;
            }

            break;
        case 8://I
            x=220;y=200;
            for (int i=0; i<80; i++) {
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
                y--;
            }
            break;
            
        case 9://J
            x=220;y=200;
            for (int i=0; i<80; i++) {
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
                y--;
            }
            _y=y;
            for (int i=0; i<=40; i++) {

                
                y=_y-sqrt(20*20-(20-i)*(20-i));
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
                                x=x-1;

            }
            break;
        case 10://K
            x=200;y=200;
            for (int i=0; i<20; i++) {
                x=x-0.7;
                y=y-1;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            for (int i=0; i<20; i++) {
                y++;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            for (int i=0; i<20; i++) {
                x=x+0.7;
                y=y-1;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            break;
        case 11://L
            x=200;y=200;
            for (int i=0; i<20; i++) {
                y--;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            for (int i=0; i<15; i++) {
                x++;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            break;
            
        case 12://M
            x=200;y=200;
            for (int i=0; i<=20; i++) {
                y++;
                x=x+0.2;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            for (int i=0; i<15; i++) {
                y--;
                x=x+0.5;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            for (int i=0; i<15; i++) {
                y++;
                x=x+0.5;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            for (int i=0; i<20; i++) {
                y--;
                x=x+0.2;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            break;
        case 13://N
            x=200;y=200;
            for (int i=0; i<=20; i++) {
                y++;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            for (int i=0; i<20; i++) {
                y--;
                x=x+0.7;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            for (int i=0; i<20; i++) {
                y++;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            break;
        case 14://O
            x=200;y=241;
            [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            for (int i=0; i<=40; i++) {
                y--;
                x=200-sqrt(20*20-(20-i)*(20-i));
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            for (int i=0; i<=40; i++) {
                x=199+sqrt(20*20-(20-i)*(20-i));
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
                y++;

            }
            
            break;
        case 15://P
            x=200;y=200;
            for (int i=0; i<=80; i++) {
                y=y+1;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
                
            }
            x=230;//y=240;
            [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            for (int i=0; i<=40; i++) {
                
                x=200+30+sqrt(20*20-(20-i)*(20-i));
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
                y--;
            }
            x=210;//y=240;
            [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            break;
        case 16://Q
            x=200;y=241;
            //[GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            for (int i=0; i<=40; i++) {
                y--;
                x=200-sqrt(20*20-(20-i)*(20-i));
                if (i>6) {
                    [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
                }
                
            }
            for (int i=0; i<=40; i++) {
                x=199+sqrt(20*20-(20-i)*(20-i));
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
                y++;
                
            }
            for (int i=0; i<=6; i++) {
                y--;
                x=200-sqrt(20*20-(20-i)*(20-i));
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            for (int i=0; i<=33; i++) {
                y--;
                x++;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];

                
            }
            break;
        case 17://R
            x=200;y=200;
            for (int i=0; i<=80; i++) {
                y=y+1;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
                
            }
            x=230;//y=240;
            [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            for (int i=0; i<=40; i++) {
                
                x=200+30+sqrt(20*20-(20-i)*(20-i));
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
                y--;
            }
            x=210;//y=240;
            [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            for (int i=0; i<=40; i++) {
                y--;
                x++;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }

            break;
        case 18://S
            
            x=220;y=200;
            for (int i=0; i<=40; i++) {
                if(i>1)
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
                x--;
                y=200+sqrt(20*20-(20-i)*(20-i));
            }
            for (int i=0; i<=20; i++) {
                x++;
                y=200-sqrt(20*20-(20-i)*(20-i));
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            for (int i=0; i<=20; i++) {
                y--;
                x=200+sqrt(20*20-(20-i)*(20-i));
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            for (int i=0; i<=40; i++) {
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
                x--;
                y=160-sqrt(20*20-(20-i)*(20-i));
            }
        
            break;
        case 19://T
            x=200;y=200;
            for (int i=0; i<15; i++) {
                x++;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            for (int i=0; i<20; i++) {
                y--;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }

            break;
        case 20://U
            x=220;y=240;
            for (int i=0; i<=40; i++) {

                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
                y--;
            }
            _y=y;
            
            for (int i=0; i<=40; i++) {
                x=x+1;
                y=_y-sqrt(20*20-(20-i)*(20-i));
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            for (int i=0; i<40; i++) {
                y++;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            break;

        case 21://V
            x=200;y=200;
            for (int i=0; i<20; i++) {
                y--;
                x=x+0.4;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            for (int i=0; i<20; i++) {
                y++;
                x=x+0.4;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            break;
        case 22://W
            x=200;y=200;
            for (int i=0; i<20; i++) {
                y--;
                x=x+0.3;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            for (int i=0; i<20; i++) {
                y++;
                x=x+0.3;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            for (int i=0; i<20; i++) {
                y--;
                x=x+0.3;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            for (int i=0; i<20; i++) {
                y++;
                x=x+0.3;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            break;
        case 23://X
            x=200;y=200;
            for (int i=0; i<20; i++) {
                y++;
                x++;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            for (int i=0; i<20; i++) {
                x--;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            for (int i=0; i<20; i++) {
                y--;
                x++;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            break;
        case 24://Y
            x=200;y=200;
            for (int i=0; i<10; i++) {
                y--;
                x=x+0.6;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            for (int i=0; i<10; i++) {
                y++;
                x=x+0.6;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }

            for (int i=0; i<20; i++) {
                y--;
                x=x-0.6;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }


            break;
        case 25://Z
            x=200;y=200;
            for (int i=0; i<20; i++) {
                x++;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            for (int i=0; i<20; i++) {
                x--;
                y--;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            for (int i=0; i<20; i++) {
                x++;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            break;
        case 26://↙
            x=200;y=200;
            for (int i=0; i<40; i++) {
                x--;
                y--;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            break;
        case 27://↘
            x=200;y=200;
            for (int i=0; i<40; i++) {
                x++;
                y--;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            break;
        case 28://↖
            x=200;y=200;
            for (int i=0; i<40; i++) {
                x--;
                y++;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            break;
        case 29://↗
            x=200;y=200;
            for (int i=0; i<40; i++) {
                x++;
                y++;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            break;
        case 30://@"┏"
            x=200;y=200;
            for (int i=0; i<20; i++) {
                y++;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            for (int i=0; i<15; i++) {
                x++;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            break;
        case 31://@"┓"
            x=200;y=200;
            for (int i=0; i<20; i++) {
                y++;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            for (int i=0; i<15; i++) {
                x--;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            break;
        case 32://@"┗"
            x=200;y=200;
            for (int i=0; i<20; i++) {
                y--;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            for (int i=0; i<15; i++) {
                x++;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            break;
        case 33://@"┛"
            x=200;y=200;
            for (int i=0; i<20; i++) {
                y--;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            for (int i=0; i<15; i++) {
                x--;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            break;
            
        case 34://@"←"
            x=200;y=200;
            for (int i=0; i<35; i++) {
                x--;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            break;
        case 35://@"↑",
            x=200;y=200;
            for (int i=0; i<35; i++) {
                y++;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            break;
        case 36://@"→",
            x=200;y=200;
            for (int i=0; i<35; i++) {
                x++;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            break;
        case 37://@"↓",
            x=200;y=200;
            for (int i=0; i<35; i++) {
                y--;
                [GestureData addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
            }
            break;
            
            
            
            
        default:
            break;
    }
    return Revered?[[NSMutableArray alloc] initWithArray:[[GestureData reverseObjectEnumerator] allObjects]]:GestureData;

}

@end
