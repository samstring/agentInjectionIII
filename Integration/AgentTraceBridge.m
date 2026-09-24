#import "AgentTraceBridge.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <sys/socket.h>
#import <unistd.h>

typedef void (^AgentSwiftTraceOutput)(
    NSString *text,
    const void * _Nullable object,
    NSInteger indent
);

@implementation AgentTraceBridge

static int AgentTraceSocket = -1;
static dispatch_queue_t AgentTraceWriteQueue;
static dispatch_once_t AgentTraceStartOnce;
static BOOL AgentTraceOutputInstalled = NO;

+ (void)start {
#if DEBUG
    dispatch_once(&AgentTraceStartOnce, ^{
        AgentTraceWriteQueue = dispatch_queue_create(
            "agentInjectionIII.trace-write",
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

    [self installSwiftTraceOutput];
    [self sendJSONObject:@{
        @"type": @"hello",
        @"timestamp": @([NSDate timeIntervalSinceReferenceDate])
    }];

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
