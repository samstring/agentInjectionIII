#import "AgentTraceBridge.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <sys/socket.h>
#import <unistd.h>
#import <dlfcn.h>

typedef void (^AgentSwiftTraceOutput)(
    NSString *text,
    const void * _Nullable object,
    NSInteger indent
);


@interface AgentTraceBridge ()
+ (void)sendJSONObject:(NSDictionary *)object;
+ (BOOL)installXCTestObserverIfAvailable;
+ (NSArray * _Nullable)xprobePathsIfAvailable;
+ (NSDictionary * _Nullable)xprobeObjectAtIndex:(NSUInteger)index
                                           paths:(NSArray *)paths;
@end

@interface AgentInjectedTestObserver : NSObject
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSMutableDictionary *> *states;
@end

@implementation AgentInjectedTestObserver

- (instancetype)init {
    self = [super init];
    if (self) {
        _states = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSString *)nameForTest:(id)test {
    @try {
        id name = [test valueForKey:@"name"];
        if ([name isKindOfClass:NSString.class] &&
            [name length] != 0) {
            return name;
        }
    } @catch (__unused NSException *exception) {
    }
    return NSStringFromClass([test class]);
}

- (NSMutableDictionary *)stateForTest:(id)test
                               create:(BOOL)create {
    NSString *name = [self nameForTest:test];
    NSMutableDictionary *state = self.states[name];
    if (!state && create) {
        state = [@{
            @"started":
                @([NSDate timeIntervalSinceReferenceDate]),
            @"messages":
                [NSMutableArray array]
        } mutableCopy];
        self.states[name] = state;
    }
    return state;
}

- (void)testCaseWillStart:(id)testCase {
    @synchronized (self) {
        [self stateForTest:testCase create:YES];
    }
}

- (void)recordFailureForTest:(id)testCase
                     message:(NSString *)message {
    if (message.length == 0) {
        return;
    }

    @synchronized (self) {
        NSMutableDictionary *state =
            [self stateForTest:testCase create:YES];
        NSMutableArray *messages = state[@"messages"];
        if (![messages containsObject:message]) {
            [messages addObject:message];
        }
    }
}

- (void)testCase:(id)testCase
didFailWithDescription:(NSString *)description
          inFile:(NSString *)filePath
          atLine:(NSUInteger)line {
    NSString *message = description ?: @"XCTest failure";
    if (filePath.length != 0) {
        message = [NSString stringWithFormat:
            @"%@ (%@:%lu)",
            message,
            filePath,
            (unsigned long)line
        ];
    }
    [self recordFailureForTest:testCase
                       message:message];
}

- (void)testCase:(id)testCase
  didRecordIssue:(id)issue {
    NSString *message = nil;
    @try {
        id compact = [issue valueForKey:@"compactDescription"];
        if ([compact isKindOfClass:NSString.class]) {
            message = compact;
        }
    } @catch (__unused NSException *exception) {
    }

    if (message.length == 0) {
        message = [issue description]
            ?: @"XCTest issue";
    }

    [self recordFailureForTest:testCase
                       message:message];
}

- (void)testCaseDidFinish:(id)testCase {
    NSString *name = [self nameForTest:testCase];
    NSTimeInterval now =
        [NSDate timeIntervalSinceReferenceDate];

    NSMutableDictionary *state = nil;
    @synchronized (self) {
        state = self.states[name];
        [self.states removeObjectForKey:name];
    }

    NSNumber *started = state[@"started"];
    NSArray *messages = state[@"messages"] ?: @[];
    NSTimeInterval duration =
        started ? now - started.doubleValue : 0;

    [AgentTraceBridge sendJSONObject:@{
        @"type": @"test_result",
        @"timestamp": @(now),
        @"testName": name ?: @"(unknown test)",
        @"passed": @(messages.count == 0),
        @"failures": @(messages.count),
        @"durationSeconds": @(duration),
        @"messages": messages
    }];
}

@end

static AgentInjectedTestObserver *AgentXCTestObserver;
static BOOL AgentXCTestObserverInstalled = NO;

@implementation AgentTraceBridge

static int AgentTraceSocket = -1;
static dispatch_queue_t AgentTraceWriteQueue;
static dispatch_queue_t AgentTraceLifetimeQueue;
static dispatch_once_t AgentTraceStartOnce;
static BOOL AgentTraceOutputInstalled = NO;

+ (void)start {
#if DEBUG
    dispatch_once(&AgentTraceStartOnce, ^{
        AgentTraceWriteQueue = dispatch_queue_create(
            "agentInjectionIII.trace-write",
            DISPATCH_QUEUE_SERIAL
        );
        AgentTraceLifetimeQueue = dispatch_queue_create(
            "agentInjectionIII.lifetime",
            DISPATCH_QUEUE_SERIAL
        );

        dispatch_async(
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
            ^{
                [self connectAndRun];
            }
        );
    });
#endif
}

+ (void)connectAndRun {
    NSString *host =
        NSProcessInfo.processInfo.environment[@"AGENT_INJECTION_TRACE_HOST"]
        ?: @"127.0.0.1";

    NSInteger port =
        [NSProcessInfo.processInfo.environment[@"AGENT_INJECTION_TRACE_PORT"]
            integerValue];
    if (port <= 0 || port > UINT16_MAX) {
        port = 8888;
    }

    int socketFD = -1;

    // Retry because app launch and daemon startup can race during development.
    for (NSInteger attempt = 0; attempt < 20 && socketFD < 0; attempt++) {
        socketFD = [self connectToHost:host port:(uint16_t)port];
        if (socketFD < 0) {
            [NSThread sleepForTimeInterval:0.5];
        }
    }

    if (socketFD < 0) {
        NSLog(@"[agentInjectionIII] Trace bridge could not connect to %@:%ld",
              host, (long)port);
        return;
    }

    AgentTraceSocket = socketFD;

    // The server validates the first frame before accepting this bridge.
    [self sendJSONObject:@{
        @"type": @"hello",
        @"protocol": @1,
        @"timestamp": @([NSDate timeIntervalSinceReferenceDate])
    }];

    [self installSwiftTraceOutput];

    dispatch_async(
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
        ^{
            while (AgentTraceSocket >= 0 &&
                   !AgentXCTestObserverInstalled) {
                if ([self installXCTestObserverIfAvailable]) {
                    break;
                }
                [NSThread sleepForTimeInterval:0.5];
            }
        }
    );

    [self readCommandLoop:socketFD];

    close(socketFD);
    if (AgentTraceSocket == socketFD) {
        AgentTraceSocket = -1;
    }
}

+ (int)connectToHost:(NSString *)host port:(uint16_t)port {
    struct addrinfo hints = {0};
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;

    NSString *portString = [NSString stringWithFormat:@"%u", port];
    struct addrinfo *addresses = NULL;

    int lookup = getaddrinfo(
        host.UTF8String,
        portString.UTF8String,
        &hints,
        &addresses
    );
    if (lookup != 0 || addresses == NULL) {
        return -1;
    }

    int socketFD = -1;

    for (struct addrinfo *entry = addresses;
         entry != NULL;
         entry = entry->ai_next) {
        int candidate = socket(
            entry->ai_family,
            entry->ai_socktype,
            entry->ai_protocol
        );
        if (candidate < 0) {
            continue;
        }

        int yes = 1;
        setsockopt(
            candidate,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &yes,
            sizeof yes
        );

        if (connect(
                candidate,
                entry->ai_addr,
                (socklen_t)entry->ai_addrlen
            ) == 0) {
            socketFD = candidate;
            break;
        }

        close(candidate);
    }

    freeaddrinfo(addresses);
    return socketFD;
}

+ (BOOL)installXCTestObserverIfAvailable {
    // XCTestObservationCenter enforces main-thread registration.
    // The trace bridge connects from a utility queue, so centralize the
    // thread hop here instead of relying on every caller to remember it.
    if (![NSThread isMainThread]) {
        __block BOOL installed = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            installed = [self installXCTestObserverIfAvailable];
        });
        return installed;
    }

    @synchronized (self) {
        if (AgentXCTestObserverInstalled) {
            return YES;
        }

        Class centerClass =
            NSClassFromString(@"XCTestObservationCenter");
        SEL sharedSelector =
            NSSelectorFromString(
                @"sharedTestObservationCenter"
            );
        SEL addSelector =
            NSSelectorFromString(@"addTestObserver:");

        if (!centerClass ||
            ![centerClass
                respondsToSelector:sharedSelector]) {
            return NO;
        }

        typedef id (*ObjectSend)(id, SEL);
        id center =
            ((ObjectSend)objc_msgSend)(
                centerClass,
                sharedSelector
            );

        if (!center ||
            ![center respondsToSelector:addSelector]) {
            return NO;
        }

        Protocol *observationProtocol =
            NSProtocolFromString(@"XCTestObservation");
        if (!observationProtocol) {
            return NO;
        }

        Class observerClass =
            AgentInjectedTestObserver.class;
        if (!class_conformsToProtocol(
                observerClass,
                observationProtocol
            )) {
            if (!class_addProtocol(
                    observerClass,
                    observationProtocol
                )) {
                NSLog(
                    @"[agentInjectionIII] Unable to add XCTestObservation conformance."
                );
                return NO;
            }
        }

        AgentXCTestObserver =
            [AgentInjectedTestObserver new];

        typedef void (*AddObserverSend)(
            id,
            SEL,
            id
        );
        ((AddObserverSend)objc_msgSend)(
            center,
            addSelector,
            AgentXCTestObserver
        );

        AgentXCTestObserverInstalled = YES;

        [self sendJSONObject:@{
            @"type": @"test_observer",
            @"timestamp":
                @([NSDate timeIntervalSinceReferenceDate])
        }];
        return YES;
    }
}

