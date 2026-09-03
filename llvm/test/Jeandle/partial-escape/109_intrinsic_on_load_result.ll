; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Edge case: a primitive intrinsic (llvm.ctlz) consumes the result
; of a load from a virtual field. The load gets folded to a constant by
; PEA's ReplaceLoad effect; the intrinsic now has a constant input.
; PEA itself doesn't fold the intrinsic (downstream optimization will);
; the test simply verifies PEA leaves no broken intermediate values
; on the way to the intrinsic and that the load forwarding is clean.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @llvm.ctlz.i32(i32, i1 immarg)
declare i32 @__gxx_personality_v0(...)

define i32 @test_ctlz_on_load_result() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 255, ptr addrspace(1) %s unordered, align 4
  %v = load atomic i32, ptr addrspace(1) %s unordered, align 4
  %lz = call i32 @llvm.ctlz.i32(i32 %v, i1 false)
  ret i32 %lz
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Allocation eliminated; load forwarded to constant 255; the ctlz call
; remains, but its operand is now `i32 255`.
; CHECK-LABEL: define i32 @test_ctlz_on_load_result
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: %{{.*}} = call i32 @llvm.ctlz.i32(i32 255, i1 false)
; CHECK: ret i32

!java-method-compilation = !{}
