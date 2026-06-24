@jeandle.personality = global ptr null

define available_externally hotspotcc void @callee_resume_landingpad() #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  invoke hotspotcc void @leaf_resume_landingpad()
          to label %normal unwind label %unwind

normal:
  ret void

unwind:
  %lp = landingpad i64
          cleanup
  resume i64 %lp
}

define available_externally hotspotcc void @callee_resume_zero() #1 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  resume i64 0
}

declare hotspotcc void @leaf_resume_landingpad()

attributes #0 = { "java-method"="105" }
attributes #1 = { "java-method"="106" }

!java-method-compilation = !{}
