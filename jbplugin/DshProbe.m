//
// DshProbe.m —— 最小可验证的注入探针。
//
// 不抓屏、不监听、不做任何事，只在被加载时往固定路径写一行。
// 如果这个都写不出来，就证明不是我们的代码问题，而是注入机制本身
// 不接受这个 dylib；那样就该换思路，而不是继续改业务代码。
//

#import <Foundation/Foundation.h>
#include <unistd.h>

__attribute__((constructor))
static void DshProbeInit(void) {
  @autoreleasepool {
    NSString *path = @"/var/mobile/dsh-probe.log";
    NSString *line = [NSString stringWithFormat:
        @"loaded uid=%d pid=%d bundle=%@\n",
        getuid(), getpid(), [[NSBundle mainBundle] bundleIdentifier]];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (handle) {
      [handle seekToEndOfFile];
      [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
      [handle closeFile];
    } else {
      [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    }
  }
}
