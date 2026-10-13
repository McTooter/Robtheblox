//
//  RobloxExec — single-file iOS Roblox executor
//

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <objc/runtime.h>
#include <substrate.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <string>
#include <vector>
#include <mutex>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <cstdlib>

// =====================================================================
//  PART 1 — Luau ABI + resolver
// =====================================================================

typedef struct lua_State lua_State;
#define LUA_OK 0
#define LUA_YIELD 1
#define LUA_TNIL 0
#define LUA_TBOOLEAN 1

typedef int (*lua_CFunction)(lua_State*);

typedef struct {
    int   (*lua_gettop)(lua_State*);
    void  (*lua_settop)(lua_State*, int);
    void  (*lua_pushvalue)(lua_State*, int);
    void  (*lua_pushnumber)(lua_State*, double);
    void  (*lua_pushstring)(lua_State*, const char*);
    void  (*lua_pushboolean)(lua_State*, int);
    void  (*lua_pushcclosurek)(lua_State*, lua_CFunction, const char*, int, void*);
    int   (*lua_type)(lua_State*, int);
    const char* (*lua_tolstring)(lua_State*, int, size_t*);
    int   (*lua_toboolean)(lua_State*, int);
    void  (*lua_getglobal)(lua_State*, const char*);
    void  (*lua_setglobal)(lua_State*, const char*);
    int   (*lua_pcall)(lua_State*, int, int, int);
    int   (*lua_resume)(lua_State*, lua_State*, int);
    lua_State* (*lua_newthread)(lua_State*);
    int   (*lua_status)(lua_State*);
    int   (*luau_load)(lua_State*, const char*, const char*, size_t, int);
    lua_State* (*lua_newstate)(void*, void*);
} LuauAPI;

static LuauAPI luau;
static uintptr_t g_text, g_textEnd;

static void text_init(void) {
    if (g_text) return;
    const struct mach_header_64* h =
        (const struct mach_header_64*)_dyld_get_image_header(0);
    unsigned long sz = 0;
    uint8_t* p = getsectiondata(h, "__TEXT", "__text", &sz);
    if (p) { g_text = (uintptr_t)p; g_textEnd = g_text + sz; }
}

static uintptr_t exec_scan(const char* pattern) {
    text_init();
    if (!g_text) return 0;
    uint8_t bytes[96] = {0}, mask[96] = {0};
    int n = 0; const char* s = pattern;
    while (*s && n < 96) {
        while (*s == ' ') s++;
        if (!*s) break;
        if (s[0] == '?' && s[1] == '?') { bytes[n] = 0; mask[n] = 0; s += 2; }
        else { bytes[n] = (uint8_t)strtoul(s, NULL, 16); mask[n] = 0xFF; s += 2; }
        n++;
    }
    if (!n) return 0;
    for (uintptr_t a = g_text; a + n < g_textEnd; a++) {
        int ok = 1;
        for (int i = 0; i < n; i++)
            if (mask[i] && *(uint8_t*)(a + i) != bytes[i]) { ok = 0; break; }
        if (ok) return a;
    }
    return 0;
}

static void* R(const char* name, const char* sig) {
    void* p = dlsym(RTLD_DEFAULT, name);
    if (p) return p;
    return (void*)exec_scan(sig);
}

static int luau_resolve(void) {
    luau.lua_gettop        = R("lua_gettop",        "FD 7B BF A9 FC 6F 02 A9 FA 67 03 A9 F8 5F 04 A9");
    luau.lua_settop        = R("lua_settop",        "FD 7B BF A9 FC 6F 02 A9 FA 67 03 A9 F8 5F 04 A9");
    luau.lua_pushvalue     = R("lua_pushvalue",     "FD 7B BF A9 FC 6F 02 A9 FA 67 03 A9 F8 5F 04 A9");
    luau.lua_pushnumber    = R("lua_pushnumber",    "FD 7B BF A9 F4 4F 01 A9 FD 03 00 91");
    luau.lua_pushstring    = R("lua_pushstring",    "FD 7B BF A9 FC 6F 02 A9 FA 67 03 A9");
    luau.lua_pushboolean   = R("lua_pushboolean",   "FD 7B BF A9 F4 4F 01 A9 FD 03 00 91");
    luau.lua_pushcclosurek = R("lua_pushcclosurek", "FD 7B BF A9 FC 6F 02 A9 FA 67 03 A9 F8 5F 04 A9 F6 57 05 A9");
    luau.lua_type          = R("lua_type",          "FD 7B BF A9 FC 6F 02 A9 FA 67 03 A9 F8 5F 04 A9");
    luau.lua_tolstring     = R("lua_tolstring",     "FD 7B BF A9 FC 6F 02 A9 FA 67 03 A9 F8 5F 04 A9");
    luau.lua_toboolean     = R("lua_toboolean",     "FD 7B BF A9 F4 4F 01 A9 FD 03 00 91");
    luau.lua_getglobal     = R("lua_getglobal",     "FD 7B BF A9 F4 4F 01 A9 FD 03 00 91");
    luau.lua_setglobal     = R("lua_setglobal",     "FD 7B BF A9 F4 4F 01 A9 FD 03 00 91");
    luau.lua_pcall         = R("lua_pcall",         "FD 7B BF A9 FC 6F 02 A9 FA 67 03 A9 F8 5F 04 A9");
    luau.lua_resume        = R("lua_resume",        "FD 7B BF A9 FC 6F 02 A9 FA 67 03 A9 F8 5F 04 A9");
    luau.lua_newthread     = R("lua_newthread",     "FD 7B BF A9 F4 4F 01 A9 FD 03 00 91");
    luau.lua_status        = R("lua_status",        "F0 03 00 AA F4 4F 01 A9 FD 7B BF A9 FD 03 00 91");
    luau.luau_load         = R("luau_load",         "FD 7B BF A9 FC 6F 02 A9 FA 67 03 A9 F8 5F 04 A9 F6 57 05 A9");
    luau.lua_newstate      = R("lua_newstate",      "FD 7B BF A9 FC 6F 02 A9 FA 67 03 A9 F8 5F 04 A9");
    return luau.lua_pcall && luau.lua_resume && luau.luau_load
        && luau.lua_getglobal && luau.lua_setglobal && luau.lua_pushcclosurek
        && luau.lua_newthread && luau.lua_tolstring;
}

// =====================================================================
//  PART 2 — executor core
// =====================================================================

static lua_State* g_L = nullptr;
static std::mutex g_mtx;
static std::vector<std::string> g_queue;
static volatile int g_ready = 0;

typedef void (*ExecLogFn)(const char*);
static ExecLogFn g_log = nullptr;

static void exec_logf(const char* fmt, ...) {
    char buf[4096];
    va_list ap; va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (g_log) g_log(buf); else printf("[exec] %s\n", buf);
}

static int l_print(lua_State* L) {
    int n = luau.lua_gettop(L);
    std::string out;
    for (int i = 1; i <= n; i++) {
        int t = luau.lua_type(L, i);
        if (t == LUA_TBOOLEAN) out += luau.lua_toboolean(L, i) ? "true" : "false";
        else if (t == LUA_TNIL) out += "nil";
        else {
            size_t len = 0;
            const char* s = luau.lua_tolstring(L, i, &len);
            if (s) out.append(s, len); else out += "?";
        }
        if (i != n) out += " ";
    }
    exec_logf("%s", out.c_str());
    return 0;
}

static int l_getgenv(lua_State* L) { luau.lua_getglobal(L, "_G"); return 1; }

static void install_globals(void) {
    luau.lua_getglobal(g_L, "print");
    luau.lua_setglobal(g_L, "oldprint");
    luau.lua_pushcclosurek(g_L, l_print, "print", 0, nullptr);
    luau.lua_setglobal(g_L, "print");
    luau.lua_pushcclosurek(g_L, l_getgenv, "getgenv", 0, nullptr);
    luau.lua_setglobal(g_L, "getgenv");
}

static void resume_step(lua_State* T);

static void schedule_resume(lua_State* T) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{ resume_step(T); });
}

static void resume_step(lua_State* T) {
    std::lock_guard<std::mutex> lk(g_mtx);
    int st = luau.lua_resume(T, nullptr, 0);
    if (st == LUA_YIELD) { schedule_resume(T); return; }
    if (st != LUA_OK) {
        size_t len = 0;
        const char* e = luau.lua_tolstring(T, -1, &len);
        exec_logf("[error] %s", e ? e : "unknown");
    }
}

