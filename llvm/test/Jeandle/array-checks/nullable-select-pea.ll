; RUN: opt -S -verify-each -passes='jeandle<O3>' -jeandle-inline=off \
; RUN:   -jeandle-vm-callback-log=%S/Inputs/nullable-select-pea.cblog \
; RUN:   -jeandle-dump-pea-ir-function=nullable_array \
; RUN:   -jeandle-dump-pea-stats %s 2>&1 | FileCheck %s

; Scalar cleanup can turn a nullable array PHI into a select. Propagate the
; branch facts into both the arraylength argument and the deopt state before
; PEA observes the select as an escaping virtual identity.

declare hotspotcc noundef nonnull ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc i32 @jeandle.arraylength(ptr addrspace(1))
declare void @use(i32)
declare i32 @llvm.experimental.deoptimize.i32(...)
declare i32 @__gxx_personality_v0(...)
declare hotspotcc void @jeandle.pre_barrier(ptr addrspace(1))
declare hotspotcc void @jeandle.post_barrier(ptr addrspace(1), ptr addrspace(1))

define i32 @nullable_array(i1 noundef %choose) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %array = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
      ptr inttoptr (i64 12345 to ptr), i32 3, i32 32, i32 16, i32 262144, i1 false, i1 false)
      to label %body unwind label %unwind
body:
  %selected = select i1 %choose, ptr addrspace(1) null, ptr addrspace(1) %array
  br i1 %choose, label %fail, label %pass
pass:
  %length = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %selected)
  call void @use(i32 %length)
  ret i32 %length
fail:
  %deopt = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -10)
      [ "deopt"(i32 20, i32 20, i64 12, ptr addrspace(1) %array, i64 65548, ptr addrspace(1) %selected) ]
  ret i32 %deopt
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: ;; PEA-DUMP before iter=0 function nullable_array
; CHECK: %array = {{(call|invoke)}} hotspotcc {{.*}}@jeandle.new_array
; CHECK-NOT: select i1
; CHECK: %length = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1){{( nonnull)?}} %array)
; CHECK: "deopt"(i32 20, i32 20, i64 12, ptr addrspace(1) %array, i64 65548, ptr addrspace(1) null)
; CHECK: ;; PEA stats @nullable_array: NeverEscapes=1 PartiallyEscapes=0 AlwaysEscapes=0
; CHECK-LABEL: ;; PEA-DUMP after iter=0 function nullable_array
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.arraylength
; CHECK: call void @use(i32 3)
; CHECK: ret i32

!java-method-compilation = !{}
