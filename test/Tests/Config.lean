/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import AwsLambda

namespace Tests

open AwsLambda

#guard (ofHex? "00ff10").map (·.toList) == some [0, 255, 16]
#guard (ofHex? "DeadBeef").map (·.toList) == some [222, 173, 190, 239]
#guard (ofHex? "").map (·.size) == some 0
#guard (ofHex? "abc").isNone
#guard (ofHex? "zz").isNone

-- A generator confined to the hex alphabet has to be asked for twice the byte count it is meant to
-- produce, so the relationship a caller depends on when sizing a key is worth pinning down.
#guard (ofHex? (String.ofList (List.replicate 64 'a'))).map (·.size) == some 32

end Tests
