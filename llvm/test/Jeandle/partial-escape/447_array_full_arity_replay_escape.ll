; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Full-arity `jeandle.new_array` replay-on-escape regression test.
;
; PEA must retain the original invoke with its complete operand list when the
; array escapes. The transform replays tracked elements onto OrigAlloc; it
; never reconstructs a new array invoke at the escape point.
;
; Here the array is virtualized (the element store at element 0 folds into the
; virtual field state), then the array pointer itself escapes through @sink.
; The original invoke remains the sole allocation, and both the replayed store
; and @sink use %arr.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_array_full_arity_materialize_escape() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  ; (klass, length=4, size_in_bytes=64, base_offset=16, length_limit=1000000).
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 4, i32 64, i32 16, i32 1000000, i1 false, i1 false)
         to label %n unwind label %u
n:
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i32 16
  %p0 = getelementptr inbounds i32, ptr addrspace(1) %base, i64 0
  store atomic i32 100, ptr addrspace(1) %p0 unordered, align 4
  call void @sink(ptr addrspace(1) %arr)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_array_full_arity_materialize_escape
; The retained source invoke keeps the FULL operand list.
; CHECK: %arr = invoke hotspotcc{{.*}} @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 64, i32 16, i32 1000000, i1 false, i1 false)
; CHECK-NEXT: to label %{{.*}} unwind label %{{.*}}
; No second allocation may be emitted.
; CHECK-NOT: @jeandle.new_array
; The element store is replayed onto %arr and @sink receives %arr.
; CHECK: %[[SLOT:[A-Za-z0-9._]+]] = getelementptr inbounds i8, ptr addrspace(1) %arr, i64 16
; CHECK: store atomic i32 100, ptr addrspace(1) %[[SLOT]] unordered, align 4
; CHECK: call void @sink(ptr addrspace(1) %arr)

!java-method-compilation = !{}
