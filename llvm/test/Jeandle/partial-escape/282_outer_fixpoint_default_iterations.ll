; RUN: opt -S -passes="partial-escape-iterative" %s \
; RUN:   | FileCheck %s --check-prefix=DEFAULT
; RUN: opt -S -passes="partial-escape-iterative" -jeandle-pea-iterations=1 %s \
; RUN:   | FileCheck %s --check-prefix=ONE

; The wrapper's default iteration cap is 2. This test pins both sides
; of that contract:
;
;   DEFAULT prefix  -- no `-jeandle-pea-iterations` flag, so the cl::opt
;                      default (2) applies. Same input as 280; we
;                      expect round 1 replay plus canonicalization to make
;                      the branch constant, then round 2 to re-analyze the
;                      retained original allocation and fold its value.
;
;   ONE prefix      -- `-jeandle-pea-iterations=1` opt-down for callers
;                      that want strict single-round semantics. With the
;                      cap at 1 the wrapper still does one
;                      analyze+transform+canonicalize round. Its original
;                      allocation remains, while current-round
;                      canonicalization removes the dead sink and leaves the
;                      constant branch for a later SimplifyCFG round.
;
; If we ever bump the default again, the DEFAULT side of this test moves
; with it; the ONE side stays constant.

@G_zero = private unnamed_addr constant i32 0

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define i32 @test_default_two_rounds()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %v = load i32, ptr @G_zero, align 4
  %c = icmp ne i32 %v, 0
  br i1 %c, label %escape, label %fast
escape:
  call void @sink(ptr addrspace(1) %o)
  br label %fast
fast:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 42, ptr addrspace(1) %slot unordered, align 4
  %val = load atomic i32, ptr addrspace(1) %slot unordered, align 4
  ret i32 %val
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; DEFAULT-LABEL: define i32 @test_default_two_rounds()
; Round 2 folds the load to the constant 42 and the dead escape branch is
; removed (no sink). The retained original allocation may remain after this
; value-folding contract; allocation elimination is not this test's oracle.
; DEFAULT-NOT: call void @sink
; DEFAULT: ret i32 42

; ONE-LABEL: define i32 @test_default_two_rounds()
; ONE: jeandle.new_instance
; ONE: br i1 false
; ONE-NOT: call void @sink
; ONE: ret i32

!java-method-compilation = !{}
