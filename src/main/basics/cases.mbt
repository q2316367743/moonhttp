// 各条用例：每条一个函数，由 `main.mbt` 的 `main` 依次调用。
// 靶子是本机 server（见 `main.mbt` 的 `demo_server`）与华为云镜像。

///|
/// 1. 基本 GET：状态码、状态文本、响应头、正文的两种读法。
async fn basic_text(client : @moonhttp.Client) -> Unit {
  println("== 1. 基本 GET（文本响应）==")
  let response = client.request(@moonhttp.Config::new("/hello"))
  println("状态行       = \{response.status} \{response.status_text}")
  println(
    "自定义头     = X-Demo: \{response.headers.get("X-Demo").unwrap_or("<缺失>")}",
  )
  println(
    "内容类型     = \{response.headers.get("content-type").unwrap_or("<缺失>")}",
  )
  println("text()       = \{response.text()}")
  println(
    "bytes().length() = \{response.bytes().length()}（UTF-8 下中文 2 字节/字）",
  )
  println("")
}

///|
/// 2. 查询参数：默认序列化的括号约定（数组 → `tags[]`、嵌套对象 → `filter[lang]`）。
async fn query_params(client : @moonhttp.Client) -> Unit {
  println("== 2. 查询参数（with_params 的默认序列化）==")
  let response = client.request(
    @moonhttp.Config::new("/echo").with_params({
      "q": "moonbit",
      "page": 2,
      "tags": ["a", "b"],
      "filter": { "lang": "moonbit" },
    }),
  )
  println("服务端收到的 query = \{echo_query(response)}")
  println(
    "（方括号在线上是百分号编码的 %5B / %5D，与 axios 一致）",
  )
  println("")
}

///|
/// 3. 自定义 paramsSerializer：`params` 整体交给这个函数，返回什么就发什么。
async fn custom_serializer(client : @moonhttp.Client) -> Unit {
  println("== 3. 自定义 paramsSerializer（整体替换默认序列化）==")
  let response = client.request(
    @moonhttp.Config::new("/echo")
    .with_params({ "q": "moonbit", "page": 2, "tags": ["a", "b"] })
    .with_params_serializer(fn(params) {
      match params {
        { "q": String(q), "page": Number(page, ..), .. } =>
          "q=\{q}&p=\{page.to_int()}&tags=a,b"
        _ => ""
      }
    }),
  )
  println("服务端收到的 query = \{echo_query(response)}")
  println("")
}

///|
/// 4. 二进制响应：`bytes()` 拿精确字节（库不猜内容类型，也不做转换）。
async fn binary_body(client : @moonhttp.Client) -> Unit {
  println("== 4. 二进制响应（application/octet-stream）==")
  let response = client.request(@moonhttp.Config::new("/bytes"))
  let bytes = response.bytes()
  println("状态行           = \{response.status} \{response.status_text}")
  println("字节数           = \{bytes.length()}")
  println(
    "前 4 个字节      = \{bytes[0].to_int()} \{bytes[1].to_int()} \{bytes[2].to_int()} \{bytes[3].to_int()}（都是 'A' = 65）",
  )
  println("content_length() = \{response.content_length()}")
  println("")
}

///|
/// 5. `response_encoding` 只管「怎么读」：同一份 UTF-8 字节按 latin1 读就是乱码，
/// 但字节数一样（读法不改动原始字节）。
async fn encoding_reading(client : @moonhttp.Client) -> Unit {
  println(
    "== 5. response_encoding 的读法（同一份字节，两种编码）==",
  )
  let utf8 = client.request(@moonhttp.Config::new("/hello"))
  let latin1 = client.request(
    @moonhttp.Config::new("/hello").with_response_encoding(
      @moonhttp.ResponseEncoding::Latin1,
    ),
  )
  println("utf-8  读法 = \{utf8.text()}（\{utf8.bytes().length()} 字节）")
  println(
    "latin1 读法 = \{latin1.text()}（\{latin1.bytes().length()} 字节）",
  )
  println("")
}

