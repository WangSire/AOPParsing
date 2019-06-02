//
//  ViewController.m
//  qweasd
//
//  Created by Siri on 2019/5/2.
//  Copyright © 2019年 Siri. All rights reserved.
//

#import "ViewController.h"
#import "PeopleModel.h"
#import "ChildModel.h"
#import "AppDelegate.h"
#include <objc/runtime.h>

@interface ViewController ()

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
    self.view.backgroundColor = [UIColor redColor];
    PeopleModel *people = [[PeopleModel alloc]init];
    [people systemMethod_PrintLogWithIndex:18 name:@"siri"];
//    [people ll_imageName];
    
    ChildModel *child = [[ChildModel alloc]init];
    [child systemMethod_PrintLogWithIndex:3 name:@"儿子"];
//    [child ll_imageName];

}





@end
