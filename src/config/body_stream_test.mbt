// 流式请求体（第五形态）的规则测试：落点、互斥、读法分流、渲染、合并与
// 重定向对流的态度。「流怎么被泵出去」归 httpconn 的真测，这里只关心
// config 层的形状——所以只需要一个不会被读的读取流占位。

///|
/// 造一个不会被读的读取流：config 层的测试不消费流，pipe 的读端足够。
fn dummy_reader() -> &@io.Reader {
  let (read_end, _write_end) = @io.pipe()
  let reader : &@io.Reader = read_end
  reader
}

///|
/// 带声明长度的流：`extract_body` 读出 Stream 形态，长度原样保留。
test "stream body keeps declared length" {
  let payload = @config.Config::default()
    .with_data_from_stream(dummy_reader(), content_length=1024)
    .extract_body()
  assert_true(payload is @config.BodyPayload::Stream(_))
  match payload {
    @config.BodyPayload::Stream(stream) =>
      assert_eq(stream.content_length, Some(1024))
    _ => fail("unreachable")
  }
}

///|
/// 不给长度就是 `None`（线上会走 chunked，那是传输层的事）。
test "stream body without length carries None" {
  let payload = @config.Config::default()
    .with_data_from_stream(dummy_reader())
    .extract_body()
  match payload {
    @config.BodyPayload::Stream(stream) =>
      assert_eq(stream.content_length, None)
    _ => fail("应是流式形态")
  }
}

///|
/// 与缓冲形态互相整体替换：后调的构建器覆盖先调的（与另外四个一样）。
test "stream and buffered bodies replace each other" {
  let as_stream = @config.Config::default()
    .with_data_from_str("first")
    .with_data_from_stream(dummy_reader())
  assert_true(as_stream.has_stream_body())
  let as_buffered = @config.Config::default()
    .with_data_from_stream(dummy_reader())
    .with_data_from_str("second")
  assert_false(as_buffered.has_stream_body())
  assert_eq(as_buffered.serialize_body().bytes, Some(b"second"))
}

///|
/// `serialize_body` 对流式形态返回空：流没有「待发送字节」，读法走
/// `extract_body`——这里钉住「不会有人误把流形态序列化成空请求体还当成功」。
test "serialize_body returns empty for stream form" {
  let serialized = @config.Config::default()
    .with_data_from_stream(dummy_reader())
    .serialize_body()
  assert_eq(serialized.bytes, None)
  assert_eq(serialized.content_type, None)
}

///|
/// `extract_body` 的另一侧：缓冲形态仍然给字节（分流不改变原语义）。
test "extract_body keeps buffered forms as bytes" {
  let payload = @config.Config::default()
    .with_data_from_json({ "a": 1 })
    .extract_body()
  match payload {
    @config.BodyPayload::Buffered(serialized) => {
      assert_eq(serialized.bytes, Some(b"{\"a\":1}"))
      assert_eq(serialized.content_type, Some("application/json"))
    }
    _ => fail("应是缓冲形态")
  }
  // 没有 body 时也是缓冲侧的全空。
  let empty = @config.Config::default().extract_body()
  match empty {
    @config.BodyPayload::Buffered(serialized) => {
      assert_eq(serialized.bytes, None)
      assert_eq(serialized.content_type, None)
    }
    _ => fail("无 body 应落在缓冲侧")
  }
}

///|
/// 渲染：流不读内容，只给「是不是流、多长」。
test "to_string renders stream form without reading it" {
  let known = @config.Config::default()
    .with_data_from_stream(dummy_reader(), content_length=7)
    .to_string()
  assert_true(known.contains("<stream 7 bytes>"))
  let unknown = @config.Config::default()
    .with_data_from_stream(dummy_reader())
    .to_string()
  assert_true(unknown.contains("<stream unknown bytes>"))
}

///|
/// 合并对 data 只取请求级：实例默认值里的流不会渗进合并结果——
/// 流是一次性资源，被「静默复制使用」比丢弃更危险。
test "merge drops instance-level stream body" {
  let defaults = @config.Config::default().with_data_from_stream(dummy_reader())
  let merged = @config.merge_config(defaults, @config.Config::default())
  assert_false(merged.has_stream_body())
}

///|
/// 重定向对流的态度：303 降 GET 时连流一起丢（降级后不需要 body）；
/// 307 保持方法、要原样重发 body，下一跳配置里流还在——由根包的
// 重定向循环检测并报错（docs/20）。
test "redirect keeps stream body only when method is preserved" {
  let put = @config.Config::new("https://api.example.com/upload")
    .with_method(@config.Method::Put)
    .with_data_from_stream(dummy_reader())
  // 303：改写成 GET，data 清空
  let see_other = put.next_redirect(
    "https://api.example.com/upload",
    303,
    Some("/done"),
  )
  match see_other {
    Some(next) => assert_false(next.has_stream_body())
    None => fail("303 应该跟随")
  }
  // 307：方法与 data 原样保留
  let temporary = put.next_redirect(
    "https://api.example.com/upload",
    307,
    Some("/elsewhere"),
  )
  match temporary {
    Some(next) => assert_true(next.has_stream_body())
    None => fail("307 应该跟随")
  }
}