static void executor_execute(const char* code) {
    if (!code || !*code) return;
    if (!g_L || !g_ready) {
        std::lock_guard<std::mutex> lk(g_mtx);
        g_queue.push_back(code);
        return;
    }
    std::lock_guard<std::mutex> lk(g_mtx);
    lua_State* T = luau.lua_newthread(g_L);
    if (luau.luau_load(T, "=executor", code, strlen(code), 0) != LUA_OK) {
        size_t len = 0;
        const char* e = luau.lua_tolstring(T, -1, &len);
        exec_logf("[syntax] %s", e ? e : "unknown");
        return;
    }
    resume_step(T);
}

// =====================================================================
//  PART 3 — VM capture
// =====================================================================

static void capture(lua_State* L) {
    if (g_L || !L) return;
    g_L = L;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_ready) return;
        install_globals();
        g_ready = 1;
        exec_logf("[exec] VM captured, ready");
        std::vector<std::string> q;
        { std::lock_guard<std::mutex> lk(g_mtx); q.swap(g_queue); }
        for (auto& s : q) executor_execute(s.c_str());
    });
}

typedef lua_State* (*newstate_t)(void*, void*);
static newstate_t orig_newstate;
static lua_State* hook_newstate(void* a, void* b) {
    lua_State* L = orig_newstate(a, b); capture(L); return L;
}

typedef int (*resume_t)(lua_State*, lua_State*, int);
static resume_t orig_resume;
static int hook_resume(lua_State* L, lua_State* from, int n) {
    if (!g_L) capture(L);
    return orig_resume(L, from, n);
}

typedef int (*pcall_t)(lua_State*, int, int, int);
static pcall_t orig_pcall;
static int hook_pcall(lua_State* L, int n, int r, int e) {
    if (!g_L) capture(L);
    return orig_pcall(L, n, r, e);
}

static void executor_boot(void) {
    if (!luau_resolve()) { NSLog(@"[exec] FATAL: resolve failed"); return; }
    if (luau.lua_newstate)
        MSHookFunction((void*)luau.lua_newstate, (void*)hook_newstate, (void**)&orig_newstate);
    if (luau.lua_resume)
        MSHookFunction((void*)luau.lua_resume, (void*)hook_resume, (void**)&orig_resume);
    if (luau.lua_pcall)
        MSHookFunction((void*)luau.lua_pcall, (void*)hook_pcall, (void**)&orig_pcall);
}

// =====================================================================
//  PART 4 — FPS unlocker
// =====================================================================

static int g_fpsTarget = 0;

@interface CADisplayLink (REFPS)
+ (void)re_install;
@end

@implementation CADisplayLink (REFPS)
+ (void)re_install {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        method_exchangeImplementations(
            class_getInstanceMethod(self, @selector(setPreferredFramesPerSecond:)),
            class_getInstanceMethod(self, @selector(re_setFPS:)));
        if (@available(iOS 15.0, *)) {
            method_exchangeImplementations(
                class_getInstanceMethod(self, @selector(setPreferredFrameRateRange:)),
                class_getInstanceMethod(self, @selector(re_setRange:)));
        }
    });
}
- (void)re_setFPS:(NSInteger)v {
    if (g_fpsTarget > 0) v = g_fpsTarget;
    [self re_setFPS:v];
}
- (void)re_setRange:(CAFrameRateRange)r {
    if (g_fpsTarget > 0) r = CAFrameRateRangeMake(g_fpsTarget, g_fpsTarget, g_fpsTarget);
    [self re_setRange:r];
}
@end

// =====================================================================
//  PART 5 — store
// =====================================================================

#define IY_CODE @"loadstring(game:HttpGet('https://raw.githubusercontent.com/EdgeIY/infiniteyield/master/source'))()"

@interface REStore : NSObject
+ (instancetype)shared;
- (id)get:(NSString*)k def:(id)d;
- (void)set:(NSString*)k v:(id)v;
- (NSArray*)starred;
- (BOOL)isStarred:(NSString*)name;
- (void)toggleStar:(NSDictionary*)item;
- (NSArray*)saved;
- (void)saveName:(NSString*)n code:(NSString*)c;
- (void)deleteSaved:(NSString*)n;
- (NSArray*)history;
- (void)addHistory:(NSString*)code;
- (void)clearHistory;
- (void)clearSaved;
- (void)resetAll;
@end

@implementation REStore
+ (instancetype)shared {
    static REStore* s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [REStore new]; [s seed]; });
    return s;
}
- (NSUserDefaults*)d { return NSUserDefaults.standardUserDefaults; }
- (id)get:(NSString*)k def:(id)def { id v = [self.d objectForKey:k]; return v ?: def; }
- (void)set:(NSString*)k v:(id)v { [self.d setObject:v forKey:k]; }

- (NSArray*)arr:(NSString*)k {
    NSData* data = [self.d dataForKey:k];
    if (!data) return @[];
    id o = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [o isKindOfClass:NSArray.class] ? o : @[];
}
- (void)setArr:(NSString*)k a:(NSArray*)a {
    NSData* data = [NSJSONSerialization dataWithJSONObject:a options:0 error:nil];
    [self.d setObject:data forKey:k];
}

- (void)seed {
    if ([[self get:@"re.seeded" def:@NO] boolValue]) return;
    [self set:@"re.seeded" v:@YES];
    [self setArr:@"re.starred" a:@[@{@"name": @"Infinite Yield", @"code": IY_CODE}]];
}

- (NSArray*)starred { return [self arr:@"re.starred"]; }
- (BOOL)isStarred:(NSString*)name {
    for (NSDictionary* d in [self starred])
        if ([d[@"name"] isEqualToString:name]) return YES;
    return NO;
}
- (void)toggleStar:(NSDictionary*)item {
    NSMutableArray* a = [[self starred] mutableCopy];
    NSInteger idx = -1;
    for (NSInteger i = 0; i < a.count; i++)
        if ([a[i][@"name"] isEqualToString:item[@"name"]]) { idx = i; break; }
    if (idx >= 0) [a removeObjectAtIndex:idx];
    else [a addObject:@{@"name": item[@"name"], @"code": item[@"code"]}];
    [self setArr:@"re.starred" a:a];
}

- (NSArray*)saved { return [self arr:@"re.saved"]; }
- (void)saveName:(NSString*)n code:(NSString*)c {
    NSMutableArray* a = [[self saved] mutableCopy];
    for (NSInteger i = 0; i < a.count; i++)
        if ([a[i][@"name"] isEqualToString:n]) { [a removeObjectAtIndex:i]; break; }
    [a insertObject:@{@"name": n, @"code": c} atIndex:0];
    [self setArr:@"re.saved" a:a];
}
- (void)deleteSaved:(NSString*)n {
    NSMutableArray* a = [[self saved] mutableCopy];
    for (NSInteger i = 0; i < a.count; i++)
        if ([a[i][@"name"] isEqualToString:n]) { [a removeObjectAtIndex:i]; break; }
    [self setArr:@"re.saved" a:a];
}

- (NSArray*)history { return [self arr:@"re.history"]; }
- (void)addHistory:(NSString*)code {
    if (!code.length) return;
    NSMutableArray* a = [[self history] mutableCopy];
    for (NSInteger i = 0; i < a.count; i++)
        if ([a[i][@"code"] isEqualToString:code]) { [a removeObjectAtIndex:i]; break; }
    [a insertObject:@{@"code": code,
                      @"date": @([[NSDate date] timeIntervalSince1970])} atIndex:0];
    if (a.count > 60) a = [[a subarrayWithRange:NSMakeRange(0, 60)] mutableCopy];
    [self setArr:@"re.history" a:a];
}
- (void)clearHistory { [self setArr:@"re.history" a:@[]]; }
- (void)clearSaved   { [self setArr:@"re.saved" a:@[]]; }
- (void)resetAll {
    [self clearHistory]; [self clearSaved]; [self setArr:@"re.starred" a:@[]];
    [self set:@"re.seeded" v:@NO];
    for (NSString* k in @[@"re.fps", @"re.haptics", @"re.blur", @"re.accent",
                          @"re.fontsize", @"re.autorun", @"re.lastscript"])
        [self.d removeObjectForKey:k];
    [self seed];
}
@end

// =====================================================================
//  PART 6 — theme
// =====================================================================

