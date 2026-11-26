/-
Reading a log by line ranges (clause selfhost.session.log-paging, decision session-log-paging).

A log is only appended to, so a line, once its newline is written, never changes: a window of lines
can be cached by anyone and only the totals grow. The index here keeps the byte offset of every
1024th line, extended by reading only what was appended, so a window is read from the nearest kept
offset rather than from the start of the log.
-/

namespace LeanFM.LogIndex

/-- Every `markEvery`th line's start offset is kept. -/
def markEvery : Nat := 1024
/-- One window reads at most this many bytes of lines, then stops (nextLine says where to go on). -/
def windowBytes : Nat := 64 * 1024 * 1024
/-- The fingerprint covers the first line, up to this many bytes. -/
def fingerprintBytes : Nat := 4096

/-! ## Pure parts -/

/-- 64-bit FNV-1a. -/
def fnv1a (bytes : ByteArray) : UInt64 := Id.run do
  let mut h : UInt64 := 0xcbf29ce484222325
  for b in bytes do
    h := (h ^^^ b.toUInt64) * 0x100000001b3
  return h

def hex16 (x : UInt64) : String :=
  let digits := (Nat.toDigits 16 x.toNat)
  String.ofList (List.replicate (16 - digits.length) '0' ++ digits)

/-- The first line of a file's first bytes (all of them when no newline is among them). -/
def firstLine (bytes : ByteArray) : ByteArray := Id.run do
  for i in [0:bytes.size] do
    if bytes[i]! == 10 then return bytes.extract 0 i
  return bytes

def fingerprint (head : ByteArray) : String := hex16 (fnv1a (firstLine head))

/-- What an index knows of a file: its complete lines, the bytes read, the start offset of lines
1, 1025, 2049, ... (`marks`), and how many bytes after the last newline belong to a line still
being written. -/
structure Index where
  lines : Nat := 0
  size : Nat := 0
  marks : Array Nat := #[0]
  partialBytes : Nat := 0
  deriving Repr, BEq, Inhabited

/-- The index extended by the next `chunk` of the file. -/
def Index.scan (ix : Index) (chunk : ByteArray) : Index := Id.run do
  let mut lines := ix.lines
  let mut marks := ix.marks
  let mut partialBytes := ix.partialBytes
  for i in [0:chunk.size] do
    if chunk[i]! == 10 then
      lines := lines + 1
      partialBytes := 0
      -- the line after this one starts at the next byte
      if lines % markEvery == 0 then marks := marks.push (ix.size + i + 1)
    else
      partialBytes := partialBytes + 1
  return { lines, size := ix.size + chunk.size, marks, partialBytes }

/-- The kept offset at or before line `n` (from 1), and the number of the line starting there. -/
def Index.markFor (ix : Index) (n : Nat) : Nat × Nat :=
  let k := min ((n - 1) / markEvery) (ix.marks.size - 1)
  (ix.marks[k]!, k * markEvery + 1)

/-- A line range as HTTP writes one: `lines=A-B`, `lines=A-` or `lines=-N`. -/
inductive Range where
  | span (first last : Nat)
  | from_ (first : Nat)
  | last (count : Nat)
  deriving Repr, BEq

def parseRange (header : String) : Except String Range := do
  let h := header.trimAscii.toString
  unless h.startsWith "lines=" do throw "a range of lines is written lines=A-B, lines=A- or lines=-N"
  let spec := (h.drop 6).toString
  if spec.contains ',' then throw "one range of lines at a time"
  match spec.splitOn "-" with
  | ["", n] =>
      let some c := n.toNat? | throw "lines=-N takes a whole number"
      if c == 0 then throw "lines=-N takes at least 1"
      return .last c
  | [a, ""] =>
      let some f := a.toNat? | throw "lines=A- takes a whole number"
      if f == 0 then throw "lines count from 1"
      return .from_ f
  | [a, b] =>
      let (some f, some l) := (a.toNat?, b.toNat?) | throw "lines=A-B takes whole numbers"
      if f == 0 then throw "lines count from 1"
      if l < f then throw "a range of lines ends after it starts"
      return .span f l
  | _ => throw "a range of lines is written lines=A-B, lines=A- or lines=-N"

