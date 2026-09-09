; RUN: opt -S \
; RUN:   -passes='function(require<partial-escape-analysis>,partial-escape-transform,insert-gc-barriers),rewrite-statepoints-for-gc,verify' \
; RUN:   -jeandle-vm-callback-log=%S/Inputs/651_gc_barrier_liveness_full_pipeline.cblog \
; RUN:   %s | FileCheck %s

; Full PEA -> barrier insertion -> statepoint rewriting coverage for reference
; fields/elements. Stores into virtual objects and their frontend barriers must
; disappear. A replayed store into a materialized Object[] must receive one
; fresh barrier. External and already-materialized sibling oops used only by a
; virtual-object descriptor must be listed as GC-live and relocated.

@arrayOopDesc.element_size.object = private constant i32 8
@satb_log = private global ptr addrspace(1) null

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc ptr addrspace(1) @jeandle.new_array(
    ptr, i32, i32, i32, i32)
declare void @observe(i32)
declare void @publish(ptr addrspace(1))
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define private hotspotcc void @jeandle.pre_barrier(
    ptr addrspace(1) %addr) #0 {
entry:
  %old = load atomic ptr addrspace(1), ptr addrspace(1) %addr unordered, align 8
  store ptr addrspace(1) %old, ptr @satb_log
  ret void
}

define private hotspotcc void @jeandle.post_barrier(
    ptr addrspace(1) %addr, ptr addrspace(1) captures(none) %oop) #0 {
entry:
  %addr.int = ptrtoint ptr addrspace(1) %addr to i64
  %card.index = lshr i64 %addr.int, 9
  %card = getelementptr inbounds i8,
      ptr inttoptr (i64 139709660639232 to ptr), i64 %card.index
  store atomic i8 0, ptr %card unordered, align 1
  ret void
}

define void @virtual_holder_and_array_elision(
    ptr addrspace(1) %external) gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %holder = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 100 to ptr), i32 24, i1 false)
      to label %alloc.array unwind label %unwind
alloc.array:
  %array = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
      ptr inttoptr (i64 8888 to ptr), i32 2, i32 32, i32 16, i32 1048576)
      to label %body unwind label %unwind
body:
  %holder.external = getelementptr inbounds i8,
      ptr addrspace(1) %holder, i64 8
  store atomic ptr addrspace(1) %external,
      ptr addrspace(1) %holder.external unordered, align 8
  call hotspotcc void @jeandle.post_barrier(
      ptr addrspace(1) %holder.external, ptr addrspace(1) %external)
  %holder.array = getelementptr inbounds i8,
      ptr addrspace(1) %holder, i64 16
  store atomic ptr addrspace(1) %array,
      ptr addrspace(1) %holder.array unordered, align 8
  call hotspotcc void @jeandle.post_barrier(
      ptr addrspace(1) %holder.array, ptr addrspace(1) %array)
  %array.base = getelementptr inbounds i8,
      ptr addrspace(1) %array, i64 16
  %array.element = getelementptr inbounds ptr addrspace(1),
      ptr addrspace(1) %array.base, i64 0
  store atomic ptr addrspace(1) %external,
      ptr addrspace(1) %array.element unordered, align 8
  call hotspotcc void @jeandle.post_barrier(
      ptr addrspace(1) %array.element, ptr addrspace(1) %external)
  call void @observe(i32 1)
      [ "deopt"(i32 17, i32 17, i64 12, ptr addrspace(1) %holder) ]
  ret void
unwind:
  %lp = landingpad i64 cleanup
  ret void
}

; CHECK-LABEL: define void @virtual_holder_and_array_elision
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: store atomic ptr addrspace(1)
; CHECK-NOT: @jeandle.post_barrier
; CHECK: @llvm.experimental.gc.statepoint
; CHECK-SAME: @observe
; CHECK-SAME: "gc-live"
; CHECK-SAME: ptr addrspace(1) %external
; CHECK: @llvm.experimental.gc.relocate

define void @materialized_array_replay(
    ptr addrspace(1) %external) gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %array = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
      ptr inttoptr (i64 8888 to ptr), i32 2, i32 32, i32 16, i32 1048576)
      to label %body unwind label %unwind
