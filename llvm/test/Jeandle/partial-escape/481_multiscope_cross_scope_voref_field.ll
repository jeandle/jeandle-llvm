; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Multi-scope descriptors, cross-scope VORef field: TWO virtual objects are
; referenced from DIFFERENT scopes, and one VO's field holds the other VO.
; %a (allocated first, klass 100, size 24) has a T_OBJECT field at offset 8
; holding %b and a T_INT field at offset 16 holding %x; %b (klass 200,
; size 16) has a T_INT field at offset 8 holding %x. %b is referenced ONLY
; by the ROOT scope's locals; %a ONLY by the INNERMOST scope's locals. Both
; descriptors go into the ROOT scope's VO section (after the first
; duplicated-BCI pair); %a's T_OBJECT field becomes a VORef field by wire ID
; in the canonical deopt pool.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(i32)
declare i32 @__gxx_personality_v0(...)

define void @multiscope_xref(i32 %x) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 100 to ptr), i32 24, i1 false)
       to label %n1 unwind label %u
n1:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 200 to ptr), i32 16, i1 false)
       to label %n2 unwind label %u
n2:
  %af1 = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  %af2 = getelementptr inbounds i8, ptr addrspace(1) %a, i64 16
  %bf1 = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic ptr addrspace(1) %b, ptr addrspace(1) %af1 unordered, align 8
  store atomic i32 %x, ptr addrspace(1) %af2 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %bf1 unordered, align 4
  ; Two-scope bundle: ROOT scope (bci 5, preceded by its should_reexecute
  ; i64) local 0 is %b; INNERMOST scope
  ; (bci 9) local 0 is %a. (i64 393233 = MethodType marker pair encoding:
  ; (6<<16)|T_METADATA(17).)
  call void @sink(i32 %x)
       [ "deopt"(i64 0, i32 5, i32 5, i64 12, ptr addrspace(1) %b,
                 i64 393233, i64 777,
                 i64 1, i32 9, i32 9, i64 12, ptr addrspace(1) %a) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Both %a and %b are NeverEscapes: eliminated and described right AFTER THE
; ROOT SCOPE PREFIX (should_reexecute i64 0 + duplicated-BCI pair
; i32 5, i32 5). Canonical pool numbering follows root-slot scan order:
; the root scope's %b is wire ID 0, then the inner scope's %a is wire ID 1.
; Descriptor order follows those wire IDs:
;   %b (wire ID 0): header (0<<32)|(4<<16)|12 = 262156; klass 200;
;     field_count 1; field (offset 8, LocalType/T_INT): (8<<32)|10 =
;     34359738378 -> %x.
;   %a (wire ID 1): header (1<<32)|(4<<16)|12 = 4295229452; klass 100;
;     field_count
;     2; field 0 (offset 8, VORef field, T_OBJECT): (8<<32)|(8<<16)|12 =
;     34360262668 -> i32 wire ID 0 (%b); field 1
;     (offset 16, LocalType/T_INT):
;     (16<<32)|10 = 68719476746 -> %x.
; The ROOT-scope slot (%b) becomes VORefLocalType wire ID 0:
; (0<<32)|(8<<16)|12 = 524300, then i32 0; the INNERMOST slot (%a)
; becomes VORefLocalType wire ID 1:
; (1<<32)|(8<<16)|12 = 4295491596, then i32 1.
; CHECK-LABEL: define void @multiscope_xref(
; CHECK-NOT: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: call void @sink(i32 %x)
; CHECK-SAME: [ "deopt"(i64 0, i32 5, i32 5, i64 262156, i64 200, i32 1, i64 34359738378, i32 %x, i64 4295229452, i64 100, i32 2, i64 34360262668, i32 0, i64 68719476746, i32 %x, i64 524300, i32 0, i64 393233, i64 777, i64 1, i32 9, i32 9, i64 4295491596, i32 1) ]
; CHECK-NOT: poison

!java-method-compilation = !{}
