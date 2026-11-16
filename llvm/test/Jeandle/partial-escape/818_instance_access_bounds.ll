; RUN: opt -S -verify-each -passes='partial-escape-iterative' %s | FileCheck %s
; RUN: opt -S -verify-each -passes='partial-escape-iterative,partial-escape-iterative' %s | FileCheck %s
;
; A profile-inlined implementation can access a field beyond a different
; receiver's layout on an infeasible branch. That field must not enter the
; virtual state: merging its default onto the feasible branch would introduce
; a replay write into the following object's header. Keep unsupported accesses
; real on their original paths, including default reads and crossing accesses.
target datalayout = "e-p:64:64-p1:64:64-p3:32:32"
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare ptr addrspace(1) @next()
declare void @publish(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

; CHECK-LABEL: define void @infeasible_other_layout(
; CHECK: @jeandle.new_instance
; CHECK: store atomic ptr addrspace(1) %array,
; CHECK-NOT: getelementptr {{.*}} i64 40
; CHECK: call void @publish(ptr addrspace(1) %object)
; CHECK-NOT: getelementptr {{.*}} i64 40
; CHECK: ret void
define void @infeasible_other_layout(ptr addrspace(1) %array) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %object = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 12345 to ptr), i32 40, i1 false) to label %init unwind label %unwind
init:
  %index = getelementptr inbounds i8, ptr addrspace(1) %object, i64 12
  store atomic i32 0, ptr addrspace(1) %index unordered, align 4
  %elements = getelementptr inbounds i8, ptr addrspace(1) %object, i64 32
  store atomic ptr addrspace(1) %array, ptr addrspace(1) %elements unordered, align 8
  %value = load atomic i32, ptr addrspace(1) %index unordered, align 4
  %masked = and i32 %value, 64
  %other_layout = icmp ne i32 %masked, 0
  br i1 %other_layout, label %other, label %merge
other:
  %iterator = call ptr addrspace(1) @next()
  %phantom = getelementptr inbounds i8, ptr addrspace(1) %object, i64 40
  store atomic ptr addrspace(1) %iterator, ptr addrspace(1) %phantom unordered, align 8
  br label %merge
merge:
  call void @publish(ptr addrspace(1) %object)
  ret void
unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define i64 @crossing_default_read(
; CHECK: @jeandle.new_instance
; CHECK: %field = getelementptr inbounds{{.*}} i8, ptr addrspace(1) %object, i64 36
; CHECK: %value = load atomic i64, ptr addrspace(1) %field unordered, align 4
; CHECK: ret i64 %value
define i64 @crossing_default_read() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %object = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 12345 to ptr), i32 40, i1 false) to label %access unwind label %unwind
access:
  %field = getelementptr inbounds i8, ptr addrspace(1) %object, i64 36
  %value = load atomic i64, ptr addrspace(1) %field unordered, align 4
  ret i64 %value
unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}


; CHECK-LABEL: define ptr addrspace(3) @valid_narrow_tail(
; CHECK-NEXT: entry:
; CHECK-NEXT: ret ptr addrspace(3) %input
define ptr addrspace(3) @valid_narrow_tail(ptr addrspace(3) %input) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %object = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 12345 to ptr), i32 40, i1 false) to label %access unwind label %unwind
access:
  %field = getelementptr inbounds i8, ptr addrspace(1) %object, i64 36
  store atomic ptr addrspace(3) %input, ptr addrspace(1) %field unordered, align 4
  %value = load atomic ptr addrspace(3), ptr addrspace(1) %field unordered, align 4
  ret ptr addrspace(3) %value
unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define <2 x i64> @valid_vector_tail(
; CHECK-NEXT: entry:
; CHECK-NEXT: ret <2 x i64> %input
define <2 x i64> @valid_vector_tail(<2 x i64> %input) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %object = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 12345 to ptr), i32 40, i1 false) to label %access unwind label %unwind
access:
  %field = getelementptr inbounds i8, ptr addrspace(1) %object, i64 24
  store <2 x i64> %input, ptr addrspace(1) %field, align 8
  %value = load <2 x i64>, ptr addrspace(1) %field, align 8
  ret <2 x i64> %value
unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

!java-method-compilation = !{}
