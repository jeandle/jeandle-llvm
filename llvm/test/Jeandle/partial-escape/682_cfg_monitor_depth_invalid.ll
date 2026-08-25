; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s -o %t
; RUN: FileCheck %s < %t

; The monitor-depth model is an edge-sensitive property of the current CFG.
; Invalid models conservatively retain monitor operations, but they do not
; disable scalar replacement of an unrelated unlocked object in the same
; function.  Valid invoke and OSR cases remain optimizable.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1) nounwind
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr)
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr)
declare void @may_throw()
declare i32 @__gxx_personality_v0(...)
declare i32 @__CxxFrameHandler3(...)

; Incoming relative depths disagree at %merge (free=0, held=1), even though
; each dynamic path exits with balanced locking.
define i32 @invalid_conflicting_merge(i1 %take.lock) gc "hotspotgc" {
entry:
  %lock.slot = alloca i64, align 8
  %lock = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68201 to ptr), i32 16, i1 false)
  %scalar = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68202 to ptr), i32 16, i1 false)
  %scalar.slot = getelementptr inbounds i8, ptr addrspace(1) %scalar, i64 8
  store atomic i32 73, ptr addrspace(1) %scalar.slot unordered, align 4
  %value = load atomic i32, ptr addrspace(1) %scalar.slot unordered, align 4
  br i1 %take.lock, label %held, label %free
held:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %lock, ptr %lock.slot) nounwind
  br label %merge
free:
  br label %merge
merge:
  %is.held = phi i1 [ true, %held ], [ false, %free ]
  br i1 %is.held, label %unlock, label %done
unlock:
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %lock, ptr %lock.slot) nounwind
  br label %done
done:
  ret i32 %value
}

; CHECK-LABEL: define i32 @invalid_conflicting_merge(
; CHECK-NOT: inttoptr (i64 68202 to ptr)
; CHECK: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
; CHECK: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
; CHECK: ret i32 73

; An ordinary root cannot consume an interpreter-held monitor.  The first
; operation therefore underflows at entry depth zero.
define i32 @invalid_underflow(ptr addrspace(1) %preheld) gc "hotspotgc" {
entry:
  %preheld.slot = alloca i64, align 8
  %scalar = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68203 to ptr), i32 16, i1 false)
  %scalar.slot = getelementptr inbounds i8, ptr addrspace(1) %scalar, i64 8
  store atomic i32 73, ptr addrspace(1) %scalar.slot unordered, align 4
  %value = load atomic i32, ptr addrspace(1) %scalar.slot unordered, align 4
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %preheld, ptr %preheld.slot) nounwind
  ret i32 %value
}

; CHECK-LABEL: define i32 @invalid_underflow(
; CHECK-NOT: inttoptr (i64 68203 to ptr)
; CHECK: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
; CHECK: ret i32 73

; A call-form monitor operation without nounwind has an unrepresented
; exceptional edge.  It cannot participate in virtual monitor elimination.
define i32 @invalid_maythrow_call_monitor() gc "hotspotgc" {
entry:
  %lock.slot = alloca i64, align 8
  %lock = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68204 to ptr), i32 16, i1 false)
  %scalar = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68205 to ptr), i32 16, i1 false)
  %scalar.slot = getelementptr inbounds i8, ptr addrspace(1) %scalar, i64 8
  store atomic i32 73, ptr addrspace(1) %scalar.slot unordered, align 4
  %value = load atomic i32, ptr addrspace(1) %scalar.slot unordered, align 4
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %lock, ptr %lock.slot)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %lock, ptr %lock.slot)
  ret i32 %value
}

; CHECK-LABEL: define i32 @invalid_maythrow_call_monitor()
; CHECK-NOT: inttoptr (i64 68205 to ptr)
; CHECK: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
; CHECK-NEXT: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
; CHECK: ret i32 73

; invoke monitorenter increments only its normal edge.  Its unwind edge sees
; the pre-enter depth and is already balanced at resume.
define void @valid_invoke_enter_edges() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %lock.slot = alloca i64, align 8
  %lock = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68206 to ptr), i32 16, i1 false)
  invoke hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %lock, ptr %lock.slot)
      to label %normal unwind label %unwind
normal:
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %lock, ptr %lock.slot) nounwind
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @valid_invoke_enter_edges()
; CHECK-NOT: inttoptr (i64 68206 to ptr)
; CHECK-NOT: @jeandle.monitor
; CHECK: ret void

