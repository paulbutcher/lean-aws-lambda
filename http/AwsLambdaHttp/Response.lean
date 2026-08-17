/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Lean.Data.Json
import Middleware
import Std.Http.Server

open Lean (Json)
open Std Async
open Std Http
open Std Http Server

namespace AwsLambda.Http

/-- Lambda rejects a buffered response payload larger than this. -/
def defaultMaxResponseBytes : Nat := 6 * 1024 * 1024

/-- How to turn a handler's response into a payload. -/
structure Options where
  /-- Where to stop accumulating a response body.

  Configurable rather than fixed because the ceiling is a property of how the function is invoked
  rather than of Lambda: a buffered response to a function URL gets 6MB, but the limit differs for
  an asynchronous invocation, and differs again for a streamed response. Raising it past what the
  invocation path allows only moves where the response is rejected. -/
  maxResponseBytes : Nat := defaultMaxResponseBytes

/-- Accumulates the body, giving up as soon as it passes what will be accepted rather than
buffering a response that can only be rejected once complete. -/
private def collect (limit : Nat) (body : Body.Any) : Async (Except String ByteArray) := do
  let mut acc := ByteArray.empty
  while true do
    match ← body.recv with
    | none => break
    | some chunk =>
      acc := acc ++ chunk.data
      if acc.size > limit then
        return .error s!"response body exceeds the {limit} byte limit"
  pure (.ok acc)

private def joinDuplicates (pairs : Array (String × String)) : List (String × Json) :=
  pairs.foldl (init := #[]) (fun acc (name, value) =>
      match acc.findIdx? (·.1 == name) with
      | some i => acc.modify i fun (name, existing) => (name, existing ++ ", " ++ value)
      | none => acc.push (name, value))
    |>.toList.map fun (name, value) => (name, Json.str value)

/-- Lambda turns each entry of the payload's `cookies` array into its own `Set-Cookie` header and
documents that responses must not set the header directly. Leaving them among the headers would
collapse a stack's several cookies into one comma-joined value that no browser will read back. -/
private def splitCookies (headers : Headers) : Array String × List (String × Json) :=
  let (cookies, rest) := headers.toArray.foldl (init := (#[], #[]))
    fun (cookies, rest) (name, value) =>
      if name == Middleware.Header.Name.setCookie then
        (cookies.push value.value, rest)
      else
        (cookies, rest.push (name.value, value.value))
  (cookies, joinDuplicates rest)

/-- A body that isn't valid UTF-8 goes back base64-encoded. Sending text as text keeps
CloudWatch's record of the response readable, which is worth the branch. -/
def responseToJson (options : Options) (response : Response Body.Any) :
    Async (Except String Json) := do
  match ← collect options.maxResponseBytes response.body with
  | .error e => pure (.error e)
  | .ok bytes =>
    let (cookies, headers) := splitCookies response.line.headers
    let (body, isBase64Encoded) :=
      match String.fromUTF8? bytes with
      | some text => (text, false)
      | none => (Middleware.Crypto.Base64.encode bytes, true)
    pure <| .ok <| Json.mkObj [
      ("statusCode", Json.num response.line.status.toCode.toNat),
      ("headers", Json.mkObj headers),
      ("cookies", Json.arr (cookies.map Json.str)),
      ("body", Json.str body),
      ("isBase64Encoded", Json.bool isBase64Encoded)]

end AwsLambda.Http
