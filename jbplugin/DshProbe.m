//
// DshProbe.m —— 极端最小探针（诊断用）
//
// 目的：只验证「注入机制现在还接受我们的 dylib 吗」。
//
// 之前的经历：
//   - 只链 Foundation + 双切片 + 二进制 plist → 能加载（60445bda、5e3f7f47）
//   - 换成 IOKit 点击版（05f5b436）→ 探针日志为空，加载失败
//
// 虽然 05f5b436 的依赖清单同样干净（只有 Foundation/CoreFoundation/
// libobjc/libSystem），但它就是进不去。为了分清「代码问题」还是
// 「TweakInject 记住了崩溃、把这个文件名拉黑」，这里同时做两件事：
//   1) 代码砍到只剩一行写文件
//   2) 换个文件名（DshProbe2）绕开可能的黑名单
//
// 如果这个都加载不了，那就是注入机制本身被破坏了，需要重启手机再试。
//

#import <Foundation/Foundation.h>
#include <unistd.h>

__attribute__((constructor))
static void DshProbeInit(void) {
  @autoreleasepool {
    NSString *line = [NSString stringWithFormat:@"loaded uid=%d pid=%d bundle=%@\n",
                      getuid(), getpid(), [[NSBundle mainBundle] bundleIdentifier]];
    [line writeToFile:@"/var/mobile/dsh-probe.log"
           atomically:NO
             encoding:NSUTF8StringEncoding
                error:NULL];
  }
}
