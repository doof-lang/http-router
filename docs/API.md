# std/http-router Guide

`std/http-router` connects `std/url.Path` parsing with `std/http-server`
requests. It provides a small route-pattern compiler, explicit match helpers,
and a fluent `Router` for HTTP handlers, prefix routes, static files, and
WebSocket upgrades.

## Patterns And Matches

Patterns are compiled once with `compileRoutePattern`. Static segments must
match exactly. Named captures begin with `:` and are returned in
`RouteMatch.params`.

```doof
pattern := try! compileRoutePattern("/users/:id")
path := try! parsePath("/users/42")
match := matchRoute(pattern, path)
id := match!.get("id")
```

`matchRoute` requires the full path to match. `matchRoutePrefix` matches a
leading prefix and returns the unmatched suffix as `RouteMatch.remaining`, which
is useful for subrouters and static file mounting.

## Fluent Router

Verb helpers such as `get` and `post` match the whole path and method.
`route(pattern, handler)` matches any method by prefix. Method-specific prefix
helpers such as `getPrefix` are useful for static file serving.

`Router.handle(request)` returns:

- a response when a route handles the request
- `null` when no path matches
- `405 Method Not Allowed` with `Allow` when the path matches but the method does not

Normal HTTP routes do not match WebSocket upgrade attempts. Use
`.websocket(path, handler)` for upgrade routes.

## Static Files And Safe Paths

`pathToFileSystemPath(root, path)` safely maps decoded URL paths under a
filesystem root. It rejects decoded parent traversal and decoded filesystem
separators before joining path parts.

`staticFiles(prefix, options)` builds on that helper and serves `GET` and `HEAD`
with content type, cache headers, ETags, `Last-Modified`, and conditional
`304 Not Modified` responses.

## API Map

Routing:

- `compileRoutePattern`
- `matchRoute`
- `matchRoutePrefix`
- `RoutePattern`
- `RouteMatch`
- `Router`

Filesystem helpers:

- `FileSystemPathError`
- `pathToFileSystemPath`
- `mimeTypeForFileSystemPath`
- `cacheControlForFileSystemPath`
- `fileSystemResponseHeaders`
- `fileSystemETag`
- `httpDate`
- `StaticFileOptions`

HTTP/WebSocket handler types are declared in the same module and operate on
`std/http-server.Request`, `Response`, and `WebSocketConnection`.

Declarations are defined in [index.do](../index.do).
