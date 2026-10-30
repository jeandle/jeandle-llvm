; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/206_array_int_load_store.cblog %s | FileCheck %s

; int[] virtual — typed-element GEPs at constant indices, store + load.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)

declare i32 @__gxx_personality_v0(...)

define i32 @test_int_array() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
         to label %n unwind label %u
n:
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i32 16
  %p1 = getelementptr inbounds i32, ptr addrspace(1) %base, i64 1
  %p3 = getelementptr inbounds i32, ptr addrspace(1) %base, i64 3
  store atomic i32 100, ptr addrspace(1) %p1 unordered, align 4
  store atomic i32 400, ptr addrspace(1) %p3 unordered, align 4
  %v1 = load atomic i32, ptr addrspace(1) %p1 unordered, align 4
  %v3 = load atomic i32, ptr addrspace(1) %p3 unordered, align 4
  %r = add i32 %v1, %v3
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_int_array
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: store
; CHECK-NOT: load
; CHECK: %r = add i32 100, 400
; CHECK: ret i32 %r

!java-method-compilation = !{}
