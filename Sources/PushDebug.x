// PushDebug.x
//
// Diagnostic only. Shows ONE alert ~12s after Discord becomes active, summarizing:
//   - whether the running process actually has the aps-environment entitlement
//   - whether iOS notification permission is granted
//   - whether the app asked to register for remote notifications
//   - whether Apple's push service answered with a device token or an error (and the error text)
//
// It does not change how Discord behaves; it only observes. Remove this file once the
// notification problem is diagnosed.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <dlfcn.h>
#import <objc/runtime.h>

#import "Logger.h"
#import "Utils.h"

static NSString *gEntitlement    = @"unknown";
static NSString *gAuthStatus     = @"unknown";
static NSString *gRegisterCalled = @"no";
static NSString *gRegResult      = @"no callback received (neither token nor error)";
static NSString *gDelegateClass  = @"unknown";
static NSString *gDelegateHooks  = @"none";

// Reads the entitlement the *running process* really has (not what the IPA claims).
static NSString *readApsEntitlement(void)
{
    typedef void *(*CreateFn)(CFAllocatorRef);
    typedef CFTypeRef (*CopyFn)(void *, CFStringRef, CFErrorRef *);

    CreateFn create = (CreateFn) dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
    CopyFn   copy   = (CopyFn) dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    if (!create || !copy)
        return @"could not look up SecTask functions";

    void *task = create(kCFAllocatorDefault);
    if (!task)
        return @"could not create SecTask";

    CFTypeRef value = copy(task, CFSTR("aps-environment"), NULL);
    if (!value)
        value = copy(task, CFSTR("com.apple.developer.aps-environment"), NULL);
    CFRelease(task);

    if (!value)
        return @"MISSING at runtime";

    NSString *result = [NSString stringWithFormat:@"%@", (__bridge id) value];
    CFRelease(value);
    return result;
}

static NSString *describeAuth(UNAuthorizationStatus status)
{
    switch (status)
    {
        case UNAuthorizationStatusNotDetermined:
            return @"not determined (permission never asked)";
        case UNAuthorizationStatusDenied:
            return @"DENIED";
        case UNAuthorizationStatusAuthorized:
            return @"authorized";
        case UNAuthorizationStatusProvisional:
            return @"provisional";
        case UNAuthorizationStatusEphemeral:
            return @"ephemeral";
        default:
            return [NSString stringWithFormat:@"unknown (%ld)", (long) status];
    }
}

// Wrap the app delegate's push callbacks so we can see what happened, then call the original.
static void hookDelegateClass(Class cls)
{
    static NSMutableSet *done = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ done = [NSMutableSet new]; });

    NSString *name = NSStringFromClass(cls);
    if ([done containsObject:name])
        return;
    [done addObject:name];
    gDelegateClass = name;

    NSMutableArray *hooked = [NSMutableArray new];

    SEL okSel = @selector(application:didRegisterForRemoteNotificationsWithDeviceToken:);
    Method okMethod = class_getInstanceMethod(cls, okSel);
    if (okMethod)
    {
        IMP orig = method_getImplementation(okMethod);
        IMP replacement = imp_implementationWithBlock(^(id selfObj, UIApplication *app, NSData *token) {
            gRegResult = [NSString stringWithFormat:@"SUCCESS: Apple issued a device token (%lu bytes)",
                                                    (unsigned long) token.length];
            BunnyLog(@"[PushDebug] %@", gRegResult);
            ((void (*)(id, SEL, UIApplication *, NSData *)) orig)(selfObj, okSel, app, token);
        });
        method_setImplementation(okMethod, replacement);
        [hooked addObject:@"token"];
    }

    SEL failSel = @selector(application:didFailToRegisterForRemoteNotificationsWithError:);
    Method failMethod = class_getInstanceMethod(cls, failSel);
    if (failMethod)
    {
        IMP orig = method_getImplementation(failMethod);
        IMP replacement = imp_implementationWithBlock(^(id selfObj, UIApplication *app, NSError *error) {
            gRegResult = [NSString stringWithFormat:@"FAILED: %@ (domain %@, code %ld)",
                                                    error.localizedDescription, error.domain,
                                                    (long) error.code];
            BunnyLog(@"[PushDebug] %@", gRegResult);
            ((void (*)(id, SEL, UIApplication *, NSError *)) orig)(selfObj, failSel, app, error);
        });
        method_setImplementation(failMethod, replacement);
        [hooked addObject:@"error"];
    }

    gDelegateHooks = hooked.count ? [hooked componentsJoinedByString:@", "]
                                  : @"delegate does not implement the push callbacks";
}

static void showPushSummary(void)
{
    gEntitlement = readApsEntitlement();

    [[UNUserNotificationCenter currentNotificationCenter]
        getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
            gAuthStatus = describeAuth(settings.authorizationStatus);

            NSString *message = [NSString
                stringWithFormat:@"aps-environment (runtime): %@\n"
                                 @"Notification permission: %@\n"
                                 @"App called registerForRemoteNotifications: %@\n"
                                 @"Registration result: %@\n"
                                 @"App delegate: %@ (hooked: %@)",
                                 gEntitlement, gAuthStatus, gRegisterCalled, gRegResult,
                                 gDelegateClass, gDelegateHooks];

            BunnyLog(@"[PushDebug]\n%@", message);
            dispatch_async(dispatch_get_main_queue(), ^{ showErrorAlert(@"Push Debug", message, nil); });
        }];
}

%hook UIApplication

- (void)setDelegate:(id<UIApplicationDelegate>)delegate
{
    %orig;
    if (delegate)
        hookDelegateClass([(NSObject *) delegate class]);
}

- (void)registerForRemoteNotifications
{
    gRegisterCalled = @"yes";
    BunnyLog(@"[PushDebug] registerForRemoteNotifications called");
    %orig;
}

%end

%ctor
{
    %init;

    __block id observer = nil;
    observer = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
                    [[NSNotificationCenter defaultCenter] removeObserver:observer];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (12 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{ showPushSummary(); });
                }];
}
