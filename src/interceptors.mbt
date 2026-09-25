// ============================================================================
// 拦截器：请求侧（改配置 / 救错）与响应侧（改响应 / 救错）的四段式
//
// 对应 axios 的 `interceptors.request` / `interceptors.response`，顺序规则逐条对齐：
// 请求侧的链**后注册先跑**（LIFO）、响应侧**先注册先跑**（FIFO）。与 axios 的一处
// 有意差异是**错误按来源分流**：请求阶段的失败（被拦下、连不上、超时、被取消、
// 重定向超限、读响应体失败）只走请求侧的错误处理器，响应侧的错误处理器**只**接
// 「请求已经成功、但状态码没通过校验（默认非 2xx）」。两条错误链的落点、顺序与
// 「为什么与 axios 不一样」见 `docs/11-interceptors.md`。
//
// 为什么挂在 `Client`（而不是像 `params_serializer` 那样进 `Config`）：`Response`
// 与 `HttpError` 定义在根包，`config` 包反向引用会成环；而且 axios 的
// `interceptors` 本来就是**实例级**（`axios.interceptors` / `instance.interceptors`），
// 不是请求级——挂在实例上才是对齐。
//
// 文件内的分区（顺序无关，用区块注释标出）：
//   1. 四个函数类型   —— 拦截器 / 错误处理器的契约
//   2. Interceptors   —— 收集与注册（链式、值语义）
//   3. 三条链的驱动   —— 顺序与错误流转（包私有，由 `client.mbt` 调）
// ============================================================================

// ---------------------------------------------------------------------------
// 1. 四个函数类型 —— 拦截器与错误处理器的契约
// ---------------------------------------------------------------------------

///|
/// 请求拦截器：拿到**合并后**的配置，返回（可能改写过的）配置。
///
/// 拿到的已经是「实例默认值 + 本次请求配置」的合并结果（与 axios 一致），所以
/// 可以直接改地址、加头、换请求体，甚至换方法。抛错表示**拦下这次请求**：请求
/// 不会发出，错误按来源分流交给**请求侧**的错误处理器
/// （`HttpError::new` 就是给这种中止准备的，见 `http_error.mbt`）。
///
/// 类型带 `async` 与 `raise HttpError` 不是装饰：`raise` 让拦截器能中止请求，
/// `async` 让「发请求前先去别处取一个 token」这类事写在同一处。代价是**具名同步
/// 函数不能直接传进来**——MoonBit 的效果推断只认箭头语法，写成 `config => ...`
/// 或用 `async fn` 显式标注即可。
pub type RequestInterceptor = async (Config) -> Config raise HttpError

///|
/// 请求侧的错误处理器，对应 axios 里 `interceptors.request.use(f, r)` 的第二个
/// 参数（但覆盖面不同：axios 的请求侧 `r` 接不到派发失败，这里接得到）。
///
/// 拿到的是**请求阶段**的失败：被请求拦截器拦下、配置拼不出可发送的请求（缺 url、
/// 代理缺 host）、连不上、超时、被取消、重定向超限、读响应体的中途失败。
/// 返回一个 `Response` 表示**这次失败就地救回来**，它会作为 `request` 的结果返回；
/// `raise error` 表示不处理、交给更早注册的错误处理器（请求侧错误链是**后注册
/// 先跑**），都没有接住就抛给调用方——与 axios 的 `Promise.reject(error)` 等价。
///
/// 救回的响应**不再经过响应侧链**：响应侧管的是「服务端这次返回的响应」，而救回的
/// 多半是缓存里存的、或本地兜底合成的，两段链各管一段。要让它也走一遍响应改写，
/// 在处理器里自己调一次改写函数即可。
///
/// 重试写在处理器体内：拿 `error.config()` 用另一个不带这层拦截器的实例再发一次
/// （与响应侧那份配方一样），见 `docs/11-interceptors.md`。
///
/// 签名与 `ResponseErrorHandler` 完全相同，分开命名是为了让两段链各自自解释、
/// 也让 `.mbti` 一眼看出这个处理器属于哪一侧。
pub type RequestErrorHandler = async (HttpError) -> Response raise HttpError

