; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; A release fence is an ordering boundary even though it has no pointer
; operand. PEA must materialize a live VO and replay its initialization before
; the fence, rather than delaying replay until the later publication call.
; This models ForkJoinTask.fork(): moving the compressed-reference field store
; after its release fence can let a worker observe the default null value.

target datalayout = "e-p:64:64-p1:64:64-p3:32:32"

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @publish(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @release_fence_before_publication(ptr addrspace(1) %value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 76401 to ptr), i32 24, i1 false)
      to label %body unwind label %unwind
body:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  %narrow = addrspacecast ptr addrspace(1) %value to ptr addrspace(3)
  store atomic ptr addrspace(3) %narrow, ptr addrspace(1) %slot unordered,
      align 4
  fence release
  call void @publish(ptr addrspace(1) %o)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @release_fence_before_publication(
; CHECK: %[[O:[-A-Za-z$._0-9]+]] = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
; CHECK: %[[NARROW:[-A-Za-z$._0-9]+]] = addrspacecast ptr addrspace(1) %value to ptr addrspace(3)
; CHECK: %[[SLOT:[-A-Za-z$._0-9]+]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %[[O]], i64 16
; CHECK-NEXT: store atomic ptr addrspace(3) %[[NARROW]], ptr addrspace(1) %[[SLOT]] unordered, align 4
; CHECK-NEXT: fence release
; CHECK-NEXT: call void @publish(ptr addrspace(1) %[[O]])

; An acquire-only fence does not order preceding initialization for a later
; publication, so it must not force a non-escaping allocation to materialize.
define i32 @acquire_fence_keeps_virtual() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 76402 to ptr), i32 16, i1 false)
      to label %body unwind label %unwind
body:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 12
  store atomic i32 42, ptr addrspace(1) %slot unordered, align 4
  fence acquire
  %value = load atomic i32, ptr addrspace(1) %slot unordered, align 4
  ret i32 %value
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @acquire_fence_keeps_virtual()
; CHECK-NOT: @jeandle.new_instance
; CHECK: fence acquire
; CHECK-NEXT: ret i32 42

; Jeandle represents C2 MemBarCPUOrder with a singlethread seq_cst fence. It
; remains an optimizer ordering point, but cannot publish a still-virtual
; object's identity to another thread. Scalar replacement may therefore span
; it, just as it does across C2 MemBarCPUOrder.
define i32 @singlethread_cpuorder_keeps_virtual() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 77003 to ptr), i32 16, i1 false)
      to label %body unwind label %unwind
body:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 12
  store atomic i32 43, ptr addrspace(1) %slot unordered, align 4
  fence syncscope("singlethread") seq_cst
  %value = load atomic i32, ptr addrspace(1) %slot unordered, align 4
  ret i32 %value
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @singlethread_cpuorder_keeps_virtual()
; CHECK-NOT: @jeandle.new_instance
; CHECK: fence syncscope("singlethread") seq_cst
; CHECK-NEXT: ret i32 43

; A singlethread fence is not a blanket permission to erase object identity.
; An actual identity-consuming call after it must still materialize the object,
; with its fields initialized before the consumer. The replay may remain after
; this non-publishing compiler fence because no observer can name the object
; before @publish receives it.
define void @singlethread_cpuorder_materializes_at_escape(
    ptr addrspace(1) %value) gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 77004 to ptr), i32 24, i1 false)
      to label %body unwind label %unwind
body:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  %narrow = addrspacecast ptr addrspace(1) %value to ptr addrspace(3)
  store atomic ptr addrspace(3) %narrow, ptr addrspace(1) %slot unordered,
      align 4
  fence syncscope("singlethread") seq_cst
  call void @publish(ptr addrspace(1) %o)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @singlethread_cpuorder_materializes_at_escape(
; CHECK: %[[ST_O:[-A-Za-z$._0-9]+]] = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
; CHECK: fence syncscope("singlethread") seq_cst
; CHECK-NEXT: %[[ST_NARROW:[-A-Za-z$._0-9]+]] = addrspacecast ptr addrspace(1) %value to ptr addrspace(3)
; CHECK-NEXT: %[[ST_SLOT:[-A-Za-z$._0-9]+]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %[[ST_O]], i64 16
; CHECK-NEXT: store atomic ptr addrspace(3) %[[ST_NARROW]], ptr addrspace(1) %[[ST_SLOT]] unordered, align 4
; CHECK-NEXT: call void @publish(ptr addrspace(1) %[[ST_O]])

; Do not generalize the CPUOrder exception to every singlethread fence.  A
; different ordering is not Jeandle's recognized CPUOrder encoding and remains
; conservative until its producer establishes more specific semantics.
define void @singlethread_release_before_publication(ptr addrspace(1) %value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 77005 to ptr), i32 24, i1 false)
      to label %body unwind label %unwind
body:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  %narrow = addrspacecast ptr addrspace(1) %value to ptr addrspace(3)
  store atomic ptr addrspace(3) %narrow, ptr addrspace(1) %slot unordered,
      align 4
  fence syncscope("singlethread") release
  call void @publish(ptr addrspace(1) %o)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @singlethread_release_before_publication(
; CHECK: %[[STR_O:[-A-Za-z$._0-9]+]] = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
; CHECK: %[[STR_NARROW:[-A-Za-z$._0-9]+]] = addrspacecast ptr addrspace(1) %value to ptr addrspace(3)
; CHECK: %[[STR_SLOT:[-A-Za-z$._0-9]+]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %[[STR_O]], i64 16
; CHECK-NEXT: store atomic ptr addrspace(3) %[[STR_NARROW]], ptr addrspace(1) %[[STR_SLOT]] unordered, align 4
; CHECK-NEXT: fence syncscope("singlethread") release
; CHECK-NEXT: call void @publish(ptr addrspace(1) %[[STR_O]])

; Only the exact built-in singlethread seq_cst form above is known to model
; Jeandle's compiler-only CPUOrder barrier. A target-specific scope may
; synchronize with other agents, so retain the conservative pre-fence rule.
define void @target_scope_release_before_publication(ptr addrspace(1) %value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 77006 to ptr), i32 24, i1 false)
      to label %body unwind label %unwind
body:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  %narrow = addrspacecast ptr addrspace(1) %value to ptr addrspace(3)
  store atomic ptr addrspace(3) %narrow, ptr addrspace(1) %slot unordered,
      align 4
  fence syncscope("agent") release
  call void @publish(ptr addrspace(1) %o)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @target_scope_release_before_publication(
; CHECK: %[[TS_O:[-A-Za-z$._0-9]+]] = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
; CHECK: %[[TS_NARROW:[-A-Za-z$._0-9]+]] = addrspacecast ptr addrspace(1) %value to ptr addrspace(3)
; CHECK: %[[TS_SLOT:[-A-Za-z$._0-9]+]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %[[TS_O]], i64 16
; CHECK-NEXT: store atomic ptr addrspace(3) %[[TS_NARROW]], ptr addrspace(1) %[[TS_SLOT]] unordered, align 4
; CHECK-NEXT: fence syncscope("agent") release
; CHECK-NEXT: call void @publish(ptr addrspace(1) %[[TS_O]])

!java-method-compilation = !{}
