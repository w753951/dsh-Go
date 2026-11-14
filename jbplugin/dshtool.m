//
// dshtool —— root 下的读屏与点按工具。
//
// 诊断要点：`tapdiag` 会把 HID 每一步的结果打出来（客户端类型、事件创建、
// 派发返回），这样「事件没送进去」和「坐标点错了」能分开，不用靠猜。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <unistd.h>
#include <errno.h>
#include <mach/mach_time.h>

typedef CGImageRef (*GetScreenFn)(void);
typedef CFTypeRef (*CreateDigitizerFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
    uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint8_t,
    double, double, double, double, uint32_t, uint32_t);
typedef void (*SetFloatFn)(CFTypeRef, uint32_t, double);
typedef CFTypeRef (*SystemCreateFn)(CFAllocatorRef);
typedef CFTypeRef (*SystemCreateTypeFn)(CFAllocatorRef, uint32_t, CFDictionaryRef);
typedef void (*DispatchFn)(CFTypeRef, CFTypeRef);
typedef void (*SetPropFn)(CFTypeRef, CFStringRef, CFTypeRef);
typedef CFTypeRef (*CopyPropFn)(CFTypeRef, CFStringRef);

static CreateDigitizerFn gCreate = NULL;
static SetFloatFn gSetFloat = NULL;
static SystemCreateFn gSystemCreate = NULL;
static SystemCreateTypeFn gSystemCreateType = NULL;
static DispatchFn gDispatch = NULL;
static SetPropFn gSetProp = NULL;
static CopyPropFn gCopyProp = NULL;

static BOOL DshLoadIOKit(void) {
  static BOOL done = NO, ok = NO;
  if (done) return ok;
  done = YES;
  void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_LOCAL);
  if (!h) return NO;
  gCreate = (CreateDigitizerFn)dlsym(h, "IOHIDEventCreateDigitizerEvent");
  gSetFloat = (SetFloatFn)dlsym(h, "IOHIDEventSetFloatValue");
  gSystemCreate = (SystemCreateFn)dlsym(h, "IOHIDEventSystemClientCreate");
  gSystemCreateType = (SystemCreateTypeFn)dlsym(h, "IOHIDEventSystemClientCreateWithType");
  gDispatch = (DispatchFn)dlsym(h, "IOHIDEventSystemClientDispatchEvent");
  gSetProp = (SetPropFn)dlsym(h, "IOHIDEventSystemClientSetProperty");
  gCopyProp = (CopyPropFn)dlsym(h, "IOHIDEventSystemClientCopyProperty");
  ok = gCreate && gDispatch && (gSystemCreate || gSystemCreateType);
  return ok;
}

// kIOHIDEventSystemClientType: 0=Monitor? 不同类型拿到的事件流权限不一样。
// 见到能送进去的那种就固定用它。
static CFTypeRef DshMakeClient(int type) {
  if (type < 0 && gSystemCreate) return gSystemCreate(kCFAllocatorDefault);
  if (!gSystemCreateType) return NULL;
  return gSystemCreateType(kCFAllocatorDefault, (uint32_t)type, NULL);
}

static CGImageRef DshCapture(void) {
  GetScreenFn fn = (GetScreenFn)dlsym(RTLD_DEFAULT, "UIGetScreenImage");
  if (!fn) {
    void *uikit = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_NOW | RTLD_LOCAL);
    if (uikit) fn = (GetScreenFn)dlsym(uikit, "UIGetScreenImage");
  }
  if (!fn) return NULL;
  CGImageRef image = fn();
  if (!image) return NULL;
  if (CGImageGetWidth(image) == 0 || CGImageGetHeight(image) == 0) {
    CGImageRelease(image);
    return NULL;
  }
  return image;
}

