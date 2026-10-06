#!/usr/bin/env python3
"""moonhttp 的共享靶子 server：用成熟运行时把 HTTP 语义摆正，供 src/main 下的
示例包打真实请求。一条命令起全套路由，示例包自己不再起服务器：

    python3 test/server.py [--port 18777]

设计约定：
- 每条路由都把「服务端实际收到了什么」回吐出来（回显头 / 回显 JSON）——
  客户端的自我声明不算数，服务端视角才是证据；
- 始终 HTTP/1.1 + keep-alive，Content-Length / chunked 两种分帧都有；
- WebDAV 等自定义方法直接支持（Python 的 http.server 按方法名派发，
  没有封闭枚举的问题——这正是选它当靶子的原因）。

路由一览（各段的断言见对应示例包的 cases 文件）：
  ANY  /echo                     回显方法/路径/query/头/请求体（JSON）
  ANY  /upload                   读干净任意分帧的请求体，回执字节数与摘要（流式上传的靶子）
  GET  /gzip                     按 Accept-Encoding 决定 gzip 与否，声明回吐在 X-Accept-Encoding
  GET  /bytes?n=&fill=           定长二进制（Content-Length 分帧）
  GET  /bytes-chunked?n=         同样字节数（chunked 分帧）
  GET  /drip                     分块慢吐（流式逐块读取的靶子）
  GET  /slow?delay=              睡够再回（timeout 的靶子）
  GET  /status/{code}            返回指定状态码
  ANY  /method                   回显请求行里的方法（自定义方法的靶子）
  ANY  /redirect/chain/{n}       连跳 n 级到 /final
  ANY  /redirect/to/{code}       用指定 3xx 跳到 /final
  ANY  /redirect/loop            自己指自己
  ANY  /redirect/cross-host      302 到 localhost（跨 host 证据）
  ANY  /final                    终点：回显方法/正文长度/Authorization/Cookie
  GET  /cookies/set?name=...     种 / 刷新 / 删除（Max-Age=0）/ 限定（Path/Secure）cookie
  GET  /cookies/whoami           回显收到的 Cookie 头
  ANY  /scoped/whoami            同上，但在 /scoped 路径下（Path 限定匹配的证据）
  GET  /http10                   裸 HTTP/1.0 响应（无 Content-Length，靠连接关闭收尾）
"""