+ (void)installSwiftTraceOutput {
    Class traceClass = NSClassFromString(@"SwiftTrace");
    SEL setter = NSSelectorFromString(@"setLogOutput:");

    if (!traceClass ||
        ![traceClass respondsToSelector:setter]) {
        NSLog(@"[agentInjectionIII] SwiftTrace.logOutput is unavailable.");
        AgentTraceOutputInstalled = NO;
        return;
    }

    AgentSwiftTraceOutput output =
        ^(NSString *text, const void *object, NSInteger indent) {
            if (text.length == 0) {
                return;
            }

            [AgentTraceBridge sendJSONObject:@{
                @"type": @"event",
                @"timestamp":
                    @([NSDate timeIntervalSinceReferenceDate]),
                @"text": text,
                @"indent": @(indent)
            }];
        };

    typedef void (*SetterSend)(id, SEL, id);
    ((SetterSend)objc_msgSend)(
        traceClass,
        setter,
        [output copy]
    );
    AgentTraceOutputInstalled = YES;
}

+ (NSArray * _Nullable)xprobePathsIfAvailable {
    void *symbol = dlsym(
        RTLD_DEFAULT,
        "xprobePaths"
    );

    // Xprobe is implemented as Objective-C++ in upstream builds, where the
    // global may be emitted with a C++-mangled name.
    if (!symbol) {
        symbol = dlsym(
            RTLD_DEFAULT,
            "_Z11xprobePaths"
        );
    }

    if (!symbol) {
        return nil;
    }

    id __unsafe_unretained *slot =
        (id __unsafe_unretained *)symbol;
    id value = *slot;

    return [value isKindOfClass:NSArray.class]
        ? value
        : nil;
}

