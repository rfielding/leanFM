def collatz (n : Nat) (steps : Nat := 0) : Nat :=
  if n ≤ 1 then steps
  else
    let next := if n % 2 == 0 then n / 2
                else 3 * n + 1
    collatz next (steps + 1)
