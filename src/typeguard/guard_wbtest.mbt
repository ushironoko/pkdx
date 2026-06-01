// 差分パリティ: 期待値は移植元 Python (.claude/hooks/type-claim-guard.py) を
// oracle として確定済み (extract_claims / TYPE_CHART_LINE / main 判定)。Python
// 削除後もこのテスト群が振る舞い等価の回帰ガードとして残る。

// --- JSONL fixture ビルダー (@json で構築し特殊文字を確実にエスケープ) --------

///|
fn line_user_text(text : String) -> String {
  let msg : Json = { "role": "user".to_json(), "content": text.to_json() }
  let ev : Json = { "type": "user".to_json(), "message": msg }
  ev.stringify()
}

///|
fn line_tool_result(tool_text : String) -> String {
  let block : Json = {
    "type": "tool_result".to_json(),
    "tool_use_id": "t1".to_json(),
    "content": tool_text.to_json(),
    "is_error": false.to_json(),
  }
  let blocks : Array[Json] = [block]
  let msg : Json = { "role": "user".to_json(), "content": blocks.to_json() }
  let ev : Json = { "type": "user".to_json(), "message": msg }
  ev.stringify()
}

///|
fn line_assistant_text(text : String) -> String {
  let block : Json = { "type": "text".to_json(), "text": text.to_json() }
  let blocks : Array[Json] = [block]
  let msg : Json = {
    "role": "assistant".to_json(),
    "content": blocks.to_json(),
  }
  let ev : Json = { "type": "assistant".to_json(), "message": msg }
  ev.stringify()
}

///|
/// 標準ターン: 人間入力 → tool_result(tool_text) → assistant(final_text)。
fn turn_jsonl(tool_text : String, final_text : String) -> String {
  [
    line_user_text("人間の入力"),
    line_tool_result(tool_text),
    line_assistant_text(final_text),
  ].join("\n")
}

///|
fn block_msg(d : GuardDecision) -> String {
  match d {
    Block(m) => m
    Pass => ""
  }
}

///|
fn is_block(d : GuardDecision) -> Bool {
  match d {
    Block(_) => true
    Pass => false
  }
}

// --- scanner 単体 (oracle 値) -----------------------------------------------

///|
test "extract_claims matches python oracle" {
  // 期待値 (oracle): 4倍->[4] 2x->[2] 0.5x->[0.5] 4×->[4] 1.5x->[] 1.3倍->[]
  // 13倍->[] A4x->[4] .5x->[] 4.x->[] 4..0x->[0] 4\n倍->[4] 0.25x->[0.25] 2倍と4x->[2,4]
  @debug.debug_inspect(extract_claims("4倍"), content="[4]")
  @debug.debug_inspect(extract_claims("2x"), content="[2]")
  @debug.debug_inspect(extract_claims("0.5x"), content="[0.5]")
  @debug.debug_inspect(extract_claims("4×"), content="[4]")
  @debug.debug_inspect(extract_claims("1.5x"), content="[]")
  @debug.debug_inspect(extract_claims("1.3倍"), content="[]")
  @debug.debug_inspect(extract_claims("13倍"), content="[]")
  @debug.debug_inspect(extract_claims("A4x"), content="[4]")
  @debug.debug_inspect(extract_claims(".5x"), content="[]")
  @debug.debug_inspect(extract_claims("4.x"), content="[]")
  @debug.debug_inspect(extract_claims("4..0x"), content="[0]")
  @debug.debug_inspect(extract_claims("4\n倍"), content="[4]")
  @debug.debug_inspect(extract_claims("0.25x"), content="[0.25]")
  @debug.debug_inspect(extract_claims("2倍と4x"), content="[2, 4]")
}

