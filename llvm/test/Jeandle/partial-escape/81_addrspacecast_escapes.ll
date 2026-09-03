; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Only addrspace(1)→addrspace(1) casts preserve the virtual
; alias. Casting to addrspace(0) (or any other AS) crosses the Java-heap
; boundary and forces materialization. Test: alloc, cast to AS(0), pass to a
; non-AS sink. The allocation must survive the analysis pass as a
; retained OrigAlloc.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink_as0(ptr)
declare i32 @__gxx_personality_v0(...)

define void @test_addrspacecast_escape() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %as0 = addrspacecast ptr addrspace(1) %o to ptr
  call void @sink_as0(ptr %as0)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_addrspacecast_escape
; CHECK: %o = invoke {{.*}}@jeandle.new_instance
; CHECK-NOT: @jeandle.new_instance
; CHECK: %as0 = addrspacecast ptr addrspace(1) %o to ptr
; CHECK: call void @sink_as0(ptr %as0)

!java-method-compilation = !{}
