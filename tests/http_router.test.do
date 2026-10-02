import { Assert } from "std/assert"
import { ChannelSender, createChannel, runMainEventLoop } from "std/event"
import { remove, writeText } from "std/fs"
import { HttpHeader } from "std/http"
import {
  Request,
  Response,
  Server,
  ServerOptions,
  WebSocketConnection,
  WebSocketEvent,
  WebSocketSendText,
  WebSocketBinary,
  WebSocketClose,
  WebSocketError,
  WebSocketOpen,
  WebSocketText,
  WebSocketWritable,
  createWebSocketConnection,
} from "std/http-server"
import { Path, parsePath } from "std/url"
import {
  HttpResponse,
  Router,
  RouteMatch,
  RoutePattern,
  StaticFileOptions,
  WebSocketRouteResult,
  cacheControlForFileSystemPath,
  compileRoutePattern,
  fileSystemResponseHeaders,
  matchRoute,
  matchRoutePrefix,
  mimeTypeForFileSystemPath,
  pathToFileSystemPath,
} from "../index"

import class NativeWebSocketTestClient from "http-server/native_http_server_test_support.hpp" as doof_http_server_test::NativeWebSocketTestClient {
  isolated static startExchangeText(host: string, port: int, requestText: string, text: string): NativeWebSocketTestClient
  isolated wait(): string
}

class RouterWebSocketState {
  let openCount: int = 0
  let text: string = ""
  let errorKind: string = ""
}

function path(text: string): Path => parsePath(text)!

function pattern(text: string): RoutePattern => compileRoutePattern(text)!

function request(method: string, path: string): Request {
  return Request {
    method,
    target: path,
    path,
    queryString: "",
    version: "HTTP/1.1",
    headers: readonly [],
    body: readonly [],
  }
}

function websocketRequest(path: string): Request {
  return Request {
    method: "GET",
    target: path,
    path,
    queryString: "",
    version: "HTTP/1.1",
    headers: readonly [
      HttpHeader { name: "Upgrade", value: "websocket" },
      HttpHeader { name: "Connection", value: "keep-alive, Upgrade" },
    ],
    body: readonly [],
  }
}

function text(status: int, body: string): HttpResponse {
  return Response.text(status, body)
}

function empty(status: int): HttpResponse {
  return Response.empty(status)
}

function header(response: Response, name: string): string | none {
  lowerName := name.toLowerCase()
  for entry of response.headers {
    if entry.name.toLowerCase() == lowerName {
      return entry.value
    }
  }
  return none
}

function requestWithHeaders(method: string, path: string, headers: readonly HttpHeader[]): Request {
  return Request {
    method,
    target: path,
    path,
    queryString: "",
    version: "HTTP/1.1",
    headers,
    body: readonly [],
  }
}

function handleRouterWebSocketEvent(
  state: RouterWebSocketState,
  event: WebSocketOpen | WebSocketText | WebSocketBinary | WebSocketWritable | WebSocketClose | WebSocketError,
): none {
  opened := event as WebSocketOpen
  case opened {
    _: Success -> {
      state.openCount += 1
      return
    }
    _: Failure -> {}
  }

  textEvent := event as WebSocketText
  case textEvent {
    textSuccess: Success -> {
      state.text = textSuccess.value.text
      textSuccess.value.connection.commands.send(WebSocketSendText {
        text: "echo:" + textSuccess.value.text,
      })!
      return
    }
    _: Failure -> {}
  }

  errorEvent := event as WebSocketError
  case errorEvent {
    errorSuccess: Success -> {
      state.errorKind = errorSuccess.value.error.kind
      return
    }
    _: Failure -> {}
  }
}

function websocketConnection(state: RouterWebSocketState): WebSocketConnection {
  connection := createWebSocketConnection()
  connection.events.onMessage((event: WebSocketEvent): none => handleRouterWebSocketEvent(state, event))
  return connection
}

function assertCompileError(text: string, kind: string): none {
  case compileRoutePattern(text) {
    s: Success -> Assert.fail("expected pattern compile failure")
    f: Failure -> Assert.equal(f.error.kind, kind)
  }
}

function assertFileSystemPathError(text: string, kind: string): none {
  case pathToFileSystemPath("/srv/www", path(text)) {
    s: Success -> Assert.fail("expected filesystem path failure")
    f: Failure -> Assert.equal(f.error.kind, kind)
  }
}

export function testExactStaticRouteMatches(): none {
  matched := matchRoute(pattern("/news"), path("/news"))

  Assert.isTrue(matched != none)
  Assert.equal(matched!.params.size, 0)
  Assert.equal(matched!.remaining.segmentCount(), 0)
}

