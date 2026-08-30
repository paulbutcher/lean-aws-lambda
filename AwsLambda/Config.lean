/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public section

namespace AwsLambda

private def hexDigit? (c : Char) : Option UInt8 :=
  if '0' ≤ c ∧ c ≤ '9' then some (UInt8.ofNat (c.toNat - '0'.toNat))
  else if 'a' ≤ c ∧ c ≤ 'f' then some (UInt8.ofNat (c.toNat - 'a'.toNat + 10))
  else if 'A' ≤ c ∧ c ≤ 'F' then some (UInt8.ofNat (c.toNat - 'A'.toNat + 10))
  else none

private def hexPairs : List Char → Option (List UInt8)
  | [] => some []
  | high :: low :: rest => do
    let high ← hexDigit? high
    let low ← hexDigit? low
    let rest ← hexPairs rest
    some ((high * 16 + low) :: rest)
  | _ => none

/-- Decodes an even-length run of hex digits.

Hex is what a secret shared between concurrently running instances of a function tends to arrive
as. `AWS::SecretsManager::Secret`'s generator can be confined to the hex alphabet exactly, but it
cannot be made to emit the padding base64 needs to land on a key of a precise length, so a key
generated there and read back here has to travel this way. -/
def ofHex? (s : String) : Option ByteArray :=
  (hexPairs s.toList).map fun bytes => ⟨bytes.toArray⟩

/-- A character list that decodes at all decodes to exactly half as many bytes as it had
characters. This is where that count is established rather than merely relied on: `hexPairs` is the
function that actually recurses, taking two characters per byte, so the induction has to happen
here, and what `ofHex?` guarantees about lengths follows from this and nothing else.

`cs` is any character list and `bytes` any byte list; `h` says `hexPairs cs` succeeded and returned
exactly `bytes`, which confines the claim to lists that decode and says nothing about the ones
rejected. `2 * bytes.length = cs.length` then reads as: twice the number of bytes produced is the
number of characters consumed, fixing the count exactly rather than bounding it. The three cases
are the three the function is defined by: no characters yield no bytes, two or more yield one byte
plus whatever the tail yields, and a lone trailing character cannot decode, so `h` is
contradictory there and discharges the case rather than needing an argument. Nothing is vacuous:
`h` holds of any even-length run of hex digits, so the hypothesis does not rule out every
instance. -/
private theorem hexPairs_length {cs : List Char} {bytes : List UInt8}
    (h : hexPairs cs = some bytes) : 2 * bytes.length = cs.length := by
  induction cs using hexPairs.induct generalizing bytes with
  | case1 => simp [hexPairs] at h; simp [h]
  | case2 high low rest ih =>
    simp [hexPairs, Option.bind_eq_some_iff] at h
    obtain ⟨_, _, _, _, tail, htail, rfl⟩ := h
    have := ih htail
    simp only [List.length_cons]
    omega
  | case3 => simp [hexPairs] at h

/-- Every secret `ofHex?` accepts yields exactly half as many bytes as the string had characters.
That is the relationship a caller depends on when sizing a key: the generator is asked for a
character count, and what comes back here has to be the byte count the cipher needs. Getting it
wrong is not caught until a function is already serving, since a key of the wrong length is a
runtime failure rather than a decode failure.

`s` is any string and `bytes` any byte array; `h` says decoding `s` succeeded and produced exactly
`bytes`, so the claim covers the strings `ofHex?` accepts and asserts nothing about those it
rejects, which is the right scope because a rejected secret never reaches a key at all.
`2 * bytes.size = s.length` says twice the decoded byte count is the character count of the
original, which is what halving means, stated as an equation so it pins the size down rather than
bounding it. It is not vacuous: `h` is satisfied by any even-length run of hex digits. `s.length`
counts characters rather than UTF-8 bytes; the two agree here only because every character a
successful decode can contain is an ASCII hex digit, which follows from `hexDigit?` and is not
separately proved. -/
theorem ofHex?_length {s : String} {bytes : ByteArray} (h : ofHex? s = some bytes) :
    2 * bytes.size = s.length := by
  simp [ofHex?] at h
  obtain ⟨list, hlist, rfl⟩ := h
  simpa [ByteArray.size, String.length] using hexPairs_length hlist

end AwsLambda
