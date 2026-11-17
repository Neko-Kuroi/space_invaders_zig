//! assets.zig - 画像・音・フォントの読み込みと解放（C版 assets.c の Zig 化）。
//! 素材は原典リポジトリのものをそのまま使う（プロジェクト直下の
//! images/ sounds/ fonts/ を、実行ファイルの場所から相対で読む）。
//! 失敗の表現は C版の 0/1 ではなく、Zig の流儀で error union を使う
//! （計画書の未決事項2、推奨どおり）。

const std = @import("std");
const c = @import("sdl");

/// 画像の番号。原典の IMAGES 辞書のキーに対応する。
pub const Tex = enum(u8) {
    ship,
    shipexplosion1,
    shipexplosion2,
    shipexplosion3,
    mystery,
    enemy1_1,
    enemy1_2,
    enemy2_1,
    enemy2_2,
    enemy3_1,
    enemy3_2,
    laser,
    laser1,
    laser2,
    enemylaser,
    enemylaser1,
    explosionblue,
    explosiongreen,
    explosionpurple,
    background,
};

pub const TEX_COUNT = 20;

/// 音の番号。原典の sounds 辞書と musicNotes、Mystery の音に対応する。
pub const Snd = enum(u8) {
    shoot,
    shoot2,
    invaderkilled,
    mysterykilled,
    shipexplosion,
    mysteryentered,
    note0,
    note1,
    note2,
    note3,
};

pub const SND_COUNT = 10;

const TEX_FILES = [TEX_COUNT][]const u8{
    "images/ship.png",
    "images/shipexplosion1.png",
    "images/shipexplosion2.png",
    "images/shipexplosion3.png",
    "images/mystery.png",
    "images/enemy1_1.png",
    "images/enemy1_2.png",
    "images/enemy2_1.png",
    "images/enemy2_2.png",
    "images/enemy3_1.png",
    "images/enemy3_2.png",
    "images/laser.png",
    "images/laser1.png",
    "images/laser2.png",
    "images/enemylaser.png",
    "images/enemylaser1.png",
    "images/explosionblue.png",
    "images/explosiongreen.png",
    "images/explosionpurple.png",
    "images/background.jpg",
};

const SND_FILES = [SND_COUNT][]const u8{
    "sounds/shoot.wav",
    "sounds/shoot2.wav",
    "sounds/invaderkilled.wav",
    "sounds/mysterykilled.wav",
    "sounds/shipexplosion.wav",
    "sounds/mysteryentered.wav",
    "sounds/0.wav",
    "sounds/1.wav",
    "sounds/2.wav",
    "sounds/3.wav",
};

