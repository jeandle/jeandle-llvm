; RUN: split-file %s %t
; RUN: opt -S -passes=character-intrinsic-specialization -verify-each %t/address-space.ll | FileCheck %s --check-prefix=KEEP
; RUN: opt -S -passes=character-intrinsic-specialization -verify-each %t/offset-width.ll | FileCheck %s --check-prefix=KEEP
; RUN: opt -S -passes=character-intrinsic-specialization -verify-each %t/result-width.ll | FileCheck %s --check-prefix=KEEP
; RUN: opt -S -passes=character-intrinsic-specialization -verify-each %t/variadic.ll | FileCheck %s --check-prefix=KEEP

; KEEP: call hotspotcc {{i32|i64}}{{.*}}@jeandle.count_positives
; KEEP-NEXT: ret

;--- address-space.ll
declare hotspotcc i32 @jeandle.count_positives(ptr, i32, i32)
define i32 @test(ptr %a) {
  %r = call hotspotcc i32 @jeandle.count_positives(ptr %a, i32 0, i32 1)
  ret i32 %r
}

;--- offset-width.ll
declare hotspotcc i32 @jeandle.count_positives(ptr addrspace(1), i64, i32)
define i32 @test(ptr addrspace(1) %a) {
  %r = call hotspotcc i32 @jeandle.count_positives(ptr addrspace(1) %a, i64 0, i32 1)
  ret i32 %r
}

;--- result-width.ll
declare hotspotcc i64 @jeandle.count_positives(ptr addrspace(1), i32, i32)
define i64 @test(ptr addrspace(1) %a) {
  %r = call hotspotcc i64 @jeandle.count_positives(ptr addrspace(1) %a, i32 0, i32 1)
  ret i64 %r
}

;--- variadic.ll
declare hotspotcc i32 @jeandle.count_positives(ptr addrspace(1), i32, i32, ...)
define i32 @test(ptr addrspace(1) %a) {
  %r = call hotspotcc i32 (ptr addrspace(1), i32, i32, ...) @jeandle.count_positives(ptr addrspace(1) %a, i32 0, i32 1)
  ret i32 %r
}
