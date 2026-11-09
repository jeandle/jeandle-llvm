; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/812_copy_packed_deopt.cblog %s | FileCheck %s --check-prefixes=CHECK,LE --implicit-check-not="invoke hotspotcc" --implicit-check-not="invoke void @jeandle.copy" --implicit-check-not="store atomic" --implicit-check-not="load atomic"
; RUN: sed 's/e-p:64:64/E-p:64:64/' %s | opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/812_copy_packed_deopt.cblog | FileCheck %s --check-prefixes=CHECK,BE --implicit-check-not="invoke hotspotcc" --implicit-check-not="invoke void @jeandle.copy" --implicit-check-not="store atomic" --implicit-check-not="load atomic"
; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform,require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/812_copy_packed_deopt.cblog %s | FileCheck %s --check-prefixes=CHECK,LE --implicit-check-not="invoke hotspotcc" --implicit-check-not="invoke void @jeandle.copy" --implicit-check-not="store atomic" --implicit-check-not="load atomic"
;
; Complete primitive groups remain virtual through a copy and safepoint.
; Descriptors contain one value per physical array element, in memory order,
; while subsequent whole-group loads still see the original packed state.
; Constants exercise folding of casts and shifts; dynamic values exercise
; owned descriptor expressions, sub-int widening and parented SSA operands.
target datalayout = "e-p:64:64"

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare void @safepoint()
declare i32 @__gxx_personality_v0(...)

; CHECK-LABEL: define i16 @byte_constants(
; CHECK: call void @safepoint()
; CHECK-SAME: [ "deopt"(i32 1, i32 1, i64 262157, i64 81201, i32 4,
; CHECK-SAME: i64 68719476746, i8 0,
; LE-SAME: i64 73014444042, i8 34, i64 77309411338, i8 17,
; BE-SAME: i64 73014444042, i8 17, i64 77309411338, i8 34,
; CHECK-SAME: i64 81604378634, i8 0, i64 524300, i32 0) ]
; CHECK: ret i16 4386
define i16 @byte_constants() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 81201 to ptr), i32 4, i32 24, i32 16, i32 1048576) to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 81201 to ptr), i32 4, i32 24, i32 16, i32 1048576) to label %init unwind label %u
init:
  %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i16 4386, ptr addrspace(1) %sp unordered, align 2
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 1, i64 2, ptr null, ptr null, i64 4, i64 4) #0 to label %read unwind label %u
read:
  call void @safepoint() [ "deopt"(i32 1, i32 1, i64 12, ptr addrspace(1) %dst) ]
  %dp = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 17
  %value = load atomic i16, ptr addrspace(1) %dp unordered, align 1
  ret i16 %value
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i16 @byte_parented_phi(
; CHECK: %packed = phi i16 [ %left.value, %left ], [ %right.value, %right ]
; LE: %[[BYTE0:[^ ]+]] = trunc i16 %packed to i8
; LE-NEXT: %[[BYTE0W:[^ ]+]] = zext i8 %[[BYTE0]] to i32
; LE-NEXT: %[[BYTEHI:[^ ]+]] = lshr i16 %packed, 8
; LE-NEXT: %[[BYTE1:[^ ]+]] = trunc i16 %[[BYTEHI]] to i8
; LE-NEXT: %[[BYTE1W:[^ ]+]] = zext i8 %[[BYTE1]] to i32
; BE: %[[BYTEHI:[^ ]+]] = lshr i16 %packed, 8
; BE-NEXT: %[[BYTE0:[^ ]+]] = trunc i16 %[[BYTEHI]] to i8
; BE-NEXT: %[[BYTE0W:[^ ]+]] = zext i8 %[[BYTE0]] to i32
; BE-NEXT: %[[BYTE1:[^ ]+]] = trunc i16 %packed to i8
; BE-NEXT: %[[BYTE1W:[^ ]+]] = zext i8 %[[BYTE1]] to i32
; CHECK-NEXT: call void @safepoint()
; CHECK-SAME: [ "deopt"(i32 2, i32 2, i64 262157, i64 81201, i32 2,
; CHECK-SAME: i64 68719476746, i32 %[[BYTE0W]], i64 73014444042, i32 %[[BYTE1W]], i64 524300, i32 0) ]
; CHECK: ret i16 %packed
define i16 @byte_parented_phi(i1 %choose, i16 %left.value, i16 %right.value) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 81201 to ptr), i32 2, i32 24, i32 16, i32 1048576) to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 81201 to ptr), i32 2, i32 24, i32 16, i32 1048576) to label %branch unwind label %u
branch:
  br i1 %choose, label %left, label %right
left:
  br label %init
right:
  br label %init
