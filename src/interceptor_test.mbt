// 拦截器的用例：请求侧的改写与顺序（LIFO）、响应侧的改写与顺序（FIFO）、
// 被拦下的请求、错误处理器重试，以及「整条重定向链只跑一次」这条关键差异。
//
// 全部走 MockTransport：拦截器的效果都落在「最终发出去的 `PreparedRequest`」上，
// Mock 正好能断言那一层（改重定向、重试这类需要多份响应的用响应队列）。
//
// AGENTS.md RL-04 例外声明：本文件是根包（`src/` 根目录）的测试文件，随用例增加
// 突破 300 行，按 RL-04 为根包文件开出的例外处理——上限 1000 行，并在此声明。

///|
/// 造一个带拦截器的实例，并把 Mock 传输层一起返回，便于断言拦截器改写过后的请求。
fn client_with_interceptors(
  response : @transport.RawResponse,
  interceptors : @moonhttp.Interceptors,
) -> (@moonhttp.Client, @transport.MockTransport) {
  let mock = @transport.MockTransport::new(response)
  let transport : &@transport.Transport = mock
  (@moonhttp.Client::new(transport~, interceptors~), mock)
}

///|
/// 跑一次请求并把抛出的错误取出来；没抛错说明用例的前提不成立。
async fn interceptor_error(
  client : @moonhttp.Client,
  config : @moonhttp.Config,
) -> @moonhttp.HttpError {
  let error = try {
    ignore(client.request(config))
    None
  } catch {
    error => Some(error)
  }
  error.unwrap()
}

///|
/// 请求拦截器拿到的是**合并后**的配置，改地址、加头、换请求体都直接生效。
/// 换请求体那条尤其重要：`data` 只取请求级、不能靠实例默认值继承，
/// 「给所有请求注入公共 body 字段」本来没有别的办法，正是 axios 官方文档给
/// 请求拦截器指的那条出路。
async test "request interceptor rewrites the outgoing request" {
  let interceptors = @moonhttp.Interceptors::new().use_request(config => {
    config
    .with_url("/v2/users")
    .with_header("X-Token", "abc")
    .with_data_from_str("{\"app_key\":\"k\"}")
  })
  let (client, mock) = client_with_interceptors(
    raw_response(200, "OK", "{}"),
    interceptors,
  )
  ignore(client.request(@moonhttp.Config::new("/v1/users")))
  let sent = mock.last_request().unwrap()
  assert_eq(sent.url, "/v2/users")
  assert_eq(sent.headers.get("X-Token"), Some("abc"))
  assert_eq(sent.body.unwrap(), @utf8.encode("{\"app_key\":\"k\"}"))
}

///|
/// 请求侧顺序：**后注册先跑**（axios 的请求拦截器是 LIFO），所以先注册的那个
/// 最后改一次配置——同名头的最终值是它写的。
async test "request interceptors run last-registered-first" {
  let mut trace = ""
  let interceptors = @moonhttp.Interceptors::new()
    .use_request(config => {
      trace = trace + "A"
      config.with_header("X-Order", "A")
    })
    .use_request(config => {
      trace = trace + "B"
      config.with_header("X-Order", "B")
    })
  let (client, mock) = client_with_interceptors(
    raw_response(200, "OK", "{}"),
    interceptors,
  )
  ignore(client.request(@moonhttp.Config::new("/a")))
  assert_eq(trace, "BA")
  assert_eq(mock.last_request().unwrap().headers.get("X-Order"), Some("A"))
}

///|
/// 响应侧顺序与前一段**相反**：**先注册先跑**（axios 的响应拦截器是 FIFO）。
/// 每个处理器拿到的都是上一个交出来的响应，所以这里是「A 先改、B 再改」。
async test "response interceptors run first-registered-first" {
  let mut trace = ""
  let interceptors = @moonhttp.Interceptors::new()
    .use_response(response => {
      trace = trace + "A"
      response.with_text(response.text() + "A")
    })
    .use_response(response => {
      trace = trace + "B"
      response.with_text(response.text() + "B")
    })
  let (client, _mock) = client_with_interceptors(
    raw_response(200, "OK", "x"),
    interceptors,
  )
  let response = client.request(@moonhttp.Config::new("/a"))
  assert_eq(trace, "AB")
  assert_eq(response.text(), "xAB")
}

