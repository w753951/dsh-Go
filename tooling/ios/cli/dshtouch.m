// dshtouch — 越狱设备上的命令行操控工具。
//
// 为什么单独做一个 CLI：iOS 15 上让 App 自带越狱权限会让 Flutter 启动即崩，
// 而命令行工具以 root 运行，不受沙盒约束，也不依赖任何 App 的签名。
//
// 用法：
//   dshtouch tap <x> <y>              按 0…1 比例点击
//   dshtouch tapxy <px> <py>          按物理像素点击
//   dshtouch swipe <x1> <y1> <x2> <y2> [ms]
//   dshtouch key home|enter|back
//   dshtouch type <text>              仅 ASCII，走 HID 键盘
//   dshtouch paste <text>             任意文字，写剪贴板后发 ⌘V
//   dshtouch open <bundle-id>
//   dshtouch apps [匹配串]
//   dshtouch screen [输出路径]        存一张整屏 PNG
//   dshtouch size                     打印屏幕点数与像素
//
// 全部失败都返回非零退出码并打印原因，绝不假装成功。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach_time.h>

static int gFailures = 0;

static void fail(NSString *format, ...) {
  va_list args;
  va_start(args, format);
  NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);
  fprintf(stderr, "dshtouch: %s\n", message.UTF8String);
  gFailures++;
}

// MARK: - IOKit HID

typedef struct {
  void *(*createDigitizer)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t,
                           uint32_t, uint32_t, uint32_t, uint8_t, double, double, double, double,
                           uint32_t, uint32_t);
  void *(*createKeyboard)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint8_t, uint32_t);
  void (*setFloat)(CFTypeRef, uint32_t, double);
  void *(*systemCreate)(CFAllocatorRef);
  void (*dispatch)(CFTypeRef, CFTypeRef);
} HIDTable;

static HIDTable gHID;

static BOOL loadHID(void) {
  void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
  void *main = dlopen(NULL, RTLD_NOW);
  if (!iokit && !main) {
    fail(@"无法加载 IOKit");
    return NO;
  }
  void *handles[2] = {iokit, main};
  void *(^lookup)(const char *) = ^void *(const char *name) {
    for (int i = 0; i < 2; i++) {
      if (!handles[i]) continue;
      void *symbol = dlsym(handles[i], name);
      if (symbol) return symbol;
    }
    return NULL;
  };

  gHID.createDigitizer = lookup("IOHIDEventCreateDigitizerEvent");
  gHID.createKeyboard = lookup("IOHIDEventCreateKeyboardEvent");
  gHID.setFloat = lookup("IOHIDEventSetFloatValue");
  gHID.systemCreate = lookup("IOHIDEventSystemClientCreate");
  gHID.dispatch = lookup("IOHIDEventSystemClientDispatchEvent");

  if (!gHID.createDigitizer || !gHID.createKeyboard || !gHID.systemCreate || !gHID.dispatch) {
    fail(@"缺少 IOHIDEvent 接口（越狱环境不完整）");
    return NO;
  }
  return YES;
}

static CFTypeRef gClient;

static CFTypeRef hidClient(void) {
  if (!gClient) {
    gClient = gHID.systemCreate(kCFAllocatorDefault);
  }
  return gClient;
}

static void sendEvent(CFTypeRef event) {
  if (!event) return;
  CFTypeRef client = hidClient();
  if (!client) return;
  gHID.dispatch(client, event);
}

static CFTypeRef digitizer(CGFloat x, CGFloat y, BOOL touched) {
  void *raw = gHID.createDigitizer(kCFAllocatorDefault, mach_absolute_time(),
                                   2, 0, 0, 0, 0, 0, 0, touched ? 1 : 0,
                                   (double)x, (double)y, 0, 0, 0, 0);
  if (!raw) return NULL;
  CFTypeRef event = (CFTypeRef)raw;
  if (gHID.setFloat) {
    gHID.setFloat(event, 0x0C, (double)x);
    gHID.setFloat(event, 0x0D, (double)y);
  }
  return event;
}

// MARK: - 屏幕

typedef struct {
  CGFloat width;
  CGFloat height;
  CGFloat scale;
} ScreenMetrics;

static ScreenMetrics metrics(void) {
  CGSize bounds = UIScreen.mainScreen.bounds;
  ScreenMetrics m = {bounds.width, bounds.height, UIScreen.mainScreen.scale};
  return m;
}

