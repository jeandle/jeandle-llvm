; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; The retained original allocation invoke preserves its metadata and
; function/arg attrs. Because materialization keeps the original
; jeandle.new_instance invoke verbatim, the calling convention, the
; JavaKlass / JavaKlassExact / NonNull return attrs, plus !prof,
; !alias.scope, !noalias, custom Jeandle metadata, and function-level attrs
; (nofree, nosync, cold) all survive untouched.
;
; The test forces a materialization by passing the virtual to an opaque
; sink, then asserts the retained invoke still carries the
; frontend-attached !prof and !alias.scope metadata.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @meta_preserved() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u, !prof !0, !alias.scope !1
n:
  call void @sink(ptr addrspace(1) %o)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @meta_preserved
; The retained invoke must keep the !prof and !alias.scope metadata that the
; frontend attached to the original allocation.
; CHECK: invoke {{.*}}@jeandle.new_instance
; CHECK-NEXT: to label %{{.*}} unwind label %{{.*}}, !prof !{{[0-9]+}}, !alias.scope !{{[0-9]+}}

!java-method-compilation = !{}
!0 = !{!"branch_weights", i32 100}
!1 = !{!2}
!2 = distinct !{!2, !3, !"jeandle.scope.0"}
!3 = distinct !{!3, !"jeandle.scope.domain"}
