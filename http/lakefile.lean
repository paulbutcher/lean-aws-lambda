/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Lake

open Lake DSL

/-- Separate from `awsLambda` so that a function serving something other than HTTP requests, a
queue or a schedule or a bucket notification, needs neither `Std.Http` nor a middleware stack to
build. Everything HTTP-shaped lives here; the runtime API lives there. -/
package «awsLambda-http» where
  version := v!"0.2.0"

require awsLambda from ".."

require middleware from git
  "https://github.com/paulbutcher/lean-middleware" @ "v0.3.0"

/-- The module root is `AwsLambdaHttp` rather than `AwsLambda.Http` because Lake resolves a module
name to exactly one package, and the `AwsLambda.*` tree already belongs to `awsLambda`. The Lean
namespace is unaffected: this still defines `AwsLambda.Http`. -/
@[default_target]
lean_lib AwsLambdaHttp
