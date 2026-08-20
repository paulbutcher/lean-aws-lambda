/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Tests.Api
public import Tests.Config
public import Tests.Event
public import Tests.Harness

public section

namespace Tests

/-- The tests that have to be run. Anything stated as a `theorem` or a `#guard` has already been
checked by the time this builds, so only the ones that need to execute appear here. -/
def runAll : IO Unit := do
  runApiTests
  runEventTests
  IO.println "All tests passed."

end Tests
