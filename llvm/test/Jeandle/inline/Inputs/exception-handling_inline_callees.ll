@jeandle.personality = global ptr null

define available_externally hotspotcc i32 @callee_with_eh() #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  invoke hotspotcc void @leaf_may_throw()
          to label %normal unwind label %unwind

normal:
  ret i32 42

unwind:
  %lp = landingpad i64
          cleanup
  resume i64 %lp
}

declare hotspotcc void @leaf_may_throw()

attributes #0 = { "java-method"="103" }

!java-method-compilation = !{}
