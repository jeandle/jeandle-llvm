@jeandle.personality = global ptr null

declare hotspotcc i32 @jeandle.example_op() #1

define available_externally hotspotcc i32 @callee_example() #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  %r = call i32 @jeandle.example_op()
  ret i32 %r
}

attributes #0 = { "java-method"="101" }
attributes #1 = { "lower-phase"="0" "noinline" }

!java-method-compilation = !{}
