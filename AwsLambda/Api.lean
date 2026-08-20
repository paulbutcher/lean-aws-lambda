/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Json
import Std.Async.TCP
import Std.Net.Addr

open Std Async

namespace AwsLambda

private def readChunkSize : UInt64 := 65536

private def maxHeadBytes : Nat := 32768

/-- A synchronous invocation's payload cannot exceed this, so neither can anything the runtime API
sends in reply to a request for one. -/
def maxEventBytes : Nat := 6 * 1024 * 1024

/-- The runtime API's own responses, as distinct from the responses a function produces for
whatever invoked it. -/
private structure ApiResponse where
  status : Nat
  headers : Array (String × String)
  body : ByteArray

/-- Failure here is always a `String`: nothing a caller can do about a runtime API that will not
answer differs by which way it refused. -/
private abbrev Api := ExceptT String Async

/-- Where the runtime API listens, in the `host:port` form the execution environment advertises
it as. `host` is kept as written so it can go straight back out as the `Host` header. -/
structure Endpoint where
  host : String
  addr : Std.Net.SocketAddress

/-- The execution environment advertises a literal address rather than a name, so this parses a
dotted quad instead of resolving through DNS. -/
def Endpoint.ofString (s : String) : Option Endpoint := do
  let (host, port) ←
    match s.splitOn ":" with
    | [host, port] => do
      let port ← port.toNat?
      if port < 65536 then some (host, port.toUInt16) else none
    | _ => none
  let octets ← (host.splitOn ".").mapM fun part => do
    let n ← part.toNat?
    if n < 256 then some n.toUInt8 else none
  match octets with
  | [a, b, c, d] => some { host := s, addr := .v4 ⟨.ofParts a b c d, port⟩ }
  | _ => none

/-- Reads the endpoint the execution environment advertises.

Throwing rather than reporting is right for both failures: neither can be reported to the runtime
API, because the address of the thing to report to is exactly what is missing. -/
def Endpoint.fromEnv : IO Endpoint := do
  let some advertised ← IO.getEnv "AWS_LAMBDA_RUNTIME_API"
    | throw (IO.userError "AWS_LAMBDA_RUNTIME_API is not set")
  let some endpoint := Endpoint.ofString advertised
    | throw (IO.userError s!"AWS_LAMBDA_RUNTIME_API is not a host:port address: {advertised}")
  pure endpoint

private def isHeadEnd (bytes : ByteArray) (i : Nat) : Bool :=
  bytes[i]? == some 13 && bytes[i + 1]? == some 10
    && bytes[i + 2]? == some 13 && bytes[i + 3]? == some 10

private def headEnd (bytes : ByteArray) : Option Nat :=
  (List.range bytes.size).find? (isHeadEnd bytes)

private def readHead (socket : TCP.Socket.Client) : Api (ByteArray × Nat) := do
  let mut acc := ByteArray.empty
  let mut closed := false
  while (headEnd acc).isNone do
    if closed then
      throw "the runtime API closed the connection before completing the response head"
    if acc.size > maxHeadBytes then
      throw "the runtime API response head exceeds the read limit"
    match ← socket.recv? readChunkSize with
    | none => closed := true
    | some chunk => acc := acc ++ chunk
  match headEnd acc with
  | some i => pure (acc, i + 4)
  | none => throw "the runtime API response head is incomplete"

/-- With no `Content-Length` the message runs to the end of the connection, which the
`Connection: close` on every request makes a usable boundary. -/
private def readToEnd (socket : TCP.Socket.Client) (buffered : ByteArray) : Api ByteArray := do
  let mut acc := buffered
  let mut reading := true
  while reading do
    match ← socket.recv? readChunkSize with
    | none => reading := false
    | some chunk => acc := acc ++ chunk
  pure acc