static NSArray<NSArray<UIColor*>*>* accents(void) {
    static NSArray* a; static dispatch_once_t o;
    dispatch_once(&o, ^{
        a = @[
          @[[UIColor colorWithRed:0.42 green:0.35 blue:1.00 alpha:1], [UIColor colorWithRed:0.18 green:0.76 blue:1.00 alpha:1]],
          @[[UIColor colorWithRed:1.00 green:0.35 blue:0.55 alpha:1], [UIColor colorWithRed:1.00 green:0.62 blue:0.30 alpha:1]],
          @[[UIColor colorWithRed:0.20 green:0.85 blue:0.55 alpha:1], [UIColor colorWithRed:0.20 green:0.70 blue:1.00 alpha:1]],
          @[[UIColor colorWithRed:1.00 green:0.75 blue:0.20 alpha:1], [UIColor colorWithRed:1.00 green:0.45 blue:0.20 alpha:1]],
          @[[UIColor colorWithRed:0.75 green:0.75 blue:0.80 alpha:1], [UIColor colorWithRed:0.45 green:0.45 blue:0.50 alpha:1]],
        ];
    });
    return a;
}
static NSInteger accIdx(void) {
    return [[[REStore shared] get:@"re.accent" def:@0] integerValue] % (NSInteger)accents().count;
}
static UIColor* accA(void) { return accents()[accIdx()][0]; }
static UIColor* accB(void) { return accents()[accIdx()][1]; }

static UIFont* mono(CGFloat s, UIFontWeight w) {
    if (@available(iOS 13.0, *)) return [UIFont monospacedSystemFontOfSize:s weight:w];
    return [UIFont fontWithName:@"Menlo-Bold" size:s] ?: [UIFont boldSystemFontOfSize:s];
}
static CGFloat fontSize(void) {
    return [[[REStore shared] get:@"re.fontsize" def:@12.5] doubleValue];
}
static void haptic(UIImpactFeedbackStyle s) {
    if (![[[REStore shared] get:@"re.haptics" def:@YES] boolValue]) return;
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:s] impactOccurred];
}
static BOOL blurOn(void) {
    return [[[REStore shared] get:@"re.blur" def:@YES] boolValue];
}

static NSArray<NSDictionary*>* commonScripts(void) {
    return @[
      @{@"name": @"Infinite Yield", @"desc": @"Admin commands", @"code": IY_CODE},
      @{@"name": @"Dark Dex",       @"desc": @"Game explorer",  @"code": @"loadstring(game:HttpGet('https://raw.githubusercontent.com/WeAreDevs-Official/DarkDex/main/DarkDex.lua'))()"},
      @{@"name": @"SimpleSpy",      @"desc": @"Remote spy",     @"code": @"loadstring(game:HttpGet('https://raw.githubusercontent.com/Exunys/SimpleSpy/main/SimpleSpy.lua'))()"},
      @{@"name": @"Hydroxide",      @"desc": @"Remote spy",     @"code": @"loadstring(game:HttpGet('https://raw.githubusercontent.com/Upbolt/Hydroxide/master/hydroxide/init.lua'))()"},
      @{@"name": @"Nameless Admin", @"desc": @"Admin commands", @"code": @"loadstring(game:HttpGet('https://raw.githubusercontent.com/NotPlaYer/Nameless-Admin/main/Main.lua'))()"},
      @{@"name": @"Rejoin Server",  @"desc": @"Teleport util",  @"code": @"game:GetService('TeleportService'):Teleport(game.PlaceId, game.Players.LocalPlayer)"},
      @{@"name": @"Fullbright",     @"desc": @"Lighting tweak", @"code": @"game.Lighting.Brightness = 3 game.Lighting.ClockTime = 14 game.Lighting.FogEnd = 1e6"},
      @{@"name": @"Anti-AFK",       @"desc": @"Stay online",    @"code": @"local vu = game:GetService('VirtualUser') game:GetService('Players').LocalPlayer.Idled:Connect(function() vu:Button2Down(Vector2.new(0,0), workspace.CurrentCamera.CFrame) task.wait(1) vu:Button2Up(Vector2.new(0,0), workspace.CurrentCamera.CFrame) end)"},
    ];
}

// =====================================================================
//  PART 7 — cells
// =====================================================================

@interface RECell : UITableViewCell
@property (nonatomic, strong) UILabel* titleLbl;
@property (nonatomic, strong) UILabel* subLbl;
@property (nonatomic, strong) UIButton* starBtn;
@property (nonatomic, copy) void (^onStar)(void);
@end

