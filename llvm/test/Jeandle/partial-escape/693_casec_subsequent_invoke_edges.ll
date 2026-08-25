; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s

; A subsequently-real Case-C identity keeps each source allocation at its
; original site, including its allocation-site deopt bundle.  No source replay
; is inserted around invoke edges.  The merged current state is replayed once
; onto the Case-C pointer PHI at the actual escape, on either a normal or an
; exceptional merge.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1) nounwind
declare void @may_throw()
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @casec_invoke_normal(i1 %choose)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %choose, label %left, label %right
left:
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69301 to ptr), i32 16, i1 false) [ "deopt"(i32 693011) ]
  %af = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic i32 41, ptr addrspace(1) %af unordered, align 4
  invoke void @may_throw()
      to label %merge unwind label %unwind
right:
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69301 to ptr), i32 16, i1 false) [ "deopt"(i32 693012) ]
  %bf = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic i32 42, ptr addrspace(1) %bf unordered, align 4
  invoke void @may_throw()
      to label %merge unwind label %unwind
merge:
  %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
  call void @sink(ptr addrspace(1) %p)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @casec_invoke_normal(
; CHECK: left:
; CHECK-NOT: store atomic i32 41
; CHECK: %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance{{.*}}[ "deopt"(i32 693011) ]
; CHECK: invoke void @may_throw()
; CHECK-NEXT: to label %merge unwind label %unwind
; CHECK: right:
; CHECK-NOT: store atomic i32 42
; CHECK: %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance{{.*}}[ "deopt"(i32 693012) ]
; CHECK: invoke void @may_throw()
; CHECK-NEXT: to label %merge unwind label %unwind
; CHECK: merge:
; CHECK-NEXT: %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
; CHECK-NEXT: %[[FIELD:pea.casec.field.phi[^ ]*]] = phi i32 [ 41, %left ], [ 42, %right ]
; CHECK-NEXT: %[[SLOT:pea.matslot[^ ]*]] = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
; CHECK-NEXT: store atomic i32 %[[FIELD]], ptr addrspace(1) %[[SLOT]] unordered, align 4
; CHECK-NEXT: call void @sink(ptr addrspace(1) %p)
; CHECK-NOT: store atomic i32 41
; CHECK-NOT: store atomic i32 42
; CHECK-NOT: store atomic
; CHECK-NOT: call void @sink
; CHECK-NOT: poison

define void @casec_invoke_unwind(i1 %choose)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %choose, label %left, label %right
left:
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69302 to ptr), i32 16, i1 false) [ "deopt"(i32 693021) ]
  %af = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic i32 51, ptr addrspace(1) %af unordered, align 4
  invoke void @may_throw()
      to label %normal.left unwind label %handler
normal.left:
  ret void
right:
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69302 to ptr), i32 16, i1 false) [ "deopt"(i32 693022) ]
  %bf = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic i32 52, ptr addrspace(1) %bf unordered, align 4
  invoke void @may_throw()
      to label %normal.right unwind label %handler
normal.right:
  ret void
handler:
  %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
  %lp = landingpad i64 cleanup
  call void @sink(ptr addrspace(1) %p)
  resume i64 %lp
}

; CHECK-LABEL: define void @casec_invoke_unwind(
; CHECK: left:
; CHECK-NOT: store atomic i32 51
; CHECK: %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance{{.*}}[ "deopt"(i32 693021) ]
; CHECK: invoke void @may_throw()
; CHECK-NEXT: to label %normal.left unwind label %handler
; CHECK: right:
; CHECK-NOT: store atomic i32 52
; CHECK: %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance{{.*}}[ "deopt"(i32 693022) ]
; CHECK: invoke void @may_throw()
; CHECK-NEXT: to label %normal.right unwind label %handler
; CHECK: handler:
; CHECK-NEXT: %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
; CHECK-NEXT: %[[UFIELD:pea.casec.field.phi[^ ]*]] = phi i32 [ 51, %left ], [ 52, %right ]
; CHECK-NEXT: %[[LP:[^ ]+]] = landingpad i64
; CHECK-NEXT: cleanup
; CHECK-NEXT: %[[USLOT:pea.matslot[^ ]*]] = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
; CHECK-NEXT: store atomic i32 %[[UFIELD]], ptr addrspace(1) %[[USLOT]] unordered, align 4
; CHECK-NEXT: call void @sink(ptr addrspace(1) %p)
; CHECK-NEXT: resume i64 %[[LP]]
; CHECK-NOT: store atomic i32 51
; CHECK-NOT: store atomic i32 52
; CHECK-NOT: store atomic
; CHECK-NOT: call void @sink
; CHECK-NOT: poison

!java-method-compilation = !{}
