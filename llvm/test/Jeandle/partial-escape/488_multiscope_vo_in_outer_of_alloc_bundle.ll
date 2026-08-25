; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Multi-scope descriptors, VO in the OUTER scope of ANOTHER ALLOCATION's
; own deopt bundle (multi-scope variant of
; 475_vo_in_other_alloc_bundle.ll). %b is allocated first and referenced
; ONLY by the ROOT scope of the deopt bundle carried by %a's allocation
; invoke. %b is NeverEscapes: described in the ROOT scope's VO section of
; %a's bundle, and the root slot is rewritten to a VORef. %a itself escapes
; at the @sink call below (PartiallyEscapes), so its invoke — and with it
; the rewritten bundle — is RETAINED (if %a were NeverEscapes too, its
; invoke would be eliminated and the bundle would vanish with it).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @multiscope_alloc_bundle(i32 %x) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 200 to ptr), i32 16, i1 false)
       to label %n1 unwind label %u
n1:
  %bf = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic i32 %x, ptr addrspace(1) %bf unordered, align 4
  ; %a's allocation invoke carries a two-scope bundle: ROOT scope (bci 5,
  ; preceded by its should_reexecute i64)
  ; local 0 is %b; the INNERMOST scope (bci 9) has one i32 local.
  ; (i64 393233 = MethodType marker pair encoding: (6<<16)|T_METADATA(17).)
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 100 to ptr), i32 16, i1 false)
       [ "deopt"(i64 0, i32 5, i32 5, i64 12, ptr addrspace(1) %b,
                 i64 393233, i64 777,
                 i64 1, i32 9, i32 9, i64 10, i32 %x) ]
       to label %n2 unwind label %u
n2:
  call void @sink(ptr addrspace(1) %a)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; %b is NeverEscapes (only in %a's bundle): eliminated and described right
; AFTER THE ROOT SCOPE PREFIX (should_reexecute i64 0 + duplicated-BCI pair
; i32 5, i32 5) of %a's bundle: header (vo_id=0,
; ScalarValueType, T_OBJECT): (0<<32)|(4<<16)|12 = 262156; klass 200;
; field_count 1; field (offset 8, LocalType/T_INT): (8<<32)|10 = 34359738378
; -> %x; the ROOT-scope slot becomes VORefLocalType: (0<<32)|(8<<16)|12 =
; 524300, then i32 0. %a is PartiallyEscapes (sink(%a)): its invoke is
; RETAINED with the rewritten bundle.
; CHECK-LABEL: define void @multiscope_alloc_bundle(
; CHECK-NOT: %b = invoke
; CHECK: %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 100 to ptr), i32 16, i1 false)
; CHECK-SAME: [ "deopt"(i64 0, i32 5, i32 5, i64 262156, i64 200, i32 1, i64 34359738378, i32 %x, i64 524300, i32 0, i64 393233, i64 777, i64 1, i32 9, i32 9, i64 10, i32 %x) ]
; CHECK: call void @sink(ptr addrspace(1) %a)
; CHECK-NOT: poison

!java-method-compilation = !{}
