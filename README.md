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

Patterns are compiled once and can include static segments, named captures, and
a final wildcard:

- `/users/:id`
- `/files/*`
- `/users/:id/posts/:postId`

Named params are returned as a readonly `Map<string, string>`. Use
`RouteMatch.get(name)` when the route pattern is expected to bind a name; it
panics if the name is missing. Wildcards match the rest of the path but do not
add a param. `matchRoutePrefix` returns a relative
`remaining` path for sub-routing.

## Fluent router

```doof
import { Router, RouteMatch, HttpRequest, HttpResponse } from "std/http-router"
import { Response } from "std/http-server"

router := Router()
  .get("/news", (match: RouteMatch, request: HttpRequest): HttpResponse => {
    return Response.text(200, "Latest news")
  })
  .route("/api/:version", (match: RouteMatch, request: HttpRequest): HttpResponse => {
    return Response.text(200, match.remaining.segment(0))
  })
```

Verb helpers match the whole request path and require the corresponding HTTP
method. `route(pattern, handler)` matches any method and applies the pattern as
a prefix; the handler receives a `RouteMatch` whose `remaining` path has that
prefix removed. `Router.handle(request)` accepts either a `std/http-server`
`Request` or a router `HttpRequest`, and returns `HttpResponse | null` when no
route matches.