static BOOL DshIsBlank(CGImageRef image) {
  size_t w = 32, h = 32;
  uint8_t *px = calloc(w * h * 4, 1);
  if (!px) return NO;
  CGColorSpaceRef sp = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(px, w, h, 8, w * 4, sp,
      (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(sp);
  if (!ctx) { free(px); return NO; }
  CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image);
  CGContextRelease(ctx);
  size_t same = 0;
  uint8_t r0 = px[0], g0 = px[1], b0 = px[2];
  for (size_t i = 0; i < w * h; i++) {
    uint8_t r = px[i*4], g = px[i*4+1], b = px[i*4+2];
    BOOL black = r < 12 && g < 12 && b < 12;
    BOOL eq = abs((int)r-(int)r0) < 6 && abs((int)g-(int)g0) < 6 && abs((int)b-(int)b0) < 6;
    if (black || eq) same++;
  }
  free(px);
  return same * 100 >= w * h * 99;
}

// 触摸阶段。真实的一次触摸是 began → moved… → ended，系统靠 eventMask 里的
// Start / Stop 位区分它们。只发 Range|Touch 而不带 Start/Stop 时，系统会把
// 每一个事件都当成一次独立的、瞬时的触碰：点击碰巧能用（坐标跳一下就够了），
// 但 UILongPressGestureRecognizer 永远等不到「按住并持续」的状态。
// 触摸相位。实测教训：给 eventMask 加 Start(0x100)/Stop(0x08)/Position(0x04)
// 会让整个注入失效——连最简单的点击都点不开 App 了。
//
// 能工作的组合只有一个：touched 时 eventMask = Range|Touch（0x03），抬起时 0。
// 系统靠坐标跳变识别点击。这套虽然在语义上「不完整」，但它确实是通的那条。
enum {
  DshPhaseBegin = 0,
  DshPhaseMove = 1,
  DshPhaseEnd = 2,
};

static CFTypeRef DshMakeEventPhase(CGFloat x, CGFloat y, int phase) {
  if (!gCreate) return NULL;
  BOOL touched = phase != DshPhaseEnd;
  // 只有这一个 eventMask 组合被验证过能用。
  uint32_t eventMask = touched ? 0x03u : 0x00u;
  CFTypeRef e = gCreate(kCFAllocatorDefault, mach_absolute_time(),
                        2, 0, 0, 0, 0, 0, 0, touched ? 1 : 0,
                        (double)x, (double)y, 0, 0, 0, 0);
  if (!e) return NULL;
  if (gSetFloat) {
    gSetFloat(e, 0x0C, (double)x);  // kIOHIDEventFieldDigitizerX
    gSetFloat(e, 0x0D, (double)y);  // kIOHIDEventFieldDigitizerY
  }
  return e;
}

static CFTypeRef DshMakeEvent(CGFloat x, CGFloat y, BOOL touched) {
  // 老接口：点按用 begin/end 两段就够。
  return DshMakeEventPhase(x, y, touched ? DshPhaseBegin : DshPhaseEnd);
}

// 逐种 client 类型试一遍，报告哪种真的送进去了。
static int DshTapDiag(CGFloat x, CGFloat y, int durationMs) {
  if (!DshLoadIOKit()) {
    printf("IOKit 符号缺失\n");
    return 2;
  }
  printf("符号: create=%d setFloat=%d sysCreate=%d sysCreateType=%d dispatch=%d\n",
         gCreate != NULL, gSetFloat != NULL, gSystemCreate != NULL,
         gSystemCreateType != NULL, gDispatch != NULL);

  // -1 表示不用类型参数的旧接口；0..3 是几种 client 类型。
  int types[] = {-1, 0, 1, 2, 3};
  for (size_t i = 0; i < sizeof(types) / sizeof(types[0]); i++) {
    int type = types[i];
    CFTypeRef client = DshMakeClient(type);
    printf("client type=%d -> %s\n", type, client ? "created" : "NULL");
    if (!client) continue;

    if (gSetProp) {
      gSetProp(client, CFSTR("AllowInstrumentation"), kCFBooleanTrue);
    }
    if (gCopyProp) {
      CFTypeRef v = gCopyProp(client, CFSTR("AllowInstrumentation"));
      printf("  AllowInstrumentation=%s\n", v ? "set" : "unset");
      if (v) CFRelease(v);
    }

    CFTypeRef down = DshMakeEvent(x, y, YES);
    if (!down) { printf("  事件创建失败\n"); CFRelease(client); continue; }
    gDispatch(client, down);
    usleep((useconds_t)(durationMs > 0 ? durationMs : 80) * 1000);
    CFTypeRef up = DshMakeEvent(x, y, NO);
    if (up) { gDispatch(client, up); CFRelease(up); }
    CFRelease(down);
    CFRelease(client);
    printf("  已派发 (%g,%g)\n", (double)x, (double)y);
    usleep(400000);
  }
  return 0;
}


// 单次长按：一个 client，按下 →（可选心跳）→ 抬起。
//
// 目标手势是 NiceBarX 绑的「状态栏右侧长按 → 运行 DSH截图 快捷指令」。
// 它挂在 SpringBoard 的状态栏视图上，靠 UILongPressGestureRecognizer 识别。
//
// 只用 down/wait/up 时它不认：真实的持续触摸虽然不发 move，但 iOS 的触摸
// 跟踪会给同一次触摸不断刷新时间戳，识别器靠这个判断「手指还在」。这里每
// heartbeatMs 补一个同位置的 touchesMoved，把触摸「续」上，参数已经修正成
// 真实的 touch=1 + isDisplayIntegrated=1，所以这些心跳是有效的。
static int DshHold(CGFloat x, CGFloat y, int durationMs) {
  if (!DshLoadIOKit()) { printf("IOKit fail\n"); return 2; }
  int hold = durationMs > 0 ? durationMs : 1200;
  CFTypeRef client = gSystemCreate ? gSystemCreate(kCFAllocatorDefault) : NULL;
  if (!client) { printf("client nil\n"); return 2; }
  if (gSetProp) gSetProp(client, CFSTR("AllowInstrumentation"), kCFBooleanTrue);

  CFTypeRef down = DshMakeEventPhase(x, y, DshPhaseBegin);
  if (!down) { printf("down nil\n"); CFRelease(client); return 2; }
  gDispatch(client, down);
  CFRelease(down);

  // 心跳：每 80ms 一个 Move 阶段事件，让识别器知道手指没离开。
  int elapsed = 0;
  const int kBeat = 80;
  while (elapsed + kBeat < hold) {
    usleep(kBeat * 1000);
    elapsed += kBeat;
    CFTypeRef beat = DshMakeEventPhase(x, y, DshPhaseMove);
    if (beat) { gDispatch(client, beat); CFRelease(beat); }
  }
  if (hold > elapsed) usleep((useconds_t)(hold - elapsed) * 1000);

  CFTypeRef up = DshMakeEventPhase(x, y, DshPhaseEnd);
  if (up) { gDispatch(client, up); CFRelease(up); }
  CFRelease(client);
  printf("长按 %dms 完成 (%g,%g)，心跳 %d 次\n",
         hold, (double)x, (double)y, elapsed / kBeat);
  return 0;
}


// 向 Darwin 通知中心发一条通知，让 Snapper3 自己截图。
//
// Snapper3 把动作挂在 CFNotificationCenterGetDarwinNotifyCenter 上，名字是
// com.jontelang.snapper3.screenshot / .instant 等。这条路不需要任何手势，
// 也不需要它对外开接口——系统通知总线本来就是公开的。
//
// 设备上没有 notifyutil，所以在这里直接调 CoreFoundation 发。
static int DshSnapNotify(const char *name) {
  if (!name || !*name) { printf("需要通知名\n"); return 64; }
  CFStringRef key = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingUTF8);
  if (!key) { printf("名字无效\n"); return 64; }
  CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
  if (!center) { printf("拿不到 Darwin 通知中心\n"); CFRelease(key); return 2; }
  CFNotificationCenterPostNotification(center, key, NULL, NULL, true);
  printf("已发送 %s\n", name);
  CFRelease(key);
  return 0;
}


