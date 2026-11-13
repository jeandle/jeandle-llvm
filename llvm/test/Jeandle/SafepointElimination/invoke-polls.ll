; RUN: opt -passes='safepoint-poll-normalization,simplifycfg,safepoint-poll-elimination,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>' -jeandle-verify-safepoint-coverage=fatal -verify-each -S %s | FileCheck %s
; RUN: opt -passes='safepoint-poll-normalization,simplifycfg,safepoint-poll-elimination' -jeandle-enable-safepoint-elim=false -verify-each -S %s | FileCheck %s --check-prefix=OFF
; RUN: opt -passes='safepoint-poll-normalization,simplifycfg,loop-simplify,loop(indvars),safepoint-strip-mining<strip-mining>,verify<jeandle-safepoint-coverage>' -jeandle-verify-safepoint-coverage=fatal -verify-each -S %s | FileCheck %s --check-prefix=STRIP
; RUN: opt -passes='safepoint-poll-normalization,simplifycfg,loop-simplify,lcssa,safepoint-poll-elimination<loop-deletion-prep>' -verify-each -S %s | FileCheck %s --check-prefix=PREP
;
; Nonthrowing normalization exposes ordinary poll calls to the existing
; elimination, ancestor coverage, empty-loop and strip-mining algorithms.

declare void @jeandle.safepoint_poll()
declare i32 @personality(...)

define void @linear() "java-method" personality ptr @personality {
entry:
  invoke void @jeandle.safepoint_poll() to label %middle unwind label %catch
middle:
  invoke void @jeandle.safepoint_poll() to label %exit unwind label %catch
exit:
  ret void
catch:
  %exception = landingpad { ptr, i32 } cleanup
  resume { ptr, i32 } %exception
}
; CHECK-LABEL: define void @linear(
; CHECK: call void @jeandle.safepoint_poll()
; CHECK-NOT: @jeandle.safepoint_poll
; CHECK: ret void
; OFF-LABEL: define void @linear(
; OFF: call void @jeandle.safepoint_poll()
; OFF: call void @jeandle.safepoint_poll()
; OFF: ret void

define void @ancestor_required(i1 %continue, ptr %output) "java-method" personality ptr @personality {
entry:
  br label %outer.header
outer.header:
  br label %inner.header
inner.header:
  %iv = phi i32 [ 0, %outer.header ], [ %next, %inner.latch ]
  store i32 %iv, ptr %output
  invoke void @jeandle.safepoint_poll() to label %inner.latch unwind label %catch
inner.latch:
  %next = add nuw nsw i32 %iv, 1
  %inner.continue = icmp ult i32 %next, 64
  br i1 %inner.continue, label %inner.header, label %outer.latch
outer.latch:
  br i1 %continue, label %outer.header, label %exit
exit:
  ret void
catch:
  %exception = landingpad { ptr, i32 } cleanup
  resume { ptr, i32 } %exception
}
; CHECK-LABEL: define void @ancestor_required(
; CHECK: store i32
; CHECK: call void @jeandle.safepoint_poll()
; CHECK: ret void

define void @counted_long(ptr %output) "java-method" personality ptr @personality {
entry:
  br label %header
header:
  %iv = phi i32 [ 0, %entry ], [ %next, %latch ]
  store i32 %iv, ptr %output
  invoke void @jeandle.safepoint_poll() to label %latch unwind label %catch
latch:
  %next = add nuw nsw i32 %iv, 1
  %continue = icmp ult i32 %next, 10000
  br i1 %continue, label %header, label %exit
exit:
  ret void
catch:
  %exception = landingpad { ptr, i32 } cleanup
  resume { ptr, i32 } %exception
}
; STRIP-LABEL: define void @counted_long(
; STRIP-NOT: invoke
; STRIP: call void @jeandle.safepoint_poll() #[[STRIPPED:[0-9]+]]
; STRIP: ret void

define void @empty_loop() "java-method" personality ptr @personality {
entry:
  br label %header
header:
  %iv = phi i32 [ 0, %entry ], [ %next, %latch ]
  invoke void @jeandle.safepoint_poll() to label %latch unwind label %catch
latch:
  %next = add nuw nsw i32 %iv, 1
  %continue = icmp ult i32 %next, 64
  br i1 %continue, label %header, label %exit
exit:
  ret void
catch:
  %exception = landingpad { ptr, i32 } cleanup
  resume { ptr, i32 } %exception
}
; PREP-LABEL: define void @empty_loop(
; PREP-NOT: @jeandle.safepoint_poll
; PREP-NOT: phi
; PREP: ret void
; STRIP: attributes #[[STRIPPED]] = { nounwind "jeandle.strip-mined-poll" }

!java-method-compilation = !{}
