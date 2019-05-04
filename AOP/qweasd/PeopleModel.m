//
//  PeopleModel.m
//  qweasd
//
//  Created by Siri on 2019/5/2.
//  Copyright © 2019年 Siri. All rights reserved.
//

#import "PeopleModel.h"
#import <objc/runtime.h>


@implementation PeopleModel

-(void)systemMethod_PrintLogWithIndex:(int)index name:(NSString *)name{
    NSLog(@"%d +  %@",index,name);
}

-(void)ll_imageName{
    NSLog(@"456");
}



@end
