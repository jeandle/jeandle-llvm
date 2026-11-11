; RUN: opt -S -passes='partial-escape-iterative,instcombine,simplifycfg' -jeandle-vm-callback-log=%S/Inputs/layout.cblog -verify-each %s | FileCheck %s
;
; Scalar hash results must remain valid across aliases, loops, invokes and deopt.
target datalayout = "e-p:64:64-p1:64:64"
@arrayOopDesc.base_offset_in_bytes.byte = constant i32 16
@arrayOopDesc.base_offset_in_bytes.int = constant i32 16
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare i32 @jeandle.vectorized_hashcode(ptr addrspace(1), i32, i32, i32, i32)
declare i32 @__gxx_personality_v0(...)
declare void @observe(ptr addrspace(1))
declare void @safepoint()
; CHECK-LABEL: @consecutive_hashes(
; CHECK-NOT: call{{.*}} @jeandle.new_array
; CHECK-NOT: @jeandle.vectorized_hashcode
; CHECK: %[[M:.*]] = mul i32 %init, 31
; CHECK: %[[A:.*]] = add i32 %[[M]], 961
; CHECK: add i32 %[[A]], %init
; CHECK: ret i32
define i32 @consecutive_hashes(i32 %init, i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10004 to ptr), i32 1, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p = getelementptr i8, ptr addrspace(1) %a, i64 16
  store atomic i32 %init, ptr addrspace(1) %p unordered, align 4
  %r1 = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 1, i32 1, i32 10)
  %r2 = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 1, i32 %r1, i32 10)
  ret i32 %r2
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
; CHECK-LABEL: @hash_result_deopt(
; CHECK: mul i32 %n, 31
; CHECK: add i32 {{.*}}, %init
; CHECK: call void @safepoint()
; CHECK: ret i32
define i32 @hash_result_deopt(i32 %init, i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10004 to ptr), i32 1, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p = getelementptr i8, ptr addrspace(1) %a, i64 16
  store atomic i32 %init, ptr addrspace(1) %p unordered, align 4
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 1, i32 %n, i32 10)
  store atomic i32 %r, ptr addrspace(1) %p unordered, align 4
  call void @safepoint() [ "deopt"(i32 99, i32 99, i64 10, i32 %r, i64 4294967308, ptr addrspace(1) %a) ]
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
; CHECK-LABEL: @hash_own_bundle(
; CHECK: call{{.*}} @jeandle.new_array
; CHECK: call i32 @jeandle.vectorized_hashcode
; CHECK-SAME: "deopt"
; CHECK: ret i32
define i32 @hash_own_bundle(i32 %init, i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10004 to ptr), i32 1, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p = getelementptr i8, ptr addrspace(1) %a, i64 16
  store atomic i32 %init, ptr addrspace(1) %p unordered, align 4
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 1, i32 %n, i32 10) [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %a) ]
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
; CHECK-LABEL: @hash_alias_rounds(
; CHECK-NOT: call{{.*}} @jeandle.new_array
; CHECK-NOT: @jeandle.vectorized_hashcode
; CHECK: shl i32 %init, 5
; CHECK: ret i32
define i32 @hash_alias_rounds(i32 %init, i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10004 to ptr), i32 1, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p = getelementptr i8, ptr addrspace(1) %a, i64 16
  store atomic i32 %init, ptr addrspace(1) %p unordered, align 4
  %first = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 1, i32 0, i32 10)
  store atomic i32 %first, ptr addrspace(1) %p unordered, align 4
  %loaded = load atomic i32, ptr addrspace(1) %p unordered, align 4
  %second = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 1, i32 %loaded, i32 10)
  store atomic i32 %second, ptr addrspace(1) %p unordered, align 4
  %final = load atomic i32, ptr addrspace(1) %p unordered, align 4
  ret i32 %final
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @loop_init(
; CHECK-NOT: call{{.*}} @jeandle.new_array
; CHECK-NOT: @jeandle.vectorized_hashcode
; CHECK: phi i32
; CHECK: mul i32
; CHECK: add i32
; CHECK: ret i32
define i32 @loop_init(i32 %init, i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10004 to ptr), i32 1, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p = getelementptr i8, ptr addrspace(1) %a, i64 16
  store atomic i32 %init, ptr addrspace(1) %p unordered, align 4
  br label %loop
loop:
  %i = phi i32 [ 0, %work ], [ %next, %loop ]
  %h = phi i32 [ 1, %work ], [ %r, %loop ]
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 1, i32 %h, i32 10)
  %next = add i32 %i, 1
  %c = icmp ult i32 %next, %n
  br i1 %c, label %loop, label %exit
exit:
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @merge_scalar(
; CHECK-NOT: call{{.*}} @jeandle.new_array
; CHECK-NOT: @jeandle.vectorized_hashcode
; CHECK: {{phi|select}}
; CHECK: add i32
; CHECK: ret i32
define i32 @merge_scalar(i32 %init, i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10004 to ptr), i32 1, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p = getelementptr i8, ptr addrspace(1) %a, i64 16
  %c = icmp eq i32 %n, 0
  br i1 %c, label %left, label %right
left:
  store atomic i32 %init, ptr addrspace(1) %p unordered, align 4
  br label %join
right:
  store atomic i32 %n, ptr addrspace(1) %p unordered, align 4
  br label %join
join:
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 1, i32 1, i32 10)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @invoke_scalar(
; CHECK-NOT: call{{.*}} @jeandle.new_array
; CHECK-NOT: @jeandle.vectorized_hashcode
; CHECK: add i32 %init, 31
; CHECK: ret i32
define i32 @invoke_scalar(i32 %init, i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10004 to ptr), i32 1, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p = getelementptr i8, ptr addrspace(1) %a, i64 16
  store atomic i32 %init, ptr addrspace(1) %p unordered, align 4
  %r = invoke i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 1, i32 1, i32 10) to label %exit unwind label %u
exit:
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

!java-method-compilation = !{}
