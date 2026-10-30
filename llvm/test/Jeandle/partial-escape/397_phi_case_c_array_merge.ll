; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA Case C — ARRAY merge. Both arms allocate the same-length array of the same
; Klass but store DIFFERENT element byte offsets (left -> 16, right -> 24).
; Array compatibility is gated by the explicit ArrayLength / element-metadata
; checks, and the synthetic VO's Fields is the union of the stored element
; slots. Both loads fold to per-entry PHIs; both array allocations are
; eliminated.
;
; Byte-offset element access (no VM callback log needed: the typed-GEP matcher
; is inert without ArrayElementType, so accesses resolve via constant offsets).

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_casec_array_merge(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %c, label %left, label %right
left:
  %a1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
        to label %lstore unwind label %u
lstore:
  %l = getelementptr inbounds i8, ptr addrspace(1) %a1, i64 16
  store atomic i32 7, ptr addrspace(1) %l unordered, align 4
  br label %merge
right:
  %a2 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
        to label %rstore unwind label %u
rstore:
  %r = getelementptr inbounds i8, ptr addrspace(1) %a2, i64 24
  store atomic i32 13, ptr addrspace(1) %r unordered, align 4
  br label %merge
merge:
  %p   = phi ptr addrspace(1) [ %a1, %lstore ], [ %a2, %rstore ]
  %s16 = getelementptr inbounds i8, ptr addrspace(1) %p, i64 16
  %v16 = load atomic i32, ptr addrspace(1) %s16 unordered, align 4
  %s24 = getelementptr inbounds i8, ptr addrspace(1) %p, i64 24
  %v24 = load atomic i32, ptr addrspace(1) %s24 unordered, align 4
  call void @use(i32 %v16)
  call void @use(i32 %v24)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_casec_array_merge
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK-DAG: phi i32 [ 7, %{{.*}} ], [ 0, %{{.*}} ]
; CHECK-DAG: phi i32 [ 0, %{{.*}} ], [ 13, %{{.*}} ]
; CHECK: ret void

!java-method-compilation = !{}