body:
  %array.base = getelementptr inbounds i8,
      ptr addrspace(1) %array, i64 16
  %array.element = getelementptr inbounds ptr addrspace(1),
      ptr addrspace(1) %array.base, i64 1
  store atomic ptr addrspace(1) %external,
      ptr addrspace(1) %array.element unordered, align 8
  call hotspotcc void @jeandle.post_barrier(
      ptr addrspace(1) %array.element, ptr addrspace(1) %external)
  call void @sink(ptr addrspace(1) %array)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  ret void
}

; CHECK-LABEL: define void @materialized_array_replay
; CHECK: @jeandle.new_array
; CHECK: store atomic ptr addrspace(1)
; The frontend barrier on the virtual store is folded; InsertGCBarriers adds
; exactly one barrier for the replayed real store.
; CHECK-COUNT-1: @jeandle.post_barrier
; CHECK: @llvm.experimental.gc.statepoint
; CHECK-SAME: @sink
; CHECK-SAME: "gc-live"
; CHECK: @llvm.experimental.gc.relocate

define void @materialized_sibling_descriptor_liveness(
    ptr addrspace(1) %external, i32 %payload) gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 100 to ptr), i32 24, i1 false)
      to label %alloc.sibling unwind label %unwind
alloc.sibling:
  %sibling = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 200 to ptr), i32 16, i1 false)
      to label %body unwind label %unwind
body:
  %sibling.payload = getelementptr inbounds i8,
      ptr addrspace(1) %sibling, i64 8
  store atomic i32 %payload,
      ptr addrspace(1) %sibling.payload unordered, align 4
  call void @publish(ptr addrspace(1) %sibling)
  %outer.external = getelementptr inbounds i8,
      ptr addrspace(1) %outer, i64 8
  store atomic ptr addrspace(1) %external,
      ptr addrspace(1) %outer.external unordered, align 8
  call hotspotcc void @jeandle.post_barrier(
      ptr addrspace(1) %outer.external, ptr addrspace(1) %external)
  %outer.sibling = getelementptr inbounds i8,
      ptr addrspace(1) %outer, i64 16
  store atomic ptr addrspace(1) %sibling,
      ptr addrspace(1) %outer.sibling unordered, align 8
  call hotspotcc void @jeandle.post_barrier(
      ptr addrspace(1) %outer.sibling, ptr addrspace(1) %sibling)
  call void @observe(i32 %payload)
      [ "deopt"(i32 29, i32 29, i64 12, ptr addrspace(1) %outer) ]
  ret void
unwind:
  %lp = landingpad i64 cleanup
  ret void
}

; CHECK-LABEL: define void @materialized_sibling_descriptor_liveness
; The outer allocation and its virtual stores/barriers disappear; the published
; sibling remains.
; CHECK-COUNT-1: @jeandle.new_instance
; CHECK-NOT: @jeandle.post_barrier
; CHECK: %[[OBSERVE_TOKEN:[-A-Za-z$._0-9]+]] = call token {{.*}}@llvm.experimental.gc.statepoint{{.*}}@observe
; CHECK-SAME: "deopt"
; CHECK-SAME: ptr addrspace(1) %[[EXTERNAL_LIVE:[-A-Za-z$._0-9]+]]
; CHECK-SAME: ptr addrspace(1) %[[SIBLING_LIVE:[-A-Za-z$._0-9]+]]
; CHECK-SAME: "gc-live"(ptr addrspace(1) %[[EXTERNAL_LIVE]], ptr addrspace(1) %[[SIBLING_LIVE]])
; Both distinct descriptor oops have their own live-set index and relocation.
; CHECK-NEXT: call coldcc ptr addrspace(1) @llvm.experimental.gc.relocate.p1(token %[[OBSERVE_TOKEN]], i32 0, i32 0)
; CHECK-NEXT: call coldcc ptr addrspace(1) @llvm.experimental.gc.relocate.p1(token %[[OBSERVE_TOKEN]], i32 1, i32 1)

attributes #0 = { noinline "lower-phase"="1" }

!java-method-compilation = !{}
