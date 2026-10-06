// 请求侧：把 `PreparedRequest` 变成线上的字节。
//
// 头的装配顺序（RFC 语义上无所谓，可读性上有所谓）：用户头在最前
//（原样保留顺序），自动补的头按 set_if_absent 跟在后面——用户显式设置
// 的同名头永远赢，与 axios 的 set_if_absent 口径一致。
// 例外是流式请求体的两个分帧头（见 build_request_headers）：那两个由栈接管。

///|
/// 上传进度的分块大小：每写完这么多字节报告一次进度。
/// 64 KiB 是「回调次数」与「进度条平滑度」的常见折中，也是流式泵的读取块大小。
const UPLOAD_CHUNK_SIZE : Int = 65536

///|
/// 默认 User-Agent。版本号与 moon.mod 的 version 手工保持一致——
/// MoonBit 没有构建期注入，升版本时这里是唯一要跟着改的地方。
/// GitHub 等服务端会直接拒绝无 UA 的请求，axios 的 node 适配器与
/// Python requests 都是同一机制：用户没设就补一份库自己的。
const DEFAULT_USER_AGENT : String = "moonhttp/0.4.0"

///|
/// 装配请求头。自动头各有出处：
/// - `Host`：RFC 9112 §7.2，由栈按目标生成（重定向层已把用户显式 Host 丢掉）；
/// - `Accept-Encoding: gzip`：**谁解压谁声明**（docs/15）——请求没声明时
///   由我们声明并负责响应侧解压；用户声明过（含 `decompress: false` 时
///   上层声明的 `identity`）就完全不动；
/// - `User-Agent`：`DEFAULT_USER_AGENT`，见上；
/// - `Connection: close`：phase 1 每请求一条连接，声明 close 让服务端
///   立刻回收（docs/17 口径 4；keep-alive 随连接池一起来）；
/// - 分帧头（`Content-Length` / `Transfer-Encoding`）按请求体形态落，见下。
///
/// 分帧头的归属分两档（docs/20）：
/// - 缓冲 / 无 body：`Content-Length` 走 set_if_absent（用户显式设置仍然赢），
///   无体发 0——phase 1 的老口径不变；
/// - 流式 body：两个头**由栈全权接管**——用户预设的一律不进头表（预设的
///   长度可能与实际写出的字节数不符，拼出坏报文；两个头并存更是协议矛盾），
///   再按 `content_length` 的有无落定长或 chunked。
fn build_request_headers(
  request : @transport.PreparedRequest,
  target : Target,
) -> @httpproto.HeaderMap {
  let headers = @httpproto.HeaderMap::new()
  let framing_managed = request.body is Some(@transport.RequestBody::Stream(_))
  for entry in request.headers.entries() {
    if framing_managed {
      let name = entry.0.to_lower()
      if name == "content-length" || name == "transfer-encoding" {
        continue
      }
    }
    headers.append(entry.0, entry.1)
  }
  headers.set_if_absent("Host", host_header(target))
  headers.set_if_absent("Accept-Encoding", "gzip")
  headers.set_if_absent("User-Agent", DEFAULT_USER_AGENT)
  headers.set_if_absent("Connection", "close")
  match request.body {
    Some(@transport.RequestBody::Stream(stream)) =>
      match stream.content_length {
        Some(length) => headers.set("Content-Length", length.to_string())
        None => headers.set("Transfer-Encoding", "chunked")
      }
    // 缓冲形态保持老口径：用户显式设置的分帧头仍然赢。
    Some(@transport.RequestBody::Buffered(bytes)) =>
      headers.set_if_absent("Content-Length", bytes.length().to_string())
    None => headers.set_if_absent("Content-Length", "0")
  }
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
/// 写请求体：按形态分派——缓冲走整块（老路径），流式走泵循环（docs/20）。
async fn write_request_body(
  conn : Connection,
  body : @transport.RequestBody,
  on_progress : @transport.ProgressCallback?,
) -> Unit raise @transport.TransportError {
  match body {
    Buffered(data) => write_buffered_body(conn, data, on_progress)
    Stream(stream) => write_stream_body(conn, stream, on_progress)
  }
}

///|
/// 写缓冲请求体：有上传进度回调时按 `UPLOAD_CHUNK_SIZE` 分块写、逐块报告。
/// 「报告了 = 已经交给内核」的口径（write 不缓冲，一次 syscall；
/// 见 docs/10-progress.md）。空 body 不触发任何回调——没有字节可报。
async fn write_buffered_body(
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

///|
/// 写流式请求体（docs/20）：从读取流按 `UPLOAD_CHUNK_SIZE` 拉取、写向连接，
/// 直到 EOF（`read_some` 返回 `None`）。
///
/// 分帧由 `StreamBody::content_length` 决定，与 `build_request_headers` 落的头
/// 是同一来源：有声明长度就裸写，写出总数必须与声明相符——不符报 `Malformed`
///（本地数据与声明对不上，不是对端的错）；没声明长度就 chunked，每块套
/// `render_chunk_frame`、收尾补终止帧。
///
/// 进度与缓冲路径同口径：每写完一块报告一次（chunked 模式 `total` 为 `None`，
/// 与下载侧 chunked 响应一致）。读源失败（如 MemoryReader 回调抛错）与
/// 写失败一样归 `Network`。
///
/// 空块跳过：chunked 下零长度帧就是终止帧（等于把报文提前截断），
/// 定长下也是噪音；EOF 只认 `None`，不认空段。
async fn write_stream_body(
  conn : Connection,
  stream : @transport.StreamBody,
  on_progress : @transport.ProgressCallback?,
) -> Unit raise @transport.TransportError {
  let chunked = stream.content_length is None
  let mut sent = 0
  while true {
    let chunk = stream.reader.read_some(max_len=UPLOAD_CHUNK_SIZE) catch {
      error => raise @transport.TransportError::Network(error.to_string())
    }
    match chunk {
      None => break
      Some(chunk) => {
        if chunk.length() == 0 {
          continue
        }
        let wire : Bytes = if chunked {
          @httpproto.render_chunk_frame(chunk) catch {
            @httpproto.ParseError::Malformed(message) =>
              raise @transport.TransportError::Malformed(message)
            @httpproto.ParseError::Unsupported(message) =>
              raise @transport.TransportError::Unsupported(message)
          }
        } else {
          chunk
        }
        conn.write(wire) catch {
          error => raise @transport.TransportError::Network(error.to_string())
        }
        sent = sent + chunk.length()
        match on_progress {
          Some(report) =>
            report({ loaded: sent, total: stream.content_length, })
          None => ()
        }
      }
    }
  }
  if chunked {
    conn.write(@httpproto.render_last_chunk()) catch {
      error => raise @transport.TransportError::Network(error.to_string())
    }
  }
  match stream.content_length {
    Some(declared) =>
      if declared != sent {
        raise @transport.TransportError::Malformed(
          "流式请求体与声明的长度不符：声明 \{declared} 字节，实际写出 \{sent} 字节",
        )
      }
    None => ()
  }
}
