/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Lake

open Lake DSL

package awsLambda where
  version := v!"0.2.0"

require json from git
  "https://github.com/paulbutcher/lean-json" @ "v0.1.0"

@[default_target]
lean_lib AwsLambda

/-- The suite is its own package, so that neither shipping library has to declare the dependencies
it needs. Running it from here keeps `lake test` at the repo root as the single entry point. -/
@[test_driver]
script tests (args) do
  let lake ← IO.appPath
  let suite ← IO.Process.spawn {
    cmd := lake.toString
    args := #["test"] ++ args.toArray
    cwd := some "test"
    env := #[("LEAN_PATH", none), ("LEAN_SRC_PATH", none), ("LAKE", none), ("LAKE_HOME", none),
      ("LAKE_PKG_URL_MAP", none), ("ELAN_TOOLCHAIN", none)]
  }
  suite.wait
