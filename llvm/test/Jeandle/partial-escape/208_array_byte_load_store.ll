; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/208_array_byte_load_store.cblog %s | FileCheck %s

; byte[] virtual — typed-element GEPs at constant byte indices with
; scale 1, so the element address is `getelementptr i8, %arr_base, idx`.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)

declare i32 @__gxx_personality_v0(...)

define i8 @test_byte_array() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 33333 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
         to label %n unwind label %u
n:
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i32 16
  %p0 = getelementptr inbounds i8, ptr addrspace(1) %base, i64 0
  %p2 = getelementptr inbounds i8, ptr addrspace(1) %base, i64 2
  store atomic i8 42, ptr addrspace(1) %p0 unordered, align 1
  store atomic i8 99, ptr addrspace(1) %p2 unordered, align 1
  %v = load atomic i8, ptr addrspace(1) %p2 unordered, align 1
  ret i8 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i8 @test_byte_array
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: store
; CHECK-NOT: load
; CHECK: ret i8 99

!java-method-compilation = !{}
