import Lean

open Lean Elab Tactic

inductive TenCases where
  | c1 | c2 | c3 | c4 | c5 | c6 | c7 | c8 | c9 | c10

elab "slow_grind" : tactic => do
  let _ ← (IO.sleep 250 : BaseIO Unit)
  evalTactic (← `(tactic| simp_all))

section

variable
  (a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14 a15 a16 a17 a18 a19 a20 : Nat)
  (a21 a22 a23 a24 a25 a26 a27 a28 a29 a30 a31 a32 a33 a34 a35 a36 a37 a38 a39 a40 : Nat)
  (a41 a42 a43 a44 a45 a46 a47 a48 a49 a50 a51 a52 a53 a54 a55 a56 a57 a58 a59 a60 : Nat)
  (a61 a62 a63 a64 a65 a66 a67 a68 a69 a70 a71 a72 a73 a74 a75 a76 a77 a78 a79 a80 : Nat)

variable
  (h1 : a0 = a1) (h2 : a1 = a2) (h3 : a2 = a3) (h4 : a3 = a4) (h5 : a4 = a5)
  (h6 : a5 = a6) (h7 : a6 = a7) (h8 : a7 = a8) (h9 : a8 = a9) (h10 : a9 = a10)
  (h11 : a10 = a11) (h12 : a11 = a12) (h13 : a12 = a13) (h14 : a13 = a14) (h15 : a14 = a15)
  (h16 : a15 = a16) (h17 : a16 = a17) (h18 : a17 = a18) (h19 : a18 = a19) (h20 : a19 = a20)
  (h21 : a20 = a21) (h22 : a21 = a22) (h23 : a22 = a23) (h24 : a23 = a24) (h25 : a24 = a25)
  (h26 : a25 = a26) (h27 : a26 = a27) (h28 : a27 = a28) (h29 : a28 = a29) (h30 : a29 = a30)
  (h31 : a30 = a31) (h32 : a31 = a32) (h33 : a32 = a33) (h34 : a33 = a34) (h35 : a34 = a35)
  (h36 : a35 = a36) (h37 : a36 = a37) (h38 : a37 = a38) (h39 : a38 = a39) (h40 : a39 = a40)
  (h41 : a40 = a41) (h42 : a41 = a42) (h43 : a42 = a43) (h44 : a43 = a44) (h45 : a44 = a45)
  (h46 : a45 = a46) (h47 : a46 = a47) (h48 : a47 = a48) (h49 : a48 = a49) (h50 : a49 = a50)
  (h51 : a50 = a51) (h52 : a51 = a52) (h53 : a52 = a53) (h54 : a53 = a54) (h55 : a54 = a55)
  (h56 : a55 = a56) (h57 : a56 = a57) (h58 : a57 = a58) (h59 : a58 = a59) (h60 : a59 = a60)
  (h61 : a60 = a61) (h62 : a61 = a62) (h63 : a62 = a63) (h64 : a63 = a64) (h65 : a64 = a65)
  (h66 : a65 = a66) (h67 : a66 = a67) (h68 : a67 = a68) (h69 : a68 = a69) (h70 : a69 = a70)
  (h71 : a70 = a71) (h72 : a71 = a72) (h73 : a72 = a73) (h74 : a73 = a74) (h75 : a74 = a75)
  (h76 : a75 = a76) (h77 : a76 = a77) (h78 : a77 = a78) (h79 : a78 = a79) (h80 : a79 = a80)

example (tag : TenCases) : a0 = a80 := by
  cases tag with
  | c1 => sorry
  | c2 => sorry
  | c3 => sorry
  | c4 => sorry
  | c5 => sorry
  | c6 => sorry
  | c7 => sorry
  | c8 => sorry
  | c9 => sorry
  | c10 => sorry

example (tag : TenCases) : a0 = a80 := by
  cases tag with
  | c1 => sorry
  | c2 => sorry
  | c3 => sorry
  | c4 => sorry
  | c5 => sorry
  | c6 => sorry
  | c7 => sorry
  | c8 => sorry
  | c9 => sorry
  | c10 => sorry

example (tag : TenCases) : a0 = a80 := by
  cases tag with
  | c1 => sorry
  | c2 => sorry
  | c3 => sorry
  | c4 => sorry
  | c5 => sorry
  | c6 => sorry
  | c7 => sorry
  | c8 => sorry
  | c9 => sorry
  | c10 => sorry

example (tag : TenCases) : a0 = a80 := by
  cases tag with
  | c1 => sorry
  | c2 => sorry
  | c3 => sorry
  | c4 => sorry
  | c5 => sorry
  | c6 => sorry
  | c7 => sorry
  | c8 => sorry
  | c9 => sorry
  | c10 => sorry

example (tag : TenCases) : a0 = a80 := by
  cases tag with
  | c1 => sorry
  | c2 => sorry
  | c3 => sorry
  | c4 => sorry
  | c5 => sorry
  | c6 => sorry
  | c7 => sorry
  | c8 => sorry
  | c9 => sorry
  | c10 => sorry

example (tag : TenCases) : a0 = a80 := by
  cases tag with
  | c1 => sorry
  | c2 => sorry
  | c3 => sorry
  | c4 => sorry
  | c5 => sorry
  | c6 => sorry
  | c7 => sorry
  | c8 => sorry
  | c9 => sorry
  | c10 => sorry

example (tag : TenCases) : a0 = a80 := by
  cases tag with
  | c1 => sorry
  | c2 => sorry
  | c3 => sorry
  | c4 => sorry
  | c5 => sorry
  | c6 => sorry
  | c7 => sorry
  | c8 => sorry
  | c9 => sorry
  | c10 => sorry

example (tag : TenCases) : a0 = a80 := by
  cases tag with
  | c1 => sorry
  | c2 => sorry
  | c3 => sorry
  | c4 => sorry
  | c5 => sorry
  | c6 => sorry
  | c7 => sorry
  | c8 => sorry
  | c9 => sorry
  | c10 => sorry

example (tag : TenCases) : a0 = a80 := by
  cases tag with
  | c1 => sorry
  | c2 => sorry
  | c3 => sorry
  | c4 => sorry
  | c5 => sorry
  | c6 => sorry
  | c7 => sorry
  | c8 => sorry
  | c9 => sorry
  | c10 => sorry

example (tag : TenCases) : a0 = a80 := by
  cases tag with
  | c1 => sorry
  | c2 => sorry
  | c3 => sorry
  | c4 => sorry
  | c5 => sorry
  | c6 => sorry
  | c7 => sorry
  | c8 => sorry
  | c9 => sorry
  | c10 => sorry

end
