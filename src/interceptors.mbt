// ============================================================================
// 拦截器：请求侧（改配置）与响应侧（改响应 / 救错重试）的两段式
//
// 对应 axios 的 `interceptors.request` / `interceptors.response`，语义逐条对齐：
// 请求侧**后注册先跑**（LIFO）、响应侧**先注册先跑**（FIFO）、非 2xx 与传输失败
// 都走响应侧的**错误处理器**（重试的落点）。落点、顺序与「为什么不做成洋葱中间件」
// 见 `docs/11-interceptors.md`。
//
// 为什么挂在 `Client`（而不是像 `params_serializer` 那样进 `Config`）：`Response`
// 与 `HttpError` 定义在根包，`config` 包反向引用会成环；而且 axios 的
// `interceptors` 本来就是**实例级**（`axios.interceptors` / `instance.interceptors`），
// 不是请求级——挂在实例上才是对齐。
//
// 文件内的分区（顺序无关，用区块注释标出）：
//   1. 三个函数类型   —— 拦截器 / 响应拦截器 / 响应错误处理器的契约
//   2. Interceptors   —— 收集与注册（链式、值语义）
//   3. 两条链的驱动   —— 顺序与错误流转（包私有，由 `client.mbt` 调）
// ============================================================================

// ---------------------------------------------------------------------------
// 1. 三个函数类型 —— 拦截器的契约
// ---------------------------------------------------------------------------

///|
/// 请求拦截器：拿到**合并后**的配置，返回（可能改写过的）配置。
///
/// 拿到的已经是「实例默认值 + 本次请求配置」的合并结果（与 axios 一致），所以
/// 可以直接改地址、加头、换请求体，甚至换方法。抛错表示**拦下这次请求**：请求
/// 不会发出，错误按 axios 的 promise 链语义交给响应侧的错误处理器
/// （`HttpError::new` 就是给这种中止准备的，见 `http_error.mbt`）。
///
/// 类型带 `async` 与 `raise HttpError` 不是装饰：`raise` 让拦截器能中止请求，
/// `async` 让「发请求前先去别处取一个 token」这类事写在同一处。代价是**具名同步
/// 函数不能直接传进来**——MoonBit 的效果推断只认箭头语法，写成 `config => ...`
/// 或用 `async fn` 显式标注即可。
pub type RequestInterceptor = async (Config) -> Config raise HttpError

///|
/// 响应拦截器（正常路径）：拿到最终的 `Response`，返回（可能改写过的）响应。
///
/// 只在 `Client::request` 上跑：`stream` / `sse` 的「响应」是还没读的字节流，
/// 改写与重试都没有明确语义（读法由入口决定是本项目已有的口径）。改写响应用
/// `Response::with_status` / `with_headers` / `with_body` / `with_text`。
pub type ResponseInterceptor = async (Response) -> Response raise HttpError

///|
/// 响应拦截器的错误路径，对应 axios 里 `use(onFulfilled, onRejected)` 的第二个
/// 参数。三类错误都会走到这里：非 2xx（`HttpError::response()` 上有完整响应，
/// 状态码、响应头、错误正文都在）、传输失败（超时、断连，`response()` 可能是
/// `None` 或只有半截正文）、以及被请求拦截器拦下的请求。
///
/// 返回一个 `Response` 表示**这个错误已经处理掉**，它会作为 `request` 的结果
/// 返回；`raise error` 表示不处理、继续往外传——与 axios 的
/// `Promise.reject(error)` 等价。重试就是在这里再发一次请求。
pub type ResponseErrorHandler = async (HttpError) -> Response raise HttpError

// ---------------------------------------------------------------------------
// 2. Interceptors —— 收集与注册
// ---------------------------------------------------------------------------

///|
/// 一对响应处理器。**私有**（不标 `priv` 会出现在 `.mbti` 里）：注册时成对给
/// （对齐 axios 的 `use(f, r)`），两个处理器的**相对位置**才是语义所在——
/// 错误处理器接住的是「排在它前面」的一切抛出的错误（请求侧、派发、更早注册的
/// 处理器），**不包括同一对里正常处理器抛出的错误**：那个由更晚注册的错误处理
/// 器接（promise 链里 `then(f, r)` 的 `r` 只处理「进入这一对之前」已是失败的
/// 情况，`src/interceptor_test.mbt` 有一条用例钉着）。
priv struct ResponsePair {
  on_fulfilled : ResponseInterceptor
  on_rejected : ResponseErrorHandler
}

