; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Case C may merge different allocations only when no source identity remains
; observable.  LLVM can carry an allocation's identity through several
; pointer wrappers before it reaches a comparison, so checking only the
; allocation's direct users is insufficient.
;
; With opaque pointers, a same-address-space pointer bitcast is not legal IR,
; and addrspacecast requires distinct address spaces.  A Java-heap identity
; therefore has no verifier-valid bitcast/addrspacecast spelling here.  The
; legal identity wrappers exercised below are freeze, offset-zero GEP, and
; multi-level combinations of them.  The conservative cases cover merge
; wrappers and derived addresses.

target datalayout = "e-p:64:64-p1:64:64"

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @safepoint()
declare ptr addrspace(1) @llvm.ptr.annotation.p1.p0(ptr addrspace(1), ptr, ptr, i32, ptr)
declare i32 @__gxx_personality_v0(...)

@.annotation = private constant [4 x i8] c"pea\00"
@.file = private constant [4 x i8] c"pea\00"

define i1 @observable_zero_gep_freeze(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %after.a unwind label %unwind
after.a:
  %alias0 = getelementptr i8, ptr addrspace(1) %a, i64 0
  %alias1 = freeze ptr addrspace(1) %alias0
  %alias2 = getelementptr i8, ptr addrspace(1) %alias1, i64 0
  br i1 %c, label %left, label %right
left:
  br label %merge
right:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
           [ "deopt"(i32 26, i32 26, i64 12, ptr addrspace(1) %a) ]
       to label %right.cont unwind label %unwind
right.cont:
  br label %merge
merge:
  %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right.cont ]
  %same = icmp eq ptr addrspace(1) %alias2, %p
  ret i1 %same
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i1 @observable_zero_gep_freeze(
; CHECK-COUNT-2: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %[[P:.*]] = phi ptr addrspace(1)
; CHECK: %[[SAME:.*]] = icmp eq ptr addrspace(1) %{{.*}}, %[[P]]
; CHECK: ret i1 %[[SAME]]
; CHECK-NOT: pea.casec.field.phi

define i1 @observable_annotation_alias(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %after.a unwind label %unwind
after.a:
  %alias = call ptr addrspace(1) @llvm.ptr.annotation.p1.p0(
               ptr addrspace(1) %a, ptr @.annotation, ptr @.file,
               i32 0, ptr null)
  br i1 %c, label %left, label %right
left:
  br label %merge
right:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %right.cont unwind label %unwind
right.cont:
  br label %merge
merge:
  %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right.cont ]
  %same = icmp eq ptr addrspace(1) %alias, %p
  ret i1 %same
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i1 @observable_annotation_alias(
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %[[ANN:.*]] = call ptr addrspace(1) @llvm.ptr.annotation
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %[[P:.*]] = phi ptr addrspace(1)
; CHECK: %[[SAME:.*]] = icmp eq ptr addrspace(1) %[[ANN]], %[[P]]
; CHECK: ret i1 %[[SAME]]
; CHECK-NOT: pea.casec.field.phi

define i1 @observable_ordinary_phi(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %after.a unwind label %unwind
after.a:
  br i1 %c, label %left, label %right
left:
  br label %merge
right:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %right.cont unwind label %unwind
right.cont:
  br label %merge
merge:
  %alias.phi = phi ptr addrspace(1) [ %a, %left ], [ %a, %right.cont ]
  %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right.cont ]
  %same = icmp eq ptr addrspace(1) %alias.phi, %p
  ret i1 %same
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i1 @observable_ordinary_phi(
; CHECK-COUNT-2: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %[[ALIAS:.*]] = phi ptr addrspace(1)
; CHECK: %[[P:.*]] = phi ptr addrspace(1)
; CHECK: %[[SAME:.*]] = icmp eq ptr addrspace(1) %[[ALIAS]], %[[P]]
; CHECK: ret i1 %[[SAME]]
; CHECK-NOT: pea.casec.field.phi

define i1 @observable_select(i1 %c, i1 %pick)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %after.a unwind label %unwind
after.a:
  %alias = select i1 %pick, ptr addrspace(1) %a, ptr addrspace(1) %a
  br i1 %c, label %left, label %right
left:
  br label %merge
right:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %right.cont unwind label %unwind
right.cont:
  br label %merge
merge:
  %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right.cont ]
  %same = icmp eq ptr addrspace(1) %alias, %p
  ret i1 %same
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i1 @observable_select(
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %[[ALIAS:.*]] = select i1 %pick, ptr addrspace(1) %{{.*}}, ptr addrspace(1) %{{.*}}
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %[[P:.*]] = phi ptr addrspace(1)
; CHECK: %[[SAME:.*]] = icmp eq ptr addrspace(1) %[[ALIAS]], %[[P]]
; CHECK: ret i1 %[[SAME]]
; CHECK-NOT: pea.casec.field.phi

define i1 @observable_derived_geps(i1 %c, i64 %offset)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
       to label %after.a unwind label %unwind
after.a:
  %nonzero = getelementptr i8, ptr addrspace(1) %a, i64 8
  %unknown = getelementptr i8, ptr addrspace(1) %a, i64 %offset
  br i1 %c, label %left, label %right
left:
  br label %merge
right:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
       to label %right.cont unwind label %unwind
right.cont:
  br label %merge
merge:
  %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right.cont ]
  %same.nonzero = icmp eq ptr addrspace(1) %nonzero, %p
  %same.unknown = icmp eq ptr addrspace(1) %unknown, %p
  %both = and i1 %same.nonzero, %same.unknown
  ret i1 %both
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i1 @observable_derived_geps(
; CHECK-COUNT-2: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: icmp eq ptr addrspace(1) %nonzero, %{{.*}}
; CHECK: icmp eq ptr addrspace(1) %unknown, %{{.*}}
; CHECK-NOT: pea.casec.field.phi

define i32 @compatible_wrapped_field_access(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %left unwind label %unwind
left:
  %alias0 = getelementptr i8, ptr addrspace(1) %a, i64 0
  %alias1 = freeze ptr addrspace(1) %alias0
  store i32 7, ptr addrspace(1) %alias1, align 4
  br i1 %c, label %merge, label %right
right:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
           [ "deopt"(i32 26, i32 26, i64 12, ptr addrspace(1) %a) ]
       to label %right.cont unwind label %unwind
right.cont:
  store i32 13, ptr addrspace(1) %b, align 4
  br label %merge
merge:
  %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right.cont ]
  %value = load i32, ptr addrspace(1) %p, align 4
  ret i32 %value
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @compatible_wrapped_field_access(
; CHECK-NOT: jeandle.new_instance
; CHECK: %pea.casec.field.phi = phi i32 [ 7, %{{.*}} ], [ 13, %{{.*}} ]
; CHECK-NOT: store i32
; CHECK-NOT: load i32
; CHECK: ret i32 %pea.casec.field.phi

define i32 @compatible_annotation_field_access(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 12345 to ptr), i32 24, i1 false)
       to label %left unwind label %unwind
left:
  %a.field = getelementptr i8, ptr addrspace(1) %a, i64 8
  %a.ann = call ptr addrspace(1) @llvm.ptr.annotation.p1.p0(
               ptr addrspace(1) %a.field, ptr @.annotation, ptr @.file,
               i32 0, ptr null)
  store i32 7, ptr addrspace(1) %a.ann, align 4
  br i1 %c, label %merge, label %right
right:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 12345 to ptr), i32 24, i1 false)
       to label %right.cont unwind label %unwind
right.cont:
  %b.field = getelementptr i8, ptr addrspace(1) %b, i64 8
  %b.ann = call ptr addrspace(1) @llvm.ptr.annotation.p1.p0(
               ptr addrspace(1) %b.field, ptr @.annotation, ptr @.file,
               i32 0, ptr null)
  store i32 13, ptr addrspace(1) %b.ann, align 4
  br label %merge
merge:
  %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right.cont ]
  %field = getelementptr i8, ptr addrspace(1) %p, i64 8
  %value = load i32, ptr addrspace(1) %field, align 4
  ret i32 %value
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @compatible_annotation_field_access(
; CHECK-NOT: jeandle.new_instance
; CHECK: %pea.casec.field.phi = phi i32 [ 7, %{{.*}} ], [ 13, %{{.*}} ]
; CHECK-NOT: store i32
; CHECK-NOT: load i32
; CHECK: ret i32 %pea.casec.field.phi

; Instruction-form ptrtoint is an identity observation in PEA. Even when its
; only pointer result is a same-width round-trip, instruction dispatch first
; materializes the virtual at ptrtoint; the structural resolver's round-trip
; support does not promise virtualization across this boundary.
define i1 @observable_ptrtoint_roundtrip(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %after.a unwind label %unwind
after.a:
  %bits = ptrtoint ptr addrspace(1) %a to i64
  %alias = inttoptr i64 %bits to ptr addrspace(1)
  br i1 %c, label %left, label %right
left:
  br label %merge
right:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %right.cont unwind label %unwind
right.cont:
  br label %merge
merge:
  %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right.cont ]
  %same = icmp eq ptr addrspace(1) %alias, %p
  ret i1 %same
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i1 @observable_ptrtoint_roundtrip(
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: ptrtoint ptr addrspace(1)
; CHECK: inttoptr i64
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %[[P:.*]] = phi ptr addrspace(1)
; CHECK: icmp eq ptr addrspace(1) %{{.*}}, %[[P]]
; CHECK-NOT: pea.casec.field.phi

; The same conservative boundary applies when the round-tripped pointer has
; only a field access. Supporting this compatible shape would require proving
; that every integer use belongs exclusively to the reversible chain.
define i32 @compatible_ptrtoint_boundary(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %after.a unwind label %unwind
after.a:
  %bits = ptrtoint ptr addrspace(1) %a to i64
  %alias = inttoptr i64 %bits to ptr addrspace(1)
  store i32 7, ptr addrspace(1) %alias, align 4
  br i1 %c, label %left, label %right
left:
  br label %merge
right:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %right.cont unwind label %unwind
right.cont:
  store i32 13, ptr addrspace(1) %b, align 4
  br label %merge
merge:
  %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right.cont ]
  %value = load i32, ptr addrspace(1) %p, align 4
  ret i32 %value
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @compatible_ptrtoint_boundary(
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: ptrtoint ptr addrspace(1)
; CHECK: inttoptr i64
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %[[P:.*]] = phi ptr addrspace(1)
; CHECK: load i32, ptr addrspace(1) %[[P]]
; CHECK-NOT: pea.casec.field.phi

; The safepoint join has a side entry, so the Case-C PHI does not dominate it.
; It is nevertheless reachable after the merge without re-executing %a.  Its
; frame state can therefore reconstruct the source identity after Case C and
; must make the merge ineligible.
define i32 @post_merge_deopt_side_entry(i1 %c, i1 %bypass)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %after.a unwind label %unwind
after.a:
  store i32 7, ptr addrspace(1) %a, align 4
  br i1 %bypass, label %bypass.path, label %choose
choose:
  br i1 %c, label %left, label %right
left:
  br label %merge
right:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %right.cont unwind label %unwind
right.cont:
  store i32 13, ptr addrspace(1) %b, align 4
  br label %merge
merge:
  %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right.cont ]
  %value = load i32, ptr addrspace(1) %p, align 4
  br label %join
bypass.path:
  br label %join
join:
  %result = phi i32 [ 0, %bypass.path ], [ %value, %merge ]
  call void @safepoint()
       [ "deopt"(i32 50, i32 50, i64 12, ptr addrspace(1) %a) ]
  ret i32 %result
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @post_merge_deopt_side_entry(
; CHECK-COUNT-2: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %[[P:.*]] = phi ptr addrspace(1)
; CHECK: load i32, ptr addrspace(1) %[[P]]
; CHECK: call void @safepoint()
; CHECK-NOT: pea.casec.field.phi

!java-method-compilation = !{}
