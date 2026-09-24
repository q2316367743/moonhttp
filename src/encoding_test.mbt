// 响应体解码的用例：`response_encoding` 怎么把字节解成 `Response::text()`。
//
// 默认是 UTF-8（对齐 axios 的 `responseEncoding` 默认值），可选 latin1 /
// ascii / utf-16le。这里逐条钉住边界，重点是那条 lossy 约定：
// 该编码下非法的字节解成替换字符，**不抛错**——响应正文由服务端说了算，
// 为了几个坏字节把整个响应判成失败得不偿失。
//
// 解码发生在**读文本的时候**（`text()` / `json()`），所以每条用例都是先在
// 配置里指定编码、再调读法；`bytes()` 那条路完全不经过编码。

///|
/// 造一份带精确字节的原始响应；`content_type` 为 `None` 表示不带这个头。
///
/// 与 `raw_response` 的区别是 body 收 `Bytes` 而不是 `String`：
/// 解码的用例必须能构造出**不是合法 UTF-8** 的正文。
fn byte_response(
  content_type : String?,
  body : Bytes,
) -> @transport.RawResponse {
  let headers = match content_type {
    Some(value) => @transport.Headers::new().set("Content-Type", value)
    None => @transport.Headers::new()
  }
  {
    status: 200,
    status_text: "OK",
    headers,
    body: @transport.ResponseBody::from_bytes(body),
  }
}

///|
/// 默认按 UTF-8 解码：中文原样解出，`text()` 就是解码后的原文。
async test "the default encoding decodes utf-8" {
  let (client, _) = client_with(
    byte_response(Some("text/plain"), @utf8.encode("中文")),
  )
  assert_eq(client.request(@moonhttp.Config::new("/x")).text(), "中文")
}

///|
/// UTF-8 遇到非法字节解成替换字符，不抛错；精确字节仍在 `bytes()` 上。
async test "invalid utf-8 bytes become replacement characters" {
  let (client, _) = client_with(byte_response(None, b"a\xffb"))
  let response = client.request(@moonhttp.Config::new("/x"))
  assert_eq(response.text(), "a\u{FFFD}b")
  assert_eq(response.bytes(), b"a\xffb")
}

///|
/// latin1 的字节值就是码点：`0xE9` 解成 `é`。
async test "latin1 maps byte values to code points" {
  let (client, _) = client_with(byte_response(None, b"caf\xe9"))
  let response = client.request(
    @moonhttp.Config::new("/x").with_response_encoding(
      @moonhttp.ResponseEncoding::Latin1,
    ),
  )
  assert_eq(response.text(), "café")
}

///|
/// ascii 只认 `0x00`–`0x7F`，更高的字节是替换字符。
async test "ascii replaces bytes above 0x7f" {
  let (client, _) = client_with(byte_response(None, b"ok\x80"))
  let response = client.request(
    @moonhttp.Config::new("/x").with_response_encoding(
      @moonhttp.ResponseEncoding::Ascii,
    ),
  )
  assert_eq(response.text(), "ok\u{FFFD}")
}

///|
/// utf-16le 按两个字节一个码元解：「中文」的字节是 `2D 4E 87 65`。
async test "utf-16le decodes two byte code units" {
  let (client, _) = client_with(byte_response(None, b"\x2d\x4e\x87\x65"))
  let response = client.request(
    @moonhttp.Config::new("/x").with_response_encoding(
      @moonhttp.ResponseEncoding::Utf16le,
    ),
  )
  assert_eq(response.text(), "中文")
}

///|
/// 编码走实例默认值时也会被请求级覆盖（合并策略 2）；
/// 覆盖回 UTF-8 后，latin1 的 `0xE9` 就成了非法字节。
async test "instance default encoding is overridden by the request" {
  let (client, _) = client_with(byte_response(None, b"caf\xe9"))
  let api = client.create(
    @moonhttp.Config::default().with_response_encoding(
      @moonhttp.ResponseEncoding::Latin1,
    ),
  )
  assert_eq(api.request(@moonhttp.Config::new("/x")).text(), "café")
  assert_eq(
    api
    .request(
      @moonhttp.Config::new("/x").with_response_encoding(
        @moonhttp.ResponseEncoding::Utf8,
      ),
    )
    .text(),
    "caf\u{FFFD}",
  )
}

