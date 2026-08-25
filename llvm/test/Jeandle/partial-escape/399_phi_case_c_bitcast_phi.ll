; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
; RUN: opt -disable-output -passes="require<partial-escape-analysis>" %s

; PEA Case C — a same-bit-width reinterpret (bitcast) of a merged field PHI.
; Both arms allocate the same Klass and store a full-width i32 at offset 8
; (different constants); the merge synthesizes a per-entry `phi i32`. The
; post-merge load reads the slot back as `float` at the SAME offset — a
; whole-slot reinterpret, which IS still supported (branch ② of coerceToType),
; unlike sub-slot / narrowing loads.
;
; This produces a coercion chain `bitcast i32 %field_phi to float` whose operand
; is the (initially unparented) Case-C field PHI. It is the regression guard for
; the transform's ReplaceLoad postorder splice treating a PHINode operand as a
; leaf (!isa<PHINode>): the bitcast is spliced before the load while the PHI is
; parented at the merge-block head by its own CreatePHI effect — no double-insert
; crash, no SSA violation.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(float)
declare i32 @__gxx_personality_v0(...)

define void @test_casec_bitcast_phi(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %c, label %left, label %right
left:
  %o1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
        to label %lstore unwind label %u
lstore:
  %l8 = getelementptr inbounds i8, ptr addrspace(1) %o1, i64 8
  store atomic i32 1078530011, ptr addrspace(1) %l8 unordered, align 4
  br label %merge
right:
  %o2 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
        to label %rstore unwind label %u
rstore:
  %r8 = getelementptr inbounds i8, ptr addrspace(1) %o2, i64 8
  store atomic i32 1082130432, ptr addrspace(1) %r8 unordered, align 4
  br label %merge
merge:
  %p  = phi ptr addrspace(1) [ %o1, %lstore ], [ %o2, %rstore ]
  %s8 = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
  %v  = load atomic float, ptr addrspace(1) %s8 unordered, align 4
  call void @use(float %v)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_casec_bitcast_phi
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: %[[PHI:.*]] = phi i32 [ 1078530011, %{{.*}} ], [ 1082130432, %{{.*}} ]
; CHECK: %[[BC:.*]] = bitcast i32 %[[PHI]] to float
; CHECK: call void @use(float %[[BC]])
; CHECK: ret void

!java-method-compilation = !{}
