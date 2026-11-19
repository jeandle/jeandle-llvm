; RUN: split-file %s %t
; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" %t/missing.ll | FileCheck %s
; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" %t/signature.ll | FileCheck %s
; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" %t/calling-convention.ll | FileCheck %s
; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" %t/not-leaf.ll | FileCheck %s
; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" %t/may-throw.ll | FileCheck %s

; A missing or incompatible helper cannot introduce a new call or safepoint.
; CHECK-LABEL: define i1 @test(
; CHECK: %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NOT: call {{.*}}@jeandle.check_klass_subtype
; CHECK: %r = call hotspotcc i1 @jeandle.check_instanceof(ptr %super, ptr addrspace(1) %o)
; CHECK-NEXT: ret i1 %r

;--- missing.ll
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)

declare i32 @__gxx_personality_v0(...)

define i1 @test(ptr %super) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 5 to ptr), i32 16, i1 false)
      to label %normal unwind label %unwind
normal:
  %r = call hotspotcc i1 @jeandle.check_instanceof(ptr %super, ptr addrspace(1) %o)
  ret i1 %r
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

!java-method-compilation = !{}

;--- signature.ll
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)
declare hotspotcc i32 @jeandle.check_klass_subtype(ptr, ptr) nounwind "gc-leaf-function"
declare i32 @__gxx_personality_v0(...)

define i1 @test(ptr %super) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 5 to ptr), i32 16, i1 false)
      to label %normal unwind label %unwind
normal:
  %r = call hotspotcc i1 @jeandle.check_instanceof(ptr %super, ptr addrspace(1) %o)
  ret i1 %r
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

!java-method-compilation = !{}

;--- calling-convention.ll
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)
declare i1 @jeandle.check_klass_subtype(ptr, ptr) nounwind "gc-leaf-function"
declare i32 @__gxx_personality_v0(...)

define i1 @test(ptr %super) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 5 to ptr), i32 16, i1 false)
      to label %normal unwind label %unwind
normal:
  %r = call hotspotcc i1 @jeandle.check_instanceof(ptr %super, ptr addrspace(1) %o)
  ret i1 %r
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

!java-method-compilation = !{}

;--- not-leaf.ll
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)
declare hotspotcc i1 @jeandle.check_klass_subtype(ptr, ptr) nounwind
declare i32 @__gxx_personality_v0(...)

define i1 @test(ptr %super) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 5 to ptr), i32 16, i1 false)
      to label %normal unwind label %unwind
normal:
  %r = call hotspotcc i1 @jeandle.check_instanceof(ptr %super, ptr addrspace(1) %o)
  ret i1 %r
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

!java-method-compilation = !{}

;--- may-throw.ll
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)
declare hotspotcc i1 @jeandle.check_klass_subtype(ptr, ptr) "gc-leaf-function"
declare i32 @__gxx_personality_v0(...)

define i1 @test(ptr %super) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 5 to ptr), i32 16, i1 false)
      to label %normal unwind label %unwind
normal:
  %r = call hotspotcc i1 @jeandle.check_instanceof(ptr %super, ptr addrspace(1) %o)
  ret i1 %r
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

!java-method-compilation = !{}
