; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; `jeandle.assume_java_type` changes only the Java klass carried by its result.
; PEA must preserve the virtual identity through the marker so the following
; field access remains scalar-replaceable, then erase the identity marker.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc ptr addrspace(1) @jeandle.assume_java_type(ptr addrspace(1))

declare i32 @__gxx_personality_v0(...)

define i32 @test_assume_java_type() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
         to label %normal unwind label %unwind

normal:
  %typed = call hotspotcc ptr addrspace(1) @jeandle.assume_java_type(
      ptr addrspace(1) %obj)
  %slot = getelementptr inbounds i8, ptr addrspace(1) %typed, i64 8
  store atomic i32 42, ptr addrspace(1) %slot unordered, align 4
  %value = load atomic i32, ptr addrspace(1) %slot unordered, align 4
  ret i32 %value

unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_assume_java_type()
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: jeandle.assume_java_type
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: ret i32 42

!java-method-compilation = !{}
