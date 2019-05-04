//
//  AppDelegate.m
//  qweasd
//
//  Created by Siri on 2019/5/2.
//  Copyright © 2019年 Siri. All rights reserved.
//

#import "AppDelegate.h"
#import "Aspects.h"
#import "PeopleModel.h"
#import "ChildModel.h"

@interface AppDelegate ()

@end

@implementation AppDelegate


- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // Override point for customization after application launch.
    
    
    
    
//    [PeopleModel aspect_hookSelector:@selector(systemMethod_PrintLogWithIndex:name:) withOptions:AspectPositionBefore usingBlock:^(id<AspectInfo> info){
//        NSLog(@"执行了");
//    } error:nil];
    
    [PeopleModel aspect_hookSelector:@selector(ll_imageName) withOptions:AspectOptionAutomaticRemoval usingBlock:^(id<AspectInfo> info){
        NSLog(@"ll_imageName");
    } error:nil];
  
    return YES;
}


- (void)applicationWillResignActive:(UIApplication *)application {
    // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
    // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
}


- (void)applicationDidEnterBackground:(UIApplication *)application {
    // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
    // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
}


- (void)applicationWillEnterForeground:(UIApplication *)application {
    // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
}


- (void)applicationDidBecomeActive:(UIApplication *)application {
    // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
}


- (void)applicationWillTerminate:(UIApplication *)application {
    // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
}


@end
