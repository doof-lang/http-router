import { Request, Response, WebSocketConnection } from "std/http-server"
import { HttpHeader } from "std/http"
import { extension, join } from "std/path"
import { Path, parsePath } from "std/url"

const SEGMENT_LITERAL = 0
const SEGMENT_PARAM = 1

export class RoutePatternError {
  readonly kind: string
  readonly index: int
  readonly message: string
}

export class FileSystemPathError {
  readonly kind: string
  readonly segment: int
  readonly message: string
}

export class RouteSegment {
  readonly kind: int
  readonly text: string
}

export class RoutePattern {
  readonly pattern: string
  private readonly segments: readonly RouteSegment[]
}

export class RouteMatch {
  readonly params: readonly Map<string, string>
  readonly remaining: Path

  get(name: string): string {
    value := params.get(name) else {
      panic("Route variable '${name}' is not bound")
    }
    return value
  }

  remainingFileSystemPath(root: string): Result<string, FileSystemPathError> {
    return pathToFileSystemPath(root, this.remaining)
  }
}

export type HttpResponse = Response
export type RouteHandler = (it: RouteMatch, request: Request): HttpResponse
export type WebSocketRouteResult = Response | WebSocketConnection
export type WebSocketRouteHandler = (it: RouteMatch, request: Request): Response | WebSocketConnection

export class RegisteredRoute {
  readonly method: string | null
  readonly pattern: RoutePattern
  readonly prefix: bool
  readonly websocket: bool
  readonly handler: (it: RouteMatch, request: Request): Response | WebSocketConnection
}

export class Router {
  private routes: RegisteredRoute[] = []

  get(pattern: string, handler: RouteHandler): Router {
    return this.add("GET", pattern, false, handler)
  }

  head(pattern: string, handler: RouteHandler): Router {
    return this.add("HEAD", pattern, false, handler)
  }

  post(pattern: string, handler: RouteHandler): Router {
    return this.add("POST", pattern, false, handler)
  }

  put(pattern: string, handler: RouteHandler): Router {
    return this.add("PUT", pattern, false, handler)
  }

  delete(pattern: string, handler: RouteHandler): Router {
    return this.add("DELETE", pattern, false, handler)
  }

  connect(pattern: string, handler: RouteHandler): Router {
    return this.add("CONNECT", pattern, false, handler)
  }

  options(pattern: string, handler: RouteHandler): Router {
    return this.add("OPTIONS", pattern, false, handler)
  }

  trace(pattern: string, handler: RouteHandler): Router {
    return this.add("TRACE", pattern, false, handler)
  }

  patch(pattern: string, handler: RouteHandler): Router {
    return this.add("PATCH", pattern, false, handler)
  }

  websocket(pattern: string, handler: WebSocketRouteHandler): Router {
    return this.addWebSocket(pattern, handler)
  }

  route(pattern: string, handler: RouteHandler): Router {
    return this.add(null, pattern, true, handler)
  }

  handle(request: Request): HttpResponse | null {
    isWebSocketUpgrade := request.isWebSocketUpgrade()
    parsed := parsePath(request.path)
    path := case parsed {
      s: Success -> s.value,
      _: Failure -> null,
    }
    if path == null {
      return null
    }

    allowedMethods: string[] := []
    for route of this.routes {
      matched := if route.prefix
        then matchRoutePrefix(route.pattern, path)
        else matchRoute(route.pattern, path)
      if matched == null {
        continue
      }

      if route.websocket {
        if !isWebSocketUpgrade {
          continue
        }
      } else if isWebSocketUpgrade {
        continue
      }

      if route.method != null && route.method! != request.method {
        if !allowedMethods.contains(route.method!) {
          allowedMethods.push(route.method!)
        }
        continue
      }

      response := route.handler(matched!, request)
      case response {
        http: Response -> return http
        websocket: WebSocketConnection -> {
          request.upgradeToWebSocket(websocket)
          return null
        }
      }
    }

    if allowedMethods.length > 0 {
      return methodNotAllowedResponse(allowedMethods.buildReadonly())
    }

    return null
  }

