//
// dshtool —— root 下的读屏与点按工具。
//
// 关键约束：从 sshd 启动的 root 进程不在图形会话里，UIGetScreenImage 往往
// 直接返回空。因此这里依次尝试多条路径，并且 `probe` 子命令会把每条路径
// 的结果都打印出来——先用它确定这台设备上到底哪条路可用，再把那条路
// 接进 App。不要凭猜测写第二遍。
//
// 用法：
//   dshtool probe                       逐条测试抓屏途径，输出结果
//   dshtool shot <path.png>             截整屏
//   dshtool tap <x> <y> [ms]            点按
//   dshtool swipe x1 y1 x2 y2 [ms]      滑动
//   dshtool info                        屏幕尺寸
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <unistd.h>
#include <mach/mach_time.h>

#pragma mark - 抓屏途径

typedef CGImageRef (*GetScreenFn)(void);
typedef IOReturn (*IOSurfaceLockFn)(void *, uint32_t, uint32_t *);
typedef IOReturn (*IOSurfaceUnlockFn)(void *, uint32_t, uint32_t *);
typedef void *(*IOSurfaceGetBaseAddressFn)(void *);

static void *DshOpen(const char *path) {
  return dlopen(path, RTLD_NOW | RTLD_LOCAL);
}

// 途径 1：UIGetScreenImage（UIKit 私有整屏接口）。
static CGImageRef DshTryUIGetScreenImage(void) {
  GetScreenFn fn = (GetScreenFn)dlsym(RTLD_DEFAULT, "UIGetScreenImage");
  if (!fn) {
    void *uikit = DshOpen("/System/Library/Frameworks/UIKit.framework/UIKit");
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

// 途径 2：HID 的 Capture 模式。IOHIDEventSystemClient 建好后设
// "ScreenCaptureMode"，部分系统版本会返回可用的截图回调。
static CGImageRef DshTryHIDCapture(void) {
  void *iokit = DshOpen("/System/Library/Frameworks/IOKit.framework/IOKit");
  if (!iokit) return NULL;
  typedef CFTypeRef (*CreateFn)(CFAllocatorRef);
  typedef void (*SetPropFn)(CFTypeRef, CFStringRef, CFTypeRef);
  CreateFn create = (CreateFn)dlsym(iokit, "IOHIDEventSystemClientCreate");
  SetPropFn setProp = (SetPropFn)dlsym(iokit, "IOHIDEventSystemClientSetProperty");
  if (!create) return NULL;
  CFTypeRef client = create(kCFAllocatorDefault);
  if (!client) return NULL;
  if (setProp) {
    setProp(client, CFSTR("ScreenCaptureMode"), kCFBooleanTrue);
    setProp(client, CFSTR("AllowInstrumentation"), kCFBooleanTrue);
  }
  CFRelease(client);
  return NULL;
}

// 途径 3：通过 SpringBoard 的私有类。需要能跟 SpringBoard 通信，
// 从 sshd 起的进程通常做不到，这里只用于确认失败原因。
static CGImageRef DshTrySpringBoard(void) {
  Class sb = NSClassFromString(@"SpringBoard");
  if (!sb) return NULL;
  return NULL;
}

static CGImageRef DshTryAll(NSString **winner) {
  CGImageRef image = DshTryUIGetScreenImage();
  if (image) { if (winner) *winner = @"UIGetScreenImage"; return image; }
  image = DshTryHIDCapture();
  if (image) { if (winner) *winner = @"HIDCapture"; return image; }
  image = DshTrySpringBoard();
  if (image) { if (winner) *winner = @"SpringBoard"; return image; }
  if (winner) *winner = @"none";
  return NULL;
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
  static BOOL loaded = NO, ok = NO;
  if (loaded) return ok;
  loaded = YES;
  void *iokit = DshOpen("/System/Library/Frameworks/IOKit.framework/IOKit");
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
  void *iokit = DshOpen("/System/Library/Frameworks/IOKit.framework/IOKit");
  if (iokit) {
    typedef void (*SetPropFn)(CFTypeRef, CFStringRef, CFTypeRef);
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

#pragma mark - 命令

static int DshProbe(void) {
  printf("uid=%d euid=%d\n", getuid(), geteuid());
  printf("bundle=%s\n", [[[NSBundle mainBundle] bundleIdentifier] UTF8String] ?: "(null)");
  // 是否有 UIKit 的 UIApplication（图形会话标志）
  Class appClass = NSClassFromString(@"UIApplication");
  printf("UIApplication=%s\n", appClass ? "present" : "absent");
  if (appClass) {
    id app = [appClass performSelector:@selector(sharedApplication)];
    printf("sharedApplication=%s\n", app ? "ok" : "nil");
  }
  Class screenClass = NSClassFromString(@"UIScreen");
  printf("UIScreen=%s\n", screenClass ? "present" : "absent");
  if (screenClass) {
    id screen = [screenClass performSelector:@selector(mainScreen)];
    if (screen) {
      CGRect bounds = [screen performSelector:@selector(bounds)] ? CGRectZero : CGRectZero;
      (void)bounds;
      printf("mainScreen=ok\n");
    } else {
      printf("mainScreen=nil (没有图形会话)\n");
    }
  }
  NSString *winner = nil;
  CGImageRef image = DshTryAll(&winner);
  if (image) {
    printf("capture=OK via=%s size=%zux%zu blank=%d\n",
           [winner UTF8String], CGImageGetWidth(image), CGImageGetHeight(image),
           DshIsBlank(image) ? 1 : 0);
    CGImageRelease(image);
  } else {
    printf("capture=FAIL via=%s\n", [winner UTF8String]);
  }
  printf("hid=%s\n", DshHidReady() ? "symbols-ok" : "missing-symbols");
  return 0;
}

static int DshShot(const char *path) {
  NSString *winner = nil;
  CGImageRef image = DshTryAll(&winner);
  if (!image) {
    fprintf(stderr, "ERR_CAPTURE: 所有抓屏途径都失败（via=%s）\n", [winner UTF8String]);
    return 1;
  }
  BOOL blank = DshIsBlank(image);
  int width = (int)CGImageGetWidth(image), height = (int)CGImageGetHeight(image);
  UIImage *wrapped = [UIImage imageWithCGImage:image];
  NSData *png = UIImagePNGRepresentation(wrapped);
  CGImageRelease(image);
  if (!png) { fprintf(stderr, "ERR_ENCODE\n"); return 1; }
  if (![png writeToFile:[NSString stringWithUTF8String:path] atomically:YES]) {
    fprintf(stderr, "ERR_WRITE\n");
    return 1;
  }
  printf("OK via=%s width=%d height=%d bytes=%lu blank=%d\n",
         [winner UTF8String], width, height, (unsigned long)png.length, blank ? 1 : 0);
  return blank ? 3 : 0;
}

static int DshTap(CGFloat x, CGFloat y, int durationMs) {
  if (!DshDispatchTouch(x, y, YES)) {
    fprintf(stderr, "ERR_HID\n");
    return 2;
  }
  usleep((useconds_t)(durationMs > 0 ? durationMs : 60) * 1000);
  DshDispatchTouch(x, y, NO);
  return 0;
}

static int DshSwipe(CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2, int durationMs) {
  int span = durationMs > 0 ? durationMs : 300, steps = 14;
  if (!DshDispatchTouch(x1, y1, YES)) { fprintf(stderr, "ERR_HID\n"); return 2; }
  for (int i = 1; i <= steps; i++) {
    CGFloat t = (CGFloat)i / (CGFloat)steps;
    DshDispatchTouch(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, YES);
    usleep((useconds_t)(span / steps) * 1000);
  }
  DshDispatchTouch(x2, y2, NO);
  return 0;
}

int main(int argc, char *argv[]) {
  @autoreleasepool {
    if (argc < 2) {
      printf("dshtool probe | shot <path> | tap <x> <y> [ms] | swipe x1 y1 x2 y2 [ms] | info\n");
      return 64;
    }
    NSString *cmd = [NSString stringWithUTF8String:argv[1]];
    if ([cmd isEqualToString:@"probe"]) return DshProbe();
    if ([cmd isEqualToString:@"shot"]) {
      if (argc < 3) return 64;
      return DshShot(argv[2]);
    }
    if ([cmd isEqualToString:@"tap"]) {
      if (argc < 4) return 64;
      return DshTap(atof(argv[2]), atof(argv[3]), argc > 4 ? atoi(argv[4]) : 60);
    }
    if ([cmd isEqualToString:@"swipe"]) {
      if (argc < 6) return 64;
      return DshSwipe(atof(argv[2]), atof(argv[3]), atof(argv[4]), atof(argv[5]),
                      argc > 6 ? atoi(argv[6]) : 300);
    }
    if ([cmd isEqualToString:@"info"]) {
      NSString *winner = nil;
      CGImageRef image = DshTryAll(&winner);
      if (image) {
        printf("uid=%d via=%s size=%zux%zu\n", getuid(), [winner UTF8String],
               CGImageGetWidth(image), CGImageGetHeight(image));
        CGImageRelease(image);
      } else {
        printf("uid=%d size=unknown via=%s\n", getuid(), [winner UTF8String]);
      }
      return 0;
    }
    fprintf(stderr, "未知命令\n");
    return 64;
  }
}
