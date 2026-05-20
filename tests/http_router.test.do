import { Assert } from "std/assert"
import { Response } from "std/http-server"
import { Path, parsePath } from "std/url"
import {
  HttpRequest,
  HttpResponse,
  Router,
  RouteMatch,
  RoutePattern,
  compileRoutePattern,
  matchRoute,
  matchRoutePrefix,
} from "../index"

function path(text: string): Path => try! parsePath(text)

function pattern(text: string): RoutePattern => try! compileRoutePattern(text)

function request(method: string, path: string): HttpRequest {
  return HttpRequest { method, path }
}

function text(status: int, body: string): HttpResponse {
  return Response.text(status, body)
}

function empty(status: int): HttpResponse {
  return Response.empty(status)
}

function assertCompileError(text: string, kind: string): void {
  case compileRoutePattern(text) {
    s: Success -> Assert.fail("expected pattern compile failure")
    f: Failure -> Assert.equal(f.error.kind, kind)
  }
}

export function testExactStaticRouteMatches(): void {
  matched := matchRoute(pattern("/news"), path("/news"))

  Assert.isTrue(matched != null)
  Assert.equal(matched!.params.size, 0)
  Assert.equal(matched!.remaining.segmentCount(), 0)
}

export function testExactRouteRejectsTrailingSegments(): void {
  matched := matchRoute(pattern("/news"), path("/news/today"))

  Assert.isTrue(matched == null)
}

export function testNamedParamCapture(): void {
  matched := matchRoute(pattern("/users/:id"), path("/users/42"))

  Assert.isTrue(matched != null)
  Assert.equal(matched!.get("id"), "42")
}

export function testMultipleNamedParamCapture(): void {
  matched := matchRoute(pattern("/users/:id/posts/:postId"), path("/users/42/posts/99"))

  Assert.isTrue(matched != null)
  Assert.equal(matched!.get("id"), "42")
  Assert.equal(matched!.get("postId"), "99")
}

export function testWildcardMatchesRestWithoutCapture(): void {
  matched := matchRoute(pattern("/files/*"), path("/files/a/b/c"))

  Assert.isTrue(matched != null)
  Assert.equal(matched!.params.size, 0)
  Assert.equal(matched!.remaining.segmentCount(), 0)
}

export function testNoMatchCases(): void {
  Assert.isTrue(matchRoute(pattern("/users/:id"), path("/teams/42")) == null)
  Assert.isTrue(matchRoute(pattern("/users/:id"), path("/users")) == null)
  Assert.isTrue(matchRoute(pattern("/users/:id"), path("/users/42/posts")) == null)
}

export function testPrefixMatchReturnsRemainingSubpath(): void {
  matched := matchRoutePrefix(pattern("children/:id"), path("/children/7/posts/12"))

  Assert.isTrue(matched != null)
  Assert.equal(matched!.get("id"), "7")
  Assert.isFalse(matched!.remaining.absolute)
  Assert.equal(matched!.remaining.segmentCount(), 2)
  Assert.equal(matched!.remaining.segment(0), "posts")
  Assert.equal(matched!.remaining.segment(1), "12")
}

export function testPrefixMatchCanBeExact(): void {
  matched := matchRoutePrefix(pattern("/children/:id"), path("/children/7"))

  Assert.isTrue(matched != null)
  Assert.equal(matched!.get("id"), "7")
  Assert.equal(matched!.remaining.segmentCount(), 0)
}

export function testSlashNormalization(): void {
  a := pattern("users/:id")
  b := pattern("/users/:id")
  c := pattern("/users/:id/")

  Assert.equal(matchRoute(a, path("/users/1"))!.get("id"), "1")
  Assert.equal(matchRoute(b, path("/users/2"))!.get("id"), "2")
  Assert.equal(matchRoute(c, path("/users/3"))!.get("id"), "3")
}

export function testDecodedPathSegmentsAreMatched(): void {
  matched := matchRoute(pattern("/files/:name"), path("/files/hello%20world"))

  Assert.isTrue(matched != null)
  Assert.equal(matched!.get("name"), "hello world")
}

export function testRootPatternMatchesEmptyPathOnly(): void {
  emptyPattern := pattern("/")

  Assert.isTrue(matchRoute(emptyPattern, path("")) != null)
  Assert.isTrue(matchRoute(emptyPattern, path("/")) == null)
}

