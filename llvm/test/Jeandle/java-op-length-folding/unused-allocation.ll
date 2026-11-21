; RUN: opt -S -verify-each -passes=java-op-length-folding -jeandle-vm-callback-log=%S/../copy-specialization/Inputs/primitive-array-clone.cblog %s | FileCheck %s

declare ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare i32 @jeandle.arraylength(ptr addrspace(1))
declare void @observe(ptr addrspace(1))
declare void @state() nounwind
@personality = global ptr null

; CHECK-LABEL: define i32 @dynamic(
; CHECK: [[NEG:%.*]] = icmp slt i32 %n, 0
; CHECK: br i1 [[NEG]], label %{{.*}}, label %{{.*}}
; CHECK: call ptr addrspace(1) @jeandle.new_array
; CHECK: ret i32 %n
define i32 @dynamic(i32 %n, ptr %klass, i1 %flag) {
entry:
  %a = call ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 103 to ptr), i32 %n, i32 48, i32 16, i32 1000, i1 false, i1 false)
  %len = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  ret i32 %len
}

; CHECK-LABEL: define i32 @positive(
; CHECK-NOT: @jeandle.new_array
; CHECK: ret i32 %positive
define i32 @positive(i32 %n, ptr %klass, i1 %flag) {
entry:
  %positive = and i32 %n, 1023
  %a = call ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 103 to ptr), i32 %positive, i32 48, i32 16, i32 1000, i1 false, i1 false)
  %len = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  ret i32 %len
}

; CHECK-LABEL: define i32 @negative(
; CHECK: call ptr addrspace(1) @jeandle.new_array
; CHECK-NOT: icmp slt
; CHECK: ret i32 -1
define i32 @negative(i32 %n, ptr %klass, i1 %flag) {
entry:
  %a = call ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 103 to ptr), i32 -1, i32 48, i32 16, i32 1000, i1 false, i1 false)
  %len = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  ret i32 %len
}

; CHECK-LABEL: define i32 @wrapped(
; CHECK: [[NEG:%.*]] = icmp slt i32 %n, 0
; CHECK: br i1 [[NEG]], label %{{.*}}, label %{{.*}}
; CHECK: call ptr addrspace(1) @jeandle.new_array
; CHECK: ret i32 %n
define i32 @wrapped(i32 %n, ptr %klass, i1 %flag) {
entry:
  %a = call ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 104 to ptr), i32 %n, i32 48, i32 16, i32 1000, i1 false, i1 false)
  %fr = freeze ptr addrspace(1) %a
  %gep = getelementptr i8, ptr addrspace(1) %fr, i64 0
  %len = call i32 @jeandle.arraylength(ptr addrspace(1) %gep)
  ret i32 %len
}

; CHECK-LABEL: define i32 @live_deopt(
; CHECK: call ptr addrspace(1) @jeandle.new_array
; CHECK-NOT: icmp slt
; CHECK: ret i32 %n
define i32 @live_deopt(i32 %n, ptr %klass, i1 %flag) {
entry:
  %a = call ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 103 to ptr), i32 %n, i32 48, i32 16, i32 1000, i1 false, i1 false)
  call void @state() [ "deopt"(ptr addrspace(1) %a) ]
  %len = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  ret i32 %len
}

; CHECK-LABEL: define i32 @live_object(
; CHECK: call ptr addrspace(1) @jeandle.new_array
; CHECK-NOT: icmp slt
; CHECK: ret i32 %n
define i32 @live_object(i32 %n, ptr %klass, i1 %flag) {
entry:
  %a = call ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 103 to ptr), i32 %n, i32 48, i32 16, i32 1000, i1 false, i1 false)
  call void @observe(ptr addrspace(1) %a)
  %len = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  ret i32 %len
}

; CHECK-LABEL: define i32 @deferred(
; CHECK: call ptr addrspace(1) @jeandle.new_array
; CHECK-NOT: icmp slt
; CHECK: ret i32 %n
define i32 @deferred(i32 %n, ptr %klass, i1 %flag) {
entry:
  %a = call ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 103 to ptr), i32 %n, i32 48, i32 16, i32 1000, i1 false, i1 true)
  %len = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  ret i32 %len
}

