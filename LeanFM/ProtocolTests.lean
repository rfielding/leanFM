import LeanFM.Protocol

namespace LeanFM

def emptyChannel : Channel Nat := { capacity := 1, queued := [] }
def fullChannel : Channel Nat := { capacity := 1, queued := [7] }

example : emptyChannel.send 7 = .sent fullChannel := by native_decide
example : fullChannel.send 8 = .blocked := by native_decide
example : emptyChannel.receive = .blocked := by native_decide
example : emptyChannel.tryReceive = none := by native_decide
example : fullChannel.receive = .received 7 emptyChannel := by native_decide
example : fullChannel.tryReceive = some (7, emptyChannel) := by native_decide

end LeanFM
