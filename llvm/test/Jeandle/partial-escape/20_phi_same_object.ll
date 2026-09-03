; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA positive: the allocation flows through a branch+merge where
; both arms agree the object is virtual and the tracked field is unchanged.
; mergeStates keeps the object virtual at the merge entry; the post-merge
; load folds to the original stored constant and the allocation is erased.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define i32 @test_phi_same_obj(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 42, ptr addrspace(1) %s unordered, align 4
  br i1 %c, label %left, label %right
left:
  br label %merge
right:
  br label %merge
merge:
  %v = load atomic i32, ptr addrspace(1) %s unordered, align 4
  ret i32 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Both branches preserve the field state (no modification). The merge sees
; the same virtual object from both, with the same field state (42 at
; offset 8). The load folds to 42 and the allocation is fully scalar-replaced.
; CHECK-LABEL: define i32 @test_phi_same_obj
; CHECK-NOT: jeandle.new_instance
; CHECK: ret i32 42

!java-method-compilation = !{}
