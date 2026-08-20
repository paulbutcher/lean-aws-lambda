/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import AwsLambda
import AwsLambdaHttp.Event
import AwsLambdaHttp.Response

open Std Async
open Std Http Server

namespace AwsLambda.Http

private def invoke (options : Options) (h : StatelessHandler) (event : Json) :
    ExceptT String Async Json := do
  let event ← ExceptT.mk (pure (Event.ofJson event))
  let request ← ExceptT.mk (Event.toRequest event)
  let response ← (h.onRequest request).run
  ExceptT.mk (responseToJson options response)

/-- Presents an ordinary `Std.Http` handler as something `AwsLambda.serve` can run.

This is the whole of what the HTTP layer offers, and the only place the two halves meet: nothing
below this knows a runtime API exists, and nothing above it knows what HTTP is. -/
def handler (h : StatelessHandler) (options : Options := {}) : AwsLambda.Handler :=
  fun event => invoke options h event

end AwsLambda.Http
