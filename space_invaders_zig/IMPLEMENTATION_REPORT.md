# Space Invaders Zig 版 実施報告書

実施日: 2026-11-16
計画書: PLAN.md（未決事項4件はすべて推奨どおりで承認）

## 1. 成果物

`~/workspace/space_invaders_zig/`（zip: `~/workspace/space_invaders_zig.zip`）

| ファイル | 行数 | 対応する C版 |
|---|---|---|
| src/logic.zig | 277 | logic.c/h |
| src/assets.zig | 192 | assets.c/h |
| src/game.zig | 1,008 | game.c/h |
| src/main.zig | 192 | main.c |
| src/sdl.zig | 44,305 | （自動生成のバインディング） |
| tests/test_logic.zig | 183 | test_logic.c（67件と1対1） |
| tests/test_replay.zig | 108 | C++版 test_replay.cpp の方式 |
| build.zig | 100 | Makefile の代わり |

手書き分は計 1,669 行（C版は 1,848 行）。素材31件は C版から複写。

## 2. 計画どおりに決めた点

- **Zig は 0.17.1 に固定**。ビルドは `zig build` / `zig build test`
- **バインディングは同梱**（未決1・案A）: `zig translate-c` で
  SDL2 本体＋image＋mixer＋ttf のヘッダ（2.30.0 系）から生成した
  `src/sdl.zig` を固定で使う。再生成は SDL の版を上げるときだけ
- **エラーは error union**（未決2・案A）: Assets.load が失敗時に
  理由を標準エラーへ出して error.LoadFailed を返す。途中で読み込んだ分は
  errdefer で解放する。main 側の初期化の後始末は、C版の goto done と
  同じ範囲を defer＋済みフラグで守る
- **乱数は DefaultPrng に固定**（未決3）: Game が種を受け取って保持し、
  randBelow は std.Random の uintLessThan を使う。通常起動の種は
  PerformanceCounter と GetTicks の混合
- **replay テストを作った**（未決4）: 固定種 12345＋合成入力＋
  16ms 手動時計で 600 フレーム。固定値は score=20 / 敵48 / 残機1 /
  自機 x=344 / fleet_bottom=290 / トーチカ 1250 / 地面 188 /
  move_number=24 / row_counter=2 / 自機は被弾直後。
  C++版の固定値（score=40 / 敵46）とは乱数の系が違うため一致しない

## 3. Zig 化で変えた表現（規則は同一）

- 後始末は `defer`（テクスチャ・フォント・SDL の終了処理）
- 定数は `const`、状態は enum、データは構造体＋メソッド
- 時刻の差は包み直し減算（`-%`）＋符号変換で C の (Sint32) キャストと一致
- 文字列の整形は std.fmt（bufPrintSentinel）
- 配列の初期化は @splat（後述の言語事情）

## 4. 実装中に分かった Zig 0.17.1 の事情

- `@cImport` は廃止済み（考察どおり）。translate-c の生成物は
  C の直訳で、定数は素の名前、関数は extern fn として使える
- C の `||` / `&&` は使えず `or` / `and` を書く
- 配列の繰り返し演算子 `**` は、リテラルの直後では字句解析の
  都合で使えなかった（`*` の空白の対称性エラー）。@splat で代用した
- 標準ライブラリの API が版で大きく動いている:
  build.zig では include パスやリンク指定が Compile から Module へ移動、
  std.fmt.bufPrintZ は bufPrintSentinel（引数の順序も違う）へ、
  std.posix.getenv と std.time.timestamp は削除されていた。
  いずれも 0.17.1 の形に合わせて実装済み

## 5. 検証（こちらで実施）

- `zig build`: 警告・エラーなしで実行ファイルが生成
- `zig build test`: logic 67件相当＋replay の固定値チェック全件合格
- スモーク（ダミードライバ）: 600 フレーム（state=Play）と
  7,200 フレーム（ゲームオーバー→タイトル復帰まで一周）を確認
- 音声なし起動（SDL_AUDIODRIVER=nonexistent）: 警告を出して完走
- zip を展開したまっさらなツリーで、ビルド＋テスト＋スモークを再確認

## 6. 未確認（Satoru 側）

- 手元でのビルド（Zig 0.17.1 の用意を含む）と実画面・操作感・音
- Android 版は今回の範囲外（計画書第8節どおり、別途計画）
