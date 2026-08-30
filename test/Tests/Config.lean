/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

meta import AwsLambda

public section

namespace Tests

open AwsLambda

#guard (ofHex? "00ff10").map (·.toList) == some [0, 255, 16]
#guard (ofHex? "DeadBeef").map (·.toList) == some [222, 173, 190, 239]
#guard (ofHex? "").map (·.size) == some 0
#guard (ofHex? "abc").isNone
#guard (ofHex? "zz").isNone

end Tests
