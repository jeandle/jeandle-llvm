; RUN: opt -disable-output -passes="partial-escape-iterative" \
; RUN:   -jeandle-pea-iterations=5 \
; RUN:   -jeandle-dump-pea-ir-function=naked_as3_nonvirtual_store \
; RUN:   %s 2>&1 | FileCheck %s --check-prefix=CONVERGENCE
; RUN: opt -S -passes="partial-escape-iterative" \
; RUN:   -jeandle-pea-iterations=5 %s \
; RUN:   | FileCheck %s --check-prefix=IR
; RUN: opt -disable-output -passes="partial-escape-iterative" \
; RUN:   -jeandle-pea-iterations=1 -jeandle-trace-pea %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=EFFECT

; A naked AS3 value stored through a non-virtual base is outside PEA's
; foldable-memory model. Analysis must reject the pointer side before creating
; an analysis-owned AS3 -> AS1 semantic cast. Otherwise transform places the
; unused cast, ADCE removes it, and every outer round repeats that churn.

target datalayout = "e-p:64:64-p1:64:64-p3:32:32"

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define void @naked_as3_nonvirtual_store(
    ptr addrspace(1) %src, ptr addrspace(1) %dst) gc "hotspotgc" {
entry:
  %v = load atomic ptr addrspace(3), ptr addrspace(1) %src
      unordered, align 4
  store atomic ptr addrspace(3) %v, ptr addrspace(1) %dst
      unordered, align 4
  ret void
}

; A naked AS3 load folded from one virtual object's reference field is itself
; a whole-object virtual alias. Storing it into another virtual object records
; only the referenced ObjectID and semantic AS1 type. The one PlaceInstruction
; below belongs to the folded load's AS1 -> AS3 replacement; there must be no
; second PlaceInstruction for a dead AS3 -> AS1 semantic cast at the store.
define void @naked_as3_virtual_ref_store()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %inner = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 76401 to ptr), i32 16, i1 false)
      to label %alloc.source unwind label %unwind

alloc.source:
  %source = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 76402 to ptr), i32 24, i1 false)
      to label %alloc.dest unwind label %unwind

alloc.dest:
  %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 76403 to ptr), i32 24, i1 false)
      to label %normal unwind label %unwind

normal:
  %source.slot = getelementptr inbounds i8, ptr addrspace(1) %source, i64 16
  %inner.narrow = addrspacecast ptr addrspace(1) %inner to ptr addrspace(3)
  store atomic ptr addrspace(3) %inner.narrow,
      ptr addrspace(1) %source.slot unordered, align 4
  %loaded = load atomic ptr addrspace(3),
      ptr addrspace(1) %source.slot unordered, align 4
  %dest.slot = getelementptr inbounds i8, ptr addrspace(1) %dest, i64 16
  store atomic ptr addrspace(3) %loaded,
      ptr addrspace(1) %dest.slot unordered, align 4
  ret void

unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CONVERGENCE: ;; PEA-DUMP after iter=0 function naked_as3_nonvirtual_store transform_idle=1
; CONVERGENCE-NOT: ;; PEA-DUMP after iter=1
; CONVERGENCE: ;; PEA-SUMMARY function naked_as3_nonvirtual_store rounds=1 stop=fixpoint

; IR-LABEL: define void @naked_as3_nonvirtual_store(
; IR-NOT: pea.semantic.oop
; IR: %v = load atomic ptr addrspace(3)
; IR: store atomic ptr addrspace(3) %v
; IR-NOT: pea.semantic.oop
; IR: ret void

; EFFECT-NOT: PEA: PlaceInstruction function=@naked_as3_nonvirtual_store
; EFFECT: PEA: PlaceInstruction function=@naked_as3_virtual_ref_store{{.*}}%loaded = load atomic ptr addrspace(3)
; EFFECT-NOT: PEA: PlaceInstruction function=@naked_as3_virtual_ref_store

!java-method-compilation = !{}
