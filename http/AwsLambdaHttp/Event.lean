/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Json
import Middleware
import Std.Http.Server

open Std Async
open Std Http
open Std Http Server

namespace AwsLambda.Http

/-- The payload format this adapter reads. Function URLs emit it, as does an API Gateway HTTP API;
a REST API's format 1.0 and an ALB's target payload are different shapes and are rejected rather
than half-read. -/
def payloadVersion : String := "2.0"

/-- The fields of an API Gateway payload format 2.0 event that this adapter uses. Everything
else the event carries (authorizer identity, stage variables, timestamps) has no bearing on the
`Request` the handler sees. -/
structure Event where
  method : String
  rawPath : String
  rawQueryString : String
  headers : Array (String × String)
  cookies : Array String
  sourceIp : String
  body : ByteArray
deriving Inhabited

namespace Event

private def stringFields (j : Json) : Array (String × String) :=
  match j with
  | .obj fields => fields.filterMap fun (name, value) =>
    match value with
    | .str s => some (name, s)
    | _ => none
  | _ => #[]

private def strings (j : Json) : Array String :=
  match j with
  | .arr elems => elems.filterMap fun
    | .str s => some s
    | _ => none
  | _ => #[]

private def orDefault (e : Except String α) (fallback : α) : α :=
  match e with
  | .ok v => v
  | .error _ => fallback

/-- The version is checked first and explicitly. Another format would otherwise fail further down
on whichever field it happens not to carry, reporting a missing `requestContext` for what is really
a function wired to the wrong kind of trigger. -/
def ofJson (j : Json) : Except String Event := do
  match j.getObjVal? "version" >>= Json.getStr? with
  | .ok version =>
    if version != payloadVersion then
      throw s!"unsupported payload format version {version}: this adapter reads {payloadVersion}"
  | .error _ =>
    throw s!"the event carries no payload format version: this adapter reads {payloadVersion}"
  let http ← j.getObjVal? "requestContext" >>= (Json.getObjVal? · "http")
  let method ← http.getObjVal? "method" >>= Json.getStr?
  let sourceIp ← http.getObjVal? "sourceIp" >>= Json.getStr?
  let rawPath ← j.getObjVal? "rawPath" >>= Json.getStr?
  let rawQueryString := orDefault (j.getObjVal? "rawQueryString" >>= Json.getStr?) ""
  let headers := stringFields (orDefault (j.getObjVal? "headers") .null)
  let cookies := strings (orDefault (j.getObjVal? "cookies") .null)
  let raw := orDefault (j.getObjVal? "body" >>= Json.getStr?) ""
  let body ←
    if orDefault (j.getObjVal? "isBase64Encoded" >>= Json.getBool?) false then
      match Middleware.Crypto.Base64.decode raw with
      | some bytes => pure bytes
      | none => throw "isBase64Encoded is set but the body is not valid base64"
    else
      pure raw.toUTF8
  pure { method, rawPath, rawQueryString, headers, cookies, sourceIp, body }

/-- Names `requestHeaders` sets itself, and therefore ignores in the event's header map. -/
def isAdapterOwned (name : String) : Bool :=
  let name := name.toLower
  name == "cookie" || name == "x-forwarded-for" || name == "x-forwarded-proto"

/-- The headers the handler sees. Three of them come from the adapter rather than from the
event's own header map, and each is a correctness requirement rather than a tidying-up:

* `Cookie` is reassembled from the event's `cookies` array. Payload format 2.0 delivers request
  cookies there and omits the header entirely, so without this the request reaching the handler
  has no cookies at all and every session lookup and anti-forgery check fails.
* `X-Forwarded-For` is set from `requestContext.http.sourceIp`, discarding whatever the client
  sent. A function URL truncates `x-forwarded-for` to its leftmost entry, which is the entry the
  client controls, so forwarding the header on would hand `Middleware.forwardedRemoteAddr` an
  address the caller chose for itself.
* `X-Forwarded-Proto` is always `https`. Neither a function URL nor an API Gateway HTTP API has a
  plaintext listener, and `Middleware.requestOrigin` assumes `http` when nothing tells it
  otherwise.

The last two are why this adapter is documented as reading function URL and API Gateway events
only: both are unconditional, and a deployment that can be reached over plain http would need them
to be conditional instead.

A header the event carries that `Headers.insert?` rejects is dropped rather than failing the
whole request, matching what the server itself would have done with it off a socket. -/
def requestHeaders (event : Event) : Headers :=
  let fromEvent := event.headers.foldl (init := Headers.empty) fun headers (name, value) =>
    if isAdapterOwned name then headers else (headers.insert? name value).getD headers
  let withCookies :=
    if event.cookies.isEmpty then fromEvent
    else
      let joined := String.intercalate "; " event.cookies.toList
      (fromEvent.insert? "cookie" joined).getD fromEvent
  let withFor := (withCookies.insert? "x-forwarded-for" event.sourceIp).getD withCookies
  (withFor.insert? "x-forwarded-proto" "https").getD withFor

/-- Reuses the server's own request-target parser rather than assembling a `URI.Path` and
`URI.Query` by hand, so a path or query string the handler would have rejected off a socket is
rejected here too. -/
def head (event : Event) : Except String Request.Head := do
  let some method := Method.ofString? event.method
    | throw s!"unsupported method: {event.method}"
  let target :=
    if event.rawQueryString.isEmpty then event.rawPath
    else event.rawPath ++ "?" ++ event.rawQueryString
  let uri ←
    match (URI.Parser.parseRequestTarget <* Std.Internal.Parsec.eof).run target.toUTF8 with
    | .ok uri => pure uri
    | .error e => throw s!"invalid request target {target}: {e}"
  pure { method, version := .v11, uri, headers := event.requestHeaders }

def toRequest (event : Event) : Async (Except String (Request Body.Stream)) := do
  match event.head with
  | .error e => pure (.error e)
  | .ok line =>
    let body ← Body.fromBytes event.body
    pure (.ok { line, body })

end Event

end AwsLambda.Http
