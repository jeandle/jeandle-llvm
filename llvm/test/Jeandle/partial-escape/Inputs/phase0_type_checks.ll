; Phase-0 type-check wrappers, matching the frontend template. PEA sees the
; phase-1 check_instanceof after these null checks and conversions are expanded.
declare hotspotcc i1 @jeandle.check_instanceof(ptr, ptr addrspace(1)) noinline "lower-phase"="1"

define hotspotcc i1 @jeandle.checkcast(ptr %klass, ptr addrspace(1) %oop) noinline "lower-phase"="0" {
entry:
  %is_null = icmp eq ptr addrspace(1) %oop, null
  br i1 %is_null, label %return_true, label %check_subtype
return_true:
  ret i1 true
check_subtype:
  %is_subtype = call hotspotcc i1 @jeandle.check_instanceof(ptr %klass, ptr addrspace(1) %oop)
  ret i1 %is_subtype
}

define hotspotcc i32 @jeandle.instanceof(ptr %klass, ptr addrspace(1) %oop) noinline "lower-phase"="0" {
entry:
  %is_null = icmp eq ptr addrspace(1) %oop, null
  br i1 %is_null, label %return_false, label %check_subtype
return_false:
  ret i32 0
check_subtype:
  %is_subtype = call hotspotcc i1 @jeandle.check_instanceof(ptr %klass, ptr addrspace(1) %oop)
  %is_subtype_ext = zext i1 %is_subtype to i32
  ret i32 %is_subtype_ext
}
