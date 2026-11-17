# Space Invaders Zig 版

C版（SDL2）を正本として、同じ仕様のゲームを Zig で書き直したもの。
C版・C++版と並べて言語ごとの書き方を比べる研究の一環。

## 必要なもの

- Zig **0.17.1**（版を固定している。上げると書き直しが必要になり得る）
- SDL2 の開発ライブラリ: SDL2 / SDL2_image / SDL2_mixer / SDL2_ttf

## ビルドと実行

```
zig build
```

実行ファイルは `zig-out/bin/space_invaders` にできる。
素材（images/ sounds/ fonts/）は実行ファイルのある場所から読むので、
実行ファイルと同じフォルダに素材を置くこと
（このフォルダ直下にコピーして実行するのが簡単）。

SDL の開発ファイルが標準の場所に無い環境では、展開ツリーの場所を渡せる
（ツリーの下に usr/include と usr/lib/<arch> がある形）:

```
zig build -Dsdl-root=<SDL の展開ツリー>
```

## テスト

```
zig build test
```

- `tests/test_logic.zig`: SDL に触れない純ロジックの単体テスト
  （C版の 67 件と 1 対 1）
- `tests/test_replay.zig`: 固定の種＋合成入力＋手動時計で 600 フレーム
  回す通しテスト

画面なしで動作だけ確認したいときは、環境変数で合成入力のスモークが使える:

```
SI_SMOKE_FRAMES=600 ./space_invaders
```

## 操作（デスクトップ）

- 開始: 何かキーを離す
- 移動: A / D（押しっぱなしで加速）
- 発射: S
- 終了: ESC / ウィンドウを閉じる

## 構成

| ファイル | 役割 |
|---|---|
| `src/logic.zig` | SDL に触れない純ロジック（敵の台帳・得点表・発射規則） |
| `src/assets.zig` | 画像・音・フォントの読み込みと文字描画 |
| `src/game.zig` | ゲームの状態と進行、描画 |
| `src/main.zig` | SDL 初期化、入力の変換、メインループ |
| `src/sdl.zig` | SDL バインディング（zig translate-c で自動生成。同梱） |

`src/sdl.zig` は Zig 0.17.1 の `zig translate-c` で SDL 2.30.0 系の
ヘッダから生成したもの。手で直さないこと。SDL の版を上げるときは
再生成する。
