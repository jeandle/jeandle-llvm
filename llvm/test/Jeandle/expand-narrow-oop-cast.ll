; RUN: opt -S -passes=expand-narrow-oop-cast %s | FileCheck %s
; RUN: opt -S -passes='expand-narrow-oop-cast,rewrite-statepoints-for-gc,verify' %s | FileCheck --check-prefix=GC %s

declare hotspotcc ptr addrspace(3) @jeandle.encode_heap_oop(ptr addrspace(1))
declare hotspotcc ptr addrspace(1) @jeandle.decode_heap_oop(ptr addrspace(3)) #1
declare hotspotcc void @deoptimize()
declare void @observe(ptr addrspace(1))
declare void @safepoint()

define hotspotcc i1 @compare_eq(ptr addrspace(3) %lhs, ptr addrspace(3) %rhs) #0 {
; CHECK-LABEL: @compare_eq(
; CHECK-NEXT:  entry:
; CHECK-NEXT:    [[CMP:%.*]] = icmp eq ptr addrspace(3) %lhs, %rhs
; CHECK-NEXT:    ret i1 [[CMP]]
entry:
  %lhs.decoded = addrspacecast ptr addrspace(3) %lhs to ptr addrspace(1)
  %rhs.decoded = addrspacecast ptr addrspace(3) %rhs to ptr addrspace(1)
  %cmp = icmp eq ptr addrspace(1) %lhs.decoded, %rhs.decoded
  ret i1 %cmp
}

define hotspotcc i1 @compare_ne(ptr addrspace(3) %lhs, ptr addrspace(3) %rhs) #0 {
; CHECK-LABEL: @compare_ne(
; CHECK-NEXT:  entry:
; CHECK-NEXT:    [[CMP:%.*]] = icmp ne ptr addrspace(3) %lhs, %rhs
; CHECK-NEXT:    ret i1 [[CMP]]
entry:
  %lhs.decoded = addrspacecast ptr addrspace(3) %lhs to ptr addrspace(1)
  %rhs.decoded = addrspacecast ptr addrspace(3) %rhs to ptr addrspace(1)
  %cmp = icmp ne ptr addrspace(1) %lhs.decoded, %rhs.decoded
  ret i1 %cmp
}

define hotspotcc i1 @compare_with_regular_use(ptr addrspace(3) %lhs,
                                               ptr addrspace(3) %rhs) #0 {
; CHECK-LABEL: @compare_with_regular_use(
; CHECK-NEXT:  entry:
; CHECK-NEXT:    [[LHS_DECODED:%.*]] = call hotspotcc ptr addrspace(1) @jeandle.decode_heap_oop(ptr addrspace(3) %lhs)
; CHECK-NEXT:    [[CMP:%.*]] = icmp eq ptr addrspace(3) %lhs, %rhs
; CHECK-NEXT:    call void @observe(ptr addrspace(1) [[LHS_DECODED]])
; CHECK-NEXT:    ret i1 [[CMP]]
entry:
  %lhs.decoded = addrspacecast ptr addrspace(3) %lhs to ptr addrspace(1)
  %rhs.decoded = addrspacecast ptr addrspace(3) %rhs to ptr addrspace(1)
  %cmp = icmp eq ptr addrspace(1) %lhs.decoded, %rhs.decoded
  call void @observe(ptr addrspace(1) %lhs.decoded)
  ret i1 %cmp
}

define hotspotcc ptr addrspace(1) @keep_non_comparison_use(ptr addrspace(3) %value) #0 {
; CHECK-LABEL: @keep_non_comparison_use(
; CHECK-NEXT:  entry:
; CHECK-NEXT:    [[DECODED:%.*]] = call hotspotcc ptr addrspace(1) @jeandle.decode_heap_oop(ptr addrspace(3) %value)
; CHECK-NEXT:    ret ptr addrspace(1) [[DECODED]]
entry:
  %decoded = addrspacecast ptr addrspace(3) %value to ptr addrspace(1)
  ret ptr addrspace(1) %decoded
}

define hotspotcc void @sink_deopt_only_decode(ptr addrspace(3) %value, i1 %condition) #0 {
; CHECK-LABEL: @sink_deopt_only_decode(
; CHECK:       deopt:
; CHECK-NEXT:    [[DECODED:%.*]] = call hotspotcc ptr addrspace(1) @jeandle.decode_heap_oop(ptr addrspace(3) %value)
; CHECK-NEXT:    call hotspotcc void @deoptimize() [ "deopt"(ptr addrspace(1) [[DECODED]]) ]
entry:
  %decoded = addrspacecast ptr addrspace(3) %value to ptr addrspace(1)
  br i1 %condition, label %deopt, label %exit

deopt:
  call hotspotcc void @deoptimize() [ "deopt"(ptr addrspace(1) %decoded) ]
  br label %exit

exit:
  ret void
}

