; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/794_clone_payload_bails.cblog %s | FileCheck %s --check-prefix=CONCRETE
; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/794_clone_payload_bails.cblog %s | FileCheck %s --check-prefix=SHORT

; Byte-payload clone bail cases:
;   The barrier case — clone-instance with a concrete source whose klass the
;   GetCloneInstanceInfo callback declines semantic field loads with
;   RequiresGCBarriers (for example a collector needing read barriers): the
;   fold must not fire, the bulk copy stays for collector-specific expansion.
;   The short case — a payload window that does not cover all fields (one
;   word short) must not fire: the destination's uncovered field would keep
;   its default instead of the source's value.

@instanceOopDesc.base_offset_in_bytes = constant i64 16

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)

define i32 @clone_instance_concrete(ptr addrspace(1) %src) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 30001 to ptr), i32 32, i1 false)
         to label %do_clone unwind label %u
do_clone:
  call void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dst, i64 16,
                          i64 2, ptr null, ptr null, i64 32, i64 32)
      #0 [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) null) ]
  br label %read
read:
  %dx = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %vx = load atomic i32, ptr addrspace(1) %dx unordered, align 4
  ret i32 %vx
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define i32 @clone_instance_short_payload() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 30001 to ptr), i32 32, i1 false)
         to label %stores unwind label %u2
stores:
  %sx = getelementptr inbounds i8, ptr addrspace(1) %src, i64 24
  store atomic i32 5, ptr addrspace(1) %sx unordered, align 4
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 30001 to ptr), i32 32, i1 false)
         to label %do_clone2 unwind label %u2
do_clone2:
  call void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dst, i64 16,
                          i64 1, ptr null, ptr null, i64 32, i64 32)
      #1 [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) null) ]
  br label %read2
read2:
  %dx = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 24
  %vx = load atomic i32, ptr addrspace(1) %dx unordered, align 4
  ret i32 %vx
u2:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

attributes #0 = { "jeandle.copy.kind"="clone-instance" "jeandle.copy.tightly-coupled-allocation" }
attributes #1 = { "jeandle.copy.kind"="clone-instance" "jeandle.copy.tightly-coupled-allocation" }

; CONCRETE-LABEL: define i32 @clone_instance_concrete
; CONCRETE: jeandle.new_instance
; CONCRETE: call void @jeandle.copy
; CONCRETE: load atomic
; CONCRETE: ret i32
;
; SHORT-LABEL: define i32 @clone_instance_short_payload
; SHORT: jeandle.new_instance
; SHORT: call void @jeandle.copy
; SHORT: load atomic
; SHORT: ret i32

!java-method-compilation = !{}