; CHECK-LABEL: define i32 @unknown_klass(
; CHECK: call ptr addrspace(1) @jeandle.new_array
; CHECK-NOT: icmp slt
; CHECK: ret i32 %n
define i32 @unknown_klass(i32 %n, ptr %klass, i1 %flag) {
entry:
  %a = call ptr addrspace(1) @jeandle.new_array(ptr null, i32 %n, i32 48, i32 16, i32 1000, i1 false, i1 false)
  %len = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  ret i32 %len
}

; CHECK-LABEL: define i32 @dynamic_klass(
; CHECK: call ptr addrspace(1) @jeandle.new_array
; CHECK-NOT: icmp slt
; CHECK: ret i32 %n
define i32 @dynamic_klass(i32 %n, ptr %klass, i1 %flag) {
entry:
  %a = call ptr addrspace(1) @jeandle.new_array(ptr %klass, i32 %n, i32 48, i32 16, i32 1000, i1 false, i1 false)
  %len = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  ret i32 %len
}

; CHECK-LABEL: define i32 @uninitialized_reference(
; CHECK: call ptr addrspace(1) @jeandle.new_array
; CHECK-NOT: icmp slt
; CHECK: ret i32 %n
define i32 @uninitialized_reference(i32 %n, ptr %klass, i1 %flag) {
entry:
  %a = call ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 105 to ptr), i32 %n, i32 48, i32 16, i32 1000, i1 true, i1 false)
  %len = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  ret i32 %len
}

; CHECK-LABEL: define i32 @reference(
; CHECK: [[NEG:%.*]] = icmp slt i32 %n, 0
; CHECK: br i1 [[NEG]], label %{{.*}}, label %{{.*}}
; CHECK: call ptr addrspace(1) @jeandle.new_array
; CHECK: ret i32 %n
define i32 @reference(i32 %n, ptr %klass, i1 %flag) {
entry:
  %a = call ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 105 to ptr), i32 %n, i32 48, i32 16, i32 1000, i1 false, i1 false)
  %len = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  ret i32 %len
}

; CHECK-LABEL: define i32 @primitive_uninitialized(
; CHECK: [[NEG:%.*]] = icmp slt i32 %n, 0
; CHECK: br i1 [[NEG]], label %{{.*}}, label %{{.*}}
; CHECK: call ptr addrspace(1) @jeandle.new_array
; CHECK: ret i32 %n
define i32 @primitive_uninitialized(i32 %n, ptr %klass, i1 %flag) {
entry:
  %a = call ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 104 to ptr), i32 %n, i32 48, i32 16, i32 1000, i1 true, i1 false)
  %len = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  ret i32 %len
}

; CHECK-LABEL: define i32 @dynamic_flags(
; CHECK: call ptr addrspace(1) @jeandle.new_array
; CHECK-NOT: icmp slt
; CHECK: ret i32 %n
define i32 @dynamic_flags(i32 %n, ptr %klass, i1 %flag) {
entry:
  %a = call ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 103 to ptr), i32 %n, i32 48, i32 16, i32 1000, i1 %flag, i1 false)
  %len = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  ret i32 %len
}

; The normal PHI gains the bypass edge. Shared unwind PHIs retain the original
; allocation edge and the original deoptimization state is unchanged.
; CHECK-LABEL: define i32 @shared_eh(
; CHECK: [[NEG:%.*]] = icmp slt i32 %n, 0
; CHECK: br i1 [[NEG]], label %[[SLOW:.*]], label %normal
; CHECK: [[SLOW]]:
; CHECK: invoke ptr addrspace(1) @jeandle.new_array{{.*}}[ "deopt"(i32 17) ]
; CHECK: normal:
; CHECK: phi i32 [ 7, %[[SLOW]] ], [ 7, %allocate ]
; CHECK: ret i32 %n
define i32 @shared_eh(i32 %n, i1 %c) personality ptr @personality {
entry:
  br i1 %c, label %allocate, label %other
allocate:
  %a = invoke ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 103 to ptr), i32 %n, i32 48, i32 16, i32 1000, i1 false, i1 false) [ "deopt"(i32 17) ] to label %normal unwind label %eh
normal:
  %p = phi i32 [7, %allocate]
  %len = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  ret i32 %len
other:
  invoke void @observe(ptr addrspace(1) null) to label %end unwind label %eh
end:
  ret i32 0
eh:
  %origin = phi i32 [17, %allocate], [18, %other]
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

!java-method-compilation = !{}
