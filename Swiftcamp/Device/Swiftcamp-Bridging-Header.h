// Exposes the C USB transport to Swift.
//
// Only the macOS target sets SWIFT_OBJC_BRIDGING_HEADER, because IOKit's USB
// interfaces do not exist on iOS. USBTransport.c compiles to stubs there.
#import "USBTransport.h"
#import "ValhallaBridge.h"
