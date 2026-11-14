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

static CFTypeRef DshMakeEvent(CGFloat x, CGFloat y, BOOL touched) {
  if (!gCreate) return NULL;
  CFTypeRef e = gCreate(kCFAllocatorDefault, mach_absolute_time(),
                        2, 0, 0, 0, 0, 0, 0, touched ? 1 : 0,
                        (double)x, (double)y, 0, 0, 0, 0);
  if (!e) return NULL;
  if (gSetFloat) {
    gSetFloat(e, 0x0C, (double)x);
    gSetFloat(e, 0x0D, (double)y);
  }
  return e;
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


// 单次长按：只用一个 client，按住期间持续发移动事件。
//
// 之前 tap 走的 DshTapDiag 会循环 5 种 client，等于连点 5 次、每次间隔 0.4 秒——
// 系统把它看成多次点击，永远不构成「长按」。长按需要一次持续的触摸，
// 而且中途要有移动事件让系统知道手指还在。
static int DshHold(CGFloat x, CGFloat y, int durationMs) {
  if (!DshLoadIOKit()) { printf("IOKit fail\n"); return 2; }
  int hold = durationMs > 0 ? durationMs : 1200;
  CFTypeRef client = gSystemCreate ? gSystemCreate(kCFAllocatorDefault) : NULL;
  if (!client) { printf("client nil\n"); return 2; }
  if (gSetProp) gSetProp(client, CFSTR("AllowInstrumentation"), kCFBooleanTrue);

  CFTypeRef down = DshMakeEvent(x, y, YES);
  if (!down) { printf("down nil\n"); CFRelease(client); return 2; }
  gDispatch(client, down);
  CFRelease(down);

  // 按住期间每 60ms 发一次同位置移动事件，模拟手指停在那里。
  int elapsed = 0;
  while (elapsed < hold) {
    usleep(60 * 1000);
    elapsed += 60;
    CFTypeRef move = DshMakeEvent(x, y, YES);
    if (move) { gDispatch(client, move); CFRelease(move); }
  }

  CFTypeRef up = DshMakeEvent(x, y, NO);
  if (up) { gDispatch(client, up); CFRelease(up); }
  CFRelease(client);
  printf("长按 %dms 完成 (%g,%g)\n", hold, (double)x, (double)y);
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
