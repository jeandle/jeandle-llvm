; The two arms are both reachable, so Transform cannot justify deleting either
; edge. Each arm creates a same-shaped virtual object; the pointer PHI at
; %join is collapsed by Case C into one synthetic VO. The synthetic VO keeps
; the first arm's AllocationCall (%a) as its structural allocation field,
; while its real identity is the PHI itself.
;
; The synthetic VO is stored in a field of another virtual object and loaded
; back. Its real identity is the merge PHI %inner, while %a is only a
; borrowed structural AllocationCall from the first Case-C predecessor.
; Reusing %a would produce a non-dominating use at %join. The two CFG edges
; remain reachable so the final Transform verifier validates the result.
; This regression is independent of CompressedOops and address space 3; those
; only made the same missing identity/availability check visible in the original
; TestStringIntrinsics failure.
;
; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use_ptr(ptr addrspace(1))

define void @casec_nested_identity_min(i1 %cond) gc "hotspotgc" {
entry:
  %outer = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 84001 to ptr), i32 24, i1 false)
  br i1 %cond, label %then, label %else
then:
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 84002 to ptr), i32 16, i1 false)
  br label %join
else:
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 84002 to ptr), i32 16, i1 false)
  br label %join
join:
  %inner = phi ptr addrspace(1) [ %a, %then ], [ %b, %else ]
  %slot = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  store ptr addrspace(1) %inner, ptr addrspace(1) %slot, align 8
  %loaded = load ptr addrspace(1), ptr addrspace(1) %slot, align 8
  call void @use_ptr(ptr addrspace(1) %loaded)
  ret void
}

; CHECK-LABEL: define void @casec_nested_identity_min
; CHECK-NOT: %outer = call hotspotcc
; CHECK: %inner = phi ptr addrspace(1) [ %a, %then ], [ %b, %else ]
; CHECK-NOT: %loaded
; CHECK: call void @use_ptr(ptr addrspace(1) %inner)
; CHECK-NOT: call void @use_ptr(ptr addrspace(1) %a)

!java-method-compilation = !{}
