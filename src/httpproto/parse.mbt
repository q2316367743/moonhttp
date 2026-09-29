///|
/// 协议层的解析错误。
///
/// 两类是刻意的区分，映射成对外错误码的职责在实现层（httpconn）：
/// - `Malformed`：字节流语法坏了（截断、缺 CRLF、非法头行）→ `ERR_BAD_RESPONSE`，
///   这是对端的问题；
/// - `Unsupported`：对端说的不是我们能说的话（HTTP/2 前言、0.9 简单响应）→
///   `ERR_NOT_SUPPORTED`，这是能力边界。docs/17 口径 1：只做 HTTP/1.0 与 1.1。
pub(all) suberror ParseError {
  Malformed(String)
  Unsupported(String)
} derive(Eq, Debug)

///|
pub extend ParseError with Eq::{equal, not_equal}

///|
pub extend ParseError with @debug.Debug::{to_repr}

///|
/// HTTP 协议版本。只认识 1.0 与 1.1（docs/17 口径 1）。
pub(all) enum HttpVersion {
  Http10
  Http11
} derive(Eq, Debug)

///|
pub extend HttpVersion with Eq::{equal, not_equal}

///|
pub extend HttpVersion with @debug.Debug::{to_repr}

///|
/// 状态行解析结果：`HTTP/1.1 200 OK` 的三个组成部分。
pub(all) struct StatusLine {
  version : HttpVersion
  code : Int
  /// 原样保留（可能为空：`HTTP/1.1 204` 合法；也可能自己含空格）
  reason : String
} derive(Eq, Debug)

///|
pub extend StatusLine with Eq::{equal, not_equal}

///|
pub extend StatusLine with @debug.Debug::{to_repr}

///|
/// 该 UTF-16 码元是否是 OWS（可选空白）：SP 或 HTAB。
///
/// 索引处访问拿到的是 `UInt16` 码元（StringView 没有 charcode_at），
/// 统一按码元数值比较，不经过 Char。
fn is_ows_unit(c : UInt16) -> Bool {
  c.to_int() == 32 || c.to_int() == 9
}

///|
/// 该码元是否是 ASCII 数字。
fn is_digit(c : UInt16) -> Bool {
  let code = c.to_int()
  code >= 48 && code <= 57
}

///|
/// 裁掉两侧 OWS，返回原 view 的子切片。
fn trim_ows(value : StringView) -> StringView {
  let end = value.length()
  let mut start = 0
  while start < end && is_ows_unit(value.at(start)) {
    start += 1
  }
  let mut stop = end
  while stop > start && is_ows_unit(value.at(stop - 1)) {
    stop -= 1
  }
  value[start:stop]
}

///|
/// 行内不得出现 CR / LF：行已经按 CRLF 切开，剩下的 CR/LF 只能是「把裸 LF
/// 当行尾」或走私形状的产物，一律拒绝（RFC 9112 §2.2 允许宽松接收，
/// 这里选严格——对客户端而言，宽松接收等于给走私开口子）。
fn reject_bare_crlf(line : StringView, what : String) -> Unit raise ParseError {
  for c in line {
    if c == '\r' || c == '\n' {
      raise ParseError::Malformed("\{what}包含裸 CR/LF")
    }
  }
}

///|
/// 报错文案用的行摘录：太长截到 32 个码元，避免把整段坏字节塞进错误信息。
fn excerpt(line : StringView) -> String {
  if line.length() > 32 {
    line[:32].to_owned() + "…"
  } else {
    line.to_owned()
  }
}

///|
/// 解析状态行（不含行尾 CRLF），严格按 RFC 9112 §4：
/// `HTTP/1.x` + 单个 SP + 三位数字 + （可选）单个 SP + reason。
///
/// - 不是 `HTTP/` 开头 → `Malformed`（这不是状态行）；
/// - 是 HTTP 但版本不是 1.0 / 1.1 → `Unsupported`（能力边界，见 ParseError 注释）；
/// - code 之后没有内容也是合法的（reason 为空）；reason 原样保留、不再裁空白
///   （个别服务器拿 reason 放自定义文本，裁了就是篡改）。
pub fn parse_status_line(line : String) -> StatusLine raise ParseError {
  reject_bare_crlf(line, "状态行")
  let space = match line.find(" ") {
    Some(index) => index
    None =>
      raise ParseError::Malformed("状态行缺少状态码：\{excerpt(line)}")
  }
  let version = match line[:space] {
    "HTTP/1.0" => HttpVersion::Http10
    "HTTP/1.1" => HttpVersion::Http11
    v =>
      if v.has_prefix("HTTP/") {
        raise ParseError::Unsupported(
          "只支持 HTTP/1.0 与 HTTP/1.1，收到：\{excerpt(line)}",
        )
      } else {
        raise ParseError::Malformed("不是状态行：\{excerpt(line)}")
      }
  }
  let code_part = line[space + 1:]
  if code_part.length() < 3 ||
    !is_digit(code_part.at(0)) ||
    !is_digit(code_part.at(1)) ||
    !is_digit(code_part.at(2)) {
    raise ParseError::Malformed(
      "状态码不是三位数字：\{excerpt(line)}",
    )
  }
  let code = (code_part.at(0).to_int() - 48) * 100 +
    (code_part.at(1).to_int() - 48) * 10 +
    (code_part.at(2).to_int() - 48)
  let reason = if code_part.length() == 3 {
    ""
  } else if code_part.at(3).to_int() == 32 {
    code_part[4:].to_owned()
  } else {
    raise ParseError::Malformed("状态码后缺少空格：\{excerpt(line)}")
  }
  { version, code, reason, }
}

///|
/// 解析头块：`lines` 是按 CRLF 切好、**不含**行尾 CRLF 的行序列
/// （终止头块的空行不包含在内）。处理三件事：
///
/// 1. obs-fold（RFC 9112 §5.2）：以 SP/HTAB 开头的行是上一行的续行，
///    折回并在衔接处用单个空格（主流实现的共同做法）；
/// 2. `Name: value` 切分：名字必须是 token——「冒号前有空白」因此被一并拒绝
///    （RFC 9112 §5.1 要求拒收，那是走私的经典形状）；值裁掉两侧 OWS；
/// 3. 同名重复：不合并，全部按顺序保留（多值压平是门面层的决策，见 HeaderMap）。
pub fn parse_header_block(lines : Array[String]) -> HeaderMap raise ParseError {
  // 第一遍：obs-fold 折行
  let folded : Array[String] = []
  for line in lines {
    reject_bare_crlf(line, "头行")
    if line.length() == 0 {
      raise ParseError::Malformed("头块中间出现空行")
    }
    if is_ows_unit(line.at(0)) {
      if folded.length() == 0 {
        raise ParseError::Malformed("头块以 obs-fold 续行开头")
      }
      folded[folded.length() - 1] = folded[folded.length() - 1] +
        " " +
        trim_ows(line).to_owned()
    } else {
      folded.push(line)
    }
  }
  // 第二遍：切分与校验
  let map = HeaderMap::new()
  for line in folded {
    let colon = match line.find(":") {
      Some(index) => index
      None =>
        raise ParseError::Malformed("头行缺少冒号：\{excerpt(line)}")
    }
    let name = line[:colon]
    if !is_token(name) {
      raise ParseError::Malformed("头名不是合法 token：\{excerpt(line)}")
    }
    map.append(name.to_owned(), trim_ows(line[colon + 1:]).to_owned())
  }
  map
}
