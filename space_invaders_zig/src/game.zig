//! game.zig - ゲームの進行と描画（C版 game.c の Zig 化）。
//! 原典 spaceinvaders.py の各メソッドの写しで、対応関係はコメントに
//! 原典の名前を残してある。構造と規則は C版と同一。
//! 乱数は std.Random の標準実装（DefaultPrng）に固定する
//! （計画書の未決事項3、推奨どおり）。

const std = @import("std");
const c = @import("sdl");
const logic = @import("logic");
const assets_mod = @import("assets");

const Assets = assets_mod.Assets;
const Tex = assets_mod.Tex;
const Snd = assets_mod.Snd;
const FleetLedger = logic.FleetLedger;
const FLEET_ROWS = logic.FLEET_ROWS;
const FLEET_COLS = logic.FLEET_COLS;
const BARRIER_ROWS = logic.BARRIER_ROWS;
const BARRIER_COLS = logic.BARRIER_COLS;

pub const SCREEN_W = 800;
pub const SCREEN_H = 600;
pub const SHIP_VX = 10;
pub const ENEMY_MOVE_DOWN = 30;
pub const BLOCKERS_POSITION = 390;
pub const ENEMY_DEFAULT_POSITION = 75;

// 自機
pub const SHIP_START_X = 375;
pub const SHIP_START_Y = 540;
pub const SHIP_W = 50;
pub const SHIP_H = 50;
pub const SHIP_RESPAWN_MS = 1600; // 被弾から再出撃まで

// 進行の時間
pub const NEXT_ROUND_DELAY_MS = 3000; // 全滅から次のラウンドまで
pub const MYSTERY_INTERVAL_MS = 25000; // ミステリーシップの出現周期

// 敵集団の到達ライン（fleet_bottom との比較）
pub const FLEET_REACH_SHIP_Y = SHIP_START_Y; // 自機の高さ。重なれば自機が消える
pub const FLEET_GAMEOVER_Y = 600; // ここまで来たらゲームオーバー

// トーチカ（4基。1セル 3x3、BARRIER_COLS x BARRIER_ROWS のセル）
pub const BLOCKER_COUNT = 4;
pub const BLOCKER_X0 = 60;
pub const BLOCKER_PITCH = 200;
pub const BLOCKER_Y_OFFSET = 25; // BLOCKERS_POSITION からの下がり
pub const BLOCKER_CELL = 3;

// 地面（y=GROUND_Y に 4x4 のセルを横一列）
pub const GROUND_Y = 595;
pub const GROUND_CELLS = 200;
pub const GROUND_CELL_W = 4;

// Android 用の発射ボタンの定数（C版と同値。描画と入力は Android 版の
// 計画で扱うため、ここでは定数だけを揃えて置く）。
pub const FIRE_BUTTON_CX = 738;
pub const FIRE_BUTTON_CY = 548;
pub const FIRE_BUTTON_R = 40;

// ミステリーシップ出現音の専用チャンネル。main.zig が起動時に
// Mix_ReserveChannels(1) で予約する。通常の効果音（-1 指定）は
// このチャンネルを使わないので、後からのフェードアウトや停止が
// 別の音にかかることはない。
pub const MYSTERY_CHANNEL = 0;

pub const MAX_PBULLETS = 24;
pub const MAX_EBULLETS = 64;
pub const MAX_EXPLOSIONS = 80;

const COL_WHITE = c.SDL_Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
const COL_GREEN = c.SDL_Color{ .r = 78, .g = 255, .b = 87, .a = 255 };
const COL_BLUE = c.SDL_Color{ .r = 80, .g = 255, .b = 239, .a = 255 };
const COL_PURPLE = c.SDL_Color{ .r = 203, .g = 0, .b = 255, .a = 255 };
const COL_RED = c.SDL_Color{ .r = 237, .g = 28, .b = 36, .a = 255 };

pub const GameState = enum { title, play, gameover };

/// 1フレーム分の入力。main.zig が SDL イベントとキー状態から作る。
pub const Input = struct {
    quit: bool = false, // ウィンドウを閉じる / ESC の KEYUP（原典 should_exit）
    any_keyup: bool = false, // タイトルで何かキーを離した（原典の開始条件）
    fire_keydown: bool = false, // S の KEYDOWN（発射はイベント駆動）
    keyup_move: bool = false, // A か D の KEYUP（vx を SHIP_VX に戻す）
    held_a: bool = false,
    held_d: bool = false,
};

pub const Ship = struct {
    r: c.SDL_Rect = mkRect(0, 0, 0, 0), // 50x50, 初期 (375, 540)
    vx: i32 = 0,
};

pub const Bullet = struct {
    r: c.SDL_Rect = mkRect(0, 0, 0, 0), // 弾の画像は 5x15
    direction: i32 = 0, // -1 上 / +1 下
    speed: i32 = 0,
    born: u32 = 0,
    active: bool = false,
    enemy: bool = false, // 敵弾か
    flashing: bool = false, // 端で image2 を出している間
};

pub const Enemy = struct {
    r: c.SDL_Rect = mkRect(0, 0, 0, 0), // 40x35
    row: i32 = 0,
    col: i32 = 0,
    image_index: i32 = 0, // アニメーション 0/1
    draw_from: u32 = 0, // この時刻までは描かない（原典の timeOffset の癖）
    alive: bool = false,
};