///|
test "extract_chart_mults matches python oracle" {
  @debug.debug_inspect(
    extract_chart_mults("こおり -> ドラゴン/ひこう: 4x"),
    content="[4]",
  )
  @debug.debug_inspect(
    extract_chart_mults("a -> b: 2x\nc -> d: 2x"),
    content="[2]",
  )
  @debug.debug_inspect(extract_chart_mults("no arrow here"), content="[]")
  @debug.debug_inspect(extract_chart_mults("x -> y: 4×"), content="[]")
  @debug.debug_inspect(
    extract_chart_mults("-> A: 2x -> B: 0.5x"),
    content="[2, 0.5]",
  )
  @debug.debug_inspect(
    extract_chart_mults("->\n  ほのお: 2x"),
    content="[2]",
  )
  @debug.debug_inspect(extract_chart_mults("-> X: 2x\r\n"), content="[2]")
  @debug.debug_inspect(extract_chart_mults("-> X:\t2x"), content="[2]")
  @debug.debug_inspect(extract_chart_mults("-> : 2x"), content="[2]")
  @debug.debug_inspect(extract_chart_mults("->   : 2x"), content="[2]")
  @debug.debug_inspect(extract_chart_mults("-> word\n: 2x"), content="[]")
  @debug.debug_inspect(
    extract_chart_mults("みず -> ほのお: 0.5x"),
    content="[0.5]",
  )
}

///|
test "fmt_mult matches python {:g}x" {
  inspect(fmt_mult(0.0), content="0x")
  inspect(fmt_mult(0.25), content="0.25x")
  inspect(fmt_mult(0.5), content="0.5x")
  inspect(fmt_mult(1.0), content="1x")
  inspect(fmt_mult(2.0), content="2x")
  inspect(fmt_mult(4.0), content="4x")
}

// --- evaluate 境界ケース ----------------------------------------------------

///|
test "evaluate: chart 2x backs claim 2x -> Pass" {
  @debug.debug_inspect(
    evaluate(turn_jsonl("ほのお -> みず: 2x", "これは2倍")),
    content="Pass",
  )
}

///|
test "evaluate: chart 2x, claim 4倍 unsupported -> Block" {
  let d = evaluate(turn_jsonl("ほのお -> みず: 2x", "これは4倍だ"))
  assert_true(is_block(d))
  assert_true(block_msg(d).contains("4x"))
}

///|
test "evaluate: no damage context (no chart, no damages marker) -> Pass" {
  @debug.debug_inspect(
    evaluate(
      turn_jsonl("ただのテキスト出力", "これは4倍だと思う"),
    ),
    content="Pass",
  )
}

///|
test "evaluate: damages marker, empty chart, claim 2x -> Block (full message)" {
  // 唯一の全文ピン: fmt_mult (2x) / chart 空フォールバック (なし) / 文面・順序を固定。
  let d = evaluate(
    turn_jsonl(
      "ダメージ計算: {\"damages\":[10,20,30]}", "およそ2倍のダメージ",
    ),
  )
  let expected =
    #|タイプ相性の捏造ガード: 最終応答に type-chart 出力で裏付けられない倍率の主張があります。
    #|  応答中の未裏付け倍率: 2x
    #|  このターンの type-chart 実出力: (なし)
    #|対処: 当該タイプの組み合わせに対し `pkdx type-chart <技タイプ> <防御タイプ(,区切り)>` を
    #|実行し、その出力倍率のみを使って記述を訂正してください。type-chart で確認できない倍率や
    #|倍率に基づく相性評価をユーザーへ提示してはいけません (CLAUDE.md #5)。
    #|
  assert_eq(block_msg(d), expected)
}

///|
test "evaluate: set difference direction (chart 2x/0.5x, claims 2x/4x) -> only 4x unsupported" {
  let d = evaluate(
    turn_jsonl("ほ -> A: 2x\nほ -> B: 0.5x", "2倍と4倍が混在"),
  )
  assert_true(is_block(d))
  let m = block_msg(d)
  assert_true(m.contains("未裏付け倍率: 4x\n"))
  assert_true(!m.contains("未裏付け倍率: 2x"))
}

///|
test "evaluate: 倍/× asymmetry — chart ASCII 4x backs claim 4× -> Pass" {
  @debug.debug_inspect(
    evaluate(turn_jsonl("ほ -> み: 4x", "これは4×だ")),
    content="Pass",
  )
}

///|
test "evaluate: 倍/× asymmetry — chart text has only 4× (no damages) -> Pass" {
  @debug.debug_inspect(
    evaluate(turn_jsonl("補正は4×という記述", "これは4倍だ")),
    content="Pass",
  )
}

