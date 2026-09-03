; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA Case C — diamond CFG, both arms allocate the same Klass and write the
; same constant into the same field. The merge PHI carries two DIFFERENT
; virtual ObjectIDs. Round 1's Case C synthesizes a fresh merged VO; both
; per-pred allocations are eliminated; the per-entry field PHI collapses to
; the common constant; the post-merge load folds to that constant.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define i32 @test_casec_same_fields(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %c, label %left, label %right
left:
  %o1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
        to label %lstore unwind label %u
lstore:
  %sl = getelementptr inbounds i8, ptr addrspace(1) %o1, i64 8
  store atomic i32 42, ptr addrspace(1) %sl unordered, align 4
  br label %merge
right:
  %o2 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
        to label %rstore unwind label %u
rstore:
  %sr = getelementptr inbounds i8, ptr addrspace(1) %o2, i64 8
  store atomic i32 42, ptr addrspace(1) %sr unordered, align 4
  br label %merge
merge:
  %p  = phi ptr addrspace(1) [ %o1, %lstore ], [ %o2, %rstore ]
  %sm = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
  %v  = load atomic i32, ptr addrspace(1) %sm unordered, align 4
  ret i32 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_casec_same_fields
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: ret i32 42

!java-method-compilation = !{}
