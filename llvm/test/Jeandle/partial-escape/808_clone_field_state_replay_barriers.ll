; RUN: opt -S -verify-each \
; RUN:   -passes='require<partial-escape-analysis>,partial-escape-transform,insert-gc-barriers' \
; RUN:   -jeandle-vm-callback-log=%S/Inputs/802_clone_instance_fold_concrete.cblog \
; RUN:   %s | FileCheck %s

; FieldState layout admission may succeed while bulk-copy barriers are needed.
; The concrete source becomes semantic loads; publication replays ordinary
; reference stores, which receive both GC barriers after PEA.

target datalayout = "e-p:64:64-p1:64:64-p3:32:32-i64:64-n8:16:32:64"

@instanceOopDesc.base_offset_in_bytes = constant i64 16
@heapOopSize = constant i32 4
@ReduceInitialCardMarks = constant i1 false

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare hotspotcc void @jeandle.pre_barrier(ptr addrspace(1))
declare hotspotcc void @jeandle.post_barrier(ptr addrspace(1), ptr addrspace(1))
declare void @publish(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @clone_field_state_replay(
    ptr addrspace(1) "java-klass"="30001" "java-klass-exact" %src)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 30001 to ptr), i32 32, i1 false)
      to label %copy unwind label %unwind
copy:
  call void @jeandle.copy(ptr addrspace(1) %src, i64 16,
      ptr addrspace(1) %dst, i64 16, i64 2,
      ptr null, ptr null, i64 32, i64 32) #0
      [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) null) ]
  call void @publish(ptr addrspace(1) %dst)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

attributes #0 = { "jeandle.copy.kind"="clone-instance" "jeandle.copy.tightly-coupled-allocation" }

; CHECK-LABEL: define void @clone_field_state_replay(
; CHECK: %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NOT: call void @jeandle.copy
; CHECK: getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
; CHECK: load atomic i32
; CHECK: getelementptr inbounds i8, ptr addrspace(1) %src, i64 20
; CHECK: load atomic i32
; CHECK: getelementptr inbounds i8, ptr addrspace(1) %src, i64 24
; CHECK: [[NARROW:%[^ ]+]] = load atomic ptr addrspace(3)
; CHECK: [[REF:%[^ ]+]] = addrspacecast ptr addrspace(3) [[NARROW]] to ptr addrspace(1)
; CHECK: [[STORED:%[^ ]+]] = addrspacecast ptr addrspace(1) [[REF]] to ptr addrspace(3)
; CHECK: [[DESTREF:%[^ ]+]] = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 24
; CHECK-NEXT: call hotspotcc void @jeandle.pre_barrier(ptr addrspace(1) [[DESTREF]])
; CHECK-NEXT: store atomic ptr addrspace(3) [[STORED]], ptr addrspace(1) [[DESTREF]] unordered
; CHECK-NEXT: [[BARRIERREF:%[^ ]+]] = addrspacecast ptr addrspace(3) [[STORED]] to ptr addrspace(1)
; CHECK-NEXT: call hotspotcc void @jeandle.post_barrier(ptr addrspace(1) [[DESTREF]], ptr addrspace(1) [[BARRIERREF]])
; CHECK-NOT: call void @jeandle.copy
; CHECK: call void @publish(ptr addrspace(1) %dst)

!java-method-compilation = !{}
