// 5.6.7 快捷指令开关 = 磁贴的远程手指
// 只做磁贴同样的动作：写同一个状态文件 + 发同一个 toggle 通知
// 一切实际路由动作由原版 App 完成（5.2.1 磁贴控制版验证可用）
// 不注入任何 App 进程，零污染
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <time.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <string.h>
#include <notify.h>

static char g_bidtag[96] = "?";
#define RCLOG_MAX 20480
static void RCLogTrim(void) {
    struct stat st;
    if (stat("/var/mobile/rc_debug.log", &st) != 0 || st.st_size <= RCLOG_MAX) return;
    FILE *rf = fopen("/var/mobile/rc_debug.log", "r");
    if (!rf) return;
    long keep = 12288;
    fseek(rf, -keep, SEEK_END);
    char *tmp = (char *)malloc(keep + 1);
    size_t n = fread(tmp, 1, keep, rf);
    fclose(rf);
    FILE *wf = fopen("/var/mobile/rc_debug.log", "w");
    if (wf) { fwrite(tmp, 1, n, wf); fclose(wf); }
    free(tmp);
}
static void RCLog(const char *msg) {
    RCLogTrim();
    int fd = open("/var/mobile/rc_debug.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    char b[320];
    time_t t = time(NULL); struct tm tmv; localtime_r(&t, &tmv);
    int n = snprintf(b, sizeof(b), "[RCX %02d:%02d:%02d %s] %s\n", tmv.tm_hour, tmv.tm_min, tmv.tm_sec, g_bidtag, msg);
    write(fd, b, n);
    close(fd);
}
static void RCLogFmt(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    RCLog(s.UTF8String ?: "?");
}

// 与磁贴源码 RCSpeakerToggle.x 逐字节同款的双路径（jbroot + 普通）
static NSArray *RCStatePaths(void) {
    static NSArray *paths = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *m = [NSMutableArray array];
        char resolved[4096];
        if (realpath("/var/jb", resolved))
            [m addObject:[[NSString alloc] initWithFormat:@"%s/var/mobile/.rc_speaker_on", resolved]];
        [m addObject:[[NSString alloc] initWithFormat:@"/var/mob%@/.rc_speaker_on", @"ile"]];
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
    for (NSString *p in RCStatePaths()) {
        [on ? @"1" : @"0" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    notify_post("com.rc.apphelper.toggle");
}
// App 读两个路径任一=1 即 ON（RCStatePaths），jbroot 残留=1 会死锁——启动时清一次
static void CleanJBResidual(void) {
    char resolved[4096];
    if (!realpath("/var/jb", resolved)) return;
    NSString *jb = [NSString stringWithFormat:@"%s/var/mobile/.rc_speaker_on", resolved];
    if ([[NSFileManager defaultManager] fileExistsAtPath:jb]) {
        unlink(jb.UTF8String);
        RCLog("cleaned jbroot residual state");
    }
}
static void RCDiagSB(NSString *line) {
    [line writeToFile:@"/var/mobile/.rc_sb_diag" atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void HandleRequest(const char *buf) {
    BOOL on;
    if (strstr(buf, "GET /on")) on = YES;
    else if (strstr(buf, "GET /off")) on = NO;
    else return;
    BOOL before = SpeakerOn();
    SetSpeakerOn(on);                          // = 磁贴 SetSpeakerOn
    notify_post("com.rc.apphelper.toggle");    // = 磁贴 CF post（同一 Darwin 中心）
    RCLogFmt(@"sb req=%@ file %d->%d toggle posted", on ? @"on" : @"off", before ? 1 : 0, on ? 1 : 0);
    RCDiagSB([NSString stringWithFormat:@"%@ req=%@ file %d->%d posted\n", [NSDate date], on ? @"on" : @"off", before ? 1 : 0, on ? 1 : 0]);
}
static void ServePort(int port) {
    int sfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sfd < 0) return;
    int opt = 1;
    setsockopt(sfd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(port);
    if (bind(sfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { close(sfd); return; }
    if (listen(sfd, 4) < 0) { close(sfd); return; }
    RCLog("switch server ready on 18081");
    char buf[1024];
    for (;;) {
        int cfd = accept(sfd, NULL, NULL);
        if (cfd < 0) continue;
        memset(buf, 0, sizeof(buf));
        read(cfd, buf, sizeof(buf) - 1);
        if (strstr(buf, "GET /status")) {
            const char *st = SpeakerOn() ? "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nConnection: close\r\n\r\n1" : "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nConnection: close\r\n\r\n0";
            write(cfd, st, strlen(st));
            close(cfd);
            continue;
        }
        if (strstr(buf, "GET /diag")) {
            NSString *s = [NSString stringWithContentsOfFile:@"/var/mobile/.rc_sb_diag" encoding:NSUTF8StringEncoding error:nil];
            NSString *body = s ?: @"no diag";
            NSData *dt = [body dataUsingEncoding:NSUTF8StringEncoding];
            char hdr[160];
            int hl = snprintf(hdr, sizeof(hdr), "HTTP/1.1 200 OK\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n", (size_t)dt.length);
            write(cfd, hdr, hl);
            write(cfd, dt.bytes, dt.length);
            close(cfd);
            continue;
        }
        HandleRequest(buf);
        const char *resp = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok";
        write(cfd, resp, strlen(resp));
        close(cfd);
    }
}

%ctor {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    snprintf(g_bidtag, sizeof(g_bidtag), "%.80s", bid.UTF8String ?: "unknown");
    CleanJBResidual();
    RCLog("switch loaded in SB (tile-mirror mode, 18081)");
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        ServePort(18081);
    });
}
