; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Compressed-oops module gate: when the module DataLayout
; describes a narrow-oop address space (p3 narrower than p1, as the frontend
; emits under UseCompressedOops), PartialEscapeAnalysis returns an empty
; result and PEA leaves the function completely untouched — even an
; obviously-dead allocation survives. This keeps the DEFAULT VM
; configuration (compressed oops on) correct until TODO(compressed-oop)
; lands.

target datalayout = "e-p:64:64:64-p1:64:64:64-p3:32:32:32"

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define void @test_unused_alloc() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
         to label %normal unwind label %unwind

normal:
  ret void

unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; PEA is idle on this module: the dead allocation invoke is retained verbatim.
; CHECK-LABEL: define void @test_unused_alloc()
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: ret void

!java-method-compilation = !{}
