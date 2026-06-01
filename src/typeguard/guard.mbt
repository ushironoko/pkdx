// 本パッケージは Claude Code transcript JSONL (外部スキーマ) に結合した IO-free
// ロジックであり、ドメイン非依存ではない。`.claude/hooks/type-claim-guard.py`
// (移植元) を仕様とした振る舞い等価実装。IO (stdin/file/exit) は src/main 側の
// 薄いハンドラが担い、ここは「文字列 → 判定」に専念する。

///|
/// Stop hook の判定結果。`Block` はターン停止メッセージを保持する。
pub enum GuardDecision {
  Pass
  Block(String)
} derive(Debug, Eq)

///|
/// stdin で渡る hook payload (`{transcript_path, stop_hook_active}`) の解釈と
/// transcript 読込を `read_transcript` 注入で純粋化したエントリ。fail-open 分岐
/// (再入 / transcript_path 欠如 / 読込失敗 / payload 不正) を実 exit/実 FS なしで
/// テストできるようにするための分離。
pub fn decide(
  payload_json : String,
  read_transcript : (String) -> String?,
) -> GuardDecision {
  let payload = @json.parse(payload_json) catch { _ => return Pass }
  match payload {
    Object(m) => {
      // Stop hook 起因の再入は素通り (無限ループ防止)
      match m.get("stop_hook_active") {
        Some(True) => return Pass
        _ => ()
      }
      let path = match m.get("transcript_path") {
        Some(String(s)) => s
        _ => return Pass
      }
      match read_transcript(path) {
        Some(text) => evaluate(text)
        None => Pass
      }
    }
    _ => Pass
  }
}

///|
/// transcript 全文を受け取り、最終応答中のタイプ相性倍率主張が type-chart の実
/// 出力で裏付けられているか判定する。裏付けの無い倍率があれば `Block`。
/// ダメ計/相性の文脈でない、または倍率主張が無いターンは `Pass`。
pub fn evaluate(transcript_text : String) -> GuardDecision {
  // JSONL を行ごとに parse。空白のみ行はスキップ。いずれかの行で parse に失敗
  // したら当該ターンの判定を諦めて素通り (Python: 例外 → exit 0 と同一)。
  let events : Array[Json] = []
  let parsed = try {
    for line in transcript_text.split("\n") {
      let s = line.to_owned()
      if is_blank(s) {
        continue
      }
      events.push(@json.parse(s))
    }
    true
  } catch {
    _ => false
  }
  if !parsed || events.length() == 0 {
    return Pass
  }

  // 最後の「生ユーザー入力」以降を「このターン」とする。
  let mut start = 0
  for i, ev in events {
    if is_human_turn_start(ev) {
      start = i
    }
  }
  if start + 1 >= events.length() {
    return Pass
  }

  // ターン内の tool 出力テキストと「最後の非空 assistant text」を収集。
  let tool_parts : Array[String] = []
  let mut final_text = ""
  for idx in (start + 1)..<events.length() {
    let ev = events[idx]
    collect_tool_result_text(ev, tool_parts)
    let t = assistant_text(ev)
    if !is_blank(t) {
      final_text = t
    }
  }
  let tool_text = tool_parts.join("\n")

  let chart_mults = extract_chart_mults(tool_text)
  // ダメ計 (damage JSON) も type-chart 行も無ければ相性の文脈ではない。
  let damage_context = tool_text.contains("\"damages\":[") ||
    chart_mults.length() > 0
  if !damage_context {
    return Pass
  }

  let claims = extract_claims(final_text)
  if claims.length() == 0 {
    return Pass
  }

  let unsupported : Array[Double] = []
  for c in claims {
    if !contains_double(chart_mults, c) {
      push_unique(unsupported, c)
    }
  }
  if unsupported.length() == 0 {
    return Pass
  }
  Block(build_message(chart_mults, unsupported))
}

// --- transcript イベントアクセサ ----------------------------------------

///|
fn ev_type(ev : Json) -> String {
  match ev {
    Object(m) =>
      match m.get("type") {
        Some(String(s)) => s
        _ => ""
      }
    _ => ""
  }
}

///|
/// `message.content` を取り出す。string / array いずれもそのまま返す。
fn ev_content(ev : Json) -> Json? {
  match ev {
    Object(m) =>
      match m.get("message") {
        Some(Object(mm)) => mm.get("content")
        _ => None
      }
    _ => None
  }
}

///|
fn block_type(b : Json) -> String {
  match b {
    Object(m) =>
      match m.get("type") {
        Some(String(s)) => s
        _ => ""
      }
    _ => ""
  }
}

///|
/// tool_result ではない生のユーザー入力か (ターン境界の判定)。content が string、
/// もしくは tool_result ブロックを含まない list のとき true。
fn is_human_turn_start(ev : Json) -> Bool {
  if ev_type(ev) != "user" {
    return false
  }
  match ev_content(ev) {
    Some(String(_)) => true
    Some(Array(blocks)) => {
      for b in blocks {
        if block_type(b) == "tool_result" {
          return false
        }
      }
      true
    }
    _ => false
  }
}

