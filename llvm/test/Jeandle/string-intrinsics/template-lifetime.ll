; RUN: opt -S -passes='jeandle-inline-driver,globaldce' -jeandle-vm-callback-log=%S/Inputs/template-lifetime.cblog -verify-each %s | FileCheck %s --check-prefix=LIVE
; RUN: opt -S -passes='jeandle-inline-driver,globaldce,java-operation-lower<phase=1>,java-operation-lower<phase=9>,java-operation-deletion' -jeandle-vm-callback-log=%S/Inputs/template-lifetime.cblog -verify-each %s | FileCheck %s --check-prefix=LOWER
;
; A replayed callee introduces the only reference to the private phase-1 op.
; Definitions needed by later barrier insertion remain rooted by llvm.used;
; externally linked runtime operations remain available for name lookup.

@jeandle.personality = global ptr null
@llvm.used = appending global [1 x ptr] [ptr @jeandle.late_barrier], section "llvm.metadata"

define hotspotcc i32 @root() #0 gc "hotspotgc" personality ptr @jeandle.personality {
  %slot = alloca i64, align 8
  %r = call hotspotcc i32 @callee_example() #2 [ "deopt"(i32 0, i32 0, i64 327695, ptr %slot) ]
  ret i32 %r
}
declare hotspotcc i32 @callee_example() #1 gc "hotspotgc"

define private hotspotcc i32 @jeandle.example_op() #3 {
  %r = call hotspotcc i32 @jeandle.live_helper()
  ret i32 %r
}
define private hotspotcc i32 @jeandle.live_helper() #3 { ret i32 4242 }
define private hotspotcc i32 @jeandle.dead_op() #3 {
  %r = call hotspotcc i32 @jeandle.dead_helper()
  ret i32 %r
}
define private hotspotcc i32 @jeandle.dead_helper() #3 { ret i32 17 }
define private hotspotcc void @jeandle.late_barrier() #4 { ret void }
define hotspotcc void @jeandle.runtime_operation() #3 { ret void }

attributes #0 = { "java-method"="1" }
attributes #1 = { "java-method"="101" }
attributes #2 = { "monomorphic-target" }
attributes #3 = { "lower-phase"="1" noinline }
attributes #4 = { "lower-phase"="9" noinline }
!java-method-compilation = !{}
!static-call-patch-size = !{!0}
!0 = !{i32 5}

; LIVE: @llvm.used = {{.*}}@jeandle.late_barrier
; LIVE-LABEL: define hotspotcc i32 @root(
; LIVE: call {{.*}}@jeandle.example_op()
; LIVE: define private hotspotcc i32 @jeandle.example_op()
; LIVE: define private hotspotcc i32 @jeandle.live_helper()
; LIVE-NOT: @jeandle.dead_
; LIVE: define private hotspotcc void @jeandle.late_barrier()
; LIVE: define hotspotcc void @jeandle.runtime_operation()
; LOWER-LABEL: define hotspotcc i32 @root(
; LOWER: ret i32 4242
; LOWER-NOT: define {{.*}}@jeandle.
