; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s --check-prefix=PEA
; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform,instcombine" %s | FileCheck %s --check-prefix=CLEAN

; Reference FieldValues are semantic addrspace(1) oops. FieldDesc retains the
; physical representation: addrspace(3), four bytes. PEA creates only
; addrspacecast at storage boundaries; ExpandNarrowOopCast owns lowering.

target datalayout = "e-p:64:64-p1:64:64-p3:32:32"

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.safepoint_poll()
declare void @sink(ptr addrspace(1))
declare void @sink_narrow(ptr addrspace(3))
declare i32 @__gxx_personality_v0(...)

; Materialization must convert the semantic oop back to compressed storage and
; replay a four-byte, align-4 store.
define void @materialize_narrow_reference(ptr addrspace(1) %ref)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
          ptr inttoptr (i64 12345 to ptr), i32 24, i1 false)
       to label %normal unwind label %unwind
normal:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  %narrow = addrspacecast ptr addrspace(1) %ref to ptr addrspace(3)
  store atomic ptr addrspace(3) %narrow, ptr addrspace(1) %slot unordered, align 4
  call void @sink(ptr addrspace(1) %o)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; A deopt-only object mirrors the gauss-mix lambda more closely: its three
; compressed captures must be encoded in the lazy-object record as semantic
; AS1 oops. Keeping the AS3 storage values here would make them non-relocatable
; across the safepoint.
define void @deopt_narrow_references(
    ptr addrspace(1) %ref0, ptr addrspace(1) %ref1,
    ptr addrspace(1) %ref2)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
          ptr inttoptr (i64 75001 to ptr), i32 24, i1 false)
       to label %normal unwind label %unwind
normal:
  %slot0 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 12
  %narrow0 = addrspacecast ptr addrspace(1) %ref0 to ptr addrspace(3)
  store atomic ptr addrspace(3) %narrow0, ptr addrspace(1) %slot0 unordered, align 4
  %slot1 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  %narrow1 = addrspacecast ptr addrspace(1) %ref1 to ptr addrspace(3)
  store atomic ptr addrspace(3) %narrow1, ptr addrspace(1) %slot1 unordered, align 4
  %slot2 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 20
  %narrow2 = addrspacecast ptr addrspace(1) %ref2 to ptr addrspace(3)
  store atomic ptr addrspace(3) %narrow2, ptr addrspace(1) %slot2 unordered, align 4
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(i32 0, i32 0, i64 12, ptr addrspace(1) %o) ]
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Branch field merging happens in semantic AS1. The narrow load boundary may
; temporarily recreate AS1 -> AS3, but ordinary InstCombine removes that cast
; together with the source-level AS3 -> AS1 decode.
define ptr addrspace(1) @merge_narrow_reference(
    i1 %cond, ptr addrspace(1) %left.ref, ptr addrspace(1) %right.ref)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
          ptr inttoptr (i64 67890 to ptr), i32 24, i1 false)
       to label %normal unwind label %unwind
normal:
  br i1 %cond, label %left, label %right
left:
  %left.slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  %left.narrow = addrspacecast ptr addrspace(1) %left.ref to ptr addrspace(3)
  store atomic ptr addrspace(3) %left.narrow, ptr addrspace(1) %left.slot unordered, align 4
  br label %merge
right:
  %right.slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  %right.narrow = addrspacecast ptr addrspace(1) %right.ref to ptr addrspace(3)
  store atomic ptr addrspace(3) %right.narrow, ptr addrspace(1) %right.slot unordered, align 4
  br label %merge
merge:
  %load.slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  %loaded = load atomic ptr addrspace(3), ptr addrspace(1) %load.slot unordered, align 4
  %wide = addrspacecast ptr addrspace(3) %loaded to ptr addrspace(1)
  ret ptr addrspace(1) %wide
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; A compressed representation that escapes directly through an opaque call
; must keep its source allocation real. The AS1 -> AS3 conversion is still a
; virtual-object alias, so the call remains visible to PEA's escape handling.
define void @escape_narrow_reference()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
          ptr inttoptr (i64 76001 to ptr), i32 16, i1 false)
       to label %normal unwind label %unwind
normal:
  %narrow = addrspacecast ptr addrspace(1) %o to ptr addrspace(3)
  call void @sink_narrow(ptr addrspace(3) %narrow)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; PEA-LABEL: define void @materialize_narrow_reference
; PEA: %[[STORED:pea\.encode\.oop.*]] = addrspacecast ptr addrspace(1) %ref to ptr addrspace(3)
; PEA: store atomic ptr addrspace(3) %[[STORED]], ptr addrspace(1) %pea.matslot unordered, align 4
; PEA: call void @sink(ptr addrspace(1) %o)

; PEA-LABEL: define void @deopt_narrow_references
; PEA-NOT: jeandle.new_instance
; PEA-NOT: addrspacecast
; PEA-NOT: store atomic
; PEA: call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 0, i32 0,
; PEA-SAME: i64 {{[0-9]+}}, i64 75001, i32 3,
; PEA-SAME: i64 51539607564, ptr addrspace(1) %ref0,
; PEA-SAME: i64 68719476748, ptr addrspace(1) %ref1,
; PEA-SAME: i64 85899345932, ptr addrspace(1) %ref2,

; PEA-LABEL: define ptr addrspace(1) @merge_narrow_reference
; PEA-NOT: jeandle.new_instance
; PEA: %[[PHI:pea\.field\.phi.*]] = phi ptr addrspace(1)
; PEA: addrspacecast ptr addrspace(1) %[[PHI]] to ptr addrspace(3)
; PEA-NOT: store atomic

; PEA-LABEL: define void @escape_narrow_reference
; PEA: %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; PEA: %narrow = addrspacecast ptr addrspace(1) %o to ptr addrspace(3)
; PEA: call void @sink_narrow(ptr addrspace(3) %narrow)

; CLEAN-LABEL: define void @deopt_narrow_references
; CLEAN-NOT: jeandle.new_instance
; CLEAN-NOT: addrspacecast
; CLEAN-NOT: store atomic
; CLEAN: call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 0, i32 0,
; CLEAN-SAME: i64 {{[0-9]+}}, i64 75001, i32 3,
; CLEAN-SAME: i64 51539607564, ptr addrspace(1) %ref0,
; CLEAN-SAME: i64 68719476748, ptr addrspace(1) %ref1,
; CLEAN-SAME: i64 85899345932, ptr addrspace(1) %ref2,

; CLEAN-LABEL: define ptr addrspace(1) @merge_narrow_reference
; CLEAN-NOT: jeandle.new_instance
; CLEAN: %[[PHI:pea\.field\.phi.*]] = phi ptr addrspace(1)
; CLEAN-NOT: addrspacecast
; CLEAN: ret ptr addrspace(1) %[[PHI]]

; CLEAN-LABEL: define void @escape_narrow_reference
; CLEAN: %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CLEAN: %narrow = addrspacecast ptr addrspace(1) %o to ptr addrspace(3)
; CLEAN: call void @sink_narrow(ptr addrspace(3) %narrow)

!java-method-compilation = !{}