///|
fn collect_tool_result_text(ev : Json, sink : Array[String]) -> Unit {
  if ev_type(ev) != "user" {
    return
  }
  match ev_content(ev) {
    Some(Array(blocks)) =>
      for b in blocks {
        if block_type(b) != "tool_result" {
          continue
        }
        match b {
          Object(m) =>
            match m.get("content") {
              Some(String(s)) => sink.push(s)
              Some(Array(items)) =>
                for x in items {
                  if block_type(x) == "text" {
                    match x {
                      Object(mm) =>
                        match mm.get("text") {
                          Some(String(t)) => sink.push(t)
                          _ => ()
                        }
                      _ => ()
                    }
                  }
                }
              _ => ()
            }
          _ => ()
        }
      }
    _ => ()
  }
}

///|
fn assistant_text(ev : Json) -> String {
  if ev_type(ev) != "assistant" {
    return ""
  }
  match ev_content(ev) {
    Some(Array(blocks)) => {
      let sb = StringBuilder::new()
      for b in blocks {
        if block_type(b) == "text" {
          match b {
            Object(m) =>
              match m.get("text") {
                Some(String(t)) =>
                  for c in t {
                    sb.write_char(c)
                  }
                _ => ()
              }
            _ => ()
          }
        }
      }
      sb.to_string()
    }
    _ => ""
  }
}

// --- 文字スキャナ (regex なし、Python regex 挙動を仕様とする) ---------------

///|
/// タイプ相性として実在する倍率か (テラ一致 1.5x / いのちのたま 1.3x 等を除外)。
fn is_valid_mult(d : Double) -> Bool {
  d == 0.0 || d == 0.25 || d == 0.5 || d == 1.0 || d == 2.0 || d == 4.0
}

///|
/// Python `\s` 相当 ([ \t\n\r\f\v])。
fn is_ws(c : Char) -> Bool {
  let n = c.to_int()
  n == 0x20 || n == 0x09 || n == 0x0A || n == 0x0D || n == 0x0B || n == 0x0C
}

///|
fn is_digit(c : Char) -> Bool {
  let n = c.to_int()
  n >= 0x30 && n <= 0x39
}

///|
/// 倍率主張の単位文字: 倍(U+500D) / x / X / ×(U+00D7)。
fn is_claim_unit(c : Char) -> Bool {
  let n = c.to_int()
  n == 0x500D || n == 0x78 || n == 0x58 || n == 0x00D7
}

///|
fn chars_of(s : String) -> Array[Char] {
  let out : Array[Char] = []
  for c in s {
    out.push(c)
  }
  out
}

///|
fn slice_decimal(chars : Array[Char], from : Int, to : Int) -> Double {
  // chars[from..<to] は [0-9]+(\.[0-9]+)? を満たす前提。
  let mut int_part = 0.0
  let mut i = from
  while i < to && is_digit(chars[i]) {
    int_part = int_part * 10.0 + (chars[i].to_int() - 0x30).to_double()
    i = i + 1
  }
  if i < to && chars[i].to_int() == 0x2E {
    i = i + 1
    let mut frac = 0.0
    let mut scale = 1.0
    while i < to && is_digit(chars[i]) {
      frac = frac * 10.0 + (chars[i].to_int() - 0x30).to_double()
      scale = scale * 10.0
      i = i + 1
    }
    int_part + frac / scale
  } else {
    int_part
  }
}

///|
/// `[0-9]+(\.[0-9]+)?` を start (digit 始まり前提) から読み、(値, 終端 index) を返す。
fn lex_number(chars : Array[Char], start : Int) -> (Double, Int) {
  let n = chars.length()
  let mut i = start
  while i < n && is_digit(chars[i]) {
    i = i + 1
  }
  if i < n && chars[i].to_int() == 0x2E && i + 1 < n && is_digit(chars[i + 1]) {
    i = i + 1
    while i < n && is_digit(chars[i]) {
      i = i + 1
    }
  }
  (slice_decimal(chars, start, i), i)
}

///|
/// 最終応答中の倍率主張を抽出。Python `([0-9]+(?:\.[0-9]+)?)\s*倍` と
/// `([0-9]+(?:\.[0-9]+)?)\s*[xX×]` の和集合。VALID_MULTS に含まれる値のみ採用。
fn extract_claims(text : String) -> Array[Double] {
  let chars = chars_of(text)
  let n = chars.length()
  let found : Array[Double] = []
  let mut i = 0
  while i < n {
    if is_digit(chars[i]) {
      let (value, j) = lex_number(chars, i)
      let mut k = j
      while k < n && is_ws(chars[k]) {
        k = k + 1
      }
      if k < n && is_claim_unit(chars[k]) && is_valid_mult(value) {
        push_unique(found, value)
      }
      i = j // 数値末尾へ前進 (非重複)
    } else {
      i = i + 1
    }
  }
  found
}

