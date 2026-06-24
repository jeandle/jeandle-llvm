@jeandle.personality = global ptr null
@inline.global = private global i32 41

define available_externally hotspotcc i32 @callee_global_variable() #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  %value = load i32, ptr @inline.global, align 4
  %result = add i32 %value, 1
  ret i32 %result
}

attributes #0 = { "java-method"="101" }

!java-method-compilation = !{}