+ (NSDictionary * _Nullable)xprobeObjectAtIndex:(NSUInteger)index
                                           paths:(NSArray *)paths {
    if (index >= paths.count) {
        return nil;
    }

    id path = paths[index];
    SEL objectSelector =
        NSSelectorFromString(@"object");
    SEL classSelector =
        NSSelectorFromString(@"aClass");
    SEL pathSelector =
        NSSelectorFromString(@"xpath");

    if (![path respondsToSelector:objectSelector]) {
        return nil;
    }

    typedef id (*ObjectSend)(id, SEL);
    id object =
        ((ObjectSend)objc_msgSend)(
            path,
            objectSelector
        );

    Class aClass = Nil;
    if ([path respondsToSelector:classSelector]) {
        aClass =
            ((Class (*)(id, SEL))objc_msgSend)(
                path,
                classSelector
            );
    }

    NSString *pathString = nil;
    if ([path respondsToSelector:pathSelector]) {
        id value =
            ((ObjectSend)objc_msgSend)(
                path,
                pathSelector
            );
        if ([value isKindOfClass:NSString.class]) {
            pathString = value;
        }
    }

    NSString *className = nil;
    if (object) {
        className = NSStringFromClass(
            [object class]
        );
    } else if (aClass) {
        className = NSStringFromClass(
            aClass
        );
    }
    if (className.length == 0) {
        className = @"(unknown)";
    }

    NSString *description = nil;
    @try {
        description = [object description];
    } @catch (__unused NSException *exception) {
    }
    if (description.length == 0) {
        description = className;
    }
    if (description.length > 2000) {
        description = [[description
            substringToIndex:2000]
            stringByAppendingString:@"…"];
    }

    NSMutableDictionary *result = [@{
        @"id": @(index),
        @"className": className,
        @"description": description
    } mutableCopy];

    if (pathString.length > 0) {
        result[@"path"] = pathString;
    }

    return result;
}

