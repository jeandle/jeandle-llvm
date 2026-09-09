; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s

; A two-entry irreducible cycle (%irr.a <-> %irr.b) whose only outside entry
; edges are both PEA-proven dead (null checks on the still-virtual %o fold).
; Each cycle block defers at the entry gate (one dead entry + the other cycle
; block still Unseen), so no block in the region ever publishes an exit, and
; the outer merge would silently skip the %irr.b predecessor when building
; %o's field PHI. The end-of-walk publication net rejects the whole analysis
; attempt instead of letting malformed PHIs reach CFG cleanup.
;
; The folded edges reach the cycle through the intermediate %deadside blocks:
; those publish dead exits with no virtual objects, so the
; unvisited-predecessor VO bail that fires at the cycle blocks finds nothing
; to bail and the merge still synthesizes %o's field PHI (missing the %irr.b
; incoming pre-fix).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define i32 @stranded_irreducible_bails(i1 %choose, i1 %k)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 75601 to ptr), i32 24, i1 false)
      to label %guard unwind label %alloc.unwind

guard:
  %is.null = icmp eq ptr addrspace(1) %o, null
  br i1 %is.null, label %deadside, label %dispatch

deadside:
  br label %irr.a

dispatch:
  %not.null = icmp ne ptr addrspace(1) %o, null
  br i1 %not.null, label %live.dispatch, label %deadside2

deadside2:
  br label %irr.b

irr.a:
  br label %irr.b

irr.b:
  br i1 %k, label %irr.a, label %merge

live.dispatch:
  br i1 %choose, label %left, label %right

left:
  %left.field = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i32 61, ptr addrspace(1) %left.field unordered, align 4
  br label %merge

right:
  %right.field = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i32 62, ptr addrspace(1) %right.field unordered, align 4
  br label %merge

merge:
  %reload = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  %value = load atomic i32, ptr addrspace(1) %reload unordered, align 4
  ret i32 %value

alloc.unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; The net bails the whole analysis attempt: the transform is a no-op, the
; allocation survives, the stranded blocks are not cleaned up, and no field
; PHI is synthesized.
; CHECK-LABEL: define i32 @stranded_irreducible_bails(
; CHECK: %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: irr.a:
; CHECK: irr.b:
; CHECK: merge:
; CHECK-NOT: pea.field.phi
; CHECK: ret i32
; CHECK-NOT: poison

!java-method-compilation = !{}
