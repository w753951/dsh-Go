//
// DshProbe.m —— SpringBoard 内的探针 + 整屏抓取。
//
// 为什么改写成"全动态加载"：
//   之前 DshScreenshotService 静态链接了 UIKit + CoreGraphics，注入进
//   SpringBoard 时在 libobjc 加载阶段就崩了，崩溃日志写的是
//   "possible pointer authentication failure"——arm64e 上，dylib 对
//   链接进来的 ObjC/CG 符号会生成需要 PAC 的 chained fixup，未正确签名
//   就会被内核拒绝。
//
//   而只链接 Foundation 的探针能稳定加载。所以这里把 UIKit / CoreGraphics /
//   ImageIO 全部改成运行时 dlopen + dlsym，链接期不产生任何静态引用。
//
// 产出：把整屏写成原始 BGRA 像素（.raw）+ 一个文本头，电脑端转 PNG。
// 不在这里做 PNG 编码，避免再引入 ImageIO 的依赖。
//

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>

static void DshLog(NSString *line) {
  NSString *path = @"/var/mobile/dsh-probe.log";
  NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
  NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
  if (!h) {
    [d writeToFile:path atomically:NO];
  } else {
    [h seekToEndOfFile];
    [h writeData:d];
    [h closeFile];
  }
}

// 从 dlopen 的库里取符号。取不到就返回 NULL，由调用方判断。
static void *DshSym(void *handle, const char *name) {
  if (!handle) return NULL;
  return dlsym(handle, name);
}

// 抓整屏 → /var/mobile/dsh-screen.raw（BGRA）+ /var/mobile/dsh-screen.txt（尺寸）
static BOOL DshGrabFullScreen(void) {
  void *uikit = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_NOW);
  void *cg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW);
  if (!uikit || !cg) {
    DshLog(@"grab: dlopen failed\n");
    return NO;
  }

  typedef void *(*GetScreenFn)(void);
  GetScreenFn getScreen = (GetScreenFn)DshSym(uikit, "UIGetScreenImage");
  if (!getScreen) {
    DshLog(@"grab: UIGetScreenImage 缺失\n");
    return NO;
  }

  typedef size_t (*GetW)(void *);
  typedef size_t (*GetH)(void *);
  typedef size_t (*GetBPR)(void *);
  typedef void *(*GetProvider)(void *);
  typedef void *(*ProviderCopyData)(void *);
  typedef const void *(*DataGetBytesPtr)(void *);
  typedef long (*DataGetLength)(void *);

  GetW imgW = (GetW)DshSym(cg, "CGImageGetWidth");
  GetH imgH = (GetH)DshSym(cg, "CGImageGetHeight");
  GetBPR imgBPR = (GetBPR)DshSym(cg, "CGImageGetBytesPerRow");
  GetProvider imgProv = (GetProvider)DshSym(cg, "CGImageGetDataProvider");
  ProviderCopyData provCopy = (ProviderCopyData)DshSym(cg, "CGDataProviderCopyData");
  DataGetBytesPtr dataBytes = (DataGetBytesPtr)DshSym(cg, "CFDataGetBytePtr");
  DataGetLength dataLen = (DataGetLength)DshSym(cg, "CFDataGetLength");
  if (!imgW || !imgH || !imgBPR || !imgProv || !provCopy || !dataBytes || !dataLen) {
    DshLog(@"grab: CoreGraphics 符号缺失\n");
    return NO;
  }

  void *image = getScreen();
  if (!image) {
    DshLog(@"grab: UIGetScreenImage 返回 NULL\n");
    return NO;
  }

  size_t w = imgW(image), h = imgH(image), bpr = imgBPR(image);
  void *provider = imgProv(image);
  void *data = provCopy(provider);
  const unsigned char *bytes = (const unsigned char *)dataBytes(data);
  long len = dataLen(data);
  if (!bytes || len <= 0) {
    DshLog([NSString stringWithFormat:@"grab: 数据为空 w=%zu h=%zu len=%ld\n", w, h, len]);
    return NO;
  }

  // 抽样判断是否全黑：全 0 说明这个进程里也拿不到画面。
  int nonZero = 0;
  for (long i = 0; i < len; i += 4001) {
    if (bytes[i]) { nonZero++; if (nonZero > 50) break; }
  }

  NSData *raw = [NSData dataWithBytes:bytes length:(NSUInteger)len];
  BOOL ok = [raw writeToFile:@"/var/mobile/dsh-screen.raw" atomically:NO];
  NSString *meta = [NSString stringWithFormat:@"%zux%zu bpr=%zu len=%ld nonzero=%d ok=%d\n",
                    w, h, bpr, len, nonZero, ok];
  [meta writeToFile:@"/var/mobile/dsh-screen.txt" atomically:NO encoding:NSUTF8StringEncoding error:NULL];
  DshLog([@"grab: " stringByAppendingString:meta]);
  return ok;
}

__attribute__((constructor))
static void DshProbeInit(void) {
  @autoreleasepool {
    DshLog([NSString stringWithFormat:@"loaded uid=%d pid=%d bundle=%@\n",
            getuid(), getpid(), [[NSBundle mainBundle] bundleIdentifier]]);

    // 不要在 constructor 里做重活：SpringBoard 启动时它可能还没准备好。
    // 延迟 5 秒，等 SpringBoard 起来再抓。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
      @autoreleasepool {
        DshLog(@"timer fired, grabbing\n");
        DshGrabFullScreen();
      }
    });
  }
}