export function testExactRouteRejectsTrailingSegments(): none {
  matched := matchRoute(pattern("/news"), path("/news/today"))

  Assert.isTrue(matched == none)
}

export function testNamedParamCapture(): none {
  matched := matchRoute(pattern("/users/:id"), path("/users/42"))

  Assert.isTrue(matched != none)
  Assert.equal(matched!.get("id"), "42")
}

export function testMultipleNamedParamCapture(): none {
  matched := matchRoute(pattern("/users/:id/posts/:postId"), path("/users/42/posts/99"))

  Assert.isTrue(matched != none)
  Assert.equal(matched!.get("id"), "42")
  Assert.equal(matched!.get("postId"), "99")
}

export function testNoMatchCases(): none {
  Assert.isTrue(matchRoute(pattern("/users/:id"), path("/teams/42")) == none)
  Assert.isTrue(matchRoute(pattern("/users/:id"), path("/users")) == none)
  Assert.isTrue(matchRoute(pattern("/users/:id"), path("/users/42/posts")) == none)
}

export function testPrefixMatchReturnsRemainingSubpath(): none {
  matched := matchRoutePrefix(pattern("children/:id"), path("/children/7/posts/12"))

  Assert.isTrue(matched != none)
  Assert.equal(matched!.get("id"), "7")
  Assert.isFalse(matched!.remaining.absolute)
  Assert.equal(matched!.remaining.segmentCount(), 2)
  Assert.equal(matched!.remaining.segment(0), "posts")
  Assert.equal(matched!.remaining.segment(1), "12")
}

export function testPrefixMatchCanBeExact(): none {
  matched := matchRoutePrefix(pattern("/children/:id"), path("/children/7"))

  Assert.isTrue(matched != none)
  Assert.equal(matched!.get("id"), "7")
  Assert.equal(matched!.remaining.segmentCount(), 0)
}

export function testPathToFileSystemPathAppliesUrlPathRelativeToRoot(): none {
  mapped := pathToFileSystemPath("/srv/www", path("/assets/css/site.css"))!

  Assert.equal(mapped, "/srv/www/assets/css/site.css")
}

export function testPathToFileSystemPathIgnoresAbsoluteUrlMarkerAndEmptySegments(): none {
  mapped := pathToFileSystemPath("/srv/www/", path("/assets//icons/"))!

  Assert.equal(mapped, "/srv/www/assets/icons")
}

export function testPathToFileSystemPathRejectsJailbreakSegments(): none {
  assertFileSystemPathError("/assets/../secret.txt", "parent-segment")
  assertFileSystemPathError("/assets/%2e%2e/secret.txt", "parent-segment")
  assertFileSystemPathError("/assets/%2Fetc/passwd", "embedded-separator")
  assertFileSystemPathError("/assets/%5Cwindows", "embedded-separator")
}

export function testRouteMatchCanMapRemainingPathToFileSystemPath(): none {
  matched := matchRoutePrefix(pattern("/static"), path("/static/images/logo.png"))

  Assert.isTrue(matched != none)
  mapped := matched!.remainingFileSystemPath("/srv/www")!
  Assert.equal(mapped, "/srv/www/images/logo.png")
}

export function testMimeTypeForFileSystemPathUsesCommonExtensions(): none {
  Assert.equal(mimeTypeForFileSystemPath("/srv/www/index.html")!, "text/html; charset=utf-8")
  Assert.equal(mimeTypeForFileSystemPath("/srv/www/app.js")!, "text/javascript; charset=utf-8")
  Assert.equal(mimeTypeForFileSystemPath("/srv/www/data.json")!, "application/json; charset=utf-8")
  Assert.equal(mimeTypeForFileSystemPath("/srv/www/logo.png")!, "image/png")
  Assert.equal(mimeTypeForFileSystemPath("/srv/www/font.woff2")!, "font/woff2")
}

export function testMimeTypeForFileSystemPathIsCaseInsensitiveAndReturnsNullForUnknown(): none {
  Assert.equal(mimeTypeForFileSystemPath("/srv/www/PHOTO.JPEG")!, "image/jpeg")
  Assert.isTrue(mimeTypeForFileSystemPath("/srv/www/Makefile") == none)
  Assert.isTrue(mimeTypeForFileSystemPath("/srv/www/file.unknown") == none)
}

