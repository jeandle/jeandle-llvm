@jeandle.personality = global ptr null

define available_externally hotspotcc i32 @late_callee() #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  %OrigPcSlot = alloca i64, align 8
  %result = call hotspotcc i32 @late_child() #2 [ "deopt"(i32 11, i32 11, i64 327695, ptr %OrigPcSlot) ]
  ret i32 %result
}

define available_externally hotspotcc i32 @late_child() #1 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  ret i32 42
}

attributes #0 = { "java-method"="104" }
attributes #1 = { "java-method"="105" }
attributes #2 = { "monomorphic-target" }

!java-method-compilation = !{}
