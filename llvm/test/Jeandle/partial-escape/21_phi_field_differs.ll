; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA positive: the two arms of the branch write different constants into
; the same tracked offset. mergeStates synthesizes a per-field PHI of i32 at
; the merge block; the post-merge load forwards through it and the original
; allocation/stores are eliminated entirely.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define i32 @test_phi_diff_field(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  br i1 %c, label %left, label %right
left:
  %s1 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 1, ptr addrspace(1) %s1 unordered, align 4
  br label %merge
right:
  %s2 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 2, ptr addrspace(1) %s2 unordered, align 4
  br label %merge
merge:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  %v = load atomic i32, ptr addrspace(1) %s unordered, align 4
  ret i32 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_phi_diff_field
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: = phi i32
; CHECK: ret i32

!java-method-compilation = !{}
