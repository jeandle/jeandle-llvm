; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA positive: one arm of the branch has an unrelated side-effect
; (a call to @log that doesn't touch the virtual) and the other arm is empty.
; Neither arm mutates the tracked field, so mergeStates concludes both preds
; agree on the field state and the object stays virtual at the merge entry.
; The post-merge load folds to the original stored constant and the
; allocation is erased.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @log(i32)
declare i32 @__gxx_personality_v0(...)

define i32 @test_branch_no_touch(i1 %c, i32 %x) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 7, ptr addrspace(1) %s unordered, align 4
  br i1 %c, label %t, label %f
t:
  call void @log(i32 %x)
  br label %merge
f:
  br label %merge
merge:
  %v = load atomic i32, ptr addrspace(1) %s unordered, align 4
  ret i32 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_branch_no_touch
; CHECK-NOT: jeandle.new_instance
; CHECK: ret i32 7

!java-method-compilation = !{}
