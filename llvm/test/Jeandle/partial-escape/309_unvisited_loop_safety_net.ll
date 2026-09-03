; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; The safety-net materializePreheaderVirtualsForUnvisitedLoops only
; fires on loops processLoop never touched. The expected case is an
; unreachable loop that the RPO walk skipped. Construct one by making
; the top-level CFG fall through to %exit unconditionally; the loop %hdr
; / %body / %latch is structurally a valid LoopInfo loop but is
; statically unreachable from %entry. The safety net is a no-op because
; nothing virtual flowed into the unreachable preheader. The function
; still compiles cleanly and the unreachable region survives until a
; later canonicalisation drops it.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define i32 @test_unvisited(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br label %exit

; ----------- unreachable loop -----------
preheader:
  br label %hdr
hdr:
  %p = phi ptr addrspace(1) [null, %preheader], [%p, %latch]
  %c = icmp slt i32 %n, 0
  br i1 %c, label %body, label %exit
body:
  br label %latch
latch:
  br label %hdr

exit:
  ret i32 0
}

; CHECK-LABEL: define i32 @test_unvisited
; CHECK: ret i32 0

!java-method-compilation = !{}