+ (void)readCommandLoop:(int)socketFD {
    NSMutableData *buffer = [NSMutableData data];
    uint8_t chunk[4096];

    while (true) {
        ssize_t count = read(
            socketFD,
            chunk,
            sizeof chunk
        );

        if (count <= 0) {
            return;
        }

        [buffer appendBytes:chunk length:(NSUInteger)count];

        while (true) {
            const uint8_t *bytes = buffer.bytes;
            NSUInteger length = buffer.length;
            NSUInteger newline = NSNotFound;

            for (NSUInteger index = 0; index < length; index++) {
                if (bytes[index] == '\n') {
                    newline = index;
                    break;
                }
            }

            if (newline == NSNotFound) {
                break;
            }

            NSData *line = [buffer subdataWithRange:
                NSMakeRange(0, newline)];

            [buffer replaceBytesInRange:
                NSMakeRange(0, newline + 1)
                withBytes:NULL
                length:0];

            if (line.length == 0) {
                continue;
            }

            NSDictionary *command =
                [NSJSONSerialization JSONObjectWithData:line
                                                options:0
                                                  error:NULL];
            if ([command isKindOfClass:NSDictionary.class]) {
                [self handleCommand:command];
            }
        }

        if (buffer.length > 1024 * 1024) {
            [buffer setLength:0];
        }
    }
}