pub const ExplosionType = enum { enemy, ship, bullet, mystery_score };

pub const Explosion = struct {
    type: ExplosionType = .enemy,
    r: c.SDL_Rect = mkRect(0, 0, 0, 0),
    row: i32 = 0, // .enemy: 色の決定に使う
    score: i32 = 0, // .mystery_score: 表示する得点
    born: u32 = 0,
    active: bool = false,
};

pub const Mystery = struct {
    r: c.SDL_Rect = mkRect(0, 0, 0, 0), // 80x40
    direction: i32 = 0,
    timer: u32 = 0,
    play_sound: bool = false,
    visible: bool = false, // このフレームで動いた＝描く（原典の blit 条件）
    channel: i32 = -1, // mysteryentered の再生チャンネル
};

pub fn mkRect(x: i32, y: i32, w: i32, h: i32) c.SDL_Rect {
    return .{ .x = x, .y = y, .w = w, .h = h };
}

/// 時刻の差（符号つき）。C の (Sint32)(now - since) と同じ包み直し。
fn tdiff(now: u32, since: u32) i32 {
    return @bitCast(now -% since);
}

/// Enemy.load_images の対応: 行ごとの2枚（index 0 が先）
fn enemyTexture(row: i32, index: i32) Tex {
    const table = [FLEET_ROWS][2]Tex{
        .{ .enemy1_2, .enemy1_1 },
        .{ .enemy2_2, .enemy2_1 },
        .{ .enemy2_2, .enemy2_1 },
        .{ .enemy3_1, .enemy3_2 },
        .{ .enemy3_1, .enemy3_2 },
    };
    return table[@intCast(row)][@intCast(index & 1)];
}

/// EnemyExplosion.get_image の対応: 行ごとの色
fn explosionTexture(row: i32) Tex {
    const table = [FLEET_ROWS]Tex{
        .explosionpurple, .explosionblue, .explosionblue,
        .explosiongreen,  .explosiongreen,
    };
    return table[@intCast(row)];
}

fn overlap(a: *const c.SDL_Rect, b: *const c.SDL_Rect) bool {
    return c.SDL_HasIntersection(a, b) == c.SDL_TRUE;
}

