///|
/// 响应体的分帧方式（RFC 9112 §6.3 的客户端侧判定）。
///
/// 分帧决定的是「从连接上读多少字节算这份响应体」——它作用在
/// **编码后的线上字节**上；gzip 解码发生在分帧之下（先按分帧切出线上字节，
/// 再按 `Content-Encoding` 解），两层不能混（docs/15 / docs/18）。
pub(all) enum BodyFraming {
  /// 没有响应体：HEAD 请求的任何响应、1xx、204、304（RFC 9112 §6.3 第 1 条）
  Empty
  /// `Transfer-Encoding: chunked`，用 `ChunkDecoder` 增量解码
  Chunked
  /// `Content-Length: N`，读满 N 字节为止
  Length(Int)
  /// 读到连接关闭为止：既没有 TE 也没有合法 CL。HTTP/1.0 服务器不写 CL 就这么发；
  /// 1.1 服务器这么发时就只能靠关闭收尾（phase 1 本来就每请求一条连接，能接住）
  UntilClose
} derive(Eq, Debug)

///|
pub extend BodyFraming with Eq::{equal, not_equal}

///|
pub extend BodyFraming with @debug.Debug::{to_repr}

///|
/// 从「这次请求是不是 HEAD」+ 状态码 + 响应头判定响应体怎么读。
///
/// 判定顺序就是 RFC 9112 §6.3 的顺序，每一步都不可交换：
/// 1. 无体规则最先——HEAD / 1xx / 204 / 304 无论头上写了什么都没有体；
/// 2. TE 优先于 CL——两者并存说明报文被中间盒改写过，按 CL 读会被走私；
///    TE 里声明的编码序列必须恰好是 `chunked`（或它之前的编码我们一律
///    不解——本库只自持 gzip，且 gzip 属于 Content-Encoding 而不是 TE）；
/// 3. 多条 `Content-Length` 必须全部一致（含逗号分隔的写法），不一致即走私形状；
/// 4. 都没有 → `UntilClose`。
pub fn body_framing(
  is_head : Bool,
  status : Int,
  headers : HeaderMap,
) -> BodyFraming raise ParseError {
  if is_head || status < 200 || status == 204 || status == 304 {
    return Empty
  }
  // TE：把所有 TE 头的值按逗号摊平成编码序列，最后一个必须是 chunked，
  // 且不允许出现任何我们不会应用的编码。
  let codings : Array[String] = []
  for value in headers.get_all("Transfer-Encoding") {
    for piece in value.split(",") {
      // split 出来的是 StringView，裁空白与折叠小写都借 String 的 API
      codings.push(piece.to_owned().trim(chars=" \t").to_owned().to_lower())
    }
  }
  if codings.length() > 0 {
    let last = codings[codings.length() - 1]
    if last != "chunked" {
      raise ParseError::Malformed(
        "Transfer-Encoding 的最后一个编码必须是 chunked，收到：\{last}",
      )
    }
    for coding in codings {
      if coding != "chunked" {
        raise ParseError::Malformed(
          "不支持的 Transfer-Encoding 编码序列（只会读 chunked）：\{coding}",
        )
      }
    }
    return Chunked
  }
  // CL：全部取出来比对；任何一条不是纯数字、或值不一致，都是坏报文。
  let lengths : Array[Int] = []
  for value in headers.get_all("Content-Length") {
    for piece in value.split(",") {
      lengths.push(parse_content_length(piece.to_owned().trim(chars=" \t")))
    }
  }
  if lengths.length() > 0 {
    let first = lengths[0]
    for length in lengths {
      if length != first {
        raise ParseError::Malformed(
          "多条 Content-Length 值不一致（走私形状）",
        )
      }
    }
    return Length(first)
  }
  UntilClose
}

///|
/// 解析单段 `Content-Length` 值：非空纯数字，带溢出保护。
fn parse_content_length(value : StringView) -> Int raise ParseError {
  if value.length() == 0 {
    raise ParseError::Malformed("Content-Length 是空值")
  }
  let mut total = 0
  for k in 0..<value.length() {
    let c = value.at(k)
    if !is_digit(c) {
      raise ParseError::Malformed("Content-Length 不是纯数字：\{value}")
    }
    // 先判溢出再乘：大于 (Int.MAX - 9) / 10 时再进位必然溢出
    if total > 214748363 {
      raise ParseError::Malformed("Content-Length 超出可表示范围")
    }
    total = total * 10 + (c.to_int() - 48)
  }
  total
}
