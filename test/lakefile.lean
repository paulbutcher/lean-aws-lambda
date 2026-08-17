/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Lake

open Lake DSL

/-- Its own package so that neither shipping library carries a dependency that exists only to test
it: Lake resolves requirements transitively, so anything they required would be fetched and built by
every application that used them. -/
package «awsLambda-tests» where
  testDriver := "tests"

require awsLambda from ".."

require «awsLambda-http» from "../http"

@[default_target]
lean_lib Tests

lean_exe tests where
  root := `Main