; invoke monitorexit decrements only its normal edge.  On unwind the lock is
; still held, so the handler's call-form exit balances the resume edge.
define void @valid_invoke_exit_edges() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %lock.slot = alloca i64, align 8
  %lock = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68207 to ptr), i32 16, i1 false)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %lock, ptr %lock.slot) nounwind
  invoke hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %lock, ptr %lock.slot)
      to label %normal unwind label %unwind
normal:
  ret void
unwind:
  %lp = landingpad i64 cleanup
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %lock, ptr %lock.slot) nounwind
  resume i64 %lp
}

; CHECK-LABEL: define void @valid_invoke_exit_edges()
; CHECK-NOT: inttoptr (i64 68207 to ptr)
; CHECK-NOT: @jeandle.monitor
; CHECK: ret void

; A resume is a real function exit.  The unwind edge below retains the depth
; held before @may_throw and therefore makes the whole monitor model invalid.
define i32 @invalid_resume_exit() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %lock.slot = alloca i64, align 8
  %lock = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68219 to ptr), i32 16, i1 false)
  %scalar = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68220 to ptr), i32 16, i1 false)
  %scalar.slot = getelementptr inbounds i8, ptr addrspace(1) %scalar, i64 8
  store atomic i32 73, ptr addrspace(1) %scalar.slot unordered, align 4
  %value = load atomic i32, ptr addrspace(1) %scalar.slot unordered, align 4
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %lock, ptr %lock.slot) nounwind
  invoke void @may_throw() to label %normal unwind label %unwind
normal:
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %lock, ptr %lock.slot) nounwind
  ret i32 %value
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @invalid_resume_exit()
; CHECK-NOT: inttoptr (i64 68220 to ptr)
; CHECK: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
; CHECK: resume i64 %lp

; A cleanupret that unwinds to the caller is a real exit.  Reaching it while
; a monitor is held invalidates the model.
define i32 @invalid_cleanupret_exit() gc "hotspotgc"
    personality ptr @__CxxFrameHandler3 {
entry:
  %lock.slot = alloca i64, align 8
  %lock = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68208 to ptr), i32 16, i1 false)
  %scalar = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68209 to ptr), i32 16, i1 false)
  %scalar.slot = getelementptr inbounds i8, ptr addrspace(1) %scalar, i64 8
  store atomic i32 73, ptr addrspace(1) %scalar.slot unordered, align 4
  %value = load atomic i32, ptr addrspace(1) %scalar.slot unordered, align 4
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %lock, ptr %lock.slot) nounwind
  invoke void @may_throw() to label %normal unwind label %cleanup
normal:
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %lock, ptr %lock.slot) nounwind
  ret i32 %value
cleanup:
  %cp = cleanuppad within none []
  cleanupret from %cp unwind to caller
}

; CHECK-LABEL: define i32 @invalid_cleanupret_exit()
; CHECK-NOT: inttoptr (i64 68209 to ptr)
; CHECK: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
; CHECK: cleanupret from %cp unwind to caller

; A catchswitch unwind-to-caller edge is likewise a real exit at the depth
; entering the dispatch block.
define i32 @invalid_catchswitch_exit() gc "hotspotgc"
    personality ptr @__CxxFrameHandler3 {
entry:
  %lock.slot = alloca i64, align 8
  %lock = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68210 to ptr), i32 16, i1 false)
  %scalar = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68211 to ptr), i32 16, i1 false)
  %scalar.slot = getelementptr inbounds i8, ptr addrspace(1) %scalar, i64 8
  store atomic i32 73, ptr addrspace(1) %scalar.slot unordered, align 4
  %value = load atomic i32, ptr addrspace(1) %scalar.slot unordered, align 4
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %lock, ptr %lock.slot) nounwind
  invoke void @may_throw() to label %normal unwind label %dispatch
normal:
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %lock, ptr %lock.slot) nounwind
  ret i32 %value
dispatch:
  %cs = catchswitch within none [label %catch] unwind to caller
catch:
  %cp = catchpad within %cs [ptr null, i32 0, ptr null]
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %lock, ptr %lock.slot) [ "funclet"(token %cp) ]
  catchret from %cp to label %caught
caught:
  ret i32 %value
}

; CHECK-LABEL: define i32 @invalid_catchswitch_exit()
; CHECK-NOT: inttoptr (i64 68211 to ptr)
; CHECK: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
; CHECK: %cs = catchswitch within none [label %catch] unwind to caller

