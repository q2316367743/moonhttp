// ============================================================================
// 拦截器：请求侧（改配置 / 救错）与响应侧（改响应 / 救错）的四段式。
//
// 对应 axios 的 `interceptors.request` / `interceptors.response`，顺序规则逐条对齐：
// 请求侧的链**后注册先跑**（LIFO）、响应侧**先注册先跑**（FIFO）。与 axios 的一处
// 有意差异是**错误按来源分流**：请求阶段的失败（被拦下、连不上、超时、被取消、
// 重定向超限、读响应体失败）只走请求侧的错误处理器，响应侧的错误处理器**只**接
// 「请求已经成功、但状态码没通过校验（默认非 2xx）」。两条错误链的落点、顺序与
// 「为什么与 axios 不一样」见 `docs/11-interceptors.md`。
//
// 为什么挂在 `Client`（而不是像 `params_serializer` 那样进 `Config`）：拦截器的
// 签名要提 `Response` / `HttpError`，它们在 `config` 的下游包里，`config` 反向
// 引用会成环；而且 axios 的 `interceptors` 本来就是**实例级**
// （`axios.interceptors` / `instance.interceptors`），不是请求级——挂在实例上
// 才是对齐。
//
// 文件分工（同包，顺序无关）：
//   interceptors.mbt          —— 四个函数类型 + 集合类型（本文件）
//   interceptors_registry.mbt —— 注册、同名替换与按名移除
//   interceptors_chain.mbt    —— 三条链的驱动（包私有，由 `pipeline.mbt` 调）
// ============================================================================

// ---------------------------------------------------------------------------
// 四个函数类型 —— 拦截器与错误处理器的契约
// ---------------------------------------------------------------------------

///|
/// 请求拦截器：拿到**合并后**的配置，返回（可能改写过的）配置。
///
/// 拿到的已经是「实例默认值 + 本次请求配置」的合并结果（与 axios 一致），所以
/// 可以直接改地址、加头、换请求体，甚至换方法。抛错表示**拦下这次请求**：请求
/// 不会发出，错误按来源分流交给**请求侧**的错误处理器
/// （`HttpError::new` 就是给这种中止准备的，见 `http_error` 包）。
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
// Interceptors —— 集合类型
//
// 「同一侧内名字唯一」是不变量：带名字的注册要么追加、要么原地换掉
// 同名那条，于是 `remove_*` 撤哪个没有歧义（维护逻辑在 interceptors_registry.mbt）。
// ---------------------------------------------------------------------------

///|
/// 一对请求处理器。**私有**（不标 `priv` 会出现在 `.mbti` 里）：注册时成对给
/// （对齐 axios 的 `use(f, r)`），两个处理器的**相对位置**才是语义所在——
/// `on_rejected` 接住的是「被本拦截器或更晚注册的拦截器拦下」以及派发阶段的失败，
/// 与更早注册的处理器无关。
priv struct RequestPair {
  on_fulfilled : RequestInterceptor
  on_rejected : RequestErrorHandler
  /// 注册时给的名字，`None` = 无名注册（事后撤不下来）
  name : String?
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
  /// 注册时给的名字，`None` = 无名注册（事后撤不下来）
  name : String?
}

///|
/// 拦截器的集合，对应 axios 实例上的 `interceptors`。
///
/// 链式构建、**值语义**：`use_*` 与 `remove_*` 都不改自己，而是返回改动后的新值
/// （与 `FormData::append_text` 同一口径——数组是共享的，就地改会让别的集合跟着变）。
/// 传给 `Client::new` 之后视作冻结：实例拿的是当时那份值，之后的注册与移除都不会
/// 影响到它——所以要给某个实例换链，就是换一份值重建（没有实例级的读写口）。
///
/// 注册时可以给一条起名（`use_request(f, name="auth")`）：名字让这条**可寻址**
/// ——同名再注册替换原位、`remove_request(name)` 按名撤下，用途是「一份共享的基础链
/// 按客户端裁剪」，这是 `Client::create` 整份继承拦截器时唯一能表达「少挂一条」的
/// 手段。无名注册的撤不下来，撤链要走名字。
///
/// ```moonbit nocheck
/// let client = @moonhttp.Client::new(
///   interceptors=@moonhttp.Interceptors::new()
///     .use_request(config => config.with_header("X-Token", token), name="auth")
///     .use_response(response => response.with_text(unwrap(response.text()))),
/// )
///
/// // 共享一份基础链，按客户端裁剪：不必把链再抄一遍，基础链演进时也不会漂
///
/// let base = @moonhttp.Interceptors::new()
///   .use_request(config => config.with_header("X-Token", token), name="auth")
///   .use_response(rewrite_json, name="rewrite")
///
/// let trimmed = base.remove_response("rewrite").unwrap()
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
