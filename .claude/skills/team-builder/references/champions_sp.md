# Champions SP (Stat Points) システム

**SP は pkdx のデフォルト計算方式。** `--version` 未指定時は Champions SP で計算される。従来の EV/IV 方式は `--version scarlet_violet` 等の deprecated バージョン指定時のみ使用される。

このドキュメントは Pokemon Champions のステータス計算システムを記録する。従来作品の EV/IV とは根本的に異なるため、育成・構築・ダメージ計算で Champions フォーマットを扱う際の一次資料。

## 1. 背景: EV/IV の廃止

従来のポケモンシリーズでは **EV (努力値, 0-252, 合計510)** と **IV (個体値, 0-31)** の2系統でステータスを制御していた。Champions ではこれらが完全に廃止され、**SP (Stat Points)** に一本化された。旧バージョン（scarlet_violet, sword_shield 等）の EV/IV 方式は deprecated として維持されるが、デフォルトでは使用されない。

エージェントが持つ従来作品の EV/IV 知識（「252振り」「A252S252」「個体値V」等）を Champions に直接適用してはならない。

## 2. 計算式

### HP

```
HP = BaseStat + SP + 75
```

### HP 以外

```
Stat = floor((BaseStat + SP + 20) × Nature)
```

Nature 倍率:

| 補正 | 倍率 | 整数演算 |
|------|------|---------|
| 上昇 | 1.1 | × 11 / 10 |
| 無補正 | 1.0 | × 1 / 1 |
| 下降 | 0.9 | × 9 / 10 |

### 制約

| 項目 | 値 |
|------|-----|
| 各ステータス最大 SP | **32** |
| 6ステータス合計上限 | **66** |
| IV | **存在しない** |

## 3. 従来 EV/IV との同値性

最大投資時、従来式と Champions 式は代数的に同値になる:

### 非 HP ステータス

```
従来:     floor((base*2 + 31 + floor(252/4)) / 2 + 5) = base + 47 + 5 = base + 52
Champions: base + 32 + 20 = base + 52
```

### HP

```
従来:     floor((base*2 + 31 + floor(252/4)) / 2) + 60 = base + 47 + 60 = base + 107
Champions: base + 32 + 75 = base + 107
```

つまり SP=32 と EV=252/IV=31 は同じ実数値を生む。差が出るのは非最大投資時のみ。

## 4. SP の「+1 優位」

従来:
- 合計 EV 510 のうち、実効的に使えるのは **508** (252+252+4)
- `floor(EV/4)` 変換により、実効ステータスポイントは **127** (63+63+1)
- 残り 2 EV は端数ロスで消滅

Champions:
- 合計 SP **66** がそのまま実効ステータスポイント
- 従来の 252/252/4 配分は SP では **32/32/1 = 65** で再現可能
- 残り **1 SP** を4番目のステータスに配分できる

### 具体例: ガブリアス いじっぱり

```
従来:     A252/S252/D4  = 508  → HP183 Atk200 Def115 SpA90 SpD106 Spe154
Champions: A32/S32/D1/H1 = 66  → HP184 Atk200 Def115 SpA90 SpD106 Spe154
                                  ^^^^
                                  HP が 1 多い
```

この +1 は構築段階で意識すべき Champions 固有のアドバンテージ。

## 5. 性格補正と SP の関係

性格補正 1.1 倍の場合、SP を 1 増やしたときの実数値変化は通常 +1 だが、`(BaseStat + SP + 20)` が `10n - 1` → `10n` を跨ぐとき（= 結果が 11 の倍数を跨ぐとき）に **+2** になる。

```
例: Spe base=102
  SP=31: (102+31+20) = 153, floor(153 × 1.1) = floor(168.3) = 168
  SP=32: (102+32+20) = 154, floor(154 × 1.1) = floor(169.4) = 169  (+1)

  SP=8:  (102+8+20)  = 130, floor(130 × 1.1) = floor(143.0) = 143
  SP=9:  (102+9+20)  = 131, floor(131 × 1.1) = floor(144.1) = 144  (+1)

  SP=17: (102+17+20) = 139, floor(139 × 1.1) = floor(152.9) = 152
  SP=18: (102+18+20) = 140, floor(140 × 1.1) = floor(154.0) = 154  (+2) ← 10n 境界
```

下降補正 0.9 倍でも同様に、`(BaseStat + SP + 20)` が `10n - 1` → `10n` を跨ぐと変化量が +2 ではなく +0（実数値が変わらない）になることがある。

## 6. HBD 最適化での相違

| 項目 | 従来 | Champions |
|------|------|-----------|
| 予算 | 508 | 66 |
| 各上限 | 252 | 32 |
| ステップ | 4 (EV 4刻み) | 1 (SP 1刻み) |
| brute-force 探索空間 | 64³ = 262,144 | 33³ = 35,937 |
| 計算関数 | `calc_hp_full` / `calc_other_full` | `calc_hp_champions` / `calc_other_champions` |
| 逆算関数 | `ev_for_hp` / `ev_for_non_hp` | `sp_for_hp_champions` / `sp_for_non_hp_champions` |

greedy 勾配法のアルゴリズム自体は同一（bulk_theory.md 参照）。予算・上限・ステップ・計算関数のみが異なる。

## 7. CLI での挙動

`--version champions` 指定時:

- `stat-calc`: `--ev` を SP として解釈（各 0-32, 合計 ≤ 66）。`--iv` は無視
- `stat-reverse`: `reverse_spread_champions` で SP + 性格を逆引き（合計 ≤ 66）
- `damage`: `StatSystem::Champions` で stat 計算を分岐。SP=32 がデフォルト最大投資
- `hbd`: `optimize_hbd_champions` / `optimize_hbd_topn_champions` を使用
- 出力テーブル: "IV"/"EV" 行の代わりに "SP" 行を表示
- JSON: `"stat_system":"champions"` フィールドで判別可能

## 8. 逆算アルゴリズム

Champions の逆算 (`reverse_spread_champions`) は従来 (`reverse_spread`) と同じ per-stat inversion パターン:

1. 各性格について、6ステータスそれぞれの実数値から SP を直接逆算
   - HP: `sp = actual - base - 75`
   - 他: 性格倍率を解除して `sp = raw - base - 20`
2. 全ステ逆算成功 → 合計 ≤ 66 を検証
3. 33^6 のブルートフォースは不要（各ステ独立に解が一意に定まる）
