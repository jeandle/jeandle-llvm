; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/202_array_symbolic_index_bails.cblog %s | FileCheck %s

; int[] virtual access via the typed-element GEP chain with a SYMBOLIC
; (non-constant) index. matchArrayElementGEP recognises the shape, the
; caller observes the non-ConstantInt index and forces the array to
; materialize. The newarray, the store, and the load all survive in IR.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @sink(i32)

declare i32 @__gxx_personality_v0(...)

define void @test_typed_gep_symbolic(i64 %idx) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
         to label %n unwind label %u
n:
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i32 16
  %elem = getelementptr inbounds i32, ptr addrspace(1) %base, i64 %idx
  store atomic i32 99, ptr addrspace(1) %elem unordered, align 4
  %v = load atomic i32, ptr addrspace(1) %elem unordered, align 4
  call void @sink(i32 %v)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_typed_gep_symbolic
; CHECK: jeandle.new_array
; CHECK: store atomic i32 99
; CHECK: load atomic i32

!java-method-compilation = !{}
