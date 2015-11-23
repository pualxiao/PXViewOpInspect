//
//  PXViewOpInspect.m
//  PXViewOpInspect
//
//  Created by 习波 肖 on 15/11/22.
//  Copyright © 2015年 习波 肖. All rights reserved.
//

#import "PXViewOpInspect.h"
#import <objc/runtime.h>
#import <objc/message.h>
#include <libkern/OSAtomic.h>
#include <execinfo.h>


static void overrideMethod(Class cls, NSString *selectorName, const char *typeDescription);
static void LGForwardInvocation(id slf, SEL selector, NSInvocation *invocation);
static NSString *extractStructName(NSString *typeEncodeString);

@implementation PXViewOpInspect

+ (void)load {
#if defined(VIEW_OP_INSPECT_CRASH) || defined(VIEW_OP_INSPECT_LOG_STACK)
    id classId = objc_getClass("UIView");
    //id classId = objc_getClass("Logger");
    Class class = [classId class];
    
    NSMutableArray *ignoreMethods = [NSMutableArray arrayWithArray:@[@"new", @"retain", @"release", @"autorelease", @"retainCount", @"dealloc", @".cxx_destruct", @"window", @"superview", @"isFocused", @"isHidden", @"frame", @"alpha"]];
    unsigned int propertyCount = 0;
    objc_property_t *properties = class_copyPropertyList(class, &propertyCount);
    for(int i = 0; i < propertyCount; i++)
    {
        objc_property_t property = properties[i];
        [ignoreMethods addObject:@(property_getName(property))];
    }
    free(properties);
    
    unsigned int methodCount = 0;
    Method *methodList = class_copyMethodList(class, &methodCount);
    for (int j = 0; j < methodCount; j++) {
        Method method = methodList[j];
        NSString *methodName = NSStringFromSelector(method_getName(method));
        if (![methodName hasPrefix:@"_"] && ![methodName hasPrefix:@"init"]) {
            BOOL isFind = NO;
            for (NSString *ignoreMethod in ignoreMethods) {
                if ([methodName isEqualToString:ignoreMethod]) {
                    isFind = YES;
                    continue;
                }
            }
            if (!isFind) {
                overrideMethod(class, methodName, method_getTypeEncoding(method));
            }
        }
    }
    
    free(methodList);
#endif
}

@end


static NSString *extractStructName(NSString *typeEncodeString)
{
    NSArray *array = [typeEncodeString componentsSeparatedByString:@"="];
    NSString *typeString = array[0];
    int firstValidIndex = 0;
    for (int i = 0; i< typeString.length; i++) {
        char c = [typeString characterAtIndex:i];
        if (c == '{' || c=='_') {
            firstValidIndex++;
        }else {
            break;
        }
    }
    return [typeString substringFromIndex:firstValidIndex];
}

#pragma clang diagnostic pop

static void LGForwardInvocation(id slf, SEL selector, NSInvocation *invocation)
{
    if (![NSThread currentThread].isMainThread) {
#ifdef VIEW_OP_INSPECT_CRASH
        NSMutableArray *array = [NSMutableArray array];
        [array addObject:nil];
#endif
#ifdef VIEW_OP_INSPECT_LOG_STACK
        NSLog(@"%@",[NSThread callStackSymbols]);
#endif
        //        void *callStack[128];
        //int frames = callStack();
    }
    NSString *selectorName = NSStringFromSelector(invocation.selector);
    NSString *LGSelectorName = [NSString stringWithFormat:@"ORIG_%@", selectorName];
    SEL LGSelector = NSSelectorFromString(LGSelectorName);
    
    if (!class_respondsToSelector(object_getClass(slf), LGSelector)) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
        SEL origForwardSelector = @selector(ORIGforwardInvocation:);
        NSMethodSignature *methodSignature = [slf methodSignatureForSelector:origForwardSelector];
        
        NSInvocation *forwardInv= [NSInvocation invocationWithMethodSignature:methodSignature];
        [forwardInv setTarget:slf];
        [forwardInv setSelector:origForwardSelector];
        [forwardInv setArgument:&invocation atIndex:2];
        [forwardInv invoke];
        return;
#pragma clang diagnostic pop
    }
    
    
    NSString *className = NSStringFromClass([slf class]);
    invocation.selector = LGSelector;
    //    NSLog(@"%@.%@ in",className ,selectorName);
    [invocation invoke];
    //    NSLog(@"%@.%@ out",className ,selectorName);
}


static void overrideMethod(Class cls, NSString *selectorName, const char *typeDescription)
{
    //    NSLog(@"%s.%@", class_getName(cls), selectorName);
    SEL selector = NSSelectorFromString(selectorName);
    
    if (!typeDescription) {
        Method method = class_getInstanceMethod(cls, selector);
        typeDescription = (char *)method_getTypeEncoding(method);
    }
    
    IMP originalImp = class_getMethodImplementation(cls, selector);
    IMP msgForwardIMP = _objc_msgForward;
    
#if !defined(__arm64__)
    
    if (typeDescription[0] == '{') {
        //In some cases that returns struct, we should use the '_stret' API:
        //http://sealiesoftware.com/blog/archive/2008/10/30/objc_explain_objc_msgSend_stret.html
        //NSMethodSignature knows the detail but has no API to return, we can only get the info from debugDescription.
        NSMethodSignature *methodSignature = [NSMethodSignature signatureWithObjCTypes:typeDescription];
        if ([methodSignature.debugDescription rangeOfString:@"is special struct return? YES"].location != NSNotFound) {
            msgForwardIMP = (IMP)_objc_msgForward_stret;
        }
    }
#endif
    
    class_replaceMethod(cls, selector, msgForwardIMP, typeDescription);
    
#pragma clang diagnostic push
    
#pragma clang diagnostic ignored "-Wundeclared-selector"
    
    if (class_getMethodImplementation(cls, @selector(forwardInvocation:)) != (IMP)LGForwardInvocation) {
        IMP originalForwardImp = class_replaceMethod(cls, @selector(forwardInvocation:), (IMP)LGForwardInvocation, "v@:@");
        class_addMethod(cls, @selector(ORIGforwardInvocation:), originalForwardImp, "v@:@");
    }
#pragma clang diagnostic pop
    if (class_respondsToSelector(cls, selector)) {
        NSString *originalSelectorName = [NSString stringWithFormat:@"ORIG_%@", selectorName];
        SEL originalSelector = NSSelectorFromString(originalSelectorName);
        if(!class_respondsToSelector(cls, originalSelector)) {
            class_addMethod(cls, originalSelector, originalImp, typeDescription);
        }
    }
}