export function testCacheControlForFileSystemPathUsesStaticAssetDefaults(): none {
  Assert.equal(cacheControlForFileSystemPath("/srv/www/index.html")!, "no-cache")
  Assert.equal(cacheControlForFileSystemPath("/srv/www/assets/app.js")!, "public, max-age=3600")
  Assert.equal(cacheControlForFileSystemPath("/srv/www/assets/logo.png")!, "public, max-age=86400")
  Assert.equal(cacheControlForFileSystemPath("/srv/www/assets/font.woff2")!, "public, max-age=31536000, immutable")
  Assert.isTrue(cacheControlForFileSystemPath("/srv/www/Makefile") == none)
}

export function testFileSystemResponseHeadersIncludesMimeTypeAndCacheControl(): none {
  headers := fileSystemResponseHeaders("/srv/www/assets/app.js")

  Assert.equal(headers.length, 2)
  Assert.equal(headers[0].name, "Content-Type")
  Assert.equal(headers[0].value, "text/javascript; charset=utf-8")
  Assert.equal(headers[1].name, "Cache-Control")
  Assert.equal(headers[1].value, "public, max-age=3600")
}

export function testFileSystemResponseHeadersAllowsOverrides(): none {
  headers := fileSystemResponseHeaders(
    "/srv/www/assets/app.bin",
    "application/example",
    "private, max-age=5",
  )

  Assert.equal(headers.length, 2)
  Assert.equal(headers[0].value, "application/example")
  Assert.equal(headers[1].value, "private, max-age=5")
}

export function testSlashNormalization(): none {
  a := pattern("users/:id")
  b := pattern("/users/:id")
  c := pattern("/users/:id/")

  Assert.equal(matchRoute(a, path("/users/1"))!.get("id"), "1")
  Assert.equal(matchRoute(b, path("/users/2"))!.get("id"), "2")
  Assert.equal(matchRoute(c, path("/users/3"))!.get("id"), "3")
}

export function testDecodedPathSegmentsAreMatched(): none {
  matched := matchRoute(pattern("/files/:name"), path("/files/hello%20world"))

  Assert.isTrue(matched != none)
  Assert.equal(matched!.get("name"), "hello world")
}

export function testRootPatternMatchesEmptyPathOnly(): none {
  emptyPattern := pattern("/")

  Assert.isTrue(matchRoute(emptyPattern, path("")) != none)
  Assert.isTrue(matchRoute(emptyPattern, path("/")) == none)
}

export function testInvalidPatternsAreRejected(): none {
  assertCompileError("/users/:id/posts/:id", "duplicate-param")
  assertCompileError("/users/:", "empty-param")
  assertCompileError("/users/:9id", "invalid-param")
  assertCompileError("/files/*", "wildcard-unsupported")
  assertCompileError("/files/*/edit", "wildcard-unsupported")
}

export function testRouterGetMatchesExactPathAndMethod(): none {
  router := Router()
    .get("/news", (match: RouteMatch, request: Request): HttpResponse => text(200, "news"))

  matched := router.handle(request("GET", "/news"))
  wrongMethod := router.handle(request("POST", "/news"))
  trailing := router.handle(request("GET", "/news/today"))

  Assert.isTrue(matched != none)
  Assert.equal(matched!.status, 200)
  Assert.isTrue(wrongMethod != none)
  Assert.equal(wrongMethod!.status, 405)
  Assert.isTrue(trailing == none)
}

export function testRouterMethodPrefixRoutesMatchSubpathsAndReturnMethodNotAllowed(): none {
  router := Router()
    .getPrefix("/", (match: RouteMatch, request: Request): HttpResponse => text(200, match.remaining.segment(0)))
    .headPrefix("/", (match: RouteMatch, request: Request): HttpResponse => empty(200))

  matched := router.handle(request("GET", "/assets/site.css"))
  wrongMethod := router.handle(request("POST", "/assets/site.css"))

  Assert.isTrue(matched != none)
  Assert.equal(matched!.status, 200)
  Assert.isTrue(wrongMethod != none)
  Assert.equal(wrongMethod!.status, 405)
  Assert.equal(wrongMethod!.headers[0].value, "GET, HEAD")
}