///|
test "evaluate: multiple tool_result events joined across the turn -> Block" {
  let t = [
    line_user_text("人間の入力"),
    line_tool_result("ほ -> み: 2x"),
    line_tool_result("ダメージ: {\"damages\":[1,2]}"),
    line_assistant_text("結論は4倍"),
  ].join("\n")
  let d = evaluate(t)
  assert_true(is_block(d))
  assert_true(block_msg(d).contains("4x"))
}

///|
test "evaluate: final_text = last non-empty assistant text (not first/concat)" {
  let t = [
    line_user_text("人間の入力"),
    line_tool_result("ほ -> み: 2x"),
    line_assistant_text("最初の見立ては4倍"),
    line_assistant_text("最終的には2倍"),
  ].join("\n")
  // last non-empty = "...2倍" -> supported by chart 2x -> Pass (4倍 in earlier text ignored)
  @debug.debug_inspect(evaluate(t), content="Pass")
}

///|
test "evaluate: trailing whitespace-only assistant text does not clobber final_text" {
  let t = [
    line_user_text("人間の入力"),
    line_tool_result("ほ -> み: 2x"),
    line_assistant_text("これは4倍"),
    line_assistant_text("   \n  "),
  ].join("\n")
  let d = evaluate(t)
  assert_true(is_block(d))
  assert_true(block_msg(d).contains("4x"))
}

///|
test "evaluate: only the last human turn is considered" {
  let t = [
    line_user_text("古いターン"),
    line_tool_result("ほ -> み: 4x"),
    line_assistant_text("過去の4倍"),
    line_user_text("新しいターン"),
    line_tool_result("ほ -> み: 2x"),
    line_assistant_text("今回は2倍"),
  ].join("\n")
  // old turn's 4倍 must be ignored; new turn chart 2x backs claim 2x
  @debug.debug_inspect(evaluate(t), content="Pass")
}

///|
test "evaluate: tool_result-only user event is NOT a turn boundary" {
  // human input, then chart 2x tool_result, then a SECOND tool_result-only user
  // event (damages), then assistant claim. If the 2nd tool_result reset the turn,
  // tool_text would be empty -> Pass. Block proves the prior chart still counts.
  let t = [
    line_user_text("人間の入力"),
    line_tool_result("ほ -> み: 2x"),
    line_tool_result("ダメージ: {\"damages\":[5]}"),
    line_assistant_text("これは4倍だ"),
  ].join("\n")
  let d = evaluate(t)
  assert_true(is_block(d))
  assert_true(block_msg(d).contains("4x"))
}

///|
test "evaluate: malformed JSONL line -> fail-open Pass" {
  let t = turn_jsonl("ほ -> み: 2x", "これは4倍だ") +
    "\n{ broken json line"
  @debug.debug_inspect(evaluate(t), content="Pass")
}

// --- decide fail-open 分岐 (reader 注入で実 FS/実 exit なし) -----------------

///|
fn const_reader(text : String) -> (String) -> String? {
  fn(_p) { Some(text) }
}

///|
test "decide: stop_hook_active re-entry -> Pass (does not read transcript)" {
  let blocking = turn_jsonl("ほ -> み: 2x", "これは4倍だ")
  let payload = "{\"stop_hook_active\": true, \"transcript_path\": \"x\"}"
  @debug.debug_inspect(decide(payload, const_reader(blocking)), content="Pass")
}

///|
test "decide: missing transcript_path -> Pass" {
  @debug.debug_inspect(decide("{}", const_reader("ignored")), content="Pass")
}

///|
test "decide: reader returns None (unreadable transcript) -> Pass" {
  let payload = "{\"transcript_path\": \"x\"}"
  @debug.debug_inspect(decide(payload, fn(_p) { None }), content="Pass")
}

///|
test "decide: empty / malformed payload -> Pass" {
  @debug.debug_inspect(decide("", const_reader("ignored")), content="Pass")
  @debug.debug_inspect(
    decide("not json", const_reader("ignored")),
    content="Pass",
  )
}

///|
test "decide: valid payload + blocking transcript -> Block" {
  let blocking = turn_jsonl("ほ -> み: 2x", "これは4倍だ")
  let payload = "{\"transcript_path\": \"x\"}"
  let d = decide(payload, const_reader(blocking))
  assert_true(is_block(d))
  assert_true(block_msg(d).contains("4x"))
}
