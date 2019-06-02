//
//  Aspects.m
//  Aspects - A delightful, simple library for aspect oriented programming.
//
//  Copyright (c) 2014 Peter Steinberger. Licensed under the MIT license.
//

#import "Aspects.h"
#import <libkern/OSAtomic.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define AspectLog(...)
//#define AspectLog(...) do { NSLog(__VA_ARGS__); }while(0)
#define AspectLogError(...) do { NSLog(__VA_ARGS__); }while(0)

// Block internals.
typedef NS_OPTIONS(int, AspectBlockFlags) {
    // 捕获外界变量
	AspectBlockFlagsHasCopyDisposeHelpers = (1 << 25),
    // Block有签名信息
	AspectBlockFlagsHasSignature          = (1 << 30)
};
/*
    因为没法直接拿到block的签名信息，所以创建_AspectBlock目的是拿到block的签名信息，然后就可以使用NSInvocation调用这个block。
    (把block转成invocation,通过invocation来调用block)
 */
typedef struct _AspectBlock {
	__unused Class isa;
	AspectBlockFlags flags;
	__unused int reserved;
	void (__unused *invoke)(struct _AspectBlock *block, ...);
	struct {
		unsigned long int reserved;
		unsigned long int size;
		// requires AspectBlockFlagsHasCopyDisposeHelpers
        // 函数指针  个人观点：对block内部中的局部变量使用了__block,则会添加copy和dispose函数指针 （而copy指针的动作是在该函数中执行）
		void (*copy)(void *dst, const void *src);
		void (*dispose)(const void *);
		// requires AspectBlockFlagsHasSignature
        const char *signature; // 方法签名  -> 就是当前block的type:v@?i
		const char *layout;
	} *descriptor;
	// imported variables
} *AspectBlockRef;

/*
   AspectInfo里面主要是 NSInvocation 信息。将NSInvocation包装一层，比如参数信息等 (block的第一个参数)
 */
@interface AspectInfo : NSObject <AspectInfo>
// 把外面传进来的实例instance，和原始的invocation保存到AspectInfo类对应的成员变量中
- (id)initWithInstance:(__unsafe_unretained id)instance invocation:(NSInvocation *)invocation;
@property (nonatomic, unsafe_unretained, readonly) id instance;
@property (nonatomic, strong, readonly) NSArray *arguments;// 原始的invocation里面的aspects参数
@property (nonatomic, strong, readonly) NSInvocation *originalInvocation;
@end

// Tracks a single aspect.

/*
 切面 ID：每进行一个hook，都会生成一个AspectIdentifier对象，包含：方法，插入的block等具体信息，签名信息等
 */

@interface AspectIdentifier : NSObject
// 生成block的方法签名NSMethodSignature
+ (instancetype)identifierWithSelector:(SEL)selector object:(id)object options:(AspectOptions)options block:(id)block error:(NSError **)error;
// 对比block的方法签名和待hook的方法签名是否兼容（参数个数，按照顺序的类型）
- (BOOL)invokeWithInfo:(id<AspectInfo>)info;
@property (nonatomic, assign) SEL selector; // 被hook方法
@property (nonatomic, strong) id block;  //外界的Block
@property (nonatomic, strong) NSMethodSignature *blockSignature;
@property (nonatomic, weak) id object;
@property (nonatomic, assign) AspectOptions options;
@end

// Tracks all aspects for an object/class.

/*
 用于盛放AspectIdentifier对象,key为别名SEL,然后关联对象存储到对应的类中 (每一个别名SEL对应一个该对象)
 */
@interface AspectsContainer : NSObject
// 按照切面的时机分别把切片Aspects放到对应的数组里面
- (void)addAspect:(AspectIdentifier *)aspect withOptions:(AspectOptions)injectPosition;
// 循环移除所有的Aspects
- (BOOL)removeAspect:(id)aspect;
// 判断是否有Aspects
- (BOOL)hasAspects;
@property (atomic, copy) NSArray *beforeAspects;
@property (atomic, copy) NSArray *insteadAspects;
@property (atomic, copy) NSArray *afterAspects;
@end


// 切面跟踪器：跟踪一个类的继承链中的hook状态：包括被hook的类，哪些SEL被hook了。(每一个class对应一个AspectTracker。 在一个继承链上，一个selector只能被hook一次。)
@interface AspectTracker : NSObject
- (id)initWithTrackedClass:(Class)trackedClass;
@property (nonatomic, strong) Class trackedClass;
@property (nonatomic, readonly) NSString *trackedClassName;
// 记录要被hook替换的方法名，用NSMutableSet是为了防止重复替换方法
@property (nonatomic, strong) NSMutableSet *selectorNames;
// key是hookingSelectorName，value是装满AspectTracker的NSMutableSet
@property (nonatomic, strong) NSMutableDictionary *selectorNamesToSubclassTrackers;
// 把AspectTracker加入到对应selectorName的集合中
- (void)addSubclassTracker:(AspectTracker *)subclassTracker hookingSelectorName:(NSString *)selectorName;
// 把AspectTracker从对应的selectorName的集合中移除
- (void)removeSubclassTracker:(AspectTracker *)subclassTracker hookingSelectorName:(NSString *)selectorName;

- (BOOL)subclassHasHookedSelectorName:(NSString *)selectorName;
// 传入一个selectorName，通过递归查找，找到所有包含这个selectorName的set，最后把这些set合并在一起作为返回值返回。
- (NSSet *)subclassTrackersHookingSelectorName:(NSString *)selectorName;
@end

@interface NSInvocation (Aspects)
- (NSArray *)aspects_arguments;
@end

#define AspectPositionFilter 0x07

#define AspectError(errorCode, errorDescription) do { \
AspectLogError(@"Aspects: %@", errorDescription); \
if (error) { *error = [NSError errorWithDomain:AspectErrorDomain code:errorCode userInfo:@{NSLocalizedDescriptionKey: errorDescription}]; }}while(0)

NSString *const AspectErrorDomain = @"AspectErrorDomain";
static NSString *const AspectsSubclassSuffix = @"_Aspects_";
static NSString *const AspectsMessagePrefix = @"aspects_";

@implementation NSObject (Aspects)

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Public Aspects API

+ (id<AspectToken>)aspect_hookSelector:(SEL)selector
                      withOptions:(AspectOptions)options
                       usingBlock:(id)block
                            error:(NSError **)error {
    return aspect_add((id)self, selector, options, block, error);
}

