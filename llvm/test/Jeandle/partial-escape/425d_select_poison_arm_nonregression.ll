; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; `select %c, %o, poison` refines poison to %o's defined whole-object
; identity. Freeze then preserves that resolved identity. A poison arm paired
; with a nonzero-offset or unknown arm does not establish whole-object
; identity.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_select_poison_arm(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
         to label %n unwind label %u
n:
  %f0 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 0
  store atomic i32 42, ptr addrspace(1) %f0 unordered, align 4
  %sel = select i1 %c, ptr addrspace(1) %o, ptr addrspace(1) poison
  %frozen = freeze ptr addrspace(1) %sel
  %r = load atomic i32, ptr addrspace(1) %frozen unordered, align 4
  call void @use(i32 %r)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_select_poison_arm
; CHECK-NOT: jeandle.new_instance
; CHECK: call{{.*}}@use(i32 42)

!java-method-compilation = !{}
