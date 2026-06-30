@jeandle.personality = global ptr null

define available_externally hotspotcc i32 @callee_duplicate_statepoint_a() #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  invoke hotspotcc void @leaf_with_duplicate_statepoint() #1
          to label %normal unwind label %unwind

normal:
  ret i32 40

unwind:
  %lpad = landingpad token
          cleanup
  ret i32 -1
}

define available_externally hotspotcc i32 @callee_duplicate_statepoint_b() #2 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  invoke hotspotcc void @leaf_with_duplicate_statepoint() #3
          to label %normal unwind label %unwind

normal:
  ret i32 2

unwind:
  %lpad = landingpad token
          cleanup
  ret i32 -1
}

declare hotspotcc void @leaf_with_duplicate_statepoint()

attributes #0 = { "java-method"="108" }
attributes #1 = { "statepoint-id"="7" "statepoint-num-patch-bytes"="5" }
attributes #2 = { "java-method"="109" }
attributes #3 = { "statepoint-id"="8" "statepoint-num-patch-bytes"="5" }

!java-method-compilation = !{}
