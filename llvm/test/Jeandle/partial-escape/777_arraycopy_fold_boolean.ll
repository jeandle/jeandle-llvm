; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/777_arraycopy_fold_boolean.cblog %s | FileCheck %s

; boolean[] elements use one-byte physical storage. A validated arraycopy
; between virtual boolean arrays folds through i8 field state, including the
; zero-initialized default element.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare hotspotcc void @jeandle.arraycopy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64) #0

declare i32 @__gxx_personality_v0(...)

define i8 @test_arraycopy_fold_boolean() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 77701 to ptr), i32 2, i32 24, i32 16, i32 1048576)
         to label %n1 unwind label %u
n1:
  %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 77702 to ptr), i32 2, i32 24, i32 16, i32 1048576)
         to label %n2 unwind label %u
n2:
  %sbase = getelementptr inbounds i8, ptr addrspace(1) %src, i32 16
  store atomic i8 1, ptr addrspace(1) %sbase unordered, align 1
  invoke hotspotcc void @jeandle.arraycopy(
            ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 2,
            ptr null, ptr null, i64 1, i64 1)
         to label %ac unwind label %u
ac:
  %dbase = getelementptr inbounds i8, ptr addrspace(1) %dest, i32 16
  %d1 = getelementptr inbounds i8, ptr addrspace(1) %dbase, i64 1
  %v0 = load atomic i8, ptr addrspace(1) %dbase unordered, align 1
  %v1 = load atomic i8, ptr addrspace(1) %d1 unordered, align 1
  %result = add i8 %v0, %v1
  ret i8 %result
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

attributes #0 = { "jeandle.arraycopy.kind"="arraycopy" "jeandle.arraycopy.validated" }

; CHECK-LABEL: define i8 @test_arraycopy_fold_boolean
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: jeandle.arraycopy
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: %result = add i8 1, 0
; CHECK: ret i8 %result

!java-method-compilation = !{}