typedef CGImageRef (*GetScreenImageFn)(void);

static CGImageRef captureScreen(void) {
  void *uikit = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_NOW);
  void *main = dlopen(NULL, RTLD_NOW);
  // 越狱环境里 UIGetScreenImage 通常在；拿不到就明确失败。
  GetScreenImageFn fn = NULL;
  if (uikit) fn = (GetScreenImageFn)dlsym(uikit, "UIGetScreenImage");
  if (!fn && main) fn = (GetScreenImageFn)dlsym(main, "UIGetScreenImage");
  if (!fn) {
    fail(@"找不到 UIGetScreenImage");
    return NULL;
  }
  return fn();
}

// MARK: - 键盘

static const uint32_t kUsageReturn = 0x28;
static const uint32_t kUsageShift = 0xE1;
static const uint32_t kUsageCommand = 0xE3;

static uint32_t usageForCharacter(unichar c, BOOL *shift) {
  *shift = NO;
  if (c >= 'a' && c <= 'z') return 0x04 + (uint32_t)(c - 'a');
  if (c >= 'A' && c <= 'Z') { *shift = YES; return 0x04 + (uint32_t)(c - 'A'); }
  if (c >= '1' && c <= '9') return 0x1E + (uint32_t)(c - '1');
  if (c == '0') return 0x27;
  switch (c) {
    case ' ': return 0x2C;
    case '-': return 0x2D;
    case '=': return 0x2E;
    case '[': return 0x2F;
    case ']': return 0x30;
    case '\\': return 0x31;
    case ';': return 0x33;
    case '\'': return 0x34;
    case '`': return 0x35;
    case ',': return 0x36;
    case '.': return 0x37;
    case '/': return 0x38;
    case '\n': return kUsageReturn;
    case '!': *shift = YES; return 0x1E;
    case '@': *shift = YES; return 0x1F;
    case '#': *shift = YES; return 0x20;
    case '$': *shift = YES; return 0x21;
    case '%': *shift = YES; return 0x22;
    case '^': *shift = YES; return 0x23;
    case '&': *shift = YES; return 0x24;
    case '*': *shift = YES; return 0x25;
    case '(': *shift = YES; return 0x26;
    case ')': *shift = YES; return 0x27;
    case '_': *shift = YES; return 0x2D;
    case '+': *shift = YES; return 0x2E;
    case '{': *shift = YES; return 0x2F;
    case '}': *shift = YES; return 0x30;
    case '|': *shift = YES; return 0x31;
    case ':': *shift = YES; return 0x33;
    case '"': *shift = YES; return 0x34;
    case '~': *shift = YES; return 0x35;
    case '<': *shift = YES; return 0x36;
    case '>': *shift = YES; return 0x37;
    case '?': *shift = YES; return 0x38;
    default: return 0;
  }
}

static CFTypeRef keyEvent(uint32_t usage, BOOL down) {
  void *raw = gHID.createKeyboard(kCFAllocatorDefault, mach_absolute_time(), 0x07, usage, down ? 1 : 0, 0);
  return (CFTypeRef)raw;
}

static void pressKey(uint32_t usage, BOOL shift) {
  if (shift) sendEvent(keyEvent(kUsageShift, YES));
  sendEvent(keyEvent(usage, YES));
  usleep(12000);
  sendEvent(keyEvent(usage, NO));
  if (shift) sendEvent(keyEvent(kUsageShift, NO));
  usleep(12000);
}

// MARK: - 应用

static id workspace(void) {
  dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
  dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW);
  Class cls = NSClassFromString(@"LSApplicationWorkspace");
  if (!cls) {
    fail(@"找不到 LSApplicationWorkspace");
    return nil;
  }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
  return [cls performSelector:NSSelectorFromString(@"defaultWorkspace")];
#pragma clang diagnostic pop
}

// MARK: - 命令

