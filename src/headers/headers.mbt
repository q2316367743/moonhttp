///|
/// HTTP 头名的大小写无关规范化：先裁掉两侧空白，再把 `A`-`Z` 折成 `a`-`z`。
///
/// HTTP/1.1 规定头字段名只在 ASCII 范围内大小写不敏感（RFC 9110 §5.1），
/// 所以这里不做 Unicode 大小写折叠，和 axios 的 `normalizeHeader` 在 ASCII 上等价。
///
/// 包内可见（`fn` 而非 `pub fn`）：规范化是 `Headers` 的封装细节，
/// 外部使用者不应该依赖「key 是小写的」这一实现事实。
fn normalize_name(name : StringView) -> String {
  let buf = StringBuilder(size_hint=name.length())
  for c in name {
    buf.write_char(c.to_ascii_lowercase())
  }
  buf.to_string()
}

///|
/// 大小写不敏感的 HTTP 头集合，对应 axios 的 `AxiosHeaders`。
///
/// 内部以小写化后的头名作为 `Map` 的 key，值里再记住写入时的原始拼写，
/// 于是 `get("Content-Type")` 与 `get("content-type")` 命中同一条记录，
/// 而遍历/打印时仍然保留调用方书写时的形状（与 axios「首次出现的拼写胜出」一致）。
///
/// 与 axios 相比的两处有意简化（README 里有完整清单）：
/// - 不支持 axios 用 `false` 表示「这条头禁止被默认值覆盖」的哨兵值；
/// - 同一个头名只能有一个字符串值，不展开多值头（axios 允许数组）。
///
/// 所有变更方法都返回新实例而不是就地修改：`Config` 是值语义的，
/// 合并配置时同一份 `Headers` 可能被多个 `Config` 引用，
/// 返回新值可以避免「改一个实例的头，另一个实例跟着变」这类共享可变状态 bug。
pub struct Headers {
  priv entries : Map[String, (String, String)]
}

///|
/// 空的头集合。
pub fn Headers::new() -> Headers {
  { entries: Map([]), }
}

///|
/// 从「头名, 值」序列构造；同名（忽略大小写）时后出现的覆盖先出现的。
pub fn Headers::from_pairs(pairs : Array[(String, String)]) -> Headers {
  let mut headers = Headers::new()
  for pair in pairs {
    headers = headers.set(pair.0, pair.1)
  }
  headers
}

///|
/// 写入一条头，返回新的集合；已有同名头（忽略大小写）时会被整体覆盖。
///
/// `(spelling, value)` 一起替换：拼写以最后一次写入为准，
/// 这与 axios 的 `AxiosHeaders::set` 默认覆盖行为一致。
pub fn Headers::set(
  self : Headers,
  name : StringView,
  value : String,
) -> Headers {
  let spelling = name.trim().to_owned()
  let entries = self.entries.copy()
  entries[normalize_name(spelling)] = (spelling, value)
  { entries, }
}

///|
/// 仅当同名头（忽略大小写）尚不存在时写入，返回新的集合。
///
/// 用于「补默认值但不能盖掉用户显式设置」的场景，例如自动补 `Content-Type`。
pub fn Headers::set_if_absent(
  self : Headers,
  name : StringView,
  value : String,
) -> Headers {
  if self.has(name) {
    self
  } else {
    self.set(name, value)
  }
}

///|
/// 按名取值，大小写不敏感。查不到返回 `None`，而不是空串，
/// 以便区分「这个头不存在」和「这个头的值是空字符串」。
pub fn Headers::get(self : Headers, name : StringView) -> String? {
  match self.entries.get(normalize_name(name.trim())) {
    Some(entry) => Some(entry.1)
    None => None
  }
}

///|
/// 是否存在该头，大小写不敏感。
pub fn Headers::has(self : Headers, name : StringView) -> Bool {
  self.entries.contains(normalize_name(name.trim()))
}

///|
/// 删除一条头，返回新的集合；不存在时原样返回。
pub fn Headers::remove(self : Headers, name : StringView) -> Headers {
  let entries = self.entries.copy()
  entries.remove(normalize_name(name.trim()))
  { entries, }
}

///|
/// 以 `other` 覆盖自身，返回新的集合（大小写不敏感，同名时 `other` 胜出）。
///
/// 这是 `flatten_headers` 实现「common 层 < 按方法层 < 请求级平铺」优先级的基石：
/// 只要按优先级从低到高依次 merge，最终结果天然就是高优先级覆盖低优先级。
pub fn Headers::merge(self : Headers, other : Headers) -> Headers {
  let entries = self.entries.copy()
  for key, entry in other.entries {
    // key 已是规范化后的小写名，直接落库即可保证两边同名项正确对撞。
    entries[key] = entry
  }
  { entries, }
}

///|
/// 头的条数。
pub fn Headers::length(self : Headers) -> Int {
  self.entries.length()
}

///|
/// 是否一条头都没有。
pub fn Headers::is_empty(self : Headers) -> Bool {
  self.entries.is_empty()
}

///|
/// 展开为「头名, 值」数组，头名保留原始拼写，顺序为插入顺序。
///
/// 顺序有意义：请求级平铺的头是最后 merge 进来的，
/// 因此它们在数组尾部，也是发送到网络上时最靠后的覆盖者。
pub fn Headers::entries(self : Headers) -> Array[(String, String)] {
  let result = []
  for _, entry in self.entries {
    result.push(entry)
  }
  result
}

///|
/// 渲染为 `名: 值` 形式，多条之间用 `", "` 连接。
/// 只用于日志与断言，不参与任何协议编码。
pub fn Headers::to_string(self : Headers) -> String {
  let buf = StringBuilder()
  let mut first = true
  for _, entry in self.entries {
    if !first {
      buf.write_string(", ")
    }
    first = false
    buf.write_string(entry.0)
    buf.write_string(": ")
    buf.write_string(entry.1)
  }
  buf.to_string()
}

///|
pub impl Show for Headers with fn to_string(self) {
  self.to_string()
}

///|
/// 显式声明把 `Show` 的方法挂成常规方法。
/// 隐式挂载已被标记为废弃，这里按当前推荐写法显式 extend；
/// `to_string` 不用列进来，因为上面已经有一个同名的固有方法。
pub extend Headers with Show::{output}

///|
/// 调试输出与 `Show` 共用同一套渲染，避免出现两种格式。
pub impl @debug.Debug for Headers with fn to_repr(self) {
  @debug.Repr::string(self.to_string())
}

///|
pub extend Headers with @debug.Debug::{to_repr}

///|
/// 语义相等：只比较「规范化后的头名 → 值」，忽略保存的原始拼写。
/// 因为头名大小写不敏感，`Content-Type: a` 与 `content-type: a` 应当判等，
/// 直接比内部 Map 会把拼写差异泄漏成不相等。
pub impl Eq for Headers with fn equal(self, other) {
  if self.entries.length() != other.entries.length() {
    return false
  }
  for key, entry in self.entries {
    match other.entries.get(key) {
      Some(other_entry) => if entry.1 != other_entry.1 { return false }
      None => return false
    }
  }
  true
}

///|
pub extend Headers with Eq::{equal, not_equal}