///|
/// 四个改写入口都返回**新**响应（原响应不受影响），读法跟着新字节走：
/// `text()` / `bytes()` / `content_length()` 读到的都是改写后的内容。
/// 响应头是整体替换（不是合并），且不会被 body 改写悄悄改掉。
///
/// 注意断言都写在拦截器**外面**：拦截器闭包的签名只允许抛 `HttpError`，
/// `assert_eq` 抛的是别的错误类型，写不进去（实测）。
async test "response rewrite entries return a new response" {
  let mut original_text = ""
  let mut original_header : String? = None
  let interceptors = @moonhttp.Interceptors::new().use_response(response => {
    let rewritten = response
      .with_body(@utf8.encode("new"))
      .with_headers(@moonhttp.Headers::new().set("X-Rewritten", "1"))
    // 原响应是独立的值，不受改写影响
    original_text = response.text()
    original_header = response.headers.get("X-Rewritten")
    rewritten
  })
  let (client, _mock) = client_with_interceptors(
    raw_response(200, "OK", "old"),
    interceptors,
  )
  let response = client.request(@moonhttp.Config::new("/a"))
  assert_eq(original_text, "old")
  assert_eq(original_header, None)
  assert_eq(response.text(), "new")
  assert_eq(response.content_length(), 3)
  assert_eq(response.headers.get("X-Rewritten"), Some("1"))
  // 头是整体替换：原来的 Content-Type 不在新头集合里
  assert_eq(response.headers.get("Content-Type"), None)
}

///|
/// 请求拦截器抛错＝**这次请求不发出**：传输层一次都没被调用，错误带着
/// 拦截器给的错误码原样抛给调用方（`HttpError::new` 就是为此准备的）。
async test "a request interceptor can abort the request" {
  let interceptors = @moonhttp.Interceptors::new().use_request(config => {
    raise @moonhttp.HttpError::new(
      "缺少 token",
      @moonhttp.ErrorCode::BadRequest,
      config,
    )
  })
  let (client, mock) = client_with_interceptors(
    raw_response(200, "OK", "{}"),
    interceptors,
  )
  let error = interceptor_error(client, @moonhttp.Config::new("/a"))
  assert_eq(error.code(), @moonhttp.ErrorCode::BadRequest)
  assert_eq(error.message(), "缺少 token")
  assert_true(error.response() is None)
  assert_eq(mock.request_count(), 0)
}

///|
/// 非 2xx 走响应拦截器的**错误路径**（对应 axios 里 `use(f, r)` 的第二个参数）：
/// `error.response()` 上有完整响应，处理器可以就地把它降级成一个正常响应。
async test "response error handler can turn a failure into a response" {
  let interceptors = @moonhttp.Interceptors::new().use_response(
    response => response,
    on_rejected=error => {
      match error.response() {
        Some(response) =>
          response.with_status(200).with_text("降级：\{response.status}")
        None => raise error
      }
    },
  )
  let (client, _mock) = client_with_interceptors(
    raw_response(503, "ServiceUnavailable", "down"),
    interceptors,
  )
  let response = client.request(@moonhttp.Config::new("/a"))
  assert_eq(response.status, 200)
  assert_eq(response.text(), "降级：503")
}

///|
/// 重试就写在错误处理器里：拿 `error.config()` 再发一次。
///
/// 这里用**另一个不带拦截器的实例**重发（`plain`），天然不会无限递归——
/// axios 需要靠 `config._retry` 标记来挡，本项目不需要。
/// 处理器的返回值直接成为 `request` 的结果。
async test "response error handler can retry the request" {
  let mock = @transport.MockTransport::from_responses([
    raw_response(500, "InternalServerError", "boom"),
    raw_response(200, "OK", "{\"ok\":true}"),
  ])
  let transport : &@transport.Transport = mock
  let plain = @moonhttp.Client::new(transport~)
  let mut first_code : @moonhttp.ErrorCode? = None
  let interceptors = @moonhttp.Interceptors::new().use_response(
    response => response,
    on_rejected=error => {
      first_code = Some(error.code())
      plain.request(error.config())
    },
  )
  let client = @moonhttp.Client::new(transport~, interceptors~)
  let response = client.request(
    @moonhttp.Config::new("https://example.com/flaky"),
  )
  assert_eq(response.status, 200)
  assert_eq(response.text(), "{\"ok\":true}")
  // 第一次是 5xx：错误码按状态码分档，且错误里带着那份响应
  assert_eq(first_code, Some(@moonhttp.ErrorCode::BadResponse))
  assert_eq(mock.request_count(), 2)
}

