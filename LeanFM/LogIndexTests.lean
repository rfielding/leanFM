import LeanFM.LogIndex

/-! Tests of decision session-log-paging (clause selfhost.session.log-paging): the pure parts of
reading a log by line ranges. -/

namespace LeanFM.LogIndexTests
open LeanFM.LogIndex

def logOf (n : Nat) : String := String.join ((List.range n).map fun i => s!"line {i + 1}\n")
def bytesOf (s : String) : ByteArray := s.toUTF8

/-- Scan in chunks of `k` bytes. -/
def scanChunks (b : ByteArray) (k : Nat) : Index := Id.run do
  let mut ix : Index := {}
  let mut i := 0
  while i < b.size do
    ix := ix.scan (b.extract i (i + k))
    i := i + k
  return ix

def three := bytesOf (logOf 3000)

-- one chunk and chunks of many sizes give the same index
#guard (Index.scan {} three).lines == 3000
#guard [1, 2, 7, 64, 1000, 4096].all fun k => scanChunks three k == Index.scan {} three
-- the marks are the starts of lines 1, 1025 and 2049
#guard (Index.scan {} three).marks.size == 3
#guard (Index.scan {} three).marks[1]! == (bytesOf (logOf 1024)).size
#guard (Index.scan {} three).marks[2]! == (bytesOf (logOf 2048)).size
#guard (Index.scan {} three).markFor 1500 == ((bytesOf (logOf 1024)).size, 1025)
#guard (Index.scan {} three).markFor 1 == (0, 1)
-- a line without its newline is not counted until the newline comes
#guard (Index.scan {} (bytesOf "a\nb")).lines == 1
#guard (Index.scan {} (bytesOf "a\nb")).partialBytes == 1
#guard ((Index.scan {} (bytesOf "a\nb")).scan (bytesOf "c\n")).lines == 2
-- ranges as HTTP writes them
#guard (parseRange "lines=5-9").toOption == some (.span 5 9)
#guard (parseRange "lines=5-").toOption == some (.from_ 5)
#guard (parseRange "lines=-3").toOption == some (.last 3)
#guard (parseRange "bytes=0-1").toOption.isNone
#guard (parseRange "lines=1-2,4-5").toOption.isNone
#guard (parseRange "lines=9-5").toOption.isNone
#guard (parseRange "lines=").toOption.isNone
#guard (parseRange "lines=0-3").toOption.isNone
#guard resolve (.span 5 9) 100 == some (5, 9)
#guard resolve (.from_ 5) 100 == some (5, 100)
#guard resolve (.last 3) 100 == some (98, 100)
#guard resolve (.last 300) 100 == some (1, 100)
#guard resolve (.span 95 200) 100 == some (95, 100)
#guard resolve (.span 101 200) 100 == none
#guard resolve (.last 3) 0 == none
-- the standard FNV-1a offset basis for no input; the fingerprint covers the first line only
#guard hex16 (fnv1a .empty) == "cbf29ce484222325"
#guard fingerprint (bytesOf "abc\nxyz") == fingerprint (bytesOf "abc\nother")
#guard fingerprint (bytesOf "abc\n") != fingerprint (bytesOf "abd\n")

end LeanFM.LogIndexTests