+ (void)handleCommand:(NSDictionary *)command {
    NSString *action = command[@"action"];

    if ([action isEqualToString:@"xprobe_search"]) {
        NSString *pattern =
            [command[@"filter"] isKindOfClass:NSString.class]
            ? command[@"filter"]
            : @"";

        dispatch_async(dispatch_get_main_queue(), ^{
            Class xprobe =
                NSClassFromString(@"Xprobe");
            SEL selector =
                NSSelectorFromString(@"_search:");

            if (!xprobe ||
                ![xprobe respondsToSelector:selector]) {
                [self sendJSONObject:@{
                    @"type": @"xprobe_result",
                    @"available": @NO,
                    @"error": @"Xprobe is not linked into this app runtime.",
                    @"objects": @[]
                }];
                return;
            }

            typedef void (*SearchSend)(
                id,
                SEL,
                id
            );
            ((SearchSend)objc_msgSend)(
                xprobe,
                selector,
                pattern ?: @""
            );

            NSArray *paths =
                [self xprobePathsIfAvailable];
            if (!paths) {
                [self sendJSONObject:@{
                    @"type": @"xprobe_result",
                    @"available": @NO,
                    @"error": @"Xprobe path table is unavailable in this runtime.",
                    @"objects": @[]
                }];
                return;
            }

            NSRegularExpression *regex = nil;
            if (pattern.length > 0) {
                regex = [NSRegularExpression
                    regularExpressionWithPattern:pattern
                    options:NSRegularExpressionCaseInsensitive
                    error:NULL];
            }

            NSMutableArray *objects =
                [NSMutableArray array];

            for (NSUInteger index = 0;
                 index < paths.count &&
                 objects.count < 500;
                 index++) {
                NSDictionary *object =
                    [self xprobeObjectAtIndex:index
                                        paths:paths];
                if (!object) {
                    continue;
                }

                if (pattern.length > 0) {
                    NSString *haystack =
                        [NSString stringWithFormat:
                            @"%@ %@ %@",
                            object[@"className"] ?: @"",
                            object[@"path"] ?: @"",
                            object[@"description"] ?: @""
                        ];

                    BOOL matches = regex
                        ? [regex firstMatchInString:haystack
                                           options:0
                                             range:NSMakeRange(
                                                 0,
                                                 haystack.length
                                             )] != nil
                        : [haystack
                            rangeOfString:pattern
                            options:NSCaseInsensitiveSearch
                          ].location != NSNotFound;

                    if (!matches) {
                        continue;
                    }
                }

                [objects addObject:object];
            }

            [self sendJSONObject:@{
                @"type": @"xprobe_result",
                @"timestamp":
                    @([NSDate timeIntervalSinceReferenceDate]),
                @"available": @YES,
                @"objects": objects
            }];
        });
        return;
    }

    if ([action isEqualToString:@"xprobe_inspect"]) {
        NSNumber *objectID =
            [command[@"objectID"] isKindOfClass:NSNumber.class]
            ? command[@"objectID"]
            : nil;

        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray *paths =
                [self xprobePathsIfAvailable];

            if (!paths) {
                [self sendJSONObject:@{
                    @"type": @"xprobe_result",
                    @"available": @NO,
                    @"error": @"Xprobe is not linked or no Xprobe search has been performed.",
                    @"objects": @[]
                }];
                return;
            }

            NSInteger index =
                objectID.integerValue;
            if (!objectID ||
                index < 0 ||
                (NSUInteger)index >= paths.count) {
                [self sendJSONObject:@{
                    @"type": @"xprobe_result",
                    @"available": @YES,
                    @"error": @"Xprobe object ID is out of range.",
                    @"objects": @[]
                }];
                return;
            }

            NSDictionary *selected =
                [self xprobeObjectAtIndex:
                    (NSUInteger)index
                    paths:paths];

            [self sendJSONObject:@{
                @"type": @"xprobe_result",
                @"timestamp":
                    @([NSDate timeIntervalSinceReferenceDate]),
                @"available": @YES,
                @"objects": @[],
                @"selected":
                    selected ?: @{},
                @"details":
                    selected[@"description"]
                        ?: @""
            }];
        });
        return;
    }

    if ([action isEqualToString:@"eval"]) {
        NSNumber *objectID =
            [command[@"objectID"] isKindOfClass:NSNumber.class]
            ? command[@"objectID"]
            : nil;
        NSString *code =
            [command[@"code"] isKindOfClass:NSString.class]
            ? command[@"code"]
            : nil;

        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray *paths =
                [self xprobePathsIfAvailable];

            if (!paths) {
                [self sendJSONObject:@{
                    @"type": @"eval_result",
                    @"available": @NO,
                    @"objectID":
                        objectID ?: @(-1),
                    @"succeeded": @NO,
                    @"error": @"Xprobe is not linked or no Xprobe search has been performed."
                }];
                return;
            }

            NSInteger index =
                objectID.integerValue;
            if (!objectID ||
                index < 0 ||
                (NSUInteger)index >= paths.count ||
                code.length == 0) {
                [self sendJSONObject:@{
                    @"type": @"eval_result",
                    @"available": @YES,
                    @"objectID":
                        objectID ?: @(-1),
                    @"succeeded": @NO,
                    @"error": @"Invalid Xprobe object ID or empty Eval code."
                }];
                return;
            }

            id path = paths[
                (NSUInteger)index
            ];
            SEL objectSelector =
                NSSelectorFromString(@"object");
            typedef id (*ObjectSend)(id, SEL);
            id object =
                [path respondsToSelector:objectSelector]
                ? ((ObjectSend)objc_msgSend)(
                    path,
                    objectSelector
                  )
                : nil;

            SEL evalSelector =
                NSSelectorFromString(
                    @"swiftEvalWithCode:"
                );

            if (!object ||
                ![object respondsToSelector:evalSelector]) {
                [self sendJSONObject:@{
                    @"type": @"eval_result",
                    @"available": @YES,
                    @"objectID": @(index),
                    @"succeeded": @NO,
                    @"error": @"Selected object does not expose swiftEvalWithCode:. Ensure HotReloading/SwiftEval is linked and the source file matches the class name."
                }];
                return;
            }

            typedef BOOL (*EvalSend)(
                id,
                SEL,
                id
            );
            BOOL succeeded =
                ((EvalSend)objc_msgSend)(
                    object,
                    evalSelector,
                    code
                );

            [self sendJSONObject:@{
                @"type": @"eval_result",
                @"timestamp":
                    @([NSDate timeIntervalSinceReferenceDate]),
                @"available": @YES,
                @"objectID": @(index),
                @"succeeded": @(succeeded),
                @"error": succeeded
                    ? (id)NSNull.null
                    : @"Swift Eval returned false."
            }];
        });
        return;
    }

    if ([action isEqualToString:@"trace_scope"]) {
        id rawFilter = command[@"filter"];
        NSString *filter =
            [rawFilter isKindOfClass:NSString.class]
            ? rawFilter
            : nil;

        NSString *scope =
            [command[@"scope"] isKindOfClass:NSString.class]
            ? command[@"scope"]
            : nil;

        NSString *name =
            [command[@"name"] isKindOfClass:NSString.class]
            ? command[@"name"]
            : nil;

        dispatch_async(dispatch_get_main_queue(), ^{
            [self setTraceFilter:filter];

            NSString *error = nil;
            if ([self startScope:scope
                            name:name
                           error:&error]) {
                [self sendTraceState:@"started"
                               error:nil];
            } else {
                [self sendTraceState:@"error"
                               error:error
                                     ?: @"Unable to start scoped trace."];
            }
        });
        return;
    }

    if ([action isEqualToString:@"trace_start"]) {
        id rawFilter = command[@"filter"];
        NSString *filter =
            [rawFilter isKindOfClass:NSString.class]
            ? rawFilter
            : nil;

        dispatch_async(dispatch_get_main_queue(), ^{
            SEL startSelector =
                NSSelectorFromString(@"swiftTraceMainBundle");

            if (!AgentTraceOutputInstalled) {
                [self sendTraceState:@"error"
                               error:@"SwiftTrace.logOutput is unavailable."];
                return;
            }

            if (![NSObject respondsToSelector:startSelector]) {
                [self sendTraceState:@"error"
                               error:@"swiftTraceMainBundle selector is unavailable."];
                return;
            }

            [self setTraceFilter:filter];
            [self invokeNSObjectClassSelector:startSelector];
            [self sendTraceState:@"started" error:nil];
        });
        return;
    }

    if ([action isEqualToString:@"call_order"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            Class bridge =
                NSClassFromString(@"AgentInjectionRuntimeBridge");
            SEL selector =
                NSSelectorFromString(@"callOrder");

            if (!bridge ||
                ![bridge respondsToSelector:selector]) {
                [self sendTraceState:@"error"
                               error:@"Agent runtime call-order bridge is unavailable. Reinstall the agent runtime."];
                return;
            }

            typedef id (*ObjectSend)(id, SEL);
            NSArray *signatures =
                ((ObjectSend)objc_msgSend)(
                    bridge,
                    selector
                ) ?: @[];

            [self sendJSONObject:@{
                @"type": @"call_order",
                @"timestamp":
                    @([NSDate timeIntervalSinceReferenceDate]),
                @"signatures": signatures
            }];
        });
        return;
    }

    if ([action isEqualToString:@"instances_start"]) {
        dispatch_async(AgentTraceLifetimeQueue, ^{
            Class bridge =
                NSClassFromString(@"AgentInjectionRuntimeBridge");
            SEL selector =
                NSSelectorFromString(@"startLifetimeTracking");

            if (!bridge ||
                ![bridge respondsToSelector:selector]) {
                [self sendTraceState:@"error"
                               error:@"Agent runtime lifetime bridge is unavailable. Reinstall the agent runtime."];
                return;
            }

            typedef NSInteger (*IntegerSend)(id, SEL);
            ((IntegerSend)objc_msgSend)(
                bridge,
                selector
            );

            [self sendTraceState:@"instances_started"
                           error:nil];
        });
        return;
    }

    if ([action isEqualToString:@"instances_read"]) {
        dispatch_async(AgentTraceLifetimeQueue, ^{
            Class bridge =
                NSClassFromString(@"AgentInjectionRuntimeBridge");
            SEL selector =
                NSSelectorFromString(@"instanceCounts");

            if (!bridge ||
                ![bridge respondsToSelector:selector]) {
                [self sendTraceState:@"error"
                               error:@"Agent runtime instance-count bridge is unavailable. Reinstall the agent runtime."];
                return;
            }

            typedef id (*ObjectSend)(id, SEL);
            NSDictionary *counts =
                ((ObjectSend)objc_msgSend)(
                    bridge,
                    selector
                ) ?: @{};

            [self sendJSONObject:@{
                @"type": @"instance_counts",
                @"timestamp":
                    @([NSDate timeIntervalSinceReferenceDate]),
                @"counts": counts
            }];
        });
        return;
    }

    if ([action isEqualToString:@"instances_stop"]) {
        dispatch_async(AgentTraceLifetimeQueue, ^{
            Class bridge =
                NSClassFromString(@"AgentInjectionRuntimeBridge");
            SEL selector =
                NSSelectorFromString(@"stopLifetimeTracking");

            if (!bridge ||
                ![bridge respondsToSelector:selector]) {
                [self sendTraceState:@"error"
                               error:@"Agent runtime lifetime bridge is unavailable. Reinstall the agent runtime."];
                return;
            }

            typedef void (*VoidSend)(id, SEL);
            ((VoidSend)objc_msgSend)(
                bridge,
                selector
            );

            [self sendTraceState:@"instances_stopped"
                           error:nil];
        });
        return;
    }

    if ([action isEqualToString:@"profile_snapshot"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SEL elapsedSelector =
                NSSelectorFromString(@"swiftTraceElapsedTimes");
            SEL countSelector =
                NSSelectorFromString(@"swiftTraceInvocationCounts");

            if (![NSObject respondsToSelector:elapsedSelector] ||
                ![NSObject respondsToSelector:countSelector]) {
                [self sendTraceState:@"error"
                               error:@"SwiftTrace profiling APIs are unavailable."];
                return;
            }

            typedef id (*ObjectSend)(id, SEL);
            NSDictionary *elapsed =
                ((ObjectSend)objc_msgSend)(
                    NSObject.class,
                    elapsedSelector
                ) ?: @{};
            NSDictionary *invocations =
                ((ObjectSend)objc_msgSend)(
                    NSObject.class,
                    countSelector
                ) ?: @{};

            [self sendJSONObject:@{
                @"type": @"profile",
                @"timestamp":
                    @([NSDate timeIntervalSinceReferenceDate]),
                @"elapsed": elapsed,
                @"invocations": invocations
            }];
        });
        return;
    }

    if ([action isEqualToString:@"trace_stop"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SEL stopSelector =
                NSSelectorFromString(@"swiftTraceRemoveAllTraces");

            if (![NSObject respondsToSelector:stopSelector]) {
                [self sendTraceState:@"error"
                               error:@"swiftTraceRemoveAllTraces selector is unavailable."];
                return;
            }

            [self invokeNSObjectClassSelector:stopSelector];
            [self setTraceFilter:nil];
            [self sendTraceState:@"stopped" error:nil];
        });
    }
}

