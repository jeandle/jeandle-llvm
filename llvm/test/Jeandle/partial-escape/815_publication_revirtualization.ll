; RUN: opt -S -verify-each -passes='require<partial-escape-analysis>,partial-escape-transform' %s | FileCheck %s
; RUN: opt -S -verify-each -passes='partial-escape-iterative' -jeandle-pea-iterations=8 %s | FileCheck %s
;
; Initialization publication is tied to its receiver until PEA finishes.
; Revirtualizing its writes removes its publication; independent user fences
; retain their memory-ordering contract across inter-iteration InstCombine.
target datalayout = "e-p:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1)) nounwind "gc-leaf-function"
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

; CHECK-LABEL: define i32 @revirtualize(
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: store
; CHECK-NOT: call
; CHECK: fence release
; CHECK-NEXT: ret i32 %value
define i32 @revirtualize(i32 %value) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %object = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false) to label %init unwind label %unwind
init:
  %field = getelementptr inbounds i8, ptr addrspace(1) %object, i64 16
  store atomic i32 %value, ptr addrspace(1) %field unordered, align 4
  fence release
  call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %object)
  %result = load atomic i32, ptr addrspace(1) %field unordered, align 4
  ret i32 %result
unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define void @replay_after_user_fence(
; CHECK: fence release
; CHECK-NEXT: %[[FIELD:[^ ]+]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %object, i64 16
; CHECK-NEXT: store atomic i32 %value, ptr addrspace(1) %[[FIELD]] unordered, align 4
; CHECK-NEXT: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %object)
; CHECK-NEXT: call void @sink(ptr addrspace(1) %object)
; CHECK-NEXT: ret void
define void @replay_after_user_fence(i32 %value) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %object = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false) to label %init unwind label %unwind
init:
  %field = getelementptr inbounds i8, ptr addrspace(1) %object, i64 16
  store atomic i32 %value, ptr addrspace(1) %field unordered, align 4
  fence release
  call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %object)
  call void @sink(ptr addrspace(1) %object)
  ret void
unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}
!java-method-compilation = !{}
