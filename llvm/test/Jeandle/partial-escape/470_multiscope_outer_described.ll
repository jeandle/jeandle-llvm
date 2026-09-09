; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Multi-scope descriptors: a VO referenced ONLY by an OUTER scope (here: the
; root scope's locals slot) is described like any inner-scope reference. The
; descriptor is emitted into the ROOT scope's VO section (right after the
; FIRST duplicated-BCI pair — the deopt-point-level object pool) and the
; outer-scope slot is rewritten to a VORef by vo-id.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(i32)
declare i32 @__gxx_personality_v0(...)

define void @multiscope(i32 %x) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 100 to ptr), i32 16, i1 false)
       to label %n1 unwind label %u
n1:
  %of = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %x, ptr addrspace(1) %of unordered, align 4
  ; Two-scope bundle: ROOT scope (bci 5, preceded by its should_reexecute
  ; i64) references %o in its locals;
  ; the innermost (current) scope (bci 9) does NOT. (i64 393233 is the
  ; MethodType marker pair encoding: (6<<16)|T_METADATA(17).)
  ; Layout per scope: [method], should_reexecute(i64), bci, bci, locals, stack, monitors, [orig_pc]
  call void @sink(i32 %x)
       [ "deopt"(i64 0, i32 5, i32 5, i64 12, ptr addrspace(1) %o,
                 i64 393233, i64 777,
                 i64 1, i32 9, i32 9, i64 10, i32 %x) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; %o is NeverEscapes (only in the bundle): eliminated and described. The
; descriptor lands right AFTER THE ROOT SCOPE PREFIX (should_reexecute i64 0
; + duplicated-BCI pair i32 5, i32 5): header
; (vo_id=0, ScalarValueType, T_OBJECT): (0<<32)|(4<<16)|12 = 262156; klass
; 100; field_count 1; field (offset 8, LocalType/T_INT): (8<<32)|10 =
; 34359738378 -> %x. The ROOT-scope locals slot becomes a VORefLocalType:
; (0<<32)|(8<<16)|12 = 524300, then i32 0.
; CHECK-LABEL: define void @multiscope(
; CHECK-NOT: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: call void @sink(i32 %x)
; CHECK-SAME: [ "deopt"(i64 0, i32 5, i32 5, i64 262156, i64 100, i32 1, i64 34359738378, i32 %x, i64 524300, i32 0,
; CHECK-SAME: i64 393233, i64 777,
; CHECK-SAME: i64 1, i32 9, i32 9, i64 10, i32 %x) ]
; CHECK-NOT: poison

!java-method-compilation = !{}