///|
/// 有界重试：处理器内部用计数器挡住无限递归，重发仍失败就把错误原样抛出去。
/// 这就是文档里给的重试配方，用它可以验证「闭包改捕获的 `mut` 变量」成立。
async test "a bounded retry stops and rethrows the failure" {
  let mock = @transport.MockTransport::new(
    raw_response(500, "InternalServerError", "boom"),
  )
  let transport : &@transport.Transport = mock
  let plain = @moonhttp.Client::new(transport~)
  let mut tried = false
  let interceptors = @moonhttp.Interceptors::new().use_response(
    response => response,
    on_rejected=error => {
      if tried {
        raise error
      }
      tried = true
      plain.request(error.config())
    },
  )
  let client = @moonhttp.Client::new(transport~, interceptors~)
  let error = interceptor_error(client, @moonhttp.Config::new("/flaky"))
  assert_true(tried)
  // 原错误原样传出来：错误码与挂在错误上的响应都还在
  assert_eq(error.code(), @moonhttp.ErrorCode::BadResponse)
  assert_eq(error.response().unwrap().status, 500)
  assert_eq(mock.request_count(), 2)
}

///|
/// 拦截器**不在**重定向循环里：一次 `request` 无论跟了几跳，两段链都只跑一次。
/// 这是「不把拦截器做成传输层中间件」的直接后果——做在传输层上会每跳重跑一遍
/// （认证头重复注入、重试被放大成「跳数 × 重试次数」）。
async test "interceptors run once for the whole redirect chain" {
  let mock = @transport.MockTransport::from_responses([
    redirect_response(302, "https://example.com/b", ""),
    raw_response(200, "OK", "done"),
  ])
  let transport : &@transport.Transport = mock
  let mut requests = 0
  let mut responses = 0
  let interceptors = @moonhttp.Interceptors::new()
    .use_request(config => {
      requests = requests + 1
      config
    })
    .use_response(response => {
      responses = responses + 1
      response
    })
  let client = @moonhttp.Client::new(transport~, interceptors~)
  let response = client.request(@moonhttp.Config::new("https://example.com/a"))
  assert_eq(response.text(), "done")
  // 跟了一跳（两次发送），但两段链各自只跑了一次
  assert_eq(mock.request_count(), 2)
  assert_eq(requests, 1)
  assert_eq(responses, 1)
}

///|
/// 两个流式入口也过**请求**拦截器，但不过响应拦截器：它们的「响应」是还没读的
/// 字节流，改写与重试都没有明确语义（读法由入口决定是本项目已有的口径）。
async test "streaming entries run request interceptors only" {
  let mock = @transport.MockTransport::new(sse_response("data: hi\n\n"))
  let transport : &@transport.Transport = mock
  let mut responses = 0
  let interceptors = @moonhttp.Interceptors::new()
    .use_request(config => config.with_url("/intercepted"))
    .use_response(response => {
      responses = responses + 1
      response
    })
  let client = @moonhttp.Client::new(transport~, interceptors~)
  let stream = client.stream(@moonhttp.Config::new("/stream"))
  assert_eq(mock.last_request().unwrap().url, "/intercepted")
  ignore(stream.read_all())
  let events = client.sse(@moonhttp.Config::new("/sse"))
  assert_eq(mock.last_request().unwrap().url, "/intercepted")
  assert_true(events.next_event() is Some(_))
  assert_eq(responses, 0)
}

