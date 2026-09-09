; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; The byte offset of a field access through pointer-identity-preserving wrappers
; is preserved by the shared offset resolver (resolveFieldOffset ->
; stripPointerCastsAndOffsets). Two wrappers are exercised:
;
;   * llvm.launder.invariant.group — allowlisted by processIntrinsic (does NOT
;     materialize), so a launder-wrapped GEP access folds with the correct
;     offset (offset-16 field), and the object is eliminated.
;
;   * inttoptr(ptrtoint(...)) round-trip — peeled by stripPointerCastsAndOffsets
;     so identity- and offset-resolution agree. A ptrtoint of a virtual-derived
;     pointer is itself an escape (marked hasVirtualInputs -> materializes), so
;     the object is conservatively kept real.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare ptr addrspace(1) @llvm.launder.invariant.group.p1.p1(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define i32 @test_launder_offset_preserved() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 11111 to ptr), i32 32, i1 false)
       to label %n unwind label %u
n:
  %g16 = getelementptr i8, ptr addrspace(1) %obj, i64 16
  %lw = call ptr addrspace(1) @llvm.launder.invariant.group.p1.p1(
                    ptr addrspace(1) %g16)
  store i32 111, ptr addrspace(1) %lw
  %r = load i32, ptr addrspace(1) %g16
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The launder-wrapped offset-16 access folds; the object is eliminated and the
; load folds to the stored 111.
; CHECK-LABEL: define i32 @test_launder_offset_preserved
; CHECK-NOT: jeandle.new_instance
; CHECK: ret i32 111

define void @test_inttoptr_roundtrip_materializes() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 22222 to ptr), i32 32, i1 false)
       to label %n unwind label %u
n:
  %g16 = getelementptr i8, ptr addrspace(1) %obj, i64 16
  %pi = ptrtoint ptr addrspace(1) %g16 to i64
  %p16 = inttoptr i64 %pi to ptr addrspace(1)
  store i32 111, ptr addrspace(1) %p16
  call void @sink(ptr addrspace(1) %obj)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

declare void @sink(ptr addrspace(1))

; The ptrtoint of the virtual-derived pointer escapes, so the object
; materializes (conservative, sound).
; CHECK-LABEL: define void @test_inttoptr_roundtrip_materializes
; CHECK: jeandle.new_instance

!java-method-compilation = !{}
