///|
/// 两个 `Json` 值的深合并，对应 axios `utils.merge` 对普通对象的递归合并：
/// - 两边都是对象 → 逐键递归合并，只在请求级出现的键补进来；
/// - 其余组合 → 请求级整体覆盖。
///
/// 「数组整体替换而不是拼接」是刻意的：axios 的 `utils.merge` 只对 plain object
/// 递归，数组走 `val.slice()` 直接替换。所以默认值里 `tags: ["a"]`、
/// 请求里 `tags: ["b"]` 的结果是 `["b"]`，而不是 `["a", "b"]`。
pub fn merge_json(base : Json, request : Json) -> Json {
  match (base, request) {
    (Object(base_fields), Object(request_fields)) => {
      // copy 后再写：base 可能属于另一个 Config，就地改会让原配置跟着变。
      // Json 是只读类型，只能经由 Json::object 重新构造。
      let merged = base_fields.copy()
      for key, value in request_fields {
        let next = match merged.get(key) {
          Some(existing) => merge_json(existing, value)
          None => value
        }
        merged[key] = next
      }
      Json::object(merged)
    }
    _ => request
  }
}

///|
/// `Json?` 层面的深合并：两侧都可能没有值，`None` 表示未提供。
///
/// 与 `merge_headers` 同构，唯一区别是合并函数换成了 `merge_json`。
/// 用于 `params` 这类以 JSON 对象承载的配置项。
pub fn merge_json_option(base : Json?, request : Json?) -> Json? {
  match (base, request) {
    (None, None) => None
    (Some(base), None) => Some(base)
    (None, Some(request)) => Some(request)
    (Some(base), Some(request)) => Some(merge_json(base, request))
  }
}
