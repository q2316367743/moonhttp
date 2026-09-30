// Set-Cookie 的解析（RFC 6265 §5.2）与过期时刻计算。
//
// 有意从简的两处：
// - `Expires` 只认标准 IMF-fixdate（`Sun, 06 Nov 1994 08:49:37 GMT`），
//   RFC 850 / asctime 两种过时格式不认——认不出时该 cookie 退化为会话
//   cookie（`Max-Age` 优先于 `Expires`，见 RFC 6265 §5.3 step 3）；
// - `HttpOnly` 解析出来直接丢弃：客户端库没有 JS 环境的概念，无从谈起。

///|
/// 解析出来的零件：还缺归属域 / 归属路径——那要拿到请求 URL 才算得出
/// （`store` 阶段补上，见 jar.mbt）。
priv struct ParsedSetCookie {
  name : String
  value : String
  /// Domain 属性（去前导点、小写）；没带（或剥完点后为空）是 None
  domain : String?
  /// Path 属性（以 `/` 开头才有效）；没带或不合法是 None
  path : String?
  /// Expires 属性解析出的时刻（Unix 毫秒）；没带或认不出是 None
  expires_at : UInt64?
  /// Max-Age 属性（秒，可负）；没带或不是合法整数是 None
  max_age : Int64?
  secure : Bool
}

///|
/// 解析一条 Set-Cookie 头值。名字为空、或第一段没有 `=` 时整条作废
/// （RFC 6265 §5.2 的口径：坏的 cookie 静默丢弃，不报错）。
fn parse_set_cookie(header : String) -> ParsedSetCookie? {
  // 第一段是 name=value，其余每段一个属性
  let head = match header.find(";") {
    Some(index) => header[:index]
    None => header
  }
  let (name, value) = match head.find("=") {
    Some(index) =>
      (head[:index].trim().to_owned(), head[index + 1:].trim().to_owned())
    None => return None
  }
  if name.is_empty() {
    return None
  }
  let attrs_text = match header.find(";") {
    Some(index) => header[index + 1:].to_owned()
    None => ""
  }
  let mut domain : String? = None
  let mut path : String? = None
  let mut expires_at : UInt64? = None
  let mut max_age : Int64? = None
  let mut secure = false
  for attr in attrs_text.split(";") {
    let attr = attr.trim()
    if attr.is_empty() {
      continue
    }
    // 属性名大小写不敏感（RFC 6265 §5.2 开头）；无值的属性按空值处理
    let (attr_name, attr_value) = match attr.find("=") {
      Some(index) =>
        (
          attr[:index].trim().to_lower().to_owned(),
          attr[index + 1:].trim().to_owned(),
        )
      None => (attr.to_lower().to_owned(), "")
    }
    match attr_name {
      "expires" => expires_at = parse_http_date(attr_value)
      "max-age" => max_age = parse_max_age(attr_value)
      "domain" => {
        // 前导点按历史习惯剥掉（RFC 6265 §5.2.3）；剥完为空则忽略该属性
        let stripped = if attr_value.has_prefix(".") {
          attr_value[1:]
        } else {
          attr_value
        }
        if !stripped.is_empty() {
          domain = Some(stripped.to_lower().to_owned())
        }
      }
      "path" => if attr_value.has_prefix("/") { path = Some(attr_value) }
      "secure" => secure = true
      // httponly 与一切未知属性：认出来只为忽略
      _ => ()
    }
  }
  Some({ name, value, domain, path, expires_at, max_age, secure, })
}

///|
/// 解析 Max-Age（RFC 6265 §5.2.2）：首字符是数字或 `-`、其余全为数字。
/// 非法一律返回 `None`（该属性被忽略，而不是整条 cookie 作废）。
fn parse_max_age(text : String) -> Int64? {
  let body = if text.has_prefix("-") { text[1:] } else { text }
  if body.is_empty() {
    return None
  }
  let mut value : Int64 = 0L
  for ch in body {
    guard ch >= '0' && ch <= '9' else { return None }
    value = value * 10L + (ch.to_int() - 48).to_int64()
  }
  Some(if text.has_prefix("-") { -value } else { value })
}

