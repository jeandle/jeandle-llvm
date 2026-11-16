; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Dynamic inspection requires a whole virtual object and an ordinary call
; without operand bundles. Retained calls keep their real object identity.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)
declare hotspotcc i1 @jeandle.check_klass_subtype(ptr, ptr) nounwind "gc-leaf-function"
declare void @publish(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define i1 @derived_receiver(ptr %super) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 5 to ptr), i32 24, i1 false)
      to label %normal unwind label %unwind
normal:
  %derived = getelementptr i8, ptr addrspace(1) %o, i64 8
  %r = call hotspotcc i1 @jeandle.check_instanceof(ptr %super, ptr addrspace(1) %derived)
  ret i1 %r
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i1 @derived_receiver(
; CHECK: %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NOT: call hotspotcc i1 @jeandle.check_klass_subtype
; CHECK: %r = call hotspotcc i1 @jeandle.check_instanceof(ptr %super, ptr addrspace(1) %derived)
; CHECK-NEXT: ret i1 %r

define i1 @published_receiver(ptr %super) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 5 to ptr), i32 24, i1 false)
      to label %normal unwind label %unwind
normal:
  call void @publish(ptr addrspace(1) %o)
  %r = call hotspotcc i1 @jeandle.check_instanceof(ptr %super, ptr addrspace(1) %o)
  ret i1 %r
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i1 @published_receiver(
; CHECK: %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: call void @publish(ptr addrspace(1) %o)
; CHECK-NEXT: %r = call hotspotcc i1 @jeandle.check_instanceof(ptr %super, ptr addrspace(1) %o)
; CHECK-NEXT: ret i1 %r

define i1 @deopt_bundle_on_query(ptr %super) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 5 to ptr), i32 24, i1 false)
      to label %normal unwind label %unwind
normal:
  %r = call hotspotcc i1 @jeandle.check_instanceof(ptr %super, ptr addrspace(1) %o) [ "deopt"(i32 3, i32 3, i64 12, ptr addrspace(1) %o) ]
  ret i1 %r
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i1 @deopt_bundle_on_query(
; CHECK: %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %r = call hotspotcc i1 @jeandle.check_instanceof(ptr %super, ptr addrspace(1) %o) [ "deopt"(i32 3, i32 3, i64 12, ptr addrspace(1) %o) ]
; CHECK-NEXT: ret i1 %r

define i1 @invoke_query(ptr %super) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 5 to ptr), i32 24, i1 false)
      to label %normal unwind label %unwind
normal:
  %r = invoke hotspotcc i1 @jeandle.check_instanceof(ptr %super, ptr addrspace(1) %o)
      to label %done unwind label %unwind
done:
  ret i1 %r
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i1 @invoke_query(
; CHECK: %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %r = invoke hotspotcc i1 @jeandle.check_instanceof(ptr %super, ptr addrspace(1) %o)
; CHECK-NEXT: to label %done unwind label %unwind
; CHECK: done:
; CHECK-NEXT: ret i1 %r

define hotspotcc i1 @musttail_query(ptr %super, ptr addrspace(1) %unused) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 5 to ptr), i32 24, i1 false)
      to label %normal unwind label %unwind
normal:
  %r = musttail call hotspotcc i1 @jeandle.check_instanceof(ptr %super, ptr addrspace(1) %o)
  ret i1 %r
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define hotspotcc i1 @musttail_query(
; CHECK: %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %r = musttail call hotspotcc i1 @jeandle.check_instanceof(ptr %super, ptr addrspace(1) %o)
; CHECK-NEXT: ret i1 %r

!java-method-compilation = !{}