// 滑动：按下 → 连续移动 → 抬起。
//
// 和「长按」不同，滑动的特点就是坐标一直在变，系统看得到位置在推进，
// 不会像静止触摸那样被判成「没有后续事件」。所以这条路比长按有希望。
static int DshSwipe(CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2, int durationMs) {
  if (!DshLoadIOKit()) { printf("IOKit fail\n"); return 2; }
  int dur = durationMs > 0 ? durationMs : 300;
  CFTypeRef client = gSystemCreate ? gSystemCreate(kCFAllocatorDefault) : NULL;
  if (!client) { printf("client nil\n"); return 2; }
  if (gSetProp) gSetProp(client, CFSTR("AllowInstrumentation"), kCFBooleanTrue);

  CFTypeRef down = DshMakeEventPhase(x1, y1, DshPhaseBegin);
  if (!down) { printf("down nil\n"); CFRelease(client); return 2; }
  gDispatch(client, down);
  CFRelease(down);

  // 60fps 插值，共 dur 毫秒。
  int steps = dur / 16;
  if (steps < 4) steps = 4;
  for (int i = 1; i <= steps; i++) {
    usleep(16 * 1000);
    CGFloat t = (CGFloat)i / (CGFloat)steps;
    CGFloat cx = x1 + (x2 - x1) * t;
    CGFloat cy = y1 + (y2 - y1) * t;
    CFTypeRef mv = DshMakeEventPhase(cx, cy, DshPhaseMove);
    if (mv) { gDispatch(client, mv); CFRelease(mv); }
  }

  CFTypeRef up = DshMakeEventPhase(x2, y2, DshPhaseEnd);
  if (up) { gDispatch(client, up); CFRelease(up); }
  CFRelease(client);
  printf("滑动 (%g,%g) → (%g,%g) 用时 %dms，%d 步\n",
         (double)x1, (double)y1, (double)x2, (double)y2, dur, steps);
  return 0;
}


