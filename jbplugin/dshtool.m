//
// dshtool —— 以 root 身份跑的读屏与点按工具。
//
// 为什么要有它：App 在自己的沙盒进程里，无论加什么 entitlement，
// `UIGetScreenImage` 都只能拿到本进程的图层，截别的 App 就是纯黑。
// root 进程没有这个限制。App 侧通过本机 sshd 调用它，
// 因此不需要插件注入、不需要特殊打包。
//
// 用法：
//   dshtool shot <path.png>            截整屏，写 PNG
//   dshtool tap <x> <y> [ms]           在屏幕像素坐标点按
//   dshtool swipe x1 y1 x2 y2 [ms]     滑动
//   dshtool info                       屏幕尺寸
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <unistd.h>
#include <mach/mach_time.h>

#pragma mark - 抓屏

static CGImageRef DshCapture(void) {
  typedef CGImageRef (*GetScreenFn)(void);
  GetScreenFn getScreen = (GetScreenFn)dlsym(RTLD_DEFAULT, "UIGetScreenImage");
  if (!getScreen) {
    void *uikit = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit",
                         RTLD_NOW | RTLD_LOCAL);
    if (uikit) getScreen = (GetScreenFn)dlsym(uikit, "UIGetScreenImage");
  }
  if (!getScreen) return NULL;
  CGImageRef image = getScreen();
  if (!image) return NULL;
  if (CGImageGetWidth(image) == 0 || CGImageGetHeight(image) == 0) {
    CGImageRelease(image);
    return NULL;
  }
  return image;
}

static BOOL DshIsBlank(CGImageRef image) {
  size_t w = 32, h = 32;
  uint8_t *pixels = calloc(w * h * 4, 1);
  if (!pixels) return NO;
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(pixels, w, h, 8, w * 4, space,
      kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(space);
  if (!ctx) { free(pixels); return NO; }
  CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image);
  CGContextRelease(ctx);
  size_t uniform = 0;
  uint8_t r0 = pixels[0], g0 = pixels[1], b0 = pixels[2];
  for (size_t i = 0; i < w * h; i++) {
    uint8_t r = pixels[i * 4], g = pixels[i * 4 + 1], b = pixels[i * 4 + 2];
    BOOL nearBlack = r < 12 && g < 12 && b < 12;
    BOOL same = abs((int)r - (int)r0) < 6 && abs((int)g - (int)g0) < 6 &&
                abs((int)b - (int)b0) < 6;
    if (nearBlack || same) uniform++;
  }
  free(pixels);
  return uniform * 100 >= w * h * 99;
}

#pragma mark - HID 注入

// 签名照抄 App 里已经能编译过的那份（IOSJailboneDevice.Symbols）：
//   IOHIDEventCreateDigitizerEvent(alloc, ts, type, subtype, ...)
// 字段码用 0x0C（x）与 0x0D（y），与 Swift 实现一致。
typedef CFTypeRef (*CreateDigitizerFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
    uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint8_t,
    double, double, double, double, uint32_t, uint32_t);
typedef void (*SetFloatFn)(CFTypeRef, uint32_t, double);
typedef CFTypeRef (*SystemCreateFn)(CFAllocatorRef);
typedef void (*DispatchFn)(CFTypeRef, CFTypeRef);

static CreateDigitizerFn gCreate = NULL;
static SetFloatFn gSetFloat = NULL;
static SystemCreateFn gSystemCreate = NULL;
static DispatchFn gDispatch = NULL;
static CFTypeRef gClient = NULL;

static BOOL DshHidReady(void) {
  static BOOL loaded = NO;
  static BOOL ok = NO;
  if (loaded) return ok;
  loaded = YES;
  void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",
                       RTLD_NOW | RTLD_LOCAL);
  if (!iokit) return NO;
  gCreate = (CreateDigitizerFn)dlsym(iokit, "IOHIDEventCreateDigitizerEvent");
  gSetFloat = (SetFloatFn)dlsym(iokit, "IOHIDEventSetFloatValue");
  gSystemCreate = (SystemCreateFn)dlsym(iokit, "IOHIDEventSystemClientCreate");
  gDispatch = (DispatchFn)dlsym(iokit, "IOHIDEventSystemClientDispatchEvent");
  ok = gCreate && gSystemCreate && gDispatch;
  return ok;
}

static CFTypeRef DshHidClient(void) {
  if (gClient) return gClient;
  if (!DshHidReady()) return NULL;
  gClient = gSystemCreate(kCFAllocatorDefault);
  if (!gClient) return NULL;
  // 允许向系统事件流派发，这是注入真正生效的前提。
  typedef void (*SetPropFn)(CFTypeRef, CFStringRef, CFTypeRef);
  void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",
                       RTLD_NOW | RTLD_LOCAL);
  if (iokit) {
    SetPropFn setProp = (SetPropFn)dlsym(iokit, "IOHIDEventSystemClientSetProperty");
    if (setProp) setProp(gClient, CFSTR("AllowInstrumentation"), kCFBooleanTrue);
  }
  return gClient;
}