; An ordinary root must have depth zero at every return.
define i32 @invalid_ordinary_unbalanced_exit() gc "hotspotgc" {
entry:
  %lock.slot = alloca i64, align 8
  %lock = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68212 to ptr), i32 16, i1 false)
  %scalar = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68213 to ptr), i32 16, i1 false)
  %scalar.slot = getelementptr inbounds i8, ptr addrspace(1) %scalar, i64 8
  store atomic i32 73, ptr addrspace(1) %scalar.slot unordered, align 4
  %value = load atomic i32, ptr addrspace(1) %scalar.slot unordered, align 4
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %lock, ptr %lock.slot) nounwind
  ret i32 %value
}

; CHECK-LABEL: define i32 @invalid_ordinary_unbalanced_exit()
; CHECK-NOT: inttoptr (i64 68213 to ptr)
; CHECK: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
; CHECK: ret i32 73

; The leading exit consumes one interpreter-held OSR monitor.  The real exit
; equation solves EntryDepth=1, so the local virtual pair at absolute depth
; zero remains eligible for elimination.
define i32 @__jeandle_osr.valid_entry_offset(ptr addrspace(1) %preheld)
    gc "hotspotgc" {
entry:
  %preheld.slot = alloca i64, align 8
  %local.slot = alloca i64, align 8
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %preheld, ptr %preheld.slot) nounwind
  %local = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68214 to ptr), i32 16, i1 false)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %local, ptr %local.slot) nounwind
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %local, ptr %local.slot) nounwind
  ret i32 73
}

; CHECK-LABEL: define i32 @__jeandle_osr.valid_entry_offset(
; CHECK: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %preheld, ptr %preheld.slot)
; CHECK-NOT: inttoptr (i64 68214 to ptr)
; CHECK-NOT: @jeandle.monitorenter
; CHECK: ret i32 73

; The two real exits require contradictory OSR entry depths (one and two).
; The local virtual monitor operations on both arms must therefore survive.
define i32 @__jeandle_osr.invalid_exit_equations(
    i1 %twice, ptr addrspace(1) %preheld) gc "hotspotgc" {
entry:
  %preheld.one = alloca i64, align 8
  %preheld.two = alloca i64, align 8
  %left.slot = alloca i64, align 8
  %right.slot = alloca i64, align 8
  %left = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68215 to ptr), i32 16, i1 false)
  %right = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68216 to ptr), i32 16, i1 false)
  %scalar = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68217 to ptr), i32 16, i1 false)
  %scalar.slot = getelementptr inbounds i8, ptr addrspace(1) %scalar, i64 8
  store atomic i32 73, ptr addrspace(1) %scalar.slot unordered, align 4
  %value = load atomic i32, ptr addrspace(1) %scalar.slot unordered, align 4
  br i1 %twice, label %two, label %one
one:
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %preheld, ptr %preheld.one) nounwind
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %left, ptr %left.slot) nounwind
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %left, ptr %left.slot) nounwind
  ret i32 %value
two:
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %preheld, ptr %preheld.one) nounwind
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %preheld, ptr %preheld.two) nounwind
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %right, ptr %right.slot) nounwind
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %right, ptr %right.slot) nounwind
  ret i32 %value
}

; CHECK-LABEL: define i32 @__jeandle_osr.invalid_exit_equations(
; CHECK-NOT: inttoptr (i64 68217 to ptr)
; CHECK: one:
; CHECK: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %left, ptr %left.slot)
; CHECK: two:
; CHECK: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %right, ptr %right.slot)
; CHECK: ret i32 73

; With no real exit, OSR chooses the minimum offset that prevents underflow.
; The leading preheld exit requires offset one, and the local virtual pair is
; again at a valid absolute depth zero.
define void @__jeandle_osr.valid_no_real_exit(
    ptr addrspace(1) %preheld) gc "hotspotgc" {
entry:
  %preheld.slot = alloca i64, align 8
  %local.slot = alloca i64, align 8
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %preheld, ptr %preheld.slot) nounwind
  %local = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68218 to ptr), i32 16, i1 false)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %local, ptr %local.slot) nounwind
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %local, ptr %local.slot) nounwind
  br label %loop
loop:
  br label %loop
}

; CHECK-LABEL: define void @__jeandle_osr.valid_no_real_exit(
; CHECK: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %preheld, ptr %preheld.slot)
; CHECK-NOT: inttoptr (i64 68218 to ptr)
; CHECK-NOT: @jeandle.monitorenter
; CHECK: loop:
; CHECK-NEXT: br label %loop

!java-method-compilation = !{}