+ (BOOL)startScope:(NSString * _Nullable)scope
                name:(NSString * _Nullable)name
               error:(NSString * _Nullable * _Nullable)error {
    Class traceClass = NSClassFromString(@"SwiftTrace");

    if (!traceClass) {
        if (error) {
            *error = @"SwiftTrace class is unavailable.";
        }
        return NO;
    }

    if ([scope isEqualToString:@"frameworks"]) {
        SEL selector =
            NSSelectorFromString(@"swiftTraceFrameworkMethods");
        if (![traceClass respondsToSelector:selector]) {
            if (error) {
                *error = @"swiftTraceFrameworkMethods is unavailable.";
            }
            return NO;
        }

        typedef NSInteger (*IntegerSend)(id, SEL);
        ((IntegerSend)objc_msgSend)(
            traceClass,
            selector
        );
        return YES;
    }

    if ([scope isEqualToString:@"uikit"]) {
        Class viewClass =
            NSClassFromString(@"UIView")
            ?: NSClassFromString(@"NSView");
        SEL selector =
            NSSelectorFromString(@"swiftTraceBundle");

        if (!viewClass ||
            ![viewClass respondsToSelector:selector]) {
            if (error) {
                *error = @"UIView/NSView SwiftTrace bundle API is unavailable.";
            }
            return NO;
        }

        typedef void (*VoidSend)(id, SEL);
        ((VoidSend)objc_msgSend)(
            viewClass,
            selector
        );
        return YES;
    }

    if ([scope isEqualToString:@"swiftui"]) {
        typedef const char *(*SwiftUIPath)(void);
        SwiftUIPath pathFunction =
            (SwiftUIPath)dlsym(
                RTLD_DEFAULT,
                "swiftUIBundlePath"
            );

        const char *path =
            pathFunction ? pathFunction() : NULL;

        if (!path) {
            if (error) {
                *error = @"SwiftUI runtime bundle was not found.";
            }
            return NO;
        }

        return [self traceBundlePath:path
                         packageName:nil
                              error:error];
    }

    if ([scope isEqualToString:@"package"]) {
        if (name.length == 0) {
            if (error) {
                *error = @"package scope requires a package name.";
            }
            return NO;
        }

        const char *path =
            NSBundle.mainBundle.executablePath.UTF8String;

        return [self traceBundlePath:path
                         packageName:name
                              error:error];
    }

    if ([scope isEqualToString:@"framework"]) {
        if (name.length == 0) {
            if (error) {
                *error = @"framework scope requires a framework name.";
            }
            return NO;
        }

        NSBundle *matched = nil;
        for (NSBundle *bundle in NSBundle.allFrameworks) {
            NSString *bundleName =
                bundle.bundleURL
                    .URLByDeletingPathExtension
                    .lastPathComponent;

            if ([bundleName isEqualToString:name] ||
                [bundle.bundleIdentifier
                    isEqualToString:name]) {
                matched = bundle;
                break;
            }
        }

        if (!matched.executablePath) {
            if (error) {
                *error = [NSString
                    stringWithFormat:
                        @"Framework not loaded: %@",
                        name];
            }
            return NO;
        }

        const char *path =
            matched.executablePath.UTF8String;

        if (![self traceBundlePath:path
                       packageName:nil
                            error:error]) {
            return NO;
        }

        SEL bundleSelector =
            NSSelectorFromString(
                @"swiftTraceBundlePath:"
            );

        if ([traceClass
                respondsToSelector:bundleSelector]) {
            typedef void (*BundleSend)(
                id,
                SEL,
                const char *
            );
            ((BundleSend)objc_msgSend)(
                traceClass,
                bundleSelector,
                path
            );
        }

        return YES;
    }

    if ([scope isEqualToString:@"main-all"]) {
        SEL methods =
            NSSelectorFromString(
                @"swiftTraceMainBundleMethods"
            );
        SEL bundle =
            NSSelectorFromString(
                @"swiftTraceMainBundle"
            );

        if (![traceClass respondsToSelector:methods] ||
            ![NSObject respondsToSelector:bundle]) {
            if (error) {
                *error = @"Main-bundle SwiftTrace APIs are unavailable.";
            }
            return NO;
        }

        typedef NSInteger (*IntegerSend)(id, SEL);
        typedef void (*VoidSend)(id, SEL);

        ((IntegerSend)objc_msgSend)(
            traceClass,
            methods
        );
        ((VoidSend)objc_msgSend)(
            NSObject.class,
            bundle
        );
        return YES;
    }

    if (error) {
        *error = [NSString
            stringWithFormat:
                @"Unknown trace scope: %@",
                scope ?: @"(null)"];
    }
    return NO;
}

