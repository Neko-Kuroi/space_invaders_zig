//! test_logic.zig - logic.zig の単体テスト（C版 test_logic.c の移植）。
//! 期待値は原典 spaceinvaders.py の実装と実測（トーチカ 318 セル/基など）から。
//! C版の CHECK 67 件と 1 対 1 に対応する。

const std = @import("std");
const logic = @import("logic");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const FleetLedger = logic.FleetLedger;
const FLEET_ROWS = logic.FLEET_ROWS;
const FLEET_COLS = logic.FLEET_COLS;

fn killColumn(l: *FleetLedger, col: i32) void {
    for (0..FLEET_ROWS) |r| {
        l.kill(@intCast(r), col);
    }
}

fn killDownTo(l: *FleetLedger, target: i32) void {
    var c: i32 = 0;
    while (c < FLEET_COLS and l.count > target) : (c += 1) {
        var r: i32 = 0;
        while (r < FLEET_ROWS and l.count > target) : (r += 1) {
            l.kill(r, c);
        }
    }
}

test "init and scores" {
    const l = FleetLedger.init();
    try expectEqual(50, l.count);
    try expectEqual(200, l.move_time);
    try expectEqual(700, l.level);
    try expectEqual(0, l.left_alive_column);
    try expectEqual(9, l.right_alive_column);
    try expectEqual(10, l.alive_column_count);
    try expect(l.min_row == 0 and l.max_row == 4);

    try expectEqual(30, logic.scoreForRow(0));
    try expectEqual(20, logic.scoreForRow(1));
    try expectEqual(20, logic.scoreForRow(2));
    try expectEqual(10, logic.scoreForRow(3));
    try expectEqual(10, logic.scoreForRow(4));
    try expectEqual(50, logic.mysteryScoreForPick(0));
    try expectEqual(100, logic.mysteryScoreForPick(1));
    try expectEqual(150, logic.mysteryScoreForPick(2));
    try expectEqual(300, logic.mysteryScoreForPick(3));

    try expectEqual(318, logic.barrierCellCount());
}

test "kill bookkeeping" {
    var l = FleetLedger.init();

    // 中央の1体: 台帳の端や速度は変わらない
    l.kill(2, 5);
    try expectEqual(49, l.count);
    try expectEqual(200, l.move_time); // 41体以上は表に無い
    try expectEqual(700, l.level);
    try expectEqual(10, l.alive_column_count);

    // 二重に倒しても数えない
    l.kill(2, 5);
    try expectEqual(49, l.count);

    // 右端の列を全滅: 右端がずれ、加算が入る
    var l2 = FleetLedger.init();
    killColumn(&l2, 9);
    try expectEqual(45, l2.count);
    try expectEqual(8, l2.right_alive_column);
    try expectEqual(5, l2.right_add_move);
    try expectEqual(9, l2.alive_column_count);
    try expect(l2.columnDead(9));
    try expect(!l2.columnDead(8));
    killColumn(&l2, 8);
    try expectEqual(7, l2.right_alive_column);
    try expectEqual(10, l2.right_add_move);

    // 左端の列を全滅
    var l3 = FleetLedger.init();
    killColumn(&l3, 0);
    try expectEqual(1, l3.left_alive_column);
    try expectEqual(5, l3.left_add_move);
    try expectEqual(9, l3.alive_column_count);
}

test "speed table" {
    var l = FleetLedger.init();
    killDownTo(&l, 41);
    try expect(l.move_time == 200 and l.level == 700);
    killDownTo(&l, 40);
    try expect(l.move_time == 110 and l.level == 400);
    killDownTo(&l, 30);
    try expectEqual(100, l.move_time);
    killDownTo(&l, 20);
    try expectEqual(90, l.move_time);
    killDownTo(&l, 15);
    try expectEqual(80, l.move_time);
    killDownTo(&l, 10);
    try expectEqual(40, l.move_time);
    killDownTo(&l, 4);
    try expectEqual(60, l.move_time);
    killDownTo(&l, 3);
    try expectEqual(60, l.move_time);
    killDownTo(&l, 2);
    try expectEqual(40, l.move_time);
    killDownTo(&l, 1);
    try expect(l.move_time == 2 and l.level == 350);
    killDownTo(&l, 0);
    try expectEqual(0, l.count);
}

