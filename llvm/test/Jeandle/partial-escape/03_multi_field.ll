; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA: allocate an object, store two distinct fields, load them
; back, and return their sum. Both fields are scalar-replaced and the
; allocation eliminated. The resulting function is `add %a, %b ; ret`.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)

declare i32 @__gxx_personality_v0(...)

define i32 @test_multi_field(i32 %a, i32 %b) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 24, i1 false)
       to label %n unwind label %u

n:
  %s1 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  %s2 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i32 %a, ptr addrspace(1) %s1 unordered, align 4
  store atomic i32 %b, ptr addrspace(1) %s2 unordered, align 4
  %v1 = load atomic i32, ptr addrspace(1) %s1 unordered, align 4
  %v2 = load atomic i32, ptr addrspace(1) %s2 unordered, align 4
  %sum = add i32 %v1, %v2
  ret i32 %sum

u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_multi_field
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: %sum = add i32 %a, %b
; CHECK: ret i32 %sum

!java-method-compilation = !{}