pub const Assets = struct {
    tex: [TEX_COUNT]?*c.SDL_Texture = @splat(null),
    snd: [SND_COUNT]?*c.Mix_Chunk = @splat(null),
    font20: ?*c.TTF_Font = null,
    font25: ?*c.TTF_Font = null,
    font50: ?*c.TTF_Font = null,

    /// base_path は素材フォルダのあるディレクトリ（末尾に '/' を含む想定）。
    /// load_sounds が false のときは音を読まない（音声デバイスが使えない
    /// 環境用）。その場合 snd[] は null のままで、play 系は何もせず -1 を返す。
    /// 失敗したら標準エラーに理由を出し、読み込み済みの分を解放して
    /// error.LoadFailed を返す。
    pub fn load(renderer: *c.SDL_Renderer, base_path: []const u8, load_sounds: bool) !Assets {
        var a = Assets{};
        errdefer a.deinit();

        var buf: [1024]u8 = undefined;
        for (0..TEX_COUNT) |i| {
            const path = joinPath(&buf, base_path, TEX_FILES[i]);
            const surf = c.IMG_Load(path.ptr);
            if (surf == null) {
                std.debug.print("image load failed: {s}: {s}\n", .{ path, c.IMG_GetError() });
                return error.LoadFailed;
            }
            a.tex[i] = c.SDL_CreateTextureFromSurface(renderer, surf);
            c.SDL_FreeSurface(surf);
            if (a.tex[i] == null) {
                std.debug.print("texture create failed: {s}\n", .{path});
                return error.LoadFailed;
            }
        }
        if (load_sounds) {
            for (0..SND_COUNT) |i| {
                const path = joinPath(&buf, base_path, SND_FILES[i]);
                a.snd[i] = c.Mix_LoadWAV(path.ptr);
                if (a.snd[i] == null) {
                    std.debug.print("sound load failed: {s}: {s}\n", .{ path, c.Mix_GetError() });
                    return error.LoadFailed;
                }
                // 原典は全ての音を set_volume(0.1) している
                _ = c.Mix_VolumeChunk(a.snd[i], @intFromFloat(@as(comptime_float, c.MIX_MAX_VOLUME) * 0.1));
            }
        }

        const path = joinPath(&buf, base_path, "fonts/space_invaders.ttf");
        a.font20 = c.TTF_OpenFont(path.ptr, 20);
        a.font25 = c.TTF_OpenFont(path.ptr, 25);
        a.font50 = c.TTF_OpenFont(path.ptr, 50);
        if (a.font20 == null or a.font25 == null or a.font50 == null) {
            std.debug.print("font load failed: {s}: {s}\n", .{ path, c.TTF_GetError() });
            return error.LoadFailed;
        }
        return a;
    }

    pub fn deinit(self: *Assets) void {
        for (0..TEX_COUNT) |i| {
            if (self.tex[i]) |t| c.SDL_DestroyTexture(t);
            self.tex[i] = null;
        }
        for (0..SND_COUNT) |i| {
            if (self.snd[i]) |s| c.Mix_FreeChunk(s);
            self.snd[i] = null;
        }
        if (self.font20) |f| c.TTF_CloseFont(f);
        if (self.font25) |f| c.TTF_CloseFont(f);
        if (self.font50) |f| c.TTF_CloseFont(f);
        self.font20 = null;
        self.font25 = null;
        self.font50 = null;
    }

    /// 文字をその場で描く（原典の Text.draw 相当）。size は 20/25/50 のみ。
    pub fn drawText(self: *Assets, renderer: *c.SDL_Renderer, size: i32, msg: [:0]const u8, color: c.SDL_Color, x: i32, y: i32) void {
        const font = if (size == 50) self.font50 else if (size == 25) self.font25 else self.font20;
        const surf = c.TTF_RenderUTF8_Blended(font, msg.ptr, color);
        if (surf == null)
            return;
        const tex = c.SDL_CreateTextureFromSurface(renderer, surf);
        if (tex != null) {
            var dst = c.SDL_Rect{ .x = x, .y = y, .w = surf.*.w, .h = surf.*.h };
            _ = c.SDL_RenderCopy(renderer, tex, null, &dst);
            c.SDL_DestroyTexture(tex);
        }
        c.SDL_FreeSurface(surf);
    }

    /// 音量は読み込み時に原典どおり全て 0.1。channel を返す（-1 は失敗）。
    pub fn play(self: *Assets, snd: Snd) i32 {
        const chunk = self.snd[@intFromEnum(snd)] orelse return -1;
        return c.Mix_PlayChannel(-1, chunk, 0);
    }

    /// チャンネルを指定して再生する。ミステリーシップの出現音のように、
    /// 後からフェードアウトや停止をかける音は、Mix_ReserveChannels で
    /// 予約した専用チャンネルで鳴らす（番号の使い回しで別の音を切らない）。
    pub fn playOn(self: *Assets, snd: Snd, channel: i32) i32 {
        const chunk = self.snd[@intFromEnum(snd)] orelse return -1;
        return c.Mix_PlayChannel(channel, chunk, 0);
    }
};

fn joinPath(buf: *[1024]u8, base: []const u8, rel: []const u8) [:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, "{s}{s}", .{ base, rel }, 0) catch buf[0..0 :0];
}
