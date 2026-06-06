# std/http-router

Route pattern matching for `std/url.Path`, plus a small fluent router for
`std/http-server`.

```doof
import { compileRoutePattern, matchRoute } from "std/http-router"
import { parsePath } from "std/url"

pattern := try! compileRoutePattern("/users/:id")
path := try! parsePath("/users/42")
matched := matchRoute(pattern, path)
id := matched!.get("id")
```

Patterns are compiled once and can include static segments and named captures:

- `/users/:id`
- `/users/:id/posts/:postId`

Named params are returned as a readonly `Map<string, string>`. Use
`RouteMatch.get(name)` when the route pattern is expected to bind a name; it
panics if the name is missing. `matchRoutePrefix` returns a relative
`remaining` path for sub-routing; the fluent router's `route(pattern, handler)`
helper uses this prefix behavior for catch-all routing.

## Fluent router

```doof
import { Router, RouteMatch, HttpResponse } from "std/http-router"
import { Request, Response } from "std/http-server"

router := Router()
  .get("/news", (match: RouteMatch, request: Request): HttpResponse => {
    return Response.text(200, "Latest news")
  })
  .route("/api/:version", (match: RouteMatch, request: Request): HttpResponse => {
    return Response.text(200, match.remaining.segment(0))
  })
```

Verb helpers match the whole request path and require the corresponding HTTP
method. `route(pattern, handler)` matches any method and applies the pattern as
a prefix; the handler receives a `RouteMatch` whose `remaining` path has that
prefix removed. `getPrefix(pattern, handler)` and `headPrefix(pattern, handler)`
are method-specific prefix routes, which is useful for static file serving.
`Router.handle(request)` accepts a `std/http-server.Request`. It returns `null`
when no route path matches, and returns a `405 Method Not Allowed` response with
an `Allow` header when the path matches but the request method does not.

Static file serving can be mounted as a method-specific prefix route:

```doof
router := Router()
  .staticFiles("/", StaticFileOptions {
    root: documentRoot,
  })
```

Static file responses support `GET` and `HEAD`, include `Content-Type`,
`Cache-Control`, `ETag`, and `Last-Modified` headers, and return `304 Not
Modified` for matching `If-None-Match` or `If-Modified-Since` requests.

WebSocket routes use `.websocket(path, handler)` and only match requests with
`Upgrade: websocket` plus a `Connection` header containing the `upgrade` token.
Normal HTTP routes do not match websocket upgrade attempts. A websocket handler
can return either a `Response` or a `WebSocketConnection`; when it returns a
connection, the router calls `Request.upgradeToWebSocket(connection)` and
returns `null`.

## Filesystem paths

Use `pathToFileSystemPath(root, path)` to safely apply a URL `Path` relative to
a filesystem root. It returns `Result<string, FileSystemPathError>` and rejects
decoded parent traversal (`..`) and decoded filesystem separators before joining
the path parts.

```doof
import { pathToFileSystemPath } from "std/http-router"
import { parsePath } from "std/url"

path := try! parsePath("/assets/site.css")
filePath := try! pathToFileSystemPath("/srv/www", path)
```

For prefix routes, `RouteMatch.remainingFileSystemPath(root)` maps the
remaining subpath:

```doof
router := Router()
  .route("/static", (match: RouteMatch, request: Request): HttpResponse => {
    filePath := try! match.remainingFileSystemPath("/srv/www")
    return Response.text(200, filePath)
  })
```

`mimeTypeForFileSystemPath(path)` looks up a common MIME type by filesystem
extension and returns `string | null`:

```doof
contentType := mimeTypeForFileSystemPath(filePath) ?? "application/octet-stream"
```

`cacheControlForFileSystemPath(path)` returns conservative cache defaults for
common static assets, and `fileSystemResponseHeaders(path)` combines MIME and
cache headers:

```doof
headers := fileSystemResponseHeaders(
  filePath,
  mimeTypeForFileSystemPath(filePath) ?? "application/octet-stream",
)
```

`fileSystemETag(size, modifiedAt)` builds the validator used by static file
serving from filesystem metadata. `httpDate(epochSeconds)` formats Unix seconds
for HTTP headers.
