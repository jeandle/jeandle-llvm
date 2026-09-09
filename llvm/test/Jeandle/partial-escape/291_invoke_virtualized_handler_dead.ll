; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Exception edge state splitting — when an invoke is virtualized
; away by processJavaOp (e.g. jeandle.arraylength on a virtual array
; folds to a compile-time constant), the analyzer emits a ReplaceCall
; effect on the InvokeInst. The transform rewrites that invoke as an
; unconditional branch to the normal dest, dropping the unwind edge.
;
; The analyzer detects this and marks the pred's unwind edge "killed",
; so contributionFor reports the edge dead when the handler asks for its
; pred's contribution. The handler therefore inherits NO virtual state from
; this pred — references to virtuals registered upstream do NOT resolve
; in the handler and so do NOT trigger materialization.
;
; Without the killed-edge handling: the handler would inherit n2's
; post-block state (VO_A still virtual + VO_A's IR alias intact); the
; @sink(%a) call inside the handler would force VO_A to materialize,
; which would in turn keep VO_A's allocation invoke in the output IR.
; With the killed-edge handling the handler is unreachable for analysis
; and VO_A's allocation is cleanly eliminated.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) readonly)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define i32 @test_291() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 7, i32 44, i32 16, i32 1048576)
         to label %n unwind label %u_arr
n:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 54321 to ptr), i32 16, i1 false)
       to label %n2 unwind label %u_a
n2:
  ; This invoke is folded by processJavaOp (foldArrayLength) into the
  ; compile-time constant 7, emitting a ReplaceCall effect on the invoke.
  ; The transform replaces the invoke with `br label %normal`, which
  ; drops the unwind edge into %handler.
  %len = invoke hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %arr)
              to label %normal unwind label %handler
normal:
  ret i32 %len
handler:
  %lp = landingpad i64 cleanup
  ; This @sink call would (without killed-edge handling) materialize
  ; VO_A at the handler; with it, the handler inherits no virtual state
  ; from n2 (killed unwind edge) and the call is a no-op for PEA. After
  ; EliminateAllocation the %a operand is RAUW'd to poison and the
  ; handler block is unreachable.
  call void @sink(ptr addrspace(1) %a)
  resume i64 %lp
u_arr:
  %lpr = landingpad i64 cleanup
  resume i64 %lpr
u_a:
  %lpa = landingpad i64 cleanup
  resume i64 %lpa
}

; All three jeandle allocations / fold targets must disappear:
; - VO_arr (klass 12345) — only used by the folded array_length.
; - VO_A   (klass 54321) — only used inside the now-dead handler.
; - The array_length call/invoke folds to the constant 7.
; CHECK-LABEL: define i32 @test_291
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: jeandle.new_instance(ptr inttoptr (i64 54321 to ptr), i32 16)
; CHECK-NOT: jeandle.arraylength
; CHECK: ret i32 7

!java-method-compilation = !{}
