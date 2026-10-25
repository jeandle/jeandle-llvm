; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/freeze-and-identity-patterns.cblog %s | FileCheck %s

declare i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)

; CHECK-LABEL: @nested_zero_gep(
; CHECK: ret i1 true
define i1 @nested_zero_gep(ptr addrspace(1) noundef "java-klass"="9" "java-klass-exact" %a,
                           i1 noundef %pick) {
  %g = getelementptr i8, ptr addrspace(1) %a, i64 0
  %r = select i1 %pick, ptr addrspace(1) %g, ptr addrspace(1) %a
  %check = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) %r)
  ret i1 %check
}

; CHECK-LABEL: @constant_selected_arm(
; CHECK: ret i1 true
define i1 @constant_selected_arm(ptr addrspace(1) "java-klass"="9" "java-klass-exact" %a,
                                 ptr addrspace(1) %unknown) {
  %r = select i1 true, ptr addrspace(1) %a, ptr addrspace(1) %unknown
  %check = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) %r)
  ret i1 %check
}

; CHECK-LABEL: @defined_icmp_select_freeze(
; CHECK: ret i1 true
define i1 @defined_icmp_select_freeze(ptr addrspace(1) noundef "java-klass"="9" "java-klass-exact" %a,
                                     ptr addrspace(1) noundef "java-klass"="9" "java-klass-exact" %b,
                                     i32 noundef %x, i1 noundef %pick) {
  %c = icmp eq i32 %x, 0
  %s = select i1 %c, ptr addrspace(1) %a, ptr addrspace(1) %b
  %f = freeze ptr addrspace(1) %s
  %r = select i1 %pick, ptr addrspace(1) %f, ptr addrspace(1) %a
  %check = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) %r)
  ret i1 %check
}

; CHECK-LABEL: @defined_load_freeze(
; CHECK: ret i1 true
define i1 @defined_load_freeze(ptr %slot) {
  %v = load ptr addrspace(1), ptr %slot, !noundef !0, !java-klass !1, !java-klass-exact !0
  %f = freeze ptr addrspace(1) %v
  %check = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) %f)
  ret i1 %check
}

; CHECK-LABEL: @defined_cycle_freeze(
; CHECK: exit:
; CHECK-NEXT: %f = freeze
; CHECK-NEXT: ret i1 true
define i1 @defined_cycle_freeze(ptr addrspace(1) noundef "java-klass"="9" "java-klass-exact" %a,
                                ptr addrspace(1) noundef "java-klass"="9" "java-klass-exact" %b,
                                i1 noundef %again) {
entry:
  br label %loop
loop:
  %p = phi ptr addrspace(1) [%a, %entry], [%q, %loop]
  %q = phi ptr addrspace(1) [%b, %entry], [%p, %loop]
  br i1 %again, label %loop, label %exit
exit:
  %f = freeze ptr addrspace(1) %p
  %check = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) %f)
  ret i1 %check
}

; CHECK-LABEL: @root_freeze_maybe_poison(
; CHECK: %check = call i1 @jeandle.check_instanceof
; CHECK-NEXT: ret i1 %check
define i1 @root_freeze_maybe_poison(ptr addrspace(1) "java-klass"="9" "java-klass-exact" %a) {
  %f = freeze ptr addrspace(1) %a
  %check = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) %f)
  ret i1 %check
}

; CHECK-LABEL: @poison_generating_icmp_freeze(
; CHECK: %check = call i1 @jeandle.check_instanceof
; CHECK-NEXT: ret i1 %check
define i1 @poison_generating_icmp_freeze(ptr addrspace(1) noundef "java-klass"="9" "java-klass-exact" %a,
                                        ptr addrspace(1) noundef "java-klass"="9" "java-klass-exact" %b,
                                        i32 noundef %x, i32 noundef %y) {
  %c = icmp samesign eq i32 %x, %y
  %s = select i1 %c, ptr addrspace(1) %a, ptr addrspace(1) %b
  %f = freeze ptr addrspace(1) %s
  %check = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) %f)
  ret i1 %check
}

; CHECK-LABEL: @nonzero_gep(
; CHECK: %check = call i1 @jeandle.check_instanceof
; CHECK-NEXT: ret i1 %check
define i1 @nonzero_gep(ptr addrspace(1) "java-klass"="9" "java-klass-exact" %a) {
  %g = getelementptr i8, ptr addrspace(1) %a, i64 1
  %check = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) %g)
  ret i1 %check
}

!0 = !{}
!1 = !{i64 9}
!java-method-compilation = !{}