import argparse
import gzip
import hashlib
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "moonhttp-target/1.0"

    # 所有方法都落进同一段路由（BaseHTTPRequestHandler 按 do_<METHOD> 派发；
    # 后面那排 WebDAV 方法正是官方 MoonBit server 发不出来的）
    def _handle(self):
        path = urlparse(self.path).path
        try:
            if path == "/echo":
                self._reply_json(self._echo())
            elif path == "/upload":
                self._upload()
            elif path == "/gzip":
                self._gzip()
            elif path == "/bytes":
                self._bytes(chunked=False)
            elif path == "/bytes-chunked":
                self._bytes(chunked=True)
            elif path == "/drip":
                self._drip()
            elif path == "/slow":
                time.sleep(int(self._query().get("delay", "800")) / 1000)
                self._reply_text("finally")
            elif path.startswith("/status/"):
                code = int(path.rsplit("/", 1)[1])
                self._reply_text(f"status={code}", status=code)
            elif path == "/method":
                self._reply_json({"method": self.command, "path": path})
            elif path.startswith("/redirect/"):
                self._redirect(path)
            elif path == "/final":
                self._final()
            elif path == "/cookies/set":
                self._cookie_set()
            elif path in ("/cookies/whoami", "/scoped/whoami"):
                self._reply_json({"cookie": self.headers.get("Cookie") or ""})
            elif path == "/http10":
                self._http10()
            else:
                self._reply_text("not found", status=404)
        except (BrokenPipeError, ConnectionResetError):
            # 客户端提前关闭（提前 close 的用例）不该把线程带出堆栈
            self.close_connection = True

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_OPTIONS = _handle
    do_HEAD = do_TRACE = do_PROPFIND = do_MKCOL = do_COPY = do_MOVE = _handle
    do_LOCK = do_UNLOCK = do_REPORT = do_PROPPATCH = _handle

    # ---- 各路由的实现 ----

    def _echo(self):
        body = self._read_body()
        parsed = urlparse(self.path)
        return {
            "method": self.command,
            "path": parsed.path,
            "query": parsed.query,
            "headers": {k.lower(): v for k, v in self.headers.items()},
            "body_len": len(body),
            "body_preview": body.decode("utf-8", "replace")[:240],
        }

    def _upload(self):
        # 读干净任意分帧（Content-Length 或 chunked）的请求体并回执收到多少：
        # 客户端流式上传的两种线上形态（docs/20）都从这里拿到服务端视角的证据。
        body = self._read_request_body()
        self._reply_json({
            "method": self.command,
            "framing": self._request_framing(),
            "received_bytes": len(body),
            "sha256_prefix": hashlib.sha256(body).hexdigest()[:16],
        })

    def _request_framing(self):
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            return "chunked"
        return "content-length"

    def _read_request_body(self):
        # Python 的 http.server 不会自动解码 chunked 请求体，这里手写一个
        # 最小解码（hex 长度行 + 数据 + CRLF，直到 0 长度终止帧）
        if self._request_framing() == "chunked":
            out = bytearray()
            while True:
                size_line = self.rfile.readline().strip()
                size = int(size_line.split(b";")[0], 16)
                if size == 0:
                    # 终止帧后的 trailer 节读到空行为止（本项目不发 trailer）
                    while True:
                        line = self.rfile.readline()
                        if line in (b"\r\n", b"\n", b""):
                            break
                    break
                out += self.rfile.read(size)
                self.rfile.read(2)  # chunk 数据后的 CRLF
            return bytes(out)
        return self._read_body()

    def _gzip(self):
        accept = self.headers.get("Accept-Encoding", "")
        payload = ("这段正文在线上是 gzip 字节——解压之后才是原文。" * 8).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        # 服务端视角的声明回吐：客户端声明了什么，这里原样还给它们看
        self.send_header("X-Accept-Encoding", accept)
        if "gzip" in accept:
            body = gzip.compress(payload)
            self.send_header("Content-Encoding", "gzip")
        else:
            body = payload
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _bytes(self, chunked):
        query = self._query()
        n = int(query.get("n", "1024"))
        fill = query.get("fill", "A").encode()
        body = (fill * n)[:n]
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        if chunked:
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            piece = 64 * 1024
            for off in range(0, len(body), piece):
                part = body[off:off + piece]
                self.wfile.write(f"{len(part):x}\r\n".encode() + part + b"\r\n")
            self.wfile.write(b"0\r\n\r\n")
        else:
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

    def _drip(self):
        query = self._query()
        chunks = int(query.get("chunks", "5"))
        size = int(query.get("size", "65536"))
        delay = int(query.get("delay", "30")) / 1000
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        piece = b"z" * size
        for _ in range(chunks):
            self.wfile.write(f"{size:x}\r\n".encode() + piece + b"\r\n")
            self.wfile.flush()
            time.sleep(delay)
        self.wfile.write(b"0\r\n\r\n")

    def _redirect(self, path):
        port = self.server.server_address[1]
        if path.startswith("/redirect/chain/"):
            depth = int(path.rsplit("/", 1)[1])
            loc = f"/redirect/chain/{depth - 1}" if depth > 0 else "/final"
            self._redirect_to(302, loc)
        elif path.startswith("/redirect/to/"):
            self._redirect_to(int(path.rsplit("/", 1)[1]), "/final")
        elif path == "/redirect/loop":
            self._redirect_to(302, "/redirect/loop")
        elif path == "/redirect/cross-host":
            # localhost 与 127.0.0.1 是两个 host 字符串：跨 host 的剥凭据 /
            # cookie 不跟随，都靠这一跳提供证据
            self._redirect_to(302, f"http://localhost:{port}/final")
        else:
            self._reply_text("not found", status=404)

    def _redirect_to(self, code, location):
        self.send_response(code)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _final(self):
        body = self._read_body()
        self._reply_json({
            "method": self.command,
            "body_len": len(body),
            "authorization": self.headers.get("Authorization") or "",
            "cookie": self.headers.get("Cookie") or "",
        })

    def _cookie_set(self):
        query = self._query()
        parts = [f"{query.get('name', 'session')}={query.get('value', '')}"]
        if "path" in query:
            parts.append(f"Path={query['path']}")
        if "max_age" in query:
            parts.append(f"Max-Age={query['max_age']}")
        if query.get("secure"):
            parts.append("Secure")
        self.send_response(200)
        self.send_header("Set-Cookie", "; ".join(parts))
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")

    def _http10(self):
        # 故意裸写：HTTP/1.0 + 没有 Content-Length，正文靠连接关闭收尾——
        # 自研栈的 1.0 兼容与 EOF 分帧在这里一次验完
        body = "hello from HTTP/1.0（无 Content-Length，靠连接关闭收尾）".encode()
        self.close_connection = True
        self.wfile.write(
            b"HTTP/1.0 200 OK\r\n"
            b"Content-Type: text/plain; charset=utf-8\r\n"
            b"Connection: close\r\n\r\n" + body
        )

    # ---- 小工具 ----

    def _query(self):
        return {k: v[0] for k, v in parse_qs(urlparse(self.path).query).items()}

    def _read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def _reply_json(self, obj, status=200):
        data = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def _reply_text(self, text, status=200):
        data = text.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)


def main():
    parser = argparse.ArgumentParser(description="moonhttp 共享靶子 server")
    parser.add_argument("--port", type=int, default=18777)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    print(f"moonhttp 靶子 server 已就绪：http://127.0.0.1:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
