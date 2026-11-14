//
// DshProbe.m —— SpringBoard 内的探针（分步验证版）
//
// 目标：在 SpringBoard 进程内抓到整屏。
//
// 已经确认的边界：
//   - 只链 Foundation 的 dylib 能稳定注入（双切片 arm64+arm64e）
//   - 静态链接 UIKit/CoreGraphics 会在 libobjc 加载期 PAC 崩
//   - UIGetScreenImage 一调用就让 SpringBoard 崩（废弃 API，iOS 15 不可用）
//
// 所以这里换路：用 objc_msgSend 运行时调 UIApplication / UIWindow，让
// SpringBoard 渲染自己的视图层级。全程零静态 UIKit 符号。
//
// 每一步都写日志。如果崩溃，最后一条日志就是崩溃点，不用猜。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <unistd.h>
#include <stdarg.h>
#include <string.h>
#include <stdlib.h>

static NSString *const kLogPath = @"/var/mobile/dsh-probe.log";

static void DshLog(NSString *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
  va_end(ap);
  NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
  NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
  if (!h) {
    [d writeToFile:kLogPath atomically:NO];
  } else {
    [h seekToEndOfFile];
    [h writeData:d];
    [h closeFile];
  }
}

// 分步执行，每步写日志。返回 YES 表示走到这一步还没崩。
typedef BOOL (*StepFn)(NSString **detail);

static void DshRunStep(const char *name, StepFn fn) {
  DshLog(@"[step] %s ...\n", name);
  NSString *detail = nil;
  BOOL ok = NO;
  @try {
    ok = fn(&detail);
  } @catch (NSException *e) {
    DshLog(@"[step] %s EXCEPTION %@: %@\n", name, e.name, e.reason);
    return;
  }
  DshLog(@"[step] %s -> %s %@\n", name, ok ? "ok" : "fail",
         detail ? detail : @"");
}

#pragma mark - 步骤 1：能否拿到 UIApplication

static BOOL StepApplication(NSString **detail) {
  void *uikit = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_NOW);
  if (!uikit) { *detail = @"dlopen UIKit 失败"; return NO; }
  DshLog(@"  UIKit handle=%p\n", uikit);

  Class appCls = NSClassFromString(@"UIApplication");
  if (!appCls) { *detail = @"UIApplication 类不存在"; return NO; }
  DshLog(@"  UIApplication class=%p\n", (__bridge void *)appCls);

  id app = ((id (*)(id, SEL))objc_msgSend)((id)appCls, sel_registerName("sharedApplication"));
  DshLog(@"  sharedApplication=%p\n", (__bridge void *)app);
  if (!app) { *detail = @"sharedApplication 为 nil"; return NO; }

  *detail = [NSString stringWithFormat:@"app=%p", (__bridge void *)app];
  return YES;
}

#pragma mark - 步骤 2：能否拿到窗口

static BOOL StepWindow(NSString **detail) {
  Class appCls = NSClassFromString(@"UIApplication");
  id app = ((id (*)(id, SEL))objc_msgSend)((id)appCls, sel_registerName("sharedApplication"));
  if (!app) { *detail = @"app nil"; return NO; }

  // SpringBoard 里 keyWindow 常常是 nil，改取 windows 里最靠前的。
  id windows = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("windows"));
  NSUInteger count = windows ? ((NSUInteger (*)(id, SEL))objc_msgSend)(windows, sel_registerName("count")) : 0;
  DshLog(@"  windows=%p count=%lu\n", (__bridge void *)windows, (unsigned long)count);
  if (count == 0) { *detail = @"没有窗口"; return NO; }

  id window = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(windows,
      sel_registerName("objectAtIndex:"), count - 1);
  DshLog(@"  window=%p class=%@\n", (__bridge void *)window,
         ((id (*)(id, SEL))objc_msgSend)(window, sel_registerName("class")));

  CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(window, sel_registerName("bounds"));
  DshLog(@"  bounds=%.1f x %.1f\n", bounds.size.width, bounds.size.height);

  *detail = [NSString stringWithFormat:@"%.0fx%.0f", bounds.size.width, bounds.size.height];
  return YES;
}

#pragma mark - 步骤 3：渲染视图层级

