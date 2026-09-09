; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; a switch instruction whose condition is a load from a virtual's i32
; field. processLoad resolves the load to the stored constant (1) and RAUWs
; the load. The transform's post-Pass-2 ConstantFoldTerminator then collapses
; the switch on a constant condition into an unconditional `br label %case1`.
; Allocation is eliminated; the dead arms are pruned by the trivially-dead
; sweep.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_switch_on_virtual(i32 %x) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 1, ptr addrspace(1) %s unordered, align 4
  %v = load atomic i32, ptr addrspace(1) %s unordered, align 4
  switch i32 %v, label %dflt [ i32 0, label %case0
                               i32 1, label %case1
                               i32 2, label %case2 ]
case0:
  call void @use(i32 0)
  br label %end
case1:
  call void @use(i32 100)
  br label %end
case2:
  call void @use(i32 200)
  br label %end
dflt:
  call void @use(i32 999)
  br label %end
end:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_switch_on_virtual
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: load atomic
; CHECK-NOT: switch i32
; CHECK: call void @use(i32 100)
; CHECK: ret void

!java-method-compilation = !{}