export function testRouterStaticFilesServesGetHeadAndConditionals(): none {
  root := "."
  filePath := root + "/.http-router-static.css"
  writeText(filePath, "static body")!

  router := Router()
    .staticFiles("/", StaticFileOptions { root })

  getResponse := router.handle(request("GET", "/.http-router-static.css"))!
  headResponse := router.handle(request("HEAD", "/.http-router-static.css"))!
  postResponse := router.handle(request("POST", "/.http-router-static.css"))!
  etag := header(getResponse, "ETag")!
  lastModified := header(getResponse, "Last-Modified")!
  etagNotModified := router.handle(requestWithHeaders(
    "GET",
    "/.http-router-static.css",
    readonly [HttpHeader { name: "If-None-Match", value: etag }],
  ))!
  dateNotModified := router.handle(requestWithHeaders(
    "GET",
    "/.http-router-static.css",
    readonly [HttpHeader { name: "If-Modified-Since", value: lastModified }],
  ))!

  remove(filePath)!

  Assert.equal(getResponse.status, 200)
  Assert.equal(header(getResponse, "Content-Type")!, "text/css; charset=utf-8")
  Assert.equal(header(getResponse, "Cache-Control")!, "public, max-age=3600")
  Assert.isTrue(etag.startsWith("\""))
  Assert.isTrue(lastModified.endsWith(" GMT"))
  Assert.equal(headResponse.status, 200)
  Assert.equal(postResponse.status, 405)
  Assert.equal(header(postResponse, "Allow")!, "GET, HEAD")
  Assert.equal(etagNotModified.status, 304)
  Assert.equal(dateNotModified.status, 304)
}

export function testRouterSupportsExpectedVerbHelpers(): none {
  router := Router()
    .head("/items", (match: RouteMatch, request: Request): HttpResponse => empty(200))
    .post("/items", (match: RouteMatch, request: Request): HttpResponse => empty(201))
    .put("/items", (match: RouteMatch, request: Request): HttpResponse => empty(202))
    .delete("/items", (match: RouteMatch, request: Request): HttpResponse => empty(203))
    .connect("/items", (match: RouteMatch, request: Request): HttpResponse => empty(204))
    .options("/items", (match: RouteMatch, request: Request): HttpResponse => empty(205))
    .trace("/items", (match: RouteMatch, request: Request): HttpResponse => empty(206))
    .patch("/items", (match: RouteMatch, request: Request): HttpResponse => empty(207))

  Assert.equal(router.handle(request("HEAD", "/items"))!.status, 200)
  Assert.equal(router.handle(request("POST", "/items"))!.status, 201)
  Assert.equal(router.handle(request("PUT", "/items"))!.status, 202)
  Assert.equal(router.handle(request("DELETE", "/items"))!.status, 203)
  Assert.equal(router.handle(request("CONNECT", "/items"))!.status, 204)
  Assert.equal(router.handle(request("OPTIONS", "/items"))!.status, 205)
  Assert.equal(router.handle(request("TRACE", "/items"))!.status, 206)
  Assert.equal(router.handle(request("PATCH", "/items"))!.status, 207)
}

export function testRequestDetectsWebSocketUpgradeAttempts(): none {
  upgrade := websocketRequest("/socket")
  ordinary := Request {
    method: "GET",
    target: "/socket",
    path: "/socket",
    queryString: "",
    version: "HTTP/1.1",
    headers: readonly [
      HttpHeader { name: "Connection", value: "upgrade" },
    ],
    body: readonly [],
  }

  Assert.isTrue(upgrade.isWebSocketUpgrade())
  Assert.isFalse(ordinary.isWebSocketUpgrade())
}

export function testRouterWebSocketRouteOnlyMatchesUpgradeAttempts(): none {
  router := Router()
    .websocket("/socket", (match: RouteMatch, request: Request): WebSocketRouteResult => text(426, "upgrade required"))

  ordinary := router.handle(request("GET", "/socket"))
  upgrade := router.handle(websocketRequest("/socket"))

  Assert.isTrue(ordinary == none)
  Assert.isTrue(upgrade != none)
  Assert.equal(upgrade!.status, 426)
}

export function testRouterGetDoesNotMatchWebSocketUpgradeAttempts(): none {
  router := Router()
    .get("/socket", (match: RouteMatch, request: Request): HttpResponse => text(200, "ordinary get"))
    .websocket("/socket", (match: RouteMatch, request: Request): WebSocketRouteResult => text(426, "upgrade required"))

  matched := router.handle(websocketRequest("/socket"))

  Assert.isTrue(matched != none)
  Assert.equal(matched!.status, 426)
}

export function testRouterReturnsNullForWebSocketUpgradeWithoutWebSocketRoute(): none {
  router := Router()
    .get("/socket", (match: RouteMatch, request: Request): HttpResponse => text(200, "ordinary get"))

  Assert.isTrue(router.handle(websocketRequest("/socket")) == none)
}

export function testRouterWebSocketRouteCanReturnConnection(): none {
  state := RouterWebSocketState()
  router := Router()
    .websocket("/socket", (match: RouteMatch, request: Request): WebSocketRouteResult => websocketConnection(state))

  matched := router.handle(websocketRequest("/socket"))
  runMainEventLoop()

  Assert.isTrue(matched == none)
  Assert.equal(state.errorKind, "missing-responder")
}

