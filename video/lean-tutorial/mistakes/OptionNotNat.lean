def priceOf (item : String) : Option Nat :=
  if item == "tea" then some 3 else none

def total : Nat := priceOf "tea" + 1