  private add(method: string | null, pattern: string, prefix: bool, handler: RouteHandler): Router {
    compiled := compileRoutePatternOrPanic(pattern)

    this.routes.push(RegisteredRoute {
      method,
      pattern: compiled,
      prefix,
      websocket: false,
      handler: (it: RouteMatch, request: Request): Response | WebSocketConnection => handler(it, request),
    })
    return this
  }

  private addWebSocket(pattern: string, handler: WebSocketRouteHandler): Router {
    compiled := compileRoutePatternOrPanic(pattern)

    this.routes.push(RegisteredRoute {
      method: null,
      pattern: compiled,
      prefix: false,
      websocket: true,
      handler,
    })
    return this
  }
}

function compileRoutePatternOrPanic(pattern: string): RoutePattern {
  case compileRoutePattern(pattern) {
    s: Success -> return s.value
    f: Failure -> panic("Invalid route pattern '${pattern}': ${f.error.message}")
  }
}

export function compileRoutePattern(pattern: string): Result<RoutePattern, RoutePatternError> {
  segments: RouteSegment[] := []
  paramNames: string[] := []
  rawSegments := normalizedSegments(pattern)

  for index of 0..<rawSegments.length {
    segment := rawSegments[index]
    if segment == "*" {
      return patternError(
        "wildcard-unsupported",
        segmentIndex(pattern, index),
        "Route wildcards are not supported; use Router.route(pattern, handler) for prefix routing",
      )
    }

    if segment.startsWith(":") {
      name := segment.slice(1)
      if name.length == 0 {
        return patternError(
          "empty-param",
          segmentIndex(pattern, index),
          "Route parameter names cannot be empty",
        )
      }
      if !isValidParamName(name) {
        return patternError(
          "invalid-param",
          segmentIndex(pattern, index),
          "Route parameter names must start with a letter or '_' and contain only letters, digits, or '_'",
        )
      }
      if paramNames.contains(name) {
        return patternError(
          "duplicate-param",
          segmentIndex(pattern, index),
          "Route parameter names must be unique",
        )
      }
      paramNames.push(name)
      segments.push(RouteSegment { kind: SEGMENT_PARAM, text: name })
      continue
    }

    segments.push(RouteSegment { kind: SEGMENT_LITERAL, text: segment })
  }

  return Success {
    value: RoutePattern {
      pattern,
      segments: segments.buildReadonly(),
    }
  }
}

export function matchRoute(pattern: RoutePattern, path: Path): RouteMatch | null {
  matched := matchCompiled(pattern, path, false)
  if matched == null {
    return null
  }
  return matched!
}

export function matchRoutePrefix(pattern: RoutePattern, path: Path): RouteMatch | null {
  matched := matchCompiled(pattern, path, true)
  if matched == null {
    return null
  }
  return matched!
}

export function pathToFileSystemPath(root: string, path: Path): Result<string, FileSystemPathError> {
  parts: string[] := [root]

  for index of 0..<path.segments.length {
    segment := path.segments[index]
    if segment.length == 0 || segment == "." {
      continue
    }

    if segment == ".." {
      return fileSystemPathError(
        "parent-segment",
        index,
        "URL paths cannot contain parent directory segments",
      )
    }

    if segment.contains("/") || segment.contains("\\") {
      return fileSystemPathError(
        "embedded-separator",
        index,
        "URL path segments cannot contain filesystem separators",
      )
    }

    parts.push(segment)
  }

  return Success { value: join(parts) }
}

export function mimeTypeForFileSystemPath(path: string): string | null {
  ext := extension(path).toLowerCase()
  return case ext {
    ".html" | ".htm" -> "text/html; charset=utf-8",
    ".css" -> "text/css; charset=utf-8",
    ".js" | ".mjs" -> "text/javascript; charset=utf-8",
    ".json" | ".map" -> "application/json; charset=utf-8",
    ".txt" | ".text" -> "text/plain; charset=utf-8",
    ".md" | ".markdown" -> "text/markdown; charset=utf-8",
    ".csv" -> "text/csv; charset=utf-8",
    ".xml" -> "application/xml; charset=utf-8",
    ".svg" -> "image/svg+xml",
    ".png" -> "image/png",
    ".jpg" | ".jpeg" -> "image/jpeg",
    ".gif" -> "image/gif",
    ".webp" -> "image/webp",
    ".ico" -> "image/x-icon",
    ".avif" -> "image/avif",
    ".wasm" -> "application/wasm",
    ".pdf" -> "application/pdf",
    ".zip" -> "application/zip",
    ".gz" -> "application/gzip",
    ".tar" -> "application/x-tar",
    ".mp3" -> "audio/mpeg",
    ".wav" -> "audio/wav",
    ".ogg" -> "audio/ogg",
    ".mp4" -> "video/mp4",
    ".webm" -> "video/webm",
    ".woff" -> "font/woff",
    ".woff2" -> "font/woff2",
    ".ttf" -> "font/ttf",
    ".otf" -> "font/otf",
    _ -> null
  }
}