/// @return A token which allows to later deregister the aspect.
- (id<AspectToken>)aspect_hookSelector:(SEL)selector
                      withOptions:(AspectOptions)options
                       usingBlock:(id)block
                            error:(NSError **)error {
    return aspect_add(self, selector, options, block, error);
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Private Helper

/* 准备总结
 1.首先调用aspect_performLocked ，利用自旋锁，保证整个操作的线程安全
 2.接着调用aspect_isSelectorAllowedAndTrack对传进来的参数进行强校验，保证参数合法性。
 3.接着创建AspectsContainer容器，利用AssociatedObject关联对象动态添加到NSObject分类中作为属性的。
 4.再由入参selector，option，创建AspectIdentifier实例。AspectIdentifier主要包含了单个的 Aspect的具体信息，包括执行时机，要执行block 所需要用到的具体信息。
 5.再将单个的 AspectIdentifier 的具体信息加到属性AspectsContainer容器中。通过options选项分别添加到容器中的beforeAspects,insteadAspects,afterAspects这三个数组。
 6.最后调用prepareClassAndHookSelector准备hook。
 */

/**
 hook前的准备工作

 @param self 当前类
 @param selector 外面传进来需要hook的SEL
 @param options 切片的时间
 @param block 切片的执行方法
 @param error 错误
 */
static id aspect_add(id self, SEL selector, AspectOptions options, id block, NSError **error) {
    NSCParameterAssert(self);
    NSCParameterAssert(selector);
    NSCParameterAssert(block);

    __block AspectIdentifier *identifier = nil;
    //  保护了block的线程安全 (使用了自旋锁)
    aspect_performLocked(^{
        //  判断hook方法合法性的代码
        if (aspect_isSelectorAllowedAndTrack(self, selector, options, error)) {
            // 获取或者创建AspectsContainer容器了 (给该类动态添加一个Aspect管理对象,并关联本类)
            AspectsContainer *aspectContainer = aspect_getContainerForObject(self, selector);
            // 创建一个新的AspectIdentifier
            identifier = [AspectIdentifier identifierWithSelector:selector object:self options:options block:block error:error];
            
            // 可能会创建失败，那就是aspect_isCompatibleBlockSignature方法返回NO。返回NO就意味着，block和要被hook的方法，两者的方法签名是不相符的。
            if (identifier) {
                // 完成了容器和AspectIdentifier初始化之后，就可以开始准备进行hook了。通过options选项分别添加到容器中的beforeAspects,insteadAspects,afterAspects这三个数组
                [aspectContainer addAspect:identifier withOptions:options];

                // Modify the class to allow message interception.
                aspect_prepareClassAndHookSelector(self, selector, error);
            }
        }
    });
    return identifier;
}

#pragma MARK 销毁aspect流程

// 把AspectsContainer都置为空，remove最关键的过程就是aspect_cleanupHookedClassAndSelector(self, aspect.selector);移除之前hook的class和selector。
static BOOL aspect_remove(AspectIdentifier *aspect, NSError **error) {
    NSCAssert([aspect isKindOfClass:AspectIdentifier.class], @"Must have correct type.");

    __block BOOL success = NO;
    aspect_performLocked(^{
        
        id self = aspect.object; // strongify
        if (self) {
            AspectsContainer *aspectContainer = aspect_getContainerForObject(self, aspect.selector);
            // 删除hook Block所有信息
            success = [aspectContainer removeAspect:aspect];
            
            // 移除之前hook的class和selector
            aspect_cleanupHookedClassAndSelector(self, aspect.selector);
            // destroy token
            aspect.object = nil;
            aspect.block = nil;
            aspect.selector = NULL;
        }else {
            NSString *errrorDesc = [NSString stringWithFormat:@"Unable to deregister hook. Object already deallocated: %@", aspect];
            AspectError(AspectErrorRemoveObjectAlreadyDeallocated, errrorDesc);
        }
    });
    return success;
}

/*
   主要是为了保证线程安全!!!
   OSSpinLockLock加锁机制，保证线程安全并且性能高。
 
   提示:不过这种锁已经不在安全，主要原因发生在低优先级线程拿到锁时，高优先级线程进入忙等(busy-wait)状态，消耗大量 CPU 时间，从而导致低优先级线程拿不到 CPU 时间，也就无法完成任务并释放锁。苹果的工程师停用了 OSSpinLock
 */
static void aspect_performLocked(dispatch_block_t block) {
    static OSSpinLock aspect_lock = OS_SPINLOCK_INIT;
    OSSpinLockLock(&aspect_lock);
    block();
    OSSpinLockUnlock(&aspect_lock);
}

static SEL aspect_aliasForSelector(SEL selector) {
    
    //用这个字符串(AspectsMessagePrefix)标记所有的selector，都加上前缀"aspects_"。
    NSCParameterAssert(selector);
	return NSSelectorFromString([AspectsMessagePrefix stringByAppendingFormat:@"_%@", NSStringFromSelector(selector)]);
}

static NSMethodSignature *aspect_blockMethodSignature(id block, NSError **error) {
    // 因为不能直接拿到block的签名信息，所以将block强制类型转换为AspectBlockRef
    AspectBlockRef layout = (__bridge void *)block;
    
    // 通过flags判断是否存在方法签名
	if (!(layout->flags & AspectBlockFlagsHasSignature)) {
        NSString *description = [NSString stringWithFormat:@"The block %@ doesn't contain a type signature.", block];
        AspectError(AspectErrorMissingBlockSignature, description);
        return nil;
    }
    // 获取block的descriptor,在descriptor获取方法签名
	void *desc = layout->descriptor;
    // 由于全局block和堆block，signature存在的位置不同,所以需要判断. （copy以及dispose两个函数在堆block才会存在）
	desc += 2 * sizeof(unsigned long int);
    
	if (layout->flags & AspectBlockFlagsHasCopyDisposeHelpers) {
		desc += 2 * sizeof(void *);
    }
    
	if (!desc) {
        NSString *description = [NSString stringWithFormat:@"The block %@ doesn't has a type signature.", block];
        AspectError(AspectErrorMissingBlockSignature, description);
        return nil;
    }
	const char *signature = (*(const char **)desc);
    // 根据类型编码获得签名信息
	return [NSMethodSignature signatureWithObjCTypes:signature];
}

// 就是匹配原方法的参数与block参数
static BOOL aspect_isCompatibleBlockSignature(NSMethodSignature *blockSignature, id object, SEL selector, NSError **error) {
    NSCParameterAssert(blockSignature);
    NSCParameterAssert(object);
    NSCParameterAssert(selector);

    BOOL signaturesMatch = YES;
    NSMethodSignature *methodSignature = [[object class] instanceMethodSignatureForSelector:selector];
    // 先比较方法签名与block签名的参数个数是否相等，不等肯定是不匹配
    if (blockSignature.numberOfArguments > methodSignature.numberOfArguments) {
        signaturesMatch = NO;
    }else {
        // 如果参数个数相等，再比较我们要替换的方法里面第一个参数是不是_cmd，对应的Type就是@
        if (blockSignature.numberOfArguments > 1) {
            const char *blockType = [blockSignature getArgumentTypeAtIndex:1];
            if (blockType[0] != '@') {
                signaturesMatch = NO;
            }
        }
        // Argument 0 is self/block, argument 1 is SEL or id<AspectInfo>. We start comparing at argument 2.
        // The block can have less arguments than the method, that's ok.
        
        // Argument 0是self/block，argument 1是SEL or id<AspectInfo>，所以从 2开始校验。
        if (signaturesMatch) {
            for (NSUInteger idx = 2; idx < blockSignature.numberOfArguments; idx++) {
                const char *methodType = [methodSignature getArgumentTypeAtIndex:idx];
                const char *blockType = [blockSignature getArgumentTypeAtIndex:idx];
                // Only compare parameter, not the optional type data.
                if (!methodType || !blockType || methodType[0] != blockType[0]) {
                    signaturesMatch = NO; break;
                }
            }
        }
    }
    
    if (!signaturesMatch) {
        // Block无法匹配方法签名
        NSString *description = [NSString stringWithFormat:@"Block signature %@ doesn't match %@.", blockSignature, methodSignature];
        AspectError(AspectErrorIncompatibleBlockSignature, description);
        return NO;
    }
    return YES;
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Class + Selector Preparation

static BOOL aspect_isMsgForwardIMP(IMP impl) {
    return impl == _objc_msgForward
#if !defined(__arm64__)
    || impl == (IMP)_objc_msgForward_stret
#endif
    ;
}

static IMP aspect_getMsgForwardIMP(NSObject *self, SEL selector) {
    IMP msgForwardIMP = _objc_msgForward;
#if !defined(__arm64__)
    // As an ugly internal runtime implementation detail in the 32bit runtime, we need to determine of the method we hook returns a struct or anything larger than id.
    // https://developer.apple.com/library/mac/documentation/DeveloperTools/Conceptual/LowLevelABI/000-Introduction/introduction.html
    // https://github.com/ReactiveCocoa/ReactiveCocoa/issues/783
    // http://infocenter.arm.com/help/topic/com.arm.doc.ihi0042e/IHI0042E_aapcs.pdf (Section 5.4)
    Method method = class_getInstanceMethod(self.class, selector);
    const char *encoding = method_getTypeEncoding(method);
    BOOL methodReturnsStructValue = encoding[0] == _C_STRUCT_B;
    if (methodReturnsStructValue) {
        @try {
            NSUInteger valueSize = 0;
            NSGetSizeAndAlignment(encoding, &valueSize, NULL);

            if (valueSize == 1 || valueSize == 2 || valueSize == 4 || valueSize == 8) {
                methodReturnsStructValue = NO;
            }
        } @catch (__unused NSException *e) {}
    }
    if (methodReturnsStructValue) {
        msgForwardIMP = (IMP)_objc_msgForward_stret;
    }
#endif
    return msgForwardIMP;
}

#pragma mark 核心
// 动态生成子类(带有_Aspects_后缀的子类),并交换类的原方法的实现为_objc_msgForward 使其直接进入消息转发模式
// 注意：实例对象会创建子类，返回子类！但类对象不会创建，返回本身
static void aspect_prepareClassAndHookSelector(NSObject *self, SEL selector, NSError **error) {
    NSCParameterAssert(selector);
    
    // 生成子类或者直接替换类方法
    Class klass = aspect_hookClass(self, error);
    
    // klass是我们hook完原始的class之后得到的类,可以从它这里获取到原有的selector的IMP
    Method targetMethod = class_getInstanceMethod(klass, selector);
    IMP targetMethodIMP = method_getImplementation(targetMethod);
    // 判断当前IMP是不是_objc_msgForward或者_objc_msgForward_stret，即判断当前IMP是不是消息转发
    if (!aspect_isMsgForwardIMP(targetMethodIMP)) {
        // Make a method alias for the existing method implementation, it not already copied.
        const char *typeEncoding = method_getTypeEncoding(targetMethod);
        SEL aliasSelector = aspect_aliasForSelector(selector);
        // 如果该类不能响应aspects_xxxx
        if (![klass instancesRespondToSelector:aliasSelector]) {
            // 就为klass添加aspects_xxxx方法,方法的实现为原生方法的实现
            __unused BOOL addedAlias = class_addMethod(klass, aliasSelector, method_getImplementation(targetMethod), typeEncoding);
            NSCAssert(addedAlias, @"Original implementation for %@ is already copied to %@ on %@", NSStringFromSelector(selector), NSStringFromSelector(aliasSelector), klass);
        }

        // We use forwardInvocation to hook in.
        // 把类的原方法的改为_objc_msgForward
        class_replaceMethod(klass, selector, aspect_getMsgForwardIMP(self, selector), typeEncoding);
        AspectLog(@"Aspects: Installed hook for -[%@ %@].", klass, NSStringFromSelector(selector));
    }
}

// Will undo the runtime changes made.
static void aspect_cleanupHookedClassAndSelector(NSObject *self, SEL selector) {
    NSCParameterAssert(self);
    NSCParameterAssert(selector);

    
	Class klass = object_getClass(self);
    BOOL isMetaClass = class_isMetaClass(klass);
    if (isMetaClass) {
        klass = (Class)self;
    }

    
    // 获取原来类的方法的IMP是不是指向了_objc_msgForward,如果是,就把该方法的IMP再指回去
    // Check if the method is marked as forwarded and undo that.
    Method targetMethod = class_getInstanceMethod(klass, selector);
    IMP targetMethodIMP = method_getImplementation(targetMethod);
    if (aspect_isMsgForwardIMP(targetMethodIMP)) {
        // Restore the original method implementation.
        const char *typeEncoding = method_getTypeEncoding(targetMethod);
        SEL aliasSelector = aspect_aliasForSelector(selector);
        Method originalMethod = class_getInstanceMethod(klass, aliasSelector);
        IMP originalIMP = method_getImplementation(originalMethod);
        NSCAssert(originalMethod, @"Original implementation for %@ not found %@ on %@", NSStringFromSelector(selector), NSStringFromSelector(aliasSelector), klass);

        class_replaceMethod(klass, selector, originalIMP, typeEncoding);
        AspectLog(@"Aspects: Removed hook for -[%@ %@].", klass, NSStringFromSelector(selector));
    }

    // Deregister global tracked selector
    // 移除AspectTracker里面所有标记的swizzledClassesDict。销毁全部记录的selector
    aspect_deregisterTrackedSelector(self, selector);

    // Get the aspect container and check if there are any hooks remaining. Clean up if there are not.
    AspectsContainer *container = aspect_getContainerForObject(self, selector);
    if (!container.hasAspects) {
        // Destroy the container
        // 需要还原类的AssociatedObject关联对象，以及用到的AspectsContainer容器。
        aspect_destroyContainerForObject(self, selector);

        // Figure out how the class was modified to undo the changes.
        NSString *className = NSStringFromClass(klass);
        if ([className hasSuffix:AspectsSubclassSuffix]) {
            // 把新建类的isa指针指向原来类
            Class originalClass = NSClassFromString([className stringByReplacingOccurrencesOfString:AspectsSubclassSuffix withString:@""]);
            NSCAssert(originalClass != nil, @"Original class must exist");
            object_setClass(self, originalClass);
            AspectLog(@"Aspects: %@ has been restored.", NSStringFromClass(originalClass));

            // We can only dispose the class pair if we can ensure that no instances exist using our subclass.
            // Since we don't globally track this, we can't ensure this - but there's also not much overhead in keeping it around.
            //objc_disposeClassPair(object.class);
        }else {
            // Class is most likely swizzled in place. Undo that.
            if (isMetaClass) {
                // 销毁了AspectsContainer容器，并且把关联对象也置成了nil
                aspect_undoSwizzleClassInPlace((Class)self);
            }else if (self.class != klass) {
            	aspect_undoSwizzleClassInPlace(klass);
            }
        }
    }
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Hook Class

static Class aspect_hookClass(NSObject *self, NSError **error) {
    NSCParameterAssert(self);
    // 获取类对象
	Class statedClass = self.class;
    // 获取到类的isa
	Class baseClass = object_getClass(self);
	NSString *className = NSStringFromClass(baseClass);

    /* 1.先判断是用来className是否包含hasSuffix:AspectsSubclassSuffix,如果包含了@"_Aspects_"后缀，代表该类已经被hook过了，直接return
       2.如果不包含@"_Aspects_"后缀，再判断是否是baseClass是否是元类，如果是元类，调用aspect_swizzleClassInPlace
       3.如果也不是元类，再判断statedClass 和 baseClass是否相等，如果不相等，说明为KVO过的对象，因为KVO的对象isa指针会指向一个中间类。对KVO中间类调用aspect_swizzleClassInPlace
    */
	if ([className hasSuffix:AspectsSubclassSuffix]) {
		return baseClass;
	}else if (class_isMetaClass(baseClass)) {
        return aspect_swizzleClassInPlace((Class)self);
    }else if (statedClass != baseClass) {
        return aspect_swizzleClassInPlace(baseClass);
    }

    // Default case. Create dynamic subclass.
    // 当className没有包含@"_Aspects_"后缀，并且也不是元类，也不是KVO的中间类，于是，默认的新建一个子类subclass。
	const char *subclassName = [className stringByAppendingString:AspectsSubclassSuffix].UTF8String;
    // 创建这个子类
	Class subclass = objc_getClass(subclassName);

	if (subclass == nil) {
        // 需要新建这个子类。调用objc_allocateClassPair()方法。(它的父类是入参superclass)
		subclass = objc_allocateClassPair(baseClass, subclassName, 0);
		if (subclass == nil) {
            NSString *errrorDesc = [NSString stringWithFormat:@"objc_allocateClassPair failed to allocate class %s.", subclassName];
            AspectError(AspectErrorFailedToAllocateClassPair, errrorDesc);
            return nil;
        }
        // 替换子类forwardInvocation方法的实现为__ASPECTS_ARE_BEING_CALLED__
		aspect_swizzleForwardInvocation(subclass);
        
        // 把class的实例方法替换成返回statedClass，也就是说把调用class时候的isa指向了statedClass了
        
        // 修改了 subclass 以及其 subclass metaclass 的 class 方法,使他返回当前对象的 class 隐藏对外的Class
		aspect_hookedGetClass(subclass, statedClass); //把subclass的isa指向了statedClass
		aspect_hookedGetClass(object_getClass(subclass), statedClass);//把subclass的元类的isa，也指向了statedClass
        
        //注册刚刚新建的子类subclass
		objc_registerClassPair(subclass);
	}
    // 把当前self的isa指向子类subclass
	object_setClass(self, subclass);
	return subclass;
}

static NSString *const AspectsForwardInvocationSelectorName = @"__aspects_forwardInvocation:";


// 替换类的forwardInvocation为__ASPECTS_ARE_BEING_CALLED__
static void aspect_swizzleForwardInvocation(Class klass) {
    NSCParameterAssert(klass);
    // If there is no method, replace will act like class_addMethod.
    IMP originalImplementation = class_replaceMethod(klass, @selector(forwardInvocation:), (IMP)__ASPECTS_ARE_BEING_CALLED__, "v@:@");
    
    // 如果存在,把原有类的forwardInvocation保存起来 (当调用hook方法,原函数没有实现,则调用原类的消息转发，可以解决JSPatch兼容的问题)
    // 关于兼容问题可查看：https://www.jianshu.com/p/dc1deaa1b28e
    
    if (originalImplementation) {
        // 不为空的话说明原方法有实现，添加一个新方法__aspects_forwardInvocation:指向了原来的originalImplementation，在__ASPECTS_ARE_BEING_CALLED__那里如果不能处理，判断是否有实现__aspects_forwardInvocation，有的话就转发。
        class_addMethod(klass, NSSelectorFromString(AspectsForwardInvocationSelectorName), originalImplementation, "v@:@");
    }
    AspectLog(@"Aspects: %@ is now aspect aware.", NSStringFromClass(klass));
}

static void aspect_undoSwizzleForwardInvocation(Class klass) {
    NSCParameterAssert(klass);
    Method originalMethod = class_getInstanceMethod(klass, NSSelectorFromString(AspectsForwardInvocationSelectorName));
    Method objectMethod = class_getInstanceMethod(NSObject.class, @selector(forwardInvocation:));
    // There is no class_removeMethod, so the best we can do is to retore the original implementation, or use a dummy.
    IMP originalImplementation = method_getImplementation(originalMethod ?: objectMethod);
    class_replaceMethod(klass, @selector(forwardInvocation:), originalImplementation, "v@:@");

    AspectLog(@"Aspects: %@ has been restored.", NSStringFromClass(klass));
}

static void aspect_hookedGetClass(Class class, Class statedClass) {
    NSCParameterAssert(class);
    NSCParameterAssert(statedClass);
	Method method = class_getInstanceMethod(class, @selector(class));
	IMP newIMP = imp_implementationWithBlock(^(id self) {
		return statedClass;
	});
	class_replaceMethod(class, @selector(class), newIMP, method_getTypeEncoding(method));
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Swizzle Class In Place

//  该方法保证了swizzledClasses这个Set集合是全局唯一的，并且给传入的block加上了线程锁@synchronized，保证了block调用中线程是安全的。
static void _aspect_modifySwizzledClasses(void (^block)(NSMutableSet *swizzledClasses)) {
    static NSMutableSet *swizzledClasses;
    static dispatch_once_t pred;
    dispatch_once(&pred, ^{
        swizzledClasses = [NSMutableSet new];
    });
    @synchronized(swizzledClasses) {
        block(swizzledClasses);
    }
}

static Class aspect_swizzleClassInPlace(Class klass) {
    NSCParameterAssert(klass);
    NSString *className = NSStringFromClass(klass);

    _aspect_modifySwizzledClasses(^(NSMutableSet *swizzledClasses) {
        if (![swizzledClasses containsObject:className]) {
            aspect_swizzleForwardInvocation(klass);
            [swizzledClasses addObject:className];
        }
    });
    return klass;
}

// 销毁了AspectsContainer容器，并且把关联对象也置成了nil
static void aspect_undoSwizzleClassInPlace(Class klass) {
    NSCParameterAssert(klass);
    NSString *className = NSStringFromClass(klass);

    _aspect_modifySwizzledClasses(^(NSMutableSet *swizzledClasses) {
        if ([swizzledClasses containsObject:className]) {
            // 把原来的ForwardInvocation再交换回来
            aspect_undoSwizzleForwardInvocation(klass);
            [swizzledClasses removeObject:className];
        }
    });
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Aspect Invoke Point

// This is a macro so we get a cleaner stack trace.
// 宏定义里面就做了两件事情，一个是执行了[aspect invokeWithInfo:info]方法，一个是把需要remove的Aspects加入等待被移除的数组中
#define aspect_invoke(aspects, info) \
for (AspectIdentifier *aspect in aspects) {\
    [aspect invokeWithInfo:info];\
    if (aspect.options & AspectOptionAutomaticRemoval) { \
        aspectsToRemove = [aspectsToRemove?:@[] arrayByAddingObject:aspect]; \
    } \
}

// This is the swizzled forwardInvocation: method.

#pragma mark 核心 消息转发逻辑处理
static void __ASPECTS_ARE_BEING_CALLED__(__unsafe_unretained NSObject *self, SEL selector, NSInvocation *invocation) {
    NSCParameterAssert(self);
    NSCParameterAssert(invocation);
    // 获取原始的selector
    SEL originalSelector = invocation.selector;
    // 获取带有aspects_xxxx前缀的方法
	SEL aliasSelector = aspect_aliasForSelector(invocation.selector);
    // 替换selector
    invocation.selector = aliasSelector;
    // 获取实例对象的容器objectContainer，这里是之前aspect_add关联过的对象。
    AspectsContainer *objectContainer = objc_getAssociatedObject(self, aliasSelector);
    // 获取获得类对象容器classContainer
    AspectsContainer *classContainer = aspect_getContainerForClass(object_getClass(self), aliasSelector);
    // 初始化AspectInfo，传入self(原始)、invocation(原始)参数
    AspectInfo *info = [[AspectInfo alloc] initWithInstance:self invocation:invocation];
    NSArray *aspectsToRemove = nil;

    // Before hooks.
    
    // 遍历beforeAspects中的hook,执行外部的block
    aspect_invoke(classContainer.beforeAspects, info);
    aspect_invoke(objectContainer.beforeAspects, info);

    // Instead hooks.
    // 这一段代码是实现Instead hooks的。先判断当前insteadAspects是否有数据，如果没有数据则判断当前继承链是否能响应aspects_xxx方法,如果能，则直接调用aliasSelector。注意：这里的aliasSelector是原方法method
    BOOL respondsToAlias = YES;
    // 判断如果是替换
    if (objectContainer.insteadAspects.count || classContainer.insteadAspects.count) {
        aspect_invoke(classContainer.insteadAspects, info);
        aspect_invoke(objectContainer.insteadAspects, info);
    }else {
        // 执行aliasSelector,回调原类中的的原方法
        Class klass = object_getClass(invocation.target);
        do {
            if ((respondsToAlias = [klass instancesRespondToSelector:aliasSelector])) {
                [invocation invoke];
                break;
            }
        }while (!respondsToAlias && (klass = class_getSuperclass(klass)));
    }

    // After hooks.
    aspect_invoke(classContainer.afterAspects, info);
    aspect_invoke(objectContainer.afterAspects, info);
    
    // 提示: before、instead、after对应时间的Aspects切片的hook如果能被执行的，都执行完毕了。

    // If no hooks are installed, call original implementation (usually to throw an exception)
    // 如果aliasSelector无法响应(原类中方法没有实现),判断原类中是否定义了消息转发,如果有则调用原类中的消息转发(ForwardInvocation),如果没有抛出异常
    if (!respondsToAlias) {
        invocation.selector = originalSelector;
        SEL originalForwardInvocationSEL = NSSelectorFromString(AspectsForwardInvocationSelectorName);
        if ([self respondsToSelector:originalForwardInvocationSEL]) {
            ((void( *)(id, SEL, NSInvocation *))objc_msgSend)(self, originalForwardInvocationSEL, invocation);
        }else {
            [self doesNotRecognizeSelector:invocation.selector];
        }
    }

    // Remove any hooks that are queued for deregistration.
    // 最后调用移除方法，移除hook。
    [aspectsToRemove makeObjectsPerformSelector:@selector(remove)];
}
#undef aspect_invoke

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Aspect Container Management

// Loads or creates the aspect container.
static AspectsContainer *aspect_getContainerForObject(NSObject *self, SEL selector) {
    NSCParameterAssert(self);
    // 获取别名SEL, 然后获得其对应的关联对象，如果获取不到，就创建一个关联对象。最终得到selector有"aspects_"前缀，对应的aspectContainer。
    SEL aliasSelector = aspect_aliasForSelector(selector);
    AspectsContainer *aspectContainer = objc_getAssociatedObject(self, aliasSelector);
    if (!aspectContainer) {
        aspectContainer = [AspectsContainer new];
        // objc_setAssociatedObject 关联
        objc_setAssociatedObject(self, aliasSelector, aspectContainer, OBJC_ASSOCIATION_RETAIN);
    }
    return aspectContainer;
}

static AspectsContainer *aspect_getContainerForClass(Class klass, SEL selector) {
    NSCParameterAssert(klass);
    AspectsContainer *classContainer = nil;
    do {
        classContainer = objc_getAssociatedObject(klass, selector);
        if (classContainer.hasAspects) break;
    }while ((klass = class_getSuperclass(klass)));

    return classContainer;
}

static void aspect_destroyContainerForObject(id<NSObject> self, SEL selector) {
    NSCParameterAssert(self);
    SEL aliasSelector = aspect_aliasForSelector(selector);
    objc_setAssociatedObject(self, aliasSelector, nil, OBJC_ASSOCIATION_RETAIN);
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Selector Blacklist Checking

static NSMutableDictionary *aspect_getSwizzledClassesDict() {
    static NSMutableDictionary *swizzledClassesDict;
    static dispatch_once_t pred;
    dispatch_once(&pred, ^{
        swizzledClassesDict = [NSMutableDictionary new];
    });
    return swizzledClassesDict;
}

/*
    类方法hook判断合法性的代码
    总结:如果不是元类，只要不是hook这"retain", "release", "autorelease", "forwardInvocation:"4种方法，而且hook “dealloc”方法的时机必须是before，并且selector能被找到，那么方法就可以被hook。
 */
static BOOL aspect_isSelectorAllowedAndTrack(NSObject *self, SEL selector, AspectOptions options, NSError **error) {
    /*
     先定义了一个NSSet，这里面是一个“黑名单”，是不允许hook的函数名。retain, release, autorelease, forwardInvocation:是不允许被hook的。
     */
    
    static NSSet *disallowedSelectorList;
    static dispatch_once_t pred;
    dispatch_once(&pred, ^{
        disallowedSelectorList = [NSSet setWithObjects:@"retain", @"release", @"autorelease", @"forwardInvocation:", nil];
    });

    // 当检测到selector的函数名是黑名单里面的函数名，立即报错。
    NSString *selectorName = NSStringFromSelector(selector);
    if ([disallowedSelectorList containsObject:selectorName]) {
        NSString *errorDescription = [NSString stringWithFormat:@"Selector %@ is blacklisted.", selectorName];
        AspectError(AspectErrorSelectorBlacklisted, errorDescription);
        return NO;
    }

    // 检查如果要切片dealloc，切片时间只能在dealloc之前，如果不是AspectPositionBefore，也要报错。
    AspectOptions position = options&AspectPositionFilter;
    if ([selectorName isEqualToString:@"dealloc"] && position != AspectPositionBefore) {
        NSString *errorDesc = @"AspectPositionBefore is the only valid position when hooking dealloc.";
        AspectError(AspectErrorSelectorDeallocPosition, errorDesc);
        return NO;
    }
    // 当selector不在黑名单里面了，如果切片是dealloc，且selector在其之前了。这时候就该判断该方法是否存在。如果self和self.class里面都找不到该selector，会报错找不到该方法。
    if (![self respondsToSelector:selector] && ![self.class instancesRespondToSelector:selector]) {
        NSString *errorDesc = [NSString stringWithFormat:@"Unable to find selector -[%@ %@].", NSStringFromClass(self.class), selectorName];
        AspectError(AspectErrorDoesNotRespondToSelector, errorDesc);
        return NO;
    }

    // class_isMetaClass 先判断是不是元类。如果是元类则判断元类里能否允许被替换方法。
    if (class_isMetaClass(object_getClass(self))) {
        Class klass = [self class];
        NSMutableDictionary *swizzledClassesDict = aspect_getSwizzledClassesDict();
        Class currentClass = [self class];

        AspectTracker *tracker = swizzledClassesDict[currentClass];
        // subclassHasHookedSelectorName会判断当前tracker的subclass里面是否包含selectorName。因为一个方法在一个类的层级里面只能被hook一次。如果已经tracker里面已经包含了一次，那么会报错。
        if ([tracker subclassHasHookedSelectorName:selectorName]) {
            NSSet *subclassTracker = [tracker subclassTrackersHookingSelectorName:selectorName];
            NSSet *subclassNames = [subclassTracker valueForKey:@"trackedClassName"];
            NSString *errorDescription = [NSString stringWithFormat:@"Error: %@ already hooked subclasses: %@. A method can only be hooked once per class hierarchy.", selectorName, subclassNames];
            AspectError(AspectErrorSelectorAlreadyHookedInClassHierarchy, errorDescription);
            return NO;
        }

        //在这个do-while循环中，currentClass = class_getSuperclass(currentClass)这个判断会从currentClass的superclass开始，一直往上找，直到这个类为根类NSObject。
        do {
            tracker = swizzledClassesDict[currentClass];
            if ([tracker.selectorNames containsObject:selectorName]) {
                if (klass == currentClass) {
                    // Already modified and topmost!
                    return YES;
                }
                NSString *errorDescription = [NSString stringWithFormat:@"Error: %@ already hooked in %@. A method can only be hooked once per class hierarchy.", selectorName, NSStringFromClass(currentClass)];
                AspectError(AspectErrorSelectorAlreadyHookedInClassHierarchy, errorDescription);
                return NO;
            }
        } while ((currentClass = class_getSuperclass(currentClass)));
        
        // 注意:经过上面合法性hook判断和类方法不允许重复替换的检查后，到此，就可以把要hook的信息记录下来，用AspectTracker标记。在标记过程中，一旦子类被更改，父类也需要跟着一起被标记。do-while的终止条件还是currentClass = class_getSuperclass(currentClass)。
        
        

        // Add the selector as being modified.
        currentClass = klass;
        AspectTracker *subclassTracker = nil;
        do {
            tracker = swizzledClassesDict[currentClass];
            if (!tracker) {
                tracker = [[AspectTracker alloc] initWithTrackedClass:currentClass];
                swizzledClassesDict[(id<NSCopying>)currentClass] = tracker;
            }
            if (subclassTracker) {
                [tracker addSubclassTracker:subclassTracker hookingSelectorName:selectorName];
            } else {
                [tracker.selectorNames addObject:selectorName];
            }

            // All superclasses get marked as having a subclass that is modified.
            subclassTracker = tracker;
        }while ((currentClass = class_getSuperclass(currentClass)));
	} else {
		return YES;
	}

    return YES;
}

static void aspect_deregisterTrackedSelector(id self, SEL selector) {
    if (!class_isMetaClass(object_getClass(self))) return;

    NSMutableDictionary *swizzledClassesDict = aspect_getSwizzledClassesDict();
    NSString *selectorName = NSStringFromSelector(selector);
    Class currentClass = [self class];
    AspectTracker *subclassTracker = nil;
    do {
        AspectTracker *tracker = swizzledClassesDict[currentClass];
        if (subclassTracker) {
            [tracker removeSubclassTracker:subclassTracker hookingSelectorName:selectorName];
        } else {
            [tracker.selectorNames removeObject:selectorName];
        }
        if (tracker.selectorNames.count == 0 && tracker.selectorNamesToSubclassTrackers) {
            [swizzledClassesDict removeObjectForKey:currentClass];
        }
        subclassTracker = tracker;
    }while ((currentClass = class_getSuperclass(currentClass)));
}

@end

@implementation AspectTracker

- (id)initWithTrackedClass:(Class)trackedClass {
    if (self = [super init]) {
        _trackedClass = trackedClass;
        _selectorNames = [NSMutableSet new];
        _selectorNamesToSubclassTrackers = [NSMutableDictionary new];
    }
    return self;
}

- (BOOL)subclassHasHookedSelectorName:(NSString *)selectorName {
    return self.selectorNamesToSubclassTrackers[selectorName] != nil;
}

- (void)addSubclassTracker:(AspectTracker *)subclassTracker hookingSelectorName:(NSString *)selectorName {
    NSMutableSet *trackerSet = self.selectorNamesToSubclassTrackers[selectorName];
    if (!trackerSet) {
        trackerSet = [NSMutableSet new];
        self.selectorNamesToSubclassTrackers[selectorName] = trackerSet;
    }
    [trackerSet addObject:subclassTracker];
}
- (void)removeSubclassTracker:(AspectTracker *)subclassTracker hookingSelectorName:(NSString *)selectorName {
    NSMutableSet *trackerSet = self.selectorNamesToSubclassTrackers[selectorName];
    [trackerSet removeObject:subclassTracker];
    if (trackerSet.count == 0) {
        [self.selectorNamesToSubclassTrackers removeObjectForKey:selectorName];
    }
}
- (NSSet *)subclassTrackersHookingSelectorName:(NSString *)selectorName {
    NSMutableSet *hookingSubclassTrackers = [NSMutableSet new];
    for (AspectTracker *tracker in self.selectorNamesToSubclassTrackers[selectorName]) {
        if ([tracker.selectorNames containsObject:selectorName]) {
            [hookingSubclassTrackers addObject:tracker];
        }
        [hookingSubclassTrackers unionSet:[tracker subclassTrackersHookingSelectorName:selectorName]];
    }
    return hookingSubclassTrackers;
}
- (NSString *)trackedClassName {
    return NSStringFromClass(self.trackedClass);
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %@, trackedClass: %@, selectorNames:%@, subclass selector names: %@>", self.class, self, NSStringFromClass(self.trackedClass), self.selectorNames, self.selectorNamesToSubclassTrackers.allKeys];
}

@end

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - NSInvocation (Aspects)

@implementation NSInvocation (Aspects)

// Thanks to the ReactiveCocoa team for providing a generic solution for this.
- (id)aspect_argumentAtIndex:(NSUInteger)index {
	const char *argType = [self.methodSignature getArgumentTypeAtIndex:index];
	// Skip const type qualifier.
	if (argType[0] == _C_CONST) argType++;

#define WRAP_AND_RETURN(type) do { type val = 0; [self getArgument:&val atIndex:(NSInteger)index]; return @(val); } while (0)
	if (strcmp(argType, @encode(id)) == 0 || strcmp(argType, @encode(Class)) == 0) {
		__autoreleasing id returnObj;
		[self getArgument:&returnObj atIndex:(NSInteger)index];
		return returnObj;
	} else if (strcmp(argType, @encode(SEL)) == 0) {
        SEL selector = 0;
        [self getArgument:&selector atIndex:(NSInteger)index];
        return NSStringFromSelector(selector);
    } else if (strcmp(argType, @encode(Class)) == 0) {
        __autoreleasing Class theClass = Nil;
        [self getArgument:&theClass atIndex:(NSInteger)index];
        return theClass;
        // Using this list will box the number with the appropriate constructor, instead of the generic NSValue.
	} else if (strcmp(argType, @encode(char)) == 0) {
		WRAP_AND_RETURN(char);
	} else if (strcmp(argType, @encode(int)) == 0) {
		WRAP_AND_RETURN(int);
	} else if (strcmp(argType, @encode(short)) == 0) {
		WRAP_AND_RETURN(short);
	} else if (strcmp(argType, @encode(long)) == 0) {
		WRAP_AND_RETURN(long);
	} else if (strcmp(argType, @encode(long long)) == 0) {
		WRAP_AND_RETURN(long long);
	} else if (strcmp(argType, @encode(unsigned char)) == 0) {
		WRAP_AND_RETURN(unsigned char);
	} else if (strcmp(argType, @encode(unsigned int)) == 0) {
		WRAP_AND_RETURN(unsigned int);
	} else if (strcmp(argType, @encode(unsigned short)) == 0) {
		WRAP_AND_RETURN(unsigned short);
	} else if (strcmp(argType, @encode(unsigned long)) == 0) {
		WRAP_AND_RETURN(unsigned long);
	} else if (strcmp(argType, @encode(unsigned long long)) == 0) {
		WRAP_AND_RETURN(unsigned long long);
	} else if (strcmp(argType, @encode(float)) == 0) {
		WRAP_AND_RETURN(float);
	} else if (strcmp(argType, @encode(double)) == 0) {
		WRAP_AND_RETURN(double);
	} else if (strcmp(argType, @encode(BOOL)) == 0) {
		WRAP_AND_RETURN(BOOL);
	} else if (strcmp(argType, @encode(bool)) == 0) {
		WRAP_AND_RETURN(BOOL);
	} else if (strcmp(argType, @encode(char *)) == 0) {
		WRAP_AND_RETURN(const char *);
	} else if (strcmp(argType, @encode(void (^)(void))) == 0) {
		__unsafe_unretained id block = nil;
		[self getArgument:&block atIndex:(NSInteger)index];
		return [block copy];
	} else {
		NSUInteger valueSize = 0;
		NSGetSizeAndAlignment(argType, &valueSize, NULL);

		unsigned char valueBytes[valueSize];
		[self getArgument:valueBytes atIndex:(NSInteger)index];

		return [NSValue valueWithBytes:valueBytes objCType:argType];
	}
	return nil;
#undef WRAP_AND_RETURN
}

- (NSArray *)aspects_arguments {
	NSMutableArray *argumentsArray = [NSMutableArray array];
	for (NSUInteger idx = 2; idx < self.methodSignature.numberOfArguments; idx++) {
		[argumentsArray addObject:[self aspect_argumentAtIndex:idx] ?: NSNull.null];
	}
	return [argumentsArray copy];
}

@end

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - AspectIdentifier

@implementation AspectIdentifier

+ (instancetype)identifierWithSelector:(SEL)selector object:(id)object options:(AspectOptions)options block:(id)block error:(NSError **)error {
    NSCParameterAssert(block);
    NSCParameterAssert(selector);
    // 获取block签名信息 (把传递进来的AspectBlock转换成NSMethodSignature的方法签名)
    NSMethodSignature *blockSignature = aspect_blockMethodSignature(block, error); // TODO: check signature compatibility, etc.
    
    // block签名和方法签名是不同的，所以需要比较签名信息
    if (!aspect_isCompatibleBlockSignature(blockSignature, object, selector, error)) {
        return nil;
    }
    
    // 如果这里匹配成功了，就会blockSignature全部都赋值给AspectIdentifier。这也就是为何AspectIdentifier里面有一个单独的属性NSMethodSignature的原因。
    AspectIdentifier *identifier = nil;
    if (blockSignature) {
        identifier = [AspectIdentifier new];
        identifier.selector = selector;
        identifier.block = block;
        identifier.blockSignature = blockSignature;
        identifier.options = options;
        identifier.object = object; // weak
    }
    return identifier;
}

/*  把blockSignature初始化得到invocation。然后处理参数，如果参数block中的参数大于1个，则把传入的AspectInfo放入blockInvocation中。然后从originalInvocation中取出参数给blockInvocation赋值。最后调用[blockInvocation invokeWithTarget:self.block];这里Target设置为self.block。也就执行了我们hook方法的block。
 */
- (BOOL)invokeWithInfo:(id<AspectInfo>)info {
    NSInvocation *blockInvocation = [NSInvocation invocationWithMethodSignature:self.blockSignature];
    
    
    NSInvocation *originalInvocation = info.originalInvocation;
    NSUInteger numberOfArguments = self.blockSignature.numberOfArguments;

    // Be extra paranoid. We already check that on hook registration.
    
    if (numberOfArguments > originalInvocation.methodSignature.numberOfArguments) {
        AspectLogError(@"Block has too many arguments. Not calling %@", info);
        return NO;
    }

    // The `self` of the block will be the AspectInfo. Optional.
    // 把AspectInfo存入到blockInvocation中,作为第一个参数
    if (numberOfArguments > 1) {
        [blockInvocation setArgument:&info atIndex:1];
    }
    
	void *argBuf = NULL;
    for (NSUInteger idx = 2; idx < numberOfArguments; idx++) {
        const char *type = [originalInvocation.methodSignature getArgumentTypeAtIndex:idx];
		NSUInteger argSize;
		NSGetSizeAndAlignment(type, &argSize, NULL);
        
		if (!(argBuf = reallocf(argBuf, argSize))) {
            AspectLogError(@"Failed to allocate memory for block invocation.");
			return NO;
		}
        
		[originalInvocation getArgument:argBuf atIndex:idx];
		[blockInvocation setArgument:argBuf atIndex:idx];
    }
    //执行block
    [blockInvocation invokeWithTarget:self.block];
    
    
    if (argBuf != NULL) {
        free(argBuf);
    }
    return YES;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p, SEL:%@ object:%@ options:%tu block:%@ (#%tu args)>", self.class, self, NSStringFromSelector(self.selector), self.object, self.options, self.block, self.blockSignature.numberOfArguments];
}

- (BOOL)remove {
    return aspect_remove(self, NULL);
}

@end

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - AspectsContainer

@implementation AspectsContainer

- (BOOL)hasAspects {
    return self.beforeAspects.count > 0 || self.insteadAspects.count > 0 || self.afterAspects.count > 0;
}

// 根据传入的切面时机,进行对应数组的存储;
- (void)addAspect:(AspectIdentifier *)aspect withOptions:(AspectOptions)options {
    NSParameterAssert(aspect);
    NSUInteger position = options&AspectPositionFilter;
    switch (position) {
        case AspectPositionBefore:  self.beforeAspects  = [(self.beforeAspects ?:@[]) arrayByAddingObject:aspect]; break;
        case AspectPositionInstead: self.insteadAspects = [(self.insteadAspects?:@[]) arrayByAddingObject:aspect]; break;
        case AspectPositionAfter:   self.afterAspects   = [(self.afterAspects  ?:@[]) arrayByAddingObject:aspect]; break;
    }
}

- (BOOL)removeAspect:(id)aspect {
    for (NSString *aspectArrayName in @[NSStringFromSelector(@selector(beforeAspects)),
                                        NSStringFromSelector(@selector(insteadAspects)),
                                        NSStringFromSelector(@selector(afterAspects))]) {
        NSArray *array = [self valueForKey:aspectArrayName];
        NSUInteger index = [array indexOfObjectIdenticalTo:aspect];
        if (array && index != NSNotFound) {
            NSMutableArray *newArray = [NSMutableArray arrayWithArray:array];
            [newArray removeObjectAtIndex:index];
            [self setValue:newArray forKey:aspectArrayName];
            return YES;
        }
    }
    return NO;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p, before:%@, instead:%@, after:%@>", self.class, self, self.beforeAspects, self.insteadAspects, self.afterAspects];
}

@end

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - AspectInfo

@implementation AspectInfo

@synthesize arguments = _arguments;

- (id)initWithInstance:(__unsafe_unretained id)instance invocation:(NSInvocation *)invocation {
    NSCParameterAssert(instance);
    NSCParameterAssert(invocation);
    if (self = [super init]) {
        _instance = instance;
        _originalInvocation = invocation;
    }
    return self;
}

- (NSArray *)arguments {
    // Lazily evaluate arguments, boxing is expensive.
    if (!_arguments) {
        _arguments = self.originalInvocation.aspects_arguments;
    }
    return _arguments;
}

@end
