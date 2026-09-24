#import "SmokeObjCHelper.h"
#import <Masonry/Masonry.h>

@implementation SmokeObjCHelper

+ (NSString *)podBackedSubtitle {
    return [NSString stringWithFormat:
        @"ObjC + CocoaPods: %@",
        NSStringFromClass(MASConstraintMaker.class)
    ];
}

@end
