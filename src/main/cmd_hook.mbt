///|
/// `pkdx hook ...` — Claude Code hook ハンドラ群。stdin で hook payload を受け取り、
/// 判定結果を exit code で返す。判定ロジックは `@typeguard` (純粋・テスト済み) に委譲し、
/// ここは stdin 読み / file 読み / exit という IO だけを担う薄いシェル。
fn cmd_hook() -> @admiral.CommandDef {
  let name = "hook"
  let description = "Claude Code hook handlers (read hook JSON on stdin)"
  let subs : Array[@admiral.CommandDef] = [
    @admiral.command(
      name="type-guard",
      description="Stop hook: block fabricated type-effectiveness multipliers",
      run=Some(fn(_ctx) { run_type_guard() }),
    ),
  ]
  @admiral.command(
    name~,
    description~,
    subcommands=subs,
    run=Some(parent_help_run(name, description, subs)),
  )
}

///|
/// Stop hook 本体。stdin payload を `@typeguard.decide` に渡し、Block のときだけ
/// stderr にガードメッセージを出して exit 2 で停止をブロックする。それ以外
/// (再入 / ダメ計・相性の文脈外 / transcript 読込失敗 / payload 不正) は素通り
/// (exit 0) — fail-open。ガード自体の不調で作業を止めない方針。
fn run_type_guard() -> Unit {
  let raw = pkdx_read_stdin()
  // transcript 読込は `@db.read_file` (8MB 上限)。8MB 超の巨大 transcript では None →
  // fail-open (Pass)。実 transcript は通常 2MB 程度のため実害は無く、誤ブロックしない
  // 安全側の degradation。移植元 Python は上限無しのため、この点のみ挙動が分岐する。
  match @typeguard.decide(raw, fn(p) { @db.read_file(p) }) {
    @typeguard.Pass => ()
    @typeguard.Block(msg) => {
      pkdx_eprintln(@db.to_c_bytes(msg))
      pkdx_exit(2)
    }
  }
}
