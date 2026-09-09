; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; freeze / offset-0-select bundle operands: both are object
; IDENTITY for the VO (freeze is peeled by resolveFieldOffset; a select with
; both arms at offset 0 of the same VO is alias-forwarded by
; propagatePointerAlias). They are describable and their slots are rewritten
; via exact pool occurrences. Companion of 472 (Case-B PHI) and 473 (derived GEP
; banned).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(i32)
declare i32 @__gxx_personality_v0(...)

define void @freeze_in_bundle(i32 %x) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 100 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %of = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %x, ptr addrspace(1) %of unordered, align 4
  %fr = freeze ptr addrspace(1) %o
  call void @sink(i32 %x)
       [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %fr) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define void @select0_in_bundle(i32 %x, i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 200 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %of = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %x, ptr addrspace(1) %of unordered, align 4
  %sel = select i1 %c, ptr addrspace(1) %o, ptr addrspace(1) %o
  call void @sink(i32 %x)
       [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %sel) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define void @poison_refined_in_bundle(i32 %x, i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 300 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %of = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %x, ptr addrspace(1) %of unordered, align 4
  %sel = select i1 %c, ptr addrspace(1) %o, ptr addrspace(1) poison
  %fr = freeze ptr addrspace(1) %sel
  call void @sink(i32 %x)
       [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %fr) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Both VOs NeverEscapes and described (same wire layout as 472):
; descriptor 262156 + klass + field (34359738378 -> %x), slot -> 524300, 0.
; CHECK-LABEL: define void @freeze_in_bundle(
; CHECK-NOT: jeandle.new_instance
; CHECK: call void @sink(i32 %x)
; CHECK-SAME: [ "deopt"(i32 99, i32 99, i64 262156, i64 100, i32 1, i64 34359738378, i32 %x, i64 524300, i32 0) ]
; CHECK-NOT: poison
; CHECK-LABEL: define void @select0_in_bundle(
; CHECK-NOT: jeandle.new_instance
; CHECK: call void @sink(i32 %x)
; CHECK-SAME: [ "deopt"(i32 99, i32 99, i64 262156, i64 200, i32 1, i64 34359738378, i32 %x, i64 524300, i32 0) ]
; CHECK-NOT: poison
; CHECK-LABEL: define void @poison_refined_in_bundle(
; CHECK-NOT: jeandle.new_instance
; CHECK: call void @sink(i32 %x)
; CHECK-SAME: [ "deopt"(i32 99, i32 99, i64 262156, i64 300, i32 1, i64 34359738378, i32 %x, i64 524300, i32 0) ]
; CHECK-NOT: poison

!java-method-compilation = !{}
