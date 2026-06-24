@jeandle.personality = global ptr null
@inline.alias = alias ptr, inttoptr (i64 4096 to ptr)

define available_externally hotspotcc i64 @callee_global_alias() #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  %addr = ptrtoint ptr @inline.alias to i64
  ret i64 %addr
}

attributes #0 = { "java-method"="102" }

!java-method-compilation = !{}
