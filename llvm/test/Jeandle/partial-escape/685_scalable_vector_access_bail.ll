; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -verify-each %s | FileCheck %s

; Scalable vectors have a runtime-dependent store size. They are legal LLVM
; memory operands but cannot be represented by PEA's fixed-width field model,
; so the access must materialize the receiver and remain in the IR.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define void @scalable_vector_store(<vscale x 4 x i32> %value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 68501 to ptr), i32 64, i1 false)
       to label %normal unwind label %unwind
normal:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store <vscale x 4 x i32> %value, ptr addrspace(1) %slot, align 16
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @scalable_vector_store(
; CHECK: %[[O:[A-Za-z0-9._]+]] = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
; CHECK: %[[SLOT:[A-Za-z0-9._]+]] = getelementptr inbounds i8, ptr addrspace(1) %[[O]], i64 16
; CHECK: store <vscale x 4 x i32> %value, ptr addrspace(1) %[[SLOT]], align 16
; CHECK: ret void

define <vscale x 4 x i32> @scalable_vector_load()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 68502 to ptr), i32 64, i1 false)
       to label %normal unwind label %unwind
normal:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  %value = load <vscale x 4 x i32>, ptr addrspace(1) %slot, align 16
  ret <vscale x 4 x i32> %value
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define <vscale x 4 x i32> @scalable_vector_load(
; CHECK: %[[O:[A-Za-z0-9._]+]] = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
; CHECK: %[[SLOT:[A-Za-z0-9._]+]] = getelementptr inbounds i8, ptr addrspace(1) %[[O]], i64 16
; CHECK: %[[VALUE:[A-Za-z0-9._]+]] = load <vscale x 4 x i32>, ptr addrspace(1) %[[SLOT]], align 16
; CHECK: ret <vscale x 4 x i32> %[[VALUE]]

!java-method-compilation = !{}
