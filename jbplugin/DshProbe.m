//
// DshProbe.m —— SpringBoard 内 HID 点击探针
//
// 核心思路：HID 事件只有在 UI 主进程里发出才会被系统接受。
// root shell 里调 IOHIDEventSystemClientDispatchEvent 一直是"派发成功但零效果"，
// 因为事件来源不被信任。而 SpringBoard 本身就是 UI 主进程——注入进去再点，
// 这条限制就不存在了。
//
// 验证目标：在 SpringBoard 内点击状态栏电池位置 (383, 21)，
// 触发 NiceBarX 绑定的「DSH截图」快捷指令，让截图落进相册。
//
// 为什么这条路比截图 API 安全：
//   已确认 UIGetScreenImage 一调就让 SpringBoard 崩；
//   而 HID 的 create/dispatch 在 root 进程里反复调过几十次都没崩，
//   只是没生效。所以风险低得多。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <unistd.h>
#include <stdarg.h>
#include <mach/mach_time.h>

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

#pragma mark - IOKit 符号

typedef CFTypeRef (*CreateDigitizerFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
    uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint8_t,
    double, double, double, double, uint32_t, uint32_t);
typedef void (*SetFloatFn)(CFTypeRef, uint32_t, double);
typedef CFTypeRef (*SystemCreateFn)(CFAllocatorRef);
typedef void (*DispatchFn)(CFTypeRef, CFTypeRef);
typedef void (*SetPropFn)(CFTypeRef, CFStringRef, CFTypeRef);

static CreateDigitizerFn gCreate = NULL;
static SetFloatFn gSetFloat = NULL;
static SystemCreateFn gSysCreate = NULL;
static DispatchFn gDispatch = NULL;
static SetPropFn gSetProp = NULL;

static BOOL DshLoadIOKit(void) {
  if (gDispatch && gCreate) return YES;

  // IOKit 是私有框架；SpringBoard 里它通常已经加载，先试 RTLD_DEFAULT。
  void *h = dlopen("/System/Library/PrivateFrameworks/IOKit.framework/IOKit",
                   RTLD_NOW | RTLD_GLOBAL);
  if (!h) h = RTLD_DEFAULT;

  gCreate = (CreateDigitizerFn)dlsym(h, "IOHIDEventCreateDigitizerEvent");
  gSetFloat = (SetFloatFn)dlsym(h, "IOHIDEventSetFloatValue");
  gSysCreate = (SystemCreateFn)dlsym(h, "IOHIDEventSystemClientCreate");
  gDispatch = (DispatchFn)dlsym(h, "IOHIDEventSystemClientDispatchEvent");
  gSetProp = (SetPropFn)dlsym(h, "IOHIDEventSystemClientSetProperty");

  DshLog(@"iokit create=%d setfloat=%d syscreate=%d dispatch=%d setprop=%d\n",
         gCreate != NULL, gSetFloat != NULL, gSysCreate != NULL,
         gDispatch != NULL, gSetProp != NULL);
  return gCreate && gDispatch && gSysCreate;
}

static CFTypeRef DshMakeEvent(CGFloat x, CGFloat y, BOOL touched) {
  if (!gCreate) return NULL;
  // 唯一验证过能被系统接受的组合：touched 时 Range|Touch（0x03），抬起 0。
  // 加 Start/Stop/Position 位会让整条注入失效（在 root 进程里实测过）。
  uint32_t mask = touched ? 0x03u : 0x00u;
  CFTypeRef e = gCreate(kCFAllocatorDefault, mach_absolute_time(),
                        2, 0, 0, mask, 0, 0, 0, touched ? 1 : 0,
                        (double)x, (double)y, 0, 0, 0, 0);
  if (!e) return NULL;
  if (gSetFloat) {
    gSetFloat(e, 0x0C, (double)x);  // kIOHIDEventFieldDigitizerX
    gSetFloat(e, 0x0D, (double)y);  // kIOHIDEventFieldDigitizerY
  }
  return e;
}

// 在进程内点一下。看起来应该和 root 进程里的调用一样，
// 区别只在"谁来发"——这里由 SpringBoard 自己发。
static void DshTapInProcess(CGFloat x, CGFloat y, int holdMs) {
  if (!DshLoadIOKit()) { DshLog(@"iokit 符号缺失，放弃\n"); return; }

  CFTypeRef client = gSysCreate(kCFAllocatorDefault);
  if (!client) { DshLog(@"client 创建失败\n"); return; }
  DshLog(@"client=%p\n", client);
  if (gSetProp) {
    gSetProp(client, CFSTR("AllowInstrumentation"), kCFBooleanTrue);
    DshLog(@"AllowInstrumentation 已设\n");
  }

  CFTypeRef down = DshMakeEvent(x, y, YES);
  if (!down) { DshLog(@"down 事件创建失败\n"); CFRelease(client); return; }
  gDispatch(client, down);
  CFRelease(down);
  DshLog(@"已派发 down (%g,%g)\n", (double)x, (double)y);

  int hold = holdMs > 0 ? holdMs : 120;
  usleep((useconds_t)hold * 1000);

  CFTypeRef up = DshMakeEvent(x, y, NO);
  if (up) { gDispatch(client, up); CFRelease(up); }
  CFRelease(client);
  DshLog(@"已派发 up，共 %d ms\n", hold);
}

#pragma mark - 入口

__attribute__((constructor))
static void DshProbeInit(void) {
  @autoreleasepool {
    DshLog(@"=== loaded uid=%d pid=%d bundle=%@ ===\n",
           getuid(), getpid(), [[NSBundle mainBundle] bundleIdentifier]);

    // 后台队列 + 8 秒：SpringBoard 启动期主队列排满，投 main queue 不会执行。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      @autoreleasepool {
        DshLog(@"timer fired, start tapping\n");

        // 电池图标在逻辑坐标 (383, 21)（实测：物理 x=1090..1183, y=53..97 @3x）。
        // 分三次点，间隔几秒，方便从相册时间戳判断哪一次生效。
        for (int i = 0; i < 3; i++) {
          DshLog(@"--- 第 %d 次点击 ---\n", i + 1);
          DshTapInProcess(383, 21, 120);
          sleep(4);
        }
        DshLog(@"=== all taps done ===\n");
      }
    });
  }
}
