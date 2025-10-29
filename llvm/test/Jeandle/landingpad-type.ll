; RUN: opt -S --passes=rewrite-statepoints-for-gc %s 2>&1 | FileCheck %s

; CHECK: landingpad token

@jeandle.personality = global ptr null

define hotspotcc void @test(i32 %0) gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  invoke hotspotcc void @callee()
          to label %bci_21_normal_dest unwind label %bci_21_unwind_dest

bci_21_unwind_dest:                               ; preds = %entry
  %14 = landingpad i64
          cleanup
  ret void

bci_21_normal_dest:                               ; preds = %entry
  ret void
}

declare hotspotcc void @callee() gc "hotspotgc"
