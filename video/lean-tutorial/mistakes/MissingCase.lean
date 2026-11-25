inductive Pointer where
  | protocol (name : String)
  | unconverted

def Pointer.describe : Pointer → String
  | .protocol n => s!"the faithful rules of {n}"
