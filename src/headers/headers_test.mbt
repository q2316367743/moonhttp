///|
/// 头名大小写不敏感是 `Headers` 的核心不变量，这里从多个入口验证它：
/// 同一条头用不同拼写读写都必须落到同一个槽位。
test "header name is case insensitive" {
  let headers = @headers.Headers::new().set("Content-Type", "application/json")
  assert_eq(headers.get("Content-Type"), Some("application/json"))
  assert_eq(headers.get("content-type"), Some("application/json"))
  assert_eq(headers.get("CONTENT-TYPE"), Some("application/json"))
  assert_true(headers.has("cOnTeNt-TyPe"))
  // 三种拼写写的是同一条，条数不应增长。
  let rewritten = headers.set("CONTENT-TYPE", "text/plain")
  assert_eq(rewritten.length(), 1)
  assert_eq(rewritten.get("Content-Type"), Some("text/plain"))
}

///|
/// 查不到的头返回 None，而不是空串——区分「没有」和「值为空」。
test "missing header returns none" {
  let headers = @headers.Headers::new()
  assert_true(headers.is_empty())
  assert_eq(headers.get("X-Missing"), None)
  assert_false(headers.has("X-Missing"))
}

///|
/// 写入时记住原始拼写，遍历时按插入顺序输出，不受规范化影响。
test "original spelling and insertion order are preserved" {
  let headers = @headers.Headers::new()
    .set("Accept", "application/json")
    .set("X-Request-Id", "abc")
  assert_eq(headers.entries(), [
    ("Accept", "application/json"),
    ("X-Request-Id", "abc"),
  ])
  assert_eq(headers.to_string(), "Accept: application/json, X-Request-Id: abc")
}

///|
/// 先出现的拼写被后来的覆盖，与 axios 的 set 覆盖语义保持一致。
test "later write wins including spelling" {
  let headers = @headers.Headers::new()
    .set("accept", "text/plain")
    .set("Accept", "application/json")
  assert_eq(headers.length(), 1)
  assert_eq(headers.entries(), [("Accept", "application/json")])
}

///|
/// 头名前后的空白在规范化时被裁掉，避免 `"Accept "` 这种拼写写出两条记录。
test "surrounding whitespace in header name is trimmed" {
  let headers = @headers.Headers::new().set("  Accept  ", "application/json")
  assert_eq(headers.length(), 1)
  assert_eq(headers.get("Accept"), Some("application/json"))
}

///|
/// set_if_absent 是「补默认值但不覆盖用户显式设置」的原语。
test "set_if_absent keeps existing value" {
  let existing = @headers.Headers::new().set("Accept", "application/json")
  let kept = existing.set_if_absent("accept", "text/plain")
  assert_eq(kept.get("Accept"), Some("application/json"))
  let added = existing.set_if_absent("X-Trace", "1")
  assert_eq(added.get("X-Trace"), Some("1"))
  assert_eq(added.length(), 2)
}

///|
/// remove 同样忽略大小写，且不存在的 key 不会破坏集合。
test "remove is case insensitive and tolerant" {
  let headers = @headers.Headers::new()
    .set("Accept", "application/json")
    .set("X-Trace", "1")
  let removed = headers.remove("accept").remove("X-Not-Here")
  assert_eq(removed.length(), 1)
  assert_eq(removed.get("Accept"), None)
  assert_eq(removed.get("X-Trace"), Some("1"))
}

///|
/// merge 的入参胜出，这正是三层 header 优先级的实现方式。
test "merge lets the argument win" {
  let common = @headers.Headers::new()
    .set("Accept", "application/json")
    .set("X-Layer", "common")
  let per_request = @headers.Headers::new()
    .set("accept", "text/plain")
    .set("X-Only", "1")
  let merged = common.merge(per_request)
  assert_eq(merged.get("Accept"), Some("text/plain"))
  assert_eq(merged.get("X-Layer"), Some("common"))
  assert_eq(merged.get("X-Only"), Some("1"))
  assert_eq(merged.length(), 3)
}

///|
/// 变更方法返回新实例，原实例不受影响——配置合并依赖这个性质。
test "mutation methods do not touch the receiver" {
  let original = @headers.Headers::new().set("Accept", "application/json")
  let _ = original.set("Accept", "text/plain")
  let _ = original.remove("Accept")
  let _ = original.merge(@headers.Headers::new().set("Accept", "text/plain"))
  assert_eq(original.get("Accept"), Some("application/json"))
  assert_eq(original.length(), 1)
}

///|
/// 判等忽略拼写差异，只比较语义内容。
test "equality ignores spelling" {
  let a = @headers.Headers::new().set("Content-Type", "application/json")
  let b = @headers.Headers::new().set("content-type", "application/json")
  let c = @headers.Headers::new().set("content-type", "text/plain")
  assert_eq(a, b)
  assert_true(a != c)
}

///|
/// from_pairs 按顺序写入，后出现的同名项覆盖先出现的。
test "from_pairs applies later entries last" {
  let headers = @headers.Headers::from_pairs([
    ("Accept", "application/json"),
    ("accept", "text/plain"),
  ])
  assert_eq(headers.length(), 1)
  assert_eq(headers.get("Accept"), Some("text/plain"))
}

///|
/// 判等的否定分支：条数不同、以及条数相同但键不同，都必须判为不相等。
test "equality rejects different shapes" {
  let one = @headers.Headers::new().set("Accept", "application/json")
  let two = one.set("X-Trace", "1")
  assert_true(one != two)
  // 条数相同但键不同：不能因为长度相等就判等
  let other_key = @headers.Headers::new().set("Accept-Encoding", "gzip")
  assert_true(one != other_key)
}

///|
/// Show 渲染（字符串插值走的就是它），与 Headers::to_string 同格式。
test "show rendering matches to_string" {
  let headers = @headers.Headers::new().set("Accept", "application/json")
  assert_eq("\{headers}", "Accept: application/json")
  assert_eq(Show::to_string(headers), "Accept: application/json")
  // Debug 走 debug_inspect 做快照断言（Repr 本身没有 Eq，不能直接比较）
  debug_inspect(headers, content="\"Accept: application/json\"")
}
