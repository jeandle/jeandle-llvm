; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA reuse-OrigAlloc model: alloc + store + load (folded to the stored
; constant) + use of the load + escape. The load fold survives the escape:
; %v becomes the constant 99 (so use_int gets a constant, consumed before the
; escape). The ORIGINAL allocation (OrigAlloc) is kept alive; PEA replays the
; tracked field store onto OrigAlloc immediately before the escape point (the
; @sink call), and the sink consumes OrigAlloc directly.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use_int(i32)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_load_then_escape() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 99, ptr addrspace(1) %s unordered, align 4
  %v = load atomic i32, ptr addrspace(1) %s unordered, align 4
  call void @use_int(i32 %v)
  call void @sink(ptr addrspace(1) %o)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_load_then_escape
; The original allocation invoke is RETAINED — exactly one new_instance.
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NOT: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; The load folds to the stored constant.
; CHECK: call void @use_int(i32 99)
; The tracked field store is replayed onto OrigAlloc before the escape.
; CHECK: %pea.matslot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
; CHECK: store atomic i32 99, ptr addrspace(1) %pea.matslot unordered, align 4
; The sink consumes OrigAlloc directly.
; CHECK: call void @sink(ptr addrspace(1) %o)

!java-method-compilation = !{}
