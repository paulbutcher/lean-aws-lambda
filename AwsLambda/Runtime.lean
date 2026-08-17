/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import AwsLambda.Api

open Lean (Json)
open Std Async

namespace AwsLambda

/-- What a function does with an invocation.

A JSON document in and a JSON document out is the whole of the runtime API's contract, whatever
invoked the function: a queue, a bucket notification, a schedule, an HTTP request. An `Except`
rather than an exception because a handler that cannot answer is an ordinary outcome to be reported
against the invocation, not a fault in the process serving it. -/
abbrev Handler := Json → Async (Except String Json)

/-- Something that went wrong which the runtime API could not be told about, or which it was told
about and an operator would still want to know. -/
inductive Failure where
  /-- The runtime API could not be asked for the next invocation. Nothing can be reported against
  an invocation that was never received, and the environment is given up rather than retried. -/
  | next (reason : String)
  /-- The handler could not produce a response. Reported to the runtime API as well. -/
  | handler (requestId : String) (reason : String)
  /-- An outcome could not be reported, so the invocation is left to time out. -/
  | report (requestId : String) (reason : String)
deriving BEq

def Failure.describe : Failure → String
  | .next reason => s!"could not fetch the next invocation: {reason}"
  | .handler requestId reason => s!"no response for {requestId}: {reason}"
  | .report requestId reason => s!"could not report the outcome of {requestId}: {reason}"

/-- How to serve invocations. -/
structure Options where
  /-- Where failures go. Structured rather than pre-formatted so a consumer can attach the parts to
  a span or a metric instead of parsing them back out of a line of text. -/
  onFailure : Failure → IO Unit := fun failure => IO.eprintln s!"lambda: {failure.describe}"

/-- Serves invocations until the execution environment is torn down.

Exits rather than continuing when `/next` fails. Nothing can be reported against an invocation that
never arrived, and carrying on would retry immediately for the rest of the environment's life,
calling `onFailure` on every pass. Exiting hands the problem to Lambda, which replaces the
environment. -/
def run (handler : Handler) (endpoint : Endpoint) (options : Options := {}) : Async Unit := do
  while true do
    match ← next endpoint with
    | .error reason =>
      options.onFailure (.next reason)
      throw <| IO.userError (Failure.next reason).describe
    | .ok invocation =>
      let outcome ←
        try handler invocation.event
        catch e => pure (.error (toString e))
      let posted ←
        match outcome with
        | .ok payload => postResponse endpoint invocation.requestId payload
        | .error reason =>
          options.onFailure (.handler invocation.requestId reason)
          postError endpoint invocation.requestId reason
      if let .error reason := posted then
        options.onFailure (.report invocation.requestId reason)

/-- The whole life of a Lambda process: find the runtime API, run `init` once, then serve
invocations with the handler it produced.

`init` covers everything that should happen once per execution environment rather than once per
invocation, such as opening a connection pool or reading a secret. A failure there is reported to
the runtime API's init endpoint before the process exits, so that Lambda replaces the environment
instead of leaving it to accept an invocation it has no way to serve. -/
def serve (init : Async Handler) (options : Options := {}) : IO Unit := Async.block do
  let endpoint ← Endpoint.fromEnv
  let started ←
    try
      Except.ok <$> init
    catch e =>
      pure (Except.error (toString e))
  match started with
  | .error reason =>
    discard <| postInitError endpoint reason
    throw (IO.userError reason)
  | .ok handler =>
    run handler endpoint options

end AwsLambda
