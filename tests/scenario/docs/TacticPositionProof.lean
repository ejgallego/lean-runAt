example (a b : Nat) (h : a = b) : 0 + a = b := by
  simp
  exact h
