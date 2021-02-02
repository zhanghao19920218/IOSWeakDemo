//
//  main.m
//  IOSWeakDemo
//
//  Created by Mason on 2021/2/2.
//

#import <Foundation/Foundation.h>
#import "BAPerson.h"

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // insert code here...
        BAPerson *object = [[BAPerson alloc] init];
        NSLog(@"Hello, World! %@", object);
        id __weak objc = object;
        
        
    }
    return 0;
}
