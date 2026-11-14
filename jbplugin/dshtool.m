//
// dshtool —— 以 root 身份跑的命令行工具，负责读屏与点按。
//
// 为什么要有它：App 在自己的沙盒进程里，无论加什么 entitlement，
// `UIGetScreenImage` 都只能拿到本进程的图层，截别的 App 就是纯黑。
// 而 root 进程没有沙盒限制，能拿到整个屏幕；HID 注入同理。
//
// App 侧通过本机 sshd（127.0.0.1:22，root）调用这个工具，因此不需要
// 任何 entitlements、不需要插件注入、也不需要 TrollStore 特殊打包。
//
// 用法：
//   dshtool shot <path.png>      截整屏，写 PNG
//   dshtool tap <x> <y> [ms]     在像素坐标点按
//   dshtool swipe x1 y1 x2 y2 [ms]
//   dshtool info                 输出屏幕尺寸、前台应用、是否锁定
//   dshtool home                 按 Home
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <unistd.h>

#pragma mark - 抓屏

static CGImageRef DshCapture(void) {
  // UIGetScreenImage 是唯一在 root 下能拿到整屏的老接口；在沙盒 App 里
  // 它只返回自己的图层，这就是之前一直截到纯黑的原因。
  typedef CGImageRef (*GetScreenFn)(void);
  GetScreenFn getScreen = (GetScreenFn)dlsym(RTLD_DEFAULT, "UIGetScreenImage");
  if (!getScreen) {
    void *uikit = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_NOW);
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
    BOOL same = abs((int)r - (int)r0) < 6 && abs((int)g - (int)g0) < 6 && abs((int)b - (int)b0) < 6;
    if (nearBlack || same) uniform++;
  }
  free(pixels);
  return uniform * 100 >= w * h * 99;
}

#pragma mark - HID 注入

static CFTypeRef gHidClient = NULL;

static CFTypeRef DshHidClient(void) {
  if (gHidClient) return gHidClient;
  void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
  if (!iokit) return NULL;
  typedef CFTypeRef (*CreateFn)(CFAllocatorRef);
  typedef void (*SetPropFn)(CFTypeRef, CFStringRef, CFTypeRef);
  CreateFn create = (CreateFn)dlsym(iokit, "IOHIDEventSystemClientCreate");
  SetPropFn setProp = (SetPropFn)dlsym(iokit, "IOHIDEventSystemClientSetProperty");
  if (!create || !setProp) return NULL;
  gHidClient = create(kCFAllocatorDefault);
  if (!gHidClient) return NULL;
  // 允许监听所有设备的事件流，这是注入能真正送进系统的关键。
  setProp(gHidClient, CFSTR("AllowInstrumentation"), kCFBooleanTrue);
  return gHidClient;
}

static BOOL DshDispatchDigitizer(CGFloat x, CGFloat y, BOOL touched) {
  void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
  if (!iokit) return NO;
  typedef CFTypeRef (*CreateDigitizerFn)(CFAllocatorRef, IOHIDEventType, uint64_t, uint32_t,
      uint32_t, IOHIDEventOptionBits, double, double, double, double, double, double, double,
      double, double, double, double, uint32_t, uint32_t, uint32_t, uint32_t);
  typedef void (*SetIntegerFn)(CFTypeRef, IOHIDEventField, CFIndex);
  typedef void (*AppendFn)(CFTypeRef, CFTypeRef);
  typedef void (*DispatchFn)(CFTypeRef, CFTypeRef);
  CreateDigitizerFn create = (CreateDigitizerFn)dlsym(iokit, "IOHIDEventCreateDigitizerEvent");
  SetIntegerFn setInt = (SetIntegerFn)dlsym(iokit, "IOHIDEventSetIntegerValue");
  AppendFn append = (AppendFn)dlsym(iokit, "IOHIDEventAppendEvent");
  DispatchFn dispatch = (DispatchFn)dlsym(iokit, "IOHIDEventSystemClientDispatchEvent");
  if (!create || !dispatch) return NO;
  CFTypeRef client = DshHidClient();
  if (!client) return NO;

  CFTypeRef finger = create(kCFAllocatorDefault,
      kIOHIDEventTypeDigitizer, 0, 0, 0, 0,
      0, 0, 0, x / 1000.0, y / 1000.0, 1.0, 1.0, 0, 0, 0, 0,
      0, 0, 0, 0);
  if (!finger) return NO;
  if (setInt) {
    setInt(finger, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
    setInt(finger, kIOHIDEventFieldDigitizerRange, 1);
  }
  CFTypeRef event = create(kCFAllocatorDefault,
      kIOHIDEventTypeDigitizer, 0, 0, 0, 0,
      0, 0, 0, x / 1000.0, y / 1000.0, 1.0, 1.0, 0, 0, 0, 0,
      0, 0, 0, touched ? 1 : 0);
  if (!event) { CFRelease(finger); return NO; }
  if (setInt) {
    setInt(event, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
    setInt(event, kIOHIDEventFieldDigitizerRange, 1);
  }
  if (append) append(event, finger);
  dispatch(client, event);
  CFRelease(event);
  CFRelease(finger);
  return YES;
}

static void DshSleepMs(int ms) {
  usleep((useconds_t)ms * 1000);
}

static int DshTap(CGFloat x, CGFloat y, int durationMs) {
  if (!DshDispatchDigitizer(x, y, YES)) {
    fprintf(stderr, "ERR_HID\n");
    return 2;
  }
  DshSleepMs(durationMs > 0 ? durationMs : 60);
  DshDispatchDigitizer(x, y, NO);
  return 0;
}

static int DshSwipe(CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2, int durationMs) {
  int span = durationMs > 0 ? durationMs : 300;
  int steps = 14;
  if (!DshDispatchDigitizer(x1, y1, YES)) {
    fprintf(stderr, "ERR_HID\n");
    return 2;
  }
  for (int i = 1; i <= steps; i++) {
    CGFloat t = (CGFloat)i / (CGFloat)steps;
    DshDispatchDigitizer(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, YES);
    DshSleepMs(span / steps);
  }
  DshDispatchDigitizer(x2, y2, NO);
  return 0;
}

#pragma mark - 主入口

static CGSize DshScreenSize(void) {
  CGImageRef image = DshCapture();
  if (!image) return CGSizeZero;
  CGSize size = CGSizeMake(CGImageGetWidth(image), CGImageGetHeight(image));
  CGImageRelease(image);
  return size;
}

static int DshShot(const char *path) {
  CGImageRef image = DshCapture();
  if (!image) {
    fprintf(stderr, "ERR_CAPTURE: 拿不到屏幕画面\n");
    return 1;
  }
  BOOL blank = DshIsBlank(image);
  int width = (int)CGImageGetWidth(image), height = (int)CGImageGetHeight(image);
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
      CGSize size = DshScreenSize();
      printf("uid=%d size=%.0fx%.0f\n", getuid(), size.width, size.height);
      return 0;
    }
    fprintf(stderr, "未知命令 %s\n", argv[1]);
    return 64;
  }
}
