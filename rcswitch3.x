// 声音路由切换助手 5.6.10 正式版 —— 快捷指令开关（磁贴镜像）
// 仅注入 SpringBoard；动作与控制中心磁贴完全等效：
//   写状态文件（jbroot + 普通双路径）→ 发 Darwin 通知 com.rc.apphelper.toggle
// 路由切换由 5.2.1 定版 RCSpeakerApp.dylib 自行完成，本插件不操作音频会话。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <notify.h>

static NSArray *RCStatePaths(void) {
    static NSArray *paths = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *m = [NSMutableArray array];
        char resolved[4096];
        if (realpath("/var/jb", resolved))
            [m addObject:[[NSString alloc] initWithFormat:@"%s/var/mobile/.rc_speaker_on", resolved]];
        [m addObject:@"/var/mobile/.rc_speaker_on"];
        paths = [m copy];
    });
    return paths;
}

static BOOL SpeakerOn(void) {
    for (NSString *p in RCStatePaths()) {
        NSString *s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
        if ([s isEqualToString:@"1"]) return YES;
    }
    return NO;
}

static void SetSpeakerOn(BOOL on) {
    for (NSString *p in RCStatePaths())
        [on ? @"1" : @"0" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
    notify_post("com.rc.apphelper.toggle");
}

static void HandleRequest(const char *buf, int cfd) {
    BOOL on;
    if (strstr(buf, "GET /on")) on = YES;
    else if (strstr(buf, "GET /off")) on = NO;
    else if (strstr(buf, "GET /status")) {
        const char *st = SpeakerOn() ? "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nConnection: close\r\n\r\n1"
                                     : "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nConnection: close\r\n\r\n0";
        write(cfd, st, strlen(st));
        close(cfd);
        return;
    } else return;
    SetSpeakerOn(on);
    const char *resp = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok";
    write(cfd, resp, strlen(resp));
    close(cfd);
}

static void ServePort(void) {
    int sfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sfd < 0) return;
    int opt = 1;
    setsockopt(sfd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(18081);
    if (bind(sfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { close(sfd); return; }
    if (listen(sfd, 4) < 0) { close(sfd); return; }
    char buf[512];
    for (;;) {
        int cfd = accept(sfd, NULL, NULL);
        if (cfd < 0) continue;
        memset(buf, 0, sizeof(buf));
        read(cfd, buf, sizeof(buf) - 1);
        HandleRequest(buf, cfd);
    }
}

%ctor {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        ServePort();
    });
}
