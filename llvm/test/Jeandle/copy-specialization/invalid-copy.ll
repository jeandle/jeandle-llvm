; RUN: split-file %s %t
; RUN: not opt -disable-output -passes=copy-specialization %t/call.ll 2>&1 | FileCheck %s --check-prefix=CALL
; RUN: not opt -disable-output -passes=copy-specialization %t/allocation.ll 2>&1 | FileCheck %s --check-prefix=ALLOC
; RUN: sed 's/"copyof"/"copyof-range"/' %t/allocation.ll | not opt -disable-output -passes=copy-specialization 2>&1 | FileCheck %s --check-prefix=ALLOC
; RUN: sed 's/"copyof"/"clone-reference-array"/' %t/allocation.ll | not opt -disable-output -passes=copy-specialization 2>&1 | FileCheck %s --check-prefix=ALLOC
; RUN: sed 's/"copyof"/"arraycopy"/' %t/allocation.ll | not opt -disable-output -passes=copy-specialization 2>&1 | FileCheck %s --check-prefix=ALLOC

; Invalid frontend contracts must produce diagnostics in assertion-enabled and
; release builds, before any scalarization or CFG rewriting.
; CALL: error: copy-specialization requires an invoke for array copies
; CALL-NOT: Assertion
; CALL-NOT: PLEASE submit a bug report
; ALLOC: error: copy-specialization requires a direct jeandle.new_array destination for tightly coupled array copies
; ALLOC-NOT: Assertion
; ALLOC-NOT: PLEASE submit a bug report

;--- call.ll
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)

define void @array_copy_call(ptr addrspace(1) %src, ptr addrspace(1) %dst) #0 {
  call void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 8, ptr null, ptr null, i64 8, i64 8) #1
  ret void
}

attributes #0 = { "java-method"="0" }
attributes #1 = { "jeandle.copy.kind"="arraycopy" }
!java-method-compilation = !{}

;--- allocation.ll
@personality = global ptr null
declare ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)

define ptr addrspace(1) @hidden_allocation(ptr addrspace(1) %src) #0 personality ptr @personality {
  %alloc = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 8, i32 48, i32 16, i32 1000, i1 false, i1 false)
  %dst = freeze ptr addrspace(1) %alloc
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 8, ptr null, ptr null, i64 8, i64 8) #1 [ "deopt"(i32 0) ] to label %normal unwind label %exception
normal:
  ret ptr addrspace(1) %dst
exception:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

attributes #0 = { "java-method"="0" }
attributes #1 = { "jeandle.copy.kind"="copyof" "jeandle.copy.validated" "jeandle.copy.tightly-coupled-allocation" }
!java-method-compilation = !{}