+ (BOOL)traceBundlePath:(const char *)path
            packageName:(NSString * _Nullable)packageName
                   error:(NSString * _Nullable * _Nullable)error {
    Class traceClass = NSClassFromString(@"SwiftTrace");
    SEL selector =
        NSSelectorFromString(
            @"swiftTraceMethodsInBundle:packageName:"
        );

    if (!traceClass ||
        ![traceClass respondsToSelector:selector]) {
        if (error) {
            *error = @"swiftTraceMethodsInBundle:packageName: is unavailable.";
        }
        return NO;
    }

    typedef NSInteger (*BundleMethodsSend)(
        id,
        SEL,
        const char *,
        NSString *
    );

    ((BundleMethodsSend)objc_msgSend)(
        traceClass,
        selector,
        path,
        packageName
    );

    return YES;
}

+ (void)sendTraceState:(NSString *)state
                 error:(NSString * _Nullable)error {
    NSMutableDictionary *message = [@{
        @"type": @"state",
        @"state": state,
        @"timestamp": @([NSDate timeIntervalSinceReferenceDate])
    } mutableCopy];

    if (error.length > 0) {
        message[@"error"] = error;
    }

    [self sendJSONObject:message];
}

+ (void)setTraceFilter:(NSString * _Nullable)filter {
    SEL selector =
        NSSelectorFromString(@"setSwiftTraceFilterInclude:");

    if (![NSObject respondsToSelector:selector]) {
        return;
    }

    typedef void (*StringSetterSend)(id, SEL, id);
    ((StringSetterSend)objc_msgSend)(
        NSObject.class,
        selector,
        filter
    );
}

