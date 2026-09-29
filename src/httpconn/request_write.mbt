// 请求侧：把 `PreparedRequest` 变成线上的字节。
//
// 头的装配顺序（RFC 语义上无所谓，可读性上有所谓）：用户头在最前
//（原样保留顺序），自动补的头按 set_if_absent 跟在后面——用户显式设置
// 的同名头永远赢，与 axios 的 set_if_absent 口径一致。

///|
/// 上传进度的分块大小：每写完这么多字节报告一次进度。
/// 与旧栈（async_http.mbt）同一粒度——64 KiB 是「回调次数」与
/// 「进度条平滑度」的常见折中，两栈报告节奏一致才好对照。
const UPLOAD_CHUNK_SIZE : Int = 65536

///|
/// 装配请求头。四条自动头各有出处：
/// - `Host`：RFC 9112 §7.2，由栈按目标生成（重定向层已把用户显式 Host 丢掉）；
/// - `Accept-Encoding: gzip`：**谁解压谁声明**（docs/15）——请求没声明时
///   由我们声明并负责响应侧解压；用户声明过（含 `decompress: false` 时
///   上层声明的 `identity`）就完全不动；
/// - `Connection: close`：phase 1 每请求一条连接，声明 close 让服务端
///   立刻回收（docs/17 口径 4；keep-alive 随连接池一起来）；
/// - `Content-Length`：phase 1 请求体一律定长（docs/17 口径 4），无体发 0，
///   与旧栈「底层据此发 Content-Length: 0」的线上行为对齐。
fn build_request_headers(
  request : @transport.PreparedRequest,
  target : Target,
) -> @httpproto.HeaderMap {
  let headers = @httpproto.HeaderMap::new()
  for entry in request.headers.entries() {
    headers.append(entry.0, entry.1)
  }
  headers.set_if_absent("Host", host_header(target))
  headers.set_if_absent("Accept-Encoding", "gzip")
  headers.set_if_absent("Connection", "close")
  let length = match request.body {
    Some(bytes) => bytes.length()
    None => 0
  }
  headers.set_if_absent("Content-Length", length.to_string())
  headers
}

///|
/// 渲染并写出请求头块。渲染失败是「请求构造不出来」（方法/头/目标的形状
/// 问题），归 `Unsupported`——不是对端的错，别记成 `Malformed`。
async fn write_request_head(
  conn : Connection,
  meth : String,
  target : String,
  headers : @httpproto.HeaderMap,
) -> Unit raise @transport.TransportError {
  let head = @httpproto.render_request_head(meth, target, headers) catch {
    @httpproto.ParseError::Malformed(message) =>
      raise @transport.TransportError::Unsupported(message)
    @httpproto.ParseError::Unsupported(message) =>
      raise @transport.TransportError::Unsupported(message)
  }
  conn.write(head) catch {
    error => raise @transport.TransportError::Network(error.to_string())
  }
}

///|
/// 写请求体：有上传进度回调时按 `UPLOAD_CHUNK_SIZE` 分块写、逐块报告。
/// 「报告了 = 已经交给内核」的口径与旧栈一致（write 不缓冲，一次 syscall；
/// 见 docs/10-progress.md）。空 body 不触发任何回调——没有字节可报。
async fn write_request_body(
  conn : Connection,
  data : Bytes,
  on_progress : @transport.ProgressCallback?,
) -> Unit raise @transport.TransportError {
  match on_progress {
    None =>
      conn.write(data) catch {
        error => raise @transport.TransportError::Network(error.to_string())
      }
    Some(report) => {
      let total = data.length()
      let mut sent = 0
      while sent < total {
        let mut end = sent + UPLOAD_CHUNK_SIZE
        if end > total {
          end = total
        }
        conn.write(data.exact_view(start=sent, end~)) catch {
          error => raise @transport.TransportError::Network(error.to_string())
        }
        sent = end
        report({ loaded: sent, total: Some(total), })
      }
    }
  }
}