///|
/// 响应拦截器（正常路径）：拿到最终的 `Response`，返回（可能改写过的）响应。
///
/// 只在 `Client::request` 上跑：`stream` / `sse` 的「响应」是还没读的字节流，
/// 改写与重试都没有明确语义（读法由入口决定是本项目已有的口径）。改写响应用
/// `Response::with_status` / `with_headers` / `with_body` / `with_text` / `with_json`；
/// 「解析 → 处理 → 写回」的配方（`json()` 抛 `@json.ParseError`，要用 `try ... catch`
/// 收掉）见 `docs/11-interceptors.md`。
pub type ResponseInterceptor = async (Response) -> Response raise HttpError

///|
/// 响应侧的错误处理器，对应 axios 里 `interceptors.response.use(f, r)` 的第二个参数。
///
/// **只接「请求已经成功、但状态码没通过校验」（默认只放行 2xx）**：这时
/// `HttpError::response()` 上有完整响应，状态码、响应头、错误正文都在手里，可以就地
/// 降级成正常响应、改写成统一形状，或重发一次。请求阶段的失败（连不上、超时、
/// 被取消、被请求拦截器拦下）**不进这里**，它们由 `RequestErrorHandler` 接
/// ——这条分流是本项目与 axios 的 promise 链有意不同的地方，理由见
/// `docs/11-interceptors.md`。
///
/// 返回一个 `Response` 表示**这个错误已经处理掉**，它会作为 `request` 的结果
/// 返回；`raise error` 表示不处理、继续往外传——与 axios 的
/// `Promise.reject(error)` 等价。重试就是在这里再发一次请求。
pub type ResponseErrorHandler = async (HttpError) -> Response raise HttpError

// ---------------------------------------------------------------------------
// 2. Interceptors —— 收集与注册
// ---------------------------------------------------------------------------

///|
/// 一对请求处理器。**私有**（不标 `priv` 会出现在 `.mbti` 里）：注册时成对给
/// （对齐 axios 的 `use(f, r)`），两个处理器的**相对位置**才是语义所在——
/// `on_rejected` 接住的是「被本拦截器或更晚注册的拦截器拦下」以及派发阶段的失败，
/// 与更早注册的处理器无关。
priv struct RequestPair {
  on_fulfilled : RequestInterceptor
  on_rejected : RequestErrorHandler
}

///|
/// 一对响应处理器。**私有**（不标 `priv` 会出现在 `.mbti` 里）：注册时成对给
/// （对齐 axios 的 `use(f, r)`），两个处理器的**相对位置**才是语义所在——
/// 错误处理器接住的是「排在它前面」的一切抛出的错误（状态码校验失败、更早注册的
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
  priv requests : Array[RequestPair]
  priv responses : Array[ResponsePair]
}

///|
/// 空的拦截器集合：一条链都不挂。
pub fn Interceptors::new() -> Interceptors {
  { requests: [], responses: [], }
}

///|
/// 追加一对请求处理器：正常处理器**后注册先跑**（axios 的请求拦截器是 LIFO），
/// 错误处理器与它同向（请求侧的两条链只有一个方向，见 `docs/11-interceptors.md`）。
///
/// `on_rejected` 省略表示「这个拦截器不管错误」，错误继续交给更早注册的错误处理器
/// （与 axios 里不写第二个参数同义）。它是可选参数，调用时得写标签：
/// `.use_request(f, on_rejected=r)`——可选参数不能按位置传（实测）。
pub fn Interceptors::use_request(
  self : Interceptors,
  on_request : RequestInterceptor,
  on_rejected? : RequestErrorHandler,
) -> Interceptors {
  let on_rejected = match on_rejected {
    Some(handler) => handler
    None => error => raise error
  }
  let requests = self.requests.copy()
  requests.push({ on_fulfilled: on_request, on_rejected, })
  { requests, responses: self.responses, }
}

