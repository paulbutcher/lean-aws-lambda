/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import AwsLambdaHttp
import Middleware
import Tests.Harness

namespace Tests

open AwsLambda.Http
open Lean (Json)
open Std Async
open Std Http
open Std Http Server

/-- A payload format 2.0 event. The client has supplied both a `Cookie` header and an
`X-Forwarded-For` that disagree with what the request context reports, which is the case this
adapter exists to get right. -/
private def spoofedEvent : String :=
  "{\"version\":\"2.0\",\"rawPath\":\"/active\",\"rawQueryString\":\"show=all&n=2\"," ++
  "\"cookies\":[\"session=abc\",\"other=1\"]," ++
  "\"headers\":{\"host\":\"id.lambda-url.eu-west-1.on.aws\",\"x-forwarded-for\":\"10.0.0.1\"," ++
  "\"x-forwarded-proto\":\"http\",\"cookie\":\"session=forged\"," ++
  "\"hx-current-url\":\"http://example.com/active\"}," ++
  "\"requestContext\":{\"http\":{\"method\":\"POST\",\"path\":\"/active\"," ++
  "\"protocol\":\"HTTP/1.1\",\"sourceIp\":\"203.0.113.7\",\"userAgent\":\"agent\"}}," ++
  "\"body\":\"title=Buy+milk\",\"isBase64Encoded\":false}"

private def parseEvent (text : String) : Except String Event := do
  Event.ofJson (← Json.parse text)

private def headerOf (text : String) (name : String) : Option String := do
  let event := (parseEvent text).toOption
  let name ← Header.Name.ofString? name
  ((← event).requestHeaders.get? name).map (·.value)

-- The address the handler sees is the one AWS reports, not the one the caller asked for.
#guard headerOf spoofedEvent "x-forwarded-for" == some "203.0.113.7"

-- Neither supported trigger has a plaintext listener, whatever the event's own header claims.
#guard headerOf spoofedEvent "x-forwarded-proto" == some "https"

-- Payload format 2.0 puts request cookies in `cookies` and omits the header, so the header the
-- session and anti-forgery middleware read has to be rebuilt from that array alone.
#guard headerOf spoofedEvent "cookie" == some "session=abc; other=1"

-- Headers the adapter has no opinion about still reach the handler.
#guard headerOf spoofedEvent "hx-current-url" == some "http://example.com/active"

private def targetOf (text : String) : Option String := do
  let event ← (parseEvent text).toOption
  ((Event.head event).map (toString ·.uri)).toOption

#guard targetOf spoofedEvent == some "/active?show=all&n=2"

private def methodOf (text : String) : Option Method := do
  let event ← (parseEvent text).toOption
  ((Event.head event).map (·.method)).toOption

#guard methodOf spoofedEvent == some .post

/-- No value the caller puts in the event's header map can reach the handler under a name the
adapter sets for itself. Stated over an arbitrary trailing header because that is the shape of
the attack: `x-forwarded-for` arrives already truncated by the function URL to the single,
caller-chosen entry that `Middleware.forwardedRemoteAddr` would otherwise read back. -/
theorem requestHeaders_ignores_client_values (event : Event) (name value : String)
    (owned : Event.isAdapterOwned name) :
    Event.requestHeaders { event with headers := event.headers.push (name, value) }
      = Event.requestHeaders event := by
  simp [Event.requestHeaders, owned]

private def versionOf (version : String) : String :=
  s!"\{\"version\":\"{version}\",\"rawPath\":\"/\",\"rawQueryString\":\"\",\"headers\":\{}," ++
  "\"requestContext\":{\"http\":{\"method\":\"GET\",\"sourceIp\":\"203.0.113.7\"}}}"

-- A REST API's format 1.0 event and an ALB's are different shapes, and reading either as 2.0 would
-- silently lose the method and the path rather than fail. The version is what says which is which.
#guard (parseEvent (versionOf "2.0")).toOption.isSome
#guard (parseEvent (versionOf "1.0")).toOption.isNone

-- An event with no version at all cannot be assumed to be the one format this reads.
#guard (parseEvent
  ("{\"rawPath\":\"/\",\"requestContext\":{\"http\":{\"method\":\"GET\"," ++
   "\"sourceIp\":\"203.0.113.7\"}}}")).toOption.isNone

private def bodyOf (text : String) : IO String := do
  let .ok event := parseEvent text | throw (IO.userError s!"could not parse event: {text}")
  pure (String.fromUTF8? event.body |>.getD "<not utf-8>")

/-- `title=Buy+milk`, base64-encoded. -/
private def base64Event : String :=
  "{\"version\":\"2.0\",\"rawPath\":\"/\",\"rawQueryString\":\"\",\"headers\":{}," ++
  "\"requestContext\":{\"http\":{\"method\":\"POST\",\"sourceIp\":\"203.0.113.7\"}}," ++
  "\"body\":\"dGl0bGU9QnV5K21pbGs=\",\"isBase64Encoded\":true}"

private def testBodies : IO Unit := do
  checkEq "plain body" "title=Buy+milk" (← bodyOf spoofedEvent)
  checkEq "base64 body" "title=Buy+milk" (← bodyOf base64Event)

private def field (payload : Json) (name : String) : String :=
  ((payload.getObjVal? name).toOption.getD .null).compress

private def responseWith (headers : Headers) : Response Body.Any :=
  { line := { status := .ok, version := .v11, headers }, body := Body.Any.ofBody ({} : Body.Empty) }

/-- Lambda turns each entry of `cookies` into its own `Set-Cookie` header and rejects responses
that set the header directly, so a stack that sets several cookies depends on them being moved
across rather than left to collapse into one comma-joined header value. -/
private def testResponseCookies : IO Unit := do
  let headers := Headers.empty
    |>.insert Middleware.Header.Name.setCookie (.mk "session=abc; Path=/")
    |>.insert Middleware.Header.Name.setCookie (.mk "csrf=xyz; Path=/")
    |>.insert Header.Name.contentType (.mk "text/html")
  let .ok payload ← Async.block (responseToJson {} (responseWith headers))
    | throw (IO.userError "response could not be encoded")
  checkEq "both cookies move to the payload's cookies array"
    "[\"session=abc; Path=/\",\"csrf=xyz; Path=/\"]" (field payload "cookies")
  checkEq "no set-cookie is left among the headers"
    "{\"content-type\":\"text/html\"}" (field payload "headers")
  checkEq "the status travels as a number" "200" (field payload "statusCode")

/-- The ceiling is reported rather than the response being handed on to be rejected downstream,
and it is the configured one rather than a fixed one, because what the invocation path allows
varies. -/
private def testResponseSizeLimitIsEnforcedAndConfigurable : IO Unit := do
  let big := String.ofList (List.replicate 4096 'x')
  let body ← Async.block (Body.fromBytes big.toUTF8)
  let response : Response Body.Any :=
    { line := { status := .ok, version := .v11, headers := Headers.empty },
      body := Body.Any.ofBody body }
  match ← Async.block (responseToJson { maxResponseBytes := 1024 } response) with
  | .ok _ => throw (IO.userError "expected a response over the limit to be refused")
  | .error e =>
    unless (e.splitOn "1024").length == 2 do
      throw (IO.userError s!"expected the configured limit to be named in {e}")

def runEventTests : IO Unit := do
  testBodies
  testResponseCookies
  testResponseSizeLimitIsEnforcedAndConfigurable

end Tests
