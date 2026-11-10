; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/205_array_index_in_constexpr_gep.cblog %s | FileCheck %s

; int[] virtual where the element address is computed by ConstantExpr
; GEPs (i.e. the typed GEP is folded into a constant expression of the
; chained shape). The stripPointerCastsAndOffsets walk + resolveFieldOffset
; together canonicalize the access to a constant byte offset that lands
; on element 1 (= ArrayBaseOffset 16 + 1*4 = 20).

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)

declare i32 @__gxx_personality_v0(...)

define i32 @test_constexpr_gep() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
         to label %n unwind label %u
n:
  ; Synthesize the element-1 address using a ConstantExpr-style GEP folded
  ; into the store/load instructions directly. Each address expression is
  ; `getelementptr i8, %arr, i64 20`, the canonical constant byte-offset
  ; form recognised by resolveFieldOffset and matchArrayElementGEP's
  ; constant fallthrough.
  %elem = getelementptr inbounds i8, ptr addrspace(1) %arr, i64 20
  store atomic i32 7, ptr addrspace(1) %elem unordered, align 4
  %v = load atomic i32, ptr addrspace(1) %elem unordered, align 4
  ret i32 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_constexpr_gep
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: store
; CHECK-NOT: load
; CHECK: ret i32 7

!java-method-compilation = !{}