static BOOL StepRender(NSString **detail) {
  Class appCls = NSClassFromString(@"UIApplication");
  id app = ((id (*)(id, SEL))objc_msgSend)((id)appCls, sel_registerName("sharedApplication"));
  id windows = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("windows"));
  NSUInteger count = ((NSUInteger (*)(id, SEL))objc_msgSend)(windows, sel_registerName("count"));
  if (count == 0) { *detail = @"没有窗口"; return NO; }

  // SpringBoard 的窗口层级有好几层（壁纸、图标、状态栏…）。
  // 用最大的那个窗口做容器，把所有窗口依次画进去。
  CGRect unionRect = CGRectZero;
  for (NSUInteger i = 0; i < count; i++) {
    id w = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(windows,
        sel_registerName("objectAtIndex:"), i);
    CGRect b = ((CGRect (*)(id, SEL))objc_msgSend)(w, sel_registerName("bounds"));
    if (b.size.width > unionRect.size.width) unionRect = b;
  }
  if (unionRect.size.width <= 0) { *detail = @"窗口尺寸为 0"; return NO; }

  // UIGraphicsBeginImageContextWithOptions(size, opaque, scale) 是 C 函数，
  // 通过 dlsym 取，避免任何静态符号。
  void *uikit = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_NOW);
  typedef void (*BeginCtx)(CGSize, BOOL, CGFloat);
  typedef id (*GetImage)(void);
  typedef void (*EndCtx)(void);
  BeginCtx begin = (BeginCtx)dlsym(uikit, "UIGraphicsBeginImageContextWithOptions");
  GetImage getImage = (GetImage)dlsym(uikit, "UIGraphicsGetImageFromCurrentImageContext");
  EndCtx end = (EndCtx)dlsym(uikit, "UIGraphicsEndImageContext");
  if (!begin || !getImage || !end) {
    *detail = @"图形上下文符号缺失";
    return NO;
  }

  begin(unionRect.size, NO, 0);
  DshLog(@"  上下文已开 %.0fx%.0f\n", unionRect.size.width, unionRect.size.height);

  for (NSUInteger i = 0; i < count; i++) {
    id w = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(windows,
        sel_registerName("objectAtIndex:"), i);
    CGRect b = ((CGRect (*)(id, SEL))objc_msgSend)(w, sel_registerName("bounds"));
    @try {
      typedef void (*DrawHierFn)(id, SEL, CGRect, BOOL);
      DrawHierFn drawHier = (DrawHierFn)(void *)objc_msgSend;
      drawHier(w, sel_registerName("drawViewHierarchyInRect:afterScreenUpdates:"), b, NO);
      DshLog(@"  窗口 %lu 已绘制\n", (unsigned long)i);
    } @catch (NSException *e) {
      DshLog(@"  窗口 %lu 绘制异常 %@\n", (unsigned long)i, e.name);
    }
  }

  id image = getImage();
  end();
  DshLog(@"  图像=%p\n", (__bridge void *)image);
  if (!image) { *detail = @"渲染结果为 nil"; return NO; }

  // 转 PNG。UIImagePNGRepresentation 是 C 函数。
  typedef id (*PngFn)(id);
  PngFn toPng = (PngFn)dlsym(uikit, "UIImagePNGRepresentation");
  if (!toPng) { *detail = @"PNG 符号缺失"; return NO; }
  id data = toPng(image);
  if (!data) { *detail = @"PNG 编码失败"; return NO; }

  NSUInteger len = ((NSUInteger (*)(id, SEL))objc_msgSend)(data, sel_registerName("length"));
  BOOL ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(data,
      sel_registerName("writeToFile:atomically:"), @"/var/mobile/dsh-screen.png", NO);
  *detail = [NSString stringWithFormat:@"png=%lu 字节 写入=%d", (unsigned long)len, ok];
  return ok;
}

#pragma mark - 入口

__attribute__((constructor))
static void DshProbeInit(void) {
  @autoreleasepool {
    DshLog(@"=== loaded uid=%d pid=%d bundle=%@ ===\n",
           getuid(), getpid(), [[NSBundle mainBundle] bundleIdentifier]);

    // 后台队列 + 8 秒：SpringBoard 启动期主队列排满，投 main queue 会一直不执行。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      @autoreleasepool {
        DshLog(@"timer fired\n");
        DshRunStep("application", StepApplication);
        DshRunStep("window", StepWindow);
        DshRunStep("render", StepRender);
        DshLog(@"=== all steps done ===\n");
      }
    });
  }
}