@implementation RECell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString*)rid {
    if ((self = [super initWithStyle:style reuseIdentifier:rid])) {
        self.backgroundColor = [UIColor colorWithWhite:1 alpha:0.045];
        UIView* sel = [UIView new];
        sel.backgroundColor = [UIColor colorWithWhite:1 alpha:0.09];
        self.selectedBackgroundView = sel;

        _titleLbl = [UILabel new];
        _titleLbl.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLbl.textColor = UIColor.whiteColor;
        _titleLbl.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        [self.contentView addSubview:_titleLbl];

        _subLbl = [UILabel new];
        _subLbl.translatesAutoresizingMaskIntoConstraints = NO;
        _subLbl.textColor = [UIColor colorWithWhite:1 alpha:0.45];
        _subLbl.font = mono(10.5, UIFontWeightRegular);
        [self.contentView addSubview:_subLbl];

        _starBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        _starBtn.translatesAutoresizingMaskIntoConstraints = NO;
        _starBtn.titleLabel.font = [UIFont systemFontOfSize:17];
        [_starBtn addTarget:self action:@selector(starTap) forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:_starBtn];

        [NSLayoutConstraint activateConstraints:@[
            [_titleLbl.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [_titleLbl.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],
            [_titleLbl.trailingAnchor constraintLessThanOrEqualToAnchor:_starBtn.leadingAnchor constant:-10],

            [_subLbl.leadingAnchor constraintEqualToAnchor:_titleLbl.leadingAnchor],
            [_subLbl.topAnchor constraintEqualToAnchor:_titleLbl.bottomAnchor constant:2],
            [_subLbl.trailingAnchor constraintLessThanOrEqualToAnchor:_starBtn.leadingAnchor constant:-10],

            [_starBtn.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-14],
            [_starBtn.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_starBtn.widthAnchor constraintEqualToConstant:34],
            [_starBtn.heightAnchor constraintEqualToConstant:34],
        ]];
    }
    return self;
}
- (void)starTap { haptic(UIImpactFeedbackStyleLight); if (self.onStar) self.onStar(); }
@end

@interface RESwitchCell : UITableViewCell
@property (nonatomic, strong) UISwitch* sw;
@end
@implementation RESwitchCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString*)rid {
    if ((self = [super initWithStyle:style reuseIdentifier:rid])) {
        self.backgroundColor = [UIColor colorWithWhite:1 alpha:0.045];
        self.textLabel.textColor = UIColor.whiteColor;
        self.textLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        _sw = [UISwitch new];
        _sw.onTintColor = accA();
        self.accessoryView = _sw;
        self.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return self;
}
@end

@interface REValueCell : UITableViewCell
@end
@implementation REValueCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString*)rid {
    if ((self = [super initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:rid])) {
        self.backgroundColor = [UIColor colorWithWhite:1 alpha:0.045];
        self.textLabel.textColor = UIColor.whiteColor;
        self.textLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        self.detailTextLabel.textColor = [UIColor colorWithWhite:1 alpha:0.5];
        self.detailTextLabel.font = mono(12, UIFontWeightRegular);
        self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return self;
}
@end

// =====================================================================
//  PART 8 — tab bar
// =====================================================================

@interface RETabBar : UIView
@property (nonatomic, copy) void (^onSelect)(NSInteger);
- (instancetype)initWithTitles:(NSArray<NSString*>*)titles;
- (void)select:(NSInteger)idx animated:(BOOL)anim;
@end

@implementation RETabBar {
    NSMutableArray<UIButton*>* _btns;
    UIView* _pill;
    NSInteger _cur;
}
- (instancetype)initWithTitles:(NSArray<NSString*>*)titles {
    if ((self = [super init])) {
        self.backgroundColor = [UIColor colorWithWhite:1 alpha:0.05];
        self.layer.cornerRadius = 13;
        if (@available(iOS 13.0, *)) self.layer.cornerCurve = kCACornerCurveContinuous;

        _pill = [UIView new];
        _pill.backgroundColor = [UIColor colorWithWhite:1 alpha:0.13];
        _pill.layer.cornerRadius = 10;
        if (@available(iOS 13.0, *)) _pill.layer.cornerCurve = kCACornerCurveContinuous;
        [self addSubview:_pill];

        _btns = [NSMutableArray array];
        UIStackView* stack = [[UIStackView alloc] initWithArrangedSubviews:@[]];
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        stack.distribution = UIStackViewDistributionFillEqually;
        stack.axis = UILayoutConstraintAxisHorizontal;
        [self addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.topAnchor constraintEqualToAnchor:self.topAnchor],
            [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        ]];

        for (NSInteger i = 0; i < titles.count; i++) {
            UIButton* b = [UIButton buttonWithType:UIButtonTypeCustom];
            [b setTitle:titles[i] forState:UIControlStateNormal];
            b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
            [b setTitleColor:[UIColor colorWithWhite:1 alpha:0.55] forState:UIControlStateNormal];
            [b setTitleColor:UIColor.whiteColor forState:UIControlStateSelected];
            b.tag = i;
            [b addTarget:self action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
            [stack addArrangedSubview:b];
            [_btns addObject:b];
        }
        _cur = 0;
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    [self layoutPillAnimated:NO];
}
- (void)layoutPillAnimated:(BOOL)anim {
    if (!_btns.count) return;
    UIButton* b = _btns[_cur];
    CGRect f = CGRectInset(b.frame, 3, 3);
    if (anim) {
        UISpringTimingParameters* sp = [[UISpringTimingParameters alloc] initWithDampingRatio:0.75];
        UIViewPropertyAnimator* a = [[UIViewPropertyAnimator alloc] initWithDuration:0.4 timingParameters:sp];
        [a addAnimations:^{ self->_pill.frame = f; }];
        [a startAnimation];
    } else {
        _pill.frame = f;
    }
}
- (void)tap:(UIButton*)b {
    if (b.tag == _cur) return;
    haptic(UIImpactFeedbackStyleLight);
    [self select:b.tag animated:YES];
    if (self.onSelect) self.onSelect(b.tag);
}
- (void)select:(NSInteger)idx animated:(BOOL)anim {
    _cur = idx;
    for (NSInteger i = 0; i < _btns.count; i++) _btns[i].selected = (i == idx);
    [self layoutPillAnimated:anim];
}
@end

// =====================================================================
//  PART 9 — console tab
// =====================================================================

@interface REConsoleVC : UIViewController <UITextViewDelegate>
@property (nonatomic, copy) void (^onExecute)(NSString*);
@property (nonatomic, strong) UITextView* editor;
@property (nonatomic, strong) UITextView* output;
- (void)setCode:(NSString*)code;
- (void)appendLog:(NSString*)s;
@end

@implementation REConsoleVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    _editor = [UITextView new];
    _editor.translatesAutoresizingMaskIntoConstraints = NO;
    _editor.backgroundColor = [UIColor colorWithWhite:0 alpha:0.30];
    _editor.textColor = UIColor.whiteColor;
    _editor.font = mono(fontSize(), UIFontWeightRegular);
    _editor.layer.cornerRadius = 12;
    if (@available(iOS 13.0, *)) _editor.layer.cornerCurve = kCACornerCurveContinuous;
    _editor.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    _editor.autocorrectionType = UITextAutocorrectionTypeNo;
    _editor.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _editor.spellCheckingType = UITextSpellCheckingTypeNo;
    _editor.keyboardAppearance = UIKeyboardAppearanceDark;
    _editor.text = @"print(\"hello\")";
    [self.view addSubview:_editor];

    UIButton* clear = [self toolBtn:@"Clear"];
    [clear addTarget:self action:@selector(clear) forControlEvents:UIControlEventTouchUpInside];

    UIButton* save = [self toolBtn:@"Save"];
    [save addTarget:self action:@selector(save) forControlEvents:UIControlEventTouchUpInside];

    UIButton* run = [UIButton buttonWithType:UIButtonTypeCustom];
    run.translatesAutoresizingMaskIntoConstraints = NO;
    [run setTitle:@"EXECUTE" forState:UIControlStateNormal];
    run.titleLabel.font = mono(13, UIFontWeightHeavy);
    [run setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    run.layer.cornerRadius = 12;
    if (@available(iOS 13.0, *)) run.layer.cornerCurve = kCACornerCurveContinuous;
    run.layer.shadowColor = accA().CGColor;
    run.layer.shadowOpacity = 0.45;
    run.layer.shadowRadius = 10;
    run.layer.shadowOffset = CGSizeZero;
    run.clipsToBounds = NO;
    [run addTarget:self action:@selector(runDown) forControlEvents:UIControlEventTouchDown];
    [run addTarget:self action:@selector(runUp) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside];
    [run addTarget:self action:@selector(run) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:run];

    CAGradientLayer* g = [CAGradientLayer layer];
    g.startPoint = CGPointMake(0, 0);
    g.endPoint = CGPointMake(1, 1);
    g.colors = @[(id)accA().CGColor, (id)accB().CGColor];
    g.cornerRadius = 12;
    [run.layer insertSublayer:g atIndex:0];
    dispatch_async(dispatch_get_main_queue(), ^{ g.frame = run.bounds; });

    _output = [UITextView new];
    _output.translatesAutoresizingMaskIntoConstraints = NO;
    _output.backgroundColor = [UIColor colorWithWhite:0 alpha:0.22];
    _output.textColor = [UIColor colorWithWhite:0.85 alpha:1];
    _output.font = mono(fontSize() - 1, UIFontWeightRegular);
    _output.layer.cornerRadius = 12;
    if (@available(iOS 13.0, *)) _output.layer.cornerCurve = kCACornerCurveContinuous;
    _output.textContainerInset = UIEdgeInsetsMake(8, 10, 8, 10);
    _output.editable = NO;
    [self.view addSubview:_output];

    [NSLayoutConstraint activateConstraints:@[
        [_editor.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_editor.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_editor.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_editor.heightAnchor constraintEqualToAnchor:self.view.heightAnchor multiplier:0.38],

        [clear.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [clear.topAnchor constraintEqualToAnchor:_editor.bottomAnchor constant:10],
        [clear.widthAnchor constraintEqualToConstant:64],
        [clear.heightAnchor constraintEqualToConstant:40],

        [save.leadingAnchor constraintEqualToAnchor:clear.trailingAnchor constant:8],
        [save.topAnchor constraintEqualToAnchor:clear.topAnchor],
        [save.widthAnchor constraintEqualToConstant:64],
        [save.heightAnchor constraintEqualToConstant:40],

        [run.leadingAnchor constraintEqualToAnchor:save.trailingAnchor constant:8],
        [run.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [run.topAnchor constraintEqualToAnchor:clear.topAnchor],
        [run.heightAnchor constraintEqualToConstant:40],

        [_output.topAnchor constraintEqualToAnchor:clear.bottomAnchor constant:10],
        [_output.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_output.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_output.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (UIButton*)toolBtn:(NSString*)t {
    UIButton* b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setTitle:t forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    b.tintColor = UIColor.whiteColor;
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    b.layer.cornerRadius = 12;
    return b;
}

- (void)setCode:(NSString*)code {
    _editor.text = code;
    [_editor setContentOffset:CGPointZero animated:NO];
}

- (void)clear { [_output setText:@""]; haptic(UIImpactFeedbackStyleLight); }

- (void)save {
    UIAlertController* a = [UIAlertController alertControllerWithTitle:@"Save Script"
        message:nil preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField* tf) { tf.placeholder = @"name"; }];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction* x) {
        NSString* n = a.textFields.firstObject.text;
        if (!n.length) n = @"untitled";
        [[REStore shared] saveName:n code:self->_editor.text];
        haptic(UIImpactFeedbackStyleMedium);
        [[NSNotificationCenter defaultCenter] postNotificationName:@"re.saved" object:nil];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)runDown {
    UIViewPropertyAnimator* a = [[UIViewPropertyAnimator alloc] initWithDuration:0.15 dampingRatio:0.5];
    [a addAnimations:^{
        for (UIView* v in self.view.subviews)
            if ([v isKindOfClass:UIButton.class] && [((UIButton*)v).titleLabel.text isEqualToString:@"EXECUTE"])
                v.transform = CGAffineTransformMakeScale(0.95, 0.95);
    }];
    [a startAnimation];
}
- (void)runUp {
    UIViewPropertyAnimator* a = [[UIViewPropertyAnimator alloc] initWithDuration:0.45 dampingRatio:0.42];
    [a addAnimations:^{
        for (UIView* v in self.view.subviews)
            if ([v isKindOfClass:UIButton.class] && [((UIButton*)v).titleLabel.text isEqualToString:@"EXECUTE"])
                v.transform = CGAffineTransformIdentity;
    }];
    [a startAnimation];
}

- (void)run {
    haptic(UIImpactFeedbackStyleMedium);
    [self appendLog:[NSString stringWithFormat:@"$ %@", _editor.text]];
    if (self.onExecute) self.onExecute(_editor.text);
}

- (void)appendLog:(NSString*)line {
    NSString* cur = _output.text ?: @"";
    _output.text = cur.length ? [cur stringByAppendingFormat:@"\n%@", line] : line;
    if (_output.text.length > 1)
        [_output scrollRangeToVisible:NSMakeRange(_output.text.length - 1, 1)];
}
@end

// =====================================================================
//  PART 10 — scripts tab
// =====================================================================

@interface REScriptsVC : UIViewController <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property (nonatomic, copy) void (^onPick)(NSString* code, NSString* name);
@end

@implementation REScriptsVC {
    UITableView* _table;
    UISearchBar* _search;
    NSArray* _starred, *_saved;
    NSString* _q;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    _search = [UISearchBar new];
    _search.translatesAutoresizingMaskIntoConstraints = NO;
    _search.placeholder = @"Search scripts";
    _search.searchBarStyle = UISearchBarStyleMinimal;
    _search.barStyle = UIBarStyleBlack;
    _search.delegate = self;
    [self.view addSubview:_search];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _table.translatesAutoresizingMaskIntoConstraints = NO;
    _table.backgroundColor = UIColor.clearColor;
    _table.separatorColor = [UIColor colorWithWhite:1 alpha:0.08];
    _table.rowHeight = 62;
    _table.dataSource = self;
    _table.delegate = self;
    _table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [_table registerClass:RECell.class forCellReuseIdentifier:@"c"];
    [self.view addSubview:_table];

    [NSLayoutConstraint activateConstraints:@[
        [_search.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_search.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_search.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_search.heightAnchor constraintEqualToConstant:44],
        [_table.topAnchor constraintEqualToAnchor:_search.bottomAnchor],
        [_table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reload)
        name:@"re.saved" object:nil];
    [self reload];
}

- (void)reload {
    _starred = [[REStore shared] starred];
    _saved = [[REStore shared] saved];
    [_table reloadData];
}

- (NSArray*)listForSection:(NSInteger)s {
    NSArray* src = (s == 0) ? _starred : (s == 1) ? commonScripts() : _saved;
    if (!_q.length) return src;
    NSMutableArray* out = [NSMutableArray array];
    for (NSDictionary* d in src)
        if ([d[@"name"] localizedCaseInsensitiveContainsString:_q]) [out addObject:d];
    return out;
}

- (void)searchBar:(UISearchBar*)sb textDidChange:(NSString*)t {
    _q = t; [_table reloadData];
}
- (void)searchBarSearchButtonClicked:(UISearchBar*)sb { [sb resignFirstResponder]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView*)t { return 3; }

- (NSString*)tableView:(UITableView*)t titleForHeaderInSection:(NSInteger)s {
    return @[@"STARRED", @"COMMON", @"SAVED"][s];
}
- (void)tableView:(UITableView*)t willDisplayHeaderView:(UIView*)v forSection:(NSInteger)s {
    UITableViewHeaderFooterView* h = (UITableViewHeaderFooterView*)v;
    h.textLabel.textColor = [UIColor colorWithWhite:1 alpha:0.4];
    h.textLabel.font = mono(10.5, UIFontWeightBold);
}

- (NSInteger)tableView:(UITableView*)t numberOfRowsInSection:(NSInteger)s {
    return [self listForSection:s].count;
}

- (UITableViewCell*)tableView:(UITableView*)t cellForRowAtIndexPath:(NSIndexPath*)ip {
    RECell* c = [t dequeueReusableCellWithIdentifier:@"c" forIndexPath:ip];
    NSDictionary* d = [self listForSection:ip.section][ip.row];
    c.titleLbl.text = d[@"name"];
    c.subLbl.text = d[@"desc"] ?: [d[@"code"] substringToIndex:MIN(52, [d[@"code"] length])];
    BOOL star = [[REStore shared] isStarred:d[@"name"]];
    [c.starBtn setTitle:star ? @"★" : @"☆" forState:UIControlStateNormal];
    c.starBtn.tintColor = star ? accA() : [UIColor colorWithWhite:1 alpha:0.35];
    __weak REScriptsVC* wself = self;
    c.onStar = ^{
        [[REStore shared] toggleStar:d];
        [wself reload];
    };
    return c;
}

- (void)tableView:(UITableView*)t didSelectRowAtIndexPath:(NSIndexPath*)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    NSDictionary* d = [self listForSection:ip.section][ip.row];
    if (self.onPick) self.onPick(d[@"code"], d[@"name"]);
}

- (BOOL)tableView:(UITableView*)t canEditRowAtIndexPath:(NSIndexPath*)ip {
    return ip.section == 2;
}
- (void)tableView:(UITableView*)t commitEditingStyle:(UITableViewCellEditingStyle)st
                                forRowAtIndexPath:(NSIndexPath*)ip {
    if (st == UITableViewCellEditingStyleDelete) {
        [[REStore shared] deleteSaved:[self listForSection:2][ip.row][@"name"]];
        [self reload];
    }
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
@end

// =====================================================================
//  PART 11 — history tab
// =====================================================================

@interface REHistoryVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) void (^onPick)(NSString* code);
@end

@implementation REHistoryVC {
    UITableView* _table;
    NSArray* _items;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    UIButton* clear = [UIButton buttonWithType:UIButtonTypeSystem];
    clear.translatesAutoresizingMaskIntoConstraints = NO;
    [clear setTitle:@"Clear History" forState:UIControlStateNormal];
    clear.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    clear.tintColor = UIColor.whiteColor;
    clear.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    clear.layer.cornerRadius = 10;
    [clear addTarget:self action:@selector(clear) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:clear];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _table.translatesAutoresizingMaskIntoConstraints = NO;
    _table.backgroundColor = UIColor.clearColor;
    _table.separatorColor = [UIColor colorWithWhite:1 alpha:0.08];
    _table.rowHeight = 56;
    _table.dataSource = self;
    _table.delegate = self;
    [_table registerClass:RECell.class forCellReuseIdentifier:@"c"];
    [self.view addSubview:_table];

    [NSLayoutConstraint activateConstraints:@[
        [clear.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:4],
        [clear.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [clear.widthAnchor constraintEqualToConstant:110],
        [clear.heightAnchor constraintEqualToConstant:34],
        [_table.topAnchor constraintEqualToAnchor:clear.bottomAnchor constant:8],
        [_table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    [self reload];
}
- (void)reload { _items = [[REStore shared] history]; [_table reloadData]; }
- (void)clear { [[REStore shared] clearHistory]; [self reload]; haptic(UIImpactFeedbackStyleLight); }

- (NSInteger)tableView:(UITableView*)t numberOfRowsInSection:(NSInteger)s { return _items.count; }
- (UITableViewCell*)tableView:(UITableView*)t cellForRowAtIndexPath:(NSIndexPath*)ip {
    RECell* c = [t dequeueReusableCellWithIdentifier:@"c" forIndexPath:ip];
    NSDictionary* d = _items[ip.row];
    NSString* code = d[@"code"];
    c.titleLbl.text = [[code stringByReplacingOccurrencesOfString:@"\n" withString:@" "]
                        substringToIndex:MIN(46, [code stringByReplacingOccurrencesOfString:@"\n" withString:@" "].length)];
    NSDate* dt = [NSDate dateWithTimeIntervalSince1970:[d[@"date"] doubleValue]];
    NSDateFormatter* f = [NSDateFormatter new];
    f.dateFormat = @"MMM d, HH:mm";
    c.subLbl.text = [f stringFromDate:dt];
    c.starBtn.hidden = YES;
    return c;
}
- (void)tableView:(UITableView*)t didSelectRowAtIndexPath:(NSIndexPath*)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (self.onPick) self.onPick(_items[ip.row][@"code"]);
}
@end

// =====================================================================
//  PART 12 — settings tab
// =====================================================================

@interface RESettingsVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) void (^onChange)(void);
@end

@implementation RESettingsVC {
    UITableView* _table;
    NSString* _fpsVal;
    NSString* _accVal;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    UITableViewStyle st = UITableViewStyleGrouped;
    if (@available(iOS 13.0, *)) st = UITableViewStyleInsetGrouped;
    _table = [[UITableView alloc] initWithFrame:CGRectZero style:st];
    _table.translatesAutoresizingMaskIntoConstraints = NO;
    _table.backgroundColor = UIColor.clearColor;
    _table.separatorColor = [UIColor colorWithWhite:1 alpha:0.08];
    _table.dataSource = self;
    _table.delegate = self;
    [_table registerClass:RESwitchCell.class forCellReuseIdentifier:@"s"];
    [_table registerClass:REValueCell.class forCellReuseIdentifier:@"v"];
    [self.view addSubview:_table];

    [NSLayoutConstraint activateConstraints:@[
        [_table.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    [self refresh];
}

- (void)refresh {
    NSInteger fps = [[[REStore shared] get:@"re.fps" def:@0] integerValue];
    _fpsVal = fps == 0 ? @"Off" : [NSString stringWithFormat:@"%ld", (long)fps];
    NSArray* names = @[@"Violet", @"Sunset", @"Mint", @"Amber", @"Silver"];
    _accVal = names[accIdx()];
    [_table reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView*)t { return 4; }

- (NSString*)tableView:(UITableView*)t titleForHeaderInSection:(NSInteger)s {
    return @[@"PERFORMANCE", @"APPEARANCE", @"BEHAVIOUR", @"DATA"][s];
}
- (void)tableView:(UITableView*)t willDisplayHeaderView:(UIView*)v forSection:(NSInteger)s {
    UITableViewHeaderFooterView* h = (UITableViewHeaderFooterView*)v;
    h.textLabel.textColor = [UIColor colorWithWhite:1 alpha:0.4];
    h.textLabel.font = mono(10.5, UIFontWeightBold);
}

- (NSInteger)tableView:(UITableView*)t numberOfRowsInSection:(NSInteger)s {
    return @[@2, @2, @1, @3][s];
}

- (UITableViewCell*)tableView:(UITableView*)t cellForRowAtIndexPath:(NSIndexPath*)ip {
    REStore* st = [REStore shared];

    if (ip.section == 0) {
        if (ip.row == 0) {
            REValueCell* c = [t dequeueReusableCellWithIdentifier:@"v" forIndexPath:ip];
            c.textLabel.text = @"FPS Unlock";
            c.detailTextLabel.text = _fpsVal;
            return c;
        }
        RESwitchCell* c = [t dequeueReusableCellWithIdentifier:@"s" forIndexPath:ip];
        c.textLabel.text = @"Haptics";
        c.sw.onTintColor = accA();
        c.sw.on = [[st get:@"re.haptics" def:@YES] boolValue];
        [c.sw removeTarget:nil action:nil forControlEvents:UIControlEventValueChanged];
        [c.sw addTarget:self action:@selector(hapChanged:) forControlEvents:UIControlEventValueChanged];
        return c;
    }
    if (ip.section == 1) {
        if (ip.row == 0) {
            REValueCell* c = [t dequeueReusableCellWithIdentifier:@"v" forIndexPath:ip];
            c.textLabel.text = @"Accent";
            c.detailTextLabel.text = _accVal;
            return c;
        }
        REValueCell* c = [t dequeueReusableCellWithIdentifier:@"v" forIndexPath:ip];
        c.textLabel.text = @"Font Size";
        c.detailTextLabel.text = [NSString stringWithFormat:@"%.1f", fontSize()];
        return c;
    }
    if (ip.section == 2) {
        RESwitchCell* c = [t dequeueReusableCellWithIdentifier:@"s" forIndexPath:ip];
        c.textLabel.text = @"Auto-run last script";
        c.sw.onTintColor = accA();
        c.sw.on = [[st get:@"re.autorun" def:@NO] boolValue];
        [c.sw removeTarget:nil action:nil forControlEvents:UIControlEventValueChanged];
        [c.sw addTarget:self action:@selector(autoChanged:) forControlEvents:UIControlEventValueChanged];
        return c;
    }
    REValueCell* c = [t dequeueReusableCellWithIdentifier:@"v" forIndexPath:ip];
    c.accessoryType = UITableViewCellAccessoryNone;
    c.detailTextLabel.text = @"";
    c.textLabel.text = @[@"Clear History", @"Clear Saved Scripts", @"Reset Everything"][ip.row];
    c.textLabel.textColor = ip.row == 2
        ? [UIColor colorWithRed:1 green:0.4 blue:0.4 alpha:1]
        : UIColor.whiteColor;
    return c;
}

- (void)hapChanged:(UISwitch*)s {
    [[REStore shared] set:@"re.haptics" v:@(s.on)];
    haptic(UIImpactFeedbackStyleLight);
}
- (void)autoChanged:(UISwitch*)s {
    [[REStore shared] set:@"re.autorun" v:@(s.on)];
}

- (void)tableView:(UITableView*)t didSelectRowAtIndexPath:(NSIndexPath*)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0 && ip.row == 0)      [self pickFPS];
    else if (ip.section == 1 && ip.row == 0) [self pickAccent];
    else if (ip.section == 1 && ip.row == 1) [self pickFont];
    else if (ip.section == 3) {
        if (ip.row == 0) { [[REStore shared] clearHistory]; }
        else if (ip.row == 1) { [[REStore shared] clearSaved]; }
        else { [[REStore shared] resetAll]; }
        [self refresh];
        if (self.onChange) self.onChange();
        haptic(UIImpactFeedbackStyleMedium);
    }
}

- (void)pickFPS {
    UIAlertController* a = [UIAlertController alertControllerWithTitle:@"FPS Unlock"
        message:@"Forces the frame rate. Needs a ProMotion device for 120."
        preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray* opts = @[@"Off", @"60", @"90", @"120", @"Max"];
    for (NSInteger i = 0; i < opts.count; i++) {
        NSInteger val = i == 0 ? 0 : (i == 4 ? (NSInteger)UIScreen.mainScreen.maximumFramesPerSecond
                                             : [opts[i] integerValue]);
        [a addAction:[UIAlertAction actionWithTitle:opts[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction* x) {
            [[REStore shared] set:@"re.fps" v:@(val)];
            g_fpsTarget = (int)val;
            [self refresh];
            if (self.onChange) self.onChange();
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)pickAccent {
    UIAlertController* a = [UIAlertController alertControllerWithTitle:@"Accent"
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray* names = @[@"Violet", @"Sunset", @"Mint", @"Amber", @"Silver"];
    for (NSInteger i = 0; i < names.count; i++) {
        [a addAction:[UIAlertAction actionWithTitle:names[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction* x) {
            [[REStore shared] set:@"re.accent" v:@(i)];
            [self refresh];
            if (self.onChange) self.onChange();
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)pickFont {
    UIAlertController* a = [UIAlertController alertControllerWithTitle:@"Font Size"
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray* sizes = @[@"11", @"12.5", @"14", @"16", @"18"];
    for (NSString* s in sizes) {
        [a addAction:[UIAlertAction actionWithTitle:s style:UIAlertActionStyleDefault handler:^(UIAlertAction* x) {
            [[REStore shared] set:@"re.fontsize" v:@([s doubleValue])];
            [self refresh];
            if (self.onChange) self.onChange();
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
@end

// =====================================================================
//  PART 13 — panel
// =====================================================================

@interface REPanelVC : UIViewController
@property (nonatomic, copy) void (^onClose)(void);
@property (nonatomic, strong) REConsoleVC* console;
- (void)appendLog:(NSString*)s;
- (void)loadCode:(NSString*)code name:(NSString*)name;
@end

@implementation REPanelVC {
    UIVisualEffectView* _blur;
    UIView* _content;
    RETabBar* _tabs;
    UIViewController* _cur;
    NSArray* _vcs;
}
- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.layer.cornerRadius = 22;
    if (@available(iOS 13.0, *)) self.view.layer.cornerCurve = kCACornerCurveContinuous;
    self.view.layer.masksToBounds = YES;
    self.view.layer.borderWidth = 0.5;
    self.view.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;

    if (blurOn()) {
        UIBlurEffectStyle bs = UIBlurEffectStyleDark;
        if (@available(iOS 13.0, *)) bs = UIBlurEffectStyleSystemChromeMaterialDark;
        _blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:bs]];
    } else {
        _blur = [[UIVisualEffectView alloc] initWithEffect:nil];
        _blur.backgroundColor = [UIColor colorWithWhite:0.07 alpha:0.94];
    }
    _blur.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_blur];
    UIView* c = _blur.contentView;

    UIView* grip = [UIView new];
    grip.translatesAutoresizingMaskIntoConstraints = NO;
    grip.backgroundColor = [UIColor colorWithWhite:1 alpha:0.25];
    grip.layer.cornerRadius = 2.5;
    [c addSubview:grip];

    UILabel* title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"EXECUTOR";
    title.textColor = [UIColor colorWithWhite:1 alpha:0.55];
    title.font = mono(10.5, UIFontWeightBold);
    [c addSubview:title];

    UIButton* close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setTitle:@"✕" forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    close.tintColor = [UIColor colorWithWhite:1 alpha:0.7];
    [close addTarget:self action:@selector(closeTap) forControlEvents:UIControlEventTouchUpInside];
    [c addSubview:close];

    _tabs = [[RETabBar alloc] initWithTitles:@[@"Console", @"Scripts", @"History", @"Settings"]];
    _tabs.translatesAutoresizingMaskIntoConstraints = NO;
    [c addSubview:_tabs];

    _content = [UIView new];
    _content.translatesAutoresizingMaskIntoConstraints = NO;
    _content.backgroundColor = UIColor.clearColor;
    [c addSubview:_content];

    [NSLayoutConstraint activateConstraints:@[
        [_blur.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_blur.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_blur.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_blur.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [grip.centerXAnchor constraintEqualToAnchor:c.centerXAnchor],
        [grip.topAnchor constraintEqualToAnchor:c.topAnchor constant:7],
        [grip.widthAnchor constraintEqualToConstant:38],
        [grip.heightAnchor constraintEqualToConstant:5],

        [title.leadingAnchor constraintEqualToAnchor:c.leadingAnchor constant:16],
        [title.topAnchor constraintEqualToAnchor:c.topAnchor constant:20],

        [close.trailingAnchor constraintEqualToAnchor:c.trailingAnchor constant:-14],
        [close.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],

        [_tabs.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:10],
        [_tabs.leadingAnchor constraintEqualToAnchor:c.leadingAnchor constant:12],
        [_tabs.trailingAnchor constraintEqualToAnchor:c.trailingAnchor constant:-12],
        [_tabs.heightAnchor constraintEqualToConstant:36],

        [_content.topAnchor constraintEqualToAnchor:_tabs.bottomAnchor constant:12],
        [_content.leadingAnchor constraintEqualToAnchor:c.leadingAnchor constant:14],
        [_content.trailingAnchor constraintEqualToAnchor:c.trailingAnchor constant:-14],
        [_content.bottomAnchor constraintEqualToAnchor:c.bottomAnchor constant:-14],
    ]];

    // tabs
    self.console = [REConsoleVC new];
    __weak REPanelVC* wself = self;
    self.console.onExecute = ^(NSString* code) {
        [[REStore shared] addHistory:code];
        [[REStore shared] set:@"re.lastscript" v:code];
        if (g_L && g_ready) executor_execute(code.UTF8String);
        else [wself appendLog:@"(waiting for VM...)"];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"re.saved" object:nil];
    };

    REScriptsVC* scripts = [REScriptsVC new];
    scripts.onPick = ^(NSString* code, NSString* name) {
        [wself loadCode:code name:name];
        [wself showTab:0];
        [wself->_tabs select:0 animated:YES];
    };

    REHistoryVC* hist = [REHistoryVC new];
    hist.onPick = ^(NSString* code) {
        [wself loadCode:code name:nil];
        [wself showTab:0];
        [wself->_tabs select:0 animated:YES];
    };

    RESettingsVC* settings = [RESettingsVC new];
    settings.onChange = ^{ [wself rebuildTheme]; };

    _vcs = @[self.console, scripts, hist, settings];

    _tabs.onSelect = ^(NSInteger i) { [wself showTab:i]; };
    [self showTab:0];

    [c addGestureRecognizer:
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)]];

    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(kb:) name:UIKeyboardWillChangeFrameNotification object:nil];
}

- (void)showTab:(NSInteger)i {
    if (_cur == _vcs[i]) return;
    UIViewController* vc = _vcs[i];

    [_cur willMoveToParentViewController:nil];
    [_cur.view removeFromSuperview];
    [_cur removeFromParentViewController];

    [self addChildViewController:vc];
    vc.view.translatesAutoresizingMaskIntoConstraints = NO;
    vc.view.alpha = 0;
    [_content addSubview:vc.view];
    [NSLayoutConstraint activateConstraints:@[
        [vc.view.topAnchor constraintEqualToAnchor:_content.topAnchor],
        [vc.view.bottomAnchor constraintEqualToAnchor:_content.bottomAnchor],
        [vc.view.leadingAnchor constraintEqualToAnchor:_content.leadingAnchor],
        [vc.view.trailingAnchor constraintEqualToAnchor:_content.trailingAnchor],
    ]];
    [vc didMoveToParentViewController:self];
    _cur = vc;

    [UIViewPropertyAnimator runningPropertyAnimatorWithDuration:0.22
        curve:UIViewAnimationCurveEaseOut animations:^{ vc.view.alpha = 1; }];
}

- (void)rebuildTheme {
    // rebuild tab content so accent colors apply
    [self showTab:0];
    [_tabs select:0 animated:NO];
}

- (void)closeTap { haptic(UIImpactFeedbackStyleLight); if (self.onClose) self.onClose(); }

- (void)appendLog:(NSString*)s { [self.console appendLog:s]; }

- (void)loadCode:(NSString*)code name:(NSString*)name {
    [self.console setCode:code];
    if (name) [self appendLog:[NSString stringWithFormat:@"[loaded] %@", name]];
}

- (void)drag:(UIPanGestureRecognizer*)g {
    UIView* sv = self.view.superview; if (!sv) return;
    static CGPoint start;
    CGPoint t = [g translationInView:sv];
    if (g.state == UIGestureRecognizerStateBegan) start = self.view.center;
    self.view.center = CGPointMake(start.x + t.x, start.y + t.y);
}

- (void)kb:(NSNotification*)n {
    UIView* sv = self.view.superview; if (!sv) return;
    CGRect kb = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    kb = [sv convertRect:kb fromView:nil];
    CGFloat overlap = CGRectGetMaxY(self.view.frame) - kb.origin.y;
    CGFloat shift = MAX(0, overlap + 16);
    CGFloat dur = [n.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewPropertyAnimator* a = [[UIViewPropertyAnimator alloc]
        initWithDuration:dur ?: 0.25 curve:UIViewAnimationCurveEaseOut
        animations:^{ self.view.transform = CGAffineTransformMakeTranslation(0, -shift); }];
    [a startAnimation];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
@end

// =====================================================================
//  PART 14 — window, orb, controller
// =====================================================================

@interface REWindow : UIWindow
@property (nonatomic, assign) BOOL captureTouches;
@end
@implementation REWindow
- (UIView*)hitTest:(CGPoint)p withEvent:(UIEvent*)e {
    UIView* v = [super hitTest:p withEvent:e];
    if (v == self || v == self.rootViewController.view) return nil;
    return v;
}
- (BOOL)canBecomeKeyWindow { return self.captureTouches; }
@end

static const CGFloat kFab = 56.0;
static const CGFloat kPad = 16.0;

@interface REFab : UIView
@property (nonatomic, copy) void (^onTap)(void);
- (void)restyle;
@end

@implementation REFab {
    CAGradientLayer* _grad;
    CADisplayLink* _link;
    CGFloat _phase;
    CGPoint _grab;
    BOOL _dragging;
}
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.bounds = CGRectMake(0, 0, kFab, kFab);
        self.layer.cornerRadius = kFab / 2;
        if (@available(iOS 13.0, *)) self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.shadowColor = accA().CGColor;
        self.layer.shadowOffset = CGSizeZero;
        self.layer.shadowOpacity = 0.5;
        self.layer.shadowRadius = 14;

        _grad = [CAGradientLayer layer];
        _grad.cornerRadius = kFab / 2;
        _grad.startPoint = CGPointMake(0, 0);
        _grad.endPoint = CGPointMake(1, 1);
        _grad.colors = @[(id)accA().CGColor, (id)accB().CGColor];
        [self.layer addSublayer:_grad];

        UILabel* g = [[UILabel alloc] initWithFrame:self.bounds];
        g.text = @">_";
        g.textColor = UIColor.whiteColor;
        g.font = mono(17, UIFontWeightHeavy);
        g.textAlignment = NSTextAlignmentCenter;
        g.userInteractionEnabled = NO;
        [self addSubview:g];

        [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tap)]];
        [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)]];
        [self breath];
    }
    return self;
}
- (void)restyle {
    self.layer.shadowColor = accA().CGColor;
    _grad.colors = @[(id)accA().CGColor, (id)accB().CGColor];
}
- (void)layoutSubviews { [super layoutSubviews]; _grad.frame = self.bounds; }

- (void)tap {
    haptic(UIImpactFeedbackStyleMedium);
    UIViewPropertyAnimator* a = [[UIViewPropertyAnimator alloc] initWithDuration:0.16 dampingRatio:0.5];
    [a addAnimations:^{ self.transform = CGAffineTransformMakeScale(0.88, 0.88); }];
    [a addCompletion:^(UIViewAnimatingPosition p) {
        UIViewPropertyAnimator* b = [[UIViewPropertyAnimator alloc] initWithDuration:0.42 dampingRatio:0.5];
        [b addAnimations:^{ self.transform = CGAffineTransformIdentity; }];
        [b startAnimation];
    }];
    [a startAnimation];
    if (self.onTap) self.onTap();
}
- (void)pan:(UIPanGestureRecognizer*)g {
    UIView* sv = self.superview; if (!sv) return;
    CGPoint t = [g translationInView:sv];
    if (g.state == UIGestureRecognizerStateBegan) {
        _grab = self.center; _dragging = YES;
        haptic(UIImpactFeedbackStyleLight);
        UIViewPropertyAnimator* a = [[UIViewPropertyAnimator alloc] initWithDuration:0.2 dampingRatio:0.6];
        [a addAnimations:^{ self.transform = CGAffineTransformMakeScale(1.12, 1.12); }];
        [a startAnimation];
    }
    CGFloat r = kFab / 2 + kPad;
    UIEdgeInsets sa = sv.safeAreaInsets;
    CGPoint c = CGPointMake(_grab.x + t.x, _grab.y + t.y);
    c.x = MAX(r, MIN(sv.bounds.size.width - r, c.x));
    c.y = MAX(r + sa.top, MIN(sv.bounds.size.height - r - sa.bottom, c.y));
    self.center = c;
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        _dragging = NO; [self snap];
    }
}
- (void)snap {
    UIView* sv = self.superview; if (!sv) return;
    CGFloat r = kFab / 2 + kPad;
    CGFloat x = (self.center.x < sv.bounds.size.width / 2) ? r : sv.bounds.size.width - r;
    UISpringTimingParameters* sp = [[UISpringTimingParameters alloc] initWithDampingRatio:0.68];
    UIViewPropertyAnimator* a = [[UIViewPropertyAnimator alloc] initWithDuration:0.5 timingParameters:sp];
    [a addAnimations:^{
        self.center = CGPointMake(x, self.center.y);
        self.transform = CGAffineTransformIdentity;
    }];
    [a startAnimation];
    haptic(UIImpactFeedbackStyleLight);
}
- (void)breath {
    if (_link) return;
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    if (@available(iOS 15.0, *))
        _link.preferredFrameRateRange = CAFrameRateRangeMake(80, 120, 120);
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
- (void)tick {
    if (_dragging || !self.window) return;
    _phase += _link.duration * 1.7;
    CGFloat s = 0.5 + 0.5 * sin(_phase);
    self.layer.shadowOpacity = 0.32 + 0.30 * s;
    self.layer.shadowRadius = 11 + 7 * s;
}
- (void)dealloc { [_link invalidate]; }
@end

@interface REUI : NSObject
+ (instancetype)shared;
- (void)install;
- (void)logLine:(NSString*)s;
@end

@implementation REUI {
    REWindow* _win;
    REFab* _fab;
    REPanelVC* _panel;
    __weak UIWindow* _prevKey;
}
+ (instancetype)shared {
    static REUI* s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [REUI new]; });
    return s;
}
- (void)install {
    if (_win) return;
    if (@available(iOS 13.0, *)) {
        for (UIScene* s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:UIWindowScene.class] &&
                s.activationState == UISceneActivationStateForegroundActive) {
                _win = [[REWindow alloc] initWithWindowScene:(UIWindowScene*)s];
                break;
            }
        }
    }
    if (!_win) _win = [[REWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    _win.windowLevel = UIWindowLevelAlert + 120;
    _win.backgroundColor = UIColor.clearColor;
    _win.rootViewController = [UIViewController new];
    _win.rootViewController.view.backgroundColor = UIColor.clearColor;
    _win.hidden = NO;

    UIView* root = _win.rootViewController.view;
    CGSize sz = root.bounds.size;
    UIEdgeInsets sa = root.safeAreaInsets;

    _fab = [[REFab alloc] initWithFrame:CGRectMake(sz.width - kFab/2 - kPad,
                                                   sz.height - sa.bottom - kFab/2 - kPad - 40,
                                                   kFab, kFab)];
    __weak REUI* wself = self;
    _fab.onTap = ^{ [wself toggle]; };
    [root addSubview:_fab];

    // auto-run last script
    if ([[[REStore shared] get:@"re.autorun" def:@NO] boolValue]) {
        NSString* last = [[REStore shared] get:@"re.lastscript" def:nil];
        if (last.length) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
            dispatch_get_main_queue(), ^{ executor_execute(last.UTF8String); });
    }
    NSLog(@"[exec] UI installed");
}

- (void)toggle { _panel ? [self collapse] : [self expand]; }

- (void)expand {
    UIView* root = _win.rootViewController.view;
    CGSize sz = root.bounds.size;
    CGFloat w = MIN(sz.width - 24, 460);
    CGFloat h = MIN(sz.height * 0.68, 660);
    CGRect pf = CGRectMake((sz.width - w)/2, (sz.height - h)/2, w, h);

    _panel = [REPanelVC new];
    __weak REUI* wself = self;
    __weak REPanelVC* wp = _panel;
    _panel.onClose = ^{ [wself collapse]; };
    [_win.rootViewController addChildViewController:_panel];
    _panel.view.frame = pf;
    _panel.view.alpha = 0;
    [root addSubview:_panel.view];
    [_panel didMoveToParentViewController:_win.rootViewController];

    _win.captureTouches = YES;
    _prevKey = UIApplication.sharedApplication.keyWindow;
    [_win makeKeyWindow];

    _panel.view.center = _fab.center;
    _panel.view.transform = CGAffineTransformMakeScale(kFab / w, kFab / h);

    UISpringTimingParameters* sp = [[UISpringTimingParameters alloc] initWithDampingRatio:0.76];
    UIViewPropertyAnimator* a = [[UIViewPropertyAnimator alloc] initWithDuration:0.55 timingParameters:sp];
    [a addAnimations:^{
        wp.view.transform = CGAffineTransformIdentity;
        wp.view.center = CGPointMake(sz.width/2, sz.height/2);
        wp.view.alpha = 1;
    }];
    [a startAnimation];

    UIViewPropertyAnimator* b = [[UIViewPropertyAnimator alloc] initWithDuration:0.28 dampingRatio:0.7];
    [b addAnimations:^{
        self->_fab.transform = CGAffineTransformMakeScale(0.001, 0.001);
        self->_fab.alpha = 0;
    }];
    [b startAnimation];
    haptic(UIImpactFeedbackStyleMedium);
}

- (void)collapse {
    REPanelVC* p = _panel; if (!p) return;
    _panel = nil;
    _win.captureTouches = NO;
    if (_prevKey) [_prevKey makeKeyWindow];

    UISpringTimingParameters* sp = [[UISpringTimingParameters alloc] initWithDampingRatio:0.8];
    UIViewPropertyAnimator* a = [[UIViewPropertyAnimator alloc] initWithDuration:0.34 timingParameters:sp];
    [a addAnimations:^{
        p.view.transform = CGAffineTransformMakeScale(0.86, 0.86);
        p.view.alpha = 0;
    }];
    [a addCompletion:^(UIViewAnimatingPosition pos) {
        [p.view removeFromSuperview];
        [p removeFromParentViewController];
    }];
    [a startAnimation];

    UIViewPropertyAnimator* b = [[UIViewPropertyAnimator alloc] initWithDuration:0.5 dampingRatio:0.55];
    [b addAnimations:^{
        self->_fab.transform = CGAffineTransformIdentity;
        self->_fab.alpha = 1;
    }];
    [b startAnimation];
}

- (void)logLine:(NSString*)s {
    if (_panel) [_panel appendLog:s];
    else NSLog(@"[exec] %@", s);
}
@end

// =====================================================================
//  PART 15 — bootstrap
// =====================================================================

static void log_to_ui(const char* msg) {
    NSString* s = [NSString stringWithUTF8String:msg ?: ""];
    dispatch_async(dispatch_get_main_queue(), ^{ [[REUI shared] logLine:s]; });
}

__attribute__((constructor))
static void re_ctor(void) {
    g_fpsTarget = (int)[[[REStore shared] get:@"re.fps" def:@0] integerValue];
    [CADisplayLink re_install];

    executor_set_log(log_to_ui);
    executor_boot();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        [[REUI shared] install];
    });
}