///|
/// 追加一对响应处理器：**先注册先跑**（axios 的响应拦截器是 FIFO）。
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
// 3. 三条链的驱动 —— 顺序与错误流转
// ---------------------------------------------------------------------------

///|
/// 跑请求侧正常链：**后注册先跑**（LIFO，与 axios 一致），每个拦截器拿到的都是
/// 上一个（更晚注册的）拦截器交出来的配置。
///
/// 不抛错而是返回 `Result`：被拦下不是本函数的异常，而是「这次请求不发了」，
/// 按来源分流应当交给请求侧的错误处理器——交给谁由调用方决定（`request` 交给
/// `run_request_errors`，两个流式入口没有错误处理器，直接抛）。
/// 因此这里显式标 `noraise`：拦截器抛出的错误全部收进了 `Err`，调用方不必
/// （也不该）在自己的错误类型里为它留位置。
async fn Interceptors::run_request(
  self : Interceptors,
  config : Config,
) -> Result[Config, HttpError] noraise {
  let mut outcome : Result[Config, HttpError] = Ok(config)
  for i = self.requests.length() - 1; i >= 0; i = i - 1 {
    // 字段里的函数值要先绑到局部变量再调：`pair.on_fulfilled(x)` 会被当成
    // 「在 `RequestPair` 上找一个叫 on_fulfilled 的方法」。
    let on_request = self.requests[i].on_fulfilled
    outcome = match outcome {
      // 正常路径：交出配置；拦截器抛错就转成「已拦下」。
      Ok(current) => Ok(on_request(current)) catch { error => Err(error) }
      // 已经被拦下：正常处理器全部跳过，错误留给错误链。
      Err(error) => Err(error)
    }
  }
  outcome
}

///|
/// 跑请求侧错误链：**后注册先跑**（与请求侧正常链同向，理由见
/// `docs/11-interceptors.md`）。
///
/// 每个错误处理器拿到当前错误：返回 `Response` 表示就地救回，立刻结束（这次请求
/// 的结果就是它）；`raise error` 表示不处理，把（可能是自己新造的）错误交给更早
/// 注册的处理器。全部没接住就抛最后那个错误——与 axios 的 promise 链一样，
/// 错误处理器可以「换一个错误继续往外传」。
async fn Interceptors::run_request_errors(
  self : Interceptors,
  error : HttpError,
) -> Response raise HttpError {
  let mut current = error
  let mut rescued : Response? = None
  for i = self.requests.length() - 1; i >= 0; i = i - 1 {
    // 救回来之后剩下的处理器不再打扰：链的意义就是「谁接住就谁说了算」。
    if rescued is None {
      let on_rejected = self.requests[i].on_rejected
      let outcome = Ok(on_rejected(current)) catch { e => Err(e) }
      match outcome {
        Ok(response) => rescued = Some(response)
        Err(next) => current = next
      }
    }
  }
  match rescued {
    Some(response) => response
    None => raise current
  }
}

///|
/// 跑响应侧链：**先注册先跑**（FIFO，与 axios 一致）。
///
/// 进来的 `outcome` 只有两种来源：通过校验的响应，或**状态码没通过校验**的错误
/// （请求阶段的失败不进这里，它们走 `run_request_errors`）。与 axios 的 promise
/// 链同构：`Ok` 走正常处理器、`Err` 走错误处理器；处理器自己抛出的错误落到
/// **更晚注册**的错误处理器手里，没人接住就抛给调用方。
/// 所以「状态码失败的重试」写在哪里是有讲究的：越早注册的错误处理器越先看到错误。
async fn Interceptors::run_response(
  self : Interceptors,
  outcome : Result[Response, HttpError],
) -> Response raise HttpError {
  let mut state = outcome
  for pair in self.responses {
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
