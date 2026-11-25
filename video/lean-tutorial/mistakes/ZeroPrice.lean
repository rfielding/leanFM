structure Price where
  cents : Nat
  positive : 0 < cents

def free : Price := ⟨0, by decide⟩