function matchCompiled(pattern: RoutePattern, path: Path, allowPrefix: bool): RouteMatch | null {
  params: Map<string, string> := {}
  let segmentIndex = 0

  for routeSegment of pattern.segments {
    if segmentIndex >= path.segments.length {
      return null
    }

    pathSegment := path.segments[segmentIndex]
    if routeSegment.kind == SEGMENT_LITERAL {
      if pathSegment != routeSegment.text {
        return null
      }
    } else {
      params[routeSegment.text] = pathSegment
    }

    segmentIndex += 1
  }

  if segmentIndex < path.segments.length {
    if !allowPrefix {
      return null
    }
    return RouteMatch {
      params: params.buildReadonly(),
      remaining: remainingPath(path, segmentIndex),
    }
  }

  return RouteMatch {
    params: params.buildReadonly(),
    remaining: emptyRemainingPath(),
  }
}

function methodNotAllowedResponse(methods: readonly string[]): HttpResponse {
  headers: HttpHeader[] := []
  headers.push(HttpHeader {
    name: "Allow",
    value: joinMethods(methods),
  })
  return Response {
    status: 405,
    headers: headers.buildReadonly(),
    body: readonly [],
  }
}

function joinMethods(methods: readonly string[]): string {
  if methods.length == 0 {
    return ""
  }

  let text = methods[0]
  for index of 1..<methods.length {
    text = "${text}, ${methods[index]}"
  }
  return text
}


function normalizedSegments(pattern: string): readonly string[] {
  let start = 0
  let end = pattern.length

  while start < end && pattern.charAt(start) == '/' {
    start += 1
  }

  while end > start && pattern.charAt(end - 1) == '/' {
    end -= 1
  }

  if start >= end {
    return readonly []
  }

  return pattern.substring(start, end).split("/").buildReadonly()
}

function remainingPath(path: Path, start: int): Path {
  segments: string[] := []
  for index of start..<path.segments.length {
    segments.push(path.segments[index])
  }
  return Path {
    absolute: false,
    segments: segments.buildReadonly(),
  }
}

function emptyRemainingPath(): Path {
  return Path {
    absolute: false,
    segments: readonly [],
  }
}

function isValidParamName(name: string): bool {
  if name.length == 0 {
    return false
  }

  first := name.charAt(0)
  if !isAlpha(first) && first != '_' {
    return false
  }

  for index of 1..<name.length {
    current := name.charAt(index)
    if !isAlpha(current) && !isDigit(current) && current != '_' {
      return false
    }
  }

  return true
}

function isAlpha(value: char): bool {
  return (value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z')
}

function isDigit(value: char): bool {
  return value >= '0' && value <= '9'
}

function patternError(kind: string, index: int, message: string): Result<RoutePattern, RoutePatternError> {
  return Failure {
    error: RoutePatternError {
      kind,
      index,
      message,
    }
  }
}

function fileSystemPathError(kind: string, segment: int, message: string): Result<string, FileSystemPathError> {
  return Failure {
    error: FileSystemPathError {
      kind,
      segment,
      message,
    }
  }
}

function segmentIndex(pattern: string, targetSegment: int): int {
  let segment = 0
  let index = 0

  while index < pattern.length && pattern.charAt(index) == '/' {
    index += 1
  }

  while segment < targetSegment && index < pattern.length {
    if pattern.charAt(index) == '/' {
      segment += 1
      while index < pattern.length && pattern.charAt(index) == '/' {
        index += 1
      }
      continue
    }
    index += 1
  }

  return index
}