private def readBody (socket : TCP.Socket.Client) (buffered : ByteArray) (length : Option Nat) :
    Api ByteArray := do
  let some length := length | readToEnd socket buffered
  let mut acc := buffered
  let mut closed := false
  while acc.size < length do
    if closed then
      throw "the runtime API closed the connection before completing the response body"
    match ← socket.recv? readChunkSize with
    | none => closed := true
    | some chunk => acc := acc ++ chunk
  pure (acc.extract 0 length)

/-- The outcome of decoding as much of a chunked body as has arrived so far. -/
inductive Chunked where
  | complete (body : ByteArray)
  | needMore
  | malformed (reason : String)
deriving BEq

private def isCrlfAt (bytes : ByteArray) (i : Nat) : Bool :=
  bytes[i]? == some 13 && bytes[i + 1]? == some 10

private def crlfFrom (bytes : ByteArray) (start : Nat) : Option Nat :=
  (List.range' start (bytes.size - start)).find? (isCrlfAt bytes)

/-- A chunk-size line is hex, optionally followed by `;` and extensions this decoder ignores. -/
private def chunkSize? (line : ByteArray) : Option Nat := do
  let text ← String.fromUTF8? line
  let digits := (text.splitOn ";").headD text |>.trimAscii.toString
  if digits.isEmpty then none else
    digits.foldl (init := some 0) fun acc c => do
      let acc ← acc
      let d ←
        if '0' ≤ c ∧ c ≤ '9' then some (c.toNat - '0'.toNat)
        else if 'a' ≤ c ∧ c ≤ 'f' then some (c.toNat - 'a'.toNat + 10)
        else if 'A' ≤ c ∧ c ≤ 'F' then some (c.toNat - 'A'.toNat + 10)
        else none
      some (acc * 16 + d)

/-- Reassembles a `Transfer-Encoding: chunked` body, reporting `needMore` rather than failing when
`bytes` holds only part of one, so a caller can read again and retry. Trailers are skipped: the
runtime API has no use for them and nothing here reads them. -/
def decodeChunked (bytes : ByteArray) : Chunked := Id.run do
  let mut pos := 0
  let mut body := ByteArray.empty
  while true do
    let some lineEnd := crlfFrom bytes pos | return .needMore
    let some size := chunkSize? (bytes.extract pos lineEnd)
      | return .malformed s!"unreadable chunk size at byte {pos}"
    let dataStart := lineEnd + 2
    if size == 0 then
      -- The body ends at the blank line closing the (possibly empty) trailer section.
      let mut trailer := dataStart
      while true do
        if isCrlfAt bytes trailer then
          return .complete body
        let some next := crlfFrom bytes trailer | return .needMore
        trailer := next + 2
      return .needMore
    if bytes.size < dataStart + size + 2 then
      return .needMore
    if !isCrlfAt bytes (dataStart + size) then
      return .malformed s!"chunk of {size} bytes is not followed by CRLF"
    body := body ++ bytes.extract dataStart (dataStart + size)
    pos := dataStart + size + 2
  return .malformed "unterminated chunked body"

private def readChunked (socket : TCP.Socket.Client) (buffered : ByteArray) : Api ByteArray := do
  let mut acc := buffered
  let mut closed := false
  while true do
    match decodeChunked acc with
    | .complete body => return body
    | .malformed reason => throw s!"the runtime API sent a malformed chunked body: {reason}"
    | .needMore =>
      if closed then
        throw "the runtime API closed the connection mid-chunk"
      if acc.size > maxEventBytes then
        throw "the runtime API response body exceeds the read limit"
      match ← socket.recv? readChunkSize with
      | none => closed := true
      | some chunk => acc := acc ++ chunk
  throw "unterminated chunked body"

private def parseHead (text : String) : Except String (Nat × Array (String × String)) := do
  match text.splitOn "\r\n" with
  | [] => throw "empty runtime API response head"
  | statusLine :: rest =>
    let some status := (statusLine.splitOn " ")[1]?.bind (·.toNat?)
      | throw s!"malformed runtime API status line: {statusLine}"
    let headers := rest.filterMap fun line =>
      match line.splitOn ":" with
      | name :: value :: more =>
        some (name.trimAscii.toString.toLower,
          (String.intercalate ":" (value :: more)).trimAscii.toString)
      | _ => none
    pure (status, headers.toArray)

/-- One request per connection. The `/next` call blocks until an invocation arrives and the
environment is frozen in between, so a connection held across invocations would be resumed
against a peer that may long since have dropped it. -/
private def request (endpoint : Endpoint) (method path : String) (body : Option ByteArray) :
    Api ApiResponse := do
  let socket ← TCP.Socket.Client.mk
  socket.connect endpoint.addr
  let head :=
    s!"{method} {path} HTTP/1.1\r\nHost: {endpoint.host}\r\nConnection: close\r\n"
      ++ (match body with
          | some body => s!"Content-Type: application/json\r\nContent-Length: {body.size}\r\n"
          | none => "")
      ++ "\r\n"
  socket.send (head.toUTF8 ++ body.getD .empty)
  let (buffered, bodyStart) ← readHead socket
  let some text := String.fromUTF8? (buffered.extract 0 (bodyStart - 4))
    | throw "the runtime API response head is not valid UTF-8"
  let (status, headers) ← parseHead text
  let header (name : String) := (headers.find? (·.1 == name)).map (·.2)
  let rest := buffered.extract bodyStart buffered.size
  let chunked := ((header "transfer-encoding").map (·.toLower.splitOn ",")).getD []
    |>.any (·.trimAscii.toString == "chunked")
  let body ←
    if chunked then
      readChunked socket rest
    else
      readBody socket rest ((header "content-length").bind (·.toNat?))
  pure { status, headers, body }

/-- An invocation, paired with the id every subsequent call about it has to quote. -/
structure Invocation where
  requestId : String
  event : Json

private def nextInvocation (endpoint : Endpoint) : Api Invocation := do
  let response ← request endpoint "GET" "/2018-06-01/runtime/invocation/next" none
  let some requestId := (response.headers.find? (·.1 == "lambda-runtime-aws-request-id")).map (·.2)
    | throw "the runtime API did not identify the invocation"
  let some text := String.fromUTF8? response.body
    | throw "the invocation event is not valid UTF-8"
  match Json.parse text with
  | .ok event => pure { requestId, event }
  | .error e => throw s!"the invocation event is not valid JSON: {e}"

/-- Waits for the next invocation. Blocks for as long as the execution environment is kept alive
without one, which is the runtime API's normal behaviour rather than a fault. -/
def next (endpoint : Endpoint) : Async (Except String Invocation) :=
  nextInvocation endpoint

private def errorPayload (message : String) : ByteArray :=
  (Json.mkObj [("errorMessage", Json.str message),
    ("errorType", Json.str "AdapterError")]).compress.toUTF8

/-- Reports `payload` as the outcome of `requestId`. -/
def postResponse (endpoint : Endpoint) (requestId : String) (payload : Json) :
    Async (Except String Unit) :=
  (discard <| request endpoint "POST" s!"/2018-06-01/runtime/invocation/{requestId}/response"
    (some payload.compress.toUTF8) : Api Unit)

/-- Reports that `requestId` could not be answered. Worth reaching even when nothing can be done
about the failure, because the alternative is an invocation that stays open until Lambda times it
out. -/
def postError (endpoint : Endpoint) (requestId message : String) : Async (Except String Unit) :=
  (discard <| request endpoint "POST" s!"/2018-06-01/runtime/invocation/{requestId}/error"
    (some (errorPayload message)) : Api Unit)

/-- Reports that initialisation failed, which has the execution environment torn down rather than
left to accept an invocation it cannot serve. -/
def postInitError (endpoint : Endpoint) (message : String) : Async (Except String Unit) :=
  (discard <| request endpoint "POST" "/2018-06-01/runtime/init/error"
    (some (errorPayload message)) : Api Unit)

end AwsLambda
