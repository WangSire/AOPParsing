# AOPParsing

###1. 什么是AOP

AOP: `Aspect Oriented Programming` 面向切面编程。通过预编译方式和运行期动态代理实现程序功能的统一维护的一种技术，针对业务处理过程中的切面进行提取，它所面对的是处理过程中的某个步骤或阶段，以获得逻辑过程中各部分之间低耦合性的隔离效果（在不修改源代码的情况下，通过运行时给程序添加统一功能！）
###2. Aspects实现原理
Aspects是利用了OC的`消息转发机制`！如果是实例对象，则使用runtime动态创建对象的子类，在子类中使用swizzling method的方式，添加一个别名SEL来记录被hook的SEL，然后把子类或类对象中的`forwardInvocation`的IMP替成`__ASPECTS_ARE_BEING_CALLED__`，如果是类对象则只是方法替换，在`__ASPECTS_ARE_BEING_CALLED__`中进行拦截处理！

消息转发流程
>2.1` resolveInstanceMethod`(或`resolveClassMethod`)：实现该方法，可以通过class_addMethod添加方法，返回YES的话系统在运行时就会重新启动一次消息发送的过程，NO的话会继续执行下一个方法。
2.2 `forwardingTargetForSelector`：实现该方法可以将消息转发给其他对象，只要这个方法返回的不是nil或self，也会重启消息发送的过程，把这消息转发给其他对象来处理。
2.3 `methodSignatureForSelector`：会去获取一个方法签名，如果没有获取到的话就直接调用`doesNotRecognizeSelector`，如果能获取的话系统就会创建一个`NSlnvocation`传给`forwardInvocation`方法。
2.4 `forwardInvocation`：该方法是上一个步传进来的`NSlnvocation`，然后调用`NSlnvocation`的`invokeWithTarget`方法，转发到对应的Target。
2.5 `doesNotRecognizeSelector`：抛出unrecognized selector sent to …异常。

Aspects大体流程
>比如要hook的方法名为obtainImageName，如果是实例对象则动态创建一个子类(hook操作在子类操作)，如果是类对象（通过该对象的isa的指向来判断是否是元类)或者被KVO过的对象，则不会创建子类，并`把类中的forwardInvocation的IMP替换为__ASPECTS_ARE_BEING_CALLED__（如果被hook类中有forwardInvocation的实现，则会添加一个新方法Aspects_forwardInvocation，指向了原来的forwardInvocation，如果在__ASPECTS_ARE_BEING_CALLED__中不能处理，则执行该事件!）`在子类或类对象中添加一个Aspects_obtainImageName的方法，然后`将Aspects_obtainImageName的IMP指向原来的obtainImageName方法的IMP`（保存原方法实现，后面要调用），再把`被hook的方法obtainImageName的IMP指向_objc_msgForward`，这样就进入了消息转发流程，而forwardInvocation的IMP被替换成了__ASPECTS_ARE_BEING_CALLED__，这样就会进入__ASPECTS_ARE_BEING_CALLED__进行拦截处理，当消息转发完成后，销毁hook逻辑，并将被hook类中的obtainImageName方法的IMP指回原IMP，删除别名SEL，整个流程结束！
###3. Aspects 中4个基本类简要概述
-  `AspectInfo`：主要是存储被hook对象NSInvocation 中信息，包含：对象的实例，方法参数信息等
-  `AspectIdentifier`：每进行一个hook，都会生成一个AspectIdentifier对象，包含：方法，切入时机，签名信息，插入的block等具体信息
-  `AspectsContainer`：用于盛放AspectIdentifier对象,key为别名SEL,然后关联对象存储到对应的类中 (每一个别名SEL对应一个该对象)
-  `AspectTracker`：跟踪一个类的继承链中的hook状态：包括被hook的类，哪些SEL被hook了。(每一个class对应一个AspectTracker)
###4. 主要代码介绍
4.1 准备工作
```
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
            
            // 可能会创建失败，那就是aspect_isCompatibleBlockSignature方法返回NO。返回NO就意味着，我们要替换的方法block和要替换的原方法，两者的方法签名是不相符的。
            if (identifier) {
                
                // 完成了容器和AspectIdentifier初始化之后，就可以开始准备进行hook了。通过options选项分别添加到容器中的beforeAspects,insteadAspects,afterAspects这三个数组
                [aspectContainer addAspect:identifier withOptions:options];

               // 动态生成子类(带有_Aspects_后缀的子类),并交换类的原方法的实现为_objc_msgForward 使其直接进入消息转发模式
                aspect_prepareClassAndHookSelector(self, selector, error);
            }
        }
    });
    return identifier;
}
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
        // 交换类的原方法的实现为_objc_msgForward
        class_replaceMethod(klass, selector, aspect_getMsgForwardIMP(self, selector), typeEncoding);
        AspectLog(@"Aspects: Installed hook for -[%@ %@].", klass, NSStringFromSelector(selector));
    }
}
```
- 首先调用aspect_performLocked ，利用自旋锁，保证整个操作的线程安全
- 调用aspect_isSelectorAllowedAndTrack对传进来的参数进行强校验，保证参数合法性。
- 创建AspectsContainer容器，利用AssociatedObject关联对象动态添加到NSObject分类中作为属性的。
 - 由入参selector，option创建AspectIdentifier实例。
 - 将单个的 AspectIdentifier 的具体信息加到属性AspectsContainer容器中。通过options选项分别添加到容器中的beforeAspects,insteadAspects,afterAspects这三个数组。