export function testInvalidPatternsAreRejected(): void {
  assertCompileError("/users/:id/posts/:id", "duplicate-param")
  assertCompileError("/users/:", "empty-param")
  assertCompileError("/users/:9id", "invalid-param")
  assertCompileError("/files/*/edit", "non-final-wildcard")
}

export function testRouterGetMatchesExactPathAndMethod(): void {
  router := Router()
    .get("/news", (match: RouteMatch, request: HttpRequest): HttpResponse => text(200, "news"))

  matched := router.handle(request("GET", "/news"))
  wrongMethod := router.handle(request("POST", "/news"))
  trailing := router.handle(request("GET", "/news/today"))

  Assert.isTrue(matched != null)
  Assert.equal(matched!.status, 200)
  Assert.isTrue(wrongMethod == null)
  Assert.isTrue(trailing == null)
}

export function testRouterSupportsExpectedVerbHelpers(): void {
  router := Router()
    .head("/items", (match: RouteMatch, request: HttpRequest): HttpResponse => empty(200))
    .post("/items", (match: RouteMatch, request: HttpRequest): HttpResponse => empty(201))
    .put("/items", (match: RouteMatch, request: HttpRequest): HttpResponse => empty(202))
    .delete("/items", (match: RouteMatch, request: HttpRequest): HttpResponse => empty(203))
    .connect("/items", (match: RouteMatch, request: HttpRequest): HttpResponse => empty(204))
    .options("/items", (match: RouteMatch, request: HttpRequest): HttpResponse => empty(205))
    .trace("/items", (match: RouteMatch, request: HttpRequest): HttpResponse => empty(206))
    .patch("/items", (match: RouteMatch, request: HttpRequest): HttpResponse => empty(207))

  Assert.equal(router.handle(request("HEAD", "/items"))!.status, 200)
  Assert.equal(router.handle(request("POST", "/items"))!.status, 201)
  Assert.equal(router.handle(request("PUT", "/items"))!.status, 202)
  Assert.equal(router.handle(request("DELETE", "/items"))!.status, 203)
  Assert.equal(router.handle(request("CONNECT", "/items"))!.status, 204)
  Assert.equal(router.handle(request("OPTIONS", "/items"))!.status, 205)
  Assert.equal(router.handle(request("TRACE", "/items"))!.status, 206)
  Assert.equal(router.handle(request("PATCH", "/items"))!.status, 207)
}

export function testRouterUsesFirstRegisteredMatch(): void {
  router := Router()
    .get("/items/:id", (match: RouteMatch, request: HttpRequest): HttpResponse => empty(201))
    .get("/items/:id", (match: RouteMatch, request: HttpRequest): HttpResponse => empty(202))

  matched := router.handle(request("GET", "/items/42"))

  Assert.isTrue(matched != null)
  Assert.equal(matched!.status, 201)
}

export function testRouterReturnsNullWhenNothingMatches(): void {
  router := Router()
    .get("/news", (match: RouteMatch, request: HttpRequest): HttpResponse => text(200, "news"))

  Assert.isTrue(router.handle(request("GET", "/missing")) == null)
}

export function testRouterRouteMatchesAnyMethodAsPrefix(): void {
  router := Router()
    .route("/api/:version", (match: RouteMatch, request: HttpRequest): HttpResponse => {
      version := match.get("version")
      firstRemaining := match.remaining.segment(0)
      if request.method == "PATCH" && version == "v1" && firstRemaining == "users" {
        return empty(209)
      }
      return empty(500)
    })

  matched := router.handle(request("PATCH", "/api/v1/users/42"))

  Assert.isTrue(matched != null)
  Assert.equal(matched!.status, 209)
}

export function testRouterRouteCanMatchExactPrefix(): void {
  router := Router()
    .route("/api", (match: RouteMatch, request: HttpRequest): HttpResponse => {
      remainingCount := match.remaining.segmentCount()
      if remainingCount == 0 {
        return empty(210)
      }
      return empty(500)
    })

  matched := router.handle(request("GET", "/api"))

  Assert.isTrue(matched != null)
  Assert.equal(matched!.status, 210)
}

export function testRouterReturnsNullForInvalidRequestPath(): void {
  router := Router()
    .get("/news", (match: RouteMatch, request: HttpRequest): HttpResponse => text(200, "news"))

  Assert.isTrue(router.handle(request("GET", "/news/%")) == null)
}