///|
/// 被请求拦截器拦下的错误会流到**响应侧**错误处理器（axios 的 promise 链就是
/// 这样：请求拦截器抛错后，链上的 rejected 处理器照常收到它）。
///
/// 这条语义支撑着一个实用写法——「缓存命中就不发请求」：请求拦截器发现有缓存
/// 就抛错拦下，错误处理器认出这个错误、把闭包里存着的那份响应还回去。
/// （代价是错误里没有响应可参考，只能靠错误本身认路。）
async test "an aborted request flows into the response error handler" {
  let mock = @transport.MockTransport::new(
    raw_response(200, "OK", "from server"),
  )
  let transport : &@transport.Transport = mock
  let mut cached : @moonhttp.Response? = None
  let interceptors = @moonhttp.Interceptors::new()
    .use_request(config => {
      match cached {
        // 命中缓存：不发这次请求，用一个错误把「拦下」传给响应侧。
        Some(_) =>
          raise @moonhttp.HttpError::new(
            "cache-hit",
            @moonhttp.ErrorCode::BadRequest,
            config,
          )
        None => config
      }
    })
    .use_response(response => response, on_rejected=error => {
      match (error.message(), cached) {
        ("cache-hit", Some(response)) => response
        _ => raise error
      }
    })
  let client = @moonhttp.Client::new(transport~, interceptors~)
  // 第一次：缓存是空的，正常发出去并存下响应
  cached = Some(client.request(@moonhttp.Config::new("/a")))
  assert_eq(mock.request_count(), 1)
  // 第二次：命中缓存，传输层一次都没被调用，拿到的还是那份响应
  let second = client.request(@moonhttp.Config::new("/a"))
  assert_eq(second.text(), "from server")
  assert_eq(mock.request_count(), 1)
}

///|
/// 响应侧「谁接住谁抛的错误」有一条容易记反的细节，这里按 axios 的 promise 链钉住：
/// **正常处理器抛出的错误不会落到同一对里的错误处理器**（promise 里 `then(f, r)` 的
/// `r` 只接「进入这一对之前」就已经是失败的情况），而是交给**更晚注册**的那一对。
///
/// 注册顺序是 [P1(f1, r1), P2(f2, r2)]，f1 抛错之后直接轮到 r2——r1 不会被执行。
async test "an error from a fulfilled handler goes to the next pair" {
  let mock = @transport.MockTransport::new(raw_response(200, "OK", "ok"))
  let transport : &@transport.Transport = mock
  let plain = @moonhttp.Client::new(transport~)
  let mut trace = ""
  let interceptors = @moonhttp.Interceptors::new()
    .use_response(
      _response => {
        trace = trace + "f1"
        raise @moonhttp.HttpError::new(
          "f1 抛的",
          @moonhttp.ErrorCode::BadResponse,
          @moonhttp.Config::default(),
        )
      },
      on_rejected=error => {
        trace = trace + "r1"
        raise error
      },
    )
    .use_response(response => response, on_rejected=_error => {
      trace = trace + "r2"
      // 兜底：重发一次，好让这个用例有一个正常的返回值可以断言
      plain.request(@moonhttp.Config::new("/fallback"))
    })
  let client = @moonhttp.Client::new(transport~, interceptors~)
  let response = client.request(@moonhttp.Config::new("/a"))
  assert_eq(response.text(), "ok")
  assert_eq(trace, "f1r2")
}

///|
/// `create` 派生的实例继承拦截器：`create` 在本项目是「同一个实例换套默认值」，
/// 换默认值不该把认证头、日志这些横切逻辑丢掉（与 axios 的 `create` 不同，
/// 那里造出来的是没有拦截器的新实例）。
async test "derived clients inherit interceptors" {
  let (client, mock) = client_with_interceptors(
    raw_response(200, "OK", "{}"),
    @moonhttp.Interceptors::new().use_request(config => {
      config.with_header("X-Token", "abc")
    }),
  )
  let api = client.create(
    @moonhttp.Config::default().with_base_url("https://api.example.com"),
  )
  ignore(api.request(@moonhttp.Config::new("/users")))
  let sent = mock.last_request().unwrap()
  assert_eq(sent.url, "https://api.example.com/users")
  assert_eq(sent.headers.get("X-Token"), Some("abc"))
}
