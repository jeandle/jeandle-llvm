; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA Case C — diamond CFG, both arms allocate the same Klass but write
; DIFFERENT constants into the same field. Case C synthesizes a per-entry
; field PHI of i32 at the merge block; the post-merge load reads through the
; PHI; both per-pred allocations are eliminated.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define i32 @test_casec_diff_fields(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %c, label %left, label %right
left:
  %o1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
        to label %lstore unwind label %u
lstore:
  %sl = getelementptr inbounds i8, ptr addrspace(1) %o1, i64 8
  store atomic i32 7, ptr addrspace(1) %sl unordered, align 4
  br label %merge
right:
  %o2 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
        to label %rstore unwind label %u
rstore:
  %sr = getelementptr inbounds i8, ptr addrspace(1) %o2, i64 8
  store atomic i32 13, ptr addrspace(1) %sr unordered, align 4
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

; CHECK-LABEL: define i32 @test_casec_diff_fields
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: = phi i32 [ 7, %{{.*}} ], [ 13, %{{.*}} ]
; CHECK: ret i32

!java-method-compilation = !{}
