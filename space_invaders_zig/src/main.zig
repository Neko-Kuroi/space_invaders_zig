//! main.zig - SDL の初期化、イベントの読み取り、メインループ
//! （C版 main.c の Zig 化）。
//! ゲームの規則は game.zig 側にあり、ここは Input への変換だけを行う。
//!
//! スモークテスト用: 環境変数 SI_SMOKE_FRAMES=N を付けると、入力を合成して
//! N フレームだけ回し、状態を表示して終了する（画面なし環境での確認用）。

const std = @import("std");
const c = @import("sdl");
const game_mod = @import("game");
const assets_mod = @import("assets");

const Game = game_mod.Game;
const Input = game_mod.Input;
const Assets = assets_mod.Assets;

/// SDL の初期化と後始末。初期化の途中で失敗した場合は、済んだ分だけを
/// 片付ける（defer で deinit を呼ぶ形、C版の goto done と同じ範囲）。
const Sdl = struct {
    window: ?*c.SDL_Window = null,
    renderer: ?*c.SDL_Renderer = null,
    video: bool = false,
    img_ready: bool = false,
    ttf_ready: bool = false,
    audio_ready: bool = false,

    fn init() !Sdl {
        var s = Sdl{};
        errdefer s.deinit();

        if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) {
            std.debug.print("SDL_Init failed: {s}\n", .{std.mem.span(c.SDL_GetError())});
            return error.InitFailed;
        }
        s.video = true;
        if ((c.IMG_Init(c.IMG_INIT_PNG | c.IMG_INIT_JPG) & (c.IMG_INIT_PNG | c.IMG_INIT_JPG)) == 0) {
            std.debug.print("IMG_Init failed: {s}\n", .{std.mem.span(c.IMG_GetError())});
            return error.InitFailed;
        }
        s.img_ready = true;
        if (c.TTF_Init() != 0) {
            std.debug.print("TTF_Init failed: {s}\n", .{std.mem.span(c.TTF_GetError())});
            return error.InitFailed;
        }
        s.ttf_ready = true;

        // 音は無くても遊べるので、音声デバイスが使えなくても続行する
        // （WSL・CI・音声デバイスのない環境など）。
        // 原典の mixer.pre_init(44100, -16, 1, 4096) に合わせる。
        if (c.SDL_InitSubSystem(c.SDL_INIT_AUDIO) == 0 and
            c.Mix_OpenAudio(44100, c.AUDIO_S16SYS, 1, 4096) == 0)
        {
            s.audio_ready = true;
            // チャンネル0をミステリーシップ出現音の専用に予約する（game.zig）
            _ = c.Mix_ReserveChannels(1);
        } else {
            const e = c.SDL_GetError();
            const msg = if (e[0] != 0) e else c.Mix_GetError();
            std.debug.print("audio unavailable, continuing without sound: {s}\n", .{std.mem.span(msg)});
        }

        s.window = c.SDL_CreateWindow(
            "Space Invaders",
            c.SDL_WINDOWPOS_CENTERED,
            c.SDL_WINDOWPOS_CENTERED,
            game_mod.SCREEN_W,
            game_mod.SCREEN_H,
            c.SDL_WINDOW_RESIZABLE,
        );
        if (s.window == null) {
            std.debug.print("window failed: {s}\n", .{std.mem.span(c.SDL_GetError())});
            return error.InitFailed;
        }
        s.renderer = c.SDL_CreateRenderer(s.window, -1, c.SDL_RENDERER_ACCELERATED | c.SDL_RENDERER_PRESENTVSYNC);
        if (s.renderer == null)
            s.renderer = c.SDL_CreateRenderer(s.window, -1, c.SDL_RENDERER_SOFTWARE);
        if (s.renderer == null) {
            std.debug.print("renderer failed: {s}\n", .{std.mem.span(c.SDL_GetError())});
            return error.InitFailed;
        }
        // 原典の SCALED 相当: 論理画面を 800x600 に固定する
        _ = c.SDL_RenderSetLogicalSize(s.renderer, game_mod.SCREEN_W, game_mod.SCREEN_H);
        return s;
    }

    fn deinit(self: *Sdl) void {
        if (self.renderer) |r| c.SDL_DestroyRenderer(r);
        if (self.window) |w| c.SDL_DestroyWindow(w);
        if (self.audio_ready) c.Mix_CloseAudio();
        if (self.ttf_ready) c.TTF_Quit();
        if (self.img_ready) c.IMG_Quit();
        if (self.video) c.SDL_Quit();
        self.* = .{};
    }
};