/-- The first and last line a range picks from `total` lines, or none when it starts after them. -/
def resolve (r : Range) (total : Nat) : Option (Nat × Nat) :=
  if total == 0 then none else
  match r with
  | .span f l => if f > total then none else some (f, min l total)
  | .from_ f => if f > total then none else some (f, total)
  | .last c => some (total - min c total + 1, total)

/-! ## The files -/

structure Entry where
  fingerprint : String
  index : Index
  handle : IO.FS.Handle

initialize table : IO.Ref (List (String × Entry)) ← IO.mkRef []

def readHead (path : System.FilePath) : IO ByteArray := do
  let h ← IO.FS.Handle.mk path .read
  h.read fingerprintBytes.toUSize

/-- Read the handle to its end, extending the index. -/
partial def drain (h : IO.FS.Handle) (ix : Index) : IO Index := do
  let chunk ← h.read 1048576
  if chunk.isEmpty then return ix
  drain h (ix.scan chunk)

/-- The index of a log as it is now: extended by what was appended, or rebuilt when the log shrank
or its first line changed. -/
def refresh (path : System.FilePath) : IO (String × Index) := do
  let key := path.toString
  let size := (← path.metadata).byteSize.toNat
  let fp := fingerprint (← readHead path)
  let old := (← table.get).lookup key
  let keep := match old with
    | some e => e.fingerprint == fp && size ≥ e.index.size
    | none => false
  let entry : Entry ← match old, keep with
    | some e, true => pure e
    | _, _ => do
        let h ← IO.FS.Handle.mk path .read
        pure { fingerprint := fp, index := {}, handle := h }
  let ix ← drain entry.handle entry.index
  let entry := { entry with index := ix }
  table.modify fun t => (key, entry) :: t.filter (·.1 != key)
  return (fp, ix)

/-- Read and drop `n` bytes (Lean has no seek). -/
partial def skip (h : IO.FS.Handle) (n : Nat) : IO ByteArray := do
  if n == 0 then return .empty
  let chunk ← h.read (min n 1048576).toUSize
  if chunk.isEmpty then return .empty
  if chunk.size ≥ n then return chunk.extract n chunk.size
  skip h (n - chunk.size)

/-- UTF-8 text of a line; a line that does not decode keeps its ASCII and shows '?' for the rest. -/
def lossy (line : ByteArray) : String :=
  match String.fromUTF8? line with
  | some t => t
  | none => String.ofList (line.toList.map fun b => if b < 128 then Char.ofNat b.toNat else '?')

/-- Lines `first` .. `last` (from 1) of a log whose index is `ix`, at most `windowBytes` of them:
the lines and the number of the line after the last one read. -/
partial def window (path : System.FilePath) (ix : Index) (first last : Nat) : IO (Array String × Nat) := do
  let last := min last ix.lines
  if first > last then return (#[], first)
  let (offset, at_) := ix.markFor first
  let h ← IO.FS.Handle.mk path .read
  let rest ← skip h offset
  let rec go (buf : ByteArray) (pos n : Nat) (acc : Array String) (bytes : Nat) : IO (Array String × Nat) := do
    -- the next complete line from pos, else read more (a cursor, so no line copies the rest)
    let mut nl : Option Nat := none
    for i in [pos:buf.size] do
      if buf[i]! == 10 then nl := some i; break
    match nl with
    | some i =>
        if n < first then go buf (i + 1) (n + 1) acc bytes
        else
          let line := buf.extract pos i
          let bytes := bytes + line.size + 1
          if bytes > windowBytes && !acc.isEmpty then return (acc, n)
          let acc := acc.push (lossy line)
          if n ≥ last then return (acc, n + 1)
          go buf (i + 1) (n + 1) acc bytes
    | none =>
        let more ← h.read 1048576
        if more.isEmpty then return (acc, n)
        go (buf.extract pos buf.size ++ more) 0 n acc bytes
  go rest 0 at_ #[] 0

end LeanFM.LogIndex