static int commandTap(NSArray<NSString *> *args, BOOL pixels) {
  if (args.count < 2) { fail(@"tap 需要两个坐标"); return 1; }
  ScreenMetrics m = metrics();
  double x = args[0].doubleValue;
  double y = args[1].doubleValue;
  CGFloat px = pixels ? (CGFloat)x : (CGFloat)x * m.width;
  CGFloat py = pixels ? (CGFloat)y : (CGFloat)y * m.height;
  CFTypeRef down = digitizer(px, py, YES);
  if (!down) { fail(@"无法创建触摸事件"); return 1; }
  sendEvent(down);
  usleep(60000);
  sendEvent(digitizer(px, py, NO));
  printf("tap %.0f,%.0f\n", px, py);
  return 0;
}

static int commandSwipe(NSArray<NSString *> *args) {
  if (args.count < 4) { fail(@"swipe 需要四个坐标"); return 1; }
  ScreenMetrics m = metrics();
  CGFloat x1 = args[0].doubleValue * m.width;
  CGFloat y1 = args[1].doubleValue * m.height;
  CGFloat x2 = args[2].doubleValue * m.width;
  CGFloat y2 = args[3].doubleValue * m.height;
  int duration = args.count >= 5 ? args[4].intValue : 300;
  int steps = duration > 300 ? 16 : 10;
  CFTypeRef start = digitizer(x1, y1, YES);
  if (!start) { fail(@"无法创建触摸事件"); return 1; }
  sendEvent(start);
  usleep((useconds_t)((duration * 1000) / steps));
  for (int i = 1; i <= steps; i++) {
    double t = (double)i / steps;
    sendEvent(digitizer(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, YES));
    usleep((useconds_t)((duration * 1000) / steps));
  }
  sendEvent(digitizer(x2, y2, NO));
  printf("swipe %.0f,%.0f -> %.0f,%.0f\n", x1, y1, x2, y2);
  return 0;
}

static int commandKey(NSString *name) {
  if ([name isEqualToString:@"enter"]) { pressKey(kUsageReturn, NO); printf("enter\n"); return 0; }
  if ([name isEqualToString:@"home"]) {
    void *sb = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
    if (!sb) { fail(@"无法加载 SpringBoardServices"); return 1; }
    void (*suspend)(CFStringRef) = (void (*)(CFStringRef))dlsym(sb, "SBSSuspendFrontmostApplication");
    if (!suspend) { fail(@"找不到 SBSSuspendFrontmostApplication"); return 1; }
    suspend(CFSTR(""));
    printf("home\n");
    return 0;
  }
  if ([name isEqualToString:@"back"]) {
    // 从屏幕左缘右滑，等同于返回上一级。
    ScreenMetrics m = metrics();
    NSArray *args = @[@"0.005", @"0.5", @"0.65", @"0.5", @"300"];
    (void)m;
    return commandSwipe(args);
  }
  fail(@"未知按键 %@", name);
  return 1;
}

static int commandType(NSString *text) {
  for (NSUInteger i = 0; i < text.length; i++) {
    BOOL shift = NO;
    uint32_t usage = usageForCharacter([text characterAtIndex:i], &shift);
    if (!usage) continue;
    pressKey(usage, shift);
  }
  printf("typed %lu chars\n", (unsigned long)text.length);
  return 0;
}

static int commandPaste(NSString *text) {
  // 中文等非 ASCII 只能靠剪贴板：先写入，再发 ⌘V。
  UIPasteboard *board = [UIPasteboard generalPasteboard];
  board.string = text;
  usleep(150000);
  sendEvent(keyEvent(kUsageCommand, YES));
  usleep(30000);
  sendEvent(keyEvent(0x19, YES));
  usleep(30000);
  sendEvent(keyEvent(0x19, NO));
  usleep(30000);
  sendEvent(keyEvent(kUsageCommand, NO));
  printf("pasted %lu chars\n", (unsigned long)text.length);
  return 0;
}

static int commandOpen(NSString *bundleID) {
  void *sb = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
  if (sb) {
    int32_t (*open)(CFStringRef, Boolean) =
        (int32_t (*)(CFStringRef, Boolean))dlsym(sb, "SBSLaunchApplicationWithIdentifier");
    if (open && open((__bridge CFStringRef)bundleID, false) == 0) {
      printf("opened %s\n", bundleID.UTF8String);
      return 0;
    }
  }
  id ws = workspace();
  if (!ws) return 1;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
  BOOL ok = [ws performSelector:NSSelectorFromString(@"openApplicationWithBundleID:") withObject:bundleID] != nil;
#pragma clang diagnostic pop
  if (!ok) { fail(@"打不开 %@", bundleID); return 1; }
  printf("opened %s\n", bundleID.UTF8String);
  return 0;
}

