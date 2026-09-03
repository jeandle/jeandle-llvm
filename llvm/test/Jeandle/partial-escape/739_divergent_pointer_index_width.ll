; RUN: opt -passes=verify -disable-output %s
; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s

; Pointer representation and GEP index widths may differ.  Address-space 1
; uses 128-bit pointers but 64-bit GEP indices here.  The i128 index is
; therefore truncated to 64 bits before address calculation: 2^64 + 8 denotes
; byte offset 8.  PEA must use the DataLayout index width both when asking LLVM
; to accumulate the GEP and when recovering an array-style byte index.

target datalayout = "e-p:64:64-p1:128:128:128:64-p3:128:128:128:64"

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define i32 @divergent_pointer_index_width() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 73901 to ptr), i32 16, i1 false)
      to label %body unwind label %unwind
body:
  %field = getelementptr i8, ptr addrspace(1) %obj,
      i128 18446744073709551624
  store atomic i32 42, ptr addrspace(1) %field unordered, align 4
  %value = load atomic i32, ptr addrspace(1) %field unordered, align 4
  ret i32 %value
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @divergent_pointer_index_width(
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: getelementptr
; CHECK-NOT: store
; CHECK-NOT: load
; CHECK: ret i32 42

!java-method-compilation = !{}