///|
/// 解析 IMF-fixdate（`Sun, 06 Nov 1994 08:49:37 GMT`，RFC 7231 §7.1.1.1）。
///
/// 按「字段按位置取」的思路切：空白切分后，第一段不是数字就当星期跳过
/// （RFC 6265 §5.1.1 对星期不校验），其后依次是日、月、年、`时:分:秒`，
/// GMT 尾段可有可无。认不出返回 `None`，调用方把它当会话 cookie 处理。
fn parse_http_date(text : String) -> UInt64? {
  let fields : Array[String] = []
  for field in text.split(" ") {
    if !field.is_empty() {
      fields.push(field.to_owned())
    }
  }
  // 第一段是纯数字时视为「没有星期」：日、月、年、时间从 0 号位开始
  let offset = if fields.length() > 0 && is_digits(fields[0]) { 0 } else { 1 }
  guard fields.length() >= offset + 4 else { return None }
  let day = fields[offset]
  let year = fields[offset + 2]
  // 年份严格 4 位：两位年份属于过时的 RFC 850 格式，这里有意不认
  let day_num = match parse_uint(day, 2) {
    Some(number) => number
    None => return None
  }
  let year_num = match parse_uint(year, 4) {
    Some(number) if year.length() == 4 => number
    _ => return None
  }
  let month = match month_number(fields[offset + 1]) {
    Some(number) => number
    None => return None
  }
  let (hour, minute, second) = match parse_hms(fields[offset + 3]) {
    Some(parts) => parts
    None => return None
  }
  let days = days_from_civil(year_num, month, day_num)
  let seconds = days * 86400L +
    hour.to_int64() * 3600L +
    minute.to_int64() * 60L +
    second.to_int64()
  // 1970 年之前（负秒数）钳成 0：语义上就是「已经过期」
  if seconds < 0L {
    return Some(0UL)
  }
  Some((seconds * 1000L).reinterpret_as_uint64())
}

///|
/// 解析 `时:分:秒`；三段都必须是 1~2 位数字。
fn parse_hms(text : String) -> (Int, Int, Int)? {
  let parts : Array[String] = []
  for part in text.split(":") {
    parts.push(part.to_owned())
  }
  if parts.length() != 3 {
    return None
  }
  let hour = match parse_uint(parts[0], 2) {
    Some(number) => number
    None => return None
  }
  let minute = match parse_uint(parts[1], 2) {
    Some(number) => number
    None => return None
  }
  let second = match parse_uint(parts[2], 2) {
    Some(number) => number
    None => return None
  }
  Some((hour, minute, second))
}

///|
/// 解析一段 1~`max_digits` 位（位数上限只用来挡异常输入，不前导补零）的
/// 非负整数。项目里既有的解析口径是 `@string.parse_int`。
fn parse_uint(text : String, max_digits : Int) -> Int? {
  guard text.length() >= 1 && text.length() <= max_digits else { return None }
  guard is_digits(text) else { return None }
  Some(@string.parse_int(text)) catch {
    _ => None
  }
}

///|
/// 非空且全为数字。
fn is_digits(text : String) -> Bool {
  if text.is_empty() {
    return false
  }
  for ch in text {
    guard ch >= '0' && ch <= '9' else { return false }
  }
  true
}

///|
/// 月份名转序号：只看前三个字母（RFC 6265 §5.1.1 的宽松口径）。
fn month_number(name : StringView) -> Int? {
  if name.length() < 3 {
    return None
  }
  match name[:3].to_lower().to_owned() {
    "jan" => Some(1)
    "feb" => Some(2)
    "mar" => Some(3)
    "apr" => Some(4)
    "may" => Some(5)
    "jun" => Some(6)
    "jul" => Some(7)
    "aug" => Some(8)
    "sep" => Some(9)
    "oct" => Some(10)
    "nov" => Some(11)
    "dec" => Some(12)
    _ => None
  }
}

///|
/// 公历日期到「自 1970-01-01 起的天数」（Howard Hinnant 的
/// days_from_civil 算法，闰年规则内建）。
fn days_from_civil(year : Int, month : Int, day : Int) -> Int64 {
  let y = if month <= 2 { year - 1 } else { year }
  let m = if month <= 2 { month + 9 } else { month - 3 }
  let era = (if y >= 0 { y } else { y - 399 }) / 400
  let yoe = y - era * 400
  let doy = (153 * m + 2) / 5 + day - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  era.to_int64() * 146097L + doe.to_int64() - 719468L
}

///|
/// Max-Age 换算成毫秒数（供 `store` 加到当前时刻上）。上限钳在约 28 万年：
/// 再大的值语义上等同「永不过期」，钳住是为了乘法不溢出。
fn add_max_age(now : UInt64, max_age : Int64) -> UInt64 {
  let clamped = if max_age > 9_000_000_000_000L {
    9_000_000_000_000L
  } else {
    max_age
  }
  now + (clamped * 1000L).reinterpret_as_uint64()
}