define hotspotcc void @share_decode_between_bundle_uses(
    ptr addrspace(3) %value, i1 %condition) #0 {
; CHECK-LABEL: @share_decode_between_bundle_uses(
; CHECK:       deopt:
; CHECK-NEXT:    [[DECODED:%.*]] = call hotspotcc ptr addrspace(1) @jeandle.decode_heap_oop(ptr addrspace(3) %value)
; CHECK-NEXT:    call hotspotcc void @deoptimize() [ "deopt"(ptr addrspace(1) [[DECODED]], ptr addrspace(1) [[DECODED]]) ]
entry:
  %decoded = addrspacecast ptr addrspace(3) %value to ptr addrspace(1)
  br i1 %condition, label %deopt, label %exit

deopt:
  call hotspotcc void @deoptimize()
      [ "deopt"(ptr addrspace(1) %decoded, ptr addrspace(1) %decoded) ]
  br label %exit

exit:
  ret void
}

define hotspotcc void @keep_non_deopt_bundle(ptr addrspace(3) %value,
                                              i1 %condition) #0 {
; CHECK-LABEL: @keep_non_deopt_bundle(
; CHECK:       entry:
; CHECK-NEXT:    [[DECODED:%.*]] = call hotspotcc ptr addrspace(1) @jeandle.decode_heap_oop(ptr addrspace(3) %value)
; CHECK-NEXT:    br i1 %condition, label %bundle, label %exit
; CHECK:       bundle:
; CHECK-NEXT:    call hotspotcc void @deoptimize() [ "not-deopt"(ptr addrspace(1) [[DECODED]]) ]
entry:
  %decoded = addrspacecast ptr addrspace(3) %value to ptr addrspace(1)
  br i1 %condition, label %bundle, label %exit

bundle:
  call hotspotcc void @deoptimize() [ "not-deopt"(ptr addrspace(1) %decoded) ]
  br label %exit

exit:
  ret void
}

define hotspotcc void @split_regular_and_deopt_uses(ptr addrspace(3) %value,
                                                     i1 %condition) #0 {
; CHECK-LABEL: @split_regular_and_deopt_uses(
; CHECK:       entry:
; CHECK-NEXT:    [[REGULAR:%.*]] = call hotspotcc ptr addrspace(1) @jeandle.decode_heap_oop(ptr addrspace(3) %value)
; CHECK-NEXT:    br i1 %condition, label %use, label %exit
; CHECK:       use:
; CHECK-NEXT:    [[DEOPT:%.*]] = call hotspotcc ptr addrspace(1) @jeandle.decode_heap_oop(ptr addrspace(3) %value)
; CHECK-NEXT:    call void @observe(ptr addrspace(1) [[REGULAR]]) [ "deopt"(ptr addrspace(1) [[DEOPT]]) ]
entry:
  %decoded = addrspacecast ptr addrspace(3) %value to ptr addrspace(1)
  br i1 %condition, label %use, label %exit

use:
  call void @observe(ptr addrspace(1) %decoded)
      [ "deopt"(ptr addrspace(1) %decoded) ]
  br label %exit

exit:
  ret void
}

define hotspotcc void @sink_decode_across_safepoint(ptr addrspace(3) %value,
                                                      i1 %condition) #0
    gc "hotspotgc" {
; GC-LABEL: @sink_decode_across_safepoint(
; GC:       @safepoint
; GC-SAME:  "gc-live"(ptr addrspace(3) %value)
; GC:       [[RELOCATED:%.*]] = call coldcc ptr addrspace(3) @llvm.experimental.gc.relocate
; GC:       deopt:
; GC:       @jeandle.decode_heap_oop(ptr addrspace(3) [[RELOCATED]])
entry:
  %decoded = addrspacecast ptr addrspace(3) %value to ptr addrspace(1)
  call void @safepoint()
  br i1 %condition, label %deopt, label %exit

deopt:
  call hotspotcc void @deoptimize()
      [ "deopt"(ptr addrspace(1) %decoded) ]
  br label %exit

exit:
  ret void
}

attributes #0 = { "java-method" "use-compressed-oops" }
attributes #1 = { "gc-leaf-function" }

!java-method-compilation = !{}
