// ============================================================================
// 拦截器的注册、同名替换与按名移除。
//
// 名字唯一性与查找规则都收在本包内：包外只需要「注册」与「按名移除」两个动作，
// 不需要认识下标（下标在条件注册下会漂，这正是寻址走名字的原因）。
// ============================================================================

///|
/// 按名字找请求处理器在链上的下标；没有这个名字返回 `None`。
///
/// 名字按原样精确匹配——不做 trim、不折叠大小写：拦截器的名字永不上线，
/// 规范化只会带来「两个写法指向同一个键」这种看不见的行为。
fn request_index_of(requests : Array[RequestPair], name : String) -> Int32? {
  for i = 0; i < requests.length(); i = i + 1 {
    match requests[i].name {
      Some(existing) => if existing == name { return Some(i) }
      None => ()
    }
  }
  None
}

///|
/// 按名字找响应处理器在链上的下标；没有这个名字返回 `None`。与请求侧同规则，
/// 两侧各扫各的数组（命名空间独立）。
fn response_index_of(responses : Array[ResponsePair], name : String) -> Int32? {
  for i = 0; i < responses.length(); i = i + 1 {
    match responses[i].name {
      Some(existing) => if existing == name { return Some(i) }
      None => ()
    }
  }
  None
}

///|
/// 注册一对请求处理器：正常处理器**后注册先跑**（axios 的请求拦截器是 LIFO），
/// 错误处理器与它同向（请求侧的两条链只有一个方向，见 `docs/11-interceptors.md`）。
///
/// `on_rejected` 省略表示「这个拦截器不管错误」，错误继续交给更早注册的错误处理器
/// （与 axios 里不写第二个参数同义）。
///
/// `name` 省略 = 无名注册：链尾追加，事后撤不下来（要能撤就得现在起名）。给了名字
/// 则这条**可寻址**：同名再注册**替换原位**——位置不变，LIFO 顺序照旧，所以同一侧
/// 内不存在同名两条；`remove_request(name)` 按名撤下。名字只在请求侧内唯一，与响应侧
/// 互不相干。
///
/// 两个可选参数调用时都得写标签（可选参数不能按位置传，实测）：
/// `.use_request(f, on_rejected=r)` / `.use_request(f, name="auth")`。
pub fn Interceptors::use_request(
  self : Interceptors,
  on_request : RequestInterceptor,
  on_rejected? : RequestErrorHandler,
  name? : StringView,
) -> Interceptors {
  let on_rejected = match on_rejected {
    Some(handler) => handler
    None => error => raise error
  }
  // copy 后再改：数组可能属于别的集合（比如一份共享的基础链），就地改会让它跟着变。
  let requests = self.requests.copy()
  match name {
    None =>
      requests.push({ on_fulfilled: on_request, on_rejected, name: None, })
    Some(value) => {
      let key = value.to_owned()
      // 显式标注：两个 pair 的字段名同形，字面量单看无法判断是哪一种。
      let pair : RequestPair = {
        on_fulfilled: on_request,
        on_rejected,
        name: Some(key),
      }
      match request_index_of(requests, key) {
        Some(index) => requests[index] = pair
        None => requests.push(pair)
      }
    }
  }
  { requests, responses: self.responses, }
}

///|
/// 注册一对响应处理器：**先注册先跑**（axios 的响应拦截器是 FIFO）。
///
/// `on_rejected` 省略表示「这个拦截器不管错误」，错误继续交给更晚注册的错误
/// 处理器（与 axios 里不写第二个参数同义）。
///
/// `name` 与请求侧同规则：省略 = 无名（撤不下来，FIFO 顺序里照常跑），给了名字则
/// 同名替换原位、可用 `remove_response(name)` 撤下；名字只在响应侧内唯一。
pub fn Interceptors::use_response(
  self : Interceptors,
  on_fulfilled : ResponseInterceptor,
  on_rejected? : ResponseErrorHandler,
  name? : StringView,
) -> Interceptors {
  let on_rejected = match on_rejected {
    Some(handler) => handler
    None => error => raise error
  }
  // copy 后再改：数组可能属于别的集合，就地改会让它跟着变。
  let responses = self.responses.copy()
  match name {
    None => responses.push({ on_fulfilled, on_rejected, name: None, })
    Some(value) => {
      let key = value.to_owned()
      // 显式标注：两个 pair 的字段名同形，字面量单看无法判断是哪一种。
      let pair : ResponsePair = { on_fulfilled, on_rejected, name: Some(key), }
      match response_index_of(responses, key) {
        Some(index) => responses[index] = pair
        None => responses.push(pair)
      }
    }
  }
  { requests: self.requests, responses, }
}

///|
/// 按名撤下一个请求拦截器，返回**新的集合**；这个名字没注册过时返回 `None`。
///
/// 名字没对上就返回 `None`，不 panic，也不静默当成撤成功：拼错的名字必须立刻可见，
/// 否则「拦截器其实还在跑」是查不出来的那类 bug。`None` 时一个元素都不动，
/// 原集合可以照用。
///
/// 对应 axios 的 `eject(id)`，差别在寻址方式：axios 用 `use` 返回的数字 id，这里用注册
/// 时给的名字——下标在条件注册下会漂，名字不会。无名注册的那几条撤不下来，要撤就得在
/// 注册时起名；撤下只影响这份值，已经交给 `Client::new` 的实例不受影响。
pub fn Interceptors::remove_request(
  self : Interceptors,
  name : StringView,
) -> Interceptors? {
  let key = name.to_owned()
  match request_index_of(self.requests, key) {
    None => None
    Some(index) => {
      let requests = self.requests.copy()
      ignore(requests.remove(index))
      Some({ requests, responses: self.responses, })
    }
  }
}

///|
/// 按名撤下一个响应拦截器，返回**新的集合**；这个名字没注册过时返回 `None`。
/// 语义与 `remove_request` 相同，只是落在响应侧（FIFO 顺序里剩下的相对位置不变）。
pub fn Interceptors::remove_response(
  self : Interceptors,
  name : StringView,
) -> Interceptors? {
  let key = name.to_owned()
  match response_index_of(self.responses, key) {
    None => None
    Some(index) => {
      let responses = self.responses.copy()
      ignore(responses.remove(index))
      Some({ requests: self.requests, responses, })
    }
  }
}