///|
/// `json()` 走的是 `text()` 同一套解码：字节先按 `response_encoding` 解成文本，
/// 再交给 `@json.parse`，所以 latin1 的 `0xE9` 在解析之前就已经是 `é` 了
/// （若跳过解码直接解析，这份正文根本解不出来）。
async test "json decodes with the configured encoding first" {
  let (client, _) = client_with(byte_response(None, b"{\"name\": \"caf\xe9\"}"))
  let response = client.request(
    @moonhttp.Config::new("/x").with_response_encoding(
      @moonhttp.ResponseEncoding::Latin1,
    ),
  )
  assert_eq(response.json(), { "name": "café" })
}

///|
/// 写回按**同一个**编码编码，与 `text()` / `json()` 的读方向对称：
/// `with_text(response.text())` 对四种编码都是恒等的。
///
/// latin1 的 `0xE9`（`é`）写回去必须还是 `0xE9`。若照 UTF-8 写就变成
/// `0xC3 0xA9`，调用方再按 latin1 读回来是 `Ã©`——改写过的响应与原文对不上，
/// 这类腐化只在非 UTF-8 客户端里出现，最难查。
async test "latin1 rewrite round trips through the same encoding" {
  let (client, _) = client_with(byte_response(None, b"caf\xe9"))
  let response = client.request(
    @moonhttp.Config::new("/x").with_response_encoding(
      @moonhttp.ResponseEncoding::Latin1,
    ),
  )
  assert_eq(response.text(), "café")
  let rewritten = response.with_text(response.text())
  assert_eq(rewritten.bytes(), b"caf\xe9")
  assert_eq(rewritten.text(), "café")
}

///|
/// latin1 / ascii 装不下的码元按 lossy 写成一个 `?`（`0x3F`），不抛错——
/// 与解码方向「非法字节解成替换字符」同一口径。注意是**逐 UTF-16 码元**写，
/// 所以 BMP 之外的字符（代理对）会写成两个 `?`。
///
/// ascii 这条还有一层：core 的 `@ascii.encode` 遇到非 ASCII 会 panic，
/// 写回要的是 lossy，所以这个编码器是自己写的。
async test "latin1 and ascii rewrites replace what they cannot represent" {
  let (client, _) = client_with(byte_response(None, b"ok"))
  let latin1 = client.request(
    @moonhttp.Config::new("/x").with_response_encoding(
      @moonhttp.ResponseEncoding::Latin1,
    ),
  )
  assert_eq(latin1.with_text("中").bytes(), b"?")
  assert_eq(latin1.with_text("😀").bytes(), b"??")
  let ascii = client.request(
    @moonhttp.Config::new("/x").with_response_encoding(
      @moonhttp.ResponseEncoding::Ascii,
    ),
  )
  assert_eq(ascii.with_text("ok").bytes(), b"ok")
  assert_eq(ascii.with_text("é").bytes(), b"?")
}

///|
/// utf-16le 同样读写对称：`中`（`2D 4E`）解出来再写回去还是两个字节。
async test "utf-16le rewrite keeps two byte code units" {
  let (client, _) = client_with(byte_response(None, b"\x2d\x4e\x87\x65"))
  let response = client.request(
    @moonhttp.Config::new("/x").with_response_encoding(
      @moonhttp.ResponseEncoding::Utf16le,
    ),
  )
  assert_eq(response.text(), "中文")
  assert_eq(response.with_text(response.text()).bytes(), b"\x2d\x4e\x87\x65")
}

///|
/// `with_json` 与 `with_text` 同一口径：`stringify()` 出来的规范 JSON 文本
/// 按 `response_encoding` 编成字节，所以 latin1 客户端里非 ASCII 值仍是
/// latin1 字节（`é` → `0xE9`），调用方 `json()` 读回来还是那个值。
async test "with_json writes back in the configured encoding" {
  let (client, _) = client_with(byte_response(None, b"{}"))
  let response = client.request(
    @moonhttp.Config::new("/x").with_response_encoding(
      @moonhttp.ResponseEncoding::Latin1,
    ),
  )
  let rewritten = response.with_json({ "name": "café" })
  assert_eq(rewritten.bytes(), b"{\"name\":\"caf\xe9\"}")
  assert_eq(rewritten.json(), { "name": "café" })
}
