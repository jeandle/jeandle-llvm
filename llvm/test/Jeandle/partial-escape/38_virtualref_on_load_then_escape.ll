; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; VirtualRef-on-load + nested-virtual materialization: the load result
; from a VirtualRef field is passed to an opaque sink. The alias install
; makes the load result resolve to the inner ObjectID, so the sink call
; escapes the *inner* virtual (not the outer). The inner's OrigAlloc must be
; retained; the outer
; stays virtual end-to-end (no live use of the outer pointer except its
; field, which is folded). After PEA we expect exactly the original inner
; array invoke (klass 12345) and the sink to receive that OrigAlloc. The outer
; allocation disappears.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_virtualref_on_load_then_escape() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %inner = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
              ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576)
           to label %nA unwind label %u1
nA:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 67890 to ptr), i32 16, i1 false)
           to label %nB unwind label %u2
nB:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 8
  store atomic ptr addrspace(1) %inner, ptr addrspace(1) %slot unordered, align 8
  %loaded = load atomic ptr addrspace(1), ptr addrspace(1) %slot unordered, align 8
  call void @sink(ptr addrspace(1) %loaded)
  ret void
u1:
  %lp1 = landingpad i64 cleanup
  resume i64 %lp1
u2:
  %lp2 = landingpad i64 cleanup
  resume i64 %lp2
}

; CHECK-LABEL: define void @test_virtualref_on_load_then_escape
; The outer (klass 67890) is fully eliminated.
; CHECK-NOT: i64 67890
; The original allocation for the inner (klass 12345) is retained.
; CHECK: %[[MAT:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576)
; CHECK-NEXT: to label %{{.*}} unwind label %{{.*}}
; The sink receives the inner OrigAlloc directly, not the eliminated load.
; CHECK: call void @sink(ptr addrspace(1) %[[MAT]])

!java-method-compilation = !{}