+ (void)invokeNSObjectClassSelector:(SEL)selector {
    if (![NSObject respondsToSelector:selector]) {
        NSLog(@"[agentInjectionIII] SwiftTrace selector unavailable: %@",
              NSStringFromSelector(selector));
        return;
    }

    typedef void (*VoidSend)(id, SEL);
    ((VoidSend)objc_msgSend)(
        NSObject.class,
        selector
    );
}

+ (void)sendJSONObject:(NSDictionary *)object {
    dispatch_queue_t queue = AgentTraceWriteQueue;
    if (!queue) {
        return;
    }

    dispatch_async(queue, ^{
        int socketFD = AgentTraceSocket;
        if (socketFD < 0) {
            return;
        }

        NSData *json =
            [NSJSONSerialization dataWithJSONObject:object
                                            options:0
                                              error:NULL];
        if (!json) {
            return;
        }

        NSMutableData *framed = [json mutableCopy];
        uint8_t newline = '\n';
        [framed appendBytes:&newline length:1];

        const uint8_t *bytes = framed.bytes;
        NSUInteger offset = 0;

        while (offset < framed.length) {
            ssize_t written = write(
                socketFD,
                bytes + offset,
                framed.length - offset
            );

            if (written <= 0) {
                return;
            }

            offset += (NSUInteger)written;
        }
    });
}

@end
