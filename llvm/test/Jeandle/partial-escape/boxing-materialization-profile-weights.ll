; RUN: opt -S -passes='box-materialization-lowering,function(instcombine),function(simplifycfg),verify' %s | FileCheck %s

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1, i1)

define hotspotcc ptr addrspace(1) @jeandle.box(
    i32 %kind, ptr %klass, i64 %raw,
    ptr addrspace(1) %cache, ptr addrspace(1) %unused,
    i64 %low, i64 %length, i1 %has_cache)
    noinline "lower-phase"="2" {
entry:
  switch i32 %kind, label %invalid [
    i32 4, label %cached
  ]

cached:
  %index = sub i64 %raw, %low
  %in.range = icmp ult i64 %index, %length
  br i1 %in.range, label %box.cache_hit, label %box.cache_miss

box.cache_hit:
  ret ptr addrspace(1) %cache

box.cache_miss:
  %allocated = call hotspotcc ptr addrspace(1)
      @jeandle.new_instance(ptr %klass, i32 16, i1 false, i1 false)
  ret ptr addrspace(1) %allocated

invalid:
  unreachable
}

define hotspotcc ptr addrspace(1) @profiled_box(
    ptr %klass, i64 %value, ptr addrspace(1) %cache) {
entry:
  %box = call hotspotcc ptr addrspace(1) @jeandle.box(
      i32 4, ptr %klass, i64 %value,
      ptr addrspace(1) %cache, ptr addrspace(1) null,
      i64 -128, i64 256, i1 true),
      !box-cache-branch-weights !0
  ret ptr addrspace(1) %box
}

; CHECK-LABEL: define hotspotcc ptr addrspace(1) @profiled_box(
; CHECK-NOT: call hotspotcc ptr addrspace(1) @jeandle.box
; CHECK: icmp ult i64
; CHECK: br i1 {{.*}}, label {{.*}}, label {{.*}}, !prof ![[WEIGHTS:[0-9]+]]
; CHECK: call hotspotcc ptr addrspace(1) @jeandle.new_instance

define hotspotcc ptr addrspace(1) @speculated_box(
    ptr %klass, i64 %value, ptr addrspace(1) %cache) {
entry:
  %box = call hotspotcc ptr addrspace(1) @jeandle.box(
      i32 4, ptr %klass, i64 %value,
      ptr addrspace(1) %cache, ptr addrspace(1) null,
      i64 -128, i64 256, i1 true)
      [ "deopt"(i32 7) ],
      !box-cache-branch-weights !1
  ret ptr addrspace(1) %box
}

; CHECK-LABEL: define hotspotcc ptr addrspace(1) @speculated_box(
; CHECK-NOT: call hotspotcc ptr addrspace(1) @jeandle.box
; CHECK: icmp ult i64
; CHECK: br i1 {{.*}}, label {{.*}}, label %box.cache_miss.unstable_if, !prof ![[SPEC_WEIGHTS:[0-9]+]]
; CHECK: box.cache_miss.unstable_if:
; CHECK: call hotspotcc ptr addrspace(1) (...) @llvm.experimental.deoptimize.p1(i32 {{-?[0-9]+}}) [ "deopt"(i32 7) ]
; CHECK-NOT: call hotspotcc ptr addrspace(1) @jeandle.new_instance

; The inliner may recursively delete an instruction whose only use was the
; original box's deopt bundle. The lowering must anchor the replacement deopt
; call before inlining so this operand remains live.
define hotspotcc ptr addrspace(1) @speculated_box_deopt_only(
    ptr %klass, i64 %value, ptr addrspace(1) %cache) {
entry:
  %deopt.only = trunc i64 %value to i32
  %box = call hotspotcc ptr addrspace(1) @jeandle.box(
      i32 4, ptr %klass, i64 %value,
      ptr addrspace(1) %cache, ptr addrspace(1) null,
      i64 -128, i64 256, i1 true)
      [ "deopt"(i32 %deopt.only) ],
      !box-cache-branch-weights !1
  ret ptr addrspace(1) %box
}

; CHECK-LABEL: define hotspotcc ptr addrspace(1) @speculated_box_deopt_only(
; CHECK: box.cache_miss.unstable_if:
; CHECK: %deopt.only = trunc i64 %value to i32
; CHECK: call hotspotcc ptr addrspace(1) (...) @llvm.experimental.deoptimize.p1(i32 {{-?[0-9]+}}) [ "deopt"(i32 %deopt.only) ]
; CHECK: ![[WEIGHTS]] = !{!"branch_weights", i32 91, i32 9}
; CHECK: ![[SPEC_WEIGHTS]] = !{!"branch_weights", i32 100, i32 1}

!0 = !{i32 91, i32 9, i1 false}
!1 = !{i32 100, i32 1, i1 true}
