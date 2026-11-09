; RUN: opt -S -passes='string-intrinsic-specialization,require<partial-escape-analysis>,partial-escape-transform,instsimplify,repeated-constant-field-folding,string-intrinsic-specialization,repeated-constant-field-folding' -jeandle-vm-callback-log=%S/Inputs/post-pea-constants.cblog -verify-each %s | FileCheck %s
; RUN: opt -S --jeandle --print-pipeline-passes %S/pipeline.ll 2>&1 | FileCheck %s --check-prefix=ORDER
; ORDER: partial-escape-iterative
; ORDER: repeated-constant-field-folding
; ORDER: string-intrinsic-specialization
; ORDER: repeated-constant-field-folding
; ORDER: copy-specialization

target datalayout = "e-p:64:64-p1:64:64"
@arrayOopDesc.base_offset_in_bytes.byte = constant i32 16
@arrayOopDesc.length_offset_in_bytes = constant i32 12
@oop_handle_Stable_0 = external global ptr addrspace(1)
@oop_handle_Stable_1 = external global ptr addrspace(1)
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)
declare i32 @jeandle.arraylength(ptr addrspace(1))
declare i32 @jeandle.string_compare(ptr addrspace(1), i32, ptr addrspace(1), i32, i32)

; PEA exposes a stable array reference from a virtual holder. Only subsequent
; VM-authorized length folding can expose the bounded String comparison.
; CHECK-LABEL: @holder_length(
; CHECK-NOT: new_instance
; CHECK-NOT: call
; CHECK-NOT: load atomic
; CHECK: ret i32 -1
define i32 @holder_length() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = load ptr addrspace(1), ptr @oop_handle_Stable_0
  %b = load ptr addrspace(1), ptr @oop_handle_Stable_1
  %holder = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 100 to ptr), i32 24, i1 false) to label %work unwind label %unwind
work:
  %field = getelementptr i8, ptr addrspace(1) %holder, i64 16
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %field unordered, align 8
  %loaded = load atomic ptr addrspace(1), ptr addrspace(1) %field unordered, align 8
  %na = call i32 @jeandle.arraylength(ptr addrspace(1) %loaded)
  %nb = call i32 @jeandle.arraylength(ptr addrspace(1) %b)
  %r = call i32 @jeandle.string_compare(ptr addrspace(1) %loaded, i32 %na, ptr addrspace(1) %b, i32 %nb, i32 0)
  ret i32 %r
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
!java-method-compilation = !{}
