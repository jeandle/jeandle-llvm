; RUN: opt -S -passes='require<partial-escape-analysis>,partial-escape-transform' -jeandle-vm-callback-log=%S/Inputs/layout.cblog -verify-each %s | FileCheck %s
;
; A hash fold must not publish instructions depending on a revoked field
; PHI. Its result may also feed a different virtual array hash. These monitor
; JavaOps deliberately exercise analysis rollback rather than Java frontend
; monitor pairing.
target datalayout = "e-p:64:64-p1:64:64"
@arrayOopDesc.base_offset_in_bytes.byte = constant i32 16
@arrayOopDesc.base_offset_in_bytes.int = constant i32 16
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare i32 @jeandle.vectorized_hashcode(ptr addrspace(1), i32, i32, i32, i32)
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare i32 @__gxx_personality_v0(...)

; CHECK-LABEL: @late_hash_dependency_1(
; CHECK: %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK-NOT: @jeandle.new_array
; CHECK: %hasha = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 1, i32 1, i32 10)
; CHECK-NOT: @jeandle.vectorized_hashcode
; CHECK: mul i32 %hasha, 31
; CHECK: @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %a
; CHECK: @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %other
; CHECK: ret i32

define i32 @late_hash_dependency_1(i1 %pick, i32 %x, i32 %y, ptr addrspace(1) %other) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock = alloca i64, align 8
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10004 to ptr), i32 1, i32 20, i32 16, i32 100, i1 false, i1 false) to label %allocb unwind label %u
allocb:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10004 to ptr), i32 1, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  br i1 %pick, label %left, label %right
left:
  store atomic i32 %x, ptr addrspace(1) %p0 unordered, align 4
  br label %join
right:
  store atomic i32 %y, ptr addrspace(1) %p0 unordered, align 4
  br label %join
join:
  %hasha = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 1, i32 1, i32 10)
  %hashb = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %b, i32 0, i32 1, i32 %hasha, i32 10)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %a, ptr %lock)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %other, ptr %lock)
  ret i32 %hashb
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @late_hash_dependency_40(
; CHECK: %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK-NOT: @jeandle.new_array
; CHECK: %hasha = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 40, i32 1, i32 10)
; CHECK-NOT: @jeandle.vectorized_hashcode
; CHECK: mul i32 %hasha, 31
; CHECK: @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %a
; CHECK: @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %other
; CHECK: ret i32

define i32 @late_hash_dependency_40(i1 %pick, i32 %x, i32 %y, ptr addrspace(1) %other) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock = alloca i64, align 8
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10004 to ptr), i32 40, i32 176, i32 16, i32 100, i1 false, i1 false) to label %allocb unwind label %u
allocb:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10004 to ptr), i32 1, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  %p1 = getelementptr i8, ptr addrspace(1) %a, i64 20
  %p2 = getelementptr i8, ptr addrspace(1) %a, i64 24
  %p3 = getelementptr i8, ptr addrspace(1) %a, i64 28
  %p4 = getelementptr i8, ptr addrspace(1) %a, i64 32
  %p5 = getelementptr i8, ptr addrspace(1) %a, i64 36
  %p6 = getelementptr i8, ptr addrspace(1) %a, i64 40
  %p7 = getelementptr i8, ptr addrspace(1) %a, i64 44
  %p8 = getelementptr i8, ptr addrspace(1) %a, i64 48
  %p9 = getelementptr i8, ptr addrspace(1) %a, i64 52
  %p10 = getelementptr i8, ptr addrspace(1) %a, i64 56
  %p11 = getelementptr i8, ptr addrspace(1) %a, i64 60
  %p12 = getelementptr i8, ptr addrspace(1) %a, i64 64
  %p13 = getelementptr i8, ptr addrspace(1) %a, i64 68
  %p14 = getelementptr i8, ptr addrspace(1) %a, i64 72
  %p15 = getelementptr i8, ptr addrspace(1) %a, i64 76
  %p16 = getelementptr i8, ptr addrspace(1) %a, i64 80
  %p17 = getelementptr i8, ptr addrspace(1) %a, i64 84
  %p18 = getelementptr i8, ptr addrspace(1) %a, i64 88
  %p19 = getelementptr i8, ptr addrspace(1) %a, i64 92
  %p20 = getelementptr i8, ptr addrspace(1) %a, i64 96
  %p21 = getelementptr i8, ptr addrspace(1) %a, i64 100
  %p22 = getelementptr i8, ptr addrspace(1) %a, i64 104
  %p23 = getelementptr i8, ptr addrspace(1) %a, i64 108
  %p24 = getelementptr i8, ptr addrspace(1) %a, i64 112
  %p25 = getelementptr i8, ptr addrspace(1) %a, i64 116
  %p26 = getelementptr i8, ptr addrspace(1) %a, i64 120
  %p27 = getelementptr i8, ptr addrspace(1) %a, i64 124
  %p28 = getelementptr i8, ptr addrspace(1) %a, i64 128
  %p29 = getelementptr i8, ptr addrspace(1) %a, i64 132
  %p30 = getelementptr i8, ptr addrspace(1) %a, i64 136
  %p31 = getelementptr i8, ptr addrspace(1) %a, i64 140
  %p32 = getelementptr i8, ptr addrspace(1) %a, i64 144
  %p33 = getelementptr i8, ptr addrspace(1) %a, i64 148
  %p34 = getelementptr i8, ptr addrspace(1) %a, i64 152
  %p35 = getelementptr i8, ptr addrspace(1) %a, i64 156
  %p36 = getelementptr i8, ptr addrspace(1) %a, i64 160
  %p37 = getelementptr i8, ptr addrspace(1) %a, i64 164
  %p38 = getelementptr i8, ptr addrspace(1) %a, i64 168
  %p39 = getelementptr i8, ptr addrspace(1) %a, i64 172
  br i1 %pick, label %left, label %right
left:
  store atomic i32 %x, ptr addrspace(1) %p0 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p1 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p2 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p3 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p4 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p5 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p6 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p7 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p8 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p9 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p10 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p11 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p12 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p13 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p14 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p15 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p16 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p17 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p18 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p19 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p20 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p21 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p22 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p23 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p24 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p25 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p26 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p27 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p28 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p29 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p30 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p31 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p32 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p33 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p34 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p35 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p36 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p37 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p38 unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %p39 unordered, align 4
  br label %join
right:
  store atomic i32 %y, ptr addrspace(1) %p0 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p1 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p2 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p3 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p4 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p5 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p6 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p7 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p8 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p9 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p10 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p11 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p12 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p13 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p14 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p15 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p16 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p17 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p18 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p19 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p20 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p21 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p22 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p23 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p24 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p25 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p26 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p27 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p28 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p29 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p30 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p31 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p32 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p33 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p34 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p35 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p36 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p37 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p38 unordered, align 4
  store atomic i32 %y, ptr addrspace(1) %p39 unordered, align 4
  br label %join
join:
  %hasha = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 40, i32 1, i32 10)
  %hashb = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %b, i32 0, i32 1, i32 %hasha, i32 10)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %a, ptr %lock)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %other, ptr %lock)
  ret i32 %hashb
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

!java-method-compilation = !{}