static BOOL DshDispatchTouch(CGFloat x, CGFloat y, BOOL touched) {
  if (!DshHidReady()) return NO;
  CFTypeRef client = DshHidClient();
  if (!client) return NO;
  CFTypeRef event = gCreate(kCFAllocatorDefault, mach_absolute_time(),
                            2, 0, 0, 0, 0, 0, 0, touched ? 1 : 0,
                            (double)x, (double)y, 0, 0, 0, 0);
  if (!event) return NO;
  if (gSetFloat) {
    gSetFloat(event, 0x0C, (double)x);
    gSetFloat(event, 0x0D, (double)y);
  }
  gDispatch(client, event);
  CFRelease(event);
  return YES;
}

static void DshSleepMs(int ms) {
  if (ms > 0) usleep((useconds_t)ms * 1000);
}

static int DshTap(CGFloat x, CGFloat y, int durationMs) {
  if (!DshDispatchTouch(x, y, YES)) {
    fprintf(stderr, "ERR_HID: 建不出 HID 事件（缺 IOKit 符号或授权）\n");
    return 2;
  }
  DshSleepMs(durationMs > 0 ? durationMs : 60);
  DshDispatchTouch(x, y, NO);
  return 0;
}

static int DshSwipe(CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2, int durationMs) {
  int span = durationMs > 0 ? durationMs : 300;
  int steps = 14;
  if (!DshDispatchTouch(x1, y1, YES)) {
    fprintf(stderr, "ERR_HID\n");
    return 2;
  }
  for (int i = 1; i <= steps; i++) {
    CGFloat t = (CGFloat)i / (CGFloat)steps;
    DshDispatchTouch(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, YES);
    DshSleepMs(span / steps);
  }
  DshDispatchTouch(x2, y2, NO);
  return 0;
}

#pragma mark - 主入口

static int DshShot(const char *path) {
  CGImageRef image = DshCapture();
  if (!image) {
    fprintf(stderr, "ERR_CAPTURE: 拿不到屏幕画面\n");
    return 1;
  }
  BOOL blank = DshIsBlank(image);
  int width = (int)CGImageGetWidth(image);
  int height = (int)CGImageGetHeight(image);
  UIImage *wrapped = [UIImage imageWithCGImage:image];
  NSData *png = UIImagePNGRepresentation(wrapped);
  CGImageRelease(image);
  if (!png) {
    fprintf(stderr, "ERR_ENCODE\n");
    return 1;
  }
  NSString *target = [NSString stringWithUTF8String:path];
  if (![png writeToFile:target atomically:YES]) {
    fprintf(stderr, "ERR_WRITE: 写不进 %s\n", path);
    return 1;
  }
  printf("OK width=%d height=%d bytes=%lu blank=%d\n",
         width, height, (unsigned long)png.length, blank ? 1 : 0);
  return blank ? 3 : 0;
}

int main(int argc, char *argv[]) {
  @autoreleasepool {
    if (argc < 2) {
      printf("dshtool shot <path> | tap <x> <y> [ms] | swipe x1 y1 x2 y2 [ms] | info\n");
      return 64;
    }
    NSString *cmd = [NSString stringWithUTF8String:argv[1]];
    if ([cmd isEqualToString:@"shot"]) {
      if (argc < 3) { fprintf(stderr, "需要路径\n"); return 64; }
      return DshShot(argv[2]);
    }
    if ([cmd isEqualToString:@"tap"]) {
      if (argc < 4) { fprintf(stderr, "需要 x y\n"); return 64; }
      return DshTap(atof(argv[2]), atof(argv[3]), argc > 4 ? atoi(argv[4]) : 60);
    }
    if ([cmd isEqualToString:@"swipe"]) {
      if (argc < 6) { fprintf(stderr, "需要 x1 y1 x2 y2\n"); return 64; }
      return DshSwipe(atof(argv[2]), atof(argv[3]), atof(argv[4]), atof(argv[5]),
                      argc > 6 ? atoi(argv[6]) : 300);
    }
    if ([cmd isEqualToString:@"info"]) {
      CGImageRef image = DshCapture();
      if (image) {
        printf("uid=%d size=%zux%zu\n", getuid(),
               CGImageGetWidth(image), CGImageGetHeight(image));
        CGImageRelease(image);
      } else {
        printf("uid=%d size=unknown\n", getuid());
      }
      return 0;
    }
    fprintf(stderr, "未知命令 %s\n", argv[1]);
    return 64;
  }
}