- 调用prepareClassAndHookSelector准备hook。
- 如果是类对象则动态创建一个子类（如果是元类或者被KVO过的对象，则不会创建子类），把类中的forwardInvocation的IMP替换为ASPECTS_ARE_BEING_CALLED
- 对selector进行hook，首先获取到原来的方法，然后判断是否指向了_objc_msgForward，没有的话，就获取原方法的MethodIMP，给该类添加一个方法aspects__xx，并将aspects__xx的IMP指向原方法，再把原方法的IMP指向_objc_msgForward，hook完毕。


4.2 消息转发逻辑处理
```
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

//宏内容
#define aspect_invoke(aspects, info) \
for (AspectIdentifier *aspect in aspects) {\
    [aspect invokeWithInfo:info];\
    if (aspect.options & AspectOptionAutomaticRemoval) { \
        aspectsToRemove = [aspectsToRemove?:@[] arrayByAddingObject:aspect]; \
    } \
}

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
```
- 获取数据传递到aspect_invoke里面，调用invokeWithInfo，执行切面代码块，执行完代码块以后，获取到新创建的类，判断是否可以响应aspects__xxxx方法，现在aspects__xxxx方法指向的是原来方法实现的IMP，如果可以响应，就通过[invocation invoke]；调用这个方法,如果不能响应就调用__aspects_forwardInvocation：这个方法，这个方法在hookClass的时候提到了，它的IMP指针指向了原来类中的forwardInvocation：判断是否可以响应，如果可以就去执行，不能响应就抛出异常doesNotRecognizeSelector!
- 把需要remove的Aspects加入等待被移除的数组中


4.3 销毁Aspect流程
```
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
```
- 调用remove方法，把AspectsContainer都置为空，remove最关键的过程就是aspect_cleanupHookedClassAndSelector(self, aspect.selector)！移除之前hook的class和selector。
```
static void aspect_cleanupHookedClassAndSelector(NSObject *self, SEL selector) {
    NSCParameterAssert(self);
    NSCParameterAssert(selector);

    // klass是现在的class(原来的类)，如果是元类，就转换成元类。
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
```
- 判断类中被hook的方法，IMP是不是指向了_objc_msgForward，如果是，就把该方法的IMP再指回去。
- 移除AspectTracker里面所有标记的swizzledClassesDict以及记录的selector。
- 如果是动态新建的子类，那么把该类的isa指针指向原类！
- 销毁了AspectsContainer容器，并且把关联对象也置成了nil。


###5. 注意事项
- Aspects是不支持hook 静态static方法的
- 不要把Aspects加到经常被使用的方法里面，因为Aspects利用的是消息转发机制，会有一些性能开销！切记不要在for循环这些方法中使用！！
- 在一个继承链上，一个selector只能被hook一次。
- 如果有使用JSPatch的话会有冲突，因为它也是采用的这种方案！比如说JSPatch把传入的 selector 先被 JSPatch hook ,那么，这里我们将不会再处理,也就`不会生成 aliasSelector` ，在消息转发中，会找不到aliasSelector 的实现，而发生崩溃！`可以通过给被hook的类添加forwardInvocation的实现来解决该冲突！`

######最后附上一张流程图
![流程图.png](https://upload-images.jianshu.io/upload_images/4053175-0fc484a3097bc18e.png?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)
