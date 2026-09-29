///|
/// HTTP 头的**多值**容器（协议层）。
///
/// HTTP 允许同名头重复出现（`Set-Cookie` 是典型，且 RFC 9110 §5.2 明确它的
/// 多个值不许合并），所以协议层不丢信息：按到达顺序记住每一条 `(名字, 值)`，
/// 同名查询提供 first / last / 全部三种口径。把多值**压平成单值**是门面层
/// （httpconn → `@headers.Headers`，取最后一个值）的决策，见 docs/18。
///
/// 大小写不敏感只在 ASCII 上折叠（RFC 9110 §5.1），与 `@headers.Headers` 的
/// `normalize_name` 同一口径；条目保留线上的原始拼写与顺序。
pub(all) struct HeaderMap {
  /// 按线上顺序保存的 (名字原样, 值原样) 序列。
  /// 类型本身就是可变集合（append / set 就地改），字段一并开放可变。
  mut entries : Array[(String, String)]
} derive(Debug)

///|
pub extend HeaderMap with @debug.Debug::{to_repr}

///|
pub fn HeaderMap::new() -> HeaderMap {
  { entries: [], }
}

///|
/// 两个头名是否指同一条头（ASCII 大小写不敏感）。
fn same_name(a : StringView, b : StringView) -> Bool {
  a.compare_ignore_ascii_case(b) == 0
}

///|
/// 追加一条头。同名重复是合法的 HTTP，这里不做任何合并。
pub fn HeaderMap::append(
  self : HeaderMap,
  name : String,
  value : String,
) -> Unit {
  self.entries.push((name, value))
}

///|
/// 覆盖式设置：移除同名所有条目后追加这一条。
pub fn HeaderMap::set(self : HeaderMap, name : String, value : String) -> Unit {
  self.remove(name)
  self.append(name, value)
}

///|
/// 不存在同名头时才追加——自动补默认头的口径：用户显式设置永远优先。
pub fn HeaderMap::set_if_absent(
  self : HeaderMap,
  name : String,
  value : String,
) -> Unit {
  if !self.has(name) {
    self.append(name, value)
  }
}

///|
/// 是否存在同名头。
pub fn HeaderMap::has(self : HeaderMap, name : StringView) -> Bool {
  for entry in self.entries {
    if same_name(entry.0, name) {
      return true
    }
  }
  false
}

///|
/// 同名头里**第一条**的值；没有则 `None`。
pub fn HeaderMap::get_first(self : HeaderMap, name : StringView) -> String? {
  for entry in self.entries {
    if same_name(entry.0, name) {
      return Some(entry.1)
    }
  }
  None
}

///|
/// 同名头里**最后一条**的值；没有则 `None`。
///
/// 重复头按「最后一个生效」是门面层的压平规则（docs/18）；分帧判定里
/// `Content-Length` 的一致性校验用的是 `get_all`，不经过这里。
pub fn HeaderMap::get_last(self : HeaderMap, name : StringView) -> String? {
  let mut found : String? = None
  for entry in self.entries {
    if same_name(entry.0, name) {
      found = Some(entry.1)
    }
  }
  found
}

///|
/// 同名头的全部值，按线上顺序；没有则空数组。
///
/// 分帧判定用它而不是 `get_first`：多条 `Content-Length` 各说各话是请求走私
/// 的经典形状（RFC 9112 §6.3），必须看到**全部**值才能判。
pub fn HeaderMap::get_all(self : HeaderMap, name : StringView) -> Array[String] {
  let values = []
  for entry in self.entries {
    if same_name(entry.0, name) {
      values.push(entry.1)
    }
  }
  values
}

///|
/// 移除同名所有条目（gzip 摘头用：解压后 `Content-Encoding` / `Content-Length`
/// 都会变成假话，见 docs/15 的「谁解压谁声明」）。保持其余条目的相对顺序。
pub fn HeaderMap::remove(self : HeaderMap, name : StringView) -> Unit {
  let kept = []
  for entry in self.entries {
    if !same_name(entry.0, name) {
      kept.push(entry)
    }
  }
  self.entries = kept
}

///|
/// 条目总数。
pub fn HeaderMap::length(self : HeaderMap) -> Int {
  self.entries.length()
}
