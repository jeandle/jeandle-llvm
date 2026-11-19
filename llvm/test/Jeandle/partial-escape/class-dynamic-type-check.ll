; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform,instcombine" %s | FileCheck %s

; A dynamic target needs the allocation's exact Klass, not an object header.
; Publication and failed-cast calls still require the original object identity.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)
declare hotspotcc i1 @jeandle.check_klass_subtype(ptr, ptr) nounwind "gc-leaf-function"
declare void @publish(ptr addrspace(1))
declare void @cast_failed(ptr addrspace(1))
declare void @safepoint(i1)
declare i32 @__gxx_personality_v0(...)

define i1 @dynamic_instance(ptr %super) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 5 to ptr), i32 16, i1 false)
      to label %normal unwind label %unwind
normal:
  %r = call hotspotcc i1 @jeandle.check_instanceof(ptr %super, ptr addrspace(1) %o)
  ret i1 %r
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i1 @dynamic_instance(
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: jeandle.check_instanceof
; CHECK: [[R:%.*]] = call hotspotcc i1 @jeandle.check_klass_subtype(ptr{{( nonnull)?}} inttoptr (i64 5 to ptr), ptr %super)
; CHECK-NEXT: ret i1 [[R]]

define i1 @dynamic_alias_phi(ptr %super, i1 %condition) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 5 to ptr), i32 16, i1 false)
      to label %normal unwind label %unwind
normal:
  br i1 %condition, label %left, label %right
left:
  br label %merge
right:
  br label %merge
merge:
  %alias = phi ptr addrspace(1) [ %o, %left ], [ %o, %right ]
  %r = call hotspotcc i1 @jeandle.check_instanceof(ptr %super, ptr addrspace(1) %alias)
  ret i1 %r
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i1 @dynamic_alias_phi(
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: jeandle.check_instanceof
; CHECK: [[R:%.*]] = call hotspotcc i1 @jeandle.check_klass_subtype(ptr{{( nonnull)?}} inttoptr (i64 5 to ptr), ptr %super)
; CHECK-NEXT: ret i1 [[R]]

define i1 @dynamic_array(ptr %super) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 6 to ptr), i32 2, i32 24, i32 16, i32 1048576, i1 false, i1 false)
      to label %normal unwind label %unwind
normal:
  %r = call hotspotcc i1 @jeandle.check_instanceof(ptr %super, ptr addrspace(1) %o)
  ret i1 %r
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i1 @dynamic_array(
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: jeandle.check_instanceof
; CHECK: [[R:%.*]] = call hotspotcc i1 @jeandle.check_klass_subtype(ptr{{( nonnull)?}} inttoptr (i64 6 to ptr), ptr %super)
; CHECK-NEXT: ret i1 [[R]]

define i32 @dynamic_cast(ptr %super) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 5 to ptr), i32 16, i1 false)
      to label %normal unwind label %unwind
normal:
  %field = getelementptr i8, ptr addrspace(1) %o, i64 8
  store atomic i32 37, ptr addrspace(1) %field unordered, align 4
  %r = call hotspotcc i1 @jeandle.check_instanceof(ptr %super, ptr addrspace(1) %o)
  br i1 %r, label %success, label %failure
success:
  %alias = freeze ptr addrspace(1) %o
  %alias.field = getelementptr i8, ptr addrspace(1) %alias, i64 8
  %value = load atomic i32, ptr addrspace(1) %alias.field unordered, align 4
  %same = icmp eq ptr addrspace(1) %alias, %o
  %result = select i1 %same, i32 %value, i32 -1
  ret i32 %result
failure:
  call void @cast_failed(ptr addrspace(1) %o) [ "deopt"(i32 7, i32 7, i64 12, ptr addrspace(1) %o) ]
  ret i32 -2
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @dynamic_cast(
; CHECK: %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: jeandle.check_instanceof
; CHECK: [[R:%.*]] = call hotspotcc i1 @jeandle.check_klass_subtype(ptr{{( nonnull)?}} inttoptr (i64 5 to ptr), ptr %super)
; CHECK-NEXT: br i1 [[R]], label %success, label %failure
; CHECK: success:
; CHECK-NOT: load atomic
; CHECK: ret i32 37
; CHECK: failure:
; CHECK: store atomic i32 37,
; CHECK: call void @cast_failed(ptr addrspace(1) %o) [ "deopt"(i32 7, i32 7, i64 12, ptr addrspace(1) %o) ]

define i1 @dynamic_publish(ptr %super) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 5 to ptr), i32 16, i1 false)
      to label %normal unwind label %unwind
normal:
  %r = call hotspotcc i1 @jeandle.check_instanceof(ptr %super, ptr addrspace(1) %o)
  call void @publish(ptr addrspace(1) %o)
  ret i1 %r
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i1 @dynamic_publish(
; CHECK: %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NOT: jeandle.check_instanceof
; CHECK: [[R:%.*]] = call hotspotcc i1 @jeandle.check_klass_subtype(ptr{{( nonnull)?}} inttoptr (i64 5 to ptr), ptr %super)
; CHECK-NEXT: call void @publish(ptr addrspace(1) %o)
; CHECK-NEXT: ret i1 [[R]]

define i32 @dynamic_deopt(ptr %super, i32 %value) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 5 to ptr), i32 16, i1 false)
      to label %normal unwind label %unwind
normal:
  %field = getelementptr i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %value, ptr addrspace(1) %field unordered, align 4
  %alias = freeze ptr addrspace(1) %o
  %r = call hotspotcc i1 @jeandle.check_instanceof(ptr %super, ptr addrspace(1) %alias)
  call void @safepoint(i1 %r) [ "deopt"(i32 9, i32 9, i64 12, ptr addrspace(1) %o, i64 4294967308, ptr addrspace(1) %alias) ]
  %result = load atomic i32, ptr addrspace(1) %field unordered, align 4
  ret i32 %result
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @dynamic_deopt(
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: jeandle.check_instanceof
; CHECK: [[R:%.*]] = call hotspotcc i1 @jeandle.check_klass_subtype(ptr{{( nonnull)?}} inttoptr (i64 5 to ptr), ptr %super)
; CHECK-NEXT: call void @safepoint(i1 [[R]]) [ "deopt"(i32 9, i32 9, i64 262156, i64 5, i32 1, i64 34359738378, i32 %value, i64 524300, i32 0, i64 524300, i32 0) ]
; CHECK-NOT: load atomic
; CHECK-NEXT: ret i32 %value

; The constant-target proof remains conservative without a subtype callback.
define i1 @unknown_constant_relation() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 5 to ptr), i32 16, i1 false)
      to label %normal unwind label %unwind
normal:
  %r = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 99 to ptr), ptr addrspace(1) %o)
  ret i1 %r
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i1 @unknown_constant_relation(
; CHECK: %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %r = call hotspotcc i1 @jeandle.check_instanceof(ptr{{( nonnull)?}} inttoptr (i64 99 to ptr), ptr addrspace(1) %o)
; CHECK-NEXT: ret i1 %r

!java-method-compilation = !{}
