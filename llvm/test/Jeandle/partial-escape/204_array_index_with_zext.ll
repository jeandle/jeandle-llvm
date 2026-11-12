; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/204_array_index_with_zext.cblog %s | FileCheck %s

; int[] virtual where the typed-GEP index is `zext i32 to i64` of a
; ConstantInt. peelIndexWrappers strips the zext, so the underlying
; ConstantInt is recovered as the canonical element index.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)

declare i32 @__gxx_personality_v0(...)

define i32 @test_zext_index() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
         to label %n unwind label %u
n:
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i32 16
  %idx32 = bitcast i32 1 to i32      ; bitcast keeps the constant intact as a non-ConstantInt user
  %idx64 = zext i32 %idx32 to i64
  %elem = getelementptr inbounds i32, ptr addrspace(1) %base, i64 %idx64
  store atomic i32 42, ptr addrspace(1) %elem unordered, align 4
  %v = load atomic i32, ptr addrspace(1) %elem unordered, align 4
  ret i32 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_zext_index
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: store
; CHECK-NOT: load
; CHECK: ret i32 42

!java-method-compilation = !{}
