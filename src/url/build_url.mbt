///|
/// 数组是否「扁平」：所有元素都是标量。
///
/// axios 的判断是 `!arr.some(isPlainObject)`（只要不含普通对象就算扁平），
/// 所以 `[[1, 2]]` 这种「数组套数组」在 axios 里也算扁平、走 `key[]`。
/// 这里把数组也视为非扁平，是有意的收紧：否则元素会被 `String([1,2])` 变成
/// `1,2` 这种既不可逆也不符合直觉的值。
fn is_flat_array(items : Array[Json]) -> Bool {
  for item in items {
    match item {
      Array(_) | Object(_) => return false
      _ => ()
    }
  }
  true
}

///|
/// 把一个 Json 标量渲染成 query 里的字符串形式，等价于 axios 的 `convertValue`。
///
/// 数字优先使用 `Json::Number` 里保存的原始字面量（`repr`）。
///
/// `repr` 只在 `Double` 无法精确表示原文本时才有值（`@json.parse` 对超大整数
/// 会填上它），此时沿用它可以避免把 `123456789012345678901234567890`
/// 写成 `1.2345678901234568e+29`。没有 `repr` 时退回 `Double` 的最短表示
/// （`1.0` 会写成 `1`，与 JS 的 `String(number)` 行为一致）。
/// 调用方也可以用 `Json::number(n, repr="...")` 显式指定文本形式。
fn render_scalar(value : Json) -> String {
  match value {
    // Null 与下面的 Array/Object 三个分支都不可达：null 在 collect_pairs 里
    // 就被跳过了，数组/对象也都在那里递归展开。它们只为让 match 完备而存在
    // ——Json 是只读枚举，少一个构造子就编译不过。
    Null => ""
    True => "true"
    False => "false"
    // `repr` 是 Number 的具名字段，只能用 `repr~`（或 `repr=repr`）取；
    // 写成位置模式 `Number(number, repr)` 会报「参数个数不对」。
    Number(number, repr~) =>
      match repr {
        Some(repr) => repr
        None => number.to_string()
      }
    String(text) => text
    // 数组/对象在调用点已被递归展开，这里只是让 match 完备。
    Array(_) | Object(_) => ""
  }
}

///|
/// 递归展开参数树，追加 `编码后的key=编码后的value` 片段。
///
/// 规则对齐 axios 的 `toFormData` 默认 visitor（`metaTokens: true`、`dots: false`）：
/// - 数组：`{ "tags": ["a", "b"] }` → `tags%5B%5D=a&tags%5B%5D=b`
/// - 嵌套对象：`{ "filter": { "status": 1 } }` → `filter%5Bstatus%5D=1`
/// - 数组里套对象：`{ "items": [{ "id": 1 }] }` → `items%5B0%5D%5Bid%5D=1`
/// - JSON 的 `null` 一律跳过，既不写 `key=` 也不写 `key=null`
///
/// 注意 key 是「先拼出 `a[0][b]` 这样的完整形状、再整体做百分号编码」，
/// 所以方括号最终是 `%5B`/`%5D`。这是 axios 的真实输出，不是字面的 `[]`。
fn collect_pairs(out : Array[String], key : String, value : Json) -> Unit {
  match value {
    // axios 的 visitor 对 undefined/null 直接跳过，这里同义。
    Null => ()
    Array(items) =>
      if is_flat_array(items) {
        for item in items {
          if item is Null {
            // 数组里的 null 同样跳过，避免产生 `tags%5B%5D=`
            continue
          }
          out.push(
            encode_component(key + "[]") +
            "=" +
            encode_component(render_scalar(item)),
          )
        }
      } else {
        // 含对象的数组改用下标：`items[0][id]`，与 axios 的 renderKey 一致。
        for index, item in items {
          collect_pairs(out, key + "[" + index.to_string() + "]", item)
        }
      }
    Object(fields) =>
      for child_key, child_value in fields {
        collect_pairs(out, key + "[" + child_key + "]", child_value)
      }
    _ =>
      out.push(
        encode_component(key) + "=" + encode_component(render_scalar(value)),
      )
  }
}

///|
/// 把参数序列化成 query string（不含前导 `?`），
/// 等价于 axios 默认的 `paramsSerializer`。`build_url` 的 `serializer` 参数
/// 可以整体替换这一步（见那里的说明），本函数本身保持默认行为不变。
///
/// 顶层不是对象时返回空串：`params` 在语义上就是「键值对集合」，
/// 传数组或标量没有对应的合法输出，axios 在这种情况下同样什么都不做。
pub fn serialize_params(params : Json) -> String {
  let pairs : Array[String] = []
  match params {
    Object(fields) =>
      for key, value in fields {
        collect_pairs(pairs, key, value)
      }
    _ => ()
  }
  let buf = StringBuilder()
  for index, pair in pairs {
    if index > 0 {
      buf.write_string("&")
    }
    buf.write_string(pair)
  }
  buf.to_string()
}

///|
/// 把 `params` 追加到 `url` 后面，等价于 axios 的 `buildURL`。
///
/// `serializer` 是自定义序列化器（对应 axios `paramsSerializer` 的函数形式）：
/// 给了它就用它替换 `serialize_params` 那一步，返回值直接被当作 query 文本。
/// **替换的只有序列化本身**——下面三条拼接规则与默认路径完全一致，
/// 因为 axios 的 `buildURL` 也是先调 `serialize`、再由自己做拼接与截断。
///
/// 三个边界行为与 axios 保持一致：
/// - URL 里已有 `?` 时用 `&` 续接，否则用 `?`；
/// - `#fragment` 会被丢弃（axios 先在 `#` 处截断再拼 query），
///   所以带 fragment 的地址发出去后不会再带 fragment；
/// - 序列化结果是空串时不留下一个空 `?`（自定义序列化器返回空串同理），
///   URL 原样返回。
pub fn build_url(
  url : String,
  params : Json?,
  serializer? : (Json) -> String,
) -> String {
  let params = match params {
    None => return url
    Some(params) => params
  }
  let query = match serializer {
    Some(serializer) => serializer(params)
    None => serialize_params(params)
  }
  if query.length() == 0 {
    return url
  }
  let base = match url.find("#") {
    Some(hash) => url[:hash].to_owned()
    None => url
  }
  let separator = if base.contains("?") { "&" } else { "?" }
  base + separator + query
}
