# 可移除的图片端点兼容层

这不是服务器根因修复，也不是全局关闭 SNI。普通下载、阅读和预加载均先检查缓存，
然后优先使用原来的正常 TLS 连接。兼容层只补救特定端点的握手异常。

## 两项独立开关

均为编译开关，默认开启，可分别关闭，不改变缓存格式、数据库或用户数据：

```sh
--dart-define=FE_IMAGE_FAST_FAILOVER=false
--dart-define=FE_IMAGE_SNI_COMPAT=false
```

- `FE_IMAGE_FAST_FAILOVER`：`WRONG_VERSION_NUMBER` 后尽早换源，并短时避让
  失败的 H@H **完整主机＋端口＋代理路径**。不是封禁整个域名组；
  不会把 fullimg 重定向后的错误当成整个画廊/API 主站不可用。
- `FE_IMAGE_SNI_COMPAT`：Android 上正常 TLS 出现该错误后，允许一次严格验证
  的无 SNI GET。其他平台不加载原生兼容路径，仍能使用快速换源。

## 默认处理顺序

1. 查缓存；命中时不进入端点恢复或网络。
2. 正常 TLS；成功就直接使用，绝不主动改为无 SNI。
3. 仅在 `HandshakeException`（可包在 DioException 中）明确包含
   `WRONG_VERSION_NUMBER` 时尝试兼容。
4. 兼容成功则继续同一页的 HTTP 流式读取；失败则保留原始握手原因，
   尽早请求新 sourceId，而不是先重复同一 URL 三次。
5. 无可用兼容路径或兼容失败时，该精确端点在内存中避让 60 秒；
   最多记录 128 个端点。到期或重启即重新尝试正常 TLS。
   显式点击普通下载“重试/继续”也会清除短时避让记录。

成功的兼容连接**不会**把主机永久标成“必须无 SNI”。下一个请求仍先试正常
TLS，因此服务器更新后无需等一次 App 更新才能回归正常连接。

## 安全边界

- 仅用于 HTTPS、443、`.hath.network` 图片 GET；拒绝 URL 用户凭据、
  请求体、Range 和显式 Host 覆盖（例如域名前置）请求。登录/API/论坛请求
  不使用此兼容路径。
- 仅当 App 明确为 DIRECT 时可用；配置 HTTP/SOCKS 代理时不偷偷绕过代理。
  系统 VPN 仍由 Android 网络栈控制。
- 使用系统 TrustManager 验证证书链，并保留 OkHttp 对**原始 URL 域名**
  的默认 hostname verifier。没有 permissive TrustManager/HostnameVerifier，
  也不继承原有 IO 路径的 `skipCertificate` 选项。
- 不携带 Cookie、Authorization、Host 等账号或路由覆盖头；只转发必要的
  Accept、Accept-Language 和 User-Agent。签名 URL 只交给相同目标端点。
- 不自动跟随原生兼容响应的重定向，不降级到 HTTP；让页面恢复流程重新获取来源。
- 正常路径的既有证书策略未在本次扩大或修改。

### Android 实现细节

`NoSniClient` 使用独立的系统 SSLContext 和固定版本 OkHttp。Android Conscrypt
只把 `SSLParameters.serverNames` 设为空并不一定会清除已记录的主机名，因此：

- 包装已连接 socket 时，用其**实际 IP**作底层 TLS peer label，抑制 SNI。
- HTTP URL、Host 和 OkHttp 的证书域名校验目标仍是原始域名，**不是 IP**。
- 禁用 OkHttp 自动配置 SNI/ALPN，只使用 HTTP/1.1；保留现代 TLS。
- 不使用隐藏 Android API、反射去关闭验证或自定义证书解析。

## 流式读取、取消和预算

- Dart 与原生按需传递 64 KiB 以内的数据块，不把整张图放入一个平台消息，
  不创建临时下载副本。Dio 和原有 SAF 落盘/完成回调继续负责保存。
- 原生最多保留 32 个请求，会话由独立工作线程处理。
- 连接/响应头受 Dart 和原生超时控制；读取受配置的空闲超时约束，最长 20 秒；
  原生单次调用总时限最多 120 秒。关闭 adapter、取消、读完、失败都会回收会话。
- 原生读取中断被转换为可重试的 HttpException，不误报下载完成。
- 每次普通尝试最多追加一次兼容连接；没有兼容循环或原生自动重试。
  下载仍最多 4 次页面尝试；兼容连接受上述超时控制，不重置页面预算。
- 对该类错误，阅读直接进入已有的“一次自动换源”，预加载最多换源一次；
  其他瞬时错误仍沿用原来的有限重试。原图预加载换源不退化为重采样图。

## 诊断

仍使用 `FE_DOWNLOAD_DIAGNOSTICS=true`：

- `sni_compat_start`：正常 TLS 失败后才进入兼容。
- `sni_compat_headers`：证书验证通过且已收到 HTTP 响应头，不代表图片已下载完成。
- `sni_compat_failed`：兼容失败，仅保存固定异常类型。
- `image_host_cooldown` / `image_host_avoided`：短时避让。避让不代表新建了一次
  TCP/TLS 连接，分析网络尝试次数时须与这些事件区分。
- 图片真正读完仍由既有 `network_complete` / `reader_network_complete` 记录。

不记录完整 URL、图片路径/query、Cookie、原生异常文本或图片内容。

## 验证范围

- Dart 回归覆盖缓存优先、正常路径不触发兼容、错误分类、开关独立性、
  主机/端口/代理隔离、60 秒过期、有界容量、主动重试、有限换源、
  流式背压、响应头超时、取消、重定向拒绝和读取错误传播。
- Android 原生独立验证程序使用与 App 相同的 Java 实现：六个日志故障节点
  的标准握手失败，无 SNI 握手均成功进入 TLS 1.3/HTTP；健康节点不受影响。
- 自签、过期等负向站点被拒绝；另外把**有效 H@H 证书**对应端点映射到
  错误原域名，验证默认 hostname verifier 仍拒绝。
- 原生会话 GET/分块读取与取消前启动验证通过。真实端点测试请求根路径，
  返回 404 是预期，不把它宣称为签名漫画图片 200 或整本下载验证。
- Release APK 需单独编译核对；不因代码测试通过就自动替换已安装 App。

## 将来移除

先分别关闭两个开关确认服务器已经恢复；缓存修复不依赖它们。
完整移除无 SNI 模块时，删除 `native_sni_compatibility.dart`、
Android `imagetransport` 目录、MainActivity 的注册和 Gradle 的 OkHttp 依赖，
再移除 `ImageTransferAdapter` 中的兼容调用即可。短时避让/快速换源也可单独
移除，不需要迁移数据库或缓存。
