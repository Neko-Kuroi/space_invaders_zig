//! logic.zig - 画面に依存しない純ロジック（C版 logic.c の Zig 化）
//!
//! 敵の台帳（原典 EnemiesGroup の kill / update_speed / random_bottom）、
//! 得点表（calculate_score）、発射の規則（check_input の分岐）を、
//! SDL に触れず単体テストできる形に切り出したもの。
//! 規則の出典は原典 spaceinvaders.py の各関数で、C版と同一。

pub const FLEET_ROWS = 5;
pub const FLEET_COLS = 10;

pub const FleetLedger = struct {
    alive: [FLEET_ROWS][FLEET_COLS]bool,
    count: i32, // 生きている敵の総数
    column_alive: [FLEET_COLS]bool, // 列に1体でも残っているか
    alive_column_count: i32,
    left_alive_column: i32, // 原典 _leftAliveColumn
    right_alive_column: i32, // 原典 _rightAliveColumn
    left_add_move: i32, // 原典 leftAddMove
    right_add_move: i32, // 原典 rightAddMove
    min_row: i32, // 原典 minRow
    max_row: i32, // 原典 maxRow
    move_time: i32, // 敵集団の移動間隔 ms（原典 moveTime）
    level: i32, // 敵の発射間隔 ms（原典の全域 LEVEL）

    /// 原典の EnemiesGroup 生成直後の状態にする。move_time=200, level=700 は
    /// 原典の初期値（Enemy の生成で LEVEL=700 に戻される癖を含む）。
    pub fn init() FleetLedger {
        var l: FleetLedger = undefined;
        for (0..FLEET_ROWS) |r| {
            for (0..FLEET_COLS) |c| {
                l.alive[r][c] = true;
            }
        }
        l.count = FLEET_ROWS * FLEET_COLS;
        for (0..FLEET_COLS) |c| {
            l.column_alive[c] = true;
        }
        l.alive_column_count = FLEET_COLS;
        l.left_alive_column = 0;
        l.right_alive_column = FLEET_COLS - 1;
        l.left_add_move = 0;
        l.right_add_move = 0;
        l.min_row = 0;
        l.max_row = 4;
        l.move_time = 200;
        l.level = 700;
        return l;
    }

    pub fn columnDead(self: *const FleetLedger, col: i32) bool {
        if (col < 0 or col >= FLEET_COLS)
            return true; // 原典では到達しない経路の安全側
        return !self.column_alive[@intCast(col)];
    }

    /// 原典 update_speed()。残数で move_time と level が変わる表と、
    /// minRow / maxRow の再計算。0体では早期 return（修正済み原典の形）。
    fn updateSpeed(self: *FleetLedger) void {
        if (self.count == 0)
            return;

        var minimum: i32 = 5;
        var maximum: i32 = 0;
        for (0..FLEET_ROWS) |r| {
            for (0..FLEET_COLS) |c| {
                if (self.alive[r][c]) {
                    const ri: i32 = @intCast(r);
                    if (ri < minimum) minimum = ri;
                    if (ri > maximum) maximum = ri;
                }
            }
        }
        self.min_row = minimum;
        self.max_row = maximum;

        if (self.count == 1) {
            self.move_time = 2;
            self.level = 350;
        } else if (self.count == 2) {
            self.move_time = 40;
        } else if (self.count == 3) {
            self.move_time = 60;
        } else if (self.count == 4) {
            self.move_time = 60;
        } else if (self.count <= 10) {
            self.move_time = 40;
        } else if (self.count <= 15) {
            self.move_time = 80;
        } else if (self.count <= 20) {
            self.move_time = 90;
        } else if (self.count <= 30) {
            self.move_time = 100;
        } else if (self.count <= 40) {
            self.move_time = 110;
            self.level = 400;
        }
        // 41体以上では原典も何も変えない（初期値 200 / 700 が残る）
    }

    /// 敵を1体倒したときの台帳更新。原典 EnemiesGroup.kill() +
    /// remove_internal 経由の update_speed() を合わせたもの。
    /// 既に死んでいるセルでも安全。
    pub fn kill(self: *FleetLedger, row: i32, col: i32) void {
        if (row < 0 or row >= FLEET_ROWS or col < 0 or col >= FLEET_COLS)
            return;
        const r: usize = @intCast(row);
        const c: usize = @intCast(col);
        if (!self.alive[r][c])
            return;
        self.alive[r][c] = false;
        self.count -= 1;

        // 列が全滅したか
        var col_dead = true;
        for (0..FLEET_ROWS) |rr| {
            if (self.alive[rr][c]) {
                col_dead = false;
                break;
            }
        }
        if (col_dead and self.column_alive[c]) {
            self.column_alive[c] = false;
            self.alive_column_count -= 1;
        }

        // 原典 kill(): 端の列が全滅したら、生きている端までずらしながら
        // 反対側の移動回数に 5 ずつ加える。右端の判定が先（elif でない方）。
        if (col == self.right_alive_column) {
            var dead = col_dead;
            while (self.right_alive_column > 0 and dead) {
                self.right_alive_column -= 1;
                self.right_add_move += 5;
                dead = self.columnDead(self.right_alive_column);
            }
        } else if (col == self.left_alive_column) {
            var dead = col_dead;
            while (self.left_alive_column < FLEET_COLS and dead) {
                self.left_alive_column += 1;
                self.left_add_move += 5;
                dead = self.columnDead(self.left_alive_column);
            }
        }

        self.updateSpeed();
    }

    /// 原典 random_bottom() の選択部分。
    /// pick は [0, alive_column_count) の乱数。生きている列を小さい順に
    /// 数えて pick 番目の列を選び、その列の一番下（最大の行）の敵を返す。
    /// 敵が1体もいなければ false。
    pub fn bottomEnemy(self: *const FleetLedger, pick: i32, out_row: *i32, out_col: *i32) bool {
        if (self.alive_column_count == 0 or pick < 0 or pick >= self.alive_column_count)
            return false;
        var seen: i32 = -1;
        for (0..FLEET_COLS) |c| {
            if (!self.column_alive[c])
                continue;
            seen += 1;
            if (seen == pick) {
                var r: i32 = FLEET_ROWS - 1;
                while (r >= 0) : (r -= 1) {
                    if (self.alive[@intCast(r)][c]) {
                        out_row.* = r;
                        out_col.* = @intCast(c);
                        return true;
                    }
                }
            }
        }
        return false;
    }
};

