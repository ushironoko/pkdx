///|
/// Query Pokemon that can learn a given move (level-up + TM).
pub fn query_learners(
  db : Db,
  move_name : String,
  version : String,
) -> Result[Array[SearchResult], String] {
  let waza_ver = to_waza_version(version)
  let sql =
    #|WITH learners AS (
    #|  SELECT pw.globalNo
    #|  FROM local_waza_language wl
    #|  JOIN local_pokedex_waza pw ON wl.waza = pw.waza AND pw.version = ?
    #|  WHERE wl.language = 'jpn' AND wl.name = ? AND wl.version = ?
    #|    AND COALESCE(pw.form, '') = '' AND COALESCE(pw.region, '') = ''
    #|  UNION ALL
    #|  SELECT pm.globalNo
    #|  FROM local_waza_language wl
    #|  JOIN local_waza_machine wm ON wl.waza = wm.machine_no AND wm.version = ?
    #|  JOIN local_pokedex_waza_machine pm ON wm.waza = pm.machine_no AND pm.version = ?
    #|  WHERE wl.language = 'jpn' AND wl.name = ? AND wl.version = ?
    #|    AND COALESCE(pm.form, '') = '' AND COALESCE(pm.region, '') = ''
    #|    AND COALESCE(pm.mega_evolution, '') = '' AND COALESCE(pm.gigantamax, '') = ''
    #|)
    #|SELECT l.globalNo, MIN(pn.name) AS name_ja,
    #|       t.type1, t.type2,
    #|       s.hp, s.attack, s.defense, s.special_attack, s.special_defense, s.speed,
    #|       (s.hp + s.attack + s.defense + s.special_attack + s.special_defense + s.speed) AS bst
    #|FROM learners l
    #|JOIN pokedex p ON l.globalNo = p.globalNo
    #|JOIN local_pokedex_type t ON p.globalNo = t.globalNo AND t.version = ?
    #|JOIN local_pokedex_status s ON p.globalNo = s.globalNo AND s.version = ?
    #|JOIN pokedex_name pn ON p.globalNo = pn.globalNo AND pn.language = 'jpn'
    #|  AND COALESCE(pn.form, '') = '' AND COALESCE(pn.region, '') = ''
    #|  AND COALESCE(pn.mega_evolution, '') = '' AND COALESCE(pn.gigantamax, '') = ''
    #|WHERE COALESCE(p.form, '') = '' AND COALESCE(p.region, '') = ''
    #|  AND COALESCE(p.mega_evolution, '') = '' AND COALESCE(p.gigantamax, '') = ''
    #|GROUP BY l.globalNo
    #|ORDER BY bst DESC
  // CTE binds: level-up(waza_ver, move_name, waza_ver) + TM(waza_ver, waza_ver, move_name, waza_ver)
  // Outer binds: type(version), status(version)
  let binds = [
    waza_ver, move_name, waza_ver, waza_ver, waza_ver, move_name, waza_ver,
    version, version,
  ]
  let rows = match query(db, sql, binds) {
    Ok(r) => r
    Err(e) => return Err(e)
  }
  let results : Array[SearchResult] = []
  for i = 0; i < rows.length(); i = i + 1 {
    let r = rows[i]
    results.push({
      global_no: r[0],
      name_ja: r[1],
      type1: r[2],
      type2: r[3],
      hp: parse_int(r[4]),
      atk: parse_int(r[5]),
      def_: parse_int(r[6]),
      spa: parse_int(r[7]),
      spd: parse_int(r[8]),
      spe: parse_int(r[9]),
      bst: parse_int(r[10]),
    })
  }
  Ok(results)
}