test "min max row" {
    var l = FleetLedger.init();
    for (0..FLEET_COLS) |c| {
        l.kill(0, @intCast(c));
    }
    try expectEqual(1, l.min_row);
    try expectEqual(4, l.max_row);
    for (0..FLEET_COLS) |c| {
        l.kill(4, @intCast(c));
    }
    try expectEqual(3, l.max_row);
}

test "bottom enemy" {
    var l = FleetLedger.init();
    var row: i32 = -1;
    var col: i32 = -1;
    try expect(l.bottomEnemy(0, &row, &col) and row == 4 and col == 0);
    try expect(l.bottomEnemy(9, &row, &col) and row == 4 and col == 9);
    l.kill(4, 0);
    try expect(l.bottomEnemy(0, &row, &col) and row == 3 and col == 0);
    killColumn(&l, 0);
    try expect(l.bottomEnemy(0, &row, &col) and row == 4 and col == 1);
    killDownTo(&l, 0);
    try expect(!l.bottomEnemy(0, &row, &col));
}

test "weapon volley" {
    var v = logic.weaponVolley(0, 0, true, true);
    try expect(v.mask == logic.VOLLEY_CENTER and v.sound == 1);
    v = logic.weaponVolley(1990, 0, true, true);
    try expect(v.mask == logic.VOLLEY_CENTER and v.sound == 1);
    v = logic.weaponVolley(2000, 0, true, true);
    try expect(v.mask == (logic.VOLLEY_LEFT | logic.VOLLEY_RIGHT) and v.sound == 2);
    v = logic.weaponVolley(3499, 0, true, true);
    try expect(v.mask == (logic.VOLLEY_LEFT | logic.VOLLEY_RIGHT) and v.sound == 2);
    v = logic.weaponVolley(3500, 0, true, true);
    try expect(v.mask == (logic.VOLLEY_CENTER | logic.VOLLEY_LEFT | logic.VOLLEY_RIGHT) and v.sound == 2);
    // 弾が残っていると通常の発射はしない
    v = logic.weaponVolley(0, 0, false, true);
    try expect(v.mask == 0 and v.sound == 0);
    // ラウンド6以上は弾が残っていても3発追加（原典の癖）
    v = logic.weaponVolley(0, 6, false, true);
    try expect(v.mask == (logic.VOLLEY_CENTER | logic.VOLLEY_LEFT | logic.VOLLEY_RIGHT) and v.sound == 2);
    // 自機が居なければ撃てない
    v = logic.weaponVolley(5000, 6, true, false);
    try expect(v.mask == 0 and v.sound == 0);
}

test "counter advance" {
    var a = logic.fleetCounterAdvance(4, 0, 4);
    try expect(a.counter == 3 and !a.wrapped);
    // 一番下の行が動いたあと包む（min_row=0 で 0→-1）
    a = logic.fleetCounterAdvance(0, 0, 4);
    try expect(a.counter == 4 and a.wrapped);
    // 上の行が全滅した直後（min_row=2）: 一番上の行が動いたら包む
    a = logic.fleetCounterAdvance(2, 2, 4);
    try expect(a.counter == 4 and a.wrapped);
    a = logic.fleetCounterAdvance(3, 2, 4);
    try expect(a.counter == 2 and !a.wrapped);
    // 止まるパターンの回帰: カウンタが min_row-1 ちょうど／それ以下でも
    // 包み直して復帰する（旧い == 判定では両方とも止まった）
    a = logic.fleetCounterAdvance(1, 2, 4);
    try expect(a.counter == 4 and a.wrapped);
    a = logic.fleetCounterAdvance(0, 2, 4);
    try expect(a.counter == 4 and a.wrapped);
    // 大きく負に沈んだ持ち越し状態からも1回で復帰する
    a = logic.fleetCounterAdvance(-50, 0, 4);
    try expect(a.counter == 4 and a.wrapped);
}
