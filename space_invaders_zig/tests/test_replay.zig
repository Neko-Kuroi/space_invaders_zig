//! test_replay.zig - ゲーム本体の通しテスト（C++版 test_replay.cpp の Zig 化）。
//! 固定の種（12345）＋合成入力＋手動時計（16ms 刻み）で 600 フレーム回し、
//! 終了時の状態が固定値と一致するかを見る。乱数の実装（DefaultPrng）と
//! Zig の版が固定されているため、値は再現する。
//! 音は読み込まない（load_sounds=false）。素材は実行時のカレント
//! ディレクトリ（zig build test ではプロジェクト直下）から読む。

const std = @import("std");
const c = @import("sdl");
const game_mod = @import("game");
const assets_mod = @import("assets");
const logic = @import("logic");

const Game = game_mod.Game;
const Input = game_mod.Input;
const Assets = assets_mod.Assets;

const FRAMES = 600;
const SEED: u64 = 12345;

// 初回実行で観測して固定した値（build 後に再確認すること）
const PIN_SCORE: i32 = 20;
const PIN_ENEMIES: i32 = 48;
const PIN_LIVES: i32 = 1;
const PIN_SHIP_X: i32 = 344;
const PIN_FLEET_BOTTOM: i32 = 290;
const PIN_BLOCKER_CELLS: i32 = 1250;
const PIN_GROUND_CELLS: i32 = 188;
const PIN_MOVE_NUMBER: i32 = 24;

fn syntheticInput(frame: i32) Input {
    // main.zig のスモークと同じ合成入力（2フレーム目に開始、
    // 右→左に動き、25フレームごとに撃つ）
    var in = Input{};
    if (frame == 2)
        in.any_keyup = true;
    if (frame > 2) {
        const phase = @mod(@divTrunc(frame, 60), 2);
        in.held_d = phase == 0;
        in.held_a = phase == 1;
        if (@mod(frame, 25) == 0)
            in.fire_keydown = true;
    }
    return in;
}

test "replay 600 frames with fixed seed" {
    _ = c.SDL_setenv("SDL_VIDEODRIVER", "dummy", 1);
    _ = c.SDL_setenv("SDL_AUDIODRIVER", "dummy", 1);

    try std.testing.expect(c.SDL_Init(c.SDL_INIT_VIDEO) == 0);
    defer c.SDL_Quit();
    _ = c.IMG_Init(c.IMG_INIT_PNG | c.IMG_INIT_JPG);
    defer c.IMG_Quit();
    try std.testing.expect(c.TTF_Init() == 0);
    defer c.TTF_Quit();

    const window = c.SDL_CreateWindow("replay", 0, 0, game_mod.SCREEN_W, game_mod.SCREEN_H, 0);
    try std.testing.expect(window != null);
    defer c.SDL_DestroyWindow(window);
    const renderer = c.SDL_CreateRenderer(window, -1, c.SDL_RENDERER_SOFTWARE);
    try std.testing.expect(renderer != null);
    defer c.SDL_DestroyRenderer(renderer);

    var assets = try Assets.load(renderer.?, "./", false);
    defer assets.deinit();

    var game = Game.init(&assets, SEED);
    var frame: i32 = 0;
    while (frame < FRAMES) : (frame += 1) {
        const now: u32 = @intCast(frame * 16);
        var in = syntheticInput(frame);
        try std.testing.expect(game.update(&in, now));
        game.render(renderer.?, now);
    }

    var blocker_cells: i32 = 0;
    for (0..game_mod.BLOCKER_COUNT) |b| {
        for (0..logic.BARRIER_ROWS) |r| {
            for (0..logic.BARRIER_COLS) |cc| {
                if (game.blockers[b][r][cc]) blocker_cells += 1;
            }
        }
    }
    var ground_cells: i32 = 0;
    for (0..game_mod.GROUND_CELLS) |i| {
        if (game.ground[i]) ground_cells += 1;
    }

    std.debug.print("\nreplay observed: state={d} score={d} enemies={d} lives={d} round={d} ship_alive={} ship_x={d} fleet_bottom={d} blockers={d} ground={d} move_number={d} row_counter={d}\n", .{
        @intFromEnum(game.state), game.score, game.ledger.count, game.lives_spare,
        game.round_num, game.ship_alive, game.ship.r.x, game.fleet_bottom,
        blocker_cells, ground_cells, game.move_number, game.row_counter,
    });

    try std.testing.expect(game.state == .play);
    try std.testing.expectEqual(PIN_SCORE, game.score);
    try std.testing.expectEqual(PIN_ENEMIES, game.ledger.count);
    try std.testing.expectEqual(PIN_LIVES, game.lives_spare);
    try std.testing.expectEqual(0, game.round_num);
    try std.testing.expectEqual(PIN_SHIP_X, game.ship.r.x);
    try std.testing.expectEqual(PIN_FLEET_BOTTOM, game.fleet_bottom);
    try std.testing.expectEqual(PIN_BLOCKER_CELLS, blocker_cells);
    try std.testing.expectEqual(PIN_GROUND_CELLS, ground_cells);
    try std.testing.expectEqual(PIN_MOVE_NUMBER, game.move_number);
    try std.testing.expectEqual(2, game.row_counter);
    try std.testing.expect(!game.ship_alive);
}