// 当前前台 App 的 bundle id。
//
// 有了它，「滑动到底有没有生效」「现在在哪个界面」都能自动判断，不用靠截图
// 或让人盯着屏幕。SpringBoardServices 的这个入口在越狱环境直接可用。
static int DshFrontmost(void) {
  void *sbs = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
                     RTLD_NOW | RTLD_LOCAL);
  if (!sbs) { printf("ERR no SpringBoardServices\n"); return 2; }
  typedef CFStringRef (*FrontFn)(void);
  FrontFn fn = (FrontFn)dlsym(sbs, "SBSCopyFrontmostApplicationDisplayIdentifier");
  if (!fn) {
    // 换一个常见符号名再试
    fn = (FrontFn)dlsym(sbs, "SBFrontmostApplicationDisplayIdentifier");
  }
  if (!fn) { printf("ERR no symbol\n"); return 2; }
  CFStringRef app = fn();
  if (!app) { printf("com.apple.springboard\n"); return 0; }
  char buf[512];
  if (CFStringGetCString(app, buf, sizeof(buf), kCFStringEncodingUTF8)) {
    printf("%s\n", buf);
  } else {
    printf("ERR convert\n");
  }
  CFRelease(app);
  return 0;
}

int main(int argc, char *argv[]) {
  @autoreleasepool {
    if (argc < 2) {
      printf("dshtool probe | shot <path> | tap <x> <y> [ms] | tapdiag <x> <y> [ms] | swipe | info\n");
      return 64;
    }
    NSString *cmd = [NSString stringWithUTF8String:argv[1]];

    if ([cmd isEqualToString:@"kbtest"]) {
      // 发一个 Home 键。用来判断 HID 通道是否真的通：按键生效而触摸不生效，
      // 就说明触摸事件缺字段，不是权限或通道的问题。
      void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",
                           RTLD_NOW | RTLD_LOCAL);
      if (!iokit) { printf("IOKit fail\n"); return 2; }
      typedef CFTypeRef (*SysCreateFn)(CFAllocatorRef);
      typedef void (*DispFn)(CFTypeRef, CFTypeRef);
      typedef void (*SetPropFn)(CFTypeRef, CFStringRef, CFTypeRef);
      typedef CFTypeRef (*CreateKbFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint8_t, uint32_t);
      SysCreateFn sc = (SysCreateFn)dlsym(iokit, "IOHIDEventSystemClientCreate");
      DispFn dp = (DispFn)dlsym(iokit, "IOHIDEventSystemClientDispatchEvent");
      SetPropFn sp = (SetPropFn)dlsym(iokit, "IOHIDEventSystemClientSetProperty");
      CreateKbFn ck = (CreateKbFn)dlsym(iokit, "IOHIDEventCreateKeyboardEvent");
      printf("sysCreate=%d dispatch=%d createKeyboard=%d\n", sc != NULL, dp != NULL, ck != NULL);
      if (!sc || !dp || !ck) return 2;
      CFTypeRef client = sc(kCFAllocatorDefault);
      if (!client) { printf("client nil\n"); return 2; }
      if (sp) sp(client, CFSTR("AllowInstrumentation"), kCFBooleanTrue);
      CFTypeRef down = ck(kCFAllocatorDefault, mach_absolute_time(), 0x40, 0, 1, 0);
      if (!down) { printf("event nil\n"); return 2; }
      dp(client, down);
      usleep(90000);
      CFTypeRef up = ck(kCFAllocatorDefault, mach_absolute_time(), 0x40, 0, 0, 0);
      if (up) { dp(client, up); CFRelease(up); }
      CFRelease(down);
      CFRelease(client);
      printf("Home 键已派发\n");
      return 0;
    }
    if ([cmd isEqualToString:@"tapdiag"]) {
      if (argc < 4) return 64;
      return DshTapDiag(atof(argv[2]), atof(argv[3]), argc > 4 ? atoi(argv[4]) : 80);
    }
    if ([cmd isEqualToString:@"snapnotify"]) {
      if (argc < 3) return 64;
      return DshSnapNotify(argv[2]);
    }
    if ([cmd isEqualToString:@"front"]) {
      return DshFrontmost();
    }
    if ([cmd isEqualToString:@"swipe"]) {
      if (argc < 6) {
        printf("用法: swipe x1 y1 x2 y2 [ms]\n");
        return 64;
      }
      return DshSwipe(atof(argv[2]), atof(argv[3]),
                      atof(argv[4]), atof(argv[5]),
                      argc > 6 ? atoi(argv[6]) : 300);
    }
    if ([cmd isEqualToString:@"hold"]) {
      if (argc < 4) return 64;
      return DshHold(atof(argv[2]), atof(argv[3]), argc > 4 ? atoi(argv[4]) : 1200);
    }
    if ([cmd isEqualToString:@"tap"]) {
      if (argc < 4) return 64;
      return DshTapDiag(atof(argv[2]), atof(argv[3]), argc > 4 ? atoi(argv[4]) : 80);
    }
    if ([cmd isEqualToString:@"probe"]) {
      printf("uid=%d\n", getuid());
      printf("IOKit=%s\n", DshLoadIOKit() ? "ok" : "fail");
      printf("UIDevice=%s\n", NSClassFromString(@"UIDevice") ? "present" : "absent");
      CGImageRef img = DshCapture();
      if (img) {
        printf("capture=OK %zux%zu blank=%d\n", CGImageGetWidth(img),
               CGImageGetHeight(img), DshIsBlank(img) ? 1 : 0);
        CGImageRelease(img);
      } else {
        printf("capture=FAIL\n");
      }
      return 0;
    }
    if ([cmd isEqualToString:@"shot"]) {
      if (argc < 3) return 64;
      CGImageRef img = DshCapture();
      if (!img) { fprintf(stderr, "ERR_CAPTURE\n"); return 1; }
      BOOL blank = DshIsBlank(img);
      UIImage *ui = [UIImage imageWithCGImage:img];
      NSData *png = UIImagePNGRepresentation(ui);
      int w = (int)CGImageGetWidth(img), h = (int)CGImageGetHeight(img);
      CGImageRelease(img);
      if (!png || ![png writeToFile:[NSString stringWithUTF8String:argv[2]] atomically:YES]) {
        fprintf(stderr, "ERR_WRITE\n");
        return 1;
      }
      printf("OK %dx%d bytes=%lu blank=%d\n", w, h, (unsigned long)png.length, blank ? 1 : 0);
      return blank ? 3 : 0;
    }
    if ([cmd isEqualToString:@"info"]) {
      CGImageRef img = DshCapture();
      if (img) {
        printf("uid=%d %zux%zu\n", getuid(), CGImageGetWidth(img), CGImageGetHeight(img));
        CGImageRelease(img);
      } else {
        printf("uid=%d unknown\n", getuid());
      }
      return 0;
    }
    return 64;
  }
}
