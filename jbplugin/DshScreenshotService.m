//
// DshScreenshotService.dylib
//
// 注入 SpringBoard 进程，监听本机回环端口，按请求截一张整屏返回 PNG。
//
// 为什么需要它：App 在自己的沙盒进程里，`_UICreateScreenUIImage` 只能拿到本
// 进程的图层，截别的 App 就是一张纯黑。只有住在 SpringBoard 里的代码才看得见
// 整个屏幕——Snapper 3 能截图正是这个原因。
//
// 只做一件事：把屏幕像素交出去。不做点按、不做输入、不读剪贴板、不联网。
// 只监听 127.0.0.1，并且要求请求里带上 App 与插件约定的密钥，
// 避免同机其它程序随意调用。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <errno.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

// 与 App 侧约定的端口和密钥。改这里就要同时改 App 侧。
static const int kDshScreenPort = 47191;
static NSString *const kDshSharedKey = @"dsh-go-screen-v1";

#pragma mark - 抓屏

static CGImageRef DshCaptureFullScreen(void) {
  // 优先用 UIKit 的整屏接口：在 SpringBoard 里它拿到的就是当前显示的一切。
  typedef CGImageRef (*GetScreenFn)(void);
  GetScreenFn getScreen = (GetScreenFn)dlsym(RTLD_DEFAULT, "UIGetScreenImage");
  if (getScreen) {
    CGImageRef image = getScreen();
    if (image && CGImageGetWidth(image) > 0) return image;
    if (image) CGImageRelease(image);
  }
  // 退一步：私有类方法。
  Class screenClass = NSClassFromString(@"UIScreen");
  if ([screenClass respondsToSelector:NSSelectorFromString(@"mainScreen")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id screen = [screenClass performSelector:NSSelectorFromString(@"mainScreen")];
    if ([screen respondsToSelector:NSSelectorFromString(@"_snapshotView")]) {
      UIView *view = [screen performSelector:NSSelectorFromString(@"_snapshotView")];
#pragma clang diagnostic pop
      if ([view isKindOfClass:[UIView class]] && view.bounds.size.width > 0) {
        UIGraphicsImageRenderer *renderer =
            [[UIGraphicsImageRenderer alloc] initWithBounds:view.bounds];
        UIImage *rendered = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
          [view drawViewHierarchyInRect:view.bounds afterScreenUpdates:NO];
        }];
        return CGImageRetain(rendered.CGImage);
      }
    }
  }
  return NULL;
}

#pragma mark - HTTP

static NSData *DshPngFromCGImage(CGImageRef image) {
  if (!image) return nil;
  UIImage *wrapped = [UIImage imageWithCGImage:image];
  NSData *png = UIImagePNGRepresentation(wrapped);
  return png;
}

static void DshWriteAll(int fd, const void *bytes, size_t length) {
  const uint8_t *p = (const uint8_t *)bytes;
  size_t written = 0;
  while (written < length) {
    ssize_t n = write(fd, p + written, length - written);
    if (n <= 0) return;
    written += (size_t)n;
  }
}

static void DshRespond(int fd, int status, const char *reason,
                       const void *body, size_t bodyLength,
                       const char *contentType) {
  char header[512];
  int headerLength = snprintf(header, sizeof(header),
      "HTTP/1.1 %d %s\r\n"
      "Content-Type: %s\r\n"
      "Content-Length: %zu\r\n"
      "Connection: close\r\n"
      "\r\n",
      status, reason, contentType, bodyLength);
  DshWriteAll(fd, header, (size_t)headerLength);
  if (body && bodyLength) DshWriteAll(fd, body, bodyLength);
}

static void DshHandleClient(int fd) {
  char request[2048] = {0};
  ssize_t got = read(fd, request, sizeof(request) - 1);
  if (got <= 0) { close(fd); return; }
  request[got] = '\0';

  // 只接受带正确密钥的 GET /capture。
  NSString *raw = [NSString stringWithUTF8String:request];
  BOOL authorized = [raw containsString:kDshSharedKey];
  BOOL wantsCapture = [raw hasPrefix:@"GET /capture"] || [raw containsString:@"GET /capture"];

  if (!authorized) {
    DshRespond(fd, 403, "Forbidden", "denied", 6, "text/plain");
    close(fd);
    return;
  }
  if (!wantsCapture) {
    // 健康检查：App 用它确认插件在不在。
    DshRespond(fd, 200, "OK", "dsh-screen", 10, "text/plain");
    close(fd);
    return;
  }

  CGImageRef image = DshCaptureFullScreen();
  NSData *png = DshPngFromCGImage(image);
  if (image) CGImageRelease(image);

  if (!png || png.length == 0) {
    DshRespond(fd, 503, "Unavailable", "nocapture", 9, "text/plain");
  } else {
    DshRespond(fd, 200, "OK", png.bytes, (size_t)png.length, "image/png");
  }
  close(fd);
}

#pragma mark - 监听

@interface DshScreenshotService : NSObject
@property (nonatomic, assign) int listenFD;
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@implementation DshScreenshotService

+ (instancetype)shared {
  static DshScreenshotService *shared = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ shared = [[DshScreenshotService alloc] init]; });
  return shared;
}

- (void)startWithLog:(void (^)(NSString *))log {
  if (self.listenFD > 0) return;
  self.queue = dispatch_queue_create("dsh.screen.service", DISPATCH_QUEUE_SERIAL);

  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) { log([NSString stringWithFormat:@"socket failed errno=%d\n", errno]); return; }
  int yes = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons(kDshScreenPort);
  // 只绑回环，局域网里别的设备连不上。
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    log([NSString stringWithFormat:@"bind failed errno=%d\n", errno]);
    close(fd);
    return;
  }
  if (listen(fd, 8) < 0) {
    log([NSString stringWithFormat:@"listen failed errno=%d\n", errno]);
    close(fd);
    return;
  }
  self.listenFD = fd;
  log([NSString stringWithFormat:@"listening on 127.0.0.1:%d\n", kDshScreenPort]);

  dispatch_async(self.queue, ^{
    while (YES) {
      int client = accept(fd, NULL, NULL);
      if (client < 0) break;
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        DshHandleClient(client);
      });
    }
  });
}

@end

#pragma mark - 注入

__attribute__((constructor))
static void DshScreenshotServiceInit(void) {
  @autoreleasepool {
    // 构造函数一进来就落一行日志。这是判断「插件到底有没有被注入」的唯一
    // 可靠手段：端口不通可能是 bind 失败、也可能是根本没被加载，两者要分开。
    NSMutableString *step = [NSMutableString string];
    [step appendString:@"constructor entered\n"];
    NSString *logPath = @"/var/mobile/dsh-screen-plugin.log";
    void (^log)(NSString *) = ^(NSString *line) {
      NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:logPath];
      if (!handle) {
        [line writeToFile:logPath atomically:NO encoding:NSUTF8StringEncoding error:NULL];
      } else {
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
      }
    };
    log([step copy]);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
      [[DshScreenshotService shared] startWithLog:log];
    });
  }
}
