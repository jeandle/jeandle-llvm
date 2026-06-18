; RUN: opt -S -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/field-phi-nested-opaque.cblog %s 2>&1 | FileCheck %s

; Regression test for the dataflow soundness bug (A1).
;
; %outer joins a ConstOop source with %inner, which is itself a PHI of two
; opaque loads. The previous algorithm seeded forwarders to Top but never
; evaluated %inner (no source pushed it), so %inner stayed at Top and
; the meet at %outer became Const{0} (Top is the meet identity). After the
; fix, opaque oop-typed producers are seeded Bottom and pushed, so %inner
; settles at Bottom and %outer at Bottom — load is NOT folded.

@oop_handle_Test_0 = external global ptr addrspace(1)
@runtime_oop_a = external global ptr addrspace(1)
@runtime_oop_b = external global ptr addrspace(1)

define i32 @test(i1 %c, i1 %c2) gc "hotspotgc" {
entry:
  %src = load ptr addrspace(1), ptr @oop_handle_Test_0
  %opaque1 = load ptr addrspace(1), ptr @runtime_oop_a
  %opaque2 = load ptr addrspace(1), ptr @runtime_oop_b
  br i1 %c, label %A, label %B
A:
  br label %inner_merge
B:
  br label %inner_merge
inner_merge:
  %inner = phi ptr addrspace(1) [ %opaque1, %A ], [ %opaque2, %B ]
  br i1 %c2, label %T, label %F
T:
  br label %outer_merge
F:
  br label %outer_merge
outer_merge:
  %outer = phi ptr addrspace(1) [ %src, %T ], [ %inner, %F ]
  %addr = getelementptr i8, ptr addrspace(1) %outer, i64 12
  %value = load i32, ptr addrspace(1) %addr
  ret i32 %value
}

; CHECK: %value = load i32, ptr addrspace(1) %addr
; CHECK: ret i32 %value

!java-method-compilation = !{}