/// 得点表。row は 0..4（ミステリーシップは mysteryScoreForPick で別扱い）。
pub fn scoreForRow(row: i32) i32 {
    const scores = [FLEET_ROWS]i32{ 30, 20, 20, 10, 10 };
    if (row < 0 or row >= FLEET_ROWS)
        return 0;
    return scores[@intCast(row)];
}

/// ミステリーシップの得点 {50, 100, 150, 300}。pick は [0,4) の乱数。
pub fn mysteryScoreForPick(pick: i32) i32 {
    const scores = [4]i32{ 50, 100, 150, 300 };
    if (pick < 0 or pick >= 4)
        return 0;
    return scores[@intCast(pick)];
}

pub const VOLLEY_CENTER: u8 = 1;
pub const VOLLEY_LEFT: u8 = 2;
pub const VOLLEY_RIGHT: u8 = 4;

pub const Volley = struct {
    mask: u8, // 撃つ弾のビットマスク（VOLLEY_*）
    sound: u8, // 鳴らす音: 0=なし, 1=shoot, 2=shoot2
};

/// 発射の規則（原典 check_input の分岐そのまま）。
/// 原典の癖: ラウンド6以上では、弾が残っていても3発が追加で撃たれる。
pub fn weaponVolley(score: i32, round_num: i32, bullets_empty: bool, ship_alive: bool) Volley {
    var volley: u8 = 0;
    var sound: u8 = 0;
    if (bullets_empty and ship_alive) {
        if (score <= 1990) {
            volley = VOLLEY_CENTER;
            sound = 1;
        } else if (score < 3500) {
            volley = VOLLEY_LEFT | VOLLEY_RIGHT;
            sound = 2;
        } else {
            volley = VOLLEY_CENTER | VOLLEY_LEFT | VOLLEY_RIGHT;
            sound = 2;
        }
    }
    if (round_num >= 6 and ship_alive) {
        volley |= VOLLEY_CENTER | VOLLEY_LEFT | VOLLEY_RIGHT;
        sound = 2;
    }
    return .{ .mask = volley, .sound = sound };
}

pub const Advance = struct {
    counter: i32,
    wrapped: bool,
};

/// 敵集団の波状移動で ROW_counter を1つ進める規則。
/// counter を -1 し、min_row-1 以下になったら max_row に包み直して
/// wrapped を真にする（moveNumber の加算は呼び出し側の仕事）。
/// 包み直しの条件は、原典の修正（一致判定 == から <= へ）を反映したもの。
/// 一致だけだと、上の行が全滅して min_row が上がったときにカウンタが
/// 条件を飛び越え、敵集団が止まってしまう。
pub fn fleetCounterAdvance(counter: i32, min_row: i32, max_row: i32) Advance {
    const next = counter - 1;
    if (next <= min_row - 1) {
        return .{ .counter = max_row, .wrapped = true };
    }
    return .{ .counter = next, .wrapped = false };
}

/// トーチカの設計表（原典 make_blockers1 の barrierDesign）。
/// 16行×26列、先頭行は空。1 のセルに 3x3 のブロックが置かれる。
/// 1基あたり318セル（原典で実測）。
pub const BARRIER_ROWS = 16;
pub const BARRIER_COLS = 26;

pub const BARRIER_DESIGN: [BARRIER_ROWS][BARRIER_COLS]u8 = .{
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0 },
    .{ 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0 },
    .{ 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0 },
    .{ 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0 },
    .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
    .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
    .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
    .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
    .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
    .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
    .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
    .{ 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1 },
    .{ 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1 },
    .{ 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1 },
    .{ 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1 },
};

/// 1基あたりのブロック数（原典では4基で 1272 個、地面 800 個と合わせて 2072）。
pub fn barrierCellCount() i32 {
    var n: i32 = 0;
    for (0..BARRIER_ROWS) |r| {
        for (0..BARRIER_COLS) |c| {
            if (BARRIER_DESIGN[r][c] != 0)
                n += 1;
        }
    }
    return n;
}