fn buildInput(in: *Input, smoke_frame: i32) void {
    in.* = .{};
    var e: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&e) != 0) {
        if (e.type == c.SDL_QUIT)
            in.quit = true;
        if (e.type == c.SDL_KEYUP) {
            in.any_keyup = true;
            if (e.key.keysym.sym == c.SDLK_ESCAPE)
                in.quit = true;
            if (e.key.keysym.sym == c.SDLK_a or e.key.keysym.sym == c.SDLK_d)
                in.keyup_move = true;
        }
        if (e.type == c.SDL_KEYDOWN and e.key.repeat == 0) {
            if (e.key.keysym.sym == c.SDLK_s)
                in.fire_keydown = true;
        }
    }
    const keys = c.SDL_GetKeyboardState(null);
    in.held_a = keys[@intCast(c.SDL_SCANCODE_A)] != 0;
    in.held_d = keys[@intCast(c.SDL_SCANCODE_D)] != 0;

    if (smoke_frame >= 0) {
        // 合成入力: 2フレーム目に開始、右→左に動き、25フレームごとに撃つ
        if (smoke_frame == 2)
            in.any_keyup = true;
        if (smoke_frame > 2) {
            const phase = @mod(@divTrunc(smoke_frame, 60), 2);
            in.held_d = phase == 0;
            in.held_a = phase == 1;
            if (@mod(smoke_frame, 25) == 0)
                in.fire_keydown = true;
        }
    }
}

/// 目標は 60fps。フレームの長さを整数ミリ秒に丸めると 62.5fps になって
/// フレーム単位で動く量（弾の速さなど）がわずかに速くなるため、
/// 高精度タイマーで「次のフレームの開始時刻」を積み上げて待つ。
fn waitForNextFrame(next: *u64, freq: u64) void {
    next.* += freq / 60;
    const t = c.SDL_GetPerformanceCounter();
    if (next.* > t) {
        const ms: u32 = @intCast((next.* - t) * 1000 / freq);
        if (ms > 0)
            c.SDL_Delay(ms);
    } else if (t - next.* > freq / 10) {
        // 大きく遅れたら（ウィンドウ移動など）追いつこうとせず仕切り直す
        next.* = t;
    }
}

pub fn main() u8 {
    const smoke_env = std.c.getenv("SI_SMOKE_FRAMES");
    const smoke_frames: i32 = if (smoke_env) |s| std.fmt.parseInt(i32, std.mem.span(s), 10) catch -1 else -1;

    var sdl = Sdl.init() catch return 1;
    defer sdl.deinit();

    const renderer = sdl.renderer.?;
    const base = c.SDL_GetBasePath();
    const base_path: []const u8 = if (base != null) std.mem.span(base) else "./";
    var assets = Assets.load(renderer, base_path, sdl.audio_ready) catch return 1;
    if (base != null)
        c.SDL_free(base);
    defer assets.deinit();

    const seed: u64 = c.SDL_GetPerformanceCounter() ^ (@as(u64, c.SDL_GetTicks()) << 32);
    var game = Game.init(&assets, seed);

    const freq = c.SDL_GetPerformanceFrequency();
    var next_frame = c.SDL_GetPerformanceCounter();
    var frame: i32 = 0;
    var running = true;
    while (running) {
        // 更新と描画で同じ時刻を使う（爆発の経過時間などがずれないように）
        const now = c.SDL_GetTicks();
        var in: Input = undefined;
        buildInput(&in, if (smoke_frames >= 0) frame else -1);
        running = game.update(&in, now);
        game.render(renderer, now);
        frame += 1;

        if (smoke_frames >= 0 and frame >= smoke_frames) {
            var buf: [128]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "smoke: frames={d} state={d} score={d} enemies={d} round={d} lives={d}\n", .{
                frame, @intFromEnum(game.state), game.score, game.ledger.count, game.round_num, game.lives_spare,
            }) catch "";
            _ = std.c.write(1, line.ptr, line.len);
            break;
        }

        waitForNextFrame(&next_frame, freq);
    }
    return 0;
}
