#import "ObjCTry.h"

BOOL VCTry(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return YES;
    } @catch (NSException *e) {
        NSLog(@"VCTry caught %@: %@", e.name, e.reason);
        return NO;
    }
}
