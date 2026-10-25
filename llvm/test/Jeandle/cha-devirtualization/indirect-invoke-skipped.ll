; RUN: opt -S -passes="function(cha-devirtualization)" -jeandle-vm-callback-log=%S/Inputs/indirect-invoke-skipped.cblog %s 2>&1 | FileCheck %s

; An invoke carrying java call-site attributes is not necessarily a direct
; java call: legal IR can attach the attributes to an indirect callee or to a
; call without a receiver argument. Such sites must be skipped gracefully —
; not dereference the missing callee or read a nonexistent receiver operand.

@jeandle.personality = global ptr null

define void @test(ptr addrspace(1) %recv, ptr %fptr) gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  invoke void %fptr(ptr addrspace(1) %recv) #0
          to label %cont unwind label %pad

cont:
  ret void

pad:
  %lp1 = landingpad i8 cleanup
  unreachable
}

define void @no_receiver(ptr %fptr) gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  invoke void %fptr() #0
          to label %cont unwind label %pad

cont:
  ret void

pad:
  %lp2 = landingpad i8 cleanup
  unreachable
}

; Both invokes are left untouched.
; CHECK: invoke void %fptr(ptr addrspace(1) %recv) #0
; CHECK: invoke void %fptr() #0

attributes #0 = { "bytecode"="invokevirtual" }

!java-method-compilation = !{}
