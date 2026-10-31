// ============================================================================
// 三条链的驱动：顺序与错误流转。全部是包私有函数，
// 只被 `pipeline.mbt` 的 `Client::request`（与 `stream_entry.mbt` 的
// 请求侧正常链）调用。
// ============================================================================

///|
/// 跑请求侧正常链：**后注册先跑**（LIFO，与 axios 一致），每个拦截器拿到的都是
/// 上一个（更晚注册的）拦截器交出来的配置。
///
/// 拦截器抛错就原样抛（`raise HttpError`）：被拦下意味着「这次请求不发了」，
/// 这个错误交给谁收口由调用方决定——`Client::request` 把它和派发阶段的失败
/// 一起收进 `stage`，再交给请求侧错误处理器；两个流式入口没有错误处理器，
/// 直接抛给调用方。不要在链内部先包成 `Result`：那只是让同一次失败多绕一层。
async fn Interceptors::run_request(
  self : Interceptors,
  config : Config,
) -> Config raise HttpError {
  let mut current = config
  for i = self.requests.length() - 1; i >= 0; i = i - 1 {
    // 字段里的函数值要先绑到局部变量再调：`pair.on_fulfilled(x)` 会被当成
    // 「在 `RequestPair` 上找一个叫 on_fulfilled 的方法」。
    let on_request = self.requests[i].on_fulfilled
    // 抛错即中止：后面的（更早注册的）拦截器不再跑，错误直接出链。
    current = on_request(current)
  }
  current
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
