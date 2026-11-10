; RUN: opt -S -verify-each -passes='require<partial-escape-analysis>,partial-escape-transform' -jeandle-vm-callback-log=%S/Inputs/813_copy_fold_common_return_replay.cblog %s | FileCheck %s
; RUN: opt -S -verify-each -passes='require<partial-escape-analysis>,partial-escape-transform,require<partial-escape-analysis>,partial-escape-transform,require<partial-escape-analysis>,partial-escape-transform' -jeandle-vm-callback-log=%S/Inputs/813_copy_fold_common_return_replay.cblog %s | FileCheck %s
;
; Materialization initializes the original allocation after its allocation or
; clone barrier. Publish those delayed writes before escape or lock replay.
; Repeated PEA must reuse both stores and their publication barrier.
target datalayout = "e-p:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare void @jeandle.membar_storestore()
declare void @publish(ptr addrspace(1), ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

; CHECK-LABEL: define void @nested_publication(
; CHECK: store atomic i8 %value, {{.*}} unordered, align 1
; CHECK-NEXT: call hotspotcc void @jeandle.membar_allocation_init(
; CHECK-NEXT: %{{[^ ]+}} = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
; CHECK-NEXT: store atomic ptr addrspace(1) %array, {{.*}} unordered, align 8
; CHECK-NEXT: call hotspotcc void @jeandle.membar_allocation_init(
; CHECK-NEXT: call void @publish(ptr addrspace(1) %outer, ptr addrspace(1) %array)
; CHECK-NEXT: ret void
define void @nested_publication(i8 %value) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false) to label %alloc unwind label %unwind
alloc:
  %array = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 1, i32 24, i32 16, i32 1048576, i1 false, i1 false) to label %init unwind label %unwind
init:
  %element = getelementptr inbounds i8, ptr addrspace(1) %array, i64 16
  store atomic i8 %value, ptr addrspace(1) %element unordered, align 1
  %field = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  store atomic ptr addrspace(1) %array, ptr addrspace(1) %field unordered, align 8
  call void @publish(ptr addrspace(1) %outer, ptr addrspace(1) %array)
  ret void
unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define void @locked_publication(
; CHECK: store atomic i32 %value, {{.*}} unordered, align 4
; CHECK-NEXT: call hotspotcc void @jeandle.membar_allocation_init(
; CHECK-NEXT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock
; CHECK-NEXT: call void @publish
; CHECK-NEXT: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock
; CHECK-NEXT: ret void
define void @locked_publication(i32 %value) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock = alloca i64, align 8
  %object = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false) to label %init unwind label %unwind
init:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %object, ptr %lock)
  %field = getelementptr inbounds i8, ptr addrspace(1) %object, i64 16
  store atomic i32 %value, ptr addrspace(1) %field unordered, align 4
  call void @publish(ptr addrspace(1) %object, ptr addrspace(1) null)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %object, ptr %lock)
  ret void
unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define i32 @stays_virtual(
; CHECK-NOT: fence
; CHECK-NOT: call
; CHECK: ret i32 %value
define i32 @stays_virtual(i32 %value) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %object = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false) to label %init unwind label %unwind
init:
  %field = getelementptr inbounds i8, ptr addrspace(1) %object, i64 16
  store atomic i32 %value, ptr addrspace(1) %field unordered, align 4
  %result = load atomic i32, ptr addrspace(1) %field unordered, align 4
  ret i32 %result
unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define void @empty_publication(
; CHECK: init:
; CHECK-NEXT: call void @publish
; CHECK-NEXT: ret void
define void @empty_publication() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %object = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false) to label %init unwind label %unwind
init:
  call void @publish(ptr addrspace(1) %object, ptr addrspace(1) null)
  ret void
unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}
!java-method-compilation = !{}