///|
/// 拦截器的集合，对应 axios 实例上的 `interceptors`。
///
/// 链式构建、**值语义**：`use_*` 不改自己，而是返回追加后的新值（与
/// `FormData::append_text` 同一口径——数组是共享的，就地改会让别的集合跟着变）。
/// 传给 `Client::new` 之后视作冻结。
///
/// ```moonbit nocheck
/// let client = @moonhttp.Client::new(
///   interceptors=@moonhttp.Interceptors::new()
///     .use_request(config => config.with_header("X-Token", token))
///     .use_response(response => response.with_text(unwrap(response.text()))),
/// )
/// ```
pub struct Interceptors {
  priv requests : Array[RequestInterceptor]
  priv responses : Array[ResponsePair]
}

///|
/// 空的拦截器集合：一条链都不挂。
pub fn Interceptors::new() -> Interceptors {
  { requests: [], responses: [], }
}

///|
/// 追加一个请求拦截器：**后注册的先跑**（axios 的请求拦截器是 LIFO）。
pub fn Interceptors::use_request(
  self : Interceptors,
  on_request : RequestInterceptor,
) -> Interceptors {
  let requests = self.requests.copy()
  requests.push(on_request)
  { requests, responses: self.responses, }
}

///|
/// 追加一对响应处理器：**先注册的先跑**（axios 的响应拦截器是 FIFO）。
///
/// `on_rejected` 省略表示「这个拦截器不管错误」，错误继续交给更晚注册的错误
/// 处理器（与 axios 里不写第二个参数同义）。
pub fn Interceptors::use_response(
  self : Interceptors,
  on_fulfilled : ResponseInterceptor,
  on_rejected? : ResponseErrorHandler,
) -> Interceptors {
  let on_rejected = match on_rejected {
    Some(handler) => handler
    None => error => raise error
  }
  let responses = self.responses.copy()
  responses.push({ on_fulfilled, on_rejected, })
  { requests: self.requests, responses, }
}

// ---------------------------------------------------------------------------
// 3. 两条链的驱动 —— 顺序与错误流转
// ---------------------------------------------------------------------------

///|
/// 跑请求侧链：**后注册先跑**（LIFO，与 axios 一致），每个拦截器拿到的都是
/// 上一个（更晚注册的）拦截器交出来的配置。
///
/// 不抛错而是返回 `Result`：被拦下不是本函数的异常，而是「这次请求不发了」，
/// 按 axios 的 promise 链语义应当交给下游的响应侧错误处理器——交给谁由调用方
/// 决定（`request` 交给响应侧，两个流式入口没有响应侧链，直接抛）。
/// 因此这里显式标 `noraise`：拦截器抛出的错误全部收进了 `Err`，调用方不必
/// （也不该）在自己的错误类型里为它留位置。
async fn Interceptors::run_request(
  self : Interceptors,
  config : Config,
) -> Result[Config, HttpError] noraise {
  let mut outcome : Result[Config, HttpError] = Ok(config)
  for i = self.requests.length() - 1; i >= 0; i = i - 1 {
    let interceptor = self.requests[i]
    outcome = match outcome {
      // 正常路径：交出配置；拦截器抛错就转成「已拦下」。
      Ok(current) => Ok(interceptor(current)) catch { error => Err(error) }
      // 已经被拦下：请求侧没有错误处理器（axios 那一对 rejected 里「拦截器之间
      // 互相救错」这一半本版本有意不做，理由见 docs/11-interceptors.md）。
      Err(error) => Err(error)
    }
  }
  outcome
}

///|
/// 跑响应侧链：**先注册先跑**（FIFO，与 axios 一致），并把请求侧可能已经抛下的
/// 错误一起带上。
///
/// 与 axios 的 promise 链同构：`Ok` 走正常处理器、`Err` 走错误处理器；处理器
/// 自己抛出的错误落到**更晚注册**的错误处理器手里，没人接住就抛给调用方。
/// 所以「重试」写在哪里是有讲究的：越早注册的错误处理器越先看到错误。
async fn Interceptors::run_response(
  self : Interceptors,
  outcome : Result[Response, HttpError],
) -> Response raise HttpError {
  let mut state = outcome
  for pair in self.responses {
    // 字段里的函数值要先绑到局部变量再调：`pair.on_fulfilled(x)` 会被当成
    // 「在 `ResponsePair` 上找一个叫 on_fulfilled 的方法」。
    let on_fulfilled = pair.on_fulfilled
    let on_rejected = pair.on_rejected
    state = match state {
      Ok(response) => Ok(on_fulfilled(response)) catch { error => Err(error) }
      Err(error) => Ok(on_rejected(error)) catch { error => Err(error) }
    }
  }
  match state {
    Ok(response) => response
    Err(error) => raise error
  }
}