export function testRouterWebSocketConnectionReturnUpgradesServerRequest(): none {
  state := RouterWebSocketState()
  router := Router()
    .get("/socket", (match: RouteMatch, request: Request): HttpResponse => text(200, "ordinary get"))
    .websocket("/socket", (match: RouteMatch, request: Request): WebSocketRouteResult => websocketConnection(state))
  let requestChannel: ChannelSender<Request> | none = none

  (requests, requestReceiver) := createChannel<Request>{
    capacity: 1,
    keepsAlive: true,
  }
  requestReceiver.onMessage((request: Request): none => {
    response := router.handle(request)
    if response != none {
      request.respond(response!)!
    }
    requestChannel!.close()
  })
  requestChannel = requests

  server := Server.listen{
    options: ServerOptions { port: 0 },
    requests,
  }!

  client := NativeWebSocketTestClient.startExchangeText(
    server.host,
    server.port,
    "GET /socket HTTP/1.1\r\nHost: example.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n",
    "hello",
  )

  runMainEventLoop()
  clientResponse := client.wait()
  server.close()!

  Assert.equal(state.openCount, 1, clientResponse)
  Assert.equal(state.text, "hello", clientResponse)
  Assert.isTrue(clientResponse.contains("HTTP/1.1 101 Switching Protocols"), clientResponse)
  Assert.isTrue(clientResponse.contains("frame|1|echo:hello"), clientResponse)
}

export function testRouterUsesFirstRegisteredMatch(): none {
  router := Router()
    .get("/items/:id", (match: RouteMatch, request: Request): HttpResponse => empty(201))
    .get("/items/:id", (match: RouteMatch, request: Request): HttpResponse => empty(202))

  matched := router.handle(request("GET", "/items/42"))

  Assert.isTrue(matched != none)
  Assert.equal(matched!.status, 201)
}

export function testRouterReturnsNullWhenNothingMatches(): none {
  router := Router()
    .get("/news", (match: RouteMatch, request: Request): HttpResponse => text(200, "news"))

  Assert.isTrue(router.handle(request("GET", "/missing")) == none)
}

export function testRouterReturnsMethodNotAllowedForTerminatingMethodMismatch(): none {
  router := Router()
    .get("/items", (match: RouteMatch, request: Request): HttpResponse => empty(200))
    .post("/items", (match: RouteMatch, request: Request): HttpResponse => empty(201))

  matched := router.handle(request("PUT", "/items"))

  Assert.isTrue(matched != none)
  Assert.equal(matched!.status, 405)
  Assert.equal(matched!.headers.length, 1)
  Assert.equal(matched!.headers[0].name, "Allow")
  Assert.equal(matched!.headers[0].value, "GET, POST")
}

export function testRouterKeepsScanningAfterMethodMismatch(): none {
  router := Router()
    .get("/items", (match: RouteMatch, request: Request): HttpResponse => empty(200))
    .route("/items", (match: RouteMatch, request: Request): HttpResponse => empty(202))

  matched := router.handle(request("PUT", "/items"))

  Assert.isTrue(matched != none)
  Assert.equal(matched!.status, 202)
}

export function testRouterRouteMatchesAnyMethodAsPrefix(): none {
  router := Router()
    .route("/api/:version", (match: RouteMatch, request: Request): HttpResponse => {
      version := match.get("version")
      firstRemaining := match.remaining.segment(0)
      if request.method == "PATCH" && version == "v1" && firstRemaining == "users" {
        return empty(209)
      }
      return empty(500)
    })

  matched := router.handle(request("PATCH", "/api/v1/users/42"))

  Assert.isTrue(matched != none)
  Assert.equal(matched!.status, 209)
}

export function testRouterRouteCanMatchExactPrefix(): none {
  router := Router()
    .route("/api", (match: RouteMatch, request: Request): HttpResponse => {
      remainingCount := match.remaining.segmentCount()
      if remainingCount == 0 {
        return empty(210)
      }
      return empty(500)
    })

  matched := router.handle(request("GET", "/api"))

  Assert.isTrue(matched != none)
  Assert.equal(matched!.status, 210)
}

export function testRouterReturnsNullForInvalidRequestPath(): none {
  router := Router()
    .get("/news", (match: RouteMatch, request: Request): HttpResponse => text(200, "news"))

  Assert.isTrue(router.handle(request("GET", "/news/%")) == none)
}