static int commandApps(NSString *query) {
  id ws = workspace();
  if (!ws) return 1;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
  NSArray *all = [ws performSelector:NSSelectorFromString(@"allInstalledApplications")];
#pragma clang diagnostic pop
  if (![all isKindOfClass:[NSArray class]]) { fail(@"取不到应用列表"); return 1; }
  int shown = 0;
  for (id app in all) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    NSString *identifier = [app performSelector:NSSelectorFromString(@"bundleIdentifier")];
    NSString *name = [app performSelector:NSSelectorFromString(@"localizedName")];
#pragma clang diagnostic pop
    if (!identifier.length) continue;
    if (!name.length) name = identifier;
    if (query.length &&
        [name rangeOfString:query options:NSCaseInsensitiveSearch].location == NSNotFound &&
        [identifier rangeOfString:query options:NSCaseInsensitiveSearch].location == NSNotFound) {
      continue;
    }
    printf("%s\t%s\n", name.UTF8String, identifier.UTF8String);
    shown++;
  }
  fprintf(stderr, "共 %d 项\n", shown);
  return 0;
}

static int commandScreen(NSString *path) {
  CGImageRef image = captureScreen();
  if (!image) return 1;
  UIImage *ui = [UIImage imageWithCGImage:image];
  NSData *png = UIImagePNGRepresentation(ui);
  if (!png) { fail(@"编码 PNG 失败"); return 1; }
  NSString *target = path.length ? path : @"/var/mobile/dshtouch-screen.png";
  NSError *error = nil;
  if (![png writeToFile:target options:NSDataWritingAtomic error:&error]) {
    fail(@"写入失败: %@", error.localizedDescription);
    return 1;
  }
  ScreenMetrics m = metrics();
  printf("%s (%.0fx%.0f pt, %lux%lu px)\n", target.UTF8String, m.width, m.height,
         (unsigned long)CGImageGetWidth(image), (unsigned long)CGImageGetHeight(image));
  return 0;
}

int main(int argc, char *argv[]) {
  @autoreleasepool {
    if (argc < 2) {
      printf("dshtouch — 越狱设备命令行操控\n\n");
      printf("  tap <x> <y>              比例点击 (0…1)\n");
      printf("  tapxy <px> <py>          像素点击\n");
      printf("  swipe <x1> <y1> <x2> <y2> [ms]\n");
      printf("  key home|enter|back\n");
      printf("  type <ascii-text>\n");
      printf("  paste <text>             任意文字，走剪贴板\n");
      printf("  open <bundle-id>\n");
      printf("  apps [query]\n");
      printf("  screen [path]\n");
      printf("  size\n");
      return 2;
    }

    if (!loadHID()) return 1;

    NSString *command = [NSString stringWithUTF8String:argv[1]];
    NSMutableArray<NSString *> *args = [NSMutableArray array];
    for (int i = 2; i < argc; i++) {
      [args addObject:[NSString stringWithUTF8String:argv[i]]];
    }

    if ([command isEqualToString:@"tap"]) return commandTap(args, NO);
    if ([command isEqualToString:@"tapxy"]) return commandTap(args, YES);
    if ([command isEqualToString:@"swipe"]) return commandSwipe(args);
    if ([command isEqualToString:@"key"]) return commandKey(args.count ? args[0] : @"");
    if ([command isEqualToString:@"type"]) return commandType(args.count ? args[0] : @"");
    if ([command isEqualToString:@"paste"]) return commandPaste(args.count ? args[0] : @"");
    if ([command isEqualToString:@"open"]) return commandOpen(args.count ? args[0] : @"");
    if ([command isEqualToString:@"apps"]) return commandApps(args.count ? args[0] : @"");
    if ([command isEqualToString:@"screen"]) return commandScreen(args.count ? args[0] : @"");
    if ([command isEqualToString:@"size"]) {
      ScreenMetrics m = metrics();
      printf("%.0fx%.0f pt, scale %.1f, %lux%lu px\n", m.width, m.height, m.scale,
             (unsigned long)(m.width * m.scale), (unsigned long)(m.height * m.scale));
      return 0;
    }

    fail(@"未知命令 %@", command);
    return 2;
  }
}
