; RUN: opt -S -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/field-phi-cycle-conflict.cblog %s 2>&1 | FileCheck %s

; Negative companion to field-phi-mutual-cycle.ll: a mutually-recursive
; PHI pair where the two entry sources are DIFFERENT oops. The lattice
; should resolve both PHIs to Bottom and refuse to fold.

@oop_handle_Test_0 = external global ptr addrspace(1)
@oop_handle_Test_1 = external global ptr addrspace(1)

define i32 @test(i1 %cond, i32 %n) gc "hotspotgc" {
entry:
  br i1 %cond, label %seed_a, label %seed_b

seed_a:
  %a = load ptr addrspace(1), ptr @oop_handle_Test_0
  br label %loop

seed_b:
  %b = load ptr addrspace(1), ptr @oop_handle_Test_1
  br label %loop

loop:
  %seed = phi ptr addrspace(1) [ %a, %seed_a ], [ %b, %seed_b ], [ %p2, %loop ]
  %p1 = phi ptr addrspace(1) [ %a, %seed_a ], [ %b, %seed_b ], [ %p2, %loop ]
  %p2 = phi ptr addrspace(1) [ %a, %seed_a ], [ %b, %seed_b ], [ %p1, %loop ]
  %i = phi i32 [ 0, %seed_a ], [ 0, %seed_b ], [ %i.next, %loop ]
  %i.next = add i32 %i, 1
  %cmp = icmp slt i32 %i.next, %n
  br i1 %cmp, label %loop, label %exit

exit:
  %addr = getelementptr i8, ptr addrspace(1) %p1, i64 12
  %value = load i32, ptr addrspace(1) %addr
  ret i32 %value
}

; CHECK: %value = load i32, ptr addrspace(1) %addr
; CHECK: ret i32 %value

!java-method-compilation = !{}