pub const Game = struct {
    state: GameState = .title,
    assets: *Assets,
    prng: std.Random.DefaultPrng,

    score: i32 = 0,
    round_num: i32 = 0, // 原典の全域 ROUND_NUM
    enemy_position: i32 = ENEMY_DEFAULT_POSITION, // 原典 enemyPosition
    lives_spare: i32 = 3, // 残機アイコンの数（初期3、被弾で減る）

    ship: Ship = .{},
    ship_alive: bool = true,
    make_new_ship: bool = false,
    ship_timer: u32 = 0,

    enemies: [FLEET_ROWS * FLEET_COLS]Enemy = @splat(.{}),
    ledger: FleetLedger = FleetLedger.init(),
    fleet_direction: i32 = 1,
    move_number: i32 = 15, // 初期値 15（原典の癖）
    left_moves: i32 = 30,
    right_moves: i32 = 30,
    row_counter: i32 = 4, // 原典の全域 ROW_counter、初期値 4
    fleet_timer: u32 = 0,
    fleet_bottom: i32 = 0,

    pbullets: [MAX_PBULLETS]Bullet = @splat(.{}),
    ebullets: [MAX_EBULLETS]Bullet = @splat(.{}),
    mystery: Mystery = .{},
    explosions: [MAX_EXPLOSIONS]Explosion = @splat(.{}),

    blockers: [BLOCKER_COUNT][BARRIER_ROWS][BARRIER_COLS]bool =
        @splat(@splat(@splat(false))),
    ground: [GROUND_CELLS]bool = @splat(false), // 地面（1セル GROUND_CELL_W px）

    shoot_timer: u32 = 0, // 原典 self.timer（敵の発射間隔の基準）
    note_timer: u32 = 0,
    note_index: i32 = 0,
    game_timer: u32 = 0, // 原典 gameTimer（最後の撃墜時刻、遷移の基準）
    game_over_timer: u32 = 0, // 原典 gameOverTimer（F-5 の専用化を踏襲）

    pub fn init(assets: *Assets, seed: u64) Game {
        var g = Game{
            .assets = assets,
            .prng = std.Random.DefaultPrng.init(seed),
        };
        g.shipPlace();
        g.ledger = FleetLedger.init();
        g.buildBlockers();
        return g;
    }

    /// [0, n) の乱数。n は正が前提（呼び出し側で保証）。
    fn randBelow(self: *Game, n: i32) i32 {
        return @intCast(self.prng.random().uintLessThan(usize, @intCast(n)));
    }

    fn enemyAt(self: *Game, row: i32, col: i32) *Enemy {
        return &self.enemies[@intCast(row * FLEET_COLS + col)];
    }

    fn pbulletCount(self: *const Game) i32 {
        var n: i32 = 0;
        for (0..MAX_PBULLETS) |i| {
            if (self.pbullets[i].active) n += 1;
        }
        return n;
    }

    fn explosionCount(self: *const Game) i32 {
        var n: i32 = 0;
        for (0..MAX_EXPLOSIONS) |i| {
            if (self.explosions[i].active) n += 1;
        }
        return n;
    }

    fn spawnExplosion(self: *Game, type_: ExplosionType, r: c.SDL_Rect, row: i32, score: i32, now: u32) void {
        for (0..MAX_EXPLOSIONS) |i| {
            if (!self.explosions[i].active) {
                self.explosions[i] = .{
                    .type = type_,
                    .r = r,
                    .row = row,
                    .score = score,
                    .born = now,
                    .active = true,
                };
                return;
            }
        }
    }

    fn spawnBullet(self: *Game, enemy: bool, x: i32, y: i32, direction: i32, speed: i32, now: u32) void {
        const arr: []Bullet = if (enemy) self.ebullets[0..] else self.pbullets[0..];
        for (arr) |*b| {
            if (!b.active) {
                b.* = .{
                    .r = mkRect(x, y, 5, 15),
                    .direction = direction,
                    .speed = speed,
                    .born = now,
                    .active = true,
                    .enemy = enemy,
                    .flashing = false,
                };
                return;
            }
        }
    }

    /// 原典 make_blockers1（4基分）＋地面。地面は原典では4基分が同じ位置に
    /// 重なって生成されるため、見た目と判定が等価な1本にまとめた。
    fn buildBlockers(self: *Game) void {
        for (0..BLOCKER_COUNT) |b| {
            for (0..BARRIER_ROWS) |r| {
                for (0..BARRIER_COLS) |cc| {
                    self.blockers[b][r][cc] = logic.BARRIER_DESIGN[r][cc] != 0;
                }
            }
        }
        for (0..GROUND_CELLS) |i| {
            self.ground[i] = true;
        }
    }

    fn blockerCellRect(base: i32, row: i32, col: i32) c.SDL_Rect {
        return mkRect(
            BLOCKER_X0 + BLOCKER_PITCH * base + col * BLOCKER_CELL,
            BLOCKERS_POSITION + BLOCKER_Y_OFFSET + row * BLOCKER_CELL,
            BLOCKER_CELL,
            BLOCKER_CELL,
        );
    }

    /// 1基ぶんのセル全体を囲む矩形。弾や敵がここに触れないなら、その基の
    /// セルは1つずつ調べなくてよい（早期除外）。
    fn blockerBaseArea(base: i32) c.SDL_Rect {
        return mkRect(
            BLOCKER_X0 + BLOCKER_PITCH * base,
            BLOCKERS_POSITION + BLOCKER_Y_OFFSET,
            BARRIER_COLS * BLOCKER_CELL,
            BARRIER_ROWS * BLOCKER_CELL,
        );
    }

    /// r に重なるトーチカのセルを全部消す（原典の groupcollide の dokill）。
    /// 1つでも消したら true。
    fn blockersEraseOverlap(self: *Game, r: *const c.SDL_Rect) bool {
        var hit = false;
        for (0..BLOCKER_COUNT) |base| {
            const area = blockerBaseArea(@intCast(base));
            if (!overlap(r, &area))
                continue;
            for (0..BARRIER_ROWS) |row| {
                for (0..BARRIER_COLS) |col| {
                    if (!self.blockers[base][row][col]) continue;
                    const cell = blockerCellRect(@intCast(base), @intCast(row), @intCast(col));
                    if (overlap(r, &cell)) {
                        self.blockers[base][row][col] = false;
                        hit = true;
                    }
                }
            }
        }
        return hit;
    }

    /// r に重なる地面のセルを全部消す。1つでも消したら true。
    fn groundEraseOverlap(self: *Game, r: *const c.SDL_Rect) bool {
        if (r.y + r.h <= GROUND_Y or r.y >= GROUND_Y + GROUND_CELL_W)
            return false;
        var hit = false;
        for (0..GROUND_CELLS) |gi| {
            if (!self.ground[gi]) continue;
            const cell = mkRect(@intCast(gi * GROUND_CELL_W), GROUND_Y, GROUND_CELL_W, GROUND_CELL_W);
            if (overlap(r, &cell)) {
                self.ground[gi] = false;
                hit = true;
            }
        }
        return hit;
    }

    /// 自機を初期位置に置く（開始・ラウンド開始・再出撃で共通）。
    fn shipPlace(self: *Game) void {
        self.ship.r = mkRect(SHIP_START_X, SHIP_START_Y, SHIP_W, SHIP_H);
        self.ship.vx = SHIP_VX;
    }

    /// 原典 reset(score)。残機（lives_spare）はここでは変えない。
    fn resetRound(self: *Game, score: i32, now: u32) void {
        self.score = score;
        self.shipPlace();
        self.ship_alive = true;
        self.make_new_ship = false;
        self.ship_timer = now;

        for (0..FLEET_ROWS) |row| {
            for (0..FLEET_COLS) |col| {
                const e = self.enemyAt(@intCast(row), @intCast(col));
                e.r = mkRect(157 + @as(i32, @intCast(col)) * 50, self.enemy_position + @as(i32, @intCast(row)) * 45, 40, 35);
                e.row = @intCast(row);
                e.col = @intCast(col);
                e.image_index = 0;
                // Enemy の timer = 生成時刻 + (行×-50 + 列×120)。
                // 描画条件は「now - timer > 200」のため、この時刻を過ぎるまで
                // その敵は描かれない（出現がずれる原典の癖）。
                e.draw_from = @bitCast(@as(i32, @bitCast(now)) + (@as(i32, @intCast(row)) * -50 + @as(i32, @intCast(col)) * 120) + 200);
                e.alive = true;
            }
        }
        self.ledger = FleetLedger.init(); // move_time=200, level=700 を含む初期化
        self.row_counter = 4; // 原典の修正に合わせ、開始時に初期値へ戻す
        self.fleet_direction = 1;
        self.move_number = 15;
        self.left_moves = 30;
        self.right_moves = 30;
        // EnemiesGroup の timer は timeOffset = 22000 * ROUND_NUM だけ過去。
        // ラウンド2以降は「追いつきの速進」になる原典の挙動のまま。
        self.fleet_timer = @bitCast(@as(i32, @bitCast(now)) - 22000 * self.round_num);
        self.fleet_bottom = self.enemy_position + (FLEET_ROWS - 1) * 45 + 35;

        self.mystery.r = mkRect(-80, 25, 80, 40);
        self.mystery.direction = 1;
        self.mystery.timer = now;
        self.mystery.play_sound = true;
        self.mystery.visible = false;
        self.mystery.channel = -1;

        self.pbullets = @splat(.{});
        self.ebullets = @splat(.{});
        self.explosions = @splat(.{});

        self.shoot_timer = now;
        self.note_timer = now;
        self.note_index = 0;
        self.game_over_timer = 0;
    }

    /// タイトルでキーを離したときの開始処理（原典 main の mainScreen 分岐）
    fn startGame(self: *Game, now: u32) void {
        self.buildBlockers();
        self.lives_spare = 3;
        self.enemy_position = ENEMY_DEFAULT_POSITION;
        self.resetRound(0, now);
        self.state = .play;
    }

    fn enterGameOver(self: *Game, now: u32) void {
        self.state = .gameover;
        self.game_over_timer = now;
        self.round_num = 0;
        self.enemy_position = ENEMY_DEFAULT_POSITION;
    }

    /// 原典 check_input の発射部分。武器の規則は logic の weaponVolley。
    fn fire(self: *Game, now: u32) void {
        const v = logic.weaponVolley(self.score, self.round_num, self.pbulletCount() == 0, self.ship_alive);
        if (v.mask & logic.VOLLEY_CENTER != 0)
            self.spawnBullet(false, self.ship.r.x + 23, self.ship.r.y + 5, -1, 15, now);
        if (v.mask & logic.VOLLEY_LEFT != 0)
            self.spawnBullet(false, self.ship.r.x + 8, self.ship.r.y + 5, -1, 15, now);
        if (v.mask & logic.VOLLEY_RIGHT != 0)
            self.spawnBullet(false, self.ship.r.x + 38, self.ship.r.y + 5, -1, 15, now);
        // 原典は第1ブロックと第2ブロックで別々に音を鳴らす。ここでは
        // weaponVolley が返した最後の音だけを鳴らす（聞き分けできない差）。
        if (v.sound == 1)
            _ = self.assets.play(.shoot)
        else if (v.sound == 2)
            _ = self.assets.play(.shoot2);
    }

    /// 原典 EnemiesGroup.update
    fn fleetUpdate(self: *Game, now: u32) void {
        const l = &self.ledger;
        if (tdiff(now, self.fleet_timer) <= l.move_time)
            return;

        const max_move = if (self.fleet_direction == 1)
            self.right_moves + l.right_add_move
        else
            self.left_moves + l.left_add_move;
        if (self.move_number >= max_move) {
            self.left_moves = 30 + l.right_add_move;
            self.right_moves = 30 + l.left_add_move;
            self.fleet_direction *= -1;
            self.move_number = 0;
            self.fleet_bottom = 0;
            for (0..FLEET_ROWS * FLEET_COLS) |i| {
                const e = &self.enemies[i];
                if (!e.alive) continue;
                e.r.y += ENEMY_MOVE_DOWN;
                e.image_index ^= 1;
                if (self.fleet_bottom < e.r.y + 35)
                    self.fleet_bottom = e.r.y + 35;
            }
        } else {
            const velocity: i32 = if (self.fleet_direction == 1) 10 else -10;
            if (l.count <= 4) {
                for (0..FLEET_ROWS * FLEET_COLS) |i| {
                    const e = &self.enemies[i];
                    if (!e.alive) continue;
                    e.r.x += velocity;
                    e.image_index ^= 1;
                }
                self.move_number += 1;
            } else {
                // ROW_counter の行だけが動く（波状の動き）
                for (0..FLEET_ROWS * FLEET_COLS) |i| {
                    const e = &self.enemies[i];
                    if (!e.alive) continue;
                    if (e.row == self.row_counter) {
                        e.r.x += velocity;
                        e.image_index ^= 1;
                    }
                }
                const adv = logic.fleetCounterAdvance(self.row_counter, l.min_row, l.max_row);
                self.row_counter = adv.counter;
                if (adv.wrapped)
                    self.move_number += 1;
            }
        }
        self.fleet_timer +%= @intCast(l.move_time);
    }

    /// 原典 Ship.update。加速と「差の1/3ずつ寄る」式をそのまま写した。
    /// 左は Python の負数の床割り算のため切り上げ、右は切り捨てになる。
    fn shipUpdate(self: *Game, in: *const Input) void {
        const s = &self.ship;
        if (in.held_a and s.r.x > 10) {
            s.vx += 1;
            s.r.x -= @divTrunc(s.vx + 2, 3);
            if (s.r.x < 10) s.r.x = 10;
        }
        if (in.held_d and s.r.x < 740) {
            s.vx += 1;
            s.r.x += @divTrunc(s.vx, 3);
            if (s.r.x > 740) s.r.x = 740;
        }
    }

    /// 原典 Bullet.update（自機弾・敵弾共通の式）
    fn bulletsUpdate(self: *Game, now: u32) void {
        updateBulletArray(self.pbullets[0..], now);
        updateBulletArray(self.ebullets[0..], now);
    }

    fn updateBulletArray(arr: []Bullet, now: u32) void {
        for (arr) |*b| {
            if (!b.active) continue;
            b.r.y += b.speed * b.direction;
            if (b.r.y < 35) {
                b.r.y = 35;
                b.flashing = true;
                if (now > b.born +% 700)
                    b.active = false;
            }
            if (b.r.y > 585) {
                b.r.y = 580;
                b.flashing = true;
                if (now > b.born +% 160)
                    b.active = false;
            }
        }
    }

    /// 原典 Mystery.update。描画は「動いたフレームだけ」のため visible で返す。
    fn mysteryUpdate(self: *Game, now: u32) void {
        const m = &self.mystery;
        m.visible = false;
        const passed = now -% m.timer;
        var reset_timer = false;
        if (passed > MYSTERY_INTERVAL_MS) {
            if ((m.r.x < 0 or m.r.x > 800) and m.play_sound) {
                // 専用チャンネル（予約済み）で鳴らす。以後のフェードアウトや
                // 停止はこの音にだけかかる
                m.channel = self.assets.playOn(.mysteryentered, MYSTERY_CHANNEL);
                m.play_sound = false;
            }
            if (m.r.x < 840 and m.direction == 1) {
                if (m.channel >= 0)
                    _ = c.Mix_FadeOutChannel(m.channel, 4000);
                m.r.x += 2;
                m.visible = true;
            } else if (m.r.x > -90 and m.direction == -1) {
                if (m.channel >= 0)
                    _ = c.Mix_FadeOutChannel(m.channel, 4000);
                m.r.x -= 2;
                m.visible = true;
            }
        }
        if (m.r.x > 830) {
            m.play_sound = true;
            m.direction = -1;
            reset_timer = true;
        }
        if (m.r.x < -90) {
            m.play_sound = true;
            m.direction = 1;
            reset_timer = true;
        }
        if (passed > MYSTERY_INTERVAL_MS and reset_timer)
            m.timer = now;
    }

    /// 原典 play_main_music
    fn playMusic(self: *Game, now: u32) void {
        const interval: u32 = @intCast(self.ledger.move_time * 3);
        if (now -% self.note_timer > interval) {
            _ = self.assets.play(@enumFromInt(@intFromEnum(Snd.note0) + @as(u8, @intCast(self.note_index))));
            self.note_index = if (self.note_index < 3) self.note_index + 1 else 0;
            self.note_timer +%= interval;
        }
    }

    /// 原典 make_enemies_shoot
    fn makeEnemiesShoot(self: *Game, now: u32) void {
        if (tdiff(now, self.shoot_timer) > self.ledger.level and self.ledger.count > 0) {
            var row: i32 = 0;
            var col: i32 = 0;
            const pick = self.randBelow(self.ledger.alive_column_count);
            if (self.ledger.bottomEnemy(pick, &row, &col)) {
                const e = self.enemyAt(row, col);
                self.spawnBullet(true, e.r.x + 14, e.r.y + 20, 1, 5, now);
                self.shoot_timer = now;
            }
        }
    }

    /// 原典 create_new_ship
    fn createNewShip(self: *Game, now: u32) void {
        if (self.make_new_ship and tdiff(now, self.ship_timer) > SHIP_RESPAWN_MS) {
            self.shipPlace();
            self.make_new_ship = false;
            self.ship_alive = true;
        }
    }

    // ---- 原典 check_collisions（処理の順番も原典どおり） ----

    fn killEnemyNoScore(self: *Game, e: *Enemy) void {
        e.alive = false;
        self.ledger.kill(e.row, e.col);
        if (self.ledger.count == 0)
            self.fleet_bottom = 0; // 後段の判定が空の集団で誤作動しないように
    }

    /// 弾とトーチカ／地面の衝突（原典の groupcollide 相当）。
    /// 原典は重なったセルを全部消すので、自機弾・敵弾とも同じ規則で
    /// 全セルを消す。敵弾のときは原典どおり bulletExplosion を置く。
    fn bulletsVsBlockers(self: *Game, enemy: bool, now: u32) void {
        const arr: []Bullet = if (enemy) self.ebullets[0..] else self.pbullets[0..];
        for (arr) |*b| {
            if (!b.active) continue;
            var hit = self.blockersEraseOverlap(&b.r);
            if (self.groundEraseOverlap(&b.r))
                hit = true;
            if (hit) {
                b.active = false;
                if (enemy)
                    self.spawnExplosion(.bullet, b.r, 0, 0, now);
            }
        }
    }

    /// (a) 自機弾 × 敵弾
    fn collideBulletsWithBullets(self: *Game) void {
        // 両方消える
        for (0..MAX_PBULLETS) |i| {
            const b = &self.pbullets[i];
            if (!b.active) continue;
            for (0..MAX_EBULLETS) |j| {
                const eb = &self.ebullets[j];
                if (eb.active and overlap(&b.r, &eb.r)) {
                    eb.active = false;
                    b.active = false;
                    break;
                }
            }
        }
    }

    /// (b) 敵 × 自機弾: pygame の groupcollide は行優先の順に処理し、
    /// 弾は最初に当たった敵で消える。その順番で写す。
    fn collideEnemiesWithPbullets(self: *Game, now: u32) void {
        for (0..FLEET_ROWS * FLEET_COLS) |i| {
            const e = &self.enemies[i];
            if (!e.alive) continue;
            for (0..MAX_PBULLETS) |j| {
                const b = &self.pbullets[j];
                if (b.active and overlap(&e.r, &b.r)) {
                    b.active = false;
                    _ = self.assets.play(.invaderkilled);
                    self.score += logic.scoreForRow(e.row);
                    self.spawnExplosion(.enemy, e.r, e.row, 0, now);
                    self.game_timer = now;
                    e.alive = false;
                    self.ledger.kill(e.row, e.col);
                    break;
                }
            }
        }
    }

    /// (c) ミステリーシップ × 自機弾
    fn collideMysteryWithPbullets(self: *Game, now: u32) void {
        for (0..MAX_PBULLETS) |j| {
            const b = &self.pbullets[j];
            if (b.active and overlap(&self.mystery.r, &b.r)) {
                b.active = false;
                if (self.mystery.channel >= 0)
                    _ = c.Mix_HaltChannel(self.mystery.channel);
                _ = self.assets.play(.mysterykilled);
                const gained = logic.mysteryScoreForPick(self.randBelow(4));
                self.score += gained;
                self.spawnExplosion(.mystery_score, self.mystery.r, 5, gained, now);
                // 原典は新しい Mystery を作り直す（次の出現は25秒後）
                self.mystery.r = mkRect(-80, 25, 80, 40);
                self.mystery.direction = 1;
                self.mystery.timer = now;
                self.mystery.play_sound = true;
                self.mystery.visible = false;
                self.mystery.channel = -1;
                break;
            }
        }
    }

    /// (d) 自機 × 敵弾
    fn collideShipWithEbullets(self: *Game, now: u32) void {
        if (self.ship_alive) {
            for (0..MAX_EBULLETS) |j| {
                const eb = &self.ebullets[j];
                if (eb.active and overlap(&self.ship.r, &eb.r)) {
                    eb.active = false;
                    _ = self.assets.play(.shipexplosion);
                    self.spawnExplosion(.ship, self.ship.r, 0, 0, now);
                    if (self.lives_spare > 0) {
                        self.lives_spare -= 1;
                    } else {
                        self.enterGameOver(now);
                    }
                    self.make_new_ship = true;
                    self.ship_timer = now;
                    self.ship_alive = false;
                    break;
                }
            }
        }
    }

    /// (e) 敵集団が自機の高さまで来たとき
    fn collideFleetReach(self: *Game, now: u32) void {
        if (self.state == .play and self.fleet_bottom >= FLEET_REACH_SHIP_Y) {
            if (self.ship_alive) {
                for (0..FLEET_ROWS * FLEET_COLS) |i| {
                    const e = &self.enemies[i];
                    if (e.alive and overlap(&e.r, &self.ship.r)) {
                        self.killEnemyNoScore(e);
                        self.ship_alive = false; // groupcollide で自機も消える
                    }
                }
            }
            if (!self.ship_alive or self.fleet_bottom >= FLEET_GAMEOVER_Y)
                self.enterGameOver(now);
        }
    }

    /// (h) 敵集団がトーチカの高さまで来たら、重なったセルが消える
    fn collideFleetWithBlockers(self: *Game) void {
        if (self.fleet_bottom < BLOCKERS_POSITION)
            return;
        for (0..FLEET_ROWS * FLEET_COLS) |i| {
            const e = &self.enemies[i];
            if (e.alive)
                _ = self.blockersEraseOverlap(&e.r);
        }
    }

    /// 原典 check_collisions。処理の順番も原典どおり。
    fn checkCollisions(self: *Game, now: u32) void {
        self.collideBulletsWithBullets(); // (a)
        self.collideEnemiesWithPbullets(now); // (b)
        self.collideMysteryWithPbullets(now); // (c)
        self.collideShipWithEbullets(now); // (d)
        self.collideFleetReach(now); // (e)
        self.bulletsVsBlockers(false, now); // (f) 自機弾 × トーチカ・地面
        self.bulletsVsBlockers(true, now); // (g) 敵弾 × トーチカ・地面
        self.collideFleetWithBlockers(); // (h)
    }

    /// 爆発の寿命の管理（原典の各 Explosion.update の消滅条件）。
    /// 描画側では状態を書き換えないよう、消滅判定はここ（更新側）に置く。
    /// ラウンド遷移の条件（explosionCount == 0）も更新側だけで決まる。
    fn explosionsUpdate(self: *Game, now: u32) void {
        for (0..MAX_EXPLOSIONS) |i| {
            const ex = &self.explosions[i];
            if (!ex.active) continue;
            const passed = now -% ex.born;
            switch (ex.type) {
                .enemy => {
                    if (passed > 400) ex.active = false;
                },
                .ship => {
                    if (passed > 800) ex.active = false;
                },
                .bullet => {
                    if (passed > 300) ex.active = false;
                },
                .mystery_score => {
                    if (passed > 600) ex.active = false;
                },
            }
        }
    }

    // ---- 状態ごとの更新 ----

    /// 1フレーム分の更新。now は SDL_GetTicks()。戻り値 false で終了。
    pub fn update(self: *Game, in: *const Input, now: u32) bool {
        if (in.quit)
            return false;

        switch (self.state) {
            .title => {
                if (in.any_keyup)
                    self.startGame(now);
            },
            .gameover => {
                // 描画は読むだけなので、爆発の寿命はここでも進める
                self.explosionsUpdate(now);
                if (tdiff(now, self.game_over_timer) > 4000)
                    self.state = .title;
            },
            .play => {
                if (self.ledger.count == 0 and self.explosionCount() == 0) {
                    // ラウンド間の画面（原典 main の startGame 分岐の前半）
                    if (in.keyup_move)
                        self.ship.vx = SHIP_VX;
                    if (in.fire_keydown)
                        self.fire(now);
                    if (tdiff(now, self.game_timer) > NEXT_ROUND_DELAY_MS) {
                        self.round_num += 1;
                        self.buildBlockers();
                        self.enemy_position = ENEMY_DEFAULT_POSITION;
                        self.resetRound(self.score, now);
                        self.game_timer +%= @as(u32, NEXT_ROUND_DELAY_MS);
                    }
                    return true;
                }
                self.playMusic(now);
                if (in.keyup_move)
                    self.ship.vx = SHIP_VX;
                if (in.fire_keydown)
                    self.fire(now);
                self.fleetUpdate(now);
                if (self.ship_alive)
                    self.shipUpdate(in);
                self.bulletsUpdate(now);
                self.mysteryUpdate(now);
                self.explosionsUpdate(now);
                self.checkCollisions(now);
                if (self.state == .play) {
                    self.createNewShip(now);
                    self.makeEnemiesShoot(now);
                }
            },
        }
        return true;
    }

    // ---- 描画 ----

    fn drawTex(self: *Game, ren: *c.SDL_Renderer, tex: Tex, x: i32, y: i32, w: i32, h: i32) void {
        var dst = mkRect(x, y, w, h);
        _ = c.SDL_RenderCopy(ren, self.assets.tex[@intFromEnum(tex)], null, &dst);
    }

    fn drawBlockers(self: *Game, ren: *c.SDL_Renderer) void {
        _ = c.SDL_SetRenderDrawColor(ren, COL_RED.r, COL_RED.g, COL_RED.b, 255);
        for (0..BLOCKER_COUNT) |base| {
            for (0..BARRIER_ROWS) |r| {
                for (0..BARRIER_COLS) |cc| {
                    if (!self.blockers[base][r][cc]) continue;
                    var cell = blockerCellRect(@intCast(base), @intCast(r), @intCast(cc));
                    _ = c.SDL_RenderFillRect(ren, &cell);
                }
            }
        }
        for (0..GROUND_CELLS) |gi| {
            if (!self.ground[gi]) continue;
            var cell = mkRect(@intCast(gi * GROUND_CELL_W), GROUND_Y, GROUND_CELL_W, GROUND_CELL_W);
            _ = c.SDL_RenderFillRect(ren, &cell);
        }
    }

    fn drawHud(self: *Game, ren: *c.SDL_Renderer) void {
        var buf: [32]u8 = undefined;
        self.assets.drawText(ren, 20, "Score", COL_WHITE, 5, 5);
        const score_text = std.fmt.bufPrintSentinel(&buf, "{d}", .{self.score}, 0) catch "0";
        self.assets.drawText(ren, 20, score_text, COL_GREEN, 85, 5);
        self.assets.drawText(ren, 20, "Lives", COL_WHITE, 640, 5);
        var i: i32 = 0;
        while (i < self.lives_spare and i < 3) : (i += 1) {
            self.drawTex(ren, .ship, 715 + 27 * i, 3, 23, 23);
        }
    }

    fn drawExplosions(self: *Game, ren: *c.SDL_Renderer, now: u32) void {
        const ship_steps = [8]Tex{
            .shipexplosion1, .shipexplosion2, .shipexplosion3,
            .shipexplosion2, .shipexplosion1, .shipexplosion3,
            .shipexplosion2, .shipexplosion3,
        };
        for (0..MAX_EXPLOSIONS) |i| {
            const ex = &self.explosions[i];
            if (!ex.active) continue;
            const passed = now -% ex.born;
            // 描画は読むだけ。消滅の判定は explosionsUpdate（更新側）にある
            switch (ex.type) {
                .enemy => {
                    if (passed <= 100)
                        self.drawTex(ren, explosionTexture(ex.row), ex.r.x, ex.r.y, 40, 35)
                    else if (passed <= 200)
                        self.drawTex(ren, explosionTexture(ex.row), ex.r.x - 6, ex.r.y - 6, 50, 45);
                },
                .ship => {
                    if (passed > 800)
                        continue;
                    var step: usize = @intCast(passed / 100);
                    if (step > 7) step = 7;
                    self.drawTex(ren, ship_steps[step], ex.r.x, ex.r.y, 50, 48);
                },
                .bullet => {
                    if (passed <= 300)
                        self.drawTex(ren, .enemylaser1, ex.r.x, ex.r.y, 5, 15);
                },
                .mystery_score => {
                    if (passed <= 200 or (passed > 400 and passed <= 600)) {
                        var buf: [16]u8 = undefined;
                        const text = std.fmt.bufPrintSentinel(&buf, "{d}", .{ex.score}, 0) catch "0";
                        self.assets.drawText(ren, 20, text, COL_WHITE, ex.r.x + 20, ex.r.y + 6);
                    }
                },
            }
        }
    }

    fn drawPlayScene(self: *Game, renderer: *c.SDL_Renderer, now: u32) void {
        self.drawTex(renderer, .background, 0, 0, SCREEN_W, SCREEN_H);
        self.drawBlockers(renderer);
        self.drawHud(renderer);

        if (self.ledger.count == 0 and self.explosionCount() == 0 and self.state == .play) {
            // ラウンド間の画面
            var buf: [16]u8 = undefined;
            self.assets.drawText(renderer, 50, "Next Round", COL_WHITE, 240, 270);
            const text = std.fmt.bufPrintSentinel(&buf, "{d}", .{self.round_num + 2}, 0) catch "0";
            self.assets.drawText(renderer, 50, text, COL_WHITE, 390, 350);
            return;
        }

        var buf: [32]u8 = undefined;
        const round_text = std.fmt.bufPrintSentinel(&buf, "Round {d}", .{self.round_num + 1}, 0) catch "Round";
        self.assets.drawText(renderer, 20, round_text, COL_WHITE, 325, 5);

        if (self.ship_alive)
            self.drawTex(renderer, .ship, self.ship.r.x, self.ship.r.y, SHIP_W, SHIP_H);

        for (0..FLEET_ROWS * FLEET_COLS) |i| {
            const e = &self.enemies[i];
            if (!e.alive) continue;
            if (tdiff(now, e.draw_from) <= 0) continue;
            self.drawTex(renderer, enemyTexture(e.row, e.image_index), e.r.x, e.r.y, 40, 35);
        }

        if (self.mystery.visible)
            self.drawTex(renderer, .mystery, self.mystery.r.x, self.mystery.r.y, 80, 40);

        for (0..MAX_PBULLETS) |i| {
            const b = &self.pbullets[i];
            if (b.active)
                self.drawTex(renderer, if (b.flashing) Tex.laser1 else Tex.laser, b.r.x, b.r.y, 5, 15);
        }
        for (0..MAX_EBULLETS) |i| {
            const b = &self.ebullets[i];
            if (b.active)
                self.drawTex(renderer, if (b.flashing) Tex.enemylaser1 else Tex.enemylaser, b.r.x, b.r.y, 5, 15);
        }

        self.drawExplosions(renderer, now);
    }

    /// 現在の状態を描く。now は update に渡したものと同じ時刻を使う
    /// （更新と描画で時刻がずれないようにするため）。
    pub fn render(self: *Game, renderer: *c.SDL_Renderer, now: u32) void {
        _ = c.SDL_RenderClear(renderer);
        switch (self.state) {
            .title => {
                self.drawTex(renderer, .background, 0, 0, SCREEN_W, SCREEN_H);
                self.assets.drawText(renderer, 50, "Space Invaders", COL_WHITE, 164, 155);
                self.assets.drawText(renderer, 25, "Press any key to continue", COL_WHITE, 201, 225);
                self.drawTex(renderer, .enemy3_1, 318, 270, 40, 40);
                self.drawTex(renderer, .enemy2_2, 318, 320, 40, 40);
                self.drawTex(renderer, .enemy1_2, 318, 370, 40, 40);
                self.drawTex(renderer, .mystery, 299, 420, 80, 40);
                self.assets.drawText(renderer, 25, "   =   10 pts", COL_GREEN, 368, 270);
                self.assets.drawText(renderer, 25, "   =   20 pts", COL_BLUE, 368, 320);
                self.assets.drawText(renderer, 25, "   =   30 pts", COL_PURPLE, 368, 370);
                self.assets.drawText(renderer, 25, "   =   ?????", COL_RED, 368, 420);
            },
            .play => {
                self.drawPlayScene(renderer, now);
            },
            .gameover => {
                self.drawPlayScene(renderer, now);
                const passed = now -% self.game_over_timer;
                var msg: ?[:0]const u8 = null;
                if (passed > 900 and passed < 1000) {
                    msg = "G";
                } else if (passed > 1000 and passed < 1100) {
                    msg = "Ga";
                } else if (passed > 1100 and passed < 1200) {
                    msg = "Gam";
                } else if (passed > 1200 and passed < 1300) {
                    msg = "Game";
                } else if (passed > 1300 and passed < 1400) {
                    msg = "Game O";
                } else if (passed > 1500 and passed < 1600) {
                    msg = "Game Ov";
                } else if (passed > 1600 and passed < 1700) {
                    msg = "Game Ove";
                } else if (passed > 1700 and passed < 1800) {
                    msg = "Game Over";
                }
                if (msg) |m|
                    self.assets.drawText(renderer, 50, m, COL_RED, 250, 270);
            },
        }
        _ = c.SDL_RenderPresent(renderer);
    }
};