init:
  %packed = phi i16 [ %left.value, %left ], [ %right.value, %right ]
  %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i16 %packed, ptr addrspace(1) %sp unordered, align 2
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 2, ptr null, ptr null, i64 2, i64 2) #0 to label %read unwind label %u
read:
  call void @safepoint() [ "deopt"(i32 2, i32 2, i64 12, ptr addrspace(1) %dst) ]
  %dp = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %value = load atomic i16, ptr addrspace(1) %dp unordered, align 2
  ret i16 %value
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Char elements are 16-bit physical cells, including values with the high bit
; set. Packed stores use memory bit order; descriptor widening is unsigned.
; CHECK-LABEL: define i32 @char_dynamic(
; LE: %[[CHAR0:[^ ]+]] = trunc i32 %packed to i16
; LE-NEXT: %[[CHAR0W:[^ ]+]] = zext i16 %[[CHAR0]] to i32
; LE-NEXT: %[[CHARHI:[^ ]+]] = lshr i32 %packed, 16
; LE-NEXT: %[[CHAR1:[^ ]+]] = trunc i32 %[[CHARHI]] to i16
; LE-NEXT: %[[CHAR1W:[^ ]+]] = zext i16 %[[CHAR1]] to i32
; BE: %[[CHARHI:[^ ]+]] = lshr i32 %packed, 16
; BE-NEXT: %[[CHAR0:[^ ]+]] = trunc i32 %[[CHARHI]] to i16
; BE-NEXT: %[[CHAR0W:[^ ]+]] = zext i16 %[[CHAR0]] to i32
; BE-NEXT: %[[CHAR1:[^ ]+]] = trunc i32 %packed to i16
; BE-NEXT: %[[CHAR1W:[^ ]+]] = zext i16 %[[CHAR1]] to i32
; CHECK-NEXT: call void @safepoint()
; CHECK-SAME: [ "deopt"(i32 3, i32 3, i64 262157, i64 81202, i32 3,
; CHECK-SAME: i64 68719476746, i32 %[[CHAR0W]], i64 77309411338, i32 %[[CHAR1W]], i64 85899345930, i16 0, i64 524300, i32 0) ]
; CHECK: ret i32 %packed
define i32 @char_dynamic(i32 %packed) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 81202 to ptr), i32 3, i32 24, i32 16, i32 1048576) to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 81202 to ptr), i32 3, i32 24, i32 16, i32 1048576) to label %init unwind label %u
init:
  %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i32 %packed, ptr addrspace(1) %sp unordered, align 4
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 2, ptr null, ptr null, i64 3, i64 3) #0 to label %read unwind label %u
read:
  call void @safepoint() [ "deopt"(i32 3, i32 3, i64 12, ptr addrspace(1) %dst) ]
  %dp = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %value = load atomic i32, ptr addrspace(1) %dp unordered, align 4
  ret i32 %value
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; A non-integer packed value is bitcast before the element shifts. Keeping
; the group after the safepoint must still fold the exact double load.
; CHECK-LABEL: define double @double_group_in_int_array(
; CHECK: %[[DOUBLEBITS:[^ ]+]] = bitcast double %packed to i64
; LE-NEXT: %[[INT0:[^ ]+]] = trunc i64 %[[DOUBLEBITS]] to i32
; LE-NEXT: %[[INTHI:[^ ]+]] = lshr i64 %[[DOUBLEBITS]], 32
; LE-NEXT: %[[INT1:[^ ]+]] = trunc i64 %[[INTHI]] to i32
; BE-NEXT: %[[INTHI:[^ ]+]] = lshr i64 %[[DOUBLEBITS]], 32
; BE-NEXT: %[[INT0:[^ ]+]] = trunc i64 %[[INTHI]] to i32
; BE-NEXT: %[[INT1:[^ ]+]] = trunc i64 %[[DOUBLEBITS]] to i32
; CHECK-NEXT: call void @safepoint()
; CHECK-SAME: [ "deopt"(i32 4, i32 4, i64 262157, i64 81204, i32 2,
; CHECK-SAME: i64 68719476746, i32 %[[INT0]], i64 85899345930, i32 %[[INT1]], i64 524300, i32 0) ]
; CHECK: ret double %packed
define double @double_group_in_int_array(double %packed) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 81204 to ptr), i32 2, i32 24, i32 16, i32 1048576) to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 81204 to ptr), i32 2, i32 24, i32 16, i32 1048576) to label %init unwind label %u
init:
  %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic double %packed, ptr addrspace(1) %sp unordered, align 8
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 2, ptr null, ptr null, i64 2, i64 2) #0 to label %read unwind label %u
read:
  call void @safepoint() [ "deopt"(i32 4, i32 4, i64 12, ptr addrspace(1) %dst) ]
  %dp = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %value = load atomic double, ptr addrspace(1) %dp unordered, align 8
  ret double %value
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Reinterpret the projected physical element bits to float, preserving -0
; and a NaN payload. The i64 constant is 0x7fc0000180000000.
; CHECK-LABEL: define i64 @float_elements(
; CHECK: call void @safepoint()
; CHECK-SAME: [ "deopt"(i32 5, i32 5, i64 262157, i64 81203, i32 2,
; LE-SAME: i64 68719476742, float -0.000000e+00, i64 85899345926, float 0x7FF8000020000000,
; BE-SAME: i64 68719476742, float 0x7FF8000020000000, i64 85899345926, float -0.000000e+00,
; CHECK-SAME: i64 524300, i32 0) ]
; CHECK: ret i64 9205357644787744768
define i64 @float_elements() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 81203 to ptr), i32 2, i32 24, i32 16, i32 1048576) to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 81203 to ptr), i32 2, i32 24, i32 16, i32 1048576) to label %init unwind label %u
init:
  %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i64 9205357644787744768, ptr addrspace(1) %sp unordered, align 8
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 2, ptr null, ptr null, i64 2, i64 2) #0 to label %read unwind label %u
read:
  call void @safepoint() [ "deopt"(i32 5, i32 5, i64 12, ptr addrspace(1) %dst) ]
  %dp = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %value = load atomic i64, ptr addrspace(1) %dp unordered, align 8
  ret i64 %value
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Dynamic physical float elements require bit reinterpretation after slicing,
; rather than conversion of the packed numeric value.
; CHECK-LABEL: define i64 @dynamic_float_elements(
; LE: %[[FLOATBITS0:[^ ]+]] = trunc i64 %packed to i32
; LE-NEXT: %[[FLOAT0:[^ ]+]] = bitcast i32 %[[FLOATBITS0]] to float
; LE-NEXT: %[[FLOATHI:[^ ]+]] = lshr i64 %packed, 32
; LE-NEXT: %[[FLOATBITS1:[^ ]+]] = trunc i64 %[[FLOATHI]] to i32
; LE-NEXT: %[[FLOAT1:[^ ]+]] = bitcast i32 %[[FLOATBITS1]] to float
; BE: %[[FLOATHI:[^ ]+]] = lshr i64 %packed, 32
; BE-NEXT: %[[FLOATBITS0:[^ ]+]] = trunc i64 %[[FLOATHI]] to i32
; BE-NEXT: %[[FLOAT0:[^ ]+]] = bitcast i32 %[[FLOATBITS0]] to float
; BE-NEXT: %[[FLOATBITS1:[^ ]+]] = trunc i64 %packed to i32
; BE-NEXT: %[[FLOAT1:[^ ]+]] = bitcast i32 %[[FLOATBITS1]] to float
; CHECK-NEXT: call void @safepoint()
; CHECK-SAME: [ "deopt"(i32 6, i32 6, i64 262157, i64 81203, i32 2,
; CHECK-SAME: i64 68719476742, float %[[FLOAT0]], i64 85899345926, float %[[FLOAT1]], i64 524300, i32 0) ]
; CHECK: ret i64 %packed
define i64 @dynamic_float_elements(i64 %packed) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 81203 to ptr), i32 2, i32 24, i32 16, i32 1048576) to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 81203 to ptr), i32 2, i32 24, i32 16, i32 1048576) to label %init unwind label %u
init:
  %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i64 %packed, ptr addrspace(1) %sp unordered, align 8
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 2, ptr null, ptr null, i64 2, i64 2) #0 to label %read unwind label %u
read:
  call void @safepoint() [ "deopt"(i32 6, i32 6, i64 12, ptr addrspace(1) %dst) ]
  %dp = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %value = load atomic i64, ptr addrspace(1) %dp unordered, align 8
  ret i64 %value
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Numeric vectors also have an exact primitive bit representation. Their
; lane order in memory is unchanged by target endianness, including the
; constant vector-to-integer fold used by the descriptor projection.
; CHECK-LABEL: define <2 x i32> @numeric_vector_group(
; CHECK: call void @safepoint()
; CHECK-SAME: [ "deopt"(i32 7, i32 7, i64 262157, i64 81204, i32 2,
; CHECK-SAME: i64 68719476746, i32 287454020, i64 85899345930, i32 1432778632, i64 524300, i32 0) ]
; CHECK: ret <2 x i32> <i32 287454020, i32 1432778632>
define <2 x i32> @numeric_vector_group() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 81204 to ptr), i32 2, i32 24, i32 16, i32 1048576) to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 81204 to ptr), i32 2, i32 24, i32 16, i32 1048576) to label %init unwind label %u
init:
  %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store <2 x i32> <i32 287454020, i32 1432778632>, ptr addrspace(1) %sp, align 8
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 2, ptr null, ptr null, i64 2, i64 2) #0 to label %read unwind label %u
read:
  call void @safepoint() [ "deopt"(i32 7, i32 7, i64 12, ptr addrspace(1) %dst) ]
  %dp = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %value = load <2 x i32>, ptr addrspace(1) %dp, align 8
  ret <2 x i32> %value
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

attributes #0 = { "jeandle.copy.kind"="arraycopy" "jeandle.copy.validated" }
!java-method-compilation = !{}