///|
/// 6. 空正文：204 没有 body，`text()` 是空串、`content_length()` 是 0。
async fn empty_response(client : @moonhttp.Client) -> Unit {
  println("== 6. 空正文（204 No Content）==")
  let response = client.request(@moonhttp.Config::new("/empty"))
  println("状态行           = \{response.status} \{response.status_text}")
  println("content_length() = \{response.content_length()}")
  println(
    "text() 长度      = \{response.text().length()}，bytes() 长度 = \{response.bytes().length()}",
  )
  println("is_success()     = \{response.is_success()}")
  println("")
}

///|
/// 7. 4xx：默认只把 2xx 当成功，404 会抛出 `HttpError`，
/// 错误上带着分类、已合并的配置，以及服务端返回的那份响应。
async fn error_4xx(client : @moonhttp.Client) -> Unit {
  println("== 7. 4xx（默认校验：非 2xx 即错误）==")
  try {
    let response = client.request(@moonhttp.Config::new("/missing"))
    println("没抛错（不应该）：\{response.status}")
  } catch {
    error => print_error(error)
  }
  println("")
}

///|
/// 8. 5xx：分类与 4xx 分开（`ERR_BAD_RESPONSE`），正文同样拿得到。
async fn error_5xx(client : @moonhttp.Client) -> Unit {
  println("== 8. 5xx（分类是 ERR_BAD_RESPONSE）==")
  try {
    let response = client.request(@moonhttp.Config::new("/boom"))
    println("没抛错（不应该）：\{response.status}")
  } catch {
    error => print_error(error)
  }
  println("")
}

///|
/// 9. `validate_status` 自定义「什么算成功」：4xx 之下都放行，418 就成了正常响应。
///
/// 注意 `is_success()` 仍按状态码区间算（2xx 才是 true），它不受校验函数影响。
async fn custom_validate(client : @moonhttp.Client) -> Unit {
  println("== 9. validate_status：让 418 也算成功 ==")
  let response = client.request(
    @moonhttp.Config::new("/teapot").with_validate_status(fn(status) {
      // 2xx 照旧算成功，另外把 418 也放进来
      (status >= 200 && status < 300) || status == 418
    }),
  )
  println("状态行       = \{response.status} \{response.status_text}")
  println(
    "正文         = \{response.text()}（没抛错，说明校验函数放行了）",
  )
  println(
    "is_success() = \{response.is_success()}（按状态码区间算，与校验函数无关）",
  )
  println("")
}

///|
/// 10. 超时：`timeout` 是毫秒，超了报 `ECONNABORTED`（与取消的 `ERR_CANCELED` 分得开）。
async fn timeout_case(client : @moonhttp.Client) -> Unit {
  println("== 10. 超时（timeout = 150ms，服务端睡 500ms）==")
  let started = @async.now()
  try {
    let response = client.request(
      @moonhttp.Config::new("/slow").with_timeout(150),
    )
    println("没抛错（不应该）：\{response.status}")
  } catch {
    error => {
      print_error(error)
      println("实际耗时     = \{(@async.now() - started).to_int()} ms")
    }
  }
  println("")
}

///|
/// 11. 真实站点：同一个客户端（不带代理）打公网。
///
/// 外网请求一律包在 try / catch 里：断网或站点变动时打印错误分类，不 panic，
/// 后面的示例也不会被带崩。
async fn real_sites() -> Unit {
  println("== 11. 真实站点（华为云 openjdk 镜像，直连可达）==")
  let client = @moonhttp.create(
    @moonhttp.Config::default()
    .with_base_url("https://mirrors.huaweicloud.com")
    .with_timeout(20_000),
  )
  try {
    let index = client.request(@moonhttp.Config::new("/openjdk/27/"))
    println("目录页     = \{index.status} \{index.status_text}")
    println(
      "内容类型   = \{index.headers.get("content-type").unwrap_or("<缺失>")}",
    )
    println("正文前 120 字符 = \{head_text(index.text(), 120)}")
  } catch {
    error => print_error(error)
  }
  try {
    let sha = client.request(
      @moonhttp.Config::new(
        "/openjdk/27/openjdk-27_macos-aarch64_bin.tar.gz.sha256",
      ),
    )
    println("sha256 文件 = \{sha.text().trim()}")
  } catch {
    error => print_error(error)
  }
  println("")
}