///|
/// type-chart 出力行から倍率を抽出。Python `->\s*[^\n:]+:\s*([0-9.]+)x`
/// (IGNORECASE) を全文連続走査で再現。チャート側は VALID_MULTS フィルタ無し
/// (出力された倍率をそのまま使う)。`×` は不可 (チャートは ASCII `4x`)。
/// 注: `-> <空白のみ>:` という退化入力では Python のバックトラック一致と分岐し
/// うるが、type-chart 実出力には防御タイプ名が必ず入るため実害はない。
fn extract_chart_mults(text : String) -> Array[Double] {
  let chars = chars_of(text)
  let n = chars.length()
  let found : Array[Double] = []
  let mut i = 0
  while i < n {
    if chars[i].to_int() == 0x2D && i + 1 < n && chars[i + 1].to_int() == 0x3E {
      match try_chart_match(chars, i + 2) {
        Some((value, endidx)) => {
          push_unique(found, value)
          i = endidx
        }
        None => i = i + 2
      }
    } else {
      i = i + 1
    }
  }
  found
}

///|
/// `->` 直後位置から `\s*[^\n:]+:\s*<数値>x` を試行。成功で (値, x の次 index)。
fn try_chart_match(chars : Array[Char], start : Int) -> (Double, Int)? {
  let n = chars.length()
  let mut p = start
  // \s* (改行含む)
  while p < n && is_ws(chars[p]) {
    p = p + 1
  }
  // [^\n:]+ (>=1 文字、改行/コロン以外)
  let seg_start = p
  while p < n && chars[p].to_int() != 0x0A && chars[p].to_int() != 0x3A {
    p = p + 1
  }
  if p >= n || chars[p].to_int() != 0x3A {
    return None // '\n' or 末尾でコロン未到達
  }
  // セグメントが空のとき、Python の `\s*[^\n:]+` は `\s*` をバックトラックさせて
  // 直前の非改行空白 (space/tab 等) を 1 文字のセグメントに充てうる。これを再現:
  // 直前が改行でない空白なら成立、そうでなければ不成立。
  if p == seg_start &&
    !(seg_start > start && chars[seg_start - 1].to_int() != 0x0A) {
    return None
  }
  p = p + 1 // ':' を消費
  while p < n && is_ws(chars[p]) {
    p = p + 1
  }
  if p >= n || !is_digit(chars[p]) {
    return None
  }
  let (value, after_num) = lex_number(chars, p)
  if after_num < n &&
    (chars[after_num].to_int() == 0x78 || chars[after_num].to_int() == 0x58) {
    Some((value, after_num + 1))
  } else {
    None
  }
}

// --- 集合 / 表示ヘルパー --------------------------------------------------

///|
fn contains_double(arr : Array[Double], v : Double) -> Bool {
  for x in arr {
    if x == v {
      return true
    }
  }
  false
}

///|
fn push_unique(arr : Array[Double], v : Double) -> Unit {
  if !contains_double(arr, v) {
    arr.push(v)
  }
}

///|
fn dedup_sorted(arr : Array[Double]) -> Array[Double] {
  let out : Array[Double] = []
  for v in arr {
    push_unique(out, v)
  }
  out.sort()
  out
}

///|
/// Python `f"{m:g}x"` 相当。整数値は整数表記、0.5 / 0.25 は固定表記。
fn fmt_mult(m : Double) -> String {
  let i = m.to_int()
  if i.to_double() == m {
    "\{i}x"
  } else if m == 0.5 {
    "0.5x"
  } else if m == 0.25 {
    "0.25x"
  } else {
    "\{m}x"
  }
}

///|
fn build_message(
  chart_mults : Array[Double],
  unsupported : Array[Double],
) -> String {
  let chart_sorted = dedup_sorted(chart_mults)
  let bad_sorted = dedup_sorted(unsupported)
  let chart_disp = if chart_sorted.length() == 0 {
    "(なし)"
  } else {
    chart_sorted.map(fmt_mult).join(", ")
  }
  let bad_disp = bad_sorted.map(fmt_mult).join(", ")
  "タイプ相性の捏造ガード: 最終応答に type-chart 出力で裏付けられない倍率の主張があります。\n" +
  "  応答中の未裏付け倍率: " +
  bad_disp +
  "\n" +
  "  このターンの type-chart 実出力: " +
  chart_disp +
  "\n" +
  "対処: 当該タイプの組み合わせに対し `pkdx type-chart <技タイプ> <防御タイプ(,区切り)>` を\n" +
  "実行し、その出力倍率のみを使って記述を訂正してください。type-chart で確認できない倍率や\n" +
  "倍率に基づく相性評価をユーザーへ提示してはいけません (CLAUDE.md #5)。\n"
}

///|
fn is_blank(s : String) -> Bool {
  for c in s {
    if !is_ws(c) {
      return false
    }
  }
  true
}